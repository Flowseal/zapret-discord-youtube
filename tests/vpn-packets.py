from pathlib import Path
import ctypes
import ipaddress
import struct
import subprocess

root = Path(__file__).resolve().parents[1]


def ps_string(value):
    return "'" + str(value).replace("'", "''") + "'"


command = (
    f". {ps_string(root / 'utils' / 'vpn-filter.ps1')}; "
    f"$base = [IO.File]::ReadAllText({ps_string(root / 'tests' / 'fixtures' / 'alt13-all.filter.txt')}); "
    "New-VpnFilter $base @(8,12)"
)
result = subprocess.run(
    ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
    capture_output=True,
    check=True,
)
filter_text = result.stdout.strip()
library = ctypes.WinDLL(str(root / "bin" / "WinDivert.dll"), use_last_error=True)
compile_filter = library.WinDivertHelperCompileFilter
compile_filter.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_uint)]
compile_filter.restype = ctypes.c_int
error = ctypes.c_char_p()
position = ctypes.c_uint()
if not compile_filter(filter_text, 0, None, 0, ctypes.byref(error), ctypes.byref(position)):
    raise RuntimeError(f"Filter error at {position.value}: {error.value}")

evaluate = library.WinDivertHelperEvalFilter
evaluate.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p]
evaluate.restype = ctypes.c_int


def packet(protocol="tcp", port=443, flags=0x18, payload=b"x", ipv6=False, private=False):
    if protocol == "tcp":
        transport = struct.pack("!HHIIBBHHH", 40000, port, 1, 1, 0x50, flags, 65535, 0, 0) + payload
        number = 6
    else:
        transport = struct.pack("!HHHH", 40000, port, 8 + len(payload), 0) + payload
        number = 17
    if ipv6:
        source = ipaddress.ip_address("2001:db8::1").packed
        target = ipaddress.ip_address("fd00::1" if private else "2001:4860:4860::8888").packed
        header = struct.pack("!IHBB16s16s", 6 << 28, len(transport), number, 64, source, target)
    else:
        source = ipaddress.ip_address("198.51.100.1").packed
        target = ipaddress.ip_address("192.168.1.1" if private else "142.250.1.1").packed
        header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(transport), 0, 0, 64, number, 0, source, target)
    return header + transport


def matches(data, interface=8, inbound=False, loopback=False, impostor=False):
    address = bytearray(80)
    flags = (0 if inbound else 1 << 17) | (int(loopback) << 18) | (int(impostor) << 19)
    if data[0] >> 4 == 6:
        flags |= 1 << 20
    struct.pack_into("I", address, 8, flags)
    struct.pack_into("II", address, 16, interface, 0)
    packet_buffer = ctypes.create_string_buffer(data)
    address_buffer = ctypes.create_string_buffer(bytes(address))
    ctypes.set_last_error(0)
    answer = bool(evaluate(filter_text, packet_buffer, len(data), address_buffer))
    if not answer and ctypes.get_last_error():
        raise ctypes.WinError(ctypes.get_last_error())
    return answer


cases = [
    ("Ethernet HTTPS", packet(), {"interface": 8}, True),
    ("Wi-Fi HTTPS", packet(), {"interface": 12}, True),
    ("TUN HTTPS", packet(), {"interface": 5}, False),
    ("recreated TUN HTTPS", packet(), {"interface": 51}, False),
    ("unknown adapter", packet(), {"interface": 30}, False),
    ("Ethernet QUIC", packet("udp"), {"interface": 8}, True),
    ("TUN QUIC", packet("udp"), {"interface": 5}, False),
    ("Discord UDP", packet("udp", 50010), {"interface": 12}, True),
    ("TUN Discord UDP", packet("udp", 50010), {"interface": 51}, False),
    ("plain DNS", packet("udp", 53), {}, False),
    ("private IPv4", packet(private=True), {}, False),
    ("IPv6 HTTPS", packet(ipv6=True), {}, True),
    ("TUN IPv6 HTTPS", packet(ipv6=True), {"interface": 5}, False),
    ("private IPv6", packet(ipv6=True, private=True), {}, False),
    ("loopback", packet(), {"loopback": True}, False),
    ("impostor", packet(), {"impostor": True}, False),
    ("empty ACK", packet(flags=0x10, payload=b""), {}, False),
    ("outbound SYN", packet(flags=0x02, payload=b""), {}, True),
    ("inbound SYNACK", packet(flags=0x12, payload=b""), {"inbound": True}, True),
    ("TUN inbound SYNACK", packet(flags=0x12, payload=b""), {"inbound": True, "interface": 5}, False),
    ("inbound application data", packet(), {"inbound": True}, False),
]
for name, data, options, expected in cases:
    actual = matches(data, **options)
    if actual != expected:
        raise RuntimeError(f"{name}: expected {expected}, got {actual}")

print(f"{len(cases)} packet checks passed using WinDivert's native filter evaluator. No driver handles were opened.")
