"""Loopback-only admission/streaming regressions against the production TLS relay.

Run directly with python3 -B Tests/Python/test_tls_admission.py -v.
Synthetic credentials only; never starts Splash or loads a model.
"""
import errno
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

    def client(self, handshake=True, *, receive_buffer=None):
        if receive_buffer is None:
            raw = socket.create_connection(('127.0.0.1', self.relay.port), timeout=2)
        else:
            # TCP cannot retract a previously advertised receive window. Set
            # the pressure fixture's bound before connect/window negotiation.
            raw = socket.socket(); raw.settimeout(2)
            try:
                raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_buffer)
                raw.connect(('127.0.0.1', self.relay.port))
            except BaseException:
                raw.close(); raise
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

    def exchange(self, response=RESPONSE, *, receive_buffer=None):
        client = self.client(receive_buffer=receive_buffer); client.sendall(HEADER)
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
        with patch.object(socket.socket, 'connect_ex', return_value=errno.ECONNREFUSED):
            # Client setup still uses connect(); only the backend attempt fails.
            raw = socket.socket(); raw.settimeout(2); raw.connect(('127.0.0.1', self.relay.port))
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
            client = context.wrap_socket(raw, server_hostname='dot.local'); self.clients.append(client)
            client.sendall(HEADER); self.assert_closed(client); self.wait_workers(0)
        self.no_upstream(); self.exchange()

    def bio_client(self):
        raw = self.client(handshake=False)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
        incoming = ssl.MemoryBIO(); outgoing = ssl.MemoryBIO()
        client = context.wrap_bio(incoming, outgoing, server_hostname='dot.local')
        while True:
            try:
                client.do_handshake(); break
            except ssl.SSLWantReadError:
                if outgoing.pending: raw.sendall(outgoing.read())
                data = raw.recv(16384); self.assertTrue(data); incoming.write(data)
        if outgoing.pending: raw.sendall(outgoing.read())
        self.assertEqual(hashlib.sha256(client.getpeercert(binary_form=True)).hexdigest(), self.relay.certificate_sha256)
        client.write(HEADER); raw.sendall(outgoing.read())
        upstream = self.upstream()
        self.assertEqual(self.receive_exact(upstream, len(HEADER)), HEADER)
        return raw, client, outgoing, upstream

    def assert_prompt_stop_without_tls_wakeup(self):
        stopper = threading.current_thread()
        close = ssl.SSLSocket.close; shutdown = ssl.SSLSocket.shutdown
        def worker_close(connection):
            if threading.current_thread() is not stopper: close(connection)
        def worker_shutdown(connection, how):
            if threading.current_thread() is not stopper: shutdown(connection, how)
        with patch.object(ssl.SSLSocket, 'close', worker_close), \
             patch.object(ssl.SSLSocket, 'shutdown', worker_shutdown):
            started = time.monotonic(); self.relay.close()
            self.assertLess(time.monotonic() - started, 1)
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.thread.is_alive())
        self.assertFalse(self.relay.workers); self.assertFalse(self.relay.connections)
        with socket.socket() as contender:
            with self.assertRaises(OSError): contender.bind(self.backend.getsockname())
        with socket.create_connection(self.backend.getsockname(), timeout=1) as direct:
            accepted = self.upstream(); direct.sendall(b'owned')
            self.assertEqual(accepted.recv(5), b'owned')
        with self.assertRaises(OSError): socket.create_connection(('127.0.0.1', self.relay.port), timeout=1)

    def test_stop_during_partial_authenticated_tls_record_needs_no_cross_thread_wakeup(self):
        raw, client, outgoing, upstream = self.bio_client()
        client.write(b'next authenticated request'); encrypted = outgoing.read()
        entered = threading.Event(); recv = ssl.SSLSocket.recv
        def observed_recv(connection, *args, **kwargs):
            if connection.server_side: entered.set()
            return recv(connection, *args, **kwargs)
        with patch.object(ssl.SSLSocket, 'recv', observed_recv):
            # select() sees real encrypted bytes, but SSL_read still needs the
            # remainder of this valid record. Stop must not wait its full budget.
            raw.sendall(encrypted[:1]); self.assertTrue(entered.wait(timeout=1))
            self.assert_prompt_stop_without_tls_wakeup()
        self.assertEqual(upstream.recv(1), b'')

    def test_slow_authenticated_tls_record_survives_readiness_retries_without_byte_changes(self):
        raw, client, outgoing, upstream = self.bio_client()
        payload = b'next authenticated request' * 200
        client.write(payload); encrypted = outgoing.read()
        retried = threading.Event(); timeouts = []; recv = ssl.SSLSocket.recv
        def observed_recv(connection, *args, **kwargs):
            try: return recv(connection, *args, **kwargs)
            except (socket.timeout, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                if connection.server_side:
                    timeouts.append(True)
                    if len(timeouts) >= 2: retried.set()
                raise
        with patch.object(ssl.SSLSocket, 'recv', observed_recv):
            raw.sendall(encrypted[:1]); self.assertTrue(retried.wait(timeout=0.8))
            raw.sendall(encrypted[1:])
            self.assertEqual(self.receive_exact(upstream, len(payload)), payload)
        self.assertGreaterEqual(len(timeouts), 2)
        self.wait_workers(1)

    def test_partial_authenticated_record_keeps_total_io_deadline(self):
        self.relay.io_timeout = 0.35
        raw, client, outgoing, upstream = self.bio_client()
        client.write(b'never completed'); encrypted = outgoing.read()
        started = time.monotonic(); raw.sendall(encrypted[:1])
        for byte in encrypted[1:5]:
            time.sleep(0.1)
            try: raw.sendall(bytes([byte]))
            except OSError: break
        self.wait_workers(0, timeout=0.3)
        self.assertLess(time.monotonic() - started, 0.8)
        self.assertEqual(upstream.recv(1), b'')

    def pressure_tls_output(self, client):
        client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        with self.relay.lock:
            secure = next(connection for connection in self.relay.connections
                          if isinstance(connection, ssl.SSLSocket))
        secure.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)

    def test_stop_during_authenticated_tls_backpressure_needs_no_cross_thread_wakeup(self):
        client, upstream = self.exchange(); self.pressure_tls_output(client)
        retried = threading.Event(); send = ssl.SSLSocket.send
        def observed_send(connection, *args, **kwargs):
            try: return send(connection, *args, **kwargs)
            except (socket.timeout, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                if connection.server_side: retried.set()
                raise
        def flood():
            try: upstream.sendall(b'fixture response' * 131072)
            except OSError: pass  # Stop closes the actual upstream endpoint.
        sender = threading.Thread(target=flood)
        with patch.object(ssl.SSLSocket, 'send', observed_send):
            sender.start()
            try:
                self.assertTrue(retried.wait(timeout=0.8))
                self.assert_prompt_stop_without_tls_wakeup()
            finally:
                self.relay.close(); sender.join(timeout=3)
        self.assertFalse(sender.is_alive())

    def test_authenticated_tls_backpressure_keeps_total_send_deadline(self):
        self.relay.io_timeout = 0.35
        client, upstream = self.exchange(receive_buffer=4096); self.pressure_tls_output(client)
        retried = threading.Event(); send = ssl.SSLSocket.send
        sendall = self.relay._sendall; operations = []
        def observed_sendall(connection, data):
            if not isinstance(connection, ssl.SSLSocket): return sendall(connection, data)
            operation = {'started': time.monotonic(), 'retries': 0}
            operations.append(operation)
            result = sendall(connection, data)
            operation.update(result=result, elapsed=time.monotonic() - operation['started'])
            return result
        def observed_send(connection, *args, **kwargs):
            try: return send(connection, *args, **kwargs)
            except (socket.timeout, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                if connection.server_side:
                    operations[-1]['retries'] += 1; retried.set()
                raise
        def flood():
            try: upstream.sendall(b'fixture response' * 131072)
            except OSError: pass
        sender = threading.Thread(target=flood)
        with patch.object(ssl.SSLSocket, 'send', observed_send), \
             patch.object(self.relay, '_sendall', observed_sendall):
            started = time.monotonic(); sender.start()
            try:
                self.assertTrue(retried.wait(timeout=0.8))
                self.wait_workers(0, timeout=0.8)
                self.assertLess(time.monotonic() - started, 0.9)
                # A transient WANT can finish normally. Prove one particular
                # unfinished production send exhausted its unchanged budget.
                failed = [operation for operation in operations if not operation['result']]
                self.assertEqual(len(failed), 1)
                self.assertGreaterEqual(failed[0]['retries'], 2)
                self.assertGreaterEqual(failed[0]['elapsed'], 0.3)
                self.assertLess(failed[0]['elapsed'], 0.8)
                self.assertFalse(self.relay.stopping.is_set())
            finally:
                self.relay.close(); sender.join(timeout=3)
        self.assertFalse(sender.is_alive()); self.assertFalse(self.relay.connections)

    def test_authenticated_tls_backpressure_retries_preserve_every_response_byte(self):
        client, upstream = self.exchange(); self.pressure_tls_output(client)
        payload = bytes(range(256)) * 512
        retried = threading.Event(); timeouts = []; errors = []; send = ssl.SSLSocket.send
        def observed_send(connection, *args, **kwargs):
            try: return send(connection, *args, **kwargs)
            except (socket.timeout, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                if connection.server_side:
                    timeouts.append(True)
                    if len(timeouts) >= 2: retried.set()
                raise
        def flood():
            try: upstream.sendall(payload)
            except OSError as error: errors.append(error)
        sender = threading.Thread(target=flood)
        with patch.object(ssl.SSLSocket, 'send', observed_send):
            sender.start()
            try:
                self.assertTrue(retried.wait(timeout=0.8))
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
                self.assertEqual(self.receive_exact(client, len(payload)), payload)
            finally:
                sender.join(timeout=3)
        self.assertFalse(sender.is_alive()); self.assertEqual(errors, [])
        self.assertGreaterEqual(len(timeouts), 2)
        upstream.sendall(b'next response')
        self.assertEqual(self.receive_exact(client, 13), b'next response')

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

    def fill_backend_accept_queue(self):
        # Discover the platform's actual finite queue length, rather than assume
        # Linux's backlog+1 behavior. A real connect timeout proves saturation.
        for count in range(64):
            connection = socket.socket(); connection.settimeout(0.05)
            try: connection.connect(self.backend.getsockname())
            except socket.timeout:
                connection.close(); return count
            except BaseException:
                connection.close(); raise
            self.clients.append(connection)
        self.fail('backend accept queue did not saturate within fixture bound')

    def test_stop_during_saturated_backend_connect_closes_tracked_socket_and_worker(self):
        client = self.client(); queued = self.fill_backend_accept_queue()
        entered = threading.Event(); captured = []; tracked = []
        connect = socket.socket.connect; connect_ex = socket.socket.connect_ex
        close = socket.socket.close; shutdown = socket.socket.shutdown
        stopper = threading.current_thread()
        def worker_close(connection):
            if connection not in captured or threading.current_thread() is not stopper: close(connection)
        def worker_shutdown(connection, how):
            if connection not in captured or threading.current_thread() is not stopper: shutdown(connection, how)
        def observed(operation, connection, address):
            if address == self.backend.getsockname():
                captured.append(connection)
                with self.relay.lock: tracked.append(connection in self.relay.connections)
                entered.set()
            return operation(connection, address)
        with patch.object(socket.socket, 'connect', lambda connection, address: observed(connect, connection, address)), \
             patch.object(socket.socket, 'connect_ex', lambda connection, address: observed(connect_ex, connection, address)), \
             patch.object(socket.socket, 'close', worker_close), \
             patch.object(socket.socket, 'shutdown', worker_shutdown):
            client.sendall(HEADER); self.assertTrue(entered.wait(timeout=1))
            with self.relay.lock: workers = list(self.relay.workers)
            started = time.monotonic(); self.relay.close()
            self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(tracked, [True]); self.assertEqual([item.fileno() for item in captured], [-1])
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.thread.is_alive())
        self.assertFalse(self.relay.workers); self.assertFalse(self.relay.connections)
        self.assertTrue(workers); self.assertTrue(all(not worker.is_alive() for worker in workers))
        with socket.socket() as contender:
            with self.assertRaises(OSError): contender.bind(self.backend.getsockname())
        for _ in range(queued): self.upstream().close()
        with socket.create_connection(self.backend.getsockname(), timeout=1) as direct:
            accepted = self.upstream(); direct.sendall(b'owned')
            self.assertEqual(accepted.recv(5), b'owned')
        self.assert_closed(client)

    def test_saturated_backend_connect_keeps_absolute_deadline_without_sending(self):
        self.relay.io_timeout = 0.35
        client = self.client(); queued = self.fill_backend_accept_queue()
        entered = threading.Event(); captured = []; sent = []
        connect_ex = socket.socket.connect_ex; send = socket.socket.send
        def observed_connect(connection, address):
            captured.append(connection); entered.set()
            return connect_ex(connection, address)
        def observed_send(connection, data, *args, **kwargs):
            if connection in captured: sent.append(bytes(data))
            return send(connection, data, *args, **kwargs)
        with patch.object(socket.socket, 'connect_ex', observed_connect), \
             patch.object(socket.socket, 'send', observed_send):
            started = time.monotonic(); client.sendall(HEADER)
            self.assertTrue(entered.wait(timeout=1)); self.wait_workers(0, timeout=0.8)
            elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 0.3); self.assertLess(elapsed, 0.9)
        self.assertEqual(sent, []); self.assertEqual([item.fileno() for item in captured], [-1])
        self.assertFalse(self.relay.connections); self.assert_closed(client)
        for _ in range(queued): self.upstream().close()
        self.no_upstream(); self.exchange()

    def test_successful_backend_connect_is_tracked_nonblocking_and_checks_socket_error(self):
        observations = []; errors = []
        connect_ex = socket.socket.connect_ex; getsockopt = socket.socket.getsockopt
        def observed_connect(connection, address):
            with self.relay.lock: tracked = connection in self.relay.connections
            observations.append((connection, address, tracked, connection.getblocking()))
            return connect_ex(connection, address)
        def observed_error(connection, level, option, *args):
            result = getsockopt(connection, level, option, *args)
            if level == socket.SOL_SOCKET and option == socket.SO_ERROR:
                errors.append((connection, result))
            return result
        with patch.object(socket.socket, 'connect_ex', observed_connect), \
             patch.object(socket.socket, 'getsockopt', observed_error):
            self.exchange()
        self.assertEqual(len(observations), 1)
        connection, address, tracked, blocking = observations[0]
        self.assertEqual(address, self.backend.getsockname()); self.assertTrue(tracked); self.assertFalse(blocking)
        self.assertEqual(errors, [(connection, 0)])

    def test_real_refused_backend_connect_releases_both_pools(self):
        results = []; errors = []
        connect_ex = socket.socket.connect_ex; getsockopt = socket.socket.getsockopt
        def observed_connect(connection, address):
            result = connect_ex(connection, address); results.append(result); return result
        def observed_error(connection, level, option, *args):
            result = getsockopt(connection, level, option, *args)
            if level == socket.SOL_SOCKET and option == socket.SO_ERROR: errors.append(result)
            return result
        # Darwin silently drops SYNs to a merely bound TCPS_CLOSED socket.
        # An established socket keeps the non-reusable port owned after its
        # listener closes, but cannot match the new connection's four-tuple.
        with tls.owned_listener() as listener:
            with socket.create_connection(listener.getsockname(), timeout=2) as owner:
                refusing, _ = listener.accept()
                with refusing:
                    listener.close()
                    with socket.socket() as contender:
                        with self.assertRaises(OSError): contender.bind(refusing.getsockname())
                    with patch.object(self.relay, 'backend', refusing), \
                         patch.object(socket.socket, 'connect_ex', observed_connect), \
                         patch.object(socket.socket, 'getsockopt', observed_error):
                        client = self.client(); client.sendall(HEADER)
                        self.assert_closed(client); self.wait_workers(0)
                    owner.sendall(b'owned'); refusing.settimeout(2)
                    self.assertEqual(refusing.recv(5), b'owned')
        self.assertIn(errno.ECONNREFUSED, results + errors)
        self.assertFalse(self.relay.connections); self.no_upstream(); self.exchange()

    def test_stop_racing_backend_connect_does_not_leave_untracked_socket(self):
        entered = threading.Event(); release = threading.Event()
        connect = socket.socket.connect_ex
        tracked = []; sockets = []
        def paused(connection, address):
            with self.relay.lock: tracked.append(connection in self.relay.connections)
            sockets.append(connection)
            result = connect(connection, address)
            entered.set(); release.wait(timeout=2)
            return result
        client = self.client()
        with patch.object(socket.socket, 'connect_ex', paused):
            client.sendall(HEADER); self.assertTrue(entered.wait(timeout=1))
            upstream = self.upstream()
            closer = threading.Thread(target=self.relay.close); closer.start()
            self.assertTrue(self.relay.stopping.wait(timeout=1))
            release.set(); closer.join(timeout=3); self.assertFalse(closer.is_alive())
        self.assertTrue(self.relay.closed); self.assertFalse(self.relay.workers)
        self.assertFalse(self.relay.connections); self.assertEqual(upstream.recv(1), b'')
        self.assert_closed(client)
        self.assertEqual(tracked, [True]); self.assertEqual([item.fileno() for item in sockets], [-1])

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
