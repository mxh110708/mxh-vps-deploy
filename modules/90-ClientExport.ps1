@{
    Id        = 'client-export'
    Name      = '生成私有 Mihomo/sing-box 客户端片段'
    Order     = 90
    Roles     = @('RealityEntry')
    Requires  = @('xray-reality')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $exportDir = Join-Path $Context.ArchivePath 'client-exports'
        [IO.Directory]::CreateDirectory($exportDir) | Out-Null
        $primaryMixed = 17891
        $backupMixed = 17892
        $primaryPath = Join-Path $exportDir 'mihomo-test-primary.yaml'
        $hasBackup = $Context.Plan.Ports.XrayBackup -and [int]$Context.Plan.Ports.XrayBackup -gt 0
        $backupPath = if ($hasBackup) { Join-Path $exportDir 'mihomo-test-backup.yaml' } else { $null }
        [IO.File]::WriteAllText($primaryPath, (New-MxhMihomoProfileText -Context $Context `
                    -ServerPort ([int]$Context.Plan.Ports.XrayPrimary) -MixedPort $primaryMixed -IncludeIpv6), [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $primaryPath
        if ($hasBackup) {
            [IO.File]::WriteAllText($backupPath, (New-MxhMihomoProfileText -Context $Context `
                        -ServerPort ([int]$Context.Plan.Ports.XrayBackup) -MixedPort $backupMixed -IncludeIpv6), [Text.UTF8Encoding]::new($false))
            Protect-VpsPrivateFile $backupPath
        }

        $s = $Context.Secrets.Xray
        $realityTarget = Get-MxhRealityTargetSettings -Plan $Context.Plan
        $outbounds = [Collections.Generic.List[object]]::new()
        foreach ($entry in @(
                @{ Tag = "$($Context.Plan.NodeName)-IPv4"; Server = [string]$Context.Plan.Server.IPv4 },
                @{ Tag = "$($Context.Plan.NodeName)-IPv6"; Server = [string]$Context.Plan.Server.IPv6 }
            )) {
            if (-not $entry.Server) { continue }
            $outbounds.Add([ordered]@{
                    type = 'vless'
                    tag = $entry.Tag
                    server = $entry.Server
                    server_port = [int]$Context.Plan.Ports.XrayPrimary
                    uuid = [string]$s.Uuid
                    flow = 'xtls-rprx-vision'
                    packet_encoding = 'xudp'
                    tls = [ordered]@{
                        enabled = $true
                        server_name = [string]$realityTarget.ServerName
                        utls = [ordered]@{ enabled = $true; fingerprint = 'chrome' }
                        reality = [ordered]@{
                            enabled = $true
                            public_key = [string]$s.RealityClientKey
                            short_id = [string]$s.ShortId
                        }
                    }
                })
        }
        $singBoxPath = Join-Path $exportDir 'sing-box-outbounds.private.json'
        Save-VpsJson -Value ([ordered]@{ outbounds = $outbounds }) -Path $singBoxPath -Private

        $notePath = Join-Path $exportDir 'README-private.txt'
        $note = @"
这些文件含 UUID、Reality 客户端密钥和 short-id，只能保存在本地私有归档。

- mihomo-test-primary.yaml：主端口真实握手/出口测试
- mihomo-test-backup.yaml：$(if ($hasBackup) { '救援端口真实握手/出口测试' } else { '此导入实例没有第二个 Reality 入口，因此未生成' })
- sing-box-outbounds.private.json：仅为 outbounds 片段，不是完整 profile

不要直接修改 Clash Verge AppData。需要加入主配置时，请使用客户端权威配置设计器生成、校验并写入你明确选择的独立权威文件。
"@
        [IO.File]::WriteAllText($notePath, $note, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $notePath

        $cores = @(Get-VpsMihomoCorePaths -ProjectRoot $Context.ProjectRoot)
        $testData = Join-Path $exportDir 'syntax-test-data'
        [IO.Directory]::CreateDirectory($testData) | Out-Null
        foreach ($core in $cores) {
            foreach ($profile in @($primaryPath, $backupPath) | Where-Object { $_ }) {
                $test = Invoke-VpsProcess -FilePath $core -ArgumentList @('-t', '-d', $testData, '-f', $profile) -TimeoutSeconds 120
                if ($test.ExitCode -ne 0) { throw "Mihomo 语法测试失败：$(Split-Path -Leaf $core) / $(Split-Path -Leaf $profile)" }
            }
        }
        if ($cores.Count -eq 0) { Write-VpsUi '未找到 Clash Verge Mihomo 核心，已跳过本地语法测试。' Warning }
        $Context.State.ClientExports = [ordered]@{
            PrimaryProfile = $primaryPath
            BackupProfile = $backupPath
            PrimaryMixedPort = $primaryMixed
            BackupMixedPort = if ($hasBackup) { $backupMixed } else { $null }
            MihomoCoresTested = @($cores)
        }
        Save-VpsContext -Context $Context
    }
}
