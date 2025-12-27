# Requirements Document

## Introduction

GUI-обёртка для zapret-discord-youtube — графический интерфейс на PowerShell + WPF, который заменяет консольное меню service.bat на удобное окно с кнопками. Цель — упростить использование zapret для обычных пользователей без потери функциональности.

## Glossary

- **GUI**: Графический интерфейс пользователя (Graphical User Interface)
- **Strategy**: Bat-файл со стратегией обхода блокировок (general.bat, general (ALT).bat и т.д.)
- **Service**: Windows-служба zapret, работающая в фоне
- **WinDivert**: Драйвер для перехвата сетевого трафика
- **IPset**: Список IP-адресов для фильтрации

## Requirements

### Requirement 1: Запуск GUI

**User Story:** As a user, I want to launch a graphical interface instead of console menu, so that I can manage zapret more conveniently.

#### Acceptance Criteria

1. WHEN the user runs zapret-gui.ps1, THE GUI SHALL display a window with all main functions
2. WHEN the GUI starts, THE System SHALL request administrator privileges if not already elevated
3. WHEN the GUI loads, THE System SHALL detect current zapret status (running/stopped)

### Requirement 2: Установка стратегии

**User Story:** As a user, I want to select and install a bypass strategy, so that I can enable zapret with my preferred configuration.

#### Acceptance Criteria

1. WHEN the user clicks "Install Service", THE GUI SHALL display a dropdown list of available strategies
2. WHEN the user selects a strategy and confirms, THE System SHALL install it as a Windows service
3. WHEN installation completes, THE GUI SHALL show success/error message
4. THE GUI SHALL display the currently installed strategy name

### Requirement 3: Удаление служб

**User Story:** As a user, I want to remove zapret services, so that I can stop the bypass or reinstall with different settings.

#### Acceptance Criteria

1. WHEN the user clicks "Remove Services", THE System SHALL stop and remove zapret service
2. WHEN removal completes, THE System SHALL also remove WinDivert service if present
3. WHEN removal completes, THE GUI SHALL update status display

### Requirement 4: Проверка статуса

**User Story:** As a user, I want to see the current status of zapret, so that I know if bypass is working.

#### Acceptance Criteria

1. THE GUI SHALL display current status of zapret service (Running/Stopped/Not installed)
2. THE GUI SHALL display current status of WinDivert service
3. THE GUI SHALL display whether winws.exe process is running
4. WHEN the user clicks "Refresh", THE GUI SHALL update all status indicators

### Requirement 5: Диагностика

**User Story:** As a user, I want to run diagnostics, so that I can identify and fix problems.

#### Acceptance Criteria

1. WHEN the user clicks "Run Diagnostics", THE System SHALL check for common issues
2. THE GUI SHALL display diagnostic results with color coding (green=OK, yellow=warning, red=error)
3. THE GUI SHALL offer to clear Discord cache if issues detected

### Requirement 6: Переключатели настроек

**User Story:** As a user, I want to toggle settings like Game Filter and IPset mode, so that I can customize bypass behavior.

#### Acceptance Criteria

1. THE GUI SHALL display toggle switches for: Game Filter, Auto-update check, IPset mode
2. WHEN the user toggles Game Filter, THE System SHALL enable/disable game port filtering
3. WHEN the user toggles IPset mode, THE System SHALL cycle through: none → any → loaded
4. WHEN settings change, THE GUI SHALL indicate that restart is required

### Requirement 7: Обновления

**User Story:** As a user, I want to check for updates, so that I can keep zapret current.

#### Acceptance Criteria

1. WHEN the user clicks "Check Updates", THE System SHALL fetch latest version from GitHub
2. IF new version available, THE GUI SHALL display version info and download link
3. THE GUI SHALL offer to open download page automatically

### Requirement 8: Тестирование стратегий

**User Story:** As a user, I want to run strategy tests, so that I can find the best working configuration.

#### Acceptance Criteria

1. WHEN the user clicks "Run Tests", THE System SHALL launch the PowerShell test utility
2. THE GUI SHALL display test progress or open separate test window

### Requirement 9: Визуальный дизайн

**User Story:** As a user, I want a modern dark-themed interface, so that it looks professional and matches Discord aesthetic.

#### Acceptance Criteria

1. THE GUI SHALL use dark color scheme (dark background, light text)
2. THE GUI SHALL use accent colors matching Discord (blurple #5865F2)
3. THE GUI SHALL have clear visual hierarchy with grouped controls
4. THE GUI SHALL be responsive and not freeze during operations
