using System.Text.Json.Nodes;

namespace Mxh.VpsDeploy.Core;

public interface IOperationWorkflow
{
    Task<TaskOutcome> ExecuteAsync(OperationRequest request, string taskId, IProgress<TaskProgress> progress, CancellationToken cancellationToken);
}

public sealed class TaskCoordinator(ArchiveStore store, IOperationWorkflow workflow)
{
    private readonly SemaphoreSlim active = new(1, 1);
    public TaskRecord? Current { get; private set; }
    public ReviewedOperation Review(OperationRequest request)
    {
        var snapshot = request.Snapshot(); OperationPolicy.Validate(snapshot);
        var planHash = ArchiveFingerprint(snapshot.InstanceRelativePath);
        return new(snapshot, Fingerprint(snapshot), planHash, OperationPolicy.Summary(snapshot));
    }
    public static string Fingerprint(OperationRequest request) => ArchiveStore.Fingerprint(new JsonObject
    {
        ["kind"] = request.Kind.ToString(), ["instance"] = request.InstanceRelativePath, ["options"] = request.Options.DeepClone()
    });
    private string ArchiveFingerprint(string relative)
    {
        var directory = store.Paths.Instance(relative); var files = new JsonObject();
        foreach (var name in new[] { "deployment-plan.json", "deployment-state.json", "secrets.dotnet.private.json", "deployment-secrets.private.json", "operation-pending.dotnet.json" })
        { var path = SafePath.Resolve(directory, name); files[name] = ClientSchemes.SourceFingerprint(path); }
        return ArchiveStore.Fingerprint(files);
    }
    public async Task<TaskRecord> ExecuteAsync(ReviewedOperation review, OperationRequest current, IProgress<TaskProgress> progress, CancellationToken cancellationToken)
    {
        if (Fingerprint(current) != review.Fingerprint || Fingerprint(review.Request) != review.Fingerprint) throw new OperationException("表单在审阅后发生变化，请重新审阅。");
        if (!await active.WaitAsync(0, cancellationToken)) throw new OperationException("已有任务执行中。");
        try
        {
            using var instanceLock = store.LockInstance(current.InstanceRelativePath);
            var planHash = ArchiveFingerprint(current.InstanceRelativePath);
            if (planHash != review.PlanFingerprint) throw new OperationException("实例归档在审阅后发生变化，请重新读取并审阅。");
            Current = new(Guid.NewGuid().ToString("N"), current.Kind, DateTimeOffset.UtcNow, null, TaskOutcome.Running, "准备", InstanceRelativePath: current.InstanceRelativePath, TargetLabel: OperationPolicy.TargetLabel(current));
            store.AppendHistory(Current);
            var reporting = new InlineProgress<TaskProgress>(p => { Current = Current with { Stage = p.Stage }; progress.Report(p); });
            try
            {
                var outcome = await workflow.ExecuteAsync(current.Snapshot(), Current.Id, reporting, cancellationToken);
                Current = Current with { Outcome = outcome, FinishedAt = DateTimeOffset.UtcNow };
            }
            catch (OperationCanceledException) { Current = Current with { Outcome = TaskOutcome.Cancelled, FinishedAt = DateTimeOffset.UtcNow }; }
            catch (Exception exception)
            {
                var safe = SafeFailures.Describe(exception);
                Current = Current with { Outcome = safe.NeedsRecovery ? TaskOutcome.NeedsRecovery : TaskOutcome.Failed,
                    SafeError = safe.Message, ErrorCode = safe.Code, NextAction = safe.NextAction, FinishedAt = DateTimeOffset.UtcNow };
            }
            store.AppendHistory(Current);
            return Current;
        }
        finally { active.Release(); }
    }
}

public sealed class InlineProgress<T>(Action<T> report) : IProgress<T> { public void Report(T value) => report(value); }

public static class OperationPolicy
{
    public static void Validate(OperationRequest request)
    {
        if (!Enum.IsDefined(request.Kind)) throw new OperationException("未知任务类型。");
        var names = request.InstanceRelativePath.Split('/');
        if (names.Length != 3 || names[2] != "MXH-VPS-Deploy" || names[0] != AppPaths.Segment(names[0]) || names[1] != AppPaths.Segment(names[1])) throw new OperationException("实例归档路径无效。");
        if (request.Kind == OperationKind.ProtocolState && request.Options.Text("Action") is not ("Enable" or "Disable" or "Switch" or "Uninstall")) throw new OperationException("未知协议操作。");
        if (request.Kind is OperationKind.Upgrade or OperationKind.Restore or OperationKind.Komari or OperationKind.Decommission)
        {
            if (!Enum.TryParse<ComponentScope>(request.Options.Text("Scope"), out var scope) || !Enum.IsDefined(scope)) throw new OperationException("请明确选择操作组件。");
            if (request.Kind == OperationKind.Restore && request.Options.Text("Backup") == "") throw new OperationException("请明确选择恢复归档。");
        }
        if (request.Kind == OperationKind.TuneNetwork && request.Options.Number("BandwidthMbps") <= 0) throw new OperationException("请填写套餐标称带宽。");
        var scopeName = request.Options.Text("Scope", "Protocol");
        if (request.Kind == OperationKind.Upgrade && scopeName != "Protocol" || request.Kind == OperationKind.Restore && scopeName != "Protocol" || request.Kind == OperationKind.RotateCredentials && scopeName != "Protocol") throw new OperationException("任务与所选组件范围不匹配。监控组件请从对应的监控入口管理。");
        if (request.Kind == OperationKind.Komari && request.Options.ContainsKey("Protocol")) throw new OperationException("监控与访问操作不能混入代理协议。");
        if (request.Kind == OperationKind.Decommission && (scopeName != "ManagedInstance" || request.Options.Text("Action") is not ("Disable" or "RemoveManaged"))) throw new OperationException("请选择明确的实例退役范围。");
        if (request.Kind == OperationKind.Komari && !(scopeName switch { "KomariAgent" => request.Options.Text("Action") is "Upgrade" or "Remove", "KomariController" => request.Options.Text("Action") is "Upgrade" or "Backup" or "Restore", "Tunnel" => request.Options.Text("Action") == "RotateToken", _ => false })) throw new OperationException("该监控组件不支持所选操作。");
    }
    public static string TargetLabel(OperationRequest request) => request.Kind switch
    {
        OperationKind.Upgrade => request.Options.Text("Protocol") switch { "RealityEntry" => "Xray · Reality 入口", "AnyTlsEntry" => "sing-box · AnyTLS / ECH 入口", "ShadowsocksLanding" => "sing-box · Shadowsocks 落地", _ => "代理核心" },
        OperationKind.Komari => (request.Options.Text("Scope") switch { "KomariAgent" => "Komari Agent", "KomariController" => "Komari 主控", _ => "Cloudflare Tunnel" }) + " · " + (request.Options.Text("Action") switch { "Upgrade" => "升级", "Remove" => "卸载", "Backup" => "一致性备份", "Restore" => "恢复备份", _ => "Token 轮换" }),
        _ => ""
    };
    public static string Summary(OperationRequest request) => request.Kind switch
    {
        OperationKind.ConnectExisting => "接入已有实例：只读识别现有配置，保留 SSH 认证、端口与防火墙。",
        OperationKind.ResumeImport => "继续接入草稿：重新只读识别现有配置，完成应用内归档。",
        OperationKind.Deploy => "新机部署：先审计系统与已有服务，建立备份后配置双 SSH 入口和所选用途；最后独立验收。网络调优由部署后另行手动发起。",
        OperationKind.HealthAudit => "只读健康与漂移检查；不重启或修改服务。",
        OperationKind.TuneNetwork => "只修改部署器自己的网络参数文件，不重放协议、SSH 或防火墙。\n套餐标称带宽：" + request.Options.Number("BandwidthMbps") + " Mbps\n参考 RTT：" + (request.Options.Number("ReferenceRttMs") == 0 ? "不启用自适应估算" : request.Options.Number("ReferenceRttMs") + " ms") + "。",
        OperationKind.Recover => "先核对未完成事务的真实状态，再按明确范围恢复。",
        OperationKind.Upgrade => "升级对象：" + TargetLabel(request) + "\n目标版本：" + request.Options.Text("TargetVersion") + "\n先核对状态并备份，再更新程序、重启所选服务并独立验收；失败按协议范围恢复。协议备份覆盖本机受管代理协议，恢复时须一并审阅。",
        OperationKind.Komari => "操作：" + TargetLabel(request) + (request.Options.Text("Action") == "Upgrade" ? "\n目标版本：" + request.Options.Text("TargetVersion") : "") + "\n" + (request.Options.Text("Scope") switch { "KomariAgent" => request.Options.Text("Action") == "Remove" ? "卸载当前 VPS 的 Agent，停止向主控上报；不删除主控历史数据。" : "备份并更新当前 VPS 的 Agent，保留连接配置和原启停状态。", "KomariController" => "先备份当前 VPS 的主控程序和数据；一致性备份、升级及恢复需要短暂停止主控，再恢复原启停状态。只处理主控专用备份，不包含 Tunnel。", _ => "只轮换当前 VPS 的 Tunnel 连接 Token 并重启 Tunnel；新 Token 在执行时输入，不修改 Cloudflare DNS 或主控数据。" }),
        _ => "任务：" + request.Kind + "；组件：" + request.Options.Text("Scope", request.Options.Text("Protocol", "受管协议")) + "。操作前备份，失败按同一组件范围恢复。"
    };
}
