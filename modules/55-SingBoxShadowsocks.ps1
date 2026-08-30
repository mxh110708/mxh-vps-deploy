@{
    Id        = 'sing-box-shadowsocks'
    Name      = '安装 sing-box 并部署 Shadowsocks 2022 落地'
    Order     = 55
    Roles     = @('ShadowsocksLanding')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)

        $arch = [string]$Context.State.Audit.Architecture
        $archKey = Get-VpsSupportedAssetArchitecture -Architecture $arch
        $asset = $Context.Versions.sing_box.assets.$archKey
        $version = [string]$Context.Plan.Shadowsocks.SingBoxVersion
        $installResult = Invoke-VpsRemoteScript -Context $Context -Asset 'sing-box-install.sh' -Parameters @{
            VERSION = $version
            ASSET_NAME = [string]$asset.name
            SHA256 = [string]$asset.sha256
            NEED_BIND_INTERFACE = ([bool]$Context.Plan.Shadowsocks.SecondaryBindInterface).ToString().ToLowerInvariant()
        } -TimeoutSeconds 1200
        $installBackup = Get-VpsMarkerValue $installResult.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.SingBoxInstall = $installBackup

        if (-not $Context.Secrets.Contains('Shadowsocks')) {
            $Context.Secrets['Shadowsocks'] = [ordered]@{}
        }
        $credentials = $Context.Secrets.Shadowsocks
        $credentialsChanged = $false
        foreach ($field in @('ServerKey', 'PrimaryUserKey')) {
            if (-not $credentials.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$credentials[$field])) {
                $credentials[$field] = New-MxhRandomBase64Key -Length 16
                $credentialsChanged = $true
            }
        }
        if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled -and
            (-not $credentials.Contains('SecondaryUserKey') -or [string]::IsNullOrWhiteSpace([string]$credentials.SecondaryUserKey))) {
            $credentials['SecondaryUserKey'] = New-MxhRandomBase64Key -Length 16
            $credentialsChanged = $true
        }
        if ($credentialsChanged) {
            Save-VpsContext -Context $Context
        }

        $config = New-MxhShadowsocksServerConfig -Context $Context
        $configJson = $config | ConvertTo-Json -Depth 30
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'sing-box-apply-config.sh' -Parameters @{
            CONFIG_JSON = $configJson
            LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
        } -TimeoutSeconds 600 -SensitiveOutput
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        $Context.State.BackupDirectories.SingBox = $backup

        Invoke-MxhShadowsocksRealValidation -Context $Context | Out-Null
        $Context.State.SingBoxVersion = $version
        Save-VpsContext -Context $Context
    }
}
