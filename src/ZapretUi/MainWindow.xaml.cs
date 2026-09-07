using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Threading;
using ZapretUi.Models;
using ZapretUi.Services;
using MessageBox = System.Windows.MessageBox;
using Style = System.Windows.Style;
using Visibility = System.Windows.Visibility;

namespace ZapretUi;

public partial class MainWindow : System.Windows.Window
{
    private readonly ObservableCollection<StrategyRow> _rows = [];
    private readonly DispatcherTimer _statusTimer;
    private CancellationTokenSource? _testCts;
    private bool _busy;
    private bool _suppressAutostart;

    private StrategyLabView? _lab;

    public MainWindow()
    {
        InitializeComponent();
        StrategyList.ItemsSource = _rows;

        ReloadStrategies();

        var warn = ZapretPaths.PathWarning();
        if (warn.Length > 0)
        {
            PathWarningText.Text = warn;
            PathWarningText.Visibility = Visibility.Visible;
        }

        _statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _statusTimer.Tick += (_, _) => RefreshStatus();
        _statusTimer.Start();
        RefreshStatus();
    }

    private void NavStrategies_Click(object sender, RoutedEventArgs e)
    {
        StrategyList.Visibility = Visibility.Visible;
        LabHost.Visibility = Visibility.Collapsed;
        StrategiesNav.Style = (Style)FindResource("PrimaryButton");
        LabNav.Style = (Style)FindResource(typeof(System.Windows.Controls.Button));
    }

    private void NavLab_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (_lab == null)
            {
                _lab = new StrategyLabView();
                _lab.RunExclusive = RunBusyAsync;
                _lab.GetSelectedStrategy = () => SelectedRow?.Info;
                _lab.ReloadStrategies = ReloadStrategies;
                _lab.RegisterTestCts = cts => _testCts = cts;
                _lab.SetCancelEnabled = v => CancelTestButton.IsEnabled = v;
                LabHost.Content = _lab;
            }

            StrategyList.Visibility = Visibility.Collapsed;
            LabHost.Visibility = Visibility.Visible;
            LabNav.Style = (Style)FindResource("PrimaryButton");
            StrategiesNav.Style = (Style)FindResource(typeof(System.Windows.Controls.Button));
        }
        catch (Exception ex)
        {
            CrashLog.Write(ex);
            MessageBox.Show(
                ex.Message + (CrashLog.LastPath == null ? "" : "\n\nЛог: " + CrashLog.LastPath),
                "Конструктор",
                MessageBoxButton.OK,
                MessageBoxImage.None);
        }
    }

    private StrategyRow? SelectedRow => StrategyList.SelectedItem as StrategyRow;

    public void ReloadStrategies()
    {
        var selected = SelectedRow?.Name;
        _rows.Clear();
        foreach (var s in StrategyCatalog.Load())
            _rows.Add(new StrategyRow { Info = s });

        if (selected != null)
        {
            var match = _rows.FirstOrDefault(r =>
                string.Equals(r.Name, selected, StringComparison.OrdinalIgnoreCase));
            if (match != null)
                StrategyList.SelectedItem = match;
            else if (_rows.Count > 0)
                StrategyList.SelectedIndex = 0;
        }
        else if (_rows.Count > 0)
            StrategyList.SelectedIndex = 0;
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedRow == null)
        {
            MessageBox.Show("Выберите стратегию.", "Zapret UI");
            return;
        }

        await RunBusyAsync(async () =>
        {
            TestStatusText.Text = "Запуск…";
            await WinwsController.ConnectAsync(SelectedRow.Info, AutostartCheck.IsChecked == true);
            TestStatusText.Text = "";
            RefreshStatus();
        });
    }

    private async void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        await RunBusyAsync(async () =>
        {
            TestStatusText.Text = "Остановка…";
            await WinwsController.StopAsync(removeWinDivert: true);
            TestStatusText.Text = "";
            RefreshStatus();
        });
    }

    private async void TestAll_Click(object sender, RoutedEventArgs e)
    {
        _testCts?.Cancel();
        _testCts = new CancellationTokenSource();
        var ct = _testCts.Token;
        var targets = StrategyTester.LoadDiscordYouTubeTargets();

        await RunBusyAsync(async () =>
        {
            CancelTestButton.IsEnabled = true;
            TestButton.IsEnabled = false;
            TestStatusText.Text = "Тест остановит текущее подключение…";
            foreach (var row in _rows)
            {
                row.Result = "";
                row.ResultKind = "";
            }

            TestProgress.Maximum = _rows.Count;
            TestProgress.Value = 0;
            StrategyTestResult? best = null;
            StrategyRow? bestRow = null;

            try
            {
                var i = 0;
                foreach (var row in _rows)
                {
                    ct.ThrowIfCancellationRequested();
                    TestStatusText.Text = $"Тест {i + 1}/{_rows.Count}: {row.Name}";
                    StrategyList.SelectedItem = row;
                    StrategyList.ScrollIntoView(row);

                    var result = await StrategyTester.TestOneAsync(row.Info, targets, ct);
                    row.Result = result.Label;
                    row.ResultKind = result.Kind;

                    if (best == null ||
                        result.Passed > best.Passed ||
                        (result.Passed == best.Passed && result.Passed > 0 && result.MedianMs < best.MedianMs))
                    {
                        best = result;
                        bestRow = row;
                    }

                    i++;
                    TestProgress.Value = i;
                }

                if (bestRow != null && best is { Passed: > 0 })
                {
                    bestRow.Result = "лучшая · " + best.Label;
                    bestRow.ResultKind = "best";
                    StrategyList.SelectedItem = bestRow;
                    StrategyList.ScrollIntoView(bestRow);
                    TestStatusText.Text = $"Готово. Лучшая: {bestRow.Name}";
                }
                else
                    TestStatusText.Text = "Готово. Ни одна стратегия не прошла smoke.";
            }
            catch (OperationCanceledException)
            {
                TestStatusText.Text = "Тест отменён.";
            }
            finally
            {
                CancelTestButton.IsEnabled = false;
                TestButton.IsEnabled = true;
                RefreshStatus();
            }
        });
    }

    private void CancelTest_Click(object sender, RoutedEventArgs e) => _testCts?.Cancel();

    private async void Autostart_Changed(object sender, RoutedEventArgs e)
    {
        if (_suppressAutostart || _busy)
            return;

        var enabled = AutostartCheck.IsChecked == true;
        var strategy = SelectedRow?.Info;
        await RunBusyAsync(async () =>
        {
            try
            {
                if (enabled)
                {
                    if (strategy == null)
                        throw new InvalidOperationException("Сначала выберите стратегию.");
                    var keep = WinwsController.Query().WinwsRunning;
                    if (keep)
                        await WinwsController.ConnectAsync(strategy, autostart: true);
                    else
                    {
                        await WinwsController.StopAsync(removeWinDivert: false);
                        StrategyCatalog.EnsureUserLists();
                        await WinwsController.ConnectAsync(strategy, autostart: true);
                    }
                }
                else
                {
                    var keep = WinwsController.Query().WinwsRunning;
                    await WinwsController.StopAsync(removeWinDivert: false);
                    if (keep && strategy != null)
                        await WinwsController.ConnectAsync(strategy, autostart: false);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Zapret UI");
            }
            RefreshStatus();
        });
    }

    private void RefreshStatus()
    {
        var status = WinwsController.Query();
        StatusText.Text = status.Label;
        _suppressAutostart = true;
        AutostartCheck.IsChecked = status.ServiceInstalled;
        _suppressAutostart = false;

        if (!string.IsNullOrWhiteSpace(status.ServiceStrategy))
        {
            var match = _rows.FirstOrDefault(r =>
                string.Equals(r.Name, status.ServiceStrategy, StringComparison.OrdinalIgnoreCase));
            if (match != null && StrategyList.SelectedItem != match && !_busy)
                StrategyList.SelectedItem = match;
        }
    }

    private async Task RunBusyAsync(Func<Task> action)
    {
        if (_busy)
            return;
        _busy = true;
        SetControlsEnabled(false);
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Zapret UI", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _busy = false;
            SetControlsEnabled(true);
            CancelTestButton.IsEnabled = false;
        }
    }

    private void SetControlsEnabled(bool enabled)
    {
        ConnectButton.IsEnabled = enabled;
        DisconnectButton.IsEnabled = enabled;
        TestButton.IsEnabled = enabled;
        AutostartCheck.IsEnabled = enabled;
        StrategyList.IsHitTestVisible = enabled;
        StrategiesNav.IsHitTestVisible = enabled;
        LabNav.IsHitTestVisible = enabled;
        if (_lab != null)
            _lab.IsHitTestVisible = enabled;
        Background = (System.Windows.Media.Brush)FindResource("Bg");
    }
}
