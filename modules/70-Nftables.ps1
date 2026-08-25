@{
    Id        = 'nftables-transition'
    Name      = '应用保留旧 SSH 的过渡 nftables'
    Order     = 70
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        if ($Context.State.Audit.ExistingServices -or [int]$Context.State.Audit.NftRuleLines -gt 0) {
            throw '初始审计不是干净主机，拒绝套用 flush ruleset 模板。'
        }
        $ports = @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)
        $bootstrapRemoved = $Context.State.Contains('BootstrapSshRemoved') -and [bool]$Context.State.BootstrapSshRemoved
        if (-not $bootstrapRemoved) { $ports += [int]$Context.Plan.Server.BootstrapSshPort }
        if ($Context.Plan.Role -eq 'RealityEntry') {
            $ports += [int]$Context.Plan.Ports.XrayPrimary
            $ports += [int]$Context.Plan.Ports.XrayBackup
        }
        elseif ($Context.Plan.Role -eq 'AnyTlsEntry') {
            $ports += [int]$Context.Plan.Ports.AnyTlsPrimary
        }
        $ports = @($ports | Sort-Object -Unique)
        $nftParameters = @{
            TCP_PORTS = ($ports -join ',')
            RESTRICTED_PORT = ''
            ALLOWED_IPV4S = ''
            ALLOWED_IPV6S = ''
        }
        if ($Context.Plan.Role -eq 'ShadowsocksLanding') {
            $nftParameters.RESTRICTED_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
            $nftParameters.ALLOWED_IPV4S = (@($Context.Plan.Shadowsocks.TrustedEntryIPv4s) -join ',')
            $nftParameters.ALLOWED_IPV6S = (@($Context.Plan.Shadowsocks.TrustedEntryIPv6s) -join ',')
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'nftables-apply.sh' `
            -Parameters $nftParameters
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.NftablesTransition = $backup
        Save-VpsContext -Context $Context

        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "加载防火墙后 root 无法连接 SSH $port。初始端口仍在规则中。"
            }
            if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
                throw "加载防火墙后 admin sudo 在 SSH $port 失败。"
            }
        }
        if ($Context.Plan.Role -eq 'ShadowsocksLanding') {
            Write-VpsUi '落地端口已按可信入口 IP 同时限制 TCP 和 UDP；本机回环自测不受该白名单影响。' Success
        }
    }
}
