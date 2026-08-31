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
    $normalized = ConvertTo-VpsInputPath -Value $Path
    $expanded = [Environment]::ExpandEnvironmentVariables($normalized)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot $expanded))
}

function Test-VpsClientCoreExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('mihomo', 'sing-box')][string]$Core,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "测试核心不存在：$Path" }
    $arguments = if ($Core -eq 'mihomo') { @('-v') } else { @('version') }
    $result = Invoke-VpsProcess -FilePath $Path -ArgumentList $arguments -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) { throw "$Core 测试核心无法执行或版本查询失败。" }
    $versionText = (($result.StdOut + "`n" + $result.StdErr).Trim())
    if ($versionText -notmatch [regex]::Escape($(if ($Core -eq 'mihomo') { 'Mihomo' } else { 'sing-box' }))) {
        throw "$Core 测试核心返回了无法识别的版本信息。"
    }
    return $versionText
}

function Get-VpsBundledClientCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidateSet('mihomo', 'sing-box')][string]$Core
    )
    if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
        throw '项目内置测试核心仅支持 Windows amd64 控制端。'
    }
    $versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    $catalog = if ($Core -eq 'mihomo') { $versions.mihomo } else { $versions.sing_box }
    $asset = $catalog.assets.windows_amd64
    if (-not $asset -or -not $asset.name -or -not $asset.sha256) { throw "$Core 的 Windows amd64 资产目录不完整。" }
    $manifestPath = Join-Path $ProjectRoot 'vendor\test-cores\windows-amd64\checksums.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw '内置测试核心 checksums.json 缺失。' }
    $manifest = Read-VpsJsonHashtable -Path $manifestPath
    $manifestEntry = @($manifest.artifacts | Where-Object { [string]$_.core -eq $Core } | Select-Object -First 1)
    if (-not $manifestEntry.Count -or [string]$manifestEntry[0].file -ne [string]$asset.name -or
        ([string]$manifestEntry[0].sha256).ToLowerInvariant() -ne ([string]$asset.sha256).ToLowerInvariant()) {
        throw "$Core 的 versions.json 与 vendor checksums.json 不一致。"
    }
    $archive = Join-Path $ProjectRoot ("vendor\test-cores\windows-amd64\" + [string]$asset.name)
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "$Core 内置测试核心压缩包缺失。" }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = ([string]$asset.sha256).ToLowerInvariant()
    if ($actual -ne $expected) { throw "$Core 内置测试核心 SHA-256 不匹配。" }

    $cacheRoot = Join-Path $ProjectRoot (".cache\client-cores\$Core-$([string]$catalog.version)-windows-amd64")
    $hashMarker = Join-Path $cacheRoot '.archive-sha256'
    $executableName = if ($Core -eq 'mihomo') { 'mihomo*.exe' } else { 'sing-box.exe' }
    $cached = @(Get-ChildItem -LiteralPath $cacheRoot -Recurse -File -Filter $executableName -ErrorAction SilentlyContinue | Select-Object -First 1)
    $markerValue = if (Test-Path -LiteralPath $hashMarker -PathType Leaf) { (Get-Content -Raw -LiteralPath $hashMarker).Trim() } else { '' }
    if (-not $cached.Count -or $markerValue -ne $expected) {
        if (Test-Path -LiteralPath $cacheRoot) { Remove-Item -LiteralPath $cacheRoot -Recurse -Force }
        [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $cacheRoot -Force
        $cached = @(Get-ChildItem -LiteralPath $cacheRoot -Recurse -File -Filter $executableName | Select-Object -First 1)
        if (-not $cached.Count) { throw "$Core 压缩包中没有预期的可执行文件。" }
        [IO.File]::WriteAllText($hashMarker, $expected + "`n", [Text.UTF8Encoding]::new($false))
    }
    Test-VpsClientCoreExecutable -Core $Core -Path $cached[0].FullName | Out-Null
    return $cached[0].FullName
}

function Resolve-VpsClientValidationCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('mihomo', 'sing-box')][string]$Core
    )
    while ($true) {
        try {
            $path = Get-VpsBundledClientCore -ProjectRoot $Context.ProjectRoot -Core $Core
            return [ordered]@{ Core = $Core; Status = 'Ready'; Path = $path; Source = 'BundledVerified'; ResolvedAt = (Get-Date).ToString('o') }
        }
        catch {
            $failure = $_.Exception.Message
            if ($Context.NonInteractive) { throw "$Core 是强制前置条件，非交互模式不能跳过：$failure" }
            Write-VpsUi "$Core 内置测试核心不可用：$failure" Warning
            $choice = Read-VpsMenu "$Core 测试核心处理" @(
                '重新校验并解压项目内置核心',
                '手动选择该核心的可执行文件',
                '明确跳过该核心验收（记录为 SkippedByUser，不算通过）'
            ) 1 -AllowBack
            if ($choice -eq 1) { continue }
            if ($choice -eq 2) {
                $manual = Read-VpsText "$Core 可执行文件路径" -AllowBack -Validate {
                    param($value) Test-VpsExistingInputPath -Value $value -PathType Leaf
                } -ValidationMessage '找不到文件；路径可全用 / 或全用 \，但不能混用。'
                $manual = (Resolve-Path -LiteralPath (ConvertTo-VpsInputPath -Value $manual)).Path
                Test-VpsClientCoreExecutable -Core $Core -Path $manual | Out-Null
                return [ordered]@{ Core = $Core; Status = 'Ready'; Path = $manual; Source = 'Manual'; ResolvedAt = (Get-Date).ToString('o') }
            }
            $confirmation = Read-VpsText "输入 SKIP-$($Core.ToUpperInvariant()) 确认跳过" -AllowBack
            if ($confirmation -cne "SKIP-$($Core.ToUpperInvariant())") { Write-VpsUi '确认短语不匹配，未跳过。' Warning; continue }
            $reason = Read-VpsText '记录跳过原因' -AllowBack -Validate { param($value) $value.Trim().Length -ge 3 } -ValidationMessage '原因至少输入 3 个字符。'
            return [ordered]@{ Core = $Core; Status = 'SkippedByUser'; Path = ''; Source = 'ExplicitOverride'; Reason = $reason; ResolvedAt = (Get-Date).ToString('o') }
        }
    }
}

function Get-VpsMihomoCorePaths {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $found = [Collections.Generic.List[string]]::new()
    try { $found.Add((Get-VpsBundledClientCore -ProjectRoot $ProjectRoot -Core mihomo)) }
    catch { }
    $settings = Get-VpsAppDefaults -ProjectRoot $ProjectRoot
    foreach ($value in @($env:MXH_VPS_MIHOMO_ALPHA, [string]$settings.mihomo.alpha_executable)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $path = Resolve-VpsPortablePath -ProjectRoot $ProjectRoot -Path $value
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and $path -notin $found) { $found.Add($path) }
    }
    return @($found)
}

function Get-VpsSingBoxCorePath {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    return Get-VpsBundledClientCore -ProjectRoot $ProjectRoot -Core 'sing-box'
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

    $showPrompt = {
        Write-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($Default)) {
            Write-Host "  默认值：$Default（直接按 Enter/回车采用）" -ForegroundColor DarkGray
        }
        if ($AllowBack) {
            if ($ZeroIsValue) { Write-Host '  本字段的 0 是有效数值；返回请在上一层菜单操作。' -ForegroundColor DarkGray }
            else { Write-Host '  输入 0 返回上一级。' -ForegroundColor DarkGray }
        }
    }

    & $showPrompt
    while ($true) {
        $value = Read-Host '请输入'
        if ($null -eq $value) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        if (Test-VpsClearCommand $value) {
            Clear-VpsScreen
            & $showPrompt
            continue
        }
        if (Test-VpsHelpCommand $value) {
            $navigationHelp = if ($AllowBack) {
                if ($ZeroIsValue) { '；本字段的 0 是有效数值，返回请在上一层菜单操作' }
                else { '；输入 0 返回上一级' }
            } else { '' }
            Show-VpsHelp $(if ($HelpText) { $HelpText } else { "请按提示输入此字段；clear/cls 清屏$navigationHelp。" })
            & $showPrompt
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

    $showPrompt = {
        Write-Host $Prompt
        Write-Host ("  默认值：{0}（直接按 Enter/回车采用）" -f $(if ($Default) { '是' } else { '否' })) -ForegroundColor DarkGray
        if ($AllowBack) { Write-Host '  输入 0 返回上一级。' -ForegroundColor DarkGray }
    }

    & $showPrompt
    while ($true) {
        $rawAnswer = Read-Host '请输入 y/n'
        if ($null -eq $rawAnswer) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        $answer = $rawAnswer.Trim().ToLowerInvariant()
        if (Test-VpsClearCommand $answer) {
            Clear-VpsScreen
            & $showPrompt
            continue
        }
        if (Test-VpsHelpCommand $answer) {
            Show-VpsHelp '输入 y/yes/是 表示确认；输入 n/no/否 表示拒绝；直接按 Enter/回车采用提示中的默认值。'
            & $showPrompt
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
        Write-Host ("  默认项：{0}（直接按 Enter/回车采用）" -f $Default) -ForegroundColor DarkGray
        Write-Host '  clear / cls. 清除当前屏幕输出' -ForegroundColor DarkGray
        Write-Host '  help / h. 查看帮助说明' -ForegroundColor DarkGray
    }
    & $showMenu
    while ($true) {
        $raw = Read-Host '请选择'
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

function Wait-VpsReturnToMainMenu {
    [CmdletBinding()]
    param()

    Write-Host ''
    if ([Console]::IsInputRedirected) {
        Write-VpsUi '当前操作已停止并返回主菜单。' Info
        return
    }
    try {
        Write-Host '请按任意键返回主菜单 . . .' -NoNewline
        [void][Console]::ReadKey($true)
        Write-Host ''
    }
    catch {
        [void](Read-Host '请按 Enter/回车返回主菜单')
    }
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

function Test-VpsReusableBootstrapSshPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$Port)

    # Provider-assigned non-privileged SSH ports can remain the managed primary
    # entry.  Keep protocol-reserved ports out of this path because those ports
    # must coexist with SSH during the staged deployment.
    return $Port -ge 1024 -and $Port -le 65535 -and $Port -notin @(8443)
}

function New-VpsSshPortSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$BootstrapPort)

    if ($BootstrapPort -lt 1 -or $BootstrapPort -gt 65535) {
        throw '服务商当前 SSH 端口必须在 1–65535。'
    }
    $reserved = @($BootstrapPort, 443, 8443)
    $reuseBootstrap = Test-VpsReusableBootstrapSshPort -Port $BootstrapPort
    $primary = if ($reuseBootstrap) {
        $BootstrapPort
    }
    else {
        Get-VpsRandomPort -Exclude $reserved
    }
    $rescue = Get-VpsRandomPort -Exclude ($reserved + @($primary))
    return [ordered]@{
        ReuseBootstrap = $reuseBootstrap
        Primary = [int]$primary
        Rescue = [int]$rescue
    }
}

function Test-VpsBootstrapSshPortRetained {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Collections.IDictionary]$Plan)

    $bootstrap = [int]$Plan.Server.BootstrapSshPort
    return $bootstrap -in @([int]$Plan.Ports.SshPrimary, [int]$Plan.Ports.SshRescue)
}

function Test-VpsSupportedOsRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$VersionId
    )

    $normalizedId = $Id.Trim().ToLowerInvariant()
    $normalizedVersion = $VersionId.Trim().Trim('"')
    switch ($normalizedId) {
        'debian' { return $normalizedVersion -match '^(12|13)(?:\.|$)' }
        default { return $false }
    }
}

function Get-VpsSupportedAssetArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Architecture)
    if ($Architecture.Trim().ToLowerInvariant() -in @('x86_64', 'amd64')) { return 'amd64' }
    throw "当前正式支持的 VPS 架构仅为 amd64，检测到：$Architecture"
}

function Assert-VpsSupportedTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OsId,
        [Parameter(Mandatory)][string]$OsVersion,
        [Parameter(Mandatory)][string]$Architecture
    )
    if (-not (Test-VpsSupportedOsRelease -Id $OsId -VersionId $OsVersion)) {
        throw "当前正式支持的 VPS 系统仅为 Debian 12/13，检测到：$OsId $OsVersion"
    }
    [void](Get-VpsSupportedAssetArchitecture -Architecture $Architecture)
    return $true
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

function Test-VpsPathSeparatorStyle {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Value,
        [switch]$AllowEmpty
    )

    $candidate = $Value.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return [bool]$AllowEmpty }
    return -not ($candidate.Contains('/') -and $candidate.Contains('\'))
}

function ConvertTo-VpsInputPath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Value,
        [switch]$AllowEmpty
    )

    $candidate = $Value.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        if ($AllowEmpty) { return '' }
        throw '路径不能为空。'
    }
    if (-not (Test-VpsPathSeparatorStyle -Value $candidate)) {
        throw '同一路径不能混用 / 和 \ 作为路径分隔符；请统一使用其中一种。'
    }

    $nativeSeparator = [IO.Path]::DirectorySeparatorChar
    if ($candidate.Contains('/')) { return $candidate.Replace([char]'/', $nativeSeparator) }
    if ($candidate.Contains('\')) { return $candidate.Replace([char]'\', $nativeSeparator) }
    return $candidate
}

function Test-VpsExistingInputPath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string]$Value,
        [ValidateSet('Any', 'Leaf', 'Container')] [string]$PathType = 'Any',
        [switch]$AllowEmpty
    )

    try { $candidate = ConvertTo-VpsInputPath -Value $Value -AllowEmpty:$AllowEmpty }
    catch { return $false }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return [bool]$AllowEmpty }
    if ($PathType -eq 'Any') { return Test-Path -LiteralPath $candidate }
    return Test-Path -LiteralPath $candidate -PathType $PathType
}

function Test-VpsArchiveRoot {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    try {
        $candidate = ConvertTo-VpsInputPath -Value $Value
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

function Get-MxhAddressFamilyNodeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily,
        [Parameter(Mandatory)][bool]$DualStack
    )
    if (-not $DualStack) { return $BaseName }
    return "$BaseName-$AddressFamily"
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

function Show-VpsXrayVersionSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('FixedVerified', 'LatestStable')][string]$Channel,
        [Parameter(Mandatory)][string]$ResolvedVersion,
        [Parameter(Mandatory)][string]$FixedVersion,
        [ValidateSet('部署', '升级')][string]$Action = '部署'
    )

    if ($Channel -eq 'LatestStable') {
        Write-VpsUi 'Xray 版本来源：XTLS/Xray-core 官方最新稳定版（LatestStable）。' Info
        Write-VpsUi "本次实际$($Action)版本：Xray $ResolvedVersion。" Success
        if ($ResolvedVersion -eq $FixedVersion) {
            Write-VpsUi "版本对比：官方 latest 与项目固定验证版当前同为 Xray $ResolvedVersion；本次版本来源仍是 LatestStable。" Info
        }
        else {
            Write-VpsUi "版本对比：官方 latest 为 Xray $ResolvedVersion，项目固定验证版为 Xray $FixedVersion；本次采用官方 latest。" Info
        }
        return
    }

    Write-VpsUi 'Xray 版本来源：项目当前固定验证版（FixedVerified）。' Info
    Write-VpsUi "本次实际$($Action)版本：Xray $ResolvedVersion。" Success
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
    Write-Host '返回统一输入 0；第一项输入 0 返回主菜单。' -ForegroundColor DarkGray

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
        $regenerated = $wizard.PortBasis -ne $basis -or -not $wizard.AutoSshPrimary
        if ($regenerated) {
            $sshSelection = New-VpsSshPortSelection -BootstrapPort ([int]$wizard.BootstrapPort)
            $usedPorts = @([int]$wizard.BootstrapPort, 443, 8443)
            $wizard.AutoSshPrimary = [int]$sshSelection.Primary
            $usedPorts += [int]$wizard.AutoSshPrimary
            $wizard.AutoSshRescue = [int]$sshSelection.Rescue
            $usedPorts += [int]$wizard.AutoSshRescue
            $wizard.AutoXrayBackup = Get-VpsRandomPort -Exclude $usedPorts
            $usedPorts += [int]$wizard.AutoXrayBackup
            $wizard.AutoLandingPort = Get-VpsRandomPort -Exclude $usedPorts
            $wizard.PortBasis = $basis
        }
        if (-not $wizard.ManualPorts -or $regenerated) {
            $wizard.SshPrimary = $wizard.AutoSshPrimary
            $wizard.SshRescue = $wizard.AutoSshRescue
            $wizard.XrayBackup = $wizard.AutoXrayBackup
            $wizard.LandingPort = $wizard.AutoLandingPort
        }
        else {
            if (Test-VpsReusableBootstrapSshPort -Port ([int]$wizard.BootstrapPort)) {
                $wizard.SshPrimary = [int]$wizard.BootstrapPort
            }
            elseif (-not $wizard.SshPrimary) { $wizard.SshPrimary = $wizard.AutoSshPrimary }
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
                    -ValidationMessage '请输入不是磁盘根目录的完整绝对路径；可全用 / 或全用 \，但不能混用。'
                $wizard.InstanceRoot = [IO.Path]::GetFullPath((ConvertTo-VpsInputPath -Value $value)).TrimEnd('\', '/')
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
                    Test-VpsExistingInputPath -Value $v -PathType Leaf
                } -ValidationMessage '找不到该私钥文件；路径可全用 / 或全用 \，但不能混用。'
                $wizard.BootstrapKeyPath = (Resolve-Path -LiteralPath (ConvertTo-VpsInputPath -Value $inputPath)).Path
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
                Show-VpsXrayVersionSelection -Channel $wizard.XrayVersionChannel `
                    -ResolvedVersion $wizard.XrayVersion -FixedVersion ([string]$versions.xray.version) -Action '部署'
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
                $wizard.ManualPorts = Read-VpsYesNo '是否手动指定需要新增的高位端口？' ([bool]$wizard.ManualPorts) -AllowBack
                if (-not $wizard.ManualPorts) { & $ensureAutoPorts }
            }
        },
        [pscustomobject]@{
            Id = 'ssh-primary'; ShouldRun = {
                [bool]$wizard.ManualPorts -and -not (Test-VpsReusableBootstrapSshPort -Port ([int]$wizard.BootstrapPort))
            }; Run = {
                $wizard.SshPrimary = [int](Read-VpsText 'SSH 主端口' -Default ([string]$wizard.SshPrimary) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -ne [int]$wizard.BootstrapPort
                } -ValidationMessage '请输入 20000–59999 内且不与初始 SSH 端口冲突的端口。')
            }
        },
        [pscustomobject]@{
            Id = 'ssh-rescue'; ShouldRun = { [bool]$wizard.ManualPorts }; Run = {
                $wizard.SshRescue = [int](Read-VpsText 'SSH 救援端口' -Default ([string]$wizard.SshRescue) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin @([int]$wizard.BootstrapPort, [int]$wizard.SshPrimary)
                } -ValidationMessage '请输入未与主 SSH 冲突的 20000–59999 救援端口。')
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
                    -Validate { param($v) Test-VpsExistingInputPath -Value $v -PathType Leaf } `
                    -ValidationMessage '找不到 Token 文件；路径可全用 / 或全用 \，但不能混用。'
                $wizard.CloudflareTokenFile = (Resolve-Path -LiteralPath (ConvertTo-VpsInputPath -Value $value)).Path
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
                    -not [string]::IsNullOrWhiteSpace($v) -and $v -notin @('Proxy', [string]$wizard.NodeName, "$($wizard.NodeName)-IPv4", "$($wizard.NodeName)-IPv6")
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
        DeploymentTransaction = [ordered]@{
            SchemaVersion = 1
            Id = ([Guid]::NewGuid().ToString('N'))
            Status = 'Planned'
            RollbackScope = 'ManagedStateWithRecoveryKey'
        }
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
    # 用户明确要求 VPS 私有归档及相关本地文件沿用所在目录权限；
    # 保留调用点以兼容旧模块，但不再修改或检查额外 ACL/文件模式。
    return
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

function Update-VpsPrivateArchiveChecksums {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if ($Context.DryRun) { return }
    $archive = [IO.Path]::GetFullPath([string]$Context.ArchivePath).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $archive -PathType Container)) {
        throw '实例私有归档目录不存在，无法生成校验和。'
    }
    $checksumPath = Join-Path $archive 'SHA256SUMS-private.txt'
    $files = Get-ChildItem -LiteralPath $archive -File -Recurse |
        Where-Object { -not $_.FullName.Equals($checksumPath, [StringComparison]::OrdinalIgnoreCase) }
    $lines = foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($archive, $file.FullName).Replace('\', '/')
        try {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName -ErrorAction Stop).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
        catch { "# UNREADABLE-SKIPPED  $relative" }
    }
    [IO.File]::WriteAllText($checksumPath, (($lines | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Protect-VpsPrivateFile $checksumPath
}

function ConvertTo-VpsOptionalStateJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$State,
        [Parameter(Mandatory)] [string]$Name,
        [int]$Depth = 8
    )

    $value = if ($State.Contains($Name)) {
        $State[$Name]
    }
    else {
        [ordered]@{ Status = 'NotRecorded' }
    }
    return $value | ConvertTo-Json -Compress -Depth $Depth
}

function Invoke-VpsProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [AllowNull()] [string]$InputText,
        [int]$TimeoutSeconds = 300,
        [string]$ProgressActivity
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
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "无法启动进程：$FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $progressShown = $false
    $lastProgressLength = 0
    $lastProgressElapsed = ''
    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }
    try {
        if ([string]::IsNullOrWhiteSpace($ProgressActivity)) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                try { $process.Kill($true) } catch { }
                throw "进程执行超时（${TimeoutSeconds}s）：$FilePath"
            }
        }
        else {
            while (-not $process.WaitForExit(500)) {
                if ($stopwatch.Elapsed.TotalSeconds -ge 2) {
                    $progressShown = $true
                    $elapsed = $stopwatch.Elapsed.ToString('hh\:mm\:ss')
                    if ($elapsed -ne $lastProgressElapsed) {
                        try {
                            $progressText = "$ProgressActivity（已运行 $elapsed，任务仍在执行，请勿关闭窗口）"
                            $padding = ' ' * [Math]::Max(0, $lastProgressLength - $progressText.Length)
                            Write-Host ("`r" + $progressText + $padding) -NoNewline
                            $lastProgressLength = $progressText.Length
                            $lastProgressElapsed = $elapsed
                        }
                        catch { }
                    }
                }
                if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    try { $process.Kill($true) } catch { }
                    throw "进程执行超时（${TimeoutSeconds}s）：$FilePath"
                }
            }
        }
    }
    finally {
        $stopwatch.Stop()
        if ($progressShown) {
            try {
                $elapsed = $stopwatch.Elapsed.ToString('hh\:mm\:ss')
                $progressText = "$ProgressActivity（已结束，用时 $elapsed）"
                $padding = ' ' * [Math]::Max(0, $lastProgressLength - $progressText.Length)
                Write-Host ("`r" + $progressText + $padding)
            }
            catch { }
        }
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

function Get-VpsManagedSshKeyPath {
    param([Parameter(Mandatory)] $Context)
    $fileName = 'id_ed25519'
    if ($Context.Plan.Contains('SshKey') -and $Context.Plan.SshKey.Contains('ManagedFileName') -and
        -not [string]::IsNullOrWhiteSpace([string]$Context.Plan.SshKey.ManagedFileName)) {
        $fileName = [string]$Context.Plan.SshKey.ManagedFileName
    }
    return Join-Path ([string]$Context.Plan.Paths.KeyDirectory) $fileName
}

function Get-VpsSshKeyPath {
    param([Parameter(Mandatory)] $Context)
    if ($Context.Plan.Contains('SshKey') -and [string]$Context.Plan.SshKey.Mode -eq 'ReuseExisting' -and
        $Context.Plan.SshKey.Contains('SourcePrivateKeyPath') -and $Context.Plan.SshKey.SourcePrivateKeyPath) {
        $source = [IO.Path]::GetFullPath([string]$Context.Plan.SshKey.SourcePrivateKeyPath)
        if (Test-Path -LiteralPath $source -PathType Leaf) { return $source }
    }
    return Get-VpsManagedSshKeyPath -Context $Context
}

function Get-VpsSshPublicKeyPath {
    param([Parameter(Mandatory)] $Context)
    return (Get-VpsManagedSshKeyPath -Context $Context) + '.pub'
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
        $arguments.Add('-o'); $arguments.Add('IdentitiesOnly=yes')
        $arguments.Add('-o'); $arguments.Add('PreferredAuthentications=publickey')
        $arguments.Add('-o'); $arguments.Add('PasswordAuthentication=no')
        $arguments.Add('-o'); $arguments.Add('KbdInteractiveAuthentication=no')
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

function Test-VpsSupportedSshPublicKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PublicKey)

    return [regex]::IsMatch(
        $PublicKey.Trim(),
        '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))\s+[A-Za-z0-9+/=]+(?:\s+.*)?$'
    )
}

function New-VpsBootstrapAccessCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PublicKey)

    $quotedKey = ConvertTo-VpsShellSingleQuote $PublicKey
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $assetPath = Join-Path $projectRoot 'assets\remote\bootstrap-access.sh'
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "缺少远端引导脚本：$assetPath"
    }
    $scriptText = [IO.File]::ReadAllText($assetPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))
    return "printf '%s' '$encoded' | base64 -d | VPS_PARAM_PUBLIC_KEY=$quotedKey bash -s"
}

function Initialize-VpsSshKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $keyPath = Get-VpsManagedSshKeyPath $Context
    $publicPath = $keyPath + '.pub'
    $sshKeygen = Get-VpsCommandPath 'ssh-keygen.exe'
    if ((Test-Path -LiteralPath $keyPath) -and (Test-Path -LiteralPath $publicPath)) {
        Protect-VpsPrivateFile -Path $keyPath
        $activeKeyPath = Get-VpsSshKeyPath $Context
        $derivedExisting = Invoke-VpsProcess -FilePath $sshKeygen -ArgumentList @('-y', '-f', $activeKeyPath) -TimeoutSeconds 60
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
        $derived = Invoke-VpsProcess -FilePath $sshKeygen -ArgumentList @('-y', '-f', $sourceResolved) -TimeoutSeconds 60
        $publicMatch = [regex]::Match($derived.StdOut.Trim(), '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))\s+([A-Za-z0-9+/=]+)(?:\s+.*)?$')
        if ($derived.ExitCode -ne 0 -or -not $publicMatch.Success) {
            throw '现有私钥无法作为无交互 OpenSSH 管理密钥使用；请确认格式和口令状态，或选择生成新 Ed25519 密钥。'
        }
        if (-not $sourceResolved.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $sourceResolved -Destination $keyPath -Force
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
    $publicKey = (Get-Content -Raw -LiteralPath (Get-VpsSshPublicKeyPath $Context)).Trim()
    if (-not (Test-VpsSupportedSshPublicKey -PublicKey $publicKey)) { throw '生成的 SSH 公钥格式异常。' }

    $rootPort = [int]$Context.Plan.Server.BootstrapSshPort
    $existing = Invoke-VpsSshCommand -Context $Context -User 'root' -Port $rootPort `
        -Command "printf 'VPSDEPLOY_KEY_OK\\n'" -AllowFailure
    if ($existing.ExitCode -eq 0 -and $existing.StdOut -match 'VPSDEPLOY_KEY_OK') {
        Write-VpsUi '服务商初始端口上的 root 公钥登录已可用。' Success
        return
    }

    $ssh = Get-VpsCommandPath 'ssh.exe'
    $remote = New-VpsBootstrapAccessCommand -PublicKey $publicKey
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
        $arguments = Get-VpsSshArguments -Context $Context -Port $rootPort -User 'root' -Interactive
        while ($true) {
            Write-VpsUi '即将打开 OpenSSH 密码提示，请输入服务商提供的 root 初始密码。' Warning
            Write-VpsUi '密码及粘贴内容不会显示字符或星号；Windows Terminal 可用鼠标右键或 Ctrl+Shift+V 粘贴，确认剪贴板没有首尾空格或换行。' Info
            & $ssh @arguments $remote
            if ($LASTEXITCODE -eq 0) {
                Write-VpsUi '初始密码认证成功，管理公钥已提交到服务器；正在进行独立公钥复验。' Success
                break
            }
            Write-VpsUi '本次初始 SSH 登录未成功，可能是密码、用户名、端口、服务端登录策略或网络问题。尚未关闭任何旧入口。' Error
            $retry = Read-VpsMenu '如何处理初始 SSH 登录失败' @(
                '重新打开 SSH 密码提示',
                '停止本次部署并保留计划，稍后使用继续模式'
            ) 1
            if ($retry -ne 1) { throw '用户停止初始 SSH 登录重试。旧入口未做任何关闭操作。' }
        }
    }

    $verified = $null
    foreach ($attempt in 1..3) {
        $verified = Invoke-VpsSshCommand -Context $Context -User 'root' -Port $rootPort `
            -Command "printf 'VPSDEPLOY_KEY_OK\\n'" -AllowFailure
        if ($verified.ExitCode -eq 0 -and $verified.StdOut -match 'VPSDEPLOY_KEY_OK') { break }
        if ($attempt -lt 3) { Start-Sleep -Milliseconds 800 }
    }
    if ($verified.ExitCode -ne 0 -or $verified.StdOut -notmatch 'VPSDEPLOY_KEY_OK') {
        throw '初始登录认证已经成功，但新管理公钥复验失败；这不是初始密码错误。可能是服务端禁用了公钥登录、使用了非标准 AuthorizedKeysFile，或本机 OpenSSH 没有采用该私钥。旧入口未做任何关闭操作。'
    }
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
        [switch]$SensitiveOutput,
        [string]$ProgressActivity
    )

    $ssh = Get-VpsCommandPath 'ssh.exe'
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($item in (Get-VpsSshArguments -Context $Context -Port $Port -User $User)) { $arguments.Add($item) }
    $arguments.Add($Command)
    $result = Invoke-VpsProcess -FilePath $ssh -ArgumentList $arguments.ToArray() -InputText $InputText `
        -TimeoutSeconds $TimeoutSeconds -ProgressActivity $ProgressActivity
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
        [switch]$SensitiveOutput,
        [string]$ProgressActivity
    )

    if (-not $Port) { $Port = [int]$Context.State.CurrentManagementPort }
    $script = New-VpsRemoteScriptPayload -Context $Context -Asset $Asset -Parameters $Parameters
    if ([string]::IsNullOrWhiteSpace($ProgressActivity)) {
        $ProgressActivity = "远程步骤执行中：$Asset"
    }
    return Invoke-VpsSshCommand -Context $Context -User $User -Port $Port -Command 'bash -s' `
        -InputText $script -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure `
        -SensitiveOutput:$SensitiveOutput -ProgressActivity $ProgressActivity
}

function Get-VpsMarkerValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string]$Text,
        [Parameter(Mandatory)] [string]$Name,
        [switch]$Required
    )

    if ($Name -notmatch '^[A-Z][A-Z0-9_]*$') { throw "标记名称无效：$Name" }
    $markerText = if ($null -eq $Text) { '' } else { $Text }
    $match = [regex]::Match($markerText, "(?m)^VPSDEPLOY_$([regex]::Escape($Name))_B64=([A-Za-z0-9+/=]*)$")
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
        [int]$Port,
        [string]$ProgressActivity
    )

    if (-not $Port) { $Port = [int]$Context.State.CurrentManagementPort }
    $scp = Get-VpsCommandPath 'scp.exe'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $LocalPath)) | Out-Null
    $args = @(
        '-q', '-o', 'BatchMode=yes', '-o', 'ControlMaster=no', '-o', 'StrictHostKeyChecking=accept-new',
        '-i', (Get-VpsSshKeyPath $Context), '-P', $Port.ToString(),
        "root@$($Context.Plan.Server.IPv4):$RemotePath", $LocalPath
    )
    $result = Invoke-VpsProcess -FilePath $scp -ArgumentList $args -TimeoutSeconds 180 -ProgressActivity $ProgressActivity
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
        [Parameter(Mandatory)] [string]$Listen,
        [Parameter(Mandatory)] [Collections.IDictionary]$Secrets,
        [Parameter(Mandatory)] [string]$TargetAddress,
        [Parameter(Mandatory)] [string]$ServerName
    )
    return [ordered]@{
        tag = $Tag
        listen = $Listen
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
    $inbounds = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(
            [ordered]@{ Name = 'primary'; Port = [int]$Context.Plan.Ports.XrayPrimary },
            [ordered]@{ Name = 'backup'; Port = [int]$Context.Plan.Ports.XrayBackup }
        )) {
        if ($entry.Port -lt 1) { continue }
        $inbounds.Add((New-MxhXrayInbound -Tag "reality-$($entry.Name)-ipv4" -Port $entry.Port -Listen '0.0.0.0' `
                    -Secrets $xraySecrets -TargetAddress $target.TargetAddress -ServerName $target.ServerName))
        if ($Context.Plan.Server.IPv6) {
            $ipv6Listen = ([string]$Context.Plan.Server.IPv6).Split('/')[0].Trim('[', ']')
            $inbounds.Add((New-MxhXrayInbound -Tag "reality-$($entry.Name)-ipv6" -Port $entry.Port -Listen $ipv6Listen `
                        -Secrets $xraySecrets -TargetAddress $target.TargetAddress -ServerName $target.ServerName))
        }
    }
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
        [Parameter(Mandatory)] [int]$MixedPort,
        [ValidateSet('IPv4', 'IPv6')][string]$AddressFamily = 'IPv4'
    )
    $server = if ($AddressFamily -eq 'IPv6') { [string]$Context.Plan.Server.IPv6 } else { [string]$Context.Plan.Server.IPv4 }
    if ([string]::IsNullOrWhiteSpace($server)) { throw "计划未配置 $AddressFamily 地址。" }
    $nodeName = Get-MxhAddressFamilyNodeName -BaseName ([string]$Context.Plan.NodeName) `
        -AddressFamily $AddressFamily -DualStack ([bool]$Context.Plan.Server.IPv6)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
            "mixed-port: $MixedPort", 'allow-lan: false', 'bind-address: 127.0.0.1',
            'mode: rule', 'log-level: warning', 'ipv6: true', '', 'proxies:',
            "  - name: $(ConvertTo-MxhYamlString $nodeName)",
            '    type: anytls',
            "    server: $(ConvertTo-MxhYamlString $server)",
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
        [switch]$IncludeIpv6,
        [ValidateSet('IPv4', 'IPv6', 'Dual')][string]$AddressFamily = 'IPv4'
    )
    if ($IncludeIpv6) { $AddressFamily = 'Dual' }
    $s = $Context.Secrets.Xray
    $realityTarget = Get-MxhRealityTargetSettings -Plan $Context.Plan
    $nodeBase = [string]$Context.Plan.NodeName
    $dualStack = [bool]$Context.Plan.Server.IPv6
    $node4 = Get-MxhAddressFamilyNodeName -BaseName $nodeBase -AddressFamily IPv4 -DualStack $dualStack
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

    $nodes = [Collections.Generic.List[string]]::new()
    if ($AddressFamily -in @('IPv4', 'Dual')) {
        Add-MxhNode $node4 ([string]$Context.Plan.Server.IPv4)
        $nodes.Add($node4)
    }
    if ($AddressFamily -in @('IPv6', 'Dual')) {
        if (-not $Context.Plan.Server.IPv6) { throw '计划未配置 IPv6，不能生成 IPv6 Reality 验收配置。' }
        $node6 = Get-MxhAddressFamilyNodeName -BaseName $nodeBase -AddressFamily IPv6 -DualStack $dualStack
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

function New-MxhRealitySingBoxOutbound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$ServerPort,
        [ValidateSet('IPv4', 'IPv6')][string]$AddressFamily = 'IPv4'
    )
    $server = if ($AddressFamily -eq 'IPv6') { [string]$Context.Plan.Server.IPv6 } else { [string]$Context.Plan.Server.IPv4 }
    if ([string]::IsNullOrWhiteSpace($server)) { throw "计划未配置 $AddressFamily 地址。" }
    $secrets = $Context.Secrets.Xray
    $target = Get-MxhRealityTargetSettings -Plan $Context.Plan
    return [ordered]@{
        type = 'vless'
        tag = 'proxy'
        server = $server
        server_port = $ServerPort
        uuid = [string]$secrets.Uuid
        flow = 'xtls-rprx-vision'
        packet_encoding = 'xudp'
        tls = [ordered]@{
            enabled = $true
            server_name = [string]$target.ServerName
            utls = [ordered]@{ enabled = $true; fingerprint = 'chrome' }
            reality = [ordered]@{
                enabled = $true
                public_key = [string]$secrets.RealityClientKey
                short_id = [string]$secrets.ShortId
            }
        }
    }
}

function New-MxhSingBoxTestConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Outbound,
        [Parameter(Mandatory)][int]$MixedPort
    )
    $proxyOutbound = Copy-MxhHashtable -Value $Outbound
    $proxyOutbound.tag = 'proxy'
    return [ordered]@{
        log = [ordered]@{ level = 'warn'; timestamp = $true }
        inbounds = @([ordered]@{
                type = 'mixed'
                tag = 'mixed-in'
                listen = '127.0.0.1'
                listen_port = $MixedPort
            })
        outbounds = @($proxyOutbound, [ordered]@{ type = 'direct'; tag = 'direct' })
        route = [ordered]@{ final = 'proxy' }
    }
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

    $dualStack = [bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled
    $primaryName = Get-MxhAddressFamilyNodeName -BaseName ([string]$Context.Plan.NodeName) -AddressFamily IPv4 -DualStack $dualStack
    Add-MxhLandingNode $primaryName ([string]$credentials.PrimaryUserKey)
    $nodes = [Collections.Generic.List[string]]::new()
    $nodes.Add($primaryName)
    if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
        $secondaryName = Get-MxhAddressFamilyNodeName -BaseName ([string]$Context.Plan.NodeName) -AddressFamily IPv6 -DualStack $dualStack
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

function Read-MxhExactNetworkBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [IO.Stream]$Stream,
        [Parameter(Mandatory)] [int]$Count
    )

    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'SOCKS5 控制连接提前关闭。' }
        $offset += $read
    }
    return $buffer
}

function Invoke-MxhSocks5UdpDnsTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$SocksPort,
        [string]$Label = 'proxy',
        [string]$DnsServer = '1.1.1.1'
    )

    $tcp = [Net.Sockets.TcpClient]::new()
    $udp = $null
    try {
        $connect = $tcp.ConnectAsync([Net.IPAddress]::Loopback, $SocksPort)
        if (-not $connect.Wait([TimeSpan]::FromSeconds(10))) { throw "SOCKS5 连接超时：$Label" }
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 20000
        $stream.WriteTimeout = 20000

        $greeting = [byte[]](5, 1, 0)
        $stream.Write($greeting, 0, $greeting.Length)
        $greetingReply = Read-MxhExactNetworkBytes -Stream $stream -Count 2
        if ($greetingReply[0] -ne 5 -or $greetingReply[1] -ne 0) { throw "SOCKS5 无认证协商失败：$Label" }

        $associate = [byte[]](5, 3, 0, 1, 0, 0, 0, 0, 0, 0)
        $stream.Write($associate, 0, $associate.Length)
        $reply = Read-MxhExactNetworkBytes -Stream $stream -Count 4
        if ($reply[0] -ne 5 -or $reply[1] -ne 0) { throw "SOCKS5 UDP ASSOCIATE 失败：$Label / REP=$($reply[1])" }

        $relayAddress = switch ($reply[3]) {
            1 { [Net.IPAddress]::new((Read-MxhExactNetworkBytes -Stream $stream -Count 4)) }
            3 {
                $length = (Read-MxhExactNetworkBytes -Stream $stream -Count 1)[0]
                $name = [Text.Encoding]::ASCII.GetString((Read-MxhExactNetworkBytes -Stream $stream -Count $length))
                @([Net.Dns]::GetHostAddresses($name) | Where-Object AddressFamily -eq InterNetwork)[0]
            }
            4 { [Net.IPAddress]::new((Read-MxhExactNetworkBytes -Stream $stream -Count 16)) }
            default { throw "SOCKS5 UDP relay 返回未知地址类型：$($reply[3])" }
        }
        $portBytes = Read-MxhExactNetworkBytes -Stream $stream -Count 2
        $relayPort = ([int]$portBytes[0] -shl 8) -bor [int]$portBytes[1]
        if ($relayPort -lt 1) { throw "SOCKS5 UDP relay 未返回有效端口：$Label" }
        if ($relayAddress.Equals([Net.IPAddress]::Any) -or $relayAddress.Equals([Net.IPAddress]::IPv6Any)) {
            $relayAddress = [Net.IPAddress]::Loopback
        }

        $transactionId = [Security.Cryptography.RandomNumberGenerator]::GetBytes(2)
        $dnsQuery = [Collections.Generic.List[byte]]::new()
        $dnsQuery.AddRange([byte[]]($transactionId[0], $transactionId[1], 1, 0, 0, 1, 0, 0, 0, 0, 0, 0))
        foreach ($labelPart in @('one', 'one', 'one', 'one')) {
            $labelBytes = [Text.Encoding]::ASCII.GetBytes($labelPart)
            $dnsQuery.Add([byte]$labelBytes.Length)
            $dnsQuery.AddRange($labelBytes)
        }
        $dnsQuery.AddRange([byte[]](0, 0, 1, 0, 1))

        $dnsAddress = [Net.IPAddress]::Parse($DnsServer)
        if ($dnsAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'UDP DNS 测试端点必须是 IPv4 地址。' }
        $packet = [Collections.Generic.List[byte]]::new()
        $packet.AddRange([byte[]](0, 0, 0, 1))
        $packet.AddRange($dnsAddress.GetAddressBytes())
        $packet.AddRange([byte[]](0, 53))
        $packet.AddRange($dnsQuery.ToArray())
        $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
        $udp.Client.ReceiveTimeout = 20000
        $udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        [void]$udp.Send($packet.ToArray(), $packet.Count, [Net.IPEndPoint]::new($relayAddress, $relayPort))

        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remote)
        if ($response.Length -lt 10 -or $response[0] -ne 0 -or $response[1] -ne 0 -or $response[2] -ne 0) {
            throw "SOCKS5 UDP relay 响应头无效：$Label"
        }
        $payloadOffset = switch ($response[3]) {
            1 { 10 }
            3 { 7 + [int]$response[4] }
            4 { 22 }
            default { throw "SOCKS5 UDP 响应含未知地址类型：$($response[3])" }
        }
        if ($response.Length -lt ($payloadOffset + 12)) { throw "UDP DNS 响应过短：$Label" }
        if ($response[$payloadOffset] -ne $transactionId[0] -or $response[$payloadOffset + 1] -ne $transactionId[1] -or
            ($response[$payloadOffset + 2] -band 0x80) -eq 0) {
            throw "UDP DNS 事务校验失败：$Label"
        }
        return $true
    }
    catch [Net.Sockets.SocketException] {
        throw "UDP DNS 往返失败：$Label / $($_.Exception.Message)"
    }
    finally {
        if ($udp) { $udp.Dispose() }
        $tcp.Dispose()
    }
}

function Invoke-MxhProxyAcceptanceRequests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Proxy,
        [Parameter(Mandatory)][int]$SocksPort,
        [Parameter(Mandatory)][string]$Label
    )
    $httpsEndpoint = $null
    $httpsErrors = [Collections.Generic.List[string]]::new()
    foreach ($uri in @('https://www.gstatic.com/generate_204', 'https://cp.cloudflare.com/generate_204')) {
        try {
            $response = Invoke-WebRequest -Uri $uri -Proxy $Proxy -TimeoutSec 25 -ProgressAction SilentlyContinue
            if ($response.StatusCode -ne 204) { throw "HTTP $($response.StatusCode)" }
            $httpsEndpoint = $uri
            break
        }
        catch { $httpsErrors.Add("$uri => $($_.Exception.Message)") }
    }
    if (-not $httpsEndpoint) { throw "HTTPS 出口验证全部失败：$Label / $($httpsErrors -join ' | ')" }

    $egress = $null
    $ipEndpoint = $null
    $ipErrors = [Collections.Generic.List[string]]::new()
    foreach ($uri in @('https://api64.ipify.org', 'https://icanhazip.com')) {
        try {
            $candidate = ([string](Invoke-RestMethod -Uri $uri -Proxy $Proxy -TimeoutSec 25 -ProgressAction SilentlyContinue)).Trim()
            $parsed = $null
            if (-not [Net.IPAddress]::TryParse($candidate, [ref]$parsed)) { throw '返回内容不是 IP 地址' }
            $egress = $candidate
            $ipEndpoint = $uri
            break
        }
        catch { $ipErrors.Add("$uri => $($_.Exception.Message)") }
    }
    if (-not $ipEndpoint) { throw "出口 IP 验证全部失败：$Label / $($ipErrors -join ' | ')" }

    $udpEndpoint = $null
    $udpErrors = [Collections.Generic.List[string]]::new()
    foreach ($server in @('1.1.1.1', '9.9.9.9')) {
        try {
            Invoke-MxhSocks5UdpDnsTest -SocksPort $SocksPort -Label $Label -DnsServer $server | Out-Null
            $udpEndpoint = $server
            break
        }
        catch { $udpErrors.Add("$server => $($_.Exception.Message)") }
    }
    if (-not $udpEndpoint) { throw "UDP DNS 验证全部失败：$Label / $($udpErrors -join ' | ')" }
    return [ordered]@{ Egress = $egress; HttpsEndpoint = $httpsEndpoint; IpEndpoint = $ipEndpoint; UdpDnsEndpoint = $udpEndpoint }
}

function Invoke-MxhMihomoEgressTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$CorePath,
        [Parameter(Mandatory)] [string]$ProfilePath,
        [Parameter(Mandatory)] [int]$MixedPort,
        [Parameter(Mandatory)] [string]$Label,
        [switch]$Detailed
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
        $acceptance = Invoke-MxhProxyAcceptanceRequests -Proxy "http://127.0.0.1:$MixedPort" -SocksPort $MixedPort -Label $Label
        if ($Detailed) { return $acceptance }
        return $acceptance.Egress
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

function Invoke-MxhSingBoxEgressTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$CorePath,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][int]$MixedPort,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Detailed
    )
    $dataDir = Join-Path $Context.ArchivePath ("client-exports\runtime-sing-box-" + $Label)
    [IO.Directory]::CreateDirectory($dataDir) | Out-Null
    $stdoutPath = Join-Path $dataDir 'sing-box.stdout.log'
    $stderrPath = Join-Path $dataDir 'sing-box.stderr.log'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $CorePath
    $startInfo.WorkingDirectory = $dataDir
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($arg in @('run', '-c', $ProfilePath)) { [void]$startInfo.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "无法启动 sing-box：$Label" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    try {
        Start-Sleep -Milliseconds 1800
        if ($process.HasExited) { throw "sing-box 提前退出：$Label" }
        $acceptance = Invoke-MxhProxyAcceptanceRequests -Proxy "http://127.0.0.1:$MixedPort" -SocksPort $MixedPort -Label $Label
        if ($Detailed) { return $acceptance }
        return $acceptance.Egress
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

function Test-MxhPublicIpv6SourceAddress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [Net.IPAddress]$Address)

    if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) { return $false }
    if ([Net.IPAddress]::IsLoopback($Address) -or $Address.IsIPv6LinkLocal -or $Address.IsIPv6Multicast -or $Address.IsIPv6SiteLocal) { return $false }
    $bytes = $Address.GetAddressBytes()
    # fc00::/7 is commonly used by TUN adapters. A connection sourced from it
    # does not prove that the Windows host has a usable native/public IPv6 path.
    return (($bytes[0] -band 0xfe) -ne 0xfc)
}

function Test-MxhControllerValidationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [ValidateSet('Reality', 'AnyTLS')] [string]$Protocol
    )

    $metadata = Get-MxhValidationTargetMetadata -Target $Target -Protocol $Protocol -Plan $Context.Plan
    if ($metadata.AddressFamily -eq 'IPv4') {
        return [ordered]@{ Usable = $true; AddressFamily = 'IPv4'; Reason = 'IPv4LocalValidation' }
    }
    $serverText = ([string]$Context.Plan.Server.IPv6).Split('/')[0].Trim('[', ']')
    $serverAddress = $null
    if (-not [Net.IPAddress]::TryParse($serverText, [ref]$serverAddress) -or
        $serverAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) {
        return [ordered]@{ Usable = $false; AddressFamily = 'IPv6'; Reason = '计划中的 IPv6 地址无效。' }
    }
    $client = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetworkV6)
    try {
        $connect = $client.ConnectAsync($serverAddress, [int]$metadata.ServerPort)
        if (-not $connect.Wait([TimeSpan]::FromSeconds(12))) {
            return [ordered]@{ Usable = $false; AddressFamily = 'IPv6'; Reason = '本机到目标 IPv6 的 TCP 连接超时。' }
        }
        $local = ([Net.IPEndPoint]$client.Client.LocalEndPoint).Address
        if (-not (Test-MxhPublicIpv6SourceAddress -Address $local)) {
            return [ordered]@{ Usable = $false; AddressFamily = 'IPv6'; Reason = '连接使用了回环、链路本地或 TUN ULA 源地址，不能作为原生 IPv6 验收。' }
        }
        return [ordered]@{ Usable = $true; AddressFamily = 'IPv6'; Reason = 'PublicIpv6Source'; LocalAddress = $local.ToString() }
    }
    catch {
        return [ordered]@{ Usable = $false; AddressFamily = 'IPv6'; Reason = "本机 IPv6 路径不可用：$($_.Exception.Message)" }
    }
    finally { $client.Dispose() }
}

function Get-MxhManagedValidationProbePlans {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $instanceRoot = $null
    if ($Context.Plan.Contains('Paths') -and $Context.Plan.Paths.Contains('InstanceDirectory') -and $Context.Plan.Paths.InstanceDirectory) {
        $providerDirectory = Split-Path -Parent ([string]$Context.Plan.Paths.InstanceDirectory)
        $instanceRoot = Split-Path -Parent $providerDirectory
    }
    if (-not $instanceRoot -or -not (Test-Path -LiteralPath $instanceRoot -PathType Container)) {
        $archiveDirectory = Split-Path -Parent $Context.PlanPath
        $instanceDirectory = Split-Path -Parent $archiveDirectory
        $providerDirectory = Split-Path -Parent $instanceDirectory
        $instanceRoot = Split-Path -Parent $providerDirectory
    }
    if (-not $instanceRoot -or -not (Test-Path -LiteralPath $instanceRoot -PathType Container)) { return @() }
    $current = [IO.Path]::GetFullPath($Context.PlanPath)
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $instanceRoot -Filter 'deployment-plan.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        if ([IO.Path]::GetFullPath($file.FullName).Equals($current, [StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            $plan = ConvertTo-MxhCompatiblePlan -Plan (Read-VpsJsonHashtable -Path $file.FullName)
            $canonicalPlanPath = Join-Path ([string]$plan.Paths.Archive) 'deployment-plan.json'
            if (-not [IO.Path]::GetFullPath($file.FullName).Equals([IO.Path]::GetFullPath($canonicalPlanPath), [StringComparison]::OrdinalIgnoreCase)) { continue }
            $statePath = Join-Path ([string]$plan.Paths.Archive) 'deployment-state.json'
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
            $state = Read-VpsJsonHashtable -Path $statePath
            if (-not $state.Contains('CurrentManagementPort')) { continue }
            $instanceLabel = if ($plan.Contains('InstanceName')) { [string]$plan.InstanceName } else { [string]$plan.Instance }
            $label = "$([string]$plan.Provider) / $instanceLabel / $([string]$plan.NodeName)"
            $candidates.Add([pscustomobject]@{ Label = $label; PlanPath = $file.FullName })
        }
        catch { }
    }
    return $candidates.ToArray()
}

function Test-MxhExternalProbeIpv6Connectivity {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ProbeContext)

    $python = @'
import socket
s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM)
s.settimeout(12)
s.connect(("2606:4700:4700::1111",443,0,0))
s.close()
print("VPSDEPLOY_PROBE_IPV6_OK")
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($python.Replace("`r`n", "`n")))
    $result = Invoke-VpsSshCommand -Context $ProbeContext -User root -Port ([int]$ProbeContext.State.CurrentManagementPort) `
        -Command "printf '%s' '$encoded' | base64 -d | python3" -TimeoutSeconds 45 -AllowFailure
    return $result.ExitCode -eq 0 -and $result.StdOut -match 'VPSDEPLOY_PROBE_IPV6_OK'
}

function Resolve-MxhExternalValidationProbeContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $savedPath = $null
    if ($Context.State.Contains('ClientValidation') -and $Context.State.ClientValidation.Contains('ExternalProbePlanPath')) {
        $savedPath = [string]$Context.State.ClientValidation.ExternalProbePlanPath
    }
    $candidates = @(Get-MxhManagedValidationProbePlans -Context $Context)
    $selectedPath = $null
    if ($savedPath -and (Test-Path -LiteralPath $savedPath -PathType Leaf)) {
        $selectedPath = $savedPath
    }
    elseif ($Context.NonInteractive) {
        throw '本机 IPv6 路径不可用，且没有预先选择外部受管 VPS 验收计划。请以交互模式选择一台可信 VPS。'
    }
    else {
        if (-not $candidates.Count) { throw '本机 IPv6 路径不可用，且没有发现可作为外部验收入口的受管 VPS。' }
        Write-VpsUi '本机 IPv6 被 TUN/路由截获或不可用；不会改动本机网络。请选择一台可信的受管 VPS 临时执行 IPv6 客户端验收。' Warning
        $choice = Read-VpsMenu '外部 IPv6 验收入口' @($candidates | ForEach-Object Label) 1 -AllowBack
        $selectedPath = [string]$candidates[$choice - 1].PlanPath
    }
    $probe = New-MxhReadonlyContextFromPlan -ProjectRoot $Context.ProjectRoot -PlanPath $selectedPath
    $probe.DryRun = $false
    $probe.NonInteractive = $true
    if (-not (Test-MxhExternalProbeIpv6Connectivity -ProbeContext $probe)) {
        throw '所选受管 VPS 没有可用的原生 IPv6 出口，不能承担 IPv6 客户端验收。'
    }
    if (-not $Context.State.Contains('ClientValidation')) { $Context.State.ClientValidation = [ordered]@{} }
    $Context.State.ClientValidation.ExternalProbePlanPath = $selectedPath
    $Context.State.ClientValidation.ExternalProbeNode = [string]$probe.Plan.NodeName
    Save-VpsContext -Context $Context
    return $probe
}

function Invoke-MxhExternalValidationTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $ProbeContext,
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [ValidateSet('Reality', 'AnyTLS')] [string]$Protocol
    )

    $probeArchitecture = Get-VpsSupportedAssetArchitecture -Architecture ([string]$ProbeContext.State.Audit.Architecture)
    $mihomoAsset = $Context.Versions.mihomo.assets.$probeArchitecture
    $singBoxAsset = $Context.Versions.sing_box.assets.$probeArchitecture
    if (-not $mihomoAsset -or -not $singBoxAsset) { throw "外部验收入口架构没有固定核心资产：$probeArchitecture" }
    $mihomoProfile = [IO.File]::ReadAllText([string]$Target.MihomoProfile, [Text.Encoding]::UTF8)
    $singBoxProfile = [IO.File]::ReadAllText([string]$Target.SingBoxProfile, [Text.Encoding]::UTF8)
    $result = Invoke-VpsRemoteScript -Context $ProbeContext -Asset 'reality-anytls-external-probe.sh' -Parameters @{
        MIHOMO_VERSION = [string]$Context.Versions.mihomo.version
        MIHOMO_ASSET_NAME = [string]$mihomoAsset.name
        MIHOMO_SHA256 = [string]$mihomoAsset.sha256
        SING_BOX_VERSION = [string]$Context.Versions.sing_box.version
        SING_BOX_ASSET_NAME = [string]$singBoxAsset.name
        SING_BOX_SHA256 = [string]$singBoxAsset.sha256
        MIHOMO_PROFILE_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($mihomoProfile))
        SING_BOX_PROFILE_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($singBoxProfile))
        MIHOMO_PORT = [string]$Target.MixedPort
        SING_BOX_PORT = [string]$Target.MixedPort
    } -TimeoutSeconds 1200 -SensitiveOutput -ProgressActivity "外部受管 VPS 正在执行 $Protocol IPv6 双核心真实验收"
    if ($result.StdOut -notmatch 'VPSDEPLOY_EXTERNAL_ACCEPTANCE_OK') { throw '外部受管 VPS 未确认真实协议验收完成。' }
    return (Get-VpsMarkerValue -Text $result.StdOut -Name EXTERNAL_ACCEPTANCE -Required) | ConvertFrom-Json -AsHashtable
}

function Get-MxhValidationTargetMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [ValidateSet('Reality', 'AnyTLS')] [string]$Protocol,
        [Parameter(Mandatory)] [Collections.IDictionary]$Plan
    )

    $readOptional = {
        param($Object, [string]$Name, $Default)
        $found = $false
        $value = $null
        if ($Object -is [Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                $found = $true
                $value = $Object[$Name]
            }
        }
        else {
            $property = $Object.PSObject.Properties[$Name]
            if ($null -ne $property) {
                $found = $true
                $value = $property.Value
            }
        }
        if (-not $found -or $null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            return $Default
        }
        return $value
    }

    $addressFamily = [string](& $readOptional $Target 'AddressFamily' '')
    if ($addressFamily -notin @('IPv4', 'IPv6')) {
        throw "$Protocol 客户端验收目标缺少有效 AddressFamily。"
    }
    $defaultPort = if ($Protocol -eq 'Reality') { [int]$Plan.Ports.XrayPrimary } else { [int]$Plan.Ports.AnyTlsPrimary }
    return [ordered]@{
        Entry = [string](& $readOptional $Target 'Entry' 'primary')
        AddressFamily = $addressFamily
        ServerPort = [int](& $readOptional $Target 'ServerPort' $defaultPort)
    }
}

function Invoke-MxhRealClientValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('Reality', 'AnyTLS')][string]$Protocol
    )
    $exports = if ($Protocol -eq 'Reality') { $Context.State.ClientExports } else { $Context.State.AnyTlsClientExports }
    if (-not $exports -or -not $exports.ValidationTargets) { throw "$Protocol 缺少逐地址族客户端验收配置，请先重新生成客户端导出。" }
    $coreStates = if ($exports.CoreValidation) { $exports.CoreValidation } else { [ordered]@{} }
    $results = [Collections.Generic.List[object]]::new()
    $localTargets = [Collections.Generic.List[object]]::new()
    $externalTargets = [Collections.Generic.List[object]]::new()
    $probeContext = $null
    foreach ($target in @($exports.ValidationTargets)) {
        $path = Test-MxhControllerValidationPath -Context $Context -Target $target -Protocol $Protocol
        if ($path.Usable) { $localTargets.Add($target); continue }
        Write-VpsUi "$Protocol 的 IPv6 本机验收路径不可用：$($path.Reason)" Warning
        if (-not $probeContext) { $probeContext = Resolve-MxhExternalValidationProbeContext -Context $Context }
        $externalTargets.Add($target)
    }
    foreach ($coreName in @('mihomo', 'sing-box')) {
        $coreState = if ($coreStates.Contains($coreName)) { $coreStates[$coreName] } else { Resolve-VpsClientValidationCore -Context $Context -Core $coreName }
        if ($coreState.Status -eq 'SkippedByUser') {
            $results.Add([ordered]@{ Core = $coreName; Status = 'SkippedByUser'; Reason = [string]$coreState.Reason; TestedAt = (Get-Date).ToString('o') })
            continue
        }
        if (-not (Test-Path -LiteralPath $coreState.Path -PathType Leaf)) { $coreState = Resolve-VpsClientValidationCore -Context $Context -Core $coreName }
        foreach ($target in $localTargets) {
            $metadata = Get-MxhValidationTargetMetadata -Target $target -Protocol $Protocol -Plan $Context.Plan
            $entryName = [string]$metadata.Entry
            $label = "$($Protocol.ToLowerInvariant())-$coreName-$entryName-$([string]$metadata.AddressFamily)"
            $acceptance = if ($coreName -eq 'mihomo') {
                Invoke-MxhMihomoEgressTest -Context $Context -CorePath $coreState.Path -ProfilePath $target.MihomoProfile `
                    -MixedPort ([int]$target.MixedPort) -Label $label -Detailed
            }
            else {
                Invoke-MxhSingBoxEgressTest -Context $Context -CorePath $coreState.Path -ProfilePath $target.SingBoxProfile `
                    -MixedPort ([int]$target.MixedPort) -Label $label -Detailed
            }
            $results.Add([ordered]@{
                    Core = $coreName
                    Entry = $entryName
                    AddressFamily = [string]$metadata.AddressFamily
                    ServerPort = [int]$metadata.ServerPort
                    Status = 'Passed'
                    Egress = [string]$acceptance.Egress
                    HttpsEndpoint = [string]$acceptance.HttpsEndpoint
                    IpEndpoint = [string]$acceptance.IpEndpoint
                    UdpDnsEndpoint = [string]$acceptance.UdpDnsEndpoint
                    TestedAt = (Get-Date).ToString('o')
                })
        }
    }
    foreach ($target in $externalTargets) {
        $metadata = Get-MxhValidationTargetMetadata -Target $target -Protocol $Protocol -Plan $Context.Plan
        $entryName = [string]$metadata.Entry
        $external = Invoke-MxhExternalValidationTarget -Context $Context -ProbeContext $probeContext -Target $target -Protocol $Protocol
        foreach ($item in @($external.results)) {
            $results.Add([ordered]@{
                    Core = [string]$item.core
                    Entry = $entryName
                    AddressFamily = [string]$metadata.AddressFamily
                    ServerPort = [int]$metadata.ServerPort
                    Status = 'Passed'
                    ValidationOrigin = "ManagedVps:$([string]$probeContext.Plan.NodeName)"
                    Egress = [string]$item.egress
                    EgressFamily = [string]$item.egress_family
                    HttpsEndpoint = [string]$item.https_endpoint
                    IpEndpoint = 'https://api64.ipify.org'
                    UdpDnsEndpoint = '1.1.1.1'
                    TestedAt = (Get-Date).ToString('o')
                })
        }
    }
    $status = if (@($results | Where-Object Status -eq 'SkippedByUser').Count) { 'SkippedByUser' } else { 'Passed' }
    $summary = [ordered]@{ Status = $status; Protocol = $Protocol; Results = $results.ToArray(); TestedAt = (Get-Date).ToString('o') }
    if ($Protocol -eq 'Reality') { $Context.State.RealityEgressTest = $summary } else { $Context.State.AnyTlsEgressTest = $summary }
    Save-VpsContext -Context $Context
    return $summary
}

function Invoke-MxhShadowsocksRealValidation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $testServer = if ($Context.Plan.Server.IPv6) { '::1' } else { '127.0.0.1' }
    $runSelfTest = {
        param([string]$Label, [string]$Password, [string]$IpVersion)
        $test = Invoke-VpsRemoteScript -Context $Context -Asset 'shadowsocks-self-test.sh' -Parameters @{
            METHOD = [string]$Context.Plan.Shadowsocks.Method
            PASSWORD = $Password
            LANDING_PORT = [string]$Context.Plan.Ports.LandingShadowsocks
            IP_VERSION = $IpVersion
            TEST_SERVER = $testServer
        } -TimeoutSeconds 240 -SensitiveOutput -AllowFailure
        if ($test.ExitCode -ne 0) {
            $details = ([string]$test.StdOut) + "`n" + ([string]$test.StdErr)
            $phaseMatch = [regex]::Match($details, '(?m)^VPSDEPLOY_SELFTEST_FAILURE_PHASE=([a-z-]+)$')
            $phase = if ($phaseMatch.Success) { $phaseMatch.Groups[1].Value } else { 'unknown' }
            throw "Shadowsocks $Label 真实协议验收失败（阶段：$phase；敏感详情仅保存在私有日志）。"
        }
        $udp = Get-VpsMarkerValue $test.StdOut UDP -Required
        if ($udp -ne 'yes') { throw "Shadowsocks $Label UDP 验收失败。" }
        return [ordered]@{
            Label = $Label
            Egress = Get-VpsMarkerValue $test.StdOut EGRESS -Required
            Udp = 'Passed'
            TestedAt = (Get-Date).ToString('o')
        }
    }
    $credentials = $Context.Secrets.Shadowsocks
    $results = [Collections.Generic.List[object]]::new()
    $results.Add((& $runSelfTest 'IPv4 用户' (([string]$credentials.ServerKey) + ':' + ([string]$credentials.PrimaryUserKey)) '4'))
    if ([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled) {
        $results.Add((& $runSelfTest 'IPv6 用户' (([string]$credentials.ServerKey) + ':' + ([string]$credentials.SecondaryUserKey)) '6'))
    }
    $summary = [ordered]@{ Status = 'Passed'; Results = $results.ToArray(); TestedAt = (Get-Date).ToString('o') }
    $Context.State.ShadowsocksSelfTest = $summary
    Save-VpsContext -Context $Context
    return $summary
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

function Format-VpsModulePlanLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Modules)

    if ($Modules.Count -eq 0) { return @() }
    $idWidth = [int](($Modules | ForEach-Object { ([string]$_.Id).Length } | Measure-Object -Maximum).Maximum)
    return @($Modules | ForEach-Object {
        '  {0,3}  {1}  {2}' -f $_.Order, ([string]$_.Id).PadRight($idWidth), $_.Name
    })
}

function Invoke-VpsModulePipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [string[]]$OnlyModule
    )

    $modules = Get-VpsModules -ProjectRoot $Context.ProjectRoot
    $eligible = @($modules | Where-Object {
            $Context.Plan.Role -in @($_.Roles) -and (& $_.IsEnabled $Context)
        })
    $selected = @($eligible)
    if (-not $OnlyModule -and $Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) {
        $migrationIds = @($Context.Plan.Migration.ModuleIds | ForEach-Object { [string]$_ })
        $selected = @($selected | Where-Object Id -in $migrationIds)
    }
    if ($OnlyModule) {
        $missing = @($OnlyModule | Where-Object { $_ -notin @($modules.Id) })
        if ($missing) { throw "未知模块：$($missing -join ', ')" }
        $selected = @($eligible | Where-Object Id -in $OnlyModule)
        $unavailable = @($OnlyModule | Where-Object { $_ -notin @($selected.Id) })
        if ($unavailable) { throw "显式模块在当前角色或状态不可用：$($unavailable -join ', ')" }
        Write-VpsUi '维护模式只运行显式模块，不会自动补跑缺失依赖。' Warning
    }
    if ($selected.Count -eq 0) { throw '本次没有可运行模块；请检查计划角色、协议变更状态或显式模块选择。' }

    Write-Host ''
    Write-Host '本次模块计划：' -ForegroundColor Cyan
    foreach ($line in (Format-VpsModulePlanLines -Modules $selected)) { Write-Host $line }
    if ($Context.DryRun) {
        Write-VpsUi 'DryRun：只显示计划，不连接服务器、不生成凭据、不改文件。' Success
        return
    }
    if (-not $Context.NonInteractive) {
        Write-VpsUi '此处返回或取消不会连接 VPS；已确认的本地计划会保留，可稍后选择【继续未完成部署】。' Muted
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
            if ($module.Id -eq 'private-archive') {
                # private-archive writes deployment-state.json while the module
                # is still Running. Refresh checksums only after the final
                # Success state is persisted so the archive verifies cleanly.
                Update-VpsPrivateArchiveChecksums -Context $Context
            }
            Write-VpsUi "$($module.Name) 已完成。" Success
        }
        catch {
            $safeMessage = $_.Exception.Message
            Set-VpsModuleState -Context $Context -Id $module.Id -Status Failed -Message $safeMessage
            Write-VpsLog -Context $Context -Level ERROR -Message "Module $($module.Id) failed: $safeMessage"
            Write-VpsUi "$($module.Name) 失败：$safeMessage" Error
            if ($Context.Plan.Contains('Migration') -and [bool]$Context.Plan.Migration.Enabled) {
                Invoke-MxhProtocolMigrationRollback -Context $Context -Reason $safeMessage
                Write-VpsUi '协议变更后续模块已停止；请确认变更前状态已经恢复，再选择【继续未完成部署】。' Warning
            }
            else {
                Write-VpsUi '后续模块已停止；旧 SSH 入口不会由核心自动关闭。修复后选择【继续未完成部署】。' Warning
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
    if ([int]$Plan.Ports.SshPrimary -eq [int]$Plan.Ports.SshRescue) {
        Write-Host "  SSH：保留单一现有端口 $($Plan.Ports.SshPrimary)（尚无独立救援入口）"
    }
    elseif (Test-VpsBootstrapSshPortRetained -Plan $Plan) {
        Write-Host "  SSH：复用服务商端口 $($Plan.Ports.SshPrimary) 作为主端口 + 新增救援端口 $($Plan.Ports.SshRescue)"
    }
    else {
        Write-Host "  SSH：$($Plan.Server.BootstrapSshPort) -> $($Plan.Ports.SshPrimary) + $($Plan.Ports.SshRescue)"
    }
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
    $sshFirewallText = if (Test-VpsBootstrapSshPortRetained -Plan $Plan) {
        '一个新增的 SSH 救援高位端口（服务商主端口继续保留）'
    }
    else {
        '两个新的 SSH 高位端口'
    }
    if ($realityInstalled) {
        Write-VpsUi "请先在服务商安全组放行${sshFirewallText}、443 和 Xray 救援端口。" Warning
        $showedPortWarning = $true
    }
    if ($anyTlsInstalled) {
        Write-VpsUi "请先在服务商安全组放行${sshFirewallText}和 TCP 443；AnyTLS 与 Xray 必须互斥。" Warning
        $showedPortWarning = $true
    }
    if ($shadowsocksInstalled) {
        Write-VpsUi "请放行${sshFirewallText}；Shadowsocks TCP+UDP 端口必须只允许上面填写的可信入口 IP。" Warning
        $showedPortWarning = $true
    }
    if (-not $showedPortWarning) {
        Write-VpsUi "请先在服务商安全组放行${sshFirewallText}。" Warning
    }
}

function Write-VpsAbandonedTransactionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$Kind,
        [Parameter(Mandatory)] [string]$PlanPath,
        [Parameter(Mandatory)] [string]$StatePath,
        [Parameter(Mandatory)] [string]$RecordId,
        [int]$PreservedPackageCount = 0,
        [bool]$SnapshotDeleted = $true,
        [string]$PlanSha256,
        [string]$StateSha256
    )

    if ($RecordId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') { throw '放弃事务记录 ID 非法。' }
    $history = Join-Path $ArchivePath 'abandoned-transactions'
    [IO.Directory]::CreateDirectory($history) | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $recordPath = Join-Path $history "$RecordId.json"
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) { return }
    $record = [ordered]@{
        SchemaVersion = 1
        Kind = $Kind
        Status = 'RolledBackAndAbandoned'
        AbandonedAt = (Get-Date).ToString('o')
        PlanSha256 = if ($PlanSha256) { $PlanSha256 } elseif (Test-Path -LiteralPath $PlanPath -PathType Leaf) { (Get-FileHash -LiteralPath $PlanPath -Algorithm SHA256).Hash } else { $null }
        StateSha256 = if ($StateSha256) { $StateSha256 } elseif (Test-Path -LiteralPath $StatePath -PathType Leaf) { (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash } else { $null }
        RecoveryKeyPreserved = $true
        PreservedPackageCount = $PreservedPackageCount
        SnapshotDeleted = $SnapshotDeleted
    }
    Save-VpsJson -Value $record -Path $recordPath -Private
    $logPath = Join-Path $ArchivePath 'deployment.log'
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Move-Item -LiteralPath $logPath -Destination (Join-Path $history "$RecordId-$stamp.log") -Force
    }
}

function Clear-VpsIncompleteLocalArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ArchivePath)

    $archive = [IO.Path]::GetFullPath($ArchivePath).TrimEnd('\', '/')
    $root = [IO.Path]::GetPathRoot($archive).TrimEnd('\', '/')
    if ($archive.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw '拒绝清理磁盘根目录。' }
    foreach ($directoryName in @('server-configs', 'client-exports')) {
        $target = Join-Path $archive $directoryName
        if (Test-Path -LiteralPath $target -PathType Container) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    foreach ($name in @('deployment-plan.json', 'deployment-state.json', 'deployment-secrets.private.json', 'SHA256SUMS-private.txt')) {
        $target = Join-Path $archive $name
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $archive -Filter '*-final-archive.txt' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
}

function Restore-VpsAbandonedMigrationLocalSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$BackupDirectory
    )

    $archive = [IO.Path]::GetFullPath($ArchivePath).TrimEnd('\', '/')
    $backup = [IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\', '/')
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $archive 'migration-backups')).TrimEnd('\', '/')
    $allowedPrefix = $allowedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $backup.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '协议变更本地快照不在实例 migration-backups 目录内，拒绝恢复。'
    }
    foreach ($name in @('deployment-plan.json', 'deployment-state.json', 'deployment-secrets.private.json')) {
        $source = Join-Path $backup $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "协议变更本地快照缺少 $name。" }
        [void](Read-VpsJsonHashtable -Path $source)
    }
    foreach ($directoryName in @('server-configs', 'client-exports')) {
        $current = Join-Path $archive $directoryName
        if (Test-Path -LiteralPath $current -PathType Container) { Remove-Item -LiteralPath $current -Recurse -Force }
        $source = Join-Path $backup $directoryName
        if (Test-Path -LiteralPath $source -PathType Container) { Copy-Item -LiteralPath $source -Destination $current -Recurse }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $archive -Filter '*-final-archive.txt' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $backup -Filter '*-final-archive.txt' -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $archive $file.Name) -Force
    }
    foreach ($name in @('deployment-plan.json', 'deployment-state.json', 'deployment-secrets.private.json')) {
        Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $archive $name) -Force
    }
}

function Invoke-VpsAbandonIncompletePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$PlanPath,
        [switch]$DryRun
    )

    $resolvedPlan = (Resolve-Path -LiteralPath $PlanPath).Path
    $plan = Read-VpsJsonHashtable -Path $resolvedPlan
    $archive = [IO.Path]::GetFullPath([string]$plan.Paths.Archive).TrimEnd('\', '/')
    if (-not ([IO.Path]::GetFullPath((Split-Path -Parent $resolvedPlan)).TrimEnd('\', '/')).Equals($archive, [StringComparison]::OrdinalIgnoreCase)) {
        throw '计划文件不在其声明的实例归档目录内，拒绝放弃。'
    }
    $statePath = Join-Path $archive 'deployment-state.json'
    $secretsPath = Join-Path $archive 'deployment-secrets.private.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw '未完成计划缺少 deployment-state.json。' }
    $state = Read-VpsJsonHashtable -Path $statePath
    $planHash = (Get-FileHash -LiteralPath $resolvedPlan -Algorithm SHA256).Hash
    $stateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    if ($DryRun) {
        Write-VpsUi 'DryRun：将验证回滚快照、恢复服务器受管状态、确认恢复 SSH、删除远端快照，并清理未完成本地计划；当前未执行。' Success
        return
    }

    $isMigration = $plan.Contains('Migration') -and [bool]$plan.Migration.Enabled
    if ($isMigration) {
        if (-not $state.Contains('Migration')) { throw '协议变更状态缺失，不能安全放弃。' }
        $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan
        $status = [string]$context.State.Migration.Status
        $capturedBeforeMutations = $context.State.Migration.Contains('BaselineCapturedBeforeMutations') -and
            [bool]$context.State.Migration.BaselineCapturedBeforeMutations
        $hasRemoteMutationState = [bool]$context.State.Migration.RollbackArmed -or
            $status -notin @('Planned') -or
            ($context.State.Migration.Contains('RemoteBackupDirectory') -and
                -not [string]::IsNullOrWhiteSpace([string]$context.State.Migration.RemoteBackupDirectory))
        if ($hasRemoteMutationState -and -not $capturedBeforeMutations) {
            throw '该旧版协议变更没有“修改前已建立快照”的可验证标记，不能自动删除快照并宣称干净回滚；请继续完成当前变更，或人工核对后使用运维中心恢复。'
        }
        if ([bool]$context.State.Migration.RollbackArmed -and -not [bool]$context.State.Migration.Committed) {
            Invoke-MxhProtocolMigrationRollback -Context $context -Reason '用户选择放弃未完成协议变更。'
            $status = [string]$context.State.Migration.Status
        }
        if ($status -notin @('Planned', 'RolledBack')) {
            throw "协议变更当前状态为 $status；只有尚未修改服务器或已经确认回滚时才能放弃。"
        }
        $localBackup = [string]$context.State.Migration.LocalBackupDirectory
        if ([string]::IsNullOrWhiteSpace($localBackup)) { $localBackup = [string]$plan.Migration.LocalBackupDirectory }
        if ([string]::IsNullOrWhiteSpace($localBackup)) { throw '协议变更缺少变更前本地快照。' }
        $remoteBackup = if ($context.State.Migration.Contains('RemoteBackupDirectory')) { [string]$context.State.Migration.RemoteBackupDirectory } else { '' }
        $remoteSnapshotDeleted = $context.State.Migration.Contains('RemoteSnapshotDeleted') -and [bool]$context.State.Migration.RemoteSnapshotDeleted
        if ($remoteBackup -and -not $remoteSnapshotDeleted) {
            if ($status -ne 'RolledBack') { throw '远端协议快照存在但尚未确认回滚，拒绝删除快照。' }
            $managementPort = [int]$context.State.CurrentManagementPort
            if (-not (Test-VpsSshConnection -Context $context -User root -Port $managementPort)) {
                throw '协议状态已回滚，但管理 SSH 复验失败；远端及本地快照均保留。'
            }
            $delete = Invoke-VpsRemoteScript -Context $context -Asset 'deployment-snapshot-delete.sh' -Parameters @{
                SNAPSHOT_DIR = $remoteBackup
                KIND = 'protocol-rolled-back'
            } -TimeoutSeconds 180 -SensitiveOutput -ProgressActivity '删除已完成回滚的协议快照'
            if ($delete.StdOut -notmatch 'VPSDEPLOY_SNAPSHOT_DELETE_OK') { throw '协议已回滚，但远端快照删除未确认；本地快照和计划均已保留。' }
            $context.State.Migration.RemoteSnapshotDeleted = $true
            Save-VpsContext -Context $context
        }
        Restore-VpsAbandonedMigrationLocalSnapshot -ArchivePath $archive -BackupDirectory $localBackup
        Remove-Item -LiteralPath $localBackup -Recurse -Force
        $recordId = 'migration-' + $planHash.Substring(0, 24).ToLowerInvariant()
        Write-VpsAbandonedTransactionRecord -ArchivePath $archive -Kind 'ProtocolMigration' -PlanPath $resolvedPlan -StatePath $statePath `
            -RecordId $recordId -SnapshotDeleted:([bool]$remoteBackup) -PlanSha256 $planHash -StateSha256 $stateHash
        $migrationResultText = if ($remoteBackup) { '服务器与本地计划均恢复到变更前，远端及本次本地快照已删除。' } else { '尚未修改服务器；本地计划已恢复到变更前，本次本地快照已删除。' }
        Write-VpsUi "未完成协议变更已放弃；$migrationResultText" Success
        return
    }

    $moduleCount = if ($state.Contains('Modules')) { @($state.Modules.Keys).Count } else { 0 }
    if (-not $state.Contains('DeploymentTransaction')) {
        if ($moduleCount -eq 0) {
            $recordId = 'local-' + $planHash.Substring(0, 24).ToLowerInvariant()
            Write-VpsAbandonedTransactionRecord -ArchivePath $archive -Kind 'LocalPlanOnly' -PlanPath $resolvedPlan -StatePath $statePath `
                -RecordId $recordId -SnapshotDeleted:$false -PlanSha256 $planHash -StateSha256 $stateHash
            Clear-VpsIncompleteLocalArtifacts -ArchivePath $archive
            Write-VpsUi '尚未连接服务器的本地计划已放弃；SSH 密钥和外部 Token 文件均保留，可重新新建部署。' Success
            return
        }
        $moduleIds = @($state.Modules.Keys | ForEach-Object { [string]$_ })
        $onlyBootstrapStage = $plan.Contains('DeploymentTransaction') -and
            @($moduleIds | Where-Object { $_ -notin @('bootstrap-access', 'deployment-baseline') }).Count -eq 0 -and
            $state.Modules.Contains('bootstrap-access') -and
            [string]$state.Modules['bootstrap-access'].Status -eq 'Success'
        if ($onlyBootstrapStage) {
            $transactionId = [string]$plan.DeploymentTransaction.Id
            if ($transactionId -notmatch '^[a-f0-9]{32}$') { throw '部署事务 ID 非法，拒绝清理远端基线。' }
            $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan
            $bootstrapPort = [int]$plan.Server.BootstrapSshPort
            if (-not (Test-VpsSshConnection -Context $context -User root -Port $bootstrapPort)) {
                throw '只有恢复公钥阶段已完成，但初始 SSH 复验失败；本地计划和可能存在的远端半成品基线均保留。'
            }
            $delete = Invoke-VpsRemoteScript -Context $context -Asset 'deployment-snapshot-delete.sh' -Parameters @{
                SNAPSHOT_DIR = "/root/vps-deploy-transaction-baselines/$transactionId"
                KIND = 'deployment-aborted-before-mutations'
            } -Port $bootstrapPort -TimeoutSeconds 180 -SensitiveOutput -ProgressActivity '清理尚未进入修改阶段的部署基线'
            if ($delete.StdOut -notmatch 'VPSDEPLOY_SNAPSHOT_DELETE_OK') { throw '远端半成品基线清理未确认；本地计划保留。' }
            Write-VpsAbandonedTransactionRecord -ArchivePath $archive -Kind 'BootstrapOnly' -PlanPath $resolvedPlan -StatePath $statePath `
                -RecordId "deployment-$transactionId" -PlanSha256 $planHash -StateSha256 $stateHash
            Clear-VpsIncompleteLocalArtifacts -ArchivePath $archive
            Write-VpsUi '部署在其他修改开始前已放弃；恢复公钥保留，远端半成品基线和本地未完成计划已清理。' Success
            return
        }
        throw '该旧计划创建时尚无统一部署前快照，且已经运行过远端模块；不能伪装成干净回滚。请继续完成部署，或先由服务商重置 VPS。'
    }
    $transaction = $state.DeploymentTransaction
    $privateArchiveSucceeded = $state.Contains('Modules') -and $state.Modules.Contains('private-archive') -and
        [string]$state.Modules['private-archive'].Status -eq 'Success'
    if ([string]$transaction.Status -eq 'Committed' -or $privateArchiveSucceeded) {
        throw '该部署已经提交完成，不属于未完成计划；如需移除，请使用现有 VPS 运维中心的完整退役。'
    }
    if ([string]$transaction.Status -notin @('Armed', 'RolledBackAwaitingSnapshotCleanup', 'SnapshotDeletedAwaitingLocalCleanup')) {
        throw "统一部署事务状态为 $($transaction.Status)，不能确认可回滚基线。"
    }
    $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan
    $remoteBaseline = if ($context.State.DeploymentTransaction.Contains('RemoteBaselineDirectory')) { [string]$context.State.DeploymentTransaction.RemoteBaselineDirectory } else { '' }
    $packageResidue = if ($context.State.DeploymentTransaction.Contains('PreservedPackageCount')) { [int]$context.State.DeploymentTransaction.PreservedPackageCount } else { 0 }
    if ([string]$context.State.DeploymentTransaction.Status -eq 'Armed') {
        $rollback = Invoke-VpsRemoteScript -Context $context -Asset 'deployment-baseline-rollback.sh' -Parameters @{
            BASELINE_DIR = $remoteBaseline
            ADMIN_USER = [string]$plan.AdminUser
        } -TimeoutSeconds 900 -SensitiveOutput -ProgressActivity '放弃未完成部署并恢复部署前状态'
        if ($rollback.StdOut -notmatch 'VPSDEPLOY_DEPLOYMENT_ROLLBACK_OK') { throw '统一回滚未返回成功标记；快照和本地计划均已保留。' }
        $packageResidueText = Get-VpsMarkerValue $rollback.StdOut PACKAGE_RESIDUE_COUNT
        if ($packageResidueText -match '^\d+$') { $packageResidue = [int]$packageResidueText }
        $context.State.DeploymentTransaction.Status = 'RolledBackAwaitingSnapshotCleanup'
        $context.State.DeploymentTransaction.PreservedPackageCount = $packageResidue
        $context.State.CurrentManagementPort = [int]$plan.Server.BootstrapSshPort
        Save-VpsContext -Context $context
    }
    if ([string]$context.State.DeploymentTransaction.Status -ne 'SnapshotDeletedAwaitingLocalCleanup') {
        $bootstrapPort = [int]$plan.Server.BootstrapSshPort
        if (-not (Test-VpsSshConnection -Context $context -User root -Port $bootstrapPort)) {
            throw '服务器受管状态已恢复，但初始 SSH 端口复验失败；远端快照和本地计划均保留，请先恢复访问。'
        }
        $delete = Invoke-VpsRemoteScript -Context $context -Asset 'deployment-snapshot-delete.sh' -Parameters @{
            SNAPSHOT_DIR = $remoteBaseline
            KIND = 'deployment-rolled-back'
        } -Port $bootstrapPort -TimeoutSeconds 180 -SensitiveOutput -ProgressActivity '删除已完成回滚的部署快照'
        if ($delete.StdOut -notmatch 'VPSDEPLOY_SNAPSHOT_DELETE_OK') { throw '服务器已恢复且 SSH 已确认，但远端快照删除失败；本地计划保留，可再次执行放弃操作。' }
        $context.State.DeploymentTransaction.Status = 'SnapshotDeletedAwaitingLocalCleanup'
        $context.State.DeploymentTransaction.RemoteBaselineDirectory = $null
        $context.State.DeploymentTransaction.SnapshotDeletedAt = (Get-Date).ToString('o')
        Save-VpsContext -Context $context
    }
    $transactionId = [string]$context.State.DeploymentTransaction.Id
    Write-VpsAbandonedTransactionRecord -ArchivePath $archive -Kind 'InitialDeployment' -PlanPath $resolvedPlan -StatePath $statePath `
        -RecordId "deployment-$transactionId" -PreservedPackageCount $packageResidue -PlanSha256 $planHash -StateSha256 $stateHash
    Clear-VpsIncompleteLocalArtifacts -ArchivePath $archive
    Write-VpsUi '未完成部署已放弃；服务器受管状态已恢复、SSH 已复验、远端快照已删除，本地 SSH 密钥和 Token 文件保留。' Success
    if ($packageResidue -gt 0) { Write-VpsUi "为避免 apt 级联卸载，保留了 $packageResidue 个部署期间新增的软件包；服务、配置、用户、SSH、防火墙和 sysctl 已回滚。" Warning }
}

function Read-VpsResumePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [string]$PlanPath,
        [switch]$NonInteractive,
        [switch]$DryRun
    )

    $candidatePath = $PlanPath
    while ($true) {
        if (-not $candidatePath) {
            $inputPath = Read-VpsText 'deployment-plan.json 完整路径' -AllowBack -Validate {
                param($v)
                Test-VpsExistingInputPath -Value $v -PathType Leaf
            } -ValidationMessage '找不到该计划文件，或路径混用了 / 与 \。可输入 0 返回主菜单。'
            $candidatePath = ConvertTo-VpsInputPath -Value $inputPath
        }
        else {
            try { $candidatePath = ConvertTo-VpsInputPath -Value $candidatePath }
            catch {
                if ($NonInteractive) { throw }
                Write-VpsUi $_.Exception.Message Warning
                $candidatePath = $null
                continue
            }
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
                '放弃未完成计划并回滚到部署前',
                '取消并返回主菜单'
            ) 1 -AllowBack
        }
        catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $choice = 0
        }
        if ($choice -eq 1) { return $plan }
        if ($choice -eq 2) {
            $confirmation = Read-VpsText '输入 ABANDON-AND-ROLLBACK 确认放弃计划并恢复服务器' -AllowBack
            if ($confirmation -cne 'ABANDON-AND-ROLLBACK') {
                Write-VpsUi '确认短语不匹配，未修改服务器或本地计划。' Warning
                continue
            }
            Invoke-VpsAbandonIncompletePlan -ProjectRoot $ProjectRoot -PlanPath $candidatePath -DryRun:$DryRun
            throw [OperationCanceledException]::new($script:VpsWizardCancelMarker)
        }
        if ($choice -eq 3) {
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
        $plan = Read-VpsResumePlan -ProjectRoot $ProjectRoot -PlanPath $PlanPath -NonInteractive:$NonInteractive -DryRun:$DryRun
        $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan -DryRun:$DryRun -NonInteractive:$NonInteractive
    }
    try {
        Invoke-VpsModulePipeline -Context $context -OnlyModule $OnlyModule
        if (-not $DryRun) {
            Write-Host ''
            if ($OnlyModule) {
                Write-VpsUi "显式模块执行完成：$($OnlyModule -join ', ')。" Success
                $deploymentStillArmed = $context.State.Contains('DeploymentTransaction') -and
                    [string]$context.State.DeploymentTransaction.Status -eq 'Armed'
                if ($deploymentStillArmed) {
                    Write-VpsUi '统一部署事务仍未完成；请从主菜单选择【继续未完成部署】完成剩余模块，或选择放弃计划并回滚到部署前。' Warning
                }
                else {
                    Write-VpsUi '本次只运行了显式模块，未据此宣称整套部署流程完成。' Muted
                }
            }
            else {
                Write-VpsUi "部署流程完成。私有归档：$($context.ArchivePath)" Success
                Write-VpsUi '最后请在服务商安全组删除初始 SSH 端口，并按归档中的客户端步骤完成真实出口测试。' Warning
            }
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

    if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw "Windows 控制端需要 PowerShell 7.4 或更高版本；当前为 $($PSVersionTable.PSVersion)。" }
    if ([string]::IsNullOrWhiteSpace($InstanceRoot)) {
        $settings = Get-VpsAppDefaults -ProjectRoot $ProjectRoot
        $configuredRoot = if ($env:MXH_VPS_INSTANCE_ROOT) { $env:MXH_VPS_INSTANCE_ROOT } else { [string]$settings.instance_root }
        $InstanceRoot = Resolve-VpsPortablePath -ProjectRoot $ProjectRoot -Path $configuredRoot
    }
    else { $InstanceRoot = ConvertTo-VpsInputPath -Value $InstanceRoot }
    if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $PlanPath = ConvertTo-VpsInputPath -Value $PlanPath }
    if (-not [string]::IsNullOrWhiteSpace($ClashAuthorityPath)) { $ClashAuthorityPath = ConvertTo-VpsInputPath -Value $ClashAuthorityPath }
    if (-not [string]::IsNullOrWhiteSpace($SingBoxAuthorityPath)) { $SingBoxAuthorityPath = ConvertTo-VpsInputPath -Value $SingBoxAuthorityPath }
    if (-not [string]::IsNullOrWhiteSpace($ClientOutputRoot)) { $ClientOutputRoot = ConvertTo-VpsInputPath -Value $ClientOutputRoot }
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
                if (Test-VpsNavigationError $_) {
                    Write-VpsUi (Get-VpsNavigationMessage $_) Info
                }
                elseif ($NonInteractive) { throw }
                else {
                    Write-VpsUi '当前操作失败；计划和状态已经保留，可从主菜单选择继续未完成部署。' Warning
                    Wait-VpsReturnToMainMenu
                }
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
    'Save-VpsContext', 'Save-VpsJson', 'Protect-VpsPrivateFile', 'Get-VpsSshKeyPath', 'Get-VpsSshPublicKeyPath',
    'Invoke-VpsProcess', 'Get-VpsCommandPath', 'Get-VpsModules', 'Get-VpsRandomPort',
    'Test-VpsReusableBootstrapSshPort', 'New-VpsSshPortSelection', 'Test-VpsBootstrapSshPortRetained',
    'Test-VpsSupportedOsRelease', 'Get-VpsSupportedAssetArchitecture', 'Assert-VpsSupportedTarget',
    'Get-VpsBundledClientCore', 'Resolve-VpsClientValidationCore', 'Get-VpsMihomoCorePaths', 'Get-VpsSingBoxCorePath',
    'New-VpsRandomString', 'Test-VpsProject', 'Get-VpsMarkerValue', 'Get-VpsSshArguments',
    'Read-VpsNetworkTuningSettings', 'Get-VpsConservativeNetworkPlan',
    'Get-MxhRealityTargetSettings', 'Set-MxhRealityExternalTarget',
    'New-MxhXrayInbound', 'New-MxhXrayServerConfig', 'New-MxhMihomoProfileText', 'New-MxhRealitySingBoxOutbound',
    'New-MxhSingBoxTestConfig', 'Invoke-MxhMihomoEgressTest', 'Invoke-MxhSingBoxEgressTest',
    'Invoke-MxhRealClientValidation', 'Invoke-MxhShadowsocksRealValidation',
    'New-MxhAnyTlsPaddingScheme', 'Get-MxhAnyTlsPaddingScheme',
    'ConvertFrom-MxhEchKeyPairText', 'New-MxhAnyTlsServerConfig', 'New-MxhAnyTlsClientOutbound', 'New-MxhAnyTlsMihomoProfileText',
    'New-MxhRandomBase64Key', 'New-MxhShadowsocksServerConfig', 'New-MxhLandingMihomoProfileText',
    'New-VpsRemoteScriptPayload', 'Get-MxhMigrationModuleIds', 'Test-MxhProtocolMigrationSource',
    'Get-MxhProtocolInventory', 'Get-MxhInventoryPrimaryRole', 'Get-MxhProtocolFirewallParameters',
    'New-MxhProtocolMigrationPlan', 'New-MxhProtocolLifecyclePlan', 'New-MxhNetworkTuningPlan'
)
