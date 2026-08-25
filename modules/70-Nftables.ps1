@{
    Id        = 'nftables-transition'
    Name      = '应用保留旧 SSH 的过渡 nftables'
    Order     = 70
    Roles     = @('RealityEntry', 'MonitorOnly')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        if ($Context.State.Audit.ExistingServices -or [int]$Context.State.Audit.NftRuleLines -gt 0) {
            throw '初始审计不是干净主机，拒绝套用 flush ruleset 模板。'
        }
        $ports = @(
            [int]$Context.Plan.Server.BootstrapSshPort,
            [int]$Context.Plan.Ports.SshPrimary,
            [int]$Context.Plan.Ports.SshRescue
        )
        if ($Context.Plan.Role -eq 'RealityEntry') {
            $ports += [int]$Context.Plan.Ports.XrayPrimary
            $ports += [int]$Context.Plan.Ports.XrayBackup
        }
        $ports = @($ports | Sort-Object -Unique)
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'nftables-apply.sh' `
            -Parameters @{ TCP_PORTS = ($ports -join ',') }
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        if (-not $Context.State.ContainsKey('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.NftablesTransition = $backup
        Save-VpsContext -Context $Context

        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
                throw "加载防火墙后 root 无法连接 SSH $port。初始端口仍在规则中。"
            }
            if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
                throw "加载防火墙后 admin sudo 在 SSH $port 失败。"
            }
        }
    }
}
