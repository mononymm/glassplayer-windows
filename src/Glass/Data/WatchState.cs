using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Glass.Data;

/// <summary>
/// Marks things watched / unwatched everywhere Glass keeps track:
/// mpv's glass-positions.json (immediately), Plex directly when it's running on this PC,
/// otherwise the GlassSync queue that the scheduled sync pushes to Plex later.
/// </summary>
public static class WatchState
{
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(3) };

    public static async Task SetAsync(Settings settings, IEnumerable<Item> items, bool watched)
    {
        var list = items.Where(i => i.IsPlayable && !string.IsNullOrEmpty(i.File)).ToList();
        if (list.Count == 0) return;
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        // 1. update the in-memory library so the UI reflects it right away
        foreach (var it in list)
        {
            it.Watched = watched;
            it.ViewOffset = 0;
            it.LastViewed = DateTime.Now;
        }

        // 2. mpv's own record (newest wins against Plex in both Glass and the mpv library)
        try { UpdatePositions(settings, list, watched, now); } catch { }

        // 3. Plex: direct if the server answers on this PC, otherwise the sync queue
        var failed = new List<Item>();
        var token = PlexToken();
        foreach (var it in list)
        {
            var ok = false;
            if (token != null)
            {
                try
                {
                    var verb = watched ? "scrobble" : "unscrobble";
                    var url = $"http://127.0.0.1:32400/:/{verb}?key={it.Id}&identifier=com.plexapp.plugins.library&X-Plex-Token={Uri.EscapeDataString(token)}";
                    using var resp = await http.GetAsync(url);
                    ok = resp.IsSuccessStatusCode;
                }
                catch { ok = false; }
            }
            if (!ok) failed.Add(it);
        }
        if (failed.Count > 0)
        {
            try { QueueForSync(settings, failed, watched, now); } catch { }
        }
    }

    static void UpdatePositions(Settings settings, List<Item> items, bool watched, long now)
    {
        var path = Path.Combine(settings.MpvConfigDir, "glass-positions.json");
        JsonObject root;
        try { root = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? new() : new(); }
        catch { root = new(); }
        var keys = root.Select(kv => kv.Key).ToList();
        foreach (var it in items)
        {
            var norm = PlexLibrary.NormPath(it.File!);
            var key = keys.FirstOrDefault(k => PlexLibrary.NormPath(k) == norm) ?? it.File!;
            var entry = root[key] as JsonObject ?? new JsonObject();
            entry["pos"] = 0;
            entry["done"] = watched;
            if (it.DurationSec > 0) entry["dur"] = it.DurationSec;
            entry["t"] = now;
            root[key] = entry;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, root.ToJsonString(), new UTF8Encoding(false));
    }

    static void QueueForSync(Settings settings, List<Item> items, bool watched, long now)
    {
        var folder = SyncFolder(settings);
        Directory.CreateDirectory(folder);
        var qpath = Path.Combine(folder, "plex-queue.json");
        JsonArray queue;
        try { queue = File.Exists(qpath) ? JsonNode.Parse(File.ReadAllText(qpath)) as JsonArray ?? new() : new(); }
        catch { queue = new(); }
        foreach (var it in items)
        {
            var norm = PlexLibrary.NormPath(it.File!);
            for (int i = queue.Count - 1; i >= 0; i--)
                if (queue[i] is JsonObject o && o["path"]?.GetValue<string>() is { } p && PlexLibrary.NormPath(p) == norm) queue.RemoveAt(i);
            queue.Add(new JsonObject
            {
                ["path"] = it.File, ["pos"] = 0, ["dur"] = it.DurationSec, ["done"] = watched, ["unwatch"] = !watched, ["t"] = now,
            });
        }
        File.WriteAllText(qpath, queue.ToJsonString(), new UTF8Encoding(false));
    }

    static string SyncFolder(Settings settings)
    {
        try
        {
            var conf = Path.Combine(settings.MpvConfigDir, "script-opts", "glass.conf");
            if (File.Exists(conf))
                foreach (var line in File.ReadAllLines(conf))
                {
                    var m = Regex.Match(line, @"^\s*sync_folder\s*=\s*(.+?)\s*$");
                    if (m.Success && m.Groups[1].Value != "") return m.Groups[1].Value;
                }
        }
        catch { }
        return @"C:\Users\Public\GlassSync";
    }

    static string? PlexToken()
    {
        try { return Registry.CurrentUser.OpenSubKey(@"Software\Plex, Inc.\Plex Media Server")?.GetValue("PlexOnlineToken") as string; }
        catch { return null; }
    }
}
