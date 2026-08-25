@{
    Id        = 'audit'
    Name      = '只读审计系统、服务、监听与防火墙'
    Order     = 10
    Roles     = @('RealityEntry', 'MonitorOnly', 'AuditOnly')
    Requires  = @('bootstrap-access')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'audit.sh' -Port ([int]$Context.Plan.Server.BootstrapSshPort)
        $audit = [ordered]@{
            OsId = Get-VpsMarkerValue $result.StdOut OS_ID -Required
            OsVersion = Get-VpsMarkerValue $result.StdOut OS_VERSION -Required
            Architecture = Get-VpsMarkerValue $result.StdOut ARCH -Required
            Kernel = Get-VpsMarkerValue $result.StdOut KERNEL -Required
            MemoryKiB = [long](Get-VpsMarkerValue $result.StdOut MEMORY_KIB -Required)
            DiskKiB = [long](Get-VpsMarkerValue $result.StdOut DISK_KIB -Required)
            ExistingServices = Get-VpsMarkerValue $result.StdOut EXISTING_SERVICES
            NftRuleLines = [int](Get-VpsMarkerValue $result.StdOut NFT_LINES -Required)
            Listeners = Get-VpsMarkerValue $result.StdOut LISTENERS
            SshEffective = Get-VpsMarkerValue $result.StdOut SSH_EFFECTIVE
            AuditedAt = (Get-Date).ToString('o')
        }
        $Context.State.Audit = $audit
        Save-VpsContext -Context $Context

        Write-VpsUi "系统：$($audit.OsId) $($audit.OsVersion)，架构：$($audit.Architecture)，内核：$($audit.Kernel)" Info
        Write-VpsUi ("资源：内存约 {0:N0} MiB，根磁盘约 {1:N1} GiB" -f ($audit.MemoryKiB / 1024), ($audit.DiskKiB / 1MB)) Info

        if ($audit.OsId -notin @('debian', 'ubuntu')) {
            throw "当前首版只支持 Debian/Ubuntu，检测到：$($audit.OsId)"
        }
        if ($audit.Architecture -notin @('x86_64', 'amd64', 'aarch64', 'arm64')) {
            throw "当前架构尚未支持：$($audit.Architecture)"
        }
        if ($Context.Plan.Role -ne 'AuditOnly') {
            if ($audit.ExistingServices) {
                throw "检测到既有服务 [$($audit.ExistingServices)]。为防止覆盖，通用新机流程已停止，请先单独审计。"
            }
            if ($audit.NftRuleLines -gt 0) {
                throw "检测到非空 nftables 规则（$($audit.NftRuleLines) 行）。最小模板包含 flush ruleset，不能自动覆盖。"
            }
        }
        Save-VpsJson -Value $audit -Path (Join-Path $Context.ArchivePath 'initial-audit.json') -Private
    }
}
