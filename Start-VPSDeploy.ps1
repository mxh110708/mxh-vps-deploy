[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'New', 'Resume', 'Import', 'Migrate', 'Maintain', 'TuneNetwork', 'ClientConfig', 'ValidateProject')]
    [string]$Mode = 'Interactive',

    [string]$PlanPath,

    [string[]]$OnlyModule,

    [string]$InstanceRoot,

    [string]$ClashAuthorityPath,

    [string]$SingBoxAuthorityPath,

    [string]$ClientOutputRoot,

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
    -ClashAuthorityPath $ClashAuthorityPath `
    -SingBoxAuthorityPath $SingBoxAuthorityPath `
    -ClientOutputRoot $ClientOutputRoot `
    -DryRun:$DryRun `
    -NonInteractive:$NonInteractive
