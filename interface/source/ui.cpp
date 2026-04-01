#include "ui.h"
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include "window.h"
#include "app_config.h"
#include "strategy_parser.h"
#include "imgui.h"
#include <shellapi.h>
#include <wininet.h>
#include <tlhelp32.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#pragma comment(lib, "wininet.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")
#include <string>
#include <vector>
#include <filesystem>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <thread>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <wchar.h> // _wcsicmp
#include <mutex>
#include <map>
#include <array>
#include <atomic>
#include <future>
#include <system_error>

namespace fs = std::filesystem;

// Шрифты секций (меньше — верхний блок, больше — блок стратегий); title bar остаётся на io.FontDefault
static ImFont* g_fontSection1 = nullptr;
static ImFont* g_fontSection2 = nullptr;

// Совпадает с аргументами запуска proxy и с tg://socks в tg-ws-proxy (windows.py).
static constexpr const char* kTgWsProxyListenHost = "127.0.0.1";
static constexpr int kTgWsProxyListenPort = 1080;

static std::vector<std::string> ScanStrategies(const std::string& rootDir);

// Глобальные переменные для версий
static std::string g_localVersion = "Unknown";
static std::string g_remoteVersion = "Unknown";
static bool g_updateAvailable = false;
static bool g_versionCheckCompleted = false;
static bool g_updateInProgress = false;
static std::mutex g_versionStateMutex;
static std::atomic<bool> g_bootstrapInProgress(false);
static std::atomic<unsigned int> g_strategyRefreshToken(0);

// Глобальные переменные для статусов сервисов
static std::atomic<int> g_discordStatus(1);  // 0 = ок, 1 = тестирование, 2 = недоступно
static std::atomic<int> g_youtubeStatus(1);
static std::atomic<int> g_telegramStatus(1);
static std::atomic<bool> g_servicesCheckInProgress(false);

// Глобальная переменная для процесса winws
static HANDLE g_winwsProcess = nullptr;
static std::mutex g_processMutex;
static HANDLE g_tgWsProxyProcess = nullptr;
static std::mutex g_tgWsProxyMutex;

// ндексы выбранной и активной стратегии (сбрасываются при нажатии "Стоп")
static std::atomic<int> g_selectedStrategyIdx(-1);
static std::atomic<int> g_activeStrategyIdx(-1);

// Тестирование стратегий: ok[0..2] = Discord, YouTube, Telegram; pingMs = ICMP RTT (мс), -1 = нет данных
struct StrategyTestEntry {
    std::array<bool, 3> ok{};
    int pingMs = -1;
};
static std::map<std::string, StrategyTestEntry> g_strategyTestResults;
static std::mutex g_strategyTestMutex;
static std::atomic<bool> g_strategyTestInProgress(false);
static std::atomic<bool> g_strategyTestStopRequested(false);
static bool g_strategyTestPaused = false;
static int g_strategyTestResumeFromIndex = 0;
static std::string g_strategyTestRestoreStrategy;
static std::string g_strategyTestCurrent;
static int g_strategyTestCurrentIdx = 0;
static int g_strategyTestTotal = 0;
static std::string g_bestStrategy;  // Лучшая стратегия по результатам теста (как в test zapret.ps1: max OK)
static std::string g_lastRuntimeError;
static std::mutex g_runtimeMessageMutex;
static std::atomic<bool> g_tgFixSetupInProgress(false);
static bool g_tgFixSetupCompleted = false;
static bool g_tgFixSetupSuccess = false;
static std::string g_tgFixSetupMessage;
static std::mutex g_tgFixSetupMutex;
static std::string g_tgPythonLauncher;
static std::mutex g_tgPythonMutex;

static void RunStrategyTest(int startIndex);

// Вычисляет лучшую стратегию по результатам теста (как в test zapret.ps1: max OK)
static void UpdateBestStrategyFromResults()
{
    std::lock_guard<std::mutex> lock(g_strategyTestMutex);
    g_bestStrategy.clear();
    if (g_strategyTestResults.empty()) return;

    std::string best;
    int maxScore = -1;
    int bestPingMs = -1;
    for (const auto& p : g_strategyTestResults)
    {
        int score = 0;
        for (bool v : p.second.ok) if (v) ++score;
        const int ping = p.second.pingMs;
        bool wins = false;
        if (score > maxScore)
            wins = true;
        else if (score == maxScore)
        {
            if (ping >= 0 && bestPingMs < 0)
                wins = true;
            else if (ping >= 0 && bestPingMs >= 0 && ping < bestPingMs)
                wins = true;
        }
        if (wins)
        {
            maxScore = score;
            best = p.first;
            bestPingMs = ping;
        }
    }
    if (maxScore >= 0) g_bestStrategy = best;
}

// Объявления функций для работы с версиями
static std::string GetLocalVersion();
static std::string GetRemoteVersion();
static void CheckVersionsAsync();
static void PerformUpdateAsync();
static std::string GetActiveStrategyNameSnapshot();
static void RestoreZapretStateAfterUpdate(bool wasRunning, const std::string& strategyName);
static void RestoreTelegramProxyStateAfterUpdate(bool wasRunning);
static bool DownloadFileToPath(const char* url, const std::string& destPath);
static bool ExtractZipWithPowerShell(const std::string& zipPath, const std::string& destDir);
static void CopyDirectoryContents(const fs::path& src, const fs::path& dest);
static int GetZapretStatus(); // 0 = работает, 1 = запускается, 2 = не работает
static int GetGameFilterStatus(); // 0 = OFF, 1 = TCP, 2 = UDP, 3 = TCP+UDP
static int MeasureIcmpPingMs(); // RTT до 1.1.1.1 (мс) или -1
static int CheckServiceStatus(const std::string& service, bool strategyTestMode = false); // 0 = ок, 1 = тестирование, 2 = недоступно
static void CheckAllServicesAsync(const std::string* strategyNameForCircles = nullptr);
static std::array<int, 3> CheckAllServiceStatusesParallel();
static std::array<int, 3> CheckAllServiceStatusesParallelForStrategyTest();
static void LaunchStrategy(const std::string& strategyName, bool scheduleServiceCheck = true);
static bool IsTelegramWsProxyRunning();
static bool StartTelegramWsProxy();
static void StopTelegramWsProxy();
static void ClearTgFixStatusStrip();
static void ShutdownAllTelegramWsProxyProcesses();
static void KillProcessTreeByRootPid(DWORD rootPid);
static void RunTgFixSetupAndLaunch();
static fs::path ResolveTelegramWsProxyRoot();
static fs::path GetUnifiedDeployBaseRoot();
static fs::path GetUnifiedZapretRootPath();
static fs::path GetUnifiedTelegramProxyRootPath();
static bool EnsureUnifiedDirectory(const fs::path& dir);
static bool DeployRepositoryArchiveIfMissing(
    const char* archiveUrl,
    const char* extractedFolderName,
    const fs::path& targetRoot,
    const fs::path& requiredPathInTarget);
static void EnsureUnifiedDeploymentAsync();
static void BootstrapRuntimeStateAsync();
static bool RunHiddenCommand(
    const std::string& commandLine,
    const std::string& workDir,
    DWORD timeoutMs,
    DWORD* outExitCode = nullptr);
static bool CommandSucceeded(
    const std::string& commandLine,
    const std::string& workDir,
    DWORD timeoutMs = 120000);
static std::vector<std::string> GetPythonLaunchersForProxy();
static bool DetectPythonLauncher(const std::string& workDir, std::string& outLauncher);
static bool EnsurePipAvailable(const std::string& launcher, const std::string& workDir);
static bool InstallTelegramProxyDependencies(
    const fs::path& tgProxyRoot,
    const std::string& launcher,
    std::string& outError);
static std::string FileSignatureForDepsMarker(const fs::path& p);
static bool TgProxyDepsMarkerMatches(const fs::path& root);
static void WriteTgProxyDepsMarker(const fs::path& root);
static void OpenPythonManagerInstallerMsix();
static bool CopyStringToWindowsClipboardUtf8(const std::string& utf8);
static std::string BuildTelegramDesktopSocksDeepLink();
static void StopZapret();
static void StopWinDivertServices();
static void StartWinDivertServices();
static void WaitForZapretStopped(int maxWaitMs);
static void WaitForZapretStoppedInterruptible(int maxWaitMs);
static void StrategyTestInterruptibleSleepMs(int totalMs);
static void EnsureTcpTimestampsEnabled();
static void EnsureUserListsFiles(const std::string& rootDir);
static std::string BuildArgsForStrategy(const std::string& strategyName, const std::string& rootDir);
static HANDLE LaunchWinwsProcess(const std::string& args);
static std::string LoadLastLaunchedStrategy();

// Объявления функций для отдельных блоков UI
static void DrawTitleBarButtons(float w, float titleBarHeight, float buttonSize, float buttonSpacing);
static void DrawVersionSection(float x, float y, float width, float height);
static void DrawStrategiesSection(float x, float y, float width, float height);
static void TryAutostartLaunchLastStrategy(bool fromAutostart);

static void DrawButtonGlow(ImVec2 center, ImU32 color, float baseRadius)
{
    ImDrawList* dl = ImGui::GetWindowDrawList();
    const float radii[]  = { baseRadius * 2.5f, baseRadius * 2.0f, baseRadius * 1.5f, baseRadius * 1.0f, baseRadius * 0.5f };
    const float alphas[] = { 0.02f, 0.06f, 0.14f, 0.24f, 0.40f };
    ImU32 rgb = color & 0x00FFFFFF;
    for (int i = 0; i < 5; i++)
    {
        ImU32 col = rgb | ((ImU32)(alphas[i] * 255) << 24);
        dl->AddCircleFilled(center, radii[i], col, 32);
    }
}

static bool IsValidZapretRoot(const fs::path& root)
{
    return fs::exists(root / "bin" / "winws.exe") &&
           fs::exists(root / "lists") &&
           fs::is_directory(root / "lists");
}

static bool IsValidTelegramProxyRoot(const fs::path& root)
{
    if (root.empty())
        return false;
    return fs::exists(root / "TgWsProxy_windows.exe") ||
           fs::exists(root / "proxy" / "tg_ws_proxy.py");
}

static fs::path GetUnifiedDeployBaseRoot()
{
    const char* pf86 = std::getenv("ProgramFiles(x86)");
    if (pf86 && pf86[0] != '\0')
        return fs::path(pf86) / "AntiZapret";

    const char* pf = std::getenv("ProgramFiles");
    if (pf && pf[0] != '\0')
        return fs::path(pf) / "AntiZapret";

    return fs::path("C:\\Program Files (x86)\\AntiZapret");
}

static fs::path GetUnifiedZapretRootPath()
{
    return GetUnifiedDeployBaseRoot() / "zapret-discord-youtube";
}

static fs::path GetUnifiedTelegramProxyRootPath()
{
    return GetUnifiedDeployBaseRoot() / "tg-ws-proxy";
}

static bool EnsureUnifiedDirectory(const fs::path& dir)
{
    try
    {
        fs::create_directories(dir);
        return fs::exists(dir) && fs::is_directory(dir);
    }
    catch (...)
    {
        return false;
    }
}

static fs::path GetStrategyTestResultsIniPath()
{
    return GetUnifiedDeployBaseRoot() / "result.ini";
}

static void SaveStrategyTestResultsToIni()
{
    UpdateBestStrategyFromResults();
    std::map<std::string, StrategyTestEntry> snapshot;
    {
        std::lock_guard<std::mutex> lock(g_strategyTestMutex);
        snapshot = g_strategyTestResults;
    }

    const fs::path iniPath = GetStrategyTestResultsIniPath();
    std::error_code ec;
    fs::create_directories(iniPath.parent_path(), ec);
    const fs::path tmpPath = iniPath;
    fs::path tmpFile = tmpPath;
    tmpFile += ".tmp";
    fs::remove(tmpFile, ec);
    ec.clear();

    {
        std::ofstream out(tmpFile, std::ios::out | std::ios::trunc | std::ios::binary);
        if (!out)
            return;
        out << "; AntiZapret strategy test results: name|D|Y|T|pingMs (1=ok, pingMs=-1 если ICMP недоступен)\r\n";
        for (const auto& kv : snapshot)
        {
            const auto& e = kv.second;
            out << kv.first << '|' << (e.ok[0] ? '1' : '0') << '|' << (e.ok[1] ? '1' : '0') << '|' << (e.ok[2] ? '1' : '0')
                << '|' << e.pingMs << "\r\n";
        }
    }

    ec.clear();
    fs::remove(iniPath, ec);
    ec.clear();
    fs::rename(tmpFile, iniPath, ec);
    if (ec)
    {
        std::error_code ec2;
        fs::remove(iniPath, ec2);
        fs::rename(tmpFile, iniPath, ec2);
    }
}

static void LoadStrategyTestResultsFromIni()
{
    const fs::path iniPath = GetStrategyTestResultsIniPath();
    std::ifstream in(iniPath, std::ios::binary);
    if (!in)
        return;

    std::map<std::string, StrategyTestEntry> loaded;
    std::string line;
    while (std::getline(in, line))
    {
        if (!line.empty() && line.back() == '\r')
            line.pop_back();
        if (line.empty() || line[0] == ';' || line[0] == '#')
            continue;

        std::vector<std::string> parts;
        parts.reserve(6);
        size_t start = 0;
        while (start <= line.size())
        {
            const size_t p = line.find('|', start);
            if (p == std::string::npos)
            {
                parts.push_back(line.substr(start));
                break;
            }
            parts.push_back(line.substr(start, p - start));
            start = p + 1;
        }
        if (parts.size() < 4)
            continue;

        const std::string& name = parts[0];
        if (name.empty() || parts[1].size() != 1u || parts[2].size() != 1u || parts[3].size() != 1u)
            continue;

        StrategyTestEntry ent;
        ent.ok = { (parts[1][0] == '1'), (parts[2][0] == '1'), (parts[3][0] == '1') };
        if (parts.size() >= 5)
        {
            const int v = std::atoi(parts[4].c_str());
            ent.pingMs = v;
        }
        loaded[name] = ent;
    }

    {
        std::lock_guard<std::mutex> lock(g_strategyTestMutex);
        g_strategyTestResults = std::move(loaded);
    }
    UpdateBestStrategyFromResults();
}

static bool DeployRepositoryArchiveIfMissing(
    const char* archiveUrl,
    const char* extractedFolderName,
    const fs::path& targetRoot,
    const fs::path& requiredPathInTarget)
{
    if (fs::exists(requiredPathInTarget))
        return true;

    if (!EnsureUnifiedDirectory(targetRoot.parent_path()))
        return false;

    const std::string zipPath = (targetRoot.parent_path() / "_bootstrap_repo.zip").string();
    const std::string extractDir = (targetRoot.parent_path() / "_bootstrap_repo_tmp").string();

    try { fs::remove_all(extractDir); } catch (...) {}
    try { fs::remove(zipPath); } catch (...) {}

    if (!DownloadFileToPath(archiveUrl, zipPath))
        return false;
    if (!ExtractZipWithPowerShell(zipPath, extractDir))
        return false;

    const fs::path extractedRoot = fs::path(extractDir) / extractedFolderName;
    if (!fs::exists(extractedRoot))
        return false;

    EnsureUnifiedDirectory(targetRoot);
    CopyDirectoryContents(extractedRoot, targetRoot);

    try
    {
        fs::remove_all(extractDir);
        fs::remove(zipPath);
    }
    catch (...) {}

    return fs::exists(requiredPathInTarget);
}

static void EnsureUnifiedDeploymentAsync()
{
    const fs::path deployBase = GetUnifiedDeployBaseRoot();
    const fs::path zapretRoot = GetUnifiedZapretRootPath();
    const fs::path tgRoot = GetUnifiedTelegramProxyRootPath();
    EnsureUnifiedDirectory(deployBase);
    EnsureUnifiedDirectory(zapretRoot);
    EnsureUnifiedDirectory(tgRoot);

    if (!IsValidZapretRoot(zapretRoot))
    {
        DeployRepositoryArchiveIfMissing(
            AppConfig::kUpdateArchiveUrl,
            AppConfig::kZapretRepoExtractedFolderName,
            zapretRoot,
            zapretRoot / "bin" / "winws.exe");
    }

    // Как zapret: при пустом/неполном tg-ws-proxy качаем репозиторий сразу при старте,
    // а не только при ручном «TG Fix».
    if (!IsValidTelegramProxyRoot(tgRoot))
    {
        DeployRepositoryArchiveIfMissing(
            AppConfig::kTelegramProxyArchiveUrl,
            AppConfig::kTelegramRepoExtractedFolderName,
            tgRoot,
            tgRoot / "proxy" / "tg_ws_proxy.py");
    }
}

static void BootstrapRuntimeStateAsync()
{
    g_bootstrapInProgress.store(true);
    EnsureUnifiedDeploymentAsync();
    g_strategyRefreshToken.fetch_add(1);

    {
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        g_localVersion = GetLocalVersion();
        g_remoteVersion = "Unknown";
        g_updateAvailable = false;
        g_versionCheckCompleted = false;
    }

    g_bootstrapInProgress.store(false);
    CheckVersionsAsync();
}

static std::string GetRootFromInstalledService()
{
    SC_HANDLE scm = OpenSCManagerA(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!scm)
        return "";

    SC_HANDLE service = OpenServiceA(scm, "zapret", SERVICE_QUERY_CONFIG);
    if (!service)
    {
        CloseServiceHandle(scm);
        return "";
    }

    DWORD bytesNeeded = 0;
    QueryServiceConfigA(service, nullptr, 0, &bytesNeeded);
    if (bytesNeeded == 0)
    {
        CloseServiceHandle(service);
        CloseServiceHandle(scm);
        return "";
    }

    std::vector<char> buffer(bytesNeeded);
    QUERY_SERVICE_CONFIGA* cfg = reinterpret_cast<QUERY_SERVICE_CONFIGA*>(buffer.data());
    if (!QueryServiceConfigA(service, cfg, bytesNeeded, &bytesNeeded) || !cfg->lpBinaryPathName)
    {
        CloseServiceHandle(service);
        CloseServiceHandle(scm);
        return "";
    }

    std::string imagePath = cfg->lpBinaryPathName;
    CloseServiceHandle(service);
    CloseServiceHandle(scm);

    // Формат обычно: "\"C:\\path\\bin\\winws.exe\" --args"
    std::string exePath;
    if (!imagePath.empty() && imagePath.front() == '"')
    {
        const size_t closingQuote = imagePath.find('"', 1);
        if (closingQuote != std::string::npos)
            exePath = imagePath.substr(1, closingQuote - 1);
    }
    else
    {
        const size_t firstSpace = imagePath.find(' ');
        exePath = imagePath.substr(0, firstSpace);
    }

    if (exePath.empty())
        return "";

    // Некоторые конфигурации служб хранят NT-путь вида \??\C:\...
    if (exePath.rfind("\\??\\", 0) == 0)
        exePath.erase(0, 4);

    fs::path candidate = fs::path(exePath).parent_path().parent_path(); // ...\bin\winws.exe -> root
    if (!candidate.empty() && IsValidZapretRoot(candidate))
        return candidate.string();

    return "";
}

// Находит корень zapret
static std::string GetZapretRoot()
{
    const fs::path unifiedRoot = GetUnifiedZapretRootPath();
    if (IsValidZapretRoot(unifiedRoot))
        return unifiedRoot.string();

    char exePath[MAX_PATH];
    if (GetModuleFileNameA(nullptr, exePath, MAX_PATH) == 0)
        return ".";

    fs::path exeDir(exePath);
    exeDir = exeDir.parent_path();
    fs::path cursor = exeDir;
    for (int i = 0; i < 6; ++i)
    {
        if (IsValidZapretRoot(cursor))
            return cursor.string();
        if (!cursor.has_parent_path())
            break;
        cursor = cursor.parent_path();
    }

    // Если cwd указывает на валидный root, используем его.
    // Это полезно для сценариев portable-запуска.
    char cwd[MAX_PATH];
    if (GetCurrentDirectoryA(MAX_PATH, cwd))
    {
        fs::path cwdPath(cwd);
        if (IsValidZapretRoot(cwdPath))
            return cwdPath.string();
    }

    // Только fallback: путь из установленной службы (может быть устаревшим после переноса).
    const std::string serviceRoot = GetRootFromInstalledService();
    if (!serviceRoot.empty())
        return serviceRoot;

    // Если unified-root еще не развёрнут, всё равно возвращаем его как целевой путь установки.
    if (EnsureUnifiedDirectory(unifiedRoot))
        return unifiedRoot.string();

    return exeDir.string();
}

// Сортировка как в проводнике: ALT2 < ALT10 (цифры как числа, не посимвольно).
static bool CompareStrategyNamesNatural(const std::string& a, const std::string& b)
{
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        const unsigned char ca = static_cast<unsigned char>(a[i]);
        const unsigned char cb = static_cast<unsigned char>(b[j]);
        const bool da = std::isdigit(ca) != 0;
        const bool db = std::isdigit(cb) != 0;
        if (da && db) {
            size_t ai = i;
            while (ai < a.size() && std::isdigit(static_cast<unsigned char>(a[ai])))
                ++ai;
            size_t bj = j;
            while (bj < b.size() && std::isdigit(static_cast<unsigned char>(b[bj])))
                ++bj;
            unsigned long long va = 0;
            for (size_t k = i; k < ai; ++k)
                va = va * 10ull + static_cast<unsigned long long>(a[k] - '0');
            unsigned long long vb = 0;
            for (size_t k = j; k < bj; ++k)
                vb = vb * 10ull + static_cast<unsigned long long>(b[k] - '0');
            if (va != vb)
                return va < vb;
            i = ai;
            j = bj;
        }
        else {
            const char la = static_cast<char>(std::tolower(ca));
            const char lb = static_cast<char>(std::tolower(cb));
            if (la != lb)
                return la < lb;
            ++i;
            ++j;
        }
    }
    return a.size() < b.size();
}

// Список стратегий: файлы general*.bat в корне zapret (имя без .bat).
static std::vector<std::string> ScanStrategies(const std::string& rootDir)
{
    std::vector<std::string> out;
    const fs::path root(rootDir);
    if (!fs::exists(root) || !fs::is_directory(root))
        return out;

    auto stemStartsWithGeneral = [](const std::string& stem) -> bool {
        static const char kPrefix[] = "general";
        const size_t n = sizeof(kPrefix) - 1;
        if (stem.size() < n)
            return false;
        for (size_t i = 0; i < n; ++i) {
            if (std::tolower(static_cast<unsigned char>(stem[i])) != static_cast<unsigned char>(kPrefix[i]))
                return false;
        }
        return true;
    };

    try {
        for (const auto& ent : fs::directory_iterator(root)) {
            if (!ent.is_regular_file())
                continue;
            const fs::path& p = ent.path();
            std::string ext = p.extension().string();
            for (char& c : ext)
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            if (ext != ".bat")
                continue;
            const std::string stem = p.stem().string();
            if (!stemStartsWithGeneral(stem))
                continue;
            out.push_back(stem);
        }
    } catch (...) {
        return {};
    }

    std::sort(out.begin(), out.end(), CompareStrategyNamesNatural);
    return out;
}

void UI_Init(float dpiScale, bool startupFromAutostart)
{
    EnsureUnifiedDirectory(GetUnifiedDeployBaseRoot());
    EnsureUnifiedDirectory(GetUnifiedZapretRootPath());
    EnsureUnifiedDirectory(GetUnifiedTelegramProxyRootPath());
    LoadStrategyTestResultsFromIni();
    std::thread(BootstrapRuntimeStateAsync).detach();

    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;

    ImGui::StyleColorsDark();
    ImGuiStyle& style = ImGui::GetStyle();
    style.ScaleAllSizes(dpiScale);
    style.FontScaleDpi = dpiScale;

    style.FrameRounding = 6.0f;
    style.ChildRounding = 6.0f;
    style.ScrollbarRounding = 4.0f;
    style.GrabRounding = 4.0f;
    style.WindowRounding = 0.0f;

    style.Colors[ImGuiCol_WindowBg] = ImVec4(0.06275f, 0.06275f, 0.06275f, 1.0f);   // #101010
    style.Colors[ImGuiCol_ChildBg] = ImVec4(0.1255f, 0.1216f, 0.1412f, 1.0f);       // #201F24
    style.Colors[ImGuiCol_Button] = ImVec4(0.22f, 0.22f, 0.26f, 1.0f);
    style.Colors[ImGuiCol_ButtonHovered] = ImVec4(0.28f, 0.28f, 0.32f, 1.0f);
    style.Colors[ImGuiCol_ButtonActive] = ImVec4(0.18f, 0.18f, 0.22f, 1.0f);
    style.Colors[ImGuiCol_FrameBg] = ImVec4(0.18f, 0.18f, 0.22f, 1.0f);
    style.Colors[ImGuiCol_ScrollbarBg] = ImVec4(0.06275f, 0.06275f, 0.06275f, 1.0f);  // #101010

    char winDir[MAX_PATH];
    GetWindowsDirectoryA(winDir, MAX_PATH);
    std::string fontsDir = std::string(winDir) + "\\Fonts\\";
    const char* fontFiles[] = {"tahoma.ttf", "arial.ttf" };
    ImFont* fontMain = nullptr;
    g_fontSection1 = nullptr;
    g_fontSection2 = nullptr;
    const ImWchar* glyphRanges = io.Fonts->GetGlyphRangesCyrillic();
    for (const char* f : fontFiles)
    {
        std::string path = fontsDir + f;
        if (GetFileAttributesA(path.c_str()) == INVALID_FILE_ATTRIBUTES)
            continue;
        fontMain = io.Fonts->AddFontFromFileTTF(path.c_str(), 14.0f, nullptr, glyphRanges);
        if (!fontMain)
            continue;
        g_fontSection1 = io.Fonts->AddFontFromFileTTF(path.c_str(), 13, nullptr, glyphRanges);
        g_fontSection2 = io.Fonts->AddFontFromFileTTF(path.c_str(), 15, nullptr, glyphRanges);
        break;
    }
    if (fontMain)
    {
        io.FontDefault = fontMain;
        if (!g_fontSection1) g_fontSection1 = fontMain;
        if (!g_fontSection2) g_fontSection2 = fontMain;
    }
    else
    {
        io.Fonts->AddFontDefault();
        g_fontSection1 = io.FontDefault;
        g_fontSection2 = io.FontDefault;
    }
    
    // Локальная/удаленная версии и состояние обновлений инициализируются в BootstrapRuntimeStateAsync:
    // сначала подтягиваем недостающие файлы в root, затем обновляем runtime-состояние.
    TryAutostartLaunchLastStrategy(startupFromAutostart);
}

void UI_Shutdown()
{
    SaveStrategyTestResultsToIni();
    // Останавливаем Zapret при закрытии приложения
    StopZapret();
    // TG proxy: дерево cmd→python и отдельные TgWsProxy_windows.exe
    ShutdownAllTelegramWsProxyProcesses();
}

// ===== РЕАЛЗАЦ ОТДЕЛЬНЫХ БЛОКОВ UI =====

static void DrawTitleBarButtons(float w, float titleBarHeight, float buttonSize, float buttonSpacing)
{
    HWND hwnd = Window_GetHandle();
    float buttonY = (titleBarHeight - buttonSize) * 0.5f;
    float buttonsStartX = w - (buttonSize * 3 + buttonSpacing * 2) - 8.0f;
    float centerY = buttonY + buttonSize * 0.5f;

    static bool prevCloseHover = false, prevMinHover = false, prevMaxHover = false;

    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, buttonSize * 0.5f);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(buttonSpacing, 0));

    // Порядок: зелёная (свернуть), жёлтая (развернуть), красная (закрыть)
    float bx = buttonsStartX;

    // Зелёная кнопка - свернуть
    if (prevMinHover) DrawButtonGlow(ImVec2(bx + buttonSize * 0.5f, centerY), IM_COL32(38, 191, 84, 255), buttonSize * 0.5f);
    ImGui::SetCursorPos(ImVec2(bx, buttonY));
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.13f, 0.69f, 0.3f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.15f, 0.75f, 0.33f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.11f, 0.6f, 0.26f, 1.0f));
    if (ImGui::Button("##Minimize", ImVec2(buttonSize, buttonSize))) ShowWindow(hwnd, SW_MINIMIZE);
    prevMinHover = ImGui::IsItemHovered();
    ImGui::PopStyleColor(3);
    bx += buttonSize + buttonSpacing;

    // Жёлтая кнопка - развернуть/восстановить
    if (prevMaxHover) DrawButtonGlow(ImVec2(bx + buttonSize * 0.5f, centerY), IM_COL32(255, 204, 26, 255), buttonSize * 0.5f);
    ImGui::SetCursorPos(ImVec2(bx, buttonY));
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.95f, 0.76f, 0.06f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 0.8f, 0.1f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.85f, 0.65f, 0.05f, 1.0f));
    WINDOWPLACEMENT wp = { sizeof(WINDOWPLACEMENT) };
    GetWindowPlacement(hwnd, &wp);
    bool isMax = (wp.showCmd == SW_SHOWMAXIMIZED);
    if (ImGui::Button("##Maximize", ImVec2(buttonSize, buttonSize))) ShowWindow(hwnd, isMax ? SW_RESTORE : SW_MAXIMIZE);
    prevMaxHover = ImGui::IsItemHovered();
    ImGui::PopStyleColor(3);
    bx += buttonSize + buttonSpacing;

    // Красная кнопка - закрыть
    if (prevCloseHover) DrawButtonGlow(ImVec2(bx + buttonSize * 0.5f, centerY), IM_COL32(255, 77, 54, 255), buttonSize * 0.5f);
    ImGui::SetCursorPos(ImVec2(bx, buttonY));
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.96f, 0.26f, 0.21f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 0.3f, 0.25f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.85f, 0.22f, 0.18f, 1.0f));
    if (ImGui::Button("##Close", ImVec2(buttonSize, buttonSize))) PostMessage(hwnd, WM_CLOSE, 0, 0);
    prevCloseHover = ImGui::IsItemHovered();
    ImGui::PopStyleColor(3);

    ImGui::PopStyleVar(2);
}

static std::string GetLocalVersion()
{
    std::string root = GetZapretRoot();
    std::vector<std::string> possiblePaths = {
        root + "\\.service\\version.txt",
        root + "\\..\\..\\zapret-discord-youtube\\.service\\version.txt", // Если запускается из interface/bin
        ".\\.service\\version.txt",
        "..\\.service\\version.txt",
        "..\\..\\zapret-discord-youtube\\.service\\version.txt"
    };
    
    // Пробуем найти файл version.txt в разных местах
    for (const std::string& versionPath : possiblePaths)
    {
        std::ifstream file(versionPath);
        if (file.is_open())
        {
            std::string version;
            if (std::getline(file, version))
            {
                // Убираем возможные пробелы в начале и конце
                size_t start = version.find_first_not_of(" \t\r\n");
                if (start != std::string::npos)
                {
                    size_t end = version.find_last_not_of(" \t\r\n");
                    version = version.substr(start, end - start + 1);
                    
                    if (!version.empty())
                    {
                        file.close();
                        return version; // Найдена версия!
                    }
                }
            }
            file.close();
        }
    }
    
    // Fallback: попробуем прочитать из service.bat
    std::string serviceBatPath = root + "\\service.bat";
    std::ifstream serviceBat(serviceBatPath);
    std::string line;
    
    if (serviceBat.is_open())
    {
        while (std::getline(serviceBat, line))
        {
            // щем строку set "LOCAL_VERSION=1.9.7b"
            size_t pos = line.find("LOCAL_VERSION=");
            if (pos != std::string::npos)
            {
                size_t start = line.find('"', pos);
                if (start != std::string::npos)
                {
                    start++; // Пропускаем открывающую кавычку
                    size_t end = line.find('"', start);
                    if (end != std::string::npos)
                    {
                        serviceBat.close();
                        return line.substr(start, end - start);
                    }
                }
            }
        }
        serviceBat.close();
    }
    
    return "Unknown"; // Если не удалось прочитать ни из одного источника
}

static std::string GetRemoteVersion()
{
    std::string result = "Unknown";
    
    // спользуем WinINet API для HTTP запроса без консольных окон
    HINTERNET hInternet = InternetOpenA("AntiZapret", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
    if (hInternet)
    {
        HINTERNET hUrl = InternetOpenUrlA(hInternet, 
            AppConfig::kVersionUrl,
            NULL, 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE, 0);
        
        if (hUrl)
        {
            char buffer[256] = {0};
            DWORD bytesRead = 0;
            
            if (InternetReadFile(hUrl, buffer, sizeof(buffer) - 1, &bytesRead))
            {
                if (bytesRead > 0)
                {
                    buffer[bytesRead] = '\0';
                    result = std::string(buffer);
                    
                    // Убираем лишние символы (переводы строк, пробелы)
                    size_t start = result.find_first_not_of(" \t\r\n");
                    if (start != std::string::npos)
                    {
                        size_t end = result.find_last_not_of(" \t\r\n");
                        result = result.substr(start, end - start + 1);
                    }
                }
            }
            InternetCloseHandle(hUrl);
        }
        InternetCloseHandle(hInternet);
    }
    
    return result;
}

static void CheckVersionsAsync()
{
    // Единый сценарий: проверка версии + обновление при необходимости.
    const std::string localVersion = GetLocalVersion();
    const std::string remoteVersion = GetRemoteVersion();
    const bool hasComparableVersions = (localVersion != "Unknown" && remoteVersion != "Unknown");
    const bool needsUpdate = hasComparableVersions && (localVersion != remoteVersion);

    {
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        g_localVersion = localVersion;
        g_remoteVersion = remoteVersion;
        g_updateAvailable = needsUpdate;
        g_versionCheckCompleted = true;
    }

    if (needsUpdate)
        std::thread(PerformUpdateAsync).detach();
}

static bool DownloadFileToPath(const char* url, const std::string& destPath)
{
    HINTERNET hInternet = InternetOpenA("AntiZapret", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
    if (!hInternet) return false;
    DWORD timeout = 60000;
    InternetSetOptionA(hInternet, INTERNET_OPTION_CONNECT_TIMEOUT, &timeout, sizeof(timeout));
    InternetSetOptionA(hInternet, INTERNET_OPTION_RECEIVE_TIMEOUT, &timeout, sizeof(timeout));
    HINTERNET hUrl = InternetOpenUrlA(hInternet, url, NULL, 0, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE, 0);
    if (!hUrl) { InternetCloseHandle(hInternet); return false; }
    std::ofstream out(destPath, std::ios::binary);
    if (!out) { InternetCloseHandle(hUrl); InternetCloseHandle(hInternet); return false; }
    char buf[65536];
    DWORD read;
    while (InternetReadFile(hUrl, buf, sizeof(buf), &read) && read > 0)
        out.write(buf, read);
    out.close();
    InternetCloseHandle(hUrl);
    InternetCloseHandle(hInternet);
    return true;
}

static bool ExtractZipWithPowerShell(const std::string& zipPath, const std::string& destDir)
{
    std::string cmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$ErrorActionPreference='Continue'; Expand-Archive -Path \\\"" +
        zipPath + "\\\" -DestinationPath \\\"" + destDir + "\\\" -Force\"";
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    std::string fullCmd = "cmd /c " + cmd;
    std::vector<char> cmdBuf(fullCmd.begin(), fullCmd.end());
    cmdBuf.push_back('\0');
    BOOL ok = CreateProcessA(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    if (!ok) return false;
    WaitForSingleObject(pi.hProcess, 120000);
    DWORD exitCode = 1;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (exitCode == 0);
}

static void CopyDirectoryContents(const fs::path& src, const fs::path& dest)
{
    if (!fs::exists(src) || !fs::is_directory(src)) return;
    try
    {
        for (const auto& entry : fs::recursive_directory_iterator(src, fs::directory_options::skip_permission_denied))
        {
            try
            {
                fs::path rel = fs::relative(entry.path(), src);
                fs::path destPath = dest / rel;
                if (entry.is_directory())
                    fs::create_directories(destPath);
                else
                {
                    fs::create_directories(destPath.parent_path());
                    fs::copy_file(entry.path(), destPath, fs::copy_options::overwrite_existing);
                }
            }
            catch (...) {}  // Пропускаем проблемный элемент и продолжаем
        }
    }
    catch (...) {}
}

static std::string GetActiveStrategyNameSnapshot()
{
    const int activeIdx = g_activeStrategyIdx.load();
    if (activeIdx < 0)
        return {};

    const std::vector<std::string> strategies = ScanStrategies(GetZapretRoot());
    if (activeIdx >= (int)strategies.size())
        return {};
    return strategies[(size_t)activeIdx];
}

static void RestoreZapretStateAfterUpdate(bool wasRunning, const std::string& strategyName)
{
    if (!wasRunning)
        return;

    std::string strategyToLaunch = strategyName;
    if (strategyToLaunch.empty())
        strategyToLaunch = LoadLastLaunchedStrategy();
    if (strategyToLaunch.empty())
        return;

    LaunchStrategy(strategyToLaunch, false);
    const std::vector<std::string> strategies = ScanStrategies(GetZapretRoot());
    for (size_t i = 0; i < strategies.size(); ++i)
    {
        if (strategies[i] == strategyToLaunch)
        {
            g_selectedStrategyIdx.store((int)i);
            g_activeStrategyIdx.store((int)i);
            break;
        }
    }
}

static void RestoreTelegramProxyStateAfterUpdate(bool wasRunning)
{
    if (!wasRunning)
        return;
    StartTelegramWsProxy();
}

static void PerformUpdateAsync()
{
    {
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        if (g_updateInProgress)
            return;
        g_updateInProgress = true;
    }

    const bool wasZapretRunning = (GetZapretStatus() != 2);
    const bool wasTelegramProxyRunning = IsTelegramWsProxyRunning();
    const std::string activeStrategyBeforeUpdate = GetActiveStrategyNameSnapshot();

    // Останавливаем всё потенциально конфликтующее перед обновлением.
    StopZapret();
    ShutdownAllTelegramWsProxyProcesses();
    StopWinDivertServices();
    WaitForZapretStopped(10000);

    std::string root = GetZapretRoot();
    std::string zipPath = root + "\\_update.zip";
    std::string extractDir = root + "\\_update_tmp";
    const char* zipUrl = AppConfig::kUpdateArchiveUrl;

    if (!DownloadFileToPath(zipUrl, zipPath))
    {
        StartWinDivertServices();
        RestoreZapretStateAfterUpdate(wasZapretRunning, activeStrategyBeforeUpdate);
        RestoreTelegramProxyStateAfterUpdate(wasTelegramProxyRunning);
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        g_updateInProgress = false;
        return;
    }

    fs::create_directories(extractDir);
    if (!ExtractZipWithPowerShell(zipPath, extractDir))
    {
        StartWinDivertServices();
        RestoreZapretStateAfterUpdate(wasZapretRunning, activeStrategyBeforeUpdate);
        RestoreTelegramProxyStateAfterUpdate(wasTelegramProxyRunning);
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        g_updateInProgress = false;
        return;
    }

    fs::path extractedFolder = fs::path(extractDir) / AppConfig::kZapretRepoExtractedFolderName;
    if (fs::exists(extractedFolder))
    {
        CopyDirectoryContents(extractedFolder, fs::path(root));
    }

    try
    {
        fs::remove_all(extractDir);
        fs::remove(zipPath);
    }
    catch (...) {}

    StartWinDivertServices();
    RestoreZapretStateAfterUpdate(wasZapretRunning, activeStrategyBeforeUpdate);
    RestoreTelegramProxyStateAfterUpdate(wasTelegramProxyRunning);

    {
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        g_localVersion = GetLocalVersion();
        g_updateAvailable = false;
        g_updateInProgress = false;
    }
}

static int GetZapretStatus()
{
    // Сначала проверяем наш внутренний процесс
    {
        std::lock_guard<std::mutex> lock(g_processMutex);
        if (g_winwsProcess)
        {
            DWORD exitCode;
            if (GetExitCodeProcess(g_winwsProcess, &exitCode))
            {
                if (exitCode == STILL_ACTIVE)
                {
                    return 0; // Наш процесс работает
                }
                else
                {
                    // Процесс завершился, очищаем handle
                    CloseHandle(g_winwsProcess);
                    g_winwsProcess = nullptr;
                }
            }
        }
    }
    
    // Проверяем, запущен ли процесс winws.exe (запущенный извне)
    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot == INVALID_HANDLE_VALUE)
        return 2; // Ошибка - считаем что не работает
    
    PROCESSENTRY32 pe32;
    pe32.dwSize = sizeof(PROCESSENTRY32);
    
    bool processFound = false;
    if (Process32First(hSnapshot, &pe32))
    {
        do
        {
            if (_wcsicmp(pe32.szExeFile, L"winws.exe") == 0)
            {
                processFound = true;
                break;
            }
        } while (Process32Next(hSnapshot, &pe32));
    }
    
    CloseHandle(hSnapshot);
    
    if (processFound)
    {
        return 0; // Работает
    }
    else
    {
        // Проверяем, установлен ли как служба
        SC_HANDLE hSCManager = OpenSCManager(NULL, NULL, SC_MANAGER_CONNECT);
        if (hSCManager)
        {
            SC_HANDLE hService = OpenService(hSCManager, L"zapret", SERVICE_QUERY_STATUS);
            if (hService)
            {
                SERVICE_STATUS status;
                if (QueryServiceStatus(hService, &status))
                {
                    if (status.dwCurrentState == SERVICE_RUNNING)
                    {
                        CloseServiceHandle(hService);
                        CloseServiceHandle(hSCManager);
                        return 0; // Работает как служба
                    }
                    else if (status.dwCurrentState == SERVICE_START_PENDING)
                    {
                        CloseServiceHandle(hService);
                        CloseServiceHandle(hSCManager);
                        return 1; // Запускается
                    }
                }
                CloseServiceHandle(hService);
            }
            CloseServiceHandle(hSCManager);
        }
        
        return 2; // Не работает
    }
}

static int GetGameFilterStatus()
{
    std::string gameFlagFile = GetZapretRoot() + "\\utils\\game_filter.enabled";
    std::ifstream file(gameFlagFile);
    
    if (!file.is_open())
        return 0; // OFF - файл не существует
    
    std::string mode;
    if (std::getline(file, mode))
    {
        // Убираем лишние символы
        size_t start = mode.find_first_not_of(" \t\r\n");
        if (start != std::string::npos)
        {
            size_t end = mode.find_last_not_of(" \t\r\n");
            mode = mode.substr(start, end - start + 1);
        }
        
        if (mode == "tcp")
            return 1; // TCP
        else if (mode == "udp")
            return 2; // UDP
        else if (mode == "all")
            return 3; // TCP+UDP
    }
    
    return 0; // По умолчанию OFF
}

// ICMP echo к Cloudflare DNS (нейтральный узел); при блокировке ICMP вернёт -1
static int MeasureIcmpPingMs()
{
    HANDLE h = IcmpCreateFile();
    if (h == INVALID_HANDLE_VALUE)
        return -1;

    IPAddr dst = inet_addr("1.1.1.1");
    if (dst == INADDR_NONE)
    {
        IcmpCloseHandle(h);
        return -1;
    }

    char sendData[4] = { 0 };
    unsigned char replyBuf[sizeof(ICMP_ECHO_REPLY) + sizeof(sendData) + 16];
    DWORD timeoutMs = 1200;
    DWORD n = IcmpSendEcho(
        h,
        dst,
        sendData,
        sizeof(sendData),
        nullptr,
        replyBuf,
        static_cast<DWORD>(sizeof(replyBuf)),
        timeoutMs);
    IcmpCloseHandle(h);
    if (n == 0)
        return -1;

    const ICMP_ECHO_REPLY* r = reinterpret_cast<const ICMP_ECHO_REPLY*>(replyBuf);
    if (r->Status != 0)
        return -1;
    return static_cast<int>(r->RoundTripTime);
}

static int CheckServiceStatus(const std::string& service, bool strategyTestMode)
{
    const DWORD kProbeTimeoutMs = strategyTestMode ? 500u : 2500u;
    const int kMaxPasses = 2;

    struct ProbePolicy
    {
        std::vector<std::string> urls;
        int minSuccess = 1;
    };

    auto probeUrl = [](const std::string& testUrl, DWORD timeoutMs) -> bool
    {
        auto extractHost = [](const std::string& url) -> std::string
        {
            size_t p = url.find("://");
            p = (p == std::string::npos) ? 0 : (p + 3);
            size_t e = url.find('/', p);
            return (e == std::string::npos) ? url.substr(p) : url.substr(p, e - p);
        };

        HINTERNET hInternet = InternetOpenA("AntiZapret", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
        if (!hInternet)
            return false;

        InternetSetOptionA(hInternet, INTERNET_OPTION_CONNECT_TIMEOUT, &timeoutMs, sizeof(timeoutMs));
        InternetSetOptionA(hInternet, INTERNET_OPTION_RECEIVE_TIMEOUT, &timeoutMs, sizeof(timeoutMs));
        InternetSetOptionA(hInternet, INTERNET_OPTION_SEND_TIMEOUT, &timeoutMs, sizeof(timeoutMs));

        HINTERNET hUrl = InternetOpenUrlA(
            hInternet,
            testUrl.c_str(),
            NULL,
            0,
            INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_SECURE | INTERNET_FLAG_NO_AUTO_REDIRECT,
            0);

        if (!hUrl)
        {
            InternetCloseHandle(hInternet);
            return false;
        }

        DWORD statusCode = 0;
        DWORD statusLen = sizeof(statusCode);
        const bool hasHttpStatus = HttpQueryInfoA(
            hUrl, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &statusCode, &statusLen, NULL);

        // Для теста доступности сети считаем 4xx "доступно": сервер ответил, значит маршрут/обход работает.
        // Но редирект на чужой host (часто блок-страница провайдера) считаем неуспехом.
        if (hasHttpStatus && statusCode >= 200 && statusCode < 500)
        {
            if (statusCode >= 300 && statusCode < 400)
            {
                char location[512] = {};
                DWORD locationLen = sizeof(location);
                if (HttpQueryInfoA(hUrl, HTTP_QUERY_LOCATION, location, &locationLen, NULL))
                {
                    const std::string expectedHost = extractHost(testUrl);
                    const std::string redirectTarget(location);
                    if (!expectedHost.empty() &&
                        redirectTarget.find(expectedHost) == std::string::npos &&
                        redirectTarget.find('/' + expectedHost) == std::string::npos)
                    {
                        InternetCloseHandle(hUrl);
                        InternetCloseHandle(hInternet);
                        return false;
                    }
                }
            }
            InternetCloseHandle(hUrl);
            InternetCloseHandle(hInternet);
            return true;
        }

        // Fallback: если код не получили, но смогли прочитать хотя бы 1 байт — endpoint доступен.
        char buffer[256];
        DWORD bytesRead = 0;
        bool contentOk = InternetReadFile(hUrl, buffer, sizeof(buffer), &bytesRead) && bytesRead > 0;

        InternetCloseHandle(hUrl);
        InternetCloseHandle(hInternet);
        return contentOk;
    };

    ProbePolicy policy;
    if (service == "discord")
    {
        policy.urls = {
            AppConfig::kDiscordMediaProbeUrl,
            "https://discord.com/api/v9/experiments",
            "https://cdn.discordapp.com"
        };
        policy.minSuccess = 1;
    }
    else if (service == "youtube")
    {
        policy.urls = {
            "https://www.youtube.com/generate_204",
            "https://i.ytimg.com",
            "https://redirector.googlevideo.com"
        };
        policy.minSuccess = 1;
    }
    else if (service == "telegram")
    {
        // Для Telegram проверяем не только shell-домен, но и URL, нужные для контента.
        policy.urls = {
            "https://web.telegram.org",
            "https://telegram.org",
            "https://telegram.org/js/telegram-web-app.js"
        };
        policy.minSuccess = 2;
    }
    else
    {
        return 2;
    }

    std::vector<std::string> toRetry;
    for (int pass = 0; pass < kMaxPasses; ++pass)
    {
        if (strategyTestMode && g_strategyTestStopRequested.load(std::memory_order_relaxed))
            return 1;

        int successCount = 0;
        const std::vector<std::string>& urls = (pass == 0) ? policy.urls : toRetry;
        if (urls.empty())
            break;

        toRetry.clear();
        for (size_t i = 0; i < urls.size(); ++i)
        {
            if (strategyTestMode && g_strategyTestStopRequested.load(std::memory_order_relaxed))
                return 1;

            if (probeUrl(urls[i], kProbeTimeoutMs))
                ++successCount;
            else
                toRetry.push_back(urls[i]);

            if (successCount >= policy.minSuccess)
                return 0;
        }
    }

    return 2;
}

static std::array<int, 3> CheckAllServiceStatusesParallel()
{
    auto discordTask = std::async(std::launch::async, []() { return CheckServiceStatus("discord"); });
    auto youtubeTask = std::async(std::launch::async, []() { return CheckServiceStatus("youtube"); });
    auto telegramTask = std::async(std::launch::async, []() { return CheckServiceStatus("telegram"); });

    return { discordTask.get(), youtubeTask.get(), telegramTask.get() };
}

static std::array<int, 3> CheckAllServiceStatusesParallelForStrategyTest()
{
    auto discordTask = std::async(std::launch::async, []() { return CheckServiceStatus("discord", true); });
    auto youtubeTask = std::async(std::launch::async, []() { return CheckServiceStatus("youtube", true); });
    auto telegramTask = std::async(std::launch::async, []() { return CheckServiceStatus("telegram", true); });

    return { discordTask.get(), youtubeTask.get(), telegramTask.get() };
}

static void CheckAllServicesAsync(const std::string* strategyNameForCircles)
{
    bool expected = false;
    if (!g_servicesCheckInProgress.compare_exchange_strong(expected, true))
        return;
    
    g_discordStatus.store(1);
    g_youtubeStatus.store(1);
    g_telegramStatus.store(1);
    
    const std::array<int, 3> statuses = CheckAllServiceStatusesParallel();
    const int d = statuses[0];
    const int y = statuses[1];
    const int t = statuses[2];
    
    g_discordStatus.store(d);
    g_youtubeStatus.store(y);
    g_telegramStatus.store(t);
    
    if (strategyNameForCircles && !strategyNameForCircles->empty())
    {
        {
            std::lock_guard<std::mutex> lock(g_strategyTestMutex);
            StrategyTestEntry ent;
            auto it = g_strategyTestResults.find(*strategyNameForCircles);
            if (it != g_strategyTestResults.end())
                ent.pingMs = it->second.pingMs;
            ent.ok = { (d == 0), (y == 0), (t == 0) };
            g_strategyTestResults[*strategyNameForCircles] = ent;
        }
        SaveStrategyTestResultsToIni();
    }
    
    g_servicesCheckInProgress.store(false);
}

static fs::path GetLastStrategyPersistPath()
{
    const char* ad = std::getenv("APPDATA");
    if (!ad || ad[0] == '\0')
        return {};
    return fs::path(ad) / "AntiZapret" / "last_strategy.txt";
}

static void SaveLastLaunchedStrategy(const std::string& strategyName)
{
    if (strategyName.empty())
        return;
    const fs::path p = GetLastStrategyPersistPath();
    if (p.empty())
        return;
    try
    {
        fs::create_directories(p.parent_path());
        std::ofstream out(p, std::ios::binary | std::ios::trunc);
        if (out)
            out << strategyName;
    }
    catch (...) {}
}

static std::string LoadLastLaunchedStrategy()
{
    const fs::path p = GetLastStrategyPersistPath();
    if (p.empty() || !fs::exists(p))
        return {};
    std::ifstream in(p);
    std::string s;
    std::getline(in, s);
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n'))
        s.pop_back();
    const size_t a = s.find_first_not_of(" \t");
    if (a == std::string::npos)
        return {};
    const size_t b = s.find_last_not_of(" \t");
    return s.substr(a, b - a + 1);
}

static void LaunchStrategy(const std::string& strategyName, bool scheduleServiceCheck)
{
    // Останавливаем текущий Zapret и ждём завершения процессов
    StopZapret();
    if (g_strategyTestInProgress.load(std::memory_order_relaxed))
    {
        WaitForZapretStoppedInterruptible(2000);
        if (g_strategyTestStopRequested.load(std::memory_order_relaxed))
            return;
    }
    else
        WaitForZapretStopped(2000);

    // В service.bat это включается при установке сервиса; делаем то же при ручном запуске.
    EnsureTcpTimestampsEnabled();

    // В service.bat :load_user_lists создаются эти файлы; без них часть стратегий не стартует.
    EnsureUserListsFiles(GetZapretRoot());

    // После обновления/остановки WinDivert службы могли быть выключены — winws без драйвера не работает.
    StartWinDivertServices();

    std::string root = GetZapretRoot();
    std::string args = BuildArgsForStrategy(strategyName, root);
    if (args.empty())
        return;

    // Запускаем winws.exe напрямую как подпроцесс.
    {
        std::lock_guard<std::mutex> lock(g_processMutex);
        g_winwsProcess = LaunchWinwsProcess(args);
    }
    {
        std::lock_guard<std::mutex> lock(g_processMutex);
        if (!g_winwsProcess)
        {
            std::lock_guard<std::mutex> msgLock(g_runtimeMessageMutex);
            g_lastRuntimeError = "Не удалось запустить winws.exe для выбранной стратегии";
            return;
        }
    }
    {
        std::lock_guard<std::mutex> msgLock(g_runtimeMessageMutex);
        g_lastRuntimeError.clear();
    }

    if (scheduleServiceCheck)
        SaveLastLaunchedStrategy(strategyName);

    if (scheduleServiceCheck)
    {
        std::string name = strategyName;
        std::thread([name]() {
            Sleep(2000);
            CheckAllServicesAsync(&name);
        }).detach();
    }
}

static void TryAutostartLaunchLastStrategy(bool fromAutostart)
{
    if (!fromAutostart)
        return;
    std::thread([]() {
        Sleep(3000);
        const std::string name = LoadLastLaunchedStrategy();
        if (name.empty())
            return;
        const std::vector<std::string> list = ScanStrategies(GetZapretRoot());
        size_t idx = static_cast<size_t>(-1);
        for (size_t i = 0; i < list.size(); ++i)
        {
            if (list[i] == name)
            {
                idx = i;
                break;
            }
        }
        if (idx == (size_t)-1)
            return;
        LaunchStrategy(name);
        g_selectedStrategyIdx.store((int)idx);
        g_activeStrategyIdx.store((int)idx);
    }).detach();
}

static bool IsWinwsRunning()
{
    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32 pe32 = { sizeof(pe32) };
    bool found = false;
    if (Process32First(hSnapshot, &pe32))
    {
        do
        {
            if (_wcsicmp(pe32.szExeFile, L"winws.exe") == 0)
            { found = true; break; }
        } while (Process32Next(hSnapshot, &pe32));
    }
    CloseHandle(hSnapshot);
    return found;
}

static bool IsZapretServiceRunning()
{
    SC_HANDLE hSCManager = OpenSCManager(NULL, NULL, SC_MANAGER_CONNECT);
    if (!hSCManager) return false;
    SC_HANDLE hService = OpenService(hSCManager, L"zapret", SERVICE_QUERY_STATUS);
    if (!hService) { CloseServiceHandle(hSCManager); return false; }
    SERVICE_STATUS status = {};
    bool running = (QueryServiceStatus(hService, &status) &&
        (status.dwCurrentState == SERVICE_RUNNING || status.dwCurrentState == SERVICE_START_PENDING || status.dwCurrentState == SERVICE_STOP_PENDING));
    CloseServiceHandle(hService);
    CloseServiceHandle(hSCManager);
    return running;
}

static void StopWinDivertServices()
{
    SC_HANDLE hSC = OpenSCManager(NULL, NULL, SC_MANAGER_CONNECT);
    if (!hSC) return;
    const wchar_t* names[] = { L"WinDivert", L"WinDivert14" };
    for (const wchar_t* name : names)
    {
        SC_HANDLE hSvc = OpenServiceW(hSC, name, SERVICE_STOP | SERVICE_QUERY_STATUS);
        if (hSvc)
        {
            SERVICE_STATUS st = {};
            ControlService(hSvc, SERVICE_CONTROL_STOP, &st);
            CloseServiceHandle(hSvc);
        }
    }
    CloseServiceHandle(hSC);
}

static void StartWinDivertServices()
{
    SC_HANDLE hSC = OpenSCManager(NULL, NULL, SC_MANAGER_CONNECT);
    if (!hSC) return;
    const wchar_t* names[] = { L"WinDivert", L"WinDivert14" };
    for (const wchar_t* name : names)
    {
        SC_HANDLE hSvc = OpenServiceW(hSC, name, SERVICE_START | SERVICE_QUERY_STATUS);
        if (hSvc)
        {
            StartServiceW(hSvc, 0, NULL);
            CloseServiceHandle(hSvc);
        }
    }
    CloseServiceHandle(hSC);
}

static void WaitForZapretStopped(int maxWaitMs)
{
    const int stepMs = 100;
    for (int elapsed = 0; elapsed < maxWaitMs; elapsed += stepMs)
    {
        if (!IsWinwsRunning() && !IsZapretServiceRunning())
            return;
        Sleep(stepMs);
    }
}

static void StrategyTestInterruptibleSleepMs(int totalMs)
{
    const int slice = 10;
    int elapsed = 0;
    while (elapsed < totalMs)
    {
        if (g_strategyTestStopRequested.load(std::memory_order_relaxed))
            return;
        const int step = (std::min)(slice, totalMs - elapsed);
        Sleep(static_cast<DWORD>(step));
        elapsed += step;
    }
}

static void EnsureTcpTimestampsEnabled()
{
    // Аналог service.bat :tcp_enable.
    const bool alreadyEnabled = CommandSucceeded(
        "cmd.exe /C \"netsh interface tcp show global | findstr /i \\\"timestamps\\\" | findstr /i \\\"enabled\\\"\"",
        "",
        8000);
    if (alreadyEnabled)
        return;

    CommandSucceeded(
        "cmd.exe /C \"netsh interface tcp set global timestamps=enabled\"",
        "",
        12000);
}

static void EnsureUserListsFiles(const std::string& rootDir)
{
    try
    {
        const fs::path lists = fs::path(rootDir) / "lists";
        fs::create_directories(lists);

        const fs::path ipsetUser = lists / "ipset-exclude-user.txt";
        if (!fs::exists(ipsetUser))
        {
            std::ofstream out(ipsetUser, std::ios::binary | std::ios::trunc);
            if (out) out << "203.0.113.113/32";
        }

        const fs::path listGeneralUser = lists / "list-general-user.txt";
        if (!fs::exists(listGeneralUser))
        {
            std::ofstream out(listGeneralUser, std::ios::binary | std::ios::trunc);
            if (out) out << "domain.example.abc";
        }

        const fs::path listExcludeUser = lists / "list-exclude-user.txt";
        if (!fs::exists(listExcludeUser))
        {
            std::ofstream out(listExcludeUser, std::ios::binary | std::ios::trunc);
            if (out) out << "domain.example.abc";
        }
    }
    catch (...) {}
}

static void WaitForZapretStoppedInterruptible(int maxWaitMs)
{
    const int stepMs = 10;
    for (int elapsed = 0; elapsed < maxWaitMs; elapsed += stepMs)
    {
        if (g_strategyTestStopRequested.load(std::memory_order_relaxed))
            return;
        if (!IsWinwsRunning() && !IsZapretServiceRunning())
            return;
        Sleep(static_cast<DWORD>(stepMs));
    }
}

static void StopZapret()
{
    // Останавливаем процесс winws.exe
    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot != INVALID_HANDLE_VALUE)
    {
        PROCESSENTRY32 pe32;
        pe32.dwSize = sizeof(PROCESSENTRY32);
        
        if (Process32First(hSnapshot, &pe32))
        {
            do
            {
                if (_wcsicmp(pe32.szExeFile, L"winws.exe") == 0)
                {
                    HANDLE hProcess = OpenProcess(PROCESS_TERMINATE, FALSE, pe32.th32ProcessID);
                    if (hProcess)
                    {
                        TerminateProcess(hProcess, 0);
                        CloseHandle(hProcess);
                    }
                }
            } while (Process32Next(hSnapshot, &pe32));
        }
        CloseHandle(hSnapshot);
    }
    
    // Останавливаем службу zapret
    SC_HANDLE hSCManager = OpenSCManager(NULL, NULL, SC_MANAGER_CONNECT);
    if (hSCManager)
    {
        SC_HANDLE hService = OpenService(hSCManager, L"zapret", SERVICE_STOP);
        if (hService)
        {
            SERVICE_STATUS status;
            ControlService(hService, SERVICE_CONTROL_STOP, &status);
            CloseServiceHandle(hService);
        }
        CloseServiceHandle(hSCManager);
    }
    
    // Сбрасываем выделение стратегии (зелёный цвет)
    g_selectedStrategyIdx.store(-1);
    g_activeStrategyIdx.store(-1);

    // Закрываем наш внутренний процесс winws если он запущен
    {
        std::lock_guard<std::mutex> lock(g_processMutex);
        if (g_winwsProcess)
        {
            TerminateProcess(g_winwsProcess, 0);
            CloseHandle(g_winwsProcess);
            g_winwsProcess = nullptr;
        }
    }
}

static void RunStrategyTest(int startIndex)
{
    g_strategyTestInProgress.store(true);
    g_strategyTestStopRequested.store(false, std::memory_order_release);

    std::string root = GetZapretRoot();
    std::vector<std::string> strategies = ScanStrategies(root);
    if (strategies.empty())
    {
        g_strategyTestInProgress.store(false);
        return;
    }
    { std::lock_guard<std::mutex> lock(g_strategyTestMutex); g_strategyTestTotal = (int)strategies.size(); }

    std::string activeStrategyName;
    if (startIndex == 0)
    {
        const int activeIdx = g_activeStrategyIdx.load();
        if (activeIdx >= 0 && activeIdx < (int)strategies.size())
            activeStrategyName = strategies[activeIdx];
        { std::lock_guard<std::mutex> lock(g_strategyTestMutex); g_strategyTestRestoreStrategy = activeStrategyName; }
        StopZapret();
        WaitForZapretStoppedInterruptible(5000);
    }
    else
    {
        { std::lock_guard<std::mutex> lock(g_strategyTestMutex); activeStrategyName = g_strategyTestRestoreStrategy; }
        StopZapret();
        WaitForZapretStoppedInterruptible(5000);
    }

    int resumeFrom = startIndex;
    for (int idx = startIndex; idx < (int)strategies.size(); ++idx)
    {
        if (g_strategyTestStopRequested.load(std::memory_order_acquire))
        {
            resumeFrom = idx;
            break;
        }

        const std::string& strategy = strategies[idx];
        { std::lock_guard<std::mutex> lock(g_strategyTestMutex); g_strategyTestCurrent = strategy; g_strategyTestCurrentIdx = idx + 1; }
        g_discordStatus.store(1);
        g_youtubeStatus.store(1);
        g_telegramStatus.store(1);
        LaunchStrategy(strategy, false);
        if (g_strategyTestStopRequested.load(std::memory_order_relaxed))
        {
            StopZapret();
            WaitForZapretStoppedInterruptible(5000);
            resumeFrom = idx + 1;
            break;
        }

        StrategyTestInterruptibleSleepMs(2000);

        if (g_strategyTestStopRequested.load(std::memory_order_relaxed))
        {
            StopZapret();
            WaitForZapretStoppedInterruptible(5000);
            resumeFrom = idx + 1;
            break;
        }

        int pingMs = -1;
        if (!g_strategyTestStopRequested.load(std::memory_order_relaxed))
            pingMs = MeasureIcmpPingMs();

        const std::array<int, 3> statuses = CheckAllServiceStatusesParallelForStrategyTest();

        if (g_strategyTestStopRequested.load(std::memory_order_relaxed))
        {
            StopZapret();
            WaitForZapretStoppedInterruptible(5000);
            resumeFrom = idx + 1;
            break;
        }

        const int d = statuses[0];
        const int y = statuses[1];
        const int t = statuses[2];

        g_discordStatus.store(d);
        g_youtubeStatus.store(y);
        g_telegramStatus.store(t);

        {
            std::lock_guard<std::mutex> lock(g_strategyTestMutex);
            StrategyTestEntry ent;
            ent.ok = { (d == 0), (y == 0), (t == 0) };
            ent.pingMs = pingMs;
            g_strategyTestResults[strategy] = ent;
        }
        SaveStrategyTestResultsToIni();

        StopZapret();
        WaitForZapretStoppedInterruptible(5000);
        resumeFrom = idx + 1;
    }

    bool wasStopped = false;
    wasStopped = g_strategyTestStopRequested.load(std::memory_order_acquire);
    bool allDone = (resumeFrom >= (int)strategies.size());
    UpdateBestStrategyFromResults();
    if (wasStopped && !allDone)
    {
        { std::lock_guard<std::mutex> lock(g_strategyTestMutex); g_strategyTestCurrent.clear(); g_strategyTestPaused = true; g_strategyTestResumeFromIndex = resumeFrom; }
        g_strategyTestInProgress.store(false);
        if (!activeStrategyName.empty())
        {
            LaunchStrategy(activeStrategyName);
            for (size_t i = 0; i < strategies.size(); ++i)
            {
                if (strategies[i] == activeStrategyName)
                {
                    g_selectedStrategyIdx.store((int)i);
                    g_activeStrategyIdx.store((int)i);
                    break;
                }
            }
        }
        return;
    }

    { std::lock_guard<std::mutex> lock(g_strategyTestMutex); g_strategyTestCurrent.clear(); g_strategyTestPaused = false; g_strategyTestResumeFromIndex = 0; }
    g_strategyTestInProgress.store(false);

    if (!activeStrategyName.empty())
    {
        LaunchStrategy(activeStrategyName);
        for (size_t i = 0; i < strategies.size(); ++i)
        {
            if (strategies[i] == activeStrategyName)
            {
                g_selectedStrategyIdx.store((int)i);
                g_activeStrategyIdx.store((int)i);
                break;
            }
        }
    }
}

static void ResolveGameFilterRanges(std::string& gameFilterTCP, std::string& gameFilterUDP)
{
    int gameFilterStatus = GetGameFilterStatus();
    if (gameFilterStatus == 1) // TCP
    {
        gameFilterTCP = "1024-65535";
        gameFilterUDP = "12";
    }
    else if (gameFilterStatus == 2) // UDP
    {
        gameFilterTCP = "12";
        gameFilterUDP = "1024-65535";
    }
    else if (gameFilterStatus == 3) // TCP+UDP
    {
        gameFilterTCP = "1024-65535";
        gameFilterUDP = "1024-65535";
    }
    else // OFF
    {
        gameFilterTCP = "12";
        gameFilterUDP = "12";
    }
}

static void ReplaceAll(std::string& target, const char* needle, const std::string& replacement)
{
    size_t pos = 0;
    const size_t needleLen = strlen(needle);
    while ((pos = target.find(needle, pos)) != std::string::npos)
    {
        target.replace(pos, needleLen, replacement);
        pos += replacement.size();
    }
}

static std::string BuildArgsForStrategy(const std::string& strategyName, const std::string& rootDir)
{
    const fs::path batPath = fs::path(rootDir) / (strategyName + ".bat");
    if (!fs::exists(batPath))
        return "";

    std::string gameFilterTCP;
    std::string gameFilterUDP;
    ResolveGameFilterRanges(gameFilterTCP, gameFilterUDP);

    const std::string binPath = rootDir + "\\bin\\";
    const std::string listsPath = rootDir + "\\lists\\";
    // Сырая строка аргументов из .bat (порядок как в файле), без пересборки через map.
    std::string args = StrategyParser::BuildExpandedArgsFromBat(
        batPath.string(), binPath, listsPath, gameFilterTCP, gameFilterUDP);
    if (args.empty())
        return "";

    // В .bat для cmd экранируют "!"; при прямом запуске winws нужен обычный "!".
    ReplaceAll(args, "^!", "!");

    return args;
}

static HANDLE LaunchWinwsProcess(const std::string& args)
{
    std::string root = GetZapretRoot();
    std::string winwsPath = root + "\\bin\\winws.exe";
    std::string commandLine = "\"" + winwsPath + "\" " + args;
    
    STARTUPINFOA si = { 0 };
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE; // Скрытый запуск
    
    PROCESS_INFORMATION pi = { 0 };
    
    // Создаем процесс
    if (CreateProcessA(
        winwsPath.c_str(),           // Путь к exe
        (char*)commandLine.c_str(),  // Командная строка
        nullptr,                     // Security attributes процесса
        nullptr,                     // Security attributes потока
        FALSE,                       // Наследование handles
        CREATE_NO_WINDOW,           // Флаги создания (без окна)
        nullptr,                     // Переменные окружения
        root.c_str(),               // Рабочая директория
        &si,                        // STARTUPINFO
        &pi                         // PROCESS_INFORMATION
    ))
    {
        // Закрываем handle потока, он нам не нужен
        CloseHandle(pi.hThread);
        
        // Возвращаем handle процесса
        return pi.hProcess;
    }
    
    return nullptr;
}

static bool IsTelegramWsProxyRunning()
{
    std::lock_guard<std::mutex> lock(g_tgWsProxyMutex);
    if (!g_tgWsProxyProcess)
        return false;

    DWORD exitCode = 0;
    if (!GetExitCodeProcess(g_tgWsProxyProcess, &exitCode))
    {
        CloseHandle(g_tgWsProxyProcess);
        g_tgWsProxyProcess = nullptr;
        return false;
    }

    if (exitCode == STILL_ACTIVE)
        return true;

    CloseHandle(g_tgWsProxyProcess);
    g_tgWsProxyProcess = nullptr;
    return false;
}

static bool LooksLikeTelegramProxyRoot(const fs::path& root)
{
    return IsValidTelegramProxyRoot(root);
}

static fs::path ResolveTelegramWsProxyRoot()
{
    const fs::path unifiedRoot = GetUnifiedTelegramProxyRootPath();
    if (LooksLikeTelegramProxyRoot(unifiedRoot))
        return unifiedRoot;

    std::vector<fs::path> bases;

    const fs::path zapretRoot = fs::path(GetZapretRoot());
    if (!zapretRoot.empty())
        bases.push_back(zapretRoot);

    char modulePath[MAX_PATH] = {};
    if (GetModuleFileNameA(nullptr, modulePath, MAX_PATH) > 0)
        bases.push_back(fs::path(modulePath).parent_path());

    try { bases.push_back(fs::current_path()); } catch (...) {}

    const char* userProfile = std::getenv("USERPROFILE");
    if (userProfile && userProfile[0] != '\0')
    {
        const fs::path userRoot(userProfile);
        bases.push_back(userRoot);
        bases.push_back(userRoot / "Documents");
        bases.push_back(userRoot / "Dokumente");
    }
    const char* oneDrive = std::getenv("OneDrive");
    if (oneDrive && oneDrive[0] != '\0')
    {
        const fs::path oneDriveRoot(oneDrive);
        bases.push_back(oneDriveRoot);
        bases.push_back(oneDriveRoot / "Documents");
        bases.push_back(oneDriveRoot / "Dokumente");
    }

    for (const fs::path& base : bases)
    {
        fs::path cur = base;
        for (int depth = 0; depth < 6 && !cur.empty(); ++depth)
        {
            const fs::path candidateMain = cur / "tg-ws-proxy-main";
            if (LooksLikeTelegramProxyRoot(candidateMain))
                return candidateMain;
            const fs::path candidateDir = cur / "tg-ws-proxy";
            if (LooksLikeTelegramProxyRoot(candidateDir))
                return candidateDir;
            const fs::path parent = cur.parent_path();
            if (parent == cur)
                break;
            cur = parent;
        }
    }

    if (EnsureUnifiedDirectory(unifiedRoot))
        return unifiedRoot;

    return fs::path();
}

static std::vector<std::string> GetPythonLaunchersForProxy()
{
    std::vector<std::string> launchers;
    {
        std::lock_guard<std::mutex> lock(g_tgPythonMutex);
        if (!g_tgPythonLauncher.empty())
            launchers.push_back(g_tgPythonLauncher);
    }

    const std::vector<std::string> defaults = { "py -3", "py", "python", "python3" };
    for (const std::string& value : defaults)
    {
        if (std::find(launchers.begin(), launchers.end(), value) == launchers.end())
            launchers.push_back(value);
    }
    return launchers;
}

static bool DetectPythonLauncher(const std::string& workDir, std::string& outLauncher)
{
    for (const std::string& launcher : GetPythonLaunchersForProxy())
    {
        // Кавычки нужны для лаунчеров вроде "py -3", иначе cmd обрезает аргументы после /C.
        const std::string cmd = "cmd.exe /C \"" + launcher + " --version\"";
        if (CommandSucceeded(cmd, workDir, 15000))
        {
            outLauncher = launcher;
            return true;
        }
    }
    outLauncher.clear();
    return false;
}

static bool EnsurePipAvailable(const std::string& launcher, const std::string& workDir)
{
    if (CommandSucceeded("cmd.exe /C \"" + launcher + " -m pip --version\"", workDir, 30000))
        return true;

    // Универсальный fallback для сред, где pip не установлен, но есть Python.
    CommandSucceeded("cmd.exe /C \"" + launcher + " -m ensurepip --upgrade\"", workDir, 120000);
    return CommandSucceeded("cmd.exe /C \"" + launcher + " -m pip --version\"", workDir, 30000);
}

static bool InstallTelegramProxyDependencies(
    const fs::path& tgProxyRoot,
    const std::string& launcher,
    std::string& outError)
{
    const fs::path requirementsPath = tgProxyRoot / "requirements.txt";
    const fs::path pyprojectPath = tgProxyRoot / "pyproject.toml";
    const std::string workDir = tgProxyRoot.string();

    auto runPipInstall = [&](const std::string& args, DWORD timeoutMs) -> bool
    {
        // args уже содержит свои кавычки для путей — не оборачиваем всю строку в одни кавычки.
        const std::string cmd = "cmd.exe /C " + launcher + " -m pip install --disable-pip-version-check --no-input " + args;
        if (CommandSucceeded(cmd, workDir, timeoutMs))
            return true;
        const std::string retry = "cmd.exe /C " + launcher + " -m pip install --disable-pip-version-check " + args;
        return CommandSucceeded(retry, workDir, timeoutMs);
    };

    if (fs::exists(requirementsPath))
    {
        // Без --upgrade: ставит только отсутствующее, не тянет обновления каждый раз.
        const std::string args = "-r \"" + requirementsPath.string() + "\"";
        if (!runPipInstall(args, 300000))
        {
            outError = "Не удалось установить зависимости из requirements.txt.";
            return false;
        }
        return true;
    }

    if (fs::exists(pyprojectPath))
    {
        // Как в официальном README: pip install -e . (консольный proxy, без extras win10).
        const std::string args = "-e .";
        if (!runPipInstall(args, 300000))
        {
            outError = "Не удалось установить пакет из pyproject.toml.";
            return false;
        }
        return true;
    }

    // Если метафайлов нет, считаем что дополнительных действий не требуется.
    return true;
}

static std::string FileSignatureForDepsMarker(const fs::path& p)
{
    std::error_code ec;
    if (!fs::is_regular_file(p, ec))
        return "0";
    const uintmax_t sz = fs::file_size(p, ec);
    if (ec)
        return "0";
    const auto ft = fs::last_write_time(p, ec);
    if (ec)
        return "0";
    const auto ticks = ft.time_since_epoch().count();
    return std::to_string(static_cast<unsigned long long>(sz)) + ":" +
        std::to_string(static_cast<long long>(ticks));
}

static bool TgProxyDepsMarkerMatches(const fs::path& root)
{
    const fs::path marker = root / ".antizapret_tg_deps";
    std::ifstream in(marker, std::ios::binary);
    if (!in)
        return false;
    std::string oldReq;
    std::string oldPyp;
    std::getline(in, oldReq);
    std::getline(in, oldPyp);
    return oldReq == FileSignatureForDepsMarker(root / "requirements.txt") &&
        oldPyp == FileSignatureForDepsMarker(root / "pyproject.toml");
}

static void WriteTgProxyDepsMarker(const fs::path& root)
{
    std::ofstream out(root / ".antizapret_tg_deps", std::ios::binary);
    if (!out)
        return;
    out << FileSignatureForDepsMarker(root / "requirements.txt") << "\n"
        << FileSignatureForDepsMarker(root / "pyproject.toml");
}

static void OpenPythonManagerInstallerMsix()
{
    ShellExecuteA(nullptr, "open", AppConfig::kPythonManagerMsixUrl, nullptr, nullptr, SW_SHOWNORMAL);
}

static bool StartTelegramWsProxy()
{
    if (IsTelegramWsProxyRunning())
        return true;

    const fs::path tgProxyRoot = ResolveTelegramWsProxyRoot();
    const fs::path proxyExePath = tgProxyRoot / "TgWsProxy_windows.exe";
    const fs::path proxyScriptPath = tgProxyRoot / "proxy" / "tg_ws_proxy.py";

    // Для консольного Python/cmd — без окна. TgWsProxy_windows.exe — GUI/tray: CREATE_NO_WINDOW часто даёт
    // мгновенный выход или сбой, поэтому запускаем его с обычными флагами и без SW_HIDE.
    STARTUPINFOA siHidden = {};
    siHidden.cb = sizeof(siHidden);
    siHidden.dwFlags = STARTF_USESHOWWINDOW;
    siHidden.wShowWindow = SW_HIDE;

    STARTUPINFOA siGui = {};
    siGui.cb = sizeof(siGui);

    std::string workDir = tgProxyRoot.string();

    const auto tryLaunch = [&](const char* applicationName, char* cmdLineWritable, DWORD creationFlags, STARTUPINFOA& siRef) -> HANDLE
    {
        PROCESS_INFORMATION localPi = {};
        const bool ok = CreateProcessA(
            applicationName,
            cmdLineWritable,
            nullptr,
            nullptr,
            FALSE,
            creationFlags,
            nullptr,
            workDir.empty() ? nullptr : workDir.c_str(),
            &siRef,
            &localPi) == TRUE;
        if (!ok)
            return nullptr;

        CloseHandle(localPi.hThread);
        Sleep(800);

        DWORD exitCode = 0;
        if (!GetExitCodeProcess(localPi.hProcess, &exitCode) || exitCode != STILL_ACTIVE)
        {
            CloseHandle(localPi.hProcess);
            return nullptr;
        }

        return localPi.hProcess;
    };

    HANDLE launched = nullptr;
    std::string usedLauncher;

    if (fs::exists(proxyExePath))
    {
        std::string cmdLine = "\"" + proxyExePath.string() + "\"";
        std::vector<char> cmdBuf(cmdLine.begin(), cmdLine.end());
        cmdBuf.push_back('\0');
        launched = tryLaunch(nullptr, cmdBuf.data(), 0, siGui);
    }

    // Запасной путь: консольный Python (если exe нет, битый, удаляется антивирусом или сразу падает).
    if (!launched && fs::exists(proxyScriptPath))
    {
        char sysDir[MAX_PATH];
        if (GetSystemDirectoryA(sysDir, MAX_PATH) == 0)
        {
            std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
            g_lastRuntimeError = "Не удалось получить системный каталог (GetSystemDirectory).";
            return false;
        }

        for (const std::string& launcher : GetPythonLaunchersForProxy())
        {
            const std::string innerCmd = launcher + " -m proxy.tg_ws_proxy --host " + kTgWsProxyListenHost +
                " --port " + std::to_string(kTgWsProxyListenPort);
            std::string fullCmd = std::string("\"") + sysDir + "\\cmd.exe\" /C \"" + innerCmd + "\"";
            std::vector<char> cmdBuf(fullCmd.begin(), fullCmd.end());
            cmdBuf.push_back('\0');
            launched = tryLaunch(nullptr, cmdBuf.data(), CREATE_NO_WINDOW, siHidden);
            if (launched)
            {
                usedLauncher = launcher;
                break;
            }
        }
    }

    if (!launched)
    {
        std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
        if (!fs::exists(proxyScriptPath) && !fs::exists(proxyExePath))
            g_lastRuntimeError = "tg-ws-proxy не найден. Положи папку tg-ws-proxy / tg-ws-proxy-main рядом с zapret или запусти TG Fix.";
        else
            g_lastRuntimeError = "Не удалось запустить tg-ws-proxy (Python/pip из TG Fix, либо рабочий TgWsProxy_windows.exe).";
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(g_tgWsProxyMutex);
        if (g_tgWsProxyProcess)
        {
            const DWORD oldPid = GetProcessId(g_tgWsProxyProcess);
            CloseHandle(g_tgWsProxyProcess);
            g_tgWsProxyProcess = nullptr;
            if (oldPid != 0)
                KillProcessTreeByRootPid(oldPid);
        }
        g_tgWsProxyProcess = launched;
    }
    if (!usedLauncher.empty())
    {
        std::lock_guard<std::mutex> lock(g_tgPythonMutex);
        g_tgPythonLauncher = usedLauncher;
    }
    return true;
}

static void CollectProcessSubtreePostOrder(
    DWORD pid,
    const std::map<DWORD, std::vector<DWORD>>& byParent,
    std::vector<DWORD>& out)
{
    auto it = byParent.find(pid);
    if (it != byParent.end())
    {
        for (DWORD child : it->second)
            CollectProcessSubtreePostOrder(child, byParent, out);
    }
    out.push_back(pid);
}

// Завершает процесс rootPid и всех потомков (нужно, когда прокси запущен через cmd.exe → python).
static void KillProcessTreeByRootPid(DWORD rootPid)
{
    if (rootPid == 0)
        return;

    std::vector<std::pair<DWORD, DWORD>> procs;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return;

    PROCESSENTRY32 pe = {};
    pe.dwSize = sizeof(PROCESSENTRY32);
    if (Process32First(snap, &pe))
    {
        do
        {
            procs.push_back({ pe.th32ProcessID, pe.th32ParentProcessID });
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);

    std::map<DWORD, std::vector<DWORD>> byParent;
    for (const auto& pr : procs)
        byParent[pr.second].push_back(pr.first);

    std::vector<DWORD> postOrder;
    CollectProcessSubtreePostOrder(rootPid, byParent, postOrder);

    for (DWORD pid : postOrder)
    {
        HANDLE h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid);
        if (!h)
            continue;
        TerminateProcess(h, 0);
        WaitForSingleObject(h, 2000);
        CloseHandle(h);
    }
}

// На случай потерянного handle или отдельного запуска TgWsProxy_windows.exe.
static void KillProcessesNamedNoCase(const char* exeBaseName)
{
    wchar_t wname[MAX_PATH];
    if (MultiByteToWideChar(CP_ACP, 0, exeBaseName, -1, wname, MAX_PATH) <= 0)
        return;

    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE)
        return;

    PROCESSENTRY32 pe = {};
    pe.dwSize = sizeof(PROCESSENTRY32);
    if (Process32First(snap, &pe))
    {
        do
        {
            if (_wcsicmp(pe.szExeFile, wname) == 0)
            {
                HANDLE h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pe.th32ProcessID);
                if (h)
                {
                    TerminateProcess(h, 0);
                    WaitForSingleObject(h, 1500);
                    CloseHandle(h);
                }
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
}

static void StopTelegramWsProxy()
{
    DWORD pid = 0;
    {
        std::lock_guard<std::mutex> lock(g_tgWsProxyMutex);
        if (!g_tgWsProxyProcess)
            return;
        pid = GetProcessId(g_tgWsProxyProcess);
        CloseHandle(g_tgWsProxyProcess);
        g_tgWsProxyProcess = nullptr;
    }

    if (pid != 0)
    {
        KillProcessTreeByRootPid(pid);
        ClearTgFixStatusStrip();
    }
}

static void ShutdownAllTelegramWsProxyProcesses()
{
    StopTelegramWsProxy();
    KillProcessesNamedNoCase("TgWsProxy_windows.exe");
    ClearTgFixStatusStrip();
}

static bool RunHiddenCommand(const std::string& commandLine, const std::string& workDir, DWORD timeoutMs, DWORD* outExitCode)
{
    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};

    std::vector<char> cmdBuf(commandLine.begin(), commandLine.end());
    cmdBuf.push_back('\0');

    BOOL created = CreateProcessA(
        nullptr,
        cmdBuf.data(),
        nullptr,
        nullptr,
        FALSE,
        CREATE_NO_WINDOW,
        nullptr,
        workDir.empty() ? nullptr : workDir.c_str(),
        &si,
        &pi);

    if (!created)
        return false;

    DWORD waitRes = WaitForSingleObject(pi.hProcess, timeoutMs);
    DWORD exitCode = 1;
    if (waitRes == WAIT_TIMEOUT)
    {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 2000);
    }
    GetExitCodeProcess(pi.hProcess, &exitCode);

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    if (outExitCode)
        *outExitCode = exitCode;
    return waitRes != WAIT_FAILED;
}

static bool CommandSucceeded(const std::string& commandLine, const std::string& workDir, DWORD timeoutMs)
{
    DWORD exitCode = 1;
    if (!RunHiddenCommand(commandLine, workDir, timeoutMs, &exitCode))
        return false;
    return exitCode == 0;
}

static std::string BuildTelegramDesktopSocksDeepLink()
{
    // Формат как в tg-ws-proxy windows.py: tg://socks?server=127.0.0.1&port=1080
    return std::string("tg://socks?server=") + kTgWsProxyListenHost + "&port=" + std::to_string(kTgWsProxyListenPort);
}

static bool CopyStringToWindowsClipboardUtf8(const std::string& utf8)
{
    if (utf8.empty())
        return false;
    if (!OpenClipboard(nullptr))
        return false;
    EmptyClipboard();

    const int wchars = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (wchars <= 0)
    {
        CloseClipboard();
        return false;
    }

    const SIZE_T byteCount = static_cast<SIZE_T>(wchars) * sizeof(WCHAR);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, byteCount);
    if (!hMem)
    {
        CloseClipboard();
        return false;
    }

    LPWSTR dst = static_cast<LPWSTR>(GlobalLock(hMem));
    if (!dst)
    {
        GlobalFree(hMem);
        CloseClipboard();
        return false;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, dst, wchars);
    GlobalUnlock(hMem);

    if (!SetClipboardData(CF_UNICODETEXT, hMem))
    {
        GlobalFree(hMem);
        CloseClipboard();
        return false;
    }
    CloseClipboard();
    return true;
}

static void SetTgFixMessage(const std::string& message)
{
    std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
    g_tgFixSetupMessage = message;
}

// Убираем строку «прокси запущен» и лишнюю высоту блока после TG Off / Стоп.
static void ClearTgFixStatusStrip()
{
    std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
    g_tgFixSetupMessage.clear();
    g_tgFixSetupCompleted = false;
    g_tgFixSetupSuccess = false;
}

static void RunTgFixSetupAndLaunch()
{
    g_tgFixSetupInProgress.store(true);
    {
        std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
        g_tgFixSetupCompleted = false;
        g_tgFixSetupSuccess = false;
        g_tgFixSetupMessage = "Проверка окружения...";
    }

    const fs::path tgProxyRoot = ResolveTelegramWsProxyRoot();
    const fs::path proxyExePath = tgProxyRoot / "TgWsProxy_windows.exe";
    const fs::path proxyScriptPath = tgProxyRoot / "proxy" / "tg_ws_proxy.py";

    if (!fs::exists(proxyExePath) && !fs::exists(proxyScriptPath))
    {
        SetTgFixMessage("tg-ws-proxy не найден, разворачиваю в общий каталог...");
        const bool deployed = DeployRepositoryArchiveIfMissing(
            AppConfig::kTelegramProxyArchiveUrl,
            AppConfig::kTelegramRepoExtractedFolderName,
            GetUnifiedTelegramProxyRootPath(),
            GetUnifiedTelegramProxyRootPath() / "proxy" / "tg_ws_proxy.py");
        if (!deployed)
        {
            SetTgFixMessage("Не удалось развернуть tg-ws-proxy в C:\\Program Files (x86)\\AntiZapret.");
            {
                std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
                g_lastRuntimeError = "Не удалось скачать/распаковать tg-ws-proxy (нужны права и интернет).";
            }
            std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
            g_tgFixSetupCompleted = true;
            g_tgFixSetupSuccess = false;
            g_tgFixSetupInProgress.store(false);
            return;
        }
    }

    const fs::path finalTgProxyRoot = ResolveTelegramWsProxyRoot();
    const fs::path finalProxyExePath = finalTgProxyRoot / "TgWsProxy_windows.exe";
    const fs::path finalProxyScriptPath = finalTgProxyRoot / "proxy" / "tg_ws_proxy.py";
    if (!fs::exists(finalProxyExePath) && !fs::exists(finalProxyScriptPath))
    {
        SetTgFixMessage("Не найдены файлы tg-ws-proxy после развёртывания (ожидались exe и/или proxy\\tg_ws_proxy.py).");
        {
            std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
            g_lastRuntimeError = "tg-ws-proxy не найден в общем каталоге.";
        }
        std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
        g_tgFixSetupCompleted = true;
        g_tgFixSetupSuccess = false;
        g_tgFixSetupInProgress.store(false);
        return;
    }

    // Если в репозитории есть Python-часть — pip/зависимости при необходимости (маркер .antizapret_tg_deps при успехе).
    if (fs::exists(finalProxyScriptPath))
    {
        SetTgFixMessage("Поиск Python...");
        std::string launcher;
        if (!DetectPythonLauncher(finalTgProxyRoot.string(), launcher))
        {
            OpenPythonManagerInstallerMsix();
            SetTgFixMessage("Python не найден. Открываю установщик Python Manager (MSIX). После установки повтори TG Fix.");
            {
                std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
                g_lastRuntimeError =
                    std::string("Python 3 не найден. Открыта ссылка на установщик: ") +
                    AppConfig::kPythonManagerMsixUrl;
            }
            std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
            g_tgFixSetupCompleted = true;
            g_tgFixSetupSuccess = false;
            g_tgFixSetupInProgress.store(false);
            return;
        }
        {
            std::lock_guard<std::mutex> lock(g_tgPythonMutex);
            g_tgPythonLauncher = launcher;
        }

        SetTgFixMessage("Проверка pip...");
        if (!EnsurePipAvailable(launcher, finalTgProxyRoot.string()))
        {
            SetTgFixMessage("pip недоступен. Установи pip для Python и повтори TG Fix.");
            {
                std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
                g_lastRuntimeError = "pip недоступен для установки пакетов tg-ws-proxy.";
            }
            std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
            g_tgFixSetupCompleted = true;
            g_tgFixSetupSuccess = false;
            g_tgFixSetupInProgress.store(false);
            return;
        }

        if (TgProxyDepsMarkerMatches(finalTgProxyRoot))
        {
            SetTgFixMessage("Зависимости уже установлены (requirements/pyproject без изменений), запускаю TG proxy...");
        }
        else
        {
            SetTgFixMessage("Устанавливаю недостающие зависимости tg-ws-proxy...");
            std::string installError;
            if (!InstallTelegramProxyDependencies(finalTgProxyRoot, launcher, installError))
            {
                SetTgFixMessage(installError.empty() ? "Не удалось установить зависимости." : installError);
                {
                    std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
                    g_lastRuntimeError = installError.empty() ? "Ошибка установки зависимостей tg-ws-proxy." : installError;
                }
                std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
                g_tgFixSetupCompleted = true;
                g_tgFixSetupSuccess = false;
                g_tgFixSetupInProgress.store(false);
                return;
            }
            WriteTgProxyDepsMarker(finalTgProxyRoot);
        }
    }

    SetTgFixMessage("Запускаю TG proxy...");
    const bool started = StartTelegramWsProxy();
    if (started)
    {
        std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
        g_lastRuntimeError.clear();
    }
    std::string successMsg;
    if (started)
    {
        const std::string tgUrl = BuildTelegramDesktopSocksDeepLink();
        const bool copied = CopyStringToWindowsClipboardUtf8(tgUrl);
        if (copied)
        {
            successMsg =
                "Shadowsocks запущен. Прокси скопирована в буфер обмена: вставь в чат Telegram и "
                "открой её, либо вручную SOCKS5 " +
                std::string(kTgWsProxyListenHost) + ":" + std::to_string(kTgWsProxyListenPort) + ".";
        }
        else
        {
            successMsg = "Shadowsocks запущен. Не удалось скопировать прокси в буфер обмена. Вручную: SOCKS5 " +
                std::string(kTgWsProxyListenHost) + ":" + std::to_string(kTgWsProxyListenPort) + " или открой: " + tgUrl;
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
        g_tgFixSetupCompleted = true;
        g_tgFixSetupSuccess = started;
        g_tgFixSetupMessage = started ? successMsg : "Не удалось запустить TG proxy (см. сообщение об ошибке).";
    }
    g_tgFixSetupInProgress.store(false);
}

static bool IsUpdateCheckEnabled()
{
    std::string updateFlagPath = GetZapretRoot() + "\\utils\\check_updates.enabled";
    std::ifstream file(updateFlagPath);
    return file.good(); // Если файл существует, то проверка обновлений включена
}

static constexpr const wchar_t* kAutostartRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static constexpr const wchar_t* kAutostartValueName = L"AntiZapret";
static constexpr const char* kAutostartTaskNameA = "AntiZapret_Autostart";

static std::wstring BuildAutostartCommandLineW()
{
    wchar_t path[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH)
        return {};
    return std::wstring(L"\"") + path + L"\" --autostart";
}

static std::string GetCurrentExePathA()
{
    char path[MAX_PATH];
    const DWORD n = GetModuleFileNameA(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH)
        return {};
    return std::string(path);
}

static bool IsAutostartTaskEnabled()
{
    const std::string cmd =
        std::string("cmd /c schtasks /Query /TN \"") + kAutostartTaskNameA + "\"";
    return CommandSucceeded(cmd, "", 8000);
}

static bool SetAutostartTaskEnabled(bool enable)
{
    if (enable)
    {
        const std::string exePath = GetCurrentExePathA();
        if (exePath.empty())
            return false;
        // /TR должен содержать путь в кавычках; экранирование нужно для передачи через cmd /c.
        const std::string trArg = std::string("\\\"") + exePath + "\\\" --autostart";
        const std::string cmd =
            std::string("cmd /c schtasks /Create /F /SC ONLOGON /TN \"") +
            kAutostartTaskNameA + "\" /TR \"" + trArg + "\" /RL HIGHEST";
        return CommandSucceeded(cmd, "", 12000);
    }
    const std::string cmd =
        std::string("cmd /c schtasks /Delete /F /TN \"") + kAutostartTaskNameA + "\"";
    DWORD exitCode = 1;
    if (!RunHiddenCommand(cmd, "", 8000, &exitCode))
        return false;
    return exitCode == 0 || exitCode == 1;
}

static bool IsAutostartEnabled()
{
    if (IsAutostartTaskEnabled())
        return true;

    HKEY hKey = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kAutostartRunKey, 0, KEY_READ, &hKey) != ERROR_SUCCESS)
        return false;

    wchar_t buf[1024];
    DWORD size = sizeof(buf);
    DWORD type = 0;
    const LONG err = RegQueryValueExW(hKey, kAutostartValueName, nullptr, &type, reinterpret_cast<BYTE*>(buf), &size);
    RegCloseKey(hKey);
    if (err != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ))
        return false;

    const std::wstring got(buf);
    const std::wstring want = BuildAutostartCommandLineW();
    if (want.empty())
        return false;
    return _wcsicmp(got.c_str(), want.c_str()) == 0;
}

static bool SetAutostartEnabled(bool enable)
{
    if (enable)
    {
        if (SetAutostartTaskEnabled(true))
        {
            // Очищаем legacy Run-запись, чтобы не дублировать автозапуск.
            HKEY hKey = nullptr;
            if (RegOpenKeyExW(HKEY_CURRENT_USER, kAutostartRunKey, 0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS)
            {
                RegDeleteValueW(hKey, kAutostartValueName);
                RegCloseKey(hKey);
            }
            return true;
        }

        const std::wstring cmd = BuildAutostartCommandLineW();
        if (cmd.empty())
            return false;
        HKEY hKey = nullptr;
        if (RegCreateKeyExW(
                HKEY_CURRENT_USER,
                kAutostartRunKey,
                0,
                nullptr,
                0,
                KEY_SET_VALUE,
                nullptr,
                &hKey,
                nullptr) != ERROR_SUCCESS)
            return false;
        const LONG err = RegSetValueExW(
            hKey,
            kAutostartValueName,
            0,
            REG_SZ,
            reinterpret_cast<const BYTE*>(cmd.c_str()),
            static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
        RegCloseKey(hKey);
        return err == ERROR_SUCCESS;
    }

    const bool taskDisabled = SetAutostartTaskEnabled(false);

    bool runDisabled = false;
    HKEY hKey = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kAutostartRunKey, 0, KEY_SET_VALUE, &hKey) == ERROR_SUCCESS)
    {
        const LONG err = RegDeleteValueW(hKey, kAutostartValueName);
        RegCloseKey(hKey);
        runDisabled = (err == ERROR_SUCCESS || err == ERROR_FILE_NOT_FOUND);
    }
    else
    {
        runDisabled = true;
    }
    return taskDisabled && runDisabled;
}

static void DrawVersionSection(float x, float y, float width, float height)
{
    std::string localVersion;
    std::string remoteVersion;
    bool updateAvailable = false;
    bool versionCheckCompleted = false;
    bool updateInProgress = false;
    {
        std::lock_guard<std::mutex> lock(g_versionStateMutex);
        localVersion = g_localVersion;
        remoteVersion = g_remoteVersion;
        updateAvailable = g_updateAvailable;
        versionCheckCompleted = g_versionCheckCompleted;
        updateInProgress = g_updateInProgress;
    }

    ImGui::SetCursorPos(ImVec2(x, y));
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.1255f, 0.1216f, 0.1412f, 1.0f));  // #201F24
    ImGui::BeginChild("##Section1", ImVec2(width, height), false, ImGuiWindowFlags_NoScrollbar);
    if (g_fontSection1)
        ImGui::PushFont(g_fontSection1);

    const float sectionPadX = 8.0f;  // Уменьшили горизонтальный отступ
    const float sectionPadY = 1.0f; // Компактнее по вертикали
    ImGui::SetCursorPos(ImVec2(sectionPadX, sectionPadY));
    
    // Выравниваем текст относительно кнопок для правильного центрирования
    ImGui::AlignTextToFramePadding();
    
    // спользуем глобальные переменные версий
    if (localVersion != "Unknown")
    {
        // Проверяем статус обновления для выбора цвета локальной версии
        if (versionCheckCompleted && updateAvailable && remoteVersion != "Unknown")
        {
            // Есть обновление - отображаем локальную версию оранжево-желтым
            ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), "%s", localVersion.c_str()); // Оранжево-желтый
        }
        else
        {
            // Нет обновления или проверка идет - отображаем зеленым
            ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "%s", localVersion.c_str()); // Зеленый
        }
        ImGui::SameLine();
        
        // Проверяем статус обновления
        if (updateInProgress)
        {
            ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), "Обновление...");
        }
        else if (!versionCheckCompleted)
        {
            // Проверка еще идет - добавляем анимированные точки
            static float animTime = 0.0f;
            animTime += ImGui::GetIO().DeltaTime;
            int dots = ((int)(animTime * 2) % 4);
            std::string dotsStr = std::string(dots, '.');
            
            ImGui::TextColored(ImVec4(0.95f, 0.76f, 0.06f, 1.0f), "Проверка%s", dotsStr.c_str());
        }
        else if (updateAvailable && remoteVersion != "Unknown")
        {
            // Нужно обновление - показываем в новом формате
            ImGui::TextColored(ImVec4(0.9f, 0.9f, 0.9f, 1.0f), "обновить до"); // Белый
            ImGui::SameLine(0, 4.0f); // Небольшой отступ
            ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "%s", remoteVersion.c_str()); // Зеленый
        }
        else if (remoteVersion != "Unknown")
        {
            // Версия актуальна
            ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "Актуально");
        }
        else
        {
            // Ошибка проверки удаленной версии
            ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "Ошибка проверки");
        }
    }
    else
    {
        ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "Unknown");
        ImGui::SameLine(0, 4.0f);
        if (updateInProgress)
            ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), "Обновление...");
        else
            ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "Ошибка чтения версии");
    }
    
    ImGui::SameLine(0, 8.0f); // Отступ перед разделителем
    
    // Вертикальный сепаратор
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    ImGui::SameLine(0, 8.0f); // Отступ после разделителя
    
    // Кнопка "Проверить обновления" с небольшим отступом
    ImGui::AlignTextToFramePadding();
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.22f, 0.22f, 0.26f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.28f, 0.28f, 0.32f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.18f, 0.18f, 0.22f, 1.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0f);
    
    if (updateInProgress)
        ImGui::BeginDisabled();
    if (ImGui::Button("Проверить обновления "))
    {
        {
            std::lock_guard<std::mutex> lock(g_versionStateMutex);
            g_versionCheckCompleted = false;
        }
        std::thread versionThread(CheckVersionsAsync);
        versionThread.detach();
    }
    if (updateInProgress)
        ImGui::EndDisabled();
    
    ImGui::PopStyleVar(1);
    ImGui::PopStyleColor(3);
    
    // Разделитель после кнопки
    ImGui::SameLine(0, 8.0f); // Отступ перед разделителем
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    
    // Статус работы
    ImGui::SameLine(0, 8.0f); // Отступ после разделителя
    ImGui::TextColored(ImVec4(0.9f, 0.9f, 0.9f, 1.0f), "Статус:"); // Белый
    ImGui::SameLine(0, 4.0f); // Небольшой отступ
    
    // Определяем статус работы Zapret
    static int currentStatus = 2; // По умолчанию не работает
    static float lastStatusCheck = 0.0f;
    float statusTime = ImGui::GetTime();
    static bool tgProxyRunning = false;
    static float lastTgProxyCheck = 0.0f;
    
    // Обновляем статус каждые 2 секунды
    if (statusTime - lastStatusCheck > 2.0f)
    {
        currentStatus = GetZapretStatus();
        lastStatusCheck = statusTime;
    }
    if (statusTime - lastTgProxyCheck > 1.0f)
    {
        tgProxyRunning = IsTelegramWsProxyRunning();
        lastTgProxyCheck = statusTime;
    }
    
    if (currentStatus == 0)
    {
        ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "Работает"); // Зеленый
    }
    else if (currentStatus == 1)
    {
        ImGui::TextColored(ImVec4(0.8f, 0.6f, 0.2f, 1.0f), "Запускается"); // Болотно-оранжевый
    }
    else
    {
        ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "Не работает"); // Красный
    }
    
    // Показываем разделитель и кнопку "Стоп" только если Zapret работает или запускается
    if (currentStatus == 0 || currentStatus == 1) // Работает или Запускается
    {
        // Разделитель после статуса
        ImGui::SameLine(0, 8.0f); // Отступ перед разделителем
        ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
        
        // Кнопка "Стоп" красным цветом
        ImGui::SameLine(0, 8.0f); // Отступ после разделителя
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.96f, 0.26f, 0.21f, 1.0f));        // Красный
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(1.0f, 0.3f, 0.25f, 1.0f));    // Светло-красный при наведении
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.85f, 0.22f, 0.18f, 1.0f));   // Темно-красный при нажатии
        ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0f);
        
        if (ImGui::Button("Стоп"))
        {
            // Останавливаем Zapret
            StopZapret();
            StopTelegramWsProxy();
            
            // Сбрасываем кэш статуса для немедленного обновления
            lastStatusCheck = 0.0f;
        }
        
        ImGui::PopStyleVar(1);
        ImGui::PopStyleColor(3);
    }

    // Кнопка GameFilter всегда доступна
    ImGui::SameLine(0, 8.0f); // Отступ перед разделителем
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    
    ImGui::SameLine(0, 8.0f); // Отступ после разделителя
    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.2f, 0.6f, 0.8f, 1.0f));        // Голубовато-синий
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.3f, 0.7f, 0.9f, 1.0f));  // Светлее при наведении
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.1f, 0.5f, 0.7f, 1.0f));   // Темнее при нажатии
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0f);
    
    static bool showGameFilterPopup = false;
    
    if (ImGui::Button("GameFilter"))
    {
        showGameFilterPopup = true;
        ImGui::OpenPopup("GameFilter Settings");
    }
    
    ImGui::PopStyleVar(1);
    ImGui::PopStyleColor(3);

    // Кнопка TG Fix / TG Off после кнопки GameFilter (при запущенном proxy — выключение)
    ImGui::SameLine(0, 8.0f);
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    ImGui::SameLine(0, 8.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0f);
    if (g_tgFixSetupInProgress.load())
        ImGui::BeginDisabled();
    if (tgProxyRunning)
    {
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.75f, 0.42f, 0.12f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.88f, 0.5f, 0.16f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.62f, 0.34f, 0.08f, 1.0f));
        if (ImGui::Button("TG Off"))
        {
            StopTelegramWsProxy();
            lastTgProxyCheck = 0.0f;
        }
        ImGui::PopStyleColor(3);
    }
    else
    {
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.145f, 0.663f, 0.906f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.2f, 0.72f, 0.95f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.12f, 0.58f, 0.82f, 1.0f));
        if (ImGui::Button("TG Fix"))
        {
            {
                std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
                g_tgFixSetupCompleted = false;
                g_tgFixSetupSuccess = false;
                g_tgFixSetupMessage = "Проверка окружения и зависимостей...";
            }
            std::thread(RunTgFixSetupAndLaunch).detach();
        }
        ImGui::PopStyleColor(3);
    }
    if (g_tgFixSetupInProgress.load())
        ImGui::EndDisabled();
    ImGui::PopStyleVar(1);

    // TG Fix без модального окна: статус одной строкой (идёт работа или итог последнего запуска).
    {
        const bool inProg = g_tgFixSetupInProgress.load();
        std::string setupMsg;
        bool completed = false;
        bool success = false;
        {
            std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
            setupMsg = g_tgFixSetupMessage;
            completed = g_tgFixSetupCompleted;
            success = g_tgFixSetupSuccess;
        }
        const bool showTgStrip =
            inProg || (completed && !setupMsg.empty() && !(success && !tgProxyRunning));
        if (showTgStrip)
        {
            ImGui::Spacing();
            ImGui::SetCursorPosX(sectionPadX);
            const float wrapW = width - sectionPadX * 2;
            ImGui::PushTextWrapPos(ImGui::GetCursorPos().x + wrapW);
            ImVec4 col(0.8f, 0.8f, 0.8f, 1.0f);
            if (inProg)
                col = ImVec4(0.95f, 0.76f, 0.06f, 1.0f);
            else if (!success)
                col = ImVec4(0.96f, 0.26f, 0.21f, 1.0f);
            else
                col = ImVec4(0.22f, 0.78f, 0.42f, 1.0f);
            ImGui::TextColored(col, "%s", setupMsg.c_str());
            ImGui::PopTextWrapPos();
        }
    }
    
    // Всплывающее окно GameFilter
    ImGui::PushStyleVar(ImGuiStyleVar_PopupRounding, 8.0f); // Закругленные углы
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(12.0f, 12.0f)); // Отступы внутри окна
    
    if (ImGui::BeginPopup("GameFilter Settings", ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoResize))
    {
        // Заголовок с увеличенным размером текста
        ImGui::PushFont(nullptr); // спользуем шрифт по умолчанию, но можно настроить размер
        ImGui::Text("Выберите режим GameFilter:");
        ImGui::PopFont();
        ImGui::Separator();
        
        // Получаем текущий статус GameFilter
        static int gameFilterMode = GetGameFilterStatus();
        static float lastGameFilterCheck = 0.0f;
        float gameFilterTime = ImGui::GetTime();
        
        // Обновляем статус каждые 0.5 секунды
        if (gameFilterTime - lastGameFilterCheck > 0.5f)
        {
            gameFilterMode = GetGameFilterStatus();
            lastGameFilterCheck = gameFilterTime;
        }
        
        ImGui::Spacing(); // Отступ после разделителя
        
        if (ImGui::RadioButton("OFF", gameFilterMode == 0))
        {
            gameFilterMode = 0;
            // Отключаем GameFilter
            std::string gameFlagFile = GetZapretRoot() + "\\utils\\game_filter.enabled";
            DeleteFileA(gameFlagFile.c_str());
        }
        
        ImGui::Spacing(); // Отступ между опциями
        
        if (ImGui::RadioButton("TCP", gameFilterMode == 1))
        {
            gameFilterMode = 1;
            // Включаем TCP режим
            std::string utilsDir = GetZapretRoot() + "\\utils";
            std::string gameFlagFile = utilsDir + "\\game_filter.enabled";
            fs::create_directories(utilsDir);
            std::ofstream file(gameFlagFile);
            if (file.is_open())
            {
                file << "tcp";
                file.close();
            }
        }
        
        ImGui::Spacing();
        
        if (ImGui::RadioButton("UDP", gameFilterMode == 2))
        {
            gameFilterMode = 2;
            // Включаем UDP режим
            std::string utilsDir = GetZapretRoot() + "\\utils";
            std::string gameFlagFile = utilsDir + "\\game_filter.enabled";
            fs::create_directories(utilsDir);
            std::ofstream file(gameFlagFile);
            if (file.is_open())
            {
                file << "udp";
                file.close();
            }
        }
        
        ImGui::Spacing();
        
        if (ImGui::RadioButton("TCP+UDP", gameFilterMode == 3))
        {
            gameFilterMode = 3;
            // Включаем TCP+UDP режим
            std::string utilsDir = GetZapretRoot() + "\\utils";
            std::string gameFlagFile = utilsDir + "\\game_filter.enabled";
            fs::create_directories(utilsDir);
            std::ofstream file(gameFlagFile);
            if (file.is_open())
            {
                file << "all";
                file.close();
            }
        }
        
        ImGui::Separator();
        
        ImGui::Spacing(); // Дополнительный отступ
        
        // Кнопка "Закрыть" по центру
        float buttonWidth = 80.0f;
        float windowWidth = ImGui::GetWindowWidth();
        ImGui::SetCursorPosX((windowWidth - buttonWidth) * 0.5f);
        
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.22f, 0.22f, 0.26f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.28f, 0.28f, 0.32f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.18f, 0.18f, 0.22f, 1.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0f);
        
        if (ImGui::Button("Закрыть", ImVec2(buttonWidth, 0)))
        {
            ImGui::CloseCurrentPopup();
        }
        
        ImGui::PopStyleVar(1);
        ImGui::PopStyleColor(3);
        
        ImGui::EndPopup();
    }
    
    ImGui::PopStyleVar(2); // Убираем стили popup окна

    // Separator для новой строки
    ImGui::Separator();
    
    // Новая строка с сервисами
    ImGui::Spacing(); // Небольшой отступ после separator
    ImGui::SetCursorPosX(sectionPadX); // Выравниваем по левому краю
    ImGui::AlignTextToFramePadding();   // одна линия с кнопкой «Автозапуск» в конце строки

    // Сервисы:
    ImGui::TextColored(ImVec4(0.9f, 0.9f, 0.9f, 1.0f), "Сервисы:"); // Белый
    ImGui::SameLine(0, 4.0f);
    
    // Discord:
    ImGui::TextColored(ImVec4(0.345f, 0.396f, 0.949f, 1.0f), "Discord:"); // #5865F2 - фирменный синий Discord
    ImGui::SameLine(0, 4.0f);
    
    // Статус Discord
    if (g_discordStatus.load() == 0)
    {
        ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "Ок"); // Зеленый
    }
    else if (g_discordStatus.load() == 1)
    {
        ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), ". . ."); // Оранжевый - тестирование
    }
    else
    {
        ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "X"); // Красный - недоступно
    }
    ImGui::SameLine(0, 8.0f);
    
    // YouTube:
    ImGui::TextColored(ImVec4(1.0f, 0.0f, 0.0f, 1.0f), "YouTube:"); // #FF0000 - фирменный красный YouTube
    ImGui::SameLine(0, 4.0f);
    
    // Статус YouTube
    if (g_youtubeStatus.load() == 0)
    {
        ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "Ок"); // Зеленый
    }
    else if (g_youtubeStatus.load() == 1)
    {
        ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), ". . ."); // Оранжевый - тестирование
    }
    else
    {
        ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "X"); // Красный - недоступно
    }
    ImGui::SameLine(0, 8.0f);
    
    // Telegram:
    ImGui::TextColored(ImVec4(0.145f, 0.663f, 0.906f, 1.0f), "Telegram:"); // #26A9E7 - фирменный голубой Telegram
    ImGui::SameLine(0, 4.0f);
    
    // Статус Telegram
    if (g_telegramStatus.load() == 0)
    {
        ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "Ок"); // Зеленый
    }
    else if (g_telegramStatus.load() == 1)
    {
        ImGui::TextColored(ImVec4(1.0f, 0.647f, 0.0f, 1.0f), ". . ."); // Оранжевый - тестирование
    }
    else
    {
        ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "X"); // Красный - недоступно
    }
    ImGui::SameLine(0, 8.0f);
    
    // Разделитель
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    ImGui::SameLine(0, 8.0f);
    
    // GameFilter:
    ImGui::TextColored(ImVec4(0.9f, 0.9f, 0.9f, 1.0f), "GameFilter:"); // Белый
    ImGui::SameLine(0, 4.0f);
    
    // Статус GameFilter
    int currentGameFilterStatus = GetGameFilterStatus();
    if (currentGameFilterStatus == 0)
    {
        ImGui::TextColored(ImVec4(0.361f, 0.361f, 0.369f, 1.0f), "Выкл"); // #5C5C5E
    }
    else if (currentGameFilterStatus == 1)
    {
        ImGui::TextColored(ImVec4(0.361f, 0.361f, 0.369f, 1.0f), "TCP"); // #5C5C5E
    }
    else if (currentGameFilterStatus == 2)
    {
        ImGui::TextColored(ImVec4(0.361f, 0.361f, 0.369f, 1.0f), "UDP"); // #5C5C5E
    }
    else if (currentGameFilterStatus == 3)
    {
        ImGui::TextColored(ImVec4(0.361f, 0.361f, 0.369f, 1.0f), "TCP+UDP"); // #5C5C5E
    }

    // TG proxy статус после текста GameFilter
    ImGui::SameLine(0, 8.0f);
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    ImGui::SameLine(0, 8.0f);
    ImGui::TextColored(ImVec4(0.145f, 0.663f, 0.906f, 1.0f), "TG proxy:");
    ImGui::SameLine(0, 4.0f);
    if (tgProxyRunning)
        ImGui::TextColored(ImVec4(0.22f, 0.78f, 0.42f, 1.0f), "Вкл");
    else
        ImGui::TextColored(ImVec4(0.8f, 0.6f, 0.2f, 1.0f), "Выкл");

    ImGui::SameLine(0, 8.0f);
    ImGui::TextColored(ImVec4(0.5f, 0.5f, 0.5f, 1.0f), "|");
    ImGui::SameLine(0, 8.0f);

    static bool autostartOn = false;
    static float lastAutostartCheck = 0.0f;
    const float atTime = ImGui::GetTime();
    if (atTime - lastAutostartCheck > 0.5f)
    {
        autostartOn = IsAutostartEnabled();
        lastAutostartCheck = atTime;
    }

    ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.22f, 0.22f, 0.26f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.28f, 0.28f, 0.32f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.18f, 0.18f, 0.22f, 1.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0f);
    const bool autostartWasOn = autostartOn;
    if (autostartWasOn)
    {
        ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.22f, 0.78f, 0.42f, 1.0f));
        ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2.0f);
    }
    if (ImGui::Button("Автозапуск", ImVec2(110.0f, 0.0f)))
    {
        SetAutostartEnabled(!autostartOn);
        autostartOn = IsAutostartEnabled();
        lastAutostartCheck = atTime;
    }
    if (autostartWasOn)
        ImGui::PopStyleVar(1);
    ImGui::PopStyleVar(1);
    if (autostartWasOn)
        ImGui::PopStyleColor(1);
    ImGui::PopStyleColor(3);

    if (g_fontSection1)
        ImGui::PopFont();
    ImGui::EndChild();
    ImGui::PopStyleColor(1);
}

static void DrawStrategiesSection(float x, float y, float width, float height)
{
    ImGui::SetCursorPos(ImVec2(x, y));
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.1255f, 0.1216f, 0.1412f, 1.0f));  // #201F24
    ImGui::BeginChild("##Section2", ImVec2(width, height), false, ImGuiWindowFlags_NoScrollbar);
    if (g_fontSection2)
        ImGui::PushFont(g_fontSection2);

    // Такие же отступы как в первой секции
    const float sectionPadX = 8.0f;
    const float sectionPadY = 2.0f;
    ImGui::SetCursorPos(ImVec2(sectionPadX, sectionPadY));
    
    // Выравниваем текст относительно кнопок
    ImGui::AlignTextToFramePadding();
    
    // Получаем список стратегий для подсчета
    static std::vector<std::string> strategies;
    static std::string lastZapretRoot;
    static unsigned int lastRefreshToken = 0;
    const bool bootstrapInProgress = g_bootstrapInProgress.load();
    std::string root = GetZapretRoot();
    const unsigned int refreshToken = g_strategyRefreshToken.load();
    if (root != lastZapretRoot || refreshToken != lastRefreshToken)
    {
        lastZapretRoot = root;
        lastRefreshToken = refreshToken;
        strategies = ScanStrategies(root);
    }
    
    // Стратегии: (количество) и кнопки тестирования
    ImGui::TextColored(ImVec4(0.9f, 0.9f, 0.9f, 1.0f), "Стратегии: (%zu)", strategies.size());
    if (bootstrapInProgress)
    {
        ImGui::SameLine();
        ImGui::TextColored(ImVec4(0.95f, 0.76f, 0.06f, 1.0f), "Подготовка файлов...");
    }
    ImGui::SameLine();
    bool testBtnDisabled = g_strategyTestInProgress.load() || bootstrapInProgress;
    bool isPaused = false;
    { std::lock_guard<std::mutex> lock(g_strategyTestMutex); isPaused = g_strategyTestPaused; }
    if (testBtnDisabled && !isPaused)
        ImGui::BeginDisabled();
    if (ImGui::Button(isPaused ? "Продолжить тест" : "Тестирование стратегий"))
    {
        int startIdx = 0;
        if (isPaused)
            { std::lock_guard<std::mutex> lock(g_strategyTestMutex); startIdx = g_strategyTestResumeFromIndex; g_strategyTestPaused = false; }
        else
        {
            { std::lock_guard<std::mutex> lock(g_strategyTestMutex); g_strategyTestResults.clear(); g_bestStrategy.clear(); }
            SaveStrategyTestResultsToIni();
        }
        std::thread t([startIdx]() { RunStrategyTest(startIdx); });
        t.detach();
    }
    if (testBtnDisabled && !isPaused)
        ImGui::EndDisabled();
    if (g_strategyTestInProgress.load())
    {
        ImGui::SameLine();
        if (ImGui::Button("Остановить"))
        {
            g_strategyTestStopRequested.store(true, std::memory_order_release);
            StopZapret();
        }
        ImGui::SameLine();
        int curIdx = 0, total = 0;
        std::string current;
        { std::lock_guard<std::mutex> lock(g_strategyTestMutex); curIdx = g_strategyTestCurrentIdx; total = g_strategyTestTotal; current = g_strategyTestCurrent; }
        ImGui::TextColored(ImVec4(0.7f, 0.7f, 0.7f, 1.0f), "%s", current.c_str());
        float progress = (total > 0) ? (float)curIdx / (float)total : 0.0f;
        ImGui::SameLine();
        ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(0.22f, 0.78f, 0.42f, 0.6f));
        ImGui::ProgressBar(progress, ImVec2(90, 0), "");
        ImGui::PopStyleColor();
        ImGui::SameLine();
        ImGui::TextColored(ImVec4(0.7f, 0.7f, 0.7f, 1.0f), "(%d/%d)", curIdx, total);
    }

    std::string runtimeError;
    {
        std::lock_guard<std::mutex> lock(g_runtimeMessageMutex);
        runtimeError = g_lastRuntimeError;
    }
    if (!runtimeError.empty())
    {
        ImGui::SameLine();
        ImGui::TextColored(ImVec4(0.96f, 0.26f, 0.21f, 1.0f), "%s", runtimeError.c_str());
    }

    // Separator
    ImGui::Separator();
    
    // Добавляем отступ после separator
    ImGui::Spacing();
    
    // Список стратегий в две колонки
    if (!strategies.empty())
    {
        if (bootstrapInProgress)
            ImGui::BeginDisabled();

        // Вычисляем размеры для грида - используем полную ширину секции
        float availableWidth = width; // спользуем всю ширину секции ректангла
        float availableHeight = height - ImGui::GetCursorPosY() - sectionPadY;
        
        // Перемещаем курсор к началу секции по X
        ImGui::SetCursorPosX(0);
        
        // Настраиваем стили для скроллбара
        ImGui::PushStyleVar(ImGuiStyleVar_ScrollbarRounding, 6.0f); // Закругление скроллбара
        ImGui::PushStyleVar(ImGuiStyleVar_GrabRounding, 6.0f);      // Закругление ползунка
        ImGui::PushStyleColor(ImGuiCol_ScrollbarBg, ImVec4(0.1255f, 0.1216f, 0.1412f, 1.0f));    // Фон скроллбара (как у секции)
        ImGui::PushStyleColor(ImGuiCol_ScrollbarGrab, ImVec4(0.3f, 0.3f, 0.35f, 1.0f));          // Ползунок
        ImGui::PushStyleColor(ImGuiCol_ScrollbarGrabHovered, ImVec4(0.4f, 0.4f, 0.45f, 1.0f));   // Ползунок при наведении
        ImGui::PushStyleColor(ImGuiCol_ScrollbarGrabActive, ImVec4(0.5f, 0.5f, 0.55f, 1.0f));    // Ползунок при нажатии
        
        ImGui::BeginChild("##StrategyGrid", ImVec2(availableWidth, availableHeight), false);
        
        // Отступ сверху под кружки первой строки (чтобы не обрезались)
        ImGui::Dummy(ImVec2(0, 14.0f));
        
        // Параметры кнопок - учитываем отступы от краев секции
        const float gridPadding = sectionPadX + 4.0f;
        const float columnGap = ImGui::GetStyle().ItemSpacing.x + 2.0f;
        const float btnH = 34.0f;
        const int rows = (int)((strategies.size() + 1) / 2);
        const float topDummyH = 14.0f;
        const float contentH = topDummyH + (rows > 0 ? (rows * btnH + (rows - 1) * ImGui::GetStyle().ItemSpacing.y) : 0.0f);
        const bool needVScrollbar = contentH > availableHeight;
        const float scrollbarReserve = needVScrollbar ? ImGui::GetStyle().ScrollbarSize : 0.0f;
        const float btnW = (availableWidth - scrollbarReserve - columnGap - gridPadding * 2) * 0.5f;
        const float btnRounding = 6.0f;
        
        // Состояние выбранной и активной стратегии (сбрасывается при нажатии "Стоп")
        int selectedIdx = g_selectedStrategyIdx.load();
        int activeIdx = g_activeStrategyIdx.load();
        
        // Не выбираем стратегию автоматически при запуске
        // activeIdx остается -1 пока пользователь не выберет стратегию
        
        // Проверяем границы индексов
        if (selectedIdx >= (int)strategies.size())
            selectedIdx = -1;
        if (activeIdx >= (int)strategies.size())
            activeIdx = -1;
        g_selectedStrategyIdx.store(selectedIdx);
        g_activeStrategyIdx.store(activeIdx);

        std::string bestStr;
        { std::lock_guard<std::mutex> lock(g_strategyTestMutex); bestStr = g_bestStrategy; }

        // Отображаем кнопки стратегий в 2 колонки
        for (size_t i = 0; i < strategies.size(); ++i)
        {
            int col = (int)(i % 2);
            if (col == 0)
                ImGui::SetCursorPosX(gridPadding); // Отступ от левого края секции
            
            bool isSelected = (selectedIdx >= 0 && (size_t)selectedIdx == i);
            bool isActive = ((int)i == activeIdx);
            
            // Стили для активной стратегии (зеленая)
            if (isActive)
            {
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.18f, 0.58f, 0.32f, 1.0f));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.22f, 0.65f, 0.38f, 1.0f));
                ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.15f, 0.5f, 0.28f, 1.0f));
                ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, btnRounding);
            }
            // Стили для выбранной стратегии (с зеленой рамкой)
            else if (isSelected)
            {
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.2f, 0.24f, 0.27f, 1.0f));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.25f, 0.29f, 0.32f, 1.0f));
                ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.17f, 0.21f, 0.24f, 1.0f));
                ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0.22f, 0.78f, 0.42f, 1.0f));
                ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, btnRounding);
                ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 2.0f);
            }
            
            if (ImGui::Button(strategies[i].c_str(), ImVec2(btnW, btnH)))
            {
                // Сначала запускаем (внутри вызывается StopZapret, который сбрасывает выделение)
                LaunchStrategy(strategies[i]);
                // После запуска выставляем зелёное выделение для выбранной стратегии
                selectedIdx = (int)i;
                activeIdx = (int)i;
                g_selectedStrategyIdx.store(selectedIdx);
                g_activeStrategyIdx.store(activeIdx);
            }

            // Кружочки над левым верхним углом кнопки: Discord, YouTube, Telegram (пустые до теста)
            {
                ImVec2 btnMin = ImGui::GetItemRectMin();
                ImDrawList* dl = ImGui::GetWindowDrawList();
                const float r = 4.0f;
                const float gap = 2.0f;
                float cx = btnMin.x + r + 2.5f;
                float cy = btnMin.y - r + 10.5f;  // над верхним краем
                const ImU32 colors[] = {
                    IM_COL32(88, 101, 242, 255),   // Discord #5865F2
                    IM_COL32(255, 0, 0, 255),      // YouTube #FF0000
                    IM_COL32(0, 136, 204, 255)     // Telegram #0088CC
                };
                std::lock_guard<std::mutex> lock(g_strategyTestMutex);
                auto it = g_strategyTestResults.find(strategies[i]);
                for (int s = 0; s < 3; ++s)
                {
                    ImU32 col;
                    if (it != g_strategyTestResults.end())
                        col = it->second.ok[s] ? colors[s] : IM_COL32(80, 80, 80, 200);
                    else
                        col = IM_COL32(110, 110, 115, 230);  // пустой до теста (ярче)
                    dl->AddCircleFilled(ImVec2(cx, cy), r, col, 12);
                    cx += r * 2 + gap;
                }
                ImFont* font = ImGui::GetFont();
                float belowY = cy + r + 2.0f;
                if (it != g_strategyTestResults.end() && it->second.pingMs >= 0)
                {
                    char pingBuf[24];
                    std::snprintf(pingBuf, sizeof(pingBuf), "%d ms", it->second.pingMs);
                    const float fsPing = ImGui::GetFontSize() * 0.6f;
                    ImVec2 tsPing = font->CalcTextSizeA(fsPing, FLT_MAX, 0.0f, pingBuf);
                    float centerX = btnMin.x + (r + 2.5f) + (r * 2 + gap);
                    dl->AddText(
                        font,
                        fsPing,
                        ImVec2(centerX - tsPing.x * 0.5f, belowY),
                        IM_COL32(160, 160, 168, 255),
                        pingBuf);
                    belowY += tsPing.y + 1.0f;
                }
                if (!bestStr.empty() && strategies[i] == bestStr)
                {
                    const char* label = "Лучший";
                    float fs = ImGui::GetFontSize() * 0.65f;
                    ImVec2 ts = font->CalcTextSizeA(fs, FLT_MAX, 0.0f, label);
                    float centerX = btnMin.x + (r + 2.5f) + (r * 2 + gap);
                    float labelX = centerX - ts.x * 0.5f;
                    dl->AddText(font, fs, ImVec2(labelX, belowY), IM_COL32(212, 175, 55, 255), label);
                }
            }
            
            // Очистка стилей
            if (isSelected && !isActive)
            {
                ImGui::PopStyleVar(2);
                ImGui::PopStyleColor(4);
            }
            else if (isActive || isSelected)
            {
                ImGui::PopStyleVar(1);
                ImGui::PopStyleColor(3);
            }
            
            // Размещение в 2 колонки
            if (col == 0)
                ImGui::SameLine(0, columnGap);
        }
        

        
        ImGui::EndChild();
        
        // Убираем стили скроллбара
        ImGui::PopStyleColor(4); // Убираем 4 цвета скроллбара
        ImGui::PopStyleVar(2);    // Убираем 2 переменные скроллбара

        if (bootstrapInProgress)
            ImGui::EndDisabled();
    }

    if (g_fontSection2)
        ImGui::PopFont();
    ImGui::EndChild();
    ImGui::PopStyleColor(1);
}

// Доп. место под строку статуса TG Fix (без модалки), чтобы текст не обрезался в BeginChild.
static float TgFixStatusStripExtraHeight()
{
    const bool inProg = g_tgFixSetupInProgress.load();
    const bool proxyRunning = IsTelegramWsProxyRunning();
    bool completed = false;
    bool success = false;
    std::string msg;
    {
        std::lock_guard<std::mutex> lock(g_tgFixSetupMutex);
        completed = g_tgFixSetupCompleted;
        success = g_tgFixSetupSuccess;
        msg = g_tgFixSetupMessage;
    }
    // Не показываем зелёный «запущен», если прокси уже не работает (TG Off, падение процесса).
    const bool showStrip =
        inProg || (completed && !msg.empty() && !(success && !proxyRunning));
    if (showStrip)
        return 32.0f;
    return 0.0f;
}

void UI_Render()
{
    HWND hwnd = Window_GetHandle();
    RECT rc;
    GetClientRect(hwnd, &rc);
    float w = (float)(rc.right - rc.left);
    float h = (float)(rc.bottom - rc.top);

    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(w, h));

    ImGuiWindowFlags flags =
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBringToFrontOnFocus;

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0f);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.06275f, 0.06275f, 0.06275f, 1.0f));  // #101010

    ImGui::Begin("##MainWindow", nullptr, flags);

    // Заголовок с кнопками управления окном
    const float titleBarHeight = 28.0f;
    const float buttonSize = 14.0f;
    const float buttonSpacing = 8.0f;

    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.06275f, 0.06275f, 0.06275f, 1.0f));  // #101010 title bar
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 0.0f);
    ImGui::BeginChild("##TitleBar", ImVec2(w, titleBarHeight), false, ImGuiWindowFlags_NoScrollbar);

    ImGui::SetCursorPos(ImVec2(12, 6));
    ImGui::TextColored(ImVec4(0.9f, 0.9f, 0.9f, 1.0f), "AntiZapret - Обход блокировок");

    // Отрисовка кнопок светофора (свернуть, развернуть, закрыть)
    DrawTitleBarButtons(w, titleBarHeight, buttonSize, buttonSpacing);

    ImGui::EndChild();
    ImGui::PopStyleVar(1);
    ImGui::PopStyleColor(1);

    // Параметры для секций
    const float pad = 12.0f;
    float y = titleBarHeight + pad;

    const float statusRowHeight = 30.0f;
    const float servicesRowHeight = 20.0f;
    const float sectionInnerPad = 5.0f;
    const float section1Height = statusRowHeight + sectionInnerPad + servicesRowHeight + TgFixStatusStripExtraHeight();

    // Первый блок (информация о версии)
    DrawVersionSection(pad, y, w - pad * 2, section1Height);
    y += section1Height + pad;

    // Второй блок (стратегии + грид)
    const float section2Height = h - y - pad;
    DrawStrategiesSection(pad, y, w - pad * 2, section2Height);

    ImGui::End();

    ImGui::PopStyleColor(1);
    ImGui::PopStyleVar(2);
}

std::vector<std::string> UI_GetStrategiesForTray()
{
    return ScanStrategies(GetZapretRoot());
}

std::string UI_GetActiveStrategyForTray()
{
    const int activeIdx = g_activeStrategyIdx.load();
    if (activeIdx < 0)
        return std::string();

    const std::vector<std::string> strategies = ScanStrategies(GetZapretRoot());
    if (activeIdx >= (int)strategies.size())
        return std::string();
    return strategies[(size_t)activeIdx];
}

bool UI_IsStrategyRunningForTray()
{
    if (g_activeStrategyIdx.load() >= 0)
        return true;

    std::lock_guard<std::mutex> lock(g_processMutex);
    if (!g_winwsProcess)
        return false;
    const DWORD wait = WaitForSingleObject(g_winwsProcess, 0);
    return wait == WAIT_TIMEOUT;
}

void UI_LaunchStrategyFromTray(const std::string& strategyName)
{
    if (strategyName.empty())
        return;
    LaunchStrategy(strategyName);
}

void UI_StopStrategyFromTray()
{
    StopZapret();
}

bool UI_IsTelegramProxyRunningForTray()
{
    return IsTelegramWsProxyRunning();
}

void UI_StartTgFixFromTray()
{
    std::thread(RunTgFixSetupAndLaunch).detach();
}

void UI_StopTgFixFromTray()
{
    ShutdownAllTelegramWsProxyProcesses();
}
