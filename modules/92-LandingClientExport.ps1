@{
    Id        = 'landing-client-export'
    Name      = '生成 Shadowsocks 落地客户端私有片段'
    Order     = 92
    Roles     = @('ShadowsocksLanding')
    Requires  = @('sing-box-shadowsocks')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)

        $exportDir = Join-Path $Context.ArchivePath 'client-exports'
        [IO.Directory]::CreateDirectory($exportDir) | Out-Null
        $mixedPort = 17893
        $mihomoPath = Join-Path $exportDir 'mihomo-shadowsocks-test.yaml'
        [IO.File]::WriteAllText($mihomoPath, (New-MxhLandingMihomoProfileText -Context $Context -MixedPort $mixedPort), [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $mihomoPath

        $credentials = $Context.Secrets.Shadowsocks
        $outbounds = [Collections.Generic.List[object]]::new()
        $outbounds.Add([ordered]@{
                type = 'shadowsocks'
                tag = "$($Context.Plan.NodeName)-IPv4"
                server = [string]$Context.Plan.Server.IPv4
                server_port = [int]$Context.Plan.Ports.LandingShadowsocks
                method = [string]$Context.Plan.Shadowsocks.Method
                password = ([string]$credentials.ServerKey) + ':' + ([string]$credentials.PrimaryUserKey)
                detour = [string]$Context.Plan.Shadowsocks.ClientTransitTag
            })
        if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
            $outbounds.Add([ordered]@{
                    type = 'shadowsocks'
                    tag = "$($Context.Plan.NodeName)-IPv6"
                    server = [string]$Context.Plan.Server.IPv4
                    server_port = [int]$Context.Plan.Ports.LandingShadowsocks
                    method = [string]$Context.Plan.Shadowsocks.Method
                    password = ([string]$credentials.ServerKey) + ':' + ([string]$credentials.SecondaryUserKey)
                    detour = [string]$Context.Plan.Shadowsocks.ClientTransitTag
                })
        }
        $singBoxPath = Join-Path $exportDir 'sing-box-shadowsocks-outbounds.private.json'
        Save-VpsJson -Value ([ordered]@{ outbounds = $outbounds }) -Path $singBoxPath -Private

        $notePath = Join-Path $exportDir 'README-shadowsocks-private.txt'
        $note = @"
这些文件包含有效 SS2022 组合密码，只能留在本地私有归档。

Mihomo 文件中的 dialer-proxy 已指向：$($Context.Plan.Shadowsocks.ClientTransitTag)
sing-box 片段中的 detour 已指向同名 tag。合并时必须确认主配置中存在该入口组/tag。

不要把纯落地节点作为受限网络直连入口；服务端防火墙仅允许可信入口 VPS 地址。
"@
        [IO.File]::WriteAllText($notePath, $note, [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $notePath

        $cores = @(Get-VpsMihomoCorePaths -ProjectRoot $Context.ProjectRoot)
        $testData = Join-Path $exportDir 'landing-syntax-test-data'
        [IO.Directory]::CreateDirectory($testData) | Out-Null
        foreach ($core in $cores) {
            $test = Invoke-VpsProcess -FilePath $core -ArgumentList @('-t', '-d', $testData, '-f', $mihomoPath) -TimeoutSeconds 120
            if ($test.ExitCode -ne 0) { throw "Mihomo Shadowsocks 语法测试失败：$(Split-Path -Leaf $core)" }
        }
        if ($cores.Count -eq 0) { Write-VpsUi '未找到 Clash Verge Mihomo 核心，已跳过落地片段语法测试。' Warning }
        $Context.State.LandingClientExports = [ordered]@{
            MihomoProfile = $mihomoPath
            SingBoxOutbounds = $singBoxPath
            MihomoCoresTested = @($cores)
        }
        Save-VpsContext -Context $Context
    }
}
