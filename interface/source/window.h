#pragma once

#include <windows.h>

HWND Window_Create(int width, int height);
void Window_SetHandle(HWND hwnd);
HWND Window_GetHandle();
void Window_SetMinSize(int minWidth, int minHeight);
