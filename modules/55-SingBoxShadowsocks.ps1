@{
    Id        = 'sing-box-shadowsocks'
    Name      = '安装 sing-box 并部署 Shadowsocks 2022 落地'
    Order     = 55
    Roles     = @('ShadowsocksLanding')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
    Invoke    = {
        param($Context)

        $arch = [string]$Context.State.Audit.Architecture
        $archKey = if ($arch -in @('x86_64', 'amd64')) { 'amd64' } else { 'arm64' }
        $asset = $Context.Versions.sing_box.assets.$archKey
        $version = [string]$Context.Plan.Shadowsocks.SingBoxVersion
        $installResult = Invoke-VpsRemoteScript -Context $Context -Asset 'sing-box-install.sh' -Parameters @{
            VERSION = $version
            ASSET_NAME = [string]$asset.name
            SHA256 = [string]$asset.sha256
            NEED_BIND_INTERFACE = ([bool]$Context.Plan.Shadowsocks.SecondaryBindInterface).ToString().ToLowerInvariant()
        } -TimeoutSeconds 1200
        $installBackup = Get-VpsMarkerValue $installResult.StdOut BACKUP_DIR -Required
        if (-not $Context.State.Contains('BackupDirectories')) { $Context.State.BackupDirectories = @{} }
        $Context.State.BackupDirectories.SingBoxInstall = $installBackup

        if (-not $Context.Secrets.Contains('Shadowsocks')) {
            $Context.Secrets['Shadowsocks'] = [ordered]@{}
        }
        $credentials = $Context.Secrets.Shadowsocks
        $credentialsChanged = $false
        foreach ($field in @('ServerKey', 'PrimaryUserKey')) {
            if (-not $credentials.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$credentials[$field])) {
                $credentials[$field] = New-MxhRandomBase64Key -Length 16
                $credentialsChanged = $true
            }
        }
        if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled -and
            (-not $credentials.Contains('SecondaryUserKey') -or [string]::IsNullOrWhiteSpace([string]$credentials.SecondaryUserKey))) {
            $credentials['SecondaryUserKey'] = New-MxhRandomBase64Key -Length 16
            $credentialsChanged = $true
        }
        if ($credentialsChanged) {
            Save-VpsContext -Context $Context
        }

        $config = New-MxhShadowsocksServerConfig -Context $Context
        $configJson = $config | ConvertTo-Json -Depth 30
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'sing-box-apply-config.sh' -Parameters @{
            CONFIG_JSON = $configJson
            LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
        } -TimeoutSeconds 600 -SensitiveOutput
        $backup = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
        $Context.State.BackupDirectories.SingBox = $backup

        $testServer = if ($Context.Plan.Server.IPv6) { '::1' } else { '127.0.0.1' }
        $runSelfTest = {
            param([string]$Label, [string]$Password, [string]$IpVersion)

            $test = Invoke-VpsRemoteScript -Context $Context -Asset 'shadowsocks-self-test.sh' -Parameters @{
                METHOD = [string]$Context.Plan.Shadowsocks.Method
                PASSWORD = $Password
                LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
                IP_VERSION = $IpVersion
                TEST_SERVER = $testServer
            } -TimeoutSeconds 180 -SensitiveOutput -AllowFailure
            if ($test.ExitCode -ne 0) {
                $details = ([string]$test.StdOut) + "`n" + ([string]$test.StdErr)
                $phaseMatch = [regex]::Match($details, '(?m)^VPSDEPLOY_SELFTEST_FAILURE_PHASE=([a-z-]+)$')
                $phaseReason = if ($phaseMatch.Success) {
                    switch ($phaseMatch.Groups[1].Value) {
                        'config-check' { '临时 sing-box 客户端配置校验' }
                        'client-start' { '临时 sing-box 客户端启动' }
                        'https' { '代理 HTTPS 与出口 IP' }
                        'udp' { 'UDP DNS 往返' }
                        default { '准备或未分类阶段' }
                    }
                } else { '未报告阶段' }
                $detailReason = switch -Regex ($details) {
                    'Short UDP DNS response' { 'UDP DNS 响应过短'; break }
                    'Invalid UDP DNS response' { 'UDP DNS 响应事务或返回码无效'; break }
                    'network is unreachable|no route to host' { '目标出口网络不可达'; break }
                    'connection refused' { '回环 Shadowsocks 监听拒绝连接'; break }
                    'timed? ?out|i/o timeout' { '代理 HTTPS 或 UDP DNS 往返超时'; break }
                    'Empty Shadowsocks egress' { '代理出口查询返回空结果'; break }
                    'check.*config|configuration.*error|decode.*config' { '临时 sing-box 客户端配置校验失败'; break }
                    default { "未分类远端错误（敏感详情已隐藏，exit=$($test.ExitCode)）" }
                }
                throw "Shadowsocks $Label 功能自测失败：$phaseReason；$detailReason"
            }
            return $test
        }

        $primaryPassword = ([string]$credentials.ServerKey) + ':' + ([string]$credentials.PrimaryUserKey)
        $primaryTest = & $runSelfTest 'IPv4 用户' $primaryPassword '4'
        $primaryEgress = Get-VpsMarkerValue $primaryTest.StdOut EGRESS -Required
        $primaryUdp = Get-VpsMarkerValue $primaryTest.StdOut UDP -Required
        if ($primaryUdp -ne 'yes') { throw 'Shadowsocks 主用户 UDP 功能自测失败。' }
        $testState = [ordered]@{
            PrimaryIpv4Egress = $primaryEgress
            PrimaryUdp = 'Passed'
            TestedAt = (Get-Date).ToString('o')
        }

        if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
            $secondaryPassword = ([string]$credentials.ServerKey) + ':' + ([string]$credentials.SecondaryUserKey)
            $secondaryTest = & $runSelfTest 'IPv6 用户' $secondaryPassword '6'
            $testState.SecondaryIpv6Egress = Get-VpsMarkerValue $secondaryTest.StdOut EGRESS -Required
            $secondaryUdp = Get-VpsMarkerValue $secondaryTest.StdOut UDP -Required
            if ($secondaryUdp -ne 'yes') { throw 'Shadowsocks IPv6 用户 UDP 功能自测失败。' }
            $testState.SecondaryUdp = 'Passed'
        }
        $Context.State.ShadowsocksSelfTest = $testState
        $Context.State.SingBoxVersion = $version
        Save-VpsContext -Context $Context
    }
}
