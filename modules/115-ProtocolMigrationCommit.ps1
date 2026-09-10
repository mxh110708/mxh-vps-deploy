@{
    Id        = 'migration-commit'
    Name      = '提交协议生命周期变更并撤销自动回滚'
    Order     = 115
    Roles     = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')
    Requires  = @('final-validation')
    IsEnabled = {
        param($Context)
        $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled
    }
    Invoke    = {
        param($Context)
        $targetRole = [string]$Context.Plan.Migration.TargetRole
        $operation = if ($Context.Plan.Migration.Contains('Operation')) {
            [string]$Context.Plan.Migration.Operation
        } else { 'InstallActivate' }

        if ($operation -in @('InstallActivate', 'InstallStandby', 'Enable')) {
            if ($targetRole -eq 'RealityEntry') {
                if (-not $Context.State.Contains('RealityEgressTest') -or $Context.State.RealityEgressTest.Status -ne 'Passed') {
                    throw '未完成真实 Reality 客户端出口测试，拒绝提交协议变更。'
                }
            }
            elseif ($targetRole -eq 'AnyTlsEntry') {
                if (-not $Context.State.Contains('AnyTlsEgressTest') -or $Context.State.AnyTlsEgressTest.Status -ne 'Passed') {
                    throw '未完成真实 AnyTLS+ECH 客户端出口测试，拒绝提交协议变更。'
                }
            }
            elseif ($targetRole -eq 'ShadowsocksLanding' -and $operation -in @('InstallActivate', 'InstallStandby', 'Enable')) {
                if ($operation -in @('InstallActivate', 'InstallStandby') -and
                    (-not $Context.State.Contains('ShadowsocksSelfTest') -or
                    $Context.State.ShadowsocksSelfTest.Status -ne 'Passed' -or
                    -not @($Context.State.ShadowsocksSelfTest.Results).Count -or
                    @($Context.State.ShadowsocksSelfTest.Results | Where-Object Udp -ne 'Passed').Count)) {
                    throw '未完成 Shadowsocks TCP/UDP 与真实出口自测，拒绝提交协议变更。'
                }
                if (-not $Context.State.Contains('MigrationShadowsocksExternalProbe') -or
                    $Context.State.MigrationShadowsocksExternalProbe.Status -ne 'Passed' -or
                    @($Context.State.MigrationShadowsocksExternalProbe.Results).Count -lt 2 -or
                    @($Context.State.MigrationShadowsocksExternalProbe.Results | Where-Object Udp -ne 'Passed').Count) {
                    throw '未从可信入口完成 Shadowsocks 双核心链式外部实测，拒绝提交协议变更。'
                }
            }
        }

        $final = if ($Context.Plan.Migration.Contains('FinalInventory')) {
            $Context.Plan.Migration.FinalInventory
        } else {
            Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
        }
        $targetAuxPort = if ([bool]$final.RealityEntry.Enabled) { [string]$Context.Plan.Ports.XrayBackup } else { '' }
        $effectiveTargetPort = if ([bool]$final.ShadowsocksLanding.Enabled) {
            [string]$Context.Plan.Ports.LandingShadowsocks
        } else { [string]$Context.Plan.Migration.TargetPrimaryPort }
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-commit.sh' -Parameters @{
            EXPECTED_BACKUP = [string]$Context.State.Migration.RemoteBackupDirectory
            SOURCE_ROLE = [string]$Context.Plan.Migration.SourceRole
            TARGET_ROLE = $targetRole
            TARGET_PORT = $effectiveTargetPort
            TARGET_AUX_PORT = $targetAuxPort
            FINAL_REALITY_ENABLED = ([bool]$final.RealityEntry.Enabled).ToString().ToLowerInvariant()
            FINAL_ANYTLS_ENABLED = ([bool]$final.AnyTlsEntry.Enabled).ToString().ToLowerInvariant()
            FINAL_SHADOWSOCKS_ENABLED = ([bool]$final.ShadowsocksLanding.Enabled).ToString().ToLowerInvariant()
            PRECOMMIT_TARGET_REQUIRED = ($operation -in @('InstallActivate', 'InstallStandby')).ToString().ToLowerInvariant()
            REMOVE_ROLE = if ($operation -eq 'Uninstall') { [string]$Context.Plan.Migration.RemoveRole } else { '' }
        } -TimeoutSeconds 300
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_COMMITTED') {
            throw '远端未返回协议生命周期变更提交成功标记。'
        }

        $Context.Plan.Role = if ($Context.Plan.Migration.Contains('FinalRole')) {
            [string]$Context.Plan.Migration.FinalRole
        } else { $targetRole }
        $Context.Plan['ProtocolInventory'] = Copy-MxhHashtable -Value $final
        $Context.State['ProtocolInventory'] = Copy-MxhHashtable -Value $final

        if ($operation -eq 'Uninstall') {
            $removeRole = [string]$Context.Plan.Migration.RemoveRole
            $protocolModule = @{
                RealityEntry = 'xray-reality'
                AnyTlsEntry = 'sing-box-anytls'
                ShadowsocksLanding = 'sing-box-shadowsocks'
            }[$removeRole]
            $Context.State.Modules[$protocolModule] = [ordered]@{
                Status = 'Uninstalled'; UpdatedAt = (Get-Date).ToString('o'); Message = 'Removed by protocol lifecycle manager'
            }
            $secretName = @{
                RealityEntry = 'Xray'
                AnyTlsEntry = 'AnyTls'
                ShadowsocksLanding = 'Shadowsocks'
            }[$removeRole]
            if ($Context.Secrets.Contains($secretName)) { $Context.Secrets.Remove($secretName) }
            $stateFields = @{
                RealityEntry = @('ClientExports', 'RealityEgressTest', 'LocalHttpsTarget', 'XrayVersion')
                AnyTlsEntry = @('AnyTlsClientExports', 'AnyTlsEgressTest', 'AnyTls')
                ShadowsocksLanding = @('LandingClientExports', 'ShadowsocksSelfTest', 'MigrationShadowsocksExternalProbe', 'SingBoxVersion')
            }[$removeRole]
            foreach ($field in $stateFields) {
                if ($Context.State.Contains($field)) { $Context.State.Remove($field) }
            }

            $archiveFiles = @{
                RealityEntry = @(
                    'client-exports\mihomo-test-primary.yaml', 'client-exports\mihomo-test-backup.yaml',
                    'client-exports\sing-box-outbounds.private.json', 'client-exports\README-private.txt',
                    'server-configs\xray-config.json', 'server-configs\nginx-reality-target.conf',
                    'server-configs\reality-target-fullchain.pem', 'server-configs\reality-target-privkey.private.pem'
                )
                AnyTlsEntry = @(
                    'client-exports\mihomo-anytls-test.yaml', 'client-exports\sing-box-anytls-outbounds.private.json',
                    'client-exports\ech-client-config.pem', 'client-exports\README-anytls-private.txt',
                    'server-configs\sing-box-anytls-config.private.json', 'server-configs\sing-box-anytls.service',
                    'server-configs\anytls-ech-key.private.pem', 'server-configs\anytls-ech-client-config.pem',
                    'server-configs\anytls-fullchain.pem', 'server-configs\anytls-privkey.private.pem'
                )
                ShadowsocksLanding = @(
                    'client-exports\mihomo-shadowsocks-test.yaml', 'client-exports\sing-box-shadowsocks-outbounds.private.json',
                    'client-exports\README-shadowsocks-private.txt', 'server-configs\sing-box-config.private.json',
                    'server-configs\sing-box.service', 'server-configs\sing-box-bind-interface-capability.conf'
                )
            }[$removeRole]
            foreach ($relative in $archiveFiles) {
                $path = Join-Path $Context.ArchivePath $relative
                if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
            }
        }

        $Context.State.Migration.Status = 'Committed'
        $Context.State.Migration.RollbackArmed = $false
        $Context.State.Migration.Committed = $true
        $Context.State.Migration.CommittedAt = (Get-Date).ToString('o')
        $Context.Plan.Migration.Status = 'Committed'
        Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
        Save-VpsContext -Context $Context

        $message = switch ($operation) {
            'InstallActivate' {
                if ($targetRole -eq 'ShadowsocksLanding') {
                    'Shadowsocks 已安装并启用；现有 Reality/AnyTLS 入口保持原状态。'
                }
                else {
                    '新入口协议已安装并启用；原入口协议仍安装在磁盘上，冲突项已停用。'
                }
            }
            'InstallStandby' { '新协议已完成真实验证并保留为停用备用；原运行状态已恢复。' }
            'Enable' { '协议启用状态已切换并完成验收。' }
            'Disable' { '协议已停用但仍保留完整安装与私有配置。' }
            'Uninstall' { '停用协议已卸载；共享 ACME 环境和回滚备份按设计保留。' }
            'NetworkTune' { '独立网络调优已应用；协议、端口和防火墙保持不变。' }
        }
        Write-VpsUi "$message 自动回滚计时器已撤销。" Success
    }
}
