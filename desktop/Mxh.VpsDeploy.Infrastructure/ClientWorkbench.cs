using System.Text.Json.Nodes;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Infrastructure;

public sealed class ClientWorkbench(ArchiveStore store, IExternalToolRunner tools, IValidationAssets assets, string python)
{
    public void Save(JsonObject scheme)
    {
        var id = scheme.Text("Id"); if (!System.Text.RegularExpressions.Regex.IsMatch(id, "^[a-f0-9]{32}$")) throw new OperationException("方案标识无效。");
        store.WriteSecret(store.Paths.Resolve("private/client-schemes/" + id + ".dotnet.private.json"), scheme);
    }
    public IEnumerable<JsonObject> List()
    {
        var directory = store.Paths.Resolve("private/client-schemes"); if (!Directory.Exists(directory)) return [];
        SafePath.CheckTree(directory);
        return Directory.EnumerateFiles(directory, "*.dotnet.private.json").Select(store.ReadSecret).ToArray();
    }
    public async Task<JsonArray> ReadSourcesAsync(string clash, string sing, CancellationToken cancellationToken)
    {
        var result = await tools.RunAsync(python, [store.Paths.Resolve("scripts/inspect_client_sources.py"), "--clash", clash, "--sing-box", sing], null, TimeSpan.FromSeconds(30), cancellationToken);
        result.RequireSuccess("来源配置无法提取受支持节点。"); return JsonNode.Parse(result.Output)!.AsArray();
    }
    public async Task<JsonObject> BuildAsync(JsonObject scheme, CancellationToken cancellationToken)
    {
        var specification = ClientSchemes.Specification(scheme); var directory = store.Paths.Resolve("private/client-candidates/" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var specFile = SafePath.Resolve(directory, "layout.private.json"); ArchiveStore.WriteJson(specFile, specification);
        var sources = new JsonObject { [scheme.Text("Clash")] = ClientSchemes.SourceFingerprint(scheme.Text("Clash")), [scheme.Text("SingBox")] = ClientSchemes.SourceFingerprint(scheme.Text("SingBox")) };
        if (scheme["Sources"] is JsonObject originalSources) foreach (var item in originalSources) { if (ClientSchemes.SourceFingerprint(item.Key) != item.Value!.ToString()) throw new OperationException("节点来源发生变化，请重新读取。"); sources[item.Key] = item.Value.DeepClone(); }
        var result = await tools.RunAsync(python, [store.Paths.Resolve("scripts/build_client_authority.py"), "--clash", scheme.Text("Clash"), "--sing-box", scheme.Text("SingBox"), "--spec", specFile, "--output", directory], null, TimeSpan.FromSeconds(60), cancellationToken);
        result.RequireSuccess("候选生成失败，请检查节点、连接关系与分组。");
        var candidate = new JsonObject { ["Clash"] = SafePath.Resolve(directory, "Clash_General.candidate.yaml"), ["SingBox"] = SafePath.Resolve(directory, "sing-box-general.candidate.json"), ["Sources"] = sources, ["SpecFingerprint"] = ArchiveStore.Fingerprint(specification), ["ValidationStatus"] = "Pending", ["Targets"] = new JsonObject() };
        candidate["ClashHash"] = ClientSchemes.SourceFingerprint(candidate.Text("Clash")); candidate["SingBoxHash"] = ClientSchemes.SourceFingerprint(candidate.Text("SingBox"));
        scheme["Candidate"] = candidate; Save(scheme); return candidate;
    }
    public async Task ValidateAsync(JsonObject scheme, CancellationToken cancellationToken)
    {
        var candidate = scheme["Candidate"]?.AsObject() ?? throw new OperationException("请先生成候选。");
        candidate["ValidationStatus"] = "Pending"; candidate["Targets"] = new JsonObject(); Save(scheme);
        if (candidate.Text("SpecFingerprint") != ArchiveStore.Fingerprint(ClientSchemes.Specification(scheme))) throw new OperationException("方案已变化，请重新生成候选。");
        var beforeClash = ClientSchemes.SourceFingerprint(candidate.Text("Clash")); var beforeSing = ClientSchemes.SourceFingerprint(candidate.Text("SingBox"));
        if (beforeClash != candidate.Text("ClashHash") || beforeSing != candidate.Text("SingBoxHash")) throw new OperationException("候选已被外部修改。");
        var mihomoPath = assets.ResolveCore("mihomo"); var singPath = assets.ResolveCore("sing-box"); await ProtocolValidation.VerifyVersion(assets, tools, "mihomo", mihomoPath, cancellationToken); await ProtocolValidation.VerifyVersion(assets, tools, "sing-box", singPath, cancellationToken);
        var data = SafePath.Resolve(Path.GetDirectoryName(candidate.Text("Clash"))!, "validation-data-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(data);
        try
        {
            if (Directory.Exists(assets.DataDirectory)) foreach (var file in Directory.EnumerateFiles(assets.DataDirectory)) { SafePath.CheckLinks(file); File.Copy(file, SafePath.Resolve(data, Path.GetFileName(file))); }
            var mihomo = await tools.RunAsync(mihomoPath, ["-t", "-d", data, "-f", candidate.Text("Clash")], null, TimeSpan.FromSeconds(40), cancellationToken); mihomo.RequireSuccess("Mihomo 校验失败。");
            var sing = await tools.RunAsync(singPath, ["check", "-c", candidate.Text("SingBox")], null, TimeSpan.FromSeconds(40), cancellationToken); sing.RequireSuccess("sing-box 校验失败。");
        }
        finally { SafePath.CheckTree(data); Directory.Delete(data, true); }
        if (beforeClash != ClientSchemes.SourceFingerprint(candidate.Text("Clash")) || beforeSing != ClientSchemes.SourceFingerprint(candidate.Text("SingBox"))) throw new OperationException("校验期间候选发生变化。");
        candidate["ValidationStatus"] = "Passed"; Save(scheme);
    }
    public void PreparePublish(JsonObject scheme, string clash, string sing)
    {
        var candidate = scheme["Candidate"]?.AsObject() ?? throw new OperationException("请先生成候选。");
        ClientSchemes.ValidateAuthorityPath(clash); ClientSchemes.ValidateAuthorityPath(sing);
        if (candidate.Text("SpecFingerprint") != ArchiveStore.Fingerprint(ClientSchemes.Specification(scheme))) throw new OperationException("方案已变化，请重新生成候选。");
        candidate["Targets"] = new JsonObject { [clash] = ClientSchemes.SourceFingerprint(clash), [sing] = ClientSchemes.SourceFingerprint(sing) }; Save(scheme);
    }
    public void Publish(JsonObject scheme, string clash, string sing)
    {
        var candidate = scheme["Candidate"]?.AsObject() ?? throw new OperationException("请先生成候选。");
        if (candidate.Text("SpecFingerprint") != ArchiveStore.Fingerprint(ClientSchemes.Specification(scheme))) throw new OperationException("方案在审阅后发生变化。");
        new CandidatePublisher(store.Paths).Publish(candidate, clash, sing);
    }
}
