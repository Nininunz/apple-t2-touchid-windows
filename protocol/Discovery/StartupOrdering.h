// SPDX-License-Identifier: GPL-2.0-only
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <sddl.h>
#include <thread>
#pragma comment(lib, "advapi32.lib")

namespace t2::startup {
// Numeric Win32 wait results avoid UMDF STATUS_* macro aliases (same convention as TransportMode.h).
inline constexpr DWORD kSignaled = 0, kAbandoned = 0x80;
inline constexpr wchar_t kGateSddl[] = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;LS)";
inline constexpr wchar_t kMutexName[] = L"Global\\T2TouchId_DiscoverySepOrdering_v1";
enum class LockResult { Acquired, Cancelled, Timeout, Abandoned, Error };
// Strict ordering, unlike TransportLock's intentionally fail-open mode policy.
// Lock order: StartupLock -> TransportLock. Never acquire in reverse order.
// Test callers may supply an isolated object name and ACL; production uses defaults.
class StartupLock {
    HANDLE handle_ = nullptr;
    LockResult result_ = LockResult::Error;
public:
    explicit StartupLock(HANDLE cancel = nullptr, DWORD waitMs = 60000,
                         const wchar_t* name = kMutexName,
                         const wchar_t* sddl = kGateSddl) {
        if (cancel && WaitForSingleObject(cancel, 0) == kSignaled) {
            result_ = LockResult::Cancelled;
            return;
        }
        PSECURITY_DESCRIPTOR sd = nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl, SDDL_REVISION_1, &sd, nullptr)) return;
        SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
        handle_ = CreateMutexExW(&sa, name, 0, SYNCHRONIZE | MUTEX_MODIFY_STATE);
        LocalFree(sd);
        if (!handle_) return;
        HANDLE handles[2] = { cancel, handle_ };
        const DWORD r = cancel ? WaitForMultipleObjects(2, handles, FALSE, waitMs)
                               : WaitForSingleObject(handle_, waitMs);
        const DWORD acquired = cancel ? kSignaled + 1 : kSignaled;
        const DWORD abandoned = cancel ? kAbandoned + 1 : kAbandoned;
        if (r == acquired) {
            if (cancel && WaitForSingleObject(cancel, 0) == kSignaled) {
                ReleaseMutex(handle_);
                result_ = LockResult::Cancelled;
            } else result_ = LockResult::Acquired;
        } else if (r == abandoned) {
            ReleaseMutex(handle_);
            result_ = LockResult::Abandoned;
        } else if (r == WAIT_TIMEOUT) result_ = LockResult::Timeout;
        else if (cancel && r == kSignaled) result_ = LockResult::Cancelled;
    }
    ~StartupLock() {
        if (owned()) ReleaseMutex(handle_);
        if (handle_) CloseHandle(handle_);
    }
    StartupLock(const StartupLock&) = delete;
    StartupLock& operator=(const StartupLock&) = delete;
    bool owned() const { return result_ == LockResult::Acquired; }
    LockResult result() const { return result_; }
};

// A cooperative deadline: stop launching work at the deadline, drain existing
// bounded network calls, and reject even a successful result returned too late.
class Deadline {
    HANDLE stop_ = nullptr;
    HANDLE done_ = nullptr;
    HANDLE cancel_ = nullptr;
    ULONGLONG end_ = 0;
    std::thread watcher_;
public:
    Deadline(HANDLE stop, DWORD budgetMs) : stop_(stop), end_(GetTickCount64() + budgetMs) {
        done_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        cancel_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!done_ || !cancel_) return;
        try {
            watcher_ = std::thread([this, budgetMs] {
                HANDLE h[2] = { done_, stop_ };
                const DWORD r = WaitForMultipleObjects(stop_ ? 2 : 1, h, FALSE, budgetMs);
                if (r != kSignaled) SetEvent(cancel_);
            });
        } catch (...) {
            SetEvent(cancel_);
        }
    }
    ~Deadline() {
        if (done_) SetEvent(done_);
        if (watcher_.joinable()) watcher_.join();
        if (cancel_) CloseHandle(cancel_);
        if (done_) CloseHandle(done_);
    }
    Deadline(const Deadline&) = delete;
    Deadline& operator=(const Deadline&) = delete;
    bool valid() const { return watcher_.joinable(); }
    HANDLE event() const { return cancel_; }
    bool cancelled() const {
        return !valid() || GetTickCount64() >= end_ ||
            WaitForSingleObject(cancel_, 0) == kSignaled ||
            (stop_ && WaitForSingleObject(stop_, 0) == kSignaled);
    }
};

enum class FlowResult { Ready, DiscoveryFailed, Cancelled, InitializationFailed };
template<class Discover, class Initialize>
FlowResult AfterDiscovery(Deadline& deadline, Discover discover, Initialize initialize) {
    if (deadline.cancelled()) return FlowResult::Cancelled;
    const bool ready = discover();
    if (deadline.cancelled()) return FlowResult::Cancelled;
    if (!ready) return FlowResult::DiscoveryFailed;
    return initialize() ? FlowResult::Ready : FlowResult::InitializationFailed;
}
} // namespace t2::startup
