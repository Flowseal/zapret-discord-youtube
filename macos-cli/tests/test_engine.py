import itertools
import json
from pathlib import Path
import subprocess
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from strategies import compile_strategy
ROOT=Path(__file__).resolve().parents[1]

class Engine(unittest.TestCase):
    def test_every_strategy_and_filter_combination(self):
        catalog=json.loads((ROOT/'vendor/catalog.json').read_text())
        self.assertEqual(len(catalog),len(list(ROOT.parent.glob('general*.bat'))))
        log=[]; failures=[]
        for item,game,ipset in itertools.product(catalog,('off','tcp','udp','all'),('loaded','none','any')):
            settings=dict(game=game,tcp='1024-65535',udp='1024-65535',ipset=ipset)
            args,ports=compile_strategy(item,ROOT/'vendor',ROOT/'vendor/lists',settings)
            result=subprocess.run([str(ROOT/'bin/utunws'),'--dry-run',*args],text=True,capture_output=True)
            log.append(item['id']+' '+game+' '+ipset+'\n'+result.stdout+result.stderr)
            if result.returncode: failures.append((item['id'],game,ipset,result.stdout+result.stderr))
        (ROOT/'strategy-validation.log').write_text('\n'.join(log))
        self.assertEqual(failures,[])

    def test_original_payloads_preserved(self):
        original=ROOT.parent/'bin'
        for path in original.glob('*.bin'):
            self.assertEqual(path.read_bytes(),(ROOT/'vendor/bin'/path.name).read_bytes(),path.name)
