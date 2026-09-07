using ZapretUi.Models;

namespace ZapretUi.Services;

public static class WinwsArgBuilder
{
    public static StrategyDraft CreateTemplate()
    {
        var d = new StrategyDraft { Name = "custom" };
        d.Global.Set("wf-tcp", "80,443,2053,2083,2087,2096,8443,%GameFilterTCP%");
        d.Global.Set("wf-udp", "443,19294-19344,50000-50100,%GameFilterUDP%");
        d.Profiles.Add(new ProfileDraft { Title = "Профиль 1" });
        return d;
    }

    public static string Build(StrategyDraft draft) => string.Join(" ", BuildBatArgLines(draft));

    public static IReadOnlyList<string> BuildBatArgLines(StrategyDraft draft)
    {
        var lines = new List<string>();
        var global = new List<string>();
        AppendSet(global, draft.Global);
        if (global.Count > 0)
            lines.Add(string.Join(" ", global));

        for (var i = 0; i < draft.Profiles.Count; i++)
        {
            var profile = new List<string>();
            AppendSet(profile, draft.Profiles[i].Options);
            if (profile.Count == 0)
                continue;
            if (i < draft.Profiles.Count - 1)
                profile.Add("--new");
            lines.Add(string.Join(" ", profile));
        }

        return lines;
    }

    public static string BuildResolved(StrategyDraft draft) =>
        StrategyCatalog.ExpandPlaceholders(Build(draft));

    private static readonly string[] EmitOrder =
    [
        "wf-tcp", "wf-udp", "wf-l3", "wf-iface", "wf-raw-part", "wf-raw", "wf-filter-lan",
        "ssid-filter", "nlm-filter",
        "filter-l3", "filter-tcp", "filter-udp", "filter-l7",
        "hostlist", "hostlist-exclude", "hostlist-domains", "hostlist-exclude-domains",
        "ipset", "ipset-exclude", "ipset-ip", "ipset-exclude-ip", "ip-id",
        "dpi-desync",
        "dpi-desync-repeats", "dpi-desync-any-protocol", "dpi-desync-skip-nosni",
        "dpi-desync-split-pos", "dpi-desync-split-seqovl", "dpi-desync-split-seqovl-pattern",
        "dpi-desync-fooling", "dpi-desync-badseq-increment",
        "dpi-desync-fake-tls-mod", "dpi-desync-hostfakesplit-mod", "dpi-desync-fakedsplit-mod",
        "dpi-desync-ttl", "dpi-desync-autottl", "dpi-desync-cutoff", "dpi-desync-start",
        "dpi-desync-fake-quic", "dpi-desync-fake-discord", "dpi-desync-fake-stun",
        "dpi-desync-fake-tls", "dpi-desync-fake-http", "dpi-desync-fake-unknown",
        "dpi-desync-fake-unknown-udp", "dpi-desync-fake-syndata",
        "dpi-desync-udplen-increment", "dpi-desync-udplen-pattern"
    ];

    private static void AppendSet(List<string> parts, OptionSet set)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in EmitOrder)
        {
            var b = set.Find(name);
            if (b == null)
                continue;
            AppendBinding(parts, b);
            seen.Add(b.Name);
        }

        foreach (var b in set.Bindings)
        {
            if (seen.Contains(b.Name))
                continue;
            AppendBinding(parts, b);
        }
    }

    private static void AppendBinding(List<string> parts, OptionBinding b)
    {
        var meta = WinwsOptionCatalog.Find(b.Name);
        foreach (var row in b.Values)
        {
            if (meta?.Kind == WinwsOptionKind.Flag)
            {
                parts.Add("--" + b.Name);
                continue;
            }

            var v = row.Value ?? "";
            if (v.Length == 0)
                continue;
            var quoted = Quote(v).Replace("!", "^!");
            parts.Add("--" + b.Name + "=" + quoted);
        }
    }

    public static string Quote(string value)
    {
        var needsQuotes = value.IndexOfAny([' ', '\t', '"']) >= 0
                          || value.Contains("%BIN%", StringComparison.OrdinalIgnoreCase)
                          || value.Contains("%LISTS%", StringComparison.OrdinalIgnoreCase)
                          || value.Contains(':') && (value.Contains('\\') || value.Contains('/'));
        if (!needsQuotes)
            return value;
        if (value.Length >= 2 && value[0] == '"' && value[^1] == '"')
            return value;
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
