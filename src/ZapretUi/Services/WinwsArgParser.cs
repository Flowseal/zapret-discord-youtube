using ZapretUi.Models;

namespace ZapretUi.Services;

public static class WinwsArgParser
{
    public static StrategyDraft Parse(string command, string name, string? batPath = null)
    {
        var tokens = Tokenize(command);
        var draft = new StrategyDraft { Name = name, SourceBatPath = batPath };
        var current = draft.Global;
        var profileIndex = 0;
        ProfileDraft? profile = null;

        for (var i = 0; i < tokens.Count; i++)
        {
            var t = tokens[i];
            if (t.Equals("--new", StringComparison.OrdinalIgnoreCase))
            {
                profileIndex++;
                profile = new ProfileDraft { Title = $"Профиль {profileIndex}" };
                draft.Profiles.Add(profile);
                current = profile.Options;
                continue;
            }

            if (!t.StartsWith("--", StringComparison.Ordinal))
                continue;

            var body = t[2..];
            string nameOpt;
            string? value = null;
            var eq = body.IndexOf('=');
            if (eq >= 0)
            {
                nameOpt = body[..eq];
                value = Unquote(body[(eq + 1)..]);
            }
            else
            {
                nameOpt = body;
                if (i + 1 < tokens.Count && !tokens[i + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    i++;
                    value = Unquote(tokens[i]);
                }
            }

            var meta = WinwsOptionCatalog.Find(nameOpt);
            var isGlobal = meta?.Scope == WinwsOptionScope.Global ||
                           nameOpt.StartsWith("wf-", StringComparison.OrdinalIgnoreCase) ||
                           nameOpt.StartsWith("ssid-", StringComparison.OrdinalIgnoreCase) ||
                           nameOpt.StartsWith("nlm-", StringComparison.OrdinalIgnoreCase);

            OptionSet target;
            if (isGlobal)
                target = draft.Global;
            else
            {
                if (profile == null)
                {
                    profileIndex = 1;
                    profile = new ProfileDraft { Title = "Профиль 1" };
                    draft.Profiles.Add(profile);
                    current = profile.Options;
                }

                target = current;
            }

            var existing = target.Find(nameOpt);
            var val = value ?? (meta?.Kind == WinwsOptionKind.Flag ? "" : "1");
            if (existing == null || meta?.Repeatable == true)
                target.AddValue(nameOpt, val);
            else
                existing.SetSingle(val);
        }

        if (draft.Profiles.Count == 0)
            draft.Profiles.Add(new ProfileDraft { Title = "Профиль 1" });

        Relabel(draft);
        return draft;
    }

    public static List<string> Tokenize(string command)
    {
        var result = new List<string>();
        var cur = new System.Text.StringBuilder();
        var inQuotes = false;
        foreach (var c in command)
        {
            if (c == '"')
            {
                inQuotes = !inQuotes;
                continue;
            }

            if (!inQuotes && char.IsWhiteSpace(c))
            {
                if (cur.Length > 0)
                {
                    result.Add(cur.ToString());
                    cur.Clear();
                }

                continue;
            }

            cur.Append(c);
        }

        if (cur.Length > 0)
            result.Add(cur.ToString());
        return result;
    }

    private static string Unquote(string s)
    {
        s = s.Trim();
        if (s.Length >= 2 && s[0] == '"' && s[^1] == '"')
            s = s[1..^1];
        return s.Replace("^!", "!");
    }

    private static void Relabel(StrategyDraft draft)
    {
        for (var i = 0; i < draft.Profiles.Count; i++)
        {
            var p = draft.Profiles[i];
            var tcp = p.Options.Find("filter-tcp")?.Values.FirstOrDefault()?.Value;
            var udp = p.Options.Find("filter-udp")?.Values.FirstOrDefault()?.Value;
            var l7 = p.Options.Find("filter-l7")?.Values.FirstOrDefault()?.Value;
            var hint = tcp ?? udp ?? l7;
            p.Title = string.IsNullOrWhiteSpace(hint) ? $"Профиль {i + 1}" : $"#{i + 1}  {TrimHint(hint)}";
        }
    }

    private static string TrimHint(string s) => s.Length <= 42 ? s : s[..40] + "…";
}
