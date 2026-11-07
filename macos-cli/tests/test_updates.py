import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import manager as m


class Updates(unittest.TestCase):
    def test_update_without_api_quota_preserves_user_lists(self):
        commit = 'a'*40
        feed = ('<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>'
                'tag:github.com,2008:Grit::Commit/'+commit+'</id></entry></feed>').encode()
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z:
            for name, content in {
                'general (ALT11).bat': '"%BIN%winws.exe" --wf-tcp=443 --filter-tcp=443',
                'LICENSE.txt': 'fixture', '.service/hosts': '192.0.2.1 fixture.invalid',
                'lists/list-general.txt': 'new.invalid\n', 'lists/ipset-all.txt': '203.0.113.0/24\n'
            }.items(): z.writestr('release/'+name, content)
        def download(url, *args):
            if url.endswith('/commits/main.atom'): return feed
            if url.endswith('/zip/'+commit): return archive.getvalue()
            raise urllib.error.HTTPError(url, 403, 'rate limit exceeded', {}, None)
        with tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
            root = Path(d); base = root/'base'; state = root/'state'
            (base/'vendor').mkdir(parents=True); (state/'lists').mkdir(parents=True)
            user = state/'lists/list-general-user.txt'; user.write_text('personal.invalid\n')
            (state/'lists/list-general.txt').write_text('old.invalid\n')
            for name, value in [('BASE', base), ('STATE', state)]:
                stack.enter_context(mock.patch.object(m, name, value))
            stack.enter_context(mock.patch.object(m, 'download', side_effect=download))
            stack.enter_context(mock.patch.object(m, 'check_engine'))
            stack.enter_context(mock.patch.object(m, 'job_loaded', return_value=False))
            stack.enter_context(mock.patch.object(m, 'update_ipset'))
            previous_umask = os.umask(0o077)
            try: m.run_updates()
            finally: os.umask(previous_umask)
            self.assertEqual(user.read_text(), 'personal.invalid\n')
            self.assertEqual((state/'lists/list-general.txt').read_text(), 'new.invalid\n')
            self.assertEqual(json.loads((base/'vendor/sources.json').read_text())['windows_commit'], commit)
            self.assertFalse((base/'vendor.previous').exists())
            self.assertFalse((state/'lists.previous').exists())
            self.assertEqual((base/'vendor/lists/list-general.txt').stat().st_mode & 0o777, 0o644)
