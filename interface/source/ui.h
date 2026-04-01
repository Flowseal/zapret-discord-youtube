#pragma once

#include <string>
#include <vector>

void UI_Init(float dpiScale, bool startupFromAutostart = false);
void UI_Shutdown();
void UI_Render();

// API for tray actions.
std::vector<std::string> UI_GetStrategiesForTray();
std::string UI_GetActiveStrategyForTray();
bool UI_IsStrategyRunningForTray();
void UI_LaunchStrategyFromTray(const std::string& strategyName);
void UI_StopStrategyFromTray();
bool UI_IsTelegramProxyRunningForTray();
void UI_StartTgFixFromTray();
void UI_StopTgFixFromTray();
