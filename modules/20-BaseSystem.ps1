@{
    Id        = 'base-system'
    Name      = '安装基础工具、时间同步并创建 admin'
    Order     = 20
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('audit')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $publicKey = (Get-Content -Raw -LiteralPath ((Get-VpsSshKeyPath $Context) + '.pub')).Trim()
        $parameters = @{
            ADMIN_USER = [string]$Context.Plan.AdminUser
            ADMIN_PASSWORD = [string]$Context.Secrets.AdminPassword
            PUBLIC_KEY = $publicKey
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'base-system.sh' -Parameters $parameters `
            -Port ([int]$Context.Plan.Server.BootstrapSshPort) -TimeoutSeconds 1200 -SensitiveOutput
        if ($result.StdOut -notmatch 'VPSDEPLOY_BASE_OK') { throw '基础环境脚本未返回成功标记。' }

        $port = [int]$Context.Plan.Server.BootstrapSshPort
        if (-not (Test-VpsSshConnection -Context $Context -User 'root' -Port $port)) {
            throw '初始端口 root 公钥复验失败。'
        }
        if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port)) {
            throw '初始端口 admin 公钥登录失败。'
        }
        if (-not (Test-VpsSshConnection -Context $Context -User $Context.Plan.AdminUser -Port $port -TestSudo)) {
            throw '初始端口 admin sudo 验证失败。'
        }
        Write-VpsUi 'admin 密码仅用于本机 sudo；SSH 密码登录会在下一阶段关闭。' Info
    }
}
