using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Infrastructure;

public sealed class HostTrust(ArchiveStore store)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task<bool> AcceptAsync(string host, int port, string algorithm, byte[] key, IUserInteraction user, CancellationToken token)
    {
        var fingerprint = "SHA256:" + Convert.ToBase64String(SHA256.HashData(key)).TrimEnd('='); var id = ArchiveStore.Digest(Encoding.UTF8.GetBytes(host)); var file = store.Paths.Resolve("private/ssh-hosts.dotnet.json");
        await gate.WaitAsync(token);
        try
        {
            var hosts = File.Exists(file) ? ArchiveStore.ReadJson(file) : new JsonObject();
            if (hosts.Text(id) == fingerprint) return true;
            if (hosts.ContainsKey(id)) throw new OperationException("SSH 主机密钥发生变化，请先独立核对服务器身份。");
            if (!await user.ConfirmHostAsync(new(host, port, algorithm, fingerprint, false), token)) return false;
            hosts[id] = fingerprint; ArchiveStore.WriteJson(file, hosts); return true;
        }
        finally { gate.Release(); }
    }
}
