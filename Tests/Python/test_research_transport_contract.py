"""Actual stdlib helper tests with injected loopback sockets; no public traffic.

Production accepts only an inherited connected public peer. Fixture-only connector/context
injection lets tests verify HTTP/TLS mechanics without altering system trust or DNS.
Swift and exact macOS sandbox acceptance are separate native gates.
"""
import gzip
import http.server
import importlib.util
import io
import json
import os
import pathlib
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Resources/Research/dot_source_fetch.py'
spec = importlib.util.spec_from_file_location('dot_source_fetch', HELPER)
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append((self.path, dict(self.headers)))
        status, data, headers = 200, b'original evidence', {'Content-Type': 'text/plain'}
        if self.path == '/early-hints':
            self.wfile.write(b'HTTP/1.1 103 Early Hints\r\nLink: </do-not-fetch>\r\n\r\n')
        elif self.path == '/upgrade':
            status, data = 101, b''
        elif self.path == '/redirect':
            status, data = 302, b''
            headers['Location'] = f'http://127.0.0.1:{self.server.server_port}/private'
        elif self.path == '/challenge':
            status, data = 401, b''
            headers['WWW-Authenticate'] = 'Basic realm="fixture"'
        elif self.path in ('/gzip', '/bomb', '/truncated-gzip'):
            data = gzip.compress(b'decoded evidence' * 100 if self.path == '/gzip' else b'x' * (fetcher.MAX_BYTES + 1))
            if self.path == '/truncated-gzip':
                data = gzip.compress(b'evidence')[:-5]
            headers['Content-Encoding'] = 'gzip'
        elif self.path == '/large':
            data = b'x' * (fetcher.MAX_BYTES + 1)
        elif self.path in ('/chunked', '/unsupported-transfer'):
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'gzip, chunked' if self.path == '/unsupported-transfer' else 'chunked')
            self.end_headers()
            self.wfile.write(b'8\r\nevidence\r\n0\r\n\r\n')
            return
        elif self.path == '/huge-header':
            headers['X-Huge'] = 'x' * 8193
        elif self.path == '/duplicate':
            self.send_response(302)
            self.send_header('Location', '/a')
            self.send_header('Location', '/b')
            self.end_headers()
            return
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Set-Cookie', 'must_not_persist=1')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


class ResearchTransportContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.requests = []
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2)

    def setUp(self):
        self.server.requests.clear()

    def request(self, path, **kwargs):
        body, metadata = io.BytesIO(), io.BytesIO()
        connector = kwargs.pop('connector', lambda _address, _port, timeout: socket.create_connection(('127.0.0.1', self.server.server_port), timeout))
        fetcher.fetch(f'http://fixture.invalid:{self.server.server_port}{path}', '1.1.1.1', 3, body, metadata, connector=connector, **kwargs)
        return body.getvalue(), json.loads(metadata.getvalue())

    def test_special_addresses_and_transition_forms_are_rejected(self):
        denied = ['0.0.0.0', '10.0.0.1', '100.64.0.1', '100.127.255.255', '127.255.1.1', '169.254.1.1', '172.31.255.255',
                  '192.0.0.9', '192.0.2.1', '192.31.196.1', '192.52.193.1', '192.88.99.1', '192.168.1.1', '192.175.48.1',
                  '198.19.1.1', '198.51.100.1', '203.0.113.1', '224.0.0.1', '255.255.255.255', '::', '::1', '::127.0.0.1',
                  '::ffff:127.0.0.1', '::ffff:8.8.8.8', '::ffff:0:127.0.0.1', '64:ff9b::7f00:1', '64:ff9b:1::1', '100::1',
                  '2001::7f00:1', '2001:db8::1', '2002:7f00:1::1', '3ffe::1', '3fff::1', '2620:4f:8000::1',
                  'fc00::1', 'fe80::1', 'fe80::1%en0', 'ff02::1', '2606:4700::5efe:7f00:1', '2606:4700::200:5efe:7f00:1']
        for address in denied:
            self.assertFalse(fetcher.public_address(address), address)
        for address in ['1.1.1.1', '8.8.8.8', '93.184.216.34', '100.63.255.255', '100.128.0.1', '172.32.0.1', '2606:4700:4700::1111', '2001:4860:4860::8888']:
            self.assertTrue(fetcher.public_address(address), address)

    def test_private_pin_never_calls_connector_or_sends_request_bytes(self):
        calls = []
        for pin in ['127.0.0.1', '::1', '::ffff:127.0.0.1', '192.168.0.1']:
            with self.assertRaises(ValueError):
                fetcher.fetch('http://fixture.invalid/', pin, 1, io.BytesIO(), io.BytesIO(), connector=lambda *args: calls.append(args))
        self.assertEqual(calls, [])
        self.assertEqual(self.server.requests, [])

    def test_http_preserves_original_host_and_separates_metadata(self):
        body, metadata = self.request('/plain')
        self.assertEqual(body, b'original evidence')
        self.assertEqual(metadata['status'], 200)
        self.assertEqual(metadata['headers']['content-type'], 'text/plain')
        self.assertNotIn('set-cookie', metadata['headers'])
        headers = self.server.requests[0][1]
        self.assertEqual(headers['Host'], f'fixture.invalid:{self.server.server_port}')
        for name in ['Cookie', 'Authorization', 'Proxy-Authorization']:
            self.assertNotIn(name, headers)

    def test_never_follows_redirect_or_retries_auth(self):
        for path, status in [('/redirect', 302), ('/challenge', 401)]:
            self.server.requests.clear()
            body, metadata = self.request(path)
            self.assertEqual(metadata['status'], status)
            self.assertEqual(body, b'')
            self.assertEqual([p for p, _ in self.server.requests], [path])

    def test_no_ambient_proxy_or_cookie_state(self):
        old = {name: os.environ.get(name) for name in ('http_proxy', 'HTTP_PROXY', 'ALL_PROXY')}
        try:
            for name in old:
                os.environ[name] = 'http://127.0.0.1:1'
            self.request('/plain'); self.request('/plain')
            self.assertEqual(len(self.server.requests), 2)
            for _, headers in self.server.requests:
                self.assertNotIn('Cookie', headers)
        finally:
            for name, value in old.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value

    def test_chunking_and_gzip_are_decoded_before_output_cap(self):
        self.assertEqual(self.request('/early-hints')[0], b'original evidence')
        self.assertEqual(self.request('/chunked')[0], b'evidence')
        self.assertEqual(self.request('/gzip')[0], b'decoded evidence' * 100)
        for path in ['/large', '/bomb', '/huge-header']:
            with self.assertRaises(fetcher.LimitExceeded, msg=path):
                self.request(path)
        for path in ['/truncated-gzip', '/duplicate', '/upgrade', '/unsupported-transfer']:
            with self.assertRaises(ValueError, msg=path):
                self.request(path)

    def test_invalid_urls_and_unsafe_timeouts_do_not_connect(self):
        for url in ['file:///etc/passwd', 'http://localhost/', 'http://127.0.0.1/', 'http://2130706433/', 'https://user:pass@example.org/',
                    'http://foo.local/', 'http://example.org:0/', 'http://example.org:65536/', 'http://a..example/', 'http://[::1]/', 'https://example.org/#fragment']:
            with self.assertRaises(ValueError, msg=url):
                fetcher.fetch(url, '1.1.1.1', 1, io.BytesIO(), io.BytesIO())
        for timeout in [0, -1, 31, float('nan')]:
            with self.assertRaises(ValueError):
                fetcher.fetch('https://example.org/', '1.1.1.1', timeout, io.BytesIO(), io.BytesIO())

    def test_cli_private_pin_is_silent_and_cannot_connect(self):
        result = subprocess.run([sys.executable, '-I', '-S', '-B', str(HELPER), 'https://fixture.invalid/private-source-query', '127.0.0.1', '1'],
                                capture_output=True, timeout=3,
                                env={'PATH': '/usr/bin:/bin', 'HOME': '/var/empty', 'LC_ALL': 'C', 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b''); self.assertEqual(result.stderr, b'')
        self.assertEqual(self.server.requests, [])

    def test_production_swift_has_no_unverified_runtime_or_urlsession_fallback(self):
        swift = (ROOT / 'src/ResearchHTTPTransport.swift').read_text()
        reader = (ROOT / 'src/ResearchNotebook.swift').read_text()
        self.assertIn('guard available else', swift)
        self.assertIn('let runtime = try await verifiedRuntime()', swift)
        self.assertIn('addresses.allSatisfy(ResearchPublicAddress.allowed)', swift)
        self.assertIn('"/usr/bin/sandbox-exec"', swift)
        self.assertIn('"-I", "-S", "-B"', swift)
        self.assertIn('kill(process.processIdentifier, SIGKILL)', swift)
        self.assertIn('ResearchPinnedSocket.connect(address: address', swift)
        self.assertIn('standardInput: socket', swift)
        self.assertIn('process.standardInput = standardInput ?? FileHandle.nullDevice', swift)
        self.assertIn('Darwin.poll(&event, 1, 0)', swift)
        self.assertIn('FD_CLOEXEC', swift)
        self.assertIn('defer { if !transferred { Darwin.close(descriptor) } }', swift)
        self.assertIn('defer { try? socket.close() }', swift)
        helper = HELPER.read_text()
        self.assertIn('connector=inherited_connection', helper)
        self.assertIn('socket.socket(fileno=0)', helper)
        self.assertNotIn('.connect(', helper)
        self.assertNotIn('getaddrinfo', helper)
        self.assertNotIn('DOT_SOURCE_ENDPOINT', swift)
        self.assertNotIn('URLSession(', reader)
        self.assertNotIn('"/usr/bin/curl"', swift)
        profile = (ROOT / 'Resources/Research/source_fetch.sb').read_text()
        for expected in ['(deny network*)', '(deny file-read*)', '(deny file-write*)', '(deny process-exec)']:
            self.assertIn(expected, profile)
        for forbidden in ['(allow network', 'DOT_SOURCE_ENDPOINT', 'DOT_MODELS', 'DOT_RUNTIME', 'DOT_STATE', '(subpath "/Users")', '(subpath "/tmp")']:
            self.assertNotIn(forbidden, profile)

    def test_inherited_socket_checks_peer_port_family_type_and_scope(self):
        for address, family, peer in [('1.1.1.1', socket.AF_INET, ('1.1.1.1', 443)),
                                      ('2606:4700:4700::1111', socket.AF_INET6, ('2606:4700:4700::1111', 443, 0, 0))]:
            inherited = mock.Mock(family=family)
            inherited.getpeername.return_value = peer
            inherited.getsockopt.return_value = socket.SOCK_STREAM
            with mock.patch.object(fetcher.socket, 'socket', return_value=inherited) as create:
                self.assertIs(fetcher.inherited_connection(address, 443, 2), inherited)
            create.assert_called_once_with(fileno=0)
            inherited.settimeout.assert_called_once_with(2)
            inherited.connect.assert_not_called()
            inherited.close.assert_not_called()
        failures = [
            (socket.AF_INET, ('8.8.8.8', 443), socket.SOCK_STREAM),
            (socket.AF_INET, ('1.1.1.1', 80), socket.SOCK_STREAM),
            (socket.AF_INET6, ('1.1.1.1', 443), socket.SOCK_STREAM),
            (socket.AF_INET, ('1.1.1.1', 443), socket.SOCK_DGRAM),
            (socket.AF_INET, ('127.0.0.1', 443), socket.SOCK_STREAM),
        ]
        for family, peer, kind in failures:
            inherited = mock.Mock(family=family)
            inherited.getpeername.return_value = peer
            inherited.getsockopt.return_value = kind
            with mock.patch.object(fetcher.socket, 'socket', return_value=inherited):
                with self.assertRaises(ValueError):
                    fetcher.inherited_connection('1.1.1.1', 443, 2)
            inherited.close.assert_called_once()
            inherited.settimeout.assert_not_called()
        inherited = mock.Mock(family=socket.AF_INET6)
        inherited.getpeername.return_value = ('2606:4700:4700::1111', 443, 0, 3)
        inherited.getsockopt.return_value = socket.SOCK_STREAM
        with mock.patch.object(fetcher.socket, 'socket', return_value=inherited):
            with self.assertRaises(ValueError):
                fetcher.inherited_connection('2606:4700:4700::1111', 443, 2)
        inherited.close.assert_called_once()

    def test_inherited_unconnected_socket_is_closed_and_private_pin_never_opens_it(self):
        inherited = mock.Mock()
        inherited.getpeername.side_effect = OSError('not connected')
        with mock.patch.object(fetcher.socket, 'socket', return_value=inherited) as create:
            with self.assertRaises(OSError):
                fetcher.inherited_connection('1.1.1.1', 443, 2)
            with self.assertRaises(ValueError):
                fetcher.inherited_connection('127.0.0.1', 443, 2)
        create.assert_called_once_with(fileno=0)
        inherited.close.assert_called_once()

    def test_cli_mismatched_inherited_peer_sends_no_request_bytes(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); listener.listen(1)
            with socket.create_connection(listener.getsockname(), timeout=1) as inherited:
                peer, _ = listener.accept()
                with peer:
                    result = subprocess.run([sys.executable, '-I', '-S', '-B', str(HELPER),
                        f'http://fixture.invalid:{listener.getsockname()[1]}/private-source-query', '1.1.1.1', '1'],
                        stdin=inherited, capture_output=True, timeout=3, close_fds=True)
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b'', b''))
                    inherited.shutdown(socket.SHUT_WR)
                    peer.settimeout(1)
                    self.assertEqual(peer.recv(1), b'', 'Rejected peer must receive zero request bytes')
                # Parent still owns its descriptor even though the child closed stdin.
                self.assertEqual(inherited.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE), socket.SOCK_STREAM)

    @unittest.skipUnless(sys.platform == 'darwin', 'Exact Seatbelt profile requires macOS')
    def test_exact_sandbox_uses_only_inherited_socket_and_denies_new_connections(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory).resolve()
            python = pathlib.Path(sys.executable).resolve()
            python_root = pathlib.Path(sys.base_prefix).resolve()
            # Match ResearchFetchRuntime: framework bin/python is an exec trampoline.
            framework = python_root / 'Resources/Python.app/Contents/MacOS/Python'
            if framework.exists():
                python = framework.resolve(strict=True)
            self.assertTrue(python.is_relative_to(python_root), 'Use the official contained test Python runtime')
            canary, secret = directory / 'canary.py', directory / 'private-sentinel'
            secret.write_text('private fixture')
            listener = socket.socket(); denied = socket.socket()
            listener.bind(('127.0.0.1', 0)); listener.listen(2)
            denied.bind(('127.0.0.1', 0)); denied.listen(1)
            try:
                port, forbidden = listener.getsockname()[1], denied.getsockname()[1]
                canary.write_text("""import errno, pathlib, socket, ssl, sys
assert ssl.OPENSSL_VERSION.startswith('OpenSSL ')
ssl.create_default_context(cafile='/etc/ssl/cert.pem')
secret = pathlib.Path(sys.argv[1])
try:
    secret.read_bytes()
except PermissionError:
    pass
else:
    raise AssertionError('private read allowed')
try:
    secret.with_name('forbidden-write').write_text('bad')
except PermissionError:
    pass
else:
    raise AssertionError('write allowed')
connection = socket.socket(fileno=0)
connection.settimeout(1)
assert connection.getpeername() == ('127.0.0.1', int(sys.argv[2]))
assert connection.recv(16) == b'host-owned'
connection.sendall(b'inherited-only')
connection.close()
# Even reconnecting to the same inherited peer must fail. No exception exists.
for port in (int(sys.argv[2]), int(sys.argv[3])):
    fresh = None
    try:
        fresh = socket.socket()
        fresh.settimeout(1)
        fresh.connect(('127.0.0.1', port))
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), error
    else:
        raise AssertionError('fresh connection allowed')
    finally:
        if fresh is not None:
            fresh.close()
print('sandbox-ok')
""")
                with socket.create_connection(listener.getsockname(), timeout=1) as inherited:
                    peer, _ = listener.accept()
                    with peer:
                        peer.sendall(b'host-owned')
                        result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(ROOT / 'Resources/Research/source_fetch.sb'),
                            '-D', 'DOT_SOURCE_PYTHON=' + str(python), '-D', 'DOT_SOURCE_PYTHON_ROOT=' + str(python_root),
                            '-D', 'DOT_SOURCE_HELPER=' + str(canary),
                            str(python), '-I', '-S', '-B', str(canary), str(secret), str(port), str(forbidden)],
                            stdin=inherited, env={'PATH': '/usr/bin:/bin', 'HOME': '/var/empty', 'LC_ALL': 'C', 'PYTHONDONTWRITEBYTECODE': '1'},
                            capture_output=True, timeout=8, close_fds=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.strip(), b'sandbox-ok')
                        peer.settimeout(1)
                        self.assertEqual(peer.recv(16), b'inherited-only')
                for sink in (listener, denied):
                    sink.settimeout(0.05)
                    with self.assertRaises(socket.timeout):
                        sink.accept()
            finally:
                listener.close(); denied.close()

    def test_tls_checks_original_hostname_before_http(self):
        openssl = shutil.which('openssl')
        if not openssl:
            self.skipTest('OpenSSL test certificate generator unavailable')
        with tempfile.TemporaryDirectory() as state:
            state = pathlib.Path(state)
            config = state / 'openssl.cnf'
            config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=fixture.invalid\n[ext]\nsubjectAltName=DNS:fixture.invalid\nbasicConstraints=critical,CA:TRUE\n')
            cert, key = state / 'cert.pem', state / 'key.pem'
            subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(config),
                            '-out', str(cert), '-keyout', str(key)], capture_output=True, check=True, timeout=10)
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            server.requests = []
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            server.socket = server_context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                def connect(_address, _port, timeout):
                    return socket.create_connection(('127.0.0.1', server.server_port), timeout)
                def context():
                    return ssl.create_default_context(cafile=str(cert))
                body, metadata = io.BytesIO(), io.BytesIO()
                fetcher.fetch('https://fixture.invalid/plain', '1.1.1.1', 3, body, metadata, connector=connect, context_factory=context)
                self.assertEqual(body.getvalue(), b'original evidence'); self.assertEqual(len(server.requests), 1)
                server.requests.clear()
                with self.assertRaises(ssl.SSLCertVerificationError):
                    fetcher.fetch('https://mismatch.invalid/plain', '1.1.1.1', 3, io.BytesIO(), io.BytesIO(), connector=connect, context_factory=context)
                self.assertEqual(server.requests, [], 'Wrong TLS hostname must see zero HTTP request bytes')
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_missing_intermediate_fails_without_fetching_private_aia(self):
        openssl = shutil.which('openssl')
        if not openssl:
            self.skipTest('OpenSSL test certificate generator unavailable')
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            def run(*args):
                subprocess.run([openssl, *args], cwd=directory, capture_output=True, check=True, timeout=10)
            key_args = ['-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes']
            (directory / 'root.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Research Test Root\n[ext]\nbasicConstraints=critical,CA:TRUE,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\n')
            run('req', '-x509', *key_args, '-days', '1', '-config', 'root.cnf', '-out', 'root.pem', '-keyout', 'root.key')
            run('req', '-new', *key_args, '-subj', '/CN=Research Test Intermediate', '-out', 'intermediate.csr', '-keyout', 'intermediate.key')
            (directory / 'intermediate.ext').write_text('basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n')
            run('x509', '-req', '-in', 'intermediate.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-CAcreateserial', '-days', '1', '-extfile', 'intermediate.ext', '-out', 'intermediate.pem')
            run('req', '-new', *key_args, '-subj', '/CN=fixture.invalid', '-out', 'leaf.csr', '-keyout', 'leaf.key')
            (directory / 'leaf.ext').write_text(f'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:fixture.invalid\nauthorityInfoAccess=caIssuers;URI:http://127.0.0.1:{self.server.server_port}/intermediate.der\n')
            run('x509', '-req', '-in', 'leaf.csr', '-CA', 'intermediate.pem', '-CAkey', 'intermediate.key', '-CAcreateserial', '-days', '1', '-extfile', 'leaf.ext', '-out', 'leaf.pem')
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.requests = []
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(directory / 'leaf.pem', directory / 'leaf.key')  # Deliberately omit intermediate.
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                connector = lambda _address, _port, timeout: socket.create_connection(('127.0.0.1', server.server_port), timeout)
                trust = lambda: ssl.create_default_context(cafile=str(directory / 'root.pem'))
                with self.assertRaises(ssl.SSLCertVerificationError):
                    fetcher.fetch('https://fixture.invalid/plain', '1.1.1.1', 3, io.BytesIO(), io.BytesIO(), connector=connector, context_factory=trust)
                self.assertEqual(self.server.requests, [], 'AIA listener must see zero requests')
                self.assertEqual(server.requests, [], 'Untrusted source must see zero HTTP bytes')
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
