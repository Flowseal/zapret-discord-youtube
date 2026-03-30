#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Финальный список реальных IP адресов Endfield
"""

import struct
from collections import Counter

class RealIPExtractor:
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
        except:
            return False
    
    def extract_ips_from_data(self, data):
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
                    
                    if self.is_real_ip(src_ip):
                        self.src_ips[src_ip] += 1
                    if self.is_real_ip(dst_ip):
                        self.dst_ips[dst_ip] += 1
                    
                    i += max(total_length, 20)
                else:
                    i += 1
            except:
                i += 1
    
    @staticmethod
    def is_real_ip(ip):
        """Проверяет реальный ли это IP (не зарезервированный и не служебный)"""
        try:
            parts = [int(x) for x in ip.split('.')]
            if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
                return False
            
            first = parts[0]
            second = parts[1]
            third = parts[2]
            fourth = parts[3]
            
            # Исключаем служебные диапазоны
            if first in [0, 255]:
                return False
            if first == 10:  # Private
                return True  # Но это приватный IP
            if first == 127:  # Loopback
                return False
            if first == 169 and second == 254:  # Link-local
                return False
            if first == 172 and 16 <= second <= 31:  # Private
                return True
            if first == 192 and second == 168:  # Private
                return True
            if first >= 224:  # Multicast и Reserved
                return False
            if first == 1:  # Dubious
                return False
            if first == 2:  # Dubious
                return False
            if first == 3:  # Dubious
                return False
            
            # Исключаем нулевые последние октеты (сетевые адреса)
            if fourth == 0 or fourth == 255:
                return False
            
            # Исключаем крайне редкие или подозрительные адреса
            if parts[1] == 0 and parts[2] == 0 and parts[3] < 5:
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
    
    for filename in files:
        extractor = RealIPExtractor(filename)
        extractor.extract()
        all_src.update(extractor.src_ips)
        all_dst.update(extractor.dst_ips)
    
    all_ips = set(all_src.keys()) | set(all_dst.keys())
    
    print("\n" + "="*70)
    print("IP АДРЕСА ENDFIELD.EXE")
    print("="*70 + "\n")
    
    print(f"✓ Всего IP адресов: {len(all_ips)}\n")
    
    # Главный IP твоего компьютера
    if '192.168.31.67' in all_src or '192.168.31.67' in all_dst:
        print("🔵 ТВЙ КОМПЬЮТЕР (локальный):")
        print(f"  192.168.31.67 (основной IP)\n")
    
    # Серверы игры (целевые IP)
    print("🎮 ИГРОВЫЕ СЕРВЕРЫ (основные целевые адреса):")
    print("-" * 70)
    for ip, count in all_dst.most_common(20):
        print(f"  {ip:<20} ({count:>4} пакетов)")
    
    # Экспорт
    export_file = r'd:\VS\zapret-discord-youtube\utils\endfield_ips_real.txt'
    try:
        with open(export_file, 'w') as f:
            f.write("ИГРОВЫЕ СЕРВЕРЫ ENDFIELD\n")
            f.write("="*70 + "\n\n")
            
            for ip, count in all_dst.most_common():
                f.write(f"{ip}\n")
        
        print(f"\n✅ Сохранено в: {export_file.split(chr(92))[-1]}")
    except:
        pass
    
    print("\n" + "="*70 + "\n")

if __name__ == '__main__':
    main()
