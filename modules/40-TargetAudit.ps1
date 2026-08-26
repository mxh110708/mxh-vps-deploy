@{
    Id        = 'target-audit'
    Name      = '审计 REALITY target（失败可显式人工覆写）'
    Order     = 40
    Roles     = @('RealityEntry')
    Requires  = @('ssh-transition')
    IsEnabled = {
        param($Context)
        -not $Context.Plan.Reality.Contains('TargetMode') -or $Context.Plan.Reality.TargetMode -ne 'LocalOwnedTls'
    }
    Invoke    = {
        param($Context)
        while ($true) {
            $parameters = @{
                TARGET = [string]$Context.Plan.Reality.Target
                SAMPLES = [string]$Context.Plan.Reality.TargetSamples
                MAX_MEDIAN_MS = [string]$Context.Plan.Reality.TargetMaxMedianMs
            }
            $result = Invoke-VpsRemoteScript -Context $Context -Asset 'target-audit.sh' -Parameters $parameters -TimeoutSeconds 900
            $encodedMatch = [regex]::Match($result.StdOut, '(?m)^VPSDEPLOY_TARGET_JSON_B64=([A-Za-z0-9+/=]+)$')
            if (-not $encodedMatch.Success) { throw 'target 审计结果无法解析。' }
            $auditJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value))
            $audit = $auditJson | ConvertFrom-Json -AsHashtable
            $audit['manual_override'] = $false
            $audit['override_reason'] = $null
            $audit['override_at'] = $null
            Save-VpsJson -Value $audit -Path (Join-Path $Context.ArchivePath 'target-audit.json') -Private
            $Context.State.TargetAudit = $audit
            Save-VpsContext -Context $Context

            Write-Host ''
            Write-Host 'Reality target 审计结果' -ForegroundColor White
            Write-Host "  Target：$($audit.target)"
            Write-Host "  解析地址：$($audit.remote_ip)"
            Write-Host "  CNAME：$(if ($audit.cname) { $audit.cname } else { '<none>' })"
            Write-Host "  TLS 1.3：$($audit.tls13)"
            Write-Host "  ALPN h2：$($audit.alpn_h2)"
            Write-Host "  证书验证：$($audit.certificate_verify_ok)"
            Write-Host "  HTTP：$($audit.http_code) / $($audit.http_version)"
            Write-Host "  最终 URL：$($audit.effective_url)"
            Write-Host "  跨域跳转：$($audit.cross_host_redirect)"
            Write-Host "  握手：$($audit.success_count)/$($audit.sample_count) 成功，失败 $($audit.failure_count)"
            Write-Host "  时延：中位 $($audit.median_ms) ms / P95 $($audit.p95_ms) ms / 最大 $($audit.max_ms) ms"
            if ($audit.shared_cdn_indicators.Count -gt 0) {
                Write-VpsUi "共享 CDN 特征：$($audit.shared_cdn_indicators -join ', ')" Warning
            }
            if ($audit.automatic_pass) {
                Write-VpsUi '该候选通过自动规则；最终仍需真实 Reality Authentication、HTTP 204 和出口测试。' Success
                break
            }

            Write-VpsUi '该候选未通过自动规则。脚本建议更换；人工覆写不会绕过后续真实 Reality 握手与出口验收。' Error
            if ($Context.NonInteractive) { throw 'REALITY target 未通过自动审计，非交互模式禁止人工覆写。' }
            $choice = Read-VpsMenu '如何处理该审计结果' @(
                '输入另一个候选并重新测试（推荐）',
                '人工接受当前结果并继续部署',
                '停止本次操作'
            ) 1 -AllowBack
            if ($choice -eq 1) {
                $newTarget = Read-VpsText '新的 target 域名' -AllowBack -Validate {
                    param($v) $v -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -and $v.Contains('.')
                }
                Set-MxhRealityExternalTarget -Plan $Context.Plan -Target $newTarget
                Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
                continue
            }
            if ($choice -eq 3) { throw '用户根据 target 审计结果停止部署。' }

            Write-VpsUi '高风险覆写：TLS 1.3、h2、证书、跨域跳转、共享 CDN、失败率或时延中至少一项不符合自动标准。' Warning
            $phrase = Read-VpsText '输入 ACCEPT-TARGET-RISK 确认人工覆写' -AllowBack
            if ($phrase -cne 'ACCEPT-TARGET-RISK') {
                Write-VpsUi '确认短语不匹配，返回处理选项。' Warning
                continue
            }
            $reason = Read-VpsText '填写人工接受原因（写入私有审计记录）' -AllowBack -Validate {
                param($v) -not [string]::IsNullOrWhiteSpace($v) -and $v.Trim().Length -ge 5
            } -ValidationMessage '请至少填写 5 个字符的原因。'
            $audit.manual_override = $true
            $audit.override_reason = $reason.Trim()
            $audit.override_at = (Get-Date).ToString('o')
            Save-VpsJson -Value $audit -Path (Join-Path $Context.ArchivePath 'target-audit.json') -Private
            $Context.State.TargetAudit = $audit
            $Context.Plan.Reality['TargetAuditManualOverride'] = [ordered]@{
                Target = [string]$audit.target
                AcceptedAt = [string]$audit.override_at
                Reason = [string]$audit.override_reason
            }
            Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
            Save-VpsContext -Context $Context
            Write-VpsUi '已记录人工覆写；如果真实 Reality 握手或出口失败，部署仍会停止并回滚。' Warning
            break
        }
    }
}
