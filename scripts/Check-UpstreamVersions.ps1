[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$versions = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config\versions.json') | ConvertFrom-Json
$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'mxh-vps-deploy-version-check' }
$xray = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
$komari = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/komari-monitor/komari-agent/releases/latest'

[pscustomobject]@{
    Component = 'Xray-core'
    Pinned = [string]$versions.xray.version
    Upstream = ([string]$xray.tag_name).TrimStart('v')
    Same = ([string]$versions.xray.version -eq ([string]$xray.tag_name).TrimStart('v'))
}
[pscustomobject]@{
    Component = 'Komari Agent'
    Pinned = [string]$versions.komari_agent.version
    Upstream = ([string]$komari.tag_name).TrimStart('v')
    Same = ([string]$versions.komari_agent.version -eq ([string]$komari.tag_name).TrimStart('v'))
}

Write-Host 'This command only reports versions. Review release notes, hashes, config tests and real handshakes before changing the manifest.' -ForegroundColor Yellow
