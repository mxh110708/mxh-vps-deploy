function New-MxhExistingImportPlanInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$InstanceRoot
    )

    $versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    $wizard = [ordered]@{
        InstanceRoot = [IO.Path]::GetFullPath((ConvertTo-VpsInputPath -Value $InstanceRoot)).TrimEnd('\', '/')
        Provider = $null
        Instance = $null
        NodeName = $null
        IPv4 = $null
        IPv6 = $null
        SshPort = 22
        BootstrapAuth = 'ExistingKey'
        BootstrapKeyPath = $null
        SshKeyMode = 'ReuseExisting'
        EnforceKeyOnlySsh = $false
        BandwidthMbps = $null
    }
    $getInstance = { Join-Path (Join-Path $wizard.InstanceRoot $wizard.Provider) $wizard.Instance }
    $getArchive = { Join-Path (& $getInstance) $script:VpsManagedDirectoryName }
    $steps = @(
        [pscustomobject]@{
            Id = 'archive-root'; ShouldRun = { $true }; Run = {
                $value = Read-VpsText '现有 VPS 私有归档根目录（不会立即创建）' -Default $wizard.InstanceRoot -AllowBack `
                    -Validate ${function:Test-VpsArchiveRoot} -ValidationMessage '请输入完整绝对路径；可全用 / 或全用 \，但不能混用，也不能是磁盘根目录。'
                $wizard.InstanceRoot = [IO.Path]::GetFullPath((ConvertTo-VpsInputPath -Value $value)).TrimEnd('\', '/')
            }
        },
        [pscustomobject]@{
            Id = 'provider'; ShouldRun = { $true }; Run = {
                $wizard.Provider = Read-VpsText '服务商名称' -Default $wizard.Provider -AllowBack `
                    -Validate ${function:Test-VpsSafePathSegment} -ValidationMessage '服务商名称包含不允许的路径字符。'
            }
        },
        [pscustomobject]@{
            Id = 'instance'; ShouldRun = { $true }; Run = {
                $wizard.Instance = Read-VpsText '实例名称' -Default $wizard.Instance -AllowBack `
                    -Validate ${function:Test-VpsSafePathSegment} -ValidationMessage '实例名称包含不允许的路径字符。'
            }
        },
        [pscustomobject]@{
            Id = 'node-name'; ShouldRun = { $true }; Run = {
                $wizard.NodeName = Read-VpsText '客户端节点基础名称' -Default $wizard.NodeName -AllowBack `
                    -Validate ${function:Test-VpsNodeName} -ValidationMessage '节点名必须是 1–120 个可打印字符且不能换行。'
            }
        },
        [pscustomobject]@{
            Id = 'ipv4'; ShouldRun = { $true }; Run = {
                $wizard.IPv4 = Read-VpsText 'VPS IPv4' -Default $wizard.IPv4 -AllowBack `
                    -Validate { param($v) Test-VpsIpAddress $v IPv4 } -ValidationMessage '请输入有效 IPv4。'
            }
        },
        [pscustomobject]@{
            Id = 'ipv6'; ShouldRun = { $true }; Run = {
                $value = Read-VpsText 'VPS IPv6（没有可留空）' -Default $wizard.IPv6 -AllowEmpty -AllowBack `
                    -Validate { param($v) -not $v -or (Test-VpsIpAddress $v IPv6) } -ValidationMessage '请输入有效 IPv6 或留空。'
                $wizard.IPv6 = if ($value) { $value } else { $null }
            }
        },
        [pscustomobject]@{
            Id = 'ssh-port'; ShouldRun = { $true }; Run = {
                $wizard.SshPort = [int](Read-VpsText '当前可用 root SSH 端口' -Default ([string]$wizard.SshPort) -AllowBack -Validate {
                        param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535
                    } -ValidationMessage '请输入 1–65535 的端口。')
            }
        },
        [pscustomobject]@{
            Id = 'ssh-auth'; ShouldRun = { $true }; Run = {
                $default = if ($wizard.BootstrapAuth -eq 'ExistingKey') { 1 } else { 2 }
                $choice = Read-VpsMenu '当前 root SSH 认证方式' @('现有 OpenSSH 私钥', '密码（由 ssh.exe 询问）') $default -AllowBack
                $wizard.BootstrapAuth = if ($choice -eq 1) { 'ExistingKey' } else { 'Password' }
                if ($wizard.BootstrapAuth -ne 'ExistingKey') {
                    $wizard.BootstrapKeyPath = $null
                    $wizard.SshKeyMode = 'GenerateManaged'
                }
            }
        },
        [pscustomobject]@{
            Id = 'ssh-key'; ShouldRun = { $wizard.BootstrapAuth -eq 'ExistingKey' }; Run = {
                $value = Read-VpsText '当前 root OpenSSH 私钥完整路径' -Default $wizard.BootstrapKeyPath -AllowBack `
                    -Validate { param($v) Test-VpsExistingInputPath -Value $v -PathType Leaf } `
                    -ValidationMessage '找不到该私钥，或路径混用了 / 与 \。'
                $wizard.BootstrapKeyPath = (Resolve-Path -LiteralPath (ConvertTo-VpsInputPath -Value $value)).Path
            }
        },
        [pscustomobject]@{
            Id = 'ssh-key-mode'; ShouldRun = { $wizard.BootstrapAuth -eq 'ExistingKey' }; Run = {
                $default = if ($wizard.SshKeyMode -eq 'GenerateManaged') { 2 } else { 1 }
                $choice = Read-VpsMenu '纳管后的 SSH 管理密钥' @(
                    '复用当前 OpenSSH 私钥并复制为规范文件名（推荐；不改服务器公钥）',
                    '生成新的实例管理密钥并写入服务器（保留旧密钥）'
                ) $default -AllowBack
                $wizard.SshKeyMode = if ($choice -eq 1) { 'ReuseExisting' } else { 'GenerateManaged' }
            }
        },
        [pscustomobject]@{
            Id = 'ssh-policy'; ShouldRun = { $true }; Run = {
                $default = if ($wizard.EnforceKeyOnlySsh) { 2 } else { 1 }
                $choice = Read-VpsMenu '纳管时是否调整现有 SSH 认证策略' @(
                    '保持服务器当前认证策略（推荐用于既有 VPS）',
                    '在密钥复验后收口为 key-only'
                ) $default -AllowBack
                $wizard.EnforceKeyOnlySsh = $choice -eq 2
            }
        },
        [pscustomobject]@{
            Id = 'bandwidth'; ShouldRun = { $true }; Run = {
                $wizard.BandwidthMbps = [int](Read-VpsText '套餐标称带宽（Mbps，例如 100 或 1000）' -Default ([string]$wizard.BandwidthMbps) -AllowBack -Validate {
                        param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 100000
                    } -ValidationMessage '请输入服务商标称的 1–100000 Mbps 整数。')
            }
        }
    )

    $buildPlan = {
        $archive = & $getArchive
        [ordered]@{
            SchemaVersion = 3
            CreatedAt = (Get-Date).ToString('o')
            Provider = $wizard.Provider
            Instance = $wizard.Instance
            NodeName = $wizard.NodeName
            Role = 'MonitorOnly'
            ProtocolInventory = [ordered]@{
                SchemaVersion = 1
                RealityEntry = [ordered]@{ Installed = $false; Enabled = $false; Active = $false; Partial = $false; Service = 'xray.service' }
                AnyTlsEntry = [ordered]@{ Installed = $false; Enabled = $false; Active = $false; Partial = $false; Service = 'sing-box-anytls.service' }
                ShadowsocksLanding = [ordered]@{ Installed = $false; Enabled = $false; Active = $false; Partial = $false; Service = 'sing-box.service' }
            }
            Server = [ordered]@{
                IPv4 = $wizard.IPv4; IPv6 = $wizard.IPv6; BootstrapUser = 'root'
                BootstrapSshPort = [int]$wizard.SshPort; BootstrapAuth = $wizard.BootstrapAuth
                BootstrapKeyPath = $wizard.BootstrapKeyPath
            }
            SshKey = [ordered]@{
                Mode = if ($wizard.BootstrapAuth -eq 'ExistingKey') { [string]$wizard.SshKeyMode } else { 'GenerateManaged' }
                SourcePrivateKeyPath = if ($wizard.BootstrapAuth -eq 'ExistingKey') { [string]$wizard.BootstrapKeyPath } else { $null }
                ManagedFileName = if ($wizard.BootstrapAuth -eq 'ExistingKey' -and $wizard.SshKeyMode -eq 'ReuseExisting') { 'id_vps_management' } else { 'id_ed25519' }
                PreserveSource = $true
            }
            AdminUser = 'root'
            Ports = [ordered]@{
                SshPrimary = [int]$wizard.SshPort; SshRescue = [int]$wizard.SshPort
                XrayPrimary = $null; XrayBackup = $null; AnyTlsPrimary = $null; LandingShadowsocks = $null
            }
            Reality = [ordered]@{
                Target = $null; TargetMode = 'ExternalAudited'; ServerName = $null; TargetAddress = $null
                LocalHttpsPort = 8443; ForceIpv4Egress = $true
                TargetSamples = [int]$versions.target_audit.samples
                TargetMaxMedianMs = [int]$versions.target_audit.maximum_median_ms
                XrayVersion = [string]$versions.xray.version
                XrayVersionChannel = 'ImportedOrLegacy'
            }
            AnyTls = [ordered]@{
                Enabled = $false; ServerName = $null; EchPublicName = $null
                SingBoxVersion = [string]$versions.sing_box.version; ForceIpv4Egress = $true
                PaddingSchemeMode = $null; PaddingScheme = @()
            }
            TrustedTls = [ordered]@{
                Enabled = $false; ZoneName = $null; CertbotEmail = $null; CloudflareTokenFile = $null
                AnyTlsCertificateName = 'mxh-anytls'; RealityCertificateName = 'mxh-reality-target'
            }
            Shadowsocks = [ordered]@{
                Method = '2022-blake3-aes-128-gcm'; SingBoxVersion = [string]$versions.sing_box.version
                TrustedEntryIPv4s = @(); TrustedEntryIPv6s = @(); ClientTransitTag = 'Imported Entry'
                SecondaryIpv6Enabled = $false; SecondaryIpv6Address = $null; SecondaryBindInterface = $null
            }
            NetworkTuning = [ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = [int]$wizard.BandwidthMbps; ReferenceRttMs = $null }
            Firewall = [ordered]@{ Mode = 'PreserveExisting' }
            Komari = [ordered]@{ Enabled = $false; Endpoint = $null; AgentVersion = [string]$versions.komari_agent.version }
            Import = [ordered]@{
                Enabled = $true; Status = 'Planned'; PreserveExistingFirewall = $true
                EnforceKeyOnlySsh = [bool]$wizard.EnforceKeyOnlySsh; CreatedAt = (Get-Date).ToString('o')
            }
            Paths = [ordered]@{
                InstanceDirectory = (& $getInstance)
                Archive = $archive
                KeyDirectory = Join-Path $archive 'ssh'
            }
        }
    }

    $index = 0
    while ($true) {
        while ($index -lt $steps.Count) {
            $step = $steps[$index]
            if (-not (& $step.ShouldRun)) { $index++; continue }
            try { & $step.Run; $index++ }
            catch {
                if (-not (Test-VpsWizardBackError $_)) { throw }
                $previous = -1
                for ($candidate = $index - 1; $candidate -ge 0; $candidate--) {
                    if (& $steps[$candidate].ShouldRun) { $previous = $candidate; break }
                }
                if ($previous -lt 0) { throw }
                $index = $previous
            }
        }
        $plan = & $buildPlan
        $existingPlan = Get-VpsExistingPlanPath -InstanceDirectory ([string]$plan.Paths.InstanceDirectory)
        if ($existingPlan) {
            Write-VpsUi '目标实例目录已经存在 deployment-plan.json；请使用现有 VPS 协议管理或 Resume，不能重复导入。' Warning
            $index = 2
            continue
        }
        Write-Host ''
        Write-Host '现有 VPS 纳管摘要' -ForegroundColor White
        Write-Host "  私有归档：$($plan.Paths.Archive)"
        Write-Host "  实例：$($plan.Provider) / $($plan.Instance)"
        Write-Host "  地址：$($plan.Server.IPv4) / $($plan.Server.IPv6)"
        Write-Host "  当前 root SSH：$($plan.Server.BootstrapSshPort) / $($plan.Server.BootstrapAuth)"
        $keyAction = if ($plan.SshKey.Mode -eq 'ReuseExisting') { '复用当前 OpenSSH 密钥，不轮换服务器公钥' } else { '写入新的实例管理公钥并保留旧密钥' }
        $sshAction = if ($plan.Import.EnforceKeyOnlySsh) { '收口为 key-only' } else { '保持现有 SSH 认证策略' }
        Write-Host "  将执行：$keyAction；$sshAction；只读识别现有协议和配置"
        Write-Host "  套餐标称带宽：$($plan.NetworkTuning.BandwidthMbps) Mbps（RTT 稍后可选）"
        Write-Host '  不会执行：重装协议、改端口、覆盖现有防火墙、修改客户端权威配置'
        $choice = Read-VpsMenu '请核对纳管方案' @('确认并开始纳管', '取消本次纳管') 1 -AllowBack
        if ($choice -eq 1) { return $plan }
        if ($choice -eq 2) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        $index = $steps.Count - 1
    }
}

function Set-MxhImportedModuleSuccess {
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$State,
        [Parameter(Mandatory)] [string]$Id,
        [string]$Message = 'Verified during existing VPS import'
    )
    $State.Modules[$Id] = [ordered]@{ Status = 'Success'; UpdatedAt = (Get-Date).ToString('o'); Message = $Message }
}

function Invoke-MxhExistingVpsImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [Collections.IDictionary]$Plan,
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    if ($DryRun) {
        Show-VpsPlanSummary -Plan $Plan
        Write-VpsUi 'DryRun：不创建归档、不生成密钥、不连接 VPS；正式纳管时才读取远端配置。' Success
        return
    }
    $archive = [IO.Path]::GetFullPath([string]$Plan.Paths.Archive)
    [IO.Directory]::CreateDirectory($archive) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $archive 'server-configs')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $archive 'client-exports')) | Out-Null
    [IO.Directory]::CreateDirectory([string]$Plan.Paths.KeyDirectory) | Out-Null
    $context = [pscustomobject]@{
        ProjectRoot = $ProjectRoot; Plan = $Plan; ArchivePath = $archive
        PlanPath = Join-Path $archive 'deployment-plan.json'
        SecretsPath = Join-Path $archive 'deployment-secrets.private.json'
        StatePath = Join-Path $archive 'deployment-state.json'
        LogPath = Join-Path $archive 'deployment.log'
        Secrets = [ordered]@{ SchemaVersion = 1; AdminPassword = '<not-managed>' }
        State = [ordered]@{
            SchemaVersion = 1; StartedAt = (Get-Date).ToString('o')
            CurrentManagementPort = [int]$Plan.Server.BootstrapSshPort
            Modules = [ordered]@{}; BackupDirectories = [ordered]@{}
        }
        DryRun = $false; NonInteractive = [bool]$NonInteractive
        Versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    }

    Initialize-VpsBootstrapAccess -Context $context
    $readImport = {
        $result = Invoke-VpsRemoteScript -Context $context -Asset 'existing-vps-import-audit.sh' -TimeoutSeconds 600 -SensitiveOutput
        if ($result.StdOut -notmatch 'VPSDEPLOY_EXISTING_IMPORT_OK') { throw '现有 VPS 远端审计未返回成功标记。' }
        $audit = (Get-VpsMarkerValue $result.StdOut IMPORT_AUDIT -Required) | ConvertFrom-Json -AsHashtable
        $private = (Get-VpsMarkerValue $result.StdOut IMPORT_PRIVATE -Required) | ConvertFrom-Json -AsHashtable
        [pscustomobject]@{ Audit = $audit; Private = $private }
    }
    $imported = & $readImport
    $managedKeyOnlyDropIn = $false
    $enforceKeyOnly = $Plan.Import.Contains('EnforceKeyOnlySsh') -and [bool]$Plan.Import.EnforceKeyOnlySsh
    if ($enforceKeyOnly -and ($imported.Audit.PasswordAuthentication -ne 'no' -or
            $imported.Audit.KbdInteractiveAuthentication -ne 'no' -or $imported.Audit.PubkeyAuthentication -ne 'yes')) {
        Write-VpsUi '现有 SSH 尚非 key-only；实例专用公钥已验证，现在应用最小认证加固，不修改监听端口。' Warning
        $harden = Invoke-VpsRemoteScript -Context $context -Asset 'existing-vps-import-ssh-keyonly.sh' -TimeoutSeconds 180
        if ($harden.StdOut -notmatch 'VPSDEPLOY_IMPORT_SSH_KEYONLY_OK') { throw '导入实例 SSH key-only 加固失败。' }
        $context.State.BackupDirectories.ImportSsh = Get-VpsMarkerValue $harden.StdOut BACKUP_DIR -Required
        $managedKeyOnlyDropIn = $true
        if (-not (Test-VpsSshConnection -Context $context -User root -Port ([int]$Plan.Server.BootstrapSshPort))) {
            throw 'SSH key-only 加固后实例专用 root 密钥复验失败。'
        }
        $imported = & $readImport
    }
    if ($enforceKeyOnly -and ($imported.Audit.PasswordAuthentication -ne 'no' -or
            $imported.Audit.KbdInteractiveAuthentication -ne 'no' -or $imported.Audit.PubkeyAuthentication -ne 'yes')) {
        throw 'SSH 有效配置仍未达到 key-only；已停止纳管，不修改代理协议或防火墙。'
    }
    if (-not $enforceKeyOnly -and $imported.Audit.PubkeyAuthentication -ne 'yes') {
        throw '当前 sshd 有效配置未启用公钥认证，无法建立可自动维护的管理入口。脚本未修改现有认证策略。'
    }
    if ([int]$Plan.Server.BootstrapSshPort -notin @($imported.Audit.SshPorts | ForEach-Object { [int]$_ })) {
        throw '用户填写的 SSH 端口不在 sshd 有效监听配置中。'
    }

    $inventory = Get-MxhProtocolInventory -Plan $Plan -RemoteInventory $imported.Audit.ProtocolInventory
    $Plan.ProtocolInventory = $inventory
    $Plan.Role = Get-MxhInventoryPrimaryRole -Inventory $inventory
    if ($imported.Audit.Contains('AdminUser') -and $imported.Audit.AdminUser) { $Plan.AdminUser = [string]$imported.Audit.AdminUser }
    if ($Plan.AdminUser -ne 'root') {
        $publicKey = (Get-Content -Raw ((Get-VpsSshKeyPath $context) + '.pub')).Trim()
        $adminKey = Invoke-VpsRemoteScript -Context $context -Asset 'existing-vps-import-admin-key.sh' -Parameters @{
            ADMIN_USER = [string]$Plan.AdminUser; PUBLIC_KEY = $publicKey
        } -TimeoutSeconds 180
        if ($adminKey.StdOut -notmatch 'VPSDEPLOY_IMPORT_ADMIN_KEY_OK') { throw '现有 VPS 的 admin 实例密钥写入未确认。' }
        if (-not (Test-VpsSshConnection -Context $context -User ([string]$Plan.AdminUser) -Port ([int]$Plan.Server.BootstrapSshPort))) {
            throw '现有 VPS 的 admin 实例密钥登录复验失败。'
        }
    }
    $sshPorts = @($imported.Audit.SshPorts | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $Plan.Ports.SshPrimary = [int]$Plan.Server.BootstrapSshPort
    $otherPort = @($sshPorts | Where-Object { $_ -ne [int]$Plan.Ports.SshPrimary } | Select-Object -First 1)
    $Plan.Ports.SshRescue = if ($otherPort.Count -gt 0) { [int]$otherPort[0] } else { [int]$Plan.Ports.SshPrimary }

    if ($inventory.RealityEntry.Installed) {
        $reality = $imported.Private.Protocols.RealityEntry
        $Plan.Ports.XrayPrimary = [int]$reality.PrimaryPort
        $Plan.Ports.XrayBackup = if ($null -ne $reality.BackupPort) { [int]$reality.BackupPort } else { $null }
        $Plan.Reality.Target = [string]$reality.TargetHost
        $Plan.Reality.TargetMode = [string]$reality.TargetMode
        $Plan.Reality.ServerName = [string]$reality.ServerName
        $Plan.Reality.TargetAddress = [string]$reality.TargetAddress
        if ($Plan.Reality.TargetMode -eq 'LocalOwnedTls' -and $Plan.Reality.TargetAddress -match ':(\d+)$') {
            $Plan.Reality.LocalHttpsPort = [int]$Matches[1]
        }
        $Plan.Reality.ForceIpv4Egress = [bool]$reality.ForceIpv4Egress
        $Plan.Reality.XrayVersion = [string]$reality.XrayVersion
        $Plan.Reality.XrayVersionChannel = 'ImportedOrLegacy'
        $context.Secrets.Xray = Copy-MxhHashtable -Value $reality.Secrets
    }
    if ($inventory.AnyTlsEntry.Installed) {
        $anyTls = $imported.Private.Protocols.AnyTlsEntry
        $Plan.Ports.AnyTlsPrimary = [int]$anyTls.Port
        $Plan.AnyTls.Enabled = $true
        $Plan.AnyTls.ServerName = [string]$anyTls.ServerName
        $Plan.AnyTls.EchPublicName = [string]$anyTls.EchPublicName
        $Plan.AnyTls.PaddingSchemeMode = 'ImportedExisting'
        $Plan.AnyTls.PaddingScheme = @($anyTls.PaddingScheme)
        $Plan.AnyTls.ForceIpv4Egress = [bool]$anyTls.ForceIpv4Egress
        $Plan.AnyTls.SingBoxVersion = [string]$anyTls.SingBoxVersion
        $context.Secrets.AnyTls = Copy-MxhHashtable -Value $anyTls.Secrets
    }
    if ($inventory.ShadowsocksLanding.Installed) {
        $ss = $imported.Private.Protocols.ShadowsocksLanding
        $Plan.Ports.LandingShadowsocks = [int]$ss.Port
        $Plan.Shadowsocks.Method = [string]$ss.Method
        $Plan.Shadowsocks.SecondaryIpv6Enabled = [bool]$ss.SecondaryIpv6Enabled
        $Plan.Shadowsocks.SingBoxVersion = [string]$ss.SingBoxVersion
        $context.Secrets.Shadowsocks = Copy-MxhHashtable -Value $ss.Secrets
    }
    $Plan.TrustedTls.Enabled = [bool]$imported.Audit.ManagedCertbot
    if ($imported.Audit.Contains('Komari') -and [bool]$imported.Audit.Komari.Agent.Installed) {
        $Plan.Komari.Enabled = [bool]$imported.Audit.Komari.Agent.Active
        if ($imported.Private.KomariAgent) {
            $Plan.Komari.Endpoint = [string]$imported.Private.KomariAgent.Endpoint
            $context.Secrets.KomariAgent = [ordered]@{ Token = [string]$imported.Private.KomariAgent.Token }
        }
        $context.State.KomariInstalled = $true
    }
    $context.State.KomariController = if ($imported.Audit.Contains('Komari')) { Copy-MxhHashtable $imported.Audit.Komari.Controller } else { @{} }
    $context.State.Cloudflared = if ($imported.Audit.Contains('Komari')) { Copy-MxhHashtable $imported.Audit.Komari.Cloudflared } else { @{} }

    $Plan.Import.Status = 'Completed'
    $Plan.Import.CompletedAt = (Get-Date).ToString('o')
    $Plan.Import.SingleSshPort = ([int]$Plan.Ports.SshPrimary -eq [int]$Plan.Ports.SshRescue)
    $Plan.Import.ManagedKeyOnlyDropIn = $managedKeyOnlyDropIn
    $Plan.Import.SshAuthenticationPreserved = -not $enforceKeyOnly
    $context.State.CurrentManagementPort = [int]$Plan.Ports.SshPrimary
    $context.State.BootstrapSshRemoved = $true
    $context.State.ProtocolInventory = Copy-MxhHashtable -Value $inventory
    $context.State.Audit = [ordered]@{
        Architecture = [string]$imported.Audit.Architecture
        MemoryKiB = [long]$imported.Audit.MemoryKiB
        OsId = [string]$imported.Audit.OsId
        OsVersion = [string]$imported.Audit.OsVersion
        ExistingServices = @((Get-MxhManagedProtocolRoles) | Where-Object { $inventory[$_].Installed })
        NftRuleLines = if ($imported.Audit.NftablesPresent) { 1 } else { 0 }
        ImportedPreserveExisting = $true
    }
    foreach ($id in @('ssh-transition', 'nftables-transition', 'final-validation', 'ssh-cutover', 'private-archive')) {
        Set-MxhImportedModuleSuccess -State $context.State -Id $id
    }
    if ($inventory.RealityEntry.Installed) { Set-MxhImportedModuleSuccess -State $context.State -Id 'xray-reality' }
    if ($inventory.AnyTlsEntry.Installed) { Set-MxhImportedModuleSuccess -State $context.State -Id 'sing-box-anytls' }
    if ($inventory.ShadowsocksLanding.Installed) { Set-MxhImportedModuleSuccess -State $context.State -Id 'sing-box-shadowsocks' }

    Save-VpsJson -Value $Plan -Path $context.PlanPath -Private
    Save-VpsJson -Value $context.Secrets -Path $context.SecretsPath -Private
    Save-VpsJson -Value $context.State -Path $context.StatePath -Private
    Save-VpsJson -Value $imported.Audit -Path (Join-Path $archive 'existing-import-audit.json') -Private

    $serverDir = Join-Path $archive 'server-configs'
    Invoke-VpsScpDownload -Context $context -RemotePath '/etc/ssh/sshd_config' -LocalPath (Join-Path $serverDir 'sshd_config')
    if ($inventory.RealityEntry.Installed) {
        Invoke-VpsScpDownload -Context $context -RemotePath '/usr/local/etc/xray/config.json' -LocalPath (Join-Path $serverDir 'xray-config.json')
        $clientModule = & (Join-Path $ProjectRoot 'modules\90-ClientExport.ps1')
        & $clientModule.Invoke $context
    }
    if ($inventory.AnyTlsEntry.Installed) {
        Invoke-VpsScpDownload -Context $context -RemotePath '/etc/sing-box-anytls/config.json' -LocalPath (Join-Path $serverDir 'sing-box-anytls-config.private.json')
        $clientModule = & (Join-Path $ProjectRoot 'modules\91-AnyTlsClientExport.ps1')
        & $clientModule.Invoke $context
    }
    if ($inventory.ShadowsocksLanding.Installed) {
        Invoke-VpsScpDownload -Context $context -RemotePath '/etc/sing-box/config.json' -LocalPath (Join-Path $serverDir 'sing-box-config.private.json')
        $clientModule = & (Join-Path $ProjectRoot 'modules\92-LandingClientExport.ps1')
        & $clientModule.Invoke $context
    }

    $report = @"
MXH VPS DEPLOY - EXISTING VPS IMPORT
Imported: $((Get-Date).ToString('o'))
Provider: $($Plan.Provider)
Instance: $($Plan.Instance)
Node: $($Plan.NodeName)
Primary role: $($Plan.Role)
Firewall mode: PreserveExisting
SSH primary/rescue: $($Plan.Ports.SshPrimary) / $($Plan.Ports.SshRescue)
Protocol inventory: $($Plan.ProtocolInventory | ConvertTo-Json -Compress -Depth 8)

Active credentials are stored in deployment-secrets.private.json and client-exports.
The import did not reinstall protocols, change proxy ports, or overwrite the existing firewall.
"@
    $reportPath = Join-Path $archive ($Plan.NodeName + '-import-archive.txt')
    [IO.File]::WriteAllText($reportPath, $report, [Text.UTF8Encoding]::new($false))
    Protect-VpsPrivateFile $reportPath
    $context.State.FinalArchive = $reportPath
    Save-VpsContext -Context $context

    $checksumPath = Join-Path $archive 'SHA256SUMS-private.txt'
    $lines = foreach ($file in (Get-ChildItem -LiteralPath $archive -File -Recurse | Where-Object FullName -ne $checksumPath)) {
        $relative = [IO.Path]::GetRelativePath($archive, $file.FullName).Replace('\', '/')
        try { "{0}  {1}" -f (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName -ErrorAction Stop).Hash.ToLowerInvariant(), $relative }
        catch { "# UNREADABLE-SKIPPED  $relative" }
    }
    [IO.File]::WriteAllText($checksumPath, (($lines | Sort-Object) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Protect-VpsPrivateFile $checksumPath
    Write-VpsUi "现有 VPS 已纳管：$archive" Success
    if ($Plan.Import.SingleSshPort) {
        Write-VpsUi '该实例只有一个现有 SSH 端口；协议管理可用，但不等同于新部署的双入口 SSH。建议以后单独补充救援端口。' Warning
    }
}
