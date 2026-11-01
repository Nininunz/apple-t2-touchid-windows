# BridgeOS discovery before SEP initialization

This fork fixes a startup-ordering failure observed on a 2019 16-inch
MacBook Pro (MacBookPro16,1), Windows 11 Pro build 26300, using the upstream
v.0.9 / RC1 baseline (`b3ea71f35dd570e0673ddd42ea8e617001849e4b`).

## Problem and resulting behavior

Previously, T2SepBootstrap could register OOL buffers and send LoadKeybag
while BridgeOS network discovery was still starting or running elsewhere.
On the tested machine, both OOL controls were acknowledged but the first
LoadKeybag request received no observed reply and timed out after five
seconds. The timeout happened before password verification; its default
SEP status value was not a successful SEP response.

Bootstrap now discovers and verifies the existing BiometricKit BridgeXPC
connection before reading the vault, registering OOL memory, or sending an
AppleKeyStore request. It requires both the existing handshake and a valid
bridge-version response, closes the connection, and lets all discovery
workers finish before starting SEP initialization.

A strict cross-process mutex covers discovery and the whole bootstrap
sequence. UMDF discovery, the CLI's separate discovery implementation, and
AppleKeyStore client calls participate. Holding the mutex across both
phases prevents another process from starting a scan in the gap between
discovery and LoadKeybag. Status queries do not take this mutex, so clients
can still check bootstrap progress.

The lock order is startup-ordering mutex, then existing transport-mode
mutex. Unlike the existing transport-mode mutex, this gate never continues
without ownership. Timeout, cancellation, mutex failure, or an abandoned
owner prevents initialization. Production access is restricted to SYSTEM,
Administrators, and LocalService; isolated tests supply their own object
name and ACL rather than weakening the production ACL.

## Deadline and failure handling

The discovery phase has a 60-second cooperative budget, including time
waiting for the gate. Existing bounded network calls drain on cancellation;
this is not a hard real-time wall-clock limit. Even a successful response
returned after the budget expires does not authorize initialization.
Transport interface arrival has its separate existing bounded wait.

The service creates its stop event before bootstrap, rather than after it,
so discovery can observe stop requests. Discovery failure is reported as
reason 7 / step 10 without changing the existing status structure layout or
renumbering existing values. The GUI describes this as readiness failure,
not an incorrect password or a proven SEP hardware hang.

The normal V2 AKS request format, digest validation, keybag contents,
credential handling, and mailbox response matching are unchanged. There is
no fixed startup sleep, automatic keybag re-import, or AKS retry loop.
The transport's existing waiting I/O handlers are explicitly constrained to
PASSIVE_LEVEL, matching their wait-lock and sleeping-poll requirements.

## Evidence and limits

On the first captured boot with coherent deployment:

- Discovery completed before the first OOL registration and AKS request.
- V2 LoadKeybag received a validated reply in approximately 85 ms.
- Set-system-keybag and both unlock operations succeeded; bootstrap reported
  SEP ready.
- A subsequent CLI test returned `verify-match`. The user then completed
  Windows Hello fingerprint setup and confirmed it worked.

This is one-machine validation, not a claim of broad hardware compatibility
or long-term boot/suspend reliability. The Linux reference also documents
this ordering hazard and orders its transport service after port refresh:
[bring-up troubleshooting](https://github.com/jmurth1234/t2-touchid-linux/blob/ea46d8a0aef3e73b0e2f747aa18721dbcd265bce/docs/LINUX_BRINGUP_TROUBLESHOOTING.md).
The experiment supports ordering as a sufficient fix on the tested machine;
it does not identify the internal BridgeOS failure mechanism.

The visible GUI does not need to remain open. The bootstrap service and
biometric/transport drivers are required for operation. macOS finger
registration and Windows Hello setup are separate: the Windows account
still needs Fingerprint recognition setup in Sign-in options.

## Deployment scope

Deploy the patched bootstrap, UMDF biometric driver, and CLI together; old
running discovery callers do not participate in the new gate. The GUI adds
the new readiness-failure message. Do not treat a bootstrap-only replacement
as a complete deployment. Keep normal installer signing/catalog verification
and a rollback copy of the prior packages. This fork does not change the
trackpad/haptics or NCM drivers or require changing Test Mode.

No signing key, private provisioning data, machine-specific installer,
raw trace, or diagnostic-only V1 capability experiment is included in this
change. Do not commit keybags, encrypted vaults, passwords, signing keys, or
memory dumps when preparing a report. A public report should use phase
results and elapsed times, not private payloads.

## Build and test

Use the upstream Visual Studio/WDK build and libplist dependency setup for
the driver, bootstrap, CLI and GUI. The shared protocol project now includes
BridgeDiscovery because bootstrap uses the existing discovery implementation.
No new wire protocol or replacement property-list library is introduced.

The ordering tests need only Visual Studio 2022 C++ tools and a Windows SDK;
they do not need WDK installation, driver installation, administrator access,
network access, enrollment, or credentials:

```powershell
msbuild tests/StartupOrderingTests.vcxproj /p:Configuration=Release /p:Platform=x64
.\build\StartupOrderingTests\x64\Release\StartupOrderingTests.exe
```

The tests cover cross-process contention, recursive acquisition,
cancellation, abandonment, object-type collision, failed/late discovery,
successful initialization, and prevention of initialization retries or
concurrent rediscovery. The standalone project can also run in Windows CI
without driver installation or credentials. The existing protocol regression
suite remains applicable.
