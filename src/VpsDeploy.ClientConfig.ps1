function Get-MxhClientLayoutTemplate {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $local = Join-Path $ProjectRoot 'config\client-layout.local.json'
    $path = if (Test-Path -LiteralPath $local -PathType Leaf) { $local } else { Join-Path $ProjectRoot 'config\client-layout.default.json' }
    return [pscustomobject]@{ Path = $path; Value = (Read-VpsJsonHashtable -Path $path) }
}

function Read-MxhOrderedNames {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Allowed,
        [string[]]$Default = @(),
        [switch]$AllowEmpty
    )
    $defaultText = @($Default | Where-Object { $_ -in $Allowed }) -join ', '
    while ($true) {
        $text = Read-VpsText $Prompt -Default $defaultText -AllowEmpty:$AllowEmpty -AllowBack
        $items = @($text -split '[,;，]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $duplicates = @($items | Group-Object | Where-Object Count -gt 1)
        $unknown = @($items | Where-Object { $_ -notin $Allowed })
        if ($duplicates) { Write-VpsUi '列表中不能出现重复项。' Warning; continue }
        if ($unknown) { Write-VpsUi "列表包含未知项：$($unknown -join ', ')" Warning; continue }
        if (-not $items.Count -and -not $AllowEmpty) { Write-VpsUi '至少选择一项。' Warning; continue }
        return $items
    }
}

function Read-MxhRegionGroups {
    param([Parameter(Mandatory)][string[]]$Defaults)
    if (-not (Read-VpsYesNo '是否新增、重命名或彻底重排地区入口组？' $false -AllowBack)) {
        return Read-MxhOrderedNames '本次启用哪些默认地区入口组（逗号分隔并按显示顺序排列）' -Allowed $Defaults -Default $Defaults
    }
    while ($true) {
        $raw = Read-VpsText '地区入口组名称（逗号分隔，例如 US-West Entry, Hong Kong Entry）' -Default ($Defaults -join ', ') -AllowBack
        $items = @($raw -split '[,;，]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($items.Count -lt 1 -or $items.Count -gt 12) { Write-VpsUi '地区入口组数量必须在 1–12 之间。' Warning; continue }
        if (@($items | Group-Object | Where-Object Count -gt 1)) { Write-VpsUi '地区入口组不能重名。' Warning; continue }
        if (@($items | Where-Object { $_.Length -gt 80 -or $_ -match '[\r\n]' -or $_ -in @('DIRECT','REJECT','BLOCK') })) {
            Write-VpsUi '地区入口组名称无效或与保留 tag 冲突。' Warning; continue
        }
        return $items
    }
}

function Read-MxhSecretText {
    param([Parameter(Mandatory)][string]$Prompt,[switch]$AllowBack)
    while ($true) {
        $hint = if($AllowBack){'（隐藏输入；输入 b 返回）'}else{'（隐藏输入）'}
        $secure = Read-Host ($Prompt+$hint) -AsSecureString
        try { $value = ConvertFrom-VpsSecureString $secure }
        finally { $secure.Dispose() }
        if(Test-VpsClearCommand $value){Clear-VpsScreen;continue}
        if($AllowBack -and $value.Trim().Equals('b',[StringComparison]::OrdinalIgnoreCase)){throw [InvalidOperationException]::new($script:VpsWizardBackMarker)}
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-VpsUi '该敏感项不能为空。' Warning
    }
}

function Read-MxhIndexSelection {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Count,
        [switch]$AllowEmpty
    )
    while ($true) {
        $raw = Read-VpsText $Prompt -AllowEmpty:$AllowEmpty -AllowBack
        if (-not $raw -and $AllowEmpty) { return @() }
        try {
            return @($raw -split '[,;，\s]+' | Where-Object { $_ } | ForEach-Object {
                    $number = 0
                    if (-not [int]::TryParse($_, [ref]$number) -or $number -lt 1 -or $number -gt $Count) {
                        throw "编号不在 1–$Count 范围内：$_"
                    }
                    $number - 1
                } | Sort-Object -Unique)
        }
        catch { Write-VpsUi $_.Exception.Message Warning }
    }
}

function Get-MxhManagedClientPlans {
    param([Parameter(Mandatory)][string]$InstanceRoot)
    if (-not (Test-Path -LiteralPath $InstanceRoot -PathType Container)) { return @() }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $InstanceRoot -Filter deployment-plan.json -File -Recurse -ErrorAction SilentlyContinue) {
        if ($file.FullName -match '[\\/](maintenance-backups|migration-backups|client-candidates|decommission-client-candidate)[\\/]') { continue }
        try {
            $plan = Read-VpsJsonHashtable -Path $file.FullName
            if (-not $plan.Contains('NodeName') -or -not $plan.Contains('Paths')) { continue }
            $result.Add([pscustomobject]@{ Path = $file.FullName; Plan = $plan })
        }
        catch { Write-VpsUi "跳过无法解析的计划：$($file.FullName)" Warning }
    }
    return @($result | Sort-Object { $_.Plan.Provider }, { $_.Plan.Instance })
}

function Read-MxhPlanSelection {
    param([object[]]$Plans)
    if (-not $Plans.Count) { Write-VpsUi '没有发现已纳管计划；仍可手动添加节点。' Info; return @() }
    Write-Host ''
    Write-Host '可提取的已纳管 VPS：' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Plans.Count; $i++) {
        Write-Host ("  {0}. {1} / {2} / {3}" -f ($i + 1), $Plans[$i].Plan.Provider, $Plans[$i].Plan.Instance, $Plans[$i].Plan.NodeName)
    }
    $indexes = @(Read-MxhIndexSelection '输入要提取的编号（逗号分隔；留空跳过）' $Plans.Count -AllowEmpty)
    return @($indexes | ForEach-Object { $Plans[$_] })
}

function Get-MxhFragmentNodeNames {
    param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Role)
    $name = switch ($Role) {
        RealityEntry { 'sing-box-outbounds.private.json' }
        AnyTlsEntry { 'sing-box-anytls-outbounds.private.json' }
        ShadowsocksLanding { 'sing-box-shadowsocks-outbounds.private.json' }
    }
    $path = Join-Path $Directory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $json = Read-VpsJsonHashtable -Path $path
    return @($json.outbounds | ForEach-Object { [string]$_.tag } | Where-Object { $_ })
}

function New-MxhManualClientNode {
    param([Parameter(Mandatory)][string[]]$RegionGroups)
    $kind = Read-VpsMenu '手动节点协议' @('VLESS + Reality + Vision 入口','AnyTLS + TLS/ECH 入口','Shadowsocks 2022 落地') 1 -AllowBack
    $name = Read-VpsText '节点名称/tag' -AllowBack -Validate ${function:Test-VpsNodeName}
    $server = Read-VpsText '服务器地址（IPv4、IPv6 或域名）' -AllowBack -Validate { param($v) -not [string]::IsNullOrWhiteSpace($v) }
    $defaultPort = if ($kind -eq 3) { '46936' } else { '443' }
    $port = [int](Read-VpsText '服务端口' -Default $defaultPort -AllowBack -Validate {
            param($v) $n = 0; [int]::TryParse($v, [ref]$n) -and $n -ge 1 -and $n -le 65535
        })
    if ($kind -eq 1) {
        $uuid = Read-MxhSecretText 'UUID' -AllowBack
        $publicKey = Read-MxhSecretText 'Reality PublicKey' -AllowBack
        $shortId = Read-MxhSecretText 'Reality short-id' -AllowBack
        $serverName = Read-VpsText 'Reality servername' -AllowBack -Validate ${function:Test-VpsHostName}
        $clash = [ordered]@{ name=$name;type='vless';server=$server;port=$port;uuid=$uuid;network='tcp';tls=$true;udp=$true;servername=$serverName;flow='xtls-rprx-vision';'client-fingerprint'='chrome';'reality-opts'=[ordered]@{'public-key'=$publicKey;'short-id'=$shortId} }
        $sing = [ordered]@{ type='vless';tag=$name;server=$server;server_port=$port;uuid=$uuid;flow='xtls-rprx-vision';packet_encoding='xudp';tls=[ordered]@{enabled=$true;server_name=$serverName;utls=[ordered]@{enabled=$true;fingerprint='chrome'};reality=[ordered]@{enabled=$true;public_key=$publicKey;short_id=$shortId}} }
        $region = $RegionGroups[(Read-VpsMenu '该入口属于哪个地区入口组' $RegionGroups 1 -AllowBack)-1]
        return [ordered]@{name=$name;kind='entry';region_group=$region;transit_group=$null;clash=$clash;sing_box=$sing}
    }
    if ($kind -eq 2) {
        $password = Read-MxhSecretText 'AnyTLS 密码' -AllowBack
        $serverName = Read-VpsText '证书域名/内部 SNI' -AllowBack -Validate ${function:Test-VpsHostName}
        $echConfig = Read-MxhSecretText 'ECH client config Base64' -AllowBack
        if ($echConfig -notmatch '^[A-Za-z0-9+/=]+$') { throw 'ECH client config 不是规范 Base64。' }
        $pem = @('-----BEGIN ECH CONFIGS-----',$echConfig,'-----END ECH CONFIGS-----')
        $clash = [ordered]@{name=$name;type='anytls';server=$server;port=$port;password=$password;udp=$true;sni=$serverName;'skip-cert-verify'=$false;'ech-opts'=[ordered]@{enable=$true;config=$echConfig}}
        $sing = [ordered]@{type='anytls';tag=$name;server=$server;server_port=$port;password=$password;tls=[ordered]@{enabled=$true;server_name=$serverName;min_version='1.3';ech=[ordered]@{enabled=$true;config=$pem}}}
        $region = $RegionGroups[(Read-VpsMenu '该入口属于哪个地区入口组' $RegionGroups 1 -AllowBack)-1]
        return [ordered]@{name=$name;kind='entry';region_group=$region;transit_group=$null;clash=$clash;sing_box=$sing}
    }
    $method = Read-VpsText 'Shadowsocks 方法' -Default '2022-blake3-aes-128-gcm' -AllowBack
    $password = Read-MxhSecretText 'Shadowsocks 客户端组合密码' -AllowBack
    $transit = $RegionGroups[(Read-VpsMenu '该落地节点经由哪个地区入口组连接' $RegionGroups 1 -AllowBack)-1]
    $clash = [ordered]@{name=$name;type='ss';server=$server;port=$port;cipher=$method;password=$password;udp=$true;'dialer-proxy'=$transit}
    $sing = [ordered]@{type='shadowsocks';tag=$name;server=$server;server_port=$port;method=$method;password=$password;detour=$transit}
    return [ordered]@{name=$name;kind='landing';region_group=$null;transit_group=$transit;clash=$clash;sing_box=$sing}
}

function Test-MxhClientBuilderRuntime {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $python = Get-VpsCommandPath 'python.exe'
    $probe = Invoke-VpsProcess $python @('-c','import ruamel.yaml') -TimeoutSeconds 30
    if ($probe.ExitCode -eq 0) { return $python }
    Write-VpsUi '客户端配置设计器缺少固定依赖 ruamel.yaml。部署/纳管功能不受影响。' Warning
    if (-not (Read-VpsYesNo '现在使用当前 Python 安装 requirements-client-merge.txt？' $true -AllowBack)) {
        throw '未安装客户端配置设计器依赖。'
    }
    $install = Invoke-VpsProcess $python @('-m','pip','install','--disable-pip-version-check','-r',(Join-Path $ProjectRoot 'requirements-client-merge.txt')) -TimeoutSeconds 600
    if ($install.ExitCode -ne 0) { throw 'Python 依赖安装失败，请检查网络或手动运行 requirements-client-merge.txt。' }
    return $python
}

function Invoke-MxhClientAuthorityDesigner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$InstanceRoot,
        [switch]$DryRun
    )
    $templateResult = Get-MxhClientLayoutTemplate -ProjectRoot $ProjectRoot
    $layout = $templateResult.Value
    Write-VpsUi "布局默认值：$($templateResult.Path)" Info
    $originalRegions = @($layout.region_groups)
    $regions = @(Read-MxhRegionGroups -Defaults $originalRegions)
    $customRegions = (($regions -join "`n") -ne ($originalRegions -join "`n"))
    $clash = Read-VpsText 'Clash 权威 YAML（只读源）' -Default ([string]$layout.authority_defaults.clash) -AllowBack -Validate { param($v) Test-Path $v.Trim('"') -PathType Leaf }
    $sing = Read-VpsText 'sing-box 权威 JSON（只读源）' -Default ([string]$layout.authority_defaults.sing_box) -AllowBack -Validate { param($v) Test-Path $v.Trim('"') -PathType Leaf }
    $authoritySing = Get-Content -Raw -LiteralPath $sing.Trim('"') | ConvertFrom-Json -AsHashtable
    $fragmentSources = [Collections.Generic.List[object]]::new()
    $manualNodes = [Collections.Generic.List[object]]::new()
    $existingNodeRefs = [Collections.Generic.List[object]]::new()
    $entryMembers = [ordered]@{}; foreach ($region in $regions) { $entryMembers[$region] = [Collections.Generic.List[string]]::new() }
    $landingNames = [Collections.Generic.List[string]]::new()

    $plans = @(Get-MxhManagedClientPlans -InstanceRoot $InstanceRoot)
    foreach ($selected in @(Read-MxhPlanSelection -Plans $plans)) {
        $inventory = Get-MxhProtocolInventory -Plan $selected.Plan
        $exports = Join-Path ([string]$selected.Plan.Paths.Archive) 'client-exports'
        foreach ($role in Get-MxhManagedProtocolRoles) {
            if (-not [bool]$inventory[$role].Installed) { continue }
            $names = @(Get-MxhFragmentNodeNames -Directory $exports -Role $role)
            if (-not $names.Count) { Write-VpsUi "$($selected.Plan.NodeName) 缺少 $role 客户端片段，已跳过。" Warning; continue }
            if (-not (Read-VpsYesNo "提取 $($selected.Plan.NodeName) 的 $(Get-MxhProtocolRoleLabel $role) 节点？" ([bool]$inventory[$role].Enabled) -AllowBack)) { continue }
            if ($role -eq 'ShadowsocksLanding') {
                $transit = $regions[(Read-VpsMenu '该落地节点使用哪个地区入口组作为 transit/detour' $regions 1 -AllowBack)-1]
                $fragmentSources.Add([ordered]@{fragment_dir=$exports;role=$role;node_names=$names;region_group=$null;transit_group=$transit})
                foreach ($name in $names) { $landingNames.Add($name) }
            }
            else {
                $region = $regions[(Read-VpsMenu "$($selected.Plan.NodeName) 加入哪个地区入口组" $regions 1 -AllowBack)-1]
                $fragmentSources.Add([ordered]@{fragment_dir=$exports;role=$role;node_names=$names;region_group=$region;transit_group=$null})
                foreach ($name in $names) { $entryMembers[$region].Add($name) }
            }
        }
    }
    while (Read-VpsYesNo '是否手动添加一台未纳管 VPS 的节点？' $false -AllowBack) {
        $node = New-MxhManualClientNode -RegionGroups $regions
        $manualNodes.Add($node)
        if ($node.kind -eq 'entry') { $entryMembers[[string]$node.region_group].Add([string]$node.name) }
        else { $landingNames.Add([string]$node.name) }
    }
    $selectedNames = @($fragmentSources | ForEach-Object { @($_.node_names) }) + @($manualNodes | ForEach-Object { [string]$_.name })
    $existingCandidates = @($authoritySing.outbounds | Where-Object {
            [string]$_.type -in @('vless','anytls','shadowsocks') -and [string]$_.tag -notin $selectedNames
        })
    if ($existingCandidates.Count) {
        Write-Host ''
        Write-Host '权威文件中尚未由受管计划/手动输入选中的现有节点：' -ForegroundColor Cyan
        for ($i = 0; $i -lt $existingCandidates.Count; $i++) {
            Write-Host ("  {0}. {1} ({2})" -f ($i + 1), $existingCandidates[$i].tag, $existingCandidates[$i].type)
        }
        $indexes=@(Read-MxhIndexSelection '直接复用哪些现有节点（逗号分隔；留空跳过，无需重新输入凭据）' $existingCandidates.Count -AllowEmpty)
        if($indexes.Count){
            $selectors = @($authoritySing.outbounds | Where-Object { [string]$_.type -eq 'selector' })
            foreach ($index in $indexes) {
                $outbound = $existingCandidates[$index]
                $name = [string]$outbound.tag
                if ([string]$outbound.type -eq 'shadowsocks') {
                    $suggested = [string]$outbound.detour
                    $default = [Array]::IndexOf($regions,$suggested) + 1
                    if ($default -lt 1) { $default = 1 }
                    $transit = $regions[(Read-VpsMenu "$name 使用哪个地区入口组作为 transit/detour" $regions $default -AllowBack) - 1]
                    $existingNodeRefs.Add([ordered]@{name=$name;kind='landing';region_group=$null;transit_group=$transit})
                    $landingNames.Add($name)
                }
                else {
                    $matches = @($selectors | Where-Object { [string]$_.tag -in $regions -and $name -in @($_.outbounds) } | ForEach-Object { [string]$_.tag })
                    $default = if ($matches.Count) { [Array]::IndexOf($regions,$matches[0]) + 1 } else { 1 }
                    if ($default -lt 1) { $default = 1 }
                    $region = $regions[(Read-VpsMenu "$name 加入哪个地区入口组" $regions $default -AllowBack) - 1]
                    $existingNodeRefs.Add([ordered]@{name=$name;kind='entry';region_group=$region;transit_group=$null})
                    $entryMembers[$region].Add($name)
                }
            }
        }
    }
    $allNodeCount = @($fragmentSources | ForEach-Object { @($_.node_names) }).Count + $manualNodes.Count + $existingNodeRefs.Count
    if ($allNodeCount -eq 0) { throw '没有选择或手动添加任何节点。' }

    $groups = [Collections.Generic.List[object]]::new(); $activeRegions = [Collections.Generic.List[string]]::new()
    foreach ($region in $regions) {
        $allowed = @($entryMembers[$region] | Sort-Object -Unique)
        if (-not $allowed.Count) { Write-VpsUi "$region 没有节点，本次候选不创建该组。" Warning; continue }
        $ordered = @(Read-MxhOrderedNames "$region 内节点顺序（第一项是首次默认）" -Allowed $allowed -Default $allowed)
        $groups.Add([ordered]@{name=$region;members=$ordered}); $activeRegions.Add($region)
    }
    if (-not $activeRegions.Count) { throw '至少需要一个包含入口节点的地区入口组。' }
    $defaultExitName = [string]$layout.default_exit_group
    $directName = [string]$layout.direct_group
    $exitAllowed = @($activeRegions) + @($landingNames | Sort-Object -Unique) + @('DIRECT')
    $exitMembers = @(Read-MxhOrderedNames "$defaultExitName 选项顺序（第一项是首次默认）" -Allowed $exitAllowed -Default $exitAllowed)
    $groups.Add([ordered]@{name=$defaultExitName;members=$exitMembers})
    $groups.Add([ordered]@{name=$directName;members=@('DIRECT',$defaultExitName)})
    $businessAllowed = @($defaultExitName) + @($activeRegions) + @($landingNames | Sort-Object -Unique) + @($directName)
    $customBusiness = Read-VpsYesNo '是否逐个调整业务组的默认项和完整顺序？' $false -AllowBack
    foreach ($definition in $layout.business_groups) {
        $default = if ([string]$definition.default -in $businessAllowed) { [string]$definition.default } else { $businessAllowed[0] }
        $members = @($default) + @($businessAllowed | Where-Object { $_ -ne $default })
        if ($definition.Contains('include_block') -and [bool]$definition.include_block) { $members += 'BLOCK' }
        if ($customBusiness) {
            $members = @(Read-MxhOrderedNames "$($definition.name) 选项顺序（第一项是首次默认）" -Allowed $members -Default $members)
            $definition.default = $members[0]
        }
        $groups.Add([ordered]@{name=[string]$definition.name;members=$members})
    }
    foreach ($guard in $layout.guard_groups) { $groups.Add([ordered]@{name=[string]$guard.name;members=@($guard.members)}) }
    $groupOrder = @($activeRegions) + @($defaultExitName,$directName) + @($layout.business_groups.name) + @($layout.guard_groups.name)

    $outputRoot = Read-VpsText '候选输出根目录' -Default ([string]$layout.authority_defaults.output_root) -AllowBack -Validate ${function:Test-VpsArchiveRoot}
    $output = Join-Path $outputRoot (Get-Date -Format yyyyMMdd-HHmmss)
    if ($DryRun) { Write-VpsUi "DryRun：将从 $($fragmentSources.Count) 个受管片段、$($manualNodes.Count) 个手动节点和 $($existingNodeRefs.Count) 个权威现有节点生成候选到 $output。" Success; return }
    [IO.Directory]::CreateDirectory($output) | Out-Null
    $removeGroups = @($originalRegions | Where-Object { $_ -notin @($activeRegions) })
    $spec = [ordered]@{schema_version=1;fragment_sources=@($fragmentSources);manual_nodes=@($manualNodes);existing_node_refs=@($existingNodeRefs);groups=@($groups);remove_groups=$removeGroups;group_order=$groupOrder}
    $specPath = Join-Path $output 'client-layout-spec.private.json'; Save-VpsJson -Value $spec -Path $specPath -Private
    $python = Test-MxhClientBuilderRuntime -ProjectRoot $ProjectRoot
    $builder = Join-Path $ProjectRoot 'scripts\build_client_authority.py'
    $result = Invoke-VpsProcess $python @($builder,'--clash',$clash.Trim('"'),'--sing-box',$sing.Trim('"'),'--spec',$specPath,'--output',$output) -TimeoutSeconds 300
    if ($result.ExitCode -ne 0) { throw "客户端候选生成失败：$($result.StdErr.Trim())" }
    $candidate = Join-Path $output 'Clash_General.candidate.yaml'; $testData = Join-Path $output 'mihomo-test-data'; [IO.Directory]::CreateDirectory($testData)|Out-Null
    $tested = [Collections.Generic.List[string]]::new()
    foreach ($core in @('D:\Program Files\Clash Verge\verge-mihomo.exe','D:\Program Files\Clash Verge\verge-mihomo-alpha.exe')) {
        if (-not (Test-Path -LiteralPath $core)) { continue }
        $test = Invoke-VpsProcess $core @('-t','-d',$testData,'-f',$candidate) -TimeoutSeconds 180
        if ($test.ExitCode -ne 0) { throw "候选未通过 $(Split-Path -Leaf $core)：$($test.StdErr.Trim())" }
        $tested.Add((Split-Path -Leaf $core))
    }
    $singCandidate = Join-Path $output 'sing-box-general.candidate.json'
    Get-Content -Raw $singCandidate | ConvertFrom-Json | Out-Null
    $singBytes = (Get-Item -LiteralPath $singCandidate).Length
    if ($singBytes -ge 4MB) { throw "sing-box 候选为 $singBytes 字节，超过桌面端 4 MiB 安全上限；请减少内联规则或节点。" }
    $defaultsChanged = $customBusiness -or $customRegions -or
        $clash.Trim('"') -ne [string]$layout.authority_defaults.clash -or
        $sing.Trim('"') -ne [string]$layout.authority_defaults.sing_box -or
        $outputRoot -ne [string]$layout.authority_defaults.output_root
    if ($defaultsChanged -and (Read-VpsYesNo '将本次地区、业务默认项和路径保存为本机默认？' $false -AllowBack)) {
        $layout.region_groups = @($regions)
        $layout.authority_defaults.clash = $clash.Trim('"')
        $layout.authority_defaults.sing_box = $sing.Trim('"')
        $layout.authority_defaults.output_root = $outputRoot
        Save-VpsJson -Value $layout -Path (Join-Path $ProjectRoot 'config\client-layout.local.json') -Private
    }
    Write-VpsUi "候选已生成：$output" Success
    Write-VpsUi "Mihomo 核心：$(if($tested.Count){$tested -join ', '}else{'未发现，已跳过'})；sing-box JSON 严格解析通过，体积 $singBytes 字节（低于 4 MiB）。权威文件和 AppData 未修改。" Info
}
