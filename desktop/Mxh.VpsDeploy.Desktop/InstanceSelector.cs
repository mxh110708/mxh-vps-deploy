using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Mxh.VpsDeploy.Desktop;

internal sealed class InstanceSelector : ComboBox
{
    public InstanceSelector() { DefaultStyleKey = typeof(ComboBox); }
    protected override void OnPointerWheelChanged(PointerRoutedEventArgs e)
    {
        // Leave closed-selector wheel input unhandled so the page can scroll.
        // The open list retains its native scrolling and click selection.
        if (IsDropDownOpen) base.OnPointerWheelChanged(e);
    }
}
