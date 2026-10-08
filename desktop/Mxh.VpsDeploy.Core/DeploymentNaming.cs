using System.Text.RegularExpressions;

namespace Mxh.VpsDeploy.Core;

public sealed class DeploymentNaming
{
    private string previousSuggestion = "";
    public static string Suggest(string provider, string instance)
    {
        var value = Regex.Replace(string.Join("-", new[] { provider.Trim(), instance.Trim() }.Where(s => s.Length > 0)), @"\s+", "-");
        return value.Length <= 120 ? value : value[..120].TrimEnd('-');
    }
    public string Update(string provider, string instance, string current)
    {
        var suggestion = Suggest(provider, instance);
        var result = current.Length == 0 || current == previousSuggestion ? suggestion : current;
        previousSuggestion = suggestion;
        return result;
    }
}
