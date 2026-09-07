using System.Windows;
using ZapretUi.Services;
using MessageBox = System.Windows.MessageBox;

namespace ZapretUi;

public partial class App : System.Windows.Application
{
    private Mutex? _mutex;
    private MainWindow? _window;
    private TrayService? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _mutex = new Mutex(true, @"Global\ZapretUi.SingleInstance", out var created);
        if (!created)
        {
            MessageBox.Show("Zapret UI уже запущен.", "Zapret UI", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        try
        {
            ZapretPaths.Resolve();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Zapret UI", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        _window = new MainWindow();
        _tray = new TrayService(_window);
        _window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _mutex?.ReleaseMutex();
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
