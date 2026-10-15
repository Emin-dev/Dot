import base64
import hashlib
import errno
import importlib.util
import json
import os
import subprocess
import time
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import patch_splash_listener as patcher
path = Path(__file__).resolve().parents[2] / 'Resources/Runtime/dot_tls.py'
spec = importlib.util.spec_from_file_location('dot_tls_fixture', path)
tls = importlib.util.module_from_spec(spec); spec.loader.exec_module(tls)

class ListenerPatchTests(unittest.TestCase):
    def helper(self):
        namespace = {'socket': socket, 'sys': sys}; exec(patcher.HELPER, namespace)
        return namespace['dot_owned_listener']
    def test_platform_socket_state_query_distinguishes_listener_without_mutation(self):
        def check(value, state, label):
            if sys.platform == 'darwin':
                tcp_conn_info = getattr(socket, 'TCP_CONNECTION_INFO', 0x106)
                self.assertEqual(value.getsockopt(socket.IPPROTO_TCP, tcp_conn_info, 1), bytes([state]), label)
            else:
                self.assertEqual(value.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN), int(state == 1), label)
        with socket.socket() as listener:
            check(listener, 0, 'unbound socket')
            listener.bind(('127.0.0.1', 0))
            check(listener, 0, 'bound-only socket')
            listener.listen(1)
            check(listener, 1, 'listening socket')
            with socket.create_connection(listener.getsockname(), timeout=2) as client:
                accepted, _ = listener.accept()
                with accepted:
                    check(client, 4, 'connected client')
                    check(accepted, 4, 'accepted connection')
            check(listener, 1, 'listener remains unchanged')
    def test_exact_inherited_listener_accepted_without_rebind(self):
        with tls.owned_listener() as listener:
            duplicate = socket.fromfd(listener.fileno(), socket.AF_INET, socket.SOCK_STREAM)
            fd = duplicate.detach()
            adopted = self.helper()(fd, '127.0.0.1', listener.getsockname()[1])
            self.assertEqual(adopted.getsockname(), listener.getsockname()); adopted.close()
            self.assertGreater(listener.fileno(), 0)
    def test_reuse_or_wrong_port_listener_rejected(self):
        with tls.owned_listener() as listener:
            with self.assertRaises(ValueError): self.helper()(listener.fileno(), '127.0.0.1', 1)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            with self.assertRaises(ValueError): self.helper()(listener.fileno(), '127.0.0.1', listener.getsockname()[1])
    def test_missing_upstream_or_changed_source_rejects_overlay(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in patcher.PINNED:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_text('unrecognized source')
            with self.assertRaises(ValueError): patcher.overlay(root)
    def test_ambiguous_anchor_rejected(self):
        with self.assertRaises(ValueError): patcher.once('x x', 'x', 'y')

class CertificateEncodingTests(unittest.TestCase):
    def test_generated_public_key_uses_named_p256_not_explicit_parameters(self):
        # LibreSSL's req defaults differ from current OpenSSL. Check the requested
        # encoding AND actual SPKI bytes, before identity() removes its private files.
        run = subprocess.run
        observed = []
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            def inspect(command, **kwargs):
                self.assertIn('ec_param_enc:named_curve', command)
                result = run(command, **kwargs)
                public = run(['/usr/bin/openssl', 'x509', '-in', str(state / 'session.crt'), '-pubkey', '-noout'],
                             check=True, capture_output=True, timeout=10).stdout
                self.assertLess(len(public), 4096)
                der = base64.b64decode(b''.join(public.splitlines()[1:-1]), validate=True)
                # Canonical SPKI: id-ecPublicKey + prime256v1 OID + uncompressed point.
                prefix = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004')
                self.assertEqual(len(der), 91)
                self.assertTrue(der.startswith(prefix), 'P-256 must use a named-curve OID')
                observed.append(True)
                return result
            with patch.object(tls.subprocess, 'run', side_effect=inspect):
                context, pin = tls.identity(state)
            self.assertEqual(observed, [True])
            self.assertEqual(context.minimum_version, ssl.TLSVersion.TLSv1_2)
            self.assertEqual(len(pin), 64)
            self.assertEqual(list(state.iterdir()), [])

class InheritedTLSListenerTests(unittest.TestCase):
    def test_exact_descriptor_is_adopted_without_bind_or_listen(self):
        with tls.owned_listener() as listener:
            descriptor = os.dup(listener.fileno())
            os.set_inheritable(descriptor, True)
            adopted = tls.adopt_listener(descriptor, listener.getsockname()[1])
            try:
                self.assertEqual(adopted.fileno(), descriptor)
                self.assertEqual(adopted.getsockname(), listener.getsockname())
                self.assertFalse(os.get_inheritable(descriptor))
                with socket.create_connection(adopted.getsockname(), timeout=2) as client:
                    connection, _ = adopted.accept(); connection.close()
            finally: adopted.close()
    def test_wrong_port_reusable_and_non_listening_sockets_are_not_closed_or_adopted(self):
        for mode in ('wrong_port', 'reusable', 'bound_only', 'wildcard'):
            with self.subTest(mode=mode), socket.socket() as listener:
                listener.bind(('0.0.0.0' if mode == 'wildcard' else '127.0.0.1', 0))
                if mode != 'bound_only': listener.listen(1)
                if mode == 'reusable': listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                port = listener.getsockname()[1]
                with self.assertRaises(ValueError): tls.adopt_listener(listener.fileno(), port % 65535 + 1 if mode == 'wrong_port' else port)
                self.assertGreaterEqual(listener.fileno(), 3)
                os.fstat(listener.fileno())
    def test_relay_uses_existing_tls_listener_and_keeps_endpoint_owned(self):
        with tempfile.TemporaryDirectory() as folder, tls.owned_listener() as backend:
            endpoint = tls.owned_listener(); descriptor = endpoint.fileno(); address = endpoint.getsockname()
            relay = tls.TLSRelay(backend, Path(folder), api_key="model-free-test", listener=endpoint)
            try:
                self.assertEqual(relay.listener.fileno(), descriptor)
                self.assertEqual(relay.port, address[1])
                with socket.socket() as contender:
                    with self.assertRaises(OSError) as error: contender.bind(address)
                    self.assertEqual(error.exception.errno, errno.EADDRINUSE)
            finally: relay.close()

class AuthenticatedRelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.state = Path(self.temp.name)
        self.backend = tls.owned_listener(); self.backend.settimeout(4)
        self.relay = tls.TLSRelay(self.backend, self.state, api_key="model-free-test")
    def tearDown(self):
        self.relay.close(); self.backend.close(); self.temp.cleanup()
    def client(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
        connection = context.wrap_socket(socket.create_connection(('127.0.0.1', self.relay.port), timeout=3), server_hostname='dot.local')
        connection.settimeout(3)
        return connection
    def test_exact_loopback_traffic_stays_owned_during_competing_binds(self):
        # Darwin can allow a wildcard bind alongside a specific local address.
        # Prove connection delivery, not merely whether bind() raises.
        cases = [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::'), (socket.AF_INET6, '::ffff:127.0.0.1')]
        for family, host in cases:
            with self.subTest(host=host), socket.socket(family, socket.SOCK_STREAM) as attacker:
                attacker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                attacker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                if family == socket.AF_INET6: attacker.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                competing = False
                try:
                    attacker.bind((host, self.backend.getsockname()[1])); attacker.listen(1); competing = True
                except OSError as error:
                    self.assertEqual(error.errno, errno.EADDRINUSE)
                # Simulate the adopted child descriptor closing; the supervisor still owns its FD.
                adopted = socket.socket(fileno=os.dup(self.backend.fileno()))
                self.assertEqual(adopted.getsockname(), self.backend.getsockname()); adopted.close()
                for _ in range(3):
                    with socket.create_connection(self.backend.getsockname(), timeout=2) as client:
                        client.sendall(b'ownership fixture')
                        owned, _ = self.backend.accept()
                        with owned:
                            owned.settimeout(2); self.assertEqual(owned.recv(100), b'ownership fixture')
                            owned.sendall(b'owned'); self.assertEqual(client.recv(100), b'owned')
                if competing:
                    attacker.settimeout(0.05)
                    with self.assertRaises(socket.timeout): attacker.accept()
    def test_pinned_tls_roundtrip_and_each_reconnect(self):
        received = []
        def backend():
            for _ in range(2):
                connection, _ = self.backend.accept()
                with connection:
                    connection.settimeout(3); received.append(connection.recv(4096)); connection.sendall(b'local reply')
        thread = threading.Thread(target=backend); thread.start()
        try:
            for _ in range(2):
                with self.client() as connection:
                    digest = hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()
                    self.assertEqual(digest, self.relay.certificate_sha256)
                    connection.sendall(b'GET /fixture HTTP/1.1\r\nAuthorization: Bearer model-free-test\r\n\r\n'); self.assertEqual(connection.recv(100), b'local reply')
            thread.join(timeout=4); self.assertFalse(thread.is_alive())
            self.assertEqual(received, [b'GET /fixture HTTP/1.1\r\nAuthorization: Bearer model-free-test\r\n\r\n'] * 2)
            self.assertFalse((self.state / 'session.key').exists()); self.assertFalse((self.state / 'session.crt').exists())
        finally: thread.join(timeout=4)
    def test_wrong_pin_sends_no_private_application_bytes(self):
        with self.client() as connection:
            digest = hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()
            self.assertNotEqual(digest, '0' * 64)
            # Client refuses this identity before writing any bearer/prompt/image.
        self.backend.settimeout(0.1)
        with self.assertRaises(socket.timeout): self.backend.accept()
    def test_close_stops_workers_before_backend_can_be_rebound(self):
        connection = self.client()
        self.relay.close(); connection.close()
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.workers)
        with socket.socket() as attacker:
            with self.assertRaises(OSError): attacker.bind(self.backend.getsockname())

class NativeFixtureContractTests(unittest.TestCase):
    def test_fixture_exposes_pin_and_stops_on_parent_eof(self):
        fixture = Path(__file__).resolve().parents[1] / 'Fixtures/tls_endpoint.py'
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            child = subprocess.Popen([sys.executable, '-I', '-B', str(fixture), folder], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not (state / 'ready.json').exists() and time.monotonic() < deadline:
                    self.assertIsNone(child.poll()); time.sleep(0.01)
                ready = json.loads((state / 'ready.json').read_text())
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
                with context.wrap_socket(socket.create_connection(('127.0.0.1', ready['port']), timeout=2), server_hostname='dot.local') as connection:
                    self.assertEqual(hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest(), ready['pin'])
                    connection.sendall(b'GET /fixture HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer model-free-test\r\n\r\n')
                    self.assertIn(b'200 OK', connection.recv(4096))
                child.stdin.close(); child.wait(timeout=4)
                self.assertEqual(child.returncode, 0, child.stderr.read().decode())
            finally:
                if child.poll() is None: child.kill(); child.wait()
                child.stderr.close()
