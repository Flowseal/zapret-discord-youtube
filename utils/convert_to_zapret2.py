#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Конвертер стратегий zapret1 (nfqws1/winws) -> zapret2 (nfqws2/winws2).

Читает все general*.bat в корне репозитория (формат winws1) и ПЕРЕЗАПИСЫВАЕТ
их стратегиями в синтаксисе winws2:

  * winws.exe            -> winws2.exe
  * --wf-tcp/--wf-udp    -> --wf-tcp-out/--wf-udp-out
  * --dpi-desync=...     -> цепочки --lua-desync=<функция zapret-antidpi.lua>
  * --dpi-desync-fake-*  -> именованные блобы (--blob=<имя>:@"file") +
                            fake:blob=<имя>
  * --dpi-desync-fooling -> аргументы фулинга функций Lua (tcp_md5, tcp_ts,
                            tcp_seq/tcp_ack, badsum, tcp_flags_unset)
  * --dpi-desync-cutoff /
    --dpi-desync-any-protocol -> --out-range / --payload=all
  * fake-tls-mod         -> tls_mod=... у инстанса fake

Таблица соответствия подробно расписана в MIGRATION.md.
Скрипт идемпотентен в обратную сторону НЕ является: запускать его нужно
на git-версии файлов zapret1 (git stash / git checkout -- 'general*.bat').

Использование:  python3 utils/convert_to_zapret2.py [--check]
  --check  только показать, что получилось бы, ничего не записывая.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------- helpers

def blob_name(filename: str) -> str:
    """tls_clienthello_www_google_com.bin -> tls_clienthello_www_google_com"""
    name = filename[:-4] if filename.lower().endswith(".bin") else filename
    return re.sub(r"[^0-9a-zA-Z_]", "_", name)


def parse_tokens(text: str):
    """Разбить командную строку bat на токены с учётом кавычек."""
    return re.findall(r'"[^"]*"|\S+', text)


def unq(tok: str) -> str:
    return tok.strip('"')


def fake_ref(value: str, blobs: dict) -> str:
    """Значение --dpi-desync-fake-* -> ссылка на блоб для Lua.

    Файл  -> регистрирует --blob и возвращает имя блоба.
    0x... -> возвращает hex как есть (inline blob в zapret2).
    """
    v = unq(value)
    if v in ("!", ""):
        # nfqws1: --dpi-desync-fake-tls=! - встроенный фейк + fake-tls-mod
        return "fake_default_tls"
    if v.startswith("0x"):
        return v
    m = re.search(r"%BIN%([^%\"]+)$", v)
    fname = m.group(1) if m else Path(v).name
    name = blob_name(fname)
    blobs.setdefault(name, fname)
    return name


def fooling_args(p: dict) -> list:
    """--dpi-desync-fooling (+badseq-increment) -> аргументы функций Lua."""
    out = []
    inc = p.get("badseq-increment")
    for mode in p.get("fooling", "").split(","):
        mode = mode.strip()
        if mode == "ts":
            # nfqws1: FOOL_TS, ts_increment=-600000 по умолчанию
            out.append("tcp_ts=-600000")
        elif mode == "md5sig":
            out.append("tcp_md5")
        elif mode == "badseq":
            # nfqws1: seq += badseq_increment (-10000), ack += -66000
            out.append(f"tcp_seq={inc if inc is not None else '-10000'}")
            out.append("tcp_ack=-66000")
        elif mode == "badsum":
            out.append("badsum")
        elif mode == "datanoack":
            out.append("tcp_flags_unset=ack")
        elif mode in ("", "none"):
            pass
        else:  # hopbyhop и т.п. в наших стратегиях не встречаются
            out.append(f"fooling_{mode}")
    return out


# ---------------------------------------------------------------- profile

def convert_profile(tokens, blobs: dict) -> list:
    """Один профиль (между --new) zapret1 -> строки аргументов winws2."""
    p = {"fake-tls": [], "fake-http": [], "fake-quic": [], "fake-unknown": [],
         "fake-unknown-udp": [], "fake-discord": [], "fake-stun": []}
    filters, actions = [], []
    for tok in tokens:
        t = unq(tok)
        if t.startswith(("--filter-", "--hostlist", "--ipset")):
            filters.append(tok)
        elif t.startswith("--ip-id="):
            p["ip-id"] = t.split("=", 1)[1]
        elif t == "--dpi-desync" or t.startswith("--dpi-desync="):
            actions = t.split("=", 1)[1].split(",") if "=" in t else []
        elif t.startswith("--dpi-desync-"):
            key, _, val = t[len("--dpi-desync-"):].partition("=")
            if key in p:                      # fake-tls, fake-http, ...
                p[key].append(fake_ref(val, blobs))
            elif key in ("split-seqovl-pattern", "fakedsplit-pattern"):
                p[key] = fake_ref(val, blobs)
            else:
                p[key] = val
        # остальные --dpi-desync-* без значения не используются

    is_udp = any(f.startswith("--filter-udp") for f in filters)
    is_tcp = any(f.startswith("--filter-tcp") for f in filters)
    any_proto = p.get("any-protocol") == "1"
    repeats = p.get("repeats")
    fool = fooling_args(p)
    ipid = [f"ip_id={p['ip-id']}"] if p.get("ip-id") else []

    def inst(fn, *args):
        a = [x for x in args if x]
        return f"--lua-desync={fn}" + (":" + ":".join(a) if a else "")

    def fake_inst(blob, payload_kind):
        args = [f"blob={blob}"]
        if repeats:
            args.append(f"repeats={repeats}")
        args += fool + ipid
        if payload_kind == "tls" and p.get("fake-tls-mod") not in (None, "none"):
            args.append(f"tls_mod={p['fake-tls-mod']}")
        if any_proto:
            args.append("payload=all")
        return inst("fake", *args)

    lines = list(filters)

    if is_udp:
        if p["fake-discord"] or p["fake-stun"]:
            lines.append("--payload=discord_ip_discovery,stun")
            for b in dict.fromkeys(p["fake-discord"] + p["fake-stun"]):
                lines.append("  " + fake_inst(b, "udp"))
        elif any_proto:
            lines.append("--payload=all")
            for b in dict.fromkeys(p["fake-unknown-udp"] or ["fake_default_quic"]):
                lines.append("  " + fake_inst(b, "udp"))
        else:  # QUIC, port 443
            if p.get("cutoff"):
                lines.append(f"--out-range=-{p['cutoff'].replace('n', 'd', 1)}")
            lines.append("--payload=quic_initial")
            for b in dict.fromkeys(p["fake-quic"] or ["fake_default_quic"]):
                lines.append("  " + fake_inst(b, "quic"))
        return lines

    if not is_tcp:
        return lines

    # --- TCP ---
    # cutoff=nX -> --out-range=-dX (счётчик пакетов С ДАННЫМИ: в winws2 по
    # умолчанию --wf-tcp-empty=0, поэтому счётчик 'n' недостоверен, см. docs)
    if p.get("cutoff"):
        lines.append(f"--out-range=-{p['cutoff'].replace('n', 'd', 1)}")
    elif not any_proto:
        lines.append("--out-range=-d10")

    split_args = []
    if p.get("split-pos"):
        split_args.append(f"pos={p['split-pos']}")
    if p.get("split-seqovl"):
        split_args.append(f"seqovl={p['split-seqovl']}")
    if p.get("split-seqovl-pattern"):
        split_args.append(f"seqovl_pattern={p['split-seqovl-pattern']}")

    # payload-секции: tls, http и (для any-protocol/game) unknown
    kinds = [("tls_client_hello", "tls", p["fake-tls"] or ["fake_default_tls"]),
             ("http_req", "http", p["fake-http"] or ["fake_default_http"])]
    if any_proto or p["fake-unknown"]:
        kinds.append(("unknown", "unknown",
                      p["fake-unknown"] or ["fake_default_tls"]))

    extra = ["payload=all"] if any_proto else []
    # syndata работает по SYN-пакету, payload-фильтр перед ним ставить нельзя
    body = []
    for act in actions:
        if act == "syndata":
            body.append("  " + inst("syndata", *(fool + ipid + extra)))

    for payload, kind, fake_blobs in kinds:
        body.append(f"--payload={payload}")
        for act in actions:
            if act == "fake":
                for b in dict.fromkeys(fake_blobs):
                    body.append("  " + fake_inst(b, kind))
            elif act == "multisplit":
                body.append("  " + inst("multisplit", *(split_args + ipid + extra)))
            elif act == "multidisorder":
                # multidisorder_legacy = порядок сегментов как в nfqws1
                body.append("  " + inst("multidisorder_legacy",
                                         *(split_args + ipid + extra)))
            elif act == "fakedsplit":
                args = list(split_args)
                if p.get("fakedsplit-pattern"):
                    args.append(f"pattern={p['fakedsplit-pattern']}")
                # fooling/repeats в fakedsplit применяются только к фейкам
                body.append("  " + inst("fakedsplit",
                                        *(args + fool +
                                          ([f"repeats={repeats}"] if repeats else []) + ipid + extra)))
            elif act == "hostfakesplit":
                args = []
                mod = p.get("hostfakesplit-mod", "")
                m = re.search(r"host=([^,]+)", mod)
                if m:
                    args.append(f"host={m.group(1)}")
                # altorder=1 в zapret2 не существует - отброшен (см. MIGRATION.md)
                body.append("  " + inst("hostfakesplit",
                                        *(args + fool +
                                          ([f"repeats={repeats}"] if repeats else []) + ipid + extra)))
            elif act == "syndata":
                pass  # уже добавлен выше
            else:
                body.append(f"  :: UNSUPPORTED zapret1 action: {act}")
    return lines + body


# ---------------------------------------------------------------- file

HEADER = """@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"
call service.bat status_zapret
call service.bat check_updates
call service.bat load_game_filter
call service.bat load_user_lists
echo:

set "BIN=%~dp0bin\\"
set "LISTS=%~dp0lists\\"
cd /d %BIN%

if not exist "%BIN%winws2.exe" (
    echo [ERROR] winws2.exe not found in bin\\
    echo Download it from https://github.com/bol-van/zapret2/releases
    echo and put winws2.exe into the bin folder. See README.md
    pause
    exit /b 1
)
"""

def convert_file(path: Path) -> str:
    raw = path.read_text(encoding="utf-8", errors="ignore")
    # командная строка winws - всё после 'winws.exe"'
    m = re.search(r'winws\.exe"\s*(.*)', raw, re.S)
    if not m:
        raise SystemExit(f"{path.name}: winws.exe launch not found")
    # сначала экранированное '^!' (fake-tls=!), потом продолжения строк
    cmd = m.group(1).replace("^!", "!").replace("^", " ")
    tokens = parse_tokens(cmd)
    # глобальные wf-* - до первого профиля
    wf, rest = [], []
    seen_filter = False
    for t in tokens:
        if t.startswith("--filter-"):
            seen_filter = True
        (rest if seen_filter else wf).append(t)
    profiles, cur = [], []
    for t in rest:
        if unq(t) == "--new":
            profiles.append(cur); cur = []
        else:
            cur.append(t)
    profiles.append(cur)

    blobs: dict = {}
    prof_lines = [convert_profile(pr, blobs) for pr in profiles if pr]

    out = [HEADER]
    start = ('start "zapret: %~n0" /min "%BIN%winws2.exe" '
             '--wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% '
             '--wf-udp-out=443,19294-19344,50000-50100,%GameFilterUDP% ^')
    out.append(start)
    out.append('--lua-init=@"%BIN%lua\\zapret-lib.lua" '
               '--lua-init=@"%BIN%lua\\zapret-antidpi.lua" ^')
    for name, fname in blobs.items():
        if not name.startswith("fake_default"):
            out.append(f'--blob={name}:@"%BIN%{fname}" ^')
    for i, lines in enumerate(prof_lines):
        for j, line in enumerate(lines):
            sep = " ^" if not (i == len(prof_lines) - 1 and j == len(lines) - 1) else ""
            prefix = "" if line.startswith(("--filter", "--payload", "--out-range")) else ""
            out.append(f"{prefix}{line}{sep}")
            if j == len(lines) - 1 and i != len(prof_lines) - 1:
                out[-1] = out[-1].replace(" ^", " --new ^") if out[-1].endswith(" ^") else out[-1] + " --new"
    return "\r\n".join(out) + "\r\n"


def main():
    check = "--check" in sys.argv
    files = sorted(ROOT.glob("general*.bat"))
    if not files:
        raise SystemExit("general*.bat not found")
    for f in files:
        new = convert_file(f)
        if check:
            print(f"===== {f.name} =====\n{new}")
        else:
            f.write_bytes(new.encode("utf-8"))
            print(f"converted: {f.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
