"""Terminal management for the native Flowseal utun/BPF engine (macOS 14+)."""
import contextlib
import fcntl
import hashlib
import io
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from strategies import (compile_strategy, import_catalog, merge_hosts, port_range,
                        prepare_vendor, validate_networks)

BASE = Path('/Library/Application Support/ZapretCLI')
STATE = Path('/Library/Application Support/ZapretCLI-state')
RUN = Path('/var/run/zapret-macos-cli')
LABEL = 'io.github.zapret-macos-cli'
PLIST = Path('/Library/LaunchDaemons')/(LABEL+'.plist')
AUTO_LABEL = LABEL+'.updater'
AUTO_PLIST = PLIST.with_name(AUTO_LABEL+'.plist')
ANCHOR = 'com.apple/zapret-macos-cli'
DEFAULTS = dict(strategy='general-alt11', game='off', tcp='1024-65535',
                udp='1024-65535', ipset='loaded')
PYTHON = '/usr/bin/python3'
ENV = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8', HOME='/var/root')


def command(args, check=True, **kwargs):
    return subprocess.run([str(x) for x in args], check=check, env=ENV,
                          text=True, capture_output=True, **kwargs)


def atomic_write(path, text, mode=0o644):
    path = Path(path)
    if path.is_symlink(): raise ValueError('Симлинк вместо файла: '+str(path))
    fd, name = tempfile.mkstemp(prefix='.'+path.name+'-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def validate_settings(settings, catalog=None):
    if set(settings) != set(DEFAULTS): raise ValueError('Некорректные поля настроек')
    if not isinstance(settings['strategy'], str) or not re.fullmatch(r'general(?:-[a-z0-9]+)*', settings['strategy']):
        raise ValueError('Некорректная стратегия')
    if settings['game'] not in ('off','tcp','udp','all') or settings['ipset'] not in ('loaded','none','any'):
        raise ValueError('Некорректный режим фильтра')
    for p in ('tcp','udp'): port_range(settings[p])
    if catalog is not None and settings['strategy'] not in [x['id'] for x in catalog]:
        raise ValueError('Стратегия отсутствует в каталоге')
    return settings


def catalog_at(root):
    return json.loads((root/'vendor/catalog.json').read_text())


def settings_at():
    path = STATE/'settings.json'
    return validate_settings(json.loads(path.read_text())) if path.exists() else dict(DEFAULTS)


def pf_rules(iface, ports):
    if not re.fullmatch(r'en[0-9]+', iface):
        raise ValueError('Нужен физический Ethernet/Wi-Fi default route (enN); VPN/TUN не перехватывается')
    # Same non-global exclusion as WinDivert's default --wf-filter-lan=1.
    networks = '0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,198.18.0.0/15,224.0.0.0/4,240.0.0.0/4'
    rules = ['table <localnets> const { '+networks+' }']
    for proto in ('tcp','udp'):
        if ports[proto]:
            # Round-trip validation prevents PF syntax injection.
            values = port_range(','.join(ports[proto]).replace(':','-'))
            rules.append('pass out quick on '+iface+' route-to (utun50 10.77.0.2) inet proto '+proto+
                         ' from any to ! <localnets> port { '+','.join(values)+' } user { >root } no state')
    return '\n'.join(rules)+'\n'


def check_engine(root, vendor, lists, settings, all_strategies=False):
    catalog = catalog_at(root) if vendor == root/'vendor' else json.loads((vendor/'catalog.json').read_text())
    validate_settings(settings, catalog)
    selected = catalog if all_strategies else [x for x in catalog if x['id'] == settings['strategy']]
    result = None
    for item in selected:
        args, ports = compile_strategy(item, vendor, lists, settings)
        test = command([root/'bin/utunws', '--dry-run', *args], check=False, timeout=20)
        if test.returncode:
            raise ValueError(item['name']+': '+(test.stdout+test.stderr)[-2400:])
        result = (args, ports)
    return result


def secure_dir(path):
    if path.is_symlink(): raise ValueError('Симлинк вместо каталога: '+str(path))
    path.mkdir(mode=0o755, parents=False, exist_ok=True)
    info = path.stat()
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('Каталог должен принадлежать root и быть недоступен для записи другим: '+str(path))


def safe_tree(root):
    for path in [root, *root.rglob('*')]:
        info = path.lstat()
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError('Необычный файл/симлинк в пакете: '+str(path))


def job_loaded(label=LABEL):
    return command(['/bin/launchctl','print','system/'+label], check=False).returncode == 0


def auto_settings():
    path = STATE/'auto-update.json'
    state = json.loads(path.read_text()) if path.exists() else dict(enabled=False,last_check=0)
    if (set(state) != {'enabled','last_check'} or type(state['enabled']) is not bool or
        not isinstance(state['last_check'],(int,float)) or not math.isfinite(state['last_check']) or state['last_check'] < 0):
        raise ValueError('Некорректные настройки автообновления')
    return state


def sync_auto_job(enabled=None):
    if enabled is None: enabled = auto_settings()['enabled']
    if enabled:
        payload = dict(Label=AUTO_LABEL, ProgramArguments=[PYTHON,'-I',str(BASE/'manager.py'),'auto-update'],
                       StartInterval=3600, RunAtLoad=True, WorkingDirectory=str(BASE),
                       StandardOutPath=str(STATE/'auto-update.log'), StandardErrorPath=str(STATE/'auto-update.log'),
                       EnvironmentVariables=ENV)
        atomic_write(AUTO_PLIST,plistlib.dumps(payload).decode())
        if not job_loaded(AUTO_LABEL):
            command(['/bin/launchctl','enable','system/'+AUTO_LABEL])
            command(['/bin/launchctl','bootstrap','system',AUTO_PLIST])
    else:
        if job_loaded(AUTO_LABEL):
            command(['/bin/launchctl','bootout','system/'+AUTO_LABEL])
            for _ in range(100):
                if not job_loaded(AUTO_LABEL): break
                time.sleep(0.1)
            else: raise RuntimeError('Планировщик ещё завершает работу')
        AUTO_PLIST.unlink(missing_ok=True)


def set_auto_updates(enabled):
    if type(enabled) is not bool: raise ValueError('Нужен режим on или off')
    if enabled and not (BASE/'manager.py').is_file(): raise ValueError('Сначала установи программу через пункт 1')
    old = auto_settings(); new = dict(old,enabled=enabled)
    atomic_write(STATE/'auto-update.json',json.dumps(new)+'\n')
    try: sync_auto_job()
    except BaseException:
        atomic_write(STATE/'auto-update.json',json.dumps(old)+'\n')
        sync_auto_job(old['enabled'])
        raise
    print('Автообновление данных '+('включено: раз в сутки' if enabled else 'выключено'))


def auto_status():
    state = auto_settings()
    active = state['enabled'] and job_loaded(AUTO_LABEL)
    print('Автообновление данных: '+('включено (раз в сутки)' if active else 'выключено'))
    if state['enabled'] and not active: print('Режим сохранён, но планировщик не загружен; восстановится при установке службы.')
    if state['last_check']:
        print('Последняя успешная проверка: '+time.strftime('%d.%m.%Y %H:%M',time.localtime(state['last_check'])))


def stop_job():
    loaded = job_loaded()
    owned = loaded or (RUN/'ready.json').exists()
    if loaded: command(['/bin/launchctl','bootout','system/'+LABEL])
    cleanup_pf()
    (RUN/'ready.json').unlink(missing_ok=True)
    if owned:
        for _ in range(100):
            if not job_loaded() and command(['/sbin/ifconfig','utun50'],check=False).returncode != 0:
                break
            time.sleep(0.1)
        else: raise RuntimeError('Предыдущая служба ещё завершает работу; повторный запуск отменён')


def start_job():
    (RUN/'ready.json').unlink(missing_ok=True)
    command(['/bin/launchctl','enable','system/'+LABEL])
    command(['/bin/launchctl','bootstrap','system',PLIST])
    for _ in range(120):
        if (RUN/'ready.json').exists(): return
        time.sleep(0.1)
    stop_job()
    raise RuntimeError('Служба не запустилась. Лог: '+str(STATE/'service.log'))


def cleanup_pf(token=None):
    command(['/sbin/pfctl','-a',ANCHOR,'-F','all'],check=False)
    tokenfile = RUN/'pf-token'
    if token is None and tokenfile.exists():
        token = tokenfile.read_text().strip()
    if token and token.isdigit(): command(['/sbin/pfctl','-X',token],check=False)
    tokenfile.unlink(missing_ok=True)


def watchdog_cleanup(engine_pid):
    with open(RUN/'supervisor.lock','a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return
        # A new supervisor holding this lock owns its own rules and token.
        cleanup_pf()
        (RUN/'ready.json').unlink(missing_ok=True)
        try: os.kill(engine_pid,signal.SIGTERM)
        except ProcessLookupError: pass


def write_plist():
    payload = dict(Label=LABEL, ProgramArguments=[PYTHON,'-I',str(BASE/'manager.py'),'supervise'],
                   RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
                   StandardOutPath=str(STATE/'service.log'), StandardErrorPath=str(STATE/'service.log'),
                   WorkingDirectory=str(BASE), EnvironmentVariables=ENV)
    atomic_write(PLIST,plistlib.dumps(payload).decode())


def install_link():
    target = Path('/usr/local/bin/zapret')
    if not target.parent.exists(): target.parent.mkdir(parents=True,mode=0o755)
    if target.exists() or target.is_symlink():
        if not target.is_symlink() or os.readlink(target) != str(BASE/'zapret'):
            raise ValueError('/usr/local/bin/zapret уже занят; служба установлена, используй полный путь')
    else: target.symlink_to(BASE/'zapret')


def install(strategy):
    source = HERE
    for folder in (BASE.parent, STATE, RUN): secure_dir(folder)
    with open(STATE/'management.lock','a') as management_lock:
        fcntl.flock(management_lock,fcntl.LOCK_EX)
        if source == BASE:
            write_plist()
            change_settings('strategy',strategy)
            if not job_loaded(): start_job()
            install_link()
            sync_auto_job()
            return
        if not re.fullmatch(r'general(?:-[a-z0-9]+)*', strategy): raise ValueError('Стратегия')
        if BASE.exists(): secure_dir(BASE)
        target = Path('/usr/local/bin/zapret')
        if (target.exists() or target.is_symlink()) and (not target.is_symlink() or os.readlink(target) != str(BASE/'zapret')):
            raise ValueError('/usr/local/bin/zapret уже занят другой программой')
        backup = BASE.with_name('ZapretCLI.previous')
        if backup.exists(): raise ValueError('Осталась резервная копия установки: '+str(backup))
        stage = Path(tempfile.mkdtemp(prefix='.ZapretCLI-stage-',dir=BASE.parent))
        active = job_loaded()
        old_settings = (STATE/'settings.json').read_text() if (STATE/'settings.json').exists() else None
        old_plist = PLIST.read_text() if PLIST.exists() else None
        promoted = False; moved_old = False; stopped = False
        try:
            for name in ('manager.py','strategies.py','zapret','watchdog.sh','bin','vendor'):
                src = source/name
                if src.is_dir():
                    safe_tree(src)
                    shutil.copytree(src,stage/name)
                else:
                    if src.is_symlink() or not src.is_file(): raise ValueError('Некорректный файл установки')
                    shutil.copyfile(src,stage/name)
            safe_tree(stage)
            for path in [stage,*stage.rglob('*')]:
                path.chmod(0o755 if path.is_dir() or path.name in ('utunws','zapret','watchdog.sh') else 0o644)
            lists = STATE/'lists'
            if lists.exists(): safe_tree(lists)
            else: shutil.copytree(stage/'vendor/lists', lists)
            settings = settings_at(); settings['strategy'] = strategy
            check_engine(stage,stage/'vendor',lists,settings)
            if active:
                stop_job()
                stopped = True
            if BASE.exists():
                BASE.rename(backup)
                moved_old = True
            stage.rename(BASE); promoted = True
            atomic_write(STATE/'settings.json',json.dumps(settings,indent=2)+'\n')
            write_plist()
            if (STATE/'service.log').exists() and (STATE/'service.log').stat().st_size > 5_000_000:
                atomic_write(STATE/'service.log','')
            start_job()
            install_link()
        except BaseException:
            if promoted or moved_old:
                stop_job()
                if promoted: shutil.rmtree(BASE)
                if backup.exists(): backup.rename(BASE)
                if old_settings is None: (STATE/'settings.json').unlink(missing_ok=True)
                else: atomic_write(STATE/'settings.json',old_settings)
                if old_plist is None: PLIST.unlink(missing_ok=True)
                else: atomic_write(PLIST,old_plist)
            if stopped and BASE.exists(): start_job()
            raise
        else:
            try:
                if backup.exists(): shutil.rmtree(backup)
            except OSError:
                print('Новая служба работает; резервная копия удалена не полностью: '+str(backup))
            sync_auto_job()
            print('Служба установлена и запущена. Меню: zapret')
        finally:
            if stage.exists(): shutil.rmtree(stage)

def change_settings(key,value):
    if key not in DEFAULTS: raise ValueError('Неизвестная настройка')
    old = settings_at(); new = dict(old); new[key] = value
    check_engine(BASE,BASE/'vendor',STATE/'lists',new)
    active = job_loaded()
    if active: stop_job()
    old_text = (STATE/'settings.json').read_text()
    try:
        atomic_write(STATE/'settings.json',json.dumps(new,indent=2)+'\n')
        if active: start_job()
    except BaseException:
        if (STATE/'settings.json').read_text() != old_text:
            atomic_write(STATE/'settings.json',old_text)
        if active: start_job()
        raise
    print('Настройки сохранены'+('; служба перезапущена' if active else ''))


def route_info():
    text = command(['/sbin/route','-n','get','default']).stdout
    iface = re.search(r'interface:\s*(\S+)',text)
    gateway = re.search(r'gateway:\s*(\S+)',text)
    if not iface or not gateway: raise ValueError('Нет default route')
    iface, gateway = iface[1],gateway[1]
    pf_rules(iface,{'tcp':[],'udp':[]})
    import ipaddress
    ipaddress.IPv4Address(gateway)
    return iface,gateway


def supervise():
    secure_dir(RUN)
    with open(RUN/'supervisor.lock','w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        cleanup_pf()
        args, ports = check_engine(BASE,BASE/'vendor',STATE/'lists',settings_at())
        iface,gateway = route_info()
        if command(['/sbin/ifconfig','utun50'],check=False).returncode == 0:
            raise RuntimeError('utun50 занят другим приложением')
        rootrules = command(['/sbin/pfctl','-sr']).stdout
        if not re.search(r'^anchor "com\.apple/\*"',rootrules,re.M):
            raise RuntimeError('В активном PF нет com.apple/* anchor; основной ruleset не изменялся')
        command(['/sbin/ping','-c','1','-t','1',gateway],check=False,timeout=3)
        arp = command(['/usr/sbin/arp','-n',gateway]).stdout
        mac = re.search(r'\bat ([0-9a-fA-F:]+) ',arp)
        if not mac or not re.fullmatch(r'(?:[0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}',mac[1]):
            raise RuntimeError('Не найден MAC шлюза')
        env = dict(ENV,ZAPRET_IFACE=iface,ZAPRET_GATEWAY_MAC=mac[1],ZAPRET_UTUN_UNIT='51')
        engine = None; watcher = None; pf_token = None
        def interrupted(signum,frame): raise KeyboardInterrupt
        for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP): signal.signal(sig,interrupted)
        try:
            engine = subprocess.Popen([str(BASE/'bin/utunws'),*args],env=env)
            watcher = subprocess.Popen(['/bin/sh',str(BASE/'watchdog.sh'),str(os.getpid()),str(engine.pid)],env=ENV,start_new_session=True)
            for _ in range(100):
                if engine.poll() is not None: raise RuntimeError('Движок завершился')
                if command(['/sbin/ifconfig','utun50'],check=False).returncode == 0: break
                time.sleep(0.1)
            else: raise RuntimeError('utun50 не появился')
            command(['/sbin/ifconfig','utun50','10.77.0.1','10.77.0.2','netmask','255.255.255.255','mtu','1500','up'])
            rules = pf_rules(iface,ports)
            command(['/sbin/pfctl','-n','-a',ANCHOR,'-f','-'],input=rules)
            enabled = command(['/sbin/pfctl','-E'])
            match = re.search(r'Token\s*:\s*(\d+)',enabled.stdout+enabled.stderr)
            if not match: raise RuntimeError('PF не вернул reference token')
            pf_token = match[1]
            atomic_write(RUN/'pf-token',pf_token+'\n',0o600)
            command(['/sbin/pfctl','-a',ANCHOR,'-f','-'],input=rules)
            atomic_write(RUN/'ready.json',json.dumps(dict(pid=engine.pid,interface=iface,started=time.time()))+'\n')
            print('READY: IPv4, '+iface+' -> utun50; IPv6 не перехватывается',flush=True)
            while engine.poll() is None:
                time.sleep(2)
                if route_info() != (iface,gateway): raise RuntimeError('Default route изменился; перезапуск')
            raise RuntimeError('Движок завершился: '+str(engine.returncode))
        finally:
            try:
                cleanup_pf(pf_token)
                (RUN/'ready.json').unlink(missing_ok=True)
            finally:
                try:
                    if watcher and watcher.poll() is None:
                        watcher.terminate()
                        try: watcher.wait(timeout=3)
                        except subprocess.TimeoutExpired: watcher.kill(); watcher.wait()
                finally:
                    if engine and engine.poll() is None:
                        engine.terminate()
                        try: engine.wait(timeout=3)
                        except subprocess.TimeoutExpired: engine.kill(); engine.wait()


class HTTPSOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Небезопасный redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url, limit=32_000_000):
    if not url.startswith('https://'): raise ValueError('Требуется HTTPS')
    opener = urllib.request.build_opener(HTTPSOnlyRedirect())
    with opener.open(urllib.request.Request(url,headers={'User-Agent':'zapret-macos-cli'}),timeout=30) as response:
        if not response.url.startswith('https://'): raise ValueError('Небезопасный redirect')
        content = response.read(limit+1)
    if len(content)>limit: raise ValueError('Слишком большой ответ обновления')
    return content


def latest_commit():
    feed = download('https://github.com/Flowseal/zapret-discord-youtube/commits/main.atom',1_000_000)
    match = re.search(rb'<id>\s*tag:github.com,2008:Grit::Commit/([0-9a-f]{40})\s*</id>',feed)
    if not match: raise ValueError('Некорректный commit')
    return match[1].decode('ascii')


def check_updates():
    root = BASE if BASE.exists() else HERE
    path = root/'vendor/sources.json'
    installed = json.loads(path.read_text()).get('windows_commit') if path.exists() else None
    if not isinstance(installed,str) or not re.fullmatch('[0-9a-f]{40}',installed): installed = None
    available = latest_commit()
    changed = installed != available
    print('Установленные данные: '+(installed[:12] if installed else 'версия не отмечена'))
    print('Доступные данные: '+available[:12])
    print('Доступно обновление данных' if changed else 'Данные уже актуальны')
    return dict(installed=installed,available=available,update_available=changed)


def run_updates():
    revision = check_updates()
    if revision['update_available']: update_vendor(revision['available'])
    update_ipset()
    state = auto_settings()
    if state['enabled']:
        state['last_check'] = time.time()
        atomic_write(STATE/'auto-update.json',json.dumps(state)+'\n')


def automatic_update():
    state = auto_settings()
    if not state['enabled']: return
    if 0 <= time.time()-state['last_check'] < 86400: return
    run_updates()


def update_vendor(commit=None):
    if commit is None: commit = latest_commit()
    if not isinstance(commit,str) or not re.fullmatch('[0-9a-f]{40}',commit): raise ValueError('Некорректный commit')
    archive = download('https://codeload.github.com/Flowseal/zapret-discord-youtube/zip/'+commit)
    with tempfile.TemporaryDirectory(prefix='.update-',dir=STATE) as d:
        temp = Path(d); source = temp/'source'; source.mkdir()
        with zipfile.ZipFile(io.BytesIO(archive)) as z:
            total = 0
            for info in z.infolist():
                parts = Path(info.filename).parts[1:]
                if not parts or '..' in parts or any(p.startswith('/') for p in parts): continue
                relative = Path(*parts)
                wanted = (len(parts)==1 and (relative.match('general*.bat') or relative.name=='LICENSE.txt')) or (len(parts)==2 and ((parts[0]=='bin' and relative.suffix=='.bin') or (parts[0]=='lists' and (relative.suffix=='.txt' or relative.name=='ipset-all.txt.backup')) or (parts[0]=='.service' and parts[1]=='hosts')))
                if not wanted or info.is_dir(): continue
                total += info.file_size
                if total>32_000_000 or info.file_size>8_000_000: raise ValueError('Слишком большой архив')
                target = source/relative; target.parent.mkdir(exist_ok=True)
                target.write_bytes(z.read(info))
        candidate = temp/'vendor'; prepare_vendor(source,candidate)
        # The engine reopens these public lists after dropping root.
        temp.chmod(0o755)
        for path in [candidate,*candidate.rglob('*')]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        settings = settings_at()
        # Exercise disabled and both transport filters before accepting new data.
        for game in ('off','tcp','udp','all'):
            for ipset in ('loaded','none','any'):
                check_engine(BASE,candidate,candidate/'lists',dict(settings,game=game,ipset=ipset),True)
        atomic_write(candidate/'sources.json',json.dumps(dict(windows_commit=commit),indent=2)+'\n')
        backup=BASE/'vendor.previous'
        if backup.exists(): raise ValueError('Есть vendor.previous, нужна проверка предыдущего обновления')
        old_lists=STATE/'lists.previous'
        if old_lists.exists(): raise ValueError('Есть lists.previous')
        shutil.copytree(STATE/'lists',old_lists)
        active=job_loaded()
        if active: stop_job()
        try:
            (BASE/'vendor').rename(backup)
            candidate.rename(BASE/'vendor')
            for path in (BASE/'vendor/lists').glob('*.txt'):
                if path.name.endswith('-user.txt'): continue
                atomic_write(STATE/'lists'/path.name,path.read_text())
            check_engine(BASE,BASE/'vendor',STATE/'lists',settings,True)
            if active: start_job()
        except BaseException:
            if job_loaded(): stop_job()
            if backup.exists():
                if (BASE/'vendor').exists(): shutil.rmtree(BASE/'vendor')
                backup.rename(BASE/'vendor')
            shutil.rmtree(STATE/'lists'); old_lists.rename(STATE/'lists')
            if active: start_job()
            raise
        shutil.rmtree(backup); shutil.rmtree(old_lists)
    print('Стратегии, payload и основные списки обновлены: '+commit[:12]+'. Движок не заменялся.')


def update_ipset():
    content=download('https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/ipset-service.txt').decode('utf-8-sig').replace('\r\n','\n')
    validate_networks(content)
    path=STATE/'lists/ipset-all.txt'; old=path.read_text()
    if content == old:
        print('IPSet уже актуален')
        return
    active=job_loaded() and settings_at()['ipset']=='loaded'
    if active: stop_job()
    try:
        atomic_write(path,content)
        check_engine(BASE,BASE/'vendor',STATE/'lists',settings_at())
        if active: start_job()
    except BaseException:
        if path.read_text() != old: atomic_write(path,old)
        if active: start_job()
        raise
    print('IPSet обновлён')


def hosts(action):
    path=Path('/private/etc/hosts')
    old=path.read_text()
    addition=(BASE/'vendor/hosts').read_text() if action=='apply' else ''
    new=merge_hosts(old,addition)
    if old == new: print('hosts уже в нужном состоянии'); return
    backup=STATE/('hosts.backup-'+str(time.time_ns()))
    atomic_write(backup,old,0o600)
    atomic_write(path,new)
    command(['/usr/bin/dscacheutil','-flushcache'],check=False)
    command(['/usr/bin/killall','-HUP','mDNSResponder'],check=False)
    print('Изменён только блок zapret в hosts. Резервная копия: '+str(backup))


def remove():
    sync_auto_job(False)
    stop_job()
    PLIST.unlink(missing_ok=True)
    link=Path('/usr/local/bin/zapret')
    if link.is_symlink() and os.readlink(link)==str(BASE/'zapret'): link.unlink()
    print('Служба удалена, PF очищен. Настройки, списки и hosts сохранены. Меню: '+str(BASE/'zapret'))


def privileged(action,*args):
    script=BASE/'manager.py' if (BASE/'manager.py').exists() and action!='install' else HERE/'manager.py'
    result=subprocess.run(['/usr/bin/sudo',PYTHON,'-I',str(script),action,*args])
    if result.returncode: raise RuntimeError('Операция не завершена (код '+str(result.returncode)+')')


def choose_strategy():
    root=BASE if (BASE/'vendor').exists() else HERE
    catalog=catalog_at(root)
    for i,item in enumerate(catalog,1): print(f'  {i:2}. {item["name"]}')
    value=input('Стратегия (0 - назад): ').strip()
    if value=='0': return None
    if not value.isdigit() or not 1<=int(value)<=len(catalog): raise ValueError('Номер стратегии вне списка')
    return catalog[int(value)-1]['id']


def diagnostics():
    loaded=command(['/bin/launchctl','print','system/'+LABEL],check=False)
    print('Служба: '+('загружена' if loaded.returncode==0 else 'не установлена/остановлена'))
    print('Настройки: '+json.dumps(settings_at(),ensure_ascii=False))
    auto_status()
    print('IPv4 через физический интерфейс. IPv6 и трафик root не перехватываются.')
    try: print('Default interface: '+route_info()[0])
    except Exception as exc: print(str(exc))
    if (STATE/'service.log').exists():
        print('Последние строки лога:')
        print('\n'.join((STATE/'service.log').read_text(errors='replace').splitlines()[-15:]))


def menu():
    if os.geteuid()==0: raise ValueError('Открывай меню без sudo; пароль запрашивается для конкретной операции')
    while True:
        try:
            s=settings_at()
            print('\nZapret macOS - Flowseal\nСтратегия: '+s['strategy']+' | game: '+s['game']+' | IPSet: '+s['ipset'])
            print('1. Установить/запустить службу и выбрать стратегию\n2. Удалить службу\n3. Game-filter TCP/UDP\n4. IPSet\n5. Файл hosts\n6. Обновления\n7. Статус и диагностика\n8. Сменить стратегию\n9. Проверить все стратегии (без изменения сети)\n0. Выход')
            choice=input('Выбор: ').strip()
            if choice=='0': return
            if choice=='1':
                strategy=choose_strategy()
                if strategy: privileged('install',strategy)
            elif choice=='2': privileged('remove')
            elif choice=='3':
                print('1. Выключен\n2. TCP + UDP\n3. Только TCP\n4. Только UDP\n5. Диапазон TCP\n6. Диапазон UDP\n0. Назад')
                c=input('Выбор: ').strip()
                modes={'1':'off','2':'all','3':'tcp','4':'udp'}
                if c in modes: privileged('set','game',modes[c])
                elif c in ('5','6'):
                    value=input('Порты (например 1024-65535 или 27000-27200,3478): ').strip()
                    port_range(value); privileged('set','tcp' if c=='5' else 'udp',value)
                if s['ipset']=='none': print('IPSet выключен: игровые IPSet-профили не обрабатывают обычные адреса.')
            elif choice=='4':
                print('1. Загруженный список\n2. Любые публичные IP\n3. Выключить IPSet-профили\n4. Обновить IPSet\n0. Назад')
                c=input('Выбор: ').strip()
                if c in ('1','2','3'): privileged('set','ipset',{'1':'loaded','2':'any','3':'none'}[c])
                elif c=='4': privileged('update-ipset')
            elif choice=='5':
                print('1. Показать добавляемые записи\n2. Применить блок Flowseal\n3. Удалить только свой блок\n0. Назад')
                c=input('Выбор: ').strip()
                if c=='1': print(((BASE if BASE.exists() else HERE)/'vendor/hosts').read_text())
                elif c in ('2','3'): privileged('hosts','apply' if c=='2' else 'remove')
            elif choice=='6':
                auto_status()
                print('1. Проверить обновления (без установки)\n2. Обновить сейчас: стратегии, списки и IPSet\n3. Включить автообновление раз в сутки\n4. Выключить автообновление\n0. Назад')
                c=input('Выбор: ').strip()
                if c=='1': check_updates()
                elif c=='2': privileged('update')
                elif c in ('3','4'): privileged('auto','on' if c=='3' else 'off')
                elif c!='0': print('Нет такого пункта')
            elif choice=='7': diagnostics()
            elif choice=='8':
                strategy=choose_strategy()
                if strategy: privileged('set','strategy',strategy)
            elif choice=='9':
                root=BASE if BASE.exists() else HERE
                lists=STATE/'lists' if STATE.exists() else root/'vendor/lists'
                check_engine(root,root/'vendor',lists,s,True)
                print('Все '+str(len(catalog_at(root)))+' стратегии прошли --dry-run; обход DPI этим не подтверждается.')
            else: print('Нет такого пункта')
        except (ValueError,RuntimeError,OSError,subprocess.SubprocessError) as exc:
            print('Ошибка: '+str(exc))
        except (EOFError,KeyboardInterrupt): print(); return


def main():
    action=sys.argv[1] if len(sys.argv)>1 else 'menu'
    if action=='menu': return menu()
    if action=='diagnostics': return diagnostics()
    if action=='check-updates': return check_updates()
    if action=='auto-status': return auto_status()
    if os.geteuid()!=0: raise ValueError('Эта операция требует sudo')
    if sys.platform!='darwin': raise ValueError('Только macOS')
    if action=='install': return install(sys.argv[2] if len(sys.argv)>2 else settings_at()['strategy'])
    if action=='watchdog-cleanup': return watchdog_cleanup(int(sys.argv[2]))
    for folder in (BASE,STATE,RUN): secure_dir(folder)
    # Serialize modifications. The supervisor uses a separate lifetime lock.
    with open(STATE/'management.lock','a') as lock:
        if action!='supervise': fcntl.flock(lock,fcntl.LOCK_EX)
        if action=='supervise': return supervise()
        if action=='set': return change_settings(*sys.argv[2:])
        if action=='remove': return remove()
        if action=='update': return run_updates()
        if action=='auto-update': return automatic_update()
        if action=='auto' and len(sys.argv)==3 and sys.argv[2] in ('on','off'):
            return set_auto_updates(sys.argv[2]=='on')
        if action=='update-ipset': return update_ipset()
        if action=='hosts' and sys.argv[2] in ('apply','remove'): return hosts(sys.argv[2])
        raise ValueError('Неизвестная команда')

if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: sys.exit(0)
    except Exception as exc:
        print('Ошибка: '+str(exc),file=sys.stderr)
        if isinstance(exc,subprocess.CalledProcessError): print(exc.stdout or '',exc.stderr or '',file=sys.stderr)
        sys.exit(1)
