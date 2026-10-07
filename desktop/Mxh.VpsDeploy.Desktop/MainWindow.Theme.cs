using Microsoft.UI.Xaml;

namespace Mxh.VpsDeploy.Desktop;

public sealed partial class MainWindow
{
    private void SetAppearance(string value, bool persist = false)
    {
        settings["Appearance"] = value == "Light" ? "Light" : "Dark";
        DesktopTheme.Set(value == "Light");
        if (Content is FrameworkElement root) root.RequestedTheme = DesktopTheme.IsLight ? ElementTheme.Light : ElementTheme.Dark;
        AppWindow.TitleBar.ButtonForegroundColor = DesktopTheme.Color(Paint.Text);
        Application.Current.Resources["SystemAccentColor"] = DesktopTheme.Color(Paint.Accent);
        foreach (var (key, role) in new[]
        {
            ("AccentFillColorDefaultBrush", Paint.Accent), ("AccentTextFillColorPrimaryBrush", Paint.Accent),
            ("ContentDialogBackground", Paint.Surface), ("ContentDialogBorderBrush", Paint.ButtonBorder),
            ("TextControlBackgroundFocused", Paint.Input), ("TextControlBackgroundPointerOver", Paint.InputHover),
            ("TextControlForegroundFocused", Paint.Text), ("TextControlBorderBrushFocused", Paint.Accent),
            ("ButtonBackgroundDisabled", Paint.Disabled), ("ButtonForegroundDisabled", Paint.DisabledText)
        }) Application.Current.Resources[key] = Brush(role);
        if (persist) SaveSettings();
    }
}
