#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Анализатор Network Monitor CAP файлов для Endfield.exe
Использует pyshark для анализа захватов пакетов
"""

import sys
import pyshark
from collections import defaultdict, Counter
import re

class NetworkCapAnalyzer:
    def __init__(self, filename):
        self.filename = filename
        self.cap = None
        self.stats = {
            'total_packets': 0,
            'ipv4_packets': 0,
            'tcp_packets': 0,
            'udp_packets': 0,
            'icmp_packets': 0,
            'dns_packets': 0,
            'https_packets': 0,
            'connections': Counter(),
            'ports_src': Counter(),
            'ports_dst': Counter(),
            'src_ips': Counter(),
            'dst_ips': Counter(),
            'tcp_flags': Counter(),
            'retransmissions': [],
            'rst_connections': [],
            'connection_resets': [],
            'timeout_issues': [],
            'dns_failures': [],
            'tcp_errors': []
        }
    
    def load_capture(self):
        """Загружает файл захвата"""
        try:
            print(f"📂 Загружаю: {self.filename.split(chr(92))[-1]}...")
            # Disable dumpcap output
            import warnings
            warnings.filterwarnings('ignore')
            self.cap = pyshark.FileCapture(self.filename, keep_packets=False)
            self.cap.load_packets()
            return True
        except Exception as e:
            print(f"❌ Ошибка загрузки: {e}")
            return False
    
    def analyze(self):
        """Анализирует пакеты в файле"""
        if not self.cap:
            return False
        
        try:
            for packet_num, packet in enumerate(self.cap, 1):
                self.analyze_packet(packet)
                
                if packet_num % 1000 == 0:
                    print(f"  ⏳ Обработано {packet_num} пакетов...")
            
            print(f"  ✓ Обработано {self.stats['total_packets']} пакетов")
            return True
            
        except Exception as e:
            print(f"❌ Ошибка анализа: {e}")
            return False
    
    def analyze_packet(self, packet):
        """Анализирует отдельный пакет"""
        self.stats['total_packets'] += 1
        
        try:
            # Проверяем IPv4
            if 'IP' in packet:
                self.analyze_ipv4(packet)
            elif 'IPv6' in packet:
                pass  # Пока пропускаем IPv6
            
            # DNS анализ
            if 'DNS' in packet:
                self.analyze_dns(packet)
            
            # TLS/SSL
            if 'TLS' in packet:
                self.stats['https_packets'] += 1
        except:
            pass
    
    def analyze_ipv4(self, packet):
        """Анализирует IPv4 пакет"""
        try:
            self.stats['ipv4_packets'] += 1
            ip_layer = packet['IP']
            
            src_ip = ip_layer.src
            dst_ip = ip_layer.dst
            
            self.stats['src_ips'][src_ip] += 1
            self.stats['dst_ips'][dst_ip] += 1
            
            # TCP анализ
            if 'TCP' in packet:
                self.analyze_tcp(packet, src_ip, dst_ip)
            
            # UDP анализ
            elif 'UDP' in packet:
                self.analyze_udp(packet, src_ip, dst_ip)
            
            # ICMP анализ
            elif 'ICMP' in packet:
                self.stats['icmp_packets'] += 1
        
        except Exception as e:
            pass
    
    def analyze_tcp(self, packet, src_ip, dst_ip):
        """Анализирует TCP сегмент"""
        try:
            self.stats['tcp_packets'] += 1
            tcp_layer = packet['TCP']
            
            src_port = int(tcp_layer.srcport)
            dst_port = int(tcp_layer.dstport)
            flags = tcp_layer.flags
            
            # Запись соединения
            conn_key = f"{src_ip}:{src_port} → {dst_ip}:{dst_port}"
            self.stats['connections'][conn_key] += 1
            self.stats['ports_dst'][dst_port] += 1
            self.stats['ports_src'][src_port] += 1
            
            # TCP флаги
            if flags:
                self.stats['tcp_flags'][flags] += 1
                
                # Проверяем на проблемы
                if 'R' in flags:  # RST флаг
                    self.stats['rst_connections'].append(conn_key)
                    self.stats['connection_resets'].append({
                        'connection': conn_key,
                        'reason': 'Сервер сбросил соединение (RST)',
                        'packet': packet.frame_info.frame_number if hasattr(packet.frame_info, 'frame_number') else '?'
                    })
                
                # SYN без ACK - попытка подключения
                if 'S' in flags and 'A' not in flags:
                    pass  # Normal SYN
                
                # FIN - завершение соединения
                if 'F' in flags:
                    pass  # Normal close
        
        except Exception as e:
            pass
    
    def analyze_udp(self, packet, src_ip, dst_ip):
        """Анализирует UDP пакет"""
        try:
            self.stats['udp_packets'] += 1
            udp_layer = packet['UDP']
            
            dst_port = int(udp_layer.dstport)
            self.stats['ports_dst'][dst_port] += 1
            
            # DNS на порту 53
            if dst_port == 53:
                self.stats['dns_packets'] += 1
        
        except:
            pass
    
    def analyze_dns(self, packet):
        """Анализирует DNS запросы/ответы"""
        try:
            dns_layer = packet['DNS']
            # Проверяем на ошибки DNS
            if hasattr(dns_layer, 'flags') and 'R' in dns_layer.flags:
                # Это ответ
                if hasattr(dns_layer, 'response_code'):
                    rcode = dns_layer.response_code
                    if rcode != '0':  # 0 = no error
                        self.stats['dns_failures'].append({
                            'error': f"DNS ошибка: {rcode}",
                            'packet': packet
                        })
        except:
            pass
    
    def print_results(self):
        """Выводит результаты анализа"""
        print(f"\n  📊 Статистика:")
        print(f"     IPv4: {self.stats['ipv4_packets']}")
        print(f"     TCP: {self.stats['tcp_packets']}")
        print(f"     UDP: {self.stats['udp_packets']}")
        print(f"     ICMP: {self.stats['icmp_packets']}")
        print(f"     DNS: {self.stats['dns_packets']}")
        print(f"     HTTPS/TLS: {self.stats['https_packets']}")
        
        if self.stats['src_ips']:
            print(f"\n  📤 Исходящие IP (топ-5):")
            for ip, count in self.stats['src_ips'].most_common(5):
                print(f"     {ip}: {count}")
        
        if self.stats['dst_ips']:
            print(f"\n  📥 Целевые IP (топ-5):")
            for ip, count in self.stats['dst_ips'].most_common(5):
                print(f"     {ip}: {count}")
        
        if self.stats['ports_dst']:
            print(f"\n  🔌 Целевые порты (топ-10):")
            for port, count in self.stats['ports_dst'].most_common(10):
                print(f"     {port}: {count}")
        
        if self.stats['tcp_flags']:
            print(f"\n  🚩 TCP флаги:")
            for flags, count in self.stats['tcp_flags'].most_common():
                print(f"     {flags}: {count}")
    
    def get_issues(self):
        """Возвращает найденные проблемы"""
        issues = []
        
        if self.stats['connection_resets']:
            issues.append({
                'severity': 'HIGH',
                'title': 'Сброс соединения (RST)',
                'count': len(self.stats['connection_resets']),
                'detail': 'Сервер или маршрутизатор отказывают в соединении'
            })
        
        if self.stats['dns_failures']:
            issues.append({
                'severity': 'MEDIUM',
                'title': 'Ошибки DNS',
                'count': len(self.stats['dns_failures']),
                'detail': 'Не удается разрешить доменные имена'
            })
        
        # Проверяем на необычные паттерны
        if self.stats['tcp_packets'] > 0 and len(self.stats['connections']) < 5:
            if self.stats['connection_resets']:
                issues.append({
                    'severity': 'HIGH',
                    'title': 'Невозможно установить соединение',
                    'count': 1,
                    'detail': 'Очень мало успешных соединений, много сбросов'
                })
        
        return issues

def main():
    files = [
        r'd:\VS\zapret-discord-youtube\asdasd\asd.cap',
        r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    ]
    
    print("\n" + "="*70)
    print("АНАЛИЗ СЕТЕВЫХ ЗАХВАТОВ ENDFIELD.EXE")
    print("="*70 + "\n")
    
    all_issues = []
    
    for filename in files:
        analyzer = NetworkCapAnalyzer(filename)
        if analyzer.load_capture() and analyzer.analyze():
            analyzer.print_results()
            issues = analyzer.get_issues()
            all_issues.extend([(filename.split(chr(92))[-1], issue) for issue in issues])
    
    # Вывод проблем
    print("\n" + "="*70)
    print("ВЫЯВЛЕННЫЕ ПРОБЛЕМЫ")
    print("="*70 + "\n")
    
    if all_issues:
        for filename, issue in all_issues:
            severity_icon = "🔴" if issue['severity'] == 'HIGH' else "🟡"
            print(f"{severity_icon} [{filename}] {issue['title']}")
            print(f"   Найдено: {issue['count']}")
            print(f"   Описание: {issue['detail']}\n")
    else:
        print("✓ Критических проблем не обнаружено\n")
    
    print("="*70)
    print("РЕКОМЕНДАЦИИ")
    print("="*70 + "\n")
    
    if all_issues:
        for _, issue in all_issues:
            if 'Сброс' in issue['title']:
                print("1. Проверьте список правил брандмауэра")
                print("2. Убедитесь, что приложение не заблокировано")
                print("3. Если используется VPN, попробуйте отключить")
                print("4. Проверьте, не блокирует ли ISP соединение\n")
            elif 'DNS' in issue['title']:
                print("1. Смените DNS серверы (1.1.1.1 или 8.8.8.8)")
                print("2. Очистите кеш DNS: ipconfig /flushdns")
                print("3. Проверьте соединение с интернетом\n")
    else:
        print("✓ Соединение выглядит стабильным")
        print("  Если проблемы все еще есть, проверьте:\n")
        print("  1. Наличие интернета и скорость соединения")
        print("  2. Брандмауэр Windows и антивирус")
        print("  3. Параметры локальной сети (proxy, VPN)")
        print("  4. Обновление драйверов сетевой карты\n")

if __name__ == '__main__':
    main()
