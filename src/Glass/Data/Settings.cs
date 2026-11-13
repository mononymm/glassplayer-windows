using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Glass.Data;

/// <summary>Where things live. Saved in %APPDATA%\Glass\settings.json; anything missing is detected.</summary>
public sealed class Settings
{
    public string? PlexDataPath { get; set; }   // ...\Plex Media Server
    public string? MpvPath { get; set; }        // ...\mpv.exe
    public int PlexAccount { get; set; } = 1;
    public double WatchedAt { get; set; } = 0.90;
    public List<int> HiddenSections { get; set; } = new();
    public List<int> SectionOrder { get; set; } = new();
    public Dictionary<int, string> SectionNames { get; set; } = new();
    public Dictionary<int, string> SectionSort { get; set; } = new();
    public double TileSize { get; set; } = 176;
    public bool SidebarExpanded { get; set; }

    public static string AppDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Glass");
    public static string CacheDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Glass", "cache");
    static string FilePath => Path.Combine(AppDir, "settings.json");

    /// <summary>mpv's config folder (where glass.lua keeps its JSON files).</summary>
    public string MpvConfigDir
    {
        get
        {
            if (MpvPath != null)
            {
                var portable = Path.Combine(Path.GetDirectoryName(MpvPath) ?? "", "portable_config");
                if (Directory.Exists(portable)) return portable;
            }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "mpv");
        }
    }

    public static Settings Load()
    {
        Settings s;
        try { s = File.Exists(FilePath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new() : new(); }
        catch { s = new(); }
        if (s.MpvPath == null || !File.Exists(s.MpvPath)) s.MpvPath = FindMpv();
        if (s.PlexDataPath == null || !Directory.Exists(s.PlexDataPath)) s.PlexDataPath = FindPlex(s);
        return s;
    }

    public void Save()
    {
        Directory.CreateDirectory(AppDir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public string? PlexDbPath => PlexDataPath == null ? null
        : Path.Combine(PlexDataPath, "Plug-in Support", "Databases", "com.plexapp.plugins.library.db");

    static string? FindMpv()
    {
        // 1. on PATH
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try { var p = Path.Combine(dir.Trim(), "mpv.exe"); if (File.Exists(p)) return p; } catch { }
        }
        // 2. registered by mpv-install.bat
        foreach (var key in new[] { @"Applications\mpv.exe\shell\open\command", @"io.mpv.mkv\shell\open\command" })
        {
            try
            {
                var v = Registry.ClassesRoot.OpenSubKey(key)?.GetValue("") as string;
                var m = v == null ? null : Regex.Match(v, "^\"([^\"]+mpv\\.exe)\"", RegexOptions.IgnoreCase);
                if (m != null && m.Success && File.Exists(m.Groups[1].Value)) return m.Groups[1].Value;
            }
            catch { }
        }
        // 3. common folders
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        foreach (var p in new[] { Path.Combine(pf, "mpv", "mpv.exe"), @"C:\mpv\mpv.exe",
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "mpv", "mpv.exe") })
            if (File.Exists(p)) return p;
        return null;
    }

    static string? FindPlex(Settings s)
    {
        // 1. the plex_db line in glass.conf (already set up on both Windows profiles)
        try
        {
            var conf = Path.Combine(s.MpvConfigDir, "script-opts", "glass.conf");
            if (File.Exists(conf))
            {
                foreach (var line in File.ReadAllLines(conf))
                {
                    var m = Regex.Match(line, @"^\s*plex_db\s*=\s*(.+?)\s*$");
                    if (!m.Success) continue;
                    var i = m.Groups[1].Value.IndexOf(@"\Plug-in Support", StringComparison.OrdinalIgnoreCase);
                    if (i > 0 && Directory.Exists(m.Groups[1].Value[..i])) return m.Groups[1].Value[..i];
                }
            }
        }
        catch { }
        // 2. Plex's own registry setting / default location
        try
        {
            var custom = Registry.CurrentUser.OpenSubKey(@"Software\Plex, Inc.\Plex Media Server")?.GetValue("LocalAppDataPath") as string;
            if (!string.IsNullOrEmpty(custom) && Directory.Exists(Path.Combine(custom, "Plex Media Server")))
                return Path.Combine(custom, "Plex Media Server");
        }
        catch { }
        var local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Plex Media Server");
        if (File.Exists(Path.Combine(local, "Plug-in Support", "Databases", "com.plexapp.plugins.library.db"))) return local;
        // 3. another Windows profile on this PC
        try
        {
            foreach (var user in Directory.GetDirectories(@"C:\Users"))
            {
                var p = Path.Combine(user, "AppData", "Local", "Plex Media Server");
                try { if (File.Exists(Path.Combine(p, "Plug-in Support", "Databases", "com.plexapp.plugins.library.db"))) return p; } catch { }
            }
        }
        catch { }
        return null;
    }
}
