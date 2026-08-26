@{
    Id        = 'private-archive'
    Name      = '下载配置并生成最终私有归档'
    Order     = 120
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-cutover')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $serverDir = Join-Path $Context.ArchivePath 'server-configs'
        $realityInstalled = Test-MxhProtocolInstalled -Plan $Context.Plan -Role 'RealityEntry'
        $anyTlsInstalled = Test-MxhProtocolInstalled -Plan $Context.Plan -Role 'AnyTlsEntry'
        $shadowsocksInstalled = Test-MxhProtocolInstalled -Plan $Context.Plan -Role 'ShadowsocksLanding'
        $importedExisting = $Context.Plan.Contains('Import') -and [bool]$Context.Plan.Import.Enabled
        $downloads = [ordered]@{ '/etc/ssh/sshd_config' = (Join-Path $serverDir 'sshd_config') }
        if ($importedExisting) {
            if ($Context.Plan.Import.Contains('ManagedKeyOnlyDropIn') -and [bool]$Context.Plan.Import.ManagedKeyOnlyDropIn) {
                $downloads['/etc/ssh/sshd_config.d/00-00-mxh-import-key-only.conf'] = Join-Path $serverDir 'sshd-00-00-mxh-import-key-only.conf'
            }
            if ($Context.State.Audit.NftRuleLines -gt 0) { $downloads['/etc/nftables.conf'] = Join-Path $serverDir 'nftables.conf' }
            if ($Context.State.Contains('NetworkTuning')) {
                $downloads['/etc/sysctl.d/99-mxh-vps-deploy.conf'] = Join-Path $serverDir 'sysctl-99-mxh-vps-deploy.conf'
            }
        }
        else {
            $downloads['/etc/ssh/sshd_config.d/00-00-local-access.conf'] = Join-Path $serverDir 'sshd-00-00-local-access.conf'
            $downloads['/etc/nftables.conf'] = Join-Path $serverDir 'nftables.conf'
            $downloads['/etc/sysctl.d/99-mxh-vps-deploy.conf'] = Join-Path $serverDir 'sysctl-99-mxh-vps-deploy.conf'
        }
        if ($realityInstalled) {
            $downloads['/usr/local/etc/xray/config.json'] = Join-Path $serverDir 'xray-config.json'
            if ($Context.Plan.Reality.Contains('TargetMode') -and $Context.Plan.Reality.TargetMode -eq 'LocalOwnedTls') {
                $downloads['/etc/nginx/sites-available/mxh-reality-target'] = Join-Path $serverDir 'nginx-reality-target.conf'
                $downloads['/etc/mxh-tls/reality-target/fullchain.pem'] = Join-Path $serverDir 'reality-target-fullchain.pem'
                $downloads['/etc/mxh-tls/reality-target/privkey.pem'] = Join-Path $serverDir 'reality-target-privkey.private.pem'
            }
        }
        if ($anyTlsInstalled) {
            $downloads['/etc/sing-box-anytls/config.json'] = Join-Path $serverDir 'sing-box-anytls-config.private.json'
            $downloads['/etc/sing-box-anytls/ech-key.pem'] = Join-Path $serverDir 'anytls-ech-key.private.pem'
            $downloads['/etc/sing-box-anytls/ech-config.pem'] = Join-Path $serverDir 'anytls-ech-client-config.pem'
            $downloads['/etc/systemd/system/sing-box-anytls.service'] = Join-Path $serverDir 'sing-box-anytls.service'
            $downloads['/etc/mxh-tls/anytls/fullchain.pem'] = Join-Path $serverDir 'anytls-fullchain.pem'
            $downloads['/etc/mxh-tls/anytls/privkey.pem'] = Join-Path $serverDir 'anytls-privkey.private.pem'
        }
        if ($shadowsocksInstalled) {
            $downloads['/etc/sing-box/config.json'] = Join-Path $serverDir 'sing-box-config.private.json'
            $downloads['/etc/systemd/system/sing-box.service'] = Join-Path $serverDir 'sing-box.service'
            if ($Context.Plan.Shadowsocks.SecondaryBindInterface) {
                $downloads['/etc/systemd/system/sing-box.service.d/20-bind-interface-capability.conf'] = Join-Path $serverDir 'sing-box-bind-interface-capability.conf'
            }
        }
        if ($Context.Plan.Komari.Enabled) {
            $downloads['/etc/komari-agent/config.json'] = Join-Path $serverDir 'komari-agent-config.private.json'
            $downloads['/etc/systemd/system/komari-agent.service'] = Join-Path $serverDir 'komari-agent.service'
        }
        if ($Context.Plan.Contains('TrustedTls') -and [bool]$Context.Plan.TrustedTls.Enabled) {
            $downloads['/etc/systemd/system/mxh-certbot-renew.service'] = Join-Path $serverDir 'mxh-certbot-renew.service'
            $downloads['/etc/systemd/system/mxh-certbot-renew.timer'] = Join-Path $serverDir 'mxh-certbot-renew.timer'
            $downloads['/usr/local/libexec/mxh-certbot-deploy'] = Join-Path $serverDir 'mxh-certbot-deploy'
        }
        foreach ($remote in $downloads.Keys) {
            Invoke-VpsScpDownload -Context $Context -RemotePath $remote -LocalPath $downloads[$remote]
        }

        $s = if ($realityInstalled) { $Context.Secrets.Xray } else { $null }
        $archivePath = Join-Path $Context.ArchivePath ($Context.Plan.NodeName + '-final-archive.txt')
        $bootstrapAuth = if ($Context.Plan.Server.Contains('BootstrapAuth')) { $Context.Plan.Server.BootstrapAuth } else { 'Password' }
        $bootstrapKeyPath = if ($Context.Plan.Server.Contains('BootstrapKeyPath')) { $Context.Plan.Server.BootstrapKeyPath } else { $null }
        $xrayBlock = if ($realityInstalled) {
            $targetSettings = Get-MxhRealityTargetSettings -Plan $Context.Plan
@"
Xray Version: $($Context.Plan.Reality.XrayVersion)
Xray Primary Port: $($Context.Plan.Ports.XrayPrimary)
Xray Rescue Port: $($Context.Plan.Ports.XrayBackup)
Reality Target Mode: $($targetSettings.Mode)
Reality Target Address: $($targetSettings.TargetAddress)
Reality Server Name: $($targetSettings.ServerName)
UUID: $($s.Uuid)
Reality PrivateKey: $($s.RealityPrivateKey)
Reality ClientKey: $($s.RealityClientKey)
Short ID: $($s.ShortId)
Force IPv4 Egress: $($Context.Plan.Reality.ForceIpv4Egress)
Reality Egress Test: $($Context.State.RealityEgressTest | ConvertTo-Json -Compress -Depth 5)
"@
        }
        else { 'Xray: Not installed by this deployment role.' }
        $anyTlsBlock = if ($anyTlsInstalled) {
            $anyTls = $Context.Secrets.AnyTls
@"
sing-box AnyTLS Version: $($Context.Plan.AnyTls.SingBoxVersion)
AnyTLS Port: $($Context.Plan.Ports.AnyTlsPrimary)
AnyTLS Server Name: $($Context.Plan.AnyTls.ServerName)
ECH Public Name: $($Context.Plan.AnyTls.EchPublicName)
AnyTLS Password: $($anyTls.Password)
ECH Server Key PEM: $($anyTls.EchServerKeyPem)
ECH Client Config PEM: $($anyTls.EchClientConfigPem)
ECH Client Config Base64: $($anyTls.EchClientConfigBase64)
Force IPv4 Egress: $($Context.Plan.AnyTls.ForceIpv4Egress)
Padding Scheme Mode: $(if ($Context.Plan.AnyTls.Contains('PaddingSchemeMode')) { $Context.Plan.AnyTls.PaddingSchemeMode } else { 'OfficialDefault' })
Padding Scheme: $((Get-MxhAnyTlsPaddingScheme -Plan $Context.Plan) | ConvertTo-Json -Compress)
AnyTLS Validation: $($Context.State.AnyTls | ConvertTo-Json -Compress -Depth 8)
AnyTLS Client Egress Test: $($Context.State.AnyTlsEgressTest | ConvertTo-Json -Compress -Depth 5)
"@
        }
        else { 'AnyTLS: Not installed by this deployment role.' }
        $shadowsocksBlock = if ($shadowsocksInstalled) {
            $ss = $Context.Secrets.Shadowsocks
            $primaryPassword = ([string]$ss.ServerKey) + ':' + ([string]$ss.PrimaryUserKey)
            $secondaryPassword = if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
                ([string]$ss.ServerKey) + ':' + ([string]$ss.SecondaryUserKey)
            }
            else { '<disabled>' }
@"
sing-box Version: $($Context.Plan.Shadowsocks.SingBoxVersion)
Shadowsocks Port: $($Context.Plan.Ports.LandingShadowsocks) TCP+UDP
Shadowsocks Method: $($Context.Plan.Shadowsocks.Method)
Server Key: $($ss.ServerKey)
Primary IPv4 User Key: $($ss.PrimaryUserKey)
Primary Client Password: $primaryPassword
Secondary IPv6 Enabled: $($Context.Plan.Shadowsocks.SecondaryIpv6Enabled)
Secondary IPv6 User Key: $($ss.SecondaryUserKey)
Secondary Client Password: $secondaryPassword
Secondary IPv6 Address: $($Context.Plan.Shadowsocks.SecondaryIpv6Address)
Secondary Bind Interface: $($Context.Plan.Shadowsocks.SecondaryBindInterface)
Trusted Entry IPv4: $(@($Context.Plan.Shadowsocks.TrustedEntryIPv4s) -join ',')
Trusted Entry IPv6: $(@($Context.Plan.Shadowsocks.TrustedEntryIPv6s) -join ',')
Client Transit Tag: $($Context.Plan.Shadowsocks.ClientTransitTag)
Server Self Test: $($Context.State.ShadowsocksSelfTest | ConvertTo-Json -Compress -Depth 5)
"@
        }
        else { 'Shadowsocks: Not installed by this deployment role.' }
        $networkTuningBlock = if ($Context.State.Contains('NetworkTuning')) {
            'Network Tuning: ' + ($Context.State.NetworkTuning | ConvertTo-Json -Compress -Depth 8)
        }
        else {
            'Network Tuning: Not recorded.'
        }
        $migrationBlock = if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) {
@"
Protocol Lifecycle Operation: $(if ($Context.Plan.Migration.Contains('Operation')) { $Context.Plan.Migration.Operation } else { 'LegacyConversion' })
Lifecycle Target: $($Context.Plan.Migration.TargetRole)
Lifecycle Status: $($Context.State.Migration.Status)
Local Pre-Change Backup: $($Context.Plan.Migration.LocalBackupDirectory)
Remote Rollback Backup: $($Context.State.Migration.RemoteBackupDirectory)
"@
        }
        else { 'Protocol Migration: Not applicable.' }
        $content = @"
MXH VPS DEPLOY - PRIVATE FINAL ARCHIVE
Generated: $((Get-Date).ToString('o'))

Provider: $($Context.Plan.Provider)
Instance: $($Context.Plan.Instance)
Node Name: $($Context.Plan.NodeName)
Role: $($Context.Plan.Role)
Protocol Inventory: $($Context.Plan.ProtocolInventory | ConvertTo-Json -Compress -Depth 8)
IPv4: $($Context.Plan.Server.IPv4)
IPv6: $($Context.Plan.Server.IPv6)

SSH Admin User: $($Context.Plan.AdminUser)
Bootstrap Authentication: $bootstrapAuth
Bootstrap Existing Key Path: $bootstrapKeyPath
SSH Primary Port: $($Context.Plan.Ports.SshPrimary)
SSH Rescue Port: $($Context.Plan.Ports.SshRescue)
Bootstrap SSH Port Removed: $($Context.State.BootstrapSshRemoved)
Admin sudo password: $($Context.Secrets.AdminPassword)
SSH private key: $(Get-VpsSshKeyPath $Context)

$xrayBlock

$anyTlsBlock

$shadowsocksBlock

$networkTuningBlock

$migrationBlock

Komari Enabled: $($Context.Plan.Komari.Enabled)
Komari Endpoint: $($Context.Plan.Komari.Endpoint)
Komari Agent Version: $($Context.Plan.Komari.AgentVersion)

Server config snapshots: $serverDir
Client exports: $(Join-Path $Context.ArchivePath 'client-exports')
Target audit: $(if ($realityInstalled -and (-not $Context.Plan.Reality.Contains('TargetMode') -or $Context.Plan.Reality.TargetMode -ne 'LocalOwnedTls')) { Join-Path $Context.ArchivePath 'target-audit.json' } else { '<not applicable>' })
Deployment plan: $($Context.PlanPath)
Deployment state: $($Context.StatePath)
Remote backup directories: $($Context.State.BackupDirectories | ConvertTo-Json -Compress -Depth 8)

SECURITY: This file contains active credentials. Keep it only in local private archives.
"@
        [IO.File]::WriteAllText($archivePath, $content, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $archivePath

        $Context.State.FinalArchive = $archivePath
        if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled -and
            $Context.State.Contains('Migration') -and [bool]$Context.State.Migration.Committed) {
            $Context.State.Migration.Status = 'Completed'
            $Context.State.Migration.CompletedAt = (Get-Date).ToString('o')
            $Context.Plan.Migration.Status = 'Completed'
            Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
        }
        Save-VpsContext -Context $Context

        $checksumPath = Join-Path $Context.ArchivePath 'SHA256SUMS-private.txt'
        $files = Get-ChildItem -LiteralPath $Context.ArchivePath -File -Recurse | Where-Object FullName -ne $checksumPath
        $lines = foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($Context.ArchivePath, $file.FullName).Replace('\', '/')
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
        [IO.File]::WriteAllText($checksumPath, (($lines | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $checksumPath
    }
}
