// HuWin.cs —— win-use-master 的 Windows 助手层。
//
// 设计目标：
//   1. 读操作尽量不碰前台焦点（EnumWindows / PrintWindow / 像素判据）。
//   2. 写操作明确走 SendInput，并把 Windows 特有的前台限制、UIPI 和锁屏状态暴露给调用方。
//   3. 所有 public API 都保持为 PowerShell Add-Type / 预编译 DLL 容易调用的简单静态方法。
//
// 本文件刻意只依赖 System、System.Drawing 和 Windows 自带 DLL；HUD 不依赖 WinForms/WPF。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class HuWin
{
    // ---------------------------------------------------------------------
    // Native types and APIs
    // ---------------------------------------------------------------------

    public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);
    private delegate IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int L, T, R, B;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X, Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr extra;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr extra;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT m;
        [FieldOffset(0)] public KEYBDINPUT k;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_MANDATORY_LABEL
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public uint cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public uint cbSize;
        public uint style;
        public WindowProc lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PAINTSTRUCT
    {
        public IntPtr hdc;
        public int fErase;
        public RECT rcPaint;
        public int fRestore;
        public int fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public byte[] rgbReserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
        public uint lPrivate;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RTL_OSVERSIONINFO
    {
        public uint dwOSVersionInfoSize;
        public uint dwMajorVersion;
        public uint dwMinorVersion;
        public uint dwBuildNumber;
        public uint dwPlatformId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szCSDVersion;
    }

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwarenessContext")] private static extern bool NativeSetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll", EntryPoint = "SetProcessDpiAwareness")] private static extern int NativeSetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsHungAppWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr SetActiveWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "SetCursorPos")] private static extern bool NativeSetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] private static extern bool SwitchDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetDpiForWindow")] private static extern uint NativeGetDpiForWindow(IntPtr hwnd);
    [DllImport("shcore.dll", EntryPoint = "GetDpiForMonitor")] private static extern int NativeGetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", EntryPoint = "GetTickCount64")] private static extern ulong NativeGetTickCount64();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string moduleName);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, uint length, out uint returnLength);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll")] private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("ntdll.dll")] private static extern int RtlGetVersion(ref RTL_OSVERSIONINFO version);

    // HUD-only Win32 APIs.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClassEx(ref WNDCLASSEX cls);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int exitCode);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern UIntPtr SetTimer(IntPtr hwnd, UIntPtr id, uint milliseconds, IntPtr callback);
    [DllImport("user32.dll")] private static extern bool KillTimer(IntPtr hwnd, UIntPtr id);
    [DllImport("user32.dll")] private static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);
    [DllImport("user32.dll")] private static extern bool UpdateWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr BeginPaint(IntPtr hwnd, out PAINTSTRUCT paint);
    [DllImport("user32.dll")] private static extern bool EndPaint(IntPtr hwnd, ref PAINTSTRUCT paint);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint colorKey, byte alpha, uint flags);

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;
    public const int DWMWA_CLOAKED = 14;
    public const int GWL_STYLE = -16;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000;
    public const int TokenIntegrityLevel = 25;

    private const uint PW_RENDERFULLCONTENT = 0x00000002;
    private const uint GA_ROOT = 2;
    private const int SW_SHOW = 5;
    private const int SW_RESTORE = 9;
    private const int SW_SHOWNOACTIVATE = 4;
    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;
    private const uint DESKTOP_SWITCHDESKTOP = 0x0100;
    private const uint TOKEN_QUERY = 0x0008;
    private static readonly string SyntheticTrailPath = Path.Combine(Path.GetTempPath(), "win-use-master.synthetic.trail");

    static HuWin()
    {
        EnsureDpiAware();
    }

    // Must run before the first coordinate API. It is best effort because a host process
    // is allowed to choose DPI awareness before this DLL is loaded.
    public static bool EnsureDpiAware()
    {
        try
        {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            if (NativeSetProcessDpiAwarenessContext(new IntPtr(-4))) return true;
        }
        catch (EntryPointNotFoundException) { }
        catch (DllNotFoundException) { }

        try
        {
            // PROCESS_PER_MONITOR_DPI_AWARE
            if (NativeSetProcessDpiAwareness(2) == 0) return true;
        }
        catch (EntryPointNotFoundException) { }
        catch (DllNotFoundException) { }

        try { return SetProcessDPIAware(); }
        catch { return false; }
    }

    // ---------------------------------------------------------------------
    // Windows and screens
    // ---------------------------------------------------------------------

    public class WinInfo
    {
        public long Hwnd;
        public uint Pid;
        public string Owner;
        public string Title;
        public string Cls;
        public int L, T, R, B;
        public bool Visible, Iconic, Zoomed, Cloaked, Tool, Hung;

        public int W { get { return R - L; } }
        public int H { get { return B - T; } }
    }

    public class ScreenInfo
    {
        public int X, Y, W, H;
        public int L, T, R, B;
        public bool Primary;

        public override string ToString()
        {
            return String.Format("{0},{1} {2}x{3}{4}", X, Y, W, H, Primary ? " primary" : "");
        }
    }

    private static WinInfo BuildWindowInfo(IntPtr hwnd)
    {
        var w = new WinInfo();
        w.Hwnd = hwnd.ToInt64();

        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        w.Pid = pid;
        w.Owner = "?";
        try
        {
            using (Process process = Process.GetProcessById((int)pid))
                w.Owner = process.ProcessName;
        }
        catch { }

        int titleLength = 0;
        try { titleLength = GetWindowTextLength(hwnd); }
        catch { }
        titleLength = Math.Max(256, Math.Min(32767, titleLength + 1));
        var title = new StringBuilder(titleLength);
        try { GetWindowText(hwnd, title, title.Capacity); }
        catch { }
        w.Title = title.ToString();

        var cls = new StringBuilder(256);
        try { GetClassName(hwnd, cls, cls.Capacity); }
        catch { }
        w.Cls = cls.ToString();

        RECT rect;
        if (GetWindowRect(hwnd, out rect))
        {
            w.L = rect.L; w.T = rect.T; w.R = rect.R; w.B = rect.B;
        }

        w.Visible = IsWindowVisible(hwnd);
        w.Iconic = IsIconic(hwnd);
        w.Zoomed = IsZoomed(hwnd);
        w.Hung = IsHungAppWindow(hwnd);
        int cloaked = 0;
        try { DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out cloaked, sizeof(int)); }
        catch { cloaked = 0; }
        w.Cloaked = cloaked != 0;
        w.Tool = (GetWindowLong(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0;
        return w;
    }

    // Enumerates facts for every top-level window. Filtering remains a policy decision
    // for the PowerShell layer (hidden/tool/cloaked windows can be diagnostically useful).
    public static List<WinInfo> AllWindows()
    {
        var result = new List<WinInfo>();
        EnumProc callback = delegate(IntPtr hwnd, IntPtr ignored)
        {
            try { result.Add(BuildWindowInfo(hwnd)); }
            catch { /* Never let one disappearing window abort the native enumeration. */ }
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return result;
    }

    public static ScreenInfo GetVirtualScreen()
    {
        int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (width <= 0 || height <= 0)
        {
            x = 0; y = 0;
            width = GetSystemMetrics(SM_CXSCREEN);
            height = GetSystemMetrics(SM_CYSCREEN);
        }
        var screen = new ScreenInfo();
        screen.X = screen.L = x;
        screen.Y = screen.T = y;
        screen.W = width;
        screen.H = height;
        screen.R = x + width;
        screen.B = y + height;
        screen.Primary = true;
        return screen;
    }

    // Friendly alias for interactive PowerShell use.
    public static ScreenInfo VirtualScreen()
    {
        return GetVirtualScreen();
    }

    public static List<ScreenInfo> AllScreens()
    {
        var result = new List<ScreenInfo>();
        MonitorEnumProc callback = delegate(IntPtr monitor, IntPtr hdc, ref RECT ignored, IntPtr data)
        {
            var info = new MONITORINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(monitor, ref info))
            {
                var s = new ScreenInfo();
                s.L = s.X = info.rcMonitor.L;
                s.T = s.Y = info.rcMonitor.T;
                s.R = info.rcMonitor.R;
                s.B = info.rcMonitor.B;
                s.W = s.R - s.L;
                s.H = s.B - s.T;
                s.Primary = (info.dwFlags & 1) != 0;
                result.Add(s);
            }
            return true;
        };

        try { EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero); }
        catch { }
        GC.KeepAlive(callback);

        if (result.Count == 0) result.Add(GetVirtualScreen());
        result.Sort(delegate(ScreenInfo a, ScreenInfo b)
        {
            if (a.Primary != b.Primary) return a.Primary ? -1 : 1;
            int byX = a.X.CompareTo(b.X);
            return byX != 0 ? byX : a.Y.CompareTo(b.Y);
        });
        return result;
    }

    // ---------------------------------------------------------------------
    // Capture and image diagnostics
    // ---------------------------------------------------------------------

    private static bool IsSaneBitmapSize(int width, int height)
    {
        if (width <= 0 || height <= 0 || width > 32767 || height > 32767) return false;
        return (long)width * (long)height <= 100000000L;
    }

    private static void EnsureOutputDirectory(string path)
    {
        string full = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(full);
        if (!String.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            Directory.CreateDirectory(directory);
    }

    private static bool CaptureWithPrintWindow(IntPtr hwnd, Bitmap bitmap, uint flags)
    {
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Black);
            IntPtr dc = IntPtr.Zero;
            try
            {
                dc = graphics.GetHdc();
                return PrintWindow(hwnd, dc, flags);
            }
            finally
            {
                if (dc != IntPtr.Zero) graphics.ReleaseHdc(dc);
            }
        }
    }

    private static int BitmapColorCount(Bitmap bitmap, int step, int stopAfter)
    {
        var seen = new HashSet<int>();
        int x0 = bitmap.Width * 8 / 100;
        int x1 = bitmap.Width - x0;
        int y0 = bitmap.Height * 18 / 100;
        int y1 = bitmap.Height - bitmap.Height * 8 / 100;
        if (x1 <= x0 || y1 <= y0)
        {
            x0 = y0 = 0; x1 = bitmap.Width; y1 = bitmap.Height;
        }
        step = Math.Max(1, step);
        for (int y = y0; y < y1; y += step)
        {
            for (int x = x0; x < x1; x += step)
            {
                Color color = bitmap.GetPixel(x, y);
                int bucket = ((color.R >> 4) << 8) | ((color.G >> 4) << 4) | (color.B >> 4);
                seen.Add(bucket);
                if (stopAfter > 0 && seen.Count >= stopAfter) return seen.Count;
            }
        }
        return seen.Count;
    }

    // Captures a top-level window's own render surface without foregrounding it.
    // null means invalid/minimized/failed. A non-null image can still be blank for
    // protected, hardware-overlay, sandboxed or deliberately non-rendering windows;
    // ColorCount/LooksBlank is the explicit diagnostic for that case.
    public static Size? ShotWindow(long hwnd, string path)
    {
        IntPtr window = new IntPtr(hwnd);
        if (String.IsNullOrEmpty(path) || !IsWindow(window) || IsIconic(window)) return null;

        RECT rect;
        if (!GetWindowRect(window, out rect)) return null;
        int width = rect.R - rect.L;
        int height = rect.B - rect.T;
        if (!IsSaneBitmapSize(width, height)) return null;

        // A DPI-unaware/system-aware target paints PrintWindow into a 96/system-DPI
        // HDC while DWM reports its scaled physical rectangle. Allocating the physical
        // size then produces a valid image in the upper-left plus a black right/bottom
        // gutter. Capture at the target's logical size; callers already map screenshot
        // pixels back to the physical window rectangle.
        double scale = PrintWindowScale(window);
        int captureWidth = Math.Max(1, (int)Math.Ceiling(width / scale));
        int captureHeight = Math.Max(1, (int)Math.Ceiling(height / scale));
        if (!IsSaneBitmapSize(captureWidth, captureHeight)) return null;

        try
        {
            using (var first = new Bitmap(captureWidth, captureHeight, PixelFormat.Format24bppRgb))
            {
                bool firstOk = CaptureWithPrintWindow(window, first, PW_RENDERFULLCONTENT);
                int firstColors = firstOk ? BitmapColorCount(first, Math.Max(1, captureWidth / 160), 4) : 0;

                // A few legacy windows reject PW_RENDERFULLCONTENT. If the first frame
                // failed or is nearly monochrome, retry the documented default flag and
                // retain whichever frame has more information.
                if (!firstOk || firstColors < 3)
                {
                    using (var fallback = new Bitmap(captureWidth, captureHeight, PixelFormat.Format24bppRgb))
                    {
                        bool fallbackOk = CaptureWithPrintWindow(window, fallback, 0);
                        int fallbackColors = fallbackOk ? BitmapColorCount(fallback, Math.Max(1, captureWidth / 160), 4) : 0;
                        if (fallbackOk && (!firstOk || fallbackColors > firstColors))
                        {
                            EnsureOutputDirectory(path);
                            fallback.Save(path, ImageFormat.Png);
                            return new Size(captureWidth, captureHeight);
                        }
                    }
                }

                if (!firstOk) return null;
                EnsureOutputDirectory(path);
                first.Save(path, ImageFormat.Png);
                return new Size(captureWidth, captureHeight);
            }
        }
        catch
        {
            return null;
        }
    }

    // PrintWindow calls into the target process and a hung provider can block the
    // caller indefinitely. Run the capture on a background worker and publish the
    // completed file only when it finishes inside the deadline. A timed-out worker
    // writes only to its unique temp path, which is removed if it ever returns.
    public static Size? ShotWindowTimed(long hwnd, string path, int timeoutMs)
    {
        if (timeoutMs <= 0) return ShotWindow(hwnd, path);
        string temp = Path.Combine(Path.GetTempPath(),
            "win-use-master-printwindow-" + Guid.NewGuid().ToString("N") + ".png");
        Task<Size?> task = Task.Run<Size?>(delegate { return ShotWindow(hwnd, temp); });
        try
        {
            if (!task.Wait(timeoutMs))
            {
                task.ContinueWith(delegate(Task<Size?> ignored)
                {
                    try { if (File.Exists(temp)) File.Delete(temp); }
                    catch { }
                }, TaskScheduler.Default);
                return null;
            }

            Size? result = task.Result;
            if (result == null || !File.Exists(temp)) return null;
            EnsureOutputDirectory(path);
            File.Copy(temp, path, true);
            return result;
        }
        catch { return null; }
        finally
        {
            if (task.IsCompleted)
            {
                try { if (File.Exists(temp)) File.Delete(temp); }
                catch { }
            }
        }
    }

    private static double PrintWindowScale(IntPtr window)
    {
        try
        {
            uint windowDpi = NativeGetDpiForWindow(window);
            if (windowDpi == 0) windowDpi = 96;
            IntPtr monitor = MonitorFromWindow(window, 2); // MONITOR_DEFAULTTONEAREST
            if (monitor == IntPtr.Zero) return 1.0;
            uint monitorX, monitorY;
            if (NativeGetDpiForMonitor(monitor, 0, out monitorX, out monitorY) != 0 || monitorX == 0)
                return 1.0;
            double scale = monitorX / (double)windowDpi;
            return scale > 1.01 && scale < 4.01 ? scale : 1.0;
        }
        catch (EntryPointNotFoundException) { return 1.0; }
        catch (DllNotFoundException) { return 1.0; }
        catch { return 1.0; }
    }

    public static uint WindowDpi(long hwnd)
    {
        try
        {
            uint value = NativeGetDpiForWindow(new IntPtr(hwnd));
            return value == 0 ? 96u : value;
        }
        catch { return 96; }
    }

    public static uint MonitorDpi(long hwnd)
    {
        try
        {
            IntPtr monitor = MonitorFromWindow(new IntPtr(hwnd), 2);
            uint x, y;
            if (monitor != IntPtr.Zero && NativeGetDpiForMonitor(monitor, 0, out x, out y) == 0 && x != 0)
                return x;
        }
        catch { }
        return 96;
    }

    public static double PrintWindowScale(long hwnd)
    {
        return PrintWindowScale(new IntPtr(hwnd));
    }

    // w/h <= 0 means the complete virtual desktop, including monitors with negative
    // coordinates. CopyFromScreen captures what is actually visible, not hidden pixels.
    public static Size ShotScreen(string path, int x, int y, int width, int height)
    {
        if (width <= 0 || height <= 0)
        {
            ScreenInfo virtualScreen = GetVirtualScreen();
            x = virtualScreen.X; y = virtualScreen.Y;
            width = virtualScreen.W; height = virtualScreen.H;
        }
        if (!IsSaneBitmapSize(width, height))
            throw new ArgumentOutOfRangeException("width", "Invalid or excessively large capture rectangle.");

        using (var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb))
        {
            using (Graphics graphics = Graphics.FromImage(bitmap))
                graphics.CopyFromScreen(x, y, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);
            EnsureOutputDirectory(path);
            bitmap.Save(path, ImageFormat.Png);
        }
        return new Size(width, height);
    }

    public static Size ShotScreen(string path)
    {
        return ShotScreen(path, 0, 0, 0, 0);
    }

    // Writes a PNG whose width is at most maxWidth (never upscales), preserving aspect.
    // Encoding finishes in memory before output is replaced, so path == outputPath works.
    public static Size? ResizePng(string path, string outputPath, int maxWidth)
    {
        if (String.IsNullOrEmpty(path) || String.IsNullOrEmpty(outputPath) || maxWidth <= 0 || !File.Exists(path))
            return null;
        try
        {
            Bitmap source;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (Image image = Image.FromStream(stream, true, true))
                source = new Bitmap(image);

            using (source)
            {
                if (source.Width <= 0 || source.Height <= 0) return null;
                int width = Math.Min(maxWidth, source.Width);
                int height = Math.Max(1, (int)Math.Round(source.Height * (double)width / source.Width));
                using (var resized = new Bitmap(width, height, PixelFormat.Format24bppRgb))
                {
                    using (Graphics graphics = Graphics.FromImage(resized))
                    {
                        graphics.CompositingMode = CompositingMode.SourceCopy;
                        graphics.CompositingQuality = CompositingQuality.HighQuality;
                        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        graphics.SmoothingMode = SmoothingMode.HighQuality;
                        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        graphics.DrawImage(source, new Rectangle(0, 0, width, height), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel);
                    }
                    using (var encoded = new MemoryStream())
                    {
                        resized.Save(encoded, ImageFormat.Png);
                        EnsureOutputDirectory(outputPath);
                        File.WriteAllBytes(outputPath, encoded.ToArray());
                    }
                }
                return new Size(width, height);
            }
        }
        catch
        {
            return null;
        }
    }

    // Quantized RGB color diversity after cropping decorations. Returns -1 on decode
    // failure. Unlike the old implementation this really uses R/G/B (not Alpha+R).
    public static int ColorCount(string path, int sampleWidth)
    {
        if (String.IsNullOrEmpty(path) || !File.Exists(path)) return -1;
        if (sampleWidth <= 0) sampleWidth = 64;
        try
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (Image image = Image.FromStream(stream, true, true))
            {
                int width = Math.Max(1, Math.Min(sampleWidth, image.Width));
                int height = Math.Max(1, (int)Math.Round(image.Height * (double)width / image.Width));
                using (var small = new Bitmap(width, height, PixelFormat.Format24bppRgb))
                {
                    using (Graphics graphics = Graphics.FromImage(small))
                    {
                        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        graphics.DrawImage(image, 0, 0, width, height);
                    }
                    return BitmapColorCount(small, 1, 0);
                }
            }
        }
        catch
        {
            return -1;
        }
    }

    public static bool LooksBlank(string path)
    {
        int colors = ColorCount(path, 64);
        return colors < 6;
    }

    private static Bitmap Downsample(string path, int requestedWidth)
    {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (Image image = Image.FromStream(stream, true, true))
        {
            int width = Math.Max(1, Math.Min(requestedWidth, image.Width));
            int height = Math.Max(1, (int)Math.Round(image.Height * (double)width / image.Width));
            var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb);
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.DrawImage(image, 0, 0, width, height);
            }
            return bitmap;
        }
    }

    private static double Normalized(double value)
    {
        if (Double.IsNaN(value) || Double.IsInfinity(value)) return 0.5;
        if (value < 0) return 0;
        if (value > 1) return 1;
        return value;
    }

    // Compares the full image and a +/-12% neighborhood around the requested normalized
    // hit point. The cast intentionally occurs after multiplying by width/height.
    public static string DiffReport(string before, string after, double hitNx, double hitNy)
    {
        const int requestedWidth = 160;
        if (!File.Exists(before) || !File.Exists(after))
            return "  ⚠️ 差分不可用（前后有一张没截成）";

        Bitmap first = null;
        Bitmap second = null;
        try
        {
            first = Downsample(before, requestedWidth);
            second = Downsample(after, requestedWidth);
            if (first.Width != second.Width || first.Height != second.Height)
                return "  ⚠️ 差分不可用（前后尺寸不一致）";

            int width = first.Width;
            int height = first.Height;
            double hitX = Normalized(hitNx);
            double hitY = Normalized(hitNy);
            int localX0 = Math.Max(0, (int)Math.Floor((hitX - 0.12) * width));
            int localX1 = Math.Min(width, (int)Math.Ceiling((hitX + 0.12) * width));
            int localY0 = Math.Max(0, (int)Math.Floor((hitY - 0.12) * height));
            int localY1 = Math.Min(height, (int)Math.Ceiling((hitY + 0.12) * height));
            if (localX1 <= localX0) localX1 = Math.Min(width, localX0 + 1);
            if (localY1 <= localY0) localY1 = Math.Min(height, localY0 + 1);

            int changed = 0, localChanged = 0, localTotal = 0;
            int minX = width, maxX = -1, minY = height, maxY = -1;
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    Color a = first.GetPixel(x, y);
                    Color b = second.GetPixel(x, y);
                    int difference = Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);
                    bool local = x >= localX0 && x < localX1 && y >= localY0 && y < localY1;
                    if (local) localTotal++;
                    if (difference > 24)
                    {
                        changed++;
                        if (local) localChanged++;
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            if (changed == 0)
                return "  effect=suspected_noop 全窗 0% 变化。按可能性：①坐标没落在控件上 ②窗口没真正激活 ③控件不响应合成事件 ④截图早于刷新";

            double percent = changed * 100.0 / (width * height);
            double localPercent = localTotal > 0 ? localChanged * 100.0 / localTotal : 0;
            string tail;
            if (localPercent < 1.0)
            {
                tail = String.Format("\n  effect=suspected_noop 落点几乎没变，全窗变化集中在 ({0:F2},{1:F2})，多半是 app 自己的动画",
                    (minX + maxX) / 2.0 / width, (minY + maxY) / 2.0 / height);
            }
            else if (localPercent < 8.0)
                tail = "\n  effect=partial 落点变化很小，可能只是焦点高亮/光标。看截图坐实";
            else
                tail = "\n  effect=confirmed 落点确实变了。仍需确认变的是「文字进去」不是「弹出了别的东西」";

            return String.Format("  📍 落点邻域(±12%) 变化 {0:F1}%  |  全窗 {1:F1}%", localPercent, percent) + tail;
        }
        catch
        {
            return "  ⚠️ 差分不可用（解码失败）";
        }
        finally
        {
            if (first != null) first.Dispose();
            if (second != null) second.Dispose();
        }
    }

    // ---------------------------------------------------------------------
    // User presence, foreground activation and input
    // ---------------------------------------------------------------------

    private static bool LastInput(out LASTINPUTINFO info, out double seconds)
    {
        info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        seconds = -1;
        if (!GetLastInputInfo(ref info)) return false;

        uint now;
        try { now = unchecked((uint)NativeGetTickCount64()); }
        catch { now = unchecked((uint)Environment.TickCount); }
        uint elapsed = unchecked(now - info.dwTime); // wrap-safe for the 32-bit native timestamp
        seconds = elapsed / 1000.0;
        return true;
    }

    // Seconds since the last keyboard/mouse event in this interactive session,
    // including SendInput and cursor restoration performed by this tool.
    public static double IdleSeconds()
    {
        LASTINPUTINFO info;
        double seconds;
        return LastInput(out info, out seconds) ? seconds : -1;
    }

    private static void WriteSyntheticTrail(uint inputTick)
    {
        try
        {
            File.WriteAllText(SyntheticTrailPath,
                inputTick.ToString() + "|" + DateTime.UtcNow.Ticks.ToString(), Encoding.ASCII);
        }
        catch { }
    }

    private static void MarkSyntheticInput()
    {
        LASTINPUTINFO info;
        double ignored;
        if (LastInput(out info, out ignored)) WriteSyntheticTrail(info.dwTime);
    }

    // GetLastInputInfo exposes the exact native timestamp of the most recent input.
    // If it still equals the timestamp recorded immediately after our SendInput, no
    // human input occurred afterwards. This exact equality is safer than comparing
    // approximate wall-clock ages and avoids a two-second self-throttle between
    // consecutive win-use-master commands.
    public static double UserIdleSeconds()
    {
        LASTINPUTINFO info;
        double seconds;
        if (!LastInput(out info, out seconds)) return -1;
        try
        {
            string[] parts = File.ReadAllText(SyntheticTrailPath, Encoding.ASCII).Trim().Split('|');
            uint inputTick;
            long markedTicks;
            if (parts.Length == 2 && UInt32.TryParse(parts[0], out inputTick) &&
                Int64.TryParse(parts[1], out markedTicks))
            {
                double age = (DateTime.UtcNow - new DateTime(markedTicks, DateTimeKind.Utc)).TotalSeconds;
                if (age >= 0 && age < 10 && info.dwTime == inputTick) return 3600;
            }
        }
        catch { }
        return seconds;
    }

    public static bool SetCursorPos(int x, int y)
    {
        LASTINPUTINFO before;
        double ignored;
        bool hadBefore = LastInput(out before, out ignored);
        bool moved = NativeSetCursorPos(x, y);
        LASTINPUTINFO after;
        if (moved && LastInput(out after, out ignored) && (!hadBefore || after.dwTime != before.dwTime))
            WriteSyntheticTrail(after.dwTime);
        return moved;
    }

    public static IntPtr ForegroundWindow()
    {
        return GetForegroundWindow();
    }

    private static bool IsForegroundFor(IntPtr requestedRoot, IntPtr activated)
    {
        IntPtr foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero) return false;
        if (foreground == activated || foreground == requestedRoot) return true;
        IntPtr foregroundRoot = GetAncestor(foreground, GA_ROOT);
        return foregroundRoot == requestedRoot;
    }

    public static bool RestoreWindow(long hwnd)
    {
        IntPtr window = new IntPtr(hwnd);
        if (!IsWindow(window)) return false;
        if (IsIconic(window)) ShowWindowAsync(window, SW_RESTORE);
        else if (!IsWindowVisible(window)) ShowWindowAsync(window, SW_SHOW);
        for (int i = 0; i < 20 && IsIconic(window); i++) Thread.Sleep(20);
        return !IsIconic(window);
    }

    public static bool ActivateWindow(long hwnd)
    {
        return ActivateWindow(hwnd, 750);
    }

    // Best-effort foreground activation under Windows' foreground-stealing rules.
    // It restores minimized windows, temporarily joins input queues, and uses one Alt
    // pulse only when the normal path failed. The actual foreground HWND is verified.
    public static bool ActivateWindow(long hwnd, int timeoutMs)
    {
        IntPtr original = new IntPtr(hwnd);
        if (!IsWindow(original)) return false;
        IntPtr root = GetAncestor(original, GA_ROOT);
        if (root == IntPtr.Zero) root = original;
        RestoreWindow(root.ToInt64());

        IntPtr target = GetLastActivePopup(root);
        if (target == IntPtr.Zero || !IsWindow(target) || !IsWindowVisible(target)) target = root;
        if (IsForegroundFor(root, target)) return true;

        uint ignoredPid;
        uint targetThread = GetWindowThreadProcessId(target, out ignoredPid);
        IntPtr oldForeground = GetForegroundWindow();
        uint foregroundThread = oldForeground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(oldForeground, out ignoredPid);
        uint currentThread = GetCurrentThreadId();
        bool attachedForeground = false;
        bool attachedTarget = false;

        try
        {
            if (foregroundThread != 0 && foregroundThread != currentThread)
                attachedForeground = AttachThreadInput(currentThread, foregroundThread, true);
            if (targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread)
                attachedTarget = AttachThreadInput(currentThread, targetThread, true);

            BringWindowToTop(target);
            SetWindowPos(target, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); // NOSIZE|NOMOVE|NOACTIVATE
            SetActiveWindow(target);
            SetFocus(target);
            SetForegroundWindow(target);
        }
        finally
        {
            if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
        }

        int wait = Math.Max(0, Math.Min(timeoutMs, 5000));
        Stopwatch clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < Math.Min(wait, 300))
        {
            if (IsForegroundFor(root, target)) return true;
            Thread.Sleep(15);
        }

        // SetForegroundWindow is intentionally rate-limited by Windows. A synthetic Alt
        // tap is the least invasive conventional unlock and is only used after failure.
        INPUT[] alt = new INPUT[2];
        alt[0] = MakeKeyInput(0x12, 0);
        alt[1] = MakeKeyInput(0x12, KEYEVENTF_KEYUP);
        if (SendInput(2, alt, Marshal.SizeOf(typeof(INPUT))) > 0) MarkSyntheticInput();
        SetForegroundWindow(target);
        BringWindowToTop(target);

        while (clock.ElapsedMilliseconds < wait)
        {
            if (IsForegroundFor(root, target)) return true;
            Thread.Sleep(15);
        }
        return IsForegroundFor(root, target);
    }

    public static POINT GetCursor()
    {
        POINT point;
        if (!GetCursorPos(out point)) { point.X = 0; point.Y = 0; }
        return point;
    }

    public static WinInfo WindowAtPoint(int x, int y)
    {
        var point = new POINT(); point.X = x; point.Y = y;
        IntPtr child = WindowFromPoint(point);
        if (child == IntPtr.Zero) return null;
        IntPtr root = GetAncestor(child, GA_ROOT);
        if (root == IntPtr.Zero) root = child;
        try { return BuildWindowInfo(root); }
        catch { return null; }
    }

    public static uint MouseClick(int x, int y, bool right)
    {
        if (!SetCursorPos(x, y)) return 0;
        Thread.Sleep(40);
        var inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].u.m.dwFlags = right ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
        inputs[1].type = INPUT_MOUSE;
        inputs[1].u.m.dwFlags = right ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP;
        uint sent = SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent > 0) MarkSyntheticInput();
        return sent;
    }

    public static bool MouseMove(int x, int y)
    {
        return SetCursorPos(x, y);
    }

    public static uint MouseWheel(int x, int y, int delta, int steps)
    {
        if (!SetCursorPos(x, y) || steps == 0) return 0;
        if (steps < 0)
        {
            if (steps == Int32.MinValue) return 0;
            steps = -steps;
            delta = -delta;
        }
        if (delta == 0) delta = 120;
        steps = Math.Min(steps, 1000);
        Thread.Sleep(50);

        uint sent = 0;
        for (int i = 0; i < steps; i++)
        {
            var input = new INPUT[1];
            input[0].type = INPUT_MOUSE;
            input[0].u.m.dwFlags = MOUSEEVENTF_WHEEL;
            input[0].u.m.mouseData = unchecked((uint)delta);
            sent += SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
            if (i + 1 < steps) Thread.Sleep(35);
        }
        if (sent > 0) MarkSyntheticInput();
        return sent;
    }

    private static INPUT MakeKeyInput(ushort vk, uint flags)
    {
        var input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.u.k.wVk = vk;
        input.u.k.dwFlags = flags;
        return input;
    }

    private static bool IsExtendedKey(ushort vk)
    {
        switch (vk)
        {
            case 0x21: case 0x22: case 0x23: case 0x24: // PgUp/PgDn/End/Home
            case 0x25: case 0x26: case 0x27: case 0x28: // arrows
            case 0x2D: case 0x2E: case 0x5B: case 0x5C: // Insert/Delete/Win
            case 0x6F: case 0x90: case 0xA3: case 0xA5: // Divide/NumLock/R-Ctrl/R-Alt
                return true;
            default:
                return false;
        }
    }

    private static bool KeyIsDown(ushort vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    // KEYEVENTF_UNICODE sends UTF-16 code units independent of the keyboard layout.
    // Surrogate pairs are intentionally emitted as their two UTF-16 units.
    public static uint TypeUnicode(string text)
    {
        if (String.IsNullOrEmpty(text)) return 0;
        uint sent = 0;
        foreach (char character in text)
        {
            var inputs = new INPUT[2];
            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].u.k.wScan = character;
            inputs[0].u.k.dwFlags = KEYEVENTF_UNICODE;
            inputs[1].type = INPUT_KEYBOARD;
            inputs[1].u.k.wScan = character;
            inputs[1].u.k.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            sent += SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
            Thread.Sleep(8);
        }
        if (sent > 0) MarkSyntheticInput();
        return sent;
    }

    // Sends modifiers down, the key down/up, then modifiers up in reverse order.
    // A physically-held modifier is not released. The win argument is fully honored.
    public static uint SendKey(ushort vk, bool ctrl, bool alt, bool shift, bool win)
    {
        var sequence = new List<INPUT>();
        var pressed = new List<ushort>();
        ushort[] wanted = new ushort[] { 0x11, 0x12, 0x10, 0x5B }; // Ctrl, Alt, Shift, LWin
        bool[] enabled = new bool[] { ctrl, alt, shift, win };

        for (int i = 0; i < wanted.Length; i++)
        {
            if (enabled[i] && !KeyIsDown(wanted[i]))
            {
                uint modifierFlags = IsExtendedKey(wanted[i]) ? KEYEVENTF_EXTENDEDKEY : 0;
                sequence.Add(MakeKeyInput(wanted[i], modifierFlags));
                pressed.Add(wanted[i]);
            }
        }

        uint keyFlags = IsExtendedKey(vk) ? KEYEVENTF_EXTENDEDKEY : 0;
        sequence.Add(MakeKeyInput(vk, keyFlags));
        sequence.Add(MakeKeyInput(vk, keyFlags | KEYEVENTF_KEYUP));

        for (int i = pressed.Count - 1; i >= 0; i--)
        {
            uint modifierFlags = IsExtendedKey(pressed[i]) ? KEYEVENTF_EXTENDEDKEY : 0;
            sequence.Add(MakeKeyInput(pressed[i], modifierFlags | KEYEVENTF_KEYUP));
        }
        INPUT[] inputs = sequence.ToArray();
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent > 0) MarkSyntheticInput();
        return sent;
    }

    // ---------------------------------------------------------------------
    // Locked desktop and UIPI integrity
    // ---------------------------------------------------------------------

    // The secure/locked desktop cannot be opened/switched to from the normal user
    // desktop. Services and unusual window stations can therefore conservatively get
    // true as well, which is the safe answer before attempting UI automation.
    public static bool ScreenLocked()
    {
        IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
        if (desktop == IntPtr.Zero) return true;
        try { return !SwitchDesktop(desktop); }
        finally { CloseDesktop(desktop); }
    }

    public static uint IntegrityLevel(uint pid)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero) return 0;
        IntPtr token = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) return 0;
            return TokenLevel(token);
        }
        finally
        {
            if (token != IntPtr.Zero) CloseHandle(token);
            CloseHandle(process);
        }
    }

    public static uint SelfIntegrity()
    {
        IntPtr token = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(Process.GetCurrentProcess().Handle, TOKEN_QUERY, out token)) return 0;
            return TokenLevel(token);
        }
        finally
        {
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    public static bool CanSendInputTo(uint pid)
    {
        uint own = SelfIntegrity();
        uint target = IntegrityLevel(pid);
        return own != 0 && target != 0 && own >= target;
    }

    public static string IntegrityName(uint level)
    {
        if (level == 0) return "unknown";
        if (level < 0x1000) return "untrusted";
        if (level < 0x2000) return "low";
        if (level < 0x3000) return "medium";
        if (level < 0x4000) return "high";
        if (level < 0x5000) return "system";
        return "protected";
    }

    private static uint TokenLevel(IntPtr token)
    {
        uint required;
        GetTokenInformation(token, TokenIntegrityLevel, IntPtr.Zero, 0, out required);
        if (required == 0 || required > 1024 * 1024) return 0;

        IntPtr buffer = Marshal.AllocHGlobal((int)required);
        try
        {
            if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, required, out required)) return 0;
            var label = (TOKEN_MANDATORY_LABEL)Marshal.PtrToStructure(buffer, typeof(TOKEN_MANDATORY_LABEL));
            if (label.Sid == IntPtr.Zero) return 0;
            IntPtr countPointer = GetSidSubAuthorityCount(label.Sid);
            if (countPointer == IntPtr.Zero) return 0;
            int count = Marshal.ReadByte(countPointer);
            if (count <= 0) return 0;
            IntPtr levelPointer = GetSidSubAuthority(label.Sid, (uint)(count - 1));
            if (levelPointer == IntPtr.Zero) return 0;
            return unchecked((uint)Marshal.ReadInt32(levelPointer));
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    // ---------------------------------------------------------------------
    // Asynchronous, non-activating HUD
    // ---------------------------------------------------------------------

    private const uint HUD_WS_POPUP = 0x80000000;
    private const uint HUD_WS_EX_TOPMOST = 0x00000008;
    private const uint HUD_WS_EX_TRANSPARENT = 0x00000020;
    private const uint HUD_WS_EX_LAYERED = 0x00080000;
    private const uint HUD_WS_EX_NOACTIVATE = 0x08000000;
    private const uint HUD_LWA_COLORKEY = 0x00000001;
    private const uint HUD_LWA_ALPHA = 0x00000002;
    private const uint WM_DESTROY = 0x0002;
    private const uint WM_PAINT = 0x000F;
    private const uint WM_TIMER = 0x0113;
    private const uint WM_MOUSEACTIVATE = 0x0021;
    private const uint WM_NCHITTEST = 0x0084;
    private const int HTTRANSPARENT = -1;
    private const int MA_NOACTIVATE = 3;
    private const uint HUD_COLOR_KEY = 0x00030201; // COLORREF for RGB(1,2,3)
    private static readonly Color HudTransparentColor = Color.FromArgb(1, 2, 3);
    private static readonly object HudSync = new object();
    private static readonly Dictionary<IntPtr, HudState> HudStates = new Dictionary<IntPtr, HudState>();
    private static readonly WindowProc HudWindowProc = HudWndProc;
    private static readonly string HudClassName = "Huashu.HuWin.Hud." + Process.GetCurrentProcess().Id;
    private static bool HudClassRegistered;
    private static int ExcludeCaptureSupport = -1;

    private class HudState
    {
        public int X, Y, Width, Height, Duration;
        public string Text;
        public Stopwatch Clock;
        public List<ScreenInfo> Screens;
    }

    // Starts a background message-loop thread and returns immediately. The window is
    // topmost, ToolWindow, NoActivate, layered and HTTRANSPARENT/WS_EX_TRANSPARENT.
    public static void ShowHud(int milliseconds, string text)
    {
        if (milliseconds <= 0) return;
        var state = new HudState();
        ScreenInfo virtualScreen = GetVirtualScreen();
        state.X = virtualScreen.X;
        state.Y = virtualScreen.Y;
        state.Width = virtualScreen.W;
        state.Height = virtualScreen.H;
        state.Duration = Math.Min(milliseconds, 600000);
        state.Text = SanitizeHudText(text);
        state.Screens = AllScreens();
        state.Clock = new Stopwatch();

        Thread thread = new Thread(delegate() { RunHud(state); });
        thread.IsBackground = true;
        thread.Name = "HuWin HUD";
        try { thread.SetApartmentState(ApartmentState.STA); }
        catch { }
        thread.Start();
    }

    public static void ShowHud(int milliseconds)
    {
        ShowHud(milliseconds, "win-use-master 正在接管屏幕");
    }

    private static string SanitizeHudText(string text)
    {
        if (String.IsNullOrEmpty(text)) return "win-use-master 正在接管屏幕";
        string cleaned = text.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ').Trim();
        if (cleaned.Length > 160) cleaned = cleaned.Substring(0, 160) + "…";
        return cleaned;
    }

    private static bool EnsureHudClass()
    {
        lock (HudSync)
        {
            if (HudClassRegistered) return true;
            var cls = new WNDCLASSEX();
            cls.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
            cls.lpfnWndProc = HudWindowProc;
            cls.hInstance = GetModuleHandle(null);
            cls.lpszClassName = HudClassName;
            ushort atom = RegisterClassEx(ref cls);
            int error = Marshal.GetLastWin32Error();
            if (atom == 0 && error != 1410) return false; // ERROR_CLASS_ALREADY_EXISTS
            HudClassRegistered = true;
            return true;
        }
    }

    private static void RunHud(HudState state)
    {
        IntPtr hwnd = IntPtr.Zero;
        try
        {
            if (!EnsureHudClass() || state.Width <= 0 || state.Height <= 0) return;
            uint exStyle = HUD_WS_EX_TOPMOST | HUD_WS_EX_TRANSPARENT | HUD_WS_EX_LAYERED |
                           HUD_WS_EX_NOACTIVATE | (uint)WS_EX_TOOLWINDOW;
            hwnd = CreateWindowEx(exStyle, HudClassName, String.Empty, HUD_WS_POPUP,
                state.X, state.Y, state.Width, state.Height, IntPtr.Zero, IntPtr.Zero,
                GetModuleHandle(null), IntPtr.Zero);
            if (hwnd == IntPtr.Zero) return;

            lock (HudSync) HudStates[hwnd] = state;
            state.Clock.Start();
            SetLayeredWindowAttributes(hwnd, HUD_COLOR_KEY, 235, HUD_LWA_COLORKEY | HUD_LWA_ALPHA);
            if (SupportsExcludeFromCapture()) SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            SetWindowPos(hwnd, new IntPtr(-1), state.X, state.Y, state.Width, state.Height,
                0x0010 | 0x0040); // SWP_NOACTIVATE | SWP_SHOWWINDOW
            InvalidateRect(hwnd, IntPtr.Zero, true);
            UpdateWindow(hwnd);
            SetTimer(hwnd, new UIntPtr(1), 40, IntPtr.Zero);

            MSG message;
            int result;
            while ((result = GetMessage(out message, IntPtr.Zero, 0, 0)) > 0)
            {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
        }
        catch
        {
            if (hwnd != IntPtr.Zero && IsWindow(hwnd)) DestroyWindow(hwnd);
        }
        finally
        {
            if (hwnd != IntPtr.Zero)
            {
                lock (HudSync) HudStates.Remove(hwnd);
            }
        }
    }

    private static IntPtr HudWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_NCHITTEST) return new IntPtr(HTTRANSPARENT);
        if (msg == WM_MOUSEACTIVATE) return new IntPtr(MA_NOACTIVATE);

        HudState state = null;
        lock (HudSync) HudStates.TryGetValue(hwnd, out state);

        if (msg == WM_TIMER && state != null)
        {
            if (state.Clock.ElapsedMilliseconds >= state.Duration)
            {
                KillTimer(hwnd, new UIntPtr(1));
                DestroyWindow(hwnd);
                return IntPtr.Zero;
            }
            double pulse = Math.Abs(Math.Sin(state.Clock.Elapsed.TotalSeconds * 5.0));
            byte alpha = (byte)(145 + 100 * pulse);
            SetLayeredWindowAttributes(hwnd, HUD_COLOR_KEY, alpha, HUD_LWA_COLORKEY | HUD_LWA_ALPHA);
            return IntPtr.Zero;
        }

        if (msg == WM_PAINT)
        {
            PAINTSTRUCT paint;
            IntPtr dc = BeginPaint(hwnd, out paint);
            try
            {
                if (dc != IntPtr.Zero && state != null) DrawHud(dc, state);
            }
            catch { }
            finally { EndPaint(hwnd, ref paint); }
            return IntPtr.Zero;
        }

        if (msg == WM_DESTROY)
        {
            lock (HudSync) HudStates.Remove(hwnd);
            PostQuitMessage(0);
            return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private static void DrawHud(IntPtr dc, HudState state)
    {
        using (Graphics graphics = Graphics.FromHdc(dc))
        {
            graphics.Clear(HudTransparentColor);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var glow = new Pen(Color.FromArgb(255, 235, 118, 46), 6.0f))
            using (var core = new Pen(Color.FromArgb(255, 255, 190, 80), 2.0f))
            {
                glow.StartCap = glow.EndCap = LineCap.Round;
                core.StartCap = core.EndCap = LineCap.Round;
                foreach (ScreenInfo screen in state.Screens)
                {
                    int left = screen.L - state.X + 20;
                    int top = screen.T - state.Y + 20;
                    int right = screen.R - state.X - 21;
                    int bottom = screen.B - state.Y - 21;
                    DrawHudCorners(graphics, glow, left, top, right, bottom, 58);
                    DrawHudCorners(graphics, core, left, top, right, bottom, 58);
                }
            }

            ScreenInfo labelScreen = state.Screens.Count > 0 ? state.Screens[0] : GetVirtualScreen();
            float labelX = labelScreen.L - state.X + 28;
            float labelY = labelScreen.T - state.Y + 30;
            Font font = null;
            try { font = new Font("Segoe UI", 12.0f, FontStyle.Bold, GraphicsUnit.Point); }
            catch { font = new Font(FontFamily.GenericSansSerif, 12.0f, FontStyle.Bold); }
            using (font)
            {
                SizeF measured = graphics.MeasureString(state.Text, font, Math.Max(100, labelScreen.W - 100));
                float boxWidth = Math.Min(Math.Max(180, measured.Width + 30), Math.Max(180, labelScreen.W - 56));
                float boxHeight = measured.Height + 18;
                using (GraphicsPath box = RoundedRectangle(new RectangleF(labelX, labelY, boxWidth, boxHeight), boxHeight / 2))
                using (var background = new SolidBrush(Color.FromArgb(245, 94, 43, 18)))
                using (var foreground = new SolidBrush(Color.White))
                {
                    graphics.FillPath(background, box);
                    graphics.DrawString(state.Text, font, foreground,
                        new RectangleF(labelX + 15, labelY + 8, boxWidth - 30, boxHeight - 10));
                }
            }
        }
    }

    private static void DrawHudCorners(Graphics graphics, Pen pen, int left, int top, int right, int bottom, int length)
    {
        if (right <= left || bottom <= top) return;
        graphics.DrawLine(pen, left, top, Math.Min(right, left + length), top);
        graphics.DrawLine(pen, left, top, left, Math.Min(bottom, top + length));
        graphics.DrawLine(pen, right, top, Math.Max(left, right - length), top);
        graphics.DrawLine(pen, right, top, right, Math.Min(bottom, top + length));
        graphics.DrawLine(pen, left, bottom, Math.Min(right, left + length), bottom);
        graphics.DrawLine(pen, left, bottom, left, Math.Max(top, bottom - length));
        graphics.DrawLine(pen, right, bottom, Math.Max(left, right - length), bottom);
        graphics.DrawLine(pen, right, bottom, right, Math.Max(top, bottom - length));
    }

    private static GraphicsPath RoundedRectangle(RectangleF rect, float radius)
    {
        float diameter = Math.Max(1, radius * 2);
        var path = new GraphicsPath();
        path.AddArc(rect.Left, rect.Top, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Top, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    private static bool SupportsExcludeFromCapture()
    {
        int cached = Volatile.Read(ref ExcludeCaptureSupport);
        if (cached >= 0) return cached == 1;
        bool supported = false;
        try
        {
            var version = new RTL_OSVERSIONINFO();
            version.dwOSVersionInfoSize = (uint)Marshal.SizeOf(typeof(RTL_OSVERSIONINFO));
            if (RtlGetVersion(ref version) == 0)
                supported = version.dwMajorVersion > 10 ||
                    (version.dwMajorVersion == 10 && version.dwBuildNumber >= 19041);
        }
        catch { }
        Interlocked.CompareExchange(ref ExcludeCaptureSupport, supported ? 1 : 0, -1);
        return supported;
    }
}
