[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot)
$ErrorActionPreference='Stop'
$checks=0
foreach($case in @(
    @{File='VpsDeploy.Core.psm1';Title='请选择操作';Count=9;Default=1;First='部署新 VPS';Last='退出'},
    @{File='VpsDeploy.Migration.ps1';Title='代理协议管理';Count=6;Default=1;First='安装并启用新协议';Last='更换 VPS'},
    @{File='VpsDeploy.Operations.ps1';Title='VPS 运维中心';Count=11;Default=2;First='从备份恢复';Last='处理未完成的维护操作'}
)){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot ('src/'+$case.File)),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Menu source does not parse'}
    $menus=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-VpsMenu' -and
        $node.CommandElements.Count -gt 3 -and $node.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.CommandElements[1].Value -eq $case.Title
    },$true))
    if($menus.Count -ne 1){throw "Menu missing or duplicated: $($case.Title)"};$checks++
    $menu=$menus[0];$labels=@($menu.CommandElements[2].SafeGetValue())
    if($labels.Count -ne $case.Count -or $menu.CommandElements[3].SafeGetValue() -ne $case.Default){throw "Menu numbering/default changed: $($case.Title)"};$checks++
    if($labels[0] -ne $case.First -or $labels[-1] -ne $case.Last){throw 'Menu actions reordered'};$checks++
    if(@($labels | Where-Object {$_ -match '生命周期|漂移|事务|凭据轮换|权威配置'}).Count){throw 'Internal terminology returned to top-level labels'};$checks++
    if($menu.Extent.Text -notmatch '-HelpText'){throw 'Menu details missing'};$checks++
}
Write-Host "Menu wording contracts passed: $checks assertions" -ForegroundColor Green
