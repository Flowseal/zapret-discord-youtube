using System.Text;
using System.Text.RegularExpressions;
using ZapretUi.Models;

namespace ZapretUi.Services;

public static class StrategyCatalog
{
    public static IReadOnlyList<StrategyInfo> Load()
    {
        return Directory.GetFiles(ZapretPaths.Root, "*.bat")
            .Where(p => !Path.GetFileName(p).StartsWith("service", StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => PadNumbers(Path.GetFileName(p)))
            .Select(p => new StrategyInfo
            {
                Name = Path.GetFileNameWithoutExtension(p),
                BatPath = p
            })
            .ToList();
    }

    public static string ExtractRawCommand(string batPath) =>
        ExtractWinwsCommand(File.ReadAllLines(batPath, Encoding.UTF8));

    public static string BuildArguments(StrategyInfo strategy)
    {
        var command = ExtractWinwsCommand(File.ReadAllLines(strategy.BatPath, Encoding.UTF8));
        return ExpandPlaceholders(command);
    }

    public static string ExpandPlaceholders(string command)
    {
        EnsureUserLists();
        var (tcp, udp) = ReadGameFilterPorts();
        var root = ZapretPaths.Root.TrimEnd('\\') + "\\";
        var bin = ZapretPaths.BinDir.TrimEnd('\\') + "\\";
        var lists = ZapretPaths.ListsDir.TrimEnd('\\') + "\\";

        return command
            .Replace("%BIN%", bin, StringComparison.OrdinalIgnoreCase)
            .Replace("%LISTS%", lists, StringComparison.OrdinalIgnoreCase)
            .Replace("%~dp0", root, StringComparison.OrdinalIgnoreCase)
            .Replace("%GameFilterTCP%", tcp, StringComparison.OrdinalIgnoreCase)
            .Replace("%GameFilterUDP%", udp, StringComparison.OrdinalIgnoreCase)
            .Replace("%GameFilter%", tcp, StringComparison.OrdinalIgnoreCase)
            .Trim();
    }

    public static void EnsureUserLists()
    {
        Directory.CreateDirectory(ZapretPaths.ListsDir);
        var ipsetUser = Path.Combine(ZapretPaths.ListsDir, "ipset-exclude-user.txt");
        var generalUser = Path.Combine(ZapretPaths.ListsDir, "list-general-user.txt");
        var excludeUser = Path.Combine(ZapretPaths.ListsDir, "list-exclude-user.txt");

        if (!File.Exists(ipsetUser))
            File.WriteAllText(ipsetUser, "203.0.113.113/32\r\n");
        if (!File.Exists(generalUser))
            File.WriteAllText(generalUser, "# Never leave this file empty\r\ndomain.example.abc\r\n");
        if (!File.Exists(excludeUser))
            File.WriteAllText(excludeUser, "domain.example.abc\r\n");
    }

    public static (string Tcp, string Udp) ReadGameFilterPorts()
    {
        const string dummy = "12";
        const string all = "1024-65535";
        if (!File.Exists(ZapretPaths.GameFilterFlag))
            return (dummy, dummy);

        var mode = File.ReadAllText(ZapretPaths.GameFilterFlag).Trim();
        if (mode.Equals("all", StringComparison.OrdinalIgnoreCase))
            return (all, all);
        if (mode.Equals("tcp", StringComparison.OrdinalIgnoreCase))
            return (all, dummy);
        return (dummy, all);
    }

    private static string ExtractWinwsCommand(IEnumerable<string> lines)
    {
        var joined = new List<string>();
        var acc = new StringBuilder();
        foreach (var raw in lines)
        {
            var line = raw.TrimEnd();
            if (line.EndsWith('^'))
            {
                acc.Append(line.TrimEnd('^').TrimEnd());
                acc.Append(' ');
                continue;
            }

            acc.Append(line);
            var full = acc.ToString().Trim();
            acc.Clear();
            if (full.Length == 0 || full.StartsWith("::") || full.StartsWith("rem ", StringComparison.OrdinalIgnoreCase))
                continue;
            joined.Add(full);
        }

        foreach (var line in joined)
        {
            var idx = line.LastIndexOf("winws.exe", StringComparison.OrdinalIgnoreCase);
            if (idx < 0)
                continue;

            var after = line[(idx + "winws.exe".Length)..];
            if (after.StartsWith('"'))
                after = after[1..];
            after = after.Trim();
            if (after.Length == 0)
                continue;
            return Regex.Replace(after, @"\s+", " ");
        }

        throw new InvalidOperationException("В файле стратегии нет запуска winws.exe.");
    }

    private static string PadNumbers(string name) =>
        Regex.Replace(name, @"\d+", m => m.Value.PadLeft(8, '0'), RegexOptions.None, TimeSpan.FromSeconds(1));
}
