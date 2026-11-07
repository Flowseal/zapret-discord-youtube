import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

class Strategies(unittest.TestCase):
    def test_module_exists(self):
        self.assertIsNotNone(importlib.util.find_spec('strategies'))

    def test_catalog_uses_natural_strategy_order(self):
        import strategies as s
        catalog = s.import_catalog(ROOT.parent)
        names = [item['name'] for item in catalog]
        self.assertEqual(names[:15], ['general', 'general (ALT)']+
                         ['general (ALT'+str(n)+')' for n in range(2, 14)]+['general (EXP)'])
        self.assertLess(names.index('general (FAKE TLS AUTO)'), names.index('general (FAKE TLS AUTO ALT)'))
        self.assertLess(names.index('general (SIMPLE FAKE)'), names.index('general (SIMPLE FAKE ALT)'))

    def test_import_and_profiles(self):
        import strategies as s
        source = ROOT.parent
        catalog = s.import_catalog(source)
        self.assertEqual(len(catalog), len(list(source.glob('general*.bat'))))
        self.assertGreater(len(catalog), 20)
        item = next(x for x in catalog if x['id'] == 'general-alt11')
        args, ports = s.compile_strategy(item, ROOT/'vendor', ROOT/'vendor/lists',
                                         {'game': 'all', 'tcp': '1024-65535',
                                          'udp': '2000-6000', 'ipset': 'loaded'})
        self.assertIn('--filter-tcp=1024-65535', args)
        self.assertIn('--filter-udp=2000-6000', args)
        self.assertIn('1024:65535', ports['tcp'])
        self.assertIn('2000:6000', ports['udp'])
        off, offports = s.compile_strategy(item, ROOT/'vendor', ROOT/'vendor/lists',
                                             {'game':'off', 'tcp':'1024-65535',
                                              'udp':'1024-65535', 'ipset':'none'})
        self.assertNotIn('--filter-tcp=1024-65535', off)
        self.assertNotIn('1024:65535', offports['tcp'])
        self.assertFalse(any('%' in v for v in off))
        self.assertTrue(any('ipset-none.txt' in v for v in off))
        for profile in s.profiles(args):
            self.assertTrue(profile)

    def test_ports_reject_injection(self):
        import strategies as s
        for value in ['0','65536','9-1','443;id','$(id)','1:3','', '1,', '-1']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                s.port_range(value)
        self.assertEqual(s.port_range('80,443,1024-65535'), ['80','443','1024:65535'])

    def test_hosts_preserves_content(self):
        import strategies as s
        original = '127.0.0.1 localhost\n# personal\n192.0.2.1 example.test\n'
        updated = s.merge_hosts(original, '1.1.1.1 discord.com\n')
        self.assertTrue(updated.startswith(original))
        self.assertEqual(s.merge_hosts(updated, ''), original)
        self.assertEqual(s.merge_hosts(updated, '1.1.1.1 discord.com\n'), updated)
        for bad in ['127.0.0.1 localhost','1.2.3.4 bad;command','not-an-ip discord.com']:
            with self.assertRaises(ValueError): s.merge_hosts(original, bad)

    def test_hosts_rejects_damaged_marker_order(self):
        import strategies as s
        for text in [s.END+'\n'+s.BEGIN+'\n', 'prefix '+s.BEGIN+'\n'+s.END+'\n']:
            with self.assertRaises(ValueError): s.merge_hosts(text,'1.1.1.1 discord.com')

    def test_downloaded_strategy_cannot_use_privileged_options(self):
        import strategies as s
        for token in ['--daemon','--debug=@/etc/hosts','--hostlist=@LISTS@/../../secret',
                      '--dpi-desync-fake-tls=/etc/hosts','--lua-init=exec']:
            with self.assertRaises(ValueError):s.validate_tokens([token])
