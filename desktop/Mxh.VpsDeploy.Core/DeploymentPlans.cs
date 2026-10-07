using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Mxh.VpsDeploy.Core;

public static class DeploymentPlans
{
    public static readonly string[] Roles = ["RealityEntry", "AnyTlsEntry", "ShadowsocksLanding", "MonitorOnly"];
    public static JsonObject Create(JsonObject form, JsonObject versions, AppPaths paths, bool existing)
    {
        var provider = AppPaths.Segment(form.Text("Provider")); var instance = AppPaths.Segment(form.Text("Instance"));
        var relative = provider + "/" + instance + "/MXH-VPS-Deploy";
        var bootstrap = form.Number("SshPort", 22);
        var primary = existing || bootstrap >= 1024 ? bootstrap : RandomNumberGenerator.GetInt32(20000, 30000);
        var rescue = existing ? primary : RandomNumberGenerator.GetInt32(30000, 40000);
        var role = existing ? "MonitorOnly" : form.Text("Role", "RealityEntry");
        var trusted = Regex.Split(form.Text("TrustedEntries"), @"[,;\s]+").Where(x => x != "").Distinct().Select(value => IPAddress.TryParse(value, out var address) ? address : throw new OperationException("可信入口地址无效。")).ToArray();
        var plan = new JsonObject
        {
            ["SchemaVersion"] = 3, ["CreatedAt"] = DateTimeOffset.UtcNow, ["Provider"] = provider, ["Instance"] = instance, ["NodeName"] = form.Text("NodeName", instance), ["Role"] = role,
            ["Server"] = new JsonObject { ["IPv4"] = form.Text("IPv4"), ["IPv6"] = form.Text("IPv6"), ["BootstrapUser"] = "root", ["BootstrapSshPort"] = bootstrap, ["BootstrapAuth"] = form.Text("KeyPath") == "" ? "Password" : "ExistingKey", ["BootstrapKeyPath"] = form.Text("KeyPath") },
            ["SshKey"] = new JsonObject { ["Mode"] = form.Text("KeyPath") == "" ? "GenerateManaged" : "ReuseExisting", ["SourcePrivateKeyPath"] = form.Text("KeyPath"), ["ManagedFileName"] = "id_vps_management", ["PreserveSource"] = true },
            ["AdminUser"] = existing ? "root" : "admin",
            ["Ports"] = new JsonObject { ["SshPrimary"] = primary, ["SshRescue"] = rescue, ["XrayPrimary"] = form.Number("RealityPort", 443), ["XrayBackup"] = form.Number("RealityBackupPort", RandomNumberGenerator.GetInt32(40000, 45000)), ["AnyTlsPrimary"] = form.Number("AnyTlsPort", 443), ["LandingShadowsocks"] = form.Number("LandingPort", 45001) },
            ["Reality"] = new JsonObject { ["Target"] = form.Text("RealityTarget"), ["TargetMode"] = form.Flag("LocalTarget") ? "LocalOwnedTls" : "ExternalAudited", ["ServerName"] = form.Text("RealityTarget"), ["LocalHttpsPort"] = 8443, ["ForceIpv4Egress"] = true, ["TargetSamples"] = versions.Number("target_audit.samples", 20), ["TargetMaxMedianMs"] = versions.Number("target_audit.maximum_median_ms", 15), ["XrayVersion"] = versions.Text("xray.version"), ["XrayVersionChannel"] = "FixedVerified" },
            ["AnyTls"] = new JsonObject { ["ServerName"] = form.Text("AnyTlsName"), ["EchPublicName"] = form.Text("EchPublicName"), ["ForceIpv4Egress"] = true, ["PaddingSchemeMode"] = "OfficialDefault", ["SingBoxVersion"] = versions.Text("sing_box.version") },
            ["Shadowsocks"] = new JsonObject { ["Method"] = "2022-blake3-aes-128-gcm", ["TrustedEntryIPv4s"] = new JsonArray(trusted.Where(x => x.AddressFamily == AddressFamily.InterNetwork).Select(x => (JsonNode?)JsonValue.Create(x.ToString())).ToArray()), ["TrustedEntryIPv6s"] = new JsonArray(trusted.Where(x => x.AddressFamily == AddressFamily.InterNetworkV6).Select(x => (JsonNode?)JsonValue.Create(x.ToString())).ToArray()), ["ClientTransitTag"] = form.Text("TransitGroup", "US-West Entry"), ["SecondaryIpv6Enabled"] = form.Flag("SecondaryIpv6Enabled"), ["SecondaryIpv6Address"] = form.Text("SecondaryIpv6Address"), ["SecondaryBindInterface"] = form.Text("SecondaryBindInterface"), ["SingBoxVersion"] = versions.Text("sing_box.version") },
            ["NetworkTuning"] = new JsonObject { ["Mode"] = form.Number("ReferenceRttMs") > 0 && role != "MonitorOnly" ? "AdaptiveConservative" : "BaselineOnly", ["BandwidthMbps"] = form.Number("BandwidthMbps"), ["ReferenceRttMs"] = form.Number("ReferenceRttMs") },
            ["Komari"] = new JsonObject { ["Enabled"] = form.Flag("KomariEnabled"), ["Endpoint"] = form.Text("KomariEndpoint"), ["AgentVersion"] = versions.Text("komari_agent.version") },
            ["TrustedTls"] = new JsonObject { ["Enabled"] = role == "AnyTlsEntry" || form.Flag("LocalTarget"), ["ZoneName"] = form.Text("ZoneName"), ["CertbotEmail"] = form.Text("CertbotEmail"), ["AnyTlsCertificateName"] = "mxh-anytls", ["RealityCertificateName"] = "mxh-reality", ["CloudflareTokenFile"] = form.Text("CloudflareTokenFile") },
            ["Paths"] = new JsonObject { ["Archive"] = paths.Instance(relative), ["KeyDirectory"] = SafePath.Resolve(paths.Instance(relative), "ssh") },
            ["Firewall"] = new JsonObject { ["Mode"] = existing ? "PreserveExisting" : "ManagedNftables" }
        };
        if (existing) plan["Import"] = new JsonObject { ["Status"] = "Pending", ["SshAuthenticationPreserved"] = true, ["EnforceKeyOnlySsh"] = false };
        else plan["DeploymentTransaction"] = new JsonObject { ["Id"] = Guid.NewGuid().ToString("N") };
        Validate(plan, existing); return plan;
    }
    public static void Validate(JsonObject plan, bool existing = false)
    {
        AppPaths.Segment(plan.Text("Provider")); AppPaths.Segment(plan.Text("Instance"));
        if (!Roles.Contains(plan.Text("Role"))) throw new OperationException("请选择受支持的实例用途。");
        if (!IPAddress.TryParse(plan.Text("Server.IPv4"), out var ip) || ip.AddressFamily != AddressFamily.InterNetwork || ip.ToString() != plan.Text("Server.IPv4")) throw new OperationException("请填写标准 IPv4 地址。");
        if (plan.Text("Server.IPv6") != "" && (!IPAddress.TryParse(plan.Text("Server.IPv6"), out var ipv6) || ipv6.AddressFamily != AddressFamily.InterNetworkV6)) throw new OperationException("IPv6 地址无效。");
        foreach (var field in new[] { "Server.BootstrapSshPort", "Ports.SshPrimary", "Ports.SshRescue" }) if (plan.Number(field) is < 1 or > 65535) throw new OperationException("SSH 端口必须在 1–65535。");
        if (!existing && plan.Number("Ports.SshPrimary") == plan.Number("Ports.SshRescue")) throw new OperationException("新部署需要独立的主、救援 SSH 端口。");
        if (plan.Number("NetworkTuning.BandwidthMbps") is < 1 or > 100000) throw new OperationException("请填写 1–100000 Mbps 的套餐标称带宽。");
        if (plan.Number("NetworkTuning.ReferenceRttMs") is < 0 or > 2000) throw new OperationException("参考 RTT 应为 1–2000 ms 或留空。");
        if (plan.Text("NodeName").Length is < 1 or > 120 || plan.Text("NodeName").Any(char.IsControl)) throw new OperationException("节点名称应为 1–120 个可打印字符。");
        if (existing) return;
        if (plan.Text("Role") == "RealityEntry" && plan.Number("Ports.XrayPrimary") is < 1 or > 65535) throw new OperationException("Reality 主入口端口无效。");
        var protocolPorts = plan.Text("Role") switch { "RealityEntry" => new[] { plan.Number("Ports.XrayPrimary"), plan.Number("Ports.XrayBackup") }.Where(p => p != 0).ToArray(), "AnyTlsEntry" => [plan.Number("Ports.AnyTlsPrimary")], "ShadowsocksLanding" => [plan.Number("Ports.LandingShadowsocks")], _ => Array.Empty<int>() };
        if (protocolPorts.Any(p => p is < 1 or > 65535) || protocolPorts.Distinct().Count() != protocolPorts.Length || protocolPorts.Intersect(new[] { plan.Number("Ports.SshPrimary"), plan.Number("Ports.SshRescue"), plan.Number("Server.BootstrapSshPort") }).Any()) throw new OperationException("协议端口无效或与管理入口冲突。");
        if (plan.Text("Role") == "RealityEntry") Domain(plan.Text("Reality.ServerName"));
        if (plan.Text("Role") == "AnyTlsEntry") { Domain(plan.Text("AnyTls.ServerName")); Domain(plan.Text("AnyTls.EchPublicName")); }
        if (plan.Flag("TrustedTls.Enabled") && (plan.Text("TrustedTls.ZoneName") == "" || plan.Text("TrustedTls.CertbotEmail") == "" || !File.Exists(plan.Text("TrustedTls.CloudflareTokenFile")))) throw new OperationException("可信证书需要区域、邮件与私人 Token 文件。");
        if (plan.Text("Role") == "ShadowsocksLanding" && plan.Strings("Shadowsocks.TrustedEntryIPv4s").Length + plan.Strings("Shadowsocks.TrustedEntryIPv6s").Length == 0) throw new OperationException("落地至少需要一个可信入口地址。");
        if (plan.Flag("Shadowsocks.SecondaryIpv6Enabled") && (!IPAddress.TryParse(plan.Text("Shadowsocks.SecondaryIpv6Address"), out var source6) || source6.AddressFamily != AddressFamily.InterNetworkV6)) throw new OperationException("IPv6 专用用户需要明确的 IPv6 源地址。");
        if (plan.Flag("Komari.Enabled") && (!Uri.TryCreate(plan.Text("Komari.Endpoint"), UriKind.Absolute, out var endpoint) || endpoint.Scheme is not ("http" or "https"))) throw new OperationException("Komari 地址需要完整的 HTTP/HTTPS URL。");
    }
    private static void Domain(string value)
    {
        if (value.Length is < 1 or > 253 || !value.Contains('.') || IPAddress.TryParse(value, out _) || value.Split('.').Any(label => !Regex.IsMatch(label, @"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"))) throw new OperationException("请填写有效域名。");
    }
    public static JsonObject Network(string role, long memoryKiB, int bandwidth, int rtt)
    {
        if (memoryKiB < 131072 || bandwidth is < 1 or > 100000 || rtt is < 0 or > 2000) throw new OperationException("网络调优输入无效。");
        var mb = memoryKiB / 1024; var tier = mb <= 512 ? "tiny" : mb <= 1024 ? "small" : mb <= 2048 ? "medium" : "standard";
        var cap = (mb <= 512 ? 4L : mb <= 1024 ? 8L : mb <= 2048 ? 16L : 32L) * 1048576;
        var adaptive = rtt > 0 && role != "MonitorOnly"; var bdp = adaptive ? (long)bandwidth * rtt * 125 : 0;
        var roleSlug = role == "ShadowsocksLanding" ? "landing" : role == "MonitorOnly" ? "monitor" : "entry";
        var bandwidthTier = bandwidth <= 100 ? "low" : bandwidth <= 500 ? "medium" : bandwidth <= 2000 ? "high" : "very-high";
        return new JsonObject { ["ROLE"] = role, ["MEMORY_KIB"] = memoryKiB, ["MODE"] = adaptive ? "AdaptiveConservative" : "BaselineOnly", ["BANDWIDTH_MBPS"] = bandwidth, ["REFERENCE_RTT_MS"] = adaptive ? rtt : 0, ["BUFFER_TARGET_BYTES"] = adaptive ? Math.Min(cap, Math.Max(roleSlug == "entry" ? 2097152L : 1048576L, bdp * 2)) : 0, ["BUFFER_CAP_BYTES"] = cap, ["QUEUE_FLOOR"] = Math.Max(roleSlug == "entry" ? 1024 : roleSlug == "landing" ? 2048 : 0, bandwidth <= 100 ? 512 : bandwidth <= 500 ? 1024 : bandwidth <= 2000 ? 2048 : 4096), ["PROFILE"] = $"{roleSlug}-{tier}-{bandwidthTier}-{(adaptive ? "adaptive" : "baseline")}" };
    }
}
