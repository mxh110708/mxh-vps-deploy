@{
    Id        = 'migration-arm-rollback'
    Name      = '部署协议迁移独立自动回滚'
    Order     = 49
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    Requires  = @('migration-preflight')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-arm-rollback.sh' -Parameters @{
            SOURCE_ROLE = [string]$Context.Plan.Migration.SourceRole
            TARGET_ROLE = [string]$Context.Plan.Migration.TargetRole
            TIMEOUT_MINUTES = [string]$Context.Plan.Migration.RollbackTimeoutMinutes
        } -TimeoutSeconds 180
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_ROLLBACK_ARMED') {
            throw '协议迁移回滚计时器未成功启用。'
        }
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.ProtocolMigration = $backup
        $Context.State.Migration.Status = 'RollbackArmed'
        $Context.State.Migration.RollbackArmed = $true
        $Context.State.Migration.RemoteBackupDirectory = $backup
        $Context.State.Migration.RollbackDeadlineMinutes = [int]$Context.Plan.Migration.RollbackTimeoutMinutes
        Save-VpsContext -Context $Context
        Write-VpsUi 'VPS 端独立回滚计时器已启用；后续失败会恢复源协议和旧 nftables。' Success
    }
}
