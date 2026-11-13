using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Glass.Controls;

/// <summary>
/// Eased mouse-wheel scrolling. On a page: c:SmoothScroll.Enabled="True".
/// On a horizontal row: c:SmoothScroll.Horizontal="True" (Shift+wheel scrolls the row, a plain wheel scrolls the page).
/// </summary>
public static class SmoothScroll
{
    public static readonly DependencyProperty EnabledProperty =
        DependencyProperty.RegisterAttached("Enabled", typeof(bool), typeof(SmoothScroll), new PropertyMetadata(false, OnEnabled));
    public static readonly DependencyProperty HorizontalProperty =
        DependencyProperty.RegisterAttached("Horizontal", typeof(bool), typeof(SmoothScroll), new PropertyMetadata(false, OnHorizontal));

    public static bool GetEnabled(DependencyObject o) => (bool)o.GetValue(EnabledProperty);
    public static void SetEnabled(DependencyObject o, bool v) => o.SetValue(EnabledProperty, v);
    public static bool GetHorizontal(DependencyObject o) => (bool)o.GetValue(HorizontalProperty);
    public static void SetHorizontal(DependencyObject o, bool v) => o.SetValue(HorizontalProperty, v);

    sealed class State
    {
        public double Target;
        public bool Running;
        public bool Horizontal;
        public TimeSpan Last;
    }

    static readonly DependencyProperty StateProperty =
        DependencyProperty.RegisterAttached("State", typeof(State), typeof(SmoothScroll));

    static void OnEnabled(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ScrollViewer sv || e.NewValue is not true) return;
        sv.SetValue(StateProperty, new State { Target = sv.VerticalOffset });
        sv.PreviewMouseWheel += (_, ev) =>
        {
            ev.Handled = true;
            Scroll(sv, -ev.Delta * 1.1, false);
        };
        sv.ScrollChanged += (_, ev) =>
        {
            var st = (State)sv.GetValue(StateProperty);
            if (!st.Running) st.Target = sv.VerticalOffset;   // scrollbar drags, keyboard, BringIntoView
        };
    }

    static void OnHorizontal(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ScrollViewer sv || e.NewValue is not true) return;
        sv.SetValue(StateProperty, new State { Target = sv.HorizontalOffset, Horizontal = true });
        sv.PreviewMouseWheel += (_, ev) =>
        {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
            {
                ev.Handled = true;
                Scroll(sv, -ev.Delta * 1.6, true);
                return;
            }
            // pass the wheel up to the page
            ev.Handled = true;
            var parent = FindParentScroller(sv);
            if (parent != null) Scroll(parent, -ev.Delta * 1.1, false);
        };
        sv.ScrollChanged += (_, ev) =>
        {
            var st = (State)sv.GetValue(StateProperty);
            if (!st.Running) st.Target = sv.HorizontalOffset;
        };
    }

    public static void ScrollRow(ScrollViewer sv, double by) => Scroll(sv, by, true);

    static void Scroll(ScrollViewer sv, double by, bool horizontal)
    {
        var st = (State?)sv.GetValue(StateProperty);
        if (st == null) { st = new State { Horizontal = horizontal, Target = horizontal ? sv.HorizontalOffset : sv.VerticalOffset }; sv.SetValue(StateProperty, st); }
        var max = horizontal ? sv.ScrollableWidth : sv.ScrollableHeight;
        st.Target = Math.Clamp(st.Target + by, 0, max);
        if (st.Running) return;
        st.Running = true;
        st.Last = TimeSpan.Zero;
        EventHandler? tick = null;
        tick = (_, args) =>
        {
            var now = ((RenderingEventArgs)args).RenderingTime;
            var dt = st.Last == TimeSpan.Zero ? 1 / 60.0 : Math.Min(0.05, (now - st.Last).TotalSeconds);
            st.Last = now;
            var cur = horizontal ? sv.HorizontalOffset : sv.VerticalOffset;
            var diff = st.Target - cur;
            if (Math.Abs(diff) < 0.5)
            {
                if (horizontal) sv.ScrollToHorizontalOffset(st.Target); else sv.ScrollToVerticalOffset(st.Target);
                CompositionTarget.Rendering -= tick;
                st.Running = false;
                return;
            }
            // exponential ease-out: covers ~1 - e^(-14 dt) of the gap each frame
            var step = diff * (1 - Math.Exp(-14 * dt));
            if (horizontal) sv.ScrollToHorizontalOffset(cur + step); else sv.ScrollToVerticalOffset(cur + step);
        };
        CompositionTarget.Rendering += tick;
    }

    static ScrollViewer? FindParentScroller(DependencyObject d)
    {
        var p = VisualTreeHelper.GetParent(d);
        while (p != null)
        {
            if (p is ScrollViewer sv && GetEnabled(sv)) return sv;
            p = VisualTreeHelper.GetParent(p);
        }
        return null;
    }
}
