using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Infrastructure;

internal sealed partial class BoundaryTests
{
    private async Task BackgroundTestTransport(Fixture f)
    {
        var root = f.Paths.Resolve("background-test"); Directory.CreateDirectory(root);
        var app = f.Root + "-independent-app";
        var id = Guid.NewGuid().ToString("N"); var token = new string('a', 64);
        var config = new JsonObject { ["SchemaVersion"] = 1, ["SessionId"] = id, ["Root"] = root, ["PipeName"] = "mxh-test-" + id, ["Token"] = token,
            ["AllowedEndpoints"] = new JsonArray(new JsonObject { ["Host"] = "192.0.2.10", ["Port"] = 22022 }) };
        var manifest = SafePath.Resolve(root, "test-session.private.json"); ArchiveStore.WriteJson(manifest, config);
        Refuses(() => BackgroundTestSession.Load(manifest, app), "unmarked test root accepted");
        ArchiveStore.WriteJson(SafePath.Resolve(root, BackgroundTestSession.Marker), new JsonObject { ["IsolatedTestRoot"] = true, ["SessionId"] = id });
        Refuses(() => BackgroundTestSession.Load(manifest, root), "production root reused for tests");
        Refuses(() => BackgroundTestSession.Load(manifest, f.Root), "nested production root reused for tests");
        var session = BackgroundTestSession.Load(manifest, app);
        Refuses(() => session.Artifact("../escape.png"), "test artifact escaped");
        Refuses(() => session.RequireLocalPath(repository), "test output touched production directory");
        Refuses(() => session.Secret("../../outside"), "test credential escaped");
        Refuses(() => session.Secret("../test-session.private.json"), "credential reference read outside test-secrets");
        var fake = new FakeRemote(); var restricted = session.Restrict(fake);
        await RefusesAsync(() => restricted.OpenAsync(new("192.0.2.11", 22022, "root", null), new FakeUser(), default), "other test VPS accepted");
        await RefusesAsync(() => restricted.OpenAsync(new("192.0.2.10", 22, "root", null), new FakeUser(), default), "unlisted SSH port accepted");
        await RefusesAsync(() => restricted.OpenAsync(new("192.0.2.10", 22022, "root", repository), new FakeUser(), default), "production private key reused");
        Check(fake.Endpoints.Count == 0, "remote scope rejection happened after connecting");
        await using (await restricted.OpenAsync(new("192.0.2.10", 22022, "root", null), new FakeUser(), default)) { }
        Check(fake.Endpoints.Count == 1, "explicit test endpoint blocked");
        var count = 0;
        await using var server = new BackgroundTestPipe(session, (command, args) =>
        {
            if (command != "ui.read") throw new OperationException("Unknown test command.", code: "TestUnknownCommand");
            count++; return Task.FromResult(new JsonObject { ["calls"] = count });
        }); server.Start();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        async Task<JsonObject> Send(JsonObject request)
        {
            await using var pipe = new NamedPipeClientStream(".", session.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(3000, timeout.Token); await BackgroundTestPipe.Write(pipe, request, timeout.Token); return await BackgroundTestPipe.Read(pipe, timeout.Token);
        }
        JsonObject Request(string credential = "") => new() { ["version"] = 1, ["id"] = Guid.NewGuid().ToString("N"), ["token"] = credential == "" ? token : credential, ["command"] = "ui.read" };
        var result = await Send(Request("wrong")); Check(!result.Flag("ok") && result.Text("error_code") == "TestAuthenticationDenied" && count == 0, "unauthenticated pipe executed");
        var request = Request(); result = await Send(request); Check(result.Flag("ok") && count == 1, "authenticated command failed");
        result = await Send(request); Check(result.Text("error_code") == "TestDuplicateRequest" && count == 1, "pipe replay executed twice");
        request = Request(); request["command"] = "shell.run"; result = await Send(request); Check(result.Text("error_code") == "TestUnknownCommand", "arbitrary shell test command accepted");
        var excessive = new MemoryStream(Encoding.UTF8.GetBytes(new string('x', BackgroundTestPipe.MaximumBytes + 1) + "\n"));
        await RefusesAsync(() => BackgroundTestPipe.Read(excessive, default), "unbounded pipe request accepted");
        await using (var pipe = new NamedPipeClientStream(".", session.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
        {
            await pipe.ConnectAsync(3000, timeout.Token); await pipe.WriteAsync(Encoding.UTF8.GetBytes("[1]\n"), timeout.Token);
        }
        result = await BackgroundTestPipe.SendAsync(session, "ui.read", new(), timeout.Token); Check(result.Flag("ok") && count == 2, "malformed JSON killed test listener");
        var log = File.ReadAllText(session.Artifact("commands.jsonl")); Check(!log.Contains(token) && !log.Contains("wrong"), "test session credentials leaked into audit");
        File.WriteAllText(SafePath.Resolve(root, PrivateDirectory.LocationFile), "{}");
        Refuses(() => BackgroundTestSession.Load(manifest, app), "external production archive reused by test process");
    }
}
