Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:VpsWizardBackMarker = '__MXH_VPS_WIZARD_BACK__'
$script:VpsWizardCancelMarker = '__MXH_VPS_WIZARD_CANCEL__'
$script:VpsManagedDirectoryName = 'MXH-VPS-Deploy'

function Write-VpsUi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step', 'Muted')]
        [string]$Kind = 'Info'
    )

    $prefix = switch ($Kind) {
        'Success' { '[成功] ' }
        'Warning' { '[注意] ' }
        'Error'   { '[错误] ' }
        'Step'    { '[步骤] ' }
        'Muted'   { '       ' }
        default   { '[信息] ' }
    }
    $color = switch ($Kind) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Step'    { 'Cyan' }
        'Muted'   { 'DarkGray' }
        default   { 'Gray' }
    }
    Write-Host ($prefix + $Message) -ForegroundColor $color
}

function Test-VpsClearCommand {
    param([AllowNull()] [string]$Value)
    if ($null -eq $Value) { return $false }
    return $Value.Trim().ToLowerInvariant() -in @('clear', 'cls')
}

function Test-VpsHelpCommand {
    param([AllowNull()] [string]$Value)
    if ($null -eq $Value) { return $false }
    return $Value.Trim().ToLowerInvariant() -in @('help', 'h', '?')
}

function Clear-VpsScreen {
    try { Clear-Host }
    catch {
        try { [Console]::Clear() }
        catch { }
    }
}

function Show-VpsHelp {
    param([string]$Text)
    Write-Host ''
    Write-Host '帮助说明' -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Write-Host '  主菜单输入 9 退出；子菜单或向导输入 0 返回上一级。'
        Write-Host '  b 和 back 始终作为普通文本，不再承担导航功能。'
        Write-Host '  输入 clear 或 cls 清屏；输入 help 或 h 再次显示帮助。'
    }
    else {
        foreach ($line in $Text -split "`r?`n") { Write-Host ('  ' + $line) }
    }
}

function Merge-VpsHashtable {
    param([hashtable]$Base,[hashtable]$Overlay)
    $result = [ordered]@{}
    if ($Base) { foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] } }
    if ($Overlay) {
        foreach ($key in $Overlay.Keys) {
            if ($result.Contains($key) -and $result[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
                $result[$key] = Merge-VpsHashtable -Base $result[$key] -Overlay $Overlay[$key]
            }
            else { $result[$key] = $Overlay[$key] }
        }
    }
    return $result
}

function Get-VpsAppDefaults {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $genericPath = Join-Path $ProjectRoot 'config\app-defaults.json'
    $localPath = Join-Path $ProjectRoot 'config\app-defaults.local.json'
    $generic = if (Test-Path -LiteralPath $genericPath -PathType Leaf) { Read-VpsJsonHashtable -Path $genericPath } else { [ordered]@{} }
    $local = if (Test-Path -LiteralPath $localPath -PathType Leaf) { Read-VpsJsonHashtable -Path $localPath } else { [ordered]@{} }
    return Merge-VpsHashtable -Base $generic -Overlay $local
}

function Resolve-VpsPortablePath {
    param([Parameter(Mandatory)][string]$ProjectRoot,[AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot $expanded))
}

function Get-VpsMihomoCorePaths {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $settings = Get-VpsAppDefaults -ProjectRoot $ProjectRoot
    $found = [Collections.Generic.List[string]]::new()
    foreach ($value in @($env:MXH_VPS_MIHOMO_STABLE,$env:MXH_VPS_MIHOMO_ALPHA,[string]$settings.mihomo.stable_executable,[string]$settings.mihomo.alpha_executable)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $path = Resolve-VpsPortablePath -ProjectRoot $ProjectRoot -Path $value
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and $path -notin $found) { $found.Add($path) }
    }
    foreach ($name in @('verge-mihomo.exe','verge-mihomo-alpha.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source -notin $found) { $found.Add($command.Source) }
    }
    $searchRoots=[Collections.Generic.List[string]]::new()
    foreach($root in @($env:ProgramFiles,${env:ProgramFiles(x86)})){if(-not[string]::IsNullOrWhiteSpace($root)){$searchRoots.Add($root)}}
    if(-not[string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)){$searchRoots.Add((Join-Path $env:LOCALAPPDATA 'Programs'))}
    foreach ($root in $searchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($relative in @('Clash Verge\verge-mihomo.exe','Clash Verge\verge-mihomo-alpha.exe','Clash Verge Rev\verge-mihomo.exe','Clash Verge Rev\verge-mihomo-alpha.exe')) {
            $path = Join-Path $root $relative
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and $path -notin $found) { $found.Add($path) }
        }
    }
    foreach ($registryRoot in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($item in @(Get-ItemProperty $registryRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and [string]$_.DisplayName -match 'Clash Verge' })) {
            $location = ([string]$item.InstallLocation).Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($location)) { continue }
            foreach ($name in @('verge-mihomo.exe','verge-mihomo-alpha.exe')) {
                $path = Join-Path $location $name
                if ((Test-Path -LiteralPath $path -PathType Leaf) -and $path -notin $found) { $found.Add($path) }
            }
        }
    }
    return @($found)
}

function Read-VpsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$ValidationMessage = '输入无效，请重新输入。',
        [switch]$AllowEmpty,
        [switch]$AllowBack,
        [switch]$ZeroIsValue,
        [string]$HelpText
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $backHint = if ($AllowBack) {
            if ($ZeroIsValue) { '（本字段的 0 是有效数值；返回请在上一层菜单操作）' }
            else { '（输入 0 返回上一级）' }
        } else { '' }
        $value = Read-Host ($Prompt + $suffix + $backHint)
        if ($null -eq $value) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        if (Test-VpsClearCommand $value) {
            Clear-VpsScreen
            continue
        }
        if (Test-VpsHelpCommand $value) {
            $navigationHelp = if ($AllowBack) {
                if ($ZeroIsValue) { '；本字段的 0 是有效数值，返回请在上一层菜单操作' }
                else { '；输入 0 返回上一级' }
            } else { '' }
            Show-VpsHelp $(if ($HelpText) { $HelpText } else { "请按提示输入此字段；clear/cls 清屏$navigationHelp。" })
            continue
        }
        if ($AllowBack -and -not $ZeroIsValue -and $value.Trim() -eq '0') {
            throw [InvalidOperationException]::new($script:VpsWizardBackMarker)
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
        if ([string]::IsNullOrWhiteSpace($value) -and -not $AllowEmpty) {
            Write-VpsUi '该项不能为空。' Warning
            continue
        }
        if ($Validate -and -not (& $Validate $value)) {
            Write-VpsUi $ValidationMessage Warning
            continue
        }
        return $value
    }
}

function Read-VpsYesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [bool]$Default = $true,
        [switch]$AllowBack
    )

    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    if ($AllowBack) { $hint += ' [0=返回]' }
    while ($true) {
        $rawAnswer = Read-Host "$Prompt $hint"
        if ($null -eq $rawAnswer) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        $answer = $rawAnswer.Trim().ToLowerInvariant()
        if (Test-VpsClearCommand $answer) {
            Clear-VpsScreen
            continue
        }
        if (Test-VpsHelpCommand $answer) {
            Show-VpsHelp '输入 y/yes/是 表示确认；输入 n/no/否 表示拒绝；留空采用方括号中的默认值。'
            continue
        }
        if ($AllowBack -and $answer -eq '0') {
            throw [InvalidOperationException]::new($script:VpsWizardBackMarker)
        }
        if (-not $answer) { return $Default }
        if ($answer -in @('y', 'yes', '是', '好', '1')) { return $true }
        if ($answer -in @('n', 'no', '否', '不')) { return $false }
        Write-VpsUi '请输入 y 或 n。' Warning
    }
}

function Read-VpsMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string[]]$Options,
        [int]$Default = 1,
        [switch]$AllowBack,
        [string]$BackLabel = '返回上一级',
        [string]$HelpText
    )

    $showMenu = {
        Write-Host ''
        Write-Host $Title -ForegroundColor Cyan
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i])
        }
        if ($AllowBack) { Write-Host ("  0. {0}" -f $BackLabel) }
        Write-Host '  clear / cls. 清除当前屏幕输出' -ForegroundColor DarkGray
        Write-Host '  help / h. 查看帮助说明' -ForegroundColor DarkGray
    }
    & $showMenu
    while ($true) {
        $raw = Read-Host "请选择 [$Default]"
        if ($null -eq $raw) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        if (Test-VpsClearCommand $raw) {
            Clear-VpsScreen
            & $showMenu
            continue
        }
        if (Test-VpsHelpCommand $raw) {
            Show-VpsHelp $HelpText
            & $showMenu
            continue
        }
        if ($AllowBack -and $raw.Trim() -eq '0') {
            throw [InvalidOperationException]::new($script:VpsWizardBackMarker)
        }
        if (-not $raw) { return $Default }
        $choice = 0
        if ([int]::TryParse($raw, [ref]$choice) -and $choice -ge 1 -and $choice -le $Options.Count) {
            return $choice
        }
        Write-VpsUi '请输入列表中的编号。' Warning
    }
}

function Test-VpsWizardBackError {
    param([Parameter(Mandatory)] $ErrorRecord)
    return $ErrorRecord.Exception.Message -eq $script:VpsWizardBackMarker
}

function Test-VpsNavigationError {
    param([Parameter(Mandatory)] $ErrorRecord)
    return $ErrorRecord.Exception.Message -in @($script:VpsWizardBackMarker, $script:VpsWizardCancelMarker)
}

function Get-VpsNavigationMessage {
    param([Parameter(Mandatory)] $ErrorRecord)
    if ($ErrorRecord.Exception.Message -eq $script:VpsWizardCancelMarker) {
        return '已取消当前操作，未开始执行新的远端模块。'
    }
    return '已返回上一级。'
}

function ConvertFrom-VpsSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Security.SecureString]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function New-VpsRandomString {
    [CmdletBinding()]
    param([int]$Length = 28)

    if ($Length -lt 16) { throw '随机秘密长度不能小于 16。' }
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789_-%@'
    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $builder = [Text.StringBuilder]::new($Length)
    foreach ($byte in $bytes) {
        [void]$builder.Append($alphabet[$byte % $alphabet.Length])
    }
    return $builder.ToString()
}

function Get-VpsRandomPort {
    [CmdletBinding()]
    param([int[]]$Exclude = @())

    for ($attempt = 0; $attempt -lt 1000; $attempt++) {
        $bytes = [byte[]]::new(4)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $value = [BitConverter]::ToUInt32($bytes, 0)
        $port = 20000 + ($value % 40000)
        if ($port -notin $Exclude) { return [int]$port }
    }
    throw '无法生成不冲突的高位端口。'
}

function Get-MxhAnyTlsOfficialPaddingScheme {
    return @(
        'stop=8',
        '0=30-30',
        '1=100-400',
        '2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000',
        '3=9-9,500-1000',
        '4=500-1000',
        '5=500-1000',
        '6=500-1000',
        '7=500-1000'
    )
}

function New-MxhAnyTlsPaddingScheme {
    [CmdletBinding()]
    param()

    # Keep the reference scheme's initial eight-write shape while varying each
    # instance once.  The 1100-byte ceiling leaves room below a typical MTU
    # after TLS/TCP/IP overhead and avoids turning fingerprint variation into a
    # throughput or fragmentation experiment.
    $newRange = {
        param([int]$LowMinimum, [int]$LowMaximum, [int]$HighMinimum, [int]$HighMaximum)
        $low = [Security.Cryptography.RandomNumberGenerator]::GetInt32($LowMinimum, $LowMaximum + 1)
        $highFloor = [Math]::Max($low, $HighMinimum)
        $high = [Security.Cryptography.RandomNumberGenerator]::GetInt32($highFloor, $HighMaximum + 1)
        return "$low-$high"
    }
    $newLargeRange = { & $newRange 480 600 800 1100 }
    $packet2 = @(
        (& $newRange 384 464 480 576),
        (& $newLargeRange),
        (& $newLargeRange),
        (& $newLargeRange),
        (& $newLargeRange)
    )
    return @(
        'stop=8',
        "0=$(& $newRange 24 48 48 80)",
        "1=$(& $newRange 96 160 320 448)",
        "2=$($packet2 -join ',c,')",
        "3=$(& $newRange 8 16 16 24),$(& $newLargeRange)",
        "4=$(& $newLargeRange)",
        "5=$(& $newLargeRange)",
        "6=$(& $newLargeRange)",
        "7=$(& $newLargeRange)"
    )
}

function Get-MxhAnyTlsPaddingScheme {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)

    if ($Plan.Contains('AnyTls') -and $Plan.AnyTls.Contains('PaddingScheme')) {
        $configured = @($Plan.AnyTls.PaddingScheme | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($configured.Count -gt 0) { return $configured }
    }
    return @(Get-MxhAnyTlsOfficialPaddingScheme)
}

function Read-VpsNetworkTuningSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')] [string]$Role,
        [switch]$AllowBack
    )

    Write-VpsUi '套餐标称带宽是必填参考值；脚本不会把网卡协商速率或一次测速当成套餐带宽。参考 RTT 可不提供。' Info
    $bandwidth = [int](Read-VpsText '套餐标称带宽（Mbps，例如 100 或 1000）' -AllowBack:$AllowBack -Validate {
            param($v)
            $n = 0
            [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 100000
        } -ValidationMessage '请输入 1–100000 之间的整数 Mbps。')
    if ($Role -eq 'MonitorOnly' -or
        -not (Read-VpsYesNo '是否有可信的代表性 RTT，用于计算额外的保守缓冲区？' $false -AllowBack:$AllowBack)) {
        return [ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = $bandwidth; ReferenceRttMs = $null }
    }
    $rttPrompt = if ($Role -in @('RealityEntry', 'AnyTlsEntry')) {
        '主要使用地到该入口 VPS 的典型 RTT（ms）'
    }
    else {
        '常用入口 VPS 到该落地机的典型 RTT（ms）'
    }
    $referenceRtt = [int](Read-VpsText $rttPrompt -AllowBack:$AllowBack -Validate {
            param($v)
            $n = 0
            [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 2000
        } -ValidationMessage '请输入 1–2000 之间的整数毫秒值。')
    return [ordered]@{
        Mode = 'AdaptiveConservative'
        BandwidthMbps = $bandwidth
        ReferenceRttMs = $referenceRtt
    }
}

function Get-VpsConservativeNetworkPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly')] [string]$Role,
        [Parameter(Mandatory)] [long]$MemoryKiB,
        [ValidateSet('BaselineOnly', 'AdaptiveConservative')] [string]$Mode = 'BaselineOnly',
        [int]$BandwidthMbps = 0,
        [int]$ReferenceRttMs = 0
    )

    if ($MemoryKiB -lt 131072) { throw '审计得到的内存小于 128 MiB，拒绝计算网络调优参数。' }
    $memoryMiB = [long][Math]::Floor($MemoryKiB / 1024)
    if ($memoryMiB -le 512) {
        $memoryTier = 'tiny'
        $bufferCap = 4MB
    }
    elseif ($memoryMiB -le 1024) {
        $memoryTier = 'small'
        $bufferCap = 8MB
    }
    elseif ($memoryMiB -le 2048) {
        $memoryTier = 'medium'
        $bufferCap = 16MB
    }
    else {
        $memoryTier = 'standard'
        $bufferCap = 32MB
    }
    $roleSlug = switch ($Role) {
        'RealityEntry' { 'entry' }
        'AnyTlsEntry' { 'entry' }
        'ShadowsocksLanding' { 'landing' }
        default { 'monitor' }
    }
    if ($BandwidthMbps -lt 0 -or $BandwidthMbps -gt 100000) { throw '标称带宽必须在 1–100000 Mbps；旧计划缺失时可为 0。' }
    $bandwidthTier = if ($BandwidthMbps -le 0) { 'unknown' } elseif ($BandwidthMbps -le 100) { 'low' } elseif ($BandwidthMbps -le 500) { 'medium' } elseif ($BandwidthMbps -le 2000) { 'high' } else { 'very-high' }
    $bandwidthQueue = if ($BandwidthMbps -le 0) { 0 } elseif ($BandwidthMbps -le 100) { 512 } elseif ($BandwidthMbps -le 500) { 1024 } elseif ($BandwidthMbps -le 2000) { 2048 } else { 4096 }
    $roleQueue = switch ($Role) {
        'RealityEntry' { 1024 }
        'AnyTlsEntry' { 1024 }
        'ShadowsocksLanding' { 2048 }
        default { 0 }
    }
    $queueFloor = [Math]::Max($roleQueue, $bandwidthQueue)
    $bdpBytes = [long]0
    $bufferTarget = [long]0
    if ($Mode -eq 'AdaptiveConservative') {
        if ($Role -eq 'MonitorOnly') { throw 'MonitorOnly 不启用自适应缓冲区调优。' }
        if ($BandwidthMbps -lt 1 -or $BandwidthMbps -gt 100000) { throw '标称带宽必须在 1–100000 Mbps。' }
        if ($ReferenceRttMs -lt 1 -or $ReferenceRttMs -gt 2000) { throw '参考 RTT 必须在 1–2000 ms。' }
        $bdpBytes = [long]$BandwidthMbps * [long]$ReferenceRttMs * 125L
        $minimum = if ($Role -in @('RealityEntry', 'AnyTlsEntry')) { 2MB } else { 1MB }
        $wanted = [Math]::Max([long]$minimum, $bdpBytes * 2L)
        $bufferTarget = [Math]::Min([long]$bufferCap, [long]$wanted)
    }
    $modeSlug = if ($Mode -eq 'AdaptiveConservative') { 'adaptive' } else { 'baseline' }
    return [ordered]@{
        Profile = "${roleSlug}-${memoryTier}-${bandwidthTier}-${modeSlug}"
        Mode = $Mode
        Role = $Role
        MemoryMiB = $memoryMiB
        MemoryTier = $memoryTier
        BandwidthMbps = if ($BandwidthMbps -gt 0) { $BandwidthMbps } else { $null }
        BandwidthTier = $bandwidthTier
        ReferenceRttMs = if ($Mode -eq 'AdaptiveConservative') { $ReferenceRttMs } else { $null }
        BdpBytes = $bdpBytes
        BufferTargetBytes = $bufferTarget
        BufferCapBytes = [long]$bufferCap
        QueueFloor = $queueFloor
    }
}

function Test-VpsIpAddress {
    param([string]$Value, [ValidateSet('IPv4', 'IPv6')] [string]$Family)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $false }
    if ($Family -eq 'IPv4') { return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork }
    return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
}

function ConvertTo-VpsIpAllowlist {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Value)

    $ipv4 = [Collections.Generic.List[string]]::new()
    $ipv6 = [Collections.Generic.List[string]]::new()
    $items = @($Value -split '[,;\s]+' | Where-Object { $_ } | Sort-Object -Unique)
    if ($items.Count -eq 0) { throw '至少需要一个可信入口 IP。' }
    foreach ($item in $items) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($item, [ref]$parsed)) { throw "无效 IP：$item" }
        if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            $ipv4.Add($parsed.ToString())
        }
        elseif ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
            $ipv6.Add($parsed.ToString())
        }
        else { throw "不支持的地址类型：$item" }
    }
    return [ordered]@{ IPv4 = $ipv4.ToArray(); IPv6 = $ipv6.ToArray() }
}

function Test-VpsSafePathSegment {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and
        $Value -notmatch '[\\/]' -and $Value -notin @('.', '..')
}

function Test-VpsArchiveRoot {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        $candidate = $Value.Trim().Trim('"')
        if (-not [IO.Path]::IsPathFullyQualified($candidate)) { return $false }
        $rawFullPath = [IO.Path]::GetFullPath($candidate)
        $fullPath = $rawFullPath.TrimEnd('\', '/')
        $pathRoot = [IO.Path]::GetPathRoot($rawFullPath).TrimEnd('\', '/')
        return -not [string]::IsNullOrWhiteSpace($fullPath) -and
            -not $fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Test-VpsNodeName {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]{1,79}$'
}

function Test-VpsHostName {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value.Length -le 253 -and
        $Value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -and
        $Value.Contains('.')
}

function Get-VpsVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ProjectRoot)

    $path = Join-Path $ProjectRoot 'config\versions.json'
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Get-VpsManagedArchivePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstanceRoot,
        [Parameter(Mandatory)] [string]$Provider,
        [Parameter(Mandatory)] [string]$Instance
    )
    $instanceDirectory = Join-Path (Join-Path $InstanceRoot $Provider) $Instance
    return Join-Path $instanceDirectory $script:VpsManagedDirectoryName
}

function Get-VpsExistingPlanPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$InstanceDirectory)
    foreach ($candidate in @(
            (Join-Path (Join-Path $InstanceDirectory $script:VpsManagedDirectoryName) 'deployment-plan.json'),
            (Join-Path $InstanceDirectory 'deployment-plan.json')
        )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Resolve-VpsXrayVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [ValidateSet('FixedVerified', 'LatestStable')] [string]$Channel = 'FixedVerified'
    )
    $versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    if ($Channel -eq 'FixedVerified') { return [string]$versions.xray.version }
    $testVersion = [Environment]::GetEnvironmentVariable('MXH_VPS_TEST_XRAY_LATEST')
    if ($testVersion) {
        if ($testVersion -notmatch '^\d+\.\d+\.\d+$') { throw '测试注入的 Xray 版本格式无效。' }
        return $testVersion
    }
    try {
        $api = if ($versions.xray.latest_stable_api) { [string]$versions.xray.latest_stable_api } else { 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' }
        $release = Invoke-RestMethod -Method Get -Headers @{ 'User-Agent' = 'MXH-VPS-Deploy' } -Uri $api -TimeoutSec 20
        if ([bool]$release.draft -or [bool]$release.prerelease) { throw 'GitHub latest 指向草稿或预发行版。' }
        $resolved = ([string]$release.tag_name).TrimStart('v')
        if ($resolved -notmatch '^\d+\.\d+\.\d+$') { throw '官方 latest 标签格式无法识别。' }
        return $resolved
    }
    catch {
        throw "无法从 XTLS/Xray-core 官方发布页解析最新稳定版：$($_.Exception.Message)。可返回选择当前固定验证版。"
    }
}

function New-VpsInteractivePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$InstanceRoot
    )

    $versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    $defaultTransitTag = [string](Get-MxhClientLayoutTemplate -ProjectRoot $ProjectRoot).Value.region_groups[0]
    Write-Host ''
    Write-Host 'MXH VPS Deploy - 新部署向导' -ForegroundColor White
    Write-Host '支持初始密码或服务商现有私钥；现有 OpenSSH 私钥默认复用，也可明确选择生成新的管理密钥。' -ForegroundColor DarkGray
    Write-Host '所有可返回的文本、是/否和编号输入统一使用 0；b/back 均按普通内容处理。第一项输入 0 返回主菜单。' -ForegroundColor DarkGray

    $defaultInstanceRoot = [IO.Path]::GetFullPath($InstanceRoot.Trim().Trim('"')).TrimEnd('\', '/')

    $wizard = [ordered]@{
        InstanceRoot = $defaultInstanceRoot
        Provider = $null
        Instance = $null
        NodeName = $null
        IPv4 = $null
        IPv6 = $null
        BootstrapPort = 22
        BootstrapAuth = 'Password'
        BootstrapKeyPath = $null
        SshKeyMode = 'GenerateManaged'
        Role = 'RealityEntry'
        AdminUser = 'admin'
        ManualPorts = $false
        PortBasis = $null
        AutoSshPrimary = $null
        AutoSshRescue = $null
        AutoXrayBackup = $null
        AutoLandingPort = $null
        SshPrimary = $null
        SshRescue = $null
        XrayBackup = $null
        LandingPort = $null
        TargetMode = 'ExternalAudited'
        Target = $null
        RealityServerName = $null
        RealityTargetAddress = $null
        LocalHttpsPort = 8443
        ForceIpv4 = $true
        AnyTlsServerName = $null
        EchPublicName = $null
        AnyTlsPaddingScheme = @()
        XrayVersionChannel = 'FixedVerified'
        XrayVersion = [string]$versions.xray.version
        CloudflareZoneName = $null
        CertbotEmail = $null
        CloudflareTokenFile = $null
        AllowlistInput = $null
        TrustedEntryIps = [ordered]@{ IPv4 = @(); IPv6 = @() }
        ClientTransitTag = $defaultTransitTag
        SecondaryIpv6Enabled = $false
        SecondaryIpv6Address = $null
        SecondaryBindInterface = $null
        NetworkAdaptive = $null
        BandwidthMbps = $null
        ReferenceRttMs = $null
        EnableKomari = $null
        KomariEndpoint = [string]$versions.komari_agent.endpoint_default
    }

    $getInstancePath = { Join-Path (Join-Path ([string]$wizard.InstanceRoot) ([string]$wizard.Provider)) ([string]$wizard.Instance) }
    $getArchivePath = { Join-Path (& $getInstancePath) $script:VpsManagedDirectoryName }
    $ensureAutoPorts = {
        $basis = [string]$wizard.BootstrapPort
        if ($wizard.PortBasis -ne $basis -or -not $wizard.AutoSshPrimary) {
            $usedPorts = @([int]$wizard.BootstrapPort, 443)
            $wizard.AutoSshPrimary = Get-VpsRandomPort -Exclude $usedPorts
            $usedPorts += [int]$wizard.AutoSshPrimary
            $wizard.AutoSshRescue = Get-VpsRandomPort -Exclude $usedPorts
            $usedPorts += [int]$wizard.AutoSshRescue
            $wizard.AutoXrayBackup = Get-VpsRandomPort -Exclude $usedPorts
            $usedPorts += [int]$wizard.AutoXrayBackup
            $wizard.AutoLandingPort = Get-VpsRandomPort -Exclude $usedPorts
            $wizard.PortBasis = $basis
        }
        if (-not $wizard.ManualPorts) {
            $wizard.SshPrimary = $wizard.AutoSshPrimary
            $wizard.SshRescue = $wizard.AutoSshRescue
            $wizard.XrayBackup = $wizard.AutoXrayBackup
            $wizard.LandingPort = $wizard.AutoLandingPort
        }
        else {
            if (-not $wizard.SshPrimary) { $wizard.SshPrimary = $wizard.AutoSshPrimary }
            if (-not $wizard.SshRescue) { $wizard.SshRescue = $wizard.AutoSshRescue }
            if (-not $wizard.XrayBackup) { $wizard.XrayBackup = $wizard.AutoXrayBackup }
            if (-not $wizard.LandingPort) { $wizard.LandingPort = $wizard.AutoLandingPort }
        }
    }
    $clearTrustedTlsState = {
        $wizard.CloudflareZoneName = $null
        $wizard.CertbotEmail = $null
        $wizard.CloudflareTokenFile = $null
    }
    $clearRoleSpecificState = {
        $wizard.TargetMode = 'ExternalAudited'
        $wizard.Target = $null
        $wizard.RealityServerName = $null
        $wizard.RealityTargetAddress = $null
        $wizard.ForceIpv4 = $true
        $wizard.AnyTlsServerName = $null
        $wizard.EchPublicName = $null
        $wizard.AnyTlsPaddingScheme = @()
        & $clearTrustedTlsState
        $wizard.AllowlistInput = $null
        $wizard.TrustedEntryIps = [ordered]@{ IPv4 = @(); IPv6 = @() }
        $wizard.ClientTransitTag = $defaultTransitTag
        $wizard.SecondaryIpv6Enabled = $false
        $wizard.SecondaryIpv6Address = $null
        $wizard.SecondaryBindInterface = $null
        $wizard.NetworkAdaptive = $null
        $wizard.BandwidthMbps = $null
        $wizard.ReferenceRttMs = $null
        & $ensureAutoPorts
        $wizard.XrayBackup = $wizard.AutoXrayBackup
        $wizard.LandingPort = $wizard.AutoLandingPort
    }

    $steps = @(
        [pscustomobject]@{
            Id = 'archive-root'; ShouldRun = { $true }; Run = {
                $value = Read-VpsText 'VPS 私有归档根目录（不会立即创建）' `
                    -Default ([string]$wizard.InstanceRoot) -AllowBack -Validate ${function:Test-VpsArchiveRoot} `
                    -ValidationMessage '请输入不是磁盘根目录的完整绝对路径，例如某个私有数据目录下的 VPS-Instances。'
                $wizard.InstanceRoot = [IO.Path]::GetFullPath($value.Trim().Trim('"')).TrimEnd('\', '/')
            }
        },
        [pscustomobject]@{
            Id = 'provider'; ShouldRun = { $true }; Run = {
                $old = [string]$wizard.Provider
                $value = Read-VpsText '服务商名称' -Default $old -AllowBack -Validate ${function:Test-VpsSafePathSegment} `
                    -ValidationMessage '名称不能包含路径分隔符或 Windows 非法字符。'
                if ($old -and $old -ne $value) {
                    $wizard.NodeName = $null
                    $wizard.CloudflareTokenFile = $null
                }
                $wizard.Provider = $value
            }
        },
        [pscustomobject]@{
            Id = 'instance'; ShouldRun = { $true }; Run = {
                $old = [string]$wizard.Instance
                while ($true) {
                    $value = Read-VpsText '实例名称' -Default $old -AllowBack -Validate ${function:Test-VpsSafePathSegment} `
                        -ValidationMessage '名称不能包含路径分隔符或 Windows 非法字符。'
                    $candidateInstance = Join-Path (Join-Path ([string]$wizard.InstanceRoot) ([string]$wizard.Provider)) $value
                    $candidatePlan = Get-VpsExistingPlanPath -InstanceDirectory $candidateInstance
                    if (-not $candidatePlan) { break }
                    Write-VpsUi "该实例已有部署计划：$candidatePlan" Warning
                    Write-VpsUi '请换一个实例名称，或逐项输入 0 返回主菜单后选择【继续未完成部署】。' Info
                    $old = $value
                }
                if ($old -and $old -ne $value) {
                    $wizard.NodeName = $null
                    $wizard.CloudflareTokenFile = $null
                }
                $wizard.Instance = $value
            }
        },
        [pscustomobject]@{
            Id = 'node-name'; ShouldRun = { $true }; Run = {
                $suggested = (([string]$wizard.Provider + '-' + [string]$wizard.Instance) -replace '[^A-Za-z0-9._-]', '-') -replace '-+', '-'
                $default = if ($wizard.NodeName) { [string]$wizard.NodeName } else { $suggested }
                $wizard.NodeName = Read-VpsText '客户端节点名称' -Default $default -AllowBack `
                    -Validate ${function:Test-VpsNodeName} -ValidationMessage '节点名只允许字母、数字、点、下划线和连字符。'
            }
        },
        [pscustomobject]@{
            Id = 'ipv4'; ShouldRun = { $true }; Run = {
                $wizard.IPv4 = Read-VpsText '服务器 IPv4' -Default ([string]$wizard.IPv4) -AllowBack `
                    -Validate { param($v) Test-VpsIpAddress $v IPv4 } -ValidationMessage '请输入有效的公网 IPv4 地址。'
            }
        },
        [pscustomobject]@{
            Id = 'ipv6'; ShouldRun = { $true }; Run = {
                $old = [string]$wizard.IPv6
                $value = Read-VpsText '服务器 IPv6（没有则直接回车）' -Default $old -AllowEmpty -AllowBack `
                    -Validate { param($v) -not $v -or (Test-VpsIpAddress $v IPv6) } `
                    -ValidationMessage '请输入有效 IPv6，或留空。'
                $wizard.IPv6 = if ($value) { $value } else { $null }
                if ($old -ne [string]$wizard.IPv6) {
                    $wizard.SecondaryIpv6Enabled = $false
                    $wizard.SecondaryIpv6Address = $null
                    $wizard.SecondaryBindInterface = $null
                }
            }
        },
        [pscustomobject]@{
            Id = 'bootstrap-port'; ShouldRun = { $true }; Run = {
                $old = [int]$wizard.BootstrapPort
                $wizard.BootstrapPort = [int](Read-VpsText '服务商当前 SSH 端口' -Default $old.ToString() -AllowBack `
                    -Validate { param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535 })
                if ($old -ne [int]$wizard.BootstrapPort) { & $ensureAutoPorts }
            }
        },
        [pscustomobject]@{
            Id = 'bootstrap-auth'; ShouldRun = { $true }; Run = {
                $default = if ($wizard.BootstrapAuth -eq 'ExistingKey') { 2 } else { 1 }
                $choice = Read-VpsMenu '服务商初始 root 登录方式' @(
                    '密码登录（由 OpenSSH 直接询问）',
                    '现有私钥登录（DMIT 等仅密钥模板）'
                ) $default -AllowBack
                $newAuth = if ($choice -eq 2) { 'ExistingKey' } else { 'Password' }
                if ($wizard.BootstrapAuth -ne $newAuth) {
                    $wizard.BootstrapKeyPath = $null
                    $wizard.SshKeyMode = if ($newAuth -eq 'ExistingKey') { 'ReuseExisting' } else { 'GenerateManaged' }
                }
                $wizard.BootstrapAuth = $newAuth
            }
        },
        [pscustomobject]@{
            Id = 'bootstrap-key'; ShouldRun = { $wizard.BootstrapAuth -eq 'ExistingKey' }; Run = {
                $inputPath = Read-VpsText '现有服务商私钥文件的完整路径' -Default ([string]$wizard.BootstrapKeyPath) -AllowBack -Validate {
                    param($v)
                    $candidate = $v.Trim().Trim('"')
                    Test-Path -LiteralPath $candidate -PathType Leaf
                } -ValidationMessage '找不到该私钥文件，请输入文件本身而不是目录。'
                $wizard.BootstrapKeyPath = (Resolve-Path -LiteralPath $inputPath.Trim().Trim('"')).Path
                Write-VpsUi '该私钥默认会复制到实例受管子目录并使用规范文件名；原文件与服务商面板记录不会改变。' Info
            }
        },
        [pscustomobject]@{
            Id = 'managed-key-mode'; ShouldRun = { $wizard.BootstrapAuth -eq 'ExistingKey' }; Run = {
                $default = if ($wizard.SshKeyMode -eq 'GenerateManaged') { 2 } else { 1 }
                $choice = Read-VpsMenu 'SSH 管理密钥策略' @(
                    '复用现有 OpenSSH 私钥（推荐；不轮换服务器公钥）',
                    '生成新的实例管理密钥并保留原密钥作为引导/救援'
                ) $default -AllowBack
                $wizard.SshKeyMode = if ($choice -eq 1) { 'ReuseExisting' } else { 'GenerateManaged' }
            }
        },
        [pscustomobject]@{
            Id = 'role'; ShouldRun = { $true }; Run = {
                $roleValues = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding', 'MonitorOnly', 'AuditOnly')
                $default = [Array]::IndexOf($roleValues, [string]$wizard.Role) + 1
                if ($default -lt 1) { $default = 1 }
                $choice = Read-VpsMenu '这台 VPS 的部署角色' @(
                    'Reality 入口节点（推荐）',
                    'AnyTLS + 可信 TLS + ECH 入口节点',
                    'Shadowsocks 2022 纯落地节点',
                    '仅 SSH/防火墙/Komari 监控',
                    '建立实例专用 SSH 公钥后执行审计，不配置系统'
                ) $default -AllowBack
                $newRole = $roleValues[$choice - 1]
                if ($wizard.Role -ne $newRole) { & $clearRoleSpecificState }
                $wizard.Role = $newRole
                if ($newRole -eq 'AnyTlsEntry' -and @($wizard.AnyTlsPaddingScheme).Count -eq 0) {
                    $wizard.AnyTlsPaddingScheme = @(New-MxhAnyTlsPaddingScheme)
                }
            }
        },
        [pscustomobject]@{
            Id = 'xray-version'; ShouldRun = { $wizard.Role -eq 'RealityEntry' }; Run = {
                $default = if ($wizard.XrayVersionChannel -eq 'LatestStable') { 2 } else { 1 }
                $choice = Read-VpsMenu 'Xray 版本通道' @(
                    "当前固定验证版（$($versions.xray.version)，推荐）",
                    'XTLS/Xray-core 官方最新稳定版（部署计划会记录解析到的具体版本）'
                ) $default -AllowBack
                $wizard.XrayVersionChannel = if ($choice -eq 2) { 'LatestStable' } else { 'FixedVerified' }
                $wizard.XrayVersion = Resolve-VpsXrayVersion -ProjectRoot $ProjectRoot -Channel $wizard.XrayVersionChannel
                Write-VpsUi "本次将使用 Xray $($wizard.XrayVersion)；安装脚本来源仍按 versions.json 固定并校验 SHA-256。" Info
            }
        },
        [pscustomobject]@{
            Id = 'admin-user'; ShouldRun = { $true }; Run = {
                $wizard.AdminUser = Read-VpsText '日常管理用户' -Default ([string]$wizard.AdminUser) -AllowBack `
                    -Validate { param($v) $v -match '^[a-z_][a-z0-9_-]{0,30}$' -and $v -ne 'root' } `
                    -ValidationMessage '请输入合法且不是 root 的 Linux 用户名。'
            }
        },
        [pscustomobject]@{
            Id = 'manual-ports'; ShouldRun = { $true }; Run = {
                & $ensureAutoPorts
                $wizard.ManualPorts = Read-VpsYesNo '是否手动指定高位端口？' ([bool]$wizard.ManualPorts) -AllowBack
                if (-not $wizard.ManualPorts) { & $ensureAutoPorts }
            }
        },
        [pscustomobject]@{
            Id = 'ssh-primary'; ShouldRun = { [bool]$wizard.ManualPorts }; Run = {
                $wizard.SshPrimary = [int](Read-VpsText 'SSH 主端口' -Default ([string]$wizard.SshPrimary) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -ne [int]$wizard.BootstrapPort
                } -ValidationMessage '请输入 20000–59999 内且不与初始 SSH 端口冲突的端口。')
            }
        },
        [pscustomobject]@{
            Id = 'ssh-rescue'; ShouldRun = { [bool]$wizard.ManualPorts }; Run = {
                $wizard.SshRescue = [int](Read-VpsText 'SSH 救援端口' -Default ([string]$wizard.SshRescue) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin @([int]$wizard.BootstrapPort, [int]$wizard.SshPrimary)
                } -ValidationMessage '请输入未与初始 SSH/主 SSH 冲突的 20000–59999 端口。')
            }
        },
        [pscustomobject]@{
            Id = 'xray-backup'; ShouldRun = { [bool]$wizard.ManualPorts -and $wizard.Role -eq 'RealityEntry' }; Run = {
                $wizard.XrayBackup = [int](Read-VpsText 'Xray 救援端口' -Default ([string]$wizard.XrayBackup) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin @([int]$wizard.BootstrapPort, [int]$wizard.SshPrimary, [int]$wizard.SshRescue, 443)
                } -ValidationMessage '请输入未与 SSH/443 冲突的 20000–59999 端口。')
            }
        },
        [pscustomobject]@{
            Id = 'landing-port'; ShouldRun = { [bool]$wizard.ManualPorts -and $wizard.Role -eq 'ShadowsocksLanding' }; Run = {
                $wizard.LandingPort = [int](Read-VpsText 'Shadowsocks TCP/UDP 端口' -Default ([string]$wizard.LandingPort) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin @([int]$wizard.BootstrapPort, [int]$wizard.SshPrimary, [int]$wizard.SshRescue, 443)
                } -ValidationMessage '请输入未与 SSH/443 冲突的 20000–59999 端口。')
            }
        },
        [pscustomobject]@{
            Id = 'reality-target-mode'; ShouldRun = { $wizard.Role -eq 'RealityEntry' }; Run = {
                $default = if ($wizard.TargetMode -eq 'LocalOwnedTls') { 2 } else { 1 }
                $choice = Read-VpsMenu 'REALITY target 模式' @(
                    '外部大学/机构/企业 target（严格审计）',
                    '自有域名 + 本机静态 HTTPS target'
                ) $default -AllowBack
                $newMode = if ($choice -eq 2) { 'LocalOwnedTls' } else { 'ExternalAudited' }
                if ($wizard.TargetMode -ne $newMode) {
                    $wizard.Target = $null
                    $wizard.RealityServerName = $null
                    $wizard.RealityTargetAddress = $null
                    & $clearTrustedTlsState
                }
                $wizard.TargetMode = $newMode
            }
        },
        [pscustomobject]@{
            Id = 'reality-target'; ShouldRun = { $wizard.Role -eq 'RealityEntry' }; Run = {
                $old = [string]$wizard.Target
                $prompt = if ($wizard.TargetMode -eq 'LocalOwnedTls') {
                    '本机 HTTPS target 域名（只填域名）'
                } else { 'REALITY target（只填域名，不含 https://）' }
                $wizard.Target = Read-VpsText $prompt -Default $old -AllowBack `
                    -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入规范域名。'
                $wizard.RealityServerName = $wizard.Target
                $wizard.RealityTargetAddress = if ($wizard.TargetMode -eq 'LocalOwnedTls') {
                    "127.0.0.1:$($wizard.LocalHttpsPort)"
                } else { "$($wizard.Target):443" }
                if ($old -and $old -ne $wizard.Target -and $wizard.TargetMode -eq 'LocalOwnedTls') {
                    & $clearTrustedTlsState
                }
                if ($wizard.TargetMode -eq 'LocalOwnedTls') {
                    Write-VpsUi 'Xray 将回落到 127.0.0.1 的静态 HTTPS 服务，不会把自有域名解析回公网 443。' Info
                }
                else {
                    Write-VpsUi 'target 应是预期长期运营的大学、机构或成熟企业网站，不能只凭品牌或一次 ping 判断。' Warning
                }
            }
        },
        [pscustomobject]@{
            Id = 'reality-target-confirm'; ShouldRun = { $wizard.Role -eq 'RealityEntry' -and $wizard.TargetMode -eq 'ExternalAudited' }; Run = {
                if (-not (Read-VpsYesNo '你确认该候选不是个人小站，并允许脚本从 VPS 严格审计？' $true -AllowBack)) {
                    Write-VpsUi '已返回 target 输入项，请更换候选。' Warning
                    throw [InvalidOperationException]::new($script:VpsWizardBackMarker)
                }
            }
        },
        [pscustomobject]@{
            Id = 'anytls-server-name'; ShouldRun = { $wizard.Role -eq 'AnyTlsEntry' }; Run = {
                $old = [string]$wizard.AnyTlsServerName
                $wizard.AnyTlsServerName = Read-VpsText 'AnyTLS 证书域名/内部 SNI（只填域名）' -Default $old -AllowBack `
                    -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入规范域名。'
                if ($old -and $old -ne $wizard.AnyTlsServerName) { & $clearTrustedTlsState }
            }
        },
        [pscustomobject]@{
            Id = 'ech-public-name'; ShouldRun = { $wizard.Role -eq 'AnyTlsEntry' }; Run = {
                $wizard.EchPublicName = Read-VpsText 'ECH 对外 public name（必须与内部 SNI 不同）' -Default ([string]$wizard.EchPublicName) -AllowBack `
                    -Validate { param($v) (Test-VpsHostName $v) -and $v -ne $wizard.AnyTlsServerName } `
                    -ValidationMessage '请输入另一个规范域名，不能与 AnyTLS 内部 SNI 相同。'
            }
        },
        [pscustomobject]@{
            Id = 'force-ipv4'; ShouldRun = { $wizard.Role -in @('RealityEntry', 'AnyTlsEntry') }; Run = {
                $wizard.ForceIpv4 = Read-VpsYesNo '是否强制代理网站流量从 VPS IPv4 出口？' ([bool]$wizard.ForceIpv4) -AllowBack
            }
        },
        [pscustomobject]@{
            Id = 'cloudflare-zone'; ShouldRun = {
                $wizard.Role -eq 'AnyTlsEntry' -or ($wizard.Role -eq 'RealityEntry' -and $wizard.TargetMode -eq 'LocalOwnedTls')
            }; Run = {
                $domain = if ($wizard.Role -eq 'AnyTlsEntry') { [string]$wizard.AnyTlsServerName } else { [string]$wizard.RealityServerName }
                $labels = @($domain -split '\.')
                $suggested = if ($labels.Count -ge 2) { ($labels[-2..-1] -join '.') } else { $domain }
                $default = if ($wizard.CloudflareZoneName) { [string]$wizard.CloudflareZoneName } else { $suggested }
                $wizard.CloudflareZoneName = Read-VpsText 'Cloudflare Zone 根域名' -Default $default -AllowBack `
                    -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入 Cloudflare 中的完整根域名。'
            }
        },
        [pscustomobject]@{
            Id = 'certbot-email'; ShouldRun = {
                $wizard.Role -eq 'AnyTlsEntry' -or ($wizard.Role -eq 'RealityEntry' -and $wizard.TargetMode -eq 'LocalOwnedTls')
            }; Run = {
                $wizard.CertbotEmail = Read-VpsText 'ACME/Let''s Encrypt 联系邮箱' -Default ([string]$wizard.CertbotEmail) -AllowBack -Validate {
                    param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                } -ValidationMessage '请输入有效邮箱地址。'
            }
        },
        [pscustomobject]@{
            Id = 'cloudflare-token'; ShouldRun = {
                $wizard.Role -eq 'AnyTlsEntry' -or ($wizard.Role -eq 'RealityEntry' -and $wizard.TargetMode -eq 'LocalOwnedTls')
            }; Run = {
                $defaultPath = if ($wizard.CloudflareTokenFile) {
                    [string]$wizard.CloudflareTokenFile
                } else { Join-Path (& $getInstancePath) 'cloudflare-certbot-token.private.txt' }
                $value = Read-VpsText 'Cloudflare Certbot Token 本地私有文件' -Default $defaultPath -AllowBack `
                    -Validate { param($v) Test-Path -LiteralPath $v -PathType Leaf } `
                    -ValidationMessage '找不到 Token 文件；请先保存到实例私有归档。'
                $wizard.CloudflareTokenFile = (Resolve-Path -LiteralPath $value).Path
                Write-VpsUi 'Token 只会通过 SSH 标准输入传到服务器 root-only 凭据文件，不写入计划、日志或 Git。' Info
            }
        },
        [pscustomobject]@{
            Id = 'landing-allowlist'; ShouldRun = { $wizard.Role -eq 'ShadowsocksLanding' }; Run = {
                while ($true) {
                    try {
                        $value = Read-VpsText '允许连接落地端口的入口 VPS 公网 IP（多个用逗号分隔）' `
                            -Default ([string]$wizard.AllowlistInput) -AllowBack
                        $wizard.TrustedEntryIps = ConvertTo-VpsIpAllowlist $value
                        $wizard.AllowlistInput = $value
                        Write-VpsUi '落地端口不会向全网开放；nftables 仅允许上面填写的可信入口 IP 访问 TCP+UDP。' Warning
                        break
                    }
                    catch {
                        if (Test-VpsWizardBackError $_) { throw }
                        Write-VpsUi $_.Exception.Message Warning
                    }
                }
            }
        },
        [pscustomobject]@{
            Id = 'landing-transit-tag'; ShouldRun = { $wizard.Role -eq 'ShadowsocksLanding' }; Run = {
                $wizard.ClientTransitTag = Read-VpsText '客户端链式连接使用的入口组/tag' -Default ([string]$wizard.ClientTransitTag) -AllowBack -Validate {
                    param($v)
                    -not [string]::IsNullOrWhiteSpace($v) -and $v -notin @('Proxy', "$($wizard.NodeName)-IPv4", "$($wizard.NodeName)-IPv6")
                } -ValidationMessage '入口组/tag 不能与生成的 Proxy 或落地节点名称重复。'
            }
        },
        [pscustomobject]@{
            Id = 'secondary-ipv6-enabled'; ShouldRun = { $wizard.Role -eq 'ShadowsocksLanding' -and [bool]$wizard.IPv6 }; Run = {
                $wizard.SecondaryIpv6Enabled = Read-VpsYesNo '是否增加独立 IPv6 出口用户？' ([bool]$wizard.SecondaryIpv6Enabled) -AllowBack
                if (-not $wizard.SecondaryIpv6Enabled) {
                    $wizard.SecondaryIpv6Address = $null
                    $wizard.SecondaryBindInterface = $null
                }
            }
        },
        [pscustomobject]@{
            Id = 'secondary-ipv6-address'; ShouldRun = { $wizard.Role -eq 'ShadowsocksLanding' -and [bool]$wizard.IPv6 -and [bool]$wizard.SecondaryIpv6Enabled }; Run = {
                $default = if ($wizard.SecondaryIpv6Address) { [string]$wizard.SecondaryIpv6Address } else { [string]$wizard.IPv6 }
                $wizard.SecondaryIpv6Address = Read-VpsText 'IPv6 出口源地址' -Default $default -AllowBack `
                    -Validate { param($v) Test-VpsIpAddress $v IPv6 } -ValidationMessage '请输入本机实际配置的 IPv6 地址。'
            }
        },
        [pscustomobject]@{
            Id = 'secondary-bind-interface'; ShouldRun = { $wizard.Role -eq 'ShadowsocksLanding' -and [bool]$wizard.IPv6 -and [bool]$wizard.SecondaryIpv6Enabled }; Run = {
                $value = Read-VpsText 'IPv6 出口接口（一般留空；多网卡时填写）' -Default ([string]$wizard.SecondaryBindInterface) -AllowEmpty -AllowBack `
                    -Validate { param($v) -not $v -or $v -match '^[A-Za-z0-9_.:-]{1,32}$' }
                $wizard.SecondaryBindInterface = if ($value) { $value } else { $null }
            }
        },
        [pscustomobject]@{
            Id = 'network-adaptive'; ShouldRun = { $wizard.Role -in @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding') }; Run = {
                Write-VpsUi '标称带宽是必填的套餐信息；参考 RTT 可不填。只有提供可信 RTT 时才启用 BDP 缓冲区计算。' Info
                $default = if ($null -eq $wizard.NetworkAdaptive) { $false } else { [bool]$wizard.NetworkAdaptive }
                $wizard.NetworkAdaptive = Read-VpsYesNo '是否提供代表性 RTT 并计算额外的保守缓冲区？' $default -AllowBack
                if (-not $wizard.NetworkAdaptive) {
                    $wizard.ReferenceRttMs = $null
                }
            }
        },
        [pscustomobject]@{
            Id = 'network-bandwidth'; ShouldRun = { $wizard.Role -in @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding') }; Run = {
                $wizard.BandwidthMbps = [int](Read-VpsText '套餐标称带宽（Mbps，例如 100 或 1000）' -Default ([string]$wizard.BandwidthMbps) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 100000
                } -ValidationMessage '请输入 1–100000 之间的整数 Mbps。')
            }
        },
        [pscustomobject]@{
            Id = 'network-rtt'; ShouldRun = { $wizard.Role -in @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding') -and [bool]$wizard.NetworkAdaptive }; Run = {
                $prompt = if ($wizard.Role -in @('RealityEntry', 'AnyTlsEntry')) {
                    '主要使用地到该入口 VPS 的典型 RTT（ms）'
                } else { '常用入口 VPS 到该落地机的典型 RTT（ms）' }
                $wizard.ReferenceRttMs = [int](Read-VpsText $prompt -Default ([string]$wizard.ReferenceRttMs) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 2000
                } -ValidationMessage '请输入 1–2000 之间的整数毫秒值。')
            }
        },
        [pscustomobject]@{
            Id = 'komari-enabled'; ShouldRun = { $wizard.Role -ne 'AuditOnly' }; Run = {
                $default = if ($null -eq $wizard.EnableKomari) { $true } else { [bool]$wizard.EnableKomari }
                $wizard.EnableKomari = Read-VpsYesNo '是否安装并纳管 Komari Agent？' $default -AllowBack
            }
        },
        [pscustomobject]@{
            Id = 'komari-endpoint'; ShouldRun = { $wizard.Role -ne 'AuditOnly' -and [bool]$wizard.EnableKomari }; Run = {
                $wizard.KomariEndpoint = Read-VpsText 'Komari 站点地址' -Default ([string]$wizard.KomariEndpoint) -AllowBack `
                    -Validate { param($v) $uri = $null; [Uri]::TryCreate($v, 'Absolute', [ref]$uri) -and $uri.Scheme -eq 'https' }
            }
        }
    )

    $buildPlan = {
        & $ensureAutoPorts
        $archivePath = & $getArchivePath
        $trustedTlsEnabled = $wizard.Role -eq 'AnyTlsEntry' -or `
            ($wizard.Role -eq 'RealityEntry' -and $wizard.TargetMode -eq 'LocalOwnedTls')
        $networkTuning = if ($wizard.Role -in @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding') -and [bool]$wizard.NetworkAdaptive) {
            [ordered]@{
                Mode = 'AdaptiveConservative'
                BandwidthMbps = [int]$wizard.BandwidthMbps
                ReferenceRttMs = [int]$wizard.ReferenceRttMs
            }
        } else {
            [ordered]@{
                Mode = 'BaselineOnly'
                BandwidthMbps = if ($wizard.Role -in @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')) { [int]$wizard.BandwidthMbps } else { $null }
                ReferenceRttMs = $null
            }
        }
        [ordered]@{
        SchemaVersion = 3
        CreatedAt = (Get-Date).ToString('o')
        Provider = $wizard.Provider
        Instance = $wizard.Instance
        NodeName = $wizard.NodeName
        Role = $wizard.Role
        ProtocolInventory = [ordered]@{
            SchemaVersion = 1
            RealityEntry = [ordered]@{
                Installed = ($wizard.Role -eq 'RealityEntry'); Enabled = ($wizard.Role -eq 'RealityEntry')
                Active = ($wizard.Role -eq 'RealityEntry'); Partial = $false; Service = 'xray.service'
            }
            AnyTlsEntry = [ordered]@{
                Installed = ($wizard.Role -eq 'AnyTlsEntry'); Enabled = ($wizard.Role -eq 'AnyTlsEntry')
                Active = ($wizard.Role -eq 'AnyTlsEntry'); Partial = $false; Service = 'sing-box-anytls.service'
            }
            ShadowsocksLanding = [ordered]@{
                Installed = ($wizard.Role -eq 'ShadowsocksLanding'); Enabled = ($wizard.Role -eq 'ShadowsocksLanding')
                Active = ($wizard.Role -eq 'ShadowsocksLanding'); Partial = $false; Service = 'sing-box.service'
            }
        }
        Server = [ordered]@{
            IPv4 = $wizard.IPv4
            IPv6 = $wizard.IPv6
            BootstrapUser = 'root'
            BootstrapSshPort = [int]$wizard.BootstrapPort
            BootstrapAuth = $wizard.BootstrapAuth
            BootstrapKeyPath = $wizard.BootstrapKeyPath
        }
        SshKey = [ordered]@{
            Mode = if ($wizard.BootstrapAuth -eq 'ExistingKey') { [string]$wizard.SshKeyMode } else { 'GenerateManaged' }
            SourcePrivateKeyPath = if ($wizard.BootstrapAuth -eq 'ExistingKey') { [string]$wizard.BootstrapKeyPath } else { $null }
            ManagedFileName = if ($wizard.BootstrapAuth -eq 'ExistingKey' -and $wizard.SshKeyMode -eq 'ReuseExisting') { 'id_vps_management' } else { 'id_ed25519' }
            PreserveSource = $true
        }
        AdminUser = $wizard.AdminUser
        Ports = [ordered]@{
            SshPrimary = [int]$wizard.SshPrimary
            SshRescue = [int]$wizard.SshRescue
            XrayPrimary = 443
            XrayBackup = if ($wizard.Role -eq 'RealityEntry') { [int]$wizard.XrayBackup } else { $null }
            AnyTlsPrimary = if ($wizard.Role -eq 'AnyTlsEntry') { 443 } else { $null }
            LandingShadowsocks = if ($wizard.Role -eq 'ShadowsocksLanding') { [int]$wizard.LandingPort } else { $null }
        }
        Reality = [ordered]@{
            Target = $wizard.Target
            TargetMode = $wizard.TargetMode
            ServerName = $wizard.RealityServerName
            TargetAddress = $wizard.RealityTargetAddress
            LocalHttpsPort = [int]$wizard.LocalHttpsPort
            ForceIpv4Egress = [bool]$wizard.ForceIpv4
            TargetSamples = [int]$versions.target_audit.samples
            TargetMaxMedianMs = [int]$versions.target_audit.maximum_median_ms
            XrayVersion = [string]$wizard.XrayVersion
            XrayVersionChannel = [string]$wizard.XrayVersionChannel
        }
        AnyTls = [ordered]@{
            Enabled = ($wizard.Role -eq 'AnyTlsEntry')
            ServerName = $wizard.AnyTlsServerName
            EchPublicName = $wizard.EchPublicName
            SingBoxVersion = $versions.sing_box.version
            ForceIpv4Egress = [bool]$wizard.ForceIpv4
            PaddingSchemeMode = if ($wizard.Role -eq 'AnyTlsEntry') { 'PerInstanceConservativeV1' } else { $null }
            PaddingScheme = @($wizard.AnyTlsPaddingScheme)
        }
        TrustedTls = [ordered]@{
            Enabled = $trustedTlsEnabled
            ZoneName = $wizard.CloudflareZoneName
            CertbotEmail = $wizard.CertbotEmail
            CloudflareTokenFile = $wizard.CloudflareTokenFile
            AnyTlsCertificateName = 'mxh-anytls'
            RealityCertificateName = 'mxh-reality-target'
        }
        Shadowsocks = [ordered]@{
            Method = '2022-blake3-aes-128-gcm'
            SingBoxVersion = $versions.sing_box.version
            TrustedEntryIPv4s = @($wizard.TrustedEntryIps.IPv4)
            TrustedEntryIPv6s = @($wizard.TrustedEntryIps.IPv6)
            ClientTransitTag = $wizard.ClientTransitTag
            SecondaryIpv6Enabled = [bool]$wizard.SecondaryIpv6Enabled
            SecondaryIpv6Address = $wizard.SecondaryIpv6Address
            SecondaryBindInterface = $wizard.SecondaryBindInterface
        }
        NetworkTuning = $networkTuning
        Firewall = [ordered]@{ Mode = 'ManagedNftables' }
        Komari = [ordered]@{
            Enabled = if ($wizard.Role -eq 'AuditOnly') { $false } else { [bool]$wizard.EnableKomari }
            Endpoint = $wizard.KomariEndpoint
            AgentVersion = $versions.komari_agent.version
        }
        Paths = [ordered]@{
            InstanceDirectory = (& $getInstancePath)
            Archive = $archivePath
            KeyDirectory = (Join-Path $archivePath 'ssh')
        }
        }
    }

    $index = 0
    while ($true) {
        while ($index -lt $steps.Count) {
            $step = $steps[$index]
            if (-not (& $step.ShouldRun)) {
                $index++
                continue
            }
            try {
                & $step.Run
                $index++
            }
            catch {
                if (-not (Test-VpsWizardBackError $_)) { throw }
                $previous = -1
                for ($candidate = $index - 1; $candidate -ge 0; $candidate--) {
                    if (& $steps[$candidate].ShouldRun) {
                        $previous = $candidate
                        break
                    }
                }
                if ($previous -lt 0) {
                    throw [InvalidOperationException]::new($script:VpsWizardBackMarker)
                }
                else {
                    $index = $previous
                    Write-VpsUi "返回上一项：$($steps[$previous].Id)" Muted
                }
            }
        }

        $plan = & $buildPlan
        $existingPlan = Get-VpsExistingPlanPath -InstanceDirectory ([string]$plan.Paths.InstanceDirectory)
        if ($existingPlan) {
            throw "该实例已有部署计划：${existingPlan}。请使用【继续未完成部署】，不要新建覆盖。"
        }

        Show-VpsPlanSummary -Plan $plan
        try {
            $reviewChoice = Read-VpsMenu '请核对部署摘要' @(
                '确认方案并继续',
                '取消本次向导（不写入任何部署计划）'
            ) 1 -AllowBack
        }
        catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $reviewChoice = 0
        }
        if ($reviewChoice -eq 1) { return $plan }
        if ($reviewChoice -eq 2) {
            throw [OperationCanceledException]::new($script:VpsWizardCancelMarker)
        }

        $previous = -1
        for ($candidate = $steps.Count - 1; $candidate -ge 0; $candidate--) {
            if (& $steps[$candidate].ShouldRun) {
                $previous = $candidate
                break
            }
        }
        if ($previous -lt 0) { throw '向导内部错误：找不到可返回的输入项。' }
        $index = $previous
        Write-VpsUi "返回修改：$($steps[$previous].Id)" Muted
    }
}

function Protect-VpsPrivateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $strict = [Environment]::GetEnvironmentVariable('MXH_VPS_STRICT_LOCAL_ACL') -eq '1'
    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $commands = @(
            @($Path, '/inheritance:r'),
            @($Path, '/grant:r', "${identity}:(F)", 'SYSTEM:(F)')
        )
        foreach ($arguments in $commands) {
            $result = Invoke-VpsProcess -FilePath 'icacls.exe' -ArgumentList $arguments -TimeoutSeconds 30
            if ($result.ExitCode -ne 0) {
                $message = "无法收紧私有文件 ACL：$Path。文件仍已保存，请确认该目录只由当前 Windows 账户使用。"
                if ($strict) { throw $message }
                Write-VpsUi $message Warning
                return
            }
        }
    }
    else {
        & chmod 600 -- $Path
        if ($LASTEXITCODE -ne 0) {
            $message = "无法设置私有文件权限：$Path"
            if ($strict) { throw $message }
            Write-VpsUi $message Warning
        }
    }
}

function Save-VpsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [string]$Path,
        [switch]$Private
    )

    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    if ($Private) { Protect-VpsPrivateFile -Path $Path }
}

function Read-VpsJsonHashtable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
}

function Initialize-VpsContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Plan,
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    $archive = [string]$Plan.Paths.Archive
    if ($DryRun) {
        return [pscustomobject]@{
            ProjectRoot = $ProjectRoot
            Plan = $Plan
            ArchivePath = $archive
            PlanPath = (Join-Path $archive 'deployment-plan.json')
            SecretsPath = (Join-Path $archive 'deployment-secrets.private.json')
            StatePath = (Join-Path $archive 'deployment-state.json')
            LogPath = (Join-Path $archive 'deployment.log')
            Secrets = [ordered]@{ SchemaVersion = 1; AdminPassword = '<DRY-RUN>'; Xray = @{} }
            State = [ordered]@{
                SchemaVersion = 1
                CurrentManagementPort = [int]$Plan.Server.BootstrapSshPort
                Modules = @{}
            }
            DryRun = $true
            NonInteractive = [bool]$NonInteractive
            Versions = (Get-VpsVersions -ProjectRoot $ProjectRoot)
        }
    }
    [IO.Directory]::CreateDirectory($archive) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $archive 'server-configs')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $archive 'client-exports')) | Out-Null
    [IO.Directory]::CreateDirectory([string]$Plan.Paths.KeyDirectory) | Out-Null

    $secretsPath = Join-Path $archive 'deployment-secrets.private.json'
    $secrets = if (Test-Path -LiteralPath $secretsPath) {
        Read-VpsJsonHashtable -Path $secretsPath
    }
    else {
        [ordered]@{ SchemaVersion = 1; AdminPassword = (New-VpsRandomString); Xray = @{} }
    }

    $statePath = Join-Path $archive 'deployment-state.json'
    $state = if (Test-Path -LiteralPath $statePath) {
        Read-VpsJsonHashtable -Path $statePath
    }
    else {
        [ordered]@{
            SchemaVersion = 1
            StartedAt = (Get-Date).ToString('o')
            CurrentManagementPort = [int]$Plan.Server.BootstrapSshPort
            Modules = @{}
        }
    }

    $context = [pscustomobject]@{
        ProjectRoot = $ProjectRoot
        Plan = $Plan
        ArchivePath = $archive
        PlanPath = (Join-Path $archive 'deployment-plan.json')
        SecretsPath = $secretsPath
        StatePath = $statePath
        LogPath = (Join-Path $archive 'deployment.log')
        Secrets = $secrets
        State = $state
        DryRun = [bool]$DryRun
        NonInteractive = [bool]$NonInteractive
        Versions = (Get-VpsVersions -ProjectRoot $ProjectRoot)
    }
    Save-VpsJson -Value $Plan -Path $context.PlanPath -Private
    Save-VpsJson -Value $secrets -Path $secretsPath -Private
    Save-VpsJson -Value $state -Path $statePath -Private
    return $context
}

function Get-VpsSecretStrings {
    param($Value)
    $result = [Collections.Generic.List[string]]::new()
    function Visit($item) {
        if ($null -eq $item) { return }
        if ($item -is [string]) {
            if ($item.Length -ge 8) { $result.Add($item) }
            return
        }
        if ($item -is [Collections.IDictionary]) {
            foreach ($value in $item.Values) { Visit $value }
            return
        }
        foreach ($property in $item.PSObject.Properties) { Visit $property.Value }
    }
    Visit $Value
    return $result.ToArray()
}

function Write-VpsLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )

    if ($Context.DryRun) { return }
    $clean = $Message
    foreach ($secret in (Get-VpsSecretStrings $Context.Secrets)) {
        $clean = $clean.Replace($secret, '<REDACTED>')
    }
    $clean = $clean -replace '(?i)(token|password|private.?key|uuid|short.?id)\s*[:=]\s*\S+', '$1=<REDACTED>'
    $clean = $clean -replace '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b', '<UUID-REDACTED>'
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('s'), $Level, $clean
    [IO.File]::AppendAllText($Context.LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Protect-VpsPrivateFile -Path $Context.LogPath
}

function Save-VpsContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)
    if ($Context.DryRun) { return }
    Save-VpsJson -Value $Context.Secrets -Path $Context.SecretsPath -Private
    Save-VpsJson -Value $Context.State -Path $Context.StatePath -Private
}

function Set-VpsModuleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [ValidateSet('Running', 'Success', 'Failed')] [string]$Status,
        [string]$Message
    )

    $Context.State.Modules[$Id] = [ordered]@{
        Status = $Status
        UpdatedAt = (Get-Date).ToString('o')
        Message = $Message
    }
    Save-VpsContext -Context $Context
}

function Invoke-VpsProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [AllowNull()] [string]$InputText,
        [int]$TimeoutSeconds = 300
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $InputText
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "无法启动进程：$FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        throw "进程执行超时（${TimeoutSeconds}s）：$FilePath"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Get-VpsCommandPath {
    param([Parameter(Mandatory)] [string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "缺少必需命令：$Name" }
    return $command.Source
}

function Get-VpsSshKeyPath {
    param([Parameter(Mandatory)] $Context)
    $fileName = 'id_ed25519'
    if ($Context.Plan.Contains('SshKey') -and $Context.Plan.SshKey.Contains('ManagedFileName') -and
        -not [string]::IsNullOrWhiteSpace([string]$Context.Plan.SshKey.ManagedFileName)) {
        $fileName = [string]$Context.Plan.SshKey.ManagedFileName
    }
    return Join-Path ([string]$Context.Plan.Paths.KeyDirectory) $fileName
}

function Get-VpsSshArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [string]$User,
        [switch]$Interactive,
        [string]$IdentityFile
    )

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('-o'); $arguments.Add('ControlMaster=no')
    $arguments.Add('-o'); $arguments.Add('ConnectTimeout=12')
    $arguments.Add('-o'); $arguments.Add('ServerAliveInterval=10')
    $arguments.Add('-o'); $arguments.Add('ServerAliveCountMax=2')
    $arguments.Add('-o'); $arguments.Add('StrictHostKeyChecking=accept-new')
    $arguments.Add('-o'); $arguments.Add('LogLevel=ERROR')
    if ($IdentityFile) {
        $arguments.Add('-o'); $arguments.Add('IdentitiesOnly=yes')
        $arguments.Add('-o'); $arguments.Add('PreferredAuthentications=publickey')
        $arguments.Add('-o'); $arguments.Add('PasswordAuthentication=no')
        $arguments.Add('-o'); $arguments.Add('KbdInteractiveAuthentication=no')
        $arguments.Add('-i'); $arguments.Add($IdentityFile)
        if (-not $Interactive) {
            $arguments.Add('-o'); $arguments.Add('BatchMode=yes')
        }
    }
    elseif (-not $Interactive) {
        $arguments.Add('-o'); $arguments.Add('BatchMode=yes')
        $arguments.Add('-i'); $arguments.Add((Get-VpsSshKeyPath $Context))
    }
    else {
        $arguments.Add('-o'); $arguments.Add('PreferredAuthentications=password,keyboard-interactive')
        $arguments.Add('-o'); $arguments.Add('PubkeyAuthentication=no')
    }
    $arguments.Add('-p'); $arguments.Add($Port.ToString())
    $arguments.Add("$User@$($Context.Plan.Server.IPv4)")
    return $arguments.ToArray()
}

function ConvertTo-VpsShellSingleQuote {
    param([Parameter(Mandatory)] [string]$Value)
    if ($Value.Contains("'")) { throw '值中包含不允许的单引号。' }
    return "'$Value'"
}

function Initialize-VpsSshKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $keyPath = Get-VpsSshKeyPath $Context
    $publicPath = $keyPath + '.pub'
    $sshKeygen = Get-VpsCommandPath 'ssh-keygen.exe'
    if ((Test-Path -LiteralPath $keyPath) -and (Test-Path -LiteralPath $publicPath)) {
        Protect-VpsPrivateFile -Path $keyPath
        $derivedExisting = Invoke-VpsProcess -FilePath $sshKeygen -ArgumentList @('-y', '-f', $keyPath) -TimeoutSeconds 60
        $derivedMatch = [regex]::Match($derivedExisting.StdOut.Trim(), '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))\s+([A-Za-z0-9+/=]+)(?:\s+.*)?$')
        $storedMatch = [regex]::Match((Get-Content -Raw -LiteralPath $publicPath).Trim(), '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))\s+([A-Za-z0-9+/=]+)(?:\s+.*)?$')
        if ($derivedExisting.ExitCode -ne 0 -or -not $derivedMatch.Success -or -not $storedMatch.Success -or
            $derivedMatch.Groups[1].Value -ne $storedMatch.Groups[1].Value -or $derivedMatch.Groups[2].Value -ne $storedMatch.Groups[2].Value) {
            throw '本地管理私钥与 .pub 不匹配或无法读取；为避免覆盖服务器入口，脚本已停止。'
        }
        return
    }
    $keyMode = if ($Context.Plan.Contains('SshKey') -and $Context.Plan.SshKey.Contains('Mode')) {
        [string]$Context.Plan.SshKey.Mode
    }
    else { 'GenerateManaged' }
    if ($keyMode -eq 'ReuseExisting') {
        $source = if ($Context.Plan.SshKey.Contains('SourcePrivateKeyPath')) {
            [string]$Context.Plan.SshKey.SourcePrivateKeyPath
        }
        else { [string]$Context.Plan.Server.BootstrapKeyPath }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "要复用的现有 OpenSSH 私钥不存在：$source"
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $keyPath)) | Out-Null
        $sourceResolved = (Resolve-Path -LiteralPath $source).Path
        $destinationFull = [IO.Path]::GetFullPath($keyPath)
        if (-not $sourceResolved.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourceResolved -Destination $keyPath -Force
        }
        # OpenSSH refuses a copied private key before it is normalized to a
        # current-user ACL, so protection must happen before ssh-keygen -y.
        Protect-VpsPrivateFile -Path $keyPath
        $derived = Invoke-VpsProcess -FilePath $sshKeygen -ArgumentList @('-y', '-f', $keyPath) -TimeoutSeconds 60
        $publicMatch = [regex]::Match($derived.StdOut.Trim(), '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))\s+([A-Za-z0-9+/=]+)(?:\s+.*)?$')
        if ($derived.ExitCode -ne 0 -or -not $publicMatch.Success) {
            throw '现有私钥无法作为无交互 OpenSSH 管理密钥使用；请确认格式和口令状态，或选择生成新 Ed25519 密钥。'
        }
        $publicMaterial = $publicMatch.Groups[1].Value + ' ' + $publicMatch.Groups[2].Value
        [IO.File]::WriteAllText($publicPath, ($publicMaterial + ' ' + [string]$Context.Plan.NodeName + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile -Path $keyPath
        Write-VpsUi '已复用现有 OpenSSH 私钥并建立规范文件名；原始私钥未改名、未删除，服务器公钥未轮换。' Success
        return
    }
    if ($keyMode -ne 'GenerateManaged') { throw "不支持的 SSH 密钥模式：$keyMode" }
    $arguments = @('-t', 'ed25519', '-a', '64', '-N', '', '-C', $Context.Plan.NodeName, '-f', $keyPath)
    $result = Invoke-VpsProcess -FilePath $sshKeygen -ArgumentList $arguments -TimeoutSeconds 60
    if ($result.ExitCode -ne 0) { throw "生成 SSH 密钥失败：$($result.StdErr.Trim())" }
    Protect-VpsPrivateFile -Path $keyPath
}

function Initialize-VpsBootstrapAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    Initialize-VpsSshKey -Context $Context
    $keyPath = Get-VpsSshKeyPath $Context
    $publicKey = (Get-Content -Raw -LiteralPath ($keyPath + '.pub')).Trim()
    if (-not $publicKey.StartsWith('ssh-ed25519 ')) { throw '生成的 SSH 公钥格式异常。' }

    $rootPort = [int]$Context.Plan.Server.BootstrapSshPort
    $existing = Invoke-VpsSshCommand -Context $Context -User 'root' -Port $rootPort `
        -Command "printf 'VPSDEPLOY_KEY_OK\\n'" -AllowFailure
    if ($existing.ExitCode -eq 0 -and $existing.StdOut -match 'VPSDEPLOY_KEY_OK') {
        Write-VpsUi '服务商初始端口上的 root 公钥登录已可用。' Success
        return
    }

    $ssh = Get-VpsCommandPath 'ssh.exe'
    $quotedKey = ConvertTo-VpsShellSingleQuote $publicKey
    $remote = "umask 077; install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; grep -qxF $quotedKey /root/.ssh/authorized_keys || printf '%s\\n' $quotedKey >> /root/.ssh/authorized_keys; printf 'VPSDEPLOY_BOOTSTRAP_OK\\n'"
    $bootstrapAuth = if ($Context.Plan.Server.Contains('BootstrapAuth')) {
        [string]$Context.Plan.Server.BootstrapAuth
    }
    else { 'Password' }
    if ($bootstrapAuth -eq 'ExistingKey') {
        $bootstrapKeyPath = [string]$Context.Plan.Server.BootstrapKeyPath
        if (-not (Test-Path -LiteralPath $bootstrapKeyPath -PathType Leaf)) {
            throw "服务商初始私钥不存在：$bootstrapKeyPath"
        }
        Protect-VpsPrivateFile -Path $bootstrapKeyPath
        Write-VpsUi '正在用服务商现有私钥建立一次性引导连接；如有口令，OpenSSH 会直接询问。' Warning
        if ($Context.NonInteractive) {
            $arguments = Get-VpsSshArguments -Context $Context -Port $rootPort -User 'root' -IdentityFile $bootstrapKeyPath
            $arguments += $remote
            $bootstrapResult = Invoke-VpsProcess -FilePath $ssh -ArgumentList $arguments -TimeoutSeconds 90
            if ($bootstrapResult.ExitCode -ne 0) {
                throw '现有服务商私钥引导失败；非交互模式不能询问私钥口令。'
            }
        }
        else {
            $arguments = Get-VpsSshArguments -Context $Context -Port $rootPort -User 'root' -Interactive -IdentityFile $bootstrapKeyPath
            & $ssh @arguments $remote
            if ($LASTEXITCODE -ne 0) { throw '现有服务商私钥引导失败。旧入口未做任何关闭操作。' }
        }
    }
    else {
        if ($Context.NonInteractive) {
            throw '非交互模式下实例专用公钥尚不可用，无法请求初始 root 密码。'
        }
        Write-VpsUi '即将首次连接。若出现密码提示，请输入服务商提供的 root 初始密码。' Warning
        $arguments = Get-VpsSshArguments -Context $Context -Port $rootPort -User 'root' -Interactive
        & $ssh @arguments $remote
        if ($LASTEXITCODE -ne 0) { throw '初始密码登录或公钥写入失败。旧入口未做任何关闭操作。' }
    }

    $verified = Invoke-VpsSshCommand -Context $Context -User 'root' -Port $rootPort `
        -Command "printf 'VPSDEPLOY_KEY_OK\\n'"
    if ($verified.StdOut -notmatch 'VPSDEPLOY_KEY_OK') { throw 'root 公钥复验失败。' }
    Write-VpsUi 'root 公钥登录已验证。' Success
}

function Invoke-VpsSshCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [string]$Command,
        [AllowNull()] [string]$InputText,
        [int]$TimeoutSeconds = 120,
        [switch]$AllowFailure,
        [switch]$SensitiveOutput
    )

    $ssh = Get-VpsCommandPath 'ssh.exe'
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($item in (Get-VpsSshArguments -Context $Context -Port $Port -User $User)) { $arguments.Add($item) }
    $arguments.Add($Command)
    $result = Invoke-VpsProcess -FilePath $ssh -ArgumentList $arguments.ToArray() -InputText $InputText -TimeoutSeconds $TimeoutSeconds
    if (-not $SensitiveOutput) {
        Write-VpsLog -Context $Context -Message "SSH $User port=$Port exit=$($result.ExitCode)"
    }
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        $message = if ($SensitiveOutput) { '远程命令失败（敏感输出已隐藏）。' } else { $result.StdErr.Trim() }
        throw "SSH 命令失败：$message"
    }
    return $result
}

function Get-VpsRemoteAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($Name -notmatch '^[A-Za-z0-9._-]+\.sh$') { throw '远端脚本名称无效。' }
    $path = Join-Path $Context.ProjectRoot (Join-Path 'assets\remote' $Name)
    if (-not (Test-Path -LiteralPath $path)) { throw "找不到远端模块脚本：$Name" }
    return (Get-Content -Raw -LiteralPath $path).Replace("`r`n", "`n").Replace("`r", "`n")
}

function New-VpsRemoteScriptPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Asset,
        [Collections.IDictionary]$Parameters = @{}
    )

    # StringBuilder.AppendLine() follows the Windows host newline and therefore
    # inserts CRLF.  Remote bash reads the trailing CR as part of option names
    # such as "pipefail\r", so build the complete payload with explicit LF.
    $preamble = [Text.StringBuilder]::new()
    [void]$preamble.Append("set -euo pipefail`n")
    foreach ($key in $Parameters.Keys) {
        $name = ([string]$key).ToUpperInvariant()
        if ($name -notmatch '^[A-Z][A-Z0-9_]*$') { throw "远端参数名无效：$key" }
        $value = if ($null -eq $Parameters[$key]) { '' } else { [string]$Parameters[$key] }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
        $exportLine = 'export VPS_PARAM_' + $name + '="$(printf ''%s'' ''' + $encoded + ''' | base64 -d)"'
        [void]$preamble.Append($exportLine + "`n")
    }
    return "(`n" + $preamble.ToString() + (Get-VpsRemoteAsset -Context $Context -Name $Asset) + "`n)`n"
}

function Invoke-VpsRemoteScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Asset,
        [Collections.IDictionary]$Parameters = @{},
        [int]$Port,
        [string]$User = 'root',
        [int]$TimeoutSeconds = 600,
        [switch]$AllowFailure,
        [switch]$SensitiveOutput
    )

    if (-not $Port) { $Port = [int]$Context.State.CurrentManagementPort }
    $script = New-VpsRemoteScriptPayload -Context $Context -Asset $Asset -Parameters $Parameters
    return Invoke-VpsSshCommand -Context $Context -User $User -Port $Port -Command 'bash -s' `
        -InputText $script -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure -SensitiveOutput:$SensitiveOutput
}

function Get-VpsMarkerValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [string]$Name,
        [switch]$Required
    )

    if ($Name -notmatch '^[A-Z][A-Z0-9_]*$') { throw "标记名称无效：$Name" }
    $match = [regex]::Match($Text, "(?m)^VPSDEPLOY_$([regex]::Escape($Name))_B64=([A-Za-z0-9+/=]*)$")
    if (-not $match.Success) {
        if ($Required) { throw "远端结果缺少标记：$Name" }
        return $null
    }
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value))
    }
    catch {
        throw "远端标记无法解码：$Name"
    }
}

function Test-VpsSshConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$User,
        [Parameter(Mandatory)] [int]$Port,
        [switch]$TestSudo
    )

    if ($TestSudo) {
        $password = [string]$Context.Secrets.AdminPassword
        $result = Invoke-VpsSshCommand -Context $Context -User $User -Port $Port `
            -Command "sudo -S -p '' sh -c 'printf VPSDEPLOY_SUDO_OK\\n'" `
            -InputText ($password + "`n") -SensitiveOutput -AllowFailure
        return $result.ExitCode -eq 0 -and $result.StdOut -match 'VPSDEPLOY_SUDO_OK'
    }
    $result = Invoke-VpsSshCommand -Context $Context -User $User -Port $Port `
        -Command "printf 'VPSDEPLOY_LOGIN_OK\\n'" -AllowFailure
    return $result.ExitCode -eq 0 -and $result.StdOut -match 'VPSDEPLOY_LOGIN_OK'
}

function Invoke-VpsScpDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$RemotePath,
        [Parameter(Mandatory)] [string]$LocalPath,
        [int]$Port
    )

    if (-not $Port) { $Port = [int]$Context.State.CurrentManagementPort }
    $scp = Get-VpsCommandPath 'scp.exe'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $LocalPath)) | Out-Null
    $args = @(
        '-q', '-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'StrictHostKeyChecking=accept-new',
        '-i', (Get-VpsSshKeyPath $Context), '-P', $Port.ToString(),
        "root@$($Context.Plan.Server.IPv4):$RemotePath", $LocalPath
    )
    $result = Invoke-VpsProcess -FilePath $scp -ArgumentList $args -TimeoutSeconds 180
    if ($result.ExitCode -ne 0) { throw "下载远端配置失败：$RemotePath" }
    Protect-VpsPrivateFile -Path $LocalPath
}

function Invoke-VpsScpUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$LocalPath,
        [Parameter(Mandatory)] [string]$RemotePath,
        [int]$Port
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) { throw "待上传文件不存在：$LocalPath" }
    if (-not $Port) { $Port = [int]$Context.State.CurrentManagementPort }
    $scp = Get-VpsCommandPath 'scp.exe'
    $args = @(
        '-q', '-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'StrictHostKeyChecking=accept-new',
        '-i', (Get-VpsSshKeyPath $Context), '-P', $Port.ToString(),
        $LocalPath, "root@$($Context.Plan.Server.IPv4):$RemotePath"
    )
    $result = Invoke-VpsProcess -FilePath $scp -ArgumentList $args -TimeoutSeconds 180
    if ($result.ExitCode -ne 0) { throw "上传远端文件失败：$RemotePath" }
}

function Get-MxhRealityTargetSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Plan)

    $targetMode = if ($Plan.Reality.Contains('TargetMode') -and $Plan.Reality.TargetMode) {
        [string]$Plan.Reality.TargetMode
    }
    else { 'ExternalAudited' }
    $serverName = if ($Plan.Reality.Contains('ServerName') -and $Plan.Reality.ServerName) {
        [string]$Plan.Reality.ServerName
    }
    else { [string]$Plan.Reality.Target }
    $targetAddress = if ($Plan.Reality.Contains('TargetAddress') -and $Plan.Reality.TargetAddress) {
        [string]$Plan.Reality.TargetAddress
    }
    else { "$([string]$Plan.Reality.Target):443" }
    return [ordered]@{
        Mode = $targetMode
        ServerName = $serverName
        TargetAddress = $targetAddress
    }
}

function Set-MxhRealityExternalTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [string]$Target
    )

    if (-not (Test-VpsHostName $Target)) { throw '新的 Reality target 域名格式无效。' }
    $Plan.Reality.Target = $Target
    if ($Plan.Reality.Contains('ServerName')) { $Plan.Reality.ServerName = $Target }
    if ($Plan.Reality.Contains('TargetAddress')) { $Plan.Reality.TargetAddress = "${Target}:443" }
}

function New-MxhXrayInbound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Tag,
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [Collections.IDictionary]$Secrets,
        [Parameter(Mandatory)] [string]$TargetAddress,
        [Parameter(Mandatory)] [string]$ServerName
    )
    return [ordered]@{
        tag = $Tag
        listen = '0.0.0.0'
        port = $Port
        protocol = 'vless'
        settings = [ordered]@{
            clients = @([ordered]@{
                    id = $Secrets.Uuid
                    flow = 'xtls-rprx-vision'
                    email = 'primary-client'
                })
            decryption = 'none'
        }
        streamSettings = [ordered]@{
            method = 'raw'
            security = 'reality'
            realitySettings = [ordered]@{
                show = $false
                target = $TargetAddress
                xver = 0
                serverNames = @($ServerName)
                privateKey = $Secrets.RealityPrivateKey
                shortIds = @($Secrets.ShortId)
            }
        }
    }
}

function New-MxhXrayServerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $xraySecrets = $Context.Secrets.Xray
    $target = Get-MxhRealityTargetSettings -Plan $Context.Plan
    $inbounds = @(
        (New-MxhXrayInbound -Tag 'reality-primary' -Port ([int]$Context.Plan.Ports.XrayPrimary) -Secrets $xraySecrets -TargetAddress $target.TargetAddress -ServerName $target.ServerName),
        (New-MxhXrayInbound -Tag 'reality-backup' -Port ([int]$Context.Plan.Ports.XrayBackup) -Secrets $xraySecrets -TargetAddress $target.TargetAddress -ServerName $target.ServerName)
    )
    $directSettings = if ($Context.Plan.Reality.ForceIpv4Egress) { [ordered]@{ domainStrategy = 'ForceIPv4' } } else { @{} }
    [object[]]$routingRules = @()
    if ($Context.Plan.Reality.ForceIpv4Egress) {
        $routingRules = ,([ordered]@{ type = 'field'; ip = @('::/0'); outboundTag = 'block' })
    }
    return [ordered]@{
        log = [ordered]@{ access = 'none'; error = '/var/log/xray/error.log'; loglevel = 'warning' }
        inbounds = $inbounds
        outbounds = @(
            [ordered]@{ tag = 'direct'; protocol = 'freedom'; settings = $directSettings },
            [ordered]@{ tag = 'block'; protocol = 'blackhole' }
        )
        routing = [ordered]@{ domainStrategy = 'AsIs'; rules = $routingRules }
    }
}

function New-MxhRandomBase64Key {
    [CmdletBinding()]
    param([ValidateSet(16, 32)] [int]$Length = 16)

    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes)
}

function ConvertFrom-MxhEchKeyPairText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Text)

    $configMatch = [regex]::Match($Text, '(?s)(-----BEGIN ECH CONFIGS-----\s+.+?\s+-----END ECH CONFIGS-----)')
    $keyMatch = [regex]::Match($Text, '(?s)(-----BEGIN ECH KEYS-----\s+.+?\s+-----END ECH KEYS-----)')
    if (-not $configMatch.Success -or -not $keyMatch.Success) { throw '无法解析 sing-box ECH 密钥对输出。' }
    $configPem = ($configMatch.Groups[1].Value -replace "`r`n", "`n").Trim() + "`n"
    $keyPem = ($keyMatch.Groups[1].Value -replace "`r`n", "`n").Trim() + "`n"
    $payload = (($configPem -split "`n") | Where-Object { $_ -and $_ -notmatch '^-----' }) -join ''
    if ($payload -notmatch '^[A-Za-z0-9+/=]+$') { throw 'ECH client config 的 Base64 载荷异常。' }
    return [ordered]@{
        ClientConfigPem = $configPem
        ClientConfigBase64 = $payload
        ServerKeyPem = $keyPem
    }
}

function New-MxhAnyTlsServerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $password = [string]$Context.Secrets.AnyTls.Password
    if ([string]::IsNullOrWhiteSpace($password)) { throw 'AnyTLS 密码尚未生成。' }
    $forceIpv4 = [bool]$Context.Plan.AnyTls.ForceIpv4Egress
    $paddingScheme = @(Get-MxhAnyTlsPaddingScheme -Plan $Context.Plan)
    $direct = [ordered]@{
        type = 'direct'
        tag = 'direct'
        domain_resolver = [ordered]@{ server = 'local'; strategy = if ($forceIpv4) { 'ipv4_only' } else { 'prefer_ipv4' } }
    }
    [object[]]$rules = @()
    if ($forceIpv4) {
        $rules = ,([ordered]@{ ip_version = 6; action = 'reject' })
    }
    return [ordered]@{
        log = [ordered]@{ level = 'warn'; timestamp = $true }
        dns = [ordered]@{ servers = @([ordered]@{ type = 'local'; tag = 'local' }) }
        inbounds = @([ordered]@{
                type = 'anytls'
                tag = 'anytls-in'
                listen = if ($Context.Plan.Server.IPv6) { '::' } else { '0.0.0.0' }
                listen_port = [int]$Context.Plan.Ports.AnyTlsPrimary
                users = @([ordered]@{ name = 'primary'; password = $password })
                padding_scheme = $paddingScheme
                tls = [ordered]@{
                    enabled = $true
                    server_name = [string]$Context.Plan.AnyTls.ServerName
                    min_version = '1.3'
                    certificate_path = '/etc/mxh-tls/anytls/fullchain.pem'
                    key_path = '/etc/mxh-tls/anytls/privkey.pem'
                    ech = [ordered]@{
                        enabled = $true
                        key_path = '/etc/sing-box-anytls/ech-key.pem'
                    }
                }
            })
        outbounds = @($direct)
        route = [ordered]@{
            rules = $rules
            final = 'direct'
        }
    }
}

function New-MxhAnyTlsClientOutbound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Server,
        [Parameter(Mandatory)] [string]$Tag
    )
    $configPem = [string]$Context.Secrets.AnyTls.EchClientConfigPem
    if ([string]::IsNullOrWhiteSpace($configPem)) { throw 'ECH client config 尚未生成。' }
    return [ordered]@{
        type = 'anytls'
        tag = $Tag
        server = $Server
        server_port = [int]$Context.Plan.Ports.AnyTlsPrimary
        password = [string]$Context.Secrets.AnyTls.Password
        tls = [ordered]@{
            enabled = $true
            server_name = [string]$Context.Plan.AnyTls.ServerName
            min_version = '1.3'
            ech = [ordered]@{
                enabled = $true
                config = @($configPem.TrimEnd() -split "`n")
            }
        }
    }
}

function New-MxhAnyTlsMihomoProfileText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int]$MixedPort
    )
    $nodeName = "$($Context.Plan.NodeName)-AnyTLS-IPv4"
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
            "mixed-port: $MixedPort", 'allow-lan: false', 'bind-address: 127.0.0.1',
            'mode: rule', 'log-level: warning', 'ipv6: true', '', 'proxies:',
            "  - name: $(ConvertTo-MxhYamlString $nodeName)",
            '    type: anytls',
            "    server: $(ConvertTo-MxhYamlString ([string]$Context.Plan.Server.IPv4))",
            "    port: $([int]$Context.Plan.Ports.AnyTlsPrimary)",
            "    password: $(ConvertTo-MxhYamlString ([string]$Context.Secrets.AnyTls.Password))",
            '    udp: true',
            "    sni: $(ConvertTo-MxhYamlString ([string]$Context.Plan.AnyTls.ServerName))",
            '    skip-cert-verify: false',
            '    ech-opts:',
            '      enable: true',
            "      config: $(ConvertTo-MxhYamlString ([string]$Context.Secrets.AnyTls.EchClientConfigBase64))",
            '', 'proxy-groups:',
            "  - name: $(ConvertTo-MxhYamlString 'Proxy')", '    type: select', '    proxies:',
            "      - $(ConvertTo-MxhYamlString $nodeName)", '', 'rules:', '  - MATCH,Proxy'
        )) { $lines.Add($line) }
    return ($lines -join "`n") + "`n"
}

function New-MxhShadowsocksServerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $credentials = $Context.Secrets.Shadowsocks
    if (-not $credentials) { throw 'Shadowsocks 凭据尚未生成。' }
    $users = [Collections.Generic.List[object]]::new()
    $users.Add([ordered]@{ name = 'ipv4-client'; password = [string]$credentials.PrimaryUserKey })
    $outbounds = [Collections.Generic.List[object]]::new()
    $outbounds.Add([ordered]@{
            type = 'direct'
            tag = 'direct-ipv4'
            domain_resolver = [ordered]@{ server = 'local'; strategy = 'ipv4_only' }
        })
    $rules = [Collections.Generic.List[object]]::new()
    $rules.Add([ordered]@{
            auth_user = @('ipv4-client')
            ip_version = 6
            action = 'reject'
        })
    $rules.Add([ordered]@{
            auth_user = @('ipv4-client')
            action = 'route'
            outbound = 'direct-ipv4'
        })

    if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
        $users.Add([ordered]@{ name = 'ipv6-client'; password = [string]$credentials.SecondaryUserKey })
        $ipv6Outbound = [ordered]@{
            type = 'direct'
            tag = 'direct-ipv6'
            inet6_bind_address = [string]$Context.Plan.Shadowsocks.SecondaryIpv6Address
            domain_resolver = [ordered]@{ server = 'local'; strategy = 'ipv6_only' }
        }
        if ($Context.Plan.Shadowsocks.SecondaryBindInterface) {
            $ipv6Outbound.bind_interface = [string]$Context.Plan.Shadowsocks.SecondaryBindInterface
        }
        $outbounds.Add($ipv6Outbound)
        $rules.Add([ordered]@{
                auth_user = @('ipv6-client')
                ip_version = 4
                action = 'reject'
            })
        $rules.Add([ordered]@{
                auth_user = @('ipv6-client')
                action = 'route'
                outbound = 'direct-ipv6'
            })
    }

    $listenAddress = if ($Context.Plan.Server.IPv6) { '::' } else { '0.0.0.0' }
    return [ordered]@{
        log = [ordered]@{ level = 'warn'; timestamp = $true }
        dns = [ordered]@{
            servers = @([ordered]@{ type = 'local'; tag = 'local' })
        }
        inbounds = @([ordered]@{
                type = 'shadowsocks'
                tag = 'ss2022-in'
                listen = $listenAddress
                listen_port = [int]$Context.Plan.Ports.LandingShadowsocks
                method = [string]$Context.Plan.Shadowsocks.Method
                password = [string]$credentials.ServerKey
                users = $users
                udp_timeout = '5m'
            })
        outbounds = $outbounds
        route = [ordered]@{
            rules = $rules
            final = 'direct-ipv4'
            auto_detect_interface = $true
        }
    }
}

function ConvertTo-MxhYamlString {
    param([AllowEmptyString()] [string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-MxhMihomoProfileText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int]$ServerPort,
        [Parameter(Mandatory)] [int]$MixedPort,
        [switch]$IncludeIpv6
    )
    $s = $Context.Secrets.Xray
    $realityTarget = Get-MxhRealityTargetSettings -Plan $Context.Plan
    $nodeBase = [string]$Context.Plan.NodeName
    $node4 = "$nodeBase-IPv4"
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
            "mixed-port: $MixedPort", 'allow-lan: false', 'bind-address: 127.0.0.1',
            'mode: rule', 'log-level: warning', 'ipv6: true', '', 'proxies:'
        )) { $lines.Add($line) }

    function Add-MxhNode([string]$Name, [string]$Server) {
        $lines.Add("  - name: $(ConvertTo-MxhYamlString $Name)")
        $lines.Add('    type: vless')
        $lines.Add("    server: $(ConvertTo-MxhYamlString $Server)")
        $lines.Add("    port: $ServerPort")
        $lines.Add("    uuid: $(ConvertTo-MxhYamlString ([string]$s.Uuid))")
        $lines.Add('    network: tcp')
        $lines.Add('    tls: true')
        $lines.Add('    udp: true')
        $lines.Add("    servername: $(ConvertTo-MxhYamlString ([string]$realityTarget.ServerName))")
        $lines.Add("    flow: $(ConvertTo-MxhYamlString 'xtls-rprx-vision')")
        $lines.Add("    client-fingerprint: $(ConvertTo-MxhYamlString 'chrome')")
        $lines.Add('    reality-opts:')
        $lines.Add("      public-key: $(ConvertTo-MxhYamlString ([string]$s.RealityClientKey))")
        $lines.Add("      short-id: $(ConvertTo-MxhYamlString ([string]$s.ShortId))")
    }

    Add-MxhNode $node4 ([string]$Context.Plan.Server.IPv4)
    $nodes = [Collections.Generic.List[string]]::new()
    $nodes.Add($node4)
    if ($IncludeIpv6 -and $Context.Plan.Server.IPv6) {
        $node6 = "$nodeBase-IPv6"
        Add-MxhNode $node6 ([string]$Context.Plan.Server.IPv6)
        $nodes.Add($node6)
    }
    $lines.Add('')
    $lines.Add('proxy-groups:')
    $lines.Add("  - name: $(ConvertTo-MxhYamlString 'Proxy')")
    $lines.Add('    type: select')
    $lines.Add('    proxies:')
    foreach ($node in $nodes) { $lines.Add("      - $(ConvertTo-MxhYamlString $node)") }
    $lines.Add('')
    $lines.Add('rules:')
    $lines.Add('  - MATCH,Proxy')
    return ($lines -join "`n") + "`n"
}

function New-MxhLandingMihomoProfileText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int]$MixedPort
    )

    $credentials = $Context.Secrets.Shadowsocks
    $transitTag = [string]$Context.Plan.Shadowsocks.ClientTransitTag
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
            "mixed-port: $MixedPort", 'allow-lan: false', 'bind-address: 127.0.0.1',
            'mode: rule', 'log-level: warning', 'ipv6: true', '', 'proxies:'
        )) { $lines.Add($line) }

    function Add-MxhLandingNode([string]$Name, [string]$UserKey) {
        $combinedPassword = ([string]$credentials.ServerKey) + ':' + $UserKey
        $lines.Add("  - name: $(ConvertTo-MxhYamlString $Name)")
        $lines.Add('    type: ss')
        $lines.Add("    server: $(ConvertTo-MxhYamlString ([string]$Context.Plan.Server.IPv4))")
        $lines.Add("    port: $([int]$Context.Plan.Ports.LandingShadowsocks)")
        $lines.Add("    cipher: $(ConvertTo-MxhYamlString ([string]$Context.Plan.Shadowsocks.Method))")
        $lines.Add("    password: $(ConvertTo-MxhYamlString $combinedPassword)")
        $lines.Add('    udp: true')
        $lines.Add('    ip-version: ipv4')
        $lines.Add("    dialer-proxy: $(ConvertTo-MxhYamlString $transitTag)")
    }

    $primaryName = "$($Context.Plan.NodeName)-IPv4"
    Add-MxhLandingNode $primaryName ([string]$credentials.PrimaryUserKey)
    $nodes = [Collections.Generic.List[string]]::new()
    $nodes.Add($primaryName)
    if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
        $secondaryName = "$($Context.Plan.NodeName)-IPv6"
        Add-MxhLandingNode $secondaryName ([string]$credentials.SecondaryUserKey)
        $nodes.Add($secondaryName)
    }

    $lines.Add('')
    $lines.Add('proxy-groups:')
    $lines.Add("  - name: $(ConvertTo-MxhYamlString $transitTag)")
    $lines.Add('    type: select')
    $lines.Add('    proxies:')
    $lines.Add('      - DIRECT')
    $lines.Add("  - name: $(ConvertTo-MxhYamlString 'Proxy')")
    $lines.Add('    type: select')
    $lines.Add('    proxies:')
    foreach ($node in $nodes) { $lines.Add("      - $(ConvertTo-MxhYamlString $node)") }
    $lines.Add('')
    $lines.Add('rules:')
    $lines.Add('  - MATCH,Proxy')
    return ($lines -join "`n") + "`n"
}

function Invoke-MxhMihomoEgressTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$CorePath,
        [Parameter(Mandatory)] [string]$ProfilePath,
        [Parameter(Mandatory)] [int]$MixedPort,
        [Parameter(Mandatory)] [string]$Label
    )
    $dataDir = Join-Path $Context.ArchivePath ("client-exports\runtime-" + $Label)
    [IO.Directory]::CreateDirectory($dataDir) | Out-Null
    $stdoutPath = Join-Path $dataDir 'mihomo.stdout.log'
    $stderrPath = Join-Path $dataDir 'mihomo.stderr.log'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $CorePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($arg in @('-d', $dataDir, '-f', $ProfilePath)) { [void]$startInfo.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "无法启动 Mihomo：$Label" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        Start-Sleep -Milliseconds 1800
        if ($process.HasExited) { throw "Mihomo 提前退出：$Label" }
        $proxy = "http://127.0.0.1:$MixedPort"
        $response = Invoke-WebRequest -Uri 'https://www.gstatic.com/generate_204' -Proxy $proxy -TimeoutSec 25
        if ($response.StatusCode -ne 204) { throw "HTTP 204 验证失败：$Label" }
        $egress = (Invoke-RestMethod -Uri 'https://api.ipify.org' -Proxy $proxy -TimeoutSec 25).Trim()
        return $egress
    }
    finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.WaitForExit()
        [IO.File]::WriteAllText($stdoutPath, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($stderrPath, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
        Protect-VpsPrivateFile $stdoutPath
        Protect-VpsPrivateFile $stderrPath
        $process.Dispose()
    }
}

function Get-VpsModules {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ProjectRoot)

    $modules = [Collections.Generic.List[hashtable]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'modules') -Filter '*.ps1' -File | Sort-Object Name)) {
        $definition = & $file.FullName
        if ($definition -isnot [hashtable]) { throw "模块未返回 Hashtable：$($file.Name)" }
        foreach ($required in @('Id', 'Name', 'Order', 'Roles', 'Requires', 'IsEnabled', 'Invoke')) {
            if (-not $definition.ContainsKey($required)) { throw "模块 $($file.Name) 缺少字段 $required" }
        }
        $definition.SourceFile = $file.FullName
        $modules.Add($definition)
    }
    $duplicates = $modules | Group-Object Id | Where-Object Count -gt 1
    if ($duplicates) { throw "模块 ID 重复：$($duplicates.Name -join ', ')" }
    $ordered = @($modules | Sort-Object Order, Id)
    $ids = @($ordered.Id)
    foreach ($module in $ordered) {
        foreach ($dependency in @($module.Requires)) {
            if ($dependency -notin $ids) { throw "模块 $($module.Id) 依赖不存在的模块：$dependency" }
            $dependencyOrder = ($ordered | Where-Object Id -eq $dependency).Order
            if ($dependencyOrder -ge $module.Order) { throw "模块依赖顺序错误：$dependency 必须早于 $($module.Id)" }
        }
    }
    return $ordered
}

function Invoke-VpsModulePipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [string[]]$OnlyModule
    )

    $modules = Get-VpsModules -ProjectRoot $Context.ProjectRoot
    $selected = @($modules | Where-Object {
            $Context.Plan.Role -in @($_.Roles) -and (& $_.IsEnabled $Context)
        })
    if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) {
        $migrationIds = @($Context.Plan.Migration.ModuleIds | ForEach-Object { [string]$_ })
        $selected = @($selected | Where-Object Id -in $migrationIds)
    }
    if ($OnlyModule) {
        $missing = @($OnlyModule | Where-Object { $_ -notin @($modules.Id) })
        if ($missing) { throw "未知模块：$($missing -join ', ')" }
        $selected = @($selected | Where-Object Id -in $OnlyModule)
        Write-VpsUi '维护模式只运行显式模块，不会自动补跑缺失依赖。' Warning
    }

    Write-Host ''
    Write-Host '本次模块计划：' -ForegroundColor Cyan
    foreach ($module in $selected) {
        Write-Host ("  {0,3}  {1,-24} {2}" -f $module.Order, $module.Id, $module.Name)
    }
    if ($Context.DryRun) {
        Write-VpsUi 'DryRun：只显示计划，不连接服务器、不生成凭据、不改文件。' Success
        return
    }
    if (-not $Context.NonInteractive) {
        Write-VpsUi '此处返回或取消不会连接 VPS；已确认的本地计划会保留，可稍后 Resume。' Muted
        if (-not (Read-VpsYesNo '确认按以上顺序开始？' $true -AllowBack)) {
            throw [OperationCanceledException]::new($script:VpsWizardCancelMarker)
        }
    }

    foreach ($module in $selected) {
        $previous = $Context.State.Modules[$module.Id]
        if (-not $OnlyModule -and $previous -and $previous.Status -eq 'Success') {
            Write-VpsUi "跳过已完成模块：$($module.Name)" Muted
            continue
        }
        Write-Host ''
        Write-VpsUi $module.Name Step
        Set-VpsModuleState -Context $Context -Id $module.Id -Status Running
        try {
            & $module.Invoke $Context
            Set-VpsModuleState -Context $Context -Id $module.Id -Status Success -Message 'Completed'
            Write-VpsUi "$($module.Name) 已完成。" Success
        }
        catch {
            $safeMessage = $_.Exception.Message
            Set-VpsModuleState -Context $Context -Id $module.Id -Status Failed -Message $safeMessage
            Write-VpsLog -Context $Context -Level ERROR -Message "Module $($module.Id) failed: $safeMessage"
            Write-VpsUi "$($module.Name) 失败：$safeMessage" Error
            if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) {
                Invoke-MxhProtocolMigrationRollback -Context $Context -Reason $safeMessage
                Write-VpsUi '协议变更后续模块已停止；请确认变更前状态已经恢复，再使用继续模式。' Warning
            }
            else {
                Write-VpsUi '后续模块已停止；旧 SSH 入口不会由核心自动关闭。修复后使用继续模式。' Warning
            }
            throw
        }
    }
}

function Test-VpsProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ProjectRoot)

    $testScript = Join-Path $ProjectRoot 'tests\Run-Tests.ps1'
    $pwsh = Get-VpsCommandPath -Name 'pwsh'
    $safeScript = $testScript.Replace("'", "''")
    $safeRoot = $ProjectRoot.Replace("'", "''")
    $command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); & '$safeScript' -ProjectRoot '$safeRoot'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $result = Invoke-VpsProcess -FilePath $pwsh -ArgumentList @(
        '-NoProfile', '-OutputFormat', 'Text', '-EncodedCommand', $encoded
    ) -TimeoutSeconds 900
    if ($result.StdOut) { Write-Host $result.StdOut -NoNewline }
    if ($result.StdErr) { Write-Host $result.StdErr -ForegroundColor Red -NoNewline }
    if ($result.ExitCode -ne 0) { throw "项目自检失败（退出码 $($result.ExitCode)）。" }
}

function Show-VpsPlanSummary {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Plan)
    Write-Host ''
    Write-Host '部署摘要' -ForegroundColor White
    Write-Host "  实例：$($Plan.Provider) / $($Plan.Instance)"
    Write-Host "  节点：$($Plan.NodeName)"
    Write-Host "  主角色/执行角色：$($Plan.Role)"
    Write-Host "  地址：$($Plan.Server.IPv4)"
    $bootstrapAuthLabel = if ($Plan.Server.Contains('BootstrapAuth') -and $Plan.Server.BootstrapAuth -eq 'ExistingKey') { '现有服务商私钥' } else { '密码' }
    Write-Host "  初始认证：$bootstrapAuthLabel"
    if ($Plan.Contains('SshKey')) {
        $keyLabel = if ([string]$Plan.SshKey.Mode -eq 'ReuseExisting') { '复用现有密钥（不轮换公钥）' } else { '生成实例管理密钥' }
        Write-Host "  管理密钥：$keyLabel"
    }
    Write-Host "  SSH：$($Plan.Server.BootstrapSshPort) -> $($Plan.Ports.SshPrimary) + $($Plan.Ports.SshRescue)"
    $realityInstalled = Test-MxhProtocolInstalled -Plan $Plan -Role 'RealityEntry'
    $anyTlsInstalled = Test-MxhProtocolInstalled -Plan $Plan -Role 'AnyTlsEntry'
    $shadowsocksInstalled = Test-MxhProtocolInstalled -Plan $Plan -Role 'ShadowsocksLanding'
    if ($realityInstalled) {
        $target = Get-MxhRealityTargetSettings -Plan $Plan
        $portsText = if ($Plan.Ports.XrayBackup) { "443 + $($Plan.Ports.XrayBackup)" } else { '443（无救援入口）' }
        Write-Host "  Xray：$portsText，target=$($target.TargetAddress)，SNI=$($target.ServerName)"
        if ($Plan.Reality.Contains('XrayVersion')) {
            $channel = if ($Plan.Reality.Contains('XrayVersionChannel')) { [string]$Plan.Reality.XrayVersionChannel } else { 'ImportedOrLegacy' }
            Write-Host "  Xray 版本：$($Plan.Reality.XrayVersion)（$channel）"
        }
    }
    if ($anyTlsInstalled) {
        Write-Host "  AnyTLS：443，SNI=$($Plan.AnyTls.ServerName)，ECH public name=$($Plan.AnyTls.EchPublicName)"
        $paddingMode = if ($Plan.AnyTls.Contains('PaddingSchemeMode') -and $Plan.AnyTls.PaddingSchemeMode) {
            [string]$Plan.AnyTls.PaddingSchemeMode
        } else { 'OfficialDefault' }
        Write-Host "  Padding：$paddingMode"
    }
    if ($shadowsocksInstalled) {
        $allowCount = @($Plan.Shadowsocks.TrustedEntryIPv4s).Count + @($Plan.Shadowsocks.TrustedEntryIPv6s).Count
        Write-Host "  Shadowsocks：TCP+UDP $($Plan.Ports.LandingShadowsocks)，可信入口 $allowCount 个"
        Write-Host "  独立 IPv6 出口：$($Plan.Shadowsocks.SecondaryIpv6Enabled)"
    }
    if ($Plan.Contains('NetworkTuning') -and $Plan.NetworkTuning.Mode -eq 'AdaptiveConservative') {
        Write-Host "  网络调优：保守自适应，$($Plan.NetworkTuning.BandwidthMbps) Mbps / $($Plan.NetworkTuning.ReferenceRttMs) ms"
    }
    else {
        $bandwidthText = if ($Plan.Contains('NetworkTuning') -and $null -ne $Plan.NetworkTuning.BandwidthMbps) { "，套餐 $($Plan.NetworkTuning.BandwidthMbps) Mbps" } else { '' }
        Write-Host "  网络调优：基础保守项（不调整缓冲区）$bandwidthText"
    }
    Write-Host "  Komari：$($Plan.Komari.Enabled)"
    Write-Host "  私有归档：$($Plan.Paths.Archive)"
    if ($Plan.Contains('Migration') -and [bool]$Plan.Migration.Enabled) {
        $operation = if ($Plan.Migration.Contains('Operation')) { $Plan.Migration.Operation } else { 'LegacyConversion' }
        Write-Host "  协议生命周期操作：$operation / $($Plan.Migration.TargetRole)（$($Plan.Migration.Status)）"
        Write-Host "  自动回滚：$($Plan.Migration.RollbackTimeoutMinutes) 分钟"
    }
    $showedPortWarning = $false
    if ($realityInstalled) {
        Write-VpsUi '请先在服务商安全组临时放行两个 SSH 高位端口、443 和 Xray 救援端口。' Warning
        $showedPortWarning = $true
    }
    if ($anyTlsInstalled) {
        Write-VpsUi '请先在服务商安全组临时放行两个 SSH 高位端口和 TCP 443；AnyTLS 与 Xray 必须互斥。' Warning
        $showedPortWarning = $true
    }
    if ($shadowsocksInstalled) {
        Write-VpsUi '请放行两个 SSH 高位端口；Shadowsocks TCP+UDP 端口必须只允许上面填写的可信入口 IP。' Warning
        $showedPortWarning = $true
    }
    if (-not $showedPortWarning) {
        Write-VpsUi '请先在服务商安全组临时放行两个 SSH 高位端口。' Warning
    }
}

function Read-VpsResumePlan {
    [CmdletBinding()]
    param(
        [string]$PlanPath,
        [switch]$NonInteractive
    )

    $candidatePath = $PlanPath
    while ($true) {
        if (-not $candidatePath) {
            $inputPath = Read-VpsText 'deployment-plan.json 完整路径' -AllowBack -Validate {
                param($v)
                $candidate = $v.Trim().Trim('"')
                Test-Path -LiteralPath $candidate -PathType Leaf
            } -ValidationMessage '找不到该计划文件。可输入 0 返回主菜单。'
            $candidatePath = $inputPath.Trim().Trim('"')
        }
        else {
            $candidatePath = $candidatePath.Trim().Trim('"')
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            if ($NonInteractive) { throw "找不到部署计划：$candidatePath" }
            Write-VpsUi "找不到部署计划：$candidatePath" Warning
            $candidatePath = $null
            continue
        }
        $candidatePath = (Resolve-Path -LiteralPath $candidatePath).Path
        try {
            $plan = Read-VpsJsonHashtable -Path $candidatePath
        }
        catch {
            if ($NonInteractive) { throw }
            Write-VpsUi "无法读取部署计划：$($_.Exception.Message)" Warning
            $candidatePath = $null
            continue
        }

        try {
            Show-VpsPlanSummary -Plan $plan
        }
        catch {
            if ($NonInteractive) { throw }
            Write-VpsUi "该 JSON 不是可用的部署计划：$($_.Exception.Message)" Warning
            $candidatePath = $null
            continue
        }
        if ($NonInteractive) { return $plan }

        try {
            $choice = Read-VpsMenu '继续部署前请核对计划' @(
                '使用此计划继续',
                '取消并返回主菜单'
            ) 1 -AllowBack
        }
        catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $choice = 0
        }
        if ($choice -eq 1) { return $plan }
        if ($choice -eq 2) {
            throw [OperationCanceledException]::new($script:VpsWizardCancelMarker)
        }
        $candidatePath = $null
    }
}

function Invoke-VpsDeploymentSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [ValidateSet('New', 'Resume', 'Import', 'Migrate', 'Maintain', 'TuneNetwork', 'ClientConfig')] [string]$Mode,
        [string]$PlanPath,
        [string[]]$OnlyModule,
        [Parameter(Mandatory)] [string]$InstanceRoot,
        [string]$ClashAuthorityPath,
        [string]$SingBoxAuthorityPath,
        [string]$ClientOutputRoot,
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    if ($Mode -eq 'Import') {
        $plan = New-MxhExistingImportPlanInteractive -ProjectRoot $ProjectRoot -InstanceRoot $InstanceRoot
        Invoke-MxhExistingVpsImport -ProjectRoot $ProjectRoot -Plan $plan -DryRun:$DryRun -NonInteractive:$NonInteractive
        return
    }
    if ($Mode -eq 'ClientConfig') {
        Invoke-MxhClientAuthorityDesigner -ProjectRoot $ProjectRoot -InstanceRoot $InstanceRoot `
            -ClashAuthorityPath $ClashAuthorityPath -SingBoxAuthorityPath $SingBoxAuthorityPath `
            -ClientOutputRoot $ClientOutputRoot -DryRun:$DryRun
        return
    }
    if ($Mode -eq 'New') {
        $plan = New-VpsInteractivePlan -ProjectRoot $ProjectRoot -InstanceRoot $InstanceRoot
        $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan -DryRun:$DryRun -NonInteractive:$NonInteractive
    }
    elseif ($Mode -eq 'Migrate') {
        $migrationResult = New-VpsProtocolMigrationPlanInteractive -ProjectRoot $ProjectRoot -PlanPath $PlanPath -DryRun:$DryRun
        $context = Initialize-MxhProtocolMigrationContext -ProjectRoot $ProjectRoot -MigrationResult $migrationResult `
            -DryRun:$DryRun -NonInteractive:$NonInteractive
    }
    elseif ($Mode -eq 'Maintain') {
        Invoke-MxhMaintenanceCenter -ProjectRoot $ProjectRoot -PlanPath $PlanPath -DryRun:$DryRun
        return
    }
    elseif ($Mode -eq 'TuneNetwork') {
        $tuningResult = New-VpsNetworkTuningPlanInteractive -ProjectRoot $ProjectRoot -PlanPath $PlanPath -DryRun:$DryRun
        $context = Initialize-MxhProtocolMigrationContext -ProjectRoot $ProjectRoot -MigrationResult $tuningResult `
            -DryRun:$DryRun -NonInteractive:$NonInteractive
    }
    else {
        $plan = Read-VpsResumePlan -PlanPath $PlanPath -NonInteractive:$NonInteractive
        $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan -DryRun:$DryRun -NonInteractive:$NonInteractive
    }
    try {
        Invoke-VpsModulePipeline -Context $context -OnlyModule $OnlyModule
        if (-not $DryRun) {
            Write-Host ''
            Write-VpsUi "部署流程完成。私有归档：$($context.ArchivePath)" Success
            Write-VpsUi '最后请在服务商安全组删除初始 SSH 端口，并按归档中的客户端步骤完成真实出口测试。' Warning
        }
    }
    finally {
        Save-VpsContext -Context $context
    }
}

function Start-VpsDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [ValidateSet('Interactive', 'New', 'Resume', 'Import', 'Migrate', 'Maintain', 'TuneNetwork', 'ClientConfig', 'ValidateProject')] [string]$Mode = 'Interactive',
        [string]$PlanPath,
        [string[]]$OnlyModule,
        [string]$InstanceRoot,
        [string]$ClashAuthorityPath,
        [string]$SingBoxAuthorityPath,
        [string]$ClientOutputRoot,
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '需要 PowerShell 7 或更高版本。' }
    if ([string]::IsNullOrWhiteSpace($InstanceRoot)) {
        $settings = Get-VpsAppDefaults -ProjectRoot $ProjectRoot
        $configuredRoot = if ($env:MXH_VPS_INSTANCE_ROOT) { $env:MXH_VPS_INSTANCE_ROOT } else { [string]$settings.instance_root }
        $InstanceRoot = Resolve-VpsPortablePath -ProjectRoot $ProjectRoot -Path $configuredRoot
    }
    if ($Mode -eq 'ValidateProject') {
        Test-VpsProject -ProjectRoot $ProjectRoot
        return
    }
    if ($Mode -eq 'Interactive') {
        while ($true) {
            try {
                $choice = Read-VpsMenu '请选择操作' @(
                    '新部署',
                    '继续未完成部署',
                    '导入/纳管没有 deployment-plan 的现有 VPS',
                    '现有 VPS 协议管理',
                    '现有 VPS 运维中心',
                    '现有 VPS 独立网络调优',
                    'Clash/sing-box 客户端权威配置设计器',
                    '项目离线自检',
                    '退出'
                ) 1 -HelpText @'
1 新部署：为新 VPS 建立归档、SSH、防火墙和所选协议，会修改服务器。
2 继续未完成部署：读取已有 deployment-plan.json，从未完成模块继续。
3 导入/纳管：保留现有服务，建立可维护计划和基线。
4 协议管理：进入安装、共存、切换、停用、卸载和备份子菜单。
5 运维中心：进入恢复、审计、轮换、SSH、防火墙、升级、客户端、Komari 和退役子菜单。
6 独立网络调优：可单独为已有 VPS 应用保守参数，标称带宽必填，RTT 可选。
7 客户端配置设计器：使用通用模板、受管片段、手动节点或可选现有配置生成并验证配置。
8 项目离线自检：不连接 VPS，仅检查本地代码、模板和依赖。
9 退出：结束脚本，不修改任何内容。
'@
            }
            catch {
                if (Test-VpsWizardBackError $_) { return }
                throw
            }
            if ($choice -eq 9) { return }
            $selectedMode = @('New', 'Resume', 'Import', 'Migrate', 'Maintain', 'TuneNetwork', 'ClientConfig', 'ValidateProject')[$choice - 1]
            if ($selectedMode -eq 'ValidateProject') {
                Test-VpsProject -ProjectRoot $ProjectRoot
                Write-VpsUi '项目离线自检完成，已返回主菜单。' Success
                continue
            }
            try {
                Invoke-VpsDeploymentSession -ProjectRoot $ProjectRoot -Mode $selectedMode -PlanPath $PlanPath `
                    -OnlyModule $OnlyModule -InstanceRoot $InstanceRoot -ClashAuthorityPath $ClashAuthorityPath `
                    -SingBoxAuthorityPath $SingBoxAuthorityPath -ClientOutputRoot $ClientOutputRoot `
                    -DryRun:$DryRun -NonInteractive:$NonInteractive
                Write-VpsUi '当前功能已结束，已返回主菜单。' Info
                $PlanPath = $null
                continue
            }
            catch {
                if (-not (Test-VpsNavigationError $_)) { throw }
                Write-VpsUi (Get-VpsNavigationMessage $_) Info
                $PlanPath = $null
                continue
            }
        }
    }

    try {
        Invoke-VpsDeploymentSession -ProjectRoot $ProjectRoot -Mode $Mode -PlanPath $PlanPath `
            -OnlyModule $OnlyModule -InstanceRoot $InstanceRoot -ClashAuthorityPath $ClashAuthorityPath `
            -SingBoxAuthorityPath $SingBoxAuthorityPath -ClientOutputRoot $ClientOutputRoot `
            -DryRun:$DryRun -NonInteractive:$NonInteractive
    }
    catch {
        if (-not (Test-VpsNavigationError $_)) { throw }
        Write-VpsUi (Get-VpsNavigationMessage $_) Info
        return
    }
}

. (Join-Path $PSScriptRoot 'VpsDeploy.Migration.ps1')
. (Join-Path $PSScriptRoot 'VpsDeploy.Import.ps1')
. (Join-Path $PSScriptRoot 'VpsDeploy.Operations.ps1')
. (Join-Path $PSScriptRoot 'VpsDeploy.ClientConfig.ps1')

Export-ModuleMember -Function @(
    'Start-VpsDeploy', 'Write-VpsUi', 'Write-VpsLog', 'Read-VpsYesNo', 'Read-VpsText',
    'ConvertFrom-VpsSecureString', 'Invoke-VpsRemoteScript', 'Invoke-VpsSshCommand',
    'Invoke-VpsScpDownload', 'Invoke-VpsScpUpload', 'Initialize-VpsBootstrapAccess', 'Test-VpsSshConnection',
    'Save-VpsContext', 'Save-VpsJson', 'Protect-VpsPrivateFile', 'Get-VpsSshKeyPath',
    'Invoke-VpsProcess', 'Get-VpsCommandPath', 'Get-VpsModules', 'Get-VpsRandomPort',
    'New-VpsRandomString', 'Test-VpsProject', 'Get-VpsMarkerValue', 'Get-VpsSshArguments',
    'Read-VpsNetworkTuningSettings', 'Get-VpsConservativeNetworkPlan',
    'Get-MxhRealityTargetSettings', 'Set-MxhRealityExternalTarget',
    'New-MxhXrayInbound', 'New-MxhXrayServerConfig', 'New-MxhMihomoProfileText', 'Invoke-MxhMihomoEgressTest',
    'New-MxhAnyTlsPaddingScheme', 'Get-MxhAnyTlsPaddingScheme',
    'ConvertFrom-MxhEchKeyPairText', 'New-MxhAnyTlsServerConfig', 'New-MxhAnyTlsClientOutbound', 'New-MxhAnyTlsMihomoProfileText',
    'New-MxhRandomBase64Key', 'New-MxhShadowsocksServerConfig', 'New-MxhLandingMihomoProfileText',
    'New-VpsRemoteScriptPayload', 'Get-MxhMigrationModuleIds', 'Test-MxhProtocolMigrationSource',
    'Get-MxhProtocolInventory', 'Get-MxhInventoryPrimaryRole', 'Get-MxhProtocolFirewallParameters',
    'New-MxhProtocolMigrationPlan', 'New-MxhProtocolLifecyclePlan', 'New-MxhNetworkTuningPlan'
)
