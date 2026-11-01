# Installer revision checks; no service, device or provisioning access.
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'Install-Update.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Installer parse failed'}
$filter=$ast.FindAll({param($node) $node -is [Management.Automation.Language.BinaryExpressionAst] -and $node.Operator -eq 'Imatch' -and $node.Right.Extent.Text -like '*T2TouchId*'},$true)
if(@($filter).Count -ne 1){throw 'Expected one biometric hardware-ID filter'}
$pattern=$filter[0].Right.SafeGetValue()
foreach($id in @('root\T2TouchIdBio','ROOT\T2TOUCHIDBIO','PCI\VEN_106B&DEV_1802&SUBSYS_1802106B')){if($id -notmatch $pattern){throw "Expected match: $id"}}
foreach($id in @('root\T2TouchId','root\T2TouchIdBioOther','PCI\VEN_106B&DEV_1801','USB\Trackpad')){if($id -match $pattern){throw "Unexpected match: $id"}}
$loop=$ast.FindAll({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$state'},$true)
if(@($loop).Count -ne 1){throw 'Expected one service restore loop'}
$script:serviceCalls=@();$script:registryCalls=@()
function Set-Service {param($Name,$StartupType) $script:serviceCalls+=@{Name=$Name;StartupType=$StartupType}}
function Set-ItemProperty {param($Path,$Name,$Value) $script:registryCalls+=@{Name=$Name;Value=$Value}}
$state=@(@{Name='T2SepBootstrap';Start=2;DelayedAutoStart=1},@{Name='WbioSrvc';Start=3;DelayedAutoStart=0},@{Name='DisabledExample';Start=4;DelayedAutoStart=0})
& ([scriptblock]::Create($loop[0].Extent.Text))
if(($serviceCalls.StartupType -join ',') -ne 'Automatic,Manual,Disabled'){throw 'SCM restore modes incorrect'}
if($registryCalls.Count -ne 6){throw 'Registry restore incomplete'}
'PASS: parser, hardware-ID positive/negative cases, mocked SCM/registry restoration; no machine state changed.'
