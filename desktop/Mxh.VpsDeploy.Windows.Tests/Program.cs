using System.Security.AccessControl;
using System.Security.Principal;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Infrastructure;
using Mxh.VpsDeploy.Windows;

var repository = Path.GetFullPath(args[0]);
var root = SafePath.Resolve(repository, ".test-output/windows-keys-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var assertions = 0;
void Check(bool value, string message) { if (!value) throw new Exception(message); assertions++; }
bool Protected(string path)
{
    var acl = new FileInfo(path).GetAccessControl();
    var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
    return acl.AreAccessRulesProtected && rules.Length == 1 && !rules[0].IsInherited &&
        rules[0].IdentityReference.Equals(WindowsIdentity.GetCurrent().User) &&
        rules[0].FileSystemRights == FileSystemRights.FullControl && rules[0].AccessControlType == AccessControlType.Allow;
}
try
{
    var manager = new ManagedKeys(new WindowsManagedKeyAccess());
    var path = manager.Prepare(SafePath.Resolve(root, "generated"), "");
    Check(File.Exists(path + ".pub") && Protected(path), "generated key is incomplete or readable by other accounts");
    var bytes = File.ReadAllBytes(path); var publicBytes = File.ReadAllBytes(path + ".pub");
    var acl = new FileInfo(path).GetAccessControl(); var owner = acl.GetOwner(typeof(SecurityIdentifier));
    acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.Read, AccessControlType.Allow));
    new FileInfo(path).SetAccessControl(acl);
    Check(!Protected(path), "permission drift fixture was not applied");
    manager.Prepare(Path.GetDirectoryName(path)!, "");
    Check(Protected(path) && Equals(owner, new FileInfo(path).GetAccessControl().GetOwner(typeof(SecurityIdentifier))), "reused key permissions or owner changed incorrectly");
    Check(bytes.SequenceEqual(File.ReadAllBytes(path)) && publicBytes.SequenceEqual(File.ReadAllBytes(path + ".pub")), "reused key was regenerated");

    // The source is outside the app-managed destination and must remain byte-for-byte and ACL-for-ACL intact.
    var source = SafePath.Resolve(root, "provider-key.pem"); File.WriteAllBytes(source, bytes);
    var sourceAcl = new FileInfo(source).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
    var copy = manager.Prepare(SafePath.Resolve(root, "copy"), source);
    Check(Protected(copy) && File.Exists(copy + ".pub"), "copied key was not protected and completed");
    Check(bytes.SequenceEqual(File.ReadAllBytes(source)) && bytes.SequenceEqual(File.ReadAllBytes(copy)), "copy modified key bytes");
    Check(sourceAcl == new FileInfo(source).GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All), "provider source permissions were modified");

    var interrupted = SafePath.Resolve(root, "interrupted");
    var retryManager = new ManagedKeys(new InterruptedKeyAccess());
    try { retryManager.Prepare(interrupted, ""); throw new Exception("ACL failure was hidden"); }
    catch (UnauthorizedAccessException) { assertions++; }
    var partial = SafePath.Resolve(interrupted, "id_vps_management"); var partialBytes = File.ReadAllBytes(partial);
    Check(!File.Exists(partial + ".pub"), "public file was written before failed permission preparation");
    retryManager.Prepare(interrupted, "");
    Check(Protected(partial) && File.Exists(partial + ".pub") && partialBytes.SequenceEqual(File.ReadAllBytes(partial)), "retry replaced the private key or skipped permission repair");
    Console.WriteLine($"PASS: {assertions} actual Windows managed-key and ACL assertions; isolated files only.");
    using var identity = WindowsIdentity.GetCurrent();
    Console.WriteLine("elevated_administrator=" + new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator));
}
finally { SafePath.CheckTree(root); Directory.Delete(root, true); }

internal sealed class InterruptedKeyAccess : IPrivateKeyAccess
{
    private bool first = true;
    public void PrepareManagedCopy(string path)
    {
        if (first) { first = false; throw new UnauthorizedAccessException("synthetic ACL interruption"); }
        new WindowsManagedKeyAccess().PrepareManagedCopy(path);
    }
}
