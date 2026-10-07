#requires -Version 7.4
[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot),[string]$InitialPackageJson,[string]$Proxy)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw '安装生命周期验证需要 Windows。'}
$ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
$fixture=Join-Path $ProjectRoot ('.test-output/desktop-installer-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$script:desktopPassed=0
function Assert-Desktop([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:desktopPassed++}
function Invoke-DesktopFixtureProcess {
 param([string]$Executable,[string[]]$Arguments,[switch]$MinimalPath,[int]$Timeout=240000)
 $start=[Diagnostics.ProcessStartInfo]::new($Executable);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 if($MinimalPath){$start.Environment['PATH']=Join-Path $env:WINDIR 'System32'}
 $process=[Diagnostics.Process]::Start($start)
 try{if(-not $process.WaitForExit($Timeout)){$process.Kill($true);throw 'Desktop fixture process timed out.'};return $process.ExitCode}finally{$process.Dispose()}
}
$app=Join-Path $fixture '应用 测试'
try{
 Import-Module (Join-Path $ProjectRoot 'src/VpsDeploy.Update.psm1') -Force
 if($InitialPackageJson){$first=Get-Content -Raw -LiteralPath $InitialPackageJson|ConvertFrom-Json -AsHashtable}
 else{$first=& (Join-Path $ProjectRoot 'scripts/New-VpsReleasePackage.ps1') -ProjectRoot $ProjectRoot -Destination (Join-Path $fixture 'initial-package') -Development -TestBuild -PackageVersion '1.0.0' -Proxy $Proxy}
 if(-not $first.TestBuild){throw 'Tests accept only a build without shortcuts or uninstall registry entries.'}
 $v=[version]$first.Version;$nextVersion="$($v.Major).$($v.Minor).$($v.Build+1)"
 $next=& (Join-Path $ProjectRoot 'scripts/New-VpsReleasePackage.ps1') -ProjectRoot $ProjectRoot -Destination (Join-Path $fixture 'next-package') -Development -TestBuild -PackageVersion $nextVersion -Proxy $Proxy
 $installArgs=@('/SP-','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS',('/DIR='+$app))
 Assert-Desktop ((Invoke-DesktopFixtureProcess $first.Installer $installArgs) -eq 0) 'real installer installs to isolated directory with spaces and Chinese'
 Assert-Desktop (Test-Path -LiteralPath (Join-Path $app 'MXH-VPS-Deploy.exe')) 'native desktop EXE installed'
 Assert-Desktop ((Get-VpsApplicationDistribution $app) -eq 'Installed') 'installer mode recognized'
 $exeBytes=[IO.File]::ReadAllBytes((Join-Path $app 'MXH-VPS-Deploy.exe'));$pe=[BitConverter]::ToInt32($exeBytes,0x3c)
 Assert-Desktop ([BitConverter]::ToUInt16($exeBytes,$pe+4) -eq 0x8664 -and [BitConverter]::ToUInt16($exeBytes,$pe+24+68) -eq 2) 'x64 Windows GUI EXE, no console subsystem'
 $proof=Join-Path $app 'runtime-proof.json'
 Assert-Desktop ((Invoke-DesktopFixtureProcess (Join-Path $app 'MXH-VPS-Deploy.exe') @('--verify-runtime',$proof) -MinimalPath) -eq 0) 'native EXE works without global PowerShell or Python on PATH'
 $runtimeProof=Get-Content -Raw -LiteralPath $proof|ConvertFrom-Json -AsHashtable
 Assert-Desktop ($runtimeProof.wpf_loaded -and $runtimeProof.runtime_paths_local -and $runtimeProof.powershell -eq '7.4.20') 'real WPF and private runtimes loaded'
 Remove-Item -LiteralPath $proof
 [IO.Directory]::CreateDirectory((Join-Path $app 'private/instances'))|Out-Null
 [IO.Directory]::CreateDirectory((Join-Path $app '.cache/fixture'))|Out-Null
 'fixture archive'|Set-Content -LiteralPath (Join-Path $app 'private/instances/record.txt')
 'fixture local settings'|Set-Content -LiteralPath (Join-Path $app 'config/app-defaults.local.json')
 'fixture cache'|Set-Content -LiteralPath (Join-Path $app '.cache/fixture/record.txt')
 $privateHash=(Get-FileHash -LiteralPath (Join-Path $app 'private/instances/record.txt')).Hash
 $localHash=(Get-FileHash -LiteralPath (Join-Path $app 'config/app-defaults.local.json')).Hash
 $outside=Join-Path $fixture 'outside-authority.json';'fixture external authority'|Set-Content -LiteralPath $outside
 $outsideHash=(Get-FileHash -LiteralPath $outside).Hash
 $readme=Join-Path $app 'README.md';$original=[IO.File]::ReadAllBytes($readme)
 'fixture user edit'|Add-Content -LiteralPath $readme
 $editedHash=(Get-FileHash -LiteralPath $readme).Hash
 Assert-Desktop ((Invoke-DesktopFixtureProcess (Join-Path $app 'app-helpers/SetupGuard.exe') @($app,$next.FileManifest)) -ne 0) 'managed user edit blocks update'
 Assert-Desktop ((Invoke-DesktopFixtureProcess $next.Installer $installArgs) -ne 0) 'real installer refuses to overwrite managed user edit'
 Assert-Desktop ((Get-FileHash -LiteralPath $readme).Hash -eq $editedHash -and (Get-VpsApplicationVersion $app).ToString() -eq $first.Version) 'blocked install leaves files and version unchanged'
 [IO.File]::WriteAllBytes($readme,$original)
 $collision=Join-Path $app 'user-note.txt';'fixture unmanaged file'|Set-Content -LiteralPath $collision
 $fake=Get-Content -Raw -LiteralPath $next.FileManifest|ConvertFrom-Json -AsHashtable
 $fake.files+=@{path='user-note.txt';sha256=(Get-FileHash -LiteralPath $collision).Hash.ToLowerInvariant()}
 $fakePath=Join-Path $fixture 'collision-manifest.json';$fake|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $fakePath
 Assert-Desktop ((Invoke-DesktopFixtureProcess (Join-Path $app 'app-helpers/SetupGuard.exe') @($app,$fakePath)) -ne 0) 'new managed path cannot overwrite an unmanaged file'
 Remove-Item -LiteralPath $collision
 $stage=Join-Path $app ('.tmp/app-update-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($stage)|Out-Null
 $setup=Join-Path $stage "mxh-vps-deploy-v$nextVersion-windows-amd64-setup.exe"
 $files=Join-Path $stage "mxh-vps-deploy-v$nextVersion-windows-amd64.files.json"
 Copy-Item -LiteralPath $next.Installer -Destination $setup
 Copy-Item -LiteralPath $next.FileManifest -Destination $files
 $helper=Join-Path $stage 'InstalledUpdate.exe';Copy-Item -LiteralPath (Join-Path $app 'app-helpers/InstalledUpdate.exe') -Destination $helper
 $job=Join-Path $stage 'update-job.private.json'
 @{ProjectRoot=$app;Stage=$stage;Version=$nextVersion;ParentPid=0;LauncherPid=0;ParentStarted='';LauncherStarted='';InstallerSha256=(Get-FileHash -LiteralPath $setup).Hash.ToLowerInvariant();ManifestSha256=(Get-FileHash -LiteralPath $files).Hash.ToLowerInvariant();CurrentManifestSha256=(Get-FileHash -LiteralPath (Join-Path $app 'application-files.json')).Hash.ToLowerInvariant()}|ConvertTo-Json|Set-Content -LiteralPath $job
 Assert-Desktop ((Invoke-DesktopFixtureProcess $helper @($job)) -eq 0) 'native update helper runs verified newer installer in place'
 Assert-Desktop ((Get-VpsApplicationVersion $app).ToString() -eq $nextVersion) 'app version updated without uninstalling'
 Assert-Desktop ((Get-FileHash -LiteralPath (Join-Path $app 'private/instances/record.txt')).Hash -eq $privateHash -and (Get-FileHash -LiteralPath (Join-Path $app 'config/app-defaults.local.json')).Hash -eq $localHash) 'in-place installer update preserves archive and local settings'
 $watch=[Diagnostics.Stopwatch]::StartNew();while((Test-Path -LiteralPath $stage) -and $watch.ElapsedMilliseconds -lt 15000){[Threading.Thread]::Sleep(50)}
 Assert-Desktop (-not(Test-Path -LiteralPath $stage)) 'successful installed update removes only its transient stage'
 Assert-Desktop (Test-Path -LiteralPath (Join-Path $app 'private/update-test-completed.txt')) 'tested update helper reaches restart handoff'
 $uninstaller=Join-Path $app 'unins000.exe'
 Assert-Desktop ((Invoke-DesktopFixtureProcess $uninstaller @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')) -eq 0) 'normal uninstall defaults to keeping data'
 Assert-Desktop (-not(Test-Path -LiteralPath (Join-Path $app 'MXH-VPS-Deploy.exe')) -and (Get-FileHash -LiteralPath (Join-Path $app 'private/instances/record.txt')).Hash -eq $privateHash -and (Get-FileHash -LiteralPath (Join-Path $app 'config/app-defaults.local.json')).Hash -eq $localHash) 'keep-data uninstall removes app and keeps archive/settings'
 Assert-Desktop ((Invoke-DesktopFixtureProcess $next.Installer $installArgs) -eq 0) 'reinstall supports retained local data'
 Assert-Desktop ((Get-FileHash -LiteralPath (Join-Path $app 'private/instances/record.txt')).Hash -eq $privateHash) 'reinstall does not replace retained archive'
 $outsideDirectory=Join-Path $fixture 'outside-data';[IO.Directory]::CreateDirectory($outsideDirectory)|Out-Null
 $outsideRecord=Join-Path $outsideDirectory 'record.txt';'fixture outside data'|Set-Content -LiteralPath $outsideRecord
 $outsideRecordHash=(Get-FileHash -LiteralPath $outsideRecord).Hash
 $junction=Join-Path $app 'private/linked-data'
 New-Item -ItemType Junction -Path $junction -Target $outsideDirectory|Out-Null
 try{
  Assert-Desktop ((Invoke-DesktopFixtureProcess (Join-Path $app 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/REMOVEDATA=1')) -ne 0) 'complete removal refuses a linked data directory'
  Assert-Desktop ((Test-Path -LiteralPath (Join-Path $app 'MXH-VPS-Deploy.exe')) -and (Get-FileHash -LiteralPath $outsideRecord).Hash -eq $outsideRecordHash) 'blocked linked uninstall preserves app and external data'
 }finally{if(Test-Path -LiteralPath $junction){[IO.Directory]::Delete($junction)}}
 Assert-Desktop ((Invoke-DesktopFixtureProcess (Join-Path $app 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/REMOVEDATA=1')) -eq 0) 'explicit delete-data uninstall succeeds'
 $watch=[Diagnostics.Stopwatch]::StartNew();while((Test-Path -LiteralPath $app) -and $watch.ElapsedMilliseconds -lt 15000){[Threading.Thread]::Sleep(50)}
 Assert-Desktop (-not(Test-Path -LiteralPath $app)) 'explicit complete removal deletes only isolated app directory'
 Assert-Desktop ((Get-FileHash -LiteralPath $outside).Hash -eq $outsideHash) 'external authority is unaffected by complete app removal'
 Write-Host "Windows installer lifecycle passed: $script:desktopPassed assertions"
}finally{
 $prefix=[IO.Path]::GetFullPath((Join-Path $ProjectRoot '.test-output')).TrimEnd('\')+'\'
 if(-not [IO.Path]::GetFullPath($fixture).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe installer fixture cleanup.'}
 if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
