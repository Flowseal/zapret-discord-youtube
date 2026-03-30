#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Строгий анализ с фильтрацией мусора
"""

import struct
from collections import Counter

class StrictIPExtractor:
    def __init__(self, filename):
        self.filename = filename
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
        valid_packets = 0
        
        while i < len(data) - 20:
            try:
                version = (data[i] >> 4)
                if version != 4:
                    i += 1
                    continue
                
                ihl = (data[i] & 0x0f) * 4
                if ihl < 20 or ihl > 60:
                    i += 1
                    continue
                
                ttl = data[i+8]
                if ttl == 0 or ttl > 255:
                    i += 1
                    continue
                
                protocol = data[i+9]
                
                total_length = struct.unpack('>H', data[i+2:i+4])[0]
                if total_length < 20 or total_length > 65535 or i + total_length > len(data):
                    i += 1
                    continue
                
                # Дополнительная проверка - есть ли в пакете реальные данные
                if total_length < 40:  # Минимум для реального пакета
                    i += 1
                    continue
                
                src_ip = '.'.join(str(b) for b in data[i+12:i+16])
                dst_ip = '.'.join(str(b) for b in data[i+16:i+20])
                
                # Строгая фильтрация - только если это исходящий пакет
                # (src = 192.168.31.67 = твой IP, dst = целевой сервер)
                if src_ip == '192.168.31.67' and self.is_public_ip(dst_ip):
                    self.dst_ips[dst_ip] += 1
                    valid_packets += 1
                
                i += max(total_length, 20)
            except:
                i += 1
    
    @staticmethod
    def is_public_ip(ip):
        """Проверяет только публичные IP"""
        try:
            parts = [int(x) for x in ip.split('.')]
            if len(parts) != 4:
                return False
            
            if any(p < 0 or p > 255 for p in parts):
                return False
            
            first = parts[0]
            
            # Только публичные адреса
            # Исключаем локальные
            if first == 192 and parts[1] == 168:
                return False
            if first == 10:
                return False
            if first == 172 and 16 <= parts[1] <= 31:
                return False
            
            # Исключаем служебные
            if first in [0, 255]:
                return False
            if first == 127:
                return False
            if first >= 224:  # Multicast
                return False
            if first in [1, 2, 3, 5]:  # Dubious ranges
                return False
            
            # Нулевые IP
            if parts[3] == 0:
                return False
            
            return True
        except:
            return False

def main():
    files = [
        r'd:\VS\zapret-discord-youtube\asdasd\asd.cap',
        r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    ]
    
    all_dst = Counter()
    
    for filename in files:
        print(f"📄 Анализирую: {filename.split(chr(92))[-1]}...")
        extractor = StrictIPExtractor(filename)
        if extractor.extract():
            all_dst.update(extractor.dst_ips)
            print(f"   ✓ Найдено IP: {len(extractor.dst_ips)}")
    
    print("\n" + "="*70)
    print("ЦЕЛЕВЫЕ СЕРВЕРЫ ENDFIELD (строгий анализ)")
    print("="*70 + "\n")
    
    print(f"✓ Всего уникальных целевых IP: {len(all_dst)}\n")
    
    if all_dst:
        print("🎯 СЕРВЕРЫ (отсортировано по частоте):\n")
        for ip, count in all_dst.most_common():
            print(f"  {ip:<20} {count:>5} пакетов")
    
    # Экспорт
    export_file = r'd:\VS\zapret-discord-youtube\utils\endfield_servers.txt'
    try:
        with open(export_file, 'w') as f:
            f.write("ЦЕЛЕВЫЕ IP АДРЕСА ENDFIELD\n")
            f.write("="*70 + "\n\n")
            for ip, count in all_dst.most_common():
                f.write(f"{ip}\n")
        print(f"\n✅ Сохранено: endfield_servers.txt")
    except:
        pass
    
    print("\n" + "="*70 + "\n")

if __name__ == '__main__':
    main()
