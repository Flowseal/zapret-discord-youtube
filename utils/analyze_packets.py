#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Анализатор файлов захвата пакетов для диагностики проблем соединения Endfield.exe
"""

import sys
import struct
from collections import defaultdict, Counter
from datetime import datetime

def read_pcap_file(filename):
    """Читает файл PCAP и извлекает информацию о пакетах"""
    packets = []
    try:
        with open(filename, 'rb') as f:
            # Читаем глобальный заголовок PCAP
            header = f.read(24)
            if len(header) < 24:
                print(f"Ошибка: файл слишком короткий: {filename}")
                return packets
            
            magic = struct.unpack('I', header[0:4])[0]
            
            # Проверка формата PCAP
            if magic == 0xa1b2c3d4:
                is_swapped = False
            elif magic == 0xd4c3b2a1:
                is_swapped = True
            else:
                print(f"Ошибка: неизвестный формат файла: {filename}")
                return packets
            
            # Парсим заголовок
            if is_swapped:
                version_major, version_minor = struct.unpack('<HH', header[4:8])
                snaplen = struct.unpack('<I', header[16:20])[0]
                network = struct.unpack('<I', header[20:24])[0]
            else:
                version_major, version_minor = struct.unpack('>HH', header[4:8])
                snaplen = struct.unpack('>I', header[16:20])[0]
                network = struct.unpack('>I', header[20:24])[0]
            
            print(f"\n[*] Анализирую файл: {filename}")
            print(f"[*] Версия PCAP: {version_major}.{version_minor}")
            print(f"[*] Snaplen: {snaplen}")
            
            packet_num = 0
            # Читаем пакеты
            while True:
                packet_header = f.read(16)
                if len(packet_header) < 16:
                    break
                
                if is_swapped:
                    ts_sec, ts_usec, incl_len, orig_len = struct.unpack('<IIII', packet_header)
                else:
                    ts_sec, ts_usec, incl_len, orig_len = struct.unpack('>IIII', packet_header)
                
                packet_data = f.read(incl_len)
                if len(packet_data) < incl_len:
                    break
                
                packet_num += 1
                packets.append({
                    'timestamp': ts_sec + ts_usec / 1000000.0,
                    'data': packet_data,
                    'length': len(packet_data),
                    'original_length': orig_len
                })
        
        print(f"[+] Всего пакетов прочитано: {packet_num}")
        
    except Exception as e:
        print(f"Ошибка при чтении файла {filename}: {e}")
    
    return packets

def analyze_ethernet_frame(data):
    """Анализирует Ethernet кадр"""
    if len(data) < 14:
        return None, None, None
    
    dest_mac = ':'.join(f'{b:02x}' for b in data[0:6])
    src_mac = ':'.join(f'{b:02x}' for b in data[6:12])
    eth_type = struct.unpack('>H', data[12:14])[0]
    payload = data[14:]
    
    return dest_mac, src_mac, eth_type, payload

def analyze_ipv4_packet(data):
    """Анализирует IPv4 пакет"""
    if len(data) < 20:
        return None
    
    version_ihl = data[0]
    ihl = (version_ihl & 0x0f) * 4
    
    if len(data) < ihl:
        return None
    
    flags_fragment = struct.unpack('>H', data[6:8])[0]
    ttl = data[8]
    protocol = data[9]
    src_ip = '.'.join(str(b) for b in data[12:16])
    dst_ip = '.'.join(str(b) for b in data[16:20])
    
    # Флаги
    flags = {
        'DF': bool(flags_fragment & 0x4000),
        'MF': bool(flags_fragment & 0x2000),
        'fragment_offset': (flags_fragment & 0x1fff) * 8
    }
    
    return {
        'src': src_ip,
        'dst': dst_ip,
        'protocol': protocol,
        'ttl': ttl,
        'flags': flags,
        'header_length': ihl,
        'payload': data[ihl:]
    }

def analyze_tcp_segment(data):
    """Анализирует TCP сегмент"""
    if len(data) < 20:
        return None
    
    src_port = struct.unpack('>H', data[0:2])[0]
    dst_port = struct.unpack('>H', data[2:4])[0]
    seq = struct.unpack('>I', data[4:8])[0]
    ack = struct.unpack('>I', data[8:12])[0]
    data_offset_flags = struct.unpack('>H', data[12:14])[0]
    
    data_offset = ((data_offset_flags >> 12) & 0x0f) * 4
    flags = {
        'FIN': bool(data_offset_flags & 0x0001),
        'SYN': bool(data_offset_flags & 0x0002),
        'RST': bool(data_offset_flags & 0x0004),
        'PSH': bool(data_offset_flags & 0x0008),
        'ACK': bool(data_offset_flags & 0x0010),
        'URG': bool(data_offset_flags & 0x0020)
    }
    
    window = struct.unpack('>H', data[14:16])[0]
    checksum = struct.unpack('>H', data[16:18])[0]
    
    return {
        'src_port': src_port,
        'dst_port': dst_port,
        'seq': seq,
        'ack': ack,
        'flags': flags,
        'window': window,
        'checksum': checksum,
        'payload': data[data_offset:]
    }

def analyze_udp_segment(data):
    """Анализирует UDP сегмент"""
    if len(data) < 8:
        return None
    
    src_port = struct.unpack('>H', data[0:2])[0]
    dst_port = struct.unpack('>H', data[2:4])[0]
    length = struct.unpack('>H', data[4:6])[0]
    checksum = struct.unpack('>H', data[6:8])[0]
    
    return {
        'src_port': src_port,
        'dst_port': dst_port,
        'length': length,
        'checksum': checksum,
        'payload': data[8:]
    }

def analyze_packets(packets, filename):
    """Анализирует пакеты и выявляет проблемы"""
    
    stats = {
        'total_packets': len(packets),
        'ipv4_packets': 0,
        'ipv6_packets': 0,
        'tcp_packets': 0,
        'udp_packets': 0,
        'other_packets': 0,
        'connections': defaultdict(int),
        'ports': Counter(),
        'ips': Counter(),
        'tcp_flags': Counter(),
        'errors': [],
        'warnings': [],
        'dns_queries': [],
        'failed_connections': []
    }
    
    print(f"\n[*] Анализирую пакеты...")
    
    for idx, packet in enumerate(packets):
        data = packet['data']
        
        # Пропускаем слишком короткие пакеты
        if len(data) < 14:
            continue
        
        # Анализируем Ethernet
        dest_mac, src_mac, eth_type, payload = analyze_ethernet_frame(data)
        
        if eth_type == 0x0800:  # IPv4
            stats['ipv4_packets'] += 1
            ipv4 = analyze_ipv4_packet(payload)
            
            if ipv4:
                stats['ips'][ipv4['src']] += 1
                stats['ips'][ipv4['dst']] += 1
                
                if ipv4['protocol'] == 6:  # TCP
                    stats['tcp_packets'] += 1
                    tcp = analyze_tcp_segment(ipv4['payload'])
                    
                    if tcp:
                        conn_key = f"{ipv4['src']}:{tcp['src_port']} -> {ipv4['dst']}:{tcp['dst_port']}"
                        stats['connections'][conn_key] += 1
                        stats['ports'][tcp['dst_port']] += 1
                        
                        # Флаги TCP
                        flag_str = ''.join(k for k, v in tcp['flags'].items() if v)
                        if flag_str:
                            stats['tcp_flags'][flag_str] += 1
                        
                        # Проверяем на ошибки
                        if tcp['flags']['RST']:
                            stats['failed_connections'].append({
                                'connection': conn_key,
                                'type': 'RST флаг (соединение сброшено)',
                                'packet': idx
                            })
                
                elif ipv4['protocol'] == 17:  # UDP
                    stats['udp_packets'] += 1
                    udp = analyze_udp_segment(ipv4['payload'])
                    
                    if udp:
                        # DNS (порт 53)
                        if udp['dst_port'] == 53 or udp['src_port'] == 53:
                            stats['dns_queries'].append({
                                'src': ipv4['src'],
                                'dst': ipv4['dst'],
                                'port': udp['dst_port']
                            })
                
        elif eth_type == 0x0806:  # ARP
            pass
        else:
            stats['other_packets'] += 1
    
    return stats

def print_analysis(file1_stats, file2_stats):
    """Выводит результаты анализа"""
    
    print("\n" + "="*70)
    print("РЕЗУЛЬТАТЫ АНАЛИЗА ФАЙЛОВ ЗАХВАТА ПАКЕТОВ")
    print("="*70)
    
    for idx, stats in enumerate([file1_stats, file2_stats], 1):
        print(f"\n[FILE {idx}]")
        print(f"Всего пакетов: {stats['total_packets']}")
        print(f"IPv4 пакетов: {stats['ipv4_packets']}")
        print(f"IPv6 пакетов: {stats['ipv6_packets']}")
        print(f"TCP пакетов: {stats['tcp_packets']}")
        print(f"UDP пакетов: {stats['udp_packets']}")
        
        if stats['ips']:
            print(f"\nТоп IP адресов:")
            for ip, count in stats['ips'].most_common(5):
                print(f"  {ip}: {count} пакетов")
        
        if stats['ports']:
            print(f"\nТоп портов:")
            for port, count in stats['ports'].most_common(5):
                print(f"  Порт {port}: {count} пакетов")
        
        if stats['tcp_flags']:
            print(f"\nТCP флаги:")
            for flags, count in stats['tcp_flags'].most_common():
                print(f"  {flags}: {count}")
        
        if stats['failed_connections']:
            print(f"\n⚠️  ПРОБЛЕМЫ СОЕДИНЕНИЯ:")
            for conn in stats['failed_connections']:
                print(f"  - {conn['type']}")
                print(f"    {conn['connection']}")
                print(f"    Пакет: {conn['packet']}")
        
        if stats['dns_queries']:
            print(f"\nDNS запросы: {len(stats['dns_queries'])}")
            for dns in stats['dns_queries'][:3]:
                print(f"  {dns['src']} -> {dns['dst']}:{dns['port']}")
    
    print("\n" + "="*70)
    print("ЗАКЛЮЧЕНИЕ И РЕКОМЕНДАЦИИ")
    print("="*70)

def main():
    file1 = r'd:\VS\zapret-discord-youtube\asdasd\asd.cap'
    file2 = r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    
    packets1 = read_pcap_file(file1)
    packets2 = read_pcap_file(file2)
    
    if not packets1 and not packets2:
        print("Ошибка: не удалось прочитать файлы!")
        return
    
    stats1 = analyze_packets(packets1, file1)
    stats2 = analyze_packets(packets2, file2)
    
    print_analysis(stats1, stats2)

if __name__ == '__main__':
    main()
