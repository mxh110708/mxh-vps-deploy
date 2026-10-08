#nullable enable
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private async Task ChooseExistingInstallation()
    {
        var instances = store.ListInstances().Where(instance => { var status = InstanceLifecycle.Read(store, instance.RelativePath, instance.Plan); return status.Managed && !status.NeedsRecovery; }).ToArray();
        if (instances.Length == 0) { Show("先完成新机部署或接入已有 VPS，然后可在同一实例追加安装。", InfoBarSeverity.Warning); return; }
        var selection = new JsonObject();
        var dialog = OperationDialog("在已有实例追加安装", Column(Text("选择已完成部署或接入的实例。连接参数沿用归档。", 14, true), Choice("实例", selection, "Instance", instances.Select(instance => (instance.RelativePath, instance.Plan.Text("Provider") + " / " + instance.Plan.Text("Instance"))), preventWheelSelection: true)), "选择组件");
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        selectedInstance = selection.Text("Instance"); await ChooseInstallation(instances.Single(instance => instance.RelativePath == selectedInstance).Plan, false);
    }
    private async Task ChooseInstallation(JsonObject plan, bool protocolsOnly = true)
    {
        var choices = ComponentInstallations.Components.Where(component => protocolsOnly ? DeploymentPlans.Roles[..3].Contains(component) && !ComponentInstallations.ProtocolInstalled(plan, component) : DeploymentPlans.Roles[..3].Contains(component) ? !ComponentInstallations.ProtocolInstalled(plan, component) : !MaintenanceTargets.Monitoring(plan, InstanceState(selectedInstance!)).Single(target => target.Scope == component).Installed).ToArray();
        if (choices.Length == 0) { Show("所选组件均已安装，可从对应的维护入口管理。"); return; }
        var selection = new JsonObject();
        var dialog = OperationDialog(protocolsOnly ? "添加代理协议" : "追加安装组件", Column(Text(plan.Text("Provider") + " / " + plan.Text("Instance"), 17), Choice("安装组件", selection, "Component", choices.Select(component => (component, ComponentInstallations.Label(component))), preventWheelSelection: true), Text("每次只安装一个组件。代理协议可使用独立端口共存；Agent、主控和 Tunnel 分别安装。", 14, true)), "填写参数");
        if (await ShowDialog(dialog) == ContentDialogResult.Primary) await InstallationDialog(plan, selection.Text("Component"));
    }
    private async Task InstallationDialog(JsonObject plan, string component)
    {
        var relative = selectedInstance!;
        var (dialog, options) = BuildInstallationDialog(plan, relative, component);
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        ComponentInstallations.Prepare(plan, InstanceState(relative), options, ArchiveStore.ReadJson(paths.Resolve("config/versions.json")));
        await Submit(new(OperationKind.InstallComponent, relative, options));
    }
    private (ContentDialog Dialog, JsonObject Options) BuildInstallationDialog(JsonObject plan, string relative, string component)
    {
        var settings = new JsonObject();
        var options = new JsonObject { ["Component"] = component, ["Settings"] = settings, ["AssetPin"] = ArchiveStore.Fingerprint(ArchiveStore.ReadJson(paths.Resolve("config/versions.json"))) };
        var panel = Column(SectionHeading(plan.Text("NodeName"), Symbol.World, plan.Text("Provider") + " / " + plan.Text("Instance")),
            Text("沿用管理连接：" + plan.Text("Server.IPv4") + " · SSH " + InstanceState(relative).Number("CurrentManagementPort", plan.Number("Ports.SshPrimary")), 14, true));
        switch (component)
        {
            case "RealityEntry":
                settings["RealityPort"] = ComponentInstallations.ProtocolInstalled(plan, "AnyTlsEntry") && plan.Number("Ports.AnyTlsPrimary") == 443 ? 8443 : 443;
                settings["RealityBackupPort"] = 0;
                panel.Children.Add(Field("目标域名 / SNI", settings, "RealityTarget"));
                panel.Children.Add(Fields(Field("主入口端口", settings, "RealityPort", numeric: true), Field("备用端口（0 为关闭）", settings, "RealityBackupPort", numeric: true)));
                panel.Children.Add(Text("使用外部 TLS 目标；执行时审计目标。新入口使用独立端口，不停用已有 AnyTLS。", 14, true)); break;
            case "AnyTlsEntry":
                settings["AnyTlsPort"] = ComponentInstallations.ProtocolInstalled(plan, "RealityEntry") && new[] { plan.Number("Ports.XrayPrimary"), plan.Number("Ports.XrayBackup") }.Contains(443) ? 8443 : 443;
                panel.Children.Add(Fields(Field("服务器名称", settings, "AnyTlsName"), Field("ECH public name", settings, "EchPublicName")));
                panel.Children.Add(Field("新 AnyTLS 入口端口", settings, "AnyTlsPort", numeric: true));
                panel.Children.Add(Fields(Field("Cloudflare 区域", settings, "ZoneName"), Field("证书联系邮件", settings, "CertbotEmail")));
                panel.Children.Add(FileField("证书 Token 私人文件", settings, "CloudflareTokenFile"));
                panel.Children.Add(Text("两个名称使用受支持的 DNS 验证证书。独立端口可与 Reality 同时运行；保留原 Reality 配置和凭据。", 14, true)); break;
            case "ShadowsocksLanding":
                settings["LandingPort"] = 45001; settings["TransitGroup"] = "US-West Entry";
                panel.Children.Add(Field("可信入口 IP（逗号分隔）", settings, "TrustedEntries"));
                panel.Children.Add(Fields(Field("新落地 TCP / UDP 端口", settings, "LandingPort", numeric: true), Field("客户端入口组", settings, "TransitGroup")));
                panel.Children.Add(Flag("启用 IPv6 专用第二用户", settings, "SecondaryIpv6Enabled"));
                panel.Children.Add(Fields(Field("IPv6 源地址（启用第二用户时填写）", settings, "SecondaryIpv6Address"), Field("绑定网卡（可选）", settings, "SecondaryBindInterface")));
                panel.Children.Add(Text("仅允许所填可信入口连接落地。已有入口继续运行。", 14, true)); break;
            case "KomariAgent":
                panel.Children.Add(Field("Komari 主控完整地址", settings, "KomariEndpoint"));
                panel.Children.Add(Text("Agent 采集本机指标并发送到主控。请先在主控创建节点；该节点的 Agent Token 在执行时输入。", 14, true)); break;
            case "KomariController":
                settings["ControllerPort"] = 25774; panel.Children.Add(Field("主控本机 HTTP 端口", settings, "ControllerPort", numeric: true));
                panel.Children.Add(Text("主控独立保存监控数据。安装后监听 127.0.0.1，可经 SSH 转发或另行安装 Tunnel 访问。管理员用户名为 admin，密码在执行时输入，并验证登录。", 14, true)); break;
            case "Tunnel":
                panel.Children.Add(Field("公开访问网址（可选，用于归档）", settings, "PublicUrl"));
                panel.Children.Add(Text("先在 Cloudflare 创建 Tunnel，并将公开域名指向本机主控地址。这里安装连接器，执行时填写 Tunnel Token；不自动创建 Tunnel、域名或 DNS。", 14, true));
                if (plan.Number("KomariController.Port") > 0) panel.Children.Add(Text("主控服务地址：http://127.0.0.1:" + plan.Number("KomariController.Port"), 14));
                panel.Children.Add(Text("执行中会检查连接器已连接 Cloudflare。公开网址的访问规则仍由 Cloudflare 控制台管理。", 14, true)); break;
        }
        var dialog = OperationDialog("安装 " + ComponentInstallations.Label(component), DialogScroll(panel), "审阅安装");
        return (dialog, options);
    }
    private UIElement InstallationReview(OperationRequest request)
    {
        var plan = ArchiveStore.ReadJson(SafePath.Resolve(paths.Instance(request.InstanceRelativePath), "deployment-plan.json"));
        var prepared = ComponentInstallations.Prepare(plan, InstanceState(request.InstanceRelativePath), request.Options, ArchiveStore.ReadJson(paths.Resolve("config/versions.json")));
        var component = request.Options.Text("Component"); var versions = ArchiveStore.ReadJson(paths.Resolve("config/versions.json"));
        var version = versions.Text(component == "RealityEntry" ? "xray.version" : component is "AnyTlsEntry" or "ShadowsocksLanding" ? "sing_box.version" : component == "KomariAgent" ? "komari_agent.version" : component == "KomariController" ? "komari_controller.version" : "cloudflared.version");
        var panel = Column(Card(Column(Text(plan.Text("Provider") + " / " + plan.Text("Instance"), 17), Text("新增组件：" + ComponentInstallations.Label(component)), Text("固定版本：" + version), Text("管理连接：" + plan.Text("Server.IPv4") + " · SSH " + InstanceState(request.InstanceRelativePath).Number("CurrentManagementPort", plan.Number("Ports.SshPrimary"))), Text("新监听端口：" + (ComponentInstallations.ListeningPorts(prepared, component).Length == 0 ? "无入站监听" : string.Join("、", ComponentInstallations.ListeningPorts(prepared, component)))))));
        var labels = new Dictionary<string, string> { ["RealityTarget"] = "Reality 目标 / SNI", ["RealityPort"] = "主入口端口", ["RealityBackupPort"] = "备用端口", ["AnyTlsName"] = "AnyTLS 服务器名称", ["EchPublicName"] = "ECH public name", ["AnyTlsPort"] = "新入口端口", ["ZoneName"] = "证书区域", ["CertbotEmail"] = "证书联系邮件", ["CloudflareTokenFile"] = "证书 Token 文件", ["LandingPort"] = "落地端口", ["TrustedEntries"] = "可信入口", ["TransitGroup"] = "客户端入口组", ["SecondaryIpv6Enabled"] = "IPv6 第二用户", ["SecondaryIpv6Address"] = "IPv6 源地址", ["SecondaryBindInterface"] = "绑定网卡", ["KomariEndpoint"] = "Agent 主控地址", ["ControllerPort"] = "主控本机端口", ["PublicUrl"] = "公开访问网址" };
        panel.Children.Add(Card(Column(request.Options["Settings"]!.AsObject().Where(item => item.Value?.ToString() != "").Select(item => (UIElement)Text(labels[item.Key] + "：" + (item.Value?.ToString() ?? ""))).ToArray())));
        var firewallBoundary = !DeploymentPlans.Roles[..3].Contains(component) ? "监控与访问组件保留既有防火墙。主控和 Tunnel 指标端口仅监听本机回环地址。" : prepared.Text("Firewall.Mode") == "PreserveExisting" ? "既有防火墙由你放行新端口，应用保留该防火墙。" : "保留既有防火墙规则，追加新协议放行规则。";
        panel.Children.Add(Card(Column(Text("操作边界", 17), Text("保留已有协议、凭据、SSH 认证与端口、网络参数。只安装本次组件；失败按本次组件范围恢复。"), Text(component == "AnyTlsEntry" ? "快照范围：AnyTLS、可信证书及续期设置；受管防火墙补充新端口规则。已有证书与 DNS Token 保留。" : DeploymentPlans.Roles[..3].Contains(component) ? "快照范围：所选协议；受管防火墙补充新端口规则。" : "快照范围：所选监控或访问组件。", 14, true), Text(firewallBoundary, 14, true))));
        panel.Children.Add(Card(Column(Text("执行顺序", 17), Text(string.Join(" → ", OperationSteps.Create(request, plan).Select(step => step.Title)), 14, true))));
        return DialogScroll(panel);
    }
}
