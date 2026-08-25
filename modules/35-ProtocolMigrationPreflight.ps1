@{
    Id        = 'migration-preflight'
    Name      = '现有协议迁移前置审计'
    Order     = 35
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    Requires  = @('ssh-transition')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "迁移前 root SSH $port 复验失败。"
            }
            if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
                throw "迁移前 admin sudo SSH $port 复验失败。"
            }
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-preflight.sh' -Parameters @{
            SOURCE_ROLE = [string]$Context.Plan.Migration.SourceRole
            TARGET_ROLE = [string]$Context.Plan.Migration.TargetRole
            SOURCE_PORT = [string]$Context.Plan.Migration.SourcePrimaryPort
            SSH_PRIMARY = [string]$Context.Plan.Ports.SshPrimary
            SSH_RESCUE = [string]$Context.Plan.Ports.SshRescue
        } -TimeoutSeconds 300
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_PREFLIGHT_OK') {
            throw '协议迁移前置审计未返回成功标记。'
        }
        $Context.State.Migration.Status = 'PreflightPassed'
        $Context.State.Migration.PreflightAt = (Get-Date).ToString('o')
        Save-VpsContext -Context $Context
    }
}
