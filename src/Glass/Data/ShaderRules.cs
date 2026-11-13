using System.IO;
using System.Text;
using System.Text.Json.Nodes;

namespace Glass.Data;

/// <summary>
/// Which upscaling mode a library or show uses: "anime" (2D Animation), "live" (Live Action) or "off"
/// (Disabled). Saved as folder rules in the mpv folder (glass-shaders.json), which the Glass mpv script
/// reads when a file starts; the longest matching folder wins. No rule = automatic (folder-name words).
/// </summary>
public static class ShaderRules
{
    public static string Label(string mode) => Modes.FirstOrDefault(m => m.mode == mode).label ?? "Automatic";

    public static readonly (string mode, string label)[] Modes =
        { ("", "Automatic"), ("live", "Live Action"), ("anime", "2D Animation"), ("off", "Disabled") };

    static string FilePath(Settings s) => Path.Combine(s.MpvConfigDir, "glass-shaders.json");

    static JsonObject Load(Settings s)
    {
        try
        {
            var p = FilePath(s);
            if (File.Exists(p) && JsonNode.Parse(File.ReadAllText(p)) is JsonObject o) return o;
        }
        catch { }
        return new JsonObject();
    }

    static JsonObject Folders(JsonObject root)
    {
        if (root["folders"] is JsonObject f) return f;
        var n = new JsonObject();
        root["folders"] = n;
        return n;
    }

    static string Norm(string p) => p.Replace('/', '\\').TrimEnd('\\');

    /// <summary>The mode set for exactly these folders ("" when they differ or none is set).</summary>
    public static string Get(Settings s, IEnumerable<string> folders)
    {
        var f = Folders(Load(s));
        var modes = folders.Select(Norm).Select(d =>
            f.FirstOrDefault(kv => string.Equals(Norm(kv.Key), d, StringComparison.OrdinalIgnoreCase)).Value?.GetValue<string>() ?? "").Distinct().ToList();
        return modes.Count == 1 ? modes[0] : "";
    }

    public static void Set(Settings s, IEnumerable<string> folders, string mode)
    {
        var root = Load(s);
        var f = Folders(root);
        foreach (var d in folders.Select(Norm).Where(d => d != ""))
        {
            foreach (var k in f.Select(kv => kv.Key).Where(k => string.Equals(Norm(k), d, StringComparison.OrdinalIgnoreCase)).ToList()) f.Remove(k);
            if (mode != "") f[d] = mode;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath(s))!);
        File.WriteAllText(FilePath(s), root.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
    }

    /// <summary>Folders that hold a show (common folder of its episodes), a season, or a movie (its folder).</summary>
    public static List<string> FoldersOf(Item it)
    {
        var files = (it.Kind is Kind.Show or Kind.Season ? it.Episodes : new[] { it }).Select(e => e.File).Where(f => !string.IsNullOrEmpty(f)).Select(f => f!).ToList();
        if (files.Count == 0) return new();
        if (it.Kind == Kind.Movie) return new() { Path.GetDirectoryName(files[0]) ?? "" };
        var parts = files.Select(f => (Path.GetDirectoryName(f) ?? "").Split('\\', '/')).ToList();
        var common = new List<string>();
        for (int i = 0; ; i++)
        {
            if (parts.Any(p => p.Length <= i)) break;
            var seg = parts[0][i];
            if (parts.All(p => string.Equals(p[i], seg, StringComparison.OrdinalIgnoreCase))) common.Add(seg); else break;
        }
        var dir = string.Join("\\", common);
        // a show whose episodes sit in "Season NN" folders: the show folder is one up
        var leaf = Path.GetFileName(dir);
        if (it.Kind == Kind.Show && leaf.StartsWith("Season", StringComparison.OrdinalIgnoreCase)) dir = Path.GetDirectoryName(dir) ?? dir;
        return dir.Length > 3 ? new() { dir } : new();
    }
}
