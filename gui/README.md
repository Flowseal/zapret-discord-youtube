# Zapret GUI

Modern WPF-based graphical interface for zapret-discord-youtube.

## Launch

Double-click `gui.bat` in the root folder, or run:
```
cscript //nologo gui\launch.vbs
```

## Structure

```
gui/
├── launch.vbs          # VBS launcher (hides PowerShell console)
├── README.md           # This file
└── src/
    ├── main.ps1        # Entry point
    ├── config.ps1      # Configuration and paths
    ├── services.ps1    # Service management (install/remove)
    ├── settings.ps1    # Settings toggles (Game Filter, IPset, etc.)
    ├── diagnostics.ps1 # System diagnostics
    ├── updates.ps1     # Update checking
    └── ui/
        ├── theme.ps1   # Color theme and helpers
        ├── xaml.ps1    # XAML window definition
        └── dialogs.ps1 # Custom dialog windows
```

## Features

- Service installation/removal
- Strategy selection
- Status monitoring
- Diagnostics
- Settings management
- Update checking
- Custom black & white design

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator privileges

## Credits

Design by [ibuildrun](https://github.com/ibuildrun)

---

# Zapret GUI (RU)

Современный графический интерфейс на WPF для zapret-discord-youtube.

## Запуск

Дважды кликните на `gui.bat` в корневой папке, или выполните:
```
cscript //nologo gui\launch.vbs
```

## Структура

```
gui/
├── launch.vbs          # VBS лаунчер (скрывает консоль PowerShell)
├── README.md           # Этот файл
└── src/
    ├── main.ps1        # Точка входа
    ├── config.ps1      # Конфигурация и пути
    ├── services.ps1    # Управление службами (установка/удаление)
    ├── settings.ps1    # Переключатели настроек (Game Filter, IPset и др.)
    ├── diagnostics.ps1 # Диагностика системы
    ├── updates.ps1     # Проверка обновлений
    └── ui/
        ├── theme.ps1   # Цветовая тема и хелперы
        ├── xaml.ps1    # XAML разметка окна
        └── dialogs.ps1 # Кастомные диалоговые окна
```

## Возможности

- Установка/удаление службы
- Выбор стратегии обхода
- Мониторинг статуса
- Диагностика системы
- Управление настройками
- Проверка обновлений
- Кастомный чёрно-белый дизайн

## Требования

- Windows 10/11
- PowerShell 5.1+
- Права администратора

## Авторы

Дизайн: [ibuildrun](https://github.com/ibuildrun)
