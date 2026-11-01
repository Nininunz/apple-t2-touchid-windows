# v0.9.1 startup ordering update

This **test-signed prerelease** updates an existing upstream v0.9 installation on x64 Windows. It is not a fresh-install package. Keep a working PIN/password for sign-in. Windows Hello enrollment must be completed in Windows Settings; macOS enrollment alone does not enable its lock-screen tile.

The fix completes BridgeOS discovery before SEP initialization and serializes discovery/SEP work across bootstrap, UMDF and CLI. A timeout now reports absence of a validated reply rather than claiming a hardware hang. Protocol request bytes and vault format are unchanged.

Hardware evidence: MacBookPro16,1, Windows 11 Pro build 26300. After the ordering fix, LoadKeybag replied in about 85 ms, bootstrap reached ready, CLI verification matched, and the user confirmed Windows Hello worked. This release rebuilds the cleaned source; these exact newly signed binaries and the generic update script have not been installed on hardware. Repeated boot and sleep/resume reliability is not established for this fork.

## Install an existing v0.9 setup

1. Extract the entire ZIP to a local directory. Verify the ZIP SHA256 against the separately published checksum file.
2. From 64-bit Windows PowerShell 5.1 run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Update.ps1 -ValidateOnly`. This checks payload hashes and signer identity without installing or trusting anything. A manifest inside an archive does not independently authenticate that archive.
3. Close all T2 Touch ID GUI and CLI processes. Use an elevated 64-bit Windows PowerShell window to run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Update.ps1 -TrustTestCertificate`.
4. The explicit certificate option trusts this fork's included public test-signing certificate in Local Machine Root and Trusted Publishers. The private signing key is not distributed. This is not Apple/Microsoft/WHQL signing. Test Mode must already be active; the script never changes BCD or Secure Boot.
5. Record the printed backup directory, then reboot manually. Use **T2 Touch ID (fork)** from the Start menu for the matching GUI/CLI. Do not run old downloaded copies alongside it.

The update backs up the current SEP and biometric OEM packages and service settings, disables/stops WbioSrvc and bootstrap, installs both driver packages, and selects a matching versioned bootstrap under Program Files. Services stay stopped until reboot. It does not import/read a vault or keybag, change the NCM driver, touch trackpad/haptics drivers, clear enrollment, or reboot. It refuses an engine adapter differing from the upstream v0.9 package. The GUI requires the .NET 8 Windows Desktop runtime, as in v0.9.

If installation fails after services are disabled, do not keep retrying or reboot into a partial update. Use Rollback.md and the printed backup. The public certificate may already have been imported even if a later step fails.

See release.json for the exact source revision, signing identity and upstream dependency provenance. Original LICENSE/NOTICE and libplist licenses are included.
