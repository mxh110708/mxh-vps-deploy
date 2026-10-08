using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Infrastructure;

/// <summary>Explicit opt-in configuration for a disposable app instance; never loaded by normal startup.</summary>
public sealed class BackgroundTestSession
{
    public const string Marker = "background-test.fixture.json";
    public string Root { get; }
    public string PipeName { get; }
    public string Token { get; }
    public string Id { get; }
    private readonly HashSet<string> endpoints = new(StringComparer.Ordinal);
    private BackgroundTestSession(JsonObject config, string root)
    {
        Root = root; PipeName = config.Text("PipeName"); Token = config.Text("Token"); Id = config.Text("SessionId");
        if (config.Number("SchemaVersion") != 1 || !Guid.TryParseExact(Id, "N", out _) ||
            !Regex.IsMatch(PipeName, @"^mxh-test-[a-f0-9]{32}$") || !Regex.IsMatch(Token, @"^[a-f0-9]{64}$"))
            throw new OperationException("后台测试会话参数无效。");
        foreach (var target in (config["AllowedEndpoints"] as JsonArray ?? []))
        {
            var host = target.Text("Host"); var port = target.Number("Port");
            if (!IPAddress.TryParse(host, out var ip) || IPAddress.IsLoopback(ip) || port is < 1 or > 65535)
                throw new OperationException("测试机白名单必须包含明确 IP 和 SSH 端口。");
            endpoints.Add(ip + ":" + port);
        }
    }
    public static BackgroundTestSession Load(string manifest, string applicationRoot)
    {
        SafePath.CheckLinks(manifest); var config = ArchiveStore.ReadJson(manifest);
        var root = Path.GetFullPath(config.Text("Root")).TrimEnd(Path.DirectorySeparatorChar);
        var application = Path.GetFullPath(applicationRoot).TrimEnd(Path.DirectorySeparatorChar);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!Path.IsPathFullyQualified(config.Text("Root")) || root.Equals(application, comparison) ||
            root.StartsWith(application + Path.DirectorySeparatorChar, comparison) || application.StartsWith(root + Path.DirectorySeparatorChar, comparison) ||
            !Path.GetFullPath(manifest).Equals(SafePath.Resolve(root, "test-session.private.json"), comparison))
            throw new OperationException("后台测试必须使用独立目录和会话清单。");
        var session = new BackgroundTestSession(config, root);
        var markerFile = SafePath.Resolve(root, Marker);
        if (!File.Exists(markerFile)) throw new OperationException("后台测试工作区缺少隔离标记。");
        var marker = ArchiveStore.ReadJson(markerFile);
        if (!marker.Flag("IsolatedTestRoot") || marker.Text("SessionId") != session.Id ||
            File.Exists(SafePath.Resolve(root, PrivateDirectory.LocationFile)))
            throw new OperationException("后台测试工作区缺少匹配标记，或重用了外部私人归档。");
        Directory.CreateDirectory(SafePath.Resolve(root, "test-artifacts"));
        return session;
    }
    public string Artifact(string name)
    {
        if (!Regex.IsMatch(name, @"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,100}$")) throw new OperationException("测试输出名称无效。");
        return SafePath.Resolve(Root, "test-artifacts/" + name);
    }
    public string Secret(string reference)
    {
        var file = SafePath.Resolve(SafePath.Resolve(Root, "test-secrets"), reference);
        if (new FileInfo(file).Length > 65536) throw new OperationException("测试凭据文件过大。");
        return File.ReadAllText(file).TrimEnd('\r', '\n');
    }
    public void RequireLocalPath(string value)
    {
        if (value == "") return;
        var full = Path.GetFullPath(value); var prefix = Root + Path.DirectorySeparatorChar;
        if (!Path.IsPathFullyQualified(value) || !full.StartsWith(prefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
            throw new OperationException("后台测试的文件和输出路径必须位于本次工作区。");
        SafePath.CheckLinks(full);
    }
    public IRemoteSessionFactory Restrict(IRemoteSessionFactory factory) => new RestrictedFactory(this, factory);
    private sealed class RestrictedFactory(BackgroundTestSession session, IRemoteSessionFactory factory) : IRemoteSessionFactory
    {
        public Task<IRemoteSession> OpenAsync(SshEndpoint endpoint, IUserInteraction interaction, CancellationToken cancellationToken)
        {
            if (!IPAddress.TryParse(endpoint.Host, out var ip) || !session.endpoints.Contains(ip + ":" + endpoint.Port))
                throw new OperationException("此 SSH 目标未列入本次后台测试白名单，连接已阻止。", code: "TestTargetDenied");
            if (endpoint.KeyPath != null) session.RequireLocalPath(endpoint.KeyPath);
            return factory.OpenAsync(endpoint, interaction, cancellationToken);
        }
    }
}
