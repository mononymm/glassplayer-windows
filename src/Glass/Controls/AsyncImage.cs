using System.Collections.Concurrent;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace Glass.Controls;

/// <summary>
/// Decodes artwork off the UI thread at the size it's shown, keeps a small memory cache,
/// and fades images in. Usage: &lt;Image c:Art.Path="{Binding PosterPath}" c:Art.Width="300"/&gt;
/// </summary>
public static class Art
{
    static readonly ConcurrentDictionary<string, ImageSource> cache = new();
    static readonly LinkedList<string> order = new();
    static readonly object gate = new();
    const int MaxCached = 900;
    static readonly SemaphoreSlim decoders = new(Math.Max(2, Environment.ProcessorCount / 2));

    public static readonly DependencyProperty PathProperty =
        DependencyProperty.RegisterAttached("Path", typeof(string), typeof(Art), new PropertyMetadata(null, OnPathChanged));
    public static readonly DependencyProperty WidthProperty =
        DependencyProperty.RegisterAttached("Width", typeof(int), typeof(Art), new PropertyMetadata(400));

    public static string? GetPath(DependencyObject o) => (string?)o.GetValue(PathProperty);
    public static void SetPath(DependencyObject o, string? v) => o.SetValue(PathProperty, v);
    public static int GetWidth(DependencyObject o) => (int)o.GetValue(WidthProperty);
    public static void SetWidth(DependencyObject o, int v) => o.SetValue(WidthProperty, v);

    static async void OnPathChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not Image img) return;
        var path = e.NewValue as string;
        if (string.IsNullOrEmpty(path)) { img.Source = null; return; }
        var width = GetWidth(img);
        var key = path + "|" + width;
        if (cache.TryGetValue(key, out var hit)) { img.Source = hit; img.Opacity = 1; return; }

        img.Source = null;
        img.Opacity = 0;
        var src = await Task.Run(() => Decode(path, width));
        if (GetPath(img) != path || src == null) return;   // the control was reused for something else
        Remember(key, src);
        img.Source = src;
        img.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220))
        { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
    }

    public static async Task<ImageSource?> LoadAsync(string? path, int width)
    {
        if (string.IsNullOrEmpty(path)) return null;
        var key = path + "|" + width;
        if (cache.TryGetValue(key, out var hit)) return hit;
        var src = await Task.Run(() => Decode(path, width));
        if (src != null) Remember(key, src);
        return src;
    }

    static ImageSource? Decode(string path, int width)
    {
        decoders.Wait();
        try
        {
            if (!File.Exists(path)) return null;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            bmp.DecodePixelWidth = width;
            bmp.StreamSource = fs;
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch { return null; }
        finally { decoders.Release(); }
    }

    static void Remember(string key, ImageSource src)
    {
        cache[key] = src;
        lock (gate)
        {
            order.AddLast(key);
            while (order.Count > MaxCached)
            {
                cache.TryRemove(order.First!.Value, out _);
                order.RemoveFirst();
            }
        }
    }
}
