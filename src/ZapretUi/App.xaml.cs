using System.Windows;
using System.Windows.Threading;
using ZapretUi.Services;
using MessageBox = System.Windows.MessageBox;

namespace ZapretUi;

public partial class App : System.Windows.Application
{
    private Mutex? _mutex;
    private MainWindow? _window;
    private TrayService? _tray;
    private bool _loggingCrash;

    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += OnDispatcherUnhandled;
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
                CrashLog.Write(ex);
        };

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

    private void OnDispatcherUnhandled(object sender, DispatcherUnhandledExceptionEventArgs args)
    {
        args.Handled = true;
        if (_loggingCrash)
            return;
        _loggingCrash = true;
        try
        {
            CrashLog.Write(args.Exception);
        }
        finally
        {
            _loggingCrash = false;
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _mutex?.ReleaseMutex();
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
