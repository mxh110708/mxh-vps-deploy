#nullable enable
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Mxh.VpsDeploy.Core;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Input;
using global::Windows.Foundation;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private string nodeDragSession = "";
    private readonly List<(Grid Row, Border Line)> nodeDropRows = new();
    private NodePointerDrag? nodePointerDrag;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? nodeScrollTimer;
    private sealed class NodePointerDrag(JsonObject selected, string session, int source, Point origin)
    {
        public JsonObject Scheme { get; } = selected;
        public string Session { get; } = session;
        public int Source { get; } = source;
        public Point Origin { get; } = origin;
        public Point Position { get; set; } = origin;
        public int Insertion { get; set; } = source;
        public bool Moved { get; set; }
    }
    private sealed class NodeReorderHandle : UserControl
    {
        public NodeReorderHandle() { ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.SizeNorthSouth); }
    }
    private UIElement ReorderableNodeRow(JsonObject selected, JsonArray nodes, int index, FrameworkElement actions)
    {
        var session = nodeDragSession; var node = nodes[index]!;
        // Button consumes pointer gestures. Capture a dedicated handle's pointer
        // for in-app reordering rather than depending on OS drag/drop startup.
        var handle = new NodeReorderHandle { Content = Text("⠿", 22, true), Tag = "NodeDragHandle." + index, Width = 32, Padding = new Thickness(6, 10, 6, 10), Background = Brush(Paint.Surface), VerticalAlignment = VerticalAlignment.Center, ManipulationMode = ManipulationModes.None };
        AutomationProperties.SetName(handle, "拖动排序 " + node.Text("name")); ToolTipService.SetToolTip(handle, "按住此处，上下拖动调整节点顺序");
        handle.PointerPressed += (_, args) =>
        {
            if (!args.GetCurrentPoint(handle).Properties.IsLeftButtonPressed || !BeginNodeReorder(selected, session, index, args.GetCurrentPoint(mainScroll).Position)) return;
            if (!handle.CapturePointer(args.Pointer)) { CancelNodeReorder(); return; }
            args.Handled = true;
        };
        handle.PointerMoved += (_, args) => { if (nodePointerDrag == null) return; UpdateNodeReorder(args.GetCurrentPoint(mainScroll).Position); args.Handled = true; };
        handle.PointerReleased += (_, args) => { if (nodePointerDrag == null) return; UpdateNodeReorder(args.GetCurrentPoint(mainScroll).Position); FinishNodeReorder(); handle.ReleasePointerCapture(args.Pointer); args.Handled = true; };
        handle.PointerCanceled += (_, _) => CancelNodeReorder(); handle.PointerCaptureLost += (_, _) => CancelNodeReorder();
        var grid = new Grid { ColumnSpacing = 18, Padding = new Thickness(16, 18, 22, 18) };
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new()); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        grid.Children.Add(handle); var description = Column(Text(node.Text("name")), Text(node.Text("kind") == "landing" ? "落地 · 连接 " + node.Text("transit_group") : "入口 · " + node.Text("region_group"), 13, true)); Grid.SetColumn(description, 1); grid.Children.Add(description); Grid.SetColumn(actions, 2); grid.Children.Add(actions);
        var target = new Grid { Tag = "NodeDropTarget." + index }; target.Children.Add(grid);
        var line = new Border { Height = 3, Background = Brush(Paint.Accent), Visibility = Visibility.Collapsed, IsHitTestVisible = false, Margin = new Thickness(12, 0, 12, 0) }; target.Children.Add(line); nodeDropRows.Add((target, line));
        return target;
    }
    private bool BeginNodeReorder(JsonObject selected, string session, int source, Point position)
    {
        CancelNodeReorder();
        if (taskCancellation != null || session != nodeDragSession || scheme != selected || currentPage != "clients" || designerStep != 1 || source < 0 || source >= nodeDropRows.Count) return false;
        nodePointerDrag = new(selected, session, source, position);
        nodeScrollTimer ??= DispatcherQueue.CreateTimer(); nodeScrollTimer.Interval = TimeSpan.FromMilliseconds(40);
        nodeScrollTimer.Tick -= ScrollNodeReorder; nodeScrollTimer.Tick += ScrollNodeReorder; nodeScrollTimer.Start(); return true;
    }
    private void ScrollNodeReorder(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        if (nodePointerDrag is not { Moved: true } drag || mainScroll == null) return;
        var y = drag.Position.Y;
        var change = y < 48 ? -18 : y > mainScroll.ActualHeight - 48 ? 18 : 0;
        if (change == 0) return;
        mainScroll.ChangeView(null, Math.Clamp(mainScroll.VerticalOffset + change, 0, mainScroll.ScrollableHeight), null, true);
        shell.UpdateLayout(); UpdateNodeReorder(drag.Position);
    }
    private void UpdateNodeReorder(Point position)
    {
        if (nodePointerDrag is not { } drag) return;
        if (taskCancellation != null || scheme != drag.Scheme || nodeDragSession != drag.Session) { CancelNodeReorder(); return; }
        drag.Position = position; drag.Moved |= Math.Abs(position.Y - drag.Origin.Y) >= 5;
        foreach (var item in nodeDropRows) item.Line.Visibility = Visibility.Collapsed;
        if (!drag.Moved || mainScroll == null || nodeDropRows.Count == 0) return;
        var insertion = nodeDropRows.Count;
        for (var index = 0; index < nodeDropRows.Count; index++)
        {
            var row = nodeDropRows[index].Row; var top = row.TransformToVisual(mainScroll).TransformPoint(new(0, 0)).Y;
            if (position.Y < top + row.ActualHeight / 2) { insertion = index; break; }
        }
        drag.Insertion = insertion;
        var target = nodeDropRows[Math.Min(insertion, nodeDropRows.Count - 1)]; target.Line.VerticalAlignment = insertion == nodeDropRows.Count ? VerticalAlignment.Bottom : VerticalAlignment.Top; target.Line.Visibility = Visibility.Visible;
    }
    private bool FinishNodeReorder()
    {
        var drag = nodePointerDrag; CancelNodeReorder();
        if (drag == null || !drag.Moved || taskCancellation != null || scheme != drag.Scheme || nodeDragSession != drag.Session) return false;
        if (!ClientSchemes.MoveNode(drag.Scheme, drag.Source, drag.Insertion)) return false;
        Navigate("clients"); Show("节点顺序已调整。保存方案后保留排序，导出前重新生成并校验。", InfoBarSeverity.Success); return true;
    }
    private void CancelNodeReorder()
    {
        nodePointerDrag = null; nodeScrollTimer?.Stop(); foreach (var item in nodeDropRows) item.Line.Visibility = Visibility.Collapsed;
    }
}
