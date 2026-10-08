using System.Text.Json.Nodes;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Infrastructure;

internal sealed partial class BoundaryTests
{
    private async Task AdditionsExperience(Fixture f)
    {
        var scheme = ClientSchemes.New(f.Paths);
        foreach (var name in new[] { "A", "B", "C", "D" }) scheme["Nodes"]!.AsArray().Add(new JsonObject { ["name"] = name, ["kind"] = "entry", ["region_group"] = "Fixture" });
        scheme["Candidate"] = new JsonObject { ["ValidationStatus"] = "Passed" };
        Check(ClientSchemes.MoveNode(scheme, 0, 4) && scheme["Nodes"]!.AsArray().Select(n => n!.Text("name")).SequenceEqual(new[] { "B", "C", "D", "A" }) && scheme["Candidate"] == null, "drag-to-end did not preserve ordering or invalidate candidate");
        Check(ClientSchemes.MoveNode(scheme, 3, 0) && scheme["Nodes"]!.AsArray()[0]!.Text("name") == "A", "drag-to-start failed");
        Check(!ClientSchemes.MoveNode(scheme, 1, 2), "adjacent no-op changed scheme");
        Refuses(() => ClientSchemes.MoveNode(scheme, 0, 5), "invalid insertion accepted");
        Check(!ClientSchemes.CanExport(scheme) && ClientSchemes.ExportHint(scheme).Contains("生成配置"), "missing generation hint");
        scheme["Candidate"] = new JsonObject { ["ValidationStatus"] = "Pending" }; Check(ClientSchemes.ExportHint(scheme).Contains("校验配置") && !ClientSchemes.CanExport(scheme), "unvalidated export enabled");
        scheme["Candidate"]!["ValidationStatus"] = "Failed"; scheme["Candidate"]!["ValidationError"] = "synthetic safe reason"; Check(ClientSchemes.ExportHint(scheme).Contains("synthetic safe reason"), "validation failure reason missing");
        scheme["Candidate"]!["ValidationStatus"] = "Passed"; scheme["Targets"]!["Clash"] = "fixture.yaml"; Check(!ClientSchemes.CanExport(scheme) && ClientSchemes.ExportHint(scheme).Contains("导出位置"), "partially filled dual output enabled");
        scheme["Targets"]!["SingBox"] = "fixture.json"; Check(ClientSchemes.CanExport(scheme), "validated and filled targets blocked");
        var tokenFile = f.Paths.Resolve("fixture-token"); File.WriteAllText(tokenFile, "synthetic-token");
        JsonObject Settings(string component) => component switch
        {
            "RealityEntry" => new() { ["RealityTarget"] = "example.com", ["RealityPort"] = 8443 },
            "AnyTlsEntry" => new() { ["AnyTlsName"] = "node.example.com", ["EchPublicName"] = "public.example.com", ["AnyTlsPort"] = 8443, ["ZoneName"] = "example.com", ["CertbotEmail"] = "admin@example.com", ["CloudflareTokenFile"] = tokenFile },
            "ShadowsocksLanding" => new() { ["LandingPort"] = 45001, ["TrustedEntries"] = "192.0.2.30" },
            "KomariAgent" => new() { ["KomariEndpoint"] = "https://monitor.example.com" }, "KomariController" => new() { ["ControllerPort"] = 25774 }, _ => new() { ["PublicUrl"] = "https://monitor.example.com" }
        };
        JsonObject Options(string component) => new() { ["Component"] = component, ["Settings"] = Settings(component), ["AssetPin"] = ArchiveStore.Fingerprint(f.Versions) };
        (JsonObject Plan, string Relative, string Directory, JsonObject State) Managed(string name, bool anyTls = false)
        {
            var plan = f.Plan(name); plan.Put("Ports.XrayBackup", JsonValue.Create(44443));
            if (anyTls) { plan["Role"] = "AnyTlsEntry"; plan["Roles"] = new JsonArray("AnyTlsEntry"); plan["ActiveEntry"] = "AnyTlsEntry"; plan.Put("Ports.AnyTlsPrimary", JsonValue.Create(443)); }
            f.SaveInstance(plan); var relative = f.Relative(plan); var directory = f.Paths.Instance(relative); var state = ArchiveStore.ReadJson(SafePath.Resolve(directory, "deployment-state.json")); state.Put("DeploymentTransaction.Status", JsonValue.Create("Committed")); ArchiveStore.WriteJson(SafePath.Resolve(directory, "deployment-state.json"), state); return (plan, relative, directory, state);
        }
        var check = Managed("installation-validation");
        var conflicting = Options("AnyTlsEntry"); conflicting["Settings"]!["AnyTlsPort"] = 443;
        Refuses(() => ComponentInstallations.Prepare(check.Plan, check.State, conflicting, f.Versions), "append shared listener accepted");
        conflicting["Settings"]!["AnyTlsPort"] = check.Plan.Number("Ports.SshPrimary"); Refuses(() => ComponentInstallations.Prepare(check.Plan, check.State, conflicting, f.Versions), "append management port accepted");
        Refuses(() => ComponentInstallations.Prepare(check.Plan, check.State, Options("RealityEntry"), f.Versions), "installed component overwrite accepted");
        var changedVersions = f.Versions.DeepClone().AsObject(); changedVersions.Put("sing_box.version", JsonValue.Create("99.0.0"));
        Refuses(() => ComponentInstallations.Prepare(check.Plan, check.State, Options("ShadowsocksLanding"), changedVersions), "unreviewed component version accepted");
        var injected = Options("ShadowsocksLanding"); injected["Settings"]!["SshPrimary"] = 12345; Refuses(() => OperationPolicy.Validate(new(OperationKind.InstallComponent, check.Relative, injected)), "append request changed SSH settings");
        foreach (var component in ComponentInstallations.Components)
        {
            var fixture = Managed("install-" + component, component == "RealityEntry"); var before = fixture.Plan.DeepClone(); var secretBefore = f.Store.ReadSecret(SafePath.Resolve(fixture.Directory, "secrets.dotnet.private.json")).Text("Xray.Uuid");
            var remote = new FakeRemote(); remote.SeedProtocols(fixture.Plan);
            var user = new FakeUser(title => title.Contains("主控管理员") ? "SyntheticStrong123" : title.Contains("Agent Token") ? "synthetic-agent-token" : title.Contains("Tunnel") ? "synthetic-tunnel-token" : "synthetic-password");
            var engine = new WorkflowEngine(f.Store, remote, new FakeKeys(), user, new FakeValidation()); var id = Guid.NewGuid().ToString("N"); remote.StatusTaskId = id; remote.StatusPhase = "Armed";
            var request = new OperationRequest(OperationKind.InstallComponent, fixture.Relative, Options(component)); var events = new List<TaskProgress>();
            Check(await engine.ExecuteAsync(request, id, new InlineProgress<TaskProgress>(events.Add), default) == TaskOutcome.Completed, "append did not complete: " + component);
            var after = ArchiveStore.ReadJson(SafePath.Resolve(fixture.Directory, "deployment-plan.json"));
            Check(after.Text("NodeName") == before.Text("NodeName") && ArchiveStore.Fingerprint(after["Ports"]!) == ArchiveStore.Fingerprint(ComponentInstallations.Prepare(before.AsObject(), fixture.State, Options(component), f.Versions)["Ports"]!) && ArchiveStore.Fingerprint(after["NetworkTuning"]!) == ArchiveStore.Fingerprint(before["NetworkTuning"]!), "append changed connection/network: " + component);
            Check(!remote.Commands.Any(asset => asset is "base-system.sh" or "ssh-transition.sh" or "bootstrap-access.sh" or "ssh-cutover.sh" or "network-tuning.sh"), "append replayed initial deployment: " + component);
            Check(!remote.ArmedComponents.Contains("Protocols") && remote.ArmedComponents.Contains(component == "Tunnel" ? "Cloudflared" : component), "append snapshot scope widened: " + component);
            if (component != "RealityEntry") Check(f.Store.ReadSecret(SafePath.Resolve(fixture.Directory, "secrets.dotnet.private.json")).Text("Xray.Uuid") == secretBefore && ArchiveStore.Fingerprint(after["Reality"]!) == ArchiveStore.Fingerprint(before["Reality"]!), "existing Reality changed during append");
            if (component == "AnyTlsEntry") Check(after.Flag("ProtocolInventory.RealityEntry.Enabled") && after.Flag("ProtocolInventory.AnyTlsEntry.Enabled") && after.Text("ActiveEntry") == "RealityEntry", "AnyTLS stopped existing Reality or changed default entry");
            var expected = OperationSteps.Create(request, fixture.Plan).Select(step => step.Id).ToArray();
            Check(events.Where(e => e.StepState == TaskStepState.Completed).Select(e => e.StepId).SequenceEqual(expected) && events.Last(e => e.StepState != null).Completed == expected.Length, "progress completion not tied to actual steps");
        }
        var blocked = Managed("append-collision"); var blockedRemote = new FakeRemote { InstallationCheckCode = "ComponentExists" }; blockedRemote.SeedProtocols(blocked.Plan);
        await RefusesAsync(() => f.Engine(blockedRemote).ExecuteAsync(new(OperationKind.InstallComponent, blocked.Relative, Options("ShadowsocksLanding")), Guid.NewGuid().ToString("N"), new InlineProgress<TaskProgress>(_ => { }), default), "remote collision ignored"); Check(blockedRemote.Mutations == 0, "collision check wrote remote state");
        var failed = Managed("append-rollback"); var failedRemote = new FakeRemote { FailAsset = "sing-box-apply-config.sh", StatusPhase = "Armed" }; failedRemote.SeedProtocols(failed.Plan); var failedId = Guid.NewGuid().ToString("N"); failedRemote.StatusTaskId = failedId;
        var failureEvents = new List<TaskProgress>(); await RefusesAsync(() => f.Engine(failedRemote).ExecuteAsync(new(OperationKind.InstallComponent, failed.Relative, Options("ShadowsocksLanding")), failedId, new InlineProgress<TaskProgress>(failureEvents.Add), default), "failed addition returned success");
        var restoredPlan = ArchiveStore.ReadJson(SafePath.Resolve(failed.Directory, "deployment-plan.json"));
        var changedSections = failed.Plan.Select(item => item.Key).Union(restoredPlan.Select(item => item.Key)).Where(key => !JsonNode.DeepEquals(failed.Plan[key], restoredPlan[key]));
        Check(JsonNode.DeepEquals(restoredPlan, failed.Plan) && failedRemote.Commands.Contains("protocol-migration-trigger-rollback.sh"), "scoped failure did not restore original plan: " + string.Join(",", changedSections));
        Check(failureEvents.Any(e => e.StepId == "component-install" && e.StepState == TaskStepState.Failed) && !failureEvents.Any(e => e.StepId == "installation-validation" && e.StepState == TaskStepState.Completed), "failed/unfinished progress shown as complete");
        Check(ArchiveStore.ReadJson(SafePath.Resolve(failed.Directory, "deployment-state.json")).Text("LastTask.Stage") == "sing-box-apply-config" && failureEvents.Last().Stage == "sing-box-apply-config", "rollback hid original failed stage in archive or task history");
        var cancelled = Managed("append-cancel"); using var cancellation = new CancellationTokenSource(); var cancelRemote = new FakeRemote { StatusPhase = "Armed" }; cancelRemote.SeedProtocols(cancelled.Plan); var cancelId = Guid.NewGuid().ToString("N"); cancelRemote.StatusTaskId = cancelId; cancelRemote.ObserveAsset = asset => { if (asset == "sing-box-apply-config.sh") cancellation.Cancel(); };
        try { await f.Engine(cancelRemote).ExecuteAsync(new(OperationKind.InstallComponent, cancelled.Relative, Options("ShadowsocksLanding")), cancelId, new InlineProgress<TaskProgress>(_ => { }), cancellation.Token); throw new Exception("append cancellation ignored"); } catch (OperationCanceledException) { assertions++; }
        Check(cancelRemote.Commands.Contains("protocol-migration-trigger-rollback.sh") && ArchiveStore.ReadJson(SafePath.Resolve(cancelled.Directory, "operation-pending.dotnet.json")).Text("Phase") == "RolledBack", "cancel did not reconcile scoped transaction");
        var lostAck = Managed("append-commit-ack"); var ackRemote = new FakeRemote { FailAsset = "maintenance-transaction-commit.sh", StatusPhase = "Committed" }; ackRemote.SeedProtocols(lostAck.Plan);
        var ackId = Guid.NewGuid().ToString("N"); ackRemote.StatusTaskId = ackId; var ackEvents = new List<TaskProgress>();
        Check(await f.Engine(ackRemote).ExecuteAsync(new(OperationKind.InstallComponent, lostAck.Relative, Options("ShadowsocksLanding")), ackId, new InlineProgress<TaskProgress>(ackEvents.Add), default) == TaskOutcome.CompletedWithWarnings, "confirmed committed addition was rolled back after lost acknowledgement");
        Check(ackRemote.Commands.Count(asset => asset == "maintenance-transaction-commit.sh") == 1 && !ackRemote.Commands.Contains("protocol-migration-trigger-rollback.sh"), "lost acknowledgement replayed installation or triggered rollback");
        Check(ackEvents.Last().StepId == "installation-commit" && ackEvents.Last().StepState == TaskStepState.Completed && ackEvents.Last().Completed == ackEvents.Last().Total, "reconciled commit remained marked failed in progress");
    }
}
