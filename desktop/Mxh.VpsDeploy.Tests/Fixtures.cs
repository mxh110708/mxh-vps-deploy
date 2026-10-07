using System.Text;
using System.Text.Json.Nodes;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Infrastructure;

internal sealed class Fixture : IDisposable
{
    public string Root { get; }
    public AppPaths Paths { get; }
    public ArchiveStore Store { get; }
    public JsonObject Versions => ArchiveStore.ReadJson(Paths.Resolve("config/versions.json"));
    public Fixture(string repository)
    {
        Root = Path.Combine(repository, ".test-output", "dotnet-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Root); Paths = new(Root); Store = new(Paths, new TestProtector());
        foreach (var name in new[] { "assets/remote", "config", "templates/client", "scripts" }) { var source = Path.Combine(repository, name); foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories).Where(p => !p.EndsWith(".local.json", StringComparison.OrdinalIgnoreCase) && !p.Contains("__pycache__", StringComparison.Ordinal))) { SafePath.CheckLinks(file); var target = Paths.Resolve(name + "/" + Path.GetRelativePath(source, file).Replace('\\', '/')); Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(file, target); } }
    }
    public string Relative(JsonObject plan) => plan.Text("Provider") + "/" + plan.Text("Instance") + "/MXH-VPS-Deploy";
    public JsonObject Plan(string name) => DeploymentPlans.Create(new JsonObject { ["Provider"] = "Example", ["Instance"] = name, ["NodeName"] = name, ["Role"] = "RealityEntry", ["RealityTarget"] = "example.com", ["IPv4"] = "192.0.2.10", ["SshPort"] = 22, ["BandwidthMbps"] = 100 }, Versions, Paths, false);
    public void SaveInstance(JsonObject plan) { var directory = Paths.Instance(Relative(plan)); ArchiveStore.WriteJson(SafePath.Resolve(directory, "deployment-plan.json"), plan); Store.WriteSecret(SafePath.Resolve(directory, "secrets.dotnet.private.json"), RealitySecrets()); ArchiveStore.WriteJson(SafePath.Resolve(directory, "deployment-state.json"), new JsonObject { ["Engine"] = "dotnet-v1", ["CurrentManagementPort"] = plan.Number("Ports.SshPrimary"), ["Audit"] = new JsonObject { ["MemoryKiB"] = 1048576 } }); }
    public static JsonObject RealitySecrets() => new() { ["Xray"] = new JsonObject { ["Uuid"] = Guid.NewGuid().ToString(), ["RealityPrivateKey"] = ServerConfigurations.RandomKey(32), ["RealityClientKey"] = ServerConfigurations.RandomKey(32), ["ShortId"] = "abcd1234" }, ["AdminPassword"] = "synthetic-password" };
    public WorkflowEngine Engine(FakeRemote remote) => new(Store, remote, new FakeKeys(), new FakeUser(), new FakeValidation());
    public void Dispose() { var full = Path.GetFullPath(Root); if (!full.Contains(Path.DirectorySeparatorChar + ".test-output" + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new Exception("cleanup boundary"); SafePath.CheckTree(full); Directory.Delete(full, true); }
}
internal sealed class TestProtector : ISecretProtector { public string Format => "TEST-ONLY"; public byte[] Protect(ReadOnlySpan<byte> data) => data.ToArray().Select(b => (byte)(b ^ 0x73)).ToArray(); public byte[] Unprotect(ReadOnlySpan<byte> data) => Protect(data); }
internal sealed class NoopKeyAccess : IPrivateKeyAccess { public void PrepareManagedCopy(string path) { } }
internal sealed class FakeWorkflow(Func<CancellationToken, Task<TaskOutcome>> run) : IOperationWorkflow { public Task<TaskOutcome> ExecuteAsync(OperationRequest request, string taskId, IProgress<TaskProgress> progress, CancellationToken cancellationToken) => run(cancellationToken); }
internal sealed class FakeUser(Func<string, string?>? secret = null) : IUserInteraction
{
    public List<string> SecretPrompts { get; } = new();
    public Task<bool> ConfirmHostAsync(HostIdentity identity, CancellationToken cancellationToken) => Task.FromResult(true);
    public Task<bool> ConfirmAsync(UserDecision decision, CancellationToken cancellationToken) => Task.FromResult(true);
    public Task<string?> SecretAsync(string title, CancellationToken cancellationToken) { SecretPrompts.Add(title); return Task.FromResult(secret == null ? "synthetic-password" : secret(title)); }
}
internal sealed class FakeKeys : IManagedKeyStore { public string Prepare(string directory, string source, string? passphrase = null) { Directory.CreateDirectory(directory); var file = SafePath.Resolve(directory, "id_vps_management"); File.WriteAllText(file, "fixture"); File.WriteAllText(file + ".pub", "fixture-public"); return file; } }
internal sealed class FakeValidation : IProtocolValidation { public Task<JsonObject> ValidateAsync(JsonObject plan, JsonObject secrets, string privateDirectory, IUserInteraction user, IProgress<string> progress, CancellationToken cancellationToken) => Task.FromResult(new JsonObject { ["Status"] = "Passed" }); public void Export(JsonObject plan, JsonObject secrets, string directory) { } }
internal sealed class FakeTools : IExternalToolRunner { public Task<CommandResult> RunAsync(string executable, IReadOnlyList<string> arguments, string? input, TimeSpan timeout, CancellationToken cancellationToken) => Task.FromResult(new CommandResult(1, "", "synthetic-credential")); }
internal sealed class FakeAssets : IValidationAssets { public string ResolveCore(string name) => name; public string DataDirectory => "unused"; }
internal sealed class FakeRemote : IRemoteSessionFactory, IRemoteSession
{
    public const string Backup = "/root/vps-deploy-backups/20000101-000000/protocol-lifecycle";
    public List<string> Commands { get; } = new(); public int Mutations { get; private set; } public string FailAsset { get; set; } = ""; public string StatusTaskId { get; set; } = ""; public string StatusPhase { get; set; } = "None"; public string ArmedComponents { get; private set; } = "";
    public List<SshEndpoint> Endpoints { get; } = new();
    public Task<IRemoteSession> OpenAsync(SshEndpoint endpoint, IUserInteraction interaction, CancellationToken cancellationToken) { cancellationToken.ThrowIfCancellationRequested(); Endpoints.Add(endpoint); return Task.FromResult<IRemoteSession>(this); }
    public Task<CommandResult> RunAsync(string command, TimeSpan timeout, CancellationToken cancellationToken) => Task.FromResult(new CommandResult(0, ArchiveStore.Digest(Encoding.UTF8.GetBytes("fixture-archive")) + "  file", ""));
    public Task<CommandResult> RunScriptAsync(string payload, TimeSpan timeout, bool mutating, CancellationToken cancellationToken)
    {
        var asset = payload.Split('\n')[0].Replace("# MXH asset: ", ""); if (!asset.EndsWith(".sh")) return Task.FromResult(new CommandResult(0, "VPSDEPLOY_SSH_OK\n", "")); Commands.Add(asset); if (mutating) Mutations++;
        if (asset == "protocol-migration-arm-rollback.sh") { var match = System.Text.RegularExpressions.Regex.Match(payload, "export VPS_PARAM_COMPONENTS=.+?'([A-Za-z0-9+/=]+)' "); ArmedComponents = Encoding.UTF8.GetString(Convert.FromBase64String(match.Groups[1].Value)); }
        if (asset == FailAsset) throw new IOException("synthetic connection lost");
        static string Marker(string name, string value) => "VPSDEPLOY_" + name + "_B64=" + Convert.ToBase64String(Encoding.UTF8.GetBytes(value)) + "\n";
        var output = asset switch { "audit.sh" => Marker("OS_ID", "debian") + Marker("OS_VERSION", "13") + Marker("ARCH", "x86_64") + Marker("MEMORY_KIB", "1048576") + Marker("EXISTING_SERVICES", "") + Marker("NFT_LINES", "0"), "maintenance-health-audit.sh" => Marker("HEALTH_AUDIT", "{\"SchemaVersion\":1}"), "protocol-migration-arm-rollback.sh" => Marker("BACKUP_DIR", Backup), "network-tuning.sh" => Marker("BACKUP_DIR", "/root/fixture-network"), "maintenance-transaction-commit.sh" => "VPSDEPLOY_MAINTENANCE_COMMITTED\n", "maintenance-transaction-status.sh" => Marker("TRANSACTION_BACKUP", Backup) + Marker("TRANSACTION_PHASE", StatusPhase) + Marker("CONTROL_TASK_ID", StatusTaskId), "protocol-migration-trigger-rollback.sh" => "VPSDEPLOY_MIGRATION_ROLLBACK_OK\n", _ => "" }; return Task.FromResult(new CommandResult(0, output, ""));
    }
    public Task<byte[]> ReadFileAsync(string absolutePath, CancellationToken cancellationToken) => Task.FromResult(Encoding.UTF8.GetBytes("{}"));
    public Task DownloadAsync(string absolutePath, string destination, CancellationToken cancellationToken) { Directory.CreateDirectory(Path.GetDirectoryName(destination)!); File.WriteAllText(destination, "fixture-archive"); return Task.CompletedTask; }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
