@{
    Id        = 'network-tuning'
    Name      = '应用独立保守网络调优（RTT 可选）'
    Order     = 60
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        if (-not $Context.Plan.Contains('NetworkTuning')) {
            $settings = if ($Context.NonInteractive) {
                [ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = $null; ReferenceRttMs = $null }
            }
            else {
                Write-VpsUi '旧部署计划没有网络调优输入；现在补充，结果会写回私有计划。' Warning
                Read-VpsNetworkTuningSettings -Role ([string]$Context.Plan.Role)
            }
            $Context.Plan.NetworkTuning = $settings
            Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
        }
        $settings = $Context.Plan.NetworkTuning
        $mode = if ([string]$settings.Mode -eq 'AdaptiveConservative') { 'AdaptiveConservative' } else { 'BaselineOnly' }
        $bandwidth = if ($null -ne $settings.BandwidthMbps) { [int]$settings.BandwidthMbps } else { 0 }
        $referenceRtt = if ($null -ne $settings.ReferenceRttMs) { [int]$settings.ReferenceRttMs } else { 0 }
        $calculated = Get-VpsConservativeNetworkPlan -Role ([string]$Context.Plan.Role) `
            -MemoryKiB ([long]$Context.State.Audit.MemoryKiB) -Mode $mode `
            -BandwidthMbps $bandwidth -ReferenceRttMs $referenceRtt
        $parameters = @{
            ROLE = [string]$calculated.Role
            MEMORY_KIB = [string]$Context.State.Audit.MemoryKiB
            MODE = [string]$calculated.Mode
            BANDWIDTH_MBPS = if ($null -ne $calculated.BandwidthMbps) { [string]$calculated.BandwidthMbps } else { '' }
            REFERENCE_RTT_MS = if ($null -ne $calculated.ReferenceRttMs) { [string]$calculated.ReferenceRttMs } else { '' }
            BUFFER_TARGET_BYTES = [string]$calculated.BufferTargetBytes
            BUFFER_CAP_BYTES = [string]$calculated.BufferCapBytes
            QUEUE_FLOOR = [string]$calculated.QueueFloor
            PROFILE = [string]$calculated.Profile
        }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'network-tuning.sh' -Parameters $parameters
        $bbr = Get-VpsMarkerValue $result.StdOut BBR -Required
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        $bufferMode = Get-VpsMarkerValue $result.StdOut BUFFER_MODE -Required
        $bufferApplied = [long](Get-VpsMarkerValue $result.StdOut BUFFER_APPLIED -Required)
        $queueApplied = [int](Get-VpsMarkerValue $result.StdOut QUEUE_APPLIED -Required)
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.Sysctl = $backup
        $Context.State.BbrEnabled = ($bbr -eq 'true')
        $Context.State.NetworkTuning = [ordered]@{
            Profile = $calculated.Profile
            Mode = $calculated.Mode
            Role = $calculated.Role
            MemoryMiB = $calculated.MemoryMiB
            MemoryTier = $calculated.MemoryTier
            BandwidthMbps = $calculated.BandwidthMbps
            ReferenceRttMs = $calculated.ReferenceRttMs
            BdpBytes = $calculated.BdpBytes
            BufferTargetBytes = $calculated.BufferTargetBytes
            BufferCapBytes = $calculated.BufferCapBytes
            BufferMode = $bufferMode
            BufferAppliedBytes = $bufferApplied
            QueueFloor = $calculated.QueueFloor
            QueueApplied = $queueApplied
            UpdatedAt = (Get-Date).ToString('o')
        }
        Save-VpsContext -Context $Context
        if ($bbr -ne 'true') { Write-VpsUi '当前内核未提供 BBR，已保留 fq/TCP Fast Open/MTU 探测与其余安全参数。' Warning }
        if ($calculated.Mode -eq 'AdaptiveConservative') {
            Write-VpsUi ("调优档案 {0}：内存 {1} MiB，{2} Mbps / {3} ms，缓冲目标 {4:N2} MiB，结果 {5}。" -f `
                    $calculated.Profile, $calculated.MemoryMiB, $calculated.BandwidthMbps, $calculated.ReferenceRttMs, `
                    ($calculated.BufferTargetBytes / 1MB), $bufferMode) Info
        }
        else {
            Write-VpsUi "调优档案 $($calculated.Profile)：只应用基础保守项，不修改 TCP 缓冲区上限。" Info
        }
    }
}
