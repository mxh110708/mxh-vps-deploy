@{
    Id        = 'protocol-lifecycle-final-firewall'
    Name      = '收口为协议变更后的最终防火墙状态'
    Order     = 114
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    Requires  = @('final-validation')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        $inventory = $Context.Plan.Migration.FinalInventory
        Invoke-MxhProtocolFirewall -Context $Context -Inventory $inventory -BackupStateName 'ProtocolLifecycleFinalFirewall'
        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "最终防火墙加载后 root SSH $port 复验失败。"
            }
        }
    }
}
