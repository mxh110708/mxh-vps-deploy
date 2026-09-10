[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ProjectRoot 'src/VpsDeploy.Core.psm1') -Force
$module = Get-Module VpsDeploy.Core
& $module {
    param($root)
    $script:checks = 0
    function Check($condition, $message) {
        if (-not $condition) { throw "Interaction regression: $message" }
        $script:checks++
    }
    function Set-InputQueue([string[]]$values) {
        $script:inputs = [Collections.Generic.Queue[string]]::new()
        foreach ($value in $values) { $script:inputs.Enqueue($value) }
    }
    function Read-Host {
        param([string]$Prompt,[switch]$AsSecureString)
        if ($script:inputs.Count -eq 0) { throw 'Unexpected extra prompt' }
        $answer=$script:inputs.Dequeue()
        if ($AsSecureString) { return ConvertTo-SecureString $answer -AsPlainText -Force }
        return $answer
    }
    function Start-MxhMaintenanceTransaction { throw 'Cancellation must not start a transaction' }
    function Invoke-VpsRemoteScript { throw 'Cancellation must not access the server' }
    function Expect-Back([scriptblock]$action) {
        $returned = $false
        try { & $action } catch {
            if (-not (Test-VpsWizardBackError $_)) { throw }
            $returned = $true
        }
        Check $returned 'submenu must propagate back only from its own selection page'
        Check ($script:inputs.Count -eq 0) 'all intended levels must be visited'
    }
    try {
        Set-InputQueue @('  ')
        Check ((Read-VpsMenu 'default' @('first','second') 2) -eq 2) 'whitespace accepts default'
        $invalid = $false
        try { Read-VpsMenu 'invalid' @('first') 2 } catch [ArgumentException] { $invalid = $true }
        Check $invalid 'invalid menu default rejected before reading input'
        Set-InputQueue @('!empty')
        Check ((Read-VpsText 'optional' -Default old -AllowEmpty -AllowClear) -ceq '') 'explicit empty clears default'
        Set-InputQueue @('!empty')
        Check ((Read-VpsText 'literal' -AllowEmpty) -ceq '!empty') 'clear syntax is opt-in'
        Set-InputQueue @('0')
        Check ((Read-VpsText 'zero value' -AllowBack -ZeroIsValue) -eq '0') 'numeric zero remains data in zero-valued fields'
        Set-InputQueue @('/back')
        Expect-Back {Read-VpsText 'zero value' -AllowBack -ZeroIsValue}
        Set-InputQueue @('100','0','','y','0','n')
        $settings = Read-VpsNetworkTuningSettings RealityEntry -AllowBack
        Check ($settings.BandwidthMbps -eq 100 -and $settings.Mode -eq 'BaselineOnly') 'network fields backtrack with retained bandwidth'
        Check ($script:inputs.Count -eq 0) 'network fields visit previous question, not caller'
        Set-InputQueue @('0')
        Expect-Back { Read-VpsNetworkTuningSettings RealityEntry -AllowBack }
        $context = @{DryRun=$false; State=@{}; Plan=@{Firewall=@{Mode='PreserveExisting'};Shadowsocks=@{TrustedEntryIPv4s=@();TrustedEntryIPv6s=@()}}}
        Set-InputQueue @('2','0','0')
        Expect-Back { Invoke-MxhFirewallMaintenance $context }
        Check ($context.Plan.Firewall.Mode -eq 'PreserveExisting') 'cancelled adoption leaves plan unchanged'
        Set-InputQueue @('9','0','9','WRONG','0')
        Expect-Back { Invoke-MxhKomariLifecycle $context }
        function Get-MxhProtocolInventory { return @{RealityEntry=@{Installed=$true;Active=$true}} }
        function Get-MxhManagedProtocolRoles { return @('RealityEntry') }
        Set-InputQueue @('1','0','0')
        Expect-Back { Invoke-MxhCredentialRotation $context }
        $context.Plan.Reality=@{XrayVersion='test'}
        $context.State=@{}
        $context.Versions=@{xray=@{version='test'}}
        Set-InputQueue @('1','0','0')
        Expect-Back { Invoke-MxhControlledUpgrade $context }
        $context.Plan.Ports=@{SshPrimary=30123;SshRescue=31234}
        Set-InputQueue @('2','0','0')
        Expect-Back { Invoke-MxhSshMaintenance $context }
        function Get-MxhHealthAudit { return @{} }
        function Show-MxhHealthAudit {}
        Set-InputQueue @('2','0','0')
        Expect-Back { Invoke-MxhDecommission $context }
        # The editor reloads its unsaved draft after cancellation without persisting it.
        Set-InputQueue @('2','0','0')
        Invoke-MxhEditClientLayoutDefaults -ProjectRoot $root
        Check ($script:inputs.Count -eq 0) 'defaults field returns to defaults menu'
        Set-InputQueue @('3','Example-Landing','192.0.2.30','46936','','example-test-password','0','revised-test-password','1')
        $node=New-MxhManualClientNode -RegionGroups @('Example Entry')
        Check ($node.kind -eq 'landing' -and $node.sing_box.password -eq 'revised-test-password') 'manual node backtracks to previous visible secret field'
        Check ($script:inputs.Count -eq 0) 'manual node skips irrelevant protocol fields when backing up'
        Set-InputQueue @('1','0','3','Example-Switch','192.0.2.31','','','example-test-password','1')
        $node=New-MxhManualClientNode -RegionGroups @('Example Entry')
        Check ($node.kind -eq 'landing' -and $node.sing_box.server_port -eq 46936) 'changing protocol resets dependent defaults'
        Set-InputQueue @('2','Example-AnyTLS','192.0.2.32','','example-test-password','example.invalid','invalid!','dGVzdA==','1')
        $node=New-MxhManualClientNode -RegionGroups @('Example Entry')
        Check ($node.sing_box.type -eq 'anytls' -and $script:inputs.Count -eq 0) 'invalid ECH retries current field'
        function Get-MxhProtocolInventory { return @{RealityEntry=@{Installed=$true;Active=$false;Enabled=$false}} }
        function New-MxhProtocolLifecyclePlan { return @{Migration=@{FinalInventory=@{}}} }
        function Show-MxhProtocolInventory {}
        $source=@{Plan=@{};State=@{};Inventory=@{};PlanPath='fixture.json'}
        Set-InputQueue @('1','1','0','0','0')
        Expect-Back { New-MxhProtocolStateDetails $source }
        Set-InputQueue @('1','0','1','WRONG','0')
        Expect-Back { New-MxhProtocolUninstallDetails $source }
        Set-InputQueue @('0')
        Expect-Back { New-MxhManualClientNode -RegionGroups @('Example Entry') }
        $cancelled=$false
        try { Read-VpsForm @(@{Key='value';Read={throw [OperationCanceledException]::new('__MXH_VPS_WIZARD_CANCEL__')}}) } catch [OperationCanceledException] {$cancelled=$true}
        Check $cancelled 'form does not swallow cancellation as back navigation'
        $testDirectory=Join-Path $root ('.tmp/interaction-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($testDirectory)|Out-Null
        $path=Join-Path $testDirectory 'state.json'
        try {
            Save-VpsJson @{version=1} $path
            Save-VpsJson @{version=2} $path
            Check ((Read-VpsJsonHashtable $path).version -eq 2) 'JSON replacement remains readable'
            function Protect-VpsPrivateFile { throw 'Simulated ACL failure' }
            $failed=$false
            try { Save-VpsJson @{version=3} $path -Private } catch { $failed=$true }
            Check $failed 'private save propagates ACL failure'
            Check ((Read-VpsJsonHashtable $path).version -eq 2) 'failed private save preserves previous file'
            Check (@(Get-ChildItem -LiteralPath $testDirectory).Count -eq 1) 'failed save cleans temporary file'
        } finally {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            [IO.Directory]::Delete($testDirectory, $false)
        }
        Write-Host "Interaction tests passed: $script:checks assertions" -ForegroundColor Green
    } finally {
        Remove-Variable inputs,checks -Scope Script -ErrorAction SilentlyContinue
    }
} $ProjectRoot
