#requires -Version 7.4
[CmdletBinding()]
param(
 [string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot),
 [Parameter(Mandatory)][string]$Destination,
 [switch]$Development,
 [Parameter(DontShow)][switch]$TestBuild,
 [Parameter(DontShow)][string]$PackageVersion,
 [Parameter(DontShow)][switch]$KeepBundle,
 [string]$CacheDirectory,[string]$SourceDirectory,[string]$Proxy
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Windows 桌面包需在 Windows 上编译。'}
$ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot);$Destination=[IO.Path]::GetFullPath($Destination)
Import-Module (Join-Path $ProjectRoot 'src/VpsDeploy.Update.psm1') -Force
$version=(Get-VpsApplicationVersion $ProjectRoot).ToString()
$application=Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config/application.json')|ConvertFrom-Json -AsHashtable
if($PackageVersion){if(-not($TestBuild -and $Development) -or $PackageVersion -notmatch '^\d+\.\d+\.\d+$'){throw '版本覆盖仅用于隔离安装测试。'};$version=$PackageVersion}
if($TestBuild -and -not $Development){throw '隔离测试包不能正式发行。'}
if(-not $Development){if($application.channel -ne 'stable'){throw '正式包需要 stable 应用版本。'};Assert-VpsGitApplicationClean $ProjectRoot}
& (Join-Path $ProjectRoot 'scripts/Test-NoSecrets.ps1') -ProjectRoot $ProjectRoot
$dependencies=& (Join-Path $ProjectRoot 'scripts/Initialize-DesktopBuild.ps1') -ProjectRoot $ProjectRoot -CacheDirectory $CacheDirectory -SourceDirectory $SourceDirectory -Proxy $Proxy
$paths=@(& git -c "safe.directory=$ProjectRoot" -c core.quotepath=false -C $ProjectRoot ls-files --cached --others --exclude-standard|Sort-Object -Unique)
if($LASTEXITCODE -ne 0 -or -not $paths.Count){throw '无法取得公开文件清单。'}
$buildRoot=Join-Path $ProjectRoot ('.tmp/desktop-package-'+[guid]::NewGuid().ToString('N'))
$bundle=Join-Path $buildRoot 'application';$installerSource=Join-Path $buildRoot 'installer'
[IO.Directory]::CreateDirectory($bundle)|Out-Null
try{
 foreach($relative in $paths){
  Assert-VpsApplicationFilePath $relative
  $source=Assert-VpsApplicationWritableScope $ProjectRoot $relative
  if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw '公开清单含缺失文件。'}
  $target=Join-Path $bundle $relative;[IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null
  Copy-Item -LiteralPath $source -Destination $target
 }
 if($PackageVersion){$application.version=$version;$application.channel='stable';$application|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $bundle 'config/application.json') -Encoding utf8}
 $runtime=Join-Path $bundle 'runtime';[IO.Directory]::CreateDirectory($runtime)|Out-Null
 foreach($name in @('powershell','python')){[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $dependencies.CacheDirectory $dependencies.Assets[$name].file),(Join-Path $runtime $name))}
 $python=Join-Path $runtime 'python'
 $site=Join-Path $python 'Lib/site-packages';[IO.Directory]::CreateDirectory($site)|Out-Null
 [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $dependencies.CacheDirectory $dependencies.Assets.yaml.file),$site)
 "python313.zip`n.`nLib/site-packages`n../../scripts`nimport site`n"|Set-Content -LiteralPath (Join-Path $python 'python313._pth') -Encoding ascii
 $sshSource=Join-Path $buildRoot 'ssh-source'
 [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $dependencies.CacheDirectory $dependencies.Assets.openssh.file),$sshSource)
 $ssh=Join-Path $runtime 'openssh';[IO.Directory]::CreateDirectory($ssh)|Out-Null
 foreach($file in Get-ChildItem -LiteralPath $sshSource -File -Recurse){
  if($file.Extension -eq '.dll' -or $file.Name -in @('ssh.exe','scp.exe','sftp.exe','ssh-keygen.exe','ssh-add.exe','ssh-agent.exe','ssh-pkcs11-helper.exe','ssh-sk-helper.exe') -or $file.Name -match '^(LICENSE|LICENCE|NOTICE|THIRD.*PARTY)'){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $ssh $file.Name)}
 }
 foreach($file in @('ssh.exe','scp.exe','ssh-keygen.exe')){if(-not(Test-Path -LiteralPath (Join-Path $ssh $file))){throw 'OpenSSH 客户端资产不完整。'}}
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
 if(-not(Test-Path -LiteralPath $compiler)){throw '缺少 Windows .NET Framework 编译器。'}
 $assembly=Join-Path $buildRoot 'AssemblyVersion.cs'
 ('[assembly:System.Reflection.AssemblyVersion("'+$version+'.0")][assembly:System.Reflection.AssemblyFileVersion("'+$version+'.0")]')|Set-Content -LiteralPath $assembly -Encoding utf8
 $helpers=Join-Path $bundle 'app-helpers';[IO.Directory]::CreateDirectory($helpers)|Out-Null
 $compile=@('/nologo','/target:winexe','/platform:x64','/optimize+','/r:System.Web.Extensions.dll','/r:System.Windows.Forms.dll','/r:System.Core.dll',('/win32manifest:'+(Join-Path $ProjectRoot 'src/desktop/app.manifest')))
 if($TestBuild){$compile+='/define:DESKTOP_TEST'}
 $targets=@(
  @{Name='MXH-VPS-Deploy.exe';Main='Mxh.VpsDeploy.Desktop.DesktopApp';Sources=@('src/desktop/DesktopApp.cs');Icon=$true},
  @{Name='app-helpers/SetupGuard.exe';Main='Mxh.VpsDeploy.Desktop.SetupGuard';Sources=@('src/desktop/SetupGuard.cs','src/desktop/DesktopFiles.cs')},
  @{Name='app-helpers/InstalledUpdate.exe';Main='Mxh.VpsDeploy.Desktop.InstalledUpdate';Sources=@('src/desktop/InstalledUpdate.cs','src/desktop/DesktopFiles.cs')},
  @{Name='app-helpers/CleanupUpdate.exe';Main='Mxh.VpsDeploy.Desktop.CleanupUpdate';Sources=@('src/desktop/CleanupUpdate.cs','src/desktop/DesktopFiles.cs')}
 )
 foreach($target in $targets){
  $compileArgs=$compile+@("/main:$($target.Main)","/out:$(Join-Path $bundle $target.Name)",$assembly)
  if($target.ContainsKey('Icon')){$compileArgs+='/win32icon:'+(Join-Path $ProjectRoot 'assets/gui/app.ico')}
  $compileArgs+=@($target.Sources|ForEach-Object{Join-Path $ProjectRoot $_})
  $compilerMessages=@(& $compiler @compileArgs)
  if($LASTEXITCODE -ne 0){$compilerMessages|Write-Host;throw ('桌面原生 EXE 编译失败：'+$target.Name)}
 }
 $compilerMessages=@(& $compiler '/nologo' '/target:exe' '/platform:x64' '/optimize+' ('/out:'+(Join-Path $helpers 'AskPass.exe')) (Join-Path $ProjectRoot 'src/gui/VpsDeploy.AskPass.cs'))
 if($LASTEXITCODE -ne 0){$compilerMessages|Write-Host;throw '图形 SSH 辅助程序编译失败。'}
 $critical=@('runtime/powershell/pwsh.exe','runtime/powershell/System.Management.Automation.dll','runtime/python/python.exe','runtime/openssh/ssh.exe','runtime/openssh/scp.exe','runtime/openssh/ssh-keygen.exe','app-helpers/AskPass.exe','app-helpers/InstalledUpdate.exe','app-helpers/SetupGuard.exe','app-helpers/CleanupUpdate.exe','Start-VPSDeploy.Gui.ps1')
 @{schema_version=1;files=@($critical|ForEach-Object{@{path=$_;sha256=(Get-FileHash -LiteralPath (Join-Path $bundle $_)).Hash.ToLowerInvariant()}});versions=@{powershell=$dependencies.Assets.powershell.version;python=$dependencies.Assets.python.version;yaml=$dependencies.Assets.yaml.version;openssh=$dependencies.Assets.openssh.version}}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $bundle 'desktop-runtime.json') -Encoding utf8
 $proof=Join-Path $bundle 'runtime-proof.json'
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $bundle 'MXH-VPS-Deploy.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.ArgumentList.Add('--verify-runtime');$start.ArgumentList.Add($proof)
 $native=[Diagnostics.Process]::Start($start)
 try{if(-not $native.WaitForExit(120000)){$native.Kill($true);throw '原生 EXE 运行环境复核超时。'};if($native.ExitCode -ne 0){throw '原生 EXE 内置环境或 WPF 加载失败。'}}finally{$native.Dispose()}
 $verification=Get-Content -Raw -LiteralPath $proof|ConvertFrom-Json -AsHashtable
 if(-not $verification.wpf_loaded -or -not $verification.runtime_paths_local){throw '桌面内置环境未实际生效。'}
 Remove-Item -LiteralPath $proof
 $testOutput=Join-Path $bundle '.test-output'
 if(Test-Path -LiteralPath $testOutput){Remove-Item -LiteralPath $testOutput -Recurse -Force}
 $files=@(Get-ChildItem -LiteralPath $bundle -File -Recurse|ForEach-Object{$relative=[IO.Path]::GetRelativePath($bundle,$_.FullName).Replace('\','/');Assert-VpsApplicationFilePath $relative;@{path=$relative;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}}|Sort-Object path)
 @{schema_version=1;version=$version;files=$files}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $bundle 'application-files.json') -Encoding utf8
 [IO.Directory]::CreateDirectory($Destination)|Out-Null
 $suffix=if($Development){'-ui-preview'}else{''};$stem="mxh-vps-deploy-v$version$suffix-windows-amd64"
 $archive=Join-Path $Destination ($stem+'.zip');$setup=Join-Path $Destination ($stem+'-setup.exe');$publicManifest=Join-Path $Destination ($stem+'.files.json')
 foreach($path in @($archive,$setup,$publicManifest)){if(Test-Path -LiteralPath $path){throw '目标发布附件已存在，未覆盖。'}}
 [IO.Directory]::CreateDirectory($installerSource)|Out-Null
 Copy-Item -LiteralPath (Join-Path $ProjectRoot 'assets/installer/Desktop.iss') -Destination $installerSource
 Copy-Item -LiteralPath (Join-Path $ProjectRoot 'assets/installer/ChineseSimplified.isl') -Destination $installerSource
 $entries=@(foreach($file in $files){$relative=$file.path.Replace('/','\');$directory=[IO.Path]::GetDirectoryName($relative);'Source: "{#BundleRoot}\'+$relative+'"; DestDir: "{app}'+$(if($directory){'\'+$directory}else{''})+'"; Flags: ignoreversion'})
 $entries|Set-Content -LiteralPath (Join-Path $installerSource 'files.iss') -Encoding utf8
 $arguments=@('/Qp',('/DBundleRoot='+$bundle),('/DAppVersion='+$version),('/DOutputPath='+$Destination),('/DOutputName='+$stem+'-setup'),('/DIsTestBuild='+[int][bool]$TestBuild),(Join-Path $installerSource 'Desktop.iss'))
 $installerMessages=@(& $dependencies.Compiler @arguments)
 if($LASTEXITCODE -ne 0){$installerMessages|Write-Host;throw 'Windows 安装包编译失败。'}
 [IO.Compression.ZipFile]::CreateFromDirectory($bundle,$archive,[IO.Compression.CompressionLevel]::Optimal,$false)
 Copy-Item -LiteralPath (Join-Path $bundle 'application-files.json') -Destination $publicManifest
 $checksumName=if($Development){'SHA256SUMS-ui-preview.txt'}else{'SHA256SUMS.txt'}
 @($archive,$setup,$publicManifest)|ForEach-Object{(Get-FileHash -LiteralPath $_).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($_)}|Set-Content -LiteralPath (Join-Path $Destination $checksumName) -Encoding ascii
 [pscustomobject]@{Archive=$archive;Installer=$setup;FileManifest=$publicManifest;Checksums=(Join-Path $Destination $checksumName);Version=$version;ManagedFiles=$files.Count;RuntimeVerification=$verification;Bundle=$(if($KeepBundle){$bundle}else{''});TestBuild=[bool]$TestBuild;Development=[bool]$Development}
}finally{
 $prefix=[IO.Path]::GetFullPath((Join-Path $ProjectRoot '.tmp')).TrimEnd('\')+'\'
 if(-not [IO.Path]::GetFullPath($buildRoot).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw '构建暂存清理范围异常。'}
 if(-not $KeepBundle -and (Test-Path -LiteralPath $buildRoot)){Remove-Item -LiteralPath $buildRoot -Recurse -Force}
}
