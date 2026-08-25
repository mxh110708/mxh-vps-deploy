@{
    Id        = 'ssh-cutover'
    Name      = '最终关闭服务商初始 SSH 端口'
    Order     = 110
    Roles     = @('RealityEntry', 'MonitorOnly')
    Requires  = @('final-validation')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        Write-VpsUi "即将从 sshd 和本机 nftables 移除初始端口 $($Context.Plan.Server.BootstrapSshPort)。" Warning
        Write-VpsUi '远端已准备 5 分钟自动回滚：若新连接验证失败，会恢复三端口配置。' Info
        if (-not $Context.NonInteractive -and -not (Read-VpsYesNo '确认执行最终收口？' $true)) {
            throw '用户取消最终 SSH 收口。'
        }
        $primary = [int]$Context.Plan.Ports.SshPrimary
        $rescue = [int]$Context.Plan.Ports.SshRescue
        $params = @{ SSH_PRIMARY = [string]$primary; SSH_RESCUE = [string]$rescue }
        $pending = Invoke-VpsRemoteScript -Context $Context -Asset 'ssh-cutover.sh' -Parameters $params -Port $primary
        if ($pending.StdOut -notmatch 'VPSDEPLOY_CUTOVER_PENDING') { throw 'SSH 收口未进入待确认状态。' }

        $allPassed = $true
        foreach ($port in @($primary, $rescue)) {
            $allPassed = $allPassed -and (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)
            $allPassed = $allPassed -and (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)
        }
        if (-not $allPassed) {
            throw '新端口收口复验失败。请等待最多 5 分钟让远端自动恢复初始端口。'
        }
        $confirm = Invoke-VpsRemoteScript -Context $Context -Asset 'ssh-cutover-confirm.sh' -Port $primary
        if ($confirm.StdOut -notmatch 'VPSDEPLOY_CUTOVER_CONFIRMED') { throw '无法取消 SSH 自动回滚计时器。' }

        $ports = @($primary, $rescue)
        if ($Context.Plan.Role -eq 'RealityEntry') {
            $ports += [int]$Context.Plan.Ports.XrayPrimary
            $ports += [int]$Context.Plan.Ports.XrayBackup
        }
        $nft = Invoke-VpsRemoteScript -Context $Context -Asset 'nftables-apply.sh' `
            -Parameters @{ TCP_PORTS = (($ports | Sort-Object -Unique) -join ',') } -Port $primary
        $backup = Get-VpsMarkerValue $nft.StdOut BACKUP_DIR -Required
        $Context.State.BackupDirectories.NftablesFinal = $backup
        $Context.State.BootstrapSshRemoved = $true
        $Context.State.CurrentManagementPort = $primary
        Save-VpsContext -Context $Context

        foreach ($port in @($primary, $rescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) { throw "最终防火墙后 SSH $port 失败。" }
        }
        Write-VpsUi 'sshd 与本机 nftables 已移除初始端口；请最后从服务商安全组同步删除。' Success
    }
}
