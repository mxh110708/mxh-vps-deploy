#nullable enable
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Mxh.VpsDeploy.Core;
using System.Text.Json.Nodes;
using global::Windows.ApplicationModel.DataTransfer;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private const string NodeDragFormat = "MXH.ConfigurationNodeOrder";
    private string nodeDragSession = "";
    private UIElement ReorderableNodeRow(JsonObject selected, JsonArray nodes, int index, FrameworkElement actions)
    {
        var session = nodeDragSession; var node = nodes[index]!;
        var handle = new Button { Content = Text("⠿", 22, true), CanDrag = true, Tag = "NodeDragHandle." + index, Width = 30, Padding = new Thickness(4, 8, 4, 8), Background = Brush(Paint.Surface), BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(handle, "拖动排序 " + node.Text("name")); ToolTipService.SetToolTip(handle, "拖动此处调整节点顺序");
        handle.DragStarting += (_, args) =>
        {
            if (taskCancellation != null || session != nodeDragSession || scheme != selected) { args.Cancel = true; return; }
            args.Data.RequestedOperation = DataPackageOperation.Move; args.Data.SetData(NodeDragFormat, session + ":" + index);
        };
        var grid = new Grid { ColumnSpacing = 18, Padding = new Thickness(16, 18, 22, 18) };
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        grid.Children.Add(handle); var description = Column(Text(node.Text("name")), Text(node.Text("kind") == "landing" ? "落地 · 连接 " + node.Text("transit_group") : "入口 · " + node.Text("region_group"), 13, true)); Grid.SetColumn(description, 1); grid.Children.Add(description); Grid.SetColumn(actions, 2); grid.Children.Add(actions);
        var target = new Grid { AllowDrop = true, Tag = "NodeDropTarget." + index }; target.Children.Add(grid);
        var line = new Border { Height = 3, Background = Brush(Paint.Accent), Visibility = Visibility.Collapsed, IsHitTestVisible = false, Margin = new Thickness(12, 0, 12, 0) }; target.Children.Add(line);
        target.DragOver += (_, args) =>
        {
            if (!args.DataView.Contains(NodeDragFormat) || session != nodeDragSession || scheme != selected || taskCancellation != null) { args.AcceptedOperation = DataPackageOperation.None; return; }
            args.AcceptedOperation = DataPackageOperation.Move;
            line.VerticalAlignment = args.GetPosition(target).Y < target.ActualHeight / 2 ? VerticalAlignment.Top : VerticalAlignment.Bottom; line.Visibility = Visibility.Visible;
            if (mainScroll != null)
            {
                var y = args.GetPosition(mainScroll).Y;
                if (y < 60) mainScroll.ChangeView(null, Math.Max(0, mainScroll.VerticalOffset - 24), null, true);
                else if (y > mainScroll.ActualHeight - 60) mainScroll.ChangeView(null, Math.Min(mainScroll.ScrollableHeight, mainScroll.VerticalOffset + 24), null, true);
            }
        };
        target.DragLeave += (_, _) => line.Visibility = Visibility.Collapsed;
        target.Drop += async (_, args) =>
        {
            var insertion = index + (args.GetPosition(target).Y >= target.ActualHeight / 2 ? 1 : 0);
            line.Visibility = Visibility.Collapsed;
            if (!args.DataView.Contains(NodeDragFormat) || taskCancellation != null) return;
            var deferral = args.GetDeferral();
            try
            {
                var data = await args.DataView.GetDataAsync(NodeDragFormat) as string;
                if (session != nodeDragSession || scheme != selected || data == null || !data.StartsWith(session + ":", StringComparison.Ordinal) || !int.TryParse(data[(session.Length + 1)..], out var source)) return;
                if (ClientSchemes.MoveNode(selected, source, insertion)) { Navigate("clients"); Show("节点顺序已调整。保存方案后保留排序，导出前重新生成并校验。", InfoBarSeverity.Success); }
            }
            catch (Exception error) { Show(SafeFailures.Describe(error).Message, InfoBarSeverity.Error); }
            finally { deferral.Complete(); }
        };
        return target;
    }
}
