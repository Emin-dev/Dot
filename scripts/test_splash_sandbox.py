"""Probe the exact bundled Splash sandbox using only standard-library local sockets."""
from pathlib import Path
import subprocess
import sys

if sys.platform != 'darwin':
    print('SKIP: macOS sandbox test requires macOS')
    raise SystemExit(77)
profile = Path(__file__).resolve().parents[1] / 'Resources/Runtime/splash.sb'
probe = '''import errno, socket
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0)); listener.listen(1)
    with socket.create_connection(listener.getsockname(), timeout=2) as client:
        accepted, _ = listener.accept(); accepted.close()
try:
    # Reserved documentation address; sandbox must reject before an actual connection.
    socket.create_connection(('192.0.2.1', 9), timeout=2)
except OSError as error:
    assert error.errno in (errno.EPERM, errno.EACCES), 'Expected OS sandbox denial'
else:
    raise AssertionError('External network was allowed')
'''
result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), sys.executable, '-I', '-c', probe],
                        capture_output=True, timeout=10, check=False)
if result.returncode != 0:
    raise AssertionError('Splash loopback-only sandbox probe failed: ' + result.stderr.decode(errors='replace')[:2000])
print('PASS: exact Splash sandbox permits loopback and denies external networking')
