[CmdletBinding()]
param([string]$ProjectRoot=(Split-Path -Parent $PSScriptRoot),[string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $Destination){$Destination=Join-Path $ProjectRoot '.tmp/linux-validation-assets'}
[IO.Directory]::CreateDirectory($Destination)|Out-Null
$catalog=Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'config/versions.json')|ConvertFrom-Json
$old=Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot 'tests/fixtures/linux-upgrade-baseline.json')|ConvertFrom-Json
$assets=@(
    @{name=$old.name;sha256=$old.sha256;source=$old.source},
    @{name=$catalog.sing_box.assets.amd64.name;sha256=$catalog.sing_box.assets.amd64.sha256;source="https://github.com/SagerNet/sing-box/releases/download/v$($catalog.sing_box.version)/$($catalog.sing_box.assets.amd64.name)"},
    @{name=$catalog.mihomo.assets.amd64.name;sha256=$catalog.mihomo.assets.amd64.sha256;source="https://github.com/MetaCubeX/mihomo/releases/download/v$($catalog.mihomo.version)/$($catalog.mihomo.assets.amd64.name)"}
)
foreach($asset in $assets){
    if($asset.name -notmatch '^[A-Za-z0-9.-]+\.(gz)$' -or $asset.sha256 -notmatch '^[0-9a-f]{64}$' -or $asset.source -notmatch '^https://github\.com/(SagerNet/sing-box|MetaCubeX/mihomo)/releases/download/v[0-9.]+/[A-Za-z0-9.-]+$'){throw 'Linux 验证资产目录无效。'}
    $path=Join-Path $Destination $asset.name
    if(Test-Path -LiteralPath $path){
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $asset.sha256){throw '已有 Linux 验证资产校验失败。'}
    }else{
        $candidate=$path+'.download'
        Invoke-WebRequest -Uri $asset.source -OutFile $candidate -TimeoutSec 180
        if((Get-FileHash -LiteralPath $candidate).Hash.ToLowerInvariant() -ne $asset.sha256){throw 'Linux 验证资产下载校验失败。'}
        Move-Item -LiteralPath $candidate -Destination $path
    }
    Write-Host "已校验：$($asset.name)"
}
