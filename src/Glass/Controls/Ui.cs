using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Glass.Data;

namespace Glass.Controls;

/// <summary>Small factory for the app's look, so pages stay readable.</summary>
public static class Ui
{
    public static readonly Color AccentColor = Color.FromRgb(0xF0, 0x30, 0x2C);
    public static readonly Brush Accent = Freeze(new SolidColorBrush(AccentColor));
    public static readonly Color BgColor = Color.FromRgb(0x0E, 0x0F, 0x13);
    public static readonly Brush Bg = Freeze(new SolidColorBrush(BgColor));
    public static readonly Brush Text = Freeze(new SolidColorBrush(Color.FromRgb(0xF4, 0xF5, 0xF7)));
    public static readonly Brush Muted = Freeze(new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush Faint = Freeze(new SolidColorBrush(Color.FromArgb(0x66, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush GlassFill = Freeze(new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush GlassHover = Freeze(new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush GlassEdge = Freeze(new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)));
    public static readonly Brush Placeholder = Freeze(new SolidColorBrush(Color.FromRgb(0x1A, 0x1C, 0x22)));
    /// <summary>Left edge of page content, clear of the collapsed sidebar.</summary>
    public const double Inset = 100;
    public static readonly FontFamily Font = new("Inter, Segoe UI Variable Display, Segoe UI");
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    // Segoe Fluent / MDL2 glyphs
    public const string IcoHome = "", IcoTv = "", IcoMovie = "", IcoSearch = "", IcoSettings = "",
        IcoPlay = "", IcoBack = "", IcoCheck = "", IcoChevronR = "", IcoChevronL = "", IcoRefresh = "",
        IcoFolder = "", IcoInfo = "";

    static T Freeze<T>(T f) where T : Freezable { f.Freeze(); return f; }

    public static TextBlock T(string text, double size = 14, FontWeight? weight = null, Brush? color = null, double opacity = 1)
        => new()
        {
            Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, Foreground = color ?? Text,
            FontFamily = Font, Opacity = opacity, TextTrimming = TextTrimming.CharacterEllipsis,
        };

    public static TextBlock Icon(string glyph, double size = 16, Brush? color = null)
        => new() { Text = glyph, FontFamily = Icons, FontSize = size, Foreground = color ?? Text, VerticalAlignment = VerticalAlignment.Center };

    public static Image Art(string? path, int decodeWidth, Stretch stretch = Stretch.UniformToFill)
    {
        var img = new Image { Stretch = stretch };
        RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
        Controls.Art.SetWidth(img, decodeWidth);
        Controls.Art.SetPath(img, path);
        return img;
    }

    /// <summary>Pill button. Accent = solid red, otherwise translucent glass.</summary>
    public static Button Pill(string label, string? glyph, Action onClick, bool accent = false, double height = 40)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (glyph != null) sp.Children.Add(new TextBlock { Text = glyph, FontFamily = Icons, FontSize = 14, Margin = new Thickness(0, 1, 8, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = Brushes.White });
        sp.Children.Add(new TextBlock { Text = label, FontFamily = Font, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center });
        var b = Chrome(sp, accent ? Accent : GlassFill, accent ? new SolidColorBrush(Color.FromRgb(0xFF, 0x4A, 0x45)) : GlassHover, new CornerRadius(height / 2), new Thickness(20, 0, 20, 0));
        b.Height = height;
        b.Click += (_, _) => onClick();
        return b;
    }

    public static Button Round(string glyph, Action onClick, double size = 40, string? tip = null)
    {
        var b = Chrome(new TextBlock { Text = glyph, FontFamily = Icons, FontSize = size * 0.36, Foreground = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            GlassFill, GlassHover, new CornerRadius(size / 2), new Thickness(0));
        b.Width = b.Height = size;
        b.ToolTip = tip;
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>A Button whose whole look is one rounded border with a hover tint.</summary>
    public static Button Chrome(UIElement content, Brush fill, Brush hover, CornerRadius radius, Thickness padding, bool stretch = false)
    {
        var tpl = new ControlTemplate(typeof(Button));
        var bd = new FrameworkElementFactory(typeof(Border), "bd");
        bd.SetValue(Border.BackgroundProperty, fill);
        bd.SetValue(Border.CornerRadiusProperty, radius);
        bd.SetValue(Border.BorderBrushProperty, GlassEdge);
        bd.SetValue(Border.BorderThicknessProperty, new Thickness(fill == Accent ? 0 : 1));
        bd.SetValue(Border.PaddingProperty, padding);
        var cp = new FrameworkElementFactory(typeof(ContentPresenter));
        cp.SetValue(ContentPresenter.HorizontalAlignmentProperty, stretch ? HorizontalAlignment.Stretch : HorizontalAlignment.Center);
        cp.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        bd.AppendChild(cp);
        tpl.VisualTree = bd;
        var over = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        over.Setters.Add(new Setter(Border.BackgroundProperty, hover, "bd"));
        tpl.Triggers.Add(over);
        var press = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        press.Setters.Add(new Setter(UIElement.OpacityProperty, 0.8, "bd"));
        tpl.Triggers.Add(press);
        return new Button { Template = tpl, Content = content, Cursor = Cursors.Hand, Focusable = false };
    }

    /// <summary>Gentle grow + glow on hover for cards.</summary>
    public static void Hoverable(FrameworkElement el, Border frame)
    {
        var st = new ScaleTransform(1, 1);
        el.RenderTransform = st;
        el.RenderTransformOrigin = new Point(0.5, 0.5);
        el.Cursor = Cursors.Hand;
        var glow = new DropShadowEffect { Color = AccentColor, BlurRadius = 0, ShadowDepth = 0, Opacity = 0.0 };
        frame.Effect = glow;
        var dur = TimeSpan.FromMilliseconds(160);
        var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut };
        void To(double s, double o, double blur)
        {
            st.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(s, dur) { EasingFunction = ease });
            st.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(s, dur) { EasingFunction = ease });
            glow.BeginAnimation(DropShadowEffect.OpacityProperty, new DoubleAnimation(o, dur));
            glow.BeginAnimation(DropShadowEffect.BlurRadiusProperty, new DoubleAnimation(blur, dur));
        }
        el.MouseEnter += (_, _) => { Panel.SetZIndex(el, 1); To(1.045, 0.55, 22); };
        el.MouseLeave += (_, _) => { Panel.SetZIndex(el, 0); To(1, 0, 0); };
    }

    public static UIElement ProgressBar(double value, double width)
    {
        var g = new Grid { Height = 4, Width = width, VerticalAlignment = VerticalAlignment.Bottom };
        g.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF)), CornerRadius = new CornerRadius(2) });
        g.Children.Add(new Border { Background = Accent, CornerRadius = new CornerRadius(2), Width = Math.Max(4, width * value), HorizontalAlignment = HorizontalAlignment.Left });
        return g;
    }

    public static Border Badge(UIElement content, Brush? bg = null) => new()
    {
        Child = content, Background = bg ?? Accent, CornerRadius = new CornerRadius(10), Padding = new Thickness(7, 2, 7, 2),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8),
    };

    /// <summary>Portrait poster card (shows, movies, seasons).</summary>
    public static FrameworkElement PosterCard(PlexLibrary lib, Item it, double w, Action onClick)
    {
        var h = w * 1.5;
        var frame = new Border { Width = w, Height = h, CornerRadius = new CornerRadius(10), Background = Placeholder, ClipToBounds = true };
        var g = new Grid();
        var img = Art(lib.Poster(it), (int)(w * 1.6));
        g.Children.Add(new Border { CornerRadius = new CornerRadius(10), Child = img, Clip = new RectangleGeometry(new Rect(0, 0, w, h), 10, 10) });
        if (it.Kind is Kind.Movie && it.Watched || it.Kind is Kind.Show && it.UnwatchedCount == 0)
            g.Children.Add(Badge(Icon(IcoCheck, 10, Brushes.White)));
        else if (it.Kind is Kind.Show && it.UnwatchedCount > 0 && it.Episodes.Any(e => e.Watched))
            g.Children.Add(Badge(T(it.UnwatchedCount.ToString(), 11, FontWeights.Bold, Brushes.White)));
        if (it.InProgress) g.Children.Add(new Border { Child = ProgressBar(it.Progress, w - 16), Margin = new Thickness(8), VerticalAlignment = VerticalAlignment.Bottom });
        frame.Child = g;

        var sp = new StackPanel { Width = w };
        sp.Children.Add(frame);
        sp.Children.Add(T(it.DisplayTitle, 13, FontWeights.SemiBold).With(t => t.Margin = new Thickness(2, 8, 2, 0)));
        var sub = it.Kind == Kind.Show ? $"{it.Children.Count} season{(it.Children.Count == 1 ? "" : "s")}" : it.SubLine;
        if (sub != "") sp.Children.Add(T(sub, 12, color: Muted).With(t => t.Margin = new Thickness(2, 2, 2, 0)));
        Hoverable(frame, frame);
        sp.Cursor = Cursors.Hand;
        sp.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        sp.ToolTip = null;
        return sp;
    }

    /// <summary>Landscape card with an episode still (Continue watching).</summary>
    public static FrameworkElement StillCard(PlexLibrary lib, Item it, double w, Action onClick)
    {
        var h = w * 9 / 16;
        var frame = new Border { Width = w, Height = h, CornerRadius = new CornerRadius(12), Background = Placeholder };
        var g = new Grid { Clip = new RectangleGeometry(new Rect(0, 0, w, h), 12, 12) };
        g.Children.Add(Art(lib.Still(it), (int)(w * 1.5)));
        g.Children.Add(new Rectangle
        {
            Fill = new LinearGradientBrush(Colors.Transparent, Color.FromArgb(0xB0, 0, 0, 0), 90),
            Height = h * 0.45, VerticalAlignment = VerticalAlignment.Bottom,
        });
        // show logo on the still when there is one, like the big apps do
        var logo = lib.Logo(it);
        if (logo != null)
            g.Children.Add(Art(logo, 360, Stretch.Uniform).With(i =>
            {
                i.MaxWidth = w * 0.42; i.MaxHeight = h * 0.28; i.HorizontalAlignment = HorizontalAlignment.Left;
                i.VerticalAlignment = VerticalAlignment.Bottom; i.Margin = new Thickness(12, 0, 0, 18);
            }));
        if (it.InProgress) g.Children.Add(new Border { Child = ProgressBar(it.Progress, w - 24), Margin = new Thickness(12, 0, 12, 9), VerticalAlignment = VerticalAlignment.Bottom });
        var play = new Border
        {
            Width = 46, Height = 46, CornerRadius = new CornerRadius(23), Background = new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)),
            BorderBrush = GlassEdge, BorderThickness = new Thickness(1), Opacity = 0,
            Child = Icon(IcoPlay, 16, Brushes.White).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(3, 0, 0, 0); }),
        };
        g.Children.Add(play);
        frame.Child = g;

        var sp = new StackPanel { Width = w };
        sp.Children.Add(frame);
        sp.Children.Add(T(it.DisplayTitle, 14, FontWeights.SemiBold).With(t => t.Margin = new Thickness(2, 9, 2, 0)));
        var sub = it.Kind == Kind.Episode ? $"{it.Code} · {it.Title}" : it.SubLine;
        sp.Children.Add(T(sub + (it.InProgress ? "  ·  " + it.RemainingText : ""), 12, color: Muted).With(t => t.Margin = new Thickness(2, 2, 2, 0)));
        Hoverable(frame, frame);
        frame.MouseEnter += (_, _) => play.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(150)));
        frame.MouseLeave += (_, _) => play.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(150)));
        sp.Cursor = Cursors.Hand;
        sp.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        return sp;
    }

    /// <summary>A titled horizontal row with arrow buttons that appear on hover.</summary>
    public static FrameworkElement Row(string title, IEnumerable<FrameworkElement> cards, Action? seeAll = null, double gap = 18)
    {
        var outer = new StackPanel { Margin = new Thickness(0, 0, 0, 34) };
        var head = new DockPanel { Margin = new Thickness(Ui.Inset, 0, 64, 12), LastChildFill = false };
        var titleText = T(title, 20, FontWeights.Bold);
        head.Children.Add(titleText);
        if (seeAll != null)
        {
            var link = Chrome(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Children = { T("See all", 13, FontWeights.SemiBold, Muted), Icon(IcoChevronR, 10, Muted).With(i => i.Margin = new Thickness(6, 2, 0, 0)) }
            }, Brushes.Transparent, GlassFill, new CornerRadius(12), new Thickness(10, 4, 10, 4));
            link.BorderThickness = new Thickness(0);
            link.Click += (_, _) => seeAll();
            link.Margin = new Thickness(12, 0, 0, 0);
            DockPanel.SetDock(link, Dock.Left);
            head.Children.Add(link);
        }
        outer.Children.Add(head);

        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(Ui.Inset, 6, 64, 10) };
        foreach (var c in cards) { c.Margin = new Thickness(0, 0, gap, 0); panel.Children.Add(c); }
        var sv = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel, Focusable = false,
        };
        SmoothScroll.SetHorizontal(sv, true);

        var host = new Grid();
        host.Children.Add(sv);
        // full-height strips at both edges: click anywhere on them to scroll the row
        Border Edge(bool left)
        {
            var c = Ui.BgColor;
            var fade = new LinearGradientBrush(
                Color.FromArgb(0xF0, c.R, c.G, c.B), Color.FromArgb(0x00, c.R, c.G, c.B), left ? 0 : 180);
            var chevron = Icon(left ? IcoChevronL : IcoChevronR, 22, Brushes.White).With(i =>
            {
                i.HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right;
                i.Margin = new Thickness(left ? 22 : 0, 0, left ? 0 : 22, 0);
                i.Opacity = 0.75;
            });
            var strip = new Border
            {
                Width = 84, Background = fade, Child = chevron, Cursor = Cursors.Hand,
                HorizontalAlignment = left ? HorizontalAlignment.Left : HorizontalAlignment.Right,
                Margin = new Thickness(left ? Inset - 24 : 0, 0, 0, 34),   // stop above the titles under the cards
                Opacity = 0, IsHitTestVisible = false,
            };
            strip.MouseEnter += (_, _) => chevron.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(120)));
            strip.MouseLeave += (_, _) => chevron.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.75, TimeSpan.FromMilliseconds(120)));
            strip.MouseLeftButtonUp += (_, e) => { e.Handled = true; SmoothScroll.ScrollRow(sv, (left ? -1 : 1) * sv.ViewportWidth * 0.8); };
            strip.MouseLeftButtonDown += (_, e) => e.Handled = true;
            return strip;
        }
        var leftEdge = Edge(true);
        var rightEdge = Edge(false);
        host.Children.Add(leftEdge);
        host.Children.Add(rightEdge);
        void Arrows(bool show)
        {
            var dur = TimeSpan.FromMilliseconds(160);
            leftEdge.IsHitTestVisible = show && sv.HorizontalOffset > 1;
            rightEdge.IsHitTestVisible = show && sv.HorizontalOffset < sv.ScrollableWidth - 1;
            leftEdge.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(leftEdge.IsHitTestVisible ? 1 : 0, dur));
            rightEdge.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(rightEdge.IsHitTestVisible ? 1 : 0, dur));
        }
        host.MouseEnter += (_, _) => Arrows(true);
        host.MouseLeave += (_, _) => Arrows(false);
        sv.ScrollChanged += (_, _) => Arrows(host.IsMouseOver);
        outer.Children.Add(host);
        return outer;
    }

    public static T With<T>(this T el, Action<T> set) { set(el); return el; }
}
