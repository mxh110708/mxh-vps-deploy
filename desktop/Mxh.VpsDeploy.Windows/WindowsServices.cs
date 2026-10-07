using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Windows;

public sealed class WindowsSecretProtector : ISecretProtector
{
    private static readonly byte[] Entropy = System.Text.Encoding.UTF8.GetBytes("MXH.VPSDeploy.Credentials.v1");
    public string Format => "WindowsCurrentUser.dotnet.v1";
    public byte[] Protect(ReadOnlySpan<byte> data) { var bytes = data.ToArray(); try { return ProtectedData.Protect(bytes, Entropy, DataProtectionScope.CurrentUser); } finally { CryptographicOperations.ZeroMemory(bytes); } }
    public byte[] Unprotect(ReadOnlySpan<byte> data) { var bytes = data.ToArray(); try { return ProtectedData.Unprotect(bytes, Entropy, DataProtectionScope.CurrentUser); } finally { CryptographicOperations.ZeroMemory(bytes); } }
}

public sealed class WindowsManagedKeyAccess : IPrivateKeyAccess
{
    public void PrepareManagedCopy(string path)
    {
        SafePath.CheckLinks(path);
        // Only called for a newly created app-owned copy, never for a provider source.
        var user = WindowsIdentity.GetCurrent().User ?? throw new OperationException("无法识别当前 Windows 用户。");
        var access = new FileSecurity(); access.SetOwner(user); access.SetAccessRuleProtection(true, false);
        access.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(access);
    }
}
