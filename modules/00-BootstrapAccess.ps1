@{
    Id        = 'bootstrap-access'
    Name      = '建立本机独立 SSH 公钥入口'
    Order     = 0
    Roles     = @('RealityEntry', 'ShadowsocksLanding', 'MonitorOnly', 'AuditOnly')
    Requires  = @()
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        Initialize-VpsBootstrapAccess -Context $Context
        Write-VpsLog -Context $Context -Message 'Bootstrap root key access verified.'
    }
}
