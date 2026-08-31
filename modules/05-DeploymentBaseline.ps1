@{
    Id        = 'deployment-baseline'
    Name      = '建立部署前统一回滚基线'
    Order     = 5
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly', 'AuditOnly')
    Requires  = @('bootstrap-access')
    IsEnabled = {
        param($Context)
        -not ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) -and
            $Context.Plan.Contains('DeploymentTransaction') -and
            (-not $Context.State.Contains('DeploymentTransaction') -or
                [string]$Context.State.DeploymentTransaction.Status -ne 'Committed')
    }
    Invoke    = {
        param($Context)
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'deployment-baseline-arm.sh' -Parameters @{
            TRANSACTION_ID = [string]$Context.Plan.DeploymentTransaction.Id
            ADMIN_USER = [string]$Context.Plan.AdminUser
        } -TimeoutSeconds 600 -SensitiveOutput -AllowFailure -ProgressActivity '建立部署前统一回滚基线'
        if ($result.ExitCode -ne 0) {
            $details = ([string]$result.StdOut) + "`n" + ([string]$result.StdErr)
            $match = [regex]::Match($details, '(?m)^VPSDEPLOY_BASELINE_FAILURE_PHASE=([a-z-]+)$')
            $phase = if ($match.Success) { $match.Groups[1].Value } else { 'unknown' }
            throw "部署前统一回滚基线建立失败（阶段：$phase；敏感详情仅保存在私有日志）。"
        }
        if ($result.StdOut -notmatch 'VPSDEPLOY_DEPLOYMENT_BASELINE_OK') { throw '部署前统一回滚基线未返回成功标记。' }
        $remote = Get-VpsMarkerValue $result.StdOut BASELINE_DIR -Required
        $Context.State.DeploymentTransaction = [ordered]@{
            Id = [string]$Context.Plan.DeploymentTransaction.Id
            Status = 'Armed'
            RemoteBaselineDirectory = $remote
            RecoveryKeyPreserved = $true
            PackageResiduePolicy = 'PreserveInstalledPackages'
            ArmedAt = (Get-Date).ToString('o')
        }
        Save-VpsContext -Context $Context
    }
}
