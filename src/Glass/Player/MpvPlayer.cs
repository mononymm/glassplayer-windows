using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Interop;

namespace Glass.Player;

/// <summary>A plain child window that mpv draws into (via --wid).</summary>
public sealed class MpvHost : HwndHost
{
    public IntPtr Handle2 { get; private set; }

    protected override HandleRef BuildWindowCore(HandleRef parent)
    {
        const int WS_CHILD = 0x40000000, WS_VISIBLE = 0x10000000, WS_CLIPCHILDREN = 0x02000000, WS_CLIPSIBLINGS = 0x04000000;
        Handle2 = CreateWindowEx(0, "static", "", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
            0, 0, 100, 100, parent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        return new HandleRef(this, Handle2);
    }

    protected override void DestroyWindowCore(HandleRef hwnd) => DestroyWindow(hwnd.Handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(int exStyle, string cls, string name, int style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);

    [DllImport("user32.dll")]
    static extern bool DestroyWindow(IntPtr hwnd);
}

/// <summary>Runs the user's own mpv (config, scripts, shaders and all) inside the app window.</summary>
public sealed class MpvPlayer
{
    Process? proc;
    NamedPipeClientStream? pipe;
    StreamWriter? writer;
    readonly string mpvPath;

    public event Action? Exited;
    public event Action<bool>? FullscreenChanged;
    public bool Running => proc is { HasExited: false };

    public MpvPlayer(string mpvPath) { this.mpvPath = mpvPath; }

    public void Play(IntPtr wid, IReadOnlyList<string> files, int start)
    {
        Stop();
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
        psi.ArgumentList.Add($"--wid={wid.ToInt64()}");
        psi.ArgumentList.Add($"--input-ipc-server=\\\\.\\pipe\\{pipeName}");
        psi.ArgumentList.Add("--idle=no");
        psi.ArgumentList.Add("--keep-open=no");
        psi.ArgumentList.Add("--force-window=immediate");
        psi.ArgumentList.Add($"--playlist-start={start}");
        psi.ArgumentList.Add($"--playlist={playlist}");

        proc = Process.Start(psi);
        if (proc == null) return;
        proc.EnableRaisingEvents = true;
        var mine = proc;
        proc.Exited += (_, _) =>
        {
            if (!ReferenceEquals(mine, proc)) return;
            CloseIpc();
            Exited?.Invoke();
        };
        _ = ConnectAsync(pipeName, mine);
    }

    public void Stop()
    {
        var p = proc;
        proc = null;
        CloseIpc();
        if (p is { HasExited: false })
        {
            try { p.Kill(); } catch { }
        }
    }

    public void Command(params object[] args)
    {
        try
        {
            writer?.WriteLine(JsonSerializer.Serialize(new { command = args }));
        }
        catch { }
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
                        FullscreenChanged?.Invoke(d.GetBoolean());
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
}
