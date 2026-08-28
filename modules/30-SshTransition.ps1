@{
    Id        = 'ssh-transition'
    Name      = '过渡到主/救援双 SSH 入口'
    Order     = 30
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('base-system')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $sshPorts = @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue) | Sort-Object -Unique
        $newPorts = @($sshPorts | Where-Object { $_ -ne [int]$Context.Plan.Server.BootstrapSshPort })
        if ($newPorts.Count -gt 0) {
            Write-VpsUi "请确认服务商安全组已放行新增 SSH TCP 端口：$($newPorts -join ', ')。" Warning
        }
        if ($Context.Plan.Role -eq 'ShadowsocksLanding') {
            Write-VpsUi "同时应只对可信入口 IP 放行 TCP+UDP $($Context.Plan.Ports.LandingShadowsocks)，不要对全网开放。" Warning
        }
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
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.SshTransition = $backup

        foreach ($port in $sshPorts) {
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
        if (Test-VpsBootstrapSshPortRetained -Plan $Context.Plan) {
            Write-VpsUi '复用的服务商主端口与新增救援端口均通过 root/admin/sudo 验证。' Success
        }
        else {
            Write-VpsUi '两个新高位端口均通过 root/admin/sudo 验证；初始端口暂时保留。' Success
        }
    }
}
