import contextlib
import http.server
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import manager


class Downloads(unittest.TestCase):
    def test_https_redirects_never_contact_http(self):
        with tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
            root = Path(d)
            cert, key = root/'cert.pem', root/'key.pem'
            subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048',
                            '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                           check=True, capture_output=True)
            requests = []

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    requests.append((self.server.server_port, self.path))
                    if self.path in ('/downgrade', '/secure'):
                        self.send_response(302)
                        self.send_header('Location', (http_url if self.path == '/downgrade' else https_url)+'/done')
                        self.end_headers()
                    else:
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b'data')

                def log_message(self, *args):
                    pass

            plain = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            secure = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            secure.socket = server_context.wrap_socket(secure.socket, server_side=True)
            http_url = 'http://localhost:'+str(plain.server_port)
            https_url = 'https://localhost:'+str(secure.server_port)
            for server in (plain, secure):
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                stack.callback(server.server_close)
                stack.callback(thread.join, 2)
                stack.callback(server.shutdown)
            client_context = ssl.create_default_context(cafile=str(cert))
            stack.enter_context(mock.patch.object(ssl, '_create_default_https_context', return_value=client_context))
            stack.enter_context(mock.patch('urllib.request.getproxies', return_value={}))
            with self.assertRaises(ValueError):
                manager.download(https_url+'/downgrade')
            self.assertFalse(any(port == plain.server_port for port, _ in requests), requests)
            self.assertEqual(manager.download(https_url+'/secure'), b'data')
            with self.assertRaises(ValueError):
                manager.download(https_url+'/done', limit=3)
            with self.assertRaises(ValueError):
                manager.download(http_url+'/done')
