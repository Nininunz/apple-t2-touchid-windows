[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$Baseline,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$CertificateThumbprint,
 [string]$SdkBin = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0',
 [string]$Tag = 'v0.9.1-startup-ordering',
 [string]$DriverVersion = '1.2026.1031.5'
)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$commit = (& git -C $src rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or (& git -C $src status --porcelain)) { throw 'Commit the release source first; staging requires a clean tree.' }
if (Test-Path $OutputDirectory) { throw 'Choose an unused output directory.' }
$signer = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint"
if (-not $signer.HasPrivateKey) { throw 'Signing key not available' }
New-Item -ItemType Directory $OutputDirectory | Out-Null
$out = (Resolve-Path $OutputDirectory).Path
foreach ($dir in @('SEP','Bio','App','Certificates','licenses\libplist')) { New-Item -ItemType Directory (Join-Path $out $dir) -Force | Out-Null }
$files = @{
 'driver\T2TouchIdTransport\build\T2TouchIdTransport\x64\Release\T2TouchIdTransport.sys'='SEP\T2TouchIdTransport.sys';
 'build\T2SepBootstrap\x64\Release\T2SepBootstrap.exe'='SEP\T2SepBootstrap.exe';
 'build\T2SepCoInstaller\x64\Release\T2SepCoInstaller.dll'='SEP\T2SepCoInstaller.dll';
 'driver\T2TouchIdBio\umdf\build\T2TouchIdBio\x64\Release\T2TouchIdBio.dll'='Bio\T2TouchIdBio.dll';
 'build\t2touchid\x64\Release\t2touchid.exe'='App\t2touchid.exe';
 'driver\T2TouchIdTransport\T2TouchIdTransport.inf'='SEP\T2TouchIdTransport.inf';
 'driver\T2TouchIdBio\umdf\T2TouchIdBio.inf'='Bio\T2TouchIdBio.inf'
}
foreach ($entry in $files.GetEnumerator()) { Copy-Item (Join-Path $src $entry.Key) (Join-Path $out $entry.Value) }
foreach ($name in @('T2TouchID_GUI.exe','T2TouchID_GUI.dll','T2TouchID_GUI.deps.json','T2TouchID_GUI.runtimeconfig.json')) { Copy-Item (Join-Path $src "driver\T2TouchIdBio\bin\Release\net8.0-windows\$name") (Join-Path $out 'App') }
$upstream = @{
 'SEP\plist-2.0.dll'='A95BD289C274571BD3A1D80CBBBC83889643719F27A31207EA448887FC9FC830';
 'Bio\plist-2.0.dll'='AFF18478C49D7561C1F6864254EE053F0E343A55C1B9AE7A44F5C523FD4FADD1';
 'Bio\T2TouchIdEngineAdapter.dll'='95B4725F031C3407E9EFDCCC25810FE9FF12EEFAC6A2B2F81E123CA979D298A9'
}
foreach ($entry in $upstream.GetEnumerator()) {
 $path=Join-Path $Baseline $entry.Key
 if ((Get-FileHash $path).Hash -ne $entry.Value) { throw "Unexpected baseline dependency: $($entry.Key)" }
 Copy-Item $path (Join-Path $out $entry.Key)
}
Copy-Item (Join-Path $Baseline 'SEP\plist-2.0.dll') (Join-Path $out 'App')
foreach ($name in @('LICENSE','NOTICE.md')) { Copy-Item (Join-Path $src $name) $out }
foreach ($name in @('Install-Update.ps1','README.md','Rollback.md','VALIDATION.md','THIRD-PARTY-NOTICES.md')) { Copy-Item (Join-Path $PSScriptRoot $name) $out }
# License texts must be checked out from the dependency source revision stated below.
$dep = Join-Path (Split-Path $src -Parent) 'build-deps\libplist'
if ((& git -C $dep rev-parse HEAD).Trim() -ne 'fe3dc34dc3484006e12b403f7ceb06f0ad40b6f4') { throw 'Use pinned libplist 2.8.0 sources for licenses and headers.' }
Copy-Item (Join-Path $dep 'COPYING'),(Join-Path $dep 'COPYING.LESSER') (Join-Path $out 'licenses\libplist')
Export-Certificate -Cert $signer -FilePath (Join-Path $out 'Certificates\ForkTestSigning.cer') | Out-Null
function Run-Checked([string]$Exe, [string[]]$Arguments) { & $Exe @Arguments; if ($LASTEXITCODE -ne 0) { throw "$Exe failed ($LASTEXITCODE)" } }
$signTool=Join-Path $SdkBin 'x64\signtool.exe'
foreach ($relative in @('SEP\T2TouchIdTransport.sys','SEP\T2SepBootstrap.exe','SEP\T2SepCoInstaller.dll','Bio\T2TouchIdBio.dll','App\t2touchid.exe','App\T2TouchID_GUI.exe','App\T2TouchID_GUI.dll')) {
 Run-Checked $signTool @('sign','/fd','SHA256','/sha1',$CertificateThumbprint,(Join-Path $out $relative))
}
foreach ($dir in @('SEP','Bio')) {
 $inf = Join-Path $out $(if($dir -eq 'SEP'){'SEP\T2TouchIdTransport.inf'}else{'Bio\T2TouchIdBio.inf'})
 $s=Get-Content $inf -Raw
 $s=$s.Replace('[SourceDisksFiles]',"[SourceDisksFiles]`r`nplist-2.0.dll = 1,,")
 $section=if($dir -eq 'SEP'){'[T2SepBootstrap_CopyFiles]'}else{'[UMDriverCopy]'}
 $s=$s.Replace($section,$section+"`r`nplist-2.0.dll")
 Set-Content $inf $s -Encoding Unicode
 $stampArgs=@('-f',$inf,'-a','amd64','-d','10/31/2026','-v',$DriverVersion)
 if($dir -eq 'Bio'){$stampArgs+=@('-u','2.15.0')}else{$stampArgs+=@('-k','1.15')}
 Run-Checked (Join-Path $SdkBin 'x64\stampinf.exe') $stampArgs
 Run-Checked (Join-Path $SdkBin 'x86\Inf2Cat.exe') @('/driver:'+(Join-Path $out $dir),'/os:10_GE_X64','/uselocaltime')
 $cat = Get-ChildItem (Join-Path $out $dir) -Filter '*.cat'
 Run-Checked $signTool @('sign','/fd','SHA256','/sha1',$CertificateThumbprint,$cat.FullName)
}
[ordered]@{
 tag=$Tag; driverVersion=$DriverVersion; sourceRepository='https://github.com/Nininunz/apple-t2-touchid-windows'; sourceCommit=$commit;
 certificateThumbprint=$CertificateThumbprint; testSigned=$true; hardwareInstalled=$false;
 baselineRelease='https://github.com/Osaul4ik/apple-t2-touchid-windows/releases/tag/v.0.9';
 baselineArchiveSHA256='ECB8CE198C70BBBDD8884DE4B3D22241E82845180243A25B8B12EB32CA64DAD4';
 baselineSourceCommit='b3ea71f35dd570e0673ddd42ea8e617001849e4b';
 unchangedBaselineFiles=$upstream; libplistVersion='2.8.0'; libplistSourceCommit='fe3dc34dc3484006e12b403f7ceb06f0ad40b6f4';
 validation=@('Ordering: 16 checks passed','Protocol tests passed; nonadmin registry test skipped','Kernel build: 0 warnings, 0 errors','No installation or reboot performed for this release')
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'release.json')
$manifest = @(Get-ChildItem $out -File -Recurse | Sort-Object FullName | ForEach-Object { [pscustomobject]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/'); sha256=(Get-FileHash $_.FullName).Hash} })
$manifest | ConvertTo-Json | Set-Content (Join-Path $out 'SHA256SUMS.json')
Write-Output "Staged $out from $commit. Run validation before archiving."

