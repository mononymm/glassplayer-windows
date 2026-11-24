using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Glass.Player;

/// <summary>
/// Runs the user's own mpv (config, scripts, shaders and all) as a borderless window that sits exactly
/// over the app's player area and follows it. mpv gets mouse and keyboard input directly this way
/// (embedding with --wid cuts mpv off from input on Windows).
/// </summary>
public sealed class MpvPlayer
{
    Process? proc;
    NamedPipeClientStream? pipe;
    StreamWriter? writer;
    readonly string mpvPath;
    IntPtr hwnd;
    IntPtr owner;
    bool mpvFullscreen;
    (int x, int y, int w, int h) bounds;

    public event Action? Exited;
    public event Action<bool>? FullscreenChanged;
    public bool Running => proc is { HasExited: false };

    public MpvPlayer(string mpvPath) { this.mpvPath = mpvPath; }

    /// <param name="ownerHwnd">The app window; mpv stays above it and minimizes with it.</param>
    /// <param name="rect">Player area in screen pixels.</param>
    public void Play(IntPtr ownerHwnd, (int x, int y, int w, int h) rect, IReadOnlyList<string> files, int start, bool fromStart = false)
    {
        Stop();
        owner = ownerHwnd;
        bounds = rect;
        mpvFullscreen = false;
        var pipeName = "glass-desktop-" + Environment.ProcessId;
        var playlist = Path.Combine(Data.Settings.CacheDir, "playlist.m3u");
        Directory.CreateDirectory(Data.Settings.CacheDir);
        File.WriteAllLines(playlist, new[] { "#EXTM3U" }.Concat(files), new UTF8Encoding(false));

        var psi = new ProcessStartInfo(mpvPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(mpvPath) ?? "",
        };
        psi.ArgumentList.Add($"--input-ipc-server=\\\\.\\pipe\\{pipeName}");
        psi.ArgumentList.Add("--idle=no");
        psi.ArgumentList.Add("--keep-open=no");
        psi.ArgumentList.Add("--force-window=immediate");
        psi.ArgumentList.Add("--border=no");
        psi.ArgumentList.Add("--title-bar=no");
        psi.ArgumentList.Add("--fullscreen=no");
        psi.ArgumentList.Add("--snap-window=no");
        psi.ArgumentList.Add("--auto-window-resize=no");
        psi.ArgumentList.Add("--keepaspect-window=no");
        psi.ArgumentList.Add($"--geometry={rect.w}x{rect.h}+{rect.x}+{rect.y}");
        psi.ArgumentList.Add("--log-file=" + Path.Combine(Data.Settings.CacheDir, "mpv.log"));
        psi.ArgumentList.Add($"--playlist-start={start}");
        if (fromStart) psi.ArgumentList.Add("--start=0");   // tells the Glass script not to resume
        psi.ArgumentList.Add($"--playlist={playlist}");

        proc = Process.Start(psi);
        if (proc == null) return;
        proc.EnableRaisingEvents = true;
        var mine = proc;
        proc.Exited += (_, _) =>
        {
            if (!ReferenceEquals(mine, proc)) return;
            hwnd = IntPtr.Zero;
            CloseIpc();
            Exited?.Invoke();
        };
        _ = AttachWindowAsync(mine);
        _ = ConnectAsync(pipeName, mine);
    }

    /// <summary>Keep mpv's window on the player area (call when the app window moves or resizes).</summary>
    public void SetBounds((int x, int y, int w, int h) rect)
    {
        bounds = rect;
        if (hwnd == IntPtr.Zero || mpvFullscreen) return;
        SetWindowPos(hwnd, IntPtr.Zero, rect.x, rect.y, rect.w, rect.h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    public void Focus()
    {
        if (hwnd != IntPtr.Zero) SetForegroundWindow(hwnd);
    }

    /// <summary>Asks mpv to quit (so the Glass script saves the position), then forces it if it hangs.</summary>
    public void Stop()
    {
        var p = proc;
        proc = null;
        hwnd = IntPtr.Zero;
        if (p is { HasExited: false })
        {
            Command("quit");
            try { if (!p.WaitForExit(2000)) p.Kill(); } catch { }
        }
        CloseIpc();
    }

    public void Command(params object[] args)
    {
        try { writer?.WriteLine(JsonSerializer.Serialize(new { command = args })); } catch { }
    }

    /// <summary>
    /// Finds mpv's video window and puts it over the player area. Looks for the window by
    /// process and class (Process.MainWindowHandle could miss it), and keeps looking for up to a
    /// minute: when mpv's window came late, Glass used to give up after 5 s, leaving mpv playing
    /// wherever it opened and "Starting mpv…" on screen.
    /// </summary>
    async Task AttachWindowAsync(Process p)
    {
        for (int i = 0; i < 600 && ReferenceEquals(p, proc) && !p.HasExited; i++)
        {
            var h = FindMpvWindow(p.Id);
            if (h != IntPtr.Zero)
            {
                hwnd = h;
                // owned by the app: stays above it, hides with it, no second taskbar button
                SetWindowLongPtr(h, GWLP_HWNDPARENT, owner);
                var ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
                SetWindowLongPtr(h, GWL_EXSTYLE, new IntPtr(ex & ~WS_EX_APPWINDOW));
                SetBounds(bounds);
                SetForegroundWindow(h);
                return;
            }
            await Task.Delay(i < 100 ? 50 : 100);
        }
    }

    delegate bool EnumWindowsProc(IntPtr h, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder name, int max);

    /// <summary>mpv's top-level window (class "mpv") belonging to process [pid], or zero.</summary>
    static IntPtr FindMpvWindow(int pid)
    {
        var found = IntPtr.Zero;
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var owner);
            if (owner != (uint)pid) return true;
            var name = new StringBuilder(32);
            GetClassName(h, name, name.Capacity);
            if (name.ToString() != "mpv") return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    async Task ConnectAsync(string name, Process owner)
    {
        for (int i = 0; i < 50 && ReferenceEquals(owner, proc) && !owner.HasExited; i++)
        {
            try
            {
                var c = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
                await c.ConnectAsync(200);
                pipe = c;
                writer = new StreamWriter(c, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
                Command("observe_property", 1, "fullscreen");
                _ = ReadLoop(c);
                return;
            }
            catch { await Task.Delay(100); }
        }
    }

    async Task ReadLoop(NamedPipeClientStream c)
    {
        using var reader = new StreamReader(c, Encoding.UTF8);
        try
        {
            while (await reader.ReadLineAsync() is { } line)
            {
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var r = doc.RootElement;
                    if (r.TryGetProperty("event", out var ev) && ev.GetString() == "property-change"
                        && r.TryGetProperty("name", out var n) && n.GetString() == "fullscreen"
                        && r.TryGetProperty("data", out var d) && (d.ValueKind == JsonValueKind.True || d.ValueKind == JsonValueKind.False))
                    {
                        mpvFullscreen = d.GetBoolean();
                        if (!mpvFullscreen) SetBounds(bounds);   // back onto the player area
                        FullscreenChanged?.Invoke(mpvFullscreen);
                    }
                }
                catch { }
            }
        }
        catch { }
    }

    void CloseIpc()
    {
        try { writer?.Dispose(); } catch { }
        try { pipe?.Dispose(); } catch { }
        writer = null;
        pipe = null;
    }

    const int GWLP_HWNDPARENT = -8, GWL_EXSTYLE = -20;
    const long WS_EX_APPWINDOW = 0x40000;
    const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    static extern IntPtr SetWindowLongPtr(IntPtr h, int index, IntPtr value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr h);
}
