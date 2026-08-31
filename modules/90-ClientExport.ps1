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
        $hasBackup = $Context.Plan.Ports.XrayBackup -and [int]$Context.Plan.Ports.XrayBackup -gt 0
        $entries = [Collections.Generic.List[object]]::new()
        $entries.Add([ordered]@{ Name = 'primary'; ServerPort = [int]$Context.Plan.Ports.XrayPrimary })
        if ($hasBackup) { $entries.Add([ordered]@{ Name = 'backup'; ServerPort = [int]$Context.Plan.Ports.XrayBackup }) }
        $families = @('IPv4')
        if ($Context.Plan.Server.IPv6) { $families += 'IPv6' }

        $targets = [Collections.Generic.List[object]]::new()
        $nextMixedPort = 17891
        foreach ($entry in $entries) {
            foreach ($family in $families) {
                $suffix = $family.ToLowerInvariant()
                $mihomoName = if ($family -eq 'IPv4') { "mihomo-test-$($entry.Name).yaml" } else { "mihomo-test-$($entry.Name)-$suffix.yaml" }
                $mihomoPath = Join-Path $exportDir $mihomoName
                $singBoxPath = Join-Path $exportDir "sing-box-test-$($entry.Name)-$suffix.private.json"
                $mixedPort = $nextMixedPort
                $nextMixedPort++
                [IO.File]::WriteAllText($mihomoPath, (New-MxhMihomoProfileText -Context $Context `
                            -ServerPort $entry.ServerPort -MixedPort $mixedPort -AddressFamily $family), [Text.UTF8Encoding]::new($false))
                Protect-VpsPrivateFile $mihomoPath
                $outbound = New-MxhRealitySingBoxOutbound -Context $Context -ServerPort $entry.ServerPort -AddressFamily $family
                Save-VpsJson -Value (New-MxhSingBoxTestConfig -Outbound $outbound -MixedPort $mixedPort) -Path $singBoxPath -Private
                $targets.Add([ordered]@{
                        Entry = $entry.Name
                        AddressFamily = $family
                        ServerPort = $entry.ServerPort
                        MixedPort = $mixedPort
                        MihomoProfile = $mihomoPath
                        SingBoxProfile = $singBoxPath
                    })
            }
        }

        $s = $Context.Secrets.Xray
        $realityTarget = Get-MxhRealityTargetSettings -Plan $Context.Plan
        $dualStack = [bool]$Context.Plan.Server.IPv6
        $outbounds = [Collections.Generic.List[object]]::new()
        foreach ($entry in @(
                @{ Tag = (Get-MxhAddressFamilyNodeName -BaseName ([string]$Context.Plan.NodeName) -AddressFamily IPv4 -DualStack $dualStack); Server = [string]$Context.Plan.Server.IPv4 },
                @{ Tag = (Get-MxhAddressFamilyNodeName -BaseName ([string]$Context.Plan.NodeName) -AddressFamily IPv6 -DualStack $dualStack); Server = [string]$Context.Plan.Server.IPv6 }
            )) {
            if (-not $entry.Server) { continue }
            $outbounds.Add([ordered]@{
                    type = 'vless'; tag = $entry.Tag; server = $entry.Server
                    server_port = [int]$Context.Plan.Ports.XrayPrimary; uuid = [string]$s.Uuid
                    flow = 'xtls-rprx-vision'; packet_encoding = 'xudp'
                    tls = [ordered]@{
                        enabled = $true; server_name = [string]$realityTarget.ServerName
                        utls = [ordered]@{ enabled = $true; fingerprint = 'chrome' }
                        reality = [ordered]@{ enabled = $true; public_key = [string]$s.RealityClientKey; short_id = [string]$s.ShortId }
                    }
                })
        }
        $outboundFragmentPath = Join-Path $exportDir 'sing-box-outbounds.private.json'
        Save-VpsJson -Value ([ordered]@{ outbounds = $outbounds }) -Path $outboundFragmentPath -Private

        $coreStates = [ordered]@{}
        foreach ($coreName in @('mihomo', 'sing-box')) {
            $coreState = Resolve-VpsClientValidationCore -Context $Context -Core $coreName
            $coreStates[$coreName] = $coreState
            if ($coreState.Status -eq 'SkippedByUser') { continue }
            foreach ($target in $targets) {
                if ($coreName -eq 'mihomo') {
                    $testData = Join-Path $exportDir "syntax-mihomo-$($target.Entry)-$($target.AddressFamily)"
                    [IO.Directory]::CreateDirectory($testData) | Out-Null
                    $test = Invoke-VpsProcess -FilePath $coreState.Path -ArgumentList @('-t', '-d', $testData, '-f', $target.MihomoProfile) -TimeoutSeconds 120
                }
                else {
                    $test = Invoke-VpsProcess -FilePath $coreState.Path -ArgumentList @('check', '-c', $target.SingBoxProfile) -TimeoutSeconds 120
                }
                if ($test.ExitCode -ne 0) { throw "$coreName 语法测试失败：$($target.Entry) / $($target.AddressFamily)" }
            }
        }

        $primaryV4 = @($targets | Where-Object { $_.Entry -eq 'primary' -and $_.AddressFamily -eq 'IPv4' })[0]
        $backupV4 = @($targets | Where-Object { $_.Entry -eq 'backup' -and $_.AddressFamily -eq 'IPv4' } | Select-Object -First 1)
        $Context.State.ClientExports = [ordered]@{
            PrimaryProfile = $primaryV4.MihomoProfile
            BackupProfile = if ($backupV4.Count) { $backupV4[0].MihomoProfile } else { $null }
            PrimaryMixedPort = $primaryV4.MixedPort
            BackupMixedPort = if ($backupV4.Count) { $backupV4[0].MixedPort } else { $null }
            SingBoxOutbounds = $outboundFragmentPath
            ValidationTargets = $targets.ToArray()
            CoreValidation = $coreStates
        }
        $notePath = Join-Path $exportDir 'README-private.txt'
        $note = @"
这些文件含 UUID、Reality 客户端密钥和 short-id，只能保存在本地私有归档。

- mihomo-test-<入口>-<地址族>.yaml：Mihomo 逐端口、逐地址族真实握手/出口测试
- sing-box-test-<入口>-<地址族>.private.json：sing-box 逐端口、逐地址族完整测试配置
- sing-box-outbounds.private.json：用于权威配置合并的 outbounds 片段

测试核心来自项目 vendor 目录，经 SHA-256 校验后解压到项目 .cache；不会读取或修改 Clash Verge AppData，也不会切换系统代理或 TUN。
"@
        [IO.File]::WriteAllText($notePath, $note, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $notePath
        Save-VpsContext -Context $Context
    }
}
