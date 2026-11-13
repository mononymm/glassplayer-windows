using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Glass.Controls;
using Glass.Data;
using static Glass.Controls.Ui;

namespace Glass.Views;

/// <summary>What pages need from the window.</summary>
public interface IShell
{
    PlexLibrary Library { get; }
    void Navigate(FrameworkElement page, string key);
    void Play(Item item);
    void OpenItem(Item item);
    void OpenSection(Section s);
}

/// <summary>Vertical page with eased scrolling and a slim overlay scrollbar.</summary>
public class GlassPage : Grid
{
    public readonly StackPanel Body = new();
    public readonly ScrollViewer Scroller;

    public GlassPage()
    {
        Background = Ui.Bg;
        Scroller = new ScrollViewer
        {
            Content = Body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false, PanningMode = PanningMode.VerticalOnly,
        };
        SmoothScroll.SetEnabled(Scroller, true);
        Children.Add(Scroller);
    }
}

/// <summary>Full-bleed backdrop with fades into the page colour. Used by home hero and detail pages.</summary>
public sealed class Backdrop : Grid
{
    readonly Image a = new() { Stretch = Stretch.UniformToFill }, b = new() { Stretch = Stretch.UniformToFill };
    bool showingA = true;

    public Backdrop(double height)
    {
        Height = height;
        ClipToBounds = true;
        foreach (var i in new[] { a, b })
        {
            RenderOptions.SetBitmapScalingMode(i, BitmapScalingMode.HighQuality);
            i.VerticalAlignment = VerticalAlignment.Top;
            i.HorizontalAlignment = HorizontalAlignment.Right;
            i.Opacity = 0;
            Children.Add(i);
        }
        // left fade for text, bottom fade into the page
        Children.Add(new Rectangle
        {
            Fill = new LinearGradientBrush(new GradientStopCollection
            {
                new(Color.FromArgb(0xF2, Ui.BgColor.R, Ui.BgColor.G, Ui.BgColor.B), 0),
                new(Color.FromArgb(0x99, Ui.BgColor.R, Ui.BgColor.G, Ui.BgColor.B), 0.38),
                new(Color.FromArgb(0x00, Ui.BgColor.R, Ui.BgColor.G, Ui.BgColor.B), 0.75),
            }, 0),
        });
        Children.Add(new Rectangle
        {
            Fill = new LinearGradientBrush(new GradientStopCollection
            {
                new(Color.FromArgb(0x00, Ui.BgColor.R, Ui.BgColor.G, Ui.BgColor.B), 0.45),
                new(Color.FromArgb(0xFF, Ui.BgColor.R, Ui.BgColor.G, Ui.BgColor.B), 1),
            }, 90),
        });
    }

    /// <summary>Crossfades to a new image.</summary>
    public async void Show(string? path)
    {
        var src = await Controls.Art.LoadAsync(path, 1920);
        var (into, outOf) = showingA ? (b, a) : (a, b);
        showingA = !showingA;
        into.Source = src;
        var dur = TimeSpan.FromMilliseconds(700);
        into.BeginAnimation(OpacityProperty, new DoubleAnimation(src == null ? 0 : 1, dur));
        outOf.BeginAnimation(OpacityProperty, new DoubleAnimation(0, dur));
        // slow drift for a bit of life
        var st = new ScaleTransform(1.06, 1.06);
        into.RenderTransformOrigin = new Point(0.7, 0.3);
        into.RenderTransform = st;
        var drift = new DoubleAnimation(1.06, 1.0, TimeSpan.FromSeconds(12)) { EasingFunction = new SineEase { EasingMode = EasingMode.EaseOut } };
        st.BeginAnimation(ScaleTransform.ScaleXProperty, drift);
        st.BeginAnimation(ScaleTransform.ScaleYProperty, drift);
    }
}

/// <summary>Title logo when Plex has one, otherwise the title in large type.</summary>
static class TitleArt
{
    public static FrameworkElement For(PlexLibrary lib, Item show, double maxW, double maxH)
    {
        var logo = lib.Logo(show);
        var text = T(show.Title, 46, FontWeights.Black).With(t => { t.TextWrapping = TextWrapping.Wrap; t.MaxWidth = maxW; });
        if (logo == null) return text;
        var img = Art(logo, 900, Stretch.Uniform).With(i => { i.MaxWidth = maxW; i.MaxHeight = maxH; i.HorizontalAlignment = HorizontalAlignment.Left; });
        return img;
    }
}

public sealed class HomePage : GlassPage
{
    readonly IShell shell;
    readonly Backdrop backdrop = new(720);
    readonly StackPanel heroText = new() { Margin = new Thickness(64, 150, 0, 0), MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Left };
    readonly DispatcherTimer rotate = new() { Interval = TimeSpan.FromSeconds(11) };
    List<Item> heroItems = new();
    int heroIndex;

    public HomePage(IShell shell)
    {
        this.shell = shell;
        var lib = shell.Library;

        var hero = new Grid { Height = 620 };
        hero.Children.Add(backdrop.With(b => b.Height = 720));
        hero.Children.Add(heroText);
        Body.Children.Add(hero);

        if (lib.Error != null)
        {
            heroText.Children.Add(T("Library unavailable", 34, FontWeights.Bold));
            heroText.Children.Add(T(lib.Error, 15, color: Muted).With(t => { t.TextWrapping = TextWrapping.Wrap; t.Margin = new Thickness(0, 10, 0, 0); }));
            return;
        }

        var cw = lib.ContinueWatching();
        heroItems = cw.Take(6).ToList();
        if (heroItems.Count == 0) heroItems = lib.Sections.SelectMany(s => lib.RecentlyAdded(s, 3)).Take(6).ToList();
        ShowHero(0);
        if (heroItems.Count > 1)
        {
            rotate.Tick += (_, _) => ShowHero(heroIndex + 1);
            rotate.Start();
            Unloaded += (_, _) => rotate.Stop();
            Loaded += (_, _) => rotate.Start();
        }

        // rows pull up into the bottom of the backdrop
        var rows = new StackPanel { Margin = new Thickness(0, -120, 0, 40) };
        if (cw.Count > 0)
            rows.Children.Add(Row("Continue watching", cw.Select(i => StillCard(lib, i, 340, () => shell.Play(i)))));
        foreach (var s in lib.Sections)
        {
            var recent = lib.RecentlyAdded(s, 24);
            if (recent.Count == 0) continue;
            rows.Children.Add(Row(s.Name, recent.Select(i => PosterCard(lib, i, 176, () => shell.OpenItem(i))), () => shell.OpenSection(s)));
        }
        Body.Children.Add(rows);
    }

    void ShowHero(int i)
    {
        if (heroItems.Count == 0) return;
        heroIndex = (i % heroItems.Count + heroItems.Count) % heroItems.Count;
        var it = heroItems[heroIndex];
        var lib = shell.Library;
        backdrop.Show(it.Kind == Kind.Episode && lib.Backdrop(it) == null ? lib.Still(it) : lib.Backdrop(it));

        var fresh = new StackPanel();
        fresh.Children.Add(TitleArt.For(lib, it.Show, 520, 190));
        var meta = it.Kind == Kind.Episode
            ? $"{it.Code}  ·  {it.Title}"
            : string.Join("  ·  ", new[] { it.Year > 0 ? it.Year.ToString() : "", it.ContentRating, it.Runtime }.Where(x => x != ""));
        fresh.Children.Add(T(meta, 16, FontWeights.SemiBold).With(t => t.Margin = new Thickness(0, 22, 0, 0)));
        var summary = it.Kind == Kind.Episode && it.Summary == "" ? it.Show.Summary : it.Summary;
        if (summary != "")
            fresh.Children.Add(T(summary, 14, color: Muted).With(t =>
            {
                t.TextWrapping = TextWrapping.Wrap; t.MaxHeight = 64; t.TextTrimming = TextTrimming.WordEllipsis; t.Margin = new Thickness(0, 8, 0, 0); t.LineHeight = 21;
            }));
        if (it.InProgress)
            fresh.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0),
                Children = { ProgressBar(it.Progress, 200), T(it.RemainingText, 12, FontWeights.SemiBold, Muted).With(t => t.Margin = new Thickness(12, -4, 0, 0)) }
            });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 22, 0, 0) };
        buttons.Children.Add(Pill(it.InProgress ? "Resume" : "Play", IcoPlay, () => shell.Play(it), accent: true, height: 44));
        buttons.Children.Add(Pill(it.Kind == Kind.Episode ? "Go to show" : "Details", IcoInfo, () => shell.OpenItem(it.Show), height: 44).With(b => b.Margin = new Thickness(12, 0, 0, 0)));
        fresh.Children.Add(buttons);

        // dots
        if (heroItems.Count > 1)
        {
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(2, 26, 0, 0) };
            for (int d = 0; d < heroItems.Count; d++)
            {
                var idx = d;
                var dot = new Border
                {
                    Width = d == heroIndex ? 22 : 7, Height = 7, CornerRadius = new CornerRadius(3.5), Margin = new Thickness(0, 0, 7, 0),
                    Background = d == heroIndex ? Ui.Accent : Ui.Faint, Cursor = Cursors.Hand,
                };
                dot.MouseLeftButtonUp += (_, _) => { rotate.Stop(); ShowHero(idx); rotate.Start(); };
                dots.Children.Add(dot);
            }
            fresh.Children.Add(dots);
        }

        heroText.Children.Clear();
        heroText.Children.Add(fresh);
        fresh.Opacity = 0;
        var tt = new TranslateTransform(0, 14);
        fresh.RenderTransform = tt;
        var dur = TimeSpan.FromMilliseconds(450);
        fresh.BeginAnimation(OpacityProperty, new DoubleAnimation(1, dur));
        tt.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, dur) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
    }
}

public sealed class SectionPage : GlassPage
{
    public SectionPage(IShell shell, Section s, IEnumerable<Item>? items = null, string? title = null)
    {
        var lib = shell.Library;
        Body.Margin = new Thickness(0, 40, 0, 40);
        Body.Children.Add(T(title ?? s.Name, 34, FontWeights.Bold).With(t => t.Margin = new Thickness(64, 30, 64, 6)));
        var list = (items ?? s.Items).ToList();
        Body.Children.Add(T($"{list.Count} {(s.IsMovies ? "movies" : "shows")}", 14, color: Muted).With(t => t.Margin = new Thickness(64, 0, 64, 24)));
        var wrap = new WrapPanel { Margin = new Thickness(58, 0, 40, 0) };
        foreach (var it in list)
            wrap.Children.Add(PosterCard(lib, it, 172, () => shell.OpenItem(it)).With(c => c.Margin = new Thickness(6, 6, 18, 22)));
        Body.Children.Add(wrap);
    }
}

public sealed class SearchPage : GlassPage
{
    public SearchPage(IShell shell)
    {
        var lib = shell.Library;
        Body.Margin = new Thickness(0, 60, 0, 40);
        var box = new TextBox
        {
            FontSize = 22, FontFamily = Font, Foreground = Ui.Text, Background = Ui.GlassFill, BorderBrush = Ui.GlassEdge,
            BorderThickness = new Thickness(1), Padding = new Thickness(18, 10, 18, 10), Margin = new Thickness(64, 0, 64, 30),
            CaretBrush = Ui.Accent, MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left, Width = 760,
        };
        box.Resources.Add(typeof(Border), new Style(typeof(Border)) { Setters = { new Setter(Border.CornerRadiusProperty, new CornerRadius(24)) } });
        var results = new WrapPanel { Margin = new Thickness(58, 0, 40, 0) };
        var hint = T("Search shows and movies", 14, color: Muted).With(t => t.Margin = new Thickness(66, -18, 0, 20));
        Body.Children.Add(box);
        Body.Children.Add(hint);
        Body.Children.Add(results);
        var debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        debounce.Tick += (_, _) =>
        {
            debounce.Stop();
            results.Children.Clear();
            var found = lib.Search(box.Text);
            hint.Text = box.Text.Trim() == "" ? "Search shows and movies" : found.Count == 0 ? "No matches" : $"{found.Count} result{(found.Count == 1 ? "" : "s")}";
            foreach (var it in found)
                results.Children.Add(PosterCard(lib, it, 160, () => shell.OpenItem(it)).With(c => c.Margin = new Thickness(6, 6, 18, 22)));
        };
        box.TextChanged += (_, _) => { debounce.Stop(); debounce.Start(); };
        Loaded += (_, _) => box.Focus();
    }
}

public sealed class DetailPage : GlassPage
{
    readonly IShell shell;
    readonly Item item;
    readonly StackPanel episodes = new() { Margin = new Thickness(64, 0, 64, 0) };
    readonly StackPanel seasonTabs = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(64, 0, 64, 20) };
    Item? season;

    public DetailPage(IShell shell, Item it)
    {
        this.shell = shell;
        item = it.Show;
        var lib = shell.Library;

        var hero = new Grid { Height = 600 };
        var bd = new Backdrop(760);
        hero.Children.Add(bd);
        bd.Show(lib.Backdrop(item));

        var info = new StackPanel { Margin = new Thickness(64, 130, 0, 0), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        info.Children.Add(TitleArt.For(lib, item, 540, 200));
        var meta = new List<string>();
        if (item.Year > 0) meta.Add(item.Year.ToString());
        if (item.ContentRating != "") meta.Add(item.ContentRating);
        if (item.Kind == Kind.Show) meta.Add($"{item.Children.Count} season{(item.Children.Count == 1 ? "" : "s")}");
        else if (item.Runtime != "") meta.Add(item.Runtime);
        if (item.Rating > 0) meta.Add($"★ {item.Rating:0.0}");
        info.Children.Add(T(string.Join("  ·  ", meta), 15, FontWeights.SemiBold).With(t => t.Margin = new Thickness(0, 22, 0, 0)));
        if (item.Kind == Kind.Movie && item.MediaSummary != "")
            info.Children.Add(T(item.MediaSummary, 13, FontWeights.SemiBold, Muted).With(t => t.Margin = new Thickness(0, 6, 0, 0)));
        if (item.Summary != "")
            info.Children.Add(T(item.Summary, 14.5, color: Muted).With(t =>
            {
                t.TextWrapping = TextWrapping.Wrap; t.MaxHeight = 110; t.TextTrimming = TextTrimming.WordEllipsis; t.LineHeight = 22; t.Margin = new Thickness(0, 12, 0, 0);
            }));

        var next = item.Kind == Kind.Show ? UpNext() : item;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 24, 0, 0) };
        if (next != null)
        {
            var label = next.InProgress ? "Resume" : "Play";
            if (next.Kind == Kind.Episode) label += "  " + next.Code.Replace(" · ", " ");
            buttons.Children.Add(Pill(label, IcoPlay, () => shell.Play(next), accent: true, height: 44));
        }
        info.Children.Add(buttons);
        if (next != null && next.InProgress)
            info.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0),
                Children = { ProgressBar(next.Progress, 200), T(next.RemainingText, 12, FontWeights.SemiBold, Muted).With(t => t.Margin = new Thickness(12, -4, 0, 0)) }
            });
        hero.Children.Add(info);
        Body.Children.Add(hero);

        if (item.Kind == Kind.Show)
        {
            var seasons = item.Children.Where(s => s.Children.Any(e => e.File != null)).OrderBy(s => s.Index == 0 ? int.MaxValue : s.Index).ToList();
            var start = next?.Season ?? seasons.FirstOrDefault();
            Body.Children.Add(seasonTabs.With(p => p.Margin = new Thickness(64, -40, 64, 22)));
            foreach (var s in seasons)
            {
                var name = s.Title != "" ? s.Title : s.Index == 0 ? "Specials" : $"Season {s.Index}";
                var tab = Pill(name, null, () => ShowSeason(s), height: 36);
                tab.Tag = s;
                tab.Margin = new Thickness(0, 0, 10, 0);
                seasonTabs.Children.Add(tab);
            }
            Body.Children.Add(episodes);
            if (start != null) ShowSeason(start);
        }
        Body.Margin = new Thickness(0, 0, 0, 60);
    }

    Item? UpNext()
    {
        var eps = item.Episodes.Where(e => e.File != null).ToList();
        var inProgress = eps.Where(e => e.InProgress).OrderByDescending(e => e.LastViewed).FirstOrDefault();
        if (inProgress != null) return inProgress;
        var last = eps.Where(e => e.Watched).OrderByDescending(e => e.LastViewed).FirstOrDefault();
        if (last != null) return eps.Skip(eps.IndexOf(last) + 1).FirstOrDefault(e => !e.Watched) ?? eps.FirstOrDefault(e => !e.Watched);
        return eps.FirstOrDefault();
    }

    void ShowSeason(Item s)
    {
        season = s;
        foreach (Button b in seasonTabs.Children)
        {
            var on = b.Tag == s;
            b.Template = Chrome(new TextBlock(), on ? Ui.Accent : Ui.GlassFill, on ? Ui.Accent : Ui.GlassHover, new CornerRadius(18), new Thickness(18, 0, 18, 0)).Template;
        }
        episodes.Children.Clear();
        var lib = shell.Library;
        foreach (var ep in s.Children.Where(e => e.File != null).OrderBy(e => e.Index))
            episodes.Children.Add(EpisodeRow(lib, ep));
        episodes.Opacity = 0;
        episodes.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(250)));
    }

    FrameworkElement EpisodeRow(PlexLibrary lib, Item ep)
    {
        const double w = 288, h = 162;
        var row = new Border
        {
            CornerRadius = new CornerRadius(16), Padding = new Thickness(12), Margin = new Thickness(-12, 0, -12, 6),
            Background = Brushes.Transparent, Cursor = Cursors.Hand,
        };
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var thumb = new Border { Width = w, Height = h, CornerRadius = new CornerRadius(12), Background = Ui.Placeholder };
        var tg = new Grid { Clip = new RectangleGeometry(new Rect(0, 0, w, h), 12, 12) };
        tg.Children.Add(Art(lib.ArtPath(ep, ep.ThumbUrl) ?? lib.Backdrop(ep), 460));
        if (ep.InProgress) tg.Children.Add(new Border { Child = ProgressBar(ep.Progress, w - 20), Margin = new Thickness(10), VerticalAlignment = VerticalAlignment.Bottom });
        if (ep.Watched) tg.Children.Add(Badge(Icon(IcoCheck, 10, Brushes.White)));
        var play = new Border
        {
            Width = 50, Height = 50, CornerRadius = new CornerRadius(25), Background = new SolidColorBrush(Color.FromArgb(0x70, 0, 0, 0)),
            BorderBrush = Ui.GlassEdge, BorderThickness = new Thickness(1), Opacity = 0,
            Child = Icon(IcoPlay, 17, Brushes.White).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(3, 0, 0, 0); }),
        };
        tg.Children.Add(play);
        thumb.Child = tg;
        g.Children.Add(thumb);

        var text = new StackPanel { Margin = new Thickness(22, 4, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        Grid.SetColumn(text, 1);
        text.Children.Add(T($"Episode {ep.Index}", 12, FontWeights.Bold, Ui.Accent));
        text.Children.Add(T(ep.Title, 18, FontWeights.SemiBold).With(t => t.Margin = new Thickness(0, 4, 0, 0)));
        var meta = new List<string>();
        if (ep.Runtime != "") meta.Add(ep.InProgress ? ep.RemainingText : ep.Runtime);
        if (ep.Aired is { } d) meta.Add(d.ToString("MMM d, yyyy"));
        if (meta.Count > 0) text.Children.Add(T(string.Join("  ·  ", meta), 12.5, FontWeights.SemiBold, Muted).With(t => t.Margin = new Thickness(0, 4, 0, 0)));
        if (ep.Summary != "")
            text.Children.Add(T(ep.Summary, 13.5, color: Muted).With(t =>
            {
                t.TextWrapping = TextWrapping.Wrap; t.MaxHeight = 62; t.TextTrimming = TextTrimming.WordEllipsis; t.LineHeight = 20; t.Margin = new Thickness(0, 8, 0, 0);
            }));
        g.Children.Add(text);
        row.Child = g;

        var dur = TimeSpan.FromMilliseconds(140);
        row.MouseEnter += (_, _) => { row.Background = Ui.GlassFill; play.BeginAnimation(OpacityProperty, new DoubleAnimation(1, dur)); };
        row.MouseLeave += (_, _) => { row.Background = Brushes.Transparent; play.BeginAnimation(OpacityProperty, new DoubleAnimation(0, dur)); };
        row.MouseLeftButtonUp += (_, _) => shell.Play(ep);
        return row;
    }
}
