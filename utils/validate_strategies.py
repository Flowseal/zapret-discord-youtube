#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Статическая проверка general*.bat (стратегий winws2):

  * нет остатков синтаксиса zapret1 (--dpi-desync*, --wf-tcp=, winws.exe);
  * вызываются только функции, реально существующие в bin/lua/zapret-antidpi.lua;
  * аргументы --lua-desync - только известные (стандартные блоки fooling /
    rawsend / ip_id / ipfrag / payload + аргументы конкретных функций);
  * все blob=<имя> либо inline 0xHEX, либо fake_default_*, либо объявлены
    через --blob=, а файлы этих --blob существуют в bin/;
  * типы --payload и функции Lua известны nfqws2;
  * у каждого файла 9 профилей (структура исходных стратегий сохранена).

Использование: python3 utils/validate_strategies.py
Код выхода 0 - всё в порядке, 1 - есть ошибки.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "bin"

# типы пейлоадов nfqws2 (docs/manual.md, "Распознавание протоколов")
PAYLOADS = {
    "all", "known", "unknown", "empty", "tls_client_hello", "tls_server_hello",
    "http_req", "http_resp", "quic_initial", "discord_ip_discovery", "stun",
    "wireguard_initiation", "wireguard_response", "wireguard_cookie",
    "dtls_client_hello", "dtls_server_hello", "dht", "bt", "xmpp_stream",
    "sip", "esp", "ike", "ntp", "dns_req", "dns_resp", "icmp", "icmp6",
}

# стандартные блоки аргументов zapret-antidpi.lua (шапка файла) +
# аргументы используемых функций (fake, multisplit, multidisorder_legacy,
# fakedsplit, hostfakesplit, syndata)
ARGS = {
    # standard fooling
    "ip_ttl", "ip6_ttl", "ip_autottl", "ip6_autottl", "ip6_hopbyhop",
    "ip6_hopbyhop2", "ip6_destopt", "ip6_destopt2", "ip6_routing", "ip6_ah",
    "tcp_seq", "tcp_ack", "tcp_ts", "tcp_md5", "tcp_flags_set",
    "tcp_flags_unset", "tcp_ts_up", "tcp_nop_del", "fool",
    # standard rawsend / reconstruct / ip_id / ipfrag / direction / payload
    "repeats", "ifout", "fwmark", "badsum", "dir", "payload",
    "ip_id", "ip_id_conn", "ipfrag", "ipfrag_disorder", "ipfrag_pos_tcp",
    "ipfrag_pos_udp", "ipfrag_pos_icmp", "ipfrag_pos", "ipfrag_next",
    # fake / syndata
    "blob", "optional", "tls_mod",
    # split-функции
    "pos", "seqovl", "seqovl_pattern", "pattern", "nodrop",
    # hostfakesplit
    "host", "midhost", "nofake1", "nofake2", "nofake3", "nofake4",
    "disorder_after",
}

OLD = ("--dpi-desync", "--wf-tcp=", "--wf-udp=", "winws.exe", "--lua-desync=fake:")


def main() -> int:
    antidpi = (BIN / "lua" / "zapret-antidpi.lua").read_text(encoding="utf-8")
    functions = set(re.findall(r"^function (\w+)\(", antidpi, re.M))
    errors = []

    files = sorted(ROOT.glob("general*.bat"))
    if not files:
        print("general*.bat не найдены"); return 1

    for f in files:
        text = f.read_text(encoding="utf-8", errors="ignore")
        for bad in ("--dpi-desync", "winws.exe"):
            if bad in text:
                errors.append(f"{f.name}: остался синтаксис zapret1: {bad}")
        if "--wf-tcp-out=" not in text or "winws2.exe" not in text:
            errors.append(f"{f.name}: нет winws2.exe / --wf-tcp-out")
        # число профилей как в исходных стратегиях zapret1 (ALT5 - укороченная)
        expected = 6 if f.name == "general (ALT5).bat" else 9
        profiles = text.count("--new") + 1
        if profiles != expected:
            errors.append(f"{f.name}: профилей {profiles}, ожидалось {expected}")

        blobs = set(re.findall(r"--blob=([\w]+):", text))
        blobs |= {"fake_default_tls", "fake_default_http", "fake_default_quic"}
        for name, fname in re.findall(r"--blob=([\w]+):@\"%BIN%([^\"]+)\"", text):
            if not (BIN / fname).exists():
                errors.append(f"{f.name}: --blob={name}: нет файла bin/{fname}")

        for fn_args in re.findall(r"--lua-desync=([^\s^]+)", text):
            fn, _, argstr = fn_args.partition(":")
            if fn not in functions:
                errors.append(f"{f.name}: нет функции Lua '{fn}'")
            for arg in filter(None, argstr.split(":")):
                key, _, val = arg.partition("=")
                if key not in ARGS:
                    errors.append(f"{f.name}: {fn}: неизвестный аргумент '{key}'")
                if key == "blob" and not val.startswith("0x") and val not in blobs:
                    errors.append(f"{f.name}: {fn}: blob '{val}' не объявлен")
                if key == "seqovl_pattern" and val not in blobs:
                    errors.append(f"{f.name}: {fn}: seqovl_pattern '{val}' не объявлен")
                if key == "pattern" and not val.startswith("0x") and val not in blobs:
                    errors.append(f"{f.name}: {fn}: pattern '{val}' не объявлен")
        for payload in re.findall(r"--payload=([^\s^]+)", text):
            for pl in payload.split(","):
                if pl not in PAYLOADS:
                    errors.append(f"{f.name}: неизвестный payload '{pl}'")

    if errors:
        print("\n".join(f"[ERROR] {e}" for e in errors))
        print(f"\nВсего ошибок: {len(errors)}")
        return 1
    print(f"OK: проверено стратегий: {len(files)}, "
          f"функций Lua доступно: {len(functions)}, ошибок нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
