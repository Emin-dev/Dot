"""Bounded per-launch TLS relay to a continuously owned inherited Splash listener.
No remote networking, persistent key, system trust changes or backend discovery.
"""
import errno
import hashlib
import hmac
import http.client
import io
import os
from pathlib import Path
import re
import select
import socket
import ssl
import subprocess
import sys
import threading
import time


def owned_listener():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 0)
        listener.bind(('127.0.0.1', 0)); listener.listen(16)
        return listener
    except BaseException:
        listener.close(); raise


def adopt_listener(descriptor, port):
    """Adopt an exact prebound loopback listener, without binding or listening again."""
    if type(descriptor) is not int or descriptor < 3 or type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('invalid_owned_listener')
    listener = socket.socket(fileno=descriptor)
    try:
        # Darwin does not implement SO_ACCEPTCONN; inspect TCP state without mutation.
        tcp_conn_info = getattr(socket, 'TCP_CONNECTION_INFO', 0x106)
        listening = (listener.getsockopt(socket.IPPROTO_TCP, tcp_conn_info, 1) == b'\x01'
                     if sys.platform == 'darwin' else listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) == 1)
        if (listener.family != socket.AF_INET or listener.type != socket.SOCK_STREAM
            or listener.getsockname() != ('127.0.0.1', port)
            or listener.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR) != 0
            or listener.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT) != 0 or not listening):
            raise ValueError('unowned_listener')
        os.set_inheritable(descriptor, False)
        return listener
    except BaseException:
        listener.detach()  # Never close an unvalidated caller descriptor.
        raise


def identity(state):
    # Recognized OS utility only. A missing/incompatible utility fails closed.
    executable = Path('/usr/bin/openssl')
    if not executable.is_file(): raise RuntimeError('system certificate generator unavailable')
    key, certificate = state / 'session.key', state / 'session.crt'
    config = state / 'session.cnf'
    config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=dot.local\n[extensions]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n')
    config.chmod(0o600)
    subprocess.run([str(executable), 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                    '-pkeyopt', 'ec_param_enc:named_curve',
                    '-nodes', '-keyout', str(key), '-out', str(certificate), '-days', '1', '-config', str(config)],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    key.chmod(0o600); certificate.chmod(0o600)
    der = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certificate, key)
    # OpenSSL and the Python TLS context have read the private material. Do not retain it on disk.
    key.unlink(); certificate.unlink(); config.unlink()
    return context, hashlib.sha256(der).hexdigest()


class TLSRelay:
    # Pending clients share no long-lived forwarding slots or backend connections.
    # A larger local flood can still saturate this finite admission pool/backlog.
    pending_limit = 8
    forwarding_limit = 4
    admission_timeout = 2
    admission_poll_interval = 0.1
    header_limit = 16384
    io_timeout = 2
    io_poll_interval = 0.1
    connection_lifetime = 180
    _field_name = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+")

    def __init__(self, backend, state, *, api_key, listener=None):
        if not isinstance(api_key, str) or not re.fullmatch(r'[A-Za-z0-9._~+/-]{1,256}={0,2}', api_key):
            raise ValueError('invalid_relay_credential')
        self._authorization = ('Bearer ' + api_key).encode('ascii')
        self.backend = backend  # Kept open by the caller until close() has joined every worker.
        self.context, self.certificate_sha256 = identity(state)
        self.listener = listener if listener is not None else owned_listener()
        self.listener.settimeout(0.2)
        self.port = self.listener.getsockname()[1]
        self.closed = False
        self.stopping = threading.Event(); self.lock = threading.Lock()
        self.workers = set(); self.connections = set()
        self.capacity = threading.BoundedSemaphore(self.forwarding_limit)
        self.pending_capacity = threading.BoundedSemaphore(self.pending_limit)
        self.thread = threading.Thread(target=self._accept, name='dot-tls-accept')
        self.thread.start()
    def _accept(self):
        while not self.stopping.is_set():
            try: connection, _ = self.listener.accept()
            except socket.timeout: continue
            except OSError: break
            if not self.pending_capacity.acquire(blocking=False): connection.close(); continue
            deadline = time.monotonic() + self.admission_timeout
            worker = threading.Thread(target=self._forward, args=(connection, deadline), name='dot-tls-forward')
            with self.lock: self.workers.add(worker); self.connections.add(connection)
            try: worker.start()
            except RuntimeError:
                with self.lock: self.workers.discard(worker); self.connections.discard(connection)
                connection.close(); self.pending_capacity.release()

    def _track(self, connection, previous=None):
        # Stop may race TLS wrapping or backend connect; no newly returned socket
        # may escape the close() snapshot or retain ownership after Stop.
        with self.lock:
            self.connections.discard(previous)
            if self.stopping.is_set():
                connection.close(); return False
            self.connections.add(connection)
        return True

    def _handshake(self, secure, deadline):
        # Cross-thread shutdown/close need not wake a TLS read on every OS.
        # Check Stop between short waits without resetting the admission budget.
        while not self.stopping.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0: return False
            secure.settimeout(min(self.admission_poll_interval, remaining))
            try:
                secure.do_handshake()
                return time.monotonic() < deadline
            except socket.timeout: continue
        return False

    def _admit(self, secure, deadline):
        buffered = bytearray()
        while not self.stopping.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0: return None
            secure.settimeout(min(self.admission_poll_interval, remaining))
            try: data = secure.recv(min(4096, self.header_limit - len(buffered)))
            except socket.timeout: continue
            if not data: return None
            buffered.extend(data)
            end = buffered.find(b'\r\n\r\n')
            if end >= 0:
                # Parse only a complete bounded HTTP/1 header block. Reject
                # ambiguous/folded authorization and malformed field syntax.
                lines = bytes(buffered[:end]).split(b'\r\n')
                request = lines[0].split(b' ')
                if (len(request) != 3 or not self._field_name.fullmatch(request[0])
                    or not request[1] or any(byte <= 32 or byte == 127 for byte in request[1])
                    or request[2] not in (b'HTTP/1.0', b'HTTP/1.1')): return None
                for line in lines[1:]:
                    name, colon, value = line.partition(b':')
                    if (not colon or not self._field_name.fullmatch(name)
                        or any(byte < 32 and byte != 9 or byte == 127 for byte in value)): return None
                headers = http.client.parse_headers(io.BytesIO(b'\r\n'.join(lines[1:]) + b'\r\n\r\n'))
                values = headers.get_all('Authorization', [])
                if (len(values) != 1 or not hmac.compare_digest(
                    values[0].strip(' \t').encode('latin-1'), self._authorization)): return None
                if time.monotonic() >= deadline: return None
                return buffered  # Preserve headers and any already-read body exactly.
            if len(buffered) >= self.header_limit: return None
        return None

    def _connect(self, connection):
        # The caller tracks this nonblocking socket before connect can begin.
        # A full backend accept queue must not hide an uncancellable socket.
        deadline = time.monotonic() + self.io_timeout
        if self.stopping.is_set(): return False
        result = connection.connect_ex(self.backend.getsockname())
        if result in (0, errno.EISCONN):
            return (not self.stopping.is_set() and time.monotonic() < deadline
                    and connection.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0)
        if result not in (errno.EINPROGRESS, errno.EALREADY, errno.EWOULDBLOCK, errno.EINTR): return False
        while not self.stopping.is_set():
            remaining = deadline - time.monotonic()
            if remaining <= 0: return False
            _, writable, exceptional = select.select([], [connection], [connection],
                                                      min(self.io_poll_interval, remaining))
            if self.stopping.is_set() or time.monotonic() >= deadline: return False
            if writable or exceptional:
                return connection.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0
        return False

    def _wait_io(self, connection, *, writable, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or self.stopping.is_set(): return False
        # Both TLS reads and writes may require either transport direction.
        select.select([] if writable else [connection], [connection] if writable else [], [],
                      min(self.io_poll_interval, remaining))
        return not self.stopping.is_set() and time.monotonic() < deadline

    def _receive(self, connection):
        # TCP readability may be only part of a TLS record. Keep the original
        # total I/O budget while checking Stop between bounded readiness waits.
        deadline = time.monotonic() + self.io_timeout
        while not self.stopping.is_set() and time.monotonic() < deadline:
            try: return connection.recv(32768)
            except ssl.SSLWantWriteError: writable = True
            except (ssl.SSLWantReadError, BlockingIOError): writable = False
            if not self._wait_io(connection, writable=writable, deadline=deadline): return b''
        return b''

    def _sendall(self, connection, data):
        # An SSL WANT retry must retain identical data and length, since some
        # bytes may already be processed. Advance only by a returned count.
        pending = memoryview(data)
        deadline = time.monotonic() + self.io_timeout
        while pending and not self.stopping.is_set() and time.monotonic() < deadline:
            try: sent = connection.send(pending)
            except ssl.SSLWantReadError: writable = False
            except (ssl.SSLWantWriteError, BlockingIOError): writable = True
            else:
                if sent <= 0: return False
                pending = pending[sent:]
                continue
            if not self._wait_io(connection, writable=writable, deadline=deadline): return False
        return not pending

    def _forward(self, raw, admission_deadline):
        secure = upstream = None
        pending = True; admitted = False
        try:
            raw.settimeout(max(0.001, admission_deadline - time.monotonic()))
            secure = self.context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
            if not self._track(secure, previous=raw): return
            if not self._handshake(secure, admission_deadline): return
            initial = self._admit(secure, admission_deadline)
            if initial is None or self.stopping.is_set(): return
            if not self.capacity.acquire(blocking=False): return
            admitted = True
            self.pending_capacity.release(); pending = False
            if self.stopping.is_set(): return
            secure.setblocking(False)
            upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if not self._track(upstream): return
            upstream.setblocking(False)
            if not self._connect(upstream): return
            if not self._sendall(upstream, initial): return
            deadline = time.monotonic() + self.connection_lifetime
            while not self.stopping.is_set() and time.monotonic() < deadline:
                readable, _, _ = select.select([secure, upstream], [], [], 0.2)
                if self.stopping.is_set(): return
                if secure.pending() and secure not in readable: readable.append(secure)
                for source in readable:
                    if self.stopping.is_set(): return
                    data = self._receive(source)
                    if not data or self.stopping.is_set(): return
                    if not self._sendall(upstream if source is secure else secure, data): return
        except (OSError, ssl.SSLError, ValueError, http.client.HTTPException): pass
        finally:
            for connection in (raw, secure, upstream):
                if connection is not None:
                    with self.lock: self.connections.discard(connection)
                    connection.close()
            with self.lock: self.workers.discard(threading.current_thread())
            if pending: self.pending_capacity.release()
            if admitted: self.capacity.release()
    def close(self):
        self.stopping.set(); self.listener.close(); self.thread.join(timeout=3)
        # No acceptor can add workers after it has stopped.
        if self.thread.is_alive(): raise RuntimeError('TLS acceptor failed to stop')
        with self.lock: connections = list(self.connections); workers = list(self.workers)
        for connection in connections:
            try: connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            connection.close()
        for worker in workers: worker.join(timeout=3)
        if any(worker.is_alive() for worker in workers): raise RuntimeError('TLS worker failed to stop')
        self.closed = True
