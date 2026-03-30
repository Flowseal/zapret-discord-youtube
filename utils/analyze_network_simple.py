#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Анализатор Network Monitor GMBU файлов без зависимостей
Парсит формат GMBU Microsoft Network Monitor напрямую
"""

import struct
import sys
from collections import defaultdict, Counter
from datetime import datetime, timedelta

class GMBUFileParser:
    """Парсер Microsoft Network Monitor GMBU формата"""
    
    def __init__(self, filename):
        self.filename = filename
        self.packets = []
        self.frame_data = []
        self.stats = {
            'total_packets': 0,
            'ipv4_packets': 0,
            'tcp_packets': 0,
            'udp_packets': 0,
            'icmp_packets': 0,
            'dns_packets': 0,
            'https_packets': 0,
            'src_ips': Counter(),
            'dst_ips': Counter(),
            'dst_ports': Counter(),
            'src_ports': Counter(),
            'tcp_flags': Counter(),
            'connection_issues': [],
            'rst_packets': 0,
            'duplicate_acks': 0,
            'retransmissions': 0
        }
    
    def parse(self):
        """Парсит файл GMBU"""
        try:
            with open(self.filename, 'rb') as f:
                # Читаем заголовок файла
                file_header = f.read(16)
                if file_header[:4] != b'GMBU':
                    print(f"  ❌ Неизвестный формат: {self.filename}")
                    return False
                
                print(f"  ✓ Парсирую: {self.filename.split(chr(92))[-1]}")
                
                # Версия формата
                version = struct.unpack('<B', file_header[4:5])[0]
                
                # Читаем остаток файла и ищем структуры
                self.parse_gmbu_frames(f)
                
                return True
        
        except Exception as e:
            print(f"  ❌ Ошибка: {e}")
            return False
    
    def parse_gmbu_frames(self, f):
        """Парсит фреймы в GMBU файле"""
        frame_count = 0
        
        while True:
            try:
                # Ищем маркеры фреймов
                # GMBU использует специальную структуру для фреймов
                pos = f.tell()
                chunk = f.read(4096)
                
                if not chunk:
                    break
                
                # Парсим Ethernet фреймы в чанке
                self.extract_ethernet_frames(chunk)
                
            except:
                break
        
        print(f"    📊 Обработано {self.stats['total_packets']} пакетов")
    
    def extract_ethernet_frames(self, data):
        """Извлекает Ethernet фреймы из бинарных данных"""
        # Ищем паттерны Ethernet фреймов
        for i in range(len(data) - 14):
            # Попробуем парсить как Ethernet фрейм
            try:
                # Получаем тип Ethernet протокола (байты 12-13)
                eth_type = struct.unpack('>H', data[i+12:i+14])[0]
                
                # IPv4 = 0x0800
                if eth_type == 0x0800 and i + 14 + 20 < len(data):
                    # Проверяем версию и длину IP заголовка
                    version_ihl = data[i+14]
                    if (version_ihl >> 4) == 4:  # IPv4
                        # Это похоже на IP фрейм
                        self.parse_ip_packet(data[i+14:i+100])
                        self.stats['total_packets'] += 1
            except:
                pass
    
    def parse_ip_packet(self, data):
        """Парсит IP пакет"""
        try:
            if len(data) < 20:
                return
            
            version_ihl = data[0]
            ihl = (version_ihl & 0x0f) * 4
            protocol = data[9]
            ttl = data[8]
            
            src_ip = '.'.join(str(b) for b in data[12:16])
            dst_ip = '.'.join(str(b) for b in data[16:20])
            
            # Проверяем валидность IP
            if not self.is_valid_ip(src_ip) or not self.is_valid_ip(dst_ip):
                return
            
            self.stats['ipv4_packets'] += 1
            self.stats['src_ips'][src_ip] += 1
            self.stats['dst_ips'][dst_ip] += 1
            
            payload = data[ihl:ihl+100]
            
            if protocol == 6:  # TCP
                self.parse_tcp(src_ip, dst_ip, payload)
            elif protocol == 17:  # UDP
                self.parse_udp(src_ip, dst_ip, payload)
            elif protocol == 1:  # ICMP
                self.stats['icmp_packets'] += 1
        
        except:
            pass
    
    def parse_tcp(self, src_ip, dst_ip, data):
        """Парсит TCP сегмент"""
        try:
            if len(data) < 14:
                return
            
            src_port = struct.unpack('>H', data[0:2])[0]
            dst_port = struct.unpack('>H', data[2:4])[0]
            seq = struct.unpack('>I', data[4:8])[0]
            ack = struct.unpack('>I', data[8:12])[0]
            
            data_offset_flags = struct.unpack('>H', data[12:14])[0]
            flags_byte = data_offset_flags & 0xFF
            
            # TCP флаги
            flag_fin = bool(flags_byte & 0x01)
            flag_syn = bool(flags_byte & 0x02)
            flag_rst = bool(flags_byte & 0x04)
            flag_psh = bool(flags_byte & 0x08)
            flag_ack = bool(flags_byte & 0x10)
            flag_urg = bool(flags_byte & 0x20)
            
            self.stats['tcp_packets'] += 1
            self.stats['dst_ports'][dst_port] += 1
            self.stats['src_ports'][src_port] += 1
            
            # Собираем строку флагов
            flags_str = ''
            if flag_syn:
                flags_str += 'S'
            if flag_ack:
                flags_str += 'A'
            if flag_fin:
                flags_str += 'F'
            if flag_rst:
                flags_str += 'R'
            if flag_psh:
                flags_str += 'P'
            if flag_urg:
                flags_str += 'U'
            
            if flags_str:
                self.stats['tcp_flags'][flags_str] += 1
            
            # Проверяем на проблемы
            if flag_rst:
                self.stats['rst_packets'] += 1
                self.stats['connection_issues'].append({
                    'type': 'RST',
                    'connection': f"{src_ip}:{src_port} → {dst_ip}:{dst_port}",
                    'reason': 'Соединение сброшено сервером'
                })
            
            # HTTPS (порт 443)
            if dst_port == 443:
                self.stats['https_packets'] += 1
            
            # DNS (порт 53)
            if dst_port == 53:
                self.stats['dns_packets'] += 1
        
        except:
            pass
    
    def parse_udp(self, src_ip, dst_ip, data):
        """Парсит UDP пакет"""
        try:
            if len(data) < 8:
                return
            
            src_port = struct.unpack('>H', data[0:2])[0]
            dst_port = struct.unpack('>H', data[2:4])[0]
            
            self.stats['udp_packets'] += 1
            self.stats['dst_ports'][dst_port] += 1
            
            if dst_port == 53:
                self.stats['dns_packets'] += 1
        
        except:
            pass
    
    @staticmethod
    def is_valid_ip(ip):
        """Проверяет валидность IP адреса"""
        try:
            parts = ip.split('.')
            if len(parts) != 4:
                return False
            for part in parts:
                num = int(part)
                if num < 0 or num > 255:
                    return False
            # Исключаем некоторые недопустимые диапазоны
            if ip.startswith('0.') or ip.startswith('255.'):
                return False
            return True
        except:
            return False
    
    def print_results(self):
        """Выводит результаты"""
        print(f"\n    📊 Статистика:")
        print(f"       IPv4: {self.stats['ipv4_packets']}")
        print(f"       TCP: {self.stats['tcp_packets']}")
        print(f"       UDP: {self.stats['udp_packets']}")
        if self.stats['dns_packets'] > 0:
            print(f"       DNS: {self.stats['dns_packets']}")
        if self.stats['https_packets'] > 0:
            print(f"       HTTPS: {self.stats['https_packets']}")
        
        if self.stats['src_ips']:
            print(f"\n    📤 Исходящие IP (топ-5):")
            for ip, count in self.stats['src_ips'].most_common(5):
                print(f"       {ip}: {count}")
        
        if self.stats['dst_ips']:
            print(f"\n    📥 Целевые IP (топ-5):")
            for ip, count in self.stats['dst_ips'].most_common(5):
                print(f"       {ip}: {count}")
        
        if self.stats['dst_ports']:
            print(f"\n    🔌 Целевые порты:")
            for port, count in self.stats['dst_ports'].most_common(10):
                port_name = self.get_port_name(port)
                print(f"       {port} ({port_name}): {count}")
        
        if self.stats['tcp_flags']:
            print(f"\n    🚩 TCP флаги:")
            for flags, count in self.stats['tcp_flags'].most_common():
                print(f"       {flags}: {count}")
        
        if self.stats['connection_issues']:
            print(f"\n    ⚠️  ПРОБЛЕМЫ СОЕДИНЕНИЯ:")
            for issue in self.stats['connection_issues'][:10]:
                print(f"       [{issue['type']}] {issue['connection']}")
                print(f"       └─ {issue['reason']}")
    
    @staticmethod
    def get_port_name(port):
        """Возвращает имя сервиса для порта"""
        ports = {
            53: 'DNS',
            80: 'HTTP',
            443: 'HTTPS',
            3306: 'MySQL',
            3389: 'RDP',
            5432: 'PostgreSQL',
            8080: 'HTTP-ALT',
            27017: 'MongoDB',
        }
        return ports.get(port, '?')
    
    def get_issues(self):
        """Возвращает список проблем"""
        issues = []
        
        if self.stats['rst_packets'] > 0:
            issues.append({
                'severity': 'HIGH',
                'type': 'RST Пакеты',
                'count': self.stats['rst_packets'],
                'description': 'Соединение часто сбрасывается сервером'
            })
        
        if self.stats['ipv4_packets'] > 0 and self.stats['tcp_packets'] == 0 and self.stats['udp_packets'] == 0:
            issues.append({
                'severity': 'MEDIUM',
                'type': 'Нет TCP/UDP',
                'count': 1,
                'description': 'Только ICMP пакеты, нет TCP/UDP соединений'
            })
        
        return issues

def main():
    files = [
        r'd:\VS\zapret-discord-youtube\asdasd\asd.cap',
        r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    ]
    
    print("\n" + "="*70)
    print("АНАЛИЗ СЕТЕВЫХ ЗАХВАТОВ - ENDFIELD.EXE")
    print("="*70 + "\n")
    
    all_issues = []
    
    for filename in files:
        parser = GMBUFileParser(filename)
        if parser.parse():
            parser.print_results()
            issues = parser.get_issues()
            all_issues.extend([(filename.split(chr(92))[-1], issue) for issue in issues])
    
    # Вывод проблем
    print("\n" + "="*70)
    print("ВЫЯВЛЕННЫЕ ПРОБЛЕМЫ И РЕШЕНИЯ")
    print("="*70 + "\n")
    
    if all_issues:
        for filename, issue in all_issues:
            severity_icon = "🔴" if issue['severity'] == 'HIGH' else "🟡"
            print(f"{severity_icon} [{filename}]")
            print(f"   Проблема: {issue['type']}")
            print(f"   Найдено: {issue['count']}")
            print(f"   Описание: {issue['description']}\n")
    else:
        print("✓ Критических проблем с соединением не обнаружено\n")
    
    print("="*70)
    print("ВОЗМОЖНЫЕ ПРИЧИНЫ И РЕКОМЕНДАЦИИ")
    print("="*70 + "\n")
    
    if any(i[1]['type'] == 'RST Пакеты' for i in all_issues):
        print("⚠️  ПРОБЛЕМА: Соединение сбрасывается сервером\n")
        print("Возможные причины:")
        print("  1. 🔥 Брандмауэр блокирует соединение")
        print("  2. 📡 ISP или операционная система блокирует трафик")
        print("  3. 🕸️  VPN или прокси-сервер отказывает в доступе")
        print("  4. 🖥️  Сервер игры недоступен или отклоняет соединения")
        print("\nДействия:")
        print("  → Проверьте Windows Defender > Брандмауэр")
        print("  → Добавьте Endfield.exe в исключения брандмауэра")
        print("  → Если используется VPN, отключите и попробуйте еще раз")
        print("  → Проверьте соединение с интернетом (ping 8.8.8.8)")
        print()
    else:
        print("✓ Соединение выглядит стабильным\n")
        print("Если проблемы все еще происходят, проверьте:\n")
        print("  1. 📊 Скорость и стабильность интернета")
        print("     → Используйте speedtest.net для проверки")
        print("  2. 🔧 Брандмауэр и антивирус")
        print("     → Убедитесь, что игра разрешена")
        print("  3. 🌐 Параметры сети")
        print("     → Проверьте proxy и DNS настройки")
        print("  4. ⚙️  Драйверы сетевой карты")
        print("     → Обновите драйверы через Device Manager")
        print("  5. 🎮 Само приложение")
        print("     → Переустановите Endfield")
        print("     → Запустите от администратора")
        print()

if __name__ == '__main__':
    main()
