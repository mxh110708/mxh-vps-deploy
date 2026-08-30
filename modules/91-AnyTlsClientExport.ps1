@{
    Id        = 'anytls-client-export'
    Name      = '生成 AnyTLS + ECH 私有客户端片段'
    Order     = 91
    Roles     = @('AnyTlsEntry')
    Requires  = @('sing-box-anytls')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)
        $exportDir = Join-Path $Context.ArchivePath 'client-exports'
        [IO.Directory]::CreateDirectory($exportDir) | Out-Null
        $families = @('IPv4')
        if ($Context.Plan.Server.IPv6) { $families += 'IPv6' }
        $targets = [Collections.Generic.List[object]]::new()
        $mixedPort = 17895
        $outbounds = [Collections.Generic.List[object]]::new()
        foreach ($family in $families) {
            $server = if ($family -eq 'IPv6') { [string]$Context.Plan.Server.IPv6 } else { [string]$Context.Plan.Server.IPv4 }
            $tag = "$($Context.Plan.NodeName)-AnyTLS-$family"
            $outbound = New-MxhAnyTlsClientOutbound -Context $Context -Server $server -Tag $tag
            $outbounds.Add($outbound)
            $suffix = $family.ToLowerInvariant()
            $mihomoName = if ($family -eq 'IPv4') { 'mihomo-anytls-test.yaml' } else { "mihomo-anytls-test-$suffix.yaml" }
            $mihomoPath = Join-Path $exportDir $mihomoName
            $singBoxTestPath = Join-Path $exportDir "sing-box-anytls-test-$suffix.private.json"
            [IO.File]::WriteAllText($mihomoPath, (New-MxhAnyTlsMihomoProfileText -Context $Context -MixedPort $mixedPort -AddressFamily $family), [Text.UTF8Encoding]::new($false))
            Protect-VpsPrivateFile $mihomoPath
            Save-VpsJson -Value (New-MxhSingBoxTestConfig -Outbound $outbound -MixedPort $mixedPort) -Path $singBoxTestPath -Private
            $targets.Add([ordered]@{ AddressFamily = $family; MixedPort = $mixedPort; MihomoProfile = $mihomoPath; SingBoxProfile = $singBoxTestPath })
            $mixedPort++
        }
        $singBoxPath = Join-Path $exportDir 'sing-box-anytls-outbounds.private.json'
        Save-VpsJson -Value ([ordered]@{ outbounds = $outbounds }) -Path $singBoxPath -Private

        $echPath = Join-Path $exportDir 'ech-client-config.pem'
        [IO.File]::WriteAllText($echPath, [string]$Context.Secrets.AnyTls.EchClientConfigPem, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $echPath

        $coreStates = [ordered]@{}
        foreach ($coreName in @('mihomo', 'sing-box')) {
            $coreState = Resolve-VpsClientValidationCore -Context $Context -Core $coreName
            $coreStates[$coreName] = $coreState
            if ($coreState.Status -eq 'SkippedByUser') { continue }
            foreach ($target in $targets) {
                if ($coreName -eq 'mihomo') {
                    $testData = Join-Path $exportDir "syntax-anytls-mihomo-$($target.AddressFamily)"
                    [IO.Directory]::CreateDirectory($testData) | Out-Null
                    $test = Invoke-VpsProcess $coreState.Path @('-t', '-d', $testData, '-f', $target.MihomoProfile) -TimeoutSeconds 120
                }
                else { $test = Invoke-VpsProcess $coreState.Path @('check', '-c', $target.SingBoxProfile) -TimeoutSeconds 120 }
                if ($test.ExitCode -ne 0) { throw "$coreName AnyTLS/ECH 语法测试失败：$($target.AddressFamily)" }
            }
        }

        $notePath = Join-Path $exportDir 'README-anytls-private.txt'
        $note = @"
这些文件含 AnyTLS 密码，只能保存在本地私有归档。ECH client config 是公开参数，但仍随节点配置统一归档。

Mihomo 与 sing-box 都生成 IPv4/IPv6 分离的完整测试配置并保持证书验证开启；Padding scheme 由服务端下发。测试不会读取或修改 Clash Verge AppData，也不会切换系统代理或 TUN。
"@
        [IO.File]::WriteAllText($notePath, $note, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $notePath
        $ipv4 = @($targets | Where-Object AddressFamily -eq 'IPv4')[0]
        $Context.State.AnyTlsClientExports = [ordered]@{
            MihomoProfile = $ipv4.MihomoProfile
            MihomoMixedPort = $ipv4.MixedPort
            SingBoxOutbounds = $singBoxPath
            EchClientConfig = $echPath
            ValidationTargets = $targets.ToArray()
            CoreValidation = $coreStates
        }
        Save-VpsContext -Context $Context
    }
}
