// AntiZapret: точка входа

#include "window.h"
#include "renderer.h"
#include "ui.h"
#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx11.h"
#include <windows.h>
#include <cstring>

static const wchar_t* SINGLE_INSTANCE_MUTEX_NAME = L"AntiZapret_SingleInstance_7F83B2E1";

static void BringExistingWindowToFront()
{
    HWND existing = ::FindWindowW(L"AntiZapret", L"AntiZapret");
    if (existing)
    {
        if (!::IsWindowVisible(existing))
            ::ShowWindow(existing, SW_SHOW);
        if (::IsIconic(existing))
            ::ShowWindow(existing, SW_RESTORE);
        ::SetForegroundWindow(existing);
    }
}

int main(int argc, char** argv)
{
    bool startupFromAutostart = false;
    for (int i = 1; i < argc; ++i)
    {
        if (argv[i] && (_stricmp(argv[i], "--autostart") == 0 || _stricmp(argv[i], "-autostart") == 0))
        {
            startupFromAutostart = true;
            break;
        }
    }

    HANDLE mutex = ::CreateMutexW(nullptr, TRUE, SINGLE_INSTANCE_MUTEX_NAME);
    if (mutex && ::GetLastError() == ERROR_ALREADY_EXISTS)
    {
        if (mutex)
            ::CloseHandle(mutex);
        BringExistingWindowToFront();
        return 0;
    }

    ImGui_ImplWin32_EnableDpiAwareness();
    float scale = ImGui_ImplWin32_GetDpiScaleForMonitor(::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY));

    int w = (int)(666 * scale);
    int h = (int)(555 * scale);

    HWND hwnd = Window_Create(w, h);
    Window_SetMinSize(w, h);
    if (!Renderer_Init(hwnd))
    {
        Renderer_Shutdown();
        if (mutex)
            ::CloseHandle(mutex);
        return 1;
    }

    ::ShowWindow(hwnd, SW_SHOWDEFAULT);
    ::UpdateWindow(hwnd);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();

    UI_Init(scale, startupFromAutostart);
    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplDX11_Init(Renderer_GetDevice(), Renderer_GetContext());

    bool done = false;
    while (!done)
    {
        MSG msg;
        while (::PeekMessage(&msg, nullptr, 0U, 0U, PM_REMOVE))
        {
            ::TranslateMessage(&msg);
            ::DispatchMessage(&msg);
            if (msg.message == WM_QUIT)
                done = true;
        }
        if (done)
            break;

        bool occluded;
        if (!Renderer_BeginFrame(&occluded))
        {
            ::Sleep(10);
            continue;
        }

        UI_Render();

        Renderer_EndFrame();
        Renderer_ClearAndPresent();
    }

    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    UI_Shutdown();

    Renderer_Shutdown();
    ::DestroyWindow(hwnd);

    WNDCLASSEXW wc = { sizeof(wc) };
    if (GetClassInfoExW(GetModuleHandle(nullptr), L"AntiZapret", &wc))
        ::UnregisterClassW(wc.lpszClassName, wc.hInstance);

    if (mutex)
        ::CloseHandle(mutex);

    return 0;
}
