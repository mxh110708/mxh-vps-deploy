[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectRoot,
    [Parameter(Mandatory)] [string]$SingBoxPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $ProjectRoot 'src\VpsDeploy.Core.psm1') -Force
$work = Join-Path ([IO.Path]::GetTempPath()) ('mxh-sing-box-check-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
try {
    $serverKey = [Convert]::ToBase64String([byte[]](1..16))
    $primaryUserKey = [Convert]::ToBase64String([byte[]](17..32))
    $secondaryUserKey = [Convert]::ToBase64String([byte[]](33..48))
    $context = [pscustomobject]@{
        Plan = [ordered]@{
            NodeName = 'Example-US.Landing'
            Server = [ordered]@{ IPv4 = '192.0.2.20'; IPv6 = '2001:db8::20' }
            Ports = [ordered]@{ LandingShadowsocks = 33456 }
            Shadowsocks = [ordered]@{
                Method = '2022-blake3-aes-128-gcm'
                SecondaryIpv6Enabled = $true
                SecondaryIpv6Address = '2001:db8::20'
                SecondaryBindInterface = 'eth0'
                ClientTransitTag = 'US-West Entry'
            }
        }
        Secrets = [ordered]@{
            Shadowsocks = [ordered]@{
                ServerKey = $serverKey
                PrimaryUserKey = $primaryUserKey
                SecondaryUserKey = $secondaryUserKey
            }
        }
    }
    $serverPath = Join-Path $work 'server.json'
    $serverConfig = New-MxhShadowsocksServerConfig -Context $context
    [IO.File]::WriteAllText($serverPath, ($serverConfig | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))

    $clientPath = Join-Path $work 'client.json'
    $clientConfig = [ordered]@{
        log = [ordered]@{ level = 'warn' }
        outbounds = @(
            [ordered]@{ type = 'direct'; tag = 'US-West Entry' },
            [ordered]@{
                type = 'shadowsocks'
                tag = 'landing'
                server = '192.0.2.20'
                server_port = 33456
                method = '2022-blake3-aes-128-gcm'
                password = $serverKey + ':' + $primaryUserKey
                detour = 'US-West Entry'
            }
        )
        route = [ordered]@{ final = 'landing' }
    }
    [IO.File]::WriteAllText($clientPath, ($clientConfig | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))

    foreach ($config in @($serverPath, $clientPath)) {
        & $SingBoxPath check -c $config
        if ($LASTEXITCODE -ne 0) { throw "sing-box config check failed: $config" }
    }
    Write-Host 'Exact sing-box core checks passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $work) { [IO.Directory]::Delete($work, $true) }
}
