@{
    Id        = 'protocol-lifecycle-state'
    Name      = '切换已安装协议的启用状态'
    Order     = 53
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    Requires  = @('migration-arm-rollback')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled -and
        [string]$Context.Plan.Migration.Operation -in @('Enable', 'Disable')
    }
    Invoke    = {
        param($Context)
        $inventory = $Context.Plan.Migration.FinalInventory
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-lifecycle-apply-state.sh' -Parameters @{
            REALITY_ENABLED = ([bool]$inventory.RealityEntry.Enabled).ToString().ToLowerInvariant()
            ANYTLS_ENABLED = ([bool]$inventory.AnyTlsEntry.Enabled).ToString().ToLowerInvariant()
            SHADOWSOCKS_ENABLED = ([bool]$inventory.ShadowsocksLanding.Enabled).ToString().ToLowerInvariant()
        } -TimeoutSeconds 300
        if ($result.StdOut -notmatch 'VPSDEPLOY_PROTOCOL_STATE_APPLIED') {
            throw '远端未返回协议状态切换成功标记。'
        }
        $Context.State.Migration.Status = 'StateApplied'
        Save-VpsContext -Context $Context
    }
}
