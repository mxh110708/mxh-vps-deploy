@{
    Id        = 'final-validation'
    Name      = '服务端总验收与协议真实出口测试'
    Order     = 100
    Roles     = @('RealityEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('nftables-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $parameters = @{
            ROLE = [string]$Context.Plan.Role
            SSH_PRIMARY = [string]$Context.Plan.Ports.SshPrimary
            SSH_RESCUE = [string]$Context.Plan.Ports.SshRescue
            XRAY_PRIMARY = [string]$Context.Plan.Ports.XrayPrimary
            XRAY_BACKUP = [string]$Context.Plan.Ports.XrayBackup
            LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
            TRUSTED_ADDRESSES = if ($Context.Plan.Role -eq 'ShadowsocksLanding') {
                (@($Context.Plan.Shadowsocks.TrustedEntryIPv4s) + @($Context.Plan.Shadowsocks.TrustedEntryIPv6s)) -join ','
            }
            else { '' }
            KOMARI_ENABLED = ([bool]$Context.Plan.Komari.Enabled).ToString().ToLowerInvariant()
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'final-validate.sh' -Parameters $parameters
        if ($result.StdOut -notmatch 'VPSDEPLOY_FINAL_OK') { throw '服务端总验收未返回成功标记。' }
        $timeSync = Get-VpsMarkerValue $result.StdOut TIME_SYNC
        if ($timeSync -ne 'yes') { Write-VpsUi 'NTP 当前尚未报告同步；部署不回滚，但建议稍后复查。' Warning }

        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) { throw "root SSH $port 复验失败。" }
            if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) { throw "admin sudo SSH $port 复验失败。" }
        }

        if ($Context.Plan.Role -eq 'RealityEntry') {
            $core = 'D:\Program Files\Clash Verge\verge-mihomo.exe'
            if (Test-Path -LiteralPath $core) {
                $primaryEgress = Invoke-MxhMihomoEgressTest -Context $Context -CorePath $core `
                    -ProfilePath $Context.State.ClientExports.PrimaryProfile `
                    -MixedPort ([int]$Context.State.ClientExports.PrimaryMixedPort) -Label 'primary'
                $backupEgress = Invoke-MxhMihomoEgressTest -Context $Context -CorePath $core `
                    -ProfilePath $Context.State.ClientExports.BackupProfile `
                    -MixedPort ([int]$Context.State.ClientExports.BackupMixedPort) -Label 'backup'
                if ($primaryEgress -ne $backupEgress) { Write-VpsUi '主/救援端口返回的出口 IP 不一致，请人工复核。' Warning }
                $Context.State.RealityEgressTest = [ordered]@{
                    Status = 'Passed'
                    PrimaryEgress = $primaryEgress
                    BackupEgress = $backupEgress
                    TestedAt = (Get-Date).ToString('o')
                }
                Write-VpsUi '主端口和救援端口均完成 Reality Authentication、HTTP 204 与出口测试。' Success
            }
            else {
                $Context.State.RealityEgressTest = [ordered]@{ Status = 'NotRun'; Reason = 'Mihomo core not found' }
                Write-VpsUi '未找到稳定版 Mihomo，真实 Reality 握手留待客户端人工完成。' Warning
            }
        }
        Save-VpsContext -Context $Context
    }
}
