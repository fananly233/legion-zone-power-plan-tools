using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Microsoft.Win32;

namespace LenovoPowerPlanTools;
public sealed record PlanRow(string Guid, string Name, string Activity, string Personality, string ResourceId);
public sealed class MainWindow : Window
{
    readonly TabControl tabs = new() { Background = Brushes.Transparent, BorderThickness = new Thickness(0), Margin = new Thickness(24, 0, 24, 10) };
    readonly TextBlock status = new() { Text = "正在读取本机状态…", Margin = new Thickness(28, 10, 28, 12) };
    readonly ProgressBar progress = new() { Height = 3, IsIndeterminate = false, Visibility = Visibility.Collapsed };
    readonly StackPanel overview = new(), library = new(), vendor = new(), backups = new();
    readonly ObservableCollection<PlanRow> plans = [];
    readonly DataGrid grid = new() { AutoGenerateColumns = false, IsReadOnly = true, CanUserAddRows = false, SelectionMode = DataGridSelectionMode.Single, MinHeight = 190, MaxHeight = 270, Margin = new Thickness(0, 0, 0, 16), Background = Brushes.White, GridLinesVisibility = DataGridGridLinesVisibility.Horizontal, HeadersVisibility = DataGridHeadersVisibility.Column };
    JsonNode? state;
    bool busy;
    public MainWindow()
    {
        Title = "联想电源计划工具 · 0.3.0"; Width = 1160; Height = 840; MinWidth = 880; MinHeight = 640;
        Background = new SolidColorBrush(Color.FromRgb(242,245,248)); FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var root = new DockPanel(); Content = root;
        var header = new StackPanel { Margin = new Thickness(28, 24, 28, 22) };
        header.Children.Add(T("联想电源计划工具", 28, true));
        header.Children.Add(T("管理你的 Windows 电源计划，让每一次修改都可以追溯。", 14, false, "#526574"));
        var zoomRow = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        zoomRow.Children.Add(T("界面缩放  ", 12));
        var zoom = new ComboBox { Width = 90, ItemsSource = new[] { "100%", "125%", "150%" }, SelectedIndex = 0 };
        zoom.SelectionChanged += (_, _) => { var scale = 1 + zoom.SelectedIndex * .25; tabs.LayoutTransform = new ScaleTransform(scale, scale); };
        zoomRow.Children.Add(zoom); header.Children.Add(zoomRow);
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var footer = new StackPanel(); footer.Children.Add(progress); footer.Children.Add(status);
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        root.Children.Add(tabs);
        AddTab("概览", overview);
        var plansPage = new StackPanel();
        plansPage.Children.Add(Heading("本机计划", "先选择计划，再执行操作。Windows 平衡计划受到保护。"));
        foreach (var pair in new[] { ("计划名称", "Name", 2d), ("状态", "Activity", 0.7), ("类型 · AC/DC", "Personality", 1d) })
            grid.Columns.Add(new DataGridTextColumn { Header = pair.Item1, Binding = new Binding(pair.Item2), Width = new DataGridLength(pair.Item3, DataGridLengthUnitType.Star) });
        grid.ItemsSource = plans;
        plansPage.Children.Add(grid);
        var actions = new WrapPanel();
        actions.Children.Add(B("设为活动计划", () => SelectedOperation("Activate")));
        actions.Children.Add(B("查看全部参数", ShowDetails));
        actions.Children.Add(B("导出备份", ExportSelected));
        actions.Children.Add(B("删除计划", () => SelectedOperation("Delete")));
        actions.Children.Add(B("导入本地 .pow", ImportLocal));
        actions.Children.Add(B("刷新", Refresh));
        plansPage.Children.Add(actions);
        plansPage.Children.Add(Heading("第三方计划库", "按需下载 · 固定版本 · SHA256 校验 · 导入后不会自动激活"));
        plansPage.Children.Add(library); AddTab("电源计划", plansPage);
        AddTab("联想防重建", vendor); AddTab("备份恢复", backups);
        Loaded += async (_, _) => await Run(Refresh);
        Closing += (_, e) => { if (busy) { e.Cancel = true; status.Text = "操作仍在进行，请等待结束后关闭。"; } };
    }
    static TextBlock T(string value, double size = 14, bool bold = false, string? color = null) => new()
    { Text = value, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, Margin = new Thickness(0, 0, 0, 8), Foreground = color is null ? (Brush)new SolidColorBrush(Color.FromRgb(24, 43, 58)) : new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)) };
    static StackPanel Heading(string title, string note)
    {
        var p = new StackPanel { Margin = new Thickness(0, 12, 0, 8) }; p.Children.Add(T(title, 21, true)); p.Children.Add(T(note, 13, false, "#526574")); return p;
    }
    static Border Card(UIElement content) => new() { Child = content, Background = Brushes.White, BorderBrush = new SolidColorBrush(Color.FromRgb(220, 229, 235)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(20), Margin = new Thickness(0, 0, 0, 14) };
    Button B(string title, Func<Task> action)
    {
        var button = new Button { Content = title }; button.Click += async (_, _) => await Run(action); return button;
    }
    void AddTab(string name, StackPanel content) => tabs.Items.Add(new TabItem { Header = name, Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(4, 12, 4, 0) } });
    async Task Run(Func<Task> action)
    {
        if (busy) return;
        busy = true; tabs.IsEnabled = false; progress.Visibility = Visibility.Visible; progress.IsIndeterminate = true;
        try { await action(); }
        catch (Exception ex) { status.Text = "未完成：" + ex.Message; MessageBox.Show(this, ex.Message, "操作未完成", MessageBoxButton.OK, MessageBoxImage.Warning); }
        finally { busy = false; tabs.IsEnabled = true; progress.IsIndeterminate = false; progress.Visibility = Visibility.Collapsed; }
    }
    void Report(string text) { Dispatcher.Invoke(() => status.Text = text); }
    async Task Refresh()
    {
        Report("读取计划与功能适配状态…");
        var result = await Engine.ReadAsync(Engine.Request("Status"));
        if (!Engine.Bool(result, "Success")) throw new InvalidOperationException(Engine.Text(result, "Message"));
        state = result["State"]!;
        var identities = ReadManagedIdentities();
        plans.Clear();
        foreach (var p in state["Plans"]!.AsArray())
        {
            var guid = Engine.Text(p, "Guid");
            plans.Add(new(guid, Engine.Text(p, "Name"), Engine.Bool(p, "IsActive") ? "● 正在使用" : "未启用",
                Engine.Text(p, "Personality") switch { "Balanced" => "平衡 / 平衡", "Other" => "含非平衡类型", _ => "未知" },
                identities.GetValueOrDefault(guid, "")));
        }
        RenderOverview(); RenderLibrary(); RenderVendor(); RenderBackups();
        Report("状态已更新。浏览不会修改系统；执行修改时才请求管理员权限。");
    }
    Dictionary<string, string> ReadManagedIdentities()
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(Catalog.BackupRoot)) return map;
        foreach (var dir in Directory.EnumerateDirectories(Catalog.BackupRoot))
            try
            {
                var m = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "manifest.json")));
                if (Engine.Text(m, "Action") == "Import" && Engine.Text(m, "Status") == "Completed")
                    map[Engine.Text(m, "PlanGuid")] = Engine.Text(m, "ResourceId");
            } catch { }
        return map;
    }
    void RenderOverview()
    {
        overview.Children.Clear();
        overview.Children.Add(Heading("当前状态", "通用电源计划管理适用于 Windows；联想防重建功能按实际安装内容开放。"));
        var current = plans.FirstOrDefault(p => p.Activity.StartsWith('●'));
        var active = new StackPanel(); active.Children.Add(T("正在使用", 13, false, "#087E8B")); active.Children.Add(T(current?.Name ?? "未知", 26, true)); active.Children.Add(T(current?.Guid ?? "", 12, false, "#526574"));
        active.Children.Add(B("管理电源计划 →", () => { tabs.SelectedIndex = 1; return Task.CompletedTask; })); overview.Children.Add(Card(active));
        var c = state!["Capabilities"]; var v = state["Vendor"]; var info = new StackPanel();
        info.Children.Add(T("设备与兼容性", 18, true));
        info.Children.Add(T($"电脑：{Engine.Text(c, "Manufacturer")} {Engine.Text(c, "Model")}"));
        info.Children.Add(T("处理器：" + Engine.Text(c, "Cpu")));
        info.Children.Add(T("Modern Standby：" + (c?["ModernStandby"] is null ? "无法确认" : Engine.Bool(c, "ModernStandby") ? "支持（仅允许已确认的平衡类型计划）" : "不支持")));
        info.Children.Add(T("Legion Zone：" + Engine.Text(v, "Version")));
        info.Children.Add(T("通用管理：可用    ·    联想模板适配：" + (Engine.Bool(v, "BasicSupported") ? "规则匹配" : "不可用")));
        info.Children.Add(B("重新检测", Refresh)); overview.Children.Add(Card(info));
        overview.Children.Add(T("适配不等于性能推荐。第三方计划的游戏表现、续航与长期稳定性仍需在具体设备验证。", 13, false, "#526574"));
        if (Engine.IsAdministrator) overview.Children.Add(T("当前界面以管理员权限启动。请退出后普通双击启动，以便正确保持托盘权限。", 14, true, "#A04517"));
    }
    bool PowerXAllowed => Engine.Text(state?["Capabilities"], "Cpu").Contains("Intel", StringComparison.OrdinalIgnoreCase);
    void RenderLibrary()
    {
        library.Children.Clear();
        foreach (var asset in Catalog.Assets)
        {
            var box = new StackPanel();
            box.Children.Add(T(asset.Name, 18, true));
            box.Children.Add(T(asset.Repository + "  ·  " + (Catalog.Matches(Catalog.CachePath(asset), asset.Sha256) ? "缓存已核验" : "尚未下载"), 12, false, "#087E8B"));
            box.Children.Add(T(asset.Description));
            box.Children.Add(T(asset.Validation + "；未验证性能、续航或全部机型。", 12, false, "#526574"));
            var row = new WrapPanel();
            row.Children.Add(B("下载 / 校验缓存", async () => { await Catalog.DownloadAsync(asset, Report); RenderLibrary(); }));
            var import = B("导入计划", async () =>
            {
                if (!Confirm("导入 " + asset.Name, asset.Description + "\n\n只导入新计划，不激活。原活动计划保持不变，操作记录保存到：\n" + Catalog.BackupRoot)) return;
                await Catalog.DownloadAsync(asset, Report);
                await Execute(Engine.Request("Import", resource: asset.Id));
            });
            import.IsEnabled = asset.Id != "powerx-v2" || PowerXAllowed;
            row.Children.Add(import);
            row.Children.Add(B("来源与说明 ↗", () => OpenUrl(asset.SourceUrl)));
            row.Children.Add(B("上游许可证 ↗", () => OpenUrl(asset.LicenseUrl)));
            box.Children.Add(row); library.Children.Add(Card(box));
        }
    }
    void RenderVendor()
    {
        vendor.Children.Clear(); var v = state!["Vendor"];
        vendor.Children.Add(Heading("联想防重建", "只有匹配已验证规则的操作才会开放。Windows 计划与 Fn+Q / 固件性能档位不是同一功能。"));
        var basic = new StackPanel();
        basic.Children.Add(T("自动切换与模板阻挡", 20, true));
        basic.Children.Add(T(Engine.Text(v, "BasicReason")));
        basic.Children.Add(T("PerformanceSwitch：" + (Engine.Text(v, "PerformanceSwitch") is "" ? "未知" : Engine.Text(v, "PerformanceSwitch"))));
        if (v?["Templates"] is JsonArray templates)
            foreach (var template in templates) basic.Children.Add(T(Engine.Text(template, "RelativePath") + "  ·  " + (Engine.Bool(template, "DisabledExists") ? "已改名" : "原模板存在"), 12));
        basic.Children.Add(T("将备份并删除四个已知联想计划、关闭游戏自动切换并改名模板。此步骤不能独立阻止自定义计划的动态重建。", 13, false, "#526574"));
        var disable = B("备份并清理联想计划", async () =>
        {
            if (Confirm("联想计划清理", "将备份安静、均衡、野兽、自定义计划，关闭自动切换并改名模板。如当前使用联想计划，将先切换到 Windows 平衡。\n\n备份：" + Catalog.BackupRoot))
                await Execute(Engine.Request("VendorDisable"));
        }); disable.IsEnabled = Engine.Bool(v, "BasicSupported"); basic.Children.Add(disable); vendor.Children.Add(Card(basic));
        var patch = new StackPanel(); patch.Children.Add(T("高级：自定义计划创建分支补丁", 20, true));
        patch.Children.Add(T(v?["Patched"] is null ? "补丁状态无法确认" : Engine.Bool(v, "Patched") ? "补丁已应用" : "补丁未应用", 15, true, "#087E8B"));
        patch.Children.Add(T(Engine.Text(v, "PatchReason")));
        patch.Children.Add(T("仅支持指定版本与 SHA256。修改两字节会使厂商 DLL 签名失效；更新可能覆盖补丁。执行时备份原文件、短暂停止托盘，并验证重新加载；失败尝试恢复。", 14, false, "#A04517"));
        var apply = B("查看并应用补丁", async () =>
        {
            if (Confirm("确认 DLL 修改影响", "此操作会使 LZTrayPlugin.dll 的联想签名失效。仅在匹配的 2.0.28.8182 文件上修改两字节，并删除自定义计划。\n\n会暂时重启托盘。失败尝试恢复；不代表已验证游戏或重启后的长期效果。\n\n是否应用？"))
                await Execute(Engine.Request("PatchApply"));
        }); apply.IsEnabled = Engine.Bool(v, "PatchSupported") && !Engine.Bool(v, "Patched"); patch.Children.Add(apply);
        patch.Children.Add(T("撤销请前往“备份恢复”，选择对应的完整备份文件夹。", 13)); vendor.Children.Add(Card(patch));
    }
    void RenderBackups()
    {
        backups.Children.Clear(); backups.Children.Add(Heading("备份恢复", "每次修改先保留操作记录。恢复会核验备份，不覆盖已有同 GUID 的后续修改。"));
        var row = new WrapPanel();
        row.Children.Add(B("选择已有备份文件夹", async () =>
        {
            var dialog = new OpenFolderDialog { Title = "选择包含 manifest.json 的完整备份文件夹" };
            if (dialog.ShowDialog(this) == true) await Restore(dialog.FolderName);
        }));
        row.Children.Add(B("打开备份目录", () => { if (Directory.Exists(Catalog.BackupRoot)) Process.Start(new ProcessStartInfo(Catalog.BackupRoot) { UseShellExecute = true }); else Report("还没有操作备份。"); return Task.CompletedTask; }));
        backups.Children.Add(row);
        backups.Children.Add(T("早期桌面备份请使用原文件夹自带的 restore.ps1；不要与其他备份混合。", 13, false, "#526574"));
        if (!Directory.Exists(Catalog.BackupRoot)) { backups.Children.Add(Card(T("暂无操作记录。导入、切换或删除计划后，会在这里显示。"))); return; }
        foreach (var dir in Directory.EnumerateDirectories(Catalog.BackupRoot).OrderDescending().Take(100))
        {
            var box = new StackPanel();
            try
            {
                var m = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "manifest.json")));
                box.Children.Add(T(Engine.Text(m, "Created"), 17, true));
                var kind = Engine.Text(m, "Action"); if (kind == "") kind = Engine.Text(m, "Kind") == "CustomPlanBranchPatch" ? "DLL 分支补丁" : "联想模板与计划";
                var outcome = Engine.Text(m, "Status");
                box.Children.Add(T(kind + "  ·  " + (outcome == "" ? "旧格式：查看结果文件" : outcome)));
                box.Children.Add(T(dir, 11, false, "#526574"));
                if (Engine.Text(m, "Error") != "") box.Children.Add(T(Engine.Text(m, "Error"), 13, false, "#A04517"));
                box.Children.Add(B("查看记录", () => { ShowText("备份记录", m!.ToJsonString(new() { WriteIndented = true })); return Task.CompletedTask; }));
                var restore = B("从此备份恢复", () => Restore(dir)); restore.IsEnabled = outcome is not ("Restored" or "RolledBack"); box.Children.Add(restore);
            }
            catch { box.Children.Add(T(Path.GetFileName(dir) + "：备份不完整，请检查该目录。", 14, false, "#A04517")); }
            backups.Children.Add(Card(box));
        }
    }
    PlanRow Selected() => grid.SelectedItem as PlanRow ?? throw new InvalidOperationException("请先选择一个本机计划。");
    async Task SelectedOperation(string action)
    {
        var selected = Selected();
        if (action == "Delete" && selected.Guid == "381b4222-f694-41f0-9685-ff5bb260df2e") throw new InvalidOperationException("Windows 平衡计划受到保护。");
        var note = action == "Delete" ? "将备份并删除此计划。" + (selected.Activity.StartsWith('●') ? "它当前正在使用，将先切换到 Windows 平衡。" : "") : "将此计划设为活动计划；操作前记录原活动计划以便恢复。";
        if (Confirm(action == "Delete" ? "删除计划" : "切换活动计划", selected.Name + "\n" + selected.Guid + "\n\n" + note + "\n备份：" + Catalog.BackupRoot))
            await Execute(Engine.Request(action, selected.Guid, selected.ResourceId));
    }
    async Task ExportSelected()
    {
        var selected = Selected(); var dialog = new SaveFileDialog { Filter = "电源计划备份 (*.pow)|*.pow", FileName = selected.Guid + ".pow", AddExtension = true, DefaultExt = ".pow" };
        if (dialog.ShowDialog(this) != true) return;
        var r = Engine.Request("Export", selected.Guid); r["ExportPath"] = dialog.FileName; await Execute(r);
    }
    async Task ImportLocal()
    {
        var dialog = new OpenFileDialog { Filter = "电源计划文件 (*.pow)|*.pow" };
        if (dialog.ShowDialog(this) != true) return;
        if (!Confirm("导入本地文件", dialog.FileName + "\n\n只导入，不激活。文件的来源、参数及兼容性由你确认；导入失败将清理本次新建的计划。")) return;
        var r = Engine.Request("Import"); r["SourcePath"] = dialog.FileName; await Execute(r);
    }
    async Task ShowDetails()
    {
        var selected = Selected(); var r = await Engine.ReadAsync(Engine.Request("Details", selected.Guid));
        if (!Engine.Bool(r, "Success")) throw new InvalidOperationException(Engine.Text(r, "Message"));
        ShowText(selected.Name + " · AC/DC 参数", Engine.Text(r, "Details"));
    }
    void ShowText(string title, string text)
    {
        new Window { Owner = this, Title = title, Width = 820, Height = 610, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, FontFamily = new FontFamily("Consolas, Microsoft YaHei UI"), FontSize = 13, Margin = new Thickness(16), VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto } }.ShowDialog();
    }
    async Task Restore(string dir)
    {
        var m = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(dir, "manifest.json")));
        var legacy = Engine.Text(m, "SchemaVersion") == "1";
        if (!Confirm("恢复备份", dir + "\n\n将按照记录撤销对应操作，并恢复记录中的活动计划。恢复不能与其他修改并行；冲突或校验失败会停止并保留记录。")) return;
        var r = Engine.Request(legacy ? "LegacyRestore" : "Restore"); r["BackupDirectory"] = dir; await Execute(r);
    }
    async Task Execute(JsonObject request)
    {
        var result = await Engine.ExecuteAsync(request, Report);
        var message = Engine.Text(result, "Message");
        if (Engine.Text(result, "BackupDirectory") != "") message += "\n\n记录：" + Engine.Text(result, "BackupDirectory");
        if (result["Errors"] is JsonArray errors && errors.Count != 0) message += "\n恢复仍有问题：" + errors.ToJsonString();
        await Refresh();
        Report(Engine.Bool(result, "Success") ? "操作已完成并重新读取状态。" : "操作未完成，请检查结果与备份。");
        MessageBox.Show(this, message, Engine.Bool(result, "Success") ? "操作结果" : "操作未完成", MessageBoxButton.OK, Engine.Bool(result, "Success") ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
    bool Confirm(string title, string text) => MessageBox.Show(this, text, title, MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK;
    static Task OpenUrl(string url) { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); return Task.CompletedTask; }
}
