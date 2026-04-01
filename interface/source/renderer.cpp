#include "renderer.h"
#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx11.h"
#include <d3d11.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

static ID3D11Device* g_device = nullptr;
static ID3D11DeviceContext* g_context = nullptr;
static IDXGISwapChain* g_swapChain = nullptr;
static ID3D11RenderTargetView* g_mainTarget = nullptr;
static bool g_occluded = false;
static UINT g_resizeW = 0, g_resizeH = 0;

bool Renderer_Init(HWND hwnd)
{
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.SampleDesc.Quality = 0;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    D3D_FEATURE_LEVEL featureLevel;
    const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        levels, 2, D3D11_SDK_VERSION,
        &sd, &g_swapChain, &g_device, &featureLevel, &g_context
    );
    if (hr == DXGI_ERROR_UNSUPPORTED)
        hr = D3D11CreateDeviceAndSwapChain(
            nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0,
            levels, 2, D3D11_SDK_VERSION,
            &sd, &g_swapChain, &g_device, &featureLevel, &g_context
        );
    if (hr != S_OK)
        return false;

    Renderer_CreateTarget();
    return true;
}

void Renderer_Shutdown()
{
    Renderer_CleanupTarget();
    if (g_swapChain) { g_swapChain->Release(); g_swapChain = nullptr; }
    if (g_context) { g_context->Release(); g_context = nullptr; }
    if (g_device) { g_device->Release(); g_device = nullptr; }
}

void Renderer_OnResize(UINT width, UINT height)
{
    g_resizeW = width;
    g_resizeH = height;
}

void Renderer_CreateTarget()
{
    if (!g_swapChain) return;
    ID3D11Texture2D* backBuffer = nullptr;
    g_swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
    if (backBuffer)
    {
        g_device->CreateRenderTargetView(backBuffer, nullptr, &g_mainTarget);
        backBuffer->Release();
    }
}

void Renderer_CleanupTarget()
{
    if (g_mainTarget) { g_mainTarget->Release(); g_mainTarget = nullptr; }
}

bool Renderer_BeginFrame(bool* outOccluded)
{
    if (g_occluded && g_swapChain->Present(0, DXGI_PRESENT_TEST) == DXGI_STATUS_OCCLUDED)
    {
        *outOccluded = true;
        return false;
    }
    g_occluded = false;
    *outOccluded = false;

    if (g_resizeW != 0 && g_resizeH != 0)
    {
        Renderer_CleanupTarget();
        g_swapChain->ResizeBuffers(0, g_resizeW, g_resizeH, DXGI_FORMAT_UNKNOWN, 0);
        g_resizeW = g_resizeH = 0;
        Renderer_CreateTarget();
    }

    ImGui_ImplDX11_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    return true;
}

void Renderer_EndFrame()
{
    ImGui::Render();
}

void Renderer_ClearAndPresent()
{
    const float clear[4] = { 0.08f, 0.08f, 0.10f, 1.0f };
    g_context->OMSetRenderTargets(1, &g_mainTarget, nullptr);
    g_context->ClearRenderTargetView(g_mainTarget, clear);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());

    HRESULT hr = g_swapChain->Present(1, 0);
    g_occluded = (hr == DXGI_STATUS_OCCLUDED);
}

ID3D11Device* Renderer_GetDevice()
{
    return g_device;
}

ID3D11DeviceContext* Renderer_GetContext()
{
    return g_context;
}

ID3D11RenderTargetView* Renderer_GetMainTarget()
{
    return g_mainTarget;
}
