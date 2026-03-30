#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Извлечение валидных IP адресов Endfield (фильтрованный список)
"""

import struct
from collections import Counter

class ValidIPExtractor:
    def __init__(self, filename):
        self.filename = filename
        self.src_ips = Counter()
        self.dst_ips = Counter()
    
    def extract(self):
        try:
            with open(self.filename, 'rb') as f:
                data = f.read()
                self.extract_ips_from_data(data)
                return True
        except Exception as e:
            print(f"❌ Ошибка: {e}")
            return False
    
    def extract_ips_from_data(self, data):
        """Парсит IP пакеты правильно"""
        i = 0
        while i < len(data) - 20:
            try:
                version = (data[i] >> 4)
                if version == 4:
                    ihl = (data[i] & 0x0f) * 4
                    if ihl < 20 or i + ihl + 20 > len(data):
                        i += 1
                        continue
                    
                    total_length = struct.unpack('>H', data[i+2:i+4])[0]
                    if total_length < 20 or i + total_length > len(data):
                        i += 1
                        continue
                    
                    src_ip = '.'.join(str(b) for b in data[i+12:i+16])
                    dst_ip = '.'.join(str(b) for b in data[i+16:i+20])
                    
                    # Проверяем валидность (только публичные и приватные сети)
                    if self.is_valid_and_significant(src_ip):
                        self.src_ips[src_ip] += 1
                    if self.is_valid_and_significant(dst_ip):
                        self.dst_ips[dst_ip] += 1
                    
                    i += max(total_length, 20)
                else:
                    i += 1
            except:
                i += 1
    
    @staticmethod
    def is_valid_and_significant(ip):
        """Проверяет валидность и значимость IP"""
        try:
            parts = [int(x) for x in ip.split('.')]
            if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
                return False
            
            # Исключаем зарезервированные диапазоны
            first = parts[0]
            
            # Исключаем все подозрительные диапазоны
            if first in [0, 255]:  # Reserved
                return False
            if first == 127:  # Loopback
                return False
            if first == 169 and parts[1] == 254:  # Link-local
                return False
            if first in [224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235]:  # Multicast
                return False
            if first >= 240:  # Reserved for future use
                return False
            
            return True
        except:
            return False

def main():
    files = [
        r'd:\VS\zapret-discord-youtube\asdasd\asd.cap',
        r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    ]
    
    all_src = Counter()
    all_dst = Counter()
    
    print("\n" + "="*70)
    print("ВАЛИДНЫЕ IP АДРЕСА - ENDFIELD.EXE")
    print("="*70 + "\n")
    
    for filename in files:
        print(f"📄 Обработка: {filename.split(chr(92))[-1]}...")
        extractor = ValidIPExtractor(filename)
        if extractor.extract():
            all_src.update(extractor.src_ips)
            all_dst.update(extractor.dst_ips)
    
    # Объединяем и получаем уникальные IP
    all_ips = set(all_src.keys()) | set(all_dst.keys())
    
    print(f"\n✓ Всего уникальных IP: {len(all_ips)}\n")
    
    print("📤 ИСХОДЯЩИЕ IP (твой компьютер):")
    print("-" * 70)
    for ip, count in all_src.most_common():
        print(f"  {ip:<20} {count:>6} пакетов")
    
    print(f"\n📥 ЦЕЛЕВЫЕ IP (серверы):")
    print("-" * 70)
    for ip, count in all_dst.most_common():
        print(f"  {ip:<20} {count:>6} пакетов")
    
    # Сохранение простого списка
    export_file = r'd:\VS\zapret-discord-youtube\utils\endfield_ips_clean.txt'
    try:
        with open(export_file, 'w') as f:
            f.write("ИСХОДЯЩИЕ IP (исходные адреса):\n")
            f.write("-" * 70 + "\n")
            for ip, count in all_src.most_common():
                f.write(f"{ip}\n")
            
            f.write("\n\nЦЕЛЕВЫЕ IP (целевые адреса серверов):\n")
            f.write("-" * 70 + "\n")
            for ip, count in all_dst.most_common():
                f.write(f"{ip}\n")
            
            f.write("\n\nВСЕ УНИКАЛЬНЫЕ IP (отсортировано):\n")
            f.write("-" * 70 + "\n")
            for ip in sorted(all_ips):
                f.write(f"{ip}\n")
        
        print(f"\n✅ Чистый список сохранен в: {export_file}")
    except Exception as e:
        print(f"❌ Ошибка при сохранении: {e}")
    
    print("\n" + "="*70 + "\n")

if __name__ == '__main__':
    main()
