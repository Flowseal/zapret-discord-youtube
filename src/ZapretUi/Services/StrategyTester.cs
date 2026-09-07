using System.Diagnostics;
using System.Net.Http;
using ZapretUi.Models;

namespace ZapretUi.Services;

public sealed class ProbeTarget
{
    public required string Name { get; init; }
    public required string Url { get; init; }
}

public sealed class StrategyTestResult
{
    public required string StrategyName { get; init; }
    public int Passed { get; init; }
    public int Total { get; init; }
    public int MedianMs { get; init; }
    public string Kind => Passed == 0 ? "fail" : Passed == Total ? "ok" : "partial";
    public string Label => Total == 0 ? "ошибка" : $"{Passed}/{Total} · {MedianMs} мс";
}

public static class StrategyTester
{
    public static IReadOnlyList<ProbeTarget> LoadDiscordYouTubeTargets()
    {
        var result = new List<ProbeTarget>();
        if (!File.Exists(ZapretPaths.TargetsFile))
            return DefaultTargets();

        foreach (var raw in File.ReadAllLines(ZapretPaths.TargetsFile))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith("###"))
                continue;
            var eq = line.IndexOf('=');
            if (eq < 0)
                continue;
            var name = line[..eq].Trim();
            var value = line[(eq + 1)..].Trim().Trim('"');
            if (value.StartsWith("PING:", StringComparison.OrdinalIgnoreCase))
                continue;
            if (!name.StartsWith("Discord", StringComparison.OrdinalIgnoreCase) &&
                !name.StartsWith("YouTube", StringComparison.OrdinalIgnoreCase))
                continue;
            if (!value.StartsWith("http", StringComparison.OrdinalIgnoreCase))
                continue;
            result.Add(new ProbeTarget { Name = name, Url = value });
        }

        return result.Count == 0 ? DefaultTargets() : result;
    }

    public static async Task<StrategyTestResult> TestOneAsync(
        StrategyInfo strategy,
        IReadOnlyList<ProbeTarget> targets,
        CancellationToken ct)
    {
        await WinwsController.ConnectAsync(strategy, autostart: false, ct).ConfigureAwait(false);
        try
        {
            using var handler = new SocketsHttpHandler
            {
                AllowAutoRedirect = true,
                MaxConnectionsPerServer = 4,
                ConnectTimeout = TimeSpan.FromSeconds(3)
            };
            using var http = new HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(4)
            };
            http.DefaultRequestVersion = System.Net.HttpVersion.Version11;
            http.DefaultRequestHeaders.TryAddWithoutValidation(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ZapretUi/1.0");

            var times = new List<int>();
            var passed = 0;

            var tasks = targets.Select(async t =>
            {
                var sw = Stopwatch.StartNew();
                try
                {
                    using var req = new HttpRequestMessage(HttpMethod.Get, t.Url);
                    using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct)
                        .ConfigureAwait(false);
                    sw.Stop();
                    var code = (int)resp.StatusCode;
                    var ok = code is >= 200 and < 400;
                    return (ok, (int)sw.ElapsedMilliseconds);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    throw;
                }
                catch
                {
                    return (false, (int)sw.ElapsedMilliseconds);
                }
            });

            foreach (var (ok, ms) in await Task.WhenAll(tasks).ConfigureAwait(false))
            {
                if (ok)
                {
                    passed++;
                    times.Add(ms);
                }
            }

            times.Sort();
            var median = times.Count == 0 ? 0 : times[times.Count / 2];
            return new StrategyTestResult
            {
                StrategyName = strategy.Name,
                Passed = passed,
                Total = targets.Count,
                MedianMs = median
            };
        }
        finally
        {
            await WinwsController.StopAsync(removeWinDivert: false, CancellationToken.None).ConfigureAwait(false);
        }
    }

    private static IReadOnlyList<ProbeTarget> DefaultTargets() =>
    [
        new() { Name = "DiscordMain", Url = "https://discord.com" },
        new() { Name = "DiscordGateway", Url = "https://gateway.discord.gg" },
        new() { Name = "YouTubeWeb", Url = "https://www.youtube.com" },
        new() { Name = "YouTubeImage", Url = "https://i.ytimg.com" }
    ];
}
