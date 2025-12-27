# Implementation Plan: Zapret GUI

## Overview

Создание PowerShell + WPF графического интерфейса для zapret-discord-youtube. Один файл zapret-gui.ps1, который заменяет консольное меню service.bat.

## Tasks

- [x] 1. Создать базовую структуру и WPF окно
  - [x] 1.1 Создать файл zapret-gui.ps1 с XAML-разметкой главного окна
    - Определить тёмную цветовую схему (#1e1e2e фон, #cdd6f4 текст, #5865F2 акцент)
    - Создать базовый layout с секциями: Status, Actions, Settings, Log
    - _Requirements: 9.1, 9.2, 9.3_
  - [x] 1.2 Добавить проверку и запрос прав администратора
    - Проверить текущие права через [Security.Principal.WindowsPrincipal]
    - Перезапустить с -Verb RunAs если нужно
    - _Requirements: 1.2_

- [x] 2. Реализовать функции определения статуса
  - [x] 2.1 Реализовать Get-ZapretStatus и Get-WinDivertStatus
    - Использовать sc query для проверки состояния служб
    - Возвращать Running/Stopped/NotInstalled
    - _Requirements: 1.3, 4.1, 4.2_
  - [x] 2.2 Реализовать Get-BypassProcessStatus
    - Использовать Get-Process для проверки winws.exe
    - _Requirements: 4.3_
  - [x] 2.3 Реализовать Get-InstalledStrategy
    - Читать из реестра HKLM\System\CurrentControlSet\Services\zapret
    - _Requirements: 2.4_
  - [ ]* 2.4 Написать property-тест для Status Detection Consistency
    - **Property 1: Service Status Detection Consistency**
    - **Validates: Requirements 1.3, 4.1, 4.2**

- [x] 3. Реализовать управление стратегиями
  - [x] 3.1 Реализовать Get-AvailableStrategies
    - Найти все .bat файлы кроме service*.bat
    - Заполнить ComboBox стратегиями
    - _Requirements: 2.1_
  - [ ]* 3.2 Написать property-тест для Strategy Enumeration
    - **Property 2: Strategy Enumeration Completeness**
    - **Validates: Requirements 2.1**
  - [x] 3.3 Реализовать Install-ZapretService
    - Парсить выбранный .bat файл для извлечения аргументов winws.exe
    - Создать службу через sc create
    - _Requirements: 2.2, 2.3_
  - [x] 3.4 Реализовать Remove-ZapretServices
    - Остановить и удалить zapret, WinDivert, WinDivert14
    - _Requirements: 3.1, 3.2, 3.3_

- [x] 4. Checkpoint - Проверить базовый функционал
  - Убедиться что окно открывается, статус отображается, службы устанавливаются/удаляются
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. Реализовать настройки (Settings)
  - [x] 5.1 Реализовать Game Filter toggle
    - Создавать/удалять файл utils\game_filter.enabled
    - _Requirements: 6.2_
  - [ ]* 5.2 Написать property-тест для Game Filter Toggle
    - **Property 3: Game Filter Toggle Consistency**
    - **Validates: Requirements 6.2**
  - [x] 5.3 Реализовать IPset Mode cycling
    - Переключать между none/any/loaded
    - Управлять файлами ipset-all.txt и ipset-all.txt.backup
    - _Requirements: 6.3_
  - [ ]* 5.4 Написать property-тест для IPset Mode Cycling
    - **Property 4: IPset Mode Cycling**
    - **Validates: Requirements 6.3**
  - [x] 5.5 Реализовать Auto Updates toggle
    - Создавать/удалять файл utils\check_updates.enabled
    - _Requirements: 6.1_

- [x] 6. Реализовать диагностику
  - [x] 6.1 Реализовать Invoke-Diagnostics
    - Проверить: BFE, Proxy, TCP timestamps, Adguard, Killer, Intel, CheckPoint, SmartByte, VPN, DNS
    - Возвращать массив DiagnosticResult
    - _Requirements: 5.1_
  - [x] 6.2 Реализовать отображение результатов с цветовой индикацией
    - Green для OK, Yellow для Warning, Red для Error
    - _Requirements: 5.2_
  - [ ]* 6.3 Написать property-тест для Diagnostic Color Mapping
    - **Property 6: Diagnostic Color Mapping**
    - **Validates: Requirements 5.2**
  - [x] 6.4 Добавить кнопку очистки кэша Discord
    - _Requirements: 5.3_

- [x] 7. Реализовать проверку обновлений
  - [x] 7.1 Реализовать Test-NewVersionAvailable
    - Загрузить version.txt с GitHub
    - Сравнить с LOCAL_VERSION
    - _Requirements: 7.1_
  - [ ]* 7.2 Написать property-тест для Version Comparison
    - **Property 5: Version Comparison Correctness**
    - **Validates: Requirements 7.2**
  - [x] 7.3 Реализовать UI для отображения информации об обновлении
    - Показать версию и кнопку скачивания
    - _Requirements: 7.2, 7.3_

- [x] 8. Реализовать запуск тестов
  - [x] 8.1 Добавить кнопку Run Tests
    - Запустить utils\test zapret.ps1 в отдельном окне
    - _Requirements: 8.1, 8.2_

- [x] 9. Финальная полировка
  - [x] 9.1 Добавить лог-панель для отображения действий
    - Показывать timestamp и сообщения
    - _Requirements: 2.3, 3.3_
  - [x] 9.2 Реализовать кнопку Refresh
    - Обновить все индикаторы статуса
    - _Requirements: 4.4_
  - [x] 9.3 Добавить асинхронное выполнение для длительных операций
    - Использовать Dispatcher для обновления UI
    - _Requirements: 9.4_

- [x] 10. Final checkpoint - Полное тестирование
  - [x] Проверить все функции вручную
  - [x] Restructured into modular gui/ directory
  - [x] VBS launcher hides PowerShell console
  - [x] All syntax validated
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Задачи с `*` — опциональные тесты, можно пропустить для быстрого MVP
- Каждая задача ссылается на конкретные требования
- Property-тесты используют Pester (встроен в PowerShell)
- Для тестирования служб нужны права администратора
