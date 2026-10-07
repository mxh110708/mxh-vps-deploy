using Microsoft.UI.Xaml;
using Mxh.VpsDeploy.Core;

namespace Mxh.VpsDeploy.Desktop;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        Trace(args, "Entry");
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Trace(args, "ComWrappers");
        Application.Start(initialization =>
        {
            Trace(args, "Application.Start");
            SynchronizationContext.SetSynchronizationContext(
                new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(
                    Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()));
            _ = new DesktopApplication(args);
        });
    }
    internal static void Trace(string[] args, string message)
    {
        var index = Array.IndexOf(args, "--verify-runtime"); if(index < 0) index = Array.IndexOf(args, "--ui-smoke");
        if(index >= 0 && index + 1 < args.Length) File.AppendAllText(args[index + 1] + ".startup.txt", message + "\n");
    }
}

public sealed partial class DesktopApplication : Application
{
    private readonly string[] arguments;
    public DesktopApplication() : this([]) { }
    public DesktopApplication(string[] arguments)
    {
        this.arguments = arguments;
        UnhandledException += (_, error) => Program.Trace(arguments, "Unhandled: " + error.Exception);
        Program.Trace(arguments, "App ctor"); InitializeComponent(); Program.Trace(arguments, "App resources");
    }
    private MainWindow? window;
    private Window? startupErrorWindow;
    private Mutex? singleton;
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Program.Trace(arguments, "OnLaunched");
        var smoke = arguments.Contains("--ui-smoke") || arguments.Contains("--verify-runtime") || arguments.Contains("--verify-installed-update");
        var root = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var index = Array.IndexOf(arguments, "--app-root");
        if (index >= 0 && smoke) root = Path.GetFullPath(arguments[index + 1]);
        singleton = new Mutex(true, "Local\\mxh-vps-deploy-desktop" + (smoke ? "-qa-" + ArchiveStore.Digest(System.Text.Encoding.UTF8.GetBytes(root))[..12] : ""), out var acquired);
        if (!acquired) { Exit(); return; }
        try { window = new MainWindow(new AppPaths(root), arguments); }
        catch (Exception error)
        {
            Program.Trace(arguments, "Startup refused: " + error.GetType().Name);
            if (smoke) { Environment.ExitCode = 1; Exit(); return; }
            startupErrorWindow = new Window { Title = "MXH VPS Deploy", Content = new Microsoft.UI.Xaml.Controls.TextBlock { Text = error is OperationException safe ? safe.Message : "本地配置或运行环境无法读取。请核对应用目录，现有文件已保留。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(30), FontSize = 16 } }; startupErrorWindow.Activate(); return;
        }
        Program.Trace(arguments, "Window constructed");
        window.Activate();
        Program.Trace(arguments, "Window activated");
    }
}
