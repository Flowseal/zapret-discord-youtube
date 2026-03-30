#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Извлечение всех IP адресов из сетевых захватов Endfield
"""

import struct
from collections import Counter, defaultdict

class IPExtractor:
    def __init__(self, filename):
        self.filename = filename
        self.all_ips = set()
        self.src_ips = Counter()
        self.dst_ips = Counter()
        self.connections = defaultdict(int)
    
    def extract(self):
        """Извлекает все IP из файла"""
        try:
            with open(self.filename, 'rb') as f:
                data = f.read()
                self.extract_ips_from_data(data)
                return True
        except Exception as e:
            print(f"❌ Ошибка: {e}")
            return False
    
    def extract_ips_from_data(self, data):
        """Ищет все IP адреса в бинарных данных"""
        i = 0
        while i < len(data) - 20:
            try:
                # Проверяем версию IPv4 (первый полубайт = 4)
                version = (data[i] >> 4)
                if version == 4:
                    # Получаем длину заголовка (второй полубайт * 4)
                    ihl = (data[i] & 0x0f) * 4
                    if ihl < 20:
                        i += 1
                        continue
                    
                    # Проверяем общую длину пакета
                    total_length = struct.unpack('>H', data[i+2:i+4])[0]
                    if total_length < 20 or i + total_length > len(data):
                        i += 1
                        continue
                    
                    src_ip = '.'.join(str(b) for b in data[i+12:i+16])
                    dst_ip = '.'.join(str(b) for b in data[i+16:i+20])
                    
                    if self.is_valid_ip(src_ip) and self.is_valid_ip(dst_ip):
                        self.all_ips.add(src_ip)
                        self.all_ips.add(dst_ip)
                        self.src_ips[src_ip] += 1
                        self.dst_ips[dst_ip] += 1
                        self.connections[f"{src_ip} → {dst_ip}"] += 1
                    
                    # Пропускаем на длину пакета, чтобы найти следующий
                    i += total_length
                else:
                    i += 1
            except:
                i += 1
    
    @staticmethod
    def is_valid_ip(ip):
        """Проверяет валидность IP"""
        try:
            parts = ip.split('.')
            if len(parts) != 4:
                return False
            for part in parts:
                num = int(part)
                if num < 0 or num > 255:
                    return False
            # Исключаем служебные диапазоны
            if ip.startswith('0.') or ip == '255.255.255.255':
                return False
            return True
        except:
            return False

def main():
    files = [
        r'd:\VS\zapret-discord-youtube\asdasd\asd.cap',
        r'd:\VS\zapret-discord-youtube\asdasd\dfgdfg.cap'
    ]
    
    all_unique_ips = set()
    all_src_ips = Counter()
    all_dst_ips = Counter()
    all_connections = Counter()
    
    print("\n" + "="*70)
    print("ПОЛНЫЙ СПИСОК IP АДРЕСОВ - ENDFIELD.EXE")
    print("="*70 + "\n")
    
    for filename in files:
        print(f"\n📄 Файл: {filename.split(chr(92))[-1]}")
        print("-" * 70)
        
        extractor = IPExtractor(filename)
        if extractor.extract():
            all_unique_ips.update(extractor.all_ips)
            all_src_ips.update(extractor.src_ips)
            all_dst_ips.update(extractor.dst_ips)
            all_connections.update(extractor.connections)
            
            print(f"\n  📍 Исходящие IP (всего {len(extractor.src_ips)}):")
            for ip, count in extractor.src_ips.most_common():
                print(f"     {ip}: {count}")
            
            print(f"\n  🎯 Целевые IP (всего {len(extractor.dst_ips)}):")
            for ip, count in extractor.dst_ips.most_common():
                print(f"     {ip}: {count}")
    
    # Итоговый список
    print("\n" + "="*70)
    print("ИТОГОВАЯ СТАТИСТИКА")
    print("="*70 + "\n")
    
    print(f"✓ Всего уникальных IP адресов: {len(all_unique_ips)}\n")
    
    print("📤 ВСЕ ИСХОДЯЩИЕ IP (отсортировано по частоте):")
    for ip, count in all_src_ips.most_common():
        print(f"  {ip}: {count}")
    
    print(f"\n📥 ВСЕ ЦЕЛЕВЫЕ IP (отсортировано по частоте):")
    for ip, count in all_dst_ips.most_common():
        print(f"  {ip}: {count}")
    
    # Экспорт в файл
    export_file = r'd:\VS\zapret-discord-youtube\utils\endfield_ips.txt'
    try:
        with open(export_file, 'w') as f:
            f.write("="*70 + "\n")
            f.write("СПИСОК IP АДРЕСОВ - ENDFIELD.EXE\n")
            f.write("="*70 + "\n\n")
            
            f.write(f"ВСЕГО УНИКАЛЬНЫХ IP: {len(all_unique_ips)}\n\n")
            
            f.write("ИСХОДЯЩИЕ IP (наш компьютер):\n")
            f.write("-"*70 + "\n")
            for ip, count in all_src_ips.most_common():
                f.write(f"{ip}: {count}\n")
            
            f.write("\n\nЦЕЛЕВЫЕ IP (серверы):\n")
            f.write("-"*70 + "\n")
            for ip, count in all_dst_ips.most_common():
                f.write(f"{ip}: {count}\n")
            
            f.write("\n\nВСЕ УНИКАЛЬНЫЕ IP (простой список):\n")
            f.write("-"*70 + "\n")
            for ip in sorted(all_unique_ips):
                f.write(f"{ip}\n")
            
            f.write("\n\nСОЕДИНЕНИЯ (исходящих → целевых):\n")
            f.write("-"*70 + "\n")
            for conn, count in all_connections.most_common(100):
                f.write(f"{conn}: {count}\n")
        
        print(f"\n✅ Результаты сохранены в: {export_file}")
    except Exception as e:
        print(f"\n❌ Ошибка при сохранении: {e}")
    
    print("\n" + "="*70 + "\n")

if __name__ == '__main__':
    main()
