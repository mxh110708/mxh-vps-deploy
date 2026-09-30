[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MxhRouteBundlePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$vendorRoot = Join-Path $ProjectRoot 'vendor/test-cores/windows-amd64'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $vendorRoot 'checksums.json') | ConvertFrom-Json
$versions = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config/versions.json') | ConvertFrom-Json
$work = Join-Path $ProjectRoot ('.tmp/client-assets-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null

function Test-AssetHash([string]$Path, [string]$Hash) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Hash
}

foreach ($asset in $manifest.artifacts) {
    if ($asset.file -notmatch '^[a-zA-Z0-9.-]+\.zip$' -or $asset.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $asset.source -notmatch '^https://github\.com/(MetaCubeX/mihomo|SagerNet/sing-box)/releases/download/') {
        throw 'Unsupported client asset path, source or hash.'
    }
    $destination = Join-Path $vendorRoot $asset.file
    if (Test-AssetHash $destination $asset.sha256) { continue }
    if (Test-Path -LiteralPath $destination) { throw 'Existing client asset differs from the pinned hash; refusing to overwrite.' }
    $download = Join-Path $work $asset.file
    Invoke-WebRequest -Uri $asset.source -OutFile $download -TimeoutSec 180
    if (-not (Test-AssetHash $download $asset.sha256)) { throw 'Downloaded client asset hash mismatch.' }
    Move-Item -LiteralPath $download -Destination $destination
    Write-Host "Verified client asset: $($asset.file)"
}

$bundle = $versions.client_compatibility.mxh_route.public_rules_bundle
if (-not $MxhRouteBundlePath) {
    $MxhRouteBundlePath = Join-Path $work 'public-rules-v1.json'
    Invoke-WebRequest -Uri $bundle.source -OutFile $MxhRouteBundlePath -TimeoutSec 60
}
if (-not (Test-AssetHash $MxhRouteBundlePath $bundle.sha256)) { throw 'MXH Route public-rule bundle hash mismatch.' }
$rules = Get-Content -Raw -LiteralPath $MxhRouteBundlePath | ConvertFrom-Json
$entries = @($manifest.data_files | Where-Object consumer -eq 'sing-box')
if ($rules.version -ne 1 -or $rules.files.Count -ne 5 -or $entries.Count -ne 5) { throw 'Invalid public-rule bundle or manifest.' }
foreach ($entry in $entries) {
    if ($entry.tag -notmatch '^geo(site|ip)-[a-z-]+$' -or $entry.file -ne "mxh-route-public-rules/$($entry.tag).srs") {
        throw 'Unsupported public-rule filename.'
    }
    $found = @($rules.files | Where-Object name -eq $entry.tag)
    if ($found.Count -ne 1 -or $found[0].sha256 -ne $entry.sha256) { throw 'Public-rule bundle differs from the pinned manifest.' }
    $bytes = [Convert]::FromBase64String($found[0].data)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($hash -ne $entry.sha256 -or $bytes.Length -lt 4 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 3) -ne 'SRS') {
        throw 'Invalid public-rule data.'
    }
    $destination = Join-Path $vendorRoot $entry.file
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-AssetHash $destination $entry.sha256)) { throw 'Existing rule file differs from the pinned manifest.' }
    } else { [IO.File]::WriteAllBytes($destination, $bytes) }
    Write-Host "Verified public rule: $($entry.tag)"
}
