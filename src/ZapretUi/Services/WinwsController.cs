using System.Diagnostics;
using System.ServiceProcess;
using Microsoft.Win32;
using ZapretUi.Models;

namespace ZapretUi.Services;

public sealed class BypassStatus
{
    public bool WinwsRunning { get; init; }
    public bool ServiceInstalled { get; init; }
    public bool ServiceRunning { get; init; }
    public string? ServiceStrategy { get; init; }

    public string Label
    {
        get
        {
            if (ServiceRunning && !string.IsNullOrWhiteSpace(ServiceStrategy))
                return $"Служба zapret · {ServiceStrategy}";
            if (ServiceRunning)
                return "Служба zapret запущена";
            if (WinwsRunning)
                return "winws.exe запущен";
            return "Остановлен";
        }
    }
}

public static class WinwsController
{
    public const string ServiceName = "zapret";
    private const string StrategyValue = "zapret-discord-youtube";

    public static BypassStatus Query()
    {
        var installed = ServiceExists(ServiceName);
        var running = installed && IsServiceRunning(ServiceName);
        string? strategy = null;
        if (installed)
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"System\CurrentControlSet\Services\zapret");
            strategy = key?.GetValue(StrategyValue) as string;
        }

        return new BypassStatus
        {
            WinwsRunning = Process.GetProcessesByName("winws").Length > 0,
            ServiceInstalled = installed,
            ServiceRunning = running,
            ServiceStrategy = strategy
        };
    }

    public static Task ConnectAsync(StrategyInfo strategy, bool autostart, CancellationToken ct = default) =>
        ConnectFromArgumentsAsync(StrategyCatalog.BuildArguments(strategy), strategy.Name, autostart, ct);

    public static async Task ConnectFromArgumentsAsync(
        string args,
        string displayName,
        bool autostart,
        CancellationToken ct = default)
    {
        EnableTcpTimestamps();
        StrategyCatalog.EnsureUserLists();

        await StopAsync(removeWinDivert: false, ct).ConfigureAwait(false);

        if (autostart)
        {
            InstallService(args, displayName);
            Run("sc", $"start {ServiceName}");
            await WaitForWinwsAsync(ct).ConfigureAwait(false);
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = ZapretPaths.Winws,
            Arguments = args,
            WorkingDirectory = ZapretPaths.BinDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        Process.Start(psi);
        await WaitForWinwsAsync(ct).ConfigureAwait(false);
    }

    public static async Task StopAsync(bool removeWinDivert, CancellationToken ct = default)
    {
        if (ServiceExists(ServiceName))
        {
            Run("net", $"stop {ServiceName}");
            Run("sc", $"delete {ServiceName}");
        }

        foreach (var p in Process.GetProcessesByName("winws"))
        {
            try
            {
                p.Kill(entireProcessTree: true);
                await p.WaitForExitAsync(ct).ConfigureAwait(false);
            }
            catch
            {
                // already gone
            }
        }

        if (removeWinDivert)
        {
            Run("net", "stop WinDivert");
            Run("sc", "delete WinDivert");
            Run("net", "stop WinDivert14");
            Run("sc", "delete WinDivert14");
        }

        await Task.Delay(200, ct).ConfigureAwait(false);
    }

    private static void InstallService(string args, string strategyName)
    {
        if (ServiceExists(ServiceName))
        {
            Run("net", $"stop {ServiceName}");
            Run("sc", $"delete {ServiceName}");
            Thread.Sleep(400);
        }

        var escaped = args.Replace("\"", "\\\"");
        var arguments =
            $"create {ServiceName} binPath= \"\\\"{ZapretPaths.Winws}\\\" {escaped}\" DisplayName= \"zapret\" start= auto";
        Run("sc.exe", arguments);
        Run("sc.exe", $"description {ServiceName} \"Zapret DPI bypass software\"");
        using var key = Registry.LocalMachine.CreateSubKey(@"System\CurrentControlSet\Services\zapret");
        key.SetValue(StrategyValue, strategyName);
    }

    private static async Task WaitForWinwsAsync(CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < 5000)
        {
            ct.ThrowIfCancellationRequested();
            if (Process.GetProcessesByName("winws").Length > 0)
            {
                await Task.Delay(300, ct).ConfigureAwait(false);
                return;
            }
            await Task.Delay(200, ct).ConfigureAwait(false);
        }

        throw new InvalidOperationException("winws.exe не запустился за 5 секунд.");
    }

    private static void EnableTcpTimestamps()
    {
        Run("netsh", "interface tcp set global timestamps=enabled");
    }

    private static bool ServiceExists(string name)
    {
        try
        {
            using var sc = new ServiceController(name);
            _ = sc.Status;
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsServiceRunning(string name)
    {
        try
        {
            using var sc = new ServiceController(name);
            return sc.Status is ServiceControllerStatus.Running or ServiceControllerStatus.StartPending;
        }
        catch
        {
            return false;
        }
    }

    private static void Run(string file, string args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = file,
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using var p = Process.Start(psi);
        p?.WaitForExit(15000);
    }
}
