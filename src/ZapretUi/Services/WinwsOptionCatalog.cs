using System.Diagnostics;
using System.Text.RegularExpressions;
using ZapretUi.Models;

namespace ZapretUi.Services;

public static class WinwsOptionCatalog
{
    private static readonly List<WinwsOption> _all = BuildBuiltin();
    private static bool _helpMerged;

    public static IReadOnlyList<WinwsOption> All => _all;

    public static WinwsOption? Find(string name) =>
        _all.FirstOrDefault(o => string.Equals(o.Name, name, StringComparison.OrdinalIgnoreCase));

    public static IEnumerable<WinwsOption> ForScope(WinwsOptionScope scope) =>
        _all.Where(o => o.Scope == scope);

    public static IEnumerable<string> Groups(WinwsOptionScope scope) =>
        ForScope(scope).Select(o => o.Group).Distinct();

    public static void MergeHelpFromWinws()
    {
        if (_helpMerged)
            return;
        _helpMerged = true;
        try
        {
            if (!File.Exists(ZapretPaths.Winws))
                return;
            var psi = new ProcessStartInfo
            {
                FileName = ZapretPaths.Winws,
                Arguments = "--help",
                WorkingDirectory = ZapretPaths.BinDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using var p = Process.Start(psi);
            if (p == null)
                return;
            var text = p.StandardOutput.ReadToEnd() + "\n" + p.StandardError.ReadToEnd();
            p.WaitForExit(8000);
            foreach (Match m in Regex.Matches(text, @"--([a-z0-9-]+)", RegexOptions.IgnoreCase, TimeSpan.FromSeconds(2)))
            {
                var name = m.Groups[1].Value;
                if (name.Equals("new", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("help", StringComparison.OrdinalIgnoreCase) ||
                    name.Equals("version", StringComparison.OrdinalIgnoreCase))
                    continue;
                if (_all.Any(o => o.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                    continue;
                _all.Add(new WinwsOption
                {
                    Name = name,
                    Scope = name.StartsWith("wf-", StringComparison.OrdinalIgnoreCase) ||
                            name.StartsWith("ssid-", StringComparison.OrdinalIgnoreCase) ||
                            name.StartsWith("nlm-", StringComparison.OrdinalIgnoreCase)
                        ? WinwsOptionScope.Global
                        : WinwsOptionScope.Profile,
                    Kind = WinwsOptionKind.String,
                    Group = "Из --help",
                    Help = "Опция из winws --help",
                    Repeatable = true
                });
            }
        }
        catch
        {
            // help is optional
        }
    }

    private static List<WinwsOption> BuildBuiltin()
    {
        var list = new List<WinwsOption>();

        void G(string name, WinwsOptionKind kind, string group, string help,
            bool repeatable = false, int min = 0, int max = 100, params string[] values)
        {
            list.Add(new WinwsOption
            {
                Name = name,
                Scope = WinwsOptionScope.Global,
                Kind = kind,
                Group = group,
                Help = help,
                Repeatable = repeatable,
                Min = min,
                Max = max,
                Values = values
            });
        }

        void P(string name, WinwsOptionKind kind, string group, string help,
            bool repeatable = false, int min = 0, int max = 100, params string[] values)
        {
            list.Add(new WinwsOption
            {
                Name = name,
                Scope = WinwsOptionScope.Profile,
                Kind = kind,
                Group = group,
                Help = help,
                Repeatable = repeatable,
                Min = min,
                Max = max,
                Values = values
            });
        }

        G("wf-iface", WinwsOptionKind.String, "WinDivert", "Индекс интерфейса [:subiface]");
        G("wf-l3", WinwsOptionKind.MultiEnum, "WinDivert", "L3 фильтр", false, 0, 0, "ipv4", "ipv6");
        G("wf-tcp", WinwsOptionKind.Ports, "WinDivert", "TCP порты WinDivert");
        G("wf-udp", WinwsOptionKind.Ports, "WinDivert", "UDP порты WinDivert");
        G("wf-raw-part", WinwsOptionKind.String, "WinDivert", "Кусок raw-фильтра", true);
        G("wf-filter-lan", WinwsOptionKind.Enum, "WinDivert", "Исключить LAN", false, 0, 0, "0", "1");
        G("wf-raw", WinwsOptionKind.String, "WinDivert", "Полный raw WinDivert filter");
        G("wf-save", WinwsOptionKind.String, "WinDivert", "Сохранить фильтр в файл и выйти");
        G("ssid-filter", WinwsOptionKind.Tokens, "WinDivert", "Включать только на SSID");
        G("nlm-filter", WinwsOptionKind.Tokens, "WinDivert", "Фильтр NLM сетей");
        G("debug", WinwsOptionKind.Enum, "Прочее", "Отладка", false, 0, 0, "0", "1");
        G("debug-level", WinwsOptionKind.Int, "Прочее", "Уровень логов", false, 0, 5);
        G("wssize", WinwsOptionKind.String, "TCP extras", "Подмена window size");
        G("wssize-cutoff", WinwsOptionKind.String, "TCP extras", "Cutoff для wssize");

        P("filter-l3", WinwsOptionKind.MultiEnum, "Фильтры", "L3 профиля", false, 0, 0, "ipv4", "ipv6");
        P("filter-tcp", WinwsOptionKind.Ports, "Фильтры", "TCP порты профиля");
        P("filter-udp", WinwsOptionKind.Ports, "Фильтры", "UDP порты профиля");
        P("filter-l7", WinwsOptionKind.MultiEnum, "Фильтры", "L7 протокол", false, 0, 0,
            "http", "tls", "quic", "wireguard", "dht", "discord", "stun", "unknown");
        P("ip-id", WinwsOptionKind.Enum, "Фильтры", "IP ID", false, 0, 0, "seq", "zero", "rnd");

        P("hostlist", WinwsOptionKind.FileList, "Host / IP", "Файл доменов", true);
        P("hostlist-exclude", WinwsOptionKind.FileList, "Host / IP", "Исключения доменов", true);
        P("hostlist-domains", WinwsOptionKind.Tokens, "Host / IP", "Домены через запятую", true);
        P("hostlist-exclude-domains", WinwsOptionKind.Tokens, "Host / IP", "Исключить домены", true);
        P("hostlist-auto", WinwsOptionKind.FileList, "Host / IP", "Авто-hostlist");
        P("hostlist-auto-fail-threshold", WinwsOptionKind.Int, "Host / IP", "Порог fail", false, 1, 20);
        P("hostlist-auto-fail-time", WinwsOptionKind.Int, "Host / IP", "Окно fail, сек", false, 1, 120);
        P("hostlist-auto-retrans-threshold", WinwsOptionKind.Int, "Host / IP", "Порог retrans", false, 1, 20);
        P("ipset", WinwsOptionKind.FileList, "Host / IP", "Файл IP", true);
        P("ipset-exclude", WinwsOptionKind.FileList, "Host / IP", "Исключения IP", true);
        P("ipset-ip", WinwsOptionKind.Tokens, "Host / IP", "IP вручную", true);
        P("ipset-exclude-ip", WinwsOptionKind.Tokens, "Host / IP", "Исключить IP", true);

        P("dpi-desync", WinwsOptionKind.MultiEnum, "Desync", "Методы по фазам 0→1→2", false, 0, 0,
            "fake", "rst", "rstack", "synack", "syndata",
            "split", "split2", "multisplit", "disorder", "disorder2", "multidisorder",
            "ipfrag1", "ipfrag2", "hostfakesplit", "fakedsplit", "fakeddisorder", "noop");
        P("dpi-desync-repeats", WinwsOptionKind.Int, "Desync", "Повторы fake", false, 1, 20);
        P("dpi-desync-any-protocol", WinwsOptionKind.Enum, "Desync", "Любой протокол", false, 0, 0, "0", "1");
        P("dpi-desync-skip-nosni", WinwsOptionKind.Enum, "Desync", "Пропуск TLS без SNI", false, 0, 0, "0", "1");
        P("dpi-desync-fwmark", WinwsOptionKind.Hex, "Desync", "fwmark (linux/win divert)");

        P("dpi-desync-split-pos", WinwsOptionKind.Tokens, "Split", "Позиции: N, midsld, sniext+N", true);
        P("dpi-desync-split-seqovl", WinwsOptionKind.Int, "Split", "Sequence overlap", false, 0, 1500);
        P("dpi-desync-split-seqovl-pattern", WinwsOptionKind.FileBin, "Split", "Паттерн seqovl");
        P("dpi-desync-hostfakesplit-mod", WinwsOptionKind.String, "Split", "host=,altorder=");
        P("dpi-desync-fakedsplit-mod", WinwsOptionKind.String, "Split", "Модификаторы fakedsplit");

        P("dpi-desync-fooling", WinwsOptionKind.MultiEnum, "Fooling", "Как прятать fake от сервера", false, 0, 0,
            "none", "md5sig", "ts", "badseq", "badsum", "hopbyhop", "hopbyhop2", "destopt", "ipfrag1");
        P("dpi-desync-badseq-increment", WinwsOptionKind.Int, "Fooling", "Инкремент badseq", false, 1, 65535);
        P("dpi-desync-badack-increment", WinwsOptionKind.Int, "Fooling", "Инкремент badack", false, 1, 65535);
        P("dpi-desync-tslen", WinwsOptionKind.Int, "Fooling", "Длина TS fooling", false, 1, 64);
        P("dpi-desync-tsfooling", WinwsOptionKind.MultiEnum, "Fooling", "TS fooling", false, 0, 0, "md5sig", "ts", "badsum");

        P("dpi-desync-ttl", WinwsOptionKind.Int, "TTL / cutoff", "TTL IPv4", false, 1, 64);
        P("dpi-desync-ttl6", WinwsOptionKind.Int, "TTL / cutoff", "Hop limit IPv6", false, 1, 64);
        P("dpi-desync-autottl", WinwsOptionKind.String, "TTL / cutoff", "auto TTL, напр. 2");
        P("dpi-desync-autottl6", WinwsOptionKind.String, "TTL / cutoff", "auto hop IPv6");
        P("dpi-desync-cutoff", WinwsOptionKind.String, "TTL / cutoff", "nN | dN | sN — стоп после пакета/данных");
        P("dpi-desync-start", WinwsOptionKind.String, "TTL / cutoff", "nN | dN | sN — старт");

        P("dpi-desync-fake-http", WinwsOptionKind.FileBin, "Fake payloads", "Fake HTTP", true);
        P("dpi-desync-fake-tls", WinwsOptionKind.FileBin, "Fake payloads", "Fake TLS (! или 0x00…)", true);
        P("dpi-desync-fake-tls-mod", WinwsOptionKind.Tokens, "Fake payloads", "rnd,dupsid,sni=host,none");
        P("dpi-desync-fake-unknown", WinwsOptionKind.FileBin, "Fake payloads", "Fake unknown TCP", true);
        P("dpi-desync-fake-unknown-udp", WinwsOptionKind.FileBin, "Fake payloads", "Fake unknown UDP", true);
        P("dpi-desync-fake-quic", WinwsOptionKind.FileBin, "Fake payloads", "Fake QUIC", true);
        P("dpi-desync-fake-syndata", WinwsOptionKind.FileBin, "Fake payloads", "Данные SYN", true);
        P("dpi-desync-fake-dht", WinwsOptionKind.FileBin, "Fake payloads", "Fake DHT", true);
        P("dpi-desync-fake-discord", WinwsOptionKind.FileBin, "Fake payloads", "Fake Discord UDP", true);
        P("dpi-desync-fake-stun", WinwsOptionKind.FileBin, "Fake payloads", "Fake STUN", true);
        P("dpi-desync-fake-wireguard", WinwsOptionKind.FileBin, "Fake payloads", "Fake WireGuard", true);

        P("dpi-desync-udplen-increment", WinwsOptionKind.Int, "UDP extras", "Прирост UDP length", false, -64, 64);
        P("dpi-desync-udplen-pattern", WinwsOptionKind.Hex, "UDP extras", "Паттерн паддинга UDP");

        P("ctrack-timeouts", WinwsOptionKind.String, "Прочее", "Таймауты conntrack");
        P("ctrack-disable", WinwsOptionKind.Flag, "Прочее", "Выключить conntrack");
        P("ipcache-size", WinwsOptionKind.Int, "Прочее", "Размер IP cache", false, 0, 100000);
        P("ipcache-lifetime", WinwsOptionKind.Int, "Прочее", "TTL IP cache, сек", false, 0, 3600);
        P("synack-split", WinwsOptionKind.Enum, "Прочее", "Режим synack split", false, 0, 0, "synack", "acksyn", "ack");
        P("dup", WinwsOptionKind.Int, "Прочее", "Дубликаты пакетов", false, 0, 16);
        P("dup-cutoff", WinwsOptionKind.String, "Прочее", "Cutoff для dup");
        P("dup-fooling", WinwsOptionKind.MultiEnum, "Прочее", "Fooling для dup", false, 0, 0,
            "none", "md5sig", "ts", "badseq", "badsum");
        P("dup-ttl", WinwsOptionKind.Int, "Прочее", "TTL дубликатов", false, 1, 64);
        P("dup-replace", WinwsOptionKind.Flag, "Прочее", "Заменять вместо дубля");
        P("orig-mod", WinwsOptionKind.String, "Прочее", "Модификация оригинала");
        P("orig-ttl", WinwsOptionKind.Int, "Прочее", "TTL оригинала", false, 1, 64);
        P("orig-autottl", WinwsOptionKind.String, "Прочее", "auto TTL оригинала");
        P("orig-fooling", WinwsOptionKind.MultiEnum, "Прочее", "Fooling оригинала", false, 0, 0,
            "none", "md5sig", "ts", "badseq", "badsum");

        return list;
    }
}
