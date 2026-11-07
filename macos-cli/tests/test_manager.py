import importlib.util
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))

class Manager(unittest.TestCase):
    def test_module_exists(self):
        self.assertIsNotNone(importlib.util.find_spec('manager'))

    def test_settings_validation(self):
        import manager as m
        good = dict(m.DEFAULTS)
        m.validate_settings(good)
        for field,value in [('strategy','../../bad'),('game','bad'),('tcp','80;id'),('ipset','bad'),('extra',1)]:
            bad = dict(good); bad[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): m.validate_settings(bad)

    def test_atomic_and_symlink(self):
        import manager as m
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); path=root/'config'
            m.atomic_write(path,'old')
            m.atomic_write(path,'new')
            self.assertEqual(path.read_text(),'new')
            link=root/'link'; link.symlink_to(path)
            with self.assertRaises(ValueError): m.atomic_write(link,'overwrite')
            self.assertEqual(path.read_text(),'new')

    def test_pf_only_physical_user_ipv4(self):
        import manager as m
        text=m.pf_rules('en0',{'tcp':['443','1024:65535'],'udp':['443']})
        self.assertIn('on en0',text)
        self.assertIn('user { >root }',text)
        self.assertIn('inet proto udp',text)
        self.assertIn('10.0.0.0/8',text)
        self.assertNotIn('inet6',text)
        with self.assertRaises(ValueError):m.pf_rules('utun4',{'tcp':['443'],'udp':[]})

    def test_failed_settings_write_restarts_old_service(self):
        import manager as m
        with tempfile.TemporaryDirectory() as d, mock.patch.object(m,'STATE',Path(d)), \
             mock.patch.object(m,'check_engine'), mock.patch.object(m,'job_loaded',return_value=True), \
             mock.patch.object(m,'stop_job'), mock.patch.object(m,'start_job') as start:
            m.atomic_write(Path(d)/'settings.json',__import__('json').dumps(m.DEFAULTS))
            with mock.patch.object(m,'atomic_write',side_effect=OSError('disk full')):
                with self.assertRaises(OSError): m.change_settings('game','all')
            start.assert_called_once()

    def test_stop_waits_for_utun_release(self):
        import subprocess
        import manager as m
        with tempfile.TemporaryDirectory() as d, mock.patch.object(m, 'RUN', Path(d)), \
             mock.patch.object(m, 'job_loaded', side_effect=[True, False, False]), \
             mock.patch.object(m, 'cleanup_pf'), mock.patch.object(m.time, 'sleep') as sleep:
            calls = []
            status = iter((0, 1))
            def command(args, **kwargs):
                calls.append(args)
                return subprocess.CompletedProcess(args, next(status) if args[:2] == ['/sbin/ifconfig', 'utun50'] else 0)
            with mock.patch.object(m, 'command', side_effect=command): m.stop_job()
            self.assertEqual(calls.count(['/sbin/ifconfig', 'utun50']), 2)
            sleep.assert_called_once()

    def test_old_watchdog_cannot_clear_new_supervisor_rules(self):
        import fcntl
        import manager as m
        with tempfile.TemporaryDirectory() as d, mock.patch.object(m, 'RUN', Path(d)), \
             mock.patch.object(m, 'cleanup_pf') as cleanup, mock.patch.object(m.os, 'kill') as kill:
            with open(Path(d)/'supervisor.lock', 'a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                m.watchdog_cleanup(123)
            cleanup.assert_not_called()
            kill.assert_not_called()
            m.watchdog_cleanup(123)
            cleanup.assert_called_once()
            kill.assert_called_once_with(123, m.signal.SIGTERM)

    def test_supervisor_stops_engine_when_cleanup_fails_or_watchdog_hangs(self):
        import contextlib
        import subprocess
        import manager as m
        for failure in ('watchdog', 'pf'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
                root = Path(d)
                engine = mock.Mock(pid=123, returncode=None)
                engine.poll.return_value = None
                watcher = mock.Mock(pid=124)
                watcher.poll.return_value = None
                if failure == 'watchdog':
                    watcher.wait.side_effect = [subprocess.TimeoutExpired('watchdog', 3), 0]
                cleanup = stack.enter_context(mock.patch.object(m, 'cleanup_pf'))
                if failure == 'pf': cleanup.side_effect = [None, OSError('PF cleanup failed')]
                stack.enter_context(mock.patch.object(m, 'RUN', root))
                stack.enter_context(mock.patch.object(m, 'secure_dir'))
                stack.enter_context(mock.patch.object(m, 'check_engine', return_value=([], {'tcp': ['443'], 'udp': []})))
                stack.enter_context(mock.patch.object(m, 'route_info', return_value=('en0', '192.0.2.1')))
                stack.enter_context(mock.patch.object(m.signal, 'signal'))
                stack.enter_context(mock.patch.object(m.subprocess, 'Popen', side_effect=[engine, watcher]))
                ifconfig_calls = 0
                def command(args, **kwargs):
                    nonlocal ifconfig_calls
                    if args == ['/sbin/ifconfig', 'utun50']:
                        ifconfig_calls += 1
                        return subprocess.CompletedProcess(args, 1 if ifconfig_calls == 1 else 0)
                    return subprocess.CompletedProcess(args, 0, 'anchor "com.apple/*"\nat 1:2:3:4:5:6 \nToken : 123\n', '')
                stack.enter_context(mock.patch.object(m, 'command', side_effect=command))
                def write(path, *args):
                    if path.name == 'ready.json': raise RuntimeError('startup interrupted')
                stack.enter_context(mock.patch.object(m, 'atomic_write', side_effect=write))
                with self.assertRaises((RuntimeError, OSError)):
                    m.supervise()
                engine.terminate.assert_called_once()
                engine.wait.assert_called_once_with(timeout=3)
                if failure == 'watchdog': watcher.kill.assert_called_once()
