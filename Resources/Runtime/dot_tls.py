"""Bounded per-launch TLS relay to a continuously owned inherited Splash listener.
No remote networking, persistent key, system trust changes or backend discovery.
"""
import hashlib
from pathlib import Path
import select
import socket
import ssl
import subprocess
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


def identity(state):
    # Recognized OS utility only. A missing/incompatible utility fails closed.
    executable = Path('/usr/bin/openssl')
    if not executable.is_file(): raise RuntimeError('system certificate generator unavailable')
    key, certificate = state / 'session.key', state / 'session.crt'
    config = state / 'session.cnf'
    config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=dot.local\n[extensions]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n')
    config.chmod(0o600)
    subprocess.run([str(executable), 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
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
    def __init__(self, backend, state):
        self.backend = backend  # Kept open by the caller until close() has joined every worker.
        self.context, self.certificate_sha256 = identity(state)
        self.listener = owned_listener(); self.listener.settimeout(0.2)
        self.port = self.listener.getsockname()[1]
        self.closed = False
        self.stopping = threading.Event(); self.lock = threading.Lock()
        self.workers = set(); self.connections = set(); self.capacity = threading.BoundedSemaphore(4)
        self.thread = threading.Thread(target=self._accept, name='dot-tls-accept')
        self.thread.start()
    def _accept(self):
        while not self.stopping.is_set():
            try: connection, _ = self.listener.accept()
            except socket.timeout: continue
            except OSError: break
            if not self.capacity.acquire(blocking=False): connection.close(); continue
            worker = threading.Thread(target=self._forward, args=(connection,), name='dot-tls-forward')
            with self.lock: self.workers.add(worker); self.connections.add(connection)
            worker.start()
    def _forward(self, raw):
        secure = upstream = None
        try:
            raw.settimeout(2)
            secure = self.context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
            with self.lock: self.connections.discard(raw); self.connections.add(secure)
            secure.do_handshake()
            if self.stopping.is_set(): return
            upstream = socket.create_connection(self.backend.getsockname(), timeout=2)
            with self.lock: self.connections.add(upstream)
            deadline = time.monotonic() + 180
            while not self.stopping.is_set() and time.monotonic() < deadline:
                readable, _, _ = select.select([secure, upstream], [], [], 0.2)
                if secure.pending() and secure not in readable: readable.append(secure)
                for source in readable:
                    data = source.recv(32768)
                    if not data: return
                    (upstream if source is secure else secure).sendall(data)
        except (OSError, ssl.SSLError, ValueError): pass
        finally:
            for connection in (raw, secure, upstream):
                if connection is not None:
                    with self.lock: self.connections.discard(connection)
                    connection.close()
            with self.lock: self.workers.discard(threading.current_thread())
            self.capacity.release()
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
