using System.Diagnostics;
using System.Text.Json.Nodes;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Infrastructure;

internal sealed partial class BoundaryTests
{
    private async Task LocalSshConfirmation(Fixture fixture, string python)
    {
        var root = fixture.Paths.Resolve("loopback"); Directory.CreateDirectory(root);
        var script = Path.Combine(repository, "desktop/Mxh.VpsDeploy.Tests/fixtures/ssh_confirmation_server.py");
        var statsFile = Path.Combine(root, "stats.json"); var readyFile = Path.Combine(root, "ready.json");
        async Task<Process> Start()
        {
            if (File.Exists(readyFile)) File.Delete(readyFile);
            var start = new ProcessStartInfo(python) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
            foreach (var arg in new[] { script, "--ready", readyFile, "--stats", statsFile }) start.ArgumentList.Add(arg);
            var process = Process.Start(start)!;
            try
            {
                for (var i = 0; i < 200 && !File.Exists(readyFile); i++) { if (process.HasExited) throw new Exception("Loopback fixture failed to start."); await Task.Delay(50); }
                if (!File.Exists(readyFile)) throw new Exception("Loopback fixture startup timed out.");
                return process;
            }
            catch { Stop(process); throw; }
        }
        static void Stop(Process process) { if (!process.HasExited) { process.Kill(true); process.WaitForExit(5000); } process.Dispose(); }
        var process = await Start();
        try
        {
            var endpoint = new SshEndpoint("127.0.0.1", ArchiveStore.ReadJson(readyFile).Number("port"), "fixture", null, "fixture-only");
            var factory = new SshSessionFactory(fixture.Store, TimeSpan.FromSeconds(3));
            var user = new HostTestUser(async (_, token) =>
            {
                Check(ArchiveStore.ReadJson(statsFile).Number("auth") == 0, "identity probe sent credentials before approval");
                await Task.Delay(TimeSpan.FromSeconds(6), token); return true;
            });
            await using (await factory.OpenAsync(endpoint, user, default)) { }
            Check(user.Confirmations == 1 && ArchiveStore.ReadJson(statsFile).Number("exec") == 0, "delayed confirmation failed or sent command");
            var known = new HostTestUser((_, _) => throw new Exception("Trusted host unexpectedly asked again."));
            await using (await factory.OpenAsync(endpoint, known, default)) { }
            Check(known.Confirmations == 0, "known identity requested repeated trust");
            try { await using var invalid = await factory.OpenAsync(endpoint with { Password = "wrong-fixture-only" }, known, default); throw new Exception("Wrong password accepted."); }
            catch (OperationException error) { Check(error.Code == "SshAuthenticationFailed", "authentication failure lost typed cause"); }
            var isolatedStore = new ArchiveStore(new AppPaths(Path.Combine(root, "cancelled")), new TestProtector());
            var cancel = new HostTestUser((_, _) => Task.FromResult(false));
            try { await using var canceled = await new SshSessionFactory(isolatedStore, TimeSpan.FromSeconds(3)).OpenAsync(endpoint, cancel, default); throw new Exception("Canceled host trusted."); }
            catch (OperationCanceledException) { Check(cancel.Confirmations == 1 && !File.Exists(isolatedStore.Paths.Resolve("private/ssh-hosts.dotnet.json")), "canceled trust saved"); }
            var fingerprint = ClientSchemes.SourceFingerprint(fixture.Paths.Resolve("private/ssh-hosts.dotnet.json"));
            Stop(process); process = await Start();
            endpoint = endpoint with { Port = ArchiveStore.ReadJson(readyFile).Number("port") };
            try { await using var changed = await factory.OpenAsync(endpoint, known, default); throw new Exception("Changed key accepted."); }
            catch (OperationException error) { Check(error.Code == "HostIdentityChanged", "host key change lacks explicit reason"); }
            Check(fingerprint == ClientSchemes.SourceFingerprint(fixture.Paths.Resolve("private/ssh-hosts.dotnet.json")) && ArchiveStore.ReadJson(statsFile).Number("auth") == 0, "changed host updated trust or sent credentials");
        }
        finally { Stop(process); }
    }
}

internal sealed class HostTestUser(Func<HostIdentity, CancellationToken, Task<bool>> confirmation) : IUserInteraction
{
    public int Confirmations { get; private set; }
    public Task<bool> ConfirmHostAsync(HostIdentity identity, CancellationToken token) { Confirmations++; return confirmation(identity, token); }
    public Task<bool> ConfirmAsync(UserDecision decision, CancellationToken token) => Task.FromResult(false);
    public Task<string?> SecretAsync(string title, CancellationToken token) => Task.FromResult<string?>(null);
}
