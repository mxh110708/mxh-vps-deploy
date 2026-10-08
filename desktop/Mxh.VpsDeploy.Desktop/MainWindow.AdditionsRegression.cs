#nullable enable
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private async Task<JsonObject> AdditionsRegression(string output)
    {
        if (!File.Exists(paths.Resolve("qa-ui-review.fixture.json"))) throw new OperationException("功能界面验证必须在合成工作区运行。");
        void Require(bool value, string reason) { if (!value) throw new OperationException(reason); }
        var instances = store.ListInstances().ToArray(); string? createdDirectory = null;
        if (instances.Length == 0)
        {
            var fixture = DeploymentPlans.Create(new JsonObject { ["Provider"] = "Example", ["Instance"] = "UI Additions", ["IPv4"] = "192.0.2.10", ["RealityTarget"] = "example.com" }, ArchiveStore.ReadJson(paths.Resolve("config/versions.json")), paths, false);
            fixture.Put("Import.Status", JsonValue.Create("Completed"));
            createdDirectory = paths.Instance("Example/UI Additions/MXH-VPS-Deploy");
            ArchiveStore.WriteJson(SafePath.Resolve(createdDirectory, "deployment-plan.json"), fixture);
            ArchiveStore.WriteJson(SafePath.Resolve(createdDirectory, "deployment-state.json"), new JsonObject { ["Engine"] = "dotnet-v1", ["CurrentManagementPort"] = fixture.Number("Ports.SshPrimary") });
        }
        var instance = store.ListInstances().First(); selectedInstance = instance.RelativePath;
        var originalScheme = scheme; var originalStep = designerStep; var originalTheme = settings.Text("Appearance", "Dark");
        try
        {
            foreach (var theme in new[] { "Dark", "Light" })
            {
                SetAppearance(theme); SelectPage("instances"); await Task.Delay(90);
                Require(Find<Button>(page).Any(b => b.Content as string == "添加协议"), "已有实例缺少追加协议入口。");
                Require(Find<Button>(page).Count(b => (b.Content as string ?? "").StartsWith("安装")) == 3, "监控和访问缺少三个独立安装入口。");
                await Capture(SafePath.Resolve(output, "additions-" + theme.ToLowerInvariant() + ".png"));
                foreach (var component in new[] { "AnyTlsEntry", "KomariController", "Tunnel" })
                {
                    var form = BuildInstallationDialog(instance.Plan, instance.RelativePath, component);
                    var pending = ShowDialog(form.Dialog);
                    try
                    {
                        await Task.Delay(180); shell.UpdateLayout();
                        Require(form.Options.Text("Component") == component && Find<TextBlock>(form.Dialog).Any(t => t.Text.StartsWith("沿用管理连接")), "安装表单缺少固定实例连接信息。");
                        if (component == "AnyTlsEntry") Require(form.Options.Number("Settings.AnyTlsPort") == 8443 && !Find<PasswordBox>(form.Dialog).Any(), "追加 AnyTLS 默认端口冲突或把凭据混入表单。");
                        var frame = Find<Border>(form.Dialog).Where(b => b.ActualWidth >= 250 && b.ActualWidth < shell.ActualWidth - 40 && b.ActualHeight > 100).OrderByDescending(b => b.ActualWidth * b.ActualHeight).First();
                        await Capture(SafePath.Resolve(output, "installation-" + component + "-" + theme.ToLowerInvariant() + ".png"), frame);
                    }
                    finally { form.Dialog.Hide(); await pending; }
                }
                var request = new OperationRequest(OperationKind.Deploy, instance.RelativePath, new JsonObject { ["Plan"] = instance.Plan.DeepClone() });
                SelectPage("deploy"); ShowExecution(request);
                Require(currentPage == "deploy" && !navigation.Keys.Any(key => key.Contains("progress")), "部署进度变成独立导航页面。");
                await RunBackground("合成部署执行", async token =>
                {
                    var planned = OperationSteps.Create(request, instance.Plan);
                    foreach (var step in planned.Take(3)) ExecutionProgress(new("fixture", step.Id, 0, planned.Count, "示例步骤完成", step.Id, TaskStepState.Completed));
                    ExecutionProgress(new("fixture", planned[3].Id, 3, planned.Count, "正在建立管理连接，等待远端返回。", planned[3].Id, TaskStepState.Running));
                    Require(pageHost.IsEnabled && navigation.Values.All(b => !b.IsEnabled) && executionRows.Values.Count(row => row.State == TaskStepState.Completed) == 3 && executionRows.Values.Count(row => row.State == TaskStepState.Running) == 1 && executionRows.Values.Any(row => row.State == TaskStepState.Waiting), "步骤状态或运行期间滚动不可用。");
                    await Task.Delay(140); shell.UpdateLayout(); await Capture(SafePath.Resolve(output, "execution-" + theme.ToLowerInvariant() + ".png"));
                    ExecutionProgress(new("fixture", planned[3].Id, 3, planned.Count, "示例：连接被拒绝，检查 SSH 端口。", planned[3].Id, TaskStepState.Failed));
                    FinishExecution(new("fixture", OperationKind.Deploy, executionStarted, DateTimeOffset.UtcNow, TaskOutcome.Failed, planned[3].Id, "示例：连接被拒绝，检查 SSH 端口。", InstanceRelativePath: instance.RelativePath));
                    Require(executionRows.Values.Count(row => row.State == TaskStepState.Completed) == 3 && executionRows.Values.Count(row => row.State == TaskStepState.Failed) == 1, "失败把待完成步骤改成完成。");
                });
                RefreshTaskResultPage(); Require(ShowingExecution && Find<Button>(page).Any(b => b.Content as string == "返回实例"), "执行结果未保留。");
                SelectPage("clients"); scheme = ClientSchemes.New(paths); designerStep = 1;
                foreach (var name in new[] { "入口 A", "入口 B", "入口 C" }) scheme["Nodes"]!.AsArray().Add(new JsonObject { ["name"] = name, ["kind"] = "entry", ["region_group"] = "US-West Entry" });
                Navigate("clients"); await Task.Delay(120);
                Require(Find<Button>(page).Count(b => (b.Tag as string ?? "").StartsWith("NodeDragHandle.") && b.CanDrag) == 3, "节点拖动手柄未接上。");
                Require(ClientSchemes.MoveNode(scheme, 2, 0), "节点重排失败"); Navigate("clients");
                Require(scheme["Nodes"]!.AsArray()[0]!.Text("name") == "入口 C", "重排顺序没有保存到方案。");
                await Capture(SafePath.Resolve(output, "node-order-" + theme.ToLowerInvariant() + ".png"));
                designerStep = 3; Navigate("clients");
                Require(!((Button)pageAction.Content).IsEnabled && Find<TextBlock>(page).Any(t => t.Tag as string == "ExportPrerequisiteHint" && t.Text.Contains("生成配置")), "未生成时缺少导出指引。");
                scheme["Candidate"] = new JsonObject { ["ValidationStatus"] = "Failed", ["ValidationError"] = "示例：所选核心未通过配置检查。" }; Navigate("clients");
                Require(Find<TextBlock>(page).Single(t => t.Tag as string == "ExportPrerequisiteHint").Text.Contains("校验未通过"), "未显示校验失败原因。");
                scheme["Candidate"]!["ValidationStatus"] = "Passed"; Navigate("clients");
                var fields = Find<TextBox>(page).Where(box => (box.Header as string ?? "").EndsWith("文件")).ToArray();
                Require(fields.Length == 2 && !((Button)pageAction.Content).IsEnabled, "空导出路径没有被提示。");
                fields[0].Text = "C:\\fixture\\example.yaml"; fields[1].Text = "C:\\fixture\\example.json";
                await Task.Delay(140);
                Require(((Button)pageAction.Content).IsEnabled, "填写导出位置后按钮未刷新。");
                await Task.Delay(140); await Capture(SafePath.Resolve(output, "export-guidance-" + theme.ToLowerInvariant() + ".png"));
                scheme = null;
            }
        }
        finally
        {
            scheme = originalScheme; designerStep = originalStep; SetAppearance(originalTheme);
            if (createdDirectory != null) { SafePath.CheckTree(createdDirectory); Directory.Delete(createdDirectory, true); }
            SelectPage("instances");
        }
        return new JsonObject { ["inline_execution"] = true, ["explicit_completion_and_failure"] = true, ["drag_handles_and_scheme_order"] = true, ["generation_validation_export_guidance"] = true, ["separate_component_installation"] = true, ["themes"] = new JsonArray("Dark", "Light"), ["remote_connections"] = 0 };
    }
}
