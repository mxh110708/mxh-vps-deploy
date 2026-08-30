@{
    Id        = 'migration-shadowsocks-probe'
    Name      = '从可信入口执行 Shadowsocks 链式实测'
    Order     = 95
    Roles     = @('ShadowsocksLanding')
    Requires  = @('landing-client-export')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        $entryPlanPath = [string]$Context.Plan.Migration.ValidationEntryPlanPath
        Test-MxhMigrationValidationEntryPlan -PlanPath $entryPlanPath `
            -LandingServerIpv4 ([string]$Context.Plan.Server.IPv4) `
            -AllowedEntryIpv4s @($Context.Plan.Shadowsocks.TrustedEntryIPv4s) | Out-Null
        $entryContext = New-MxhReadonlyContextFromPlan -ProjectRoot $Context.ProjectRoot -PlanPath $entryPlanPath
        $entryPort = [int]$entryContext.State.CurrentManagementPort
        if (-not (Test-VpsSshConnection -Context $entryContext -User root -Port $entryPort)) {
            throw '无法通过实例专用密钥登录验证入口 VPS。'
        }
        $arch = [string]$entryContext.State.Audit.Architecture
        $archKey = Get-VpsSupportedAssetArchitecture -Architecture $arch
        $asset = $Context.Versions.sing_box.assets.$archKey
        $credentials = $Context.Secrets.Shadowsocks
        $password = ([string]$credentials.ServerKey) + ':' + ([string]$credentials.PrimaryUserKey)
        $probe = Invoke-VpsRemoteScript -Context $entryContext -Asset 'shadowsocks-external-probe.sh' -Parameters @{
            VERSION = [string]$Context.Plan.Shadowsocks.SingBoxVersion
            ASSET_NAME = [string]$asset.name
            SHA256 = [string]$asset.sha256
            SELF_TEST_SCRIPT = Get-VpsRemoteAsset -Context $Context -Name 'shadowsocks-self-test.sh'
            METHOD = [string]$Context.Plan.Shadowsocks.Method
            PASSWORD = $password
            LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
            IP_VERSION = '4'
            TEST_SERVER = [string]$Context.Plan.Server.IPv4
        } -Port $entryPort -TimeoutSeconds 900 -SensitiveOutput
        $egress = Get-VpsMarkerValue $probe.StdOut EGRESS -Required
        $udp = Get-VpsMarkerValue $probe.StdOut UDP -Required
        if ($udp -ne 'yes' -or -not $egress) { throw '可信入口到 Shadowsocks 落地的 TCP/UDP 链式实测失败。' }
        $Context.State.MigrationShadowsocksExternalProbe = [ordered]@{
            Status = 'Passed'
            EntryNode = [string]$entryContext.Plan.NodeName
            Egress = $egress
            Udp = 'Passed'
            TestedAt = (Get-Date).ToString('o')
        }
        Save-VpsContext -Context $Context
        Write-VpsUi '可信入口 → Shadowsocks 落地的 TCP、UDP 和真实出口测试均通过。' Success
    }
}
