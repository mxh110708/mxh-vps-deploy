using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private readonly DeploymentNaming deploymentNaming = new();
    private void Deployment()
    {
        var existing = deploymentForm.Flag("Existing");
        deploymentForm["NodeName"] = deploymentNaming.Update(deploymentForm.Text("Provider"), deploymentForm.Text("Instance"), deploymentForm.Text("NodeName"));
        var provider = Field("服务商", deploymentForm, "Provider"); var instance = Field("实例名称", deploymentForm, "Instance"); var nodeName = Field("节点名称", deploymentForm, "NodeName");
        void SuggestName() { nodeName.Text = deploymentNaming.Update(deploymentForm.Text("Provider"), deploymentForm.Text("Instance"), nodeName.Text); }
        provider.TextChanged += (_, _) => SuggestName(); instance.TextChanged += (_, _) => SuggestName();
        nodeName.LostFocus += (_, _) => { if (nodeName.Text.Trim() == "") SuggestName(); };
        page.Children.Add(Row(Action("部署新 VPS", () => { deploymentForm["Existing"] = false; Navigate("deploy"); return Task.CompletedTask; }, !existing), Action("接入已有 VPS", () => { deploymentForm["Existing"] = true; Navigate("deploy"); return Task.CompletedTask; }, existing), Action("已有实例追加安装", ChooseExistingInstallation)));
        page.Children.Add(Card(Column(SectionHeading("连接信息", Symbol.World, existing ? "读取已有配置，并建立本地受管归档。" : "填写实例信息，执行时再输入连接凭据。"),
            Fields(provider, instance, nodeName, Field("当前 root SSH 端口", deploymentForm, "SshPort", "22", true), Field("IPv4", deploymentForm, "IPv4"), Field("IPv6（可选）", deploymentForm, "IPv6")), Text("节点名根据服务商和实例生成；修改后保留你的命名。SSH 端口填写现在已能登录的端口。", 14, true), FileField("SSH 私钥（可选，留空使用密码）", deploymentForm, "KeyPath"))));
        if (!existing)
        {
            var roles = deploymentForm["Roles"] is JsonArray ? deploymentForm.Strings("Roles") : new[] { deploymentForm.Text("Role", "RealityEntry") };
            var selection = new List<UIElement>();
            foreach (var role in DeploymentPlans.Roles[..3])
            {
                var box = DesktopTypography.Mark(new CheckBox { Content = RoleLabel(role), IsChecked = roles.Contains(role), Tag = "Purpose." + role }, TypeRole.Body, 14);
                void Change(bool enabled)
                {
                    var updated = roles.Where(r => r != role && r != "MonitorOnly").ToList(); if (enabled) updated.Add(role);
                    deploymentForm["Roles"] = new JsonArray(DeploymentPlans.Roles[..3].Where(updated.Contains).Select(r => (JsonNode?)JsonValue.Create(r)).ToArray());
                    var entries = updated.Where(r => r is "RealityEntry" or "AnyTlsEntry").ToArray();
                    if (!entries.Contains(deploymentForm.Text("ActiveEntry"))) deploymentForm["ActiveEntry"] = entries.FirstOrDefault() ?? "";
                    Navigate("deploy");
                }
                box.Checked += (_, _) => Change(true); box.Unchecked += (_, _) => Change(false); selection.Add(box);
            }
            var monitor = Flag("Komari 监控 Agent", deploymentForm, "KomariEnabled"); monitor.Checked += (_, _) => Navigate("deploy"); monitor.Unchecked += (_, _) => Navigate("deploy"); selection.Add(monitor);
            page.Children.Add(Card(Column(SectionHeading("用途组合", Symbol.Setting, "可以同时选择入口、落地与监控；不选代理协议时只做基础维护。"), Fields(selection.Cast<FrameworkElement>().ToArray()))));
            if (roles.Contains("RealityEntry") && roles.Contains("AnyTlsEntry"))
                page.Children.Add(Card(Column(Choice("默认启用的入口", deploymentForm, "ActiveEntry", [("RealityEntry", "Reality"), ("AnyTlsEntry", "AnyTLS / ECH")]), Text("两个入口都会安装并归档。当前只启用所选入口，之后可在实例页切换。", 14, true))));
            if (roles.Contains("RealityEntry"))
            {
                var local = Flag("使用自己的域名与本机 HTTPS 目标", deploymentForm, "LocalTarget"); local.Checked += (_, _) => Navigate("deploy"); local.Unchecked += (_, _) => Navigate("deploy");
                page.Children.Add(Card(Column(SectionHeading("Reality 入口", Symbol.Link), Field("目标域名 / SNI", deploymentForm, "RealityTarget"), local,
                    Details("Reality 端口", Fields(Field("主入口端口", deploymentForm, "RealityPort", "443", true), Field("备用端口（空为自动，0 为关闭）", deploymentForm, "RealityBackupPort", numeric: true))))));
            }
            if (roles.Contains("AnyTlsEntry")) page.Children.Add(Card(Column(SectionHeading("AnyTLS / ECH 入口", Symbol.Link), Fields(Field("服务器名称", deploymentForm, "AnyTlsName"), Field("ECH public name", deploymentForm, "EchPublicName")), Field("入口端口", deploymentForm, "AnyTlsPort", "443", true))));
            if (roles.Contains("ShadowsocksLanding")) page.Children.Add(Card(Column(SectionHeading("Shadowsocks 落地", Symbol.Link), Field("可信入口地址（逗号分隔）", deploymentForm, "TrustedEntries"),
                Fields(Field("落地 TCP / UDP 端口", deploymentForm, "LandingPort", "45001", true), Field("入口组", deploymentForm, "TransitGroup", "US-West Entry")),
                Details("IPv6 专用出口用户", Column(Flag("启用第二用户", deploymentForm, "SecondaryIpv6Enabled"), Fields(Field("IPv6 源地址", deploymentForm, "SecondaryIpv6Address"), Field("绑定网卡（可选）", deploymentForm, "SecondaryBindInterface")))))));
            if (roles.Contains("AnyTlsEntry") || roles.Contains("RealityEntry") && deploymentForm.Flag("LocalTarget")) page.Children.Add(Card(Column(SectionHeading("可信证书", Symbol.Permissions), Fields(Field("Cloudflare 区域", deploymentForm, "ZoneName"), Field("证书联系邮件", deploymentForm, "CertbotEmail")), FileField("证书 Token 私人文件", deploymentForm, "CloudflareTokenFile"))));
            if (deploymentForm.Flag("KomariEnabled")) page.Children.Add(Card(Column(SectionHeading("监控连接", Symbol.World), Field("Komari 主控地址", deploymentForm, "KomariEndpoint"), Text("填写完整的 HTTP/HTTPS 主控地址；Agent Token 在执行时单独输入。", 14, true))));
        }
        else page.Children.Add(Card(SectionHeading("接入已有实例", Symbol.Library, "连接后读取远端配置，生成应用内归档，并保留现有 SSH、服务与防火墙。")));
        page.Children.Add(Text("网络调优已独立到左侧入口，部署和接入均不自动修改网络参数。", 14, true));
        pageAction.Content = Action("审阅计划", async () =>
        {
            var plan = DeploymentPlans.Create(deploymentForm, ArchiveStore.ReadJson(paths.Resolve("config/versions.json")), paths, existing);
            var relative = plan.Text("Provider") + "/" + plan.Text("Instance") + "/MXH-VPS-Deploy";
            await Submit(new(existing ? OperationKind.ConnectExisting : OperationKind.Deploy, relative, new JsonObject { ["Plan"] = plan }));
        }, true);
    }

    private void NetworkPage()
    {
        var instances = store.ListInstances().Where(instance => { var status = InstanceLifecycle.Read(store, instance.RelativePath, instance.Plan); return status.Managed && !status.NeedsRecovery; }).ToArray();
        if (instances.Length == 0) { page.Children.Add(Card(Column(SectionHeading("选择已部署的实例", Symbol.Globe, "部署完成或接入已有 VPS 后，可以在这里单独调优。"), Action("查看实例", () => { SelectPage("instances"); return Task.CompletedTask; })))); return; }
        var selection = new JsonObject { ["Instance"] = instances.Any(i => i.RelativePath == selectedInstance) ? selectedInstance : instances[0].RelativePath };
        var picker = Choice("目标实例", selection, "Instance", instances.Select(i => (i.RelativePath, i.Plan.Text("Provider") + " / " + i.Plan.Text("Instance"))), preventWheelSelection: true);
        var panel = new StackPanel { Spacing = 20 }; page.Children.Add(picker); page.Children.Add(panel);
        void Refresh()
        {
            selectedInstance = selection.Text("Instance"); var plan = instances.First(i => i.RelativePath == selectedInstance).Plan; panel.Children.Clear();
            var storedBandwidth = plan.Number("NetworkTuning.BandwidthMbps");
            var options = new JsonObject { ["Scope"] = "Network", ["BandwidthMbps"] = storedBandwidth > 0 ? storedBandwidth : 100, ["ReferenceRttMs"] = plan.Number("NetworkTuning.ReferenceRttMs"), ["Mode"] = plan.Number("NetworkTuning.ReferenceRttMs") > 0 ? "Adaptive" : "Baseline" };
            panel.Children.Add(Card(SectionHeading(plan.Text("NodeName"), Symbol.World, "网络调优为独立维护任务，执行前会备份并审阅。")));
            var stateFile = SafePath.Resolve(paths.Instance(selectedInstance), "deployment-state.json"); var state = File.Exists(stateFile) ? ArchiveStore.ReadJson(stateFile) : new JsonObject();
            panel.Children.Add(SettingsGroup(SettingRow("本地调优记录", state["NetworkTuning"] == null ? "尚无已执行的调优记录" : state.Text("NetworkTuning.PROFILE"), Symbol.Clock, Text("运行状态以健康检查为准", 14, true))));
            var mode = Choice("调优方式", options, "Mode", [("Baseline", "基础网络配置"), ("Adaptive", "按带宽与 RTT 估算")]);
            var rtt = Field("参考 RTT（ms）", options, "ReferenceRttMs", numeric: true); rtt.IsEnabled = options.Text("Mode") == "Adaptive";
            mode.SelectionChanged += (_, _) => { rtt.IsEnabled = options.Text("Mode") == "Adaptive"; if (!rtt.IsEnabled) rtt.Text = "0"; };
            panel.Children.Add(Card(Column(SectionHeading("调优参数", Symbol.Setting), mode, Fields(Field("套餐标称带宽（Mbps）", options, "BandwidthMbps", numeric: true), rtt), Text("估算模式受目标内存上限约束。基础模式不推算链路缓冲；不会自动运行公网测速。", 14, true))));
            panel.Children.Add(Card(Column(SectionHeading("本次范围", Symbol.Permissions, "仅调整部署器管理的网络参数文件。协议、SSH、防火墙和监控保持当前配置。"), Action("只读健康检查", () => Submit(new(OperationKind.HealthAudit, selectedInstance!, new()))))));
            pageAction.Content = Action("审阅调优", () => Submit(new(OperationKind.TuneNetwork, selectedInstance!, options)), true);
        }
        picker.SelectionChanged += (_, _) => Refresh(); Refresh();
    }
}
