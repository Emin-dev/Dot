"""Probe exact Splash file/owned-port boundaries with stdlib temporary fixtures.
No neural imports, personal-data reads, external requests or app execution.
"""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

if sys.platform != 'darwin':
    print('SKIP: macOS sandbox test requires macOS')
    raise SystemExit(77)

profile = Path(__file__).resolve().parents[1] / 'Resources/Runtime/splash.sb'
with tempfile.TemporaryDirectory(prefix='dot-splash-policy-') as temporary:
    base = Path(temporary).resolve()
    runtime, models, scripts, private, outside = [base / name for name in ('runtime', 'models', 'scripts', 'private, ü "directory', 'Documents')]
    for folder in (runtime, models, scripts, private, outside): folder.mkdir(mode=0o700)
    (runtime / 'runtime.fixture').write_bytes(b'runtime')
    (models / 'model.fixture').write_bytes(b'model')
    secret = outside / 'private.fixture'; secret.write_bytes(b'private-fixture')
    (models / 'escape').symlink_to(secret); (private / 'escape').symlink_to(secret)
    manifest = base / 'manifest.json'; manifest.write_text('{}')
    helper = scripts / 'probe.py'
    helper.write_text('''import errno, mmap, os, pathlib, socket, subprocess, sys
runtime, models, private, outside, manifest = map(pathlib.Path, sys.argv[1:6])
backend_fd,tls_fd,other_port = map(int,sys.argv[6:9])
def denied(operation):
    try: operation()
    except OSError as error:
        assert error.errno in (errno.EPERM,errno.EACCES),repr(error)
        return
    raise AssertionError('sandbox allowed forbidden operation')
assert (runtime/'runtime.fixture').read_bytes()==b'runtime'
assert manifest.read_text()=='{}'
with (models/'model.fixture').open('rb') as stream:
    with mmap.mmap(stream.fileno(),0,access=mmap.ACCESS_READ) as mapped: assert mapped[:]==b'model'
owned=private/'owned'
with owned.open('x+b') as stream:
    stream.truncate(1024)
    with mmap.mmap(stream.fileno(),1024) as mapped: mapped[:4]=b'dot!'
owned.unlink()
for path in (outside/'private.fixture',models/'escape',private/'escape',models/'../Documents/private.fixture'):
    denied(path.read_bytes)
def directory(path):
    with os.scandir(path): pass
denied(lambda: directory(outside));denied(lambda: directory('/private/tmp'))
for path in (outside/'owned-probe',models/'owned-probe',runtime/'owned-probe',manifest,private/'escape'):
    denied(lambda:path.write_bytes(b'forbidden'))
openssl=subprocess.run(['/usr/bin/openssl','version'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
assert openssl.returncode==0,openssl.stderr.decode(errors='replace')[:1000]
with socket.socket(fileno=backend_fd) as backend, socket.socket(fileno=tls_fd) as tls:
    backend.settimeout(3);tls.settimeout(3)
    with socket.create_connection(backend.getsockname(),timeout=3) as client:
        accepted,_=backend.accept()
        with accepted:
            client.sendall(b'backend');assert accepted.recv(7)==b'backend'
            accepted.sendall(b'reply');assert client.recv(5)==b'reply'
    connection,_=tls.accept()
    with connection:
        connection.settimeout(3); assert connection.recv(3)==b'tls'
        connection.sendall(b'reply')
    def connect(address):
        with socket.create_connection(address,timeout=2): pass
    denied(lambda:connect(('127.0.0.1',other_port)))
    denied(lambda:connect(tls.getsockname()))
    denied(lambda:connect(('192.0.2.1',9)))
    def bind(address):
        with socket.socket() as sock: sock.bind(address)
    denied(lambda:bind(('127.0.0.1',0)));denied(lambda:bind(('0.0.0.0',0)))
    def udp(address):
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:sock.sendto(b'fixture',address)
    denied(lambda:udp(('192.0.2.1',9)));denied(lambda:udp(backend.getsockname()))
    def ipv6():
        with socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as sock:
            sock.settimeout(2);sock.connect(('::1',backend.getsockname()[1]))
    denied(ipv6)
''')
    with socket.socket() as backend, socket.socket() as tls, socket.socket() as other, socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as other_ipv6:
        for listener in (backend, tls, other):
            listener.bind(('127.0.0.1',0)); listener.listen(2)
        other_ipv6.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        other_ipv6.bind(('::1',backend.getsockname()[1]));other_ipv6.listen(1)
        values = {'DOT_RUNTIME': runtime, 'DOT_MODELS': models, 'DOT_RUNTIME_SCRIPTS': scripts,
                  'DOT_STATE': private, 'DOT_MANIFEST': manifest, 'DOT_PYTHON_ROOT': Path(sys.base_prefix).resolve(),
                  'DOT_BACKEND_ADDRESS': 'localhost:' + str(backend.getsockname()[1]),
                  'DOT_TLS_ADDRESS': 'localhost:' + str(tls.getsockname()[1])}
        command = ['/usr/bin/sandbox-exec']
        for name,value in values.items(): command.extend(['-D',name+'='+str(value)])
        command.extend(['-f',str(profile),str(Path(sys._base_executable).resolve()),'-I','-B',str(helper),
                        str(runtime),str(models),str(private),str(outside),str(manifest),
                        str(backend.fileno()),str(tls.fileno()),str(other.getsockname()[1])])
        replies, failures = [], []
        def call_owned_listener():
            try:
                with socket.create_connection(tls.getsockname(),timeout=5) as client:
                    client.settimeout(5);client.sendall(b'tls');replies.append(client.recv(5))
            except OSError as error: failures.append(type(error).__name__)
        caller=threading.Thread(target=call_owned_listener);caller.start()
        try:
            result = subprocess.run(command,cwd=private,pass_fds=(backend.fileno(),tls.fileno()),
                env={'PATH':'/usr/bin:/bin','HOME':str(private),'TMPDIR':str(private),'LANG':'en_US.UTF-8'},
                capture_output=True,timeout=15,check=False)
        finally: caller.join(timeout=6)
        assert result.returncode == 0, 'Splash sandbox probe failed: ' + result.stderr.decode(errors='replace')[:2000]
        assert replies == [b'reply'] and not failures and not caller.is_alive(), 'Owned TLS-port reply failed'
    assert secret.read_bytes() == b'private-fixture' and manifest.read_text() == '{}'
    assert all(not (folder/'owned-probe').exists() for folder in (outside,runtime,models))
print('PASS: Splash runtime/model read/mmap, private writes and owned listener traffic; denied personal-fixture reads, symlink escapes, outside writes, other ports and external networking')
