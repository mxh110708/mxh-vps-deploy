using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Windows;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private UpdateFixtureTransport? updateFixture;
    private string? updateProof;
    private bool updateStarted;
    private bool updateConfirmationClicked;
    private JsonArray? updateNegativeChecks;
    private WindowsUpdates CreateUpdates() => updateFixture == null
        ? new(paths, settings.Text("UpdateProxy"))
        : new(paths, new HttpClient(updateFixture, false) { Timeout = TimeSpan.FromMinutes(8) });

    private async Task InstalledUpdateSmoke()
    {
        var proof = paths.Resolve(".tmp/ui-update-proof.json"); var checks = new JsonArray();
        var timer = DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(100);
        try
        {
            // Only an installer fixture can substitute transport or approve this synthetic update.
            if (!ArchiveStore.ReadJson(paths.Resolve("desktop-runtime.json")).Flag("test_build") || !paths.Root.Equals(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) throw new OperationException("应用内更新验证只能使用隔离 QA 安装包。");
            var directory = paths.Resolve(".tmp/qa-update-fixture"); var baseline = ArchiveStore.ReadJson(SafePath.Resolve(directory, "release.json"));
            async Task Refuses(string name, Action<UpdateFixtureTransport> change, bool prepare)
            {
                using var transport = new UpdateFixtureTransport(directory, baseline.DeepClone().AsObject()); change(transport);
                using var updates = new WindowsUpdates(paths, new HttpClient(transport, false));
                try { var update = await updates.CheckAsync(default); if (prepare) await updates.PrepareAsync(update!, default); }
                catch (OperationException) { checks.Add(name); return; }
                throw new OperationException("更新边界未拒绝：" + name);
            }
            await Refuses("foreign_asset_url", t => t.Release["assets"]!.AsArray()[0]!["browser_download_url"] = "https://example.invalid/installer.exe", false);
            await Refuses("missing_github_digest", t => t.Release["assets"]!.AsArray()[0]!["digest"] = "", false);
            await Refuses("oversized_asset", t => t.Release["assets"]!.AsArray()[0]!["size"] = 300L * 1024 * 1024 + 1, false);
            await Refuses("checksum_tamper", t => t.Corrupt = "SHA256SUMS.txt", true);
            await Refuses("installer_tamper", t => t.Corrupt = Path.GetFileName(t.Release["assets"]!.AsArray()[0]!.Text("browser_download_url")), true);
            await Refuses("download_size_overrun", t => t.Release["assets"]!.AsArray()[0]!["size"] = 1, true);
            if (Directory.EnumerateDirectories(paths.Resolve(".tmp"), "app-update-*").Any()) throw new OperationException("失败的下载暂存未清理。");
            checks.Add("failed_stages_removed");
            using (var transport = new UpdateFixtureTransport(directory, baseline.DeepClone().AsObject()))
            {
                transport.Release["tag_name"] = "v" + ArchiveStore.ReadJson(paths.Resolve("config/application.json")).Text("version");
                using var updates = new WindowsUpdates(paths, new HttpClient(transport, false));
                if (await updates.CheckAsync(default) != null) throw new OperationException("重复版本被视为更新。"); checks.Add("equal_version_ignored");
            }
            updateFixture = new(directory, baseline); updateProof = proof; updateNegativeChecks = checks;
            var confirmed = false;
            timer.Tick += (_, _) =>
            {
                if (confirmed) return;
                var dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(shell.XamlRoot).SelectMany(p => Find<ContentDialog>(p.Child)).FirstOrDefault(d => d.Title as string == "发现更新 " + baseline.Text("tag_name")[1..]);
                if (dialog == null) return;
                var button = Find<Button>(dialog).FirstOrDefault(b => b.Content as string == "确认"); if (button == null) return;
                confirmed = true; updateConfirmationClicked = true; ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            };
            timer.Start(); SelectPage("settings");
            var check = Find<Button>(shell).Single(b => b.Content as string == "检查更新");
            ((IInvokeProvider)new ButtonAutomationPeer(check).GetPattern(PatternInterface.Invoke)).Invoke();
            for (var attempt = 0; attempt < 600 && !updateStarted; attempt++) await Task.Delay(100);
            if (!updateStarted || !confirmed) throw new OperationException("应用内检查更新未完成交接。");
            var result = ArchiveStore.ReadJson(proof); result["negative_checks"] = checks; result["confirmation_clicked"] = confirmed; ArchiveStore.WriteJson(proof, result);
        }
        catch (Exception error)
        {
            ArchiveStore.WriteJson(proof, new JsonObject { ["ui_update_started"] = false, ["error"] = error is OperationException safe ? safe.Message : error.GetType().Name }); Environment.ExitCode = 1; Close();
        }
        finally { timer.Stop(); }
    }
    private void RecordUpdateStart(string stage)
    {
        if (updateProof == null) return;
        var job = ArchiveStore.ReadJson(SafePath.Resolve(stage, "update-job.private.json"));
        ArchiveStore.WriteJson(updateProof, new JsonObject { ["ui_update_started"] = true, ["version"] = job.Text("Version"), ["stage"] = stage, ["launcher_pid_recorded"] = job.Number("LauncherPid") > 0, ["confirmation_clicked"] = updateConfirmationClicked, ["negative_checks"] = updateNegativeChecks?.DeepClone(), ["requests"] = new JsonArray(updateFixture!.Requests.Select(u => (JsonNode?)JsonValue.Create(u)).ToArray()) }); updateStarted = true;
    }
}

internal sealed class UpdateFixtureTransport(string directory, JsonObject release) : HttpMessageHandler
{
    public JsonObject Release { get; } = release;
    public string? Corrupt { get; set; }
    public List<string> Requests { get; } = [];
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); var uri = request.RequestUri!; Requests.Add(uri.AbsoluteUri);
        if (uri.AbsoluteUri == "https://api.github.com/repos/mxh110708/mxh-vps-deploy/releases/latest") return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Release.ToJsonString(), Encoding.UTF8, "application/json") });
        var name = Uri.UnescapeDataString(uri.Segments.Last());
        if (uri.Host != "github.com" || !uri.AbsolutePath.StartsWith("/mxh110708/mxh-vps-deploy/releases/download/", StringComparison.Ordinal)) throw new OperationException("QA 请求超出更新范围。");
        HttpContent content = name == Corrupt ? new ByteArrayContent([1, 2, 3]) : new StreamContent(File.OpenRead(SafePath.Resolve(directory, name)));
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
    }
}
