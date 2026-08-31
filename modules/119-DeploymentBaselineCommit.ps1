@{
    Id        = 'deployment-baseline-commit'
    Name      = '提交部署并删除统一回滚快照'
    Order     = 119
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly', 'AuditOnly')
    Requires  = @('deployment-baseline')
    IsEnabled = {
        param($Context)
        -not ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) -and
            $Context.Plan.Contains('DeploymentTransaction') -and
            (-not $Context.State.Contains('DeploymentTransaction') -or
                [string]$Context.State.DeploymentTransaction.Status -ne 'Committed')
    }
    Invoke    = {
        param($Context)
        if (-not $Context.State.Contains('DeploymentTransaction') -or
            [string]$Context.State.DeploymentTransaction.Status -ne 'Armed') {
            throw '统一回滚基线尚未建立或状态不可提交，拒绝删除快照。'
        }
        $requiredModule = if ([string]$Context.Plan.Role -eq 'AuditOnly') { 'audit' } else { 'ssh-cutover' }
        if (-not $Context.State.Contains('Modules') -or
            -not $Context.State.Modules.Contains($requiredModule) -or
            [string]$Context.State.Modules[$requiredModule].Status -ne 'Success') {
            throw "部署事务尚未通过 $requiredModule，拒绝提前删除统一回滚快照。"
        }
        $remote = [string]$Context.State.DeploymentTransaction.RemoteBaselineDirectory
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'deployment-snapshot-delete.sh' -Parameters @{
            SNAPSHOT_DIR = $remote
            KIND = 'deployment-committed'
        } -TimeoutSeconds 180 -SensitiveOutput -ProgressActivity '提交部署并删除统一回滚快照'
        if ($result.StdOut -notmatch 'VPSDEPLOY_SNAPSHOT_DELETE_OK') { throw '部署已验收，但统一回滚快照删除未确认；保留计划并继续未完成部署重试。' }
        $Context.State.DeploymentTransaction.Status = 'Committed'
        $Context.State.DeploymentTransaction.RemoteBaselineDirectory = $null
        $Context.State.DeploymentTransaction.CommittedAt = (Get-Date).ToString('o')
        Save-VpsContext -Context $Context
    }
}
