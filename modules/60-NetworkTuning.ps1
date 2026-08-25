@{
    Id        = 'network-tuning'
    Name      = '应用保守 BBR/fq 与 MTU 探测基线'
    Order     = 60
    Roles     = @('RealityEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'network-tuning.sh'
        $bbr = Get-VpsMarkerValue $result.StdOut BBR -Required
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.Sysctl = $backup
        $Context.State.BbrEnabled = ($bbr -eq 'true')
        Save-VpsContext -Context $Context
        if ($bbr -ne 'true') { Write-VpsUi '当前内核未提供 BBR，已仅应用 fq/TCP Fast Open/MTU 探测。' Warning }
    }
}
