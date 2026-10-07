using System.Text.Json.Nodes;

namespace Mxh.VpsDeploy.Core;

public static class ClientSchemes
{
    public static JsonObject New(AppPaths paths) => new()
    {
        ["Id"] = Guid.NewGuid().ToString("N"), ["Name"] = "新方案", ["OutputClients"] = "Both", ["Nodes"] = new JsonArray(), ["SourceMode"] = "GenericTemplate",
        ["Clash"] = paths.Resolve("templates/client/clash-general.template.yaml"), ["SingBox"] = paths.Resolve("templates/client/sing-box-general.template.json"),
        ["Layout"] = ArchiveStore.ReadJson(paths.Resolve("config/client-layout.default.json")), ["Targets"] = new JsonObject { ["Clash"] = "", ["SingBox"] = "" }
    };
    // Missing selection is the known, historical two-client scheme format.
    public static string[] Formats(JsonObject model) => model.Text("OutputClients", "Both") switch
    {
        "Both" => ["Clash", "SingBox"], "Clash" => ["Clash"], "SingBox" => ["SingBox"],
        _ => throw new OperationException("请至少选择一个生成目标。")
    };
    public static string OutputLabel(JsonObject model) => model.Text("OutputClients", "Both") switch { "SingBox" => "sing-box", "Clash" => "Clash", "Both" => "sing-box + Clash", "None" => "未选择生成目标", _ => throw new OperationException("配置目标无效。") };
    public static IEnumerable<(string Format, string Path)> SelectedTargets(JsonObject model, string clash, string sing) => Formats(model).Select(format => (format, format == "Clash" ? clash : sing));
    public static JsonObject Specification(JsonObject scheme)
    {
        var formats = Formats(scheme);
        var nodes = scheme["Nodes"]!.AsArray(); var layout = scheme["Layout"]!.AsObject();
        if (nodes.Count == 0 || nodes.Select(n => n!.Text("name")).Distinct().Count() != nodes.Count) throw new OperationException("请添加节点，名称不能重复。");
        foreach (var node in nodes)
            foreach (var format in formats)
                if (node![format == "Clash" ? "clash" : "sing_box"] is not JsonObject config || config.Text(format == "Clash" ? "name" : "tag") != node.Text("name"))
                    throw new OperationException("节点缺少所选客户端的配置，请补充节点或重新读取来源。");
        var regions = layout.Strings("region_groups").Where(region => nodes.Any(n => n!.Text("kind") == "entry" && n.Text("region_group") == region)).ToArray();
        if (regions.Length == 0) throw new OperationException("至少需要一个入口节点及地区组。");
        foreach (var node in nodes.Where(n => n!.Text("kind") == "landing")) if (!regions.Contains(node!.Text("transit_group"))) throw new OperationException("落地节点需要连接到有可用节点的入口组。");
        var groups = new JsonArray();
        void Group(string name, IEnumerable<string> members) => groups.Add(new JsonObject { ["name"] = name, ["members"] = new JsonArray(members.Distinct().Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()) });
        foreach (var region in regions) Group(region, nodes.Where(n => n!.Text("kind") == "entry" && n.Text("region_group") == region).Select(n => n!.Text("name")));
        var exit = layout.Text("default_exit_group"); var direct = layout.Text("direct_group");
        var landings = nodes.Where(n => n!.Text("kind") == "landing").Select(n => n!.Text("name")).ToArray();
        var allowed = regions.Concat(landings).Append("DIRECT").ToArray();
        Group(exit, layout.Strings("default_exit_members").Where(allowed.Contains).Concat(allowed)); Group(direct, ["DIRECT", exit]);
        var business = new[] { exit, direct }.Concat(regions).Concat(landings).ToArray();
        foreach (var definition in layout["business_groups"]!.AsArray())
        {
            var first = business.Contains(definition!.Text("default")) ? definition.Text("default") : exit;
            var members = new[] { first }.Concat(definition.Strings("order").Where(business.Contains)).Concat(business);
            if (definition.Flag("include_block")) members = members.Append("BLOCK"); Group(definition.Text("name"), members);
        }
        foreach (var definition in layout["guard_groups"]!.AsArray()) Group(definition!.Text("name"), definition.Strings("members"));
        return new JsonObject { ["schema_version"] = 1, ["source_mode"] = scheme.Text("SourceMode"), ["output_mode"] = "CandidateOnly", ["client_formats"] = new JsonArray(formats.Select(f => (JsonNode?)JsonValue.Create(f)).ToArray()), ["manual_nodes"] = nodes.DeepClone(), ["fragment_sources"] = new JsonArray(), ["existing_node_refs"] = new JsonArray(), ["groups"] = groups,
            ["group_order"] = new JsonArray(groups.Select(g => (JsonNode?)JsonValue.Create(g!.Text("name"))).ToArray()), ["remove_groups"] = new JsonArray(layout.Strings("region_groups").Where(r => !regions.Contains(r)).Select(r => (JsonNode?)JsonValue.Create(r)).ToArray()) };
    }
    public static string SourceFingerprint(string path) { SafePath.CheckLinks(path); return File.Exists(path) ? ArchiveStore.Digest(File.ReadAllBytes(path)) : "missing"; }
    public static void ValidateAuthorityPath(string path)
    {
        if (!Path.IsPathFullyQualified(path)) throw new OperationException("请选择完整的权威文件路径。");
        SafePath.CheckLinks(path);
        var normalized = path.Replace('\\', '/').ToLowerInvariant();
        if (normalized.Contains("/appdata/") && (normalized.Contains("clash") || normalized.Contains("verge"))) throw new OperationException("请选择独立权威文件，不能发布到客户端 AppData 副本。");
    }
}

public sealed class CandidatePublisher(AppPaths paths, Action<string, byte[]>? writer = null)
{
    private readonly Action<string, byte[]> write = writer ?? ArchiveStore.AtomicWrite;
    public void Publish(JsonObject candidate, string clashTarget, string singTarget)
    {
        if (Pending().Any()) throw new OperationException("存在未完成的客户端发布，请先在记录页恢复。");
        if (candidate.Text("ValidationStatus") != "Passed") throw new OperationException("候选尚未通过所选客户端的核心校验，不能导出。");
        var selected = ClientSchemes.SelectedTargets(candidate, clashTarget, singTarget).ToArray();
        foreach (var target in selected) ClientSchemes.ValidateAuthorityPath(target.Path);
        var comparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
        if (selected.Select(t => Path.GetFullPath(t.Path)).Distinct(comparer).Count() != selected.Length) throw new OperationException("配置文件不能使用同一路径。");
        foreach (var pair in candidate["Sources"]!.AsObject()) if (ClientSchemes.SourceFingerprint(pair.Key) != pair.Value!.ToString()) throw new OperationException("来源在生成候选后发生变化，请重新生成并校验。");
        var targets = selected.Select(t => Path.GetFullPath(t.Path)).ToArray(); var sources = selected.Select(t => candidate.Text(t.Format)).ToArray(); var hashes = selected.Select(t => candidate.Text(t.Format + "Hash")).ToArray();
        var expected = candidate["Targets"]!.AsObject();
        string Expected(string path) => expected[path]?.ToString() ?? throw new OperationException("目标缺少审阅时的摘要。");
        var bytes = sources.Select(source => { SafePath.CheckLinks(source); return File.ReadAllBytes(source); }).ToArray();
        for (var i = 0; i < targets.Length; i++) if (ArchiveStore.Digest(bytes[i]) != hashes[i] || ClientSchemes.SourceFingerprint(targets[i]) != Expected(targets[i])) throw new OperationException("候选或目标文件已变化，请重新审阅。");
        var locks = new List<FileStream>(); var transaction = paths.Resolve("private/client-publish/" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(transaction);
        var journal = new JsonObject { ["SchemaVersion"] = 2, ["SchemeId"] = candidate.Text("SchemeId"), ["Formats"] = new JsonArray(selected.Select(t => (JsonNode?)JsonValue.Create(t.Format)).ToArray()), ["Phase"] = "Preparing", ["Targets"] = new JsonArray(targets.Select(p => (JsonNode?)JsonValue.Create(p)).ToArray()), ["Hashes"] = new JsonArray(hashes.Select(h => (JsonNode?)JsonValue.Create(h)).ToArray()), ["OriginalHashes"] = new JsonArray(targets.Select(p => (JsonNode?)JsonValue.Create(Expected(p))).ToArray()) };
        var journalPath = SafePath.Resolve(transaction, "transaction.json");
        var originals = new byte[]?[targets.Length];
        try
        {
            foreach (var target in targets.Order(StringComparer.Ordinal)) { Directory.CreateDirectory(Path.GetDirectoryName(target)!); SafePath.CheckLinks(target + ".mxh-publish.lock"); locks.Add(new FileStream(target + ".mxh-publish.lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)); }
            for (var i = 0; i < targets.Length; i++)
            {
                if (ClientSchemes.SourceFingerprint(targets[i]) != Expected(targets[i])) throw new OperationException("目标在获取发布锁期间发生变化。");
                if (File.Exists(targets[i])) { originals[i] = File.ReadAllBytes(targets[i]); ArchiveStore.AtomicWrite(SafePath.Resolve(transaction, i + ".backup"), originals[i]!); }
            }
            journal["Phase"] = "Prepared"; ArchiveStore.WriteJson(journalPath, journal);
            for (var i = 0; i < targets.Length; i++) { write(targets[i], bytes[i]); journal["Applied"] = i + 1; ArchiveStore.WriteJson(journalPath, journal); }
            journal["Phase"] = "Committed"; ArchiveStore.WriteJson(journalPath, journal);
        }
        catch
        {
            var recovered = true;
            for (var i = 0; i < targets.Length; i++)
            {
                var current = ClientSchemes.SourceFingerprint(targets[i]);
                if (current == Expected(targets[i])) continue;
                if (journal.Text("Phase") == "Preparing" || current != hashes[i]) { recovered = false; continue; }
                try { if (originals[i] == null) File.Delete(targets[i]); else ArchiveStore.AtomicWrite(targets[i], originals[i]!); } catch { recovered = false; }
            }
            journal["Phase"] = recovered ? "RolledBack" : "NeedsRecovery"; ArchiveStore.WriteJson(journalPath, journal);
            throw new OperationException(recovered ? "发布未完成，已恢复原文件。" : "发布恢复未确认，保留记录，未覆盖外部改动。", !recovered);
        }
        finally { foreach (var held in locks) held.Dispose(); }
    }
    public IEnumerable<string> Pending()
    {
        var root = paths.Resolve("private/client-publish"); if (!Directory.Exists(root)) return [];
        SafePath.CheckTree(root);
        return Directory.EnumerateFiles(root, "transaction.json", SearchOption.AllDirectories).Where(p => ArchiveStore.ReadJson(p).Text("Phase") is not ("Committed" or "RolledBack")).ToArray();
    }
    public void Recover(string journalFile)
    {
        var root = paths.Resolve("private/client-publish");
        var relative = Path.GetRelativePath(root, Path.GetFullPath(journalFile)).Replace('\\', '/'); journalFile = SafePath.Resolve(root, relative);
        var journal = ArchiveStore.ReadJson(journalFile); if (journal.Text("Phase") is "Committed" or "RolledBack") return;
        var targets = journal.Strings("Targets"); var hashes = journal.Strings("Hashes"); var originals = journal.Strings("OriginalHashes");
        var formats = journal.Strings("Formats");
        var known = journal["SchemaVersion"] == null ? targets.Length == 2 : journal.Number("SchemaVersion") == 2 && formats.Length == targets.Length && formats.Distinct().Count() == formats.Length && formats.All(f => f is "Clash" or "SingBox");
        if (!known || journal.Text("Phase") is not ("Preparing" or "Prepared" or "NeedsRecovery") || targets.Length is < 1 or > 2 || hashes.Length != targets.Length || originals.Length != targets.Length || targets.Select(Path.GetFullPath).Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal).Count() != targets.Length || hashes.Any(h => !System.Text.RegularExpressions.Regex.IsMatch(h, "^[a-f0-9]{64}$")) || originals.Any(h => h != "missing" && !System.Text.RegularExpressions.Regex.IsMatch(h, "^[a-f0-9]{64}$"))) throw new OperationException("配置恢复记录不完整或版本不受支持。", true);
        if (journal.Text("Phase") == "Preparing") { journal["Phase"] = "RolledBack"; ArchiveStore.WriteJson(journalFile, journal); return; }
        var held = new List<FileStream>();
        try
        {
            foreach (var target in targets.Order(StringComparer.Ordinal)) { ClientSchemes.ValidateAuthorityPath(target); SafePath.CheckLinks(target + ".mxh-publish.lock"); held.Add(new FileStream(target + ".mxh-publish.lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)); }
            byte[]?[] backups = new byte[]?[targets.Length];
            for (var i = 0; i < targets.Length; i++)
            {
                var current = ClientSchemes.SourceFingerprint(targets[i]); if (current != hashes[i] && current != originals[i]) throw new OperationException("目标含外部改动，未覆盖，请维护者核对。", true);
                if (originals[i] != "missing") { backups[i] = File.ReadAllBytes(SafePath.Resolve(Path.GetDirectoryName(journalFile)!, i + ".backup")); if (ArchiveStore.Digest(backups[i]!) != originals[i]) throw new OperationException("客户端恢复备份摘要不匹配。", true); }
            }
            journal["Phase"] = "NeedsRecovery"; ArchiveStore.WriteJson(journalFile, journal);
            for (var i = 0; i < targets.Length; i++)
            {
                var current = ClientSchemes.SourceFingerprint(targets[i]); if (current == originals[i]) continue; if (current != hashes[i]) throw new OperationException("恢复期间目标发生外部改动。", true);
                if (backups[i] == null) File.Delete(targets[i]); else ArchiveStore.AtomicWrite(targets[i], backups[i]!);
            }
            journal["Phase"] = "RolledBack"; ArchiveStore.WriteJson(journalFile, journal);
        }
        finally { foreach (var file in held) file.Dispose(); }
    }
}
