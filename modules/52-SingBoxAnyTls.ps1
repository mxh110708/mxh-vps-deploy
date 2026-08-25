@{
    Id        = 'sing-box-anytls'
    Name      = '部署 AnyTLS + 可信 TLS + ECH 入口'
    Order     = 52
    Roles     = @('AnyTlsEntry')
    Requires  = @('certbot-dns')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)

        $arch = [string]$Context.State.Audit.Architecture
        $archKey = if ($arch -in @('x86_64', 'amd64')) { 'amd64' } else { 'arm64' }
        $asset = $Context.Versions.sing_box.assets.$archKey
        $version = [string]$Context.Plan.AnyTls.SingBoxVersion
        $install = Invoke-VpsRemoteScript -Context $Context -Asset 'sing-box-anytls-install.sh' -Parameters @{
            VERSION = $version
            ASSET_NAME = [string]$asset.name
            SHA256 = [string]$asset.sha256
        } -TimeoutSeconds 1200
        $installBackup = Get-VpsMarkerValue $install.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.AnyTlsInstall = $installBackup

        if (-not $Context.Secrets.Contains('AnyTls')) { $Context.Secrets.AnyTls = [ordered]@{} }
        $secrets = $Context.Secrets.AnyTls
        if (-not $secrets.Contains('Password') -or [string]::IsNullOrWhiteSpace([string]$secrets.Password)) {
            $secrets.Password = New-MxhRandomBase64Key -Length 32
        }
        $needEch = -not $secrets.Contains('EchServerKeyPem') -or
            [string]::IsNullOrWhiteSpace([string]$secrets.EchServerKeyPem) -or
            -not $secrets.Contains('EchClientConfigPem') -or
            [string]::IsNullOrWhiteSpace([string]$secrets.EchClientConfigPem)
        if ($needEch) {
            $ech = Invoke-VpsRemoteScript -Context $Context -Asset 'anytls-generate-ech.sh' -Parameters @{
                PUBLIC_NAME = [string]$Context.Plan.AnyTls.EchPublicName
            } -SensitiveOutput
            $configPem = Get-VpsMarkerValue $ech.StdOut ECH_CONFIG -Required
            $keysPem = Get-VpsMarkerValue $ech.StdOut ECH_KEYS -Required
            $parsed = ConvertFrom-MxhEchKeyPairText -Text ($configPem + "`n" + $keysPem)
            $secrets.EchClientConfigPem = $parsed.ClientConfigPem
            $secrets.EchClientConfigBase64 = $parsed.ClientConfigBase64
            $secrets.EchServerKeyPem = $parsed.ServerKeyPem
        }
        Save-VpsContext -Context $Context

        $config = New-MxhAnyTlsServerConfig -Context $Context
        $apply = Invoke-VpsRemoteScript -Context $Context -Asset 'anytls-apply-config.sh' -Parameters @{
            CONFIG_JSON = ($config | ConvertTo-Json -Depth 30)
            ECH_KEYS_PEM = [string]$secrets.EchServerKeyPem
            ECH_CONFIG_PEM = [string]$secrets.EchClientConfigPem
            PORT = [string]$Context.Plan.Ports.AnyTlsPrimary
            SERVER_NAME = [string]$Context.Plan.AnyTls.ServerName
        } -TimeoutSeconds 600 -SensitiveOutput
        $backup = Get-VpsMarkerValue $apply.StdOut BACKUP_DIR -Required
        $Context.State.BackupDirectories.AnyTls = $backup
        $xrayWasActive = Get-VpsMarkerValue $apply.StdOut XRAY_WAS_ACTIVE
        $xrayWasEnabled = Get-VpsMarkerValue $apply.StdOut XRAY_WAS_ENABLED

        $testServer = if ($Context.Plan.Server.IPv6) { '::1' } else { '127.0.0.1' }
        $selfTest = Invoke-VpsRemoteScript -Context $Context -Asset 'anytls-self-test.sh' -Parameters @{
            PASSWORD = [string]$secrets.Password
            PORT = [string]$Context.Plan.Ports.AnyTlsPrimary
            SERVER = $testServer
            SERVER_NAME = [string]$Context.Plan.AnyTls.ServerName
            ECH_CONFIG_PEM = [string]$secrets.EchClientConfigPem
        } -TimeoutSeconds 240 -SensitiveOutput
        $egress = Get-VpsMarkerValue $selfTest.StdOut EGRESS -Required
        $udp = Get-VpsMarkerValue $selfTest.StdOut UDP -Required
        if ($udp -ne 'yes') { throw 'AnyTLS UDP 功能自测失败。' }
        $Context.State.AnyTls = [ordered]@{
            SingBoxVersion = $version
            Egress = $egress
            Tcp = 'Passed'
            Udp = 'Passed'
            Ech = 'Passed'
            TrustedCertificate = 'Passed'
            PaddingSchemeMode = if ($Context.Plan.AnyTls.Contains('PaddingSchemeMode')) {
                [string]$Context.Plan.AnyTls.PaddingSchemeMode
            } else { 'OfficialDefault' }
            XrayWasActive = $xrayWasActive
            XrayWasEnabled = $xrayWasEnabled
            TestedAt = (Get-Date).ToString('o')
        }
        Save-VpsContext -Context $Context
    }
}
