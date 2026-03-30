#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Компаратор трафика VPN vs NO-VPN для диагностики проблем подключения Endfield
Анализирует различия между рабочим (VPN) и нерабочим (NO-VPN) трафиком
"""

import struct
import sys
import os
from collections import Counter, defaultdict
from datetime import datetime

class TrafficComparator:
    def __init__(self, vpn_file, novpn_file):
        self.vpn_file = vpn_file
        self.novpn_file = novpn_file
        
        self.vpn_stats = {
            'total_packets': 0,
            'tcp_packets': 0,
            'udp_packets': 0,
            'dst_ips': Counter(),
            'dst_ports': Counter(),
            'tcp_flags': Counter(),
            'rst_count': 0,
            'syn_count': 0,
            'syn_ack_count': 0,
            'fin_count': 0,
            'tls_handshakes': 0,
            'packet_sizes': [],
            'unique_connections': set()
        }
        
        self.novpn_stats = {
            'total_packets': 0,
            'tcp_packets': 0,
            'udp_packets': 0,
            'dst_ips': Counter(),
            'dst_ports': Counter(),
            'tcp_flags': Counter(),
            'rst_count': 0,
            'syn_count': 0,
            'syn_ack_count': 0,
            'fin_count': 0,
            'tls_handshakes': 0,
            'packet_sizes': [],
            'unique_connections': set()
        }
    
    def analyze_file(self, filename, stats):
        """Анализирует CAP или ETL файл"""
        print(f"\n📂 Анализирую: {os.path.basename(filename)}")
        
        try:
            with open(filename, 'rb') as f:
                data = f.read()
            
            # Определяем формат файла
            if data[:4] == b'GMBU' or data[:4] == b'\xa1\xb2\xc3\xd4':
                # CAP файл
                self.analyze_cap_data(data, stats)
            else:
                # Пытаемся парсить как сырые данные
                self.analyze_raw_data(data, stats)
            
            print(f"  ✅ Обработано {stats['total_packets']} пакетов")
            
        except Exception as e:
            print(f"  ❌ Ошибка: {e}")
            return False
        
        return True
    
    def analyze_raw_data(self, data, stats):
        """Парсит сырые бинарные данные в поисках IP пакетов"""
        i = 0
        while i < len(data) - 20:
            # Ищем IPv4 пакеты
            if i + 20 <= len(data):
                version = (data[i] >> 4)
                if version == 4:
                    packet_len = self.parse_ip_packet(data[i:], stats)
                    if packet_len > 0:
                        i += packet_len
                        continue
            i += 1
    
    def analyze_cap_data(self, data, stats):
        """Анализирует CAP файл"""
        # Простой парсинг - ищем Ethernet фреймы
        i = 0
        while i < len(data) - 14:
            try:
                # Ethernet тип на офсете 12-13
                if i + 14 < len(data):
                    eth_type = struct.unpack('>H', data[i+12:i+14])[0]
                    if eth_type == 0x0800:  # IPv4
                        packet_len = self.parse_ip_packet(data[i+14:], stats)
                        if packet_len > 0:
                            i += 14 + packet_len
                            continue
            except:
                pass
            i += 1
    
    def parse_ip_packet(self, data, stats):
        """Парсит IP пакет"""
        try:
            if len(data) < 20:
                return 0
            
            version = (data[0] >> 4)
            if version != 4:
                return 0
            
            ihl = (data[0] & 0x0f) * 4
            if ihl < 20 or ihl > 60:
                return 0
            
            total_length = struct.unpack('>H', data[2:4])[0]
            if total_length < 20 or total_length > len(data):
                return 0
            
            protocol = data[9]
            src_ip = '.'.join(str(b) for b in data[12:16])
            dst_ip = '.'.join(str(b) for b in data[16:20])
            
            stats['total_packets'] += 1
            stats['packet_sizes'].append(total_length)
            
            # Фильтруем только исходящие пакеты к публичным IP
            if self.is_local_ip(src_ip) and self.is_public_ip(dst_ip):
                stats['dst_ips'][dst_ip] += 1
                
                # TCP анализ
                if protocol == 6 and len(data) >= ihl + 20:
                    self.parse_tcp(data[ihl:], dst_ip, stats)
                    stats['tcp_packets'] += 1
                
                # UDP анализ
                elif protocol == 17 and len(data) >= ihl + 8:
                    self.parse_udp(data[ihl:], dst_ip, stats)
                    stats['udp_packets'] += 1
            
            return total_length
            
        except:
            return 0
    
    def parse_tcp(self, data, dst_ip, stats):
        """Парсит TCP заголовок"""
        try:
            if len(data) < 20:
                return
            
            src_port = struct.unpack('>H', data[0:2])[0]
            dst_port = struct.unpack('>H', data[2:4])[0]
            flags = data[13]
            
            stats['dst_ports'][dst_port] += 1
            stats['unique_connections'].add(f"{dst_ip}:{dst_port}")
            
            # Флаги TCP
            fin = flags & 0x01
            syn = flags & 0x02
            rst = flags & 0x04
            psh = flags & 0x08
            ack = flags & 0x10
            
            flag_str = []
            if fin: flag_str.append('FIN')
            if syn: flag_str.append('SYN')
            if rst: flag_str.append('RST')
            if psh: flag_str.append('PSH')
            if ack: flag_str.append('ACK')
            
            stats['tcp_flags'][','.join(flag_str)] += 1
            
            if rst:
                stats['rst_count'] += 1
            if syn and not ack:
                stats['syn_count'] += 1
            if syn and ack:
                stats['syn_ack_count'] += 1
            if fin:
                stats['fin_count'] += 1
            
            # Проверка TLS handshake (порт 443 + данные)
            if dst_port == 443 and len(data) > 25:
                # TLS ContentType = 0x16 (Handshake)
                if data[20] == 0x16:
                    stats['tls_handshakes'] += 1
                    
        except:
            pass
    
    def parse_udp(self, data, dst_ip, stats):
        """Парсит UDP заголовок"""
        try:
            if len(data) < 8:
                return
            
            src_port = struct.unpack('>H', data[0:2])[0]
            dst_port = struct.unpack('>H', data[2:4])[0]
            
            stats['dst_ports'][dst_port] += 1
            stats['udp_packets'] += 1
            stats['unique_connections'].add(f"{dst_ip}:{dst_port}")
            
        except:
            pass
    
    @staticmethod
    def is_local_ip(ip):
        """Проверяет локальный IP"""
        try:
            parts = [int(x) for x in ip.split('.')]
            if parts[0] == 192 and parts[1] == 168:
                return True
            if parts[0] == 10:
                return True
            if parts[0] == 172 and 16 <= parts[1] <= 31:
                return True
            return False
        except:
            return False
    
    @staticmethod
    def is_public_ip(ip):
        """Проверяет публичный IP"""
        try:
            parts = [int(x) for x in ip.split('.')]
            if len(parts) != 4:
                return False
            
            # Исключаем приватные
            if parts[0] == 192 and parts[1] == 168:
                return False
            if parts[0] == 10:
                return False
            if parts[0] == 172 and 16 <= parts[1] <= 31:
                return False
            if parts[0] in [0, 127, 255]:
                return False
            if parts[0] >= 224:
                return False
            
            return True
        except:
            return False
    
    def compare(self):
        """Сравнивает трафик VPN и NO-VPN"""
        print("\n" + "=" * 80)
        print("🔍 СРАВНИТЕЛЬНЫЙ АНАЛИЗ ТРАФИКА ENDFIELD")
        print("=" * 80)
        
        # Анализируем оба файла
        if not self.analyze_file(self.vpn_file, self.vpn_stats):
            return False
        
        if not self.analyze_file(self.novpn_file, self.novpn_stats):
            return False
        
        # Выводим результаты
        self.print_comparison()
        
        # Выводим рекомендации
        self.print_recommendations()
        
        return True
    
    def print_comparison(self):
        """Выводит сравнение статистики"""
        print("\n" + "=" * 80)
        print("📊 ОБЩАЯ СТАТИСТИКА")
        print("=" * 80)
        
        print(f"\n{'Метрика':<40} {'VPN':<20} {'NO-VPN':<20}")
        print("-" * 80)
        print(f"{'Всего пакетов':<40} {self.vpn_stats['total_packets']:<20} {self.novpn_stats['total_packets']:<20}")
        print(f"{'TCP пакетов':<40} {self.vpn_stats['tcp_packets']:<20} {self.novpn_stats['tcp_packets']:<20}")
        print(f"{'UDP пакетов':<40} {self.vpn_stats['udp_packets']:<20} {self.novpn_stats['udp_packets']:<20}")
        print(f"{'Уникальных подключений':<40} {len(self.vpn_stats['unique_connections']):<20} {len(self.novpn_stats['unique_connections']):<20}")
        
        # Средний размер пакета
        vpn_avg = sum(self.vpn_stats['packet_sizes']) / max(len(self.vpn_stats['packet_sizes']), 1)
        novpn_avg = sum(self.novpn_stats['packet_sizes']) / max(len(self.novpn_stats['packet_sizes']), 1)
        print(f"{'Средний размер пакета':<40} {vpn_avg:<20.1f} {novpn_avg:<20.1f}")
        
        print("\n" + "=" * 80)
        print("🔌 TCP СОЕДИНЕНИЯ")
        print("=" * 80)
        print(f"\n{'Флаг':<40} {'VPN':<20} {'NO-VPN':<20}")
        print("-" * 80)
        print(f"{'SYN (попытки подключения)':<40} {self.vpn_stats['syn_count']:<20} {self.novpn_stats['syn_count']:<20}")
        print(f"{'SYN-ACK (принятые подключения)':<40} {self.vpn_stats['syn_ack_count']:<20} {self.novpn_stats['syn_ack_count']:<20}")
        print(f"{'RST (сброс соединений)':<40} {self.vpn_stats['rst_count']:<20} {self.novpn_stats['rst_count']:<20}")
        print(f"{'FIN (завершение)':<40} {self.vpn_stats['fin_count']:<20} {self.novpn_stats['fin_count']:<20}")
        print(f"{'TLS handshakes':<40} {self.vpn_stats['tls_handshakes']:<20} {self.novpn_stats['tls_handshakes']:<20}")
        
        # Целевые IP
        print("\n" + "=" * 80)
        print("🌍 ЦЕЛЕВЫЕ IP АДРЕСА")
        print("=" * 80)
        
        vpn_ips = set(self.vpn_stats['dst_ips'].keys())
        novpn_ips = set(self.novpn_stats['dst_ips'].keys())
        
        common_ips = vpn_ips & novpn_ips
        vpn_only = vpn_ips - novpn_ips
        novpn_only = novpn_ips - vpn_ips
        
        print(f"\nОбщие IP (доступны в обоих режимах): {len(common_ips)}")
        for ip in sorted(common_ips)[:10]:
            print(f"  ✅ {ip:<20} VPN: {self.vpn_stats['dst_ips'][ip]:>5}  NO-VPN: {self.novpn_stats['dst_ips'][ip]:>5}")
        
        print(f"\nТолько с VPN (заблокированы без VPN): {len(vpn_only)}")
        for ip in sorted(vpn_only, key=lambda x: self.vpn_stats['dst_ips'][x], reverse=True)[:10]:
            print(f"  🔒 {ip:<20} Пакетов: {self.vpn_stats['dst_ips'][ip]}")
        
        print(f"\nТолько без VPN: {len(novpn_only)}")
        for ip in sorted(novpn_only, key=lambda x: self.novpn_stats['dst_ips'][x], reverse=True)[:10]:
            print(f"  ⚠️  {ip:<20} Пакетов: {self.novpn_stats['dst_ips'][ip]}")
        
        # Порты
        print("\n" + "=" * 80)
        print("🔌 ЦЕЛЕВЫЕ ПОРТЫ")
        print("=" * 80)
        
        print("\nТоп-10 портов с VPN:")
        for port, count in self.vpn_stats['dst_ports'].most_common(10):
            service = self.get_port_service(port)
            print(f"  {port:>5} ({service:<15}): {count:>5} пакетов")
        
        print("\nТоп-10 портов без VPN:")
        for port, count in self.novpn_stats['dst_ports'].most_common(10):
            service = self.get_port_service(port)
            print(f"  {port:>5} ({service:<15}): {count:>5} пакетов")
    
    def print_recommendations(self):
        """Выводит рекомендации по устранению проблемы"""
        print("\n" + "=" * 80)
        print("💡 ДИАГНОСТИКА И РЕКОМЕНДАЦИИ")
        print("=" * 80)
        
        # Анализ RST пакетов
        if self.novpn_stats['rst_count'] > self.vpn_stats['rst_count'] * 2:
            print("\n⚠️  ПРОБЛЕМА: Высокий уровень RST (сброс соединений) без VPN")
            print("   Возможная причина: DPI блокирует соединения")
            print("   Рекомендация: Использовать фрагментацию или подделку TLS")
        
        # Анализ SYN без SYN-ACK
        vpn_syn_ratio = self.vpn_stats['syn_ack_count'] / max(self.vpn_stats['syn_count'], 1)
        novpn_syn_ratio = self.novpn_stats['syn_ack_count'] / max(self.novpn_stats['syn_count'], 1)
        
        if novpn_syn_ratio < 0.5 and vpn_syn_ratio > 0.7:
            print("\n⚠️  ПРОБЛЕМА: Подключения не устанавливаются без VPN")
            print("   Возможная причина: Блокировка на уровне TCP handshake")
            print("   Рекомендация: Использовать TCP fragmentation или подмену TTL")
        
        # Анализ заблокированных IP
        vpn_ips = set(self.vpn_stats['dst_ips'].keys())
        novpn_ips = set(self.novpn_stats['dst_ips'].keys())
        blocked_ips = vpn_ips - novpn_ips
        
        if len(blocked_ips) > 0:
            print(f"\n🔒 НАЙДЕНО {len(blocked_ips)} заблокированных IP адресов")
            print("   Эти адреса доступны с VPN, но не без него:")
            
            # Сохраняем в файл
            output_file = os.path.join(os.path.dirname(__file__), 'endfield_blocked_ips.txt')
            with open(output_file, 'w') as f:
                for ip in sorted(blocked_ips, key=lambda x: self.vpn_stats['dst_ips'][x], reverse=True):
                    f.write(f"{ip}\n")
                    if self.vpn_stats['dst_ips'][ip] > 10:
                        print(f"     • {ip} ({self.vpn_stats['dst_ips'][ip]} пакетов)")
            
            print(f"\n   ✅ Список сохранен в: {output_file}")
            print("   Рекомендация: Добавить эти IP в список для обработки zapret")
        
        # Проверка TLS
        if self.vpn_stats['tls_handshakes'] > 0 and self.novpn_stats['tls_handshakes'] == 0:
            print("\n⚠️  ПРОБЛЕМА: TLS handshake блокируется без VPN")
            print("   Возможная причина: DPI анализирует TLS Client Hello")
            print("   Рекомендация: Использовать --fake-tls или --fake-sni")
        
        print("\n" + "=" * 80)
        print("🔧 ПРЕДЛАГАЕМЫЕ КОМАНДЫ ZAPRET:")
        print("=" * 80)
        
        # Генерируем команды для zapret
        if len(blocked_ips) > 0:
            print("\n1. Добавить IP адреса в ipset:")
            print("   Скопировать содержимое endfield_blocked_ips.txt в lists/ipset-all.txt")
        
        print("\n2. Попробовать разные стратегии обхода:")
        print("   а) Фрагментация TCP:")
        print("      --dpi-desync=split2 --dpi-desync-fooling=badseq")
        print("   б) Подделка TLS:")
        print("      --dpi-desync=fake --dpi-desync-fake-tls=0x16030100")
        print("   в) Комбинированный подход:")
        print("      --dpi-desync=split2 --dpi-desync-split-pos=2 --dpi-desync-fooling=badseq,md5sig")
        
        print("\n" + "=" * 80)
    
    @staticmethod
    def get_port_service(port):
        """Возвращает название сервиса для порта"""
        services = {
            80: "HTTP",
            443: "HTTPS",
            53: "DNS",
            8080: "HTTP-Alt",
            8443: "HTTPS-Alt",
            3478: "STUN",
            5228: "Google",
            27015: "Game",
            30000: "Game",
        }
        return services.get(port, "Unknown")


def find_latest_captures():
    """Ищет последние файлы захвата VPN и NO-VPN"""
    asdasd_dir = os.path.join(os.path.dirname(__file__), '..', 'asdasd')
    
    if not os.path.exists(asdasd_dir):
        return None, None
    
    vpn_files = []
    novpn_files = []
    
    for filename in os.listdir(asdasd_dir):
        filepath = os.path.join(asdasd_dir, filename)
        if 'endfield_vpn' in filename.lower() and (filename.endswith('.etl') or filename.endswith('.cap')):
            vpn_files.append(filepath)
        elif 'endfield_novpn' in filename.lower() and (filename.endswith('.etl') or filename.endswith('.cap')):
            novpn_files.append(filepath)
    
    vpn_file = max(vpn_files, key=os.path.getmtime) if vpn_files else None
    novpn_file = max(novpn_files, key=os.path.getmtime) if novpn_files else None
    
    return vpn_file, novpn_file


def main():
    print("🔍 КОМПАРАТОР ТРАФИКА VPN vs NO-VPN")
    print("=" * 80)
    
    # Проверяем аргументы
    if len(sys.argv) == 3:
        vpn_file = sys.argv[1]
        novpn_file = sys.argv[2]
    else:
        # Ищем последние файлы автоматически
        print("🔎 Ищу последние файлы захвата...")
        vpn_file, novpn_file = find_latest_captures()
        
        if not vpn_file or not novpn_file:
            print("\n❌ Не найдены файлы захвата!")
            print("\nИспользование:")
            print("  python compare_traffic.py <vpn_file> <novpn_file>")
            print("\nИли сначала захватите трафик:")
            print("  .\\capture_traffic.ps1 -Mode vpn")
            print("  .\\capture_traffic.ps1 -Mode novpn")
            return 1
    
    # Проверяем существование файлов
    if not os.path.exists(vpn_file):
        print(f"❌ Файл не найден: {vpn_file}")
        return 1
    
    if not os.path.exists(novpn_file):
        print(f"❌ Файл не найден: {novpn_file}")
        return 1
    
    print(f"\n📁 VPN трафик: {os.path.basename(vpn_file)}")
    print(f"📁 NO-VPN трафик: {os.path.basename(novpn_file)}")
    
    # Запускаем сравнение
    comparator = TrafficComparator(vpn_file, novpn_file)
    if comparator.compare():
        print("\n✅ Анализ завершен успешно!")
        return 0
    else:
        print("\n❌ Ошибка при анализе")
        return 1


if __name__ == '__main__':
    sys.exit(main())
