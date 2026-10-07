#requires -Version 7.4
[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot),[string]$CacheDirectory,[string]$SourceDirectory,[string]$Proxy,[ValidateSet('powershell','python','yaml','openssh','inno_setup')][string[]]$Names=@('powershell','python','yaml','openssh','inno_setup'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
if(-not $CacheDirectory){$CacheDirectory=Join-Path $ProjectRoot '.cache/desktop-build'}
$CacheDirectory=[IO.Path]::GetFullPath($CacheDirectory)
if((Test-Path -LiteralPath $CacheDirectory) -and ((Get-Item -LiteralPath $CacheDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '桌面构建缓存不能是联接。'}
[IO.Directory]::CreateDirectory($CacheDirectory)|Out-Null
$assets=Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config/desktop-assets.json')|ConvertFrom-Json -AsHashtable
foreach($name in $Names){
 $asset=$assets[$name]
 $path=Join-Path $CacheDirectory $asset.file
 if(-not(Test-Path -LiteralPath $path)){
  $source=if($SourceDirectory){Join-Path $SourceDirectory $asset.file}else{$null}
  if($source -and (Test-Path -LiteralPath $source)){
   if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -ne $asset.sha256){throw '桌面运行环境来源哈希不符。'}
   Copy-Item -LiteralPath $source -Destination $path
  }else{
   $temporary=$path+'.download-'+[guid]::NewGuid().ToString('N')
   try{
    $request=@{Uri=$asset.url;OutFile=$temporary;TimeoutSec=240};if($Proxy){$request.Proxy=$Proxy}
    Invoke-WebRequest @request
    if((Get-FileHash -LiteralPath $temporary).Hash.ToLowerInvariant() -ne $asset.sha256){throw '桌面运行环境下载哈希不符。'}
    [IO.File]::Move($temporary,$path)
   }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
  }
 }
 if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $asset.sha256){throw '已有桌面构建资产哈希不符，未覆盖缓存。'}
}
$compilerRoot=Join-Path $CacheDirectory ('inno-'+$assets.inno_setup.version)
$compiler=Join-Path $compilerRoot 'ISCC.exe'
if(-not(Test-Path -LiteralPath $compiler)){
 if(Test-Path -LiteralPath $compilerRoot){throw '已有 Inno 编译器目录不完整，未覆盖。'}
 $installer=Join-Path $CacheDirectory $assets.inno_setup.file
 # Official portable mode creates no uninstaller, associations or Add/Remove entry.
 $start=[Diagnostics.ProcessStartInfo]::new($installer)
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true
 foreach($arg in @('/PORTABLE=1','/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS','/TASKS=',('/DIR='+$compilerRoot))){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start)
 try{if(-not $process.WaitForExit(120000)){$process.Kill($true);throw '便携 Inno 编译器展开超时。'};if($process.ExitCode -ne 0){throw '便携 Inno 编译器展开失败。'}}finally{$process.Dispose()}
}
if((Get-Item -LiteralPath $compilerRoot).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Inno 编译器目录不能是联接。'}
if(-not(Test-Path -LiteralPath $compiler)){throw '缺少 Inno 编译器。'}
[pscustomobject]@{CacheDirectory=$CacheDirectory;Compiler=$compiler;Assets=$assets}
