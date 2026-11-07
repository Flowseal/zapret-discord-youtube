import contextlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import manager as m


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.source, self.base, self.state, self.run = [self.root/name for name in ('source', 'base', 'state', 'run')]
        for folder in (self.source, self.base, self.state, self.run): folder.mkdir()
        self.plist = self.root/'service.plist'
        for name, value in (('HERE', self.source), ('BASE', self.base), ('STATE', self.state),
                            ('RUN', self.run), ('PLIST', self.plist)):
            self.stack.enter_context(mock.patch.object(m, name, value))
        self.stack.enter_context(mock.patch.object(m, 'secure_dir'))
        self.stack.enter_context(mock.patch.object(m, 'sync_auto_job'))
        self.stack.enter_context(mock.patch.object(m, 'check_engine', return_value=([], {'tcp': ['443'], 'udp': []})))
        self.stack.enter_context(mock.patch.object(m, 'Path', side_effect=lambda p: self.root/'cli' if str(p) == '/usr/local/bin/zapret' else Path(p)))

    def test_reinstall_from_retained_menu_recreates_plist(self):
        self.stack.enter_context(mock.patch.object(m, 'HERE', self.base))
        (self.state/'settings.json').write_text(json.dumps(m.DEFAULTS))
        self.stack.enter_context(mock.patch.object(m, 'job_loaded', return_value=False))
        start = self.stack.enter_context(mock.patch.object(m, 'start_job', side_effect=lambda: self.assertTrue(self.plist.is_file())))
        m.install('general-alt11')
        start.assert_called_once()
        self.assertTrue((self.root/'cli').is_symlink())
        self.assertEqual((self.root/'cli').readlink(), self.base/'zapret')

    def test_failed_promotion_restores_old_installation(self):
        self.assert_failed_install_rename(False)

    def test_failed_backup_rename_restarts_old_installation(self):
        self.assert_failed_install_rename(True)

    def test_partial_backup_cleanup_keeps_new_installation(self):
        (self.base/'old').write_text('preserve')
        for name in ('manager.py', 'strategies.py', 'zapret', 'watchdog.sh'):
            (self.source/name).write_text('new')
        for name in ('bin', 'vendor', 'vendor/lists'): (self.source/name).mkdir()
        self.stack.enter_context(mock.patch.object(m, 'job_loaded', return_value=True))
        self.stack.enter_context(mock.patch.object(m, 'stop_job'))
        start = self.stack.enter_context(mock.patch.object(m, 'start_job'))
        original_rmtree = m.shutil.rmtree
        def rmtree(path, *args, **kwargs):
            if path == self.base.with_name('ZapretCLI.previous'):
                (path/'old').unlink()
                raise OSError('simulated partial backup cleanup')
            return original_rmtree(path, *args, **kwargs)
        with mock.patch.object(m.shutil, 'rmtree', side_effect=rmtree):
            m.install('general-alt11')
        self.assertEqual((self.base/'manager.py').read_text(), 'new')
        start.assert_called_once()

    def assert_failed_install_rename(self, backup):
        (self.base/'old').write_text('preserve')
        for name in ('manager.py', 'strategies.py', 'zapret', 'watchdog.sh'):
            (self.source/name).write_text('')
        for name in ('bin', 'vendor', 'vendor/lists'): (self.source/name).mkdir()
        self.stack.enter_context(mock.patch.object(m, 'job_loaded', return_value=True))
        self.stack.enter_context(mock.patch.object(m, 'stop_job'))
        start = self.stack.enter_context(mock.patch.object(m, 'start_job'))
        original_rename = Path.rename
        def rename(path, target):
            if (backup and path == self.base) or (not backup and path.name.startswith('.ZapretCLI-stage-')):
                raise OSError('simulated promotion failure')
            return original_rename(path, target)
        self.stack.enter_context(mock.patch.object(Path, 'rename', rename))
        with self.assertRaisesRegex(OSError, 'promotion failure'): m.install('general-alt11')
        self.assertEqual((self.base/'old').read_text(), 'preserve')
        self.assertFalse(self.base.with_name('ZapretCLI.previous').exists())
        start.assert_called_once()

    def test_pf_reference_released_when_token_write_fails(self):
        commands = []
        engine, watcher = mock.Mock(pid=123), mock.Mock(pid=124)
        engine.poll.return_value = watcher.poll.return_value = None
        self.stack.enter_context(mock.patch.object(m, 'route_info', return_value=('en0', '192.0.2.1')))
        self.stack.enter_context(mock.patch.object(m.signal, 'signal'))
        self.stack.enter_context(mock.patch.object(m.subprocess, 'Popen', side_effect=[engine, watcher]))
        ifconfig_calls = 0
        def command(args, **kwargs):
            nonlocal ifconfig_calls
            commands.append(args)
            if args == ['/sbin/ifconfig', 'utun50']:
                ifconfig_calls += 1
                return subprocess.CompletedProcess(args, 1 if ifconfig_calls == 1 else 0, '', '')
            return subprocess.CompletedProcess(args, 0, 'anchor "com.apple/*"\nat 1:2:3:4:5:6 \nToken : 123\n', '')
        def write(path, *args):
            if path.name == 'pf-token': raise OSError('simulated disk full')
        self.stack.enter_context(mock.patch.object(m, 'command', side_effect=command))
        self.stack.enter_context(mock.patch.object(m, 'atomic_write', side_effect=write))
        with self.assertRaisesRegex(OSError, 'disk full'): m.supervise()
        self.assertIn(['/sbin/pfctl', '-E'], commands)
        self.assertIn(['/sbin/pfctl', '-X', '123'], commands)
