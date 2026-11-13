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

    readonly Grid root = new();
    readonly Grid pageHost = new();
    readonly Border sidebar;
    readonly StackPanel nav = new();
    readonly Grid playerLayer = new() { Background = Brushes.Black, Visibility = Visibility.Collapsed };
    readonly MpvHost mpvHost = new();
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

        root.Children.Add(pageHost);

        sidebar = BuildSidebar();
        root.Children.Add(sidebar);

        playerLayer.Children.Add(mpvHost);
        root.Children.Add(playerLayer);

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
        if (current != null) back.Push((current, currentKey, (current as Page)?.Scroller.VerticalOffset ?? 0));
        Show(page, key, animate: true);
    }

    void Show(FrameworkElement page, string key, bool animate, double scroll = 0)
    {
        pageHost.Children.Clear();
        pageHost.Children.Add(page);
        current = page;
        currentKey = key;
        HighlightNav();
        if (page is Page p && scroll > 0) p.Loaded += (_, _) => p.Scroller.ScrollToVerticalOffset(scroll);
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
        if (page is Page p) p.Scroller.ScrollToVerticalOffset(scroll);
    }

    void GoTo(string key, Func<FrameworkElement> make)
    {
        if (currentKey == key && back.Count == 0) return;
        back.Clear();
        Show(make(), key, animate: true);
    }

    public void OpenItem(Item item) => Navigate(new DetailPage(this, item), "item:" + item.Show.Id);
    public void OpenSection(Section s) => Navigate(new SectionPage(this, s), "section:" + s.Id);

    // ---------------------------------------------------------------- sidebar

    Border BuildSidebar()
    {
        nav.Margin = new Thickness(0, 18, 0, 18);
        var bar = new Border
        {
            Width = 64, Margin = new Thickness(12), CornerRadius = new CornerRadius(22),
            Background = new SolidColorBrush(Color.FromArgb(0x8C, 0x16, 0x18, 0x1E)), BorderBrush = Ui.GlassEdge, BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Child = nav,
        };
        bar.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 30, ShadowDepth = 0, Opacity = 0.5, Color = Colors.Black };
        return bar;
    }

    void RebuildNav()
    {
        nav.Children.Clear();
        nav.Children.Add(NavButton("home", IcoHome, "Home", () => GoTo("home", () => new HomePage(this))));
        foreach (var s in Library.Sections.Where(s => !settings.HiddenSections.Contains(s.Name)))
        {
            var sec = s;
            nav.Children.Add(NavButton("section:" + s.Id, s.IsMovies ? IcoMovie : IcoTv, s.Name, () => GoTo("section:" + sec.Id, () => new SectionPage(this, sec))));
        }
        nav.Children.Add(NavButton("search", IcoSearch, "Search  (Ctrl+F)", () => GoTo("search", () => new SearchPage(this))));
        nav.Children.Add(new Border { Height = 1, Background = Ui.GlassEdge, Margin = new Thickness(16, 8, 16, 8) });
        nav.Children.Add(NavButton("refresh", IcoRefresh, "Refresh library", async () => await Reload(goHome: currentKey == "home")));
        nav.Children.Add(NavButton("settings", IcoSettings, "Settings", ShowSettings));
        HighlightNav();
    }

    Button NavButton(string key, string glyph, string tip, Action click)
    {
        var b = Chrome(Icon(glyph, 18, Ui.Muted).With(i => i.HorizontalAlignment = HorizontalAlignment.Center),
            Brushes.Transparent, Ui.GlassFill, new CornerRadius(14), new Thickness(0));
        b.Width = 46; b.Height = 46; b.Margin = new Thickness(0, 3, 0, 3); b.Tag = key; b.BorderThickness = new Thickness(0);
        b.ToolTip = new ToolTip { Content = tip, Placement = System.Windows.Controls.Primitives.PlacementMode.Right };
        b.Click += (_, _) => click();
        return b;
    }

    void HighlightNav()
    {
        var key = currentKey.StartsWith("item:") ? "" : currentKey;
        foreach (var c in nav.Children)
            if (c is Button b && b.Content is TextBlock t)
                t.Foreground = (string?)b.Tag == key ? Ui.Accent : Ui.Muted;
    }

    // ---------------------------------------------------------------- playback

    public void Play(Item item)
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
        // let WPF create the child window before mpv attaches to it
        Dispatcher.BeginInvoke(() => mpv.Play(mpvHost.Handle2, list.Select(i => i.File!).ToList(), start),
            System.Windows.Threading.DispatcherPriority.Loaded);
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
        p.FullscreenChanged += fs => Dispatcher.BeginInvoke(() => SetFullscreen(fs));
        return p;
    }

    void RefreshCurrent(string key)
    {
        double scroll = (current as Page)?.Scroller.VerticalOffset ?? 0;
        FrameworkElement? page = null;
        if (key == "home") page = new HomePage(this);
        else if (key.StartsWith("item:") && int.TryParse(key[5..], out var id) && Library.ById.TryGetValue(id, out var it)) page = new DetailPage(this, it);
        else if (key.StartsWith("section:") && int.TryParse(key[8..], out var sid) && Library.Sections.FirstOrDefault(s => s.Id == sid) is { } sec) page = new SectionPage(this, sec);
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
        var page = new Page();
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
