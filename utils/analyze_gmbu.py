#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Анализатор Network Monitor GMBU файлов для диагностики Endfield.exe
"""

import struct
import sys
from collections import defaultdict, Counter
from datetime import datetime

class GMBUParser:
    """Парсер Microsoft Network Monitor GMBU формата"""
    
    # GMBU file signature
    SIGNATURE = b'GMBU'
    
    # Типы протоколов
    PROTOCOLS = {
        0x0800: 'IPv4',
        0x0806: 'ARP',
        0x86DD: 'IPv6',
    }
    
    # Типы IP протоколов
    IP_PROTOCOLS = {
        6: 'TCP',
        17: 'UDP',
        1: 'ICMP',
    }
    
    def __init__(self, filename):
        self.filename = filename
        self.packets = []
        self.stats = {
            'total_packets': 0,
            'ipv4_packets': 0,
            'tcp_packets': 0,
            'udp_packets': 0,
            'connections': Counter(),
            'ports': Counter(),
            'src_ips': Counter(),
            'dst_ips': Counter(),
            'tcp_flags': Counter(),
            'errors': [],
            'rst_connections': [],
            'syn_floods': [],
            'retransmissions': []
        }
    
    def parse_file(self):
        """Парсит GMBU файл"""
        try:
            with open(self.filename, 'rb') as f:
                # Читаем заголовок
                header = f.read(16)
                if header[:4] != self.SIGNATURE:
                    print(f"❌ Ошибка: неверный формат файла")
                    return False
                
                print(f"✓ Анализирую: {self.filename.split(chr(92))[-1]}")
                
                # Парсим остальной файл
                while True:
                    # Пытаемся прочитать запись фрейма
                    frame_header = f.read(20)
                    if len(frame_header) < 20:
                        break
                    
                    try:
                        # Парсим заголовок фрейма
                        # Формат может быть специфичным для Network Monitor
                        self.parse_frame(f, frame_header)
                    except Exception as e:
                        self.stats['errors'].append(str(e))
                        break
                
                print(f"  📊 Всего пакетов: {self.stats['total_packets']}")
                return True
                
        except Exception as e:
            print(f"❌ Ошибка при чтении файла: {e}")
            return False
    
    def parse_frame(self, f, frame_header):
        """Парсит отдельный фрейм"""
        # Попытаемся интерпретировать различные структуры
        try:
            # Базовая интерпретация
            frame_size = struct.unpack('<I', frame_header[0:4])[0]
            
            if frame_size > 0x10000:  # Санитарная проверка
                return
            
            frame_data = f.read(frame_size)
            if len(frame_data) < frame_size:
                return
            
            self.stats['total_packets'] += 1
            
            # Пробуем парсить как Ethernet + IP + TCP/UDP
            if len(frame_data) >= 14:
                self.analyze_frame(frame_data)
                
        except Exception as e:
            pass
    
    def analyze_frame(self, data):
        """Анализирует содержимое фрейма"""
        
        # Пропускаем слишком маленькие пакеты
        if len(data) < 14:
            return
        
        try:
            # Ethernet заголовок (может быть)
            eth_type = struct.unpack('>H', data[12:14])[0]
            payload_offset = 14
            
            # IPv4
            if eth_type == 0x0800:
                self.analyze_ipv4(data[payload_offset:])
            else:
                # Может быть это напрямую IP пакет
                self.analyze_ipv4(data)
                
        except:
            pass
    
    def analyze_ipv4(self, data):
        """Анализирует IPv4 пакет"""
        if len(data) < 20:
            return
        
        try:
            version_ihl = data[0]
            ihl = (version_ihl & 0x0f) * 4
            protocol = data[9]
            
            src_ip = '.'.join(str(b) for b in data[12:16])
            dst_ip = '.'.join(str(b) for b in data[16:20])
            
            self.stats['ipv4_packets'] += 1
            self.stats['src_ips'][src_ip] += 1
            self.stats['dst_ips'][dst_ip] += 1
            
            payload = data[ihl:]
            
            if protocol == 6:  # TCP
                self.analyze_tcp(src_ip, dst_ip, payload)
            elif protocol == 17:  # UDP
                self.analyze_udp(src_ip, dst_ip, payload)
                
        except:
            pass
    
    def analyze_tcp(self, src_ip, dst_ip, data):
        """Анализирует TCP сегмент"""
        if len(data) < 20:
            return
        
        try:
            src_port = struct.unpack('>H', data[0:2])[0]
            dst_port = struct.unpack('>H', data[2:4])[0]
            seq = struct.unpack('>I', data[4:8])[0]
            ack = struct.unpack('>I', data[8:12])[0]
            flags_byte = data[13]
            
            # TCP флаги
            flags = {
                'FIN': bool(flags_byte & 0x01),
                'SYN': bool(flags_byte & 0x02),
                'RST': bool(flags_byte & 0x04),
                'PSH': bool(flags_byte & 0x08),
                'ACK': bool(flags_byte & 0x10),
                'URG': bool(flags_byte & 0x20)
            }
            
            self.stats['tcp_packets'] += 1
            
            conn_key = f"{src_ip}:{src_port} → {dst_ip}:{dst_port}"
            self.stats['connections'][conn_key] += 1
            self.stats['ports'][dst_port] += 1
            
            flag_str = ''.join(k for k, v in flags.items() if v)
            if flag_str:
                self.stats['tcp_flags'][flag_str] += 1
            
            # Обнаруживаем проблемы
            if flags['RST']:
                self.stats['rst_connections'].append(conn_key)
            
            if flags['SYN'] and not flags['ACK']:
                # Попытка подключения
                pass
                
        except:
            pass
    
    def analyze_udp(self, src_ip, dst_ip, data):
        """Анализирует UDP пакет"""
        if len(data) < 8:
            return
        
        try:
            src_port = struct.unpack('>H', data[0:2])[0]
            dst_port = struct.unpack('>H', data[2:4])[0]
            
            self.stats['udp_packets'] += 1
            self.stats['ports'][dst_port] += 1
            
        except:
            pass
    
    def print_results(self):
        """Выводит результаты анализа"""
        print(f"\n  📈 IPv4 пакетов: {self.stats['ipv4_packets']}")
        print(f"  🔗 TCP пакетов: {self.stats['tcp_packets']}")
        print(f"  📡 UDP пакетов: {self.stats['udp_packets']}")
        
        if self.stats['src_ips']:
            print(f"\n  📍 Исходящие IP (топ-5):")
            for ip, count in self.stats['src_ips'].most_common(5):
                print(f"     {ip}: {count} пакетов")
        
        if self.stats['dst_ips']:
            print(f"\n  🎯 Целевые IP (топ-5):")
            for ip, count in self.stats['dst_ips'].most_common(5):
                print(f"     {ip}: {count} пакетов")
        
        if self.stats['ports']:
            print(f"\n  🔌 Используемые порты (топ-10):")
            for port, count in self.stats['ports'].most_common(10):
                service = self.get_port_service(port)
                print(f"     Порт {port} ({service}): {count} пакетов")
        
        if self.stats['tcp_flags']:
            print(f"\n  🚩 TCP флаги:")
            for flags, count in self.stats['tcp_flags'].most_common():
                print(f"     {flags}: {count}")
        
        if self.stats['rst_connections']:
            print(f"\n  ⚠️  СБРОШЕННЫЕ СОЕДИНЕНИЯ (RST флаги):")
            rst_set = set(self.stats['rst_connections'])
            for conn in list(rst_set)[:5]:
                print(f"     ❌ {conn}")
            if len(rst_set) > 5:
                print(f"     ... и еще {len(rst_set) - 5}")
    
    @staticmethod
    def get_port_service(port):
        """Возвращает имя сервиса для порта"""
        services = {
            53: 'DNS',
            80: 'HTTP',
            443: 'HTTPS',
            3306: 'MySQL',
            3389: 'RDP',
            5432: 'PostgreSQL',
            8080: 'HTTP Alt',
            27017: 'MongoDB',
        }
        return services.get(port, '?')

def main():
    files = [
        r'd:\VS\zapret-discord-youtube\asdasd\asd.cap',
        r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    ]
    
    print("\n" + "="*70)
    print("АНАЛИЗ ФАЙЛОВ ЗАХВАТА ПАКЕТОВ ENDFIELD.EXE")
    print("="*70 + "\n")
    
    results = []
    
    for filename in files:
        parser = GMBUParser(filename)
        if parser.parse_file():
            parser.print_results()
            results.append(parser.stats)
            print()
    
    print("="*70)
    print("ДИАГНОСТИКА ПРОБЛЕМ СОЕДИНЕНИЯ")
    print("="*70)
    
    if results:
        has_issues = False
        
        for idx, stats in enumerate(results, 1):
            if stats['rst_connections']:
                has_issues = True
                print(f"\n[ФАЙЛ {idx}] ⚠️  ОБНАРУЖЕНЫ ПРОБЛЕМЫ:")
                print(f"  • Сброшенные соединения (RST флаги): {len(set(stats['rst_connections']))}")
                print(f"  → Причина: сервер или маршрутизатор сбрасывают соединение")
                print(f"  → Решение: проверьте брандмауэр, VPN, блокировку портов")
        
        if not has_issues:
            print("\n✓ Критических проблем не обнаружено")
    
    print("\n" + "="*70 + "\n")

if __name__ == '__main__':
    main()
