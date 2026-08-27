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
Assert-True ([string]$manifest.komari_controller.version -eq '1.3.1') 'Komari controller pinned stable baseline'
Assert-True ([string]$manifest.komari_controller.assets.amd64.name -eq 'komari-linux-amd64') 'Komari controller amd64 asset name'
Assert-True ([string]$manifest.komari_controller.assets.amd64.sha256 -match '^[0-9a-f]{64}$') 'Komari controller amd64 SHA-256'
Assert-True ([string]$manifest.komari_controller.assets.arm64.sha256 -match '^[0-9a-f]{64}$') 'Komari controller arm64 SHA-256'
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
$coreModule = Get-Module VpsDeploy.Core
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
Assert-True ('migration-preflight' -in $modules.Id) 'protocol migration preflight module exists'
Assert-True ('migration-arm-rollback' -in $modules.Id) 'protocol migration rollback timer module exists'
Assert-True ('migration-commit' -in $modules.Id) 'protocol migration commit module exists'
Assert-True ('migration-shadowsocks-probe' -in $modules.Id) 'trusted-entry Shadowsocks migration probe module exists'
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
$migrationArm = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\protocol-migration-arm-rollback.sh')
Assert-True ($migrationArm -match 'mxh-protocol-migration-rollback\.timer') 'protocol migration installs a VPS-side rollback timer'
Assert-True ($migrationArm -match 'cp -a /etc/nftables\.conf') 'protocol migration backs up the source firewall'
$migrationCommit = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\protocol-migration-commit.sh')
Assert-True ($migrationCommit -match 'FINAL_REALITY_ENABLED' -and $migrationCommit -match 'FINAL_ANYTLS_ENABLED') 'lifecycle commit applies explicit final service states'
Assert-True ($migrationCommit -match 'systemctl stop mxh-protocol-migration-rollback\.timer') 'migration commit cancels rollback only after target validation'
$lifecycleUninstall = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\protocol-lifecycle-uninstall.sh')
Assert-True ($lifecycleUninstall -match 'systemctl is-enabled' -and $lifecycleUninstall -match 'VPSDEPLOY_PROTOCOL_UNINSTALLED') 'uninstall refuses active protocols and returns a success marker'
$backupPrune = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\protocol-backup-prune.sh')
Assert-True ($backupPrune -match 'mxh-protocol-migration-rollback\.timer' -and $backupPrune -match 'protocol-lifecycle') 'backup cleanup protects active rollback and limits its remote scope'
$localHttpsSetup = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\local-https-target.sh')
Assert-True ($localHttpsSetup -match 'mask nginx\.service') 'nginx is masked while the package default site could start'
Assert-True ($localHttpsSetup -match 'unmask nginx\.service') 'nginx is unmasked only after package installation checks'
$targetAuditModule = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'modules\40-TargetAudit.ps1')
Assert-True ($targetAuditModule -match 'ACCEPT-TARGET-RISK' -and $targetAuditModule -match 'manual_override') 'failed target audits support an explicit recorded manual override'
Assert-True ($targetAuditModule -match 'NonInteractive.*禁止人工覆写') 'noninteractive target audit cannot silently bypass automatic requirements'
$importAudit = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\existing-vps-import-audit.sh')
Assert-True ($importAudit -match 'IMPORT_PRIVATE' -and $importAudit -match 'RealityEntry') 'existing VPS import discovers supported protocol state and private configuration'
$importPythonMatch = [regex]::Match($importAudit, "(?s)python3 <<'PY'\n(.+?)\nPY")
Assert-True $importPythonMatch.Success 'existing import Python audit payload is extractable'
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCommand) {
    $importPythonPath = Join-Path $ProjectRoot '.test-output\existing-import-audit.py'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $importPythonPath)) | Out-Null
    [IO.File]::WriteAllText($importPythonPath, $importPythonMatch.Groups[1].Value, [Text.UTF8Encoding]::new($false))
    $pythonSyntax = Invoke-VpsProcess -FilePath $pythonCommand.Source -ArgumentList @(
        '-c', 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")', $importPythonPath
    ) -TimeoutSeconds 30
    Assert-True ($pythonSyntax.ExitCode -eq 0) 'existing import Python audit parses'
    [IO.File]::Delete($importPythonPath)
}
$importSsh = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'assets\remote\existing-vps-import-ssh-keyonly.sh')
Assert-True ($importSsh -match 'PasswordAuthentication no' -and $importSsh -match 'PubkeyAuthentication yes') 'optional existing-VPS key-only hardening remains available'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'src\VpsDeploy.Import.ps1')) -match 'EnforceKeyOnlySsh') 'existing VPS import explicitly records whether SSH authentication is preserved or hardened'

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

$keyReuseRoot = Join-Path $ProjectRoot '.test-output\ssh-key-reuse'
if (Test-Path -LiteralPath $keyReuseRoot) { [IO.Directory]::Delete($keyReuseRoot, $true) }
[IO.Directory]::CreateDirectory($keyReuseRoot) | Out-Null
$sourceKey = Join-Path $keyReuseRoot 'provider-original-key'
$keygenResult = Invoke-VpsProcess -FilePath (Get-Command ssh-keygen.exe -ErrorAction Stop).Source `
    -ArgumentList @('-t','ed25519','-N','','-C','provider-fixture','-f',$sourceKey) -TimeoutSeconds 60
Assert-True ($keygenResult.ExitCode -eq 0) 'fixture Ed25519 provider key generated'
$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceKey).Hash
$managedDirectory = Join-Path $keyReuseRoot 'MXH-VPS-Deploy\ssh'
$reuseContext = [pscustomobject]@{ Plan = [ordered]@{
        NodeName='Example-Reused-Key';Server=[ordered]@{BootstrapKeyPath=$sourceKey}
        SshKey=[ordered]@{Mode='ReuseExisting';SourcePrivateKeyPath=$sourceKey;ManagedFileName='id_ed25519';PreserveSource=$true}
        Paths=[ordered]@{KeyDirectory=$managedDirectory}
    } }
& $coreModule { param($Context) Initialize-VpsSshKey -Context $Context } $reuseContext 6>$null
$managedKey = Join-Path $managedDirectory 'id_ed25519'
Assert-True (Test-Path -LiteralPath $managedKey -PathType Leaf) 'existing provider key is copied under a normalized managed filename'
Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $managedKey).Hash -eq $sourceHash) 'managed key copy preserves the provider private key instead of rotating it'
Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $sourceKey).Hash -eq $sourceHash) 'provider key source is never renamed or modified'
Assert-True ((Get-Content -Raw -LiteralPath ($managedKey + '.pub')).Trim() -match '^ssh-ed25519\s+') 'public key is derived from the reused private key'
[IO.Directory]::Delete($keyReuseRoot, $true)

$oldLatest = [Environment]::GetEnvironmentVariable('MXH_VPS_TEST_XRAY_LATEST')
try {
    [Environment]::SetEnvironmentVariable('MXH_VPS_TEST_XRAY_LATEST','99.1.2')
    $resolvedLatest = & $coreModule { param($Root) Resolve-VpsXrayVersion -ProjectRoot $Root -Channel LatestStable } $ProjectRoot
    Assert-True ($resolvedLatest -eq '99.1.2') 'latest-stable Xray channel resolves and stores an exact version'
    $resolvedFixed = & $coreModule { param($Root) Resolve-VpsXrayVersion -ProjectRoot $Root -Channel FixedVerified } $ProjectRoot
    Assert-True ($resolvedFixed -eq '26.3.27') 'fixed verified Xray channel remains available'
}
finally { [Environment]::SetEnvironmentVariable('MXH_VPS_TEST_XRAY_LATEST',$oldLatest) }

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

Write-Host '== Bidirectional protocol migration planning ==' -ForegroundColor Cyan
$realitySourcePath = Join-Path $ProjectRoot 'tests\fixtures\dry-run-plan.json'
$anyTlsSourcePath = Join-Path $ProjectRoot 'tests\fixtures\dry-run-anytls-plan.json'
$shadowsocksSourcePath = Join-Path $ProjectRoot 'tests\fixtures\dry-run-landing-plan.json'
$realitySource = Get-Content -Raw -LiteralPath $realitySourcePath | ConvertFrom-Json -AsHashtable
$anyTlsSource = Get-Content -Raw -LiteralPath $anyTlsSourcePath | ConvertFrom-Json -AsHashtable
$shadowsocksSource = Get-Content -Raw -LiteralPath $shadowsocksSourcePath | ConvertFrom-Json -AsHashtable
$migrationAllowlist = [ordered]@{ IPv4 = @('192.0.2.70'); IPv6 = @('2001:db8::70') }
$baselineTuning = [ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = $null; ReferenceRttMs = $null }
$migrationCases = @(
    @{ Source = $realitySource; Path = $realitySourcePath; Target = 'AnyTlsEntry'; Port = 443 },
    @{ Source = $realitySource; Path = $realitySourcePath; Target = 'ShadowsocksLanding'; Port = 34101 },
    @{ Source = $anyTlsSource; Path = $anyTlsSourcePath; Target = 'RealityEntry'; Port = 34102 },
    @{ Source = $anyTlsSource; Path = $anyTlsSourcePath; Target = 'ShadowsocksLanding'; Port = 34103 },
    @{ Source = $shadowsocksSource; Path = $shadowsocksSourcePath; Target = 'RealityEntry'; Port = 34104 },
    @{ Source = $shadowsocksSource; Path = $shadowsocksSourcePath; Target = 'AnyTlsEntry'; Port = 443 }
)
$migrationPlans = foreach ($case in $migrationCases) {
    New-MxhProtocolMigrationPlan -SourcePlan $case.Source -SourcePlanPath $case.Path `
        -TargetRole $case.Target -TargetServicePort $case.Port `
        -RealityTargetMode ExternalAudited -RealityTarget 'target.example.invalid' `
        -RealityServerName 'target.example.invalid' -RealityTargetAddress 'target.example.invalid:443' `
        -AnyTlsServerName 'edge.example.invalid' -EchPublicName 'www.example.invalid' `
        -AnyTlsPaddingScheme @('stop=8', '0=10-20') -ForceIpv4Egress $true `
        -TrustedTlsEnabled ($case.Target -eq 'AnyTlsEntry') -CloudflareZoneName 'example.invalid' `
        -CertbotEmail 'fixture@example.invalid' -CloudflareTokenFile 'C:\fixture-token.private.txt' `
        -TrustedEntryIps $migrationAllowlist -ClientTransitTag 'US-West Entry' `
        -ValidationEntryPlanPath 'C:\fixture-entry-plan.json' `
        -SecondaryIpv6Enabled $false -NetworkTuning $baselineTuning
}
Assert-True ($migrationPlans.Count -eq 6) 'all six directed protocol role conversions are generated'
$directionNames = @($migrationPlans | ForEach-Object { "$($_.Migration.SourceRole)->$($_.Migration.TargetRole)" })
Assert-True (($directionNames | Sort-Object -Unique).Count -eq 6) 'every Reality AnyTLS Shadowsocks direction is unique'
foreach ($plan in $migrationPlans) {
    Assert-True ($plan.Role -eq $plan.Migration.TargetRole) "migration target role is authoritative for $($plan.Migration.SourceRole)->$($plan.Role)"
    Assert-True ('migration-preflight' -in $plan.Migration.ModuleIds) 'migration plan includes fresh preflight'
    Assert-True ('migration-arm-rollback' -in $plan.Migration.ModuleIds) 'migration plan arms rollback before target switch'
    Assert-True ('migration-commit' -in $plan.Migration.ModuleIds) 'migration plan requires final commit'
    Assert-True ('final-validation' -in $plan.Migration.ModuleIds) 'migration plan includes target validation'
    $targetModule = switch ($plan.Role) {
        'RealityEntry' { 'xray-reality' }
        'AnyTlsEntry' { 'sing-box-anytls' }
        'ShadowsocksLanding' { 'sing-box-shadowsocks' }
    }
    Assert-True ($targetModule -in $plan.Migration.ModuleIds) "migration includes target module $targetModule"
}
Assert-True (($migrationPlans | Where-Object Role -eq 'RealityEntry').Count -eq 2) 'two sources can migrate to Reality'
Assert-True (($migrationPlans | Where-Object Role -eq 'AnyTlsEntry').Count -eq 2) 'two sources can migrate to AnyTLS'
Assert-True (($migrationPlans | Where-Object Role -eq 'ShadowsocksLanding').Count -eq 2) 'two sources can migrate to Shadowsocks'
Assert-True (@($migrationPlans | Where-Object Role -eq 'ShadowsocksLanding' | Where-Object { 'migration-shadowsocks-probe' -notin $_.Migration.ModuleIds }).Count -eq 0) 'every Shadowsocks migration requires a trusted-entry external probe'
$localRealityMigrationIds = @(Get-MxhMigrationModuleIds -TargetRole RealityEntry -RealityTargetMode LocalOwnedTls)
Assert-True ('certbot-dns' -in $localRealityMigrationIds -and 'local-https-target' -in $localRealityMigrationIds) 'local Reality migration includes certificate and loopback HTTPS modules'
Assert-True ('target-audit' -notin $localRealityMigrationIds) 'local Reality migration excludes external target audit'

Write-Host '== Protocol lifecycle inventory and state transitions ==' -ForegroundColor Cyan
$standbyAnyTls = New-MxhProtocolMigrationPlan -SourcePlan $realitySource -SourcePlanPath $realitySourcePath `
    -TargetRole AnyTlsEntry -Operation InstallStandby -TargetServicePort 443 `
    -AnyTlsServerName 'edge.example.invalid' -EchPublicName 'www.example.invalid' `
    -AnyTlsPaddingScheme @('stop=8', '0=10-20') -TrustedTlsEnabled $true `
    -CloudflareZoneName 'example.invalid' -CertbotEmail 'fixture@example.invalid' `
    -CloudflareTokenFile 'C:\fixture-token.private.txt' -NetworkTuning $baselineTuning
Assert-True ($standbyAnyTls.ProtocolInventory.RealityEntry.Installed -and $standbyAnyTls.ProtocolInventory.RealityEntry.Enabled) 'standby install keeps Reality installed and enabled'
Assert-True ($standbyAnyTls.ProtocolInventory.AnyTlsEntry.Installed -and -not $standbyAnyTls.ProtocolInventory.AnyTlsEntry.Enabled) 'standby install records AnyTLS as installed but disabled'
Assert-True ($standbyAnyTls.Migration.ValidationInventory.AnyTlsEntry.Enabled) 'standby protocol is temporarily enabled for real validation'
Assert-True ($standbyAnyTls.Migration.FinalRole -eq 'RealityEntry') 'standby install restores the original primary role'

$enableAnyTls = New-MxhProtocolLifecyclePlan -SourcePlan $standbyAnyTls -SourcePlanPath $realitySourcePath `
    -SourceInventory $standbyAnyTls.ProtocolInventory -TargetRole AnyTlsEntry -Operation Enable
Assert-True ($enableAnyTls.Migration.FinalInventory.AnyTlsEntry.Enabled) 'enabling installed AnyTLS marks it enabled'
Assert-True (-not $enableAnyTls.Migration.FinalInventory.RealityEntry.Enabled) 'enabling AnyTLS disables conflicting Reality without uninstalling it'
Assert-True ($enableAnyTls.Migration.FinalInventory.RealityEntry.Installed) 'entry switch preserves Reality installation'
Assert-True ('protocol-lifecycle-state' -in $enableAnyTls.Migration.ModuleIds -and 'sing-box-anytls' -notin $enableAnyTls.Migration.ModuleIds) 'switching installed protocols does not reinstall the target'

$uninstallReality = New-MxhProtocolLifecyclePlan -SourcePlan $enableAnyTls -SourcePlanPath $realitySourcePath `
    -SourceInventory $enableAnyTls.Migration.FinalInventory -TargetRole RealityEntry -Operation Uninstall
Assert-True (-not $uninstallReality.Migration.FinalInventory.RealityEntry.Installed) 'uninstall removes the disabled protocol from final inventory'
Assert-True ($uninstallReality.Migration.FinalInventory.AnyTlsEntry.Enabled) 'uninstall leaves the active peer entry enabled'
Assert-True ('protocol-lifecycle-uninstall' -in $uninstallReality.Migration.ModuleIds) 'uninstall plan uses the dedicated removal module'
Assert-True ('protocol-lifecycle-final-firewall' -in $uninstallReality.Migration.ModuleIds) 'uninstall plan performs final firewall convergence before commit'
$activeUninstallRejected = $false
try {
    New-MxhProtocolLifecyclePlan -SourcePlan $enableAnyTls -SourcePlanPath $realitySourcePath `
        -SourceInventory $enableAnyTls.Migration.FinalInventory -TargetRole AnyTlsEntry -Operation Uninstall | Out-Null
}
catch { $activeUninstallRejected = $_.Exception.Message -match '只能卸载' }
Assert-True $activeUninstallRejected 'active protocols cannot be uninstalled directly'

$realityToSs = @($migrationPlans | Where-Object { $_.Migration.SourceRole -eq 'RealityEntry' -and $_.Migration.TargetRole -eq 'ShadowsocksLanding' })[0]
Assert-True ($realityToSs.Migration.FinalInventory.RealityEntry.Enabled -and $realityToSs.Migration.FinalInventory.ShadowsocksLanding.Enabled) 'Shadowsocks can run concurrently with the entry protocol'
$firewallFixtureState = [ordered]@{ BootstrapSshRemoved = $true }
$firewallParameters = Get-MxhProtocolFirewallParameters -Plan $realityToSs -State $firewallFixtureState -Inventory $realityToSs.Migration.FinalInventory
Assert-True ([string]$firewallParameters.TCP_PORTS -match '443' -and [string]$firewallParameters.TCP_PORTS -match [string]$realityToSs.Ports.XrayBackup) 'concurrent firewall retains Reality primary and rescue ports'
Assert-True ([string]$firewallParameters.RESTRICTED_PORT -eq [string]$realityToSs.Ports.LandingShadowsocks) 'concurrent firewall keeps Shadowsocks as the restricted TCP and UDP port'
$standaloneBaseline = [ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = $null; ReferenceRttMs = $null }
$networkOnlyPlan = New-MxhNetworkTuningPlan -SourcePlan $realitySource -SourcePlanPath $realitySourcePath `
    -TuningRole RealityEntry -NetworkTuning $standaloneBaseline
Assert-True ($networkOnlyPlan.Migration.Operation -eq 'NetworkTune') 'standalone network tuning uses a dedicated lifecycle operation'
Assert-True ('network-tuning' -in $networkOnlyPlan.Migration.ModuleIds) 'standalone network tuning includes the tuning module'
Assert-True ('nftables-transition' -notin $networkOnlyPlan.Migration.ModuleIds -and 'protocol-lifecycle-final-firewall' -notin $networkOnlyPlan.Migration.ModuleIds) 'standalone network tuning does not rewrite the firewall'
Assert-True ($networkOnlyPlan.NetworkTuning.Mode -eq 'BaselineOnly' -and $null -eq $networkOnlyPlan.NetworkTuning.ReferenceRttMs) 'baseline network tuning requires no RTT'

$clearCommandResult = & (Get-Module VpsDeploy.Core) {
    [ordered]@{
        Clear = Test-VpsClearCommand ' clear '
        Cls = Test-VpsClearCommand 'CLS'
        BreadCloud = Test-VpsClearCommand 'BreadCloud'
        Clearwater = Test-VpsClearCommand 'Clearwater'
    }
}
Assert-True ($clearCommandResult.Clear -and $clearCommandResult.Cls) 'clear and cls are exact global clear commands'
Assert-True (-not $clearCommandResult.BreadCloud -and -not $clearCommandResult.Clearwater) 'clear command never uses prefix matching'
$archiveRootValidation = & (Get-Module VpsDeploy.Core) {
    param($AbsolutePath, $DriveRoot)
    [ordered]@{
        Absolute = Test-VpsArchiveRoot $AbsolutePath
        Relative = Test-VpsArchiveRoot 'relative\archive'
        DriveRoot = Test-VpsArchiveRoot $DriveRoot
    }
} $ProjectRoot ([IO.Path]::GetPathRoot($ProjectRoot))
Assert-True ($archiveRootValidation.Absolute) 'archive root accepts a fully qualified non-root path'
Assert-True (-not $archiveRootValidation.Relative -and -not $archiveRootValidation.DriveRoot) 'archive root rejects relative paths and a bare drive root'

$migrationFixtureRoot = Join-Path $ProjectRoot '.test-output\migration-context'
if (Test-Path -LiteralPath $migrationFixtureRoot) { [IO.Directory]::Delete($migrationFixtureRoot, $true) }
[IO.Directory]::CreateDirectory($migrationFixtureRoot) | Out-Null
$migrationSourcePlan = ($realitySource | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable
$migrationSourcePlan.Paths.Archive = $migrationFixtureRoot
$migrationSourcePlan.Paths.KeyDirectory = Join-Path $migrationFixtureRoot 'fixture-id_ed25519'
[IO.Directory]::CreateDirectory([string]$migrationSourcePlan.Paths.KeyDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $migrationSourcePlan.Paths.KeyDirectory 'id_ed25519'), 'fixture-key')
[IO.File]::WriteAllText((Join-Path $migrationSourcePlan.Paths.KeyDirectory 'id_ed25519.pub'), 'fixture-public-key')
$migrationSourcePlanPath = Join-Path $migrationFixtureRoot 'deployment-plan.json'
$successState = { [ordered]@{ Status = 'Success'; UpdatedAt = '2026-01-01T00:00:00Z'; Message = 'fixture' } }
$migrationSourceState = [ordered]@{
    SchemaVersion = 1
    CurrentManagementPort = [int]$migrationSourcePlan.Ports.SshPrimary
    Modules = [ordered]@{
        'ssh-transition' = & $successState
        'xray-reality' = & $successState
        'nftables-transition' = & $successState
        'final-validation' = & $successState
        'ssh-cutover' = & $successState
        'private-archive' = & $successState
        'komari-agent' = & $successState
    }
}
$migrationSourceSecrets = [ordered]@{
    SchemaVersion = 1
    AdminPassword = 'fixture-admin-password'
    Xray = [ordered]@{ Uuid = 'fixture'; RealityPrivateKey = 'fixture'; RealityClientKey = 'fixture'; ShortId = 'fixture' }
}
Save-VpsJson -Value $migrationSourcePlan -Path $migrationSourcePlanPath -Private
Save-VpsJson -Value $migrationSourceState -Path (Join-Path $migrationFixtureRoot 'deployment-state.json') -Private
Save-VpsJson -Value $migrationSourceSecrets -Path (Join-Path $migrationFixtureRoot 'deployment-secrets.private.json') -Private
Assert-True (Test-MxhProtocolMigrationSource -PlanPath $migrationSourcePlanPath -Plan $migrationSourcePlan -State $migrationSourceState) 'completed script-managed source is accepted for migration'
$migrationTargetPlan = New-MxhProtocolMigrationPlan -SourcePlan $migrationSourcePlan -SourcePlanPath $migrationSourcePlanPath `
    -TargetRole ShadowsocksLanding -TargetServicePort 34201 -TrustedEntryIps $migrationAllowlist `
    -ClientTransitTag 'US-West Entry' -NetworkTuning $baselineTuning
$migrationResultFixture = [pscustomobject]@{
    Plan = $migrationTargetPlan
    Source = [pscustomobject]@{ PlanPath = $migrationSourcePlanPath; Plan = $migrationSourcePlan; State = $migrationSourceState }
}
$migrationContext = & (Get-Module VpsDeploy.Core) {
    param($Root, $Result)
    Initialize-MxhProtocolMigrationContext -ProjectRoot $Root -MigrationResult $Result -NonInteractive
} $ProjectRoot $migrationResultFixture
Assert-True ($migrationContext.Plan.Role -eq 'ShadowsocksLanding') 'migration context writes the target role plan'
Assert-True (Test-Path -LiteralPath (Join-Path $migrationContext.Plan.Migration.LocalBackupDirectory 'deployment-plan.json')) 'migration context preserves the source plan before replacement'
Assert-True ($migrationContext.State.Modules.Contains('xray-reality')) 'migration context preserves source protocol history'
Assert-True (-not $migrationContext.State.Modules.Contains('nftables-transition') -and -not $migrationContext.State.Modules.Contains('final-validation')) 'migration context resets target validation and firewall modules'
Assert-True ($migrationContext.State.Migration.Status -eq 'Planned' -and -not $migrationContext.State.Migration.RollbackArmed) 'migration context starts before remote rollback is armed'
[IO.Directory]::Delete($migrationFixtureRoot, $true)

Write-Host '== Conservative adaptive network planning ==' -ForegroundColor Cyan
$entrySmall = Get-VpsConservativeNetworkPlan -Role RealityEntry -MemoryKiB 1048576 `
    -Mode AdaptiveConservative -BandwidthMbps 1000 -ReferenceRttMs 160
Assert-True ($entrySmall.MemoryTier -eq 'small') '1 GiB entry uses small memory tier'
Assert-True ($entrySmall.BufferCapBytes -eq 8MB) '1 GiB entry buffer cap is 8 MiB'
Assert-True ($entrySmall.BufferTargetBytes -eq 8MB) 'high-BDP entry is capped by memory'
Assert-True ($entrySmall.QueueFloor -eq 2048) 'entry queue floor considers the nominal 1 Gbps plan conservatively'
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
Assert-True ($anyTlsSmall.Profile -eq 'entry-small-high-adaptive') 'AnyTLS profile records role, memory, nominal bandwidth and mode'
Assert-True ($anyTlsSmall.BufferCapBytes -eq 8MB) 'AnyTLS entry respects memory cap'
$monitor = Get-VpsConservativeNetworkPlan -Role MonitorOnly -MemoryKiB 1048576 -Mode BaselineOnly
Assert-True ($monitor.BufferTargetBytes -eq 0) 'monitor baseline does not tune buffers'
Assert-True ($monitor.QueueFloor -eq 0) 'monitor baseline does not pin proxy queues'
$baselineKnownBandwidth = Get-VpsConservativeNetworkPlan -Role RealityEntry -MemoryKiB 1048576 -Mode BaselineOnly -BandwidthMbps 500
Assert-True ($baselineKnownBandwidth.BandwidthMbps -eq 500 -and $baselineKnownBandwidth.ReferenceRttMs -eq $null) 'baseline records required nominal bandwidth without requiring RTT'
Assert-True ($baselineKnownBandwidth.BufferTargetBytes -eq 0 -and $baselineKnownBandwidth.QueueFloor -eq 1024) 'bandwidth-aware baseline remains conservative and does not tune buffers'
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
    '',                  # accept the visible archive-root default
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

$reuseWizardRoot = Join-Path $ProjectRoot '.test-output\wizard-existing-key-root'
$reuseWizardKey = Join-Path $ProjectRoot '.test-output\wizard-existing-provider-key'
if(Test-Path $reuseWizardRoot){[IO.Directory]::Delete($reuseWizardRoot,$true)}
foreach($item in @($reuseWizardKey,$reuseWizardKey+'.pub')){if(Test-Path $item){Remove-Item $item -Force}}
$reuseKeygen=Invoke-VpsProcess (Get-Command ssh-keygen.exe).Source @('-t','ed25519','-N','','-C','provider-reuse-wizard','-f',$reuseWizardKey) -TimeoutSeconds 60
Assert-True ($reuseKeygen.ExitCode -eq 0) 'existing-key wizard fixture key generated'
$reuseWizardInput=(@('', 'ExampleProvider','ReuseExistingInstance','','192.0.2.63','','','2',$reuseWizardKey,'1','4','','n','n','1')-join[Environment]::NewLine)+[Environment]::NewLine
$reuseWizardResult=Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile','-File',(Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),'-Mode','New','-DryRun','-InstanceRoot',$reuseWizardRoot
) -InputText $reuseWizardInput -TimeoutSeconds 60
Assert-True ($reuseWizardResult.ExitCode -eq 0) 'new-deployment wizard accepts provider existing-key reuse without forcing a new public key'
Assert-True (-not(Test-Path $reuseWizardRoot)) 'existing-key New DryRun creates no instance archive'
foreach($item in @($reuseWizardKey,$reuseWizardKey+'.pub')){if(Test-Path $item){Remove-Item $item -Force}}

$branchResetRoot = Join-Path $ProjectRoot '.test-output\wizard-branch-reset'
$branchDefaultRoot = Join-Path $ProjectRoot '.test-output\wizard-default-root'
$branchResetArchive = Join-Path $branchResetRoot 'ExampleProvider\BranchReset'
$branchInputs = @(
    $branchResetRoot, 'ExampleProvider', 'BranchReset', '', '192.0.2.61', '', '', '1', '1', '1', '', 'n',
    '1', 'target.example.com', 'y', 'y', 'n', '1000', 'n', '2',
    'b', 'b', 'b', 'b', 'b', 'b', 'b', 'b', 'b', 'b', # Komari -> role
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
} $branchQueue $ProjectRoot $branchDefaultRoot 6>$null
Assert-True ($branchPlan.Role -eq 'MonitorOnly') 'back navigation can replace a previously completed role branch'
Assert-True (-not $branchPlan.Reality.Target -and -not $branchPlan.TrustedTls.Enabled -and -not $branchPlan.AnyTls.Enabled) 'role change clears stale proxy and trusted TLS fields'
Assert-True ($branchPlan.NetworkTuning.Mode -eq 'BaselineOnly') 'role change clears stale adaptive tuning fields'
Assert-True ([string]$branchPlan.Paths.Archive -eq (Join-Path $branchResetArchive 'MXH-VPS-Deploy')) 'interactive archive root uses the instance managed-data subdirectory'
Assert-True ($branchQueue.Count -eq 0) 'branch-reset wizard consumed the expected navigation path'
Assert-True (-not (Test-Path -LiteralPath $branchResetArchive)) 'in-memory branch-reset test writes no plan or archive'

Write-Host '== Interactive navigation hierarchy ==' -ForegroundColor Cyan
$hierarchyInput = (@('clear', '1', 'b', '2', 'b', 'cls', '0') -join [Environment]::NewLine) + [Environment]::NewLine
$hierarchyResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'), '-Mode', 'Interactive', '-DryRun'
) -InputText $hierarchyInput -TimeoutSeconds 60
Assert-True ($hierarchyResult.ExitCode -eq 0) 'first new-deployment field and resume path both return to the main menu'
Assert-True ($hierarchyResult.StdOut -match 'MXH VPS Deploy' -and `
    [regex]::Matches($hierarchyResult.StdOut, '(?m)^b\r?$').Count -eq 2) 'interactive hierarchy consumed back commands in both child workflows'
Assert-True ($hierarchyResult.StdOut -notmatch '__MXH_VPS_WIZARD_' -and $hierarchyResult.StdErr -notmatch '__MXH_VPS_WIZARD_') 'navigation markers never leak to the console'
Assert-True ($hierarchyResult.StdOut -match '(?m)^clear\r?$' -and $hierarchyResult.StdOut -match '(?m)^cls\r?$') 'clear and cls are consumed by live menu navigation'

$providerPrefixInput = (@('1', '', 'BreadCloud', 'b', 'b', 'b', '0') -join [Environment]::NewLine) + [Environment]::NewLine
$providerPrefixResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'), '-Mode', 'Interactive', '-DryRun'
) -InputText $providerPrefixInput -TimeoutSeconds 60
Assert-True ($providerPrefixResult.ExitCode -eq 0) 'provider names beginning with b remain valid while exact b navigates back'
Assert-True ($providerPrefixResult.StdOut -match '(?m)^BreadCloud\r?$') 'BreadCloud is accepted as a provider value, not parsed as a back command'

$migrationDryRoot = Join-Path $ProjectRoot '.test-output\migration-dryrun-source'
$migrationEntryRoot = Join-Path $ProjectRoot '.test-output\migration-validation-entry'
if (Test-Path -LiteralPath $migrationDryRoot) { [IO.Directory]::Delete($migrationDryRoot, $true) }
if (Test-Path -LiteralPath $migrationEntryRoot) { [IO.Directory]::Delete($migrationEntryRoot, $true) }
[IO.Directory]::CreateDirectory($migrationDryRoot) | Out-Null
[IO.Directory]::CreateDirectory($migrationEntryRoot) | Out-Null
$migrationDryPlan = ($realitySource | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable
$migrationDryPlan.Paths.Archive = $migrationDryRoot
$migrationDryPlan.Paths.KeyDirectory = Join-Path $migrationDryRoot 'fixture-id_ed25519'
[IO.Directory]::CreateDirectory([string]$migrationDryPlan.Paths.KeyDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $migrationDryPlan.Paths.KeyDirectory 'id_ed25519'), 'fixture-key')
[IO.File]::WriteAllText((Join-Path $migrationDryPlan.Paths.KeyDirectory 'id_ed25519.pub'), 'fixture-public-key')
$migrationDryPlanPath = Join-Path $migrationDryRoot 'deployment-plan.json'
$migrationDryState = [ordered]@{
    SchemaVersion = 1
    CurrentManagementPort = [int]$migrationDryPlan.Ports.SshPrimary
    Modules = [ordered]@{
        'ssh-transition' = & $successState
        'xray-reality' = & $successState
        'nftables-transition' = & $successState
        'final-validation' = & $successState
        'ssh-cutover' = & $successState
        'private-archive' = & $successState
    }
}
Save-VpsJson -Value $migrationDryPlan -Path $migrationDryPlanPath -Private
Save-VpsJson -Value $migrationDryState -Path (Join-Path $migrationDryRoot 'deployment-state.json') -Private
Save-VpsJson -Value $migrationSourceSecrets -Path (Join-Path $migrationDryRoot 'deployment-secrets.private.json') -Private
$migrationEntryPlan = ($realitySource | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable
$migrationEntryPlan.Server.IPv4 = '192.0.2.70'
$migrationEntryPlan.Paths.Archive = $migrationEntryRoot
$migrationEntryPlan.Paths.KeyDirectory = Join-Path $migrationEntryRoot 'fixture-id_ed25519'
[IO.Directory]::CreateDirectory([string]$migrationEntryPlan.Paths.KeyDirectory) | Out-Null
[IO.File]::WriteAllText((Join-Path $migrationEntryPlan.Paths.KeyDirectory 'id_ed25519'), 'fixture-key')
[IO.File]::WriteAllText((Join-Path $migrationEntryPlan.Paths.KeyDirectory 'id_ed25519.pub'), 'fixture-public-key')
$migrationEntryPlanPath = Join-Path $migrationEntryRoot 'deployment-plan.json'
$migrationEntryState = [ordered]@{
    SchemaVersion = 1
    CurrentManagementPort = [int]$migrationEntryPlan.Ports.SshPrimary
    Audit = [ordered]@{ Architecture = 'x86_64' }
    Modules = [ordered]@{
        'xray-reality' = & $successState
        'final-validation' = & $successState
        'ssh-cutover' = & $successState
    }
}
Save-VpsJson -Value $migrationEntryPlan -Path $migrationEntryPlanPath -Private
Save-VpsJson -Value $migrationEntryState -Path (Join-Path $migrationEntryRoot 'deployment-state.json') -Private
Save-VpsJson -Value $migrationSourceSecrets -Path (Join-Path $migrationEntryRoot 'deployment-secrets.private.json') -Private
$migrationDryInput = (@('1', '1', '2', '', '192.0.2.70', '', $migrationEntryPlanPath, 'n', 'n', '1') -join [Environment]::NewLine) + [Environment]::NewLine
$migrationDryResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'Migrate', '-DryRun', '-PlanPath', $migrationDryPlanPath
) -InputText $migrationDryInput -TimeoutSeconds 60
Assert-True ($migrationDryResult.ExitCode -eq 0) 'existing Reality plan can enter Shadowsocks migration DryRun'
foreach ($expectedId in @('migration-preflight', 'migration-arm-rollback', 'sing-box-shadowsocks', 'migration-shadowsocks-probe', 'migration-commit')) {
    Assert-True ($migrationDryResult.StdOut -match [regex]::Escape($expectedId)) "migration DryRun displays $expectedId"
}
Assert-True ($migrationDryResult.StdOut -notmatch '(?m)\sbootstrap-access\s' -and $migrationDryResult.StdOut -notmatch '(?m)\sxray-reality\s') 'migration DryRun excludes clean-install and source protocol modules'
[IO.Directory]::Delete($migrationDryRoot, $true)
[IO.Directory]::Delete($migrationEntryRoot, $true)

function New-TestMigrationSourceFixture {
    param(
        [Collections.IDictionary]$Template,
        [string]$Root,
        [string]$ProtocolModule
    )
    if (Test-Path -LiteralPath $Root) { [IO.Directory]::Delete($Root, $true) }
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $plan = ($Template | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable
    $plan.Paths.Archive = $Root
    $plan.Paths.KeyDirectory = Join-Path $Root 'fixture-id_ed25519'
    [IO.Directory]::CreateDirectory([string]$plan.Paths.KeyDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $plan.Paths.KeyDirectory 'id_ed25519'), 'fixture-key')
    [IO.File]::WriteAllText((Join-Path $plan.Paths.KeyDirectory 'id_ed25519.pub'), 'fixture-public-key')
    $planPath = Join-Path $Root 'deployment-plan.json'
    $state = [ordered]@{
        SchemaVersion = 1
        CurrentManagementPort = [int]$plan.Ports.SshPrimary
        Modules = [ordered]@{
            'ssh-transition' = & $successState
            $ProtocolModule = & $successState
            'nftables-transition' = & $successState
            'final-validation' = & $successState
            'ssh-cutover' = & $successState
            'private-archive' = & $successState
        }
    }
    Save-VpsJson -Value $plan -Path $planPath -Private
    Save-VpsJson -Value $state -Path (Join-Path $Root 'deployment-state.json') -Private
    Save-VpsJson -Value $migrationSourceSecrets -Path (Join-Path $Root 'deployment-secrets.private.json') -Private
    return $planPath
}

Write-Host '== Maintenance center dry-run and client candidate engine ==' -ForegroundColor Cyan
$maintenanceFunctions = @(
    'Invoke-MxhMaintenanceCenter','Invoke-MxhManualRestoreCenter','Get-MxhHealthAudit','Invoke-MxhCredentialRotation',
    'Invoke-MxhSshMaintenance','Invoke-MxhFirewallMaintenance','Invoke-MxhControlledUpgrade',
    'Invoke-MxhClientCandidateMerge','Invoke-MxhKomariLifecycle','Invoke-MxhDecommission'
)
foreach ($name in $maintenanceFunctions) {
    $exists = & $coreModule { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) } $name
    Assert-True $exists "maintenance function exists: $name"
}
$healthAuditFixture = [ordered]@{
    SchemaVersion=1;CollectedAt='2026-01-01T00:00:00Z';Ssh=[ordered]@{Valid=$true;Ports=@([int]$realitySource.Ports.SshPrimary,[int]$realitySource.Ports.SshRescue);PasswordAuthentication='no';KbdInteractiveAuthentication='no';PubkeyAuthentication='yes';PermitRootLogin='prohibit-password'}
    Services=[ordered]@{
        RealityEntry=[ordered]@{Installed=$true;Enabled=$true;Active=$true}
        AnyTlsEntry=[ordered]@{Installed=$false;Enabled=$false;Active=$false}
        ShadowsocksLanding=[ordered]@{Installed=$false;Enabled=$false;Active=$false}
        KomariAgent=[ordered]@{Installed=$false;Enabled=$false;Active=$false}
        KomariController=[ordered]@{Installed=$false;Enabled=$false;Active=$false}
        Cloudflared=[ordered]@{Installed=$false;Enabled=$false;Active=$false}
    }
    Versions=[ordered]@{Xray='Xray 26.3.27';SingBoxAnyTls=$null;SingBox=$null;KomariAgent=$null}
    Hashes=[ordered]@{Xray=$null;Nftables='same'}
    Nftables=[ordered]@{Present=$true;Valid=$true};Certificate=[ordered]@{Present=$false;DaysRemaining=$null}
    Timers=[ordered]@{RollbackActive=$false;CertbotRenewEnabled=$false}
}
$healthPayload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($healthAuditFixture|ConvertTo-Json -Compress -Depth 20)))
$healthContext=[pscustomobject]@{Plan=$realitySource;State=[ordered]@{Modules=@{};KomariInstalled=$false;HealthBaseline=[ordered]@{Hashes=[ordered]@{Xray='old-hash';Nftables='same'}}};DryRun=$false}
$healthReport=& $coreModule {param($c,$payload) function Invoke-VpsRemoteScript{return [pscustomobject]@{StdOut="VPSDEPLOY_HEALTH_AUDIT_B64=$payload`nVPSDEPLOY_HEALTH_AUDIT_OK`n"}};try{Get-MxhHealthAudit $c}finally{Remove-Item Function:\Invoke-VpsRemoteScript -ErrorAction SilentlyContinue}} $healthContext $healthPayload
Assert-True ('CONFIG_HASH_DRIFT' -in @($healthReport.Findings.Code)) 'health drift detects deletion of a previously baselined managed file'
Assert-True ((Get-Content -Raw (Join-Path $ProjectRoot 'assets\remote\existing-vps-import-audit.sh')) -match 'Password.*PublicKey') 'existing import parser recognizes Xray 26.3.27 Password (PublicKey) label'
$maintenanceRoot = Join-Path $ProjectRoot '.test-output\maintenance-center-dryrun'
$maintenancePlan = New-TestMigrationSourceFixture -Template $realitySource -Root $maintenanceRoot -ProtocolModule 'xray-reality'
$maintenanceInput = (@('1','2','n') -join [Environment]::NewLine) + [Environment]::NewLine
$maintenanceResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile','-File',(Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),'-Mode','Maintain','-DryRun','-PlanPath',$maintenancePlan
) -InputText $maintenanceInput -TimeoutSeconds 60
Assert-True ($maintenanceResult.ExitCode -eq 0) 'maintenance center health audit DryRun exits cleanly'
Assert-True ($maintenanceResult.StdOut -match 'DryRun') 'maintenance center routes to read-only health audit'

$candidateRoot = Join-Path $maintenanceRoot 'candidate-fixture'
$fragmentRoot = Join-Path $candidateRoot 'fragments'
$outputRoot = Join-Path $candidateRoot 'output'
[IO.Directory]::CreateDirectory($fragmentRoot) | Out-Null
$authorityYaml = Join-Path $candidateRoot 'authority.yaml'
$authorityJson = Join-Path $candidateRoot 'authority.json'
[IO.File]::WriteAllText($authorityYaml, @"
proxies:
  - name: Existing-IPv4
    type: vless
    server: 192.0.2.9
proxy-groups:
  - name: US-West Entry
    type: select
    proxies:
      - Existing-IPv4
  - name: Europe Entry
    type: select
    proxies:
      - Existing-IPv4
rules:
  - MATCH,US-West Entry
"@)
[IO.File]::WriteAllText((Join-Path $fragmentRoot 'mihomo-test-primary.yaml'), @"
proxies:
  - name: Candidate-IPv4
    type: vless
    server: 192.0.2.1
proxy-groups: []
rules: []
"@)
Save-VpsJson -Value ([ordered]@{ outbounds=@([ordered]@{type='vless';tag='Candidate-IPv4';server='192.0.2.1'}) }) -Path (Join-Path $fragmentRoot 'sing-box-outbounds.private.json')
Save-VpsJson -Value ([ordered]@{ outbounds=@(
        [ordered]@{type='vless';tag='Existing-IPv4';server='192.0.2.9'},[ordered]@{type='direct';tag='DIRECT'},[ordered]@{type='block';tag='BLOCK'},
        [ordered]@{type='selector';tag='US-West Entry';outbounds=@('Existing-IPv4')},
        [ordered]@{type='selector';tag='Europe Entry';outbounds=@('Existing-IPv4')}
    ); route=[ordered]@{rules=@()} }) -Path $authorityJson
$pythonCommandForClient = Get-Command python.exe -ErrorAction SilentlyContinue
$clientBuilderAvailable = $false
if ($pythonCommandForClient) {
    $dependencyProbe = Invoke-VpsProcess -FilePath $pythonCommandForClient.Source -ArgumentList @('-c','import ruamel.yaml') -TimeoutSeconds 30
    $clientBuilderAvailable = $dependencyProbe.ExitCode -eq 0
}
if ($clientBuilderAvailable) {
$python = $pythonCommandForClient.Source
$merge = Invoke-VpsProcess -FilePath $python -ArgumentList @(
    (Join-Path $ProjectRoot 'scripts\merge_client_authority.py'),'--clash',$authorityYaml,'--sing-box',$authorityJson,
    '--fragments',$fragmentRoot,'--output',$outputRoot,'--roles','RealityEntry','--entry-group','US-West Entry'
) -TimeoutSeconds 60
Assert-True ($merge.ExitCode -eq 0) 'client authority candidate merge fixture succeeds'
$mergedJson = Get-Content -Raw (Join-Path $outputRoot 'sing-box-general.candidate.json') | ConvertFrom-Json -AsHashtable
Assert-True ((Get-Item (Join-Path $outputRoot 'sing-box-general.candidate.json')).Length -lt 4MB) 'legacy candidate merger keeps runtime JSON below the desktop IPC ceiling'
Assert-True ('Candidate-IPv4' -in @($mergedJson.outbounds.tag)) 'candidate merge adds sing-box outbound'
Assert-True ('Candidate-IPv4' -in @((@($mergedJson.outbounds | Where-Object tag -eq 'US-West Entry')[0]).outbounds)) 'candidate merge updates selected sing-box entry selector'
$removeRoot = Join-Path $candidateRoot 'remove-output'
$remove = Invoke-VpsProcess -FilePath $python -ArgumentList @(
    (Join-Path $ProjectRoot 'scripts\merge_client_authority.py'),'--clash',(Join-Path $outputRoot 'Clash_General.candidate.yaml'),
    '--sing-box',(Join-Path $outputRoot 'sing-box-general.candidate.json'),'--fragments',$fragmentRoot,'--output',$removeRoot,
    '--roles','','--remove-prefix','Candidate'
) -TimeoutSeconds 60
Assert-True ($remove.ExitCode -eq 0) 'decommission candidate removal fixture succeeds'
$removedJson = Get-Content -Raw (Join-Path $removeRoot 'sing-box-general.candidate.json') | ConvertFrom-Json -AsHashtable
Assert-True ('Candidate-IPv4' -notin @($removedJson.outbounds.tag)) 'decommission candidate removes matching sing-box outbound'

$designerOutput = Join-Path $candidateRoot 'designer-output'
$designerSpec = Join-Path $candidateRoot 'designer-spec.private.json'
$manualLanding = [ordered]@{
    name='Example Exit A IPv4';kind='landing';region_group=$null;transit_group='US-West Entry'
    clash=[ordered]@{name='Example Exit A IPv4';type='ss';server='192.0.2.2';port=34567;cipher='2022-blake3-aes-128-gcm';password='fixture';udp=$true;'dialer-proxy'='US-West Entry'}
    sing_box=[ordered]@{type='shadowsocks';tag='Example Exit A IPv4';server='192.0.2.2';server_port=34567;method='2022-blake3-aes-128-gcm';password='fixture';detour='US-West Entry'}
}
$designerSpecValue = [ordered]@{
    schema_version=1
    fragment_sources=@([ordered]@{fragment_dir=$fragmentRoot;role='RealityEntry';node_names=@('Candidate-IPv4');region_group='US-West Entry';transit_group=$null})
    manual_nodes=@($manualLanding)
    existing_node_refs=@([ordered]@{name='Existing-IPv4';kind='entry';region_group='US-West Entry';transit_group=$null})
    groups=@(
        [ordered]@{name='US-West Entry';members=@('Candidate-IPv4','Existing-IPv4')},
        [ordered]@{name='Default Exit';members=@('Example Exit A IPv4','US-West Entry','DIRECT')},
        [ordered]@{name='Direct Route';members=@('DIRECT','Default Exit')},
        [ordered]@{name='AI Services';members=@('Default Exit','US-West Entry','Example Exit A IPv4','Direct Route')}
    )
    remove_groups=@('Europe Entry')
    group_order=@('US-West Entry','Default Exit','Direct Route','AI Services')
}
Save-VpsJson -Value $designerSpecValue -Path $designerSpec -Private
$designer = Invoke-VpsProcess -FilePath $python -ArgumentList @(
    (Join-Path $ProjectRoot 'scripts\build_client_authority.py'),'--clash',$authorityYaml,'--sing-box',$authorityJson,
    '--spec',$designerSpec,'--output',$designerOutput
) -TimeoutSeconds 60
Assert-True ($designer.ExitCode -eq 0) 'independent client authority designer builds a candidate from managed and manual nodes'
$designerJson = Get-Content -Raw (Join-Path $designerOutput 'sing-box-general.candidate.json') | ConvertFrom-Json -AsHashtable
Assert-True ((Get-Item (Join-Path $designerOutput 'sing-box-general.candidate.json')).Length -lt 4MB) 'independent designer emits compact sing-box runtime JSON'
$designerEntry = @($designerJson.outbounds | Where-Object tag -eq 'US-West Entry')[0]
$designerLanding = @($designerJson.outbounds | Where-Object tag -eq 'Example Exit A IPv4')[0]
Assert-True (@($designerEntry.outbounds)[0] -eq 'Candidate-IPv4') 'regional entry order controls the selector first default'
Assert-True ('Existing-IPv4' -in @($designerEntry.outbounds)) 'existing authority node can be reused without re-entering credentials'
Assert-True ($designerLanding.detour -eq 'US-West Entry') 'landing detour follows the chosen regional entry group'
Assert-True ((@($designerJson.outbounds | Where-Object tag -eq 'Default Exit')[0]).default -eq 'Example Exit A IPv4') 'default exit first member is written as sing-box selector default'
Assert-True (-not @($designerJson.outbounds | Where-Object tag -eq 'Europe Entry').Count) 'disabled default region group is removed from the candidate'
$designerYamlText = Get-Content -Raw (Join-Path $designerOutput 'Clash_General.candidate.yaml')
Assert-True ($designerYamlText -match 'dialer-proxy:\s+US-West Entry') 'Clash landing node receives the matching dialer-proxy'
$cycleSpec = Get-Content -Raw -LiteralPath $designerSpec | ConvertFrom-Json -AsHashtable
$cycleSpec.groups = @([ordered]@{name='Cycle A';members=@('Cycle B')},[ordered]@{name='Cycle B';members=@('Cycle A')})
$cyclePath = Join-Path $candidateRoot 'cycle-spec.private.json'; Save-VpsJson -Value $cycleSpec -Path $cyclePath -Private
$cycle = Invoke-VpsProcess -FilePath $python -ArgumentList @(
    (Join-Path $ProjectRoot 'scripts\build_client_authority.py'),'--clash',$authorityYaml,'--sing-box',$authorityJson,
    '--spec',$cyclePath,'--output',(Join-Path $candidateRoot 'cycle-output')
) -TimeoutSeconds 60
Assert-True ($cycle.ExitCode -ne 0 -and $cycle.StdErr -match 'cycle') 'client authority designer rejects selector cycles before writing candidates'

$designerInstanceRoot = Join-Path $candidateRoot 'empty-instances'; [IO.Directory]::CreateDirectory($designerInstanceRoot)|Out-Null
$designerDryOutput = Join-Path $candidateRoot 'dry-output-root'
$designerDryInput = (@(
    'n','US-West Entry',$authorityYaml,$authorityJson,
    'n','1','1','','','n',$designerDryOutput
) -join [Environment]::NewLine) + [Environment]::NewLine
$designerDry = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile','-File',(Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),'-Mode','ClientConfig','-DryRun','-InstanceRoot',$designerInstanceRoot
) -InputText $designerDryInput -TimeoutSeconds 60
Assert-True ($designerDry.ExitCode -eq 0) 'independent ClientConfig mode completes a no-write DryRun without any managed VPS'
Assert-True ($designerDry.StdOut -match 'Existing-IPv4' -and $designerDry.StdOut -match 'DryRun') 'ClientConfig can reuse an existing authority node without re-entering credentials'
Assert-True (-not(Test-Path -LiteralPath $designerDryOutput)) 'ClientConfig DryRun writes no candidate directory'
}
else {
    Write-Host 'Client authority engine tests skipped: optional pinned ruamel.yaml dependency is not installed.' -ForegroundColor Yellow
    Assert-True (Test-Path -LiteralPath (Join-Path $ProjectRoot 'requirements-client-merge.txt')) 'optional client designer dependency manifest exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $ProjectRoot 'scripts\build_client_authority.py')) 'client designer remains discoverable when optional runtime is absent'
}
[IO.Directory]::Delete($maintenanceRoot, $true)

$backupCleanupRoot = Join-Path $ProjectRoot '.test-output\protocol-backup-cleanup-dryrun'
$backupCleanupPlan = New-TestMigrationSourceFixture -Template $realitySource -Root $backupCleanupRoot -ProtocolModule 'xray-reality'
$backupCleanupCandidate = Join-Path $backupCleanupRoot 'migration-backups\20260101-000000-Enable-RealityEntry'
[IO.Directory]::CreateDirectory($backupCleanupCandidate) | Out-Null
[IO.File]::WriteAllText((Join-Path $backupCleanupCandidate 'deployment-plan.json'), 'fixture')
$backupCleanupInput = (@('1', '5', '1', '0', 'DELETE-BACKUPS', '3') -join [Environment]::NewLine) + [Environment]::NewLine
$backupCleanupResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'Migrate', '-DryRun', '-PlanPath', $backupCleanupPlan
) -InputText $backupCleanupInput -TimeoutSeconds 60
Assert-True ($backupCleanupResult.ExitCode -eq 0) 'protocol backup cleanup DryRun exits cleanly'
Assert-True ($backupCleanupResult.StdOut -match 'DryRun' -and $backupCleanupResult.StdOut -match 'migration-backups') 'backup cleanup DryRun reports its bounded local scope'
Assert-True (Test-Path -LiteralPath $backupCleanupCandidate -PathType Container) 'backup cleanup DryRun deletes no local backup'
[IO.Directory]::Delete($backupCleanupRoot, $true)

$anyToRealityRoot = Join-Path $ProjectRoot '.test-output\migration-anytls-to-reality'
$anyToRealityPlan = New-TestMigrationSourceFixture -Template $anyTlsSource -Root $anyToRealityRoot -ProtocolModule 'sing-box-anytls'
$anyToRealityInput = (@('1', '1', '1', '', '1', '1', 'target.example.invalid', 'y', 'y', 'n', '1') -join [Environment]::NewLine) + [Environment]::NewLine
$anyToRealityResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'Migrate', '-DryRun', '-PlanPath', $anyToRealityPlan
) -InputText $anyToRealityInput -TimeoutSeconds 60
Assert-True ($anyToRealityResult.ExitCode -eq 0) 'existing AnyTLS plan can enter external Reality migration DryRun'
Assert-True ($anyToRealityResult.StdOut -match 'target-audit' -and $anyToRealityResult.StdOut -match 'xray-reality') 'AnyTLS to Reality DryRun selects target audit and Xray modules'
Assert-True ($anyToRealityResult.StdOut -notmatch '(?m)\ssing-box-anytls\s') 'AnyTLS to Reality DryRun excludes the source service module'
$networkTuneInput = (@('1', '1000', '', '1') -join [Environment]::NewLine) + [Environment]::NewLine
$networkTuneResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'TuneNetwork', '-DryRun', '-PlanPath', $anyToRealityPlan
) -InputText $networkTuneInput -TimeoutSeconds 60
Assert-True ($networkTuneResult.ExitCode -eq 0) 'standalone network tuning enters DryRun on an existing managed VPS'
Assert-True ($networkTuneResult.StdOut -notmatch '(?m)\snftables-transition\s') 'standalone network tuning DryRun does not include firewall application'
[IO.Directory]::Delete($anyToRealityRoot, $true)

$ssToAnyRoot = Join-Path $ProjectRoot '.test-output\migration-ss-to-anytls'
$ssToAnyPlan = New-TestMigrationSourceFixture -Template $shadowsocksSource -Root $ssToAnyRoot -ProtocolModule 'sing-box-shadowsocks'
$ssTokenPath = Join-Path $ssToAnyRoot 'cloudflare-certbot-token.private.txt'
[IO.File]::WriteAllText($ssTokenPath, 'fixture-token-value')
$ssToAnyInput = (@(
    '1', '1', '2', 'edge.example.invalid', 'www.example.invalid', 'y', '', 'fixture@example.invalid', $ssTokenPath, 'n', '1'
) -join [Environment]::NewLine) + [Environment]::NewLine
$ssToAnyResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'Migrate', '-DryRun', '-PlanPath', $ssToAnyPlan
) -InputText $ssToAnyInput -TimeoutSeconds 60
Assert-True ($ssToAnyResult.ExitCode -eq 0) 'existing Shadowsocks plan can enter AnyTLS migration DryRun'
Assert-True ($ssToAnyResult.StdOut -match 'certbot-dns' -and $ssToAnyResult.StdOut -match 'sing-box-anytls') 'Shadowsocks to AnyTLS DryRun selects certificate and AnyTLS modules'
Assert-True ($ssToAnyResult.StdOut -notmatch '(?m)\ssing-box-shadowsocks\s') 'Shadowsocks to AnyTLS DryRun excludes the source service module'
[IO.Directory]::Delete($ssToAnyRoot, $true)

$importRoot = Join-Path $ProjectRoot '.test-output\existing-import-dryrun-root'
$importArchive = Join-Path $importRoot 'ExampleProvider\ExistingImport'
$importKey = Join-Path $ProjectRoot '.test-output\existing-import-provider-key'
if (Test-Path -LiteralPath $importRoot) { [IO.Directory]::Delete($importRoot, $true) }
[IO.File]::WriteAllText($importKey, 'fixture-existing-key')
$importInput = (@(
    '', 'ExampleProvider', 'ExistingImport', 'Example-US.Imported', '192.0.2.90', '', '', '1', $importKey,
    '1', '1', '1000', '1'
) -join [Environment]::NewLine) + [Environment]::NewLine
$importResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'Import', '-DryRun', '-InstanceRoot', $importRoot
) -InputText $importInput -TimeoutSeconds 60
Assert-True ($importResult.ExitCode -eq 0) 'existing VPS import wizard supports a no-write DryRun without deployment-plan.json'
Assert-True ($importResult.StdErr -notmatch 'Exception|Error') 'existing VPS import DryRun reports no execution error'
$importSourceText = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'src\VpsDeploy.Import.ps1')
Assert-True ($importSourceText -match "SshKeyMode = 'ReuseExisting'" -and $importSourceText -match 'EnforceKeyOnlySsh = \$false') 'existing VPS import defaults to key reuse and preserves SSH authentication policy'
Assert-True ($importResult.StdOut -match '1000 Mbps' -and $importResult.StdOut -match 'MXH-VPS-Deploy') 'existing VPS import records nominal bandwidth and managed subdirectory layout'
Assert-True (-not (Test-Path -LiteralPath $importArchive)) 'existing VPS import DryRun creates no private archive or plan'
[IO.File]::Delete($importKey)

$directBackInput = 'b' + [Environment]::NewLine
$directBackResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'), '-Mode', 'New', '-DryRun'
) -InputText $directBackInput -TimeoutSeconds 60
Assert-True ($directBackResult.ExitCode -eq 0) 'direct New mode exits cleanly when backing out of its first field'
Assert-True ($directBackResult.StdOut -notmatch '__MXH_VPS_WIZARD_' -and $directBackResult.StdErr -notmatch '__MXH_VPS_WIZARD_') 'direct-mode back remains an internal control signal'

$mainMenuExitResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'), '-Mode', 'Interactive', '-DryRun'
) -InputText ("0" + [Environment]::NewLine) -TimeoutSeconds 60
Assert-True ($mainMenuExitResult.ExitCode -eq 0) 'main menu exits cleanly with zero'
$startVpsDeploySource = & $coreModule { (Get-Command Start-VpsDeploy).ScriptBlock.ToString() }
Assert-True ($startVpsDeploySource -match "-AllowBack\s+-BackLabel\s+'退出'") 'main menu exposes zero as its canonical exit'
Assert-True (([regex]::Matches($startVpsDeploySource, '退出')).Count -eq 1) 'main menu has no duplicate numbered exit'

$resumeFixture = (Join-Path $ProjectRoot 'tests\fixtures\dry-run-plan.json')
$resumeNavigationInput = (@('2', ('"' + $resumeFixture + '"'), '0', 'b', '0') -join [Environment]::NewLine) + [Environment]::NewLine
$resumeNavigationResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'), '-Mode', 'Interactive', '-DryRun'
) -InputText $resumeNavigationInput -TimeoutSeconds 60
Assert-True ($resumeNavigationResult.ExitCode -eq 0) 'resume summary returns to quoted plan-path selection and then to the main menu'
Assert-True ($resumeNavigationResult.StdOut -match 'ExampleInstance') 'resume path with surrounding quotes is normalized and loaded'

$cancelInstanceRoot = Join-Path $ProjectRoot '.test-output\wizard-cancel-root'
$cancelArchive = Join-Path $cancelInstanceRoot 'ExampleProvider\CancelAtSummary'
$cancelInput = (@(
    '1', '', 'ExampleProvider', 'CancelAtSummary', '', '192.0.2.62', '', '', '1', '4', '', 'n', 'n', '3', '0'
) -join [Environment]::NewLine) + [Environment]::NewLine
$cancelResult = Invoke-VpsProcess -FilePath $pwshPath -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $ProjectRoot 'Start-VPSDeploy.ps1'),
    '-Mode', 'Interactive', '-DryRun', '-InstanceRoot', $cancelInstanceRoot
) -InputText $cancelInput -TimeoutSeconds 60
Assert-True ($cancelResult.ExitCode -eq 0) 'summary cancellation returns to the main menu without an error pause'
Assert-True (-not (Test-Path -LiteralPath $cancelArchive)) 'summary cancellation writes no plan, credentials, or instance archive'
Assert-True ($cancelResult.StdOut -notmatch '__MXH_VPS_WIZARD_' -and $cancelResult.StdErr -notmatch '__MXH_VPS_WIZARD_') 'summary cancellation marker never leaks to the console'

$preExecutionContext = [pscustomobject]@{
    ProjectRoot = $ProjectRoot
    Plan = [ordered]@{ Role = 'AuditOnly' }
    State = [ordered]@{ Modules = @{} }
    DryRun = $false
    NonInteractive = $false
}
$preExecutionBack = & $coreModule {
    param($Context)
    function Read-Host { param([string]$Prompt); return 'b' }
    try {
        Invoke-VpsModulePipeline -Context $Context -OnlyModule @('audit')
        return '<no-navigation-signal>'
    }
    catch { return $_.Exception.Message }
    finally { Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue }
} $preExecutionContext 6>$null
Assert-True ($preExecutionBack -eq '__MXH_VPS_WIZARD_BACK__') 'final pre-execution confirmation can return before any remote module starts'
Assert-True ($preExecutionContext.State.Modules.Count -eq 0) 'pre-execution back leaves every module untouched'

$testOutputRoot = Join-Path $ProjectRoot '.test-output'
if (Test-Path -LiteralPath $testOutputRoot) {
    $remainingTestOutput = @(Get-ChildItem -LiteralPath $testOutputRoot -Force)
    if ($remainingTestOutput.Count -eq 0) { [IO.Directory]::Delete($testOutputRoot, $false) }
}

Write-Host '== Secret scan ==' -ForegroundColor Cyan
& (Join-Path $ProjectRoot 'scripts\Test-NoSecrets.ps1') -ProjectRoot $ProjectRoot
Assert-True $true 'secret scan'

Write-Host "All tests passed: $passed assertions" -ForegroundColor Green
