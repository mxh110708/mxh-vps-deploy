using System.Text;
using System.Text.Json.Nodes;

namespace Mxh.VpsDeploy.Core;

public static class ClientProfiles
{
    public sealed record NodePair(string Name, string Role, string Family, JsonObject Clash, JsonObject SingBox, string EgressFamily = "IPv4");
    public static IEnumerable<NodePair> Nodes(JsonObject plan, JsonObject secrets, bool enabledOnly = false)
    {
        foreach (var role in DeploymentPlans.Roles[..3])
        {
            var installed = plan.At("ProtocolInventory." + role) == null ? plan.Text("Role") == role : plan.Flag("ProtocolInventory." + role + (enabledOnly ? ".Enabled" : ".Installed"));
            if (!installed) continue;
            foreach (var (family, address) in new[] { ("IPv4", plan.Text("Server.IPv4")), ("IPv6", plan.Text("Server.IPv6")) })
            {
                if (address == "") continue;
                // A landing IPv6 user selects its egress family; it can still use the IPv4 entry listener.
                var users = role == "ShadowsocksLanding" && plan.Flag("Shadowsocks.SecondaryIpv6Enabled") ? new[] { "IPv4", "IPv6" } : new[] { "IPv4" };
                foreach (var egress in users)
                {
                    var name = plan.Text("NodeName") + (role == "ShadowsocksLanding" ? "." + egress + "-Exit" : "") + (plan.Text("Server.IPv6") == "" ? "" : "-" + family);
                    foreach (var port in role == "RealityEntry" && plan.Number("Ports.XrayBackup") > 0 ? new[] { plan.Number("Ports.XrayPrimary"), plan.Number("Ports.XrayBackup") } : new[] { plan.Number(role == "RealityEntry" ? "Ports.XrayPrimary" : role == "AnyTlsEntry" ? "Ports.AnyTlsPrimary" : "Ports.LandingShadowsocks") })
                    {
                        var nodeName = name + (role == "RealityEntry" && port != plan.Number("Ports.XrayPrimary") ? "-Backup" : "");
                        var clash = new JsonObject { ["name"] = nodeName, ["server"] = address, ["port"] = port, ["udp"] = true };
                        var sing = new JsonObject { ["tag"] = nodeName, ["server"] = address, ["server_port"] = port };
                        if (role == "RealityEntry")
                        {
                            clash["type"] = "vless"; clash["uuid"] = secrets.Text("Xray.Uuid"); clash["flow"] = "xtls-rprx-vision"; clash["tls"] = true; clash["network"] = "tcp"; clash["servername"] = plan.Text("Reality.ServerName", plan.Text("Reality.Target")); clash["client-fingerprint"] = "chrome"; clash["reality-opts"] = new JsonObject { ["public-key"] = secrets.Text("Xray.RealityClientKey"), ["short-id"] = secrets.Text("Xray.ShortId") };
                            sing["type"] = "vless"; sing["uuid"] = secrets.Text("Xray.Uuid"); sing["flow"] = "xtls-rprx-vision"; sing["tls"] = new JsonObject { ["enabled"] = true, ["server_name"] = plan.Text("Reality.ServerName", plan.Text("Reality.Target")), ["utls"] = new JsonObject { ["enabled"] = true, ["fingerprint"] = "chrome" }, ["reality"] = new JsonObject { ["enabled"] = true, ["public_key"] = secrets.Text("Xray.RealityClientKey"), ["short_id"] = secrets.Text("Xray.ShortId") } };
                        }
                        else if (role == "AnyTlsEntry")
                        {
                            var pem = secrets.Text("AnyTls.EchClientConfigPem"); var payload = string.Join("", pem.Split('\n').Where(l => l != "" && !l.StartsWith("-----")));
                            clash["type"] = "anytls"; clash["password"] = secrets.Text("AnyTls.Password"); clash["sni"] = plan.Text("AnyTls.ServerName"); clash["skip-cert-verify"] = false; clash["ech-opts"] = new JsonObject { ["enable"] = true, ["config"] = payload };
                            sing["type"] = "anytls"; sing["password"] = secrets.Text("AnyTls.Password"); sing["tls"] = new JsonObject { ["enabled"] = true, ["server_name"] = plan.Text("AnyTls.ServerName"), ["min_version"] = "1.3", ["ech"] = new JsonObject { ["enabled"] = true, ["config"] = new JsonArray(pem.TrimEnd().Split('\n').Select(l => (JsonNode?)JsonValue.Create(l)).ToArray()) } };
                        }
                        else
                        {
                            var password = secrets.Text("Shadowsocks.ServerKey") + ":" + secrets.Text(egress == "IPv6" ? "Shadowsocks.SecondaryUserKey" : "Shadowsocks.PrimaryUserKey");
                            clash["type"] = "ss"; clash["cipher"] = plan.Text("Shadowsocks.Method"); clash["password"] = password;
                            sing["type"] = "shadowsocks"; sing["method"] = plan.Text("Shadowsocks.Method"); sing["password"] = password;
                        }
                        yield return new(nodeName, role, family, clash, sing, egress);
                    }
                }
            }
        }
    }
    public static JsonObject SingProbe(NodePair node, int port) => new()
    {
        ["log"] = new JsonObject { ["level"] = "warn" }, ["inbounds"] = new JsonArray(new JsonObject { ["type"] = "mixed", ["tag"] = "probe-in", ["listen"] = "127.0.0.1", ["listen_port"] = port }),
        ["outbounds"] = new JsonArray(node.SingBox.DeepClone()), ["route"] = new JsonObject { ["final"] = node.Name }
    };
    // JSON is a YAML subset and preserves all string values without manual quoting.
    public static JsonObject ClashProbe(NodePair node, int port) => new()
    {
        ["mixed-port"] = port, ["allow-lan"] = false, ["bind-address"] = "127.0.0.1", ["mode"] = "rule", ["log-level"] = "warning", ["ipv6"] = true, ["geodata-mode"] = true, ["geo-auto-update"] = false,
        ["proxies"] = new JsonArray(node.Clash.DeepClone()), ["proxy-groups"] = new JsonArray(new JsonObject { ["name"] = "Probe", ["type"] = "select", ["proxies"] = new JsonArray(node.Name) }), ["rules"] = new JsonArray("MATCH,Probe")
    };
    public static void Export(JsonObject plan, JsonObject secrets, string directory)
    {
        Directory.CreateDirectory(directory);
        foreach (var group in Nodes(plan, secrets).GroupBy(n => n.Role))
        {
            var jsonName = group.Key == "RealityEntry" ? "sing-box-outbounds.private.json" : group.Key == "AnyTlsEntry" ? "sing-box-anytls-outbounds.private.json" : "sing-box-shadowsocks-outbounds.private.json";
            var yamlName = group.Key == "RealityEntry" ? "mihomo-test-primary.yaml" : group.Key == "AnyTlsEntry" ? "mihomo-anytls-test.yaml" : "mihomo-shadowsocks-test.yaml";
            ArchiveStore.WriteJson(SafePath.Resolve(directory, jsonName), new JsonObject { ["outbounds"] = new JsonArray(group.Select(n => n.SingBox.DeepClone()).ToArray()) });
            ArchiveStore.WriteJson(SafePath.Resolve(directory, yamlName), new JsonObject { ["proxies"] = new JsonArray(group.Select(n => n.Clash.DeepClone()).ToArray()) });
        }
    }
}
