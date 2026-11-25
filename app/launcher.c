#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <shellapi.h>
#include <strsafe.h>
#include <wchar.h>

#include "embedded_script.h"

#define PATH_CAPACITY 32768
#define TEMP_FOLDER_NAME L"ZapretManager"

static BOOL file_exists(const wchar_t *path)
{
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

static BOOL path_has_zapret(const wchar_t *folder)
{
    wchar_t candidate[PATH_CAPACITY];
    if (FAILED(StringCchPrintfW(candidate, PATH_CAPACITY, L"%ls\\bin\\winws.exe", folder))) {
        return FALSE;
    }
    return file_exists(candidate);
}

static BOOL resolve_root(wchar_t *root, size_t root_capacity)
{
    wchar_t executable[PATH_CAPACITY];
    DWORD length = GetModuleFileNameW(NULL, executable, PATH_CAPACITY);
    if (length == 0 || length >= PATH_CAPACITY) {
        return FALSE;
    }

    wchar_t *slash = wcsrchr(executable, L'\\');
    if (slash == NULL) {
        return FALSE;
    }
    *slash = L'\0';

    /* Accept the EXE either in the repo root or in its app subfolder. */
    if (path_has_zapret(executable)) {
        return SUCCEEDED(StringCchCopyW(root, root_capacity, executable));
    }

    slash = wcsrchr(executable, L'\\');
    if (slash == NULL) {
        return FALSE;
    }
    *slash = L'\0';
    if (!path_has_zapret(executable)) {
        return FALSE;
    }
    return SUCCEEDED(StringCchCopyW(root, root_capacity, executable));
}

static BOOL write_embedded_script(wchar_t *script_path, size_t script_path_capacity, HANDLE *script_lock)
{
    *script_lock = INVALID_HANDLE_VALUE;
    wchar_t temp_path[PATH_CAPACITY];
    DWORD temp_length = GetTempPathW(PATH_CAPACITY, temp_path);
    if (temp_length == 0 || temp_length >= PATH_CAPACITY) {
        return FALSE;
    }
    if (temp_path[temp_length - 1] == L'\\' || temp_path[temp_length - 1] == L'/') {
        temp_path[temp_length - 1] = L'\0';
    }

    wchar_t temp_folder[PATH_CAPACITY];
    if (FAILED(StringCchPrintfW(temp_folder, PATH_CAPACITY, L"%ls\\%ls", temp_path, TEMP_FOLDER_NAME))) {
        return FALSE;
    }
    if (!CreateDirectoryW(temp_folder, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
        return FALSE;
    }

    DWORD tick = GetTickCount();
    if (FAILED(StringCchPrintfW(
            script_path,
            script_path_capacity,
            L"%ls\\ZapretManager-%lu-%lu.ps1",
            temp_folder,
            GetCurrentProcessId(),
            tick))) {
        return FALSE;
    }

    HANDLE output = CreateFileW(
        script_path,
        GENERIC_WRITE,
        0,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_TEMPORARY | FILE_ATTRIBUTE_HIDDEN,
        NULL);
    if (output == INVALID_HANDLE_VALUE) {
        return FALSE;
    }

    DWORD bytes_written = 0;
    BOOL ok = WriteFile(output, embedded_script, (DWORD)sizeof(embedded_script), &bytes_written, NULL);
    if (ok && bytes_written == (DWORD)sizeof(embedded_script)) {
        ok = FlushFileBuffers(output);
    } else {
        ok = FALSE;
    }
    CloseHandle(output);

    if (!ok) {
        DeleteFileW(script_path);
        return FALSE;
    }

    /* Hold a read-only, read-share handle until PowerShell exits so the
       elevated process cannot be tricked into executing a swapped temp file. */
    *script_lock = CreateFileW(
        script_path,
        GENERIC_READ,
        FILE_SHARE_READ,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_TEMPORARY | FILE_ATTRIBUTE_HIDDEN,
        NULL);
    if (*script_lock == INVALID_HANDLE_VALUE) {
        DeleteFileW(script_path);
        return FALSE;
    }
    return TRUE;
}

static void cleanup_embedded_script(const wchar_t *script_path, HANDLE *script_lock)
{
    if (*script_lock != INVALID_HANDLE_VALUE) {
        CloseHandle(*script_lock);
        *script_lock = INVALID_HANDLE_VALUE;
    }
    DeleteFileW(script_path);
}

static void show_error(const wchar_t *text)
{
    MessageBoxW(NULL, text, L"Zapret Manager", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command_line, int show_command)
{
    (void)instance;
    (void)previous;
    (void)command_line;
    (void)show_command;

    wchar_t root[PATH_CAPACITY];
    if (!resolve_root(root, PATH_CAPACITY)) {
        show_error(L"Не найдена папка Zapret. Поместите ZapretManager.exe в app\\ рядом с bin\\winws.exe и general*.bat.");
        return 2;
    }

    wchar_t script_path[PATH_CAPACITY];
    HANDLE script_lock = INVALID_HANDLE_VALUE;
    if (!write_embedded_script(script_path, PATH_CAPACITY, &script_lock)) {
        show_error(L"Не удалось подготовить встроенный интерфейс во временной папке. Проверьте доступ к %TEMP%.");
        return 3;
    }

    wchar_t system_directory[PATH_CAPACITY];
    UINT system_length = GetSystemDirectoryW(system_directory, PATH_CAPACITY);
    if (system_length == 0 || system_length >= PATH_CAPACITY) {
        cleanup_embedded_script(script_path, &script_lock);
        show_error(L"Не удалось найти системную папку Windows.");
        return 4;
    }

    wchar_t powershell_path[PATH_CAPACITY];
    if (FAILED(StringCchPrintfW(
            powershell_path,
            PATH_CAPACITY,
            L"%ls\\WindowsPowerShell\\v1.0\\powershell.exe",
            system_directory))) {
        cleanup_embedded_script(script_path, &script_lock);
        show_error(L"Не удалось сформировать путь к Windows PowerShell.");
        return 5;
    }
    if (!file_exists(powershell_path)) {
        cleanup_embedded_script(script_path, &script_lock);
        show_error(L"Windows PowerShell 5.1 не найден. Для этого приложения требуется Windows 10 или 11.");
        return 6;
    }

    wchar_t parameters[PATH_CAPACITY];
    if (FAILED(StringCchPrintfW(
            parameters,
            PATH_CAPACITY,
            L"-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"%ls\" -RootPath \"%ls\"",
            script_path,
            root))) {
        cleanup_embedded_script(script_path, &script_lock);
        show_error(L"Не удалось сформировать параметры запуска.");
        return 7;
    }

    SHELLEXECUTEINFOW execute_info;
    ZeroMemory(&execute_info, sizeof(execute_info));
    execute_info.cbSize = sizeof(execute_info);
    execute_info.fMask = SEE_MASK_NOCLOSEPROCESS;
    execute_info.lpVerb = L"runas";
    execute_info.lpFile = powershell_path;
    execute_info.lpParameters = parameters;
    execute_info.lpDirectory = root;
    execute_info.nShow = SW_HIDE;

    if (!ShellExecuteExW(&execute_info)) {
        DWORD error = GetLastError();
        cleanup_embedded_script(script_path, &script_lock);
        if (error == ERROR_CANCELLED) {
            return 0;
        }
        wchar_t message[256];
        StringCchPrintfW(message, 256, L"Не удалось запустить Windows PowerShell (код ошибки %lu).", error);
        show_error(message);
        return 8;
    }

    if (execute_info.hProcess != NULL) {
        WaitForSingleObject(execute_info.hProcess, INFINITE);
        CloseHandle(execute_info.hProcess);
        cleanup_embedded_script(script_path, &script_lock);
    } else if (script_lock != INVALID_HANDLE_VALUE) {
        /* If ShellExecuteEx did not return a process handle, leave the temp
           script in place for PowerShell to open after this process exits. */
        CloseHandle(script_lock);
    }
    return 0;
}
