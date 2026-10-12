"""Probe the exact product voice profile with standard-library code only.
No package/model imports, downloads or microphone/audio use.
"""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('SKIP: macOS sandbox test requires macOS')
    raise SystemExit(77)
profile = Path(__file__).resolve().parents[1] / 'Resources/Voice/voice.sb'
with tempfile.TemporaryDirectory(prefix='dot-voice-policy-') as temporary, socket.socket() as listener:
    base = Path(temporary).resolve()
    private = base / 'private, ü "directory'; private.mkdir(mode=0o700)
    outside = base / 'outside'; outside.mkdir()
    listener.bind(('127.0.0.1', 0)); listener.listen(1)
    probe = '''import errno, mmap, os, pathlib, socket, sys
private, outside, port = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
def denied(operation):
    try: operation()
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), repr(error)
        return
    raise AssertionError('sandbox allowed forbidden operation')
def directory(path):
    with os.scandir(path): pass
for name in ('/tmp', '/private/tmp'): denied(lambda: directory(name))
directory(private)
file = private / 'owned'
with file.open('x+b') as stream:
    stream.truncate(1024)
    with mmap.mmap(stream.fileno(),1024) as mapped: mapped[0:4] = b'dot!'
file.unlink()
def outside_write():
    path = outside / 'owned-probe'
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
denied(outside_write)
assert not (outside / 'owned-probe').exists(), 'forbidden file was created'
def connect():
    with socket.create_connection(('127.0.0.1',port),timeout=2): pass
denied(connect)
'''
    result = subprocess.run(['/usr/bin/sandbox-exec', '-D', 'DOT_OUTPUT='+str(private), '-f', str(profile),
        sys.executable, '-I', '-B', '-c', probe, str(private), str(outside), str(listener.getsockname()[1])],
        env={'PATH':'/usr/bin:/bin','HOME':str(private),'TMPDIR':str(private),'LANG':'en_US.UTF-8'},
        timeout=10, check=False)
    assert result.returncode == 0, 'Product voice sandbox did not enforce its boundaries'
print('PASS: exact voice profile permits private mmap; denies global temp enumeration, outside writes and loopback')
