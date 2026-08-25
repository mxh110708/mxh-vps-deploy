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
        $mixedPort = 17894
        $mihomoPath = Join-Path $exportDir 'mihomo-anytls-test.yaml'
        [IO.File]::WriteAllText($mihomoPath, (New-MxhAnyTlsMihomoProfileText -Context $Context -MixedPort $mixedPort), [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $mihomoPath

        $outbounds = [Collections.Generic.List[object]]::new()
        $outbounds.Add((New-MxhAnyTlsClientOutbound -Context $Context -Server ([string]$Context.Plan.Server.IPv4) `
                    -Tag "$($Context.Plan.NodeName)-AnyTLS-IPv4"))
        if ($Context.Plan.Server.IPv6) {
            $outbounds.Add((New-MxhAnyTlsClientOutbound -Context $Context -Server ([string]$Context.Plan.Server.IPv6) `
                        -Tag "$($Context.Plan.NodeName)-AnyTLS-IPv6"))
        }
        $singBoxPath = Join-Path $exportDir 'sing-box-anytls-outbounds.private.json'
        Save-VpsJson -Value ([ordered]@{ outbounds = $outbounds }) -Path $singBoxPath -Private

        $echPath = Join-Path $exportDir 'ech-client-config.pem'
        [IO.File]::WriteAllText($echPath, [string]$Context.Secrets.AnyTls.EchClientConfigPem, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $echPath

        $notePath = Join-Path $exportDir 'README-anytls-private.txt'
        $note = @"
这些文件含 AnyTLS 密码，只能保存在本地私有归档。ECH client config 是公开参数，但仍随节点配置统一归档。

Mihomo 使用 ech-opts.config；sing-box 使用 tls.ech.config。两者都保持证书验证开启。
Padding scheme 由 AnyTLS 服务端在协议内下发，客户端节点不要重复填写。
AnyTLS 与 Xray Reality 共用 TCP 443 时必须互斥，不能同时启动。
"@
        [IO.File]::WriteAllText($notePath, $note, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $notePath

        $cores = @(@(
                'D:\Program Files\Clash Verge\verge-mihomo.exe',
                'D:\Program Files\Clash Verge\verge-mihomo-alpha.exe'
            ) | Where-Object { Test-Path -LiteralPath $_ })
        $testData = Join-Path $exportDir 'anytls-syntax-test-data'
        [IO.Directory]::CreateDirectory($testData) | Out-Null
        foreach ($core in $cores) {
            $test = Invoke-VpsProcess -FilePath $core -ArgumentList @('-t', '-d', $testData, '-f', $mihomoPath) -TimeoutSeconds 120
            if ($test.ExitCode -ne 0) { throw "Mihomo AnyTLS/ECH 语法测试失败：$(Split-Path -Leaf $core)" }
        }
        if ($cores.Count -eq 0) { Write-VpsUi '未找到 Clash Verge Mihomo 核心，已跳过 AnyTLS 片段语法测试。' Warning }
        $Context.State.AnyTlsClientExports = [ordered]@{
            MihomoProfile = $mihomoPath
            MihomoMixedPort = $mixedPort
            SingBoxOutbounds = $singBoxPath
            EchClientConfig = $echPath
            MihomoCoresTested = @($cores)
        }
        Save-VpsContext -Context $Context
    }
}
