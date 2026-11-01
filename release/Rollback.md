# Roll back an update

Use the backup directory printed by Install-Update.ps1, under `%ProgramData%\T2TouchId\UpdateBackups`. Do not read or copy provisioning files. The backup contains only driver packages and service configuration.

1. Keep T2SepBootstrap and WbioSrvc disabled and stopped during rollback. In elevated Windows PowerShell run `Set-Service WbioSrvc -StartupType Disabled; Set-Service T2SepBootstrap -StartupType Disabled; Stop-Service WbioSrvc; Stop-Service T2SepBootstrap`.
2. In Device Manager, for **Apple T2 SEP Mailbox**, choose Update driver → Browse my computer → Let me pick → Have Disk, and select the exported T2TouchIdTransport.inf in the corresponding OEM backup subfolder. Repeat for **Apple T2 Touch ID (Windows Hello sensor)** with the exported T2TouchIdBio.inf. Have Disk is needed because the prior version can rank lower. Do not select/remove NCM, keyboard or trackpad devices. Do not use broad driver cleanup commands.
3. Restore the bootstrap service path from rollback.json. In elevated PowerShell, set `$b` to the backup directory and run:

```powershell
$state = Get-Content (Join-Path $b 'rollback.json') -Raw | ConvertFrom-Json
foreach ($s in $state.Services) {
    $mode = switch ([int]$s.Start) { 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } default { throw 'Unexpected service start type' } }
    $svc = Get-CimInstance Win32_Service -Filter ("Name='" + $s.Name + "'")
    $r = Invoke-CimMethod -InputObject $svc -MethodName Change -Arguments @{PathName=[string]$s.PathName; StartMode=$mode}
    if ($r.ReturnValue -ne 0) { throw "Service restore failed: $($s.Name)" }
    Set-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $s.Name) -Name DelayedAutoStart -Value ([int]$s.DelayedAutoStart)
}
```

4. Reboot manually. Original downloaded GUI/CLI files were not overwritten; use those again. The versioned Program Files copy and fork shortcut may be removed after successful rollback. Keep the backup until verified.
5. The new certificate can remain while any fork-signed package is installed. If all such packages are removed and you want to revoke that trust, use certlm.msc to remove only the certificate whose exact thumbprint appears in release.json, from Root and Trusted Publishers. Do not remove the upstream certificate or any trackpad certificate.

No rollback step changes Test Mode, NCM, trackpad/haptics, vault data or Hello enrollment. If the prior bootstrap was in the System32 folder updated by PnP, restoring its exported prior SEP package also restores that bootstrap payload; merely changing the service path is insufficient.
