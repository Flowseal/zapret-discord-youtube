using System.Text;
using ZapretUi.Models;

namespace ZapretUi.Services;

public static class WinwsBatWriter
{
    public static bool IsStockPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return false;
        var name = Path.GetFileNameWithoutExtension(path);
        return !name.Contains("(DEV", StringComparison.OrdinalIgnoreCase);
    }

    public static string SuggestPath(string displayName)
    {
        var safe = Sanitize(displayName);
        return Path.Combine(ZapretPaths.Root, $"general (DEV {safe}).bat");
    }

    public static void Write(StrategyDraft draft, string path)
    {
        var lines = WinwsArgBuilder.BuildBatArgLines(draft).ToList();
        if (lines.Count == 0)
            throw new InvalidOperationException("Черновик пустой: нет аргументов winws.");

        var sb = new StringBuilder();
        sb.AppendLine("@echo off");
        sb.AppendLine("chcp 65001 > nul");
        sb.AppendLine(":: 65001 - UTF-8");
        sb.AppendLine();
        sb.AppendLine("cd /d \"%~dp0\"");
        sb.AppendLine("call service.bat status_zapret");
        sb.AppendLine("call service.bat check_updates");
        sb.AppendLine("call service.bat load_game_filter");
        sb.AppendLine("call service.bat load_user_lists");
        sb.AppendLine("echo:");
        sb.AppendLine();
        sb.AppendLine("set \"BIN=%~dp0bin\\\"");
        sb.AppendLine("set \"LISTS=%~dp0lists\\\"");
        sb.AppendLine("cd /d %BIN%");
        sb.AppendLine();

        for (var i = 0; i < lines.Count; i++)
        {
            var prefix = i == 0
                ? "start \"zapret: %~n0\" /min \"%BIN%winws.exe\" "
                : "";
            var suffix = i < lines.Count - 1 ? " ^" : "";
            sb.AppendLine(prefix + lines[i] + suffix);
        }

        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        draft.SourceBatPath = path;
        draft.Name = Path.GetFileNameWithoutExtension(path);
    }

    private static string Sanitize(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var s = name.Trim();
        if (s.StartsWith("general", StringComparison.OrdinalIgnoreCase))
            s = s["general".Length..].Trim();
        s = s.Trim('(', ')').Trim();
        if (s.StartsWith("DEV", StringComparison.OrdinalIgnoreCase))
            s = s[3..].Trim();
        var chars = s.Select(c => invalid.Contains(c) ? '_' : c).ToArray();
        s = new string(chars).Trim();
        return s.Length == 0 ? "custom" : s;
    }
}
