namespace ZapretUi.Services;

public static class ZapretPaths
{
    public static string Root { get; private set; } = "";
    public static string BinDir => Path.Combine(Root, "bin");
    public static string ListsDir => Path.Combine(Root, "lists");
    public static string UtilsDir => Path.Combine(Root, "utils");
    public static string Winws => Path.Combine(BinDir, "winws.exe");
    public static string TargetsFile => Path.Combine(UtilsDir, "targets.txt");
    public static string GameFilterFlag => Path.Combine(UtilsDir, "game_filter.enabled");

    public static void Resolve()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 10 && dir != null; i++)
        {
            if (LooksLikePack(dir.FullName))
            {
                Root = dir.FullName;
                return;
            }

            var nested = Path.Combine(dir.FullName, "zapret-discord-youtube-UI");
            if (LooksLikePack(nested))
            {
                Root = nested;
                return;
            }

            dir = dir.Parent;
        }

        throw new InvalidOperationException(
            "Не найден пак zapret (bin\\winws.exe). Положите ZapretUi.exe рядом с general.bat и папкой bin.");
    }

    public static string PathWarning()
    {
        var issues = new List<string>();
        if (Root.Contains("OneDrive", StringComparison.OrdinalIgnoreCase))
            issues.Add("путь в OneDrive — WinDivert часто ломается, лучше скопировать пак на C:\\zapret");
        if (ContainsNonAscii(Root))
            issues.Add("в пути есть не-ASCII символы (кириллица) — распакуйте в путь латиницей");
        return issues.Count == 0 ? "" : string.Join(". ", issues);
    }

    private static bool LooksLikePack(string dir) =>
        File.Exists(Path.Combine(dir, "bin", "winws.exe"));

    private static bool ContainsNonAscii(string path) => path.Any(c => c > 127);
}
