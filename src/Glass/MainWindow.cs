using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Glass.Controls;
using Glass.Data;
using Glass.Player;
using Glass.Views;
using Microsoft.Win32;
using static Glass.Controls.Ui;

namespace Glass;

public sealed class MainWindow : Window, IShell
{
    readonly Settings settings = Settings.Load();
    public PlexLibrary Library { get; private set; }
    public Settings Settings => settings;
    public void SaveSettings() => settings.Save();
    public void RefreshPage() => RefreshCurrent(currentKey);

    public IReadOnlyList<Section> Sections
    {
        get
        {
            foreach (var s in Library.Sections)
                s.Name = settings.SectionNames.TryGetValue(s.Id, out var n) && !string.IsNullOrWhiteSpace(n) ? n : s.PlexName;
            return Library.Sections
                .Where(s => !settings.HiddenSections.Contains(s.Id))
                .OrderBy(s => { var i = settings.SectionOrder.IndexOf(s.Id); return i < 0 ? 1000 + s.Id : i; })
                .ToList();
        }
    }

    readonly Grid root = new();
    readonly Grid pageHost = new();
    readonly Border sidebar;
    readonly StackPanel nav = new();
    readonly Grid playerLayer = new() { Background = Brushes.Black, Visibility = Visibility.Collapsed };
    readonly Border loading;
    MpvPlayer? mpv;

    readonly Stack<(FrameworkElement page, string key, double scroll)> back = new();
    FrameworkElement? current;
    string currentKey = "";

    WindowState stateBeforeFs;
    WindowStyle styleBeforeFs;
    bool fullscreen;

    public MainWindow()
    {
        Title = "Glass";
        Width = 1500; Height = 920; MinWidth = 900; MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Ui.Bg;
        FontFamily = Ui.Font;
        try { Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/glass.ico")); } catch { }
        Library = new PlexLibrary(settings);
        Ui.MenuFor = MenuFor;

        root.Children.Add(pageHost);
        if (settings.SidebarExpanded) pageHost.Margin = new Thickness(NavExpanded - NavCollapsed, 0, 0, 0);

        sidebar = BuildSidebar();
        root.Children.Add(sidebar);

        playerLayer.Children.Add(T("Starting mpv…", 14, color: Ui.Muted).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.VerticalAlignment = VerticalAlignment.Center; }));
        root.Children.Add(playerLayer);
        // mpv's window follows the app window
        LocationChanged += (_, _) => SyncPlayer();
        SizeChanged += (_, _) => SyncPlayer();
        playerLayer.MouseLeftButtonDown += (_, _) => mpv?.Focus();

        loading = new Border
        {
            Background = Ui.Bg,
            Child = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Children = { T("Glass", 40, FontWeights.Black).With(t => t.HorizontalAlignment = HorizontalAlignment.Center),
                             T("Reading your library…", 14, color: Muted).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 10, 0, 0); }) }
            }
        };
        root.Children.Add(loading);
        Content = root;

        SourceInitialized += (_, _) => DarkTitleBar();
        Loaded += async (_, _) => await Reload(goHome: true);
        PreviewKeyDown += OnKey;
        MouseUp += (_, e) => { if (e.ChangedButton == MouseButton.XButton1) GoBack(); };
        Closing += (_, _) => mpv?.Stop();
    }

    // ---------------------------------------------------------------- library

    async Task Reload(bool goHome)
    {
        var lib = new PlexLibrary(settings);
        await Task.Run(lib.Load);
        Library = lib;
        if (loading.Visibility == Visibility.Visible)
        {
            loading.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(300)));
            await Task.Delay(300);
            loading.Visibility = Visibility.Collapsed;
        }
        RebuildNav();
        if (goHome) { back.Clear(); Show(new HomePage(this), "home", animate: true); }
    }

    // ---------------------------------------------------------------- navigation

    public void Navigate(FrameworkElement page, string key)
    {
        if (current != null) back.Push((current, currentKey, (current as GlassPage)?.Scroller.VerticalOffset ?? 0));
        Show(page, key, animate: true);
    }

    void Show(FrameworkElement page, string key, bool animate, double scroll = 0)
    {
        pageHost.Children.Clear();
        pageHost.Children.Add(page);
        current = page;
        currentKey = key;
        HighlightNav();
        if (page is GlassPage p && scroll > 0) p.Loaded += (_, _) => p.Scroller.ScrollToVerticalOffset(scroll);
        if (animate)
        {
            page.Opacity = 0;
            var tt = new TranslateTransform(0, 18);
            page.RenderTransform = tt;
            var dur = TimeSpan.FromMilliseconds(320);
            page.BeginAnimation(OpacityProperty, new DoubleAnimation(1, dur));
            tt.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, dur) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        }
    }

    void GoBack()
    {
        if (playerLayer.Visibility == Visibility.Visible) return;
        if (back.Count == 0) return;
        var (page, key, scroll) = back.Pop();
        Show(page, key, animate: true, scroll);
        if (page is GlassPage p) p.Scroller.ScrollToVerticalOffset(scroll);
    }

    void GoTo(string key, Func<FrameworkElement> make)
    {
        if (currentKey == key && back.Count == 0) return;
        back.Clear();
        Show(make(), key, animate: true);
    }

    // ---------------------------------------------------------------- right-click menu

    IEnumerable<(string, string, Action)?> MenuFor(Item it)
    {
        const string IcoRestart = "\uE72C", IcoEye = "\uE7B3", IcoEyeOff = "\uED1A", IcoList = "\uE8FD", IcoShow = "\uE7F4";
        var list = new List<(string, string, Action)?>();
        if (it.IsPlayable)
        {
            list.Add((it.InProgress ? $"Resume  ·  {it.RemainingText}" : "Play", IcoPlay, () => Play(it)));
            if (it.InProgress || it.Watched) list.Add(("Play from beginning", IcoRestart, () => Play(it, fromStart: true)));
            list.Add(null);
            list.Add(it.Watched ? ("Mark as unwatched", IcoEyeOff, () => Mark(new[] { it }, false))
                                : ("Mark as watched", IcoEye, () => Mark(new[] { it }, true)));
            if (it.Kind == Kind.Episode && it.Season is { } season)
            {
                var rest = season.Children.Where(e => e.File != null && e.Index <= it.Index).ToList();
                if (rest.Count > 1) list.Add(("Mark watched up to here", IcoCheck, () => Mark(rest, true)));
                list.Add(null);
                list.Add(($"Go to {(season.Title != "" ? season.Title : $"Season {season.Index}")}", IcoList,
                    () => Navigate(new DetailPage(this, it.Show, season), "item:" + it.Show.Id)));
                list.Add(($"Go to {it.Show.Title}", IcoShow, () => OpenItem(it.Show)));
            }
            else if (it.Kind == Kind.Movie)
            {
                list.Add(null);
                list.Add(("Details", IcoInfo, () => OpenItem(it)));
            }
        }
        else if (it.Kind == Kind.Show)
        {
            list.Add(("Open", IcoShow, () => OpenItem(it)));
            if (it.UpNext() is { } next)
                list.Add(($"{(next.InProgress ? "Resume" : "Play")} {next.Code.Replace(" · ", " ")}", IcoPlay, () => Play(next)));
            list.Add(null);
            var eps = it.Episodes.Where(e => e.File != null).ToList();
            if (eps.Any(e => !e.Watched)) list.Add(("Mark show as watched", IcoEye, () => Mark(eps, true)));
            if (eps.Any(e => e.Watched || e.InProgress)) list.Add(("Mark show as unwatched", IcoEyeOff, () => Mark(eps, false)));
        }
        return list;
    }

    async void Mark(IEnumerable<Item> items, bool watched)
    {
        await WatchState.SetAsync(settings, items, watched);
        RefreshCurrent(currentKey);
    }

    public void OpenItem(Item item) => Navigate(new DetailPage(this, item), "item:" + item.Show.Id);
    public void OpenSection(Section s) => Navigate(new SectionPage(this, s), "section:" + s.Id);

    // ---------------------------------------------------------------- sidebar

    const double NavCollapsed = 60, NavExpanded = 232;
    readonly StackPanel navFooter = new();
    readonly StackPanel navHeader = new();

    Border BuildSidebar()
    {
        var stack = new DockPanel { LastChildFill = false, Margin = new Thickness(6) };
        DockPanel.SetDock(navHeader, Dock.Top);
        stack.Children.Add(navHeader);
        DockPanel.SetDock(nav, Dock.Top);
        nav.Margin = new Thickness(0, 4, 0, 0);
        stack.Children.Add(nav);
        DockPanel.SetDock(navFooter, Dock.Top);
        stack.Children.Add(navFooter);
        var bar = new Border
        {
            Width = settings.SidebarExpanded ? NavExpanded : NavCollapsed, Margin = new Thickness(12),
            CornerRadius = new CornerRadius(18),
            Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x17, 0x19, 0x1F)), BorderBrush = Ui.GlassEdge, BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Child = stack,
        };
        bar.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 28, ShadowDepth = 6, Opacity = 0.55, Color = Colors.Black };
        return bar;
    }

    void ToggleSidebar()
    {
        settings.SidebarExpanded = !settings.SidebarExpanded;
        settings.Save();
        var to = settings.SidebarExpanded ? NavExpanded : NavCollapsed;
        var dur = TimeSpan.FromMilliseconds(260);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        sidebar.BeginAnimation(WidthProperty, new DoubleAnimation(to, dur) { EasingFunction = ease });
        // push the page over so nothing hides behind the wider bar
        pageHost.BeginAnimation(MarginProperty, new ThicknessAnimation(new Thickness(settings.SidebarExpanded ? NavExpanded - NavCollapsed : 0, 0, 0, 0), dur) { EasingFunction = ease });
        RebuildNav();
    }

    void RebuildNav()
    {
        navHeader.Children.Clear();
        navHeader.Children.Add(NavButton("toggle", "\uE700", settings.SidebarExpanded ? "Collapse" : "Expand", ToggleSidebar));
        navHeader.Children.Add(new Border { Height = 1, Background = Ui.GlassEdge, Margin = new Thickness(6, 4, 6, 2) });
        nav.Children.Clear();
        nav.Children.Add(NavButton("home", IcoHome, "Home", () => GoTo("home", () => new HomePage(this))));
        foreach (var s in Sections)
        {
            var sec = s;
            nav.Children.Add(NavButton("section:" + s.Id, s.IsMovies ? IcoMovie : IcoTv, s.Name, () => GoTo("section:" + sec.Id, () => new SectionPage(this, sec))));
        }
        nav.Children.Add(NavButton("search", IcoSearch, "Search", () => GoTo("search", () => new SearchPage(this))));
        navFooter.Children.Clear();
        navFooter.Children.Add(new Border { Height = 1, Background = Ui.GlassEdge, Margin = new Thickness(6, 6, 6, 6) });
        navFooter.Children.Add(NavButton("libraries", "\uE70F", "Edit libraries", () => GoTo("libraries", () => new LibrariesPage(this, RebuildNav))));
        navFooter.Children.Add(NavButton("refresh", IcoRefresh, "Refresh", async () => await Reload(goHome: currentKey == "home")));
        navFooter.Children.Add(NavButton("settings", IcoSettings, "Settings", ShowSettings));
        HighlightNav();
    }

    static readonly Brush NavHover = new SolidColorBrush(Color.FromArgb(0x24, 0xF0, 0x30, 0x2C));
    static readonly Brush NavActive = new SolidColorBrush(Color.FromArgb(0x38, 0xF0, 0x30, 0x2C));

    /// <summary>A sidebar row in the same style as the right-click menu: icon column, label when expanded.</summary>
    Border NavButton(string key, string glyph, string label, Action click)
    {
        var g = new Grid { Height = 42 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(46) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = Icon(glyph, 16, Ui.Muted).With(i => { i.HorizontalAlignment = HorizontalAlignment.Center; i.TextAlignment = TextAlignment.Center; });
        g.Children.Add(icon);
        var text = T(label, 13.5, FontWeights.SemiBold, Ui.Muted).With(t => { t.VerticalAlignment = VerticalAlignment.Center; t.Margin = new Thickness(0, 0, 12, 0); });
        Grid.SetColumn(text, 1);
        text.Visibility = settings.SidebarExpanded ? Visibility.Visible : Visibility.Collapsed;
        g.Children.Add(text);
        var row = new Border
        {
            Child = g, CornerRadius = new CornerRadius(11), Margin = new Thickness(0, 1, 0, 1), Tag = key,
            Background = Brushes.Transparent, Cursor = Cursors.Hand,
        };
        if (!settings.SidebarExpanded)
            row.ToolTip = new ToolTip { Content = label, Placement = System.Windows.Controls.Primitives.PlacementMode.Right };
        row.MouseEnter += (_, _) => { if (!IsActive(row)) { row.Background = NavHover; icon.Foreground = Ui.Accent; text.Foreground = Ui.Text; } };
        row.MouseLeave += (_, _) => HighlightNav();
        row.MouseLeftButtonUp += (_, e) => { e.Handled = true; click(); };
        return row;
    }

    bool IsActive(Border row)
    {
        var key = currentKey.StartsWith("item:") ? "" : currentKey;
        return (string?)row.Tag == key;
    }

    void HighlightNav()
    {
        foreach (var panel in new[] { nav, navFooter })
            foreach (var c in panel.Children)
                if (c is Border { Child: Grid g } row && row.Tag is string)
                {
                    var on = IsActive(row);
                    row.Background = on ? NavActive : Brushes.Transparent;
                    foreach (var t in g.Children.OfType<TextBlock>())
                        t.Foreground = on ? (t.FontFamily == Ui.Icons ? Ui.Accent : Ui.Text) : Ui.Muted;
                }
    }

    // ---------------------------------------------------------------- playback

    public void Play(Item item, bool fromStart = false)
    {
        if (settings.MpvPath == null || !File.Exists(settings.MpvPath))
        {
            if (!AskForMpv()) return;
        }
        List<Item> list;
        if (item.Kind == Kind.Episode) list = item.Show.Episodes.Where(e => e.File != null).ToList();
        else if (item.Kind == Kind.Show) { OpenItem(item); return; }
        else list = new() { item };
        var start = Math.Max(0, list.IndexOf(item));

        mpv ??= CreatePlayer();
        sidebar.Visibility = Visibility.Collapsed;
        playerLayer.Visibility = Visibility.Visible;
        playerLayer.Opacity = 0;
        playerLayer.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(200)));
        Dispatcher.BeginInvoke(() => mpv.Play(new WindowInteropHelper(this).Handle, PlayerRect(), list.Select(i => i.File!).ToList(), start, fromStart),
            System.Windows.Threading.DispatcherPriority.Loaded);
    }

    /// <summary>The player area in screen pixels.</summary>
    (int x, int y, int w, int h) PlayerRect()
    {
        var src = PresentationSource.FromVisual(root);
        if (src?.CompositionTarget == null) return (0, 0, 1280, 720);
        var m = src.CompositionTarget.TransformToDevice;
        var tl = root.PointToScreen(new Point(0, 0));
        return ((int)Math.Round(tl.X), (int)Math.Round(tl.Y), (int)Math.Round(root.ActualWidth * m.M11), (int)Math.Round(root.ActualHeight * m.M22));
    }

    void SyncPlayer()
    {
        if (mpv?.Running == true && playerLayer.Visibility == Visibility.Visible && WindowState != WindowState.Minimized)
            mpv.SetBounds(PlayerRect());
    }

    MpvPlayer CreatePlayer()
    {
        var p = new MpvPlayer(settings.MpvPath!);
        p.Exited += () => Dispatcher.BeginInvoke(async () =>
        {
            SetFullscreen(false);
            playerLayer.Visibility = Visibility.Collapsed;
            sidebar.Visibility = Visibility.Visible;
            Activate();
            // pick up the new watch progress
            var keep = currentKey;
            await Reload(goHome: false);
            RefreshCurrent(keep);
        });
        // mpv handles its own fullscreen now; when it comes back, put it over the player area again
        p.FullscreenChanged += fs => Dispatcher.BeginInvoke(() => { if (!fs) SyncPlayer(); });
        return p;
    }

    void RefreshCurrent(string key)
    {
        double scroll = (current as GlassPage)?.Scroller.VerticalOffset ?? 0;
        FrameworkElement? page = null;
        if (key == "home") page = new HomePage(this);
        else if (key.StartsWith("item:") && int.TryParse(key[5..], out var id) && Library.ById.TryGetValue(id, out var it)) page = new DetailPage(this, it);
        else if (key.StartsWith("section:") && int.TryParse(key[8..], out var sid) && Sections.FirstOrDefault(s => s.Id == sid) is { } sec) page = new SectionPage(this, sec);
        if (page == null) return;
        // older pages in the back stack keep old progress; that's fine for v1
        Show(page, key, animate: false, scroll);
    }

    void SetFullscreen(bool on)
    {
        if (on == fullscreen) return;
        fullscreen = on;
        if (on)
        {
            stateBeforeFs = WindowState; styleBeforeFs = WindowStyle;
            WindowStyle = WindowStyle.None;
            if (WindowState == WindowState.Maximized) WindowState = WindowState.Normal;
            WindowState = WindowState.Maximized;
        }
        else
        {
            WindowStyle = styleBeforeFs;
            WindowState = stateBeforeFs;
        }
    }

    bool AskForMpv()
    {
        var dlg = new OpenFileDialog { Title = "Where is mpv.exe?", Filter = "mpv|mpv.exe|Programs|*.exe" };
        if (dlg.ShowDialog(this) != true) return false;
        settings.MpvPath = dlg.FileName;
        settings.Save();
        mpv = null;
        return true;
    }

    // ---------------------------------------------------------------- settings

    void ShowSettings()
    {
        var page = new GlassPage();
        page.Body.Margin = new Thickness(64, 70, 64, 40);
        page.Body.Children.Add(T("Settings", 34, FontWeights.Bold));
        page.Body.Children.Add(T("Glass finds these on its own; change them if it guessed wrong.", 14, color: Muted).With(t => t.Margin = new Thickness(0, 6, 0, 30)));

        FrameworkElement PathRow(string label, string? value, string button, Action pick)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 0, 0, 22) };
            sp.Children.Add(T(label, 13, FontWeights.SemiBold, Muted));
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            row.Children.Add(new Border
            {
                Background = Ui.GlassFill, BorderBrush = Ui.GlassEdge, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14, 9, 14, 9), Width = 640, Child = T(value ?? "Not found", 14, color: value == null ? Ui.Accent : Ui.Text),
            });
            row.Children.Add(Pill(button, IcoFolder, pick, height: 40).With(b => b.Margin = new Thickness(12, 0, 0, 0)));
            sp.Children.Add(row);
            return sp;
        }

        page.Body.Children.Add(PathRow("mpv", settings.MpvPath, "Choose", () => { if (AskForMpv()) ShowSettings(); }));
        page.Body.Children.Add(PathRow("Plex data folder", settings.PlexDataPath, "Choose", async () =>
        {
            var dlg = new OpenFolderDialog { Title = "Choose the \"Plex Media Server\" folder" };
            if (dlg.ShowDialog(this) != true) return;
            settings.PlexDataPath = dlg.FolderName;
            settings.Save();
            await Reload(goHome: false);
            ShowSettings();
        }));
        page.Body.Children.Add(T($"Library: {Library.Sections.Count} libraries, {Library.ById.Count} items" + (Library.Error != null ? " — " + Library.Error : ""),
            13, color: Muted).With(t => t.Margin = new Thickness(0, 10, 0, 0)));
        GoTo("settings", () => page);
        if (currentKey == "settings" && current != page) Show(page, "settings", animate: false);
    }

    // ---------------------------------------------------------------- keys

    void OnKey(object sender, KeyEventArgs e)
    {
        if (playerLayer.Visibility == Visibility.Visible) return;   // mpv has its own keys
        if (e.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control) { GoTo("search", () => new SearchPage(this)); e.Handled = true; }
        else if (e.Key == Key.Escape || e.Key == Key.Back && e.OriginalSource is not TextBox) { GoBack(); e.Handled = true; }
        else if (e.Key == Key.F5) { _ = Reload(goHome: currentKey == "home"); e.Handled = true; }
    }

    // ---------------------------------------------------------------- dark title bar

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    void DarkTitleBar()
    {
        var h = new WindowInteropHelper(this).Handle;
        int on = 1;
        DwmSetWindowAttribute(h, 20, ref on, sizeof(int));                 // immersive dark mode
        int caption = 0x00130F0E;                                          // COLORREF (BGR) of #0E0F13
        DwmSetWindowAttribute(h, 35, ref caption, sizeof(int));            // caption colour (Windows 11)
    }
}
