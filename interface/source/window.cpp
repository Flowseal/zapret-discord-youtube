#include "window.h"
#include "ui.h"
#include "imgui.h"
#include "imgui_impl_win32.h"
#include <dwmapi.h>
#include <shellapi.h>
#include <windowsx.h>
#include <algorithm>
#include <string>
#include <vector>

#pragma comment(lib, "dwmapi.lib")

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);
void Renderer_OnResize(UINT width, UINT height);

static HWND g_hWnd = nullptr;
static int g_minWidth = 600;
static int g_minHeight = 548;

static bool g_dragging = false;
static POINT g_dragStartCursor;
static POINT g_dragStartWindow;
static bool g_trayIconAdded = false;

static constexpr UINT WM_APP_TRAYICON = WM_APP + 1;
static constexpr UINT TRAY_ICON_ID = 1001;
static constexpr UINT TRAY_MENU_OPEN_ID = 2001;
static constexpr UINT TRAY_MENU_DISABLE_ID = 2002;
static constexpr UINT TRAY_MENU_EXIT_ID = 2003;
static constexpr UINT TRAY_MENU_TG_FIX_ID = 2004;
static constexpr UINT TRAY_MENU_TG_OFF_ID = 2005;
static constexpr UINT TRAY_STRATEGY_BASE_ID = 3000;
static constexpr UINT TRAY_STRATEGY_MAX_ITEMS = 500;
static std::vector<std::string> g_trayStrategies;

static LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

static std::wstring Utf8ToWide(const std::string& text)
{
    if (text.empty())
        return std::wstring();
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    if (size <= 1)
        return std::wstring();
    std::wstring out((size_t)size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, &out[0], size);
    out.pop_back(); // remove terminating NUL
    return out;
}

static void AddTrayIcon(HWND hWnd)
{
    if (g_trayIconAdded)
        return;

    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hWnd;
    nid.uID = TRAY_ICON_ID;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_APP_TRAYICON;
    nid.hIcon = (HICON)LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, 16, 16, 0);
    lstrcpynW(nid.szTip, L"AntiZapret", ARRAYSIZE(nid.szTip));

    if (Shell_NotifyIconW(NIM_ADD, &nid))
    {
        nid.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &nid);
        g_trayIconAdded = true;
    }
}

static void RemoveTrayIcon(HWND hWnd)
{
    if (!g_trayIconAdded)
        return;
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hWnd;
    nid.uID = TRAY_ICON_ID;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    g_trayIconAdded = false;
}

static void RestoreFromTray(HWND hWnd)
{
    ShowWindow(hWnd, SW_RESTORE);
    ShowWindow(hWnd, SW_SHOW);
    SetForegroundWindow(hWnd);
    RemoveTrayIcon(hWnd);
}

static void MinimizeToTray(HWND hWnd)
{
    AddTrayIcon(hWnd);
    ShowWindow(hWnd, SW_HIDE);
}

static void ShowTrayMenu(HWND hWnd)
{
    HMENU menu = CreatePopupMenu();
    if (!menu)
        return;

    g_trayStrategies = UI_GetStrategiesForTray();
    const std::string activeStrategy = UI_GetActiveStrategyForTray();
    const bool isRunning = UI_IsStrategyRunningForTray();
    const bool tgProxyRunning = UI_IsTelegramProxyRunningForTray();

    AppendMenuW(menu, MF_STRING, TRAY_MENU_OPEN_ID, L"Открыть");
    if (isRunning)
        AppendMenuW(menu, MF_STRING, TRAY_MENU_DISABLE_ID, L"Отключить");
    else
        AppendMenuW(menu, MF_STRING | MF_GRAYED, TRAY_MENU_DISABLE_ID, L"Отключить");

    if (tgProxyRunning)
        AppendMenuW(menu, MF_STRING | MF_GRAYED, TRAY_MENU_TG_FIX_ID, L"TG Fix");
    else
        AppendMenuW(menu, MF_STRING, TRAY_MENU_TG_FIX_ID, L"TG Fix");
    if (tgProxyRunning)
        AppendMenuW(menu, MF_STRING, TRAY_MENU_TG_OFF_ID, L"Выключить TG proxy");
    else
        AppendMenuW(menu, MF_STRING | MF_GRAYED, TRAY_MENU_TG_OFF_ID, L"Выключить TG proxy");

    HMENU strategiesMenu = CreatePopupMenu();
    if (strategiesMenu)
    {
        const size_t maxItems = (std::min)(g_trayStrategies.size(), (size_t)TRAY_STRATEGY_MAX_ITEMS);
        for (size_t i = 0; i < maxItems; ++i)
        {
            const UINT cmdId = TRAY_STRATEGY_BASE_ID + (UINT)i;
            UINT flags = MF_STRING;
            if (!activeStrategy.empty() && g_trayStrategies[i] == activeStrategy)
                flags |= MF_CHECKED;
            const std::wstring itemName = Utf8ToWide(g_trayStrategies[i]);
            AppendMenuW(strategiesMenu, flags, cmdId, itemName.empty() ? L"(без имени)" : itemName.c_str());
        }
        if (maxItems == 0)
            AppendMenuW(strategiesMenu, MF_STRING | MF_GRAYED, TRAY_STRATEGY_BASE_ID, L"(список пуст)");
        AppendMenuW(menu, MF_POPUP, (UINT_PTR)strategiesMenu, L"Стратегии");
    }

    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, TRAY_MENU_EXIT_ID, L"Выход");

    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(hWnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, hWnd, nullptr);
    DestroyMenu(menu);
}

void Window_SetHandle(HWND hwnd)
{
    g_hWnd = hwnd;
}

HWND Window_GetHandle()
{
    return g_hWnd;
}

void Window_SetMinSize(int minWidth, int minHeight)
{
    g_minWidth = minWidth;
    g_minHeight = minHeight;
}

HWND Window_Create(int width, int height)
{
    WNDCLASSEXW wc = { sizeof(wc), CS_CLASSDC, WndProc, 0L, 0L, GetModuleHandle(nullptr), nullptr, nullptr, nullptr, nullptr, L"AntiZapret", nullptr };
    wc.hIcon = (HICON)LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, 0, 0, LR_DEFAULTSIZE);
    wc.hIconSm = (HICON)LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, 16, 16, 0);
    ::RegisterClassExW(&wc);

    HWND hwnd = ::CreateWindowExW(
        WS_EX_APPWINDOW,
        wc.lpszClassName,
        L"AntiZapret",
        WS_POPUP,
        100, 100, width, height,
        nullptr, nullptr, wc.hInstance, nullptr
    );

    g_hWnd = hwnd;

    DWM_WINDOW_CORNER_PREFERENCE preference = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, sizeof(preference));
    BOOL darkMode = TRUE;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &darkMode, sizeof(darkMode));

    return hwnd;
}

static bool IsInTitleBarExcludeButtons(POINT ptClient, int clientWidth)
{
    const int titleBarHeight = 32;
    const int buttonAreaWidth = 100;
    return ptClient.y < titleBarHeight && ptClient.x < clientWidth - buttonAreaWidth;
}

static LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    // Custom drag: неблокирующее перетаскивание (HTCAPTION блокирует поток)
    if (msg == WM_LBUTTONDOWN && !g_dragging)
    {
        POINT pt = { GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
        RECT rc;
        GetClientRect(hWnd, &rc);
        if (IsInTitleBarExcludeButtons(pt, rc.right))
        {
            g_dragging = true;
            g_dragStartCursor.x = GET_X_LPARAM(lParam);
            g_dragStartCursor.y = GET_Y_LPARAM(lParam);
            ClientToScreen(hWnd, &g_dragStartCursor);
            RECT wr;
            GetWindowRect(hWnd, &wr);
            g_dragStartWindow.x = wr.left;
            g_dragStartWindow.y = wr.top;
            SetCapture(hWnd);
            return 0;
        }
    }
    if (msg == WM_MOUSEMOVE && g_dragging)
    {
        POINT pt = { GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
        ClientToScreen(hWnd, &pt);
        int dx = pt.x - g_dragStartCursor.x;
        int dy = pt.y - g_dragStartCursor.y;
        g_dragStartCursor = pt;
        g_dragStartWindow.x += dx;
        g_dragStartWindow.y += dy;
        SetWindowPos(hWnd, nullptr, g_dragStartWindow.x, g_dragStartWindow.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
        return 0;
    }
    if ((msg == WM_LBUTTONUP || msg == WM_CAPTURECHANGED) && g_dragging)
    {
        g_dragging = false;
        ReleaseCapture();
        if (msg == WM_LBUTTONUP)
            return 0;
    }

    if (ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam))
        return true;

    switch (msg)
    {
    case WM_GETMINMAXINFO:
    {
        MINMAXINFO* pMMI = (MINMAXINFO*)lParam;
        pMMI->ptMinTrackSize.x = g_minWidth;
        pMMI->ptMinTrackSize.y = g_minHeight;
        return 0;
    }
    case WM_SIZE:
        if (wParam == SIZE_MINIMIZED)
        {
            MinimizeToTray(hWnd);
            return 0;
        }
        Renderer_OnResize((UINT)LOWORD(lParam), (UINT)HIWORD(lParam));
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wParam))
        {
        case TRAY_MENU_OPEN_ID:
            RestoreFromTray(hWnd);
            return 0;
        case TRAY_MENU_DISABLE_ID:
            UI_StopStrategyFromTray();
            return 0;
        case TRAY_MENU_EXIT_ID:
            PostMessageW(hWnd, WM_CLOSE, 0, 0);
            return 0;
        case TRAY_MENU_TG_FIX_ID:
            UI_StartTgFixFromTray();
            return 0;
        case TRAY_MENU_TG_OFF_ID:
            UI_StopTgFixFromTray();
            return 0;
        default:
            if (LOWORD(wParam) >= TRAY_STRATEGY_BASE_ID)
            {
                const UINT idx = LOWORD(wParam) - TRAY_STRATEGY_BASE_ID;
                if (idx < g_trayStrategies.size())
                    UI_LaunchStrategyFromTray(g_trayStrategies[idx]);
                return 0;
            }
            break;
        }
        break;
    case WM_APP_TRAYICON:
        switch (LOWORD(lParam))
        {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
            RestoreFromTray(hWnd);
            return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
            ShowTrayMenu(hWnd);
            return 0;
        default:
            break;
        }
        break;
    case WM_SYSCOMMAND:
        if ((wParam & 0xfff0) == SC_KEYMENU)
            return 0;
        break;
    case WM_CLOSE:
        RemoveTrayIcon(hWnd);
        break;
    case WM_DESTROY:
        RemoveTrayIcon(hWnd);
        ::PostQuitMessage(0);
        return 0;
    case WM_NCHITTEST:
    {
        POINT pt = { GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
        ::ScreenToClient(hWnd, &pt);

        RECT rc;
        ::GetClientRect(hWnd, &rc);

        const int borderSize = 5;
        const int titleBarHeight = 32;
        const int buttonAreaWidth = 100;

        if (pt.y < borderSize)
        {
            if (pt.x < borderSize) return HTTOPLEFT;
            if (pt.x > rc.right - borderSize) return HTTOPRIGHT;
            return HTTOP;
        }
        if (pt.y > rc.bottom - borderSize)
        {
            if (pt.x < borderSize) return HTBOTTOMLEFT;
            if (pt.x > rc.right - borderSize) return HTBOTTOMRIGHT;
            return HTBOTTOM;
        }
        if (pt.x < borderSize) return HTLEFT;
        if (pt.x > rc.right - borderSize) return HTRIGHT;

        // Title bar: HTCLIENT чтобы получать WM_LBUTTONDOWN (кастомный drag)
        if (pt.y < titleBarHeight && pt.x < rc.right - buttonAreaWidth)
            return HTCLIENT;

        return HTCLIENT;
    }
    }
    return ::DefWindowProcW(hWnd, msg, wParam, lParam);
}
