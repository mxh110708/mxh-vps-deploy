@{
    Id        = 'migration-preflight'
    Name      = '现有协议生命周期变更前置审计'
    Order     = 35
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-transition')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "协议变更前 root SSH $port 复验失败。"
            }
            if ($Context.Plan.AdminUser -ne 'root' -and
                -not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
                throw "协议变更前 admin sudo SSH $port 复验失败。"
            }
        }
        $initial = if ($Context.Plan.Migration.Contains('InitialInventory')) {
            $Context.Plan.Migration.InitialInventory
        }
        else {
            Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-preflight.sh' -Parameters @{
            SOURCE_ROLE = [string]$Context.Plan.Migration.SourceRole
            TARGET_ROLE = [string]$Context.Plan.Migration.TargetRole
            SOURCE_PORT = [string]$Context.Plan.Migration.SourcePrimaryPort
            SSH_PRIMARY = [string]$Context.Plan.Ports.SshPrimary
            SSH_RESCUE = [string]$Context.Plan.Ports.SshRescue
            REALITY_INSTALLED = ([bool]$initial.RealityEntry.Installed).ToString().ToLowerInvariant()
            REALITY_ENABLED = ([bool]$initial.RealityEntry.Enabled).ToString().ToLowerInvariant()
            ANYTLS_INSTALLED = ([bool]$initial.AnyTlsEntry.Installed).ToString().ToLowerInvariant()
            ANYTLS_ENABLED = ([bool]$initial.AnyTlsEntry.Enabled).ToString().ToLowerInvariant()
            SHADOWSOCKS_INSTALLED = ([bool]$initial.ShadowsocksLanding.Installed).ToString().ToLowerInvariant()
            SHADOWSOCKS_ENABLED = ([bool]$initial.ShadowsocksLanding.Enabled).ToString().ToLowerInvariant()
            XRAY_BACKUP_PORT = if ($Context.Plan.Ports.XrayBackup) { [string]$Context.Plan.Ports.XrayBackup } else { '' }
            SHADOWSOCKS_PORT = if ($Context.Plan.Ports.LandingShadowsocks) { [string]$Context.Plan.Ports.LandingShadowsocks } else { '' }
        } -TimeoutSeconds 300
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_PREFLIGHT_OK') {
            throw '协议生命周期变更前置审计未返回成功标记。'
        }
        $Context.State.Migration.Status = 'PreflightPassed'
        $Context.State.Migration.PreflightAt = (Get-Date).ToString('o')
        Save-VpsContext -Context $Context
    }
}
