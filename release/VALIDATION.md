# Release validation

Build the Release/x64 bootstrap, CLI, UMDF driver, kernel transport and co-installer with VS 2022 v143 and WDK/SDK 10.0.26100.0. Set `ReleasePackaging=true` for native projects to omit local PDB paths, `ResolveNuGetPackages=false` for native projects, and use Spectre-mitigated libraries for the kernel/UMDF builds. Build the WPF GUI with .NET 8, `DebugType=None` and `DebugSymbols=false`.

Run tests/StartupOrderingTests.vcxproj and tests/T2TouchIdTests.vcxproj. A nonadmin registry round-trip skip is expected and must be reported. No test should access provisioning secrets.

Stage the INF templates as amd64, inject libplist runtime copy entries just as upstream's release workflow does, and stamp both DriverVer values identically. Sign PE files with the dedicated nonexportable fork test-signing key, generate catalogs with Inf2Cat, then sign catalogs. Ship only the public CER. Keep upstream runtime/engine binaries unchanged and record their upstream archive SHA256 and libplist 2.8.0 source revision in release.json; include its LGPL/GPL license texts. Do not ship PDBs, logs, traces, provisioning or private key files.

Validate all manifest hashes, certificate identities and cryptographic catalog signatures; run Install-Update.ps1 -ValidateOnly with the packaged payload in both PowerShell 5.1 and the development shell. Check the ZIP contents against an explicit allowlist, scan generated binaries for local build paths, and publish a separate ZIP checksum. Validation-only does not test PnP installation, catalog policy trust, reboot ordering or hardware behavior of these exact binaries. Keep a prerelease designation until those are tested.
