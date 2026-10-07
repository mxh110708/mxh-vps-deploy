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
            Current = new(Guid.NewGuid().ToString("N"), current.Kind, DateTimeOffset.UtcNow, null, TaskOutcome.Running, "准备");
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
                Current = Current with { Outcome = exception is OperationException { NeedsRecovery: true } ? TaskOutcome.NeedsRecovery : TaskOutcome.Failed,
                    SafeError = exception is OperationException safe ? safe.Message : "任务失败，请核对当前阶段与恢复记录。", FinishedAt = DateTimeOffset.UtcNow };
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
        if (request.Kind == OperationKind.Upgrade && scopeName is not ("Protocol" or "KomariAgent" or "KomariController") || request.Kind == OperationKind.Restore && scopeName != "Protocol" || request.Kind == OperationKind.RotateCredentials && scopeName != "Protocol") throw new OperationException("任务与所选组件范围不匹配。");
        if (request.Kind == OperationKind.Decommission && (scopeName != "ManagedInstance" || request.Options.Text("Action") is not ("Disable" or "RemoveManaged"))) throw new OperationException("请选择明确的实例退役范围。");
        if (request.Kind == OperationKind.Komari && !(scopeName switch { "KomariAgent" => request.Options.Text("Action") is "Upgrade" or "Remove", "KomariController" => request.Options.Text("Action") is "Upgrade" or "Backup" or "Restore", "Tunnel" => request.Options.Text("Action") == "RotateToken", _ => false })) throw new OperationException("该监控组件不支持所选操作。");
    }
    public static string Summary(OperationRequest request) => request.Kind switch
    {
        OperationKind.ConnectExisting => "接入已有实例：只读识别现有配置，保留 SSH 认证、端口与防火墙。",
        OperationKind.Deploy => "新机部署：先审计系统与已有服务，建立备份后配置双 SSH 入口和所选协议；最后独立验收。",
        OperationKind.HealthAudit => "只读健康与漂移检查；不重启或修改服务。",
        OperationKind.TuneNetwork => "只修改部署器自己的网络参数文件，不重放协议、SSH 或防火墙。",
        OperationKind.Recover => "先核对未完成事务的真实状态，再按明确范围恢复。",
        _ => "任务：" + request.Kind + "；组件：" + request.Options.Text("Scope", request.Options.Text("Protocol", "受管协议")) + "。操作前备份，失败按同一组件范围恢复。"
    };
}
