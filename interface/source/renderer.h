#pragma once

#include <windows.h>

struct ID3D11Device;
struct ID3D11DeviceContext;
struct IDXGISwapChain;
struct ID3D11RenderTargetView;

bool Renderer_Init(HWND hwnd);
void Renderer_Shutdown();
void Renderer_OnResize(UINT width, UINT height);
void Renderer_CreateTarget();
void Renderer_CleanupTarget();

bool Renderer_BeginFrame(bool* outOccluded);
void Renderer_EndFrame();
void Renderer_ClearAndPresent();

ID3D11Device* Renderer_GetDevice();
ID3D11DeviceContext* Renderer_GetContext();
ID3D11RenderTargetView* Renderer_GetMainTarget();
