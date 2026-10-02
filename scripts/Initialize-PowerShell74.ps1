[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Destination,
    [string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\tests\fixtures\powershell74-runtime.json') | ConvertFrom-Json
$resolvedDestination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $resolvedDestination) { throw 'Use a new destination for the isolated PowerShell runtime.' }
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = $resolvedDestination + '.zip'
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        $parent = Split-Path -Parent $ArchivePath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Invoke-WebRequest -Uri $manifest.url -OutFile $ArchivePath -TimeoutSec 180
    }
}
$actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $manifest.sha256) { throw 'PowerShell 7.4 archive checksum mismatch; extraction refused.' }
Expand-Archive -LiteralPath $ArchivePath -DestinationPath $resolvedDestination
$runtime = Join-Path $resolvedDestination 'pwsh.exe'
$actualVersion = & $runtime -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $manifest.version) { throw 'Isolated PowerShell runtime version mismatch.' }
Write-Output $resolvedDestination
