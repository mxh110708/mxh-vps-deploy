#nullable enable
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Mxh.VpsDeploy.Core;
using global::Windows.Foundation;
using global::Windows.System;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private async Task NodeReorderRegression(string output, string theme, Action<bool, string> require)
    {
        var originalSize = AppWindow.Size;
        var scale = shell.XamlRoot.RasterizationScale;
        try
        {
            AppWindow.Resize(new((int)(1000 * scale), (int)(720 * scale)));
            Navigate("clients"); await Task.Delay(120); shell.UpdateLayout();
            require(nodeDropRows.Count == 3 && Find<NodeReorderHandle>(page).Count() == 3, "节点指针拖动手柄未接上。");
            Point Grip(int index) => nodeDropRows[index].Handle.TransformToVisual(mainScroll).TransformPoint(new(22, 26));
            Point Before(int index) => new(Grip(index).X, nodeDropRows[index].Row.TransformToVisual(mainScroll).TransformPoint(new(0, 2)).Y);
            async Task WaitForState(Func<bool> condition, string reason)
            {
                var until = DateTimeOffset.UtcNow.AddSeconds(3);
                while (!condition() && DateTimeOffset.UtcNow < until) { shell.UpdateLayout(); await Task.Delay(25); }
                require(condition(), reason);
            }
            await WaitForState(() => nodeDropRows.All(row => row.Handle.IsLoaded && row.Row.ActualHeight > 0), "节点手柄布局未就绪。");
            // A compact desktop can clip the third row. Scroll the real viewport
            // before checking hit testing or starting a pointer gesture.
            mainScroll!.ChangeView(null, Math.Clamp(mainScroll.VerticalOffset + Before(0).Y - 14, 0, mainScroll.ScrollableHeight), null, true);
            await WaitForState(() => Before(0).Y >= 0 && Grip(2).Y < mainScroll.ActualHeight - 12, "拖动起点与落点没有进入实际可视区域。");
            string Names() => string.Join("|", scheme!["Nodes"]!.AsArray().Select(n => n!.Text("name")));
            bool Press(int index, uint id = 1, bool capture = true) => nodeDropRows[index].Handle.Press?.Invoke(Grip(index), id, () => capture) == true;
            var handle = nodeDropRows[2].Handle;
            // Scroll transforms can update before the compositor's hit-test tree.
            // Require the real hit target to be ready, not just layout coordinates.
            bool HitHandle() => VisualTreeHelper.FindElementsInHostCoordinates(handle.TransformToVisual(null).TransformPoint(new(22, 26)), shell).Contains(handle);
            await WaitForState(HitHandle, "手柄中心没有实际命中原生控件。手柄纵坐标：" + Grip(2).Y.ToString("F0") + "；可视高度：" + mainScroll!.ActualHeight.ToString("F0"));
            var target = Before(0);
            scheme!["Candidate"] = new JsonObject { ["ValidationStatus"] = "Passed" };
            require(Press(2), "原生手柄按下未开始。");
            handle.Move?.Invoke(target, 1); shell.UpdateLayout();
            require(nodeDragPreview != null && nodeDropRows[0].Line.Visibility == Visibility.Visible && nodeDropRows[0].Row.Background != null && nodeDropRows[2].Row.Opacity < 1, "缺少拖动整行、落点线或行高亮。");
            var previewTop = Canvas.GetTop(nodeDragPreview!); var shifted = new Point(target.X, target.Y + 14);
            handle.Move?.Invoke(shifted, 1);
            require(Math.Abs(Canvas.GetTop(nodeDragPreview!) - previewTop - 14) < 1, "拖动行没有跟随指针。");
            await Capture(SafePath.Resolve(output, "node-drag-" + theme.ToLowerInvariant() + ".png"));
            require(handle.Release?.Invoke(target, 1) == true && scheme["Candidate"] == null, "释放未重排或未失效已校验配置。");
            require(Names() == "入口 C|入口 A|入口 B" && nodeDragPreview == null, "重排顺序未保存到方案或拖动行残留。");
            await Capture(SafePath.Resolve(output, "node-order-" + theme.ToLowerInvariant() + ".png"));
            var savedCandidate = new JsonObject { ["ValidationStatus"] = "Passed" }; scheme["Candidate"] = savedCandidate;
            handle = nodeDropRows[0].Handle; var click = Grip(0);
            require(Press(0) && handle.Release?.Invoke(click, 1) == false && scheme["Candidate"] == savedCandidate, "点击手柄意外改变顺序或校验状态。");
            require(!Press(0, capture: false) && nodePointerDrag == null, "未取得指针捕获时仍开始拖动。");
            handle = nodeDropRows[2].Handle; var origin = Grip(2); target = Before(0);
            require(Press(2), "取消用例无法开始拖动。");
            handle.Move?.Invoke(target, 2);
            require(nodePointerDrag?.Moved == false && handle.Release?.Invoke(target, 2) == false, "其他指针改变当前拖动。");
            require(!Press(0, 2) && nodePointerDrag?.Source == 2, "第二个指针抢占当前拖动。");
            handle.Move?.Invoke(target, 1); handle.Key?.Invoke(VirtualKey.Escape);
            require(nodePointerDrag == null && nodeDragPreview == null && nodeDropRows.All(row => row.Row.Opacity == 1 && row.Line.Visibility == Visibility.Collapsed) && Names() == "入口 C|入口 A|入口 B" && scheme["Candidate"] == savedCandidate, "Esc 取消未恢复原顺序或清理拖动视觉。");
            require(Press(2), "移出列表用例无法开始。");
            var outside = new Point(-40, target.Y); handle.Move?.Invoke(outside, 1);
            require(handle.Release?.Invoke(outside, 1) == false && Names() == "入口 C|入口 A|入口 B", "列表外释放仍改变顺序。");
            require(Press(2), "失去捕获用例无法开始。"); handle.Move?.Invoke(target, 1); handle.Cancel?.Invoke(1);
            require(nodePointerDrag == null && nodeDragPreview == null && scheme["Candidate"] == savedCandidate, "取消/失去捕获没有清理拖动。");
            handle = nodeDropRows[0].Handle; Navigate("clients");
            require(handle.Press?.Invoke(origin, 1, () => true) == false && nodePointerDrag == null, "旧页面手柄可以修改新页面。");
            nodeDropRows[0].Handle.Key?.Invoke(VirtualKey.Up); nodeDropRows[2].Handle.Key?.Invoke(VirtualKey.Down);
            require(Names() == "入口 C|入口 A|入口 B", "首尾方向键越界。");
            nodeDropRows[0].Handle.Key?.Invoke(VirtualKey.Down);
            require(Names() == "入口 A|入口 C|入口 B", "手柄方向键未调整顺序。");

            for (var index = 4; index <= 20; index++) scheme!["Nodes"]!.AsArray().Add(new JsonObject { ["name"] = "入口 " + index, ["kind"] = "entry", ["region_group"] = "US-West Entry" });
            Navigate("clients"); await Task.Delay(100); mainScroll!.ChangeView(null, 420, null, true);
            await WaitForState(() => Math.Abs(mainScroll.VerticalOffset - 420) < 2 && nodeDropRows.All(row => row.Row.ActualHeight > 0), "长列表没有滚动到测试起点。");
            var visible = nodeDropRows.Select((row, index) => (row, index)).First(item => Grip(item.index).Y > 70 && Grip(item.index).Y < mainScroll.ActualHeight - 70).index;
            handle = nodeDropRows[visible].Handle;
            require(Press(visible), "滚动后的拖动未开始。");
            var edge = new Point(Grip(visible).X, mainScroll.ActualHeight - 12); handle.Move?.Invoke(edge, 1);
            var oldOffset = mainScroll.VerticalOffset;
            await WaitForState(() => mainScroll.VerticalOffset > oldOffset && nodeDragPreview != null, "拖到边缘没有自动滚动。");
            var sourceName = scheme["Nodes"]!.AsArray()[visible]!.Text("name"); var offsetBeforeDrop = mainScroll.VerticalOffset;
            require(handle.Release?.Invoke(edge, 1) == true && scheme["Nodes"]!.AsArray()[visible]!.Text("name") != sourceName, "滚动后的落点不正确。");
            await WaitForState(() => Math.Abs(mainScroll.VerticalOffset - offsetBeforeDrop) < 2 && nodeDragPreview == null, "排序后滚动位置跳变或拖动视觉未清理。");
            scheme["Nodes"]!.AsArray().Clear();
            foreach (var name in new[] { "入口 C", "入口 A", "入口 B" }) scheme["Nodes"]!.AsArray().Add(new JsonObject { ["name"] = name, ["kind"] = "entry", ["region_group"] = "US-West Entry" });
            Navigate("clients"); mainScroll.ChangeView(null, 0, null, true);
        }
        finally { CancelNodeReorder(); AppWindow.Resize(originalSize); shell.UpdateLayout(); }
    }
}
