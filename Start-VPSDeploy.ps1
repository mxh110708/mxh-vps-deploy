[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'New', 'Resume', 'Import', 'Migrate', 'TuneNetwork', 'ValidateProject')]
    [string]$Mode = 'Interactive',

    [string]$PlanPath,

    [string[]]$OnlyModule,

    [string]$InstanceRoot = 'F:\VPS\VPS-Instances',

    [switch]$DryRun,

    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $projectRoot 'src\VpsDeploy.Core.psm1'
Import-Module $modulePath -Force

Start-VpsDeploy `
    -ProjectRoot $projectRoot `
    -Mode $Mode `
    -PlanPath $PlanPath `
    -OnlyModule $OnlyModule `
    -InstanceRoot $InstanceRoot `
    -DryRun:$DryRun `
    -NonInteractive:$NonInteractive
