-- AntiZapret interface: x86 only, bin/ output, build/ intermediates
-- premake сразу генерирует .vcxproj в build/, .sln в корне — без патчей в bat

workspace "AntiZapret"
    location "."
    configurations { "Debug", "Release" }
    platforms { "Win32" }

    filter "platforms:Win32"
        architecture "x86"

project "AntiZapret"
    location "build"
    targetdir "bin"
    objdir "build/%{cfg.platform}_%{cfg.buildcfg}"

    kind "WindowedApp"
    language "C++"
    cppdialect "C++17"
    staticruntime "On"
    -- GitHub Actions windows-latest provides v143 toolchain
    toolset "v143"

    files {
        "source/**.cpp",
        "source/**.h",
        "app.rc",
        "vendor/imgui-1.92.6/imgui.cpp",
        "vendor/imgui-1.92.6/imgui_draw.cpp",
        "vendor/imgui-1.92.6/imgui_tables.cpp",
        "vendor/imgui-1.92.6/imgui_widgets.cpp",
        "vendor/imgui-1.92.6/imgui_demo.cpp",
        "vendor/imgui-1.92.6/backends/imgui_impl_win32.cpp",
        "vendor/imgui-1.92.6/backends/imgui_impl_dx11.cpp",
    }

    includedirs {
        "source",
        "vendor/imgui-1.92.6",
        "vendor/imgui-1.92.6/backends",
    }

    links { "d3d11.lib", "dxgi.lib", "dwmapi.lib" }

    -- GUI app entry point (no console)
    linkoptions { "/ENTRY:mainCRTStartup" }

    -- Exe при запуске требует права администратора (UAC)
    linkoptions { "/MANIFESTUAC:level='requireAdministrator'" }

    -- Исходники в UTF-8 для корректного отображения кириллицы
    buildoptions { "/utf-8" }

    filter "configurations:Debug"
        symbols "On"
        runtime "Debug"
        targetname "AntiZapret_d"

    filter "configurations:Release"
        optimize "On"
        runtime "Release"
        targetname "AntiZapret"

