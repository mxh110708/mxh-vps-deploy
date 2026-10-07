#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$output=[IO.Path]::GetFullPath($OutputPath)
if(-not $output.StartsWith(([IO.Path]::GetFullPath($project).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw '运行环境检查输出范围无效。'}
Import-Module (Join-Path $project 'src/VpsDeploy.Core.psm1') -Force
$python=Get-VpsCommandPath 'python.exe'
$ssh=Get-VpsCommandPath 'ssh.exe'
$py=Invoke-VpsProcess $python @('-c','import sys, ruamel.yaml; import build_client_authority; print(sys.version.split()[0]); print(ruamel.yaml.__version__)') -TimeoutSeconds 30
if($py.ExitCode -ne 0){throw '内置 Python 或客户端模块检查失败。'}
$ss=Invoke-VpsProcess $ssh @('-V') -TimeoutSeconds 30
if($ss.ExitCode -ne 0){throw '内置 OpenSSH 检查失败。'}
$guiRoot=Join-Path $project '.test-output/desktop-runtime-gui'
try{
 & (Join-Path $project 'Start-VPSDeploy.Gui.ps1') -NoShow -InstanceRoot $guiRoot
 @{schema_version=1;powershell=$PSVersionTable.PSVersion.ToString();python=$py.StdOut.Trim();ssh=$ss.StdErr.Trim();wpf_loaded=$true;runtime_paths_local=($python.StartsWith($project) -and $ssh.StartsWith($project))}|ConvertTo-Json|Set-Content -LiteralPath $output -Encoding utf8
}finally{
 if(Test-Path -LiteralPath $guiRoot){Remove-Item -LiteralPath $guiRoot -Recurse -Force}
}
