namespace ZapretUi.Services;

public static class CrashLog
{
    public static string? LastPath { get; private set; }

    public static void Write(Exception ex)
    {
        try
        {
            var text = DateTime.Now.ToString("s") + "\r\n" + ex + "\r\n";
            var paths = new List<string>();
            if (!string.IsNullOrEmpty(ZapretPaths.Root))
                paths.Add(Path.Combine(ZapretPaths.Root, "zapret-ui-crash.log"));
            paths.Add(Path.Combine(Path.GetTempPath(), "zapret-ui-crash.log"));
            foreach (var path in paths)
            {
                File.AppendAllText(path, text);
                LastPath = path;
            }
        }
        catch
        {
            // ignore
        }
    }
}
