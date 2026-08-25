[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    $script:passed++
}

Write-Host '== PowerShell syntax ==' -ForegroundColor Cyan
$parseErrors = [Collections.Generic.List[object]]::new()
Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | Where-Object Extension -in @('.ps1', '.psm1') | ForEach-Object {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in $errors) {
        $parseErrors.Add([pscustomobject]@{ File = $_.FullName; Line = $parseError.Extent.StartLineNumber; Message = $parseError.Message })
    }
}
if ($parseErrors.Count -gt 0) { $parseErrors | Format-Table -AutoSize; throw 'PowerShell parse failed.' }
Assert-True $true 'PowerShell files parse'

Write-Host '== Manifest and module graph ==' -ForegroundColor Cyan
$manifest = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config\versions.json') | ConvertFrom-Json
Assert-True ($manifest.schema_version -eq 1) 'version manifest schema'
Assert-True ([string]$manifest.xray.version -match '^\d+\.\d+\.\d+$') 'Xray pinned version'
Assert-True ([string]$manifest.xray.installer_commit -match '^[0-9a-f]{40}$') 'Xray installer commit'
Assert-True ([string]$manifest.xray.installer_sha256 -match '^[0-9a-f]{64}$') 'Xray installer SHA-256'
Assert-True ([string]$manifest.komari_agent.assets.amd64.sha256 -match '^[0-9a-f]{64}$') 'Komari amd64 SHA-256'

Import-Module (Join-Path $ProjectRoot 'src\VpsDeploy.Core.psm1') -Force
$modules = @(Get-VpsModules -ProjectRoot $ProjectRoot)
Assert-True ($modules.Count -ge 10) 'module count'
Assert-True (($modules.Id | Sort-Object -Unique).Count -eq $modules.Count) 'module IDs unique'
Assert-True ($modules[0].Id -eq 'bootstrap-access') 'bootstrap first'
Assert-True ($modules[-1].Id -eq 'private-archive') 'archive last'
Assert-True ('ssh-cutover' -in $modules.Id) 'safe SSH cutover module exists'

Write-Host '== Client export fixture ==' -ForegroundColor Cyan
$fixtureRoot = Join-Path $ProjectRoot '.test-output\client-export'
if (Test-Path -LiteralPath $fixtureRoot) {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.test-output'))
    if (-not $resolved.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    [IO.Directory]::Delete($resolved, $true)
}
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$fixtureContext = [pscustomobject]@{
    ProjectRoot = $ProjectRoot
    ArchivePath = $fixtureRoot
    Plan = [ordered]@{
        NodeName = 'Example-US.Entry'
        Server = [ordered]@{ IPv4 = '192.0.2.10'; IPv6 = '2001:db8::10' }
        Ports = [ordered]@{ XrayPrimary = 443; XrayBackup = 32345 }
        Reality = [ordered]@{ Target = 'www.example.edu' }
    }
    Secrets = [ordered]@{
        AdminPassword = 'fixture-only-password'
        Xray = [ordered]@{
            Uuid = [guid]::Empty.ToString()
            RealityPrivateKey = 'fixture-private-key-not-used-by-client'
            RealityClientKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
            ShortId = '0123456789abcdef'
        }
    }
    State = [ordered]@{ Modules = @{} }
    SecretsPath = (Join-Path $fixtureRoot 'secrets.json')
    StatePath = (Join-Path $fixtureRoot 'state.json')
    LogPath = (Join-Path $fixtureRoot 'test.log')
    DryRun = $false
}
$clientModule = $modules | Where-Object Id -eq 'client-export'
& $clientModule.Invoke $fixtureContext
$singBoxFixture = Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'client-exports\sing-box-outbounds.private.json') | ConvertFrom-Json
Assert-True ($singBoxFixture.outbounds.Count -eq 2) 'sing-box IPv4 and IPv6 outbounds generated'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'client-exports\mihomo-test-primary.yaml')) -match 'xtls-rprx-vision') 'Mihomo Vision profile generated'
[IO.Directory]::Delete($fixtureRoot, $true)

Write-Host '== Random port generator ==' -ForegroundColor Cyan
$ports = 1..200 | ForEach-Object { Get-VpsRandomPort -Exclude @(22, 443) }
Assert-True (@($ports | Where-Object { $_ -lt 20000 -or $_ -gt 59999 }).Count -eq 0) 'ports stay in 20000-59999'
Assert-True (@($ports | Where-Object { $_ -in @(22, 443) }).Count -eq 0) 'excluded ports not returned'

Write-Host '== Bash syntax and line endings ==' -ForegroundColor Cyan
$bashCandidates = @(
    'D:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\bin\bash.exe',
    '/usr/bin/bash',
    '/bin/bash'
)
$bash = $bashCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$shellFiles = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'assets\remote') -Filter '*.sh' -File)
Assert-True ($shellFiles.Count -ge 10) 'remote shell module count'
foreach ($file in $shellFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Assert-True (-not $text.Contains("`r")) "$($file.Name) uses LF"
    Assert-True ($text -notmatch '(?m)^\s*set\s+-[^\n]*x') "$($file.Name) does not enable xtrace"
    if ($bash) {
        & $bash -n $file.FullName
        Assert-True ($LASTEXITCODE -eq 0) "$($file.Name) bash -n"
    }
}
if (-not $bash) { Write-Warning 'Bash not found; bash -n was skipped.' }

Write-Host '== Offline dry run ==' -ForegroundColor Cyan
$dryRunArchive = 'F:\MXH-VPS-DEPLOY-DRY-RUN-SHOULD-NOT-EXIST'
if (Test-Path -LiteralPath $dryRunArchive) { throw "Dry-run sentinel path already exists: $dryRunArchive" }
& (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1') -Mode Resume `
    -PlanPath (Join-Path $ProjectRoot 'tests\fixtures\dry-run-plan.json') -DryRun -NonInteractive
Assert-True (-not (Test-Path -LiteralPath $dryRunArchive)) 'dry run creates no instance data'

Write-Host '== Secret scan ==' -ForegroundColor Cyan
& (Join-Path $ProjectRoot 'scripts\Test-NoSecrets.ps1') -ProjectRoot $ProjectRoot
Assert-True $true 'secret scan'

Write-Host "All tests passed: $passed assertions" -ForegroundColor Green
