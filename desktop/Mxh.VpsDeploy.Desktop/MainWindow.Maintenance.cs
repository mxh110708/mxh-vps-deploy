using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private JsonObject InstanceState(string relative)
    {
        var file = SafePath.Resolve(paths.Instance(relative), "deployment-state.json");
        return File.Exists(file) ? ArchiveStore.ReadJson(file) : new();
    }
    private (ContentDialog Dialog, JsonObject Options) CoreUpgradeDialog(JsonObject plan)
    {
        var targets = MaintenanceTargets.ProxyCores(plan, ArchiveStore.ReadJson(paths.Resolve("config/versions.json")));
        var options = new JsonObject { ["Scope"] = "Protocol" };
        var selector = Choice("升级对象", options, "Protocol", targets.Select(t => (t.Protocol, t.Name)), preventWheelSelection: true);
        var details = new StackPanel { Spacing = 12 };
        var dialog = OperationDialog("代理核心升级", DialogScroll(Column(Text(plan.Text("Provider") + " / " + plan.Text("Instance"), 17),
            Text("升级此 VPS 上运行代理协议的核心程序。请选择具体服务并核对版本。", 14, true), selector, details)), "审阅升级");
        void Refresh()
        {
            details.Children.Clear(); options.Remove("TargetVersion");
            var target = targets.FirstOrDefault(t => t.Protocol == options.Text("Protocol"));
            dialog.IsPrimaryButtonEnabled = target?.Enabled == true;
            if (target == null) { details.Children.Add(Text("此实例还没有受管代理核心。")); return; }
            options["TargetVersion"] = target.TargetVersion;
            details.Children.Add(Card(Column(Text(target.Name, 17),
                Text("归档版本：" + target.ArchivedVersion, 14, true), Text("升级目标：" + target.TargetVersion, 18),
                Text("服务：" + target.Service, 13, true))));
            details.Children.Add(Text(target.Enabled ? "执行前核对远端状态并备份，再更新程序、重启此服务并完成独立验收。" : "该协议在归档中处于停用状态。请先在协议管理中启用，再升级并验收。", 14, true));
            if (target.ArchivedVersion == target.TargetVersion) details.Children.Add(Text("归档版本已与目标一致；继续将重新安装并校验此版本。", 14, true));
            details.Children.Add(Text("这里显示本地归档版本，目标是应用支持的固定版本。协议恢复点包含本机受管代理协议，回滚前会核对范围。", 13, true));
        }
        selector.SelectionChanged += (_, _) => Refresh(); Refresh(); return (dialog, options);
    }
    private async Task UpgradeCore(JsonObject plan)
    {
        var relative = selectedInstance!; var sheet = CoreUpgradeDialog(plan);
        if (await ShowDialog(sheet.Dialog) == ContentDialogResult.Primary) await Submit(new(OperationKind.Upgrade, relative, sheet.Options));
    }
    private UIElement MonitoringControls(JsonObject plan, JsonObject state)
    {
        var rows = MaintenanceTargets.Monitoring(plan, state).Select(target =>
        {
            var needsCheck = target.RequiresVerification || !target.Installed && state.Flag("MonitoringInventory." + (target.Scope == "Tunnel" ? "Cloudflared" : target.Scope) + ".Installed");
            var button = needsCheck
                ? Action("核对并纳管", () => Submit(new(OperationKind.HealthAudit, selectedInstance!, new())))
                : target.Installed ? Action(target.Scope == "KomariAgent" ? "管理 Agent" : target.Scope == "KomariController" ? "管理主控" : "管理 Tunnel", () => ManageMonitoring(plan, target.Scope))
                : Action(target.Scope == "KomariAgent" ? "安装 Agent" : target.Scope == "KomariController" ? "安装主控" : "安装 Tunnel", () => InstallationDialog(plan, target.Scope));
            return SettingRow(target.Name, target.Status + " · " + target.Description, target.Scope == "Tunnel" ? Symbol.Link : Symbol.View, button);
        }).ToArray();
        var group = SettingsGroup(rows);
        return MaintenanceTargets.Monitoring(plan, state).Single(t => t.Scope == "Tunnel").Installed ? Column(group, TunnelAccessPanel(plan, state)) : group;
    }
    private (ContentDialog Dialog, JsonObject Options) MonitoringDialog(JsonObject plan, JsonObject state, string scope)
    {
        var target = MaintenanceTargets.Monitoring(plan, state).Single(t => t.Scope == scope);
        if (!target.Installed) throw new OperationException("当前实例没有此组件的受管安装记录。请先核对实际状态。");
        var versions = ArchiveStore.ReadJson(paths.Resolve("config/versions.json"));
        var options = new JsonObject { ["Scope"] = scope };
        var actions = Choice("操作", options, "Action", scope switch
        {
            "KomariAgent" => [("Upgrade", "升级 Agent"), ("Remove", "卸载 Agent")],
            "KomariController" => [("Upgrade", "升级主控"), ("Backup", "创建主控一致性备份"), ("Restore", "恢复主控专用备份")],
            _ => [("RotateToken", "轮换 Tunnel 连接 Token")]
        }, preventWheelSelection: true);
        var details = new StackPanel { Spacing = 12 };
        var dialog = OperationDialog(target.Name, DialogScroll(Column(Text(plan.Text("Provider") + " / " + plan.Text("Instance"), 17),
            Text(target.Description, 14, true), actions, details)), "审阅操作");
        void Refresh()
        {
            details.Children.Clear(); options.Remove("Backup"); options.Remove("TargetVersion"); dialog.IsPrimaryButtonEnabled = true;
            if (options.Text("Action") == "Upgrade")
            {
                options["TargetVersion"] = MaintenanceTargets.TargetVersion(scope, versions);
                details.Children.Add(Card(Column(Text("升级对象：" + target.Name, 16), Text("目标版本：" + options.Text("TargetVersion"), 18), Text("更新此程序，保留原配置及启停状态。", 14, true))));
            }
            if (scope == "KomariController")
            {
                details.Children.Add(Text("一致性备份、升级和恢复会短暂停止当前 VPS 的主控，完成后恢复原启停状态。只包含主控程序与数据。", 14, true));
                if (options.Text("Action") == "Restore")
                {
                    var root = SafePath.Resolve(paths.Instance(selectedInstance!), "komari-backups");
                    if (Directory.Exists(root)) SafePath.CheckTree(root);
                    var backups = Directory.Exists(root) ? Directory.EnumerateFiles(root, "*.json").Select(ArchiveStore.ReadJson).Where(b => b.At("IncludeTunnel") != null && !b.Flag("IncludeTunnel") && b.Text("RemoteBackup") != "").ToArray() : [];
                    details.Children.Add(Choice("主控专用恢复点", options, "Backup", backups.Select(b => (b.Text("RemoteBackup"), LocalTime(b.Text("At")))), preventWheelSelection: true));
                    dialog.IsPrimaryButtonEnabled = backups.Length > 0;
                    if (backups.Length == 0) details.Children.Add(Text("还没有主控专用恢复点。请先创建一致性备份。", 14, true));
                }
            }
            if (scope == "KomariAgent" && options.Text("Action") == "Remove") details.Children.Add(Text("卸载本机 Agent 并停止上报。主控中保存的历史数据不会删除；以后重新部署 Agent 才会恢复上报。", 14, true));
            if (scope == "Tunnel") details.Children.Add(Text("只更新本机 Tunnel 的连接 Token，并重启 Tunnel。新 Token 在执行时输入；不会修改 Cloudflare DNS。", 14, true));
            details.Children.Add(Text(scope == "KomariController" ? "Agent 和 Tunnel 分别维护，不包含在主控备份与恢复中。" : scope == "KomariAgent" ? "这里不升级代理核心，也不操作监控主控或 Tunnel。" : "主控程序、监控数据和 Agent 保持原配置。", 13, true));
        }
        actions.SelectionChanged += (_, _) => Refresh(); Refresh(); return (dialog, options);
    }
    private async Task ManageMonitoring(JsonObject plan, string scope)
    {
        var relative = selectedInstance!; var sheet = MonitoringDialog(plan, InstanceState(relative), scope);
        if (await ShowDialog(sheet.Dialog) == ContentDialogResult.Primary) await Submit(new(OperationKind.Komari, relative, sheet.Options));
    }
}
