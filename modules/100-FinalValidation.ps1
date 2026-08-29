@{
    Id        = 'final-validation'
    Name      = '服务端总验收与协议真实出口测试'
    Order     = 100
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('nftables-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $inventory = if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled -and
            $Context.Plan.Migration.Contains('ValidationInventory')) {
            $Context.Plan.Migration.ValidationInventory
        } else {
            Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
        }
        $parameters = @{
            ROLE = [string]$Context.Plan.Role
            SSH_PRIMARY = [string]$Context.Plan.Ports.SshPrimary
            SSH_RESCUE = [string]$Context.Plan.Ports.SshRescue
            XRAY_PRIMARY = [string]$Context.Plan.Ports.XrayPrimary
            XRAY_BACKUP = [string]$Context.Plan.Ports.XrayBackup
            ANYTLS_PORT = [string]$Context.Plan.Ports.AnyTlsPrimary
            ANYTLS_SERVER_NAME = if ([bool]$inventory.AnyTlsEntry.Enabled) { [string]$Context.Plan.AnyTls.ServerName } else { '' }
            REALITY_TARGET_MODE = if ([bool]$inventory.RealityEntry.Enabled -and $Context.Plan.Reality.Contains('TargetMode')) {
                [string]$Context.Plan.Reality.TargetMode
            } else { 'ExternalAudited' }
            REALITY_SERVER_NAME = if ([bool]$inventory.RealityEntry.Enabled) {
                [string]((Get-MxhRealityTargetSettings -Plan $Context.Plan).ServerName)
            } else { '' }
            LOCAL_HTTPS_PORT = if ([bool]$inventory.RealityEntry.Enabled -and $Context.Plan.Reality.Contains('LocalHttpsPort')) {
                [string]$Context.Plan.Reality.LocalHttpsPort
            } else { '' }
            LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
            TRUSTED_ADDRESSES = if ([bool]$inventory.ShadowsocksLanding.Enabled) {
                (@($Context.Plan.Shadowsocks.TrustedEntryIPv4s) + @($Context.Plan.Shadowsocks.TrustedEntryIPv6s)) -join ','
            }
            else { '' }
            REALITY_ENABLED = ([bool]$inventory.RealityEntry.Enabled).ToString().ToLowerInvariant()
            ANYTLS_ENABLED = ([bool]$inventory.AnyTlsEntry.Enabled).ToString().ToLowerInvariant()
            SHADOWSOCKS_ENABLED = ([bool]$inventory.ShadowsocksLanding.Enabled).ToString().ToLowerInvariant()
            FIREWALL_MODE = if ($Context.Plan.Contains('Firewall') -and $Context.Plan.Firewall.Contains('Mode')) {
                [string]$Context.Plan.Firewall.Mode
            } else { 'ManagedNftables' }
            KOMARI_ENABLED = ([bool]$Context.Plan.Komari.Enabled).ToString().ToLowerInvariant()
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'final-validate.sh' -Parameters $parameters
        if ($result.StdOut -notmatch 'VPSDEPLOY_FINAL_OK') { throw '服务端总验收未返回成功标记。' }
        $timeSync = Get-VpsMarkerValue $result.StdOut TIME_SYNC
        if ($timeSync -ne 'yes') { Write-VpsUi 'NTP 当前尚未报告同步；部署不回滚，但建议稍后复查。' Warning }

        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) { throw "root SSH $port 复验失败。" }
            if ($Context.Plan.AdminUser -ne 'root' -and -not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) { throw "admin sudo SSH $port 复验失败。" }
        }

        if ([bool]$inventory.RealityEntry.Enabled) {
            $core = @(Get-VpsMihomoCorePaths -ProjectRoot $Context.ProjectRoot | Where-Object { (Split-Path -Leaf $_) -eq 'verge-mihomo.exe' } | Select-Object -First 1)
            $core = if($core.Count){$core[0]}else{''}
            if (Test-Path -LiteralPath $core) {
                $primaryEgress = Invoke-MxhMihomoEgressTest -Context $Context -CorePath $core `
                    -ProfilePath $Context.State.ClientExports.PrimaryProfile `
                    -MixedPort ([int]$Context.State.ClientExports.PrimaryMixedPort) -Label 'primary'
                $backupEgress = $null
                if ($Context.State.ClientExports.BackupProfile) {
                    $backupEgress = Invoke-MxhMihomoEgressTest -Context $Context -CorePath $core `
                        -ProfilePath $Context.State.ClientExports.BackupProfile `
                        -MixedPort ([int]$Context.State.ClientExports.BackupMixedPort) -Label 'backup'
                    if ($primaryEgress -ne $backupEgress) { Write-VpsUi '主/救援端口返回的出口 IP 不一致，请人工复核。' Warning }
                }
                $Context.State.RealityEgressTest = [ordered]@{
                    Status = 'Passed'
                    PrimaryEgress = $primaryEgress
                    BackupEgress = $backupEgress
                    UdpDns = 'Passed'
                    TestedAt = (Get-Date).ToString('o')
                }
                Write-VpsUi $(if ($backupEgress) { '主端口和救援端口均完成 Reality Authentication、HTTP 204、出口 IP 与 UDP DNS 往返测试。' } else { 'Reality 主端口已完成 Authentication、HTTP 204、出口 IP 与 UDP DNS 往返测试；该导入实例没有救援入口。' }) Success
            }
            else {
                $Context.State.RealityEgressTest = [ordered]@{ Status = 'NotRun'; Reason = 'Mihomo core not found' }
                Write-VpsUi '未找到稳定版 Mihomo，真实 Reality 握手留待客户端人工完成。' Warning
            }
        }
        elseif ([bool]$inventory.AnyTlsEntry.Enabled) {
            $core = @(Get-VpsMihomoCorePaths -ProjectRoot $Context.ProjectRoot | Where-Object { (Split-Path -Leaf $_) -eq 'verge-mihomo.exe' } | Select-Object -First 1)
            $core = if($core.Count){$core[0]}else{''}
            if (Test-Path -LiteralPath $core) {
                $egress = Invoke-MxhMihomoEgressTest -Context $Context -CorePath $core `
                    -ProfilePath $Context.State.AnyTlsClientExports.MihomoProfile `
                    -MixedPort ([int]$Context.State.AnyTlsClientExports.MihomoMixedPort) -Label 'anytls'
                $Context.State.AnyTlsEgressTest = [ordered]@{
                    Status = 'Passed'
                    Egress = $egress
                    UdpDns = 'Passed'
                    TestedAt = (Get-Date).ToString('o')
                }
                Write-VpsUi 'AnyTLS 已完成受信证书、ECH、HTTP 204、出口 IP 与 UDP DNS 往返测试。' Success
            }
            else {
                $Context.State.AnyTlsEgressTest = [ordered]@{ Status = 'NotRun'; Reason = 'Mihomo core not found' }
                Write-VpsUi '未找到稳定版 Mihomo，AnyTLS 真实客户端测试留待人工完成。' Warning
            }
        }
        Save-VpsContext -Context $Context
    }
}
