Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Read-VpsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Default,
        [scriptblock]$Validate,
        [string]$ValidationMessage = '输入无效，请重新输入。',
        [switch]$AllowEmpty
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $value = Read-Host ($Prompt + $suffix)
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
        [bool]$Default = $true
    )

    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $hint").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @('y', 'yes', '是', '好', '1')) { return $true }
        if ($answer -in @('n', 'no', '否', '不', '0')) { return $false }
        Write-VpsUi '请输入 y 或 n。' Warning
    }
}

function Read-VpsMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string[]]$Options,
        [int]$Default = 1
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i])
    }
    while ($true) {
        $raw = Read-Host "请选择 [$Default]"
        if (-not $raw) { return $Default }
        $choice = 0
        if ([int]::TryParse($raw, [ref]$choice) -and $choice -ge 1 -and $choice -le $Options.Count) {
            return $choice
        }
        Write-VpsUi '请输入列表中的编号。' Warning
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

function Test-VpsIpAddress {
    param([string]$Value, [ValidateSet('IPv4', 'IPv6')] [string]$Family)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $false }
    if ($Family -eq 'IPv4') { return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork }
    return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
}

function Test-VpsSafePathSegment {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and
        $Value -notmatch '[\\/]' -and $Value -notin @('.', '..')
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

function New-VpsInteractivePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$InstanceRoot
    )

    $versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    Write-Host ''
    Write-Host 'MXH VPS Deploy - 新部署向导' -ForegroundColor White
    Write-Host '支持初始密码或服务商现有私钥；密码只由 OpenSSH 询问，现有私钥只用于一次性引导。' -ForegroundColor DarkGray

    $provider = Read-VpsText '服务商名称' -Validate ${function:Test-VpsSafePathSegment} `
        -ValidationMessage '名称不能包含路径分隔符或 Windows 非法字符。'
    $instance = Read-VpsText '实例名称' -Validate ${function:Test-VpsSafePathSegment} `
        -ValidationMessage '名称不能包含路径分隔符或 Windows 非法字符。'
    $suggestedNode = (($provider + '-' + $instance) -replace '[^A-Za-z0-9._-]', '-') -replace '-+', '-'
    $nodeName = Read-VpsText '客户端节点名称' -Default $suggestedNode `
        -Validate ${function:Test-VpsNodeName} -ValidationMessage '节点名只允许字母、数字、点、下划线和连字符。'
    $ipv4 = Read-VpsText '服务器 IPv4' -Validate { param($v) Test-VpsIpAddress $v IPv4 } `
        -ValidationMessage '请输入有效的公网 IPv4 地址。'
    $ipv6 = Read-VpsText '服务器 IPv6（没有则直接回车）' -AllowEmpty `
        -Validate { param($v) -not $v -or (Test-VpsIpAddress $v IPv6) } `
        -ValidationMessage '请输入有效 IPv6，或留空。'
    $bootstrapPort = [int](Read-VpsText '服务商当前 SSH 端口' -Default '22' `
        -Validate { param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535 })
    $bootstrapAuthChoice = Read-VpsMenu '服务商初始 root 登录方式' @(
        '密码登录（由 OpenSSH 直接询问）',
        '现有私钥登录（DMIT 等仅密钥模板）'
    ) 1
    $bootstrapAuth = if ($bootstrapAuthChoice -eq 2) { 'ExistingKey' } else { 'Password' }
    $bootstrapKeyPath = $null
    if ($bootstrapAuth -eq 'ExistingKey') {
        $bootstrapKeyInput = Read-VpsText '现有服务商私钥文件的完整路径' -Validate {
            param($v)
            $candidate = $v.Trim().Trim('"')
            Test-Path -LiteralPath $candidate -PathType Leaf
        } -ValidationMessage '找不到该私钥文件，请输入文件本身而不是目录。'
        $bootstrapKeyPath = (Resolve-Path -LiteralPath $bootstrapKeyInput.Trim().Trim('"')).Path
        Write-VpsUi '该私钥只用于写入新的实例专用公钥；不会复制进源码仓库或上传 GitHub。' Info
    }

    $roleChoice = Read-VpsMenu '这台 VPS 的部署角色' @(
        'Reality 入口节点（推荐）',
        '仅 SSH/防火墙/Komari 监控',
        '只读审计，不做变更'
    ) 1
    $role = @('RealityEntry', 'MonitorOnly', 'AuditOnly')[$roleChoice - 1]

    $adminUser = Read-VpsText '日常管理用户' -Default 'admin' `
        -Validate { param($v) $v -match '^[a-z_][a-z0-9_-]{0,30}$' -and $v -ne 'root' } `
        -ValidationMessage '请输入合法且不是 root 的 Linux 用户名。'

    $usedPorts = @($bootstrapPort, 443)
    $sshPrimary = Get-VpsRandomPort -Exclude $usedPorts
    $usedPorts += $sshPrimary
    $sshRescue = Get-VpsRandomPort -Exclude $usedPorts
    $usedPorts += $sshRescue
    $xrayBackup = Get-VpsRandomPort -Exclude $usedPorts

    if (Read-VpsYesNo '是否手动指定高位端口？' $false) {
        $sshPrimary = [int](Read-VpsText 'SSH 主端口' -Default $sshPrimary.ToString() -Validate {
                param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -ne $bootstrapPort
            })
        $sshRescue = [int](Read-VpsText 'SSH 救援端口' -Default $sshRescue.ToString() -Validate {
                param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin @($bootstrapPort, $sshPrimary)
            })
        if ($role -eq 'RealityEntry') {
            $xrayBackup = [int](Read-VpsText 'Xray 救援端口' -Default $xrayBackup.ToString() -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin @($bootstrapPort, $sshPrimary, $sshRescue, 443)
                })
        }
    }

    $target = $null
    $forceIpv4 = $true
    if ($role -eq 'RealityEntry') {
        $target = Read-VpsText 'REALITY target（只填域名，不含 https://）' `
            -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入规范域名。'
        Write-VpsUi 'target 应是预期长期运营的大学、机构或成熟企业网站，不能只凭品牌或一次 ping 判断。' Warning
        if (-not (Read-VpsYesNo '你确认该候选不是个人小站，并允许脚本从 VPS 严格审计？' $true)) {
            throw '用户取消：请准备更合适的 REALITY target 后重试。'
        }
        $forceIpv4 = Read-VpsYesNo '是否强制代理网站流量从 VPS IPv4 出口？' $true
    }

    $enableKomari = $false
    $komariEndpoint = $versions.komari_agent.endpoint_default
    if ($role -ne 'AuditOnly') {
        $enableKomari = Read-VpsYesNo '是否安装并纳管 Komari Agent？' $true
        if ($enableKomari) {
            $komariEndpoint = Read-VpsText 'Komari 站点地址' -Default $komariEndpoint `
                -Validate { param($v) $uri = $null; [Uri]::TryCreate($v, 'Absolute', [ref]$uri) -and $uri.Scheme -eq 'https' }
        }
    }

    $archivePath = Join-Path (Join-Path $InstanceRoot $provider) $instance
    $existingPlan = Join-Path $archivePath 'deployment-plan.json'
    if (Test-Path -LiteralPath $existingPlan) {
        throw "该实例已有部署计划：${existingPlan}。请使用【继续未完成部署】，不要新建覆盖。"
    }
    return [ordered]@{
        SchemaVersion = 1
        CreatedAt = (Get-Date).ToString('o')
        Provider = $provider
        Instance = $instance
        NodeName = $nodeName
        Role = $role
        Server = [ordered]@{
            IPv4 = $ipv4
            IPv6 = $ipv6
            BootstrapUser = 'root'
            BootstrapSshPort = $bootstrapPort
            BootstrapAuth = $bootstrapAuth
            BootstrapKeyPath = $bootstrapKeyPath
        }
        AdminUser = $adminUser
        Ports = [ordered]@{
            SshPrimary = $sshPrimary
            SshRescue = $sshRescue
            XrayPrimary = 443
            XrayBackup = if ($role -eq 'RealityEntry') { $xrayBackup } else { $null }
        }
        Reality = [ordered]@{
            Target = $target
            ForceIpv4Egress = $forceIpv4
            TargetSamples = [int]$versions.target_audit.samples
            TargetMaxMedianMs = [int]$versions.target_audit.maximum_median_ms
            XrayVersion = $versions.xray.version
        }
        Komari = [ordered]@{
            Enabled = $enableKomari
            Endpoint = $komariEndpoint
            AgentVersion = $versions.komari_agent.version
        }
        Paths = [ordered]@{
            Archive = $archivePath
            KeyDirectory = (Join-Path $archivePath ($nodeName + '-id_ed25519'))
        }
    }
}

function Protect-VpsPrivateFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($IsWindows) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $commands = @(
            @($Path, '/inheritance:r'),
            @($Path, '/grant:r', "${identity}:(F)", 'SYSTEM:(F)')
        )
        foreach ($arguments in $commands) {
            $result = Invoke-VpsProcess -FilePath 'icacls.exe' -ArgumentList $arguments -TimeoutSeconds 30
            if ($result.ExitCode -ne 0) {
                throw "无法收紧私有文件 ACL：$Path"
            }
        }
    }
    else {
        & chmod 600 -- $Path
        if ($LASTEXITCODE -ne 0) { throw "无法设置私有文件权限：$Path" }
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
    return Join-Path ([string]$Context.Plan.Paths.KeyDirectory) 'id_ed25519'
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
    if ((Test-Path -LiteralPath $keyPath) -and (Test-Path -LiteralPath $publicPath)) {
        Protect-VpsPrivateFile -Path $keyPath
        return
    }
    $sshKeygen = Get-VpsCommandPath 'ssh-keygen.exe'
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
    $preamble = [Text.StringBuilder]::new()
    [void]$preamble.AppendLine('set -euo pipefail')
    foreach ($key in $Parameters.Keys) {
        $name = ([string]$key).ToUpperInvariant()
        if ($name -notmatch '^[A-Z][A-Z0-9_]*$') { throw "远端参数名无效：$key" }
        $value = if ($null -eq $Parameters[$key]) { '' } else { [string]$Parameters[$key] }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
        $exportLine = 'export VPS_PARAM_' + $name + '="$(printf ''%s'' ''' + $encoded + ''' | base64 -d)"'
        [void]$preamble.AppendLine($exportLine)
    }
    $script = "(`n" + $preamble.ToString() + (Get-VpsRemoteAsset -Context $Context -Name $Asset) + "`n)`n"
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

function New-MxhXrayInbound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Tag,
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [Collections.IDictionary]$Secrets,
        [Parameter(Mandatory)] [string]$Target
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
                target = "${Target}:443"
                xver = 0
                serverNames = @($Target)
                privateKey = $Secrets.RealityPrivateKey
                shortIds = @($Secrets.ShortId)
            }
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
        $lines.Add("    servername: $(ConvertTo-MxhYamlString ([string]$Context.Plan.Reality.Target))")
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
    if (-not $Context.NonInteractive -and -not (Read-VpsYesNo '确认按以上顺序开始？' $true)) {
        throw '用户取消部署。'
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
            Write-VpsUi '后续模块已停止；旧 SSH 入口不会由核心自动关闭。修复后使用继续模式。' Warning
            throw
        }
    }
}

function Test-VpsProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ProjectRoot)

    $testScript = Join-Path $ProjectRoot 'tests\Run-Tests.ps1'
    & $testScript -ProjectRoot $ProjectRoot
    if ($LASTEXITCODE -ne 0) { throw '项目自检失败。' }
}

function Show-VpsPlanSummary {
    param([Parameter(Mandatory)] [Collections.IDictionary]$Plan)
    Write-Host ''
    Write-Host '部署摘要' -ForegroundColor White
    Write-Host "  实例：$($Plan.Provider) / $($Plan.Instance)"
    Write-Host "  节点：$($Plan.NodeName)"
    Write-Host "  角色：$($Plan.Role)"
    Write-Host "  地址：$($Plan.Server.IPv4)"
    $bootstrapAuthLabel = if ($Plan.Server.Contains('BootstrapAuth') -and $Plan.Server.BootstrapAuth -eq 'ExistingKey') { '现有服务商私钥' } else { '密码' }
    Write-Host "  初始认证：$bootstrapAuthLabel"
    Write-Host "  SSH：$($Plan.Server.BootstrapSshPort) -> $($Plan.Ports.SshPrimary) + $($Plan.Ports.SshRescue)"
    if ($Plan.Role -eq 'RealityEntry') {
        Write-Host "  Xray：443 + $($Plan.Ports.XrayBackup)，target=$($Plan.Reality.Target)"
    }
    Write-Host "  Komari：$($Plan.Komari.Enabled)"
    Write-Host "  私有归档：$($Plan.Paths.Archive)"
    Write-VpsUi '请先在服务商安全组临时放行上面两个 SSH 高位端口、443 和可选 Xray 救援端口。' Warning
}

function Start-VpsDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [ValidateSet('Interactive', 'New', 'Resume', 'ValidateProject')] [string]$Mode = 'Interactive',
        [string]$PlanPath,
        [string[]]$OnlyModule,
        [string]$InstanceRoot = 'F:\VPS\VPS-Instances',
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '需要 PowerShell 7 或更高版本。' }
    if ($Mode -eq 'ValidateProject') {
        Test-VpsProject -ProjectRoot $ProjectRoot
        return
    }
    if ($Mode -eq 'Interactive') {
        $choice = Read-VpsMenu '请选择操作' @('新部署', '继续未完成部署', '项目离线自检', '退出') 1
        $Mode = @('New', 'Resume', 'ValidateProject', 'Exit')[$choice - 1]
        if ($Mode -eq 'Exit') { return }
        if ($Mode -eq 'ValidateProject') { Test-VpsProject -ProjectRoot $ProjectRoot; return }
    }

    if ($Mode -eq 'New') {
        $plan = New-VpsInteractivePlan -ProjectRoot $ProjectRoot -InstanceRoot $InstanceRoot
    }
    else {
        if (-not $PlanPath) {
            $PlanPath = Read-VpsText 'deployment-plan.json 完整路径' -Validate { param($v) Test-Path -LiteralPath $v }
        }
        $plan = Read-VpsJsonHashtable -Path $PlanPath
    }

    Show-VpsPlanSummary -Plan $plan
    $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan -DryRun:$DryRun -NonInteractive:$NonInteractive
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

Export-ModuleMember -Function @(
    'Start-VpsDeploy', 'Write-VpsUi', 'Write-VpsLog', 'Read-VpsYesNo', 'Read-VpsText',
    'ConvertFrom-VpsSecureString', 'Invoke-VpsRemoteScript', 'Invoke-VpsSshCommand',
    'Invoke-VpsScpDownload', 'Initialize-VpsBootstrapAccess', 'Test-VpsSshConnection',
    'Save-VpsContext', 'Save-VpsJson', 'Protect-VpsPrivateFile', 'Get-VpsSshKeyPath',
    'Invoke-VpsProcess', 'Get-VpsCommandPath', 'Get-VpsModules', 'Get-VpsRandomPort',
    'New-VpsRandomString', 'Test-VpsProject', 'Get-VpsMarkerValue', 'Get-VpsSshArguments',
    'New-MxhXrayInbound', 'New-MxhMihomoProfileText', 'Invoke-MxhMihomoEgressTest'
)
