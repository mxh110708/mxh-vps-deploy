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
        $readAsset = {
            param($Assets, [string]$Architecture)
            if ($Assets -is [Collections.IDictionary]) { return $Assets[$Architecture] }
            $property = $Assets.PSObject.Properties[$Architecture]
            if ($null -eq $property) { throw "版本清单缺少 $Architecture 资产。" }
            return $property.Value
        }
        $singBoxAsset = & $readAsset $Context.Versions.sing_box.assets $archKey
        $mihomoAsset = & $readAsset $Context.Versions.mihomo.assets $archKey
        $credentials = $Context.Secrets.Shadowsocks
        $users = [Collections.Generic.List[object]]::new()
        $users.Add([pscustomobject]@{ Label = 'IPv4 用户'; Key = [string]$credentials.PrimaryUserKey; IpVersion = '4' })
        if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
            $users.Add([pscustomobject]@{ Label = 'IPv6 用户'; Key = [string]$credentials.SecondaryUserKey; IpVersion = '6' })
        }
        $results = [Collections.Generic.List[object]]::new()
        foreach ($user in $users) {
            $password = ([string]$credentials.ServerKey) + ':' + ([string]$user.Key)
            $probe = Invoke-VpsRemoteScript -Context $entryContext -Asset 'shadowsocks-external-probe.sh' -Parameters @{
                MIHOMO_VERSION = [string]$Context.Versions.mihomo.version
                MIHOMO_ASSET_NAME = [string]$mihomoAsset.name
                MIHOMO_SHA256 = [string]$mihomoAsset.sha256
                SING_BOX_VERSION = [string]$Context.Plan.Shadowsocks.SingBoxVersion
                SING_BOX_ASSET_NAME = [string]$singBoxAsset.name
                SING_BOX_SHA256 = [string]$singBoxAsset.sha256
                METHOD = [string]$Context.Plan.Shadowsocks.Method
                PASSWORD = $password
                LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
                IP_VERSION = [string]$user.IpVersion
                TEST_SERVER = [string]$Context.Plan.Server.IPv4
            } -Port $entryPort -TimeoutSeconds 900 -SensitiveOutput `
                -ProgressActivity "可信入口执行 Shadowsocks $([string]$user.Label) 双核心验收"
            $acceptance = (Get-VpsMarkerValue $probe.StdOut EXTERNAL_ACCEPTANCE -Required) | ConvertFrom-Json -AsHashtable
            if ($acceptance.status -ne 'Passed' -or @($acceptance.results).Count -ne 2 -or
                @($acceptance.results | Where-Object udp -ne 'Passed').Count) {
                throw "可信入口到 Shadowsocks $([string]$user.Label) 的双核心 TCP/UDP 链式实测失败。"
            }
            foreach ($item in @($acceptance.results)) {
                $results.Add([ordered]@{
                    User = [string]$user.Label
                    Core = [string]$item.core
                    AddressFamily = [string]$item.egress_family
                    Egress = [string]$item.egress
                    HttpsEndpoint = [string]$item.https_endpoint
                    Udp = [string]$item.udp
                    TestedAt = (Get-Date).ToString('o')
                })
            }
        }
        $Context.State.MigrationShadowsocksExternalProbe = [ordered]@{
            Status = 'Passed'
            EntryNode = [string]$entryContext.Plan.NodeName
            Results = $results.ToArray()
            TestedAt = (Get-Date).ToString('o')
        }
        Save-VpsContext -Context $Context
        Write-VpsUi '可信入口 → Shadowsocks 落地的 Mihomo、sing-box、HTTPS 出口和 UDP 测试均通过。' Success
    }
}
