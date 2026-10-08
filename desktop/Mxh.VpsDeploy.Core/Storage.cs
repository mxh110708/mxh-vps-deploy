using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Mxh.VpsDeploy.Core;

public sealed class AppPaths
{
    public string Root { get; }
    public string Private => Resolve("private");
    public string Instances => Resolve("private/instances");
    public AppPaths(string root) { Root = Path.GetFullPath(root); SafePath.CheckLinks(Root); }
    public string Resolve(string relative) => SafePath.Resolve(Root, relative);
    public string Instance(string relative) => SafePath.Resolve(Instances, relative);
    public static string Segment(string value)
    {
        value = value.Trim();
        if (value is "." or ".." || !Regex.IsMatch(value, @"^[\p{L}\p{N}][\p{L}\p{N}._ -]{0,63}$") || value.EndsWith('.') || value.EndsWith(' ') || Regex.IsMatch(value, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase))
            throw new OperationException("名称包含路径或系统保留字符。");
        return value;
    }
}

public static class SafePath
{
    public static string Resolve(string root, string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains(':') || relative.Contains('\\') || relative.Split('/').Any(p => p is ".." or "." or ""))
            throw new OperationException("路径超出允许范围。");
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(Path.Combine(root, relative));
        if (!full.StartsWith(fullRoot, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new OperationException("路径超出允许范围。");
        CheckLinks(full);
        return full;
    }
    public static void CheckLinks(string full)
    {
        for (var path = Path.GetFullPath(full); !string.IsNullOrEmpty(path); path = Path.GetDirectoryName(path))
        {
            try { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new OperationException("目录包含链接，已停止操作。"); }
            catch (FileNotFoundException) { if (new FileInfo(path).LinkTarget != null) throw new OperationException("目录包含链接，已停止操作。"); }
            catch (DirectoryNotFoundException) { if (new DirectoryInfo(path).LinkTarget != null) throw new OperationException("目录包含链接，已停止操作。"); }
        }
    }
    public static void CheckTree(string root)
    {
        CheckLinks(root);
        foreach (var entry in Directory.EnumerateFileSystemEntries(root))
        {
            CheckLinks(entry);
            if (Directory.Exists(entry)) CheckTree(entry);
        }
    }
}

public sealed class ArchiveStore(AppPaths paths, ISecretProtector protector)
{
    public AppPaths Paths { get; } = paths;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    public static string Digest(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    public static string Fingerprint(JsonNode node) => Digest(Encoding.UTF8.GetBytes(Canonical(node)));
    private static string Canonical(JsonNode? node) => node switch
    {
        JsonObject o => "{" + string.Join(',', o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => JsonSerializer.Serialize(p.Key) + ":" + Canonical(p.Value))) + "}",
        JsonArray a => "[" + string.Join(',', a.Select(Canonical)) + "]",
        _ => node?.ToJsonString() ?? "null"
    };
    public static JsonObject ReadJson(string path)
    {
        SafePath.CheckLinks(path);
        return JsonNode.Parse(File.ReadAllBytes(path))?.AsObject() ?? throw new OperationException("归档内容无效。");
    }
    public static void WriteJson(string path, JsonNode value) => AtomicWrite(path, Encoding.UTF8.GetBytes(value.ToJsonString(JsonOptions)));
    public static void AtomicWrite(string path, byte[] bytes)
    {
        SafePath.CheckLinks(path); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".write-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { stream.Write(bytes); stream.Flush(true); }
            SafePath.CheckLinks(path); File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public void WriteSecret(string path, JsonObject data)
    {
        var clear = Encoding.UTF8.GetBytes(data.ToJsonString());
        try { WriteJson(path, new JsonObject { ["schema_version"] = 1, ["protection"] = protector.Format, ["data"] = Convert.ToBase64String(protector.Protect(clear)) }); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }
    public JsonObject ReadSecret(string path)
    {
        var value = ReadJson(path);
        if (value.Text("protection") != protector.Format) throw new OperationException("凭据由其他系统或账号保护，请由维护者转换。");
        var clear = protector.Unprotect(Convert.FromBase64String(value.Text("data")));
        try { return JsonNode.Parse(clear)!.AsObject(); } finally { CryptographicOperations.ZeroMemory(clear); }
    }
    public FileStream LockInstanceGuard(string relative)
    {
        OperationPolicy.Validate(new(OperationKind.HealthAudit, relative, new()));
        var identity = Path.GetFullPath(Paths.Instance(relative)); if (OperatingSystem.IsWindows()) identity = identity.ToUpperInvariant();
        var file = Paths.Resolve("private/instance-locks/" + Digest(Encoding.UTF8.GetBytes(identity)) + ".lock");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        try { return new FileStream(file, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new OperationException("该实例已有任务运行，请等待其结束。", code: "InstanceBusy"); }
    }
    public IDisposable LockInstance(string relative)
    {
        var guard = LockInstanceGuard(relative);
        try
        {
            var directory = Paths.Instance(relative); Directory.CreateDirectory(directory);
            var legacy = new FileStream(SafePath.Resolve(directory, ".operation.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return new InstanceLock(guard, legacy);
        }
        catch (IOException) { guard.Dispose(); throw new OperationException("该实例已有任务运行，请等待其结束。", code: "InstanceBusy"); }
        catch { guard.Dispose(); throw; }
    }
    private sealed class InstanceLock(FileStream guard, FileStream legacy) : IDisposable { public void Dispose() { legacy.Dispose(); guard.Dispose(); } }
    public IEnumerable<(string RelativePath, JsonObject Plan)> ListInstances()
    {
        if (!Directory.Exists(Paths.Instances)) yield break;
        SafePath.CheckTree(Paths.Instances);
        foreach (var file in Directory.EnumerateFiles(Paths.Instances, "deployment-plan.json", SearchOption.AllDirectories))
        {
            JsonObject? plan = null;
            try { plan = ReadJson(file); } catch (JsonException) { }
            if (plan != null) yield return (Path.GetRelativePath(Paths.Instances, Path.GetDirectoryName(file)!).Replace('\\', '/'), plan);
        }
    }
    public void AppendHistory(TaskRecord record)
    {
        var file = Paths.Resolve("private/task-history.dotnet.json");
        var old = File.Exists(file) ? JsonNode.Parse(File.ReadAllText(file))!.AsArray() : new JsonArray();
        var index = old.Select((v, i) => (v, i)).FirstOrDefault(p => p.v?.AsObject().Text("Id") == record.Id);
        var node = JsonSerializer.SerializeToNode(record, JsonOptions);
        if (index.v != null) old[index.i] = node; else old.Add(node);
        while (old.Count > 120) old.RemoveAt(0);
        WriteJson(file, old);
    }
}
