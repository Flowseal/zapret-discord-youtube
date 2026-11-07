"""Import Flowseal BAT files as data, without executing downloaded code."""
import ipaddress
import json
from pathlib import Path
import re
import shlex

BEGIN = '# BEGIN zapret-macos-cli'
END = '# END zapret-macos-cli'
SAFE_OPTIONS = set(('dpi-desync dpi-desync-any-protocol dpi-desync-badseq-increment '
    'dpi-desync-cutoff dpi-desync-fake-discord dpi-desync-fake-http dpi-desync-fake-quic '
    'dpi-desync-fake-stun dpi-desync-fake-tls dpi-desync-fake-tls-mod dpi-desync-fake-unknown '
    'dpi-desync-fake-unknown-udp dpi-desync-fakedsplit-pattern dpi-desync-fooling '
    'dpi-desync-hostfakesplit-mod dpi-desync-repeats dpi-desync-split-pos '
    'dpi-desync-split-seqovl dpi-desync-split-seqovl-pattern filter-l3 filter-l7 '
    'filter-tcp filter-udp hostlist hostlist-domains hostlist-exclude '
    'hostlist-exclude-domains ip-id ipset ipset-exclude new wf-tcp wf-udp').split())


def validate_tokens(args):
    for token in args:
        key, _, value = token.partition('=')
        if key.removeprefix('--') not in SAFE_OPTIONS or not token.startswith('--'):
            raise ValueError('Недопустимая опция стратегии: ' + key)
        if '/' in value or '\\' in value or '@' in value:
            if not re.fullmatch(r'@(BIN|LISTS)@/[A-Za-z0-9_-]+\.(bin|txt)', value):
                raise ValueError('Недопустимый путь стратегии')
        if any(ord(c) < 32 for c in token):
            raise ValueError('Управляющий символ в стратегии')


def port_range(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*', value):
        raise ValueError('Порты: число или диапазон через дефис, список через запятую')
    result = []
    for part in value.split(','):
        ends = [int(x) for x in part.split('-')]
        if not all(1 <= x <= 65535 for x in ends) or ends[0] > ends[-1]:
            raise ValueError('Диапазон портов должен быть внутри 1-65535')
        result.append(':'.join(map(str, ends)))
    return result


def profiles(args):
    result = [[]]
    for arg in args:
        if arg == '--new':
            result.append([])
        else:
            result[-1].append(arg)
    return result


def catalog_order(item):
    name = item['name'].casefold().replace('(', '').replace(')', '')
    return [int(part) if part.isdecimal() else part for part in re.split(r'(\d+)', name)]


def import_catalog(source):
    result = []
    for path in sorted(source.glob('general*.bat')):
        text = path.read_text(encoding='utf-8-sig').replace('^\n', ' ')
        match = re.search(r'"%BIN%winws\.exe"\s+(.+)', text, re.I)
        if not match:
            raise ValueError('Не найден winws: ' + path.name)
        command = match[1].strip().replace('%BIN%', '@BIN@/').replace('%LISTS%', '@LISTS@/').replace('^!', '!')
        args = shlex.split(command)
        validate_tokens(args)
        if any(not x.startswith('--') or '\n' in x or '\r' in x for x in args):
            raise ValueError('Неожиданный формат: ' + path.name)
        if any(re.search(r'%(?!GameFilter(?:TCP|UDP)?%)', x.replace('%GameFilterTCP%', '').replace('%GameFilterUDP%', '')) for x in args):
            raise ValueError('Неизвестная переменная: ' + path.name)
        ident = re.sub(r'[^a-z0-9]+', '-', path.stem.lower()).strip('-')
        result.append({'id': ident, 'name': path.stem, 'source': path.name, 'args': args})
    if not result or len({x['id'] for x in result}) != len(result):
        raise ValueError('Пустой каталог или повторяющиеся имена стратегий')
    return sorted(result, key=catalog_order)


def compile_strategy(item, vendor, lists, settings):
    validate_tokens(item['args'])
    game = settings['game']
    if game not in ('off', 'tcp', 'udp', 'all') or settings['ipset'] not in ('loaded', 'none', 'any'):
        raise ValueError('Неизвестный режим фильтра')
    enabled = {p: game in (p, 'all') for p in ('tcp', 'udp')}
    for p in enabled:
        port_range(settings[p])
    ports = {'tcp': [], 'udp': []}
    output = []
    for block in profiles(item['args']):
        if any(x == '--filter-' + p + '=%GameFilter' + p.upper() + '%' and not enabled[p] for p in enabled for x in block):
            continue
        translated = []
        for token in block:
            if token.startswith(('--wf-tcp=', '--wf-udp=')):
                proto = token[5:8]
                value = token.split('=', 1)[1]
                value = value.replace('%GameFilter' + proto.upper() + '%', settings[proto] if enabled[proto] else '').strip(',')
                ports[proto] = port_range(value) if value else []
                continue
            if token.startswith('--wf-'):
                raise ValueError('Не поддержан WinDivert-фильтр: ' + token)
            token = token.replace('%GameFilterTCP%', settings['tcp']).replace('%GameFilterUDP%', settings['udp'])
            if token.startswith('--ipset=') and token.endswith('@LISTS@/ipset-all.txt'):
                target = lists/'ipset-all.txt' if settings['ipset'] == 'loaded' else vendor/('ipset-' + settings['ipset'] + '.txt')
                token = '--ipset=' + str(target)
            token = token.replace('@BIN@', str(vendor/'bin')).replace('@LISTS@', str(lists))
            if '%' in token or '@BIN@' in token or '@LISTS@' in token:
                raise ValueError('Необработанная подстановка')
            translated.append(token)
        if translated:
            if output: output.append('--new')
            output.extend(translated)
    return output, ports


def validate_networks(text):
    count = 0
    for line in text.splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            ipaddress.ip_network(line, strict=False)
            count += 1
    if not count: raise ValueError('Пустой IPSet')
    return text


def merge_hosts(original, addition):
    if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
        raise ValueError('Повреждён блок hosts, требуется ручная проверка')
    if BEGIN in original:
        lines = original.splitlines()
        if BEGIN not in lines or END not in lines or lines.index(BEGIN) > lines.index(END):
            raise ValueError('Повреждён блок hosts, требуется ручная проверка')
    clean = re.sub(re.escape(BEGIN) + r'\n.*?' + re.escape(END) + r'\n?', '', original, flags=re.S)
    rows = []
    for line in addition.splitlines():
        fields = line.split('#', 1)[0].split()
        if not fields: continue
        address = ipaddress.ip_address(fields[0])
        if address.is_loopback or address.is_unspecified or len(fields) < 2:
            raise ValueError('Некорректная hosts-запись')
        for host in fields[1:]:
            if not re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', host) or host.lower() == 'localhost':
                raise ValueError('Некорректное имя в hosts')
        rows.append(' '.join(fields))
    if not rows: return clean
    if not clean.endswith('\n'): clean += '\n'
    return clean + BEGIN + '\n' + '\n'.join(rows) + '\n' + END + '\n'


def prepare_vendor(source, target):
    import shutil
    target.mkdir(parents=True, exist_ok=True)
    (target/'bin').mkdir()
    (target/'lists').mkdir()
    catalog = import_catalog(source)
    for path in (source/'bin').glob('*.bin'):
        shutil.copyfile(path, target/'bin'/path.name)
    for path in (source/'lists').glob('*.txt'):
        shutil.copyfile(path, target/'lists'/path.name)
    for name in ('list-general-user.txt', 'list-exclude-user.txt', 'ipset-exclude-user.txt'):
        (target/'lists'/name).touch()
    # Flowseal's default IPSet can be a placeholder; loaded uses the full backup.
    full = source/'lists/ipset-all.txt.backup'
    if full.exists(): shutil.copyfile(full, target/'lists/ipset-all.txt')
    (target/'ipset-any.txt').write_text('0.0.0.0/0\n::/0\n')
    (target/'ipset-none.txt').write_text('203.0.113.113/32\n2001:db8::1/128\n')
    (target/'catalog.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2)+'\n')
    shutil.copyfile(source/'LICENSE.txt', target/'LICENSE-Flowseal.txt')
    shutil.copyfile(source/'.service/hosts', target/'hosts')
    return catalog


if __name__ == '__main__':
    import sys
    prepare_vendor(Path(sys.argv[1]), Path(sys.argv[2]))
