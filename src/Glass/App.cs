using System.Windows;
using System.Windows.Threading;

namespace Glass;

public sealed class App : Application
{
    [STAThread]
    public static void Main()
    {
        var app = new App { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.DispatcherUnhandledException += (_, e) =>
        {
            MessageBox.Show(e.Exception.Message, "Glass", MessageBoxButton.OK, MessageBoxImage.Warning);
            e.Handled = true;
        };
        app.Run(new MainWindow());
    }
}
