[CmdletBinding()]
param([switch]$ValidateOnly, [switch]$TrustTestCertificate)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$meta = Get-Content (Join-Path $root 'release.json') -Raw | ConvertFrom-Json
$manifest = Get-Content (Join-Path $root 'SHA256SUMS.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest) {
    $path = [IO.Path]::GetFullPath((Join-Path $root $entry.path))
    if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path' }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Hash mismatch: $($entry.path)" }
}
if (@(Get-ChildItem $root -File -Recurse).Count -ne ($manifest.Count + 1)) { throw 'Unexpected package files; extract a fresh archive.' }
$certPath = Join-Path $root 'Certificates\ForkTestSigning.cer'
$cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $certPath
if ($cert.Thumbprint -ne $meta.certificateThumbprint) { throw 'Certificate identity mismatch' }
foreach ($name in @('SEP\T2TouchIdTransport.sys','SEP\T2SepBootstrap.exe','SEP\T2SepCoInstaller.dll','Bio\T2TouchIdBio.dll','App\t2touchid.exe','App\T2TouchID_GUI.exe','SEP\T2TouchIdTransport.cat','Bio\T2TouchIdBio.cat')) {
    $sig = Get-AuthenticodeSignature (Join-Path $root $name)
    if ($null -eq $sig.SignerCertificate -or $sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) { throw "Unexpected signer: $name" }
}
if ($ValidateOnly) { Write-Output "Package hashes and signer identities verified: $($meta.tag). No changes made."; return }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run in elevated Windows PowerShell 5.1.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell.' }
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class T2UpdateCodeIntegrity {
 [StructLayout(LayoutKind.Sequential)] public struct Info { public uint Length; public uint Options; }
 [DllImport("ntdll.dll")] public static extern int NtQuerySystemInformation(int kind, ref Info info, uint length, out uint returned);
}
"@
$ci = New-Object T2UpdateCodeIntegrity+Info
$ci.Length = 8
[uint32]$returned = 0
if ([T2UpdateCodeIntegrity]::NtQuerySystemInformation(103, [ref]$ci, 8, [ref]$returned) -ne 0 -or ($ci.Options -band 2) -eq 0) { throw 'Test Mode must already be enabled. This update does not change boot configuration.' }
$services = @(Get-CimInstance Win32_Service -Filter "Name='T2SepBootstrap' OR Name='WbioSrvc'")
if ($services.Count -ne 2) { throw 'An existing v0.9 installation with T2SepBootstrap and WbioSrvc is required.' }
if (Get-Process T2TouchID_GUI,t2touchid -ErrorAction SilentlyContinue) { throw 'Close the GUI and CLI before updating.' }
$devices = @()
foreach ($d in Get-PnpDevice -PresentOnly) {
    if ($d.InstanceId -notmatch '^(PCI\\VEN_106B&DEV_1802|ROOT\\)') { continue }
    $ids = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_HardwareIds -ErrorAction SilentlyContinue).Data
    if (@($ids | Where-Object { $_ -match '^(PCI\\VEN_106B&DEV_1802|root\\T2TouchId$)' }).Count -eq 0) { continue }
    $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_DriverInfPath).Data
    if ($inf -notmatch '^oem\d+\.inf$') { throw 'Expected an installed third-party driver package.' }
    $devices += [pscustomobject]@{InstanceId=$d.InstanceId; Inf=$inf}
}
if ($devices.Count -ne 2 -or @($devices | Where-Object InstanceId -like 'PCI*').Count -ne 1) { throw 'Expected exactly one existing SEP device and one T2 biometric device.' }
$engine = Join-Path $env:SystemRoot 'System32\WinBioPlugIns\T2TouchIdEngineAdapter.dll'
if ((Get-FileHash $engine).Hash -ne (Get-FileHash (Join-Path $root 'Bio\T2TouchIdEngineAdapter.dll')).Hash) { throw 'Installed engine adapter differs from v0.9. Review before updating.' }
if (-not (Test-Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)") -or -not (Test-Path "Cert:\LocalMachine\TrustedPublisher\$($cert.Thumbprint)")) {
    if (-not $TrustTestCertificate) { throw 'First installation requires -TrustTestCertificate to explicitly trust the included public test-signing certificate.' }
    Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
}
foreach ($name in @('SEP\T2TouchIdTransport.cat','Bio\T2TouchIdBio.cat','SEP\T2SepBootstrap.exe','App\t2touchid.exe')) {
    if ((Get-AuthenticodeSignature (Join-Path $root $name)).Status -ne 'Valid') { throw "Signature trust verification failed: $name" }
}
$backup = Join-Path $env:ProgramData ('T2TouchId\UpdateBackups\' + $meta.tag + '-' + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$state = foreach ($s in $services) {
    $reg = Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $s.Name)
    [pscustomobject]@{Name=$s.Name; PathName=$s.PathName; Start=[int]$reg.Start; DelayedAutoStart=[int]$(if ($reg.PSObject.Properties['DelayedAutoStart']) { $reg.DelayedAutoStart } else { 0 }); State=$s.State}
}
[pscustomobject]@{Services=@($state); Devices=$devices; Release=$meta.tag} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $backup 'rollback.json')
foreach ($d in $devices) {
    $dest = Join-Path $backup $d.Inf
    New-Item -ItemType Directory -Path $dest | Out-Null
    & pnputil.exe /export-driver $d.Inf $dest
    if ($LASTEXITCODE -ne 0) { throw "Backup failed: $($d.Inf)" }
}
$target = Join-Path $env:ProgramFiles ('Nininunz\Apple T2 Touch ID\' + $meta.tag)
if (Test-Path $target) { throw "Target exists; review previous attempt: $target" }
try {
    foreach ($s in $services) { Set-Service -Name $s.Name -StartupType Disabled }
    Stop-Service WbioSrvc -ErrorAction Stop
    Stop-Service T2SepBootstrap -ErrorAction Stop
    New-Item -ItemType Directory -Path $target | Out-Null
    Copy-Item (Join-Path $root 'App') $target -Recurse
    New-Item -ItemType Directory (Join-Path $target 'Service') | Out-Null
    Copy-Item (Join-Path $root 'SEP\T2SepBootstrap.exe'),(Join-Path $root 'SEP\plist-2.0.dll') (Join-Path $target 'Service')
    foreach ($inf in @('SEP\T2TouchIdTransport.inf','Bio\T2TouchIdBio.inf')) {
        & pnputil.exe /add-driver (Join-Path $root $inf) /install
        if ($LASTEXITCODE -notin @(0,3010)) { throw "Driver update failed: $inf (exit $LASTEXITCODE)" }
    }
    foreach ($d in $devices) {
        $version = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_DriverVersion).Data
        if ($version -ne $meta.driverVersion) { throw "New driver not selected: $($d.InstanceId), version $version" }
    }
    $svc = Get-CimInstance Win32_Service -Filter "Name='T2SepBootstrap'"
    $result = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{PathName=('"' + (Join-Path $target 'Service\T2SepBootstrap.exe') + '"')}
    if ($result.ReturnValue -ne 0) { throw 'Bootstrap service path update failed' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\T2 Touch ID (fork).lnk'))
    $shortcut.TargetPath = Join-Path $target 'App\T2TouchID_GUI.exe'
    $shortcut.WorkingDirectory = Join-Path $target 'App'
    $shortcut.Save()
    foreach ($s in $state) {
        Set-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $s.Name) -Name Start -Value $s.Start
        Set-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $s.Name) -Name DelayedAutoStart -Value $s.DelayedAutoStart
    }
    Write-Output "Update staged. Reboot manually before using Touch ID. Backup: $backup"
} catch {
    Write-Warning "Update incomplete. Services remain disabled to prevent mixed initialization. Follow Rollback.md with backup $backup before rebooting. $($_.Exception.Message)"
    throw
}



