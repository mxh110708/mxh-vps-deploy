@{
    Id        = 'final-validation'
    Name      = '服务端总验收与协议真实出口测试'
    Order     = 100
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
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
            ANYTLS_PORT = [string]$Context.Plan.Ports.AnyTlsPrimary
            ANYTLS_SERVER_NAME = if ($Context.Plan.Role -eq 'AnyTlsEntry') { [string]$Context.Plan.AnyTls.ServerName } else { '' }
            REALITY_TARGET_MODE = if ($Context.Plan.Role -eq 'RealityEntry' -and $Context.Plan.Reality.Contains('TargetMode')) {
                [string]$Context.Plan.Reality.TargetMode
            } else { 'ExternalAudited' }
            REALITY_SERVER_NAME = if ($Context.Plan.Role -eq 'RealityEntry') {
                [string]((Get-MxhRealityTargetSettings -Plan $Context.Plan).ServerName)
            } else { '' }
            LOCAL_HTTPS_PORT = if ($Context.Plan.Role -eq 'RealityEntry' -and $Context.Plan.Reality.Contains('LocalHttpsPort')) {
                [string]$Context.Plan.Reality.LocalHttpsPort
            } else { '' }
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
        elseif ($Context.Plan.Role -eq 'AnyTlsEntry') {
            $core = 'D:\Program Files\Clash Verge\verge-mihomo.exe'
            if (Test-Path -LiteralPath $core) {
                $egress = Invoke-MxhMihomoEgressTest -Context $Context -CorePath $core `
                    -ProfilePath $Context.State.AnyTlsClientExports.MihomoProfile `
                    -MixedPort ([int]$Context.State.AnyTlsClientExports.MihomoMixedPort) -Label 'anytls'
                $Context.State.AnyTlsEgressTest = [ordered]@{
                    Status = 'Passed'
                    Egress = $egress
                    TestedAt = (Get-Date).ToString('o')
                }
                Write-VpsUi 'AnyTLS 已完成受信证书、ECH、HTTP 204 与真实出口测试。' Success
            }
            else {
                $Context.State.AnyTlsEgressTest = [ordered]@{ Status = 'NotRun'; Reason = 'Mihomo core not found' }
                Write-VpsUi '未找到稳定版 Mihomo，AnyTLS 真实客户端测试留待人工完成。' Warning
            }
        }
        Save-VpsContext -Context $Context
    }
}
