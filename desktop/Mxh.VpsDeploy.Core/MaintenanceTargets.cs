using System.Text.Json.Nodes;

namespace Mxh.VpsDeploy.Core;

public sealed record ProxyCoreTarget(string Protocol, string Name, string Service, string ArchivedVersion, string TargetVersion, bool Enabled);
public sealed record MonitoringTarget(string Scope, string Name, string Description, bool Installed);

public static class MaintenanceTargets
{
    public static IReadOnlyList<ProxyCoreTarget> ProxyCores(JsonObject plan, JsonObject versions) => DeploymentPlans.Roles[..3]
        .Where(role => plan.Flag("ProtocolInventory." + role + ".Installed", plan.Text("Role") == role))
        .Select(role => new ProxyCoreTarget(role, role == "RealityEntry" ? "Xray · Reality 入口" : role == "AnyTlsEntry" ? "sing-box · AnyTLS / ECH 入口" : "sing-box · Shadowsocks 落地",
            role == "RealityEntry" ? "xray" : role == "AnyTlsEntry" ? "sing-box-anytls" : "sing-box",
            plan.Text(role == "RealityEntry" ? "Reality.XrayVersion" : role == "AnyTlsEntry" ? "AnyTls.SingBoxVersion" : "Shadowsocks.SingBoxVersion", "未记录"),
            versions.Text(role == "RealityEntry" ? "xray.version" : "sing_box.version"),
            plan.Flag("ProtocolInventory." + role + ".Enabled", plan.Text("Role") == role))).ToArray();
    public static IReadOnlyList<MonitoringTarget> Monitoring(JsonObject plan, JsonObject state) =>
    [
        new("KomariAgent", "Komari Agent", "采集当前 VPS 的运行指标，发送给 Komari 主控。", state.Flag("KomariInstalled", plan.Flag("Komari.Enabled"))),
        new("KomariController", "Komari 主控", "在当前 VPS 保存监控数据、提供网页面板。", state.Flag("KomariController.Installed")),
        new("Tunnel", "Cloudflare Tunnel", "将当前 VPS 上的主控网页连接到 Cloudflare 访问入口。", state.Flag("Cloudflared.Installed"))
    ];
    public static string TargetVersion(string scope, JsonObject versions) => scope switch
    {
        "KomariAgent" => versions.Text("komari_agent.version"), "KomariController" => versions.Text("komari_controller.version"), _ => ""
    };
    public static void Validate(OperationRequest request, JsonObject plan, JsonObject state, JsonObject versions)
    {
        OperationPolicy.Validate(request);
        if (request.Kind == OperationKind.Upgrade)
        {
            var target = ProxyCores(plan, versions).SingleOrDefault(t => t.Protocol == request.Options.Text("Protocol"));
            if (target == null) throw new OperationException("请选择已安装的代理核心。");
            if (!target.Enabled) throw new OperationException("请先启用对应协议，再升级并完成独立验收。");
            if (request.Options.Text("TargetVersion") != target.TargetVersion) throw new OperationException("升级目标版本发生变化，请重新审阅。", code: "TargetVersionChanged");
        }
        if (request.Kind == OperationKind.Komari)
        {
            var target = Monitoring(plan, state).Single(t => t.Scope == request.Options.Text("Scope"));
            if (!target.Installed) throw new OperationException("当前实例没有此组件的受管安装记录。请先通过接入或健康检查核对实际状态。", code: "ComponentNotManaged");
            if (request.Options.Text("Action") == "Upgrade" && request.Options.Text("TargetVersion") != TargetVersion(target.Scope, versions)) throw new OperationException("升级目标版本发生变化，请重新审阅。", code: "TargetVersionChanged");
            if (request.Options.Text("Action") == "Restore" && request.Options.Text("Backup") == "") throw new OperationException("请选择主控专用恢复点。");
        }
    }
}
