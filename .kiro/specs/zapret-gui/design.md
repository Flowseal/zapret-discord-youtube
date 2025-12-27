# Design Document: Zapret GUI

## Overview

PowerShell + WPF графический интерфейс для zapret-discord-youtube. Один файл `zapret-gui.ps1`, который заменяет консольное меню `service.bat` на современное окно с кнопками и переключателями. Использует встроенные возможности Windows без внешних зависимостей.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     zapret-gui.ps1                          │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   WPF UI    │  │   Logic     │  │   Service Manager   │  │
│  │   Layer     │◄─┤   Layer     │◄─┤   (sc, net stop)    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│         │                │                    │             │
│         ▼                ▼                    ▼             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  XAML UI    │  │  Status     │  │   Existing .bat     │  │
│  │  Definition │  │  Detection  │  │   files (strategies)│  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Принцип работы:**
- GUI вызывает те же команды, что и service.bat (sc, net stop, reg query)
- Не дублирует логику — переиспользует существующие bat-файлы
- Статус определяется через sc query и tasklist

## Components and Interfaces

### 1. Main Window (XAML)

```
┌──────────────────────────────────────────────────────────┐
│  ⚡ Zapret GUI v1.9.1                              [─][×] │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  ┌─ Status ────────────────────────────────────────────┐ │
│  │  Zapret Service:    ● Running (general ALT3)        │ │
│  │  WinDivert:         ● Running                       │ │
│  │  Bypass Process:    ● Active                        │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ Actions ───────────────────────────────────────────┐ │
│  │  Strategy: [general (ALT3).bat        ▼]            │ │
│  │                                                     │ │
│  │  [  Install Service  ]  [  Remove Services  ]       │ │
│  │  [  Run Diagnostics  ]  [    Run Tests      ]       │ │
│  │  [  Check Updates    ]  [     Refresh       ]       │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ Settings ──────────────────────────────────────────┐ │
│  │  Game Filter:     [OFF]  ←→  [ON]                   │ │
│  │  Auto Updates:    [OFF]  ←→  [ON]                   │ │
│  │  IPset Mode:      [ none | any | loaded ]           │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ Log ───────────────────────────────────────────────┐ │
│  │  [16:42:15] Service installed successfully          │ │
│  │  [16:42:16] Zapret is now running                   │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### 2. Core Functions

```powershell
# Status Detection
function Get-ZapretStatus { }      # Returns: Running/Stopped/NotInstalled
function Get-WinDivertStatus { }   # Returns: Running/Stopped/NotInstalled  
function Get-BypassProcessStatus { } # Returns: Active/Inactive
function Get-InstalledStrategy { }  # Returns: strategy name or $null

# Service Management
function Install-ZapretService { param($StrategyFile) }
function Remove-ZapretServices { }

# Settings
function Get-GameFilterStatus { }   # Returns: enabled/disabled
function Set-GameFilter { param($Enabled) }
function Get-IPsetMode { }          # Returns: none/any/loaded
function Set-IPsetMode { param($Mode) }

# Utilities
function Get-AvailableStrategies { } # Returns: array of .bat files
function Invoke-Diagnostics { }      # Returns: array of diagnostic results
function Test-NewVersionAvailable { } # Returns: $true/$false + version info
```

## Data Models

### StatusInfo
```powershell
class StatusInfo {
    [string]$ZapretService      # Running/Stopped/NotInstalled
    [string]$WinDivertService   # Running/Stopped/NotInstalled
    [string]$BypassProcess      # Active/Inactive
    [string]$InstalledStrategy  # Strategy name or empty
}
```

### DiagnosticResult
```powershell
class DiagnosticResult {
    [string]$CheckName          # e.g., "Base Filtering Engine"
    [string]$Status             # OK/Warning/Error
    [string]$Message            # Description
    [string]$HelpUrl            # Optional link to issue
}
```

### Settings
```powershell
class Settings {
    [bool]$GameFilterEnabled
    [bool]$AutoUpdateEnabled
    [string]$IPsetMode          # none/any/loaded
}
```

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system—essentially, a formal statement about what the system should do.*

### Property 1: Service Status Detection Consistency

*For any* Windows service state (Running, Stopped, or not installed), the `Get-ZapretStatus` and `Get-WinDivertStatus` functions SHALL return exactly one of three valid states: "Running", "Stopped", or "NotInstalled".

**Validates: Requirements 1.3, 4.1, 4.2**

### Property 2: Strategy Enumeration Completeness

*For any* directory containing .bat files, the `Get-AvailableStrategies` function SHALL return all .bat files except those starting with "service", and the count SHALL equal the actual count of matching files.

**Validates: Requirements 2.1**

### Property 3: Game Filter Toggle Consistency

*For any* toggle action on Game Filter, if the flag file exists before toggle, it SHALL not exist after toggle, and vice versa. The function SHALL be idempotent when called twice.

**Validates: Requirements 6.2**

### Property 4: IPset Mode Cycling

*For any* current IPset mode, calling `Set-IPsetMode` with "next" SHALL cycle through states in order: none → any → loaded → none. The cycle SHALL be deterministic and complete.

**Validates: Requirements 6.3**

### Property 5: Version Comparison Correctness

*For any* two semantic version strings (X.Y.Z format), the version comparison function SHALL correctly determine if version A is greater than, equal to, or less than version B.

**Validates: Requirements 7.2**

### Property 6: Diagnostic Color Mapping

*For any* diagnostic result status (OK, Warning, Error), the color mapping function SHALL return exactly one color: Green for OK, Yellow for Warning, Red for Error.

**Validates: Requirements 5.2**

## Error Handling

| Error | Handling |
|-------|----------|
| Not running as admin | Show elevation prompt, restart with RunAs |
| Service install fails | Show error in log, keep UI responsive |
| Network timeout (updates) | Show warning, allow retry |
| Missing bin folder | Show error, disable Install button |
| Strategy file not found | Remove from dropdown, log warning |

## Testing Strategy

### Unit Tests (Pester)
- Test status detection functions with mocked sc query output
- Test version comparison with various version strings
- Test IPset mode cycling logic
- Test strategy enumeration with test directory

### Property-Based Tests (Pester + custom generators)
- Generate random service states, verify detection consistency
- Generate random version pairs, verify comparison correctness
- Test toggle idempotency with random initial states

### Integration Tests
- Manual testing of service install/remove (requires admin)
- Visual verification of UI layout and colors

**Test Framework:** Pester (built into PowerShell)
**Minimum iterations for property tests:** 100
