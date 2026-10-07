using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation;
using Mxh.VpsDeploy.Core;
using Mxh.VpsDeploy.Infrastructure;
using Mxh.VpsDeploy.Windows;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow : Window, IUserInteraction
{
    private readonly AppPaths paths;
    private readonly ArchiveStore store;
    private readonly TaskCoordinator coordinator;
    private readonly ClientWorkbench workbench;
    private readonly Dictionary<string, Button> navigation = new();
    private readonly Grid shell = new();
    private readonly Dictionary<Button, UIElement> disclosures = new();
    private readonly StackPanel page = new() { Spacing = 20, MaxWidth = 1120, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly UserControl pageHost = new();
    private readonly UserControl pageAction = new();
    private readonly TextBlock heading = new() { FontSize = 27, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly TextBlock caption = new() { FontSize = 13, Foreground = Brush(Paint.Muted), TextWrapping = TextWrapping.Wrap };
    private readonly InlineNotice notice = new();
    private readonly TextBlock taskText = new() { Text = "就绪", FontSize = 13, Foreground = Brush(Paint.Muted), TextWrapping = TextWrapping.Wrap };
    private readonly Border taskProgress = new() { Height = 3, Background = Brush(Paint.Accent), Visibility = Visibility.Collapsed };
    private readonly Button cancel = new() { Content = "取消任务", Visibility = Visibility.Collapsed };
    private readonly SemaphoreSlim dialogs = new(1);
    private readonly JsonObject settings;
    private readonly JsonObject deploymentForm = new() { ["Provider"] = "", ["Instance"] = "", ["NodeName"] = "", ["SshPort"] = 22, ["Role"] = "RealityEntry", ["BandwidthMbps"] = 100, ["ReferenceRttMs"] = 0 };
    private JsonObject? scheme;
    private string? selectedInstance;
    private CancellationTokenSource? taskCancellation;
    private bool closing;
    private string currentPage = "overview";
    private readonly string[] launchArguments;

    public MainWindow(AppPaths paths, string[] arguments)
    {
        this.paths = paths; launchArguments = arguments; store = new(paths, new WindowsSecretProtector());
        var assets = new ValidationAssets(paths, "windows-amd64"); var tools = new ExternalToolRunner();
        coordinator = new(store, new WorkflowEngine(store, new SshSessionFactory(store), new ManagedKeys(new WindowsManagedKeyAccess()), this, new ProtocolValidation(assets, tools)));
        workbench = new(store, tools, assets, paths.Resolve("runtime/python/python.exe"));
        var preference = paths.Resolve("private/desktop-settings.json"); settings = File.Exists(preference) ? ArchiveStore.ReadJson(preference) : new JsonObject { ["AutoCheckUpdates"] = false, ["UpdateProxy"] = "http://127.0.0.1:2080" };
        fonts = new(paths);
        try { SetFont(settings.Text("FontId", "Route")); }
        catch (OperationException) { SetFont("Route"); fontFallback = true; }
        Title = "MXH VPS Deploy"; AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1320, 880)); ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonForegroundColor = ColorHelper.FromArgb(255, 230, 233, 238); AppWindow.TitleBar.ButtonBackgroundColor = ColorHelper.FromArgb(0, 0, 0, 0); AppWindow.TitleBar.ButtonInactiveBackgroundColor = ColorHelper.FromArgb(0, 0, 0, 0);
        Application.Current.Resources["ContentDialogMaxWidth"] = 760d; Application.Current.Resources["ContentDialogMinWidth"] = 400d; Application.Current.Resources["ContentDialogCornerRadius"] = new CornerRadius(12);
        Application.Current.Resources["ContentControlThemeFontFamily"] = InterfaceFont;
        var root = new UserControl { FontFamily = InterfaceFont, FontSize = 14, RequestedTheme = ElementTheme.Dark, Background = Brush(Paint.Canvas), Content = shell }; Content = root;
        shell.Background = Brush(Paint.Canvas); shell.RowDefinitions.Add(new() { Height = new GridLength(40) }); shell.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); shell.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var title = new Grid { Background = Brush(Paint.Title), Margin = new Thickness(20, 0, 145, 0) }; title.Children.Add(new TextBlock { Text = "MXH VPS Deploy", VerticalAlignment = VerticalAlignment.Center, FontSize = 13, Foreground = Brush(Paint.Muted) }); shell.Children.Add(title); SetTitleBar(title);
        var body = new Grid(); body.ColumnDefinitions.Add(new() { Width = new GridLength(220) }); body.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        var sidebar = new StackPanel { Padding = new Thickness(14, 22, 14, 18), Spacing = 5 };
        sidebar.Children.Add(new StackPanel { Margin = new Thickness(12, 0, 0, 26), Spacing = 8, Children = { new TextBlock { Text = "MXH Deploy", FontSize = 26, Foreground = Brush(Paint.SidebarText), FontFamily = new FontFamily("ms-appx:///Fonts/SourceSerif4-600.ttf#Source Serif 4"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }, new TextBlock { Text = "VPS 部署与维护", FontSize = 12, Foreground = Brush(Paint.SidebarMuted) } } });
        foreach (var (id, label, icon) in new[] { ("overview", "概述", Symbol.Home), ("instances", "实例", Symbol.World), ("deploy", "部署", Symbol.Add), ("clients", "客户端", Symbol.Link), ("records", "记录", Symbol.Clock), ("settings", "设置", Symbol.Setting) })
        { var labelText = Text(label, 14); labelText.Foreground = Brush(Paint.SidebarText); var button = new Button { Content = Row(new SymbolIcon(icon) { Width = 18, Height = 18, Foreground = Brush(Paint.SidebarIcon) }, labelText), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(14, 11, 14, 11), Background = Brush(Paint.Sidebar), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(7) }; button.Click += (_, _) => SelectPage(id); navigation[id] = button; sidebar.Children.Add(button); }
        body.Children.Add(new Border { Background = Brush(Paint.Sidebar), BorderBrush = Brush(Paint.SidebarBorder), BorderThickness = new Thickness(0, 0, 1, 0), Child = sidebar });
        pageHost.Content = page;
        var content = new ScrollViewer { Content = new StackPanel { Spacing = 22, Margin = new Thickness(36, 24, 36, 28), Children = { new StackPanel { Spacing = 7, Children = { heading, caption } }, notice, pageHost } }, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; Grid.SetColumn(content, 1); body.Children.Add(content);
        Grid.SetRow(body, 1); shell.Children.Add(body);
        var taskBar = new Grid { Padding = new Thickness(20, 9, 20, 9), Background = Brush(Paint.Footer), ColumnSpacing = 16 };
        taskBar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); taskBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); taskBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        taskBar.Children.Add(new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center, Children = { taskText, taskProgress } }); Grid.SetColumn(pageAction, 1); taskBar.Children.Add(pageAction); Grid.SetColumn(cancel, 2); taskBar.Children.Add(cancel);
        cancel.FontSize = 13; cancel.Padding = new Thickness(16, 8, 16, 8); cancel.CornerRadius = new CornerRadius(6); cancel.Background = Brush(Paint.Button); cancel.BorderBrush = Brush(Paint.ButtonBorder);
        cancel.Click += (_, _) => { taskCancellation?.Cancel(); taskText.Text = "正在等待安全边界；远端步骤完成后再处理取消。"; cancel.IsEnabled = false; };
        Grid.SetRow(taskBar, 2); shell.Children.Add(taskBar);
        AppWindow.Closing += (_, e) => { if (taskCancellation != null) { e.Cancel = true; closing = true; taskCancellation.Cancel(); taskText.Text = "正在安全结束任务，完成后关闭窗口。"; } else SaveDraft(); };
        SetAppearance(settings.Text("Appearance", "Dark"));
        root.Loaded += async (_, _) => { var scale = root.XamlRoot.RasterizationScale; var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea; AppWindow.Resize(new((int)Math.Min(1280 * scale, area.Width - 32 * scale), (int)Math.Min(850 * scale, area.Height - 32 * scale))); SelectPage("overview"); if (fontFallback) Show("所选字体暂时不可用，已使用内置原版字体。可在设置中重新选择或导入。", InfoBarSeverity.Warning); if (arguments.Contains("--verify-installed-update")) { await InstalledUpdateSmoke(); return; } if (arguments.Contains("--ui-smoke") || arguments.Contains("--verify-runtime")) { await UiSmoke(); return; } if (settings.Flag("AutoCheckUpdates")) await CheckUpdates(true); };
    }
    private static SolidColorBrush Brush(Paint role) => DesktopTheme.Brush(role);
    private static TextBlock Text(string value, int size = 14, bool muted = false) => new() { Text = value, FontSize = size, FontFamily = InterfaceFont, TextWrapping = TextWrapping.Wrap, Foreground = Brush(muted ? Paint.Muted : Paint.Text) };
    private static StackPanel Column(params UIElement[] children) { var panel = new StackPanel { Spacing = 14 }; foreach (var child in children) panel.Children.Add(child); return panel; }
    private static Border Card(UIElement content) => new() { Background = Brush(Paint.Surface), BorderBrush = Brush(Paint.Border), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(22), Child = content };
    private Button Action(string title, Func<Task> handler, bool accent = false)
    {
        var button = new Button { Content = title, MinHeight = 36, FontSize = 13, Padding = new Thickness(16, 8, 16, 8), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), BorderBrush = Brush(accent ? Paint.Accent : Paint.ButtonBorder), Background = Brush(accent ? Paint.Accent : Paint.Button), Foreground = Brush(accent ? Paint.AccentText : Paint.Text) }; AutomationProperties.SetName(button, title);
        button.Click += async (_, _) => { try { if (taskCancellation != null) throw new OperationException("已有任务运行，请等待结束。"); await handler(); } catch (OperationCanceledException) { Show("已取消。"); } catch (Exception error) { Show(error is OperationException safe ? safe.Message : "操作未完成，请检查输入与当前任务。", InfoBarSeverity.Error); } }; return button;
    }
    private static StackPanel Row(params UIElement[] children) { var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center }; foreach (var child in children) panel.Children.Add(child); return panel; }
    private static Grid Fields(params FrameworkElement[] children)
    {
        var grid = new Grid { ColumnSpacing = 20, RowSpacing = 16 }; grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new());
        foreach (var child in children) grid.Children.Add(child);
        var columns = 0;
        void Arrange(int count) { if (columns == count) return; columns = count; grid.RowDefinitions.Clear(); grid.ColumnDefinitions[1].Width = count == 2 ? new GridLength(1, GridUnitType.Star) : new GridLength(0); for (var i = 0; i < children.Length; i++) { if (i % count == 0) grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); Grid.SetColumn(children[i], i % count); Grid.SetRow(children[i], i / count); } }
        Arrange(2); grid.SizeChanged += (_, _) => Arrange(grid.ActualWidth < 560 ? 1 : 2); return grid;
    }
    private CheckBox Flag(string label, JsonObject model, string key)
    {
        var box = new CheckBox { Content = label, IsChecked = model.Flag(key) }; box.Checked += (_, _) => model[key] = true; box.Unchecked += (_, _) => model[key] = false; return box;
    }
    private UIElement Details(string label, UIElement content)
    {
        content.Visibility = Visibility.Collapsed;
        var arrow = new TextBlock { Text = "\uE70D", FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 11, Foreground = Brush(Paint.Icon), VerticalAlignment = VerticalAlignment.Center };
        var button = Action(label, () => { var open = content.Visibility != Visibility.Visible; content.Visibility = open ? Visibility.Visible : Visibility.Collapsed; arrow.Text = open ? "\uE70E" : "\uE70D"; return Task.CompletedTask; });
        button.Content = Trailing(Text(label, 13), arrow); button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Padding = new Thickness(16, 12, 16, 12); button.Background = Brush(Paint.Surface);
        if (launchArguments.Contains("--review-screenshots")) disclosures[button] = content; return new StackPanel { Spacing = 14, Children = { button, content } };
    }
    private void Show(string message, InfoBarSeverity severity = InfoBarSeverity.Informational) { notice.Message = message; notice.Severity = severity; notice.IsOpen = true; }
    private void Navigate(string id)
    {
        currentPage = id; page.Children.Clear(); disclosures.Clear(); pageAction.Content = null; notice.IsOpen = false; heading.Text = id switch { "overview" => "概述", "instances" => "实例", "deploy" => "部署", "clients" => "客户端", "records" => "任务记录", _ => "设置" }; caption.Text = id switch { "overview" => "集中管理你的 VPS 与客户端配置。", "instances" => "选择实例，查看归档并进行维护。", "deploy" => "配置实例，审阅计划，然后执行。", "clients" => "编辑节点与连接关系，校验后发布。", "records" => "查看任务结果和需要处理的恢复记录。", _ => "应用更新、连接设置与私人数据。" };
        try { switch (id) { case "overview": Overview(); break; case "instances": Instances(); break; case "deploy": Deployment(); break; case "clients": Clients(); break; case "records": Records(); break; default: Settings(); break; } } catch (Exception error) { Show(error is OperationException safe ? safe.Message : "本地记录暂时无法读取，请核对数据目录。", InfoBarSeverity.Error); }
        if (Content is DependencyObject root) ApplyFont(root);
    }
    private void SelectPage(string id)
    {
        if (taskCancellation != null) return;
        foreach (var pair in navigation)
        {
            var active = pair.Key == id; pair.Value.Background = Brush(active ? Paint.SidebarSelected : Paint.Sidebar);
            if (pair.Value.Content is StackPanel items) { ((SymbolIcon)items.Children[0]).Foreground = Brush(active ? Paint.SidebarSelectedIcon : Paint.SidebarIcon); var label = (TextBlock)items.Children[1]; label.Foreground = Brush(active ? Paint.SidebarSelectedText : Paint.SidebarText); label.FontWeight = active ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal; }
        }
        Navigate(id);
    }
    private void Overview()
    {
        var grid = new Grid { ColumnSpacing = 16 }; grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new());
        grid.Children.Add(Card(Column(Row(new SymbolIcon(Symbol.World) { Foreground = Brush(Paint.Accent) }, Text("受管实例", 15)), Row(Text(store.ListInstances().Count().ToString(), 32), Text("个实例", 12, true)), Action("查看实例", () => { SelectPage("instances"); return Task.CompletedTask; }))));
        var right = Card(Column(Row(new SymbolIcon(Symbol.Link) { Foreground = Brush(Paint.Accent) }, Text("客户端方案", 15)), Row(Text(workbench.List().Count().ToString(), 32), Text("个方案", 12, true)), Action("打开工作台", () => { SelectPage("clients"); return Task.CompletedTask; }))); Grid.SetColumn(right, 1); grid.Children.Add(right); page.Children.Add(grid);
        page.Children.Add(Card(Trailing(Column(Text("开始新的部署", 18), Text("部署新的 VPS，或接入已经配置好的实例。", 13, true)), Row(Action("新建部署", () => { deploymentForm["Existing"] = false; SelectPage("deploy"); return Task.CompletedTask; }, true), Action("接入已有 VPS", () => { deploymentForm["Existing"] = true; SelectPage("deploy"); return Task.CompletedTask; })) )));
        var file = paths.Resolve("private/task-history.dotnet.json"); var last = File.Exists(file) ? JsonNode.Parse(File.ReadAllText(file))!.AsArray().LastOrDefault() : null;
        page.Children.Add(Card(Column(Text("最近任务", 18), Text(last == null ? "暂时还没有任务记录" : OutcomeLabel((TaskOutcome)last.Number("Outcome")), 14, last == null), Text(last == null ? "完成部署、维护或客户端发布后，可在记录页查看结果。" : last.Text("Stage"), 13, true), Action("查看记录", () => { SelectPage("records"); return Task.CompletedTask; }))));
    }
    private void Instances()
    {
        var instances = store.ListInstances().ToArray(); if (instances.Length == 0) { page.Children.Add(Card(Column(Text("还没有受管实例", 22), Text("从部署页创建，或接入已有 VPS。", 14, true), Action("开始", () => { SelectPage("deploy"); return Task.CompletedTask; }, true)))); return; }
        var selection = new JsonObject(); var picker = Choice("选择实例", selection, "Instance", instances.Select(instance => (instance.RelativePath, instance.Plan.Text("Provider") + " / " + instance.Plan.Text("Instance"))));
        var details = new StackPanel { Spacing = 20 }; page.Children.Add(picker); page.Children.Add(details);
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedItem is not ComboBoxItem item) return;
            selectedInstance = (string)item.Tag; details.Children.Clear(); var plan = instances.First(x => x.RelativePath == selectedInstance).Plan;
            details.Children.Add(Card(Column(SectionHeading(plan.Text("NodeName"), Symbol.World, RoleLabel(plan.Text("Role"))), Text(plan.Text("Server.IPv4") + (plan.Text("Server.IPv6") == "" ? "" : " / " + plan.Text("Server.IPv6")), 14, true), Text("本地归档 · 运行状态需通过健康检查确认", 12, true))));
            details.Children.Add(GroupLabel("日常维护"));
            details.Children.Add(SettingsGroup(
                SettingRow("健康检查", "读取服务、监听与管理入口的当前状态", Symbol.Sync, Action("检查", () => Submit(new(OperationKind.HealthAudit, selectedInstance, new())))),
                SettingRow("协议与组件", "管理入口协议，或升级受管组件", Symbol.Setting, Row(Action("协议管理", () => OperationSheet(OperationKind.ProtocolState, plan)), Action("组件升级", () => OperationSheet(OperationKind.Upgrade, plan)))),
                SettingRow("凭据与网络", "轮换协议凭据，调整实例网络参数", Symbol.Permissions, Row(Action("凭据轮换", () => OperationSheet(OperationKind.RotateCredentials, plan)), Action("网络参数", () => OperationSheet(OperationKind.TuneNetwork, plan)))),
                SettingRow("监控管理", "管理 Komari Agent、主控与 Tunnel", Symbol.View, Action("管理", () => OperationSheet(OperationKind.Komari, plan)))));
            details.Children.Add(Details("恢复与后续操作", SettingsGroup(
                SettingRow("未完成任务", "核对事务状态，再选择恢复操作", Symbol.Sync, Action("核对", () => Submit(new(OperationKind.Recover, selectedInstance, new())))),
                SettingRow("备份与部署", "从协议备份恢复，或继续已有部署", Symbol.Library, Row(Action("从备份恢复", () => OperationSheet(OperationKind.Restore, plan)), Action("继续部署", () => Submit(new(OperationKind.Resume, selectedInstance, new()))))),
                SettingRow("实例退役", "停用或移除受管协议与 Agent", Symbol.Delete, Action("审阅退役", () => OperationSheet(OperationKind.Decommission, plan))))));
        };
        var selectionIndex = Math.Max(0, Array.FindIndex(instances, x => x.RelativePath == selectedInstance)); if (picker.SelectedIndex == selectionIndex) picker.SelectedIndex = -1; picker.SelectedIndex = selectionIndex;
    }
    private static string RoleLabel(string role) => role switch { "RealityEntry" => "Reality 入口", "AnyTlsEntry" => "AnyTLS / ECH 入口", "ShadowsocksLanding" => "Shadowsocks 落地", _ => "监控或基础维护" };
    private TextBox Field(string label, JsonObject model, string key, string defaultValue = "", bool numeric = false)
    {
        var box = new TextBox { Header = label, Text = model.Text(key, defaultValue), HorizontalAlignment = HorizontalAlignment.Stretch, MinWidth = 180, FontSize = 13, MinHeight = 38, Padding = new Thickness(12, 9, 12, 9), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), BorderBrush = Brush(Paint.InputBorder), Background = Brush(Paint.Input), Foreground = Brush(Paint.Text) }; AutomationProperties.SetName(box, label);
        box.TextChanged += (_, _) => { model[key] = numeric && int.TryParse(box.Text, out var number) ? JsonValue.Create(number) : JsonValue.Create(box.Text.Trim()); }; return box;
    }
    private UIElement FileField(string label, JsonObject model, string key, bool save = false)
    {
        var grid = new Grid { ColumnSpacing = 10 }; grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); var field = Field(label, model, key); grid.Children.Add(field);
        var browse = Action("浏览", async () => { var result = await PickFile(save, key.Contains("Clash") ? ".yaml" : ".json"); if (result != null) field.Text = result; }); browse.VerticalAlignment = VerticalAlignment.Bottom; Grid.SetColumn(browse, 1); grid.Children.Add(browse); return grid;
    }
    private async Task<string?> PickFile(bool save, string extension)
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker(); picker.FileTypeFilter.Add(save ? extension : "*"); if (save && extension == ".yaml") picker.FileTypeFilter.Add(".yml"); WinRT.Interop.InitializeWithWindow.Initialize(picker, handle); return (await picker.PickSingleFileAsync())?.Path;
    }
    private void Deployment()
    {
        var existing = deploymentForm.Flag("Existing");
        var mode = Row(Action("部署新 VPS", () => { deploymentForm["Existing"] = false; Navigate("deploy"); return Task.CompletedTask; }, !existing), Action("接入已有 VPS", () => { deploymentForm["Existing"] = true; Navigate("deploy"); return Task.CompletedTask; }, existing));
        page.Children.Add(mode);
        page.Children.Add(Card(Column(
            SectionHeading("连接信息", Symbol.World, existing ? "读取已有配置，并建立本地受管归档。" : "填写实例信息，执行时再输入连接凭据。"),
            Fields(Field("服务商", deploymentForm, "Provider"), Field("实例名称", deploymentForm, "Instance"),
                Field("节点名称", deploymentForm, "NodeName"), Field("当前 root SSH 端口", deploymentForm, "SshPort", "22", true),
                Field("IPv4", deploymentForm, "IPv4"), Field("IPv6（可选）", deploymentForm, "IPv6")),
            FileField("SSH 私钥（可选，留空使用密码）", deploymentForm, "KeyPath"))));
        if (!existing)
        {
            var role = Choice("实例用途", deploymentForm, "Role", DeploymentPlans.Roles.Select(value => (value, RoleLabel(value))));
            role.SelectionChanged += (_, _) => Navigate("deploy");
            var purpose = deploymentForm.Text("Role", "RealityEntry");
            var purposeFields = new StackPanel { Spacing = 16 }; purposeFields.Children.Add(role);
            if (purpose == "RealityEntry")
            {
                purposeFields.Children.Add(Field("目标域名 / SNI", deploymentForm, "RealityTarget"));
                purposeFields.Children.Add(Details("端口与证书设置", Column(
                    Fields(Field("主入口端口", deploymentForm, "RealityPort", "443", true), Field("备用端口（空为自动，0 为关闭）", deploymentForm, "RealityBackupPort", numeric: true)),
                    Flag("使用自己的域名与本机 HTTPS 目标", deploymentForm, "LocalTarget"),
                    Fields(Field("Cloudflare 区域", deploymentForm, "ZoneName"), Field("证书联系邮件", deploymentForm, "CertbotEmail")),
                    FileField("证书 Token 私人文件", deploymentForm, "CloudflareTokenFile"))));
            }
            if (purpose == "AnyTlsEntry")
                purposeFields.Children.Add(Column(Fields(Field("服务器名称", deploymentForm, "AnyTlsName"), Field("ECH public name", deploymentForm, "EchPublicName"),
                    Field("Cloudflare 区域", deploymentForm, "ZoneName"), Field("证书联系邮件", deploymentForm, "CertbotEmail")), FileField("证书 Token 私人文件", deploymentForm, "CloudflareTokenFile")));
            if (purpose == "ShadowsocksLanding")
                purposeFields.Children.Add(Column(Field("可信入口地址（逗号分隔）", deploymentForm, "TrustedEntries"),
                    Fields(Field("落地 TCP / UDP 端口", deploymentForm, "LandingPort", "45001", true), Field("入口组", deploymentForm, "TransitGroup", "US-West Entry")),
                    Details("IPv6 专用出口用户", Column(Flag("启用第二用户", deploymentForm, "SecondaryIpv6Enabled"), Fields(Field("IPv6 源地址", deploymentForm, "SecondaryIpv6Address"), Field("绑定网卡（可选）", deploymentForm, "SecondaryBindInterface"))))));
            page.Children.Add(Card(Column(SectionHeading("用途配置", Symbol.Setting), purposeFields)));
            page.Children.Add(Card(Column(SectionHeading("网络参数", Symbol.Globe),
                Fields(Field("套餐标称带宽（Mbps）", deploymentForm, "BandwidthMbps", "100", true), Field("参考 RTT（ms，可选）", deploymentForm, "ReferenceRttMs", "0", true)), Text("用于保守调优，不运行公网测速。", 12, true))));
            page.Children.Add(Details("可选监控 Agent", Card(Column(Flag("启用 Komari Agent", deploymentForm, "KomariEnabled"), Field("主控地址", deploymentForm, "KomariEndpoint"), Text("Token 在执行时单独输入。", 12, true)))));
        }
        else page.Children.Add(Card(Column(SectionHeading("归档信息", Symbol.Library), Field("套餐标称带宽（Mbps）", deploymentForm, "BandwidthMbps", "100", true), Text("连接后读取远端实际配置，生成应用内的实例归档。", 12, true))));
        var review = Action("审阅计划", async () => { var plan = DeploymentPlans.Create(deploymentForm, ArchiveStore.ReadJson(paths.Resolve("config/versions.json")), paths, existing); var relative = plan.Text("Provider") + "/" + plan.Text("Instance") + "/MXH-VPS-Deploy"; await Submit(new(existing ? OperationKind.ConnectExisting : OperationKind.Deploy, relative, new JsonObject { ["Plan"] = plan })); }, true);
        page.Children.Add(Text("执行前会确认操作范围与 SSH 主机身份。", 12, true)); pageAction.Content = review;
    }
    private async Task Submit(OperationRequest request)
    {
        if (taskCancellation != null) throw new OperationException("已有任务运行，请等待结束。"); var review = coordinator.Review(request); var plan = request.Options["Plan"] as JsonObject; var detail = review.Summary;
        if (plan != null) detail += "\n\n" + plan.Text("Provider") + " / " + plan.Text("Instance") + "\n" + RoleLabel(plan.Text("Role")) + "\n管理入口：" + plan.Text("Ports.SshPrimary") + " / " + plan.Text("Ports.SshRescue");
        if (!await ConfirmAsync(new("审阅并执行", detail), CancellationToken.None)) return;
        await RunBackground("准备任务", async token => { var progress = new Progress<TaskProgress>(p => taskText.Text = p.Stage + " · " + p.Message); var record = await Task.Run(() => coordinator.ExecuteAsync(review, request, progress, token)); taskText.Text = OutcomeLabel(record.Outcome) + " · " + record.Stage; Show(record.SafeError ?? OutcomeLabel(record.Outcome), record.Outcome is TaskOutcome.Failed or TaskOutcome.NeedsRecovery ? InfoBarSeverity.Error : record.Outcome == TaskOutcome.Completed ? InfoBarSeverity.Success : InfoBarSeverity.Warning); });
    }
    private async Task RunBackground(string label, Func<CancellationToken, Task> action)
    {
        if (taskCancellation != null) throw new OperationException("已有任务运行，请等待结束。");
        taskCancellation = new(); cancel.Visibility = Visibility.Visible; cancel.IsEnabled = true; taskProgress.Visibility = Visibility.Visible; taskText.Text = label; pageHost.IsEnabled = false; pageAction.IsEnabled = false; foreach (var button in navigation.Values) button.IsEnabled = false;
        try { await action(taskCancellation.Token); }
        finally { taskCancellation.Dispose(); taskCancellation = null; pageHost.IsEnabled = true; pageAction.IsEnabled = true; foreach (var button in navigation.Values) button.IsEnabled = true; cancel.Visibility = Visibility.Collapsed; taskProgress.Visibility = Visibility.Collapsed; if (closing) { SaveDraft(); Close(); } }
    }
    private static string OutcomeLabel(TaskOutcome outcome) => outcome switch { TaskOutcome.Completed => "已完成", TaskOutcome.CompletedWithWarnings => "已完成，含未验收项", TaskOutcome.Cancelled => "已取消", TaskOutcome.NeedsRecovery => "待恢复", TaskOutcome.Failed => "失败", _ => "上次任务未确认结束" };
    private void Records()
    {
        var publisher = new CandidatePublisher(paths);
        foreach (var pending in publisher.Pending()) page.Children.Add(Card(Column(Text("客户端发布待恢复", 18), Text("上次双文件发布未确认结束。恢复前会核对两份目标与备份的摘要。", 13, true), Action("核对并恢复", async () => { if (await ConfirmAsync(new("恢复客户端发布", "仅恢复此发布事务原来的两份权威文件；发现外部改动时停止。"), CancellationToken.None)) await RunBackground("恢复客户端发布", token => { token.ThrowIfCancellationRequested(); publisher.Recover(pending); Show("客户端发布已恢复。", InfoBarSeverity.Success); return Task.CompletedTask; }); }))));
        var file = paths.Resolve("private/task-history.dotnet.json"); if (!File.Exists(file)) { page.Children.Add(Text("还没有任务记录。", 16, true)); return; }
        foreach (var item in JsonNode.Parse(File.ReadAllText(file))!.AsArray().Reverse()) { var record = item!.AsObject(); page.Children.Add(Card(Column(Text(OutcomeLabel((TaskOutcome)record.Number("Outcome")), 18), Text(record.Text("StartedAt") + " · " + record.Text("Stage"), 13, true), Text(record.Text("SafeError"), 13, true)))); }
    }
    private void SaveDraft() { if (scheme != null) workbench.Save(scheme); }
    public Task<bool> ConfirmHostAsync(HostIdentity identity, CancellationToken cancellationToken) => ConfirmAsync(new("核对 SSH 主机身份", identity.Host + "\n" + identity.Algorithm + "\n" + identity.Sha256Fingerprint + "\n\n请与服务商控制台或可信记录核对。"), cancellationToken);
    public async Task<bool> ConfirmAsync(UserDecision decision, CancellationToken cancellationToken) => await OnUi(async () =>
    {
        var phrase = new TextBox { Header = decision.RequiredPhrase == null ? "" : "输入 " + decision.RequiredPhrase + " 确认", Visibility = decision.RequiredPhrase == null ? Visibility.Collapsed : Visibility.Visible }; var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = decision.Title, Content = Column(Text(decision.Description), phrase), PrimaryButtonText = "确认", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
        if (decision.RequiredPhrase != null) { dialog.IsPrimaryButtonEnabled = false; phrase.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = phrase.Text == decision.RequiredPhrase; } using var registration = cancellationToken.Register(() => DispatcherQueue.TryEnqueue(dialog.Hide)); return await ShowDialog(dialog) == ContentDialogResult.Primary;
    }, cancellationToken);
    public async Task<string?> SecretAsync(string title, CancellationToken cancellationToken) => await OnUi(async () =>
    {
        var box = SecretField(title); var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "输入凭据", Content = box, PrimaryButtonText = "继续", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close }; using var registration = cancellationToken.Register(() => DispatcherQueue.TryEnqueue(dialog.Hide)); var result = await ShowDialog(dialog); var value = result == ContentDialogResult.Primary ? box.Password : null; box.Password = ""; return value;
    }, cancellationToken);
    private async Task<T> OnUi<T>(Func<Task<T>> action, CancellationToken cancellationToken)
    {
        await dialogs.WaitAsync(cancellationToken); try { var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously); if (!DispatcherQueue.TryEnqueue(async () => { try { completion.SetResult(await action()); } catch (Exception error) { completion.TrySetException(error); } })) throw new OperationCanceledException(); return await completion.Task; } finally { dialogs.Release(); }
    }
}
