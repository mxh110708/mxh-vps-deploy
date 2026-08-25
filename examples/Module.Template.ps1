# Copy this file into modules/, rename it with a numeric prefix, then edit the definition.
@{
    Id        = 'example-module'
    Name      = '示例模块（复制后修改）'
    Order     = 500
    Roles     = @('RealityEntry', 'MonitorOnly')
    Requires  = @('audit')
    IsEnabled = { param($Context) $false }
    Invoke    = {
        param($Context)
        # Put remote Bash in assets/remote/example-module.sh and call:
        # Invoke-VpsRemoteScript -Context $Context -Asset 'example-module.sh'
        throw '示例模块默认禁用。'
    }
}
