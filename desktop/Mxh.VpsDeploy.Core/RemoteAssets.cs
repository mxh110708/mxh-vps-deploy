using System.Text;
using System.Text.RegularExpressions;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Core;

public sealed class RemoteAssets(AppPaths paths)
{
    public string Read(string name)
    {
        if (!Regex.IsMatch(name, @"^[a-z0-9-]+\.sh$")) throw new OperationException("远端模块名称无效。");
        return File.ReadAllText(paths.Resolve("assets/remote/" + name)).Replace("\r\n", "\n").Replace('\r', '\n');
    }
    public string Payload(string asset, IReadOnlyDictionary<string, string> parameters)
    {
        var text = new StringBuilder("# MXH asset: " + asset + "\nset -euo pipefail\n");
        foreach (var (name, value) in parameters.OrderBy(p => p.Key))
        {
            if (!Regex.IsMatch(name, "^[A-Z][A-Z0-9_]*$")) throw new OperationException("远端参数名称无效。");
            var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
            text.Append("export VPS_PARAM_").Append(name).Append("=\"$(printf '%s' '").Append(encoded).Append("' | base64 -d)\"\n");
        }
        if (parameters.ContainsKey("EXPECTED_TRANSACTION")) text.Append(Read("maintenance-mutation-guard.sh")).Append("\nvps_begin_mutation || exit 1\n");
        return text.Append(Read(asset)).Append('\n').ToString();
    }
    public static string Marker(string text, string name, bool required = true)
    {
        if (!Regex.IsMatch(name, "^[A-Z][A-Z0-9_]*$")) throw new OperationException("远端标记名称无效。");
        var match = Regex.Match(text.Replace("\r\n", "\n"), "(?m)^VPSDEPLOY_" + name + "_B64=([A-Za-z0-9+/=]*)$");
        if (!match.Success) { if (required) throw new OperationException("远端步骤缺少结果标记：" + name); return ""; }
        return Encoding.UTF8.GetString(Convert.FromBase64String(match.Groups[1].Value));
    }
    public static void RequireMarker(CommandResult result, string marker)
    {
        result.RequireSuccess("远端步骤执行失败；请核对任务阶段与恢复记录。");
        if (!result.Output.Split('\n').Any(l => l.TrimEnd('\r') == "VPSDEPLOY_" + marker)) throw new OperationException("远端步骤未确认完成：" + marker);
    }
}
