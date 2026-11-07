import contextlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import manager as m


class AutoUpdates(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack(); self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.base = self.root/'base'; (self.base/'vendor').mkdir(parents=True)
        (self.base/'manager.py').write_text('fixture')
        for name, value in [('BASE', self.base), ('STATE', self.root), ('AUTO_PLIST', self.root/'auto.plist')]:
            self.stack.enter_context(mock.patch.object(m, name, value, create=True))

    def test_check_is_readonly_and_uses_installed_revision(self):
        path = self.base/'vendor/sources.json'; path.write_text(json.dumps({'windows_commit': 'a'*40}))
        with mock.patch.object(m, 'latest_commit', return_value='b'*40, create=True), \
             mock.patch.object(m, 'atomic_write') as write, mock.patch.object(m, 'command') as command:
            result = m.check_updates()
        self.assertEqual(result, {'installed': 'a'*40, 'available': 'b'*40, 'update_available': True})
        write.assert_not_called(); command.assert_not_called()

    def test_default_is_off_and_daily_gate(self):
        self.assertEqual(m.auto_settings(), {'enabled': False, 'last_check': 0})
        with mock.patch.object(m, 'run_updates') as run, mock.patch.object(m.time, 'time', return_value=100000):
            m.automatic_update(); run.assert_not_called()
            m.atomic_write(self.root/'auto-update.json', json.dumps({'enabled': True, 'last_check': 99999}))
            m.automatic_update(); run.assert_not_called()
            m.atomic_write(self.root/'auto-update.json', json.dumps({'enabled': True, 'last_check': 0}))
            m.automatic_update(); run.assert_called_once()

    def test_failed_schedule_rolls_back_flag(self):
        with mock.patch.object(m, 'sync_auto_job', side_effect=[OSError('bootstrap failed'), None], create=True):
            with self.assertRaisesRegex(OSError, 'bootstrap failed'): m.set_auto_updates(True)
        self.assertFalse(m.auto_settings()['enabled'])

    def test_cannot_enable_before_install(self):
        (self.base/'manager.py').unlink()
        with self.assertRaisesRegex(ValueError, 'Сначала установи'): m.set_auto_updates(True)
        self.assertFalse(m.auto_settings()['enabled'])

    def test_schedule_is_hourly_while_updates_are_daily(self):
        with mock.patch.object(m, 'job_loaded', return_value=False), mock.patch.object(m, 'command') as command:
            m.sync_auto_job(True)
        data = plistlib.loads(m.AUTO_PLIST.read_bytes())
        self.assertEqual(data['StartInterval'], 3600)
        self.assertTrue(data['RunAtLoad'])
        self.assertEqual(data['ProgramArguments'][-1], 'auto-update')
        self.assertEqual(command.call_args_list[-1].args[0][1], 'bootstrap')

    def test_successful_update_records_check_only_after_success(self):
        m.atomic_write(self.root/'auto-update.json', json.dumps({'enabled': True, 'last_check': 0}))
        with mock.patch.object(m, 'check_updates', return_value={'available': 'b'*40, 'update_available': True}), \
             mock.patch.object(m, 'update_vendor') as update, mock.patch.object(m, 'update_ipset'), \
             mock.patch.object(m.time, 'time', return_value=100000):
            m.run_updates()
        update.assert_called_once_with('b'*40)
        self.assertEqual(m.auto_settings()['last_check'], 100000)

    def test_failed_update_is_retried_next_hour(self):
        m.atomic_write(self.root/'auto-update.json', json.dumps({'enabled': True, 'last_check': 0}))
        with mock.patch.object(m, 'check_updates', return_value={'update_available': False}), \
             mock.patch.object(m, 'update_ipset', side_effect=OSError('offline')):
            with self.assertRaises(OSError): m.run_updates()
        self.assertEqual(m.auto_settings()['last_check'], 0)

    def test_same_ipset_does_not_stop_service(self):
        (self.root/'lists').mkdir(); path=self.root/'lists/ipset-all.txt'; path.write_text('1.1.1.1/32\n')
        with mock.patch.object(m, 'download', return_value=b'1.1.1.1/32\r\n'), \
             mock.patch.object(m, 'stop_job') as stop:
            m.update_ipset()
        stop.assert_not_called()

    def test_remove_unloads_schedule_and_keeps_user_choice(self):
        m.atomic_write(self.root/'auto-update.json',json.dumps({'enabled':True,'last_check':0}))
        m.AUTO_PLIST.write_text('scheduled')
        plist=self.root/'native.plist'; plist.write_text('native')
        with mock.patch.object(m,'PLIST',plist), mock.patch.object(m,'stop_job'), \
             mock.patch.object(m,'job_loaded',side_effect=[True,False]), mock.patch.object(m,'command') as command:
            m.remove()
        command.assert_called_once_with(['/bin/launchctl','bootout','system/'+m.AUTO_LABEL])
        self.assertFalse(m.AUTO_PLIST.exists())
        self.assertFalse(plist.exists())
        self.assertTrue(m.auto_settings()['enabled'])
