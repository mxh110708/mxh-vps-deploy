@{
    Id        = 'private-archive'
    Name      = '下载配置并生成最终私有归档'
    Order     = 120
    Roles     = @('RealityEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-cutover')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $serverDir = Join-Path $Context.ArchivePath 'server-configs'
        $downloads = [ordered]@{
            '/etc/ssh/sshd_config' = (Join-Path $serverDir 'sshd_config')
            '/etc/ssh/sshd_config.d/00-00-local-access.conf' = (Join-Path $serverDir 'sshd-00-00-local-access.conf')
            '/etc/nftables.conf' = (Join-Path $serverDir 'nftables.conf')
            '/etc/sysctl.d/99-mxh-vps-deploy.conf' = (Join-Path $serverDir 'sysctl-99-mxh-vps-deploy.conf')
        }
        if ($Context.Plan.Role -eq 'RealityEntry') {
            $downloads['/usr/local/etc/xray/config.json'] = Join-Path $serverDir 'xray-config.json'
        }
        elseif ($Context.Plan.Role -eq 'ShadowsocksLanding') {
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
        foreach ($remote in $downloads.Keys) {
            Invoke-VpsScpDownload -Context $Context -RemotePath $remote -LocalPath $downloads[$remote]
        }

        $s = $Context.Secrets.Xray
        $archivePath = Join-Path $Context.ArchivePath ($Context.Plan.NodeName + '-final-archive.txt')
        $bootstrapAuth = if ($Context.Plan.Server.Contains('BootstrapAuth')) { $Context.Plan.Server.BootstrapAuth } else { 'Password' }
        $bootstrapKeyPath = if ($Context.Plan.Server.Contains('BootstrapKeyPath')) { $Context.Plan.Server.BootstrapKeyPath } else { $null }
        $xrayBlock = if ($Context.Plan.Role -eq 'RealityEntry') {
@"
Xray Version: $($Context.Plan.Reality.XrayVersion)
Xray Primary Port: $($Context.Plan.Ports.XrayPrimary)
Xray Rescue Port: $($Context.Plan.Ports.XrayBackup)
Reality Target: $($Context.Plan.Reality.Target)
UUID: $($s.Uuid)
Reality PrivateKey: $($s.RealityPrivateKey)
Reality ClientKey: $($s.RealityClientKey)
Short ID: $($s.ShortId)
Force IPv4 Egress: $($Context.Plan.Reality.ForceIpv4Egress)
Reality Egress Test: $($Context.State.RealityEgressTest | ConvertTo-Json -Compress -Depth 5)
"@
        }
        else { 'Xray: Not installed by this deployment role.' }
        $shadowsocksBlock = if ($Context.Plan.Role -eq 'ShadowsocksLanding') {
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
        $content = @"
MXH VPS DEPLOY - PRIVATE FINAL ARCHIVE
Generated: $((Get-Date).ToString('o'))

Provider: $($Context.Plan.Provider)
Instance: $($Context.Plan.Instance)
Node Name: $($Context.Plan.NodeName)
Role: $($Context.Plan.Role)
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

$shadowsocksBlock

$networkTuningBlock

Komari Enabled: $($Context.Plan.Komari.Enabled)
Komari Endpoint: $($Context.Plan.Komari.Endpoint)
Komari Agent Version: $($Context.Plan.Komari.AgentVersion)

Server config snapshots: $serverDir
Client exports: $(Join-Path $Context.ArchivePath 'client-exports')
Target audit: $(if ($Context.Plan.Role -eq 'RealityEntry') { Join-Path $Context.ArchivePath 'target-audit.json' } else { '<not applicable>' })
Deployment plan: $($Context.PlanPath)
Deployment state: $($Context.StatePath)
Remote backup directories: $($Context.State.BackupDirectories | ConvertTo-Json -Compress -Depth 8)

SECURITY: This file contains active credentials. Keep it only in local private archives.
"@
        [IO.File]::WriteAllText($archivePath, $content, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $archivePath

        $checksumPath = Join-Path $Context.ArchivePath 'SHA256SUMS-private.txt'
        $files = Get-ChildItem -LiteralPath $Context.ArchivePath -File -Recurse | Where-Object FullName -ne $checksumPath
        $lines = foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($Context.ArchivePath, $file.FullName).Replace('\', '/')
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
        [IO.File]::WriteAllText($checksumPath, (($lines | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $checksumPath
        $Context.State.FinalArchive = $archivePath
        Save-VpsContext -Context $Context
    }
}
