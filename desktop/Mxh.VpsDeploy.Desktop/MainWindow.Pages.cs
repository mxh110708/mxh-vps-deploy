using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private ComboBox Choice(string label, JsonObject model, string key, IEnumerable<(string Value, string Label)> choices)
    {
        var box = new ComboBox { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 38, FontSize = 13, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), BorderBrush = Brush(Paint.InputBorder), Background = Brush(Paint.Input), Foreground = Brush(Paint.Text) };
        foreach (var (value, title) in choices) box.Items.Add(new ComboBoxItem { Content = title, Tag = value });
        box.SelectedIndex = Math.Max(0, box.Items.Cast<ComboBoxItem>().ToList().FindIndex(i => (string)i.Tag == model.Text(key)));
        if (box.SelectedItem is ComboBoxItem first) model[key] = (string)first.Tag;
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is ComboBoxItem item) model[key] = (string)item.Tag; }; return box;
    }
    private async Task OperationSheet(OperationKind kind, JsonObject plan)
    {
        var options = new JsonObject { ["Scope"] = kind == OperationKind.TuneNetwork ? "Network" : kind == OperationKind.Decommission ? "ManagedInstance" : "Protocol", ["Protocol"] = plan.Text("Role"), ["BandwidthMbps"] = plan.Number("NetworkTuning.BandwidthMbps"), ["ReferenceRttMs"] = plan.Number("NetworkTuning.ReferenceRttMs") };
        var panel = Column(Text("选择本次操作范围，再审阅执行。", 14, true));
        ComboBox? component = null;
        if (kind is OperationKind.Upgrade or OperationKind.Komari) { component = Choice("组件", options, "Scope", kind == OperationKind.Komari ? [("KomariAgent", "Komari Agent"), ("KomariController", "Komari Controller"), ("Tunnel", "Cloudflare Tunnel")] : [("Protocol", "代理协议"), ("KomariAgent", "Komari Agent"), ("KomariController", "Komari Controller")]); panel.Children.Add(component); }
        if (kind is OperationKind.ProtocolState or OperationKind.RotateCredentials or OperationKind.Upgrade) panel.Children.Add(Choice("协议", options, "Protocol", DeploymentPlans.Roles[..3].Where(role => plan.Flag("ProtocolInventory." + role + ".Installed") || plan.Text("Role") == role).Select(role => (role, RoleLabel(role)))));
        if (kind == OperationKind.ProtocolState) panel.Children.Add(Choice("操作", options, "Action", [("Switch", "切换到此入口"), ("Enable", "启用"), ("Disable", "停用备用"), ("Uninstall", "卸载此协议")]));
        if (kind == OperationKind.Komari)
        {
            var actions = new StackPanel { Spacing = 16 }; panel.Children.Add(actions);
            void RefreshActions()
            {
                actions.Children.Clear(); options.Remove("Action");
                var choice = Choice("操作", options, "Action", options.Text("Scope") switch { "KomariController" => [("Upgrade", "更新主控"), ("Backup", "主控一致性备份"), ("Restore", "恢复主控备份")], "Tunnel" => [("RotateToken", "轮换 Tunnel Token")], _ => [("Upgrade", "更新 Agent"), ("Remove", "卸载 Agent")] }); actions.Children.Add(choice);
                var backups = new StackPanel(); actions.Children.Add(backups);
                void RefreshBackups() { backups.Children.Clear(); if (options.Text("Action") != "Restore") return; var root = SafePath.Resolve(paths.Instance(selectedInstance!), "komari-backups"); if (Directory.Exists(root)) { SafePath.CheckTree(root); backups.Children.Add(Choice("主控恢复点", options, "Backup", Directory.EnumerateFiles(root, "*.json").Select(ArchiveStore.ReadJson).Where(b => !b.Flag("IncludeTunnel")).Select(b => (b.Text("RemoteBackup"), b.Text("At"))))); } }
                choice.SelectionChanged += (_, _) => RefreshBackups(); RefreshBackups();
                if (options.Text("Scope") == "KomariController") actions.Children.Add(Text("一致性备份和升级需要短暂停止主控。操作完成后恢复原运行状态，Tunnel 不在本次范围。", 13, true));
            }
            component!.SelectionChanged += (_, _) => RefreshActions(); RefreshActions();
        }
        if (kind == OperationKind.TuneNetwork) { panel.Children.Add(Field("套餐标称带宽（Mbps）", options, "BandwidthMbps", numeric: true)); panel.Children.Add(Field("参考 RTT（ms，可选）", options, "ReferenceRttMs", numeric: true)); }
        if (kind == OperationKind.Restore)
        {
            var directory = SafePath.Resolve(paths.Instance(selectedInstance!), "maintenance-backups");
            var backups = Directory.Exists(directory) ? Directory.EnumerateFiles(directory, "restore-metadata.json", SearchOption.AllDirectories).Select(ArchiveStore.ReadJson).ToArray() : [];
            panel.Children.Add(Choice("恢复点", options, "Backup", backups.Select(b => (b.Text("RemoteBackup"), b.Text("CreatedAt")))));
            panel.Children.Add(Choice("恢复范围", options, "RestoreMode", [("ConfigOnly", "仅恢复协议配置"), ("Full", "恢复协议程序、文件与服务")])); panel.Children.Add(Text("仅限协议范围；SSH、网络、防火墙和监控保持当前配置。", 13, true));
        }
        if (kind == OperationKind.Decommission) { panel.Children.Add(Choice("退役级别", options, "Action", [("Disable", "停用受管协议与 Agent"), ("RemoveManaged", "卸载受管协议与 Agent")])); panel.Children.Add(Text("保留 SSH 和基础系统；主控与 Tunnel 不包含在此范围。", 13, true)); }
        var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = kind switch { OperationKind.ProtocolState => "协议管理", OperationKind.Upgrade => "组件升级", OperationKind.RotateCredentials => "凭据轮换", OperationKind.TuneNetwork => "网络参数", OperationKind.Komari => "监控管理", OperationKind.Restore => "从备份恢复", _ => "实例退役" }, Content = panel, PrimaryButtonText = "审阅", CloseButtonText = "取消" };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        await Submit(new(kind, selectedInstance!, options));
    }
    private void Clients()
    {
        if (scheme == null)
        {
            page.Children.Add(Card(Trailing(SectionHeading("客户端工作台", Symbol.Link, "在方案中管理节点、连接关系与发布目标。"), Action("创建方案", () => { scheme = ClientSchemes.New(paths); workbench.Save(scheme); Navigate("clients"); return Task.CompletedTask; }, true))));
            var savedSchemes = workbench.List().ToArray();
            if (savedSchemes.Length == 0) page.Children.Add(Card(Column(Text("还没有客户端方案", 18), Text("创建一个方案后，即可添加节点并生成两端配置。", 13, true))));
            else { page.Children.Add(GroupLabel("已保存的方案")); page.Children.Add(SettingsGroup(savedSchemes.Select(saved => (UIElement)SettingRow(saved.Text("Name"), saved["Nodes"]!.AsArray().Count + " 个节点", Symbol.Link, Action("打开", () => { scheme = saved; if (scheme["Candidate"] is JsonObject candidate) { candidate["ValidationStatus"] = "Pending"; candidate["Targets"] = new JsonObject(); workbench.Save(scheme); } Navigate("clients"); return Task.CompletedTask; }))).ToArray())); }
            return;
        }
        var schemeName = Field("方案名称", scheme, "Name"); schemeName.MinWidth = 320; schemeName.MaxWidth = 440; schemeName.HorizontalAlignment = HorizontalAlignment.Left;
        page.Children.Add(Card(Trailing(schemeName, Row(Action("保存方案", () => { workbench.Save(scheme); Show("方案已保存。", InfoBarSeverity.Success); return Task.CompletedTask; }), Action("方案列表", () => { SaveDraft(); scheme = null; Navigate("clients"); return Task.CompletedTask; })))));
        page.Children.Add(Trailing(GroupLabel("节点"), Row(Action("添加受管节点", AddManagedNodes), Action("手动添加", () => EditNode(null)), Action("读取现有配置", ReadClientSources))));
        var nodes = scheme["Nodes"]!.AsArray();
        var nodeRows = new List<UIElement>();
        if (nodes.Count == 0) page.Children.Add(Card(Column(Text("还没有节点", 16), Text("添加受管实例中的节点，或手动填写连接信息。", 12, true))));
        for (var i = 0; i < nodes.Count; i++)
        {
            var index = i; var node = nodes[i]!.AsObject();
            var up = Action("↑", () => { if (index > 0) { var copy = nodes[index]!.DeepClone(); nodes.RemoveAt(index); nodes.Insert(index - 1, copy); DirtyScheme(); } return Task.CompletedTask; }); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(up, "上移节点"); up.IsEnabled = index > 0;
            var down = Action("↓", () => { if (index < nodes.Count - 1) { var copy = nodes[index]!.DeepClone(); nodes.RemoveAt(index); nodes.Insert(index + 1, copy); DirtyScheme(); } return Task.CompletedTask; }); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(down, "下移节点"); down.IsEnabled = index < nodes.Count - 1;
            nodeRows.Add(SettingRow(node.Text("name"), node.Text("kind") == "landing" ? "落地 → " + node.Text("transit_group") : "入口 → " + node.Text("region_group"), Symbol.Link,
                Row(up, down, Action("编辑", () => EditNode(index)), Action("移除", () => { nodes.RemoveAt(index); DirtyScheme(); return Task.CompletedTask; }))));
        }
        if (nodeRows.Count != 0) page.Children.Add(SettingsGroup(nodeRows.ToArray()));
        page.Children.Add(Details("分组与默认出口", SettingsGroup(
            SettingRow("业务默认项", "为业务分组选择默认出口", Symbol.List, Action("编辑", EditBusinessGroups)),
            SettingRow("默认出口顺序", "调整默认出口组的成员顺序", Symbol.Sort, Action("编辑", EditExitOrder)))));
        var validated = scheme.Text("Candidate.ValidationStatus") == "Passed";
        var generate = Action("生成候选", async () => { try { await RunBackground("正在生成候选", async token => await workbench.BuildAsync(scheme!, token)); } finally { Navigate("clients"); } Show("候选已生成。", InfoBarSeverity.Success); }, scheme["Candidate"] == null); generate.IsEnabled = nodes.Count != 0;
        var validate = Action("校验候选", async () => { try { await RunBackground("正在校验候选", async token => await workbench.ValidateAsync(scheme!, token)); } finally { Navigate("clients"); } Show("两端核心校验通过。", InfoBarSeverity.Success); }, scheme["Candidate"] != null && !validated); validate.IsEnabled = scheme["Candidate"] != null;
        var publish = Action("审阅并发布", PublishClients, validated); publish.IsEnabled = validated;
        page.Children.Add(Card(Column(SectionHeading("配置发布", Symbol.Upload, validated ? "两端核心已通过校验，可以审阅发布。" : "先生成候选，再校验两端配置。"),
            Row(generate, validate), Details("发布目标", Column(FileField("Clash 权威文件", scheme["Targets"]!.AsObject(), "Clash", true), FileField("sing-box 权威文件", scheme["Targets"]!.AsObject(), "SingBox", true))))));
        pageAction.Content = publish;
    }
    private void DirtyScheme() { scheme!.Remove("Candidate"); workbench.Save(scheme); Navigate("clients"); }
    private async Task AddManagedNodes()
    {
        var all = new List<(ClientProfiles.NodePair Node, JsonObject Plan, string Relative)>();
        foreach (var instance in store.ListInstances())
        {
            var secretFile = SafePath.Resolve(paths.Instance(instance.RelativePath), "secrets.dotnet.private.json"); if (!File.Exists(secretFile)) continue;
            var secrets = store.ReadSecret(secretFile); all.AddRange(ClientProfiles.Nodes(instance.Plan, secrets).Select(n => (n, instance.Plan, instance.RelativePath))); secrets.Clear();
        }
        var panel = new StackPanel { Spacing = 8 }; var selections = new List<(CheckBox Check, ClientProfiles.NodePair Node, JsonObject Plan, string Relative)>();
        foreach (var item in all) { var check = new CheckBox { Content = item.Node.Name }; panel.Children.Add(check); selections.Add((check, item.Node, item.Plan, item.Relative)); }
        if (all.Count == 0) panel.Children.Add(Text("没有可用的受管节点。"));
        var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "选择节点", Content = new ScrollViewer { Content = panel, MaxHeight = 420 }, PrimaryButtonText = "添加", CloseButtonText = "取消" };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        scheme!["Sources"] ??= new JsonObject();
        foreach (var item in selections.Where(s => s.Check.IsChecked == true))
        {
            var node = new JsonObject { ["name"] = item.Node.Name, ["kind"] = item.Node.Role == "ShadowsocksLanding" ? "landing" : "entry", ["region_group"] = "US-West Entry", ["transit_group"] = item.Plan.Text("Shadowsocks.ClientTransitTag", "US-West Entry"), ["clash"] = item.Node.Clash.DeepClone(), ["sing_box"] = item.Node.SingBox.DeepClone() }; scheme["Nodes"]!.AsArray().Add(node);
            foreach (var name in new[] { "deployment-plan.json", "secrets.dotnet.private.json" }) { var file = SafePath.Resolve(paths.Instance(item.Relative), name); scheme["Sources"]![file] = ClientSchemes.SourceFingerprint(file); }
        }
        DirtyScheme();
    }
    private async Task ReadClientSources()
    {
        var sources = new JsonObject { ["Clash"] = "", ["SingBox"] = "" }; var panel = Column(FileField("Clash 来源", sources, "Clash"), FileField("sing-box 来源", sources, "SingBox"));
        var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "读取现有配置", Content = panel, PrimaryButtonText = "读取", CloseButtonText = "取消" };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) return;
        JsonArray nodes = new(); await RunBackground("读取来源配置", async token => nodes = await workbench.ReadSourcesAsync(sources.Text("Clash"), sources.Text("SingBox"), token));
        scheme!["Clash"] = sources.Text("Clash"); scheme["SingBox"] = sources.Text("SingBox"); scheme["SourceMode"] = "ExistingAuthority";
        foreach (var node in nodes) { var copy = node!.DeepClone(); copy["region_group"] = "US-West Entry"; copy["transit_group"] = "US-West Entry"; scheme["Nodes"]!.AsArray().Add(copy); }
        DirtyScheme();
    }
    private async Task EditNode(int? index)
    {
        var activeScheme = scheme ?? throw new OperationException("请先选择方案。");
        var existing = index.HasValue ? activeScheme["Nodes"]!.AsArray()[index.Value]!.AsObject() : null;
        var model = new JsonObject { ["Name"] = existing?.Text("name") ?? "", ["Role"] = existing?.Text("clash.type") switch { "ss" => "ShadowsocksLanding", "anytls" => "AnyTlsEntry", _ => "RealityEntry" }, ["Address"] = existing?.Text("clash.server") ?? "", ["Port"] = existing?.Number("clash.port") ?? 443, ["Region"] = existing?.Text("region_group", "US-West Entry") ?? "US-West Entry", ["Transit"] = existing?.Text("transit_group", "US-West Entry") ?? "US-West Entry", ["Sni"] = existing?.Text("clash.servername", existing.Text("clash.sni")) ?? "", ["Uuid"] = existing?.Text("clash.uuid") ?? "", ["PublicKey"] = existing?.Text("clash.reality-opts.public-key") ?? "", ["ShortId"] = existing?.Text("clash.reality-opts.short-id") ?? "", ["Ech"] = existing?.Text("clash.ech-opts.config") ?? "", ["Method"] = existing?.Text("clash.cipher", "2022-blake3-aes-128-gcm") ?? "2022-blake3-aes-128-gcm" };
        var password = SecretField("密码 / SS2022 组合密钥", existing?.Text("clash.password") ?? "");
        var uuid = SecretField("UUID", model.Text("Uuid"));
        var role = Choice("协议", model, "Role", DeploymentPlans.Roles[..3].Select(value => (value, RoleLabel(value)))); if (existing != null) role.IsEnabled = false;
        var specifics = new StackPanel { Spacing = 16 }; var panel = Column(Fields(Field("节点名称", model, "Name"), role, Field("服务器地址", model, "Address"), Field("端口", model, "Port", numeric: true)), specifics); panel.MinWidth = 600;
        void Refresh()
        {
            specifics.Children.Clear();
            if (model.Text("Role") == "ShadowsocksLanding") { specifics.Children.Add(Fields(Choice("连接的入口组", model, "Transit", activeScheme["Layout"]!.Strings("region_groups").Select(r => (r, r))), Field("Shadowsocks 方法", model, "Method"))); specifics.Children.Add(password); }
            else { specifics.Children.Add(Fields(Choice("入口地区", model, "Region", activeScheme["Layout"]!.Strings("region_groups").Select(r => (r, r))), Field("SNI", model, "Sni"))); if (model.Text("Role") == "RealityEntry") { specifics.Children.Add(uuid); specifics.Children.Add(Fields(Field("Reality 公钥", model, "PublicKey"), Field("short-id", model, "ShortId"))); } else { specifics.Children.Add(password); specifics.Children.Add(Field("ECH 客户端配置", model, "Ech")); } }
        }
        role.SelectionChanged += (_, _) => Refresh(); Refresh();
        var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = existing == null ? "添加节点" : "编辑节点", Content = new ScrollViewer { Content = panel, MaxHeight = 500 }, PrimaryButtonText = "保存", CloseButtonText = "取消" };
        if (await ShowDialog(dialog) != ContentDialogResult.Primary) { password.Password = ""; uuid.Password = ""; return; }
        model["Uuid"] = uuid.Password.Trim(); uuid.Password = "";
        var fakePlan = new JsonObject { ["NodeName"] = model.Text("Name"), ["Role"] = model.Text("Role"), ["Server"] = new JsonObject { ["IPv4"] = model.Text("Address"), ["IPv6"] = "" }, ["Ports"] = new JsonObject { ["XrayPrimary"] = model.Number("Port"), ["AnyTlsPrimary"] = model.Number("Port"), ["LandingShadowsocks"] = model.Number("Port") }, ["Reality"] = new JsonObject { ["ServerName"] = model.Text("Sni") }, ["AnyTls"] = new JsonObject { ["ServerName"] = model.Text("Sni") }, ["Shadowsocks"] = new JsonObject { ["Method"] = model.Text("Method") } };
        var fakeSecrets = new JsonObject { ["Xray"] = new JsonObject { ["Uuid"] = model.Text("Uuid"), ["RealityClientKey"] = model.Text("PublicKey"), ["ShortId"] = model.Text("ShortId") }, ["AnyTls"] = new JsonObject { ["Password"] = password.Password, ["EchClientConfigPem"] = "-----BEGIN ECH CONFIGS-----\n" + model.Text("Ech") + "\n-----END ECH CONFIGS-----\n" }, ["Shadowsocks"] = new JsonObject { ["ServerKey"] = password.Password.Split(':')[0], ["PrimaryUserKey"] = password.Password.Contains(':') ? password.Password[(password.Password.IndexOf(':') + 1)..] : "" } };
        var pair = ClientProfiles.Nodes(fakePlan, fakeSecrets).First();
        pair.Clash["name"] = model.Text("Name"); pair.SingBox["tag"] = model.Text("Name");
        // Preserve legitimate advanced node settings when editing the fields exposed by this form.
        var clash = existing?["clash"]?.DeepClone().AsObject() ?? pair.Clash.DeepClone().AsObject(); var sing = existing?["sing_box"]?.DeepClone().AsObject() ?? pair.SingBox.DeepClone().AsObject();
        if (existing != null)
        {
            foreach (var field in new[] { "name", "server", "port", "uuid", "servername", "sni", "password", "cipher", "reality-opts.public-key", "reality-opts.short-id", "ech-opts.config" }) if (pair.Clash.At(field) is JsonNode value) clash.Put(field, value.DeepClone());
            foreach (var field in new[] { "tag", "server", "server_port", "uuid", "password", "method", "tls.server_name", "tls.reality.public_key", "tls.reality.short_id", "tls.ech.config" }) if (pair.SingBox.At(field) is JsonNode value) sing.Put(field, value.DeepClone());
        }
        var node = new JsonObject { ["name"] = model.Text("Name"), ["kind"] = model.Text("Role") == "ShadowsocksLanding" ? "landing" : "entry", ["region_group"] = model.Text("Region"), ["transit_group"] = model.Text("Transit"), ["clash"] = clash, ["sing_box"] = sing };
        if (index.HasValue) activeScheme["Nodes"]!.AsArray()[index.Value] = node; else activeScheme["Nodes"]!.AsArray().Add(node); password.Password = ""; fakeSecrets.Clear(); DirtyScheme();
    }
    private async Task EditBusinessGroups()
    {
        var definitions = scheme!["Layout"]!["business_groups"]!.DeepClone().AsArray(); var panel = new StackPanel { Spacing = 14 }; var choices = new[] { scheme.Text("Layout.default_exit_group"), scheme.Text("Layout.direct_group") }.Concat(scheme["Layout"]!.Strings("region_groups")).Concat(scheme["Nodes"]!.AsArray().Where(n => n!.Text("kind") == "landing").Select(n => n!.Text("name"))).ToArray();
        foreach (var definition in definitions.OfType<JsonObject>()) panel.Children.Add(Choice(definition.Text("name"), definition, "default", choices.Select(c => (c, c))));
        var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "业务默认出口", Content = new ScrollViewer { Content = panel, MaxHeight = 480 }, PrimaryButtonText = "保存", CloseButtonText = "取消" };
        if (await ShowDialog(dialog) == ContentDialogResult.Primary) { scheme["Layout"]!["business_groups"] = definitions; DirtyScheme(); }
    }
    private async Task EditExitOrder()
    {
        var members = scheme!["Layout"]!.Strings("default_exit_members").ToList(); var panel = new StackPanel { Spacing = 8 }; var list = new ListView { SelectionMode = ListViewSelectionMode.Single, ItemsSource = members.ToArray() }; panel.Children.Add(list);
        panel.Children.Add(Row(Action("上移", () => { var index = list.SelectedIndex; if (index > 0) { (members[index - 1], members[index]) = (members[index], members[index - 1]); list.ItemsSource = members.ToArray(); list.SelectedIndex = index - 1; } return Task.CompletedTask; }), Action("下移", () => { var index = list.SelectedIndex; if (index >= 0 && index < members.Count - 1) { (members[index + 1], members[index]) = (members[index], members[index + 1]); list.ItemsSource = members.ToArray(); list.SelectedIndex = index + 1; } return Task.CompletedTask; })));
        var dialog = new ContentDialog { XamlRoot = shell.XamlRoot, RequestedTheme = ElementTheme.Dark, Title = "默认出口顺序", Content = panel, PrimaryButtonText = "保存", CloseButtonText = "取消" };
        if (await ShowDialog(dialog) == ContentDialogResult.Primary) { scheme["Layout"]!["default_exit_members"] = new JsonArray(members.Select(m => (JsonNode?)JsonValue.Create(m)).ToArray()); DirtyScheme(); }
    }
    private async Task PublishClients()
    {
        var selected = scheme ?? throw new OperationException("请先选择方案。"); var clash = selected.Text("Targets.Clash"); var sing = selected.Text("Targets.SingBox"); workbench.PreparePublish(selected, clash, sing);
        if (!await ConfirmAsync(new("发布客户端权威", "两端候选已校验。将备份并替换以下权威文件：\n" + clash + "\n" + sing + "\n客户端需要你自行导入。"), CancellationToken.None)) return;
        await RunBackground("发布权威文件", token => { token.ThrowIfCancellationRequested(); workbench.Publish(selected, clash, sing); Show("两份权威已发布，备份和事务记录已保存。", InfoBarSeverity.Success); return Task.CompletedTask; });
    }
    private void Settings()
    {
        page.Children.Add(GroupLabel("外观"));
        var appearance = Choice("", settings, "Appearance", [("Dark", "深色"), ("Light", "浅色")]); appearance.MinWidth = 150; appearance.Tag = "Appearance"; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(appearance, "颜色模式");
        appearance.SelectionChanged += (_, _) => SetAppearance(settings.Text("Appearance"), true);
        page.Children.Add(SettingsGroup(SettingRow("颜色模式", "切换深色与浅色界面", Symbol.Setting, appearance), FontSetting()));
        var check = new ToggleSwitch { IsOn = settings.Flag("AutoCheckUpdates"), OnContent = "", OffContent = "", MinWidth = 0, Width = 48 }; check.Toggled += (_, _) => { settings["AutoCheckUpdates"] = check.IsOn; SaveSettings(); };
        page.Children.Add(GroupLabel("更新"));
        page.Children.Add(SettingsGroup(
            SettingRow("自动检查更新", "在启动应用时检查正式版本", Symbol.Sync, check),
            SettingRow("检查更新", "安装新版后自动重新打开应用", Symbol.Download, Action("检查更新", () => CheckUpdates(false)))));
        var proxy = Field("代理地址（可留空）", settings, "UpdateProxy"); proxy.LostFocus += (_, _) => SaveSettings();
        page.Children.Add(Details("更新连接", Card(Column(proxy, Text("此地址仅供应用下载更新使用。", 12, true)))));
        page.Children.Add(GroupLabel("数据与配置"));
        page.Children.Add(SettingsGroup(
            SettingRow("私人归档", "实例、客户端方案与凭据统一存放在应用目录", Symbol.Folder, Action("打开目录", () => { SafePath.CheckLinks(paths.Private); Directory.CreateDirectory(paths.Private); System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(paths.Private) { UseShellExecute = true }); return Task.CompletedTask; })),
            SettingRow("卸载数据处理", "卸载时可选择保留归档和本地配置，或彻底删除应用数据", Symbol.Delete, Text("卸载时选择", 12, true))));
        var version = ArchiveStore.ReadJson(paths.Resolve("config/application.json")).Text("version");
        page.Children.Add(GroupLabel("关于"));
        page.Children.Add(SettingsGroup(SettingRow("MXH VPS Deploy", "Windows 桌面应用", Symbol.Help, Text("v" + version, 13, true))));
    }
    private void SaveSettings() => ArchiveStore.WriteJson(paths.Resolve("private/desktop-settings.json"), settings);
}
