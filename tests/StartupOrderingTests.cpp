// SPDX-License-Identifier: GPL-2.0-only
#include "../protocol/Discovery/StartupOrdering.h"
#include <atomic>
#include <iostream>
#include <string>
#include <vector>
using namespace t2::startup;
// Only test objects allow unprivileged authenticated users. Production ACL is unchanged.
static constexpr wchar_t kTestAcl[] = L"D:(A;;GA;;;OW)(A;;0x100001;;;AU)";
static int checks = 0;
static void Check(bool value, const char* label) {
    ++checks;
    if (!value) { std::cerr << "FAIL: " << label << "\n"; ExitProcess(1); }
}
static DWORD Child(const std::wstring& mode, const std::wstring& name) {
    wchar_t exe[MAX_PATH]; GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring command = L"\"" + std::wstring(exe) + L"\" " + mode + L" " + name;
    STARTUPINFOW si{}; si.cb = sizeof(si); PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, nullptr, &si, &pi)) return 999;
    CloseHandle(pi.hThread);
    if (WaitForSingleObject(pi.hProcess, 5000) != WAIT_OBJECT_0) ExitProcess(2);
    DWORD code = 999; GetExitCodeProcess(pi.hProcess, &code); CloseHandle(pi.hProcess);
    return code;
}
int wmain(int argc, wchar_t** argv) {
    if (argc == 3) {
        StartupLock lock(nullptr, 100, argv[2], kTestAcl);
        if (std::wstring(argv[1]) == L"contend") return lock.result() == LockResult::Timeout ? 0 : 3;
        if (!lock.owned()) return 4;
        ExitProcess(0); // intentionally abandoned, parent keeps the object alive
    }
    const std::wstring name = L"Local\\T2OrderingTests_" + std::to_wstring(GetCurrentProcessId());
    HANDLE cancel = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    { StartupLock lock(cancel, 10, name.c_str(), kTestAcl); Check(lock.result() == LockResult::Cancelled, "pre-cancel"); }
    ResetEvent(cancel);
    {
        StartupLock outer(nullptr, 100, name.c_str(), kTestAcl); Check(outer.owned(), "gate creation");
        { StartupLock nested(nullptr, 10, name.c_str(), kTestAcl); Check(nested.owned(), "bootstrap recursive discovery lock"); }
        Check(Child(L"contend", name) == 0, "cross-process exclusion");
        std::atomic<bool> wasCancelled{false};
        std::thread waiter([&] { StartupLock lock(cancel, 2000, name.c_str(), kTestAcl); wasCancelled = lock.result() == LockResult::Cancelled; });
        SetEvent(cancel); waiter.join(); Check(wasCancelled, "cancellation while contended");
    }
    ResetEvent(cancel);
    HANDLE keeper = CreateMutexW(nullptr, FALSE, name.c_str());
    Check(keeper != nullptr, "keep abandoned object alive");
    Check(Child(L"abandon", name) == 0, "abandon child");
    { StartupLock lock(nullptr, 100, name.c_str(), kTestAcl); Check(lock.result() == LockResult::Abandoned && !lock.owned(), "abandon fails closed"); }
    CloseHandle(keeper);
    const std::wstring collision = name + L"_collision";
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, collision.c_str());
    { StartupLock lock(nullptr, 10, collision.c_str(), kTestAcl); Check(lock.result() == LockResult::Error && !lock.owned(), "wrong object type fails closed"); }
    CloseHandle(event);
    int initializationCalls = 0, discoveryCalls = 0;
    {
        Deadline d(cancel, 1000);
        auto result = AfterDiscovery(d, [&] { ++discoveryCalls; return false; }, [&] { ++initializationCalls; return true; });
        Check(result == FlowResult::DiscoveryFailed && initializationCalls == 0, "no initialization after failed discovery");
    }
    {
        Deadline d(cancel, 10);
        auto result = AfterDiscovery(d, [] { Sleep(30); return true; }, [&] { ++initializationCalls; return true; });
        Check(result == FlowResult::Cancelled && initializationCalls == 0, "late successful discovery cannot initialize");
    }
    SetEvent(cancel);
    {
        Deadline d(cancel, 1000);
        auto result = AfterDiscovery(d, [&] { ++discoveryCalls; return true; }, [&] { ++initializationCalls; return true; });
        Check(result == FlowResult::Cancelled && discoveryCalls == 1 && initializationCalls == 0, "stopped service launches neither phase");
    }
    ResetEvent(cancel);
    std::vector<int> order;
    {
        Deadline d(cancel, 1000);
        auto result = AfterDiscovery(d, [&] { order.push_back(1); return true; }, [&] { order.push_back(2); ++initializationCalls; return false; });
        Check(result == FlowResult::InitializationFailed && initializationCalls == 1 && order == std::vector<int>({1,2}), "exact ordering and no AKS retry");
    }
    // Discovery cannot restart while bootstrap owns the gate through initialization.
    {
        StartupLock bootstrap(nullptr, 100, name.c_str(), kTestAcl);
        std::atomic<bool> blocked{false};
        std::thread discovery([&] { StartupLock lock(nullptr, 30, name.c_str(), kTestAcl); blocked = !lock.owned(); });
        discovery.join(); Check(blocked, "discovery excluded through SEP phase");
    }
    {
        int calls = 0;
        Deadline d(cancel, 1000);
        auto result = AfterDiscovery(d, [] { return true; }, [&] { ++calls; return true; });
        Check(result == FlowResult::Ready && calls == 1, "successful discovery initializes exactly once");
    }
    {
        int calls = 0;
        Deadline d(cancel, 1000);
        auto result = AfterDiscovery(d, [&] { SetEvent(cancel); return true; }, [&] { ++calls; return true; });
        Check(result == FlowResult::Cancelled && calls == 0, "stop during discovery blocks initialization");
    }
    CloseHandle(cancel);
    std::cout << "PASS " << checks << " checks; no driver, network, vault or registry access\n";
    return 0;
}
