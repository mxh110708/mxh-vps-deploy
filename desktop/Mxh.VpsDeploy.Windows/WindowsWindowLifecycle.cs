using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Mxh.VpsDeploy.Windows;

public static class WindowsWindowLifecycle
{
    // Window.Close destroys a WinUI window directly. WM_CLOSE follows the same
    // cancellable AppWindow.Closing path as its system close affordance.
    public static void RequestClose(nint ownWindow)
    {
        if (!PostMessageW(ownWindow, 0x0010, 0, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessageW(nint window, uint message, nuint wParam, nint lParam);
}
