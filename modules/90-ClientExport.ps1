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
        $backupPath = Join-Path $exportDir 'mihomo-test-backup.yaml'
        [IO.File]::WriteAllText($primaryPath, (New-MxhMihomoProfileText -Context $Context `
                    -ServerPort ([int]$Context.Plan.Ports.XrayPrimary) -MixedPort $primaryMixed -IncludeIpv6), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($backupPath, (New-MxhMihomoProfileText -Context $Context `
                    -ServerPort ([int]$Context.Plan.Ports.XrayBackup) -MixedPort $backupMixed -IncludeIpv6), [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $primaryPath
        Protect-VpsPrivateFile $backupPath

        $s = $Context.Secrets.Xray
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
                        server_name = [string]$Context.Plan.Reality.Target
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
- mihomo-test-backup.yaml：救援端口真实握手/出口测试
- sing-box-outbounds.private.json：仅为 outbounds 片段，不是完整 profile

不要直接修改 Clash Verge AppData。需要加入主配置时，只审计并修改 F:\VPS\Clash YAML 下的权威文件；sing-box 同理维护 F:\VPS\Sing-box Config。
"@
        [IO.File]::WriteAllText($notePath, $note, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $notePath

        $cores = @(
            'D:\Program Files\Clash Verge\verge-mihomo.exe',
            'D:\Program Files\Clash Verge\verge-mihomo-alpha.exe'
        ) | Where-Object { Test-Path -LiteralPath $_ }
        $testData = Join-Path $exportDir 'syntax-test-data'
        [IO.Directory]::CreateDirectory($testData) | Out-Null
        foreach ($core in $cores) {
            foreach ($profile in @($primaryPath, $backupPath)) {
                $test = Invoke-VpsProcess -FilePath $core -ArgumentList @('-t', '-d', $testData, '-f', $profile) -TimeoutSeconds 120
                if ($test.ExitCode -ne 0) { throw "Mihomo 语法测试失败：$(Split-Path -Leaf $core) / $(Split-Path -Leaf $profile)" }
            }
        }
        if ($cores.Count -eq 0) { Write-VpsUi '未找到 Clash Verge Mihomo 核心，已跳过本地语法测试。' Warning }
        $Context.State.ClientExports = [ordered]@{
            PrimaryProfile = $primaryPath
            BackupProfile = $backupPath
            PrimaryMixedPort = $primaryMixed
            BackupMixedPort = $backupMixed
            MihomoCoresTested = @($cores)
        }
        Save-VpsContext -Context $Context
    }
}
