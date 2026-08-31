@{
    Id        = 'certbot-dns'
    Name      = '配置 Cloudflare DNS-01 证书与自动续期'
    Order     = 42
    Roles     = @('RealityEntry', 'AnyTlsEntry')
    Requires  = @('ssh-transition')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('TrustedTls') -and [bool]$Context.Plan.TrustedTls.Enabled
    }
    Invoke    = {
        param($Context)

        $tokenPath = [string]$Context.Plan.TrustedTls.CloudflareTokenFile
        if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
            throw 'Cloudflare Certbot Token 本地私有文件不存在。'
        }
        Protect-VpsPrivateFile -Path $tokenPath
        $token = (Get-Content -Raw -LiteralPath $tokenPath).Trim()
        if ([string]::IsNullOrWhiteSpace($token) -or $token -match '[\r\n]') {
            throw 'Cloudflare Certbot Token 文件必须只包含一行非空 Token。'
        }

        $isAnyTls = $Context.Plan.Role -eq 'AnyTlsEntry'
        $isLocalReality = $Context.Plan.Role -eq 'RealityEntry' -and
            $Context.Plan.Reality.Contains('TargetMode') -and
            $Context.Plan.Reality.TargetMode -eq 'LocalOwnedTls'
        $parameters = [ordered]@{
            CLOUDFLARE_TOKEN = $token
            ZONE_NAME = [string]$Context.Plan.TrustedTls.ZoneName
            EMAIL = [string]$Context.Plan.TrustedTls.CertbotEmail
            PROPAGATION_SECONDS = '30'
            ANYTLS_ENABLED = $isAnyTls.ToString().ToLowerInvariant()
            ANYTLS_CERT_NAME = [string]$Context.Plan.TrustedTls.AnyTlsCertificateName
            ANYTLS_DOMAINS = if ($isAnyTls) {
                @([string]$Context.Plan.AnyTls.ServerName, [string]$Context.Plan.AnyTls.EchPublicName) -join ','
            } else { '' }
            REALITY_ENABLED = $isLocalReality.ToString().ToLowerInvariant()
            REALITY_CERT_NAME = [string]$Context.Plan.TrustedTls.RealityCertificateName
            REALITY_DOMAINS = if ($isLocalReality) { [string]$Context.Plan.Reality.ServerName } else { '' }
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'certbot-dns-setup.sh' `
            -Parameters $parameters -TimeoutSeconds 1800 -SensitiveOutput -AllowFailure `
            -ProgressActivity '配置 Cloudflare DNS-01 证书与自动续期'
        if ($result.ExitCode -ne 0) {
            $safeError = Get-VpsMarkerValue -Text $result.StdOut -Name CERTBOT_SAFE_ERROR
            if ($safeError) { throw $safeError }
            throw 'Certbot DNS-01 远程执行失败；敏感输出已隐藏，且远端未返回可公开的阶段错误。'
        }
        if ($result.StdOut -notmatch 'VPSDEPLOY_CERTBOT_DNS_OK') {
            throw 'Certbot DNS-01 未返回成功标记。'
        }
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        $version = Get-VpsMarkerValue $result.StdOut CERTBOT_VERSION -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.CertbotDns = $backup
        $Context.State.TrustedTls = [ordered]@{
            CertbotVersion = $version
            AnyTlsCertificate = if ($isAnyTls) { [string]$Context.Plan.TrustedTls.AnyTlsCertificateName } else { $null }
            RealityCertificate = if ($isLocalReality) { [string]$Context.Plan.TrustedTls.RealityCertificateName } else { $null }
            RenewalTimer = 'mxh-certbot-renew.timer'
            TestedAt = (Get-Date).ToString('o')
        }
        Save-VpsContext -Context $Context
    }
}
