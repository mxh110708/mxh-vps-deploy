@{
    Id        = 'migration-commit'
    Name      = '提交协议迁移并停用源协议'
    Order     = 115
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    Requires  = @('final-validation')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        $targetRole = [string]$Context.Plan.Migration.TargetRole
        if ($targetRole -eq 'RealityEntry') {
            if (-not $Context.State.Contains('RealityEgressTest') -or $Context.State.RealityEgressTest.Status -ne 'Passed') {
                throw '未完成真实 Reality 客户端出口测试，拒绝提交迁移。'
            }
        }
        elseif ($targetRole -eq 'AnyTlsEntry') {
            if (-not $Context.State.Contains('AnyTlsEgressTest') -or $Context.State.AnyTlsEgressTest.Status -ne 'Passed') {
                throw '未完成真实 AnyTLS+ECH 客户端出口测试，拒绝提交迁移。'
            }
        }
        else {
            if (-not $Context.State.Contains('ShadowsocksSelfTest') -or
                $Context.State.ShadowsocksSelfTest.PrimaryUdp -ne 'Passed' -or
                -not $Context.State.ShadowsocksSelfTest.PrimaryIpv4Egress) {
                throw '未完成 Shadowsocks TCP/UDP 与真实出口自测，拒绝提交迁移。'
            }
            if (-not $Context.State.Contains('MigrationShadowsocksExternalProbe') -or
                $Context.State.MigrationShadowsocksExternalProbe.Status -ne 'Passed') {
                throw '未从可信入口完成 Shadowsocks 链式外部实测，拒绝提交迁移。'
            }
        }

        $targetAuxPort = if ($targetRole -eq 'RealityEntry') { [string]$Context.Plan.Ports.XrayBackup } else { '' }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-commit.sh' -Parameters @{
            SOURCE_ROLE = [string]$Context.Plan.Migration.SourceRole
            TARGET_ROLE = $targetRole
            TARGET_PORT = [string]$Context.Plan.Migration.TargetPrimaryPort
            TARGET_AUX_PORT = $targetAuxPort
        } -TimeoutSeconds 180
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_COMMITTED') {
            throw '远端未返回协议迁移提交成功标记。'
        }
        $Context.State.Migration.Status = 'Committed'
        $Context.State.Migration.RollbackArmed = $false
        $Context.State.Migration.Committed = $true
        $Context.State.Migration.CommittedAt = (Get-Date).ToString('o')
        $Context.Plan.Migration.Status = 'Committed'
        Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
        Save-VpsContext -Context $Context
        Write-VpsUi '目标协议已验收，源协议服务已停用，自动回滚计时器已撤销。' Success
    }
}
