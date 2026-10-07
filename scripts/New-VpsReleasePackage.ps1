#requires -Version 7.4
[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot),[Parameter(Mandatory)][string]$Destination,[switch]$Development)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$Destination = [IO.Path]::GetFullPath($Destination)
Import-Module (Join-Path $ProjectRoot 'src/VpsDeploy.Update.psm1') -Force
$version = (Get-VpsApplicationVersion $ProjectRoot).ToString()
$application = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config/application.json') | ConvertFrom-Json -AsHashtable
if (-not $Development) {
    if ($application.channel -ne 'stable') { throw '正式包需要 stable 应用版本；开发包请明确使用 -Development。' }
    Assert-VpsGitApplicationClean $ProjectRoot
}
& (Join-Path $ProjectRoot 'scripts/Test-NoSecrets.ps1') -ProjectRoot $ProjectRoot
$paths = @(& git -c "safe.directory=$ProjectRoot" -c core.quotepath=false -C $ProjectRoot ls-files --cached --others --exclude-standard | Sort-Object -Unique)
if ($LASTEXITCODE -ne 0 -or -not $paths.Count) { throw '无法取得公开文件清单。' }
$stage = Join-Path $ProjectRoot ('.tmp/release-package-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
try {
    $files = foreach ($relative in $paths) {
        if ($relative -eq 'application-files.json') { continue }
        Assert-VpsApplicationFilePath $relative
        $source = Assert-VpsApplicationWritableScope $ProjectRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw '公开文件清单含缺失文件。' }
        $target = Join-Path $stage $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target
        @{ path=$relative; sha256=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() }
    }
    @{ schema_version=1; version=$version; files=@($files) } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $stage 'application-files.json') -Encoding utf8
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $suffix = if ($Development) { '-ui-preview' } else { '' }
    $name = "mxh-vps-deploy-v$version$suffix-windows-amd64.zip"
    $archive = Join-Path $Destination $name
    if (Test-Path -LiteralPath $archive) { throw '目标发布包已存在，未覆盖。' }
    $zip = [IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
            $relative = [IO.Path]::GetRelativePath($stage,$file.FullName).Replace('\','/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$relative,[IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    $verified = Join-Path $stage 'verification'
    [void](Expand-VpsVerifiedApplicationPackage $archive $verified)
    $checksumName = if ($Development) { 'SHA256SUMS-ui-preview.txt' } else { 'SHA256SUMS.txt' }
    ((Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() + '  ' + $name) |
        Set-Content -LiteralPath (Join-Path $Destination $checksumName) -Encoding ascii
    [pscustomobject]@{ Archive=$archive; Checksums=(Join-Path $Destination $checksumName); Version=$version; Development=[bool]$Development }
} finally {
    $prefix = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.tmp')).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($stage).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw '发布暂存清理范围异常。' }
    Remove-Item -LiteralPath $stage -Recurse -Force
}
