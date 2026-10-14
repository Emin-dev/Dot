"""Loopback-only admission/streaming regressions against the production TLS relay.

Run directly with python3 -B Tests/Python/test_tls_admission.py -v.
Synthetic credentials only; never starts Splash or loads a model.
"""
import hashlib
import importlib.util
from pathlib import Path
import socket
import ssl
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dot_tls_admission_fixture', ROOT / 'Resources/Runtime/dot_tls.py')
tls = importlib.util.module_from_spec(spec); spec.loader.exec_module(tls)
TOKEN = 'model-free-test'
HEADER = b'GET /fixture HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer model-free-test\r\n\r\n'
RESPONSE = b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK'


class TLSAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.backend = tls.owned_listener()
        self.relay = tls.TLSRelay(self.backend, Path(self.temporary.name), api_key=TOKEN)
        self.clients = []
        self.upstreams = []

    def tearDown(self):
        self.relay.close()
        for connection in self.clients + self.upstreams: connection.close()
        self.backend.close(); self.temporary.cleanup()

    def client(self, handshake=True):
        raw = socket.create_connection(('127.0.0.1', self.relay.port), timeout=2)
        if not handshake:
            self.clients.append(raw); return raw
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
        try: secure = context.wrap_socket(raw, server_hostname='dot.local')
        except BaseException:
            raw.close(); raise
        self.clients.append(secure)
        # A fixture trust store is unnecessary: verify the exact per-launch pin
        # before sending even the synthetic token or body.
        self.assertEqual(hashlib.sha256(secure.getpeercert(binary_form=True)).hexdigest(), self.relay.certificate_sha256)
        return secure

    def upstream(self):
        self.backend.settimeout(2)
        connection, _ = self.backend.accept(); connection.settimeout(2)
        self.upstreams.append(connection)
        return connection

    def receive_exact(self, connection, length):
        data = bytearray()
        while len(data) < length:
            piece = connection.recv(length - len(data))
            self.assertTrue(piece, 'connection closed before expected fixture bytes')
            data.extend(piece)
        return bytes(data)

    def no_upstream(self):
        self.backend.settimeout(0.05)
        with self.assertRaises(socket.timeout): self.backend.accept()

    def wait_workers(self, count, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.relay.lock: actual = len(self.relay.workers)
            if actual == count: return
            time.sleep(0.005)
        self.fail(f'expected {count} relay workers, got {actual}')

    def assert_closed(self, connection):
        try: self.assertEqual(connection.recv(1), b'')
        except (ConnectionResetError, ssl.SSLError): pass

    def exchange(self, response=RESPONSE):
        client = self.client(); client.sendall(HEADER)
        upstream = self.upstream()
        self.assertEqual(self.receive_exact(upstream, len(HEADER)), HEADER)
        upstream.sendall(response)
        self.assertEqual(self.receive_exact(client, len(response)), response)
        return client, upstream

    def test_four_held_unauthenticated_tls_clients_allow_valid_fifth_without_upstreams(self):
        held = [self.client() for _ in range(4)]
        self.wait_workers(4); self.no_upstream()
        with self.relay.lock: self.assertEqual(len(self.relay.connections), 4)
        client, upstream = self.exchange()
        # The regression succeeds while all four idle clients remain pending,
        # rather than waiting for their deadline to release old forwarding slots.
        self.wait_workers(5)
        with self.relay.lock: self.assertEqual(len(self.relay.connections), 6)
        self.no_upstream()
        client.close(); upstream.close()
        for connection in held: connection.close()
        self.wait_workers(0)

    def test_pending_pool_overflow_is_bounded_and_releases_after_cancel(self):
        held = [self.client() for _ in range(self.relay.pending_limit)]
        self.wait_workers(self.relay.pending_limit); self.no_upstream()
        with self.assertRaises((OSError, ssl.SSLError)): self.client()
        self.wait_workers(self.relay.pending_limit)
        with self.relay.lock: self.assertEqual(len(self.relay.connections), self.relay.pending_limit)
        held.pop().close(); self.wait_workers(self.relay.pending_limit - 1)
        self.exchange(); self.no_upstream()

    def test_authenticated_capacity_is_separate_and_overflow_opens_no_upstream(self):
        pairs = [self.exchange() for _ in range(self.relay.forwarding_limit)]
        self.wait_workers(self.relay.forwarding_limit)
        rejected = self.client(); rejected.sendall(HEADER); self.assert_closed(rejected)
        self.no_upstream()
        idle = [self.client() for _ in range(self.relay.pending_limit)]
        self.wait_workers(self.relay.forwarding_limit + self.relay.pending_limit)
        with self.relay.lock:
            self.assertEqual(len(self.relay.connections), 2 * self.relay.forwarding_limit + self.relay.pending_limit)
        # Pending clients cannot disrupt already authenticated streaming sockets.
        pairs[0][1].sendall(b'next fixture chunk')
        self.assertEqual(self.receive_exact(pairs[0][0], 18), b'next fixture chunk')
        for client in idle: client.close()
        for client, upstream in pairs: client.close(); upstream.close()
        self.wait_workers(0); self.exchange()

    def test_missing_wrong_duplicate_and_malformed_authorization_never_connect(self):
        requests = [
            b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
            HEADER.replace(b'model-free-test', b'incorrect'),
            HEADER.replace(b'Bearer ', b'Basic '),
            HEADER.replace(b'Bearer ', b'bearer '),
            HEADER[:-2] + b'Authorization: Bearer model-free-test\r\n\r\n',
            HEADER[:-2] + b'authorization: Bearer incorrect\r\n\r\n',
            HEADER.replace(b'Authorization:', b'Authorization :'),
            HEADER.replace(b'Authorization:', b' Authorization:'),
            HEADER.replace(b'Authorization:', b'X: a\r\n\tAuthorization:'),
            HEADER.replace(b'Host: localhost', b'Host localhost'),
            HEADER.replace(b'Host: localhost', b'Host: local\x00host'),
            HEADER.replace(b'Host: localhost', b'Host: local\nhost'),
            HEADER.replace(b'HTTP/1.1', b'HTTP/2'),
            HEADER.replace(b'GET /fixture ', b'GET  /fixture '),
            HEADER[:-2] + b'X: x\r\n' * 101 + b'\r\n',
        ]
        for index, request in enumerate(requests):
            with self.subTest(index=index):
                connection = self.client(); connection.sendall(request)
                self.assert_closed(connection); self.wait_workers(0); self.no_upstream()
        self.exchange()

    def test_header_overflow_never_connects_and_exact_limit_is_accepted(self):
        filler = b'X-Padding: '
        prefix = HEADER[:-2] + filler
        oversized = prefix + b'x' * self.relay.header_limit
        connection = self.client()
        connection.sendall(oversized); self.assert_closed(connection)
        self.wait_workers(0); self.no_upstream()
        request = prefix + b'x' * (self.relay.header_limit - len(prefix) - 4) + b'\r\n\r\n'
        self.assertEqual(len(request), self.relay.header_limit)
        connection = self.client(); connection.sendall(request)
        upstream = self.upstream()
        self.assertEqual(self.receive_exact(upstream, len(request)), request)
        upstream.sendall(RESPONSE)
        self.assertEqual(self.receive_exact(connection, len(RESPONSE)), RESPONSE)

    def test_total_deadline_covers_partial_handshake_header_and_trickle(self):
        self.relay.admission_timeout = 0.3
        raw = self.client(handshake=False)
        partial = self.client(); partial.sendall(HEADER[:-3])
        trickle = self.client(); trickle.sendall(b'G')
        started = time.monotonic()
        for _ in range(6):
            time.sleep(0.07)
            try: trickle.sendall(b'E')
            except OSError: break
        self.wait_workers(0, timeout=1)
        self.assertLess(time.monotonic() - started, 0.9)
        for connection in (raw, partial, trickle): self.assert_closed(connection)
        self.no_upstream(); self.exchange()

    def test_header_deadline_does_not_restart_after_slow_handshake(self):
        self.relay.admission_timeout = 0.8
        raw = self.client(handshake=False)
        self.wait_workers(1)
        started = time.monotonic()
        time.sleep(0.5)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
        secure = context.wrap_socket(raw, server_hostname='dot.local'); self.clients.append(secure)
        secure.sendall(HEADER[:-2])
        self.assert_closed(secure)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 1.15, 'header timeout restarted after handshake')
        self.wait_workers(0); self.no_upstream(); self.exchange()

    def test_stop_racing_tls_wrap_closes_new_secure_socket_without_upstream(self):
        entered = threading.Event(); release = threading.Event()
        wrap = self.relay.context.wrap_socket
        def paused(*args, **kwargs):
            secure = wrap(*args, **kwargs)
            entered.set(); release.wait(timeout=2)
            return secure
        with patch.object(self.relay.context, 'wrap_socket', side_effect=paused):
            raw = self.client(handshake=False); self.assertTrue(entered.wait(timeout=1))
            closer = threading.Thread(target=self.relay.close); closer.start()
            self.assertTrue(self.relay.stopping.wait(timeout=1))
            release.set(); closer.join(timeout=3); self.assertFalse(closer.is_alive())
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.workers)
        self.assertFalse(self.relay.connections); self.assert_closed(raw); self.no_upstream()

    def test_valid_slow_handshake_and_header_survive_cancellation_poll_timeouts(self):
        handshake_timeouts = []; header_timeouts = []
        handshake_retried = threading.Event(); header_retried = threading.Event()
        handshake = ssl.SSLSocket.do_handshake; recv = ssl.SSLSocket.recv
        def observed_handshake(connection, *args, **kwargs):
            try: return handshake(connection, *args, **kwargs)
            except socket.timeout:
                if connection.server_side:
                    handshake_timeouts.append(True)
                    if len(handshake_timeouts) >= 2: handshake_retried.set()
                raise
        def observed_recv(connection, *args, **kwargs):
            try: return recv(connection, *args, **kwargs)
            except socket.timeout:
                if connection.server_side:
                    header_timeouts.append(True)
                    if len(header_timeouts) >= 2: header_retried.set()
                raise
        with patch.object(ssl.SSLSocket, 'do_handshake', observed_handshake), \
             patch.object(ssl.SSLSocket, 'recv', observed_recv):
            raw = self.client(handshake=False); self.wait_workers(1)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
            incoming = ssl.MemoryBIO(); outgoing = ssl.MemoryBIO()
            client = context.wrap_bio(incoming, outgoing, server_hostname='dot.local')
            # Send a real ClientHello, then withhold the remaining handshake
            # until the server has retried its partially advanced TLS state.
            with self.assertRaises(ssl.SSLWantReadError): client.do_handshake()
            raw.sendall(outgoing.read())
            self.assertTrue(handshake_retried.wait(timeout=0.8))
            while True:
                try:
                    client.do_handshake(); break
                except ssl.SSLWantReadError:
                    if outgoing.pending: raw.sendall(outgoing.read())
                    data = raw.recv(16384); self.assertTrue(data)
                    incoming.write(data)
            if outgoing.pending: raw.sendall(outgoing.read())
            self.assertEqual(hashlib.sha256(client.getpeercert(binary_form=True)).hexdigest(), self.relay.certificate_sha256)
            client.write(HEADER[:-2]); raw.sendall(outgoing.read())
            self.assertTrue(header_retried.wait(timeout=0.8)); self.no_upstream()
            client.write(HEADER[-2:]); raw.sendall(outgoing.read())
            upstream = self.upstream()
            self.assertEqual(self.receive_exact(upstream, len(HEADER)), HEADER)
            upstream.sendall(RESPONSE)
            response = bytearray()
            while len(response) < len(RESPONSE):
                try:
                    data = client.read(len(RESPONSE) - len(response)); self.assertTrue(data)
                    response.extend(data)
                except ssl.SSLWantReadError:
                    data = raw.recv(16384); self.assertTrue(data)
                    incoming.write(data)
            self.assertEqual(response, RESPONSE)
        self.assertGreaterEqual(len(handshake_timeouts), 2)
        self.assertGreaterEqual(len(header_timeouts), 2)

    def test_each_keepalive_request_and_response_remains_byte_identical(self):
        response = RESPONSE.replace(b'Connection: close', b'Connection: keep-alive')
        client, upstream = self.exchange(response=response)
        for request in (HEADER, HEADER.replace(b'model-free-test', b'incorrect')):
            # This is initial connection admission, not a replacement HTTP server:
            # Splash still authenticates each request on an admitted connection.
            client.sendall(request)
            self.assertEqual(self.receive_exact(upstream, len(request)), request)
            upstream.sendall(response)
            self.assertEqual(self.receive_exact(client, len(response)), response)

    def test_fragmented_header_body_large_upload_sse_and_backend_eof_are_unchanged(self):
        client = self.client()
        body = b'fixture-body-' * 8000
        header = (b'POST /v1/chat/completions HTTP/1.1\r\nhost: localhost\r\n'
                  b'authorization:\tBearer model-free-test \t\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n')
        client.sendall(header[:20]); self.no_upstream()
        client.sendall(header[20:-2]); self.no_upstream()
        client.sendall(header[-2:] + body[:200])
        upstream = self.upstream()
        first = header + body[:200]
        self.assertEqual(self.receive_exact(upstream, len(first)), first)
        sender = threading.Thread(target=client.sendall, args=(body[200:],)); sender.start()
        self.assertEqual(self.receive_exact(upstream, len(body) - 200), body[200:])
        sender.join(timeout=2); self.assertFalse(sender.is_alive())
        for chunk in (b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n',
                      b'data: {"content":"fixture"}\n\n', b'data: [DONE]\n\n'):
            upstream.sendall(chunk)
            self.assertEqual(self.receive_exact(client, len(chunk)), chunk)
        upstream.shutdown(socket.SHUT_RDWR); upstream.close()
        self.assert_closed(client); self.wait_workers(0)

    def test_expect_continue_and_chunked_request_remain_streamed(self):
        client = self.client()
        header = (b'POST /fixture HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer model-free-test\r\n'
                  b'Expect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n')
        client.sendall(header)
        upstream = self.upstream(); self.assertEqual(self.receive_exact(upstream, len(header)), header)
        interim = b'HTTP/1.1 100 Continue\r\n\r\n'
        upstream.sendall(interim); self.assertEqual(self.receive_exact(client, len(interim)), interim)
        chunks = b'7\r\nfixture\r\n0\r\n\r\n'
        client.sendall(chunks); self.assertEqual(self.receive_exact(upstream, len(chunks)), chunks)
        upstream.sendall(RESPONSE); self.assertEqual(self.receive_exact(client, len(RESPONSE)), RESPONSE)

    def test_client_cancel_releases_authenticated_slot_and_closes_upstream(self):
        client, upstream = self.exchange()
        client.close()
        self.assertEqual(upstream.recv(1), b'')
        self.wait_workers(0); self.exchange()

    def test_failed_backend_connect_releases_both_pools(self):
        with patch.object(tls.socket, 'create_connection', side_effect=ConnectionRefusedError):
            # create the local client without using the patched convenience API.
            raw = socket.socket(); raw.settimeout(2); raw.connect(('127.0.0.1', self.relay.port))
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
            client = context.wrap_socket(raw, server_hostname='dot.local'); self.clients.append(client)
            client.sendall(HEADER); self.assert_closed(client); self.wait_workers(0)
        self.no_upstream(); self.exchange()

    def test_stop_joins_pending_and_authenticated_workers_before_backend_release(self):
        self.client(handshake=False)
        partial = self.client(); partial.sendall(HEADER[:-2])
        self.client()
        client, upstream = self.exchange()
        self.wait_workers(4)
        started = time.monotonic(); self.relay.close()
        self.assertLess(time.monotonic() - started, 1)
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.thread.is_alive())
        self.assertFalse(self.relay.workers); self.assertFalse(self.relay.connections)
        self.assertEqual(upstream.recv(1), b'')
        with socket.socket() as contender:
            with self.assertRaises(OSError): contender.bind(self.backend.getsockname())
        # The retained backend remains listening and owned, never shutdown by Stop.
        with socket.create_connection(self.backend.getsockname(), timeout=1) as direct:
            accepted = self.upstream(); direct.sendall(b'owned')
            self.assertEqual(accepted.recv(5), b'owned')
        with self.assertRaises(OSError): socket.create_connection(('127.0.0.1', self.relay.port), timeout=1)
        self.relay.close()  # Repeated Stop is safe.

    def test_stop_does_not_require_cross_thread_tls_socket_wakeup(self):
        # Model platforms where closing a socket in another thread does not
        # interrupt an in-flight TLS operation. Workers still own final close.
        stopper = threading.current_thread()
        close = ssl.SSLSocket.close
        shutdown = ssl.SSLSocket.shutdown
        def worker_close(connection):
            if threading.current_thread() is not stopper: close(connection)
        def worker_shutdown(connection, how):
            if threading.current_thread() is not stopper: shutdown(connection, how)
        with patch.object(ssl.SSLSocket, 'close', worker_close), \
             patch.object(ssl.SSLSocket, 'shutdown', worker_shutdown):
            self.test_stop_joins_pending_and_authenticated_workers_before_backend_release()

    def test_stop_racing_backend_connect_does_not_leave_untracked_socket(self):
        entered = threading.Event(); release = threading.Event()
        create = socket.create_connection
        def paused(address, **kwargs):
            connection = create(address, **kwargs)
            entered.set(); release.wait(timeout=2)
            return connection
        client = self.client()
        with patch.object(tls.socket, 'create_connection', side_effect=paused):
            client.sendall(HEADER); self.assertTrue(entered.wait(timeout=1))
            upstream = self.upstream()
            closer = threading.Thread(target=self.relay.close); closer.start()
            self.assertTrue(self.relay.stopping.wait(timeout=1))
            release.set(); closer.join(timeout=3); self.assertFalse(closer.is_alive())
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.workers)
        self.assertFalse(self.relay.connections); self.assertEqual(upstream.recv(1), b'')
        self.assert_closed(client)

    def test_bad_tls_and_prehandshake_disconnect_release_pending_capacity(self):
        for _ in range(3):
            connection = self.client(handshake=False)
            connection.sendall(b'GET /not-tls HTTP/1.1\r\n\r\n')
            self.assert_closed(connection); self.wait_workers(0); self.no_upstream()
            connection = self.client(handshake=False); connection.close()
            self.wait_workers(0)
        self.exchange()

    def test_authenticated_forwarding_lifetime_is_still_bounded(self):
        self.relay.connection_lifetime = 0.1
        client, upstream = self.exchange()
        self.wait_workers(0, timeout=1)
        self.assert_closed(client); self.assertEqual(upstream.recv(1), b'')
        self.exchange()

    def test_missing_or_invalid_credential_fails_before_listener_or_identity(self):
        with patch.object(tls, 'identity') as identity, patch.object(tls, 'owned_listener') as owned:
            with self.assertRaises(TypeError): tls.TLSRelay(self.backend, Path(self.temporary.name))
            for value in ('', '\r\n', 'fixture secret', 'x' * 300, None):
                with self.assertRaises(ValueError): tls.TLSRelay(self.backend, Path(self.temporary.name), api_key=value)
            identity.assert_not_called(); owned.assert_not_called()


if __name__ == '__main__': unittest.main()
