using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Mxh.VpsDeploy.Core;
using Renci.SshNet;

namespace Mxh.VpsDeploy.Infrastructure;

public sealed class SshSessionFactory(ArchiveStore store) : IRemoteSessionFactory
{
    private readonly HostTrust trust = new(store);
    public async Task<IRemoteSession> OpenAsync(SshEndpoint endpoint, IUserInteraction interaction, CancellationToken cancellationToken)
    {
        if (endpoint.Port is < 1 or > 65535 || string.IsNullOrWhiteSpace(endpoint.Host) || !Regex.IsMatch(endpoint.User, "^[a-z_][a-z0-9_-]{0,31}$")) throw new OperationException("SSH 连接参数无效。");
        return await Task.Run(async () =>
        {
            PrivateKeyFile? key = null;
            var methods = new List<AuthenticationMethod>();
            if (endpoint.KeyPath != null)
            {
                SafePath.CheckLinks(endpoint.KeyPath);
                try { key = string.IsNullOrEmpty(endpoint.KeyPassphrase) ? new PrivateKeyFile(endpoint.KeyPath) : new PrivateKeyFile(endpoint.KeyPath, endpoint.KeyPassphrase); }
                catch (Renci.SshNet.Common.SshPassPhraseNullOrEmptyException) { throw new KeyPassphraseRequiredException(); }
                methods.Add(new PrivateKeyAuthenticationMethod(endpoint.User, key));
            }
            if (endpoint.Password != null) methods.Add(new PasswordAuthenticationMethod(endpoint.User, endpoint.Password));
            if (methods.Count == 0) throw new OperationException("请提供 SSH 密钥或密码。");
            var connection = new ConnectionInfo(endpoint.Host, endpoint.Port, endpoint.User, methods.ToArray()) { Timeout = TimeSpan.FromSeconds(20) };
            var ssh = new SshClient(connection); var sftp = new SftpClient(connection);
            bool Accept(byte[] hostKey, string algorithm)
            {
                return trust.AcceptAsync(endpoint.Host, endpoint.Port, algorithm, hostKey, interaction, cancellationToken).GetAwaiter().GetResult();
            }
            ssh.HostKeyReceived += (_, e) => e.CanTrust = Accept(e.HostKey, e.HostKeyName);
            sftp.HostKeyReceived += (_, e) => e.CanTrust = Accept(e.HostKey, e.HostKeyName);
            try { await ssh.ConnectAsync(cancellationToken); await sftp.ConnectAsync(cancellationToken); return new SshRemoteSession(ssh, sftp, key); }
            catch { ssh.Dispose(); sftp.Dispose(); key?.Dispose(); throw; }
        }, cancellationToken);
    }
}

internal sealed class SshRemoteSession(SshClient ssh, SftpClient sftp, PrivateKeyFile? key) : IRemoteSession
{
    public async Task<CommandResult> RunAsync(string command, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var remote = ssh.CreateCommand(command); remote.CommandTimeout = timeout;
        await remote.ExecuteAsync(cancellationToken);
        return new(remote.ExitStatus ?? -1, remote.Result, remote.Error);
    }
    public async Task<CommandResult> RunScriptAsync(string payload, TimeSpan timeout, bool mutating, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var created = await RunAsync("umask 077; mktemp -d /tmp/mxh-vps.XXXXXXXXXX", TimeSpan.FromSeconds(30), cancellationToken);
        created.RequireSuccess("无法建立远端任务临时目录。");
        var directory = created.Output.Trim();
        if (!Regex.IsMatch(directory, @"^/tmp/mxh-vps\.[A-Za-z0-9]{10}$")) throw new OperationException("远端临时目录返回异常。");
        var script = directory + "/operation.sh";
        try
        {
            var bytes = Encoding.UTF8.GetBytes(payload.Replace("\r\n", "\n").Replace('\r', '\n'));
            using var stream = new MemoryStream(bytes);
            try { await Task.Run(() => sftp.UploadFile(stream, script, false), cancellationToken); sftp.ChangePermissions(script, 0x180); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            cancellationToken.ThrowIfCancellationRequested();
            // Once a mutation starts, finish the remote step before honoring UI cancellation.
            // Disconnecting a channel does not establish whether a remote write happened.
            return await RunAsync("bash " + ShellQuote(script), timeout, mutating ? CancellationToken.None : cancellationToken);
        }
        finally
        {
            try { await RunAsync("rm -f -- " + ShellQuote(script) + "; rmdir -- " + ShellQuote(directory), TimeSpan.FromSeconds(30), CancellationToken.None); }
            catch { /* A connection loss is reported by the caller as requiring recovery. */ }
        }
    }
    public async Task<byte[]> ReadFileAsync(string absolutePath, CancellationToken cancellationToken)
    {
        ValidateRemotePath(absolutePath);
        return await Task.Run(() => { using var data = new MemoryStream(); sftp.DownloadFile(absolutePath, data); return data.ToArray(); }, cancellationToken);
    }
    public async Task DownloadAsync(string absolutePath, string destination, CancellationToken cancellationToken)
    {
        ValidateRemotePath(absolutePath); SafePath.CheckLinks(destination);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temporary = destination + ".download-" + Guid.NewGuid().ToString("N");
        try
        {
            await Task.Run(() => { using var file = new FileStream(temporary, FileMode.CreateNew); sftp.DownloadFile(absolutePath, file); file.Flush(true); }, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested(); SafePath.CheckLinks(destination); File.Move(temporary, destination, false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static string ShellQuote(string value) => "'" + value.Replace("'", "'\"'\"'") + "'";
    private static void ValidateRemotePath(string path)
    {
        if (!path.StartsWith('/') || path.Contains('\0') || path.Contains('\r') || path.Contains('\n') || path.Split('/').Contains("..")) throw new OperationException("远端文件路径无效。");
    }
    public ValueTask DisposeAsync() { ssh.Dispose(); sftp.Dispose(); key?.Dispose(); return ValueTask.CompletedTask; }
}
