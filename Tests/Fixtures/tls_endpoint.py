"""Model-free native URLSession fixture. Uses the production TLS relay only."""
import importlib.util
import json
from pathlib import Path
import select
import socket
import ssl
import sys
import threading
import time

path = Path(__file__).resolve().parents[2] / 'Resources/Runtime/dot_tls.py'
spec = importlib.util.spec_from_file_location('_dot_tls_fixture', path)
tls = importlib.util.module_from_spec(spec); spec.loader.exec_module(tls)
if sys.version_info < (3, 11) or not ssl.OPENSSL_VERSION.startswith('OpenSSL ') or ssl.OPENSSL_VERSION_INFO < (1, 1, 1):
    raise RuntimeError('Native TLS fixture requires an explicitly selected Python3.11+ / supported OpenSSL interpreter')
state = Path(sys.argv[1]); backend = tls.owned_listener(); backend.settimeout(0.1)
relay = tls.TLSRelay(backend, state, api_key="model-free-test")
# Test-only diagnostics. Never log a request, bearer, private key or user content.
(state / 'tls-debug.json').write_text(json.dumps({'python': sys.version[:512], 'executable': sys.executable[:1024], 'ssl': ssl.OPENSSL_VERSION[:256],
    'minimum_version': str(relay.context.minimum_version), 'maximum_version': str(relay.context.maximum_version), 'ciphers': [x['name'] for x in relay.context.get_ciphers()[:64]]}))
original_wrap = relay.context.wrap_socket
error_lock = threading.Lock()
def observed_wrap(*args, **kwargs):
    connection = original_wrap(*args, **kwargs)
    original_handshake = connection.do_handshake
    def observed_handshake(*handshake_args, **handshake_kwargs):
        try: return original_handshake(*handshake_args, **handshake_kwargs)
        except ssl.SSLError as error:
            with error_lock:
                path = state / 'tls-errors.txt'
                previous = path.read_text() if path.exists() else ''
                if len(previous) < 4096: path.write_text(previous + json.dumps({'library': error.library, 'reason': error.reason, 'message': str(error)[:512]})[:1024] + '\n')
            raise
    connection.do_handshake = observed_handshake
    return connection
relay.context.wrap_socket = observed_wrap
stop = threading.Event()
(state / 'received').write_text('0')
def receive():
    count = 0
    while not stop.is_set():
        try: connection, _ = backend.accept()
        except socket.timeout: continue
        with connection:
            connection.settimeout(2)
            try: data = connection.recv(4096)
            except OSError: continue
            count += len(data)
            (state / 'received').write_text(str(count))
            if data:
                connection.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK')
worker = threading.Thread(target=receive); worker.start()
try:
    (state / 'ready.tmp').write_text(json.dumps({'port': relay.port, 'pin': relay.certificate_sha256}))
    (state / 'ready.tmp').rename(state / 'ready.json')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        ready, _, _ = select.select([sys.stdin], [], [], 0.1)
        if ready: break
finally:
    relay.close(); stop.set(); worker.join(timeout=3); backend.close()
