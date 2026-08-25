@{
    Id        = 'xray-reality'
    Name      = '安装固定版 Xray 并部署双入口 REALITY'
    Order     = 50
    Roles     = @('RealityEntry')
    Requires  = @('target-audit')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $xrayVersion = [string]$Context.Plan.Reality.XrayVersion
        $installParameters = @{
            VERSION = $xrayVersion
            INSTALLER_URL = [string]$Context.Versions.xray.installer_url
            INSTALLER_SHA256 = [string]$Context.Versions.xray.installer_sha256
        }
        Invoke-VpsRemoteScript -Context $Context -Asset 'xray-install.sh' -Parameters $installParameters -TimeoutSeconds 1200 | Out-Null

        $xraySecrets = $Context.Secrets.Xray
        $needCredentials = -not $xraySecrets
        if (-not $needCredentials) {
            foreach ($field in @('Uuid', 'RealityPrivateKey', 'RealityClientKey', 'ShortId')) {
                if (-not $xraySecrets.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$xraySecrets[$field])) {
                    $needCredentials = $true
                    break
                }
            }
        }
        if ($needCredentials) {
            $credentialResult = Invoke-VpsRemoteScript -Context $Context -Asset 'xray-generate-credentials.sh' -SensitiveOutput
            $match = [regex]::Match($credentialResult.StdOut, '(?m)^VPSDEPLOY_XRAY_SECRET_B64=([A-Za-z0-9+/=]+)$')
            if (-not $match.Success) { throw 'Xray 凭据生成结果无法解析。' }
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value))
            $Context.Secrets.Xray = $json | ConvertFrom-Json -AsHashtable
            $xraySecrets = $Context.Secrets.Xray
            Save-VpsContext -Context $Context
        }

        $target = [string]$Context.Plan.Reality.Target
        $inbounds = @(
            (New-MxhXrayInbound -Tag 'reality-primary' -Port ([int]$Context.Plan.Ports.XrayPrimary) -Secrets $xraySecrets -Target $target),
            (New-MxhXrayInbound -Tag 'reality-backup' -Port ([int]$Context.Plan.Ports.XrayBackup) -Secrets $xraySecrets -Target $target)
        )
        $directSettings = if ($Context.Plan.Reality.ForceIpv4Egress) { [ordered]@{ domainStrategy = 'ForceIPv4' } } else { @{} }
        $routingRules = if ($Context.Plan.Reality.ForceIpv4Egress) {
            @([ordered]@{ type = 'field'; ip = @('::/0'); outboundTag = 'block' })
        }
        else { @() }
        $config = [ordered]@{
            log = [ordered]@{ access = 'none'; error = '/var/log/xray/error.log'; loglevel = 'warning' }
            inbounds = $inbounds
            outbounds = @(
                [ordered]@{ tag = 'direct'; protocol = 'freedom'; settings = $directSettings },
                [ordered]@{ tag = 'block'; protocol = 'blackhole' }
            )
            routing = [ordered]@{ domainStrategy = 'AsIs'; rules = $routingRules }
        }
        $configJson = $config | ConvertTo-Json -Depth 30
        $applyParameters = @{
            CONFIG_JSON = $configJson
            PRIMARY_PORT = [string]$Context.Plan.Ports.XrayPrimary
            BACKUP_PORT = [string]$Context.Plan.Ports.XrayBackup
            TARGET = $target
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'xray-apply-config.sh' -Parameters $applyParameters -TimeoutSeconds 600 -SensitiveOutput
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.Xray = $backup
        $Context.State.XrayVersion = $xrayVersion
        Save-VpsContext -Context $Context
    }
}
