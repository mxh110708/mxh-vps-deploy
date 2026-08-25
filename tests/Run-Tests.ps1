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
Assert-True ('certbot-dns' -in $modules.Id) 'Certbot DNS-01 module exists'
Assert-True ('local-https-target' -in $modules.Id) 'local Reality HTTPS target module exists'
Assert-True ('sing-box-anytls' -in $modules.Id) 'AnyTLS trusted TLS server module exists'
Assert-True ('anytls-client-export' -in $modules.Id) 'AnyTLS client export module exists'
$shadowsocksSelfTest = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\shadowsocks-self-test.sh')
Assert-True ($shadowsocksSelfTest -match 'VPSDEPLOY_UDP_B64') 'Shadowsocks self-test reports functional UDP result'
Assert-True ($shadowsocksSelfTest -match '"type": "direct"') 'Shadowsocks self-test creates a UDP tunnel inbound'
Assert-True ($shadowsocksSelfTest -match 'override_address') 'Shadowsocks UDP self-test uses an explicit DNS destination'
$externalProbe = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\shadowsocks-external-probe.sh')
Assert-True ($externalProbe -match 'sha256sum --check --status') 'external Shadowsocks probe verifies pinned core checksum'
Assert-True ($externalProbe -match 'VPS_PARAM_SELF_TEST_SCRIPT') 'external probe reuses the canonical TCP/UDP self-test'
$singBoxInstaller = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\sing-box-install.sh')
Assert-True ($singBoxInstaller -match 'RestrictAddressFamilies=[^\r\n]*AF_NETLINK') 'sing-box systemd sandbox permits route-update netlink'
$anyTlsInstaller = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\sing-box-anytls-install.sh')
Assert-True ($anyTlsInstaller -match 'Conflicts=xray\.service') 'AnyTLS and Xray services are mutually exclusive'
Assert-True ($anyTlsInstaller -match 'RestrictAddressFamilies=[^\r\n]*AF_NETLINK') 'AnyTLS sandbox permits route-update netlink'
Assert-True ($anyTlsInstaller -match 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE') 'AnyTLS receives only the privileged-port bind capability'
Assert-True ($anyTlsInstaller -notmatch '(?m)^User=root$') 'AnyTLS never runs as root'
$certbotSetup = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\certbot-dns-setup.sh')
Assert-True ($certbotSetup -match 'dns-cloudflare') 'Certbot uses Cloudflare DNS-01 plugin'
Assert-True ($certbotSetup -match 'mxh-certbot-renew\.timer') 'Certbot renewal timer is installed'
Assert-True ($certbotSetup -match 'disable --now certbot\.timer') 'distribution Certbot timer is disabled to avoid duplicate renewal owners'
Assert-True ($certbotSetup -notmatch 'echo\s+.*CLOUDFLARE_TOKEN') 'Certbot setup never prints the Cloudflare token'
$anyTlsApply = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\anytls-apply-config.sh')
Assert-True ($anyTlsApply -match "rollback_needed='yes'") 'AnyTLS cutover arms automatic rollback'
Assert-True ($anyTlsApply -match 'systemctl start xray\.service') 'AnyTLS cutover restores an originally active Xray service on failure'
$localHttpsSetup = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\local-https-target.sh')
Assert-True ($localHttpsSetup -match 'mask nginx\.service') 'nginx is masked while the package default site could start'
Assert-True ($localHttpsSetup -match 'unmask nginx\.service') 'nginx is unmasked only after package installation checks'

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
$localRealityPlan = [ordered]@{
    Reality = [ordered]@{
        Target = 'portal.example.invalid'
        TargetMode = 'LocalOwnedTls'
        ServerName = 'portal.example.invalid'
        TargetAddress = '127.0.0.1:8443'
    }
}
$localRealityTarget = Get-MxhRealityTargetSettings -Plan $localRealityPlan
Assert-True ($localRealityTarget.Mode -eq 'LocalOwnedTls') 'local Reality target mode is preserved'
Assert-True ($localRealityTarget.TargetAddress -eq '127.0.0.1:8443') 'local Reality target never loops to public 443'
Assert-True ($localRealityTarget.ServerName -eq 'portal.example.invalid') 'local Reality SNI uses owned domain'
$replacementRealityPlan = [ordered]@{
    Reality = [ordered]@{
        Target = 'old.example.invalid'
        TargetMode = 'ExternalAudited'
        ServerName = 'old.example.invalid'
        TargetAddress = 'old.example.invalid:443'
    }
}
Set-MxhRealityExternalTarget -Plan $replacementRealityPlan -Target 'new.example.invalid'
$replacementRealityTarget = Get-MxhRealityTargetSettings -Plan $replacementRealityPlan
Assert-True ($replacementRealityTarget.ServerName -eq 'new.example.invalid') 'replacement Reality target updates client server name'
Assert-True ($replacementRealityTarget.TargetAddress -eq 'new.example.invalid:443') 'replacement Reality target updates server destination'
$legacyRealityPlan = [ordered]@{ Reality = [ordered]@{ Target = 'legacy.example.invalid' } }
Set-MxhRealityExternalTarget -Plan $legacyRealityPlan -Target 'legacy-new.example.invalid'
$legacyRealityTarget = Get-MxhRealityTargetSettings -Plan $legacyRealityPlan
Assert-True ($legacyRealityTarget.ServerName -eq 'legacy-new.example.invalid') 'legacy Reality replacement keeps client compatibility'
Assert-True ($legacyRealityTarget.TargetAddress -eq 'legacy-new.example.invalid:443') 'legacy Reality replacement keeps server compatibility'
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

Write-Host '== AnyTLS trusted TLS and ECH fixture ==' -ForegroundColor Cyan
$generatedPadding = @(New-MxhAnyTlsPaddingScheme)
Assert-True ($generatedPadding.Count -eq 9) 'per-instance AnyTLS padding has stop plus packet 0-7 rules'
Assert-True ($generatedPadding[0] -eq 'stop=8') 'conservative AnyTLS padding stops after the initial packet window'
Assert-True (@($generatedPadding | Where-Object { $_ -notmatch '^(?:stop=8|[0-7]=[0-9,c-]+)$' }).Count -eq 0) 'generated AnyTLS padding uses valid restricted syntax'
$paddingNumbers = @([regex]::Matches(($generatedPadding -join ','), '\d+') | ForEach-Object { [int]$_.Value })
Assert-True (($paddingNumbers | Measure-Object -Maximum).Maximum -le 1100) 'generated AnyTLS padding stays below conservative plaintext maximum'
$legacyPadding = @(Get-MxhAnyTlsPaddingScheme -Plan ([ordered]@{ AnyTls = [ordered]@{} }))
Assert-True ($legacyPadding[2] -eq '1=100-400') 'legacy AnyTLS plans fall back to the official padding scheme'
$fakeEchConfig = "-----BEGIN ECH CONFIGS-----`nQUJDRA==`n-----END ECH CONFIGS-----`n"
$fakeEchKeys = "-----BEGIN ECH KEYS-----`nRUZHSA==`n-----END ECH KEYS-----`n"
$parsedEch = ConvertFrom-MxhEchKeyPairText -Text ($fakeEchConfig + $fakeEchKeys)
Assert-True ($parsedEch.ClientConfigBase64 -eq 'QUJDRA==') 'ECH client base64 is extracted without headers'
$anyTlsContext = [pscustomobject]@{
    Plan = [ordered]@{
        NodeName = 'Example-US.AnyTLS'
        Server = [ordered]@{ IPv4 = '192.0.2.40'; IPv6 = '2001:db8::40' }
        Ports = [ordered]@{ AnyTlsPrimary = 443 }
        AnyTls = [ordered]@{
            ServerName = 'edge.example.invalid'
            EchPublicName = 'www.example.invalid'
            ForceIpv4Egress = $true
            PaddingSchemeMode = 'PerInstanceConservativeV1'
            PaddingScheme = $generatedPadding
        }
    }
    Secrets = [ordered]@{
        AnyTls = [ordered]@{
            Password = [Convert]::ToBase64String([byte[]](49..80))
            EchServerKeyPem = $fakeEchKeys
            EchClientConfigPem = $fakeEchConfig
            EchClientConfigBase64 = $parsedEch.ClientConfigBase64
        }
    }
}
$anyTlsServerConfig = New-MxhAnyTlsServerConfig -Context $anyTlsContext
$anyTlsRoundTrip = $anyTlsServerConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json
Assert-True ($anyTlsRoundTrip.inbounds[0].type -eq 'anytls') 'AnyTLS server inbound generated'
Assert-True ($anyTlsRoundTrip.inbounds[0].tls.min_version -eq '1.3') 'AnyTLS requires TLS 1.3'
Assert-True ($anyTlsRoundTrip.inbounds[0].tls.ech.enabled) 'AnyTLS server ECH enabled'
Assert-True ((@($anyTlsRoundTrip.inbounds[0].padding_scheme) -join "`n") -eq ($generatedPadding -join "`n")) 'AnyTLS server preserves the per-instance padding scheme'
Assert-True (@($anyTlsRoundTrip.route.rules).Count -eq 1) 'AnyTLS IPv4-only rule remains an array'
$anyTlsClient = New-MxhAnyTlsClientOutbound -Context $anyTlsContext -Server '192.0.2.40' -Tag 'anytls-out'
Assert-True ($anyTlsClient.tls.ech.enabled) 'sing-box AnyTLS client ECH enabled'
Assert-True (-not $anyTlsClient.tls.Contains('insecure')) 'sing-box AnyTLS client does not disable certificate verification'
$anyTlsMihomo = New-MxhAnyTlsMihomoProfileText -Context $anyTlsContext -MixedPort 17894
Assert-True ($anyTlsMihomo -match 'type: anytls') 'Mihomo AnyTLS profile generated'
Assert-True ($anyTlsMihomo -match 'skip-cert-verify: false') 'Mihomo AnyTLS keeps certificate verification enabled'
Assert-True ($anyTlsMihomo -match 'ech-opts:') 'Mihomo AnyTLS profile includes ECH'

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
$anyTlsSmall = Get-VpsConservativeNetworkPlan -Role AnyTlsEntry -MemoryKiB 1048576 `
    -Mode AdaptiveConservative -BandwidthMbps 1000 -ReferenceRttMs 160
Assert-True ($anyTlsSmall.Profile -eq 'entry-small-adaptive') 'AnyTLS uses conservative entry tuning profile'
Assert-True ($anyTlsSmall.BufferCapBytes -eq 8MB) 'AnyTLS entry respects memory cap'
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

foreach ($case in @(
        @{ Name = 'anytls'; Fixture = 'dry-run-anytls-plan.json'; Sentinel = 'DRY-RUN-ANYTLS-SENTINEL-SHOULD-NOT-EXIST' },
        @{ Name = 'local Reality'; Fixture = 'dry-run-local-reality-plan.json'; Sentinel = 'DRY-RUN-LOCAL-REALITY-SENTINEL-SHOULD-NOT-EXIST' }
    )) {
    $sentinel = Join-Path $ProjectRoot $case.Sentinel
    if (Test-Path -LiteralPath $sentinel) { throw "Dry-run sentinel path already exists: $sentinel" }
    Push-Location $ProjectRoot
    try {
        Start-VpsDeploy -ProjectRoot $ProjectRoot -Mode Resume `
            -PlanPath (Join-Path $ProjectRoot (Join-Path 'tests\fixtures' $case.Fixture)) -DryRun -NonInteractive
    }
    finally { Pop-Location }
    Assert-True (-not (Test-Path -LiteralPath $sentinel)) "$($case.Name) dry run creates no instance data"
}

Write-Host '== Interactive wizard back navigation ==' -ForegroundColor Cyan
$wizardInstanceRoot = Join-Path $ProjectRoot '.test-output\wizard-instance-root'
$wizardArchive = Join-Path $wizardInstanceRoot 'ExampleProvider\RevisedInstance'
if (Test-Path -LiteralPath $wizardArchive) { throw "Wizard dry-run archive already exists: $wizardArchive" }
$wizardInputLines = @(
    'ExampleProvider',
    'OriginalInstance',
    'b',                 # return from node name to instance name
    'RevisedInstance',
    '',                  # accept regenerated node name
    '192.0.2.60',
    '',                  # no IPv6
    '',                  # default bootstrap SSH port
    '0',                 # return from authentication menu to SSH port
    '',
    '1',                 # password bootstrap
    '4',                 # MonitorOnly
    '',                  # default admin user
    'n',                 # automatic high ports
    'n',                 # no Komari
    '2',                 # summary: return to previous active item
    'n',
    '1'                  # confirm revised summary
)
$wizardInput = ($wizardInputLines -join [Environment]::NewLine) + [Environment]::NewLine
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
$wizardResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile',
    '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'New',
    '-DryRun',
    '-InstanceRoot', $wizardInstanceRoot
) -InputText $wizardInput -TimeoutSeconds 60
Assert-True ($wizardResult.ExitCode -eq 0) 'interactive wizard completes after multiple back operations'
Assert-True ($wizardResult.StdOut -match 'RevisedInstance') 'back navigation replaces the earlier instance value'
Assert-True ($wizardResult.StdOut -match 'bootstrap-port' -and $wizardResult.StdOut -match 'komari-enabled') 'text, numbered menu, and summary back paths are exercised'
Assert-True (-not (Test-Path -LiteralPath $wizardArchive)) 'interactive wizard dry run writes no plan or archive'

$branchResetRoot = Join-Path $ProjectRoot '.test-output\wizard-branch-reset'
$branchResetArchive = Join-Path $branchResetRoot 'ExampleProvider\BranchReset'
$branchInputs = @(
    'ExampleProvider', 'BranchReset', '', '192.0.2.61', '', '', '1', '1', '', 'n',
    '1', 'target.example.com', 'y', 'y', 'n', 'n', '2',
    'b', 'b', 'b', 'b', 'b', 'b', 'b', 'b', # Komari -> role
    '4', '', 'n', 'n', '1'                   # switch to MonitorOnly and confirm
)
$branchQueue = [Collections.Generic.Queue[string]]::new()
$branchInputs | ForEach-Object { $branchQueue.Enqueue($_) }
$coreModule = Get-Module VpsDeploy.Core
$branchPlan = & $coreModule {
    param($InputQueue, $Root, $InstanceRoot)
    $script:WizardTestInputQueue = $InputQueue
    function Read-Host {
        param([string]$Prompt)
        if ($script:WizardTestInputQueue.Count -eq 0) { throw "Wizard test input exhausted at: $Prompt" }
        return $script:WizardTestInputQueue.Dequeue()
    }
    try { New-VpsInteractivePlan -ProjectRoot $Root -InstanceRoot $InstanceRoot }
    finally {
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
        Remove-Variable WizardTestInputQueue -Scope Script -ErrorAction SilentlyContinue
    }
} $branchQueue $ProjectRoot $branchResetRoot 6>$null
Assert-True ($branchPlan.Role -eq 'MonitorOnly') 'back navigation can replace a previously completed role branch'
Assert-True (-not $branchPlan.Reality.Target -and -not $branchPlan.TrustedTls.Enabled -and -not $branchPlan.AnyTls.Enabled) 'role change clears stale proxy and trusted TLS fields'
Assert-True ($branchPlan.NetworkTuning.Mode -eq 'BaselineOnly') 'role change clears stale adaptive tuning fields'
Assert-True ($branchQueue.Count -eq 0) 'branch-reset wizard consumed the expected navigation path'
Assert-True (-not (Test-Path -LiteralPath $branchResetArchive)) 'in-memory branch-reset test writes no plan or archive'

$testOutputRoot = Join-Path $ProjectRoot '.test-output'
if (Test-Path -LiteralPath $testOutputRoot) {
    $remainingTestOutput = @(Get-ChildItem -LiteralPath $testOutputRoot -Force)
    if ($remainingTestOutput.Count -eq 0) { [IO.Directory]::Delete($testOutputRoot, $false) }
}

Write-Host '== Secret scan ==' -ForegroundColor Cyan
& (Join-Path $ProjectRoot 'scripts\Test-NoSecrets.ps1') -ProjectRoot $ProjectRoot
Assert-True $true 'secret scan'

Write-Host "All tests passed: $passed assertions" -ForegroundColor Green
