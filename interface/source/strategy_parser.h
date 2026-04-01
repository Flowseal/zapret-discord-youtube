#pragma once

#include <string>
#include <vector>
#include <map>

namespace StrategyParser {

// Generic params: key -> list of values (supports multiple --dpi-desync-fake-tls, etc.)
using ParamMap = std::map<std::string, std::vector<std::string>>;

struct FilterBlock {
    ParamMap params;
};

struct Strategy {
    std::string name;           // file base name (e.g. "general (ALT2)")
    ParamMap globalParams;      // --wf-tcp, --wf-udp, etc.
    std::vector<FilterBlock> blocks;
};

// Parse general*.bat file. Returns empty Strategy on error.
Strategy Parse(const std::string& filePath);

// Rebuild full command-line args for winws.exe from parsed strategy.
// binPath: e.g. "C:\zapret\bin\"
// listsPath: e.g. "C:\zapret\lists\"
// gameFilterTCP, gameFilterUDP: from GameFilter (e.g. "12" or "1024-65535")
std::vector<std::string> BuildArgs(const Strategy& s,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP);

// Single string for CreateProcess etc.
std::string BuildArgsString(const Strategy& s,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP);

// Аргументы как в .bat (после winws.exe), порядок сохранён; подстановка %BIN%, %LISTS%, фильтров игр.
std::string BuildExpandedArgsFromBat(const std::string& filePath,
    const std::string& binPath,
    const std::string& listsPath,
    const std::string& gameFilterTCP,
    const std::string& gameFilterUDP);

} // namespace StrategyParser
