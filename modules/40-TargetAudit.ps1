@{
    Id        = 'target-audit'
    Name      = '严格审计 REALITY target'
    Order     = 40
    Roles     = @('RealityEntry')
    Requires  = @('ssh-transition')
    IsEnabled = { param($Context) $true }
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
            Save-VpsJson -Value $audit -Path (Join-Path $Context.ArchivePath 'target-audit.json') -Private
            $Context.State.TargetAudit = $audit
            Save-VpsContext -Context $Context

            Write-VpsUi ("TLS 1.3={0}，h2={1}，证书={2}，HTTP={3}" -f $audit.tls13, $audit.alpn_h2, $audit.certificate_verify_ok, $audit.http_code) Info
            Write-VpsUi ("握手 {0}/{1} 成功，中位={2} ms，P95={3} ms，最大={4} ms" -f $audit.success_count, $audit.sample_count, $audit.median_ms, $audit.p95_ms, $audit.max_ms) Info
            if ($audit.shared_cdn_indicators.Count -gt 0) {
                Write-VpsUi "共享 CDN 特征：$($audit.shared_cdn_indicators -join ', ')" Warning
            }
            if ($audit.automatic_pass) {
                Write-VpsUi '该候选通过自动强制项；最终仍需真实 REALITY 握手。' Success
                break
            }

            Write-VpsUi '候选未通过：TLS/h2/证书/跳转/CDN/失败次数/15 ms 门槛中至少一项不合格。' Error
            if ($Context.NonInteractive -or -not (Read-VpsYesNo '是否立即输入另一个候选并重新测试？' $true)) {
                throw 'REALITY target 未通过严格审计。'
            }
            $newTarget = Read-VpsText '新的 target 域名' -Validate {
                param($v) $v -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -and $v.Contains('.')
            }
            $Context.Plan.Reality.Target = $newTarget
            Save-VpsJson -Value $Context.Plan -Path $Context.PlanPath -Private
        }
    }
}
