@{
    Id        = 'nftables-transition'
    Name      = '应用保留旧 SSH 的过渡 nftables'
    Order     = 70
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $preserveExisting = $Context.Plan.Contains('Firewall') -and $Context.Plan.Firewall.Contains('Mode') -and
            $Context.Plan.Firewall.Mode -eq 'PreserveExisting'
        if (-not $preserveExisting -and ($Context.State.Audit.ExistingServices -or [int]$Context.State.Audit.NftRuleLines -gt 0)) {
            throw '初始审计不是干净主机，拒绝套用 flush ruleset 模板。'
        }
        $inventory = if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled -and
            $Context.Plan.Migration.Contains('ValidationInventory')) {
            $Context.Plan.Migration.ValidationInventory
        } else {
            Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
        }
        Invoke-MxhProtocolFirewall -Context $Context -Inventory $inventory -BackupStateName 'NftablesTransition'

        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "加载防火墙后 root 无法连接 SSH $port。初始端口仍在规则中。"
            }
            if ($Context.Plan.AdminUser -ne 'root' -and -not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
                throw "加载防火墙后 admin sudo 在 SSH $port 失败。"
            }
        }
        if ([bool]$inventory.ShadowsocksLanding.Enabled) {
            Write-VpsUi '落地端口已按可信入口 IP 同时限制 TCP 和 UDP；本机回环自测不受该白名单影响。' Success
        }
    }
}
