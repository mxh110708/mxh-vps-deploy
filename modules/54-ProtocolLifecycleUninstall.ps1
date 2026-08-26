@{
    Id        = 'protocol-lifecycle-uninstall'
    Name      = '卸载已停用的协议运行时与配置'
    Order     = 54
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    Requires  = @('migration-arm-rollback')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled -and
        [string]$Context.Plan.Migration.Operation -eq 'Uninstall'
    }
    Invoke    = {
        param($Context)
        $role = [string]$Context.Plan.Migration.RemoveRole
        if ([bool]$Context.Plan.Migration.InitialInventory[$role].Enabled) {
            throw '安全限制：协议仍处于启用状态，必须先单独停用或切换，再执行卸载。'
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-lifecycle-uninstall.sh' -Parameters @{
            REMOVE_ROLE = $role
        } -TimeoutSeconds 300
        if ($result.StdOut -notmatch 'VPSDEPLOY_PROTOCOL_UNINSTALLED') {
            throw '远端未返回协议卸载成功标记。'
        }
        $Context.State.Migration.Status = 'RuntimeRemoved'
        Save-VpsContext -Context $Context
    }
}
