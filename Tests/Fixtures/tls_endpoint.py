"""Model-free native URLSession fixture. Uses the production TLS relay only."""
import importlib.util
import json
from pathlib import Path
import select
import socket
import sys
import threading
import time

path = Path(__file__).resolve().parents[2] / 'Resources/Runtime/dot_tls.py'
spec = importlib.util.spec_from_file_location('_dot_tls_fixture', path)
tls = importlib.util.module_from_spec(spec); spec.loader.exec_module(tls)
state = Path(sys.argv[1]); backend = tls.owned_listener(); backend.settimeout(0.1)
relay = tls.TLSRelay(backend, state)
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
