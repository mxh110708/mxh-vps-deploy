function Get-MxhProtocolRoleLabel {
    param([Parameter(Mandatory)] [string]$Role)
    switch ($Role) {
        'RealityEntry' { 'Reality 入口' }
        'AnyTlsEntry' { 'AnyTLS + 可信 TLS + ECH 入口' }
        'ShadowsocksLanding' { 'Shadowsocks 2022 落地' }
        default { $Role }
    }
}

function Get-MxhProtocolServiceName {
    param([Parameter(Mandatory)] [string]$Role)
    switch ($Role) {
        'RealityEntry' { 'xray.service' }
        'AnyTlsEntry' { 'sing-box-anytls.service' }
        'ShadowsocksLanding' { 'sing-box.service' }
        default { throw "不支持的协议角色：$Role" }
    }
}

function Test-MxhModuleSucceeded {
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$State,
        [Parameter(Mandatory)] [string]$Id
    )
    if (-not $State.Contains('Modules') -or -not $State.Modules.Contains($Id)) { return $false }
    return [string]$State.Modules[$Id].Status -eq 'Success'
}

function Get-MxhMigrationModuleIds {
    param(
        [Parameter(Mandatory)] [ValidateSet('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')]
        [string]$TargetRole,
        [string]$RealityTargetMode = 'ExternalAudited'
    )

    $ids = [Collections.Generic.List[string]]::new()
    $ids.Add('migration-preflight')
    if ($TargetRole -eq 'RealityEntry') {
        if ($RealityTargetMode -eq 'LocalOwnedTls') {
            $ids.Add('certbot-dns')
            $ids.Add('local-https-target')
        }
        else { $ids.Add('target-audit') }
        $ids.Add('migration-arm-rollback')
        $ids.Add('xray-reality')
        $ids.Add('client-export')
    }
    elseif ($TargetRole -eq 'AnyTlsEntry') {
        $ids.Add('certbot-dns')
        $ids.Add('migration-arm-rollback')
        $ids.Add('sing-box-anytls')
        $ids.Add('anytls-client-export')
    }
    else {
        $ids.Add('migration-arm-rollback')
        $ids.Add('sing-box-shadowsocks')
        $ids.Add('landing-client-export')
        $ids.Add('migration-shadowsocks-probe')
    }
    $ids.Add('network-tuning')
    $ids.Add('nftables-transition')
    $ids.Add('final-validation')
    $ids.Add('migration-commit')
    $ids.Add('private-archive')
    return $ids.ToArray()
}

function Test-MxhProtocolMigrationSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PlanPath,
        [Parameter(Mandatory)] [Collections.IDictionary]$Plan,
        [Parameter(Mandatory)] [Collections.IDictionary]$State
    )

    $supported = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    if ([string]$Plan.Role -notin $supported) {
        throw '协议迁移只支持 Reality、AnyTLS 和 Shadowsocks 三种已完成角色。'
    }
    foreach ($section in @('Server', 'Ports', 'Paths', 'NetworkTuning', 'Komari')) {
        if (-not $Plan.Contains($section)) { throw "部署计划缺少 $section 段。" }
    }
    $resolvedPlan = (Resolve-Path -LiteralPath $PlanPath).Path
    $planParent = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedPlan)).TrimEnd('\', '/')
    $archive = [IO.Path]::GetFullPath([string]$Plan.Paths.Archive).TrimEnd('\', '/')
    if (-not $planParent.Equals($archive, [StringComparison]::OrdinalIgnoreCase)) {
        throw '计划文件不在其声明的实例私有归档根目录中，拒绝迁移。'
    }
    $requiredModules = @('ssh-transition', 'nftables-transition', 'final-validation', 'ssh-cutover', 'private-archive')
    $protocolModule = switch ([string]$Plan.Role) {
        'RealityEntry' { 'xray-reality' }
        'AnyTlsEntry' { 'sing-box-anytls' }
        'ShadowsocksLanding' { 'sing-box-shadowsocks' }
    }
    $requiredModules += $protocolModule
    $missing = @($requiredModules | Where-Object { -not (Test-MxhModuleSucceeded -State $State -Id $_) })
    if ($missing.Count -gt 0) {
        throw "源计划尚未完整验收，缺少成功状态：$($missing -join ', ')。请先使用继续未完成部署。"
    }
    $managementPort = [int]$State.CurrentManagementPort
    if ($managementPort -notin @([int]$Plan.Ports.SshPrimary, [int]$Plan.Ports.SshRescue)) {
        throw '当前管理端口不是计划中的 SSH 主/救援端口，拒绝自动迁移。'
    }
    $keyPath = Join-Path ([string]$Plan.Paths.KeyDirectory) 'id_ed25519'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        throw '实例专用 SSH 私钥不存在，无法安全迁移。'
    }
    foreach ($privateFile in @('deployment-state.json', 'deployment-secrets.private.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $archive $privateFile) -PathType Leaf)) {
            throw "实例私有归档缺少 $privateFile。"
        }
    }
    if ($Plan.Contains('Migration') -and [bool]$Plan.Migration.Enabled) {
        $status = [string]$Plan.Migration.Status
        if ($status -notin @('Completed', 'Committed')) {
            throw "已有未完成迁移（状态 $status），请使用继续未完成部署，不要创建第二个迁移。"
        }
    }
    return $true
}

function Test-MxhMigrationValidationEntryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PlanPath,
        [Parameter(Mandatory)] [string]$LandingServerIpv4,
        [Parameter(Mandatory)] [string[]]$AllowedEntryIpv4s
    )

    $resolved = (Resolve-Path -LiteralPath $PlanPath).Path
    $plan = Read-VpsJsonHashtable -Path $resolved
    if ([string]$plan.Role -notin @('RealityEntry', 'AnyTlsEntry')) {
        throw '外部链式探测必须选择一台已完成的 Reality 或 AnyTLS 入口计划。'
    }
    $entryIpv4 = [string]$plan.Server.IPv4
    if ($entryIpv4 -eq $LandingServerIpv4) { throw '验证入口不能就是正在转换为落地机的同一台 VPS。' }
    if ($entryIpv4 -notin $AllowedEntryIpv4s) {
        throw "验证入口 IPv4 未包含在 Shadowsocks 可信入口白名单中：$entryIpv4"
    }
    $archive = [string]$plan.Paths.Archive
    $planParent = [IO.Path]::GetFullPath((Split-Path -Parent $resolved)).TrimEnd('\', '/')
    $archiveFull = [IO.Path]::GetFullPath($archive).TrimEnd('\', '/')
    if (-not $planParent.Equals($archiveFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw '验证入口计划不在其声明的私有归档根目录中。'
    }
    $statePath = Join-Path $archive 'deployment-state.json'
    $secretsPath = Join-Path $archive 'deployment-secrets.private.json'
    $keyPath = Join-Path ([string]$plan.Paths.KeyDirectory) 'id_ed25519'
    foreach ($path in @($statePath, $secretsPath, $keyPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "验证入口归档缺少文件：$path" }
    }
    $state = Read-VpsJsonHashtable -Path $statePath
    if ([int]$state.CurrentManagementPort -notin @([int]$plan.Ports.SshPrimary, [int]$plan.Ports.SshRescue)) {
        throw '验证入口的当前管理端口不在 SSH 主/救援端口中。'
    }
    $protocolModule = if ($plan.Role -eq 'RealityEntry') { 'xray-reality' } else { 'sing-box-anytls' }
    foreach ($id in @('ssh-cutover', 'final-validation', $protocolModule)) {
        if (-not (Test-MxhModuleSucceeded -State $state -Id $id)) { throw "验证入口未完成模块：$id" }
    }
    return $true
}

function Read-MxhProtocolMigrationSource {
    [CmdletBinding()]
    param([string]$PlanPath)

    $candidatePath = $PlanPath
    while ($true) {
        if (-not $candidatePath) {
            $inputPath = Read-VpsText '现有 VPS 的 deployment-plan.json 完整路径' -AllowBack -Validate {
                param($v)
                $candidate = $v.Trim().Trim('"')
                Test-Path -LiteralPath $candidate -PathType Leaf
            } -ValidationMessage '找不到该计划文件。可输入 b 返回主菜单。'
            $candidatePath = $inputPath.Trim().Trim('"')
        }
        $candidatePath = (Resolve-Path -LiteralPath $candidatePath.Trim().Trim('"')).Path
        try {
            $plan = Read-VpsJsonHashtable -Path $candidatePath
            $archive = [string]$plan.Paths.Archive
            $state = Read-VpsJsonHashtable -Path (Join-Path $archive 'deployment-state.json')
            Test-MxhProtocolMigrationSource -PlanPath $candidatePath -Plan $plan -State $state | Out-Null
            Show-VpsPlanSummary -Plan $plan
            Write-VpsUi "当前协议：$(Get-MxhProtocolRoleLabel -Role ([string]$plan.Role))" Info
        }
        catch {
            Write-VpsUi "不能作为迁移源：$($_.Exception.Message)" Warning
            $candidatePath = $null
            continue
        }
        try {
            $choice = Read-VpsMenu '请选择迁移源操作' @(
                '使用此实例',
                '重新选择计划文件',
                '取消并返回主菜单'
            ) 1 -AllowBack
        }
        catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $choice = 2
        }
        if ($choice -eq 1) {
            return [pscustomobject]@{ PlanPath = $candidatePath; Plan = $plan; State = $state }
        }
        if ($choice -eq 3) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        $candidatePath = $null
    }
}

function New-MxhProtocolMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Collections.IDictionary]$SourcePlan,
        [Parameter(Mandatory)] [string]$SourcePlanPath,
        [Parameter(Mandatory)] [ValidateSet('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')]
        [string]$TargetRole,
        [int]$TargetServicePort,
        [string]$RealityTargetMode = 'ExternalAudited',
        [string]$RealityTarget,
        [string]$RealityServerName,
        [string]$RealityTargetAddress,
        [int]$RealityLocalHttpsPort = 8443,
        [string]$AnyTlsServerName,
        [string]$EchPublicName,
        [string[]]$AnyTlsPaddingScheme = @(),
        [bool]$ForceIpv4Egress = $true,
        [bool]$TrustedTlsEnabled = $false,
        [string]$CloudflareZoneName,
        [string]$CertbotEmail,
        [string]$CloudflareTokenFile,
        [Collections.IDictionary]$TrustedEntryIps = ([ordered]@{ IPv4 = @(); IPv6 = @() }),
        [string]$ClientTransitTag,
        [string]$ValidationEntryPlanPath,
        [bool]$SecondaryIpv6Enabled = $false,
        [string]$SecondaryIpv6Address,
        [string]$SecondaryBindInterface,
        [Collections.IDictionary]$NetworkTuning = ([ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = $null; ReferenceRttMs = $null })
    )

    $sourceRole = [string]$SourcePlan.Role
    if ($sourceRole -eq $TargetRole) { throw '源协议和目标协议不能相同。' }
    $plan = ($SourcePlan | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable
    $plan.Role = $TargetRole
    $plan['UpdatedAt'] = (Get-Date).ToString('o')
    $plan.Ports.XrayPrimary = 443
    $plan.Ports.AnyTlsPrimary = 443
    if ($TargetRole -eq 'RealityEntry') { $plan.Ports.XrayBackup = $TargetServicePort }
    if ($TargetRole -eq 'ShadowsocksLanding') { $plan.Ports.LandingShadowsocks = $TargetServicePort }

    if (-not $plan.Contains('Reality')) { $plan.Reality = [ordered]@{} }
    if ($TargetRole -eq 'RealityEntry') {
        $plan.Reality.Target = $RealityTarget
        $plan.Reality.TargetMode = $RealityTargetMode
        $plan.Reality.ServerName = $RealityServerName
        $plan.Reality.TargetAddress = $RealityTargetAddress
        $plan.Reality.LocalHttpsPort = $RealityLocalHttpsPort
        $plan.Reality.ForceIpv4Egress = $ForceIpv4Egress
    }
    if (-not $plan.Contains('AnyTls')) { $plan.AnyTls = [ordered]@{} }
    $plan.AnyTls.Enabled = ($TargetRole -eq 'AnyTlsEntry')
    if ($TargetRole -eq 'AnyTlsEntry') {
        $plan.AnyTls.ServerName = $AnyTlsServerName
        $plan.AnyTls.EchPublicName = $EchPublicName
        $plan.AnyTls.ForceIpv4Egress = $ForceIpv4Egress
        $plan.AnyTls.PaddingSchemeMode = 'PerInstanceConservativeV1'
        $plan.AnyTls.PaddingScheme = @($AnyTlsPaddingScheme)
    }
    if (-not $plan.Contains('TrustedTls')) { $plan.TrustedTls = [ordered]@{} }
    $plan.TrustedTls.Enabled = $TrustedTlsEnabled
    $plan.TrustedTls.ZoneName = $CloudflareZoneName
    $plan.TrustedTls.CertbotEmail = $CertbotEmail
    $plan.TrustedTls.CloudflareTokenFile = $CloudflareTokenFile
    if (-not $plan.TrustedTls.Contains('AnyTlsCertificateName')) { $plan.TrustedTls.AnyTlsCertificateName = 'mxh-anytls' }
    if (-not $plan.TrustedTls.Contains('RealityCertificateName')) { $plan.TrustedTls.RealityCertificateName = 'mxh-reality-target' }

    if (-not $plan.Contains('Shadowsocks')) { $plan.Shadowsocks = [ordered]@{} }
    if ($TargetRole -eq 'ShadowsocksLanding') {
        $plan.Shadowsocks.Method = '2022-blake3-aes-128-gcm'
        $plan.Shadowsocks.TrustedEntryIPv4s = @($TrustedEntryIps.IPv4)
        $plan.Shadowsocks.TrustedEntryIPv6s = @($TrustedEntryIps.IPv6)
        $plan.Shadowsocks.ClientTransitTag = $ClientTransitTag
        $plan.Shadowsocks.SecondaryIpv6Enabled = $SecondaryIpv6Enabled
        $plan.Shadowsocks.SecondaryIpv6Address = $SecondaryIpv6Address
        $plan.Shadowsocks.SecondaryBindInterface = $SecondaryBindInterface
    }
    $plan.NetworkTuning = $NetworkTuning

    $sourcePort = switch ($sourceRole) {
        'ShadowsocksLanding' { [int]$SourcePlan.Ports.LandingShadowsocks }
        default { 443 }
    }
    $targetPort = if ($TargetRole -eq 'ShadowsocksLanding') { $TargetServicePort } else { 443 }
    $moduleIds = @(Get-MxhMigrationModuleIds -TargetRole $TargetRole -RealityTargetMode $RealityTargetMode)
    $plan['Migration'] = [ordered]@{
        Enabled = $true
        SchemaVersion = 1
        Mode = 'ProtocolRoleConversion'
        SourceRole = $sourceRole
        TargetRole = $TargetRole
        SourceService = Get-MxhProtocolServiceName -Role $sourceRole
        TargetService = Get-MxhProtocolServiceName -Role $TargetRole
        SourcePrimaryPort = $sourcePort
        TargetPrimaryPort = $targetPort
        ValidationEntryPlanPath = if ($TargetRole -eq 'ShadowsocksLanding') { $ValidationEntryPlanPath } else { $null }
        SourcePlanPath = (Resolve-Path -LiteralPath $SourcePlanPath).Path
        SourcePlanSha256 = (Get-FileHash -LiteralPath $SourcePlanPath -Algorithm SHA256).Hash
        RollbackTimeoutMinutes = 20
        ModuleIds = $moduleIds
        Status = 'Planned'
        CreatedAt = (Get-Date).ToString('o')
        LocalBackupDirectory = $null
    }
    return $plan
}

function New-MxhProtocolMigrationDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [string]$ProjectRoot
    )

    $versions = Get-VpsVersions -ProjectRoot $ProjectRoot
    $sourcePlan = $Source.Plan
    $sourceRole = [string]$sourcePlan.Role
    $allRoles = @('RealityEntry', 'AnyTlsEntry', 'ShadowsocksLanding')
    $targetRoles = @($allRoles | Where-Object { $_ -ne $sourceRole })
    $preferredTarget = if ($sourceRole -eq 'RealityEntry') { 'AnyTlsEntry' } else { 'RealityEntry' }
    if ($preferredTarget -notin $targetRoles) { $preferredTarget = $targetRoles[0] }

    $sourceActivePorts = @([int]$sourcePlan.Ports.SshPrimary, [int]$sourcePlan.Ports.SshRescue, 443)
    if ($sourceRole -eq 'RealityEntry' -and $sourcePlan.Ports.Contains('XrayBackup') -and $sourcePlan.Ports.XrayBackup) {
        $sourceActivePorts += [int]$sourcePlan.Ports.XrayBackup
    }
    if ($sourceRole -eq 'ShadowsocksLanding' -and $sourcePlan.Ports.Contains('LandingShadowsocks') -and $sourcePlan.Ports.LandingShadowsocks) {
        $sourceActivePorts += [int]$sourcePlan.Ports.LandingShadowsocks
    }
    $sourceActivePorts = @($sourceActivePorts | Sort-Object -Unique)

    $priorXrayBackup = if ($sourcePlan.Ports.Contains('XrayBackup') -and $sourcePlan.Ports.XrayBackup) { [int]$sourcePlan.Ports.XrayBackup } else { 0 }
    $xrayBackup = if ($priorXrayBackup -ge 20000 -and $priorXrayBackup -le 59999 -and $priorXrayBackup -notin $sourceActivePorts) {
        $priorXrayBackup
    } else { Get-VpsRandomPort -Exclude $sourceActivePorts }
    $portExclusions = @($sourceActivePorts + $xrayBackup | Sort-Object -Unique)
    $priorLandingPort = if ($sourcePlan.Ports.Contains('LandingShadowsocks') -and $sourcePlan.Ports.LandingShadowsocks) { [int]$sourcePlan.Ports.LandingShadowsocks } else { 0 }
    $landingPort = if ($priorLandingPort -ge 20000 -and $priorLandingPort -le 59999 -and $priorLandingPort -notin $sourceActivePorts) {
        $priorLandingPort
    } else { Get-VpsRandomPort -Exclude $portExclusions }

    $realityMode = if ($sourcePlan.Contains('Reality') -and $sourcePlan.Reality.Contains('TargetMode')) {
        [string]$sourcePlan.Reality.TargetMode
    } else { 'ExternalAudited' }
    $realityTarget = if ($sourcePlan.Contains('Reality') -and $sourcePlan.Reality.Contains('Target')) { [string]$sourcePlan.Reality.Target } else { $null }
    $anyTlsPadding = if ($sourcePlan.Contains('AnyTls') -and $sourcePlan.AnyTls.Contains('PaddingScheme') -and @($sourcePlan.AnyTls.PaddingScheme).Count -gt 0) {
        @($sourcePlan.AnyTls.PaddingScheme)
    } else { @(New-MxhAnyTlsPaddingScheme) }
    $allowlistInput = if ($sourcePlan.Contains('Shadowsocks') -and
        $sourcePlan.Shadowsocks.Contains('TrustedEntryIPv4s') -and $sourcePlan.Shadowsocks.Contains('TrustedEntryIPv6s')) {
        (@($sourcePlan.Shadowsocks.TrustedEntryIPv4s) + @($sourcePlan.Shadowsocks.TrustedEntryIPv6s)) -join ','
    } else { $null }
    $trustedEntryIps = if ($allowlistInput) { ConvertTo-VpsIpAllowlist $allowlistInput } else { [ordered]@{ IPv4 = @(); IPv6 = @() } }
    $sourceAdaptive = $sourcePlan.Contains('NetworkTuning') -and $sourcePlan.NetworkTuning.Mode -eq 'AdaptiveConservative'

    $wizard = [ordered]@{
        TargetRole = $preferredTarget
        XrayBackup = $xrayBackup
        LandingPort = $landingPort
        RealityTargetMode = $realityMode
        RealityTarget = $realityTarget
        ForceIpv4 = if ($sourcePlan.Contains('Reality') -and $sourcePlan.Reality.Contains('ForceIpv4Egress')) { [bool]$sourcePlan.Reality.ForceIpv4Egress } elseif ($sourcePlan.Contains('AnyTls') -and $sourcePlan.AnyTls.Contains('ForceIpv4Egress')) { [bool]$sourcePlan.AnyTls.ForceIpv4Egress } else { $true }
        AnyTlsServerName = if ($sourcePlan.Contains('AnyTls') -and $sourcePlan.AnyTls.Contains('ServerName')) { [string]$sourcePlan.AnyTls.ServerName } else { $null }
        EchPublicName = if ($sourcePlan.Contains('AnyTls') -and $sourcePlan.AnyTls.Contains('EchPublicName')) { [string]$sourcePlan.AnyTls.EchPublicName } else { $null }
        AnyTlsPaddingScheme = $anyTlsPadding
        CloudflareZoneName = if ($sourcePlan.Contains('TrustedTls') -and $sourcePlan.TrustedTls.Contains('ZoneName')) { [string]$sourcePlan.TrustedTls.ZoneName } else { $null }
        CertbotEmail = if ($sourcePlan.Contains('TrustedTls') -and $sourcePlan.TrustedTls.Contains('CertbotEmail')) { [string]$sourcePlan.TrustedTls.CertbotEmail } else { $null }
        CloudflareTokenFile = if ($sourcePlan.Contains('TrustedTls') -and $sourcePlan.TrustedTls.Contains('CloudflareTokenFile')) { [string]$sourcePlan.TrustedTls.CloudflareTokenFile } else { $null }
        AllowlistInput = $allowlistInput
        TrustedEntryIps = $trustedEntryIps
        ClientTransitTag = if ($sourcePlan.Contains('Shadowsocks') -and $sourcePlan.Shadowsocks.Contains('ClientTransitTag') -and $sourcePlan.Shadowsocks.ClientTransitTag) { [string]$sourcePlan.Shadowsocks.ClientTransitTag } else { 'US-West Entry' }
        ValidationEntryPlanPath = $null
        SecondaryIpv6Enabled = if ($sourcePlan.Contains('Shadowsocks') -and $sourcePlan.Shadowsocks.Contains('SecondaryIpv6Enabled')) { [bool]$sourcePlan.Shadowsocks.SecondaryIpv6Enabled } else { $false }
        SecondaryIpv6Address = if ($sourcePlan.Contains('Shadowsocks') -and $sourcePlan.Shadowsocks.Contains('SecondaryIpv6Address')) { [string]$sourcePlan.Shadowsocks.SecondaryIpv6Address } else { $null }
        SecondaryBindInterface = if ($sourcePlan.Contains('Shadowsocks') -and $sourcePlan.Shadowsocks.Contains('SecondaryBindInterface')) { [string]$sourcePlan.Shadowsocks.SecondaryBindInterface } else { $null }
        NetworkAdaptive = $sourceAdaptive
        BandwidthMbps = if ($sourceAdaptive) { [int]$sourcePlan.NetworkTuning.BandwidthMbps } else { $null }
        ReferenceRttMs = if ($sourceAdaptive) { [int]$sourcePlan.NetworkTuning.ReferenceRttMs } else { $null }
    }

    $steps = @(
        [pscustomobject]@{
            Id = 'target-role'; ShouldRun = { $true }; Run = {
                $labels = @($targetRoles | ForEach-Object { Get-MxhProtocolRoleLabel -Role $_ })
                $default = [Array]::IndexOf($targetRoles, [string]$wizard.TargetRole) + 1
                if ($default -lt 1) { $default = 1 }
                $choice = Read-VpsMenu '迁移到哪一种协议角色' $labels $default -AllowBack
                $newRole = $targetRoles[$choice - 1]
                if ($wizard.TargetRole -ne $newRole) {
                    $wizard.TargetRole = $newRole
                    $wizard.NetworkAdaptive = $sourceAdaptive
                    $wizard.BandwidthMbps = if ($sourceAdaptive) { [int]$sourcePlan.NetworkTuning.BandwidthMbps } else { $null }
                    $wizard.ReferenceRttMs = if ($sourceAdaptive) { [int]$sourcePlan.NetworkTuning.ReferenceRttMs } else { $null }
                }
            }
        },
        [pscustomobject]@{
            Id = 'xray-backup'; ShouldRun = { $wizard.TargetRole -eq 'RealityEntry' }; Run = {
                $wizard.XrayBackup = [int](Read-VpsText '新的 Xray 救援端口' -Default ([string]$wizard.XrayBackup) -AllowBack -Validate {
                    param($v)
                    $n = 0
                    [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin $sourceActivePorts
                } -ValidationMessage '端口必须在 20000–59999，且不能与当前仍在运行的服务或 SSH 端口冲突。')
            }
        },
        [pscustomobject]@{
            Id = 'reality-target-mode'; ShouldRun = { $wizard.TargetRole -eq 'RealityEntry' }; Run = {
                $default = if ($wizard.RealityTargetMode -eq 'LocalOwnedTls') { 2 } else { 1 }
                $choice = Read-VpsMenu 'REALITY target 模式' @(
                    '外部大学/机构/企业 target（严格审计）',
                    '自有域名 + 本机静态 HTTPS target'
                ) $default -AllowBack
                $newMode = if ($choice -eq 2) { 'LocalOwnedTls' } else { 'ExternalAudited' }
                if ($wizard.RealityTargetMode -ne $newMode) {
                    $wizard.RealityTargetMode = $newMode
                    $wizard.RealityTarget = $null
                    $wizard.CloudflareZoneName = $null
                    $wizard.CertbotEmail = $null
                    $wizard.CloudflareTokenFile = $null
                }
            }
        },
        [pscustomobject]@{
            Id = 'reality-target'; ShouldRun = { $wizard.TargetRole -eq 'RealityEntry' }; Run = {
                $prompt = if ($wizard.RealityTargetMode -eq 'LocalOwnedTls') { '本机 HTTPS target 域名' } else { 'REALITY 外部 target 域名' }
                $wizard.RealityTarget = Read-VpsText $prompt -Default ([string]$wizard.RealityTarget) -AllowBack `
                    -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入不含协议、路径和端口的规范域名。'
            }
        },
        [pscustomobject]@{
            Id = 'reality-target-confirm'; ShouldRun = { $wizard.TargetRole -eq 'RealityEntry' -and $wizard.RealityTargetMode -eq 'ExternalAudited' }; Run = {
                if (-not (Read-VpsYesNo '确认该候选不是个人小站，并允许从 VPS 严格审计？' $true -AllowBack)) {
                    throw [InvalidOperationException]::new($script:VpsWizardBackMarker)
                }
            }
        },
        [pscustomobject]@{
            Id = 'anytls-server-name'; ShouldRun = { $wizard.TargetRole -eq 'AnyTlsEntry' }; Run = {
                $wizard.AnyTlsServerName = Read-VpsText 'AnyTLS 证书域名/内部 SNI' -Default ([string]$wizard.AnyTlsServerName) -AllowBack `
                    -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入规范域名。'
            }
        },
        [pscustomobject]@{
            Id = 'ech-public-name'; ShouldRun = { $wizard.TargetRole -eq 'AnyTlsEntry' }; Run = {
                $wizard.EchPublicName = Read-VpsText 'ECH 对外 public name' -Default ([string]$wizard.EchPublicName) -AllowBack -Validate {
                    param($v) (Test-VpsHostName $v) -and $v -ne $wizard.AnyTlsServerName
                } -ValidationMessage '请输入与 AnyTLS 内部 SNI 不同的规范域名。'
            }
        },
        [pscustomobject]@{
            Id = 'force-ipv4'; ShouldRun = { $wizard.TargetRole -in @('RealityEntry', 'AnyTlsEntry') }; Run = {
                $wizard.ForceIpv4 = Read-VpsYesNo '是否强制代理网站流量从 VPS IPv4 出口？' ([bool]$wizard.ForceIpv4) -AllowBack
            }
        },
        [pscustomobject]@{
            Id = 'cloudflare-zone'; ShouldRun = {
                $wizard.TargetRole -eq 'AnyTlsEntry' -or ($wizard.TargetRole -eq 'RealityEntry' -and $wizard.RealityTargetMode -eq 'LocalOwnedTls')
            }; Run = {
                $domain = if ($wizard.TargetRole -eq 'AnyTlsEntry') { [string]$wizard.AnyTlsServerName } else { [string]$wizard.RealityTarget }
                $labels = @($domain -split '\.')
                $suggested = if ($labels.Count -ge 2) { ($labels[-2..-1] -join '.') } else { $domain }
                $default = if ($wizard.CloudflareZoneName) { [string]$wizard.CloudflareZoneName } else { $suggested }
                $wizard.CloudflareZoneName = Read-VpsText 'Cloudflare Zone 根域名' -Default $default -AllowBack `
                    -Validate ${function:Test-VpsHostName} -ValidationMessage '请输入 Cloudflare 中的完整根域名。'
            }
        },
        [pscustomobject]@{
            Id = 'certbot-email'; ShouldRun = {
                $wizard.TargetRole -eq 'AnyTlsEntry' -or ($wizard.TargetRole -eq 'RealityEntry' -and $wizard.RealityTargetMode -eq 'LocalOwnedTls')
            }; Run = {
                $wizard.CertbotEmail = Read-VpsText 'ACME/Let''s Encrypt 联系邮箱' -Default ([string]$wizard.CertbotEmail) -AllowBack -Validate {
                    param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                } -ValidationMessage '请输入有效邮箱地址。'
            }
        },
        [pscustomobject]@{
            Id = 'cloudflare-token'; ShouldRun = {
                $wizard.TargetRole -eq 'AnyTlsEntry' -or ($wizard.TargetRole -eq 'RealityEntry' -and $wizard.RealityTargetMode -eq 'LocalOwnedTls')
            }; Run = {
                $default = if ($wizard.CloudflareTokenFile) { [string]$wizard.CloudflareTokenFile } else {
                    Join-Path ([string]$sourcePlan.Paths.Archive) 'cloudflare-certbot-token.private.txt'
                }
                $value = Read-VpsText 'Cloudflare Certbot Token 本地私有文件' -Default $default -AllowBack `
                    -Validate { param($v) Test-Path -LiteralPath $v -PathType Leaf } `
                    -ValidationMessage '找不到 Token 文件。'
                $wizard.CloudflareTokenFile = (Resolve-Path -LiteralPath $value).Path
            }
        },
        [pscustomobject]@{
            Id = 'landing-port'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' }; Run = {
                $wizard.LandingPort = [int](Read-VpsText 'Shadowsocks TCP/UDP 端口' -Default ([string]$wizard.LandingPort) -AllowBack -Validate {
                    param($v)
                    $n = 0
                    [int]::TryParse($v, [ref]$n) -and $n -ge 20000 -and $n -le 59999 -and $n -notin $sourceActivePorts
                } -ValidationMessage '端口必须在 20000–59999，且不能与当前仍在运行的服务或 SSH 端口冲突。')
            }
        },
        [pscustomobject]@{
            Id = 'landing-allowlist'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' }; Run = {
                while ($true) {
                    try {
                        $value = Read-VpsText '允许连接落地端口的入口 VPS 公网 IP（多个用逗号分隔）' `
                            -Default ([string]$wizard.AllowlistInput) -AllowBack
                        $wizard.TrustedEntryIps = ConvertTo-VpsIpAllowlist $value
                        $wizard.AllowlistInput = $value
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
            Id = 'landing-transit-tag'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' }; Run = {
                $wizard.ClientTransitTag = Read-VpsText '客户端链式连接使用的入口组/tag' -Default ([string]$wizard.ClientTransitTag) -AllowBack -Validate {
                    param($v) -not [string]::IsNullOrWhiteSpace($v) -and $v -notin @('Proxy', "$($sourcePlan.NodeName)-IPv4", "$($sourcePlan.NodeName)-IPv6")
                } -ValidationMessage '入口组/tag 不能与生成的落地节点名称重复。'
            }
        },
        [pscustomobject]@{
            Id = 'landing-validation-entry'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' }; Run = {
                while ($true) {
                    try {
                        $value = Read-VpsText '用于链式实测的入口 VPS deployment-plan.json' `
                            -Default ([string]$wizard.ValidationEntryPlanPath) -AllowBack -Validate {
                                param($v) Test-Path -LiteralPath $v.Trim().Trim('"') -PathType Leaf
                            } -ValidationMessage '找不到该入口计划文件。'
                        $resolved = (Resolve-Path -LiteralPath $value.Trim().Trim('"')).Path
                        Test-MxhMigrationValidationEntryPlan -PlanPath $resolved `
                            -LandingServerIpv4 ([string]$sourcePlan.Server.IPv4) `
                            -AllowedEntryIpv4s @($wizard.TrustedEntryIps.IPv4) | Out-Null
                        $wizard.ValidationEntryPlanPath = $resolved
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
            Id = 'secondary-ipv6-enabled'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' -and [bool]$sourcePlan.Server.IPv6 }; Run = {
                $wizard.SecondaryIpv6Enabled = Read-VpsYesNo '是否增加独立 IPv6 出口用户？' ([bool]$wizard.SecondaryIpv6Enabled) -AllowBack
                if (-not $wizard.SecondaryIpv6Enabled) {
                    $wizard.SecondaryIpv6Address = $null
                    $wizard.SecondaryBindInterface = $null
                }
            }
        },
        [pscustomobject]@{
            Id = 'secondary-ipv6-address'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' -and [bool]$sourcePlan.Server.IPv6 -and [bool]$wizard.SecondaryIpv6Enabled }; Run = {
                $default = if ($wizard.SecondaryIpv6Address) { [string]$wizard.SecondaryIpv6Address } else { [string]$sourcePlan.Server.IPv6 }
                $wizard.SecondaryIpv6Address = Read-VpsText 'IPv6 出口源地址' -Default $default -AllowBack `
                    -Validate { param($v) Test-VpsIpAddress $v IPv6 } -ValidationMessage '请输入本机实际配置的 IPv6 地址。'
            }
        },
        [pscustomobject]@{
            Id = 'secondary-bind-interface'; ShouldRun = { $wizard.TargetRole -eq 'ShadowsocksLanding' -and [bool]$sourcePlan.Server.IPv6 -and [bool]$wizard.SecondaryIpv6Enabled }; Run = {
                $value = Read-VpsText 'IPv6 出口接口（一般留空）' -Default ([string]$wizard.SecondaryBindInterface) -AllowEmpty -AllowBack `
                    -Validate { param($v) -not $v -or $v -match '^[A-Za-z0-9_.:-]{1,32}$' }
                $wizard.SecondaryBindInterface = if ($value) { $value } else { $null }
            }
        },
        [pscustomobject]@{
            Id = 'network-adaptive'; ShouldRun = { $true }; Run = {
                $wizard.NetworkAdaptive = Read-VpsYesNo '是否为目标角色重新应用保守自适应网络调优？' ([bool]$wizard.NetworkAdaptive) -AllowBack
                if (-not $wizard.NetworkAdaptive) {
                    $wizard.BandwidthMbps = $null
                    $wizard.ReferenceRttMs = $null
                }
            }
        },
        [pscustomobject]@{
            Id = 'network-bandwidth'; ShouldRun = { [bool]$wizard.NetworkAdaptive }; Run = {
                $wizard.BandwidthMbps = [int](Read-VpsText '套餐标称带宽（Mbps）' -Default ([string]$wizard.BandwidthMbps) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 100000
                } -ValidationMessage '请输入 1–100000 之间的整数 Mbps。')
            }
        },
        [pscustomobject]@{
            Id = 'network-rtt'; ShouldRun = { [bool]$wizard.NetworkAdaptive }; Run = {
                $prompt = if ($wizard.TargetRole -in @('RealityEntry', 'AnyTlsEntry')) { '主要使用地到该入口 VPS 的典型 RTT（ms）' } else { '常用入口 VPS 到该落地机的典型 RTT（ms）' }
                $wizard.ReferenceRttMs = [int](Read-VpsText $prompt -Default ([string]$wizard.ReferenceRttMs) -AllowBack -Validate {
                    param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 2000
                } -ValidationMessage '请输入 1–2000 之间的整数毫秒值。')
            }
        }
    )

    $buildPlan = {
        $trustedTls = $wizard.TargetRole -eq 'AnyTlsEntry' -or `
            ($wizard.TargetRole -eq 'RealityEntry' -and $wizard.RealityTargetMode -eq 'LocalOwnedTls')
        $network = if ($wizard.NetworkAdaptive) {
            [ordered]@{ Mode = 'AdaptiveConservative'; BandwidthMbps = [int]$wizard.BandwidthMbps; ReferenceRttMs = [int]$wizard.ReferenceRttMs }
        } else { [ordered]@{ Mode = 'BaselineOnly'; BandwidthMbps = $null; ReferenceRttMs = $null } }
        $targetPort = if ($wizard.TargetRole -eq 'RealityEntry') { [int]$wizard.XrayBackup } elseif ($wizard.TargetRole -eq 'ShadowsocksLanding') { [int]$wizard.LandingPort } else { 443 }
        $realityServerName = if ($wizard.TargetRole -eq 'RealityEntry') { [string]$wizard.RealityTarget } else { $null }
        $realityAddress = if ($wizard.TargetRole -eq 'RealityEntry' -and $wizard.RealityTargetMode -eq 'LocalOwnedTls') {
            '127.0.0.1:8443'
        } elseif ($wizard.TargetRole -eq 'RealityEntry') { "$($wizard.RealityTarget):443" } else { $null }
        New-MxhProtocolMigrationPlan -SourcePlan $sourcePlan -SourcePlanPath $Source.PlanPath `
            -TargetRole $wizard.TargetRole -TargetServicePort $targetPort `
            -RealityTargetMode $wizard.RealityTargetMode -RealityTarget $wizard.RealityTarget `
            -RealityServerName $realityServerName -RealityTargetAddress $realityAddress `
            -AnyTlsServerName $wizard.AnyTlsServerName -EchPublicName $wizard.EchPublicName `
            -AnyTlsPaddingScheme @($wizard.AnyTlsPaddingScheme) -ForceIpv4Egress ([bool]$wizard.ForceIpv4) `
            -TrustedTlsEnabled $trustedTls -CloudflareZoneName $wizard.CloudflareZoneName `
            -CertbotEmail $wizard.CertbotEmail -CloudflareTokenFile $wizard.CloudflareTokenFile `
            -TrustedEntryIps $wizard.TrustedEntryIps -ClientTransitTag $wizard.ClientTransitTag `
            -ValidationEntryPlanPath $wizard.ValidationEntryPlanPath `
            -SecondaryIpv6Enabled ([bool]$wizard.SecondaryIpv6Enabled) `
            -SecondaryIpv6Address $wizard.SecondaryIpv6Address -SecondaryBindInterface $wizard.SecondaryBindInterface `
            -NetworkTuning $network
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
                Write-VpsUi "返回迁移上一项：$($steps[$previous].Id)" Muted
            }
        }

        $plan = & $buildPlan
        Write-Host ''
        Write-Host '协议迁移摘要' -ForegroundColor White
        Write-Host "  实例：$($plan.Provider) / $($plan.Instance)"
        Write-Host "  源协议：$(Get-MxhProtocolRoleLabel -Role $sourceRole)"
        Write-Host "  目标协议：$(Get-MxhProtocolRoleLabel -Role ([string]$plan.Role))"
        Write-Host "  SSH：保留 $($plan.Ports.SshPrimary) + $($plan.Ports.SshRescue)"
        Write-Host "  自动回滚：切换后 20 分钟内未完成验收则恢复源服务和旧 nftables"
        Show-VpsPlanSummary -Plan $plan
        try {
            $choice = Read-VpsMenu '请核对迁移方案' @(
                '确认并进入迁移模块计划',
                '返回修改上一项',
                '取消并返回主菜单'
            ) 1 -AllowBack
        }
        catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $choice = 2
        }
        if ($choice -eq 1) { return [pscustomobject]@{ Plan = $plan; Source = $Source } }
        if ($choice -eq 3) { throw [OperationCanceledException]::new($script:VpsWizardCancelMarker) }
        for ($candidate = $steps.Count - 1; $candidate -ge 0; $candidate--) {
            if (& $steps[$candidate].ShouldRun) { $index = $candidate; break }
        }
    }
}

function New-VpsProtocolMigrationPlanInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [string]$PlanPath
    )

    $candidatePath = $PlanPath
    while ($true) {
        $source = Read-MxhProtocolMigrationSource -PlanPath $candidatePath
        try { return New-MxhProtocolMigrationDetails -Source $source -ProjectRoot $ProjectRoot }
        catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $candidatePath = $null
            Write-VpsUi '已返回迁移源计划选择。' Info
        }
    }
}

function Initialize-MxhProtocolMigrationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] $MigrationResult,
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    $plan = $MigrationResult.Plan
    $source = $MigrationResult.Source
    $archive = [IO.Path]::GetFullPath([string]$plan.Paths.Archive)
    if ($DryRun) {
        $context = Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan -DryRun -NonInteractive:$NonInteractive
        $context.State = ($source.State | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable
        $context.State['Migration'] = [ordered]@{
            Status = 'DryRun'
            RollbackArmed = $false
            Committed = $false
        }
        return $context
    }

    $statePath = Join-Path $archive 'deployment-state.json'
    $secretsPath = Join-Path $archive 'deployment-secrets.private.json'
    $freshSourcePlan = Read-VpsJsonHashtable -Path $source.PlanPath
    $state = Read-VpsJsonHashtable -Path $statePath
    Test-MxhProtocolMigrationSource -PlanPath $source.PlanPath -Plan $freshSourcePlan -State $state | Out-Null
    $freshHash = (Get-FileHash -LiteralPath $source.PlanPath -Algorithm SHA256).Hash
    if ($freshHash -ne [string]$plan.Migration.SourcePlanSha256) {
        throw '源部署计划在迁移向导确认后发生变化，拒绝覆盖；请重新进入迁移向导。'
    }
    $secrets = Read-VpsJsonHashtable -Path $secretsPath
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backupRoot = Join-Path $archive 'migration-backups'
    $backupDirectory = Join-Path $backupRoot ("$stamp-$($plan.Migration.SourceRole)-to-$($plan.Migration.TargetRole)")
    $resolvedBackup = [IO.Path]::GetFullPath($backupDirectory)
    $archivePrefix = $archive.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedBackup.StartsWith($archivePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '迁移备份目录越出实例私有归档，拒绝继续。'
    }
    [IO.Directory]::CreateDirectory($resolvedBackup) | Out-Null
    foreach ($name in @('deployment-plan.json', 'deployment-state.json', 'deployment-secrets.private.json')) {
        $sourceFile = Join-Path $archive $name
        if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
            $destination = Join-Path $resolvedBackup $name
            Copy-Item -LiteralPath $sourceFile -Destination $destination
            Protect-VpsPrivateFile -Path $destination
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $archive -Filter '*-final-archive.txt' -File -ErrorAction SilentlyContinue)) {
        $destination = Join-Path $resolvedBackup $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        Protect-VpsPrivateFile -Path $destination
    }
    foreach ($directoryName in @('server-configs', 'client-exports')) {
        $sourceDirectory = Join-Path $archive $directoryName
        if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
            Copy-Item -LiteralPath $sourceDirectory -Destination (Join-Path $resolvedBackup $directoryName) -Recurse
        }
    }

    $plan.Migration.LocalBackupDirectory = $resolvedBackup
    $state['Migration'] = [ordered]@{
        Status = 'Planned'
        SourceRole = [string]$plan.Migration.SourceRole
        TargetRole = [string]$plan.Migration.TargetRole
        LocalBackupDirectory = $resolvedBackup
        RollbackArmed = $false
        Committed = $false
        StartedAt = (Get-Date).ToString('o')
    }
    foreach ($id in @($plan.Migration.ModuleIds)) {
        if ($state.Modules.Contains([string]$id)) { $state.Modules.Remove([string]$id) }
    }
    Save-VpsJson -Value $plan -Path (Join-Path $archive 'deployment-plan.json') -Private
    Save-VpsJson -Value $state -Path $statePath -Private
    Save-VpsJson -Value $secrets -Path $secretsPath -Private
    return Initialize-VpsContext -ProjectRoot $ProjectRoot -Plan $plan -NonInteractive:$NonInteractive
}

function New-MxhReadonlyContextFromPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$PlanPath
    )

    $plan = Read-VpsJsonHashtable -Path $PlanPath
    $archive = [string]$plan.Paths.Archive
    $state = Read-VpsJsonHashtable -Path (Join-Path $archive 'deployment-state.json')
    $secrets = Read-VpsJsonHashtable -Path (Join-Path $archive 'deployment-secrets.private.json')
    return [pscustomobject]@{
        ProjectRoot = $ProjectRoot
        Plan = $plan
        ArchivePath = $archive
        PlanPath = $PlanPath
        SecretsPath = (Join-Path $archive 'deployment-secrets.private.json')
        StatePath = (Join-Path $archive 'deployment-state.json')
        LogPath = (Join-Path $archive 'deployment.log')
        Secrets = $secrets
        State = $state
        DryRun = $true
        NonInteractive = $true
        Versions = (Get-VpsVersions -ProjectRoot $ProjectRoot)
    }
}

function Invoke-MxhProtocolMigrationRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$Reason
    )

    if (-not $Context.Plan.Contains('Migration') -or -not [bool]$Context.Plan.Migration.Enabled) { return }
    if (-not $Context.State.Contains('Migration')) { return }
    if (-not [bool]$Context.State.Migration.RollbackArmed -or [bool]$Context.State.Migration.Committed) { return }

    Write-VpsUi '迁移失败，正在立即触发源协议与旧 nftables 回滚；若 SSH 暂时不可达，服务器端计时器仍会自动执行。' Warning
    try {
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-trigger-rollback.sh' -Parameters @{
            SOURCE_ROLE = [string]$Context.Plan.Migration.SourceRole
        } -TimeoutSeconds 180
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_ROLLBACK_OK') { throw '远端未返回回滚成功标记。' }
        $Context.State.Migration.Status = 'RolledBack'
        $Context.State.Migration.RollbackArmed = $false
        $Context.State.Migration.RolledBackAt = (Get-Date).ToString('o')
        $Context.State.Migration.LastError = $Reason
        $Context.Plan.Migration.Status = 'RolledBack'
        Write-VpsUi '源协议服务和旧防火墙已恢复。可修复原因后使用 Resume 重试迁移。' Success
    }
    catch {
        $Context.State.Migration.Status = 'RollbackPending'
        $Context.State.Migration.LastError = $Reason
        $Context.State.Migration.RollbackError = $_.Exception.Message
        $Context.Plan.Migration.Status = 'RollbackPending'
        Write-VpsUi '立即回滚未能确认；请等待最多 20 分钟让 VPS 端独立计时器恢复源协议。' Error
    }
    finally {
        $modules = @(Get-VpsModules -ProjectRoot $Context.ProjectRoot)
        foreach ($module in $modules) {
            if ($module.Id -eq 'migration-preflight' -or ([int]$module.Order -ge 49 -and $module.Id -in @($Context.Plan.Migration.ModuleIds))) {
                if ($Context.State.Modules.Contains([string]$module.Id)) { $Context.State.Modules.Remove([string]$module.Id) }
            }
        }
        Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
        Save-VpsContext -Context $Context
    }
}
