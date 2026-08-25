@{
    Id        = 'local-https-target'
    Name      = '部署 Reality 本机静态 HTTPS target'
    Order     = 45
    Roles     = @('RealityEntry')
    Requires  = @('certbot-dns')
    IsEnabled = {
        param($Context)
        $Context.Plan.Reality.Contains('TargetMode') -and $Context.Plan.Reality.TargetMode -eq 'LocalOwnedTls'
    }
    Invoke    = {
        param($Context)
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'local-https-target.sh' -Parameters @{
            DOMAIN = [string]$Context.Plan.Reality.ServerName
            PORT = [string]$Context.Plan.Reality.LocalHttpsPort
            CERT_NAME = [string]$Context.Plan.TrustedTls.RealityCertificateName
        } -TimeoutSeconds 1200
        if ($result.StdOut -notmatch 'VPSDEPLOY_LOCAL_HTTPS_OK') {
            throw 'Reality 本机 HTTPS target 未返回成功标记。'
        }
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        $Context.State.BackupDirectories.LocalHttpsTarget = $backup
        $Context.State.LocalHttpsTarget = [ordered]@{
            Listen = "127.0.0.1:$($Context.Plan.Reality.LocalHttpsPort)"
            ServerName = [string]$Context.Plan.Reality.ServerName
            Tls13 = 'Passed'
            Http2 = 'Passed'
            PublicListener = $false
        }
        Save-VpsContext -Context $Context
    }
}
