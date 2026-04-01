# AntiZapret Interface

## Русский

Десктопное приложение с интерфейсом на базе Dear ImGui и DirectX 11.

### Зависимость ImGui

Проект использует `imgui-1.92.6` как **git submodule**:

- путь: `vendor/imgui-1.92.6`
- репозиторий: [Dear ImGui v1.92.6](https://github.com/ocornut/imgui/tree/v1.92.6)

На GitHub такая папка отображается как ссылка (gitlink), а не как набор файлов в основном репозитории.

### Локальная сборка

1. Инициализируй submodule:
   `git submodule add -b v1.92.6 https://github.com/ocornut/imgui.git vendor/imgui-1.92.6`
2. Клонируй с submodules (на новых машинах):
   `git clone --recurse-submodules <your-repo-url>`
3. Запусти `win-install-project.bat`.
4. Открой `AntiZapret.sln`.
5. Собери `Release | Win32`.

### Сборка в GitHub Actions

Файл workflow: `.github/workflows/build.yml`

При каждом push/PR GitHub Actions:

1. подтягивает submodules (включая `imgui-1.92.6`)
2. генерирует solution через `premake5.exe`
3. собирает `Release | Win32`
4. загружает `.exe` как artifact

---

## English

Desktop application with a UI based on Dear ImGui and DirectX 11.

### ImGui dependency

The project uses `imgui-1.92.6` as a **git submodule**:

- path: `vendor/imgui-1.92.6`
- source: [Dear ImGui v1.92.6](https://github.com/ocornut/imgui/tree/v1.92.6)

On GitHub, this path is shown as a link (gitlink), not as vendored files in the main repository.

### Local build

1. Initialize the submodule:
   `git submodule add -b v1.92.6 https://github.com/ocornut/imgui.git vendor/imgui-1.92.6`
2. Clone with submodules (on new machines):
   `git clone --recurse-submodules <your-repo-url>`
3. Run `win-install-project.bat`.
4. Open `AntiZapret.sln`.
5. Build `Release | Win32`.

### GitHub Actions build

Workflow file: `.github/workflows/build.yml`

On every push/PR, GitHub Actions:

1. fetches submodules (including `imgui-1.92.6`)
2. generates the solution via `premake5.exe`
3. builds `Release | Win32`
4. uploads the `.exe` artifact

