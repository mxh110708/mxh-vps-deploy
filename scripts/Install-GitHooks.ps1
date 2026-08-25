[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

git -C $ProjectRoot config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw '无法配置 Git hooksPath。' }
Write-Host 'Git pre-commit hook enabled.' -ForegroundColor Green
