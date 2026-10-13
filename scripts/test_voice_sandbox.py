"""Probe the exact voice profile with temporary canaries and stdlib Python.
Compiles a tiny native dylib to test the private eSpeak-copy mapping exception.
No package/model imports, personal-data reads, downloads or audio use.
"""
from pathlib import Path
import shutil
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
    runtime = base / 'voice runtime'; runtime.mkdir()
    outside = base / 'Documents'; outside.mkdir()
    sibling = base / 'voice runtime-other'; sibling.mkdir()
    model = runtime / 'weights.fixture'; model.write_bytes(b'fixture-model')
    secret = outside / 'private.fixture'; secret.write_bytes(b'private-fixture')
    (sibling / 'private.fixture').write_bytes(b'private-fixture')
    (runtime / 'escape').symlink_to(secret)
    (private / 'escape').symlink_to(secret)
    # Model-free native fixture: eSpeak's dependency makes per-instance copies.
    # Only its precise private tempfile/name convention may be executable-mapped.
    native_source = base / 'fixture.c'; native_source.write_text('int dot_fixture(void) { return 17; }\n')
    native_library = base / 'fixture.dylib'
    subprocess.run(['/usr/bin/clang', '-dynamiclib', str(native_source), '-o', str(native_library)],
                   capture_output=True, check=True, timeout=30)
    copies = private / 'tmpfixture'; copies.mkdir()
    other = private / 'other'; other.mkdir()
    for destination in (copies / 'libespeak-ng.dylib', copies / 'other.dylib',
                        other / 'libespeak-ng.dylib', outside / 'libespeak-ng.dylib'):
        shutil.copyfile(native_library, destination)
    (copies / 'escape.dylib').symlink_to(outside / 'libespeak-ng.dylib')
    escaped_copy = private / 'tmpescape'; escaped_copy.mkdir()
    (escaped_copy / 'libespeak-ng.dylib').symlink_to(outside / 'libespeak-ng.dylib')
    listener.bind(('127.0.0.1', 0)); listener.listen(1)
    helper = base / 'probe.py'
    helper.write_text('''import ctypes, errno, mmap, os, pathlib, socket, sys
private, runtime, outside, sibling = map(pathlib.Path, sys.argv[1:5])
port = int(sys.argv[5])
def denied(operation):
    try: operation()
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), repr(error)
        return
    raise AssertionError('sandbox allowed forbidden operation')
def directory(path):
    with os.scandir(path): pass
for name in ('/tmp', '/private/tmp'): denied(lambda: directory(name))
directory(private); directory(runtime)
with (runtime / 'weights.fixture').open('rb') as stream:
    with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
        assert mapped[:] == b'fixture-model'
file = private / 'owned'
with file.open('x+b') as stream:
    stream.truncate(1024)
    with mmap.mmap(stream.fileno(),1024) as mapped: mapped[0:4] = b'dot!'
file.unlink()
library = ctypes.CDLL(str(private / 'tmpfixture/libespeak-ng.dylib'))
assert library.dot_fixture() == 17
for path in (private / 'tmpfixture/other.dylib', private / 'other/libespeak-ng.dylib',
             private / 'tmpfixture/escape.dylib', outside / 'libespeak-ng.dylib'):
    try: ctypes.CDLL(str(path))
    except OSError as error:
        assert 'sandbox' in str(error).lower() or 'not permitted' in str(error).lower(), str(error)
    else: raise AssertionError('sandbox allowed unrelated native-library mapping')
try: ctypes.CDLL(str(private / 'tmpescape/libespeak-ng.dylib'))
except OSError as error:
    assert 'sandbox' in str(error).lower() or 'not permitted' in str(error).lower(), str(error)
else: raise AssertionError('sandbox followed matching-name native-library symlink outside private root')
for path in (outside / 'private.fixture', sibling / 'private.fixture', runtime / 'escape',
             private / 'escape', runtime / '../Documents/private.fixture'):
    denied(path.read_bytes)
denied(lambda: directory(outside))
for path in (outside / 'owned-probe', runtime / 'owned-probe', private / 'escape'):
    denied(lambda: path.write_bytes(b'forbidden'))
def connect(address):
    with socket.create_connection(address,timeout=2): pass
denied(lambda: connect(('127.0.0.1',port)))
denied(lambda: connect(('192.0.2.1',9)))
def bind():
    with socket.socket() as sock: sock.bind(('127.0.0.1',0))
denied(bind)
def udp():
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock: sock.sendto(b'fixture',('192.0.2.1',9))
denied(udp)
''')
    values = {'DOT_OUTPUT': private, 'DOT_VOICE_ROOT': runtime, 'DOT_VOICE_HELPER': helper,
              'DOT_PYTHON_ROOT': Path(sys.base_prefix).resolve()}
    command = ['/usr/bin/sandbox-exec']
    for name, value in values.items(): command.extend(['-D', name + '=' + str(value)])
    command.extend(['-f', str(profile), str(Path(sys._base_executable).resolve()), '-I', '-B', str(helper),
                    str(private), str(runtime), str(outside), str(sibling), str(listener.getsockname()[1])])
    result = subprocess.run(command, cwd=private,
        env={'PATH':'/usr/bin:/bin','HOME':str(private),'TMPDIR':str(private),'LANG':'en_US.UTF-8'},
        capture_output=True, timeout=15, check=False)
    assert result.returncode == 0, 'Voice sandbox probe failed: ' + result.stderr.decode(errors='replace')[:2000]
    assert secret.read_bytes() == b'private-fixture'
    assert not (outside / 'owned-probe').exists() and not (runtime / 'owned-probe').exists()
print('PASS: voice runtime read/mmap, exact private eSpeak-copy mapping and private writes; denied unrelated executable mappings, personal-fixture reads, symlink escapes, outside writes and all tested networking')
