@{
    Id        = 'ssh-transition'
    Name      = '过渡到初始 + 主/救援双高位 SSH'
    Order     = 30
    Roles     = @('RealityEntry', 'MonitorOnly')
    Requires  = @('base-system')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        Write-VpsUi "请确认服务商安全组已放行 TCP $($Context.Plan.Ports.SshPrimary) 和 $($Context.Plan.Ports.SshRescue)。" Warning
        if (-not $Context.NonInteractive -and -not (Read-VpsYesNo '已放行并准备继续？' $true)) {
            throw '用户尚未放行服务商安全组。'
        }
        $parameters = @{
            BOOTSTRAP_PORT = [string]$Context.Plan.Server.BootstrapSshPort
            SSH_PRIMARY = [string]$Context.Plan.Ports.SshPrimary
            SSH_RESCUE = [string]$Context.Plan.Ports.SshRescue
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'ssh-transition.sh' -Parameters $parameters `
            -Port ([int]$Context.Plan.Server.BootstrapSshPort)
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        if (-not $Context.State.ContainsKey('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.SshTransition = $backup

        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "root 无法通过新端口 $port 建立全新公钥连接。"
            }
            if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port)) {
                throw "admin 无法通过新端口 $port 建立全新公钥连接。"
            }
            if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
                throw "admin 在新端口 $port 上 sudo 失败。"
            }
        }
        $Context.State.CurrentManagementPort = [int]$Context.Plan.Ports.SshPrimary
        Save-VpsContext -Context $Context
        Write-VpsUi '两个高位端口均通过 root/admin/sudo 验证；初始端口仍保留。' Success
    }
}
