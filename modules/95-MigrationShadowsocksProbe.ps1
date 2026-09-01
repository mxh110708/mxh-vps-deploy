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
        Invoke-MxhShadowsocksExternalValidation -Context $Context | Out-Null
    }
}
