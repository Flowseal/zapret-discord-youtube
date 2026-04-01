#include "strategy_parser.h"
#include <fstream>
#include <sstream>
#include <cctype>
#include <cstring>

namespace StrategyParser {

namespace {

std::string ReadFileUtf8(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return {};
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Позиция подстроки "winws.exe" без учёта регистра.
size_t FindWinwsExe(const std::string& line) {
    static const char kNeedle[] = "winws.exe";
    const size_t n = sizeof(kNeedle) - 1;
    if (line.size() < n)
        return std::string::npos;
    for (size_t i = 0; i + n <= line.size(); ++i) {
        bool ok = true;
        for (size_t j = 0; j < n; ++j) {
            if (std::tolower(static_cast<unsigned char>(line[i + j])) !=
                static_cast<unsigned char>(kNeedle[j])) {
                ok = false;
                break;
            }
        }
        if (ok)
            return i;
    }
    return std::string::npos;
}

// После `"...winws.exe"` в .bat часто идёт закрывающая кавычка перед аргументами — ломает разбор.
void TrimAfterExePath(std::string& s) {
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
        s.erase(s.begin());
    if (!s.empty() && s.front() == '"')
        s.erase(s.begin());
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
        s.erase(s.begin());
}

// Find line containing "winws.exe", return everything after "winws.exe"
std::string ExtractArgsFromBatch(const std::string& content) {
    size_t pos = 0;
    std::string result;

    while (pos < content.size()) {
        size_t lineEnd = content.find('\n', pos);
        if (lineEnd == std::string::npos)
            lineEnd = content.size();

        std::string line = content.substr(pos, lineEnd - pos);
        // Remove \r if present
        while (!line.empty() && line.back() == '\r')
            line.pop_back();

        size_t winws = FindWinwsExe(line);
        if (winws != std::string::npos) {
            result = line.substr(winws + strlen("winws.exe"));
            break;
        }
        pos = lineEnd + 1;
    }

    if (result.empty())
        return {};

    // Join continuation lines (^ at end)
    pos = 0;
    std::string joined;
    while (pos < content.size()) {
        size_t lineEnd = content.find('\n', pos);
        if (lineEnd == std::string::npos)
            lineEnd = content.size();
        std::string line = content.substr(pos, lineEnd - pos);
        while (!line.empty() && line.back() == '\r')
            line.pop_back();

        size_t winws = FindWinwsExe(line);
        if (winws != std::string::npos) {
            joined = line.substr(winws + strlen("winws.exe"));
            pos = lineEnd + 1;
            while (pos < content.size()) {
                size_t nextEnd = content.find('\n', pos);
                if (nextEnd == std::string::npos)
                    nextEnd = content.size();
                std::string nextLine = content.substr(pos, nextEnd - pos);
                while (!nextLine.empty() && nextLine.back() == '\r')
                    nextLine.pop_back();

                if (!joined.empty() && joined.back() == '^') {
                    joined.pop_back();
                    while (!nextLine.empty() && nextLine.back() == '\r')
                        nextLine.pop_back();
                    joined += nextLine;
                }
                else
                    break;
                pos = nextEnd + 1;
            }
            break;
        }
        pos = lineEnd + 1;
    }

    std::string out = joined.empty() ? result : joined;
    TrimAfterExePath(out);
    return out;
}

// Tokenize: split by whitespace, respect "quoted" (--key="value" stays one token)
std::vector<std::string> Tokenize(const std::string& s) {
    std::vector<std::string> tokens;
    const char* p = s.c_str();
    while (*p) {
        while (*p && std::isspace(static_cast<unsigned char>(*p)))
            ++p;
        if (!*p)
            break;
        if (*p == '"') {
            ++p;
            std::string t;
            while (*p && *p != '"') {
                if (*p == '\\')
                    ++p;
                if (*p)
                    t += *p++;
            }
            if (*p == '"')
                ++p;
            tokens.push_back(t);
        }
        else {
            std::string t;
            while (*p && !std::isspace(static_cast<unsigned char>(*p))) {
                if (*p == '"') {
                    t += *p++;
                    while (*p && *p != '"') {
                        if (*p == '\\') ++p;
                        if (*p) t += *p++;
                    }
                    if (*p == '"')
                        t += *p++;
                }
                else
                    t += *p++;
            }
            if (!t.empty())
                tokens.push_back(t);
        }
    }
    return tokens;
}

// Args that take next token as value (space-separated)
const char* const kArgsWithValue[] = { "sni", "host", "altorder" };

bool IsArgWithValue(const std::string& name) {
    for (const char* a : kArgsWithValue) {
        size_t len = strlen(a);
        if (name.size() > len && name.compare(name.size() - len - 1, len + 1, std::string("=") + a) == 0)
            return true;
        if (name == a)
            return true;
    }
    return false;
}

void ParseTokensIntoMap(const std::vector<std::string>& tokens, ParamMap& out) {
    std::string pendingKey;
    bool expectValue = false;

    for (size_t i = 0; i < tokens.size(); ++i) {
        const std::string& t = tokens[i];
        if (t == "^")
            continue;

        if (expectValue && !pendingKey.empty()) {
            out[pendingKey].push_back(t);
            pendingKey.clear();
            expectValue = false;
            continue;
        }

        if (t.size() >= 2 && t[0] == '-' && t[1] == '-') {
            size_t eq = t.find('=');
            if (eq != std::string::npos) {
                std::string key = t.substr(2, eq - 2);
                std::string val = t.substr(eq + 1);
                if (val.size() >= 2 && val.front() == '"' && val.back() == '"')
                    val = val.substr(1, val.size() - 2);
                out[key].push_back(val);
                pendingKey.clear();
                expectValue = false;
            }
            else {
                std::string key = t.substr(2);
                if (IsArgWithValue(key)) {
                    pendingKey = key;
                    expectValue = true;
                }
                else {
                    out[key].push_back("");
                    pendingKey.clear();
                }
            }
        }
    }
}

// Substitute %BIN%, %LISTS%, %GameFilterTCP%, %GameFilterUDP%
std::string SubstituteVars(const std::string& s,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP)
{
    std::string r = s;
    auto replace = [&r](const char* from, const std::string& to) {
        size_t pos = 0;
        while ((pos = r.find(from, pos)) != std::string::npos) {
            r.replace(pos, strlen(from), to);
            pos += to.size();
        }
    };
    replace("%BIN%", binPath);
    replace("%LISTS%", listsPath);
    replace("%GameFilterTCP%", gameFilterTCP);
    replace("%GameFilterUDP%", gameFilterUDP);
    return r;
}

void AddBlockParamsToVector(const ParamMap& params,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP,
    std::vector<std::string>& out)
{
    for (const auto& kv : params) {
        for (const std::string& val : kv.second) {
            std::string sub = SubstituteVars(val, binPath, listsPath, gameFilterTCP, gameFilterUDP);
            std::string arg = "--" + kv.first;
            if (!sub.empty())
                arg += "=" + (sub.find(' ') != std::string::npos ? "\"" + sub + "\"" : sub);
            out.push_back(arg);
        }
    }
}

} // namespace

Strategy Parse(const std::string& filePath) {
    Strategy s;
    std::string content = ReadFileUtf8(filePath);
    if (content.empty())
        return s;

    std::string argsStr = ExtractArgsFromBatch(content);
    if (argsStr.empty())
        return s;

    // Extract name from path: "C:\path\general (ALT2).bat" -> "general (ALT2)"
    size_t slash = filePath.find_last_of("/\\");
    std::string base = slash != std::string::npos ? filePath.substr(slash + 1) : filePath;
    size_t dot = base.rfind('.');
    if (dot != std::string::npos)
        base.resize(dot);
    s.name = base;

    // Split by " --new " to get blocks
    std::vector<std::string> segments;
    size_t pos = 0;
    const char* delim = " --new ";
    const size_t delimLen = strlen(delim);

    while (pos < argsStr.size()) {
        size_t next = argsStr.find(delim, pos);
        if (next == std::string::npos) {
            std::string seg = argsStr.substr(pos);
            while (!seg.empty() && (seg.back() == ' ' || seg.back() == '\t' || seg.back() == '^'))
                seg.pop_back();
            if (!seg.empty())
                segments.push_back(seg);
            break;
        }
        std::string seg = argsStr.substr(pos, next - pos);
        while (!seg.empty() && (seg.back() == ' ' || seg.back() == '\t' || seg.back() == '^'))
            seg.pop_back();
        if (!seg.empty())
            segments.push_back(seg);
        pos = next + delimLen;
    }

    if (segments.empty())
        return s;

    for (size_t i = 0; i < segments.size(); ++i) {
        std::vector<std::string> tokens = Tokenize(segments[i]);
        ParamMap m;
        ParseTokensIntoMap(tokens, m);

        if (i == 0) {
            // First segment: separate global (--wf-*) from first block (--filter-*)
            ParamMap global;
            FilterBlock firstBlock;
            for (const auto& kv : m) {
                bool isFilter = (kv.first.find("filter-") == 0);
                if (isFilter)
                    firstBlock.params.insert(kv);
                else
                    global.insert(kv);
            }
            s.globalParams = std::move(global);
            if (!firstBlock.params.empty())
                s.blocks.push_back(std::move(firstBlock));
        }
        else {
            FilterBlock block;
            block.params = std::move(m);
            s.blocks.push_back(std::move(block));
        }
    }

    return s;
}

std::vector<std::string> BuildArgs(const Strategy& s,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP)
{
    std::vector<std::string> out;

    for (const auto& kv : s.globalParams) {
        for (const std::string& val : kv.second) {
            std::string sub = SubstituteVars(val, binPath, listsPath, gameFilterTCP, gameFilterUDP);
            std::string arg = "--" + kv.first;
            if (!sub.empty())
                arg += "=" + (sub.find(' ') != std::string::npos ? "\"" + sub + "\"" : sub);
            out.push_back(arg);
        }
    }

    for (size_t i = 0; i < s.blocks.size(); ++i) {
        AddBlockParamsToVector(s.blocks[i].params, binPath, listsPath, gameFilterTCP, gameFilterUDP, out);
        if (i + 1 < s.blocks.size())
            out.push_back("--new");
    }

    return out;
}

std::string BuildArgsString(const Strategy& s,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP)
{
    std::vector<std::string> args = BuildArgs(s, binPath, listsPath, gameFilterTCP, gameFilterUDP);
    std::string r;
    for (size_t i = 0; i < args.size(); ++i) {
        if (i)
            r += " ";
        r += args[i];
    }
    return r;
}

std::string BuildExpandedArgsFromBat(const std::string& filePath,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP)
{
    std::string content = ReadFileUtf8(filePath);
    if (content.empty())
        return {};

    std::string argsStr = ExtractArgsFromBatch(content);
    if (argsStr.empty())
        return {};

    return SubstituteVars(argsStr, binPath, listsPath, gameFilterTCP, gameFilterUDP);
}

} // namespace StrategyParser
