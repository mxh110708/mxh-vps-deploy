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
Assert-True ([string]$manifest.sing_box.version -match '^\d+\.\d+\.\d+$') 'sing-box pinned version'
Assert-True ([string]$manifest.sing_box.assets.amd64.sha256 -match '^[0-9a-f]{64}$') 'sing-box amd64 SHA-256'
Assert-True ([string]$manifest.sing_box.assets.windows_amd64.sha256 -match '^[0-9a-f]{64}$') 'sing-box Windows SHA-256'

# ValidateProject invokes this script from inside the already imported core
# module.  Forcing that same module to reload would tear down the caller's
# session state (including this script's Assert-True helper).  Direct test runs
# still import the module normally.
if (-not (Get-Command Get-VpsModules -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $ProjectRoot 'src\VpsDeploy.Core.psm1') -Force
}
$modules = @(Get-VpsModules -ProjectRoot $ProjectRoot)
Assert-True ($modules.Count -ge 10) 'module count'
Assert-True (($modules.Id | Sort-Object -Unique).Count -eq $modules.Count) 'module IDs unique'
Assert-True ($modules[0].Id -eq 'bootstrap-access') 'bootstrap first'
Assert-True ($modules[-1].Id -eq 'private-archive') 'archive last'
Assert-True ('ssh-cutover' -in $modules.Id) 'safe SSH cutover module exists'
Assert-True ('sing-box-shadowsocks' -in $modules.Id) 'Shadowsocks server module exists'
Assert-True ('landing-client-export' -in $modules.Id) 'Shadowsocks client export module exists'

Write-Host '== Bootstrap authentication arguments ==' -ForegroundColor Cyan
$sshArgumentContext = [pscustomobject]@{
    Plan = [ordered]@{
        Server = [ordered]@{ IPv4 = '192.0.2.10' }
        Paths = [ordered]@{ KeyDirectory = 'C:\fixture-key' }
    }
}
$providerKeyArgs = @(Get-VpsSshArguments -Context $sshArgumentContext -Port 22 -User root `
        -Interactive -IdentityFile 'C:\provider-existing-key')
Assert-True ('C:\provider-existing-key' -in $providerKeyArgs) 'existing provider key is passed to OpenSSH'
Assert-True ('IdentitiesOnly=yes' -in $providerKeyArgs) 'provider key uses IdentitiesOnly'
Assert-True ('PreferredAuthentications=publickey' -in $providerKeyArgs) 'provider key cannot silently fall back to password'
Assert-True ('BatchMode=yes' -notin $providerKeyArgs) 'interactive provider key permits passphrase prompt'
$passwordArgs = @(Get-VpsSshArguments -Context $sshArgumentContext -Port 22 -User root -Interactive)
Assert-True ('-i' -notin $passwordArgs) 'password bootstrap does not force an identity file'
Assert-True ('PubkeyAuthentication=no' -in $passwordArgs) 'password bootstrap does not accidentally reuse an agent key'

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
        Reality = [ordered]@{ Target = 'www.example.edu'; ForceIpv4Egress = $true }
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
Assert-True (@($singBoxFixture.outbounds).Count -eq 2) 'sing-box IPv4 and IPv6 outbounds generated'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $fixtureRoot 'client-exports\mihomo-test-primary.yaml')) -match 'xtls-rprx-vision') 'Mihomo Vision profile generated'
$serverConfig = New-MxhXrayServerConfig -Context $fixtureContext
$serverConfigRoundTrip = $serverConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json
Assert-True (@($serverConfigRoundTrip.routing.rules).Count -eq 1) 'Xray routing rules remain a JSON array with one rule'
Assert-True ($serverConfigRoundTrip.routing.rules[0].outboundTag -eq 'block') 'Xray IPv6 egress block rule preserved'
[IO.Directory]::Delete($fixtureRoot, $true)

Write-Host '== Shadowsocks landing fixture ==' -ForegroundColor Cyan
$landingFixtureRoot = Join-Path $ProjectRoot '.test-output\landing-export'
if (Test-Path -LiteralPath $landingFixtureRoot) { [IO.Directory]::Delete($landingFixtureRoot, $true) }
[IO.Directory]::CreateDirectory($landingFixtureRoot) | Out-Null
$serverKey = [Convert]::ToBase64String([byte[]](1..16))
$primaryUserKey = [Convert]::ToBase64String([byte[]](17..32))
$secondaryUserKey = [Convert]::ToBase64String([byte[]](33..48))
$landingContext = [pscustomobject]@{
    ProjectRoot = $ProjectRoot
    ArchivePath = $landingFixtureRoot
    Plan = [ordered]@{
        NodeName = 'Example-US.Landing'
        Server = [ordered]@{ IPv4 = '192.0.2.20'; IPv6 = '2001:db8::20' }
        Ports = [ordered]@{ LandingShadowsocks = 33456 }
        Shadowsocks = [ordered]@{
            Method = '2022-blake3-aes-128-gcm'
            ClientTransitTag = 'US-West Entry'
            SecondaryIpv6Enabled = $true
            SecondaryIpv6Address = '2001:db8::20'
            SecondaryBindInterface = 'eth0'
        }
    }
    Secrets = [ordered]@{
        AdminPassword = 'fixture-only-password'
        Shadowsocks = [ordered]@{
            ServerKey = $serverKey
            PrimaryUserKey = $primaryUserKey
            SecondaryUserKey = $secondaryUserKey
        }
    }
    State = [ordered]@{ Modules = @{} }
    SecretsPath = (Join-Path $landingFixtureRoot 'secrets.json')
    StatePath = (Join-Path $landingFixtureRoot 'state.json')
    LogPath = (Join-Path $landingFixtureRoot 'test.log')
    DryRun = $false
}
$serverConfig = New-MxhShadowsocksServerConfig -Context $landingContext
Assert-True (@($serverConfig.inbounds[0].users).Count -eq 2) 'SS2022 server has two users'
Assert-True (@($serverConfig.outbounds).Count -eq 2) 'landing server has IPv4 and IPv6 direct outbounds'
Assert-True ($serverConfig.outbounds[1].inet6_bind_address -eq '2001:db8::20') 'IPv6 outbound binds configured address'
Assert-True (@($serverConfig.route.rules).Count -eq 4) 'auth_user routing and opposite-family reject rules generated'
$landingExportModule = $modules | Where-Object Id -eq 'landing-client-export'
& $landingExportModule.Invoke $landingContext
$landingOutbounds = Get-Content -Raw -LiteralPath (Join-Path $landingFixtureRoot 'client-exports\sing-box-shadowsocks-outbounds.private.json') | ConvertFrom-Json
Assert-True (@($landingOutbounds.outbounds).Count -eq 2) 'two landing client outbounds generated'
Assert-True (($landingOutbounds.outbounds[0].password -split ':').Count -eq 2) 'client password combines server and user keys'
Assert-True ($landingOutbounds.outbounds[0].detour -eq 'US-West Entry') 'sing-box detour points to transit tag'
[IO.Directory]::Delete($landingFixtureRoot, $true)

Write-Host '== Conservative adaptive network planning ==' -ForegroundColor Cyan
$entrySmall = Get-VpsConservativeNetworkPlan -Role RealityEntry -MemoryKiB 1048576 `
    -Mode AdaptiveConservative -BandwidthMbps 1000 -ReferenceRttMs 160
Assert-True ($entrySmall.MemoryTier -eq 'small') '1 GiB entry uses small memory tier'
Assert-True ($entrySmall.BufferCapBytes -eq 8MB) '1 GiB entry buffer cap is 8 MiB'
Assert-True ($entrySmall.BufferTargetBytes -eq 8MB) 'high-BDP entry is capped by memory'
Assert-True ($entrySmall.QueueFloor -eq 1024) 'entry queue floor is conservative'
$entryTiny = Get-VpsConservativeNetworkPlan -Role RealityEntry -MemoryKiB 524288 `
    -Mode AdaptiveConservative -BandwidthMbps 100 -ReferenceRttMs 160
Assert-True ($entryTiny.BufferTargetBytes -eq 4000000) '100 Mbps 160 ms entry uses two BDP below tiny cap'
Assert-True ($entryTiny.BufferTargetBytes -le $entryTiny.BufferCapBytes) 'tiny entry never exceeds memory cap'
$landingSmall = Get-VpsConservativeNetworkPlan -Role ShadowsocksLanding -MemoryKiB 1048576 `
    -Mode AdaptiveConservative -BandwidthMbps 1000 -ReferenceRttMs 5
Assert-True ($landingSmall.BufferTargetBytes -eq 1250000) 'nearby landing uses entry-to-landing RTT BDP'
Assert-True ($landingSmall.QueueFloor -eq 2048) 'landing queue floor reflects fan-in role'
$monitor = Get-VpsConservativeNetworkPlan -Role MonitorOnly -MemoryKiB 1048576 -Mode BaselineOnly
Assert-True ($monitor.BufferTargetBytes -eq 0) 'monitor baseline does not tune buffers'
Assert-True ($monitor.QueueFloor -eq 0) 'monitor baseline does not pin proxy queues'
$invalidTuningRejected = $false
try {
    Get-VpsConservativeNetworkPlan -Role RealityEntry -MemoryKiB 1048576 `
        -Mode AdaptiveConservative -BandwidthMbps 0 -ReferenceRttMs 160 | Out-Null
}
catch { $invalidTuningRejected = $true }
Assert-True $invalidTuningRejected 'invalid adaptive bandwidth is rejected'

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
$remotePayload = New-VpsRemoteScriptPayload `
    -Context ([pscustomobject]@{ ProjectRoot = $ProjectRoot }) `
    -Asset 'audit.sh' -Parameters ([ordered]@{ SAMPLE = 'value' })
Assert-True (-not $remotePayload.Contains("`r")) 'generated remote payload uses LF on Windows'
Assert-True ($remotePayload -match '(?m)^set -euo pipefail$') 'generated remote payload includes strict bash preamble'
foreach ($file in $shellFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Assert-True (-not $text.Contains("`r")) "$($file.Name) uses LF"
    Assert-True ($text -notmatch '(?m)^\s*set\s+-[^\n]*x') "$($file.Name) does not enable xtrace"
    Assert-True ($text -notmatch 'nft\s+list\s+ruleset\s*\|\s*grep\s+-[^\s]*q') "$($file.Name) avoids pipefail plus grep-q SIGPIPE checks"
    if ($bash) {
        & $bash -n $file.FullName
        Assert-True ($LASTEXITCODE -eq 0) "$($file.Name) bash -n"
    }
}
if (-not $bash) { Write-Warning 'Bash not found; bash -n was skipped.' }

Write-Host '== Offline dry run ==' -ForegroundColor Cyan
$dryRunArchive = Join-Path $ProjectRoot 'DRY-RUN-SENTINEL-SHOULD-NOT-EXIST'
if (Test-Path -LiteralPath $dryRunArchive) { throw "Dry-run sentinel path already exists: $dryRunArchive" }
Push-Location $ProjectRoot
try {
    Start-VpsDeploy -ProjectRoot $ProjectRoot -Mode Resume `
        -PlanPath (Join-Path $ProjectRoot 'tests\fixtures\dry-run-plan.json') -DryRun -NonInteractive
}
finally {
    Pop-Location
}
Assert-True (-not (Test-Path -LiteralPath $dryRunArchive)) 'dry run creates no instance data'

$landingDryRunArchive = Join-Path $ProjectRoot 'DRY-RUN-LANDING-SENTINEL-SHOULD-NOT-EXIST'
if (Test-Path -LiteralPath $landingDryRunArchive) { throw "Dry-run sentinel path already exists: $landingDryRunArchive" }
Push-Location $ProjectRoot
try {
    Start-VpsDeploy -ProjectRoot $ProjectRoot -Mode Resume `
        -PlanPath (Join-Path $ProjectRoot 'tests\fixtures\dry-run-landing-plan.json') -DryRun -NonInteractive
}
finally {
    Pop-Location
}
Assert-True (-not (Test-Path -LiteralPath $landingDryRunArchive)) 'landing dry run creates no instance data'

Write-Host '== Secret scan ==' -ForegroundColor Cyan
& (Join-Path $ProjectRoot 'scripts\Test-NoSecrets.ps1') -ProjectRoot $ProjectRoot
Assert-True $true 'secret scan'

Write-Host "All tests passed: $passed assertions" -ForegroundColor Green
