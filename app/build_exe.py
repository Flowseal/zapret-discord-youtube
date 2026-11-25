#!/usr/bin/env python3
"""Build the single-file x64 Windows launcher, embedding ZapretManager.ps1."""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
SCRIPT = APP_DIR / "ZapretManager.ps1"
SOURCE = APP_DIR / "launcher.c"
OUTPUT = APP_DIR / "ZapretManager.exe"


def zig_prefix() -> list[str]:
    zig = shutil.which("zig")
    if zig:
        return [zig]
    if importlib.util.find_spec("ziglang") is not None:
        return [sys.executable, "-m", "ziglang"]
    raise SystemExit(
        "Zig was not found. Install Zig 0.13+ or run: "
        "python -m pip install ziglang==0.13.0"
    )


def make_header(script_bytes: bytes) -> str:
    rows = []
    for offset in range(0, len(script_bytes), 16):
        rows.append("    " + ", ".join(f"0x{byte:02x}" for byte in script_bytes[offset : offset + 16]) + ",")
    return (
        "/* Generated from ZapretManager.ps1 by build_exe.py. */\n"
        "#ifndef ZAPRET_MANAGER_EMBEDDED_SCRIPT_H\n"
        "#define ZAPRET_MANAGER_EMBEDDED_SCRIPT_H\n"
        "static const unsigned char embedded_script[] = {\n"
        + "\n".join(rows)
        + "\n};\n"
        "#endif\n"
    )


def main() -> int:
    if not SCRIPT.is_file() or not SOURCE.is_file():
        raise SystemExit("ZapretManager.ps1 or launcher.c is missing.")

    # Keep the PowerShell BOM: Windows PowerShell 5.1 uses it to decode UTF-8 UI text.
    script_bytes = SCRIPT.read_bytes()
    if not script_bytes.startswith(b"\xef\xbb\xbf"):
        raise SystemExit("ZapretManager.ps1 must be saved as UTF-8 with BOM.")

    with tempfile.TemporaryDirectory(prefix="zapret-manager-build-") as build_dir:
        build_path = Path(build_dir)
        (build_path / "embedded_script.h").write_text(make_header(script_bytes), encoding="ascii")
        command = zig_prefix() + [
            "cc",
            "-target",
            "x86_64-windows-gnu",
            "-O2",
            "-g0",
            "-Wall",
            "-Wextra",
            "-Wl,/subsystem:windows",
            "-I",
            str(build_path),
            str(SOURCE),
            "-o",
            str(OUTPUT),
            "-lshell32",
            "-luser32",
        ]
        print("Building x64 Windows GUI executable…")
        subprocess.run(command, check=True)

    print(f"Created: {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
