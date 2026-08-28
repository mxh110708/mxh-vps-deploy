[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$versions = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config\versions.json') | ConvertFrom-Json
$settings = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config\app-defaults.json') | ConvertFrom-Json
$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'mxh-vps-deploy-version-check' }
$xray = Invoke-RestMethod -Headers $headers -Uri $settings.release_apis.xray
$komariController = Invoke-RestMethod -Headers $headers -Uri $settings.release_apis.komari_controller
$komariAgent = Invoke-RestMethod -Headers $headers -Uri $settings.release_apis.komari_agent
$singBox = Invoke-RestMethod -Headers $headers -Uri $settings.release_apis.sing_box
foreach($release in @($xray,$komariController,$komariAgent,$singBox)){if($release.draft -or $release.prerelease){throw "latest API 返回了非正式版本：$($release.tag_name)"}}

[pscustomobject]@{
    Component = 'Xray-core'
    Pinned = [string]$versions.xray.version
    Upstream = ([string]$xray.tag_name).TrimStart('v')
    Same = ([string]$versions.xray.version -eq ([string]$xray.tag_name).TrimStart('v'))
}
[pscustomobject]@{
    Component = 'Komari Agent'
    Pinned = [string]$versions.komari_agent.version
    Upstream = ([string]$komariAgent.tag_name).TrimStart('v')
    Same = ([string]$versions.komari_agent.version -eq ([string]$komariAgent.tag_name).TrimStart('v'))
}
[pscustomobject]@{
    Component = 'Komari Controller'
    Pinned = [string]$versions.komari_controller.version
    Upstream = ([string]$komariController.tag_name).TrimStart('v')
    Same = ([string]$versions.komari_controller.version -eq ([string]$komariController.tag_name).TrimStart('v'))
}
[pscustomobject]@{
    Component = 'sing-box'
    Pinned = [string]$versions.sing_box.version
    Upstream = ([string]$singBox.tag_name).TrimStart('v')
    Same = ([string]$versions.sing_box.version -eq ([string]$singBox.tag_name).TrimStart('v'))
}

Write-Host 'This command only reports versions. Review release notes, hashes, config tests and real handshakes before changing the manifest.' -ForegroundColor Yellow
