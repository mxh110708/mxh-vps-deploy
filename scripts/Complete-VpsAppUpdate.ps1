#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$JobPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stage = $null; $started = $false
try {
    $job = Get-Content -Raw -LiteralPath $JobPath | ConvertFrom-Json -AsHashtable
    $root = [IO.Path]::GetFullPath([string]$job.ProjectRoot)
    $stage = [IO.Path]::GetFullPath([string]$job.Stage)
    $prefix = [IO.Path]::GetFullPath((Join-Path $root '.tmp')).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $stage.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $stage) -notmatch '^app-update-[0-9a-f]{32}$' -or
        [IO.Path]::GetFullPath($PSScriptRoot) -ne $stage -or
        [IO.Path]::GetFullPath($JobPath) -ne (Join-Path $stage 'update-job.private.json') -or
        [IO.Path]::GetFullPath([string]$job.Package) -ne (Join-Path $stage 'package')) { throw '更新暂存路径无效。' }
    foreach ($directory in @($root,(Join-Path $root '.tmp'),$stage)) {
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '更新目录不能包含联接。' }
    }
    $parent = Get-Process -Id ([int]$job.ParentPid) -ErrorAction SilentlyContinue
    if ($parent -and -not $parent.WaitForExit(120000)) { throw '应用尚未安全退出，未更新任何文件。' }
    Import-Module (Join-Path $stage 'VpsDeploy.Update.psm1') -Force
    if (Test-Path -LiteralPath (Join-Path $root '.git')) {
        Assert-VpsGitApplicationClean $root
        Get-VpsGitApplicationRelease $root $job.Tag $job.Proxy
        $started = $true
        Complete-VpsGitApplicationUpdate $root $job.Tag $job.Version
    } else {
        $started = $true
        Install-VpsPortableApplicationUpdate $root $job.Package (Join-Path $stage 'rollback')
    }
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-STA','-WindowStyle','Hidden','-File',(Join-Path $root 'Start-VPSDeploy.Gui.ps1'))) { $start.ArgumentList.Add($arg) }
    [void][Diagnostics.Process]::Start($start)
    # Successful update: remove only this validated, newly created staging tree.
    Remove-Item -LiteralPath $stage -Recurse -Force
} catch {
    $message = if ($started) { '更新未完成；私人数据保留。本次恢复材料保存在应用 .tmp 下，请处理后再更新。' } else { '更新未开始，当前应用文件保留。请重新打开应用后重试。' }
    if (-not $started -and $stage -and $PSScriptRoot -eq $stage -and (Split-Path -Leaf $stage) -match '^app-update-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show($message,'MXH VPS Deploy 更新','OK','Error')
    exit 1
}
