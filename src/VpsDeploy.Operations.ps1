function Get-MxhMaintenanceContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$ProjectRoot, [Parameter(Mandatory)] $Source, [switch]$DryRun)
    $context = New-MxhReadonlyContextFromPlan -ProjectRoot $ProjectRoot -PlanPath $Source.PlanPath
    $context.DryRun = [bool]$DryRun
    $context.NonInteractive = $false
    return $context
}

function Save-MxhMaintenanceContext {
    param([Parameter(Mandatory)] $Context)
    if ($Context.DryRun) { return }
    Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
    Save-VpsContext -Context $Context
}

function Start-MxhMaintenanceTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$Label)
    if ($Context.DryRun) { return [ordered]@{ DryRun = $true; Label = $Label } }
    if ($Label -notmatch '^[A-Za-z0-9-]{1,48}$') { throw '维护事务标签无效。' }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $local = Join-Path $Context.ArchivePath "maintenance-backups\$stamp-$Label"
    [IO.Directory]::CreateDirectory($local) | Out-Null
    foreach ($name in @('deployment-plan.json','deployment-state.json','deployment-secrets.private.json')) {
        $path = Join-Path $Context.ArchivePath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination (Join-Path $local $name); Protect-VpsPrivateFile (Join-Path $local $name) }
    }
    foreach ($directory in @('client-exports','server-configs')) {
        $path = Join-Path $Context.ArchivePath $directory
        if (Test-Path -LiteralPath $path -PathType Container) { Copy-Item -LiteralPath $path -Destination (Join-Path $local $directory) -Recurse }
    }
    $role = Get-MxhInventoryPrimaryRole -Inventory (Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State)
    $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-arm-rollback.sh' -Parameters @{
        SOURCE_ROLE = $role; TARGET_ROLE = $role; TIMEOUT_MINUTES = '20'
    } -TimeoutSeconds 300
    $remote = Get-VpsMarkerValue $result.StdOut BACKUP_DIR -Required
    $transaction = [ordered]@{ Label=$Label; LocalBackup=$local; RemoteBackup=$remote; StartedAt=(Get-Date).ToString('o'); Committed=$false }
    Save-VpsJson -Value $transaction -Path (Join-Path $local 'maintenance-transaction.json') -Private
    $Context.State.MaintenanceTransaction = $transaction
    Save-MxhMaintenanceContext $Context
    return $transaction
}

function Complete-MxhMaintenanceTransaction {
    param([Parameter(Mandatory)] $Context)
    if ($Context.DryRun) { return }
    $result = Invoke-VpsRemoteScript -Context $Context -Asset 'maintenance-transaction-commit.sh'
    if ($result.StdOut -notmatch 'VPSDEPLOY_MAINTENANCE_COMMITTED') { throw '维护事务提交未确认。' }
    $Context.State.MaintenanceTransaction.Committed = $true
    $Context.State.MaintenanceTransaction.CommittedAt = (Get-Date).ToString('o')
    Save-MxhMaintenanceContext $Context
}

function Undo-MxhMaintenanceTransaction {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] [string]$Reason)
    if ($Context.DryRun) { return }
    try {
        $result = Invoke-VpsRemoteScript -Context $Context -Asset 'protocol-migration-trigger-rollback.sh' -Parameters @{ SOURCE_ROLE = (Get-MxhInventoryPrimaryRole -Inventory (Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State)) } -TimeoutSeconds 300
        if ($result.StdOut -notmatch 'VPSDEPLOY_MIGRATION_ROLLBACK_OK') { throw '服务器未确认回滚。' }
        $backup=[string]$Context.State.MaintenanceTransaction.LocalBackup
        if($backup -and (Test-Path $backup -PathType Container)){
            foreach($name in @('deployment-plan.json','deployment-state.json','deployment-secrets.private.json')){
                $source=Join-Path $backup $name;if(Test-Path $source){Copy-Item $source (Join-Path $Context.ArchivePath $name) -Force;Protect-VpsPrivateFile (Join-Path $Context.ArchivePath $name)}
            }
            $Context.Plan=Read-VpsJsonHashtable $Context.PlanPath
            $Context.State=Read-VpsJsonHashtable $Context.StatePath
            $Context.Secrets=Read-VpsJsonHashtable $Context.SecretsPath
        }
        $Context.State.LastMaintenanceRollback=[ordered]@{At=(Get-Date).ToString('o');Reason=$Reason;RemoteConfirmed=$true}
        Save-MxhMaintenanceContext $Context
    }
    catch { Write-VpsUi '立即回滚无法确认；VPS 端 20 分钟计时器仍会独立恢复。' Error; throw }
}

function Get-MxhHealthAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context, [switch]$Persist, [switch]$InitializeBaseline)
    if ($Context.DryRun) {
        return [ordered]@{ SchemaVersion=1; DryRun=$true; Findings=@(); Status='DryRun' }
    }
    $result = Invoke-VpsRemoteScript -Context $Context -Asset 'maintenance-health-audit.sh' -TimeoutSeconds 300
    $audit = (Get-VpsMarkerValue $result.StdOut HEALTH_AUDIT -Required) | ConvertFrom-Json -AsHashtable
    $findings = [Collections.Generic.List[object]]::new()
    $add = { param($severity,$code,$message) $findings.Add([ordered]@{ Severity=$severity; Code=$code; Message=$message }) }
    if (-not $audit.Ssh.Valid) { & $add Critical 'SSH_CONFIG_INVALID' 'sshd -T 未通过。' }
    if ($audit.Ssh.PasswordAuthentication -ne 'no' -or $audit.Ssh.KbdInteractiveAuthentication -ne 'no' -or $audit.Ssh.PubkeyAuthentication -ne 'yes') {
        & $add Critical 'SSH_NOT_KEY_ONLY' 'SSH 有效配置不是公钥独占登录。'
    }
    $expectedPorts = @([int]$Context.Plan.Ports.SshPrimary,[int]$Context.Plan.Ports.SshRescue) | Sort-Object -Unique
    foreach ($port in $expectedPorts) { if ($port -notin @($audit.Ssh.Ports | ForEach-Object {[int]$_})) { & $add Critical 'SSH_PORT_DRIFT' '一个计划内 SSH 入口没有出现在有效配置中。' } }
    $inventory = Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
    foreach ($role in Get-MxhManagedProtocolRoles) {
        $expected = $inventory[$role]; $actual = $audit.Services[$role]
        foreach ($field in @('Installed','Enabled','Active')) {
            if ([bool]$expected[$field] -ne [bool]$actual[$field]) { & $add Critical 'PROTOCOL_STATE_DRIFT' "$role 的 $field 与本地清单不一致。" }
        }
    }
    if ($audit.Nftables.Present -and -not $audit.Nftables.Valid) { & $add Critical 'NFTABLES_INVALID' 'nftables 持久化配置语法无效。' }
    if ($inventory.AnyTlsEntry.Installed -and (-not $audit.Certificate.Present -or [int]$audit.Certificate.DaysRemaining -lt 21)) {
        & $add Warning 'TLS_CERT_EXPIRY' 'AnyTLS 证书不存在或剩余不足 21 天。'
    }
    if ($audit.Timers.RollbackActive) { & $add Warning 'ROLLBACK_TIMER_ACTIVE' '存在尚未提交的自动回滚计时器。' }
    if ($Context.State.Contains('HealthBaseline')) {
        foreach ($key in $Context.State.HealthBaseline.Hashes.Keys) {
            $old=[string]$Context.State.HealthBaseline.Hashes[$key]; $now=[string]$audit.Hashes[$key]
            if (($old -or $now) -and $old -ne $now) { & $add Warning 'CONFIG_HASH_DRIFT' "$key 的 SHA-256 与已确认基线不同。" }
        }
    }
    $expectedAgentInstalled=$Context.State.Contains('KomariInstalled') -and [bool]$Context.State.KomariInstalled
    if($expectedAgentInstalled -ne [bool]$audit.Services.KomariAgent.Installed){& $add Warning 'KOMARI_AGENT_DRIFT' 'Komari Agent 安装状态与本地清单不一致。'}
    if([bool]$Context.Plan.Komari.Enabled -ne [bool]$audit.Services.KomariAgent.Active){& $add Warning 'KOMARI_AGENT_STATE_DRIFT' 'Komari Agent 运行状态与本地计划不一致。'}
    if($inventory.RealityEntry.Installed -and [string]$audit.Versions.Xray -notmatch [regex]::Escape([string]$Context.Plan.Reality.XrayVersion)){& $add Warning 'XRAY_VERSION_DRIFT' 'Xray 版本与固定计划不一致。'}
    if($inventory.AnyTlsEntry.Installed -and [string]$audit.Versions.SingBoxAnyTls -notmatch [regex]::Escape([string]$Context.Plan.AnyTls.SingBoxVersion)){& $add Warning 'SINGBOX_VERSION_DRIFT' 'AnyTLS sing-box 版本与固定计划不一致。'}
    if($inventory.ShadowsocksLanding.Installed -and [string]$audit.Versions.SingBox -notmatch [regex]::Escape([string]$Context.Plan.Shadowsocks.SingBoxVersion)){& $add Warning 'SINGBOX_VERSION_DRIFT' 'Shadowsocks sing-box 版本与固定计划不一致。'}
    if($Context.State.Contains('KomariController') -and [bool]$Context.State.KomariController.Installed -and [string]$audit.Versions.KomariController -notmatch [regex]::Escape([string]$Context.Versions.komari_controller.version)){& $add Warning 'KOMARI_CONTROLLER_VERSION_DRIFT' 'Komari Controller 版本与固定目录不一致。'}
    $status = if (@($findings | Where-Object Severity -eq Critical).Count) {'Critical'} elseif ($findings.Count) {'Warning'} else {'Healthy'}
    if ($InitializeBaseline -and $status -eq 'Healthy') {
        $Context.State.HealthBaseline = [ordered]@{ EstablishedAt=(Get-Date).ToString('o'); Hashes=Copy-MxhHashtable $audit.Hashes }
    }
    $report=[ordered]@{ SchemaVersion=1; Status=$status; CollectedAt=$audit.CollectedAt; Findings=$findings.ToArray(); Snapshot=$audit }
    if ($Persist) {
        $dir=Join-Path $Context.ArchivePath 'health-audits'; [IO.Directory]::CreateDirectory($dir)|Out-Null
        $path=Join-Path $dir ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'.json')
        Save-VpsJson $report $path -Private; $Context.State.LastHealthAudit=$path; Save-MxhMaintenanceContext $Context
    }
    return $report
}

function Show-MxhHealthAudit {
    param([Parameter(Mandatory)] $Report)
    Write-Host ''; Write-Host "健康审计：$($Report.Status)" -ForegroundColor White
    if (-not @($Report.Findings).Count) { Write-VpsUi '未发现服务状态、SSH、防火墙、证书或配置哈希异常。' Success; return }
    foreach ($finding in $Report.Findings) { Write-VpsUi "[$($finding.Code)] $($finding.Message)" $(if($finding.Severity -eq 'Critical'){'Error'}else{'Warning'}) }
}

function Invoke-MxhHealthAuditInteractive {
    param($Context)
    $initialize = -not $Context.State.Contains('HealthBaseline')
    $report=Get-MxhHealthAudit $Context -Persist -InitializeBaseline:$initialize
    Show-MxhHealthAudit $report
    if ($initialize -and $report.Status -eq 'Healthy') { Write-VpsUi '已把本次脱敏哈希快照建立为配置漂移基线。' Success }
    elseif (-not $initialize -and $report.Status -ne 'Critical' -and @($report.Findings).Count -gt 0 -and
        @($report.Findings | Where-Object Code -ne 'CONFIG_HASH_DRIFT').Count -eq 0 -and
        (Read-VpsYesNo '这些哈希变化是否为已确认维护结果，并更新为新基线？' $false -AllowBack)) {
        $Context.State.HealthBaseline = [ordered]@{ EstablishedAt=(Get-Date).ToString('o'); Hashes=Copy-MxhHashtable $report.Snapshot.Hashes }
        Save-MxhMaintenanceContext $Context
        Write-VpsUi '配置漂移基线已更新；远端没有因此被修改。' Success
    }
}

function Invoke-MxhManualRestoreCenter {
    param($Context)
    if ($Context.DryRun) { Write-VpsUi 'DryRun：将枚举本地/远端成对备份，恢复前再建立当前状态快照。' Success; return }
    $candidates=@()
    $migrationRoot=Join-Path $Context.ArchivePath 'migration-backups'
    $candidates+=@(Get-ChildItem $migrationRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $statePath=Join-Path $_.FullName 'deployment-state.json'; if(Test-Path $statePath){$s=Read-VpsJsonHashtable $statePath;$remote=$null;if($s.Contains('Migration') -and $s.Migration.Contains('RemoteBackupDirectory')){$remote=[string]$s.Migration.RemoteBackupDirectory};if($remote){[pscustomobject]@{Directory=$_.FullName;Remote=$remote;Name=$_.Name;Time=$_.LastWriteTimeUtc}}}
    })
    $maintenanceRoot=Join-Path $Context.ArchivePath 'maintenance-backups'
    $candidates+=@(Get-ChildItem $maintenanceRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $metadata=Join-Path $_.FullName 'maintenance-transaction.json';if(Test-Path $metadata){$m=Read-VpsJsonHashtable $metadata;if($m.RemoteBackup){[pscustomobject]@{Directory=$_.FullName;Remote=[string]$m.RemoteBackup;Name=$_.Name;Time=$_.LastWriteTimeUtc}}}
    })
    $candidates=@($candidates|Sort-Object Time -Descending)
    if(-not $candidates.Count){Write-VpsUi '没有找到可验证的本地/远端成对协议备份。' Warning; return}
    $choice=Read-VpsMenu '选择恢复点' @($candidates|ForEach-Object{$_.Name}) 1 -AllowBack
    $selected=$candidates[$choice-1]
    $scopeChoice=Read-VpsMenu '恢复范围' @('仅恢复协议配置和凭据文件，保留当前服务/防火墙状态','完整恢复协议文件、服务启停、防火墙和 sysctl') 1 -AllowBack
    $scope=if($scopeChoice -eq 1){'ConfigOnly'}else{'Full'}
    if((Read-VpsText '输入 RESTORE 确认' -AllowBack) -cne 'RESTORE'){Write-VpsUi '未恢复。' Warning;return}
    Start-MxhMaintenanceTransaction $Context 'ManualRestore'|Out-Null
    try {
        $r=Invoke-VpsRemoteScript $Context 'maintenance-restore-apply.sh' @{BACKUP_PATH=$selected.Remote;SCOPE=$scope} -TimeoutSeconds 600
        if($r.StdOut -notmatch 'VPSDEPLOY_MANUAL_RESTORE_APPLIED'){throw '恢复脚本未确认完成。'}
        $report=Get-MxhHealthAudit $Context
        Show-MxhHealthAudit $report
        if(-not(Read-VpsYesNo '保留此次恢复结果？' $true)){throw '用户选择恢复到操作前状态。'}
        Complete-MxhMaintenanceTransaction $Context
        foreach($name in @('deployment-plan.json','deployment-state.json','deployment-secrets.private.json')){
            $source=Join-Path $selected.Directory $name; if(Test-Path $source){Copy-Item $source (Join-Path $Context.ArchivePath $name) -Force}
        }
        Write-VpsUi '远端恢复与对应本地元数据恢复已提交。建议立即再运行一次健康审计并建立新基线。' Success
    } catch { Undo-MxhMaintenanceTransaction $Context $_.Exception.Message; throw }
}

function Invoke-MxhCredentialRotation {
    param($Context)
    $inventory=Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
    $roles=@(Get-MxhManagedProtocolRoles|Where-Object{[bool]$inventory[$_].Installed})
    if(-not $roles.Count){Write-VpsUi '没有可轮换的受管代理协议。' Warning;return}
    $choice=Read-VpsMenu '选择凭据轮换对象' @($roles|ForEach-Object{Get-MxhProtocolRoleLabel $_}) 1 -AllowBack
    $role=$roles[$choice-1]
    if(-not [bool]$inventory[$role].Active){throw '为避免备用协议被意外激活，当前只允许轮换正在运行的协议。请先切换到该协议。'}
    if($Context.DryRun){Write-VpsUi "DryRun：将为 $role 生成候选凭据、功能测试后再替换。" Success;return}
    $candidateSecrets=Copy-MxhHashtable $Context.Secrets
    if($role -eq 'RealityEntry'){
        $r=Invoke-VpsRemoteScript $Context 'xray-generate-credentials.sh' @{} -SensitiveOutput
        $encoded=[regex]::Match($r.StdOut,'(?m)^VPSDEPLOY_XRAY_SECRET_B64=([A-Za-z0-9+/=]+)$')
        if(-not $encoded.Success){throw '无法解析新 Reality 凭据。'}
        $candidateSecrets.Xray=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.Groups[1].Value))|ConvertFrom-Json -AsHashtable)
    } elseif($role -eq 'AnyTlsEntry'){
        $candidateSecrets.AnyTls.Password=New-VpsRandomString 32
    } else {
        $candidateSecrets.Shadowsocks.PrimaryUserKey=New-MxhRandomBase64Key 16
        if([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled){$candidateSecrets.Shadowsocks.SecondaryUserKey=New-MxhRandomBase64Key 16}
    }
    $candidate=[pscustomobject]@{ProjectRoot=$Context.ProjectRoot;Plan=$Context.Plan;ArchivePath=$Context.ArchivePath;PlanPath=$Context.PlanPath;SecretsPath=$Context.SecretsPath;StatePath=$Context.StatePath;LogPath=$Context.LogPath;Secrets=$candidateSecrets;State=$Context.State;DryRun=$false;NonInteractive=$false;Versions=$Context.Versions}
    $config=if($role -eq 'RealityEntry'){New-MxhXrayServerConfig $candidate}elseif($role -eq 'AnyTlsEntry'){New-MxhAnyTlsServerConfig $candidate}else{New-MxhShadowsocksServerConfig $candidate}
    Start-MxhMaintenanceTransaction $Context 'CredentialRotation'|Out-Null
    try {
        $r=Invoke-VpsRemoteScript $Context 'maintenance-protocol-config-apply.sh' @{ROLE=$role;CONFIG_JSON=($config|ConvertTo-Json -Depth 40);WAS_ACTIVE='true'} -TimeoutSeconds 300 -SensitiveOutput
        if($r.StdOut -notmatch 'VPSDEPLOY_CREDENTIAL_CONFIG_APPLIED'){throw '远端未确认候选凭据配置。'}
        $modulePath=if($role -eq 'RealityEntry'){'modules\90-ClientExport.ps1'}elseif($role -eq 'AnyTlsEntry'){'modules\91-AnyTlsClientExport.ps1'}else{'modules\92-LandingClientExport.ps1'}
        $module=&(Join-Path $Context.ProjectRoot $modulePath); & $module.Invoke $candidate
        if($role -eq 'RealityEntry'){
            $core=@(Get-VpsMihomoCorePaths -ProjectRoot $Context.ProjectRoot|Where-Object{(Split-Path -Leaf $_)-eq'verge-mihomo.exe'}|Select-Object -First 1);if(-not$core.Count){throw '找不到 Mihomo 稳定核心，不能完成 Reality 真实握手。'};$core=$core[0]
            Invoke-MxhMihomoEgressTest $candidate $core $candidate.State.ClientExports.PrimaryProfile ([int]$candidate.State.ClientExports.PrimaryMixedPort) 'credential-candidate'|Out-Null
        } elseif($role -eq 'AnyTlsEntry'){
            $r=Invoke-VpsRemoteScript $Context 'anytls-self-test.sh' @{PASSWORD=$candidateSecrets.AnyTls.Password;PORT=[string]$Context.Plan.Ports.AnyTlsPrimary;SERVER=[string]$Context.Plan.Server.IPv4;SERVER_NAME=[string]$Context.Plan.AnyTls.ServerName;ECH_CONFIG_PEM=[string]$candidateSecrets.AnyTls.EchClientConfigPem} -TimeoutSeconds 300 -SensitiveOutput
            if($r.StdOut -notmatch 'VPSDEPLOY_ANYTLS_SELF_TEST_OK'){throw 'AnyTLS 候选密码功能测试失败。'}
        } else {
            $password=[string]$candidateSecrets.Shadowsocks.ServerKey+':'+[string]$candidateSecrets.Shadowsocks.PrimaryUserKey
            $r=Invoke-VpsRemoteScript $Context 'shadowsocks-self-test.sh' @{METHOD=[string]$Context.Plan.Shadowsocks.Method;PASSWORD=$password;LANDING_PORT=[string]$Context.Plan.Ports.LandingShadowsocks;IP_VERSION='4';TEST_SERVER='127.0.0.1'} -TimeoutSeconds 300 -SensitiveOutput
            if($r.StdOut -notmatch 'VPSDEPLOY_SHADOWSOCKS_SELF_TEST_OK'){throw 'Shadowsocks 候选用户密钥功能测试失败。'}
        }
        Complete-MxhMaintenanceTransaction $Context
        $Context.Secrets=$candidateSecrets; $Context.State=$candidate.State
        $Context.State.CredentialRotation=[ordered]@{Role=$role;RotatedAt=(Get-Date).ToString('o');Mode=if($role -eq 'RealityEntry'){'AtomicCutover'}else{'CandidateValidated'} }
        Save-MxhMaintenanceContext $Context
        $serverDir=Join-Path $Context.ArchivePath 'server-configs'
        if($role -eq 'RealityEntry'){Invoke-VpsScpDownload $Context '/usr/local/etc/xray/config.json' (Join-Path $serverDir 'xray-config.json')}
        elseif($role -eq 'AnyTlsEntry'){Invoke-VpsScpDownload $Context '/etc/sing-box-anytls/config.json' (Join-Path $serverDir 'sing-box-anytls-config.private.json')}
        else{Invoke-VpsScpDownload $Context '/etc/sing-box/config.json' (Join-Path $serverDir 'sing-box-config.private.json')}
        Write-VpsUi '凭据已轮换并完成功能测试；旧值只保留在受保护的维护备份中。' Success
    }catch{Undo-MxhMaintenanceTransaction $Context $_.Exception.Message;throw}
}

function Test-MxhSshIdentityConnection {
    param($Context,[string]$Identity,[int]$Port,[string]$User)
    $ssh=Get-VpsCommandPath 'ssh.exe'; $args=@('-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=12','-i',$Identity,'-p',[string]$Port,"$User@$($Context.Plan.Server.IPv4)",'printf VPSDEPLOY_NEW_KEY_OK')
    $r=Invoke-VpsProcess $ssh $args -TimeoutSeconds 30
    return $r.ExitCode -eq 0 -and $r.StdOut -match 'VPSDEPLOY_NEW_KEY_OK'
}

function Invoke-MxhSshMaintenance {
    param($Context)
    $action=Read-VpsMenu 'SSH 独立维护' @('只读审计','轮换实例专用 Ed25519 密钥','重设双 SSH 端口并同时轮换密钥') 1 -AllowBack
    if($action -eq 1){Show-MxhHealthAudit (Get-MxhHealthAudit $Context -Persist);return}
    $changePorts=$action -eq 3
    if($changePorts -and [string]$Context.Plan.Firewall.Mode -eq 'PreserveExisting'){throw '保留现有防火墙模式下脚本拒绝自动换端口；请先人工审计并转为受管防火墙。'}
    $primary=if($changePorts){Get-VpsRandomPort}else{[int]$Context.Plan.Ports.SshPrimary}
    $rescue=if($changePorts){Get-VpsRandomPort -Exclude @($primary)}else{[int]$Context.Plan.Ports.SshRescue}
    if($Context.DryRun){Write-VpsUi 'DryRun：将并行保留旧/新入口，验证新密钥后再移除旧入口和旧公钥。' Success;return}
    $key=Get-VpsSshKeyPath $Context; $oldPublic=(Get-Content -Raw ($key+'.pub')).Trim()
    $temp=$key+'.rotation-'+(Get-Date -Format yyyyMMddHHmmss); $keygen=Get-VpsCommandPath 'ssh-keygen.exe'
    $r=Invoke-VpsProcess $keygen @('-t','ed25519','-a','64','-N','','-C',$Context.Plan.NodeName,'-f',$temp) -TimeoutSeconds 60
    if($r.ExitCode -ne 0){throw '生成候选 SSH 密钥失败。'}; Protect-VpsPrivateFile $temp
    $newPublic=(Get-Content -Raw ($temp+'.pub')).Trim(); $oldPorts=@([int]$Context.Plan.Ports.SshPrimary,[int]$Context.Plan.Ports.SshRescue)|Sort-Object -Unique
    $rotationStamp=Get-Date -Format yyyyMMddHHmmss;$keyBackup=$key+'.bak-'+$rotationStamp;$publicBackup=($key+'.pub')+'.bak-'+$rotationStamp;$localSwapped=$false
    try{
        if($changePorts){
            $tempPlan=Copy-MxhHashtable $Context.Plan; $tempPlan.Ports.SshPrimary=$primary;$tempPlan.Ports.SshRescue=$rescue
            $parameters=Get-MxhProtocolFirewallParameters $tempPlan $Context.State (Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State)
            $parameters.TCP_PORTS=(@($oldPorts+$primary+$rescue+($parameters.TCP_PORTS-split','|ForEach-Object{[int]$_}))|Sort-Object -Unique)-join','
            Invoke-VpsRemoteScript $Context 'nftables-apply.sh' $parameters -TimeoutSeconds 180|Out-Null
        }
        $r=Invoke-VpsRemoteScript $Context 'maintenance-ssh-apply.sh' @{OLD_PORTS=$oldPorts-join',';NEW_PRIMARY=[string]$primary;NEW_RESCUE=[string]$rescue;NEW_PUBLIC_KEY=$newPublic;ADMIN_USER=[string]$Context.Plan.AdminUser} -TimeoutSeconds 180
        if($r.StdOut -notmatch 'VPSDEPLOY_SSH_MAINTENANCE_STAGED'){throw 'SSH 候选入口未确认。'}
        $portChecks=@([pscustomobject]@{Label='Primary';Port=$primary},[pscustomobject]@{Label='Rescue';Port=$rescue})|Sort-Object Port -Unique
        foreach($check in $portChecks){foreach($user in @('root',[string]$Context.Plan.AdminUser)|Sort-Object -Unique){if(-not(Test-MxhSshIdentityConnection $Context $temp $check.Port $user)){throw "候选 SSH 密钥复验失败：$user / $($check.Label)。"}}}
        Move-Item $key $keyBackup;Move-Item ($key+'.pub') $publicBackup;Move-Item $temp $key;Move-Item ($temp+'.pub') ($key+'.pub');Protect-VpsPrivateFile $key;$localSwapped=$true
        foreach($check in $portChecks){foreach($user in @('root',[string]$Context.Plan.AdminUser)|Sort-Object -Unique){if(-not(Test-VpsSshConnection $Context $user $check.Port)){throw "本地密钥切换后复验失败：$user / $($check.Label)。"}}}
        $r=Invoke-VpsRemoteScript $Context 'maintenance-ssh-commit.sh' @{NEW_PRIMARY=[string]$primary;NEW_RESCUE=[string]$rescue;NEW_PUBLIC_KEY=$newPublic;OLD_PUBLIC_KEY=$oldPublic;ADMIN_USER=[string]$Context.Plan.AdminUser} -TimeoutSeconds 180
        if($r.StdOut -notmatch 'VPSDEPLOY_SSH_MAINTENANCE_COMMITTED'){throw 'SSH 维护提交失败。'}
        $Context.Plan.Ports.SshPrimary=$primary;$Context.Plan.Ports.SshRescue=$rescue;$Context.State.CurrentManagementPort=$primary
        if($changePorts){Invoke-MxhProtocolFirewall $Context (Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State) 'SshMaintenanceFinalFirewall'}
        Save-MxhMaintenanceContext $Context;Write-VpsUi '新密钥已在 root/admin 与双端口验证，旧公钥和旧端口已移除。' Success
    }catch{
        try { Invoke-VpsSshCommand $Context root ([int]$Context.State.CurrentManagementPort) 'systemctl start mxh-ssh-maintenance-rollback.service; systemctl disable --now mxh-ssh-maintenance-rollback.timer >/dev/null 2>&1 || true' -AllowFailure | Out-Null } catch { }
        if($localSwapped){
            if(Test-Path $key){Move-Item $key ($key+'.failed-'+$rotationStamp) -Force};if(Test-Path ($key+'.pub')){Move-Item ($key+'.pub') (($key+'.pub')+'.failed-'+$rotationStamp) -Force}
            if(Test-Path $keyBackup){Move-Item $keyBackup $key -Force};if(Test-Path $publicBackup){Move-Item $publicBackup ($key+'.pub') -Force};Protect-VpsPrivateFile $key
        }
        throw
    }finally{foreach($p in @($temp,$temp+'.pub')){if(Test-Path $p){Remove-Item $p -Force}}}
}

function Invoke-MxhFirewallMaintenance {
    param($Context)
    $mode=[string]$Context.Plan.Firewall.Mode
    $options=if($mode -eq 'PreserveExisting'){@('只读语法与状态审计','明确接管为受管最小 nftables（会替换现有规则）')}else{@('只读语法与状态审计','按本地协议清单重新生成受管规则','修改 Shadowsocks 可信入口白名单并应用')}
    $choice=Read-VpsMenu "防火墙独立维护（$mode）" $options 1 -AllowBack
    if($choice -eq 1){Show-MxhHealthAudit (Get-MxhHealthAudit $Context -Persist);return}
    if($Context.DryRun){Write-VpsUi 'DryRun：将先预检候选规则，再事务化应用和复验 SSH/协议监听。' Success;return}
    $new4=@($Context.Plan.Shadowsocks.TrustedEntryIPv4s);$new6=@($Context.Plan.Shadowsocks.TrustedEntryIPv6s)
    if($mode -eq 'PreserveExisting'){
        if((Read-VpsText '输入 ADOPT-MANAGED-NFT 确认替换现有规则' -AllowBack)-cne 'ADOPT-MANAGED-NFT'){throw '确认短语不匹配，未接管防火墙。'}
        $Context.Plan.Firewall.Mode='ManagedNftables'
    }
    if($choice -eq 3){
        $new4=ConvertTo-VpsIpAllowlist (Read-VpsText '可信入口 IPv4，逗号分隔' -Default ($new4-join',') -AllowEmpty -AllowBack) IPv4
        $new6=ConvertTo-VpsIpAllowlist (Read-VpsText '可信入口 IPv6，逗号分隔' -Default ($new6-join',') -AllowEmpty -AllowBack) IPv6
        if(-not $new4.Count -and -not $new6.Count){throw 'Shadowsocks 白名单不能同时为空。'}
    }
    Start-MxhMaintenanceTransaction $Context 'FirewallMaintenance'|Out-Null
    try{
        $Context.Plan.Shadowsocks.TrustedEntryIPv4s=@($new4);$Context.Plan.Shadowsocks.TrustedEntryIPv6s=@($new6)
        Invoke-MxhProtocolFirewall $Context (Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State) 'IndependentFirewall'
        foreach($port in @([int]$Context.Plan.Ports.SshPrimary,[int]$Context.Plan.Ports.SshRescue)|Sort-Object -Unique){if(-not(Test-VpsSshConnection $Context root $port)){throw '防火墙应用后 SSH 复验失败。'}}
        $report=Get-MxhHealthAudit $Context; if($report.Status -eq 'Critical'){throw '防火墙应用后的健康审计出现严重项。'}
        Complete-MxhMaintenanceTransaction $Context;Save-MxhMaintenanceContext $Context;Write-VpsUi '防火墙候选已通过语法、双 SSH 和服务状态复验。' Success
    }catch{Undo-MxhMaintenanceTransaction $Context $_.Exception.Message;throw}
}

function Invoke-MxhControlledUpgrade {
    param($Context)
    $inventory=Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State
    $roles=@(Get-MxhManagedProtocolRoles|Where-Object{[bool]$inventory[$_].Installed})
    if([bool]$Context.State.KomariInstalled){$roles+='KomariAgent'}
    if($Context.State.Contains('KomariController') -and [bool]$Context.State.KomariController.Installed){$roles+='KomariController'}
    if(-not $roles.Count){Write-VpsUi '没有可升级的受管组件。' Warning;return}
    $choice=Read-VpsMenu '选择受控升级组件（使用 versions.json 固定版本与 SHA-256）' @($roles|ForEach-Object{if($_ -eq 'KomariAgent'){'Komari Agent'}elseif($_ -eq 'KomariController'){'Komari Controller'}else{Get-MxhProtocolRoleLabel $_}}) 1 -AllowBack
    $role=$roles[$choice-1]
    $targetVersion=$null;$targetChannel=$null
    if($role -eq 'RealityEntry'){
        $channelChoice=Read-VpsMenu 'Xray 升级目标' @(
            "保持计划版本（$($Context.Plan.Reality.XrayVersion)）",
            "切换到当前固定验证版（$($Context.Versions.xray.version)）",
            '解析并切换到 XTLS/Xray-core 官方最新稳定版'
        ) 1 -AllowBack
        $targetVersion=if($channelChoice -eq 1){[string]$Context.Plan.Reality.XrayVersion}elseif($channelChoice -eq 2){[string]$Context.Versions.xray.version}else{Resolve-VpsXrayVersion -ProjectRoot $Context.ProjectRoot -Channel LatestStable}
        $targetChannel=if($channelChoice -eq 3){'LatestStable'}elseif($channelChoice -eq 2){'FixedVerified'}elseif($Context.Plan.Reality.Contains('XrayVersionChannel')){[string]$Context.Plan.Reality.XrayVersionChannel}else{'ImportedOrLegacy'}
    }
    if($Context.DryRun){Write-VpsUi "DryRun：将下载并校验固定资产、配置检查、同版本可重复安装、失败自动回滚：$role" Success;return}
    Start-MxhMaintenanceTransaction $Context 'ControlledUpgrade'|Out-Null
    try{
        $arch=if([string]$Context.State.Audit.Architecture -in @('x86_64','amd64')){'amd64'}else{'arm64'}
        if($role -eq 'RealityEntry'){
            Invoke-VpsRemoteScript $Context 'xray-install.sh' @{VERSION=$targetVersion;INSTALLER_URL=[string]$Context.Versions.xray.installer_url;INSTALLER_SHA256=[string]$Context.Versions.xray.installer_sha256} -TimeoutSeconds 1200|Out-Null
            $Context.Plan.Reality.XrayVersion=$targetVersion;$Context.Plan.Reality.XrayVersionChannel=$targetChannel
        }elseif($role -in @('AnyTlsEntry','ShadowsocksLanding')){
            $asset=$Context.Versions.sing_box.assets.$arch; $script=if($role -eq 'AnyTlsEntry'){'sing-box-anytls-install.sh'}else{'sing-box-install.sh'}
            $params=@{VERSION=[string]$Context.Versions.sing_box.version;ASSET_NAME=[string]$asset.name;SHA256=[string]$asset.sha256}
            if($role -eq 'ShadowsocksLanding'){$params.NEED_BIND_INTERFACE=([bool]$Context.Plan.Shadowsocks.SecondaryIpv6Enabled).ToString().ToLowerInvariant()}
            Invoke-VpsRemoteScript $Context $script $params -TimeoutSeconds 1200|Out-Null
        }elseif($role -eq 'KomariAgent'){
            $asset=$Context.Versions.komari_agent.assets.$arch
            $r=Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='AgentUpgrade';VERSION=[string]$Context.Versions.komari_agent.version;ASSET_NAME=[string]$asset.name;SHA256=[string]$asset.sha256} -TimeoutSeconds 1200
            if($r.StdOut -notmatch 'VPSDEPLOY_KOMARI_LIFECYCLE_OK'){throw 'Komari Agent 升级未确认。'}
        }else{
            $asset=$Context.Versions.komari_controller.assets.$arch
            $backupResult=Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerBackup'} -TimeoutSeconds 600;$remoteBackup=Get-VpsMarkerValue $backupResult.StdOut KOMARI_BACKUP -Required
            $backupDirectory=Join-Path $Context.ArchivePath 'komari-backups';[IO.Directory]::CreateDirectory($backupDirectory)|Out-Null;$localBackup=Join-Path $backupDirectory (Split-Path -Leaf $remoteBackup);Invoke-VpsScpDownload $Context $remoteBackup $localBackup
            $r=Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerUpgrade';VERSION=[string]$Context.Versions.komari_controller.version;ASSET_NAME=[string]$asset.name;SHA256=[string]$asset.sha256} -TimeoutSeconds 1200
            if($r.StdOut -notmatch 'VPSDEPLOY_KOMARI_LIFECYCLE_OK'){throw 'Komari Controller 升级未确认。'}
            Write-VpsUi "Controller 升级前完整备份已下载：$localBackup" Success
        }
        if($role -notin @('KomariAgent','KomariController')){
            $stateResult=Invoke-VpsRemoteScript $Context 'protocol-lifecycle-apply-state.sh' @{
                REALITY_ENABLED=([bool]$inventory.RealityEntry.Enabled).ToString().ToLowerInvariant()
                ANYTLS_ENABLED=([bool]$inventory.AnyTlsEntry.Enabled).ToString().ToLowerInvariant()
                SHADOWSOCKS_ENABLED=([bool]$inventory.ShadowsocksLanding.Enabled).ToString().ToLowerInvariant()
            } -TimeoutSeconds 300
            if($stateResult.StdOut -notmatch 'VPSDEPLOY_PROTOCOL_STATE_APPLIED'){throw '升级后原服务启停状态恢复未确认。'}
        }
        $report=Get-MxhHealthAudit $Context;if($report.Status -eq 'Critical'){throw '升级后健康审计出现严重项。'}
        Complete-MxhMaintenanceTransaction $Context;$Context.State.LastControlledUpgrade=[ordered]@{Component=$role;At=(Get-Date).ToString('o');Catalog='versions.json'};Save-MxhMaintenanceContext $Context
        Write-VpsUi '固定资产校验、安装、配置检查和服务复验均通过。' Success
    }catch{Undo-MxhMaintenanceTransaction $Context $_.Exception.Message;throw}
}

function Invoke-MxhClientCandidateMerge {
    param($Context)
    $instanceDirectory=[string]$Context.Plan.Paths.InstanceDirectory
    $providerDirectory=Split-Path -Parent $instanceDirectory
    $instanceRoot=Split-Path -Parent $providerDirectory
    Write-VpsUi "将打开独立客户端配置设计器；当前实例可从受管计划列表提取：$($Context.Plan.NodeName)" Info
    Invoke-MxhClientAuthorityDesigner -ProjectRoot $Context.ProjectRoot -InstanceRoot $instanceRoot -DryRun:$Context.DryRun
}

function Invoke-MxhKomariLifecycle {
    param($Context)
    $choice=Read-VpsMenu 'Komari 完整生命周期' @('状态审计','安装/修复/轮换 Agent Token','按固定版本升级 Agent（保留 Token）','卸载 Agent','备份 Controller 数据/二进制/服务','从本地备份恢复 Controller','轮换 Cloudflare Tunnel Token','按固定版本升级 Controller（自动备份并保留数据、主题和启停状态）','卸载 Controller 与 Connector') 1 -AllowBack -HelpText @'
状态审计只读；安装、轮换、升级和卸载会修改当前 VPS。
Controller 升级会先下载一份完整本地备份，再进入事务；失败会恢复旧二进制和事务快照。
脚本验证版本、回环监听、HTTP、服务状态与 Tunnel 服务；登录、TOTP 和主题视觉效果仍需用户在浏览器最终确认。
'@
    if($Context.DryRun){Write-VpsUi 'DryRun：只显示 Komari 生命周期动作，不读取 Token、不连接服务器。' Success;return}
    $endpoint=$null
    if($choice -eq 2){
        $endpointDefault=if($Context.Plan.Komari.Endpoint){[string]$Context.Plan.Komari.Endpoint}else{[string]$Context.Versions.komari_agent.endpoint_default}
        $endpoint=Read-VpsText 'Komari 站点 HTTPS 地址' -Default $endpointDefault -AllowBack -Validate{param($v)$uri=$null;[Uri]::TryCreate($v,'Absolute',[ref]$uri)-and$uri.Scheme-eq'https'}
    }
    if($choice -eq 1){$r=Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='Status'};Write-VpsUi 'Komari 服务状态审计完成（详细结果只写入私有日志）。' Success;return}
    if($choice -in @(2,3,4,7,8,9)){Start-MxhMaintenanceTransaction $Context 'KomariLifecycle'|Out-Null}
    try{
        if($choice -eq 2){
            $secure=Read-Host 'Komari Agent Token（不显示）' -AsSecureString;$token=ConvertFrom-VpsSecureString $secure
            try{$arch=if([string]$Context.State.Audit.Architecture -in @('x86_64','amd64')){'amd64'}else{'arm64'};$asset=$Context.Versions.komari_agent.assets.$arch
                $r=Invoke-VpsRemoteScript $Context 'komari-agent.sh' @{ENDPOINT=$endpoint;TOKEN=$token;NODE_NAME=[string]$Context.Plan.NodeName;VERSION=[string]$Context.Versions.komari_agent.version;ASSET_NAME=[string]$asset.name;SHA256=[string]$asset.sha256} -TimeoutSeconds 1200 -SensitiveOutput
            }finally{$token=$null;$secure.Dispose()};$Context.Plan.Komari.Endpoint=$endpoint;$Context.Plan.Komari.Enabled=$true;$Context.State.KomariInstalled=$true
        }elseif($choice -eq 3){
            $arch=if([string]$Context.State.Audit.Architecture -in @('x86_64','amd64')){'amd64'}else{'arm64'};$asset=$Context.Versions.komari_agent.assets.$arch
            Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='AgentUpgrade';VERSION=[string]$Context.Versions.komari_agent.version;ASSET_NAME=[string]$asset.name;SHA256=[string]$asset.sha256} -TimeoutSeconds 1200|Out-Null
        }elseif($choice -eq 4){Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='AgentUninstall'}|Out-Null;$Context.Plan.Komari.Enabled=$false;$Context.State.KomariInstalled=$false
        }elseif($choice -eq 5){
            $r=Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerBackup'} -TimeoutSeconds 600;$remote=Get-VpsMarkerValue $r.StdOut KOMARI_BACKUP -Required
            $dir=Join-Path $Context.ArchivePath 'komari-backups';[IO.Directory]::CreateDirectory($dir)|Out-Null;$local=Join-Path $dir (Split-Path -Leaf $remote);Invoke-VpsScpDownload $Context $remote $local;Write-VpsUi "Controller 备份已下载：$local" Success;return
        }elseif($choice -eq 6){
            $file=Read-VpsText 'Controller 备份 tar.gz 完整路径' -AllowBack -Validate{param($v)Test-Path $v.Trim('"')};$activate=Read-VpsYesNo '恢复后启用 Controller？（同机验证可选否）' $false -AllowBack
            $remote='/root/'+(Split-Path -Leaf $file.Trim('"'));Invoke-VpsScpUpload $Context $file.Trim('"') $remote
            Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerRestore';BACKUP_FILE=$remote;FINAL_ACTIVE=$activate.ToString().ToLowerInvariant()} -TimeoutSeconds 600|Out-Null;Write-VpsUi 'Controller 数据已恢复并在回环地址完成启动验证；最终启停状态按选择应用，Tunnel 未自动启动。' Success;return
        }elseif($choice -eq 7){
            $secure=Read-Host 'Cloudflare Tunnel Token（不显示）' -AsSecureString;$token=ConvertFrom-VpsSecureString $secure
            try{Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='TunnelRotate';TUNNEL_TOKEN=$token} -TimeoutSeconds 300 -SensitiveOutput|Out-Null}finally{$token=$null;$secure.Dispose()}
        }elseif($choice -eq 8){
            $arch=if([string]$Context.State.Audit.Architecture -in @('x86_64','amd64')){'amd64'}else{'arm64'};$asset=$Context.Versions.komari_controller.assets.$arch
            $backupResult=Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerBackup'} -TimeoutSeconds 600;$remoteBackup=Get-VpsMarkerValue $backupResult.StdOut KOMARI_BACKUP -Required
            $backupDirectory=Join-Path $Context.ArchivePath 'komari-backups';[IO.Directory]::CreateDirectory($backupDirectory)|Out-Null;$localBackup=Join-Path $backupDirectory (Split-Path -Leaf $remoteBackup);Invoke-VpsScpDownload $Context $remoteBackup $localBackup
            Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerUpgrade';VERSION=[string]$Context.Versions.komari_controller.version;ASSET_NAME=[string]$asset.name;SHA256=[string]$asset.sha256} -TimeoutSeconds 1200|Out-Null
            $audit=Get-MxhHealthAudit $Context;if($audit.Status -eq 'Critical'){throw 'Komari Controller 升级后健康审计出现严重项。'}
            Write-VpsUi "升级前完整备份已下载：$localBackup" Success
        }else{
            if((Read-VpsText '输入 REMOVE-KOMARI-CONTROLLER 确认' -AllowBack)-cne 'REMOVE-KOMARI-CONTROLLER'){throw '确认短语不匹配。'}
            Invoke-VpsRemoteScript $Context 'maintenance-komari.sh' @{ACTION='ControllerUninstall'} -TimeoutSeconds 300|Out-Null
        }
        if($choice -in @(2,3,4,7,8,9)){Complete-MxhMaintenanceTransaction $Context;Save-MxhMaintenanceContext $Context}
        Write-VpsUi 'Komari 生命周期操作已提交。' Success
    }catch{if($choice -in @(2,3,4,7,8,9)){Undo-MxhMaintenanceTransaction $Context $_.Exception.Message};throw}
}

function Invoke-MxhDecommission {
    param($Context)
    $choice=Read-VpsMenu '完整退役' @('只生成退役清单和最终健康报告','停止并禁用代理协议与 Komari Agent（保留文件和 SSH）','最终备份后删除受管代理/Agent 文件（保留远端恢复点）','彻底退役受管代理/Agent，并在本地备份后清除远端恢复点','整机受管组件退役：再移除 Komari Controller/Connector，保留 SSH 与系统') 1 -AllowBack
    $report=Get-MxhHealthAudit $Context -Persist;Show-MxhHealthAudit $report
    if($choice -eq 1){Write-VpsUi '退役预检已完成，没有修改 VPS。' Success;return}
    $scope=if($choice -eq 2){'Disable'}else{'RemoveManaged'};$wipeBackups=$choice -in @(4,5);$removeController=$choice -eq 5
    if((Read-VpsText '输入 DECOMMISSION 确认' -AllowBack)-cne 'DECOMMISSION'){Write-VpsUi '未退役。' Warning;return}
    if($removeController -and (Read-VpsText '再次输入 DECOMMISSION-ALL 确认移除 Controller/Connector' -AllowBack)-cne 'DECOMMISSION-ALL'){Write-VpsUi '未执行整机退役。' Warning;return}
    if($Context.DryRun){Write-VpsUi "DryRun：将执行 $scope；SSH 和系统文件保留。" Success;return}
    $layout=(Get-MxhClientLayoutTemplate -ProjectRoot $Context.ProjectRoot).Value
    $clash=[string]$layout.authority_defaults.clash;$sing=[string]$layout.authority_defaults.sing_box
    if((Test-Path $clash) -and (Test-Path $sing)){
        $out=Join-Path $Context.ArchivePath ('decommission-client-candidate\'+(Get-Date -Format yyyyMMdd-HHmmss));[IO.Directory]::CreateDirectory($out)|Out-Null
        $python=Get-VpsCommandPath 'python.exe';$script=Join-Path $Context.ProjectRoot 'scripts\merge_client_authority.py'
        $r=Invoke-VpsProcess $python @($script,'--clash',$clash,'--sing-box',$sing,'--fragments',(Join-Path $Context.ArchivePath 'client-exports'),'--output',$out,'--roles','','--remove-prefix',[string]$Context.Plan.NodeName) -TimeoutSeconds 300
        if($r.ExitCode -ne 0){throw '无法生成退役节点删除候选，已停止远端退役。'}
        $clashCandidate=Join-Path $out 'Clash_General.candidate.yaml';$testData=Join-Path $out 'mihomo-test-data';[IO.Directory]::CreateDirectory($testData)|Out-Null
        foreach($core in @(Get-VpsMihomoCorePaths -ProjectRoot $Context.ProjectRoot)){if(Test-Path $core){$test=Invoke-VpsProcess $core @('-t','-d',$testData,'-f',$clashCandidate) -TimeoutSeconds 180;if($test.ExitCode -ne 0){throw '退役删除候选未通过 Mihomo 双核心语法测试。'}}}
        $singCandidate=Join-Path $out 'sing-box-general.candidate.json';Get-Content -Raw $singCandidate|ConvertFrom-Json|Out-Null
        if((Get-Item $singCandidate).Length-ge 4MB){throw '退役 sing-box 候选超过 4 MiB 桌面端安全上限。'}
        Protect-VpsPrivateFile $clashCandidate;Protect-VpsPrivateFile (Join-Path $out 'sing-box-general.candidate.json')
        Write-VpsUi "已先生成客户端节点删除候选：$out" Success
    }
    $transaction=Start-MxhMaintenanceTransaction $Context 'DecommissionFinal'
    $agentWasInstalled=$Context.State.Contains('KomariInstalled') -and [bool]$Context.State.KomariInstalled
    $backupDir=Join-Path $Context.ArchivePath 'decommission-backup';[IO.Directory]::CreateDirectory($backupDir)|Out-Null
    Invoke-VpsScpDownload $Context ($transaction.RemoteBackup+'/protocol-files.tar.gz') (Join-Path $backupDir ((Get-Date -Format yyyyMMdd-HHmmss)+'-managed-files.tar.gz'))
    $decommissionCommitted=$false
    try{
        $r=Invoke-VpsRemoteScript $Context 'maintenance-decommission.sh' @{SCOPE=$scope;REMOVE_CONTROLLER=$removeController.ToString().ToLowerInvariant()} -TimeoutSeconds 300
        if($r.StdOut -notmatch 'VPSDEPLOY_DECOMMISSION_OK'){throw '退役动作未确认。'}
        foreach($role in Get-MxhManagedProtocolRoles){$Context.Plan.ProtocolInventory[$role].Enabled=$false;$Context.Plan.ProtocolInventory[$role].Active=$false;if($scope -eq 'RemoveManaged'){$Context.Plan.ProtocolInventory[$role].Installed=$false}}
        $Context.Plan.Role=Get-MxhInventoryPrimaryRole $Context.Plan.ProtocolInventory
        $Context.State.ProtocolInventory=Copy-MxhHashtable $Context.Plan.ProtocolInventory
        $Context.Plan.Komari.Enabled=$false;$Context.State.KomariInstalled=if($scope -eq 'RemoveManaged'){$false}else{$agentWasInstalled}
        if([string]$Context.Plan.Firewall.Mode -ne 'PreserveExisting'){Invoke-MxhProtocolFirewall $Context (Get-MxhProtocolInventory -Plan $Context.Plan -State $Context.State) 'DecommissionFinalFirewall'}
        foreach($port in @([int]$Context.Plan.Ports.SshPrimary,[int]$Context.Plan.Ports.SshRescue)|Sort-Object -Unique){if(-not(Test-VpsSshConnection $Context root $port)){throw '退役后 SSH 复验失败。'}}
        Complete-MxhMaintenanceTransaction $Context
        $decommissionCommitted=$true
        if($wipeBackups){$final=Invoke-VpsRemoteScript $Context 'maintenance-decommission-finalize.sh' @{CONFIRM='WIPE-REMOTE-BACKUPS'} -TimeoutSeconds 180;if($final.StdOut -notmatch 'VPSDEPLOY_DECOMMISSION_FINALIZED'){throw '远端恢复点清理未确认。'}}
        $Context.State.Decommission=[ordered]@{Scope=$scope;ControllerRemoved=$removeController;RemoteBackupsWiped=$wipeBackups;At=(Get-Date).ToString('o');FinalBackup=$backupDir}
        Save-MxhMaintenanceContext $Context;Write-VpsUi '退役完成；SSH 与系统保留，最终受管文件备份已下载。' Success
    }catch{if(-not $decommissionCommitted){Undo-MxhMaintenanceTransaction $Context $_.Exception.Message};throw}
}

function Invoke-MxhMaintenanceCenter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot,[string]$PlanPath,[switch]$DryRun)
    $candidate=$PlanPath
    while($true){
        $source=Read-MxhProtocolMigrationSource -ProjectRoot $ProjectRoot -PlanPath $candidate -DryRun:$DryRun
        $context=Get-MxhMaintenanceContext $ProjectRoot $source -DryRun:$DryRun
        try{
            $choice=Read-VpsMenu '现有 VPS 运维中心' @('手动恢复中心','只读健康审计与配置漂移检测','代理凭据轮换','SSH 独立维护','防火墙独立维护','可控版本升级','客户端权威配置设计器','Komari 完整生命周期','完整退役','重新选择实例') 2 -AllowBack -HelpText @'
恢复、轮换、SSH、防火墙、升级、Komari 和退役会先建立事务/备份，再修改 VPS。
健康审计与漂移检测只读。客户端配置设计器主要操作本地文件，不连接 VPS；只有选择覆盖权威配置时才会写入所选文件。
完整退役是高风险操作，分级确认且保留 SSH；请先完成最终备份。
'@
            switch($choice){
                1{Invoke-MxhManualRestoreCenter $context}
                2{Invoke-MxhHealthAuditInteractive $context}
                3{Invoke-MxhCredentialRotation $context}
                4{Invoke-MxhSshMaintenance $context}
                5{Invoke-MxhFirewallMaintenance $context}
                6{Invoke-MxhControlledUpgrade $context}
                7{Invoke-MxhClientCandidateMerge $context}
                8{Invoke-MxhKomariLifecycle $context}
                9{Invoke-MxhDecommission $context}
                10{$candidate=$null;continue}
            }
            if(Read-VpsYesNo '继续维护当前实例？' $true){$candidate=$source.PlanPath;continue};return
        }catch{if(Test-VpsWizardBackError $_){return};throw}
    }
}
