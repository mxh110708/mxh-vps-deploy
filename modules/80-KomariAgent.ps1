@{
    Id        = 'komari-agent'
    Name      = '安装低权限 Komari Agent'
    Order     = 80
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('nftables-transition')
    IsEnabled = { param($Context) [bool]$Context.Plan.Komari.Enabled }
    Invoke    = {
        param($Context)
        if ($Context.NonInteractive) { throw 'Komari Token 必须交互式隐藏输入。' }
        $secure = Read-Host '请输入 Komari 新节点 Token（输入不会显示）' -AsSecureString
        $token = ConvertFrom-VpsSecureString $secure
        try {
            if ([string]::IsNullOrWhiteSpace($token) -or $token -match '\s') { throw 'Komari Token 为空或含空白字符。' }
            $arch = [string]$Context.State.Audit.Architecture
            $archKey = Get-VpsSupportedAssetArchitecture -Architecture $arch
            $asset = $Context.Versions.komari_agent.assets.$archKey
            $parameters = @{
                ENDPOINT = [string]$Context.Plan.Komari.Endpoint
                TOKEN = $token
                NODE_NAME = [string]$Context.Plan.NodeName
                VERSION = [string]$Context.Plan.Komari.AgentVersion
                ASSET_NAME = [string]$asset.name
                SHA256 = [string]$asset.sha256
            }
            $result = Invoke-VpsRemoteScript -Context $Context -Asset 'komari-agent.sh' -Parameters $parameters `
                -TimeoutSeconds 900 -SensitiveOutput
            if ($result.StdOut -notmatch 'VPSDEPLOY_KOMARI_OK') { throw 'Komari Agent 未返回成功标记。' }
            $Context.State.KomariInstalled = $true
            Save-VpsContext -Context $Context
        }
        finally {
            $token = $null
            $secure.Dispose()
        }
    }
}
