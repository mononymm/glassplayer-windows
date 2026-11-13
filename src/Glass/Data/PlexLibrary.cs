using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Glass.Data;

public enum Kind { Movie = 1, Show = 2, Season = 3, Episode = 4 }

public sealed class Section
{
    public int Id { get; init; }
    public string PlexName { get; init; } = "";
    public string Name { get; set; } = "";
    public bool IsMovies { get; init; }
    public List<Item> Items { get; } = new();
    /// <summary>The library's folders on disk.</summary>
    public List<string> Roots { get; } = new();
}

public sealed class Item
{
    public int Id { get; init; }
    public int ParentId { get; init; }
    public int SectionId { get; init; }
    public Kind Kind { get; init; }
    public string Guid { get; init; } = "";
    public string Title { get; init; } = "";
    public string SortTitle { get; init; } = "";
    public string Summary { get; init; } = "";
    public int Year { get; init; }
    public int Index { get; init; }
    public long DurationMs { get; set; }
    public string ThumbUrl { get; init; } = "";
    public string ArtUrl { get; init; } = "";
    public string LogoUrl { get; init; } = "";
    public string Hash { get; init; } = "";
    public DateTime Added { get; init; }
    public DateTime? Aired { get; init; }
    public string ContentRating { get; init; } = "";
    public double Rating { get; init; }

    public Item? Parent { get; set; }
    public List<Item> Children { get; } = new();

    // media
    public string? File { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public string VideoCodec { get; set; } = "";
    public string AudioCodec { get; set; } = "";
    public int Channels { get; set; }
    public int BitrateKbps { get; set; }
    public string ColorTrc { get; set; } = "";

    // watch state (newest of Plex and mpv)
    public double ViewOffset { get; set; }   // seconds
    public bool Watched { get; set; }
    public DateTime LastViewed { get; set; }

    public Item Show => Kind == Kind.Episode ? Parent?.Parent ?? this : Kind == Kind.Season ? Parent ?? this : this;
    public Item? Season => Kind == Kind.Episode ? Parent : Kind == Kind.Season ? this : null;
    public bool IsPlayable => Kind is Kind.Movie or Kind.Episode;
    public double DurationSec => DurationMs / 1000.0;

    public double Progress => DurationSec > 0 && ViewOffset > 0 && !Watched ? Math.Clamp(ViewOffset / DurationSec, 0, 1) : 0;
    public bool InProgress => Progress > 0.005;

    public IEnumerable<Item> Episodes => Kind switch
    {
        Kind.Show => Children.OrderBy(s => s.Index).SelectMany(s => s.Children.OrderBy(e => e.Index)),
        Kind.Season => Children.OrderBy(e => e.Index),
        _ => Enumerable.Empty<Item>(),
    };

    /// <summary>For a show: the episode in progress, else the next unwatched after the last one finished.</summary>
    public Item? UpNext()
    {
        var eps = Episodes.Where(e => e.File != null).ToList();
        var inProgress = eps.Where(e => e.InProgress).OrderByDescending(e => e.LastViewed).FirstOrDefault();
        if (inProgress != null) return inProgress;
        var last = eps.Where(e => e.Watched).OrderByDescending(e => e.LastViewed).FirstOrDefault();
        if (last != null) return eps.Skip(eps.IndexOf(last) + 1).FirstOrDefault(e => !e.Watched) ?? eps.FirstOrDefault(e => !e.Watched);
        return eps.FirstOrDefault();
    }

    public int UnwatchedCount => Kind is Kind.Show or Kind.Season ? Episodes.Count(e => !e.Watched) : 0;

    public string Code => Kind == Kind.Episode
        ? $"S{(Parent?.Index ?? 0):00} · E{Index:00}" : "";

    public string DisplayTitle => Kind == Kind.Episode ? Show.Title : Title;

    public string SubLine => Kind switch
    {
        Kind.Episode => $"{Code} · {Title}",
        Kind.Movie => Year > 0 ? Year.ToString() : "",
        Kind.Show => Year > 0 ? Year.ToString() : "",
        Kind.Season => Title,
        _ => "",
    };

    public string Runtime
    {
        get
        {
            var m = (int)Math.Round(DurationSec / 60);
            return m <= 0 ? "" : m >= 60 ? $"{m / 60}h {m % 60}m" : $"{m}m";
        }
    }

    public string RemainingText
    {
        get
        {
            if (!InProgress) return Runtime;
            var m = (int)Math.Ceiling((DurationSec - ViewOffset) / 60);
            return $"{m} min left";
        }
    }

    public string MediaSummary
    {
        get
        {
            var p = new List<string>();
            if (Height > 0) p.Add(Width >= 3200 || Height >= 1800 ? "4K" : Width >= 1800 || Height >= 1000 ? "1080p" : Width >= 1200 || Height >= 700 ? "720p" : $"{Height}p");
            if (ColorTrc is "smpte2084") p.Add("HDR10");
            else if (ColorTrc is "arib-std-b67") p.Add("HLG");
            if (VideoCodec != "") p.Add(PrettyCodec(VideoCodec));
            if (AudioCodec != "") p.Add(PrettyCodec(AudioCodec) + (Channels switch { 6 => " 5.1", 8 => " 7.1", 2 => " Stereo", 1 => " Mono", 0 => "", _ => $" {Channels}ch" }));
            return string.Join("  ·  ", p);
        }
    }

    static string PrettyCodec(string c) => c.ToLowerInvariant() switch
    {
        "hevc" or "h265" => "HEVC", "h264" => "H.264", "av1" => "AV1", "mpeg4" => "MPEG-4",
        "truehd" => "TrueHD", "eac3" => "DD+", "ac3" => "Dolby Digital", "dca" or "dts" => "DTS",
        "aac" => "AAC", "flac" => "FLAC", "opus" => "Opus", "mp3" => "MP3",
        _ => c.ToUpperInvariant(),
    };
}

/// <summary>Reads the Plex library straight from Plex's database (a private copy), so it works with Plex off.</summary>
public sealed class PlexLibrary
{
    readonly Settings settings;
    public List<Section> Sections { get; } = new();
    public Dictionary<int, Item> ById { get; } = new();
    public Dictionary<string, Item> ByFile { get; } = new(StringComparer.OrdinalIgnoreCase);
    public string? Error { get; private set; }

    public PlexLibrary(Settings s) { settings = s; }

    public static string NormPath(string p) => p.Replace('/', '\\').ToLowerInvariant();

    public void Load()
    {
        Sections.Clear(); ById.Clear(); ByFile.Clear(); Error = null;
        var src = settings.PlexDbPath;
        if (src == null || !System.IO.File.Exists(src)) { Error = "Couldn't find your Plex database. Set the Plex folder in Settings."; return; }

        // Work on a copy (with its write-ahead log) so we never touch or lock Plex's own file.
        Directory.CreateDirectory(Settings.CacheDir);
        var db = Path.Combine(Settings.CacheDir, "plex.db");
        try
        {
            CopyShared(src, db);
            if (System.IO.File.Exists(src + "-wal")) CopyShared(src + "-wal", db + "-wal");
            else if (System.IO.File.Exists(db + "-wal")) System.IO.File.Delete(db + "-wal");
            if (System.IO.File.Exists(db + "-shm")) System.IO.File.Delete(db + "-shm");
        }
        catch (Exception ex) { Error = "Couldn't read the Plex database: " + ex.Message; return; }

        using var con = new SqliteConnection($"Data Source={db};Pooling=False");
        con.Open();

        foreach (var r in Rows(con, "select id, name, section_type from library_sections order by id"))
        {
            var t = Convert.ToInt32(r[2]);
            if (t is not (1 or 2)) continue;
            Sections.Add(new Section { Id = Convert.ToInt32(r[0]), PlexName = Str(r[1]), Name = Str(r[1]), IsMovies = t == 1 });
        }

        foreach (var r in Rows(con, "select library_section_id, root_path from section_locations"))
        {
            var sec = Sections.FirstOrDefault(x => x.Id == Int(r[0]));
            if (sec != null && Str(r[1]) != "") sec.Roots.Add(Str(r[1]));
        }

        foreach (var r in Rows(con, @"select id, library_section_id, parent_id, metadata_type, guid, title, title_sort, summary, year, ""index"",
                duration, user_thumb_url, user_art_url, user_clear_logo_url, hash, added_at, originally_available_at, content_rating, audience_rating
                from metadata_items where metadata_type in (1,2,3,4) and deleted_at is null"))
        {
            var it = new Item
            {
                Id = Convert.ToInt32(r[0]), SectionId = Int(r[1]), ParentId = Int(r[2]), Kind = (Kind)Convert.ToInt32(r[3]),
                Guid = Str(r[4]), Title = Str(r[5]), SortTitle = Str(r[6]), Summary = Str(r[7]), Year = Int(r[8]), Index = Int(r[9]),
                DurationMs = Long(r[10]), ThumbUrl = Str(r[11]), ArtUrl = Str(r[12]), LogoUrl = Str(r[13]), Hash = Str(r[14]),
                Added = Date(r[15]) ?? DateTime.MinValue, Aired = Date(r[16]), ContentRating = Str(r[17]), Rating = Dbl(r[18]),
            };
            ById[it.Id] = it;
        }
        foreach (var it in ById.Values)
        {
            if (it.ParentId != 0 && ById.TryGetValue(it.ParentId, out var p)) { it.Parent = p; p.Children.Add(it); }
        }

        foreach (var r in Rows(con, @"select mi.metadata_item_id, mi.width, mi.height, mi.video_codec, mi.audio_codec, mi.audio_channels,
                mi.bitrate, mp.file, mi.duration, mi.color_trc from media_items mi join media_parts mp on mp.media_item_id = mi.id
                where mi.deleted_at is null and mp.deleted_at is null order by mi.id, mp.id"))
        {
            if (!ById.TryGetValue(Int(r[0]), out var it) || it.File != null) continue;
            it.File = Str(r[7]);
            it.Width = Int(r[1]); it.Height = Int(r[2]);
            it.VideoCodec = Str(r[3]); it.AudioCodec = Str(r[4]); it.Channels = Int(r[5]);
            it.BitrateKbps = Int(r[6]);
            if (it.DurationMs <= 0) it.DurationMs = Long(r[8]);
            it.ColorTrc = Str(r[9]);
            if (it.File != "") ByFile[NormPath(it.File)] = it;
        }

        // Plex's watch state, keyed by guid.
        var byGuid = ById.Values.Where(i => i.Guid != "").GroupBy(i => i.Guid).ToDictionary(g => g.Key, g => g.ToList());
        foreach (var r in Rows(con, $"select guid, view_offset, view_count, last_viewed_at, updated_at from metadata_item_settings where account_id = {settings.PlexAccount}"))
        {
            if (!byGuid.TryGetValue(Str(r[0]), out var items)) continue;
            foreach (var it in items)
            {
                it.ViewOffset = Long(r[1]) / 1000.0;
                it.Watched = Int(r[2]) > 0 && it.ViewOffset <= 0;
                it.LastViewed = Date(r[3]) ?? Date(r[4]) ?? DateTime.MinValue;
            }
        }
        con.Close();
        SqliteConnection.ClearAllPools();

        MergeMpvPositions();

        foreach (var sec in Sections)
        {
            sec.Items.AddRange(ById.Values.Where(i => i.SectionId == sec.Id && (i.Kind == (sec.IsMovies ? Kind.Movie : Kind.Show))
                                                       && (i.Kind == Kind.Show ? i.Children.Count > 0 : i.File != null))
                .OrderBy(i => string.IsNullOrEmpty(i.SortTitle) ? i.Title : i.SortTitle, StringComparer.OrdinalIgnoreCase));
        }
    }

    /// <summary>mpv's own record (glass-positions.json) wins when it's newer than Plex's.</summary>
    void MergeMpvPositions()
    {
        try
        {
            var path = Path.Combine(settings.MpvConfigDir, "glass-positions.json");
            if (!System.IO.File.Exists(path)) return;
            using var doc = JsonDocument.Parse(System.IO.File.ReadAllText(path));
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return;
            foreach (var p in doc.RootElement.EnumerateObject())
            {
                if (!ByFile.TryGetValue(NormPath(p.Name), out var it)) continue;
                var e = p.Value;
                if (e.ValueKind != JsonValueKind.Object) continue;
                double t = e.TryGetProperty("t", out var tv) && tv.ValueKind == JsonValueKind.Number ? tv.GetDouble() : 0;
                var when = DateTimeOffset.FromUnixTimeSeconds((long)t).LocalDateTime;
                if (when <= it.LastViewed.AddSeconds(5)) continue;
                bool done = e.TryGetProperty("done", out var dv) && dv.ValueKind == JsonValueKind.True;
                double pos = e.TryGetProperty("pos", out var pv) && pv.ValueKind == JsonValueKind.Number ? pv.GetDouble() : 0;
                it.Watched = done;
                it.ViewOffset = done ? 0 : pos;
                it.LastViewed = when;
            }
        }
        catch { }
    }

    /// <summary>One entry per show: the episode in progress, or the next one after the last finished.</summary>
    public List<Item> ContinueWatching(int max = 24)
    {
        var list = new List<Item>();
        var playable = ById.Values.Where(i => i.IsPlayable && i.File != null && i.LastViewed > DateTime.MinValue);
        foreach (var g in playable.GroupBy(i => i.Kind == Kind.Episode ? i.Show.Id : -i.Id))
        {
            var last = g.OrderByDescending(i => i.LastViewed).First();
            // anything started and not finished stays, even if it was rewound to the very start
            if (!last.Watched) { list.Add(last); continue; }
            if (last.Kind == Kind.Episode && last.Watched)
            {
                var eps = last.Show.Episodes.Where(e => e.File != null).ToList();
                var idx = eps.IndexOf(last);
                var next = eps.Skip(idx + 1).FirstOrDefault(e => !e.Watched);
                if (next != null) { next.LastViewed = next.LastViewed > last.LastViewed ? next.LastViewed : last.LastViewed; list.Add(next); }
            }
        }
        return list.OrderByDescending(i => i.LastViewed).Take(max).ToList();
    }

    public List<Item> RecentlyAdded(Section s, int max = 30) =>
        ById.Values.Where(i => i.SectionId == s.Id && (s.IsMovies ? i.Kind == Kind.Movie && i.File != null : i.Kind == Kind.Show && i.Children.Count > 0))
            .Select(i => (item: i, added: s.IsMovies ? i.Added : i.Episodes.Select(e => e.Added).DefaultIfEmpty(i.Added).Max()))
            .OrderByDescending(x => x.added).Take(max).Select(x => x.item).ToList();

    public List<Item> Search(string q)
    {
        q = q.Trim();
        if (q.Length == 0) return new();
        return ById.Values.Where(i => (i.Kind is Kind.Movie or Kind.Show) && i.Title.Contains(q, StringComparison.OrdinalIgnoreCase)
                                      && (i.Kind == Kind.Show ? i.Children.Count > 0 : i.File != null))
            .OrderBy(i => i.Title.StartsWith(q, StringComparison.OrdinalIgnoreCase) ? 0 : 1).ThenBy(i => i.Title).Take(60).ToList();
    }

    // ---- artwork on disk ----

    /// <summary>Where Plex keeps the file for an artwork URL (metadata://, upload://, media://).</summary>
    public string? ArtPath(Item it, string url)
    {
        if (string.IsNullOrEmpty(url) || settings.PlexDataPath == null) return null;
        var i = url.IndexOf("://", StringComparison.Ordinal);
        if (i < 0) return null;
        var scheme = url[..i];
        var rest = url[(i + 3)..].Replace('/', '\\');
        var root = settings.PlexDataPath;
        var top = it.Show;
        var folder = top.Kind == Kind.Movie ? "Movies" : "TV Shows";
        var cands = new List<string>();
        string? Bundle(string h) => h.Length < 2 ? null : Path.Combine(root, "Metadata", folder, h[..1], h[1..] + ".bundle");
        switch (scheme)
        {
            case "metadata":
                foreach (var h in new[] { it.Hash, top.Hash }.Distinct())
                {
                    var b = Bundle(h); if (b == null) continue;
                    cands.Add(Path.Combine(b, "Contents", "_combined", rest));
                    if (it.Kind == Kind.Episode && it.Parent != null)
                        cands.Add(Path.Combine(b, "Contents", "_combined", "seasons", it.Parent.Index.ToString(CultureInfo.InvariantCulture), "episodes", it.Index.ToString(CultureInfo.InvariantCulture), rest));
                    if (it.Kind == Kind.Season)
                        cands.Add(Path.Combine(b, "Contents", "_combined", "seasons", it.Index.ToString(CultureInfo.InvariantCulture), rest));
                }
                break;
            case "upload":
                foreach (var h in new[] { it.Hash, top.Hash }.Distinct())
                {
                    var b = Bundle(h); if (b != null) cands.Add(Path.Combine(b, "Uploads", rest));
                }
                break;
            case "media":
                cands.Add(Path.Combine(root, "Media", "localhost", rest));
                break;
        }
        foreach (var c in cands) if (System.IO.File.Exists(c)) return c;
        return null;
    }

    public string? Poster(Item it) => ArtPath(it, it.ThumbUrl) ?? (it.Parent != null ? Poster(it.Parent) : null);
    public string? Backdrop(Item it) => ArtPath(it.Show, it.Show.ArtUrl) ?? (it.Kind == Kind.Movie ? ArtPath(it, it.ArtUrl) : null);
    public string? Logo(Item it) => ArtPath(it.Show, it.Show.LogoUrl);
    /// <summary>Episode still, falling back to the show's backdrop.</summary>
    public string? Still(Item it) => (it.Kind == Kind.Episode ? ArtPath(it, it.ThumbUrl) : null) ?? Backdrop(it);

    // ---- helpers ----

    static void CopyShared(string from, string to)
    {
        using var src = new FileStream(from, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var dst = new FileStream(to, FileMode.Create, FileAccess.Write, FileShare.None);
        src.CopyTo(dst);
    }

    static IEnumerable<object?[]> Rows(SqliteConnection con, string sql)
    {
        using var cmd = con.CreateCommand();
        cmd.CommandText = sql;
        using var rd = cmd.ExecuteReader();
        while (rd.Read())
        {
            var row = new object?[rd.FieldCount];
            for (int i = 0; i < rd.FieldCount; i++) row[i] = rd.IsDBNull(i) ? null : rd.GetValue(i);
            yield return row;
        }
    }

    static string Str(object? o) => o?.ToString() ?? "";
    static int Int(object? o) => o switch { null => 0, long l => (int)l, int i => i, double d => (int)d, string s when int.TryParse(s, out var v) => v, _ => 0 };
    static long Long(object? o) => o switch { null => 0, long l => l, int i => i, double d => (long)d, string s when long.TryParse(s, out var v) => v, _ => 0 };
    static double Dbl(object? o) => o switch { null => 0, double d => d, long l => l, string s when double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) => v, _ => 0 };

    /// <summary>Plex stores dates as unix seconds in some columns and as text in others.</summary>
    static DateTime? Date(object? o)
    {
        switch (o)
        {
            case null: return null;
            case long l when l > 0: return DateTimeOffset.FromUnixTimeSeconds(l).LocalDateTime;
            case double d when d > 0: return DateTimeOffset.FromUnixTimeSeconds((long)d).LocalDateTime;
            case string s when long.TryParse(s, out var v) && v > 0: return DateTimeOffset.FromUnixTimeSeconds(v).LocalDateTime;
            case string s when DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dt): return dt.ToLocalTime();
            default: return null;
        }
    }
}
