# zapret-discord-youtube UI

## Стек

- UI: WPF, .NET 8 (`net8.0-windows`), self-contained single-file `win-x64`
- Ядро обхода: существующий пак Flowseal (`winws.exe` + WinDivert), без своего DPI-движка
- Пак лежит в `zapret-discord-youtube-UI/`

## Архитектура

`ZapretUi.exe` — тонкий контроллер: парсит `general*.bat`, стартует/останавливает `winws`, ставит службу `zapret`, гоняет HTTPS-smoke по стратегиям.

Корень пака: рядом с exe (`bin\winws.exe`) или каталог `zapret-discord-youtube-UI` при отладке.

## Именование

- C#: PascalCase типы/методы, `_camelCase` поля
- Проект: `src/ZapretUi`
- Стратегии: имя файла `.bat` без расширения
