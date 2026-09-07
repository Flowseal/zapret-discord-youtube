using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using Application = System.Windows.Application;

namespace ZapretUi.Services;

public sealed class TrayService : IDisposable
{
    private readonly MainWindow _window;
    private readonly NotifyIcon _icon;
    private bool _disposed;

    public TrayService(MainWindow window)
    {
        _window = window;
        _icon = new NotifyIcon
        {
            Text = "Zapret UI",
            Visible = true,
            Icon = SystemIcons.Shield
        };
        _icon.DoubleClick += (_, _) => ShowWindow();

        var menu = new ContextMenuStrip();
        menu.Items.Add("Открыть", null, (_, _) => ShowWindow());
        menu.Items.Add("Выход", null, (_, _) => Exit());
        _icon.ContextMenuStrip = menu;

        _window.Closing += OnClosing;
    }

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        _window.Hide();
    }

    private void ShowWindow()
    {
        _window.Show();
        _window.WindowState = System.Windows.WindowState.Normal;
        _window.Activate();
    }

    private void Exit()
    {
        _window.Closing -= OnClosing;
        _icon.Visible = false;
        Application.Current.Shutdown();
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _window.Closing -= OnClosing;
        _icon.Visible = false;
        _icon.Dispose();
    }
}
