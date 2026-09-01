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
        $getEnabledPort = {
            param([string]$Name,[bool]$Enabled)
            if(-not $Enabled){return ''}
            if(-not $Context.Plan.Ports.Contains($Name) -or $null -eq $Context.Plan.Ports[$Name] -or
                [string]::IsNullOrWhiteSpace([string]$Context.Plan.Ports[$Name])){
                throw "已启用协议缺少端口字段：Ports.$Name。"
            }
            return [string]$Context.Plan.Ports[$Name]
        }
        $parameters = @{
            ROLE = [string]$Context.Plan.Role
            SSH_PRIMARY = [string]$Context.Plan.Ports.SshPrimary
            SSH_RESCUE = [string]$Context.Plan.Ports.SshRescue
            XRAY_PRIMARY = & $getEnabledPort 'XrayPrimary' ([bool]$inventory.RealityEntry.Enabled)
            XRAY_BACKUP = & $getEnabledPort 'XrayBackup' ([bool]$inventory.RealityEntry.Enabled)
            ANYTLS_PORT = & $getEnabledPort 'AnyTlsPrimary' ([bool]$inventory.AnyTlsEntry.Enabled)
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
            LANDING_PORT = & $getEnabledPort 'LandingShadowsocks' ([bool]$inventory.ShadowsocksLanding.Enabled)
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

        $managedAdminPassword = Test-VpsManagedAdminPassword -Context $Context
        foreach ($port in @([int]$Context.Plan.Ports.SshPrimary, [int]$Context.Plan.Ports.SshRescue)) {
            if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) { throw "root SSH $port 复验失败。" }
            if ($Context.Plan.AdminUser -ne 'root') {
                $adminReady = if ($managedAdminPassword) {
                    Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo
                } else {
                    Test-VpsImportedAdminSudoPolicy -Context $Context -User $Context.Plan.AdminUser -Port $port
                }
                if (-not $adminReady) { throw "admin sudo SSH $port 复验失败。" }
            }
        }
        if ($Context.Plan.AdminUser -ne 'root' -and -not $managedAdminPassword) {
            Write-VpsUi '导入实例的现有 admin 密码未纳管：已验证公钥登录和 sudo 授权策略，未验证未知密码本身。' Warning
        }

        if ([bool]$inventory.RealityEntry.Enabled) {
            $summary = Invoke-MxhRealClientValidation -Context $Context -Protocol Reality
            Write-VpsUi $(if ($summary.Status -eq 'Passed') {
                    'Mihomo 与 sing-box 已逐入口、逐地址族完成 Reality 握手、HTTPS 出口、出口 IP 与 UDP DNS 验收。'
                } else { 'Reality 可执行的真实验收已完成；用户明确跳过的核心或地址族已记录为 SkippedByUser，不计为通过。' }) `
                $(if ($summary.Status -eq 'Passed') { 'Success' } else { 'Warning' })
        }
        if ([bool]$inventory.AnyTlsEntry.Enabled) {
            $summary = Invoke-MxhRealClientValidation -Context $Context -Protocol AnyTLS
            Write-VpsUi $(if ($summary.Status -eq 'Passed') {
                    'Mihomo 与 sing-box 已逐地址族完成 AnyTLS 受信证书、ECH、HTTPS 出口、出口 IP 与 UDP DNS 验收。'
                } else { 'AnyTLS 可执行的真实验收已完成；用户明确跳过的核心或地址族已记录为 SkippedByUser，不计为通过。' }) `
                $(if ($summary.Status -eq 'Passed') { 'Success' } else { 'Warning' })
        }
        Save-VpsContext -Context $Context
    }
}
