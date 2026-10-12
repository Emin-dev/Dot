"""Verify the exact helper sandbox profile denies even loopback sockets.
Runs only an inline standard-library probe, never Kokoro, assets or downloads.
"""
import socket
import subprocess
import sys

if sys.platform != 'darwin':
    print('SKIP: macOS sandbox test requires macOS')
    raise SystemExit(77)
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0)); listener.listen(1)
    port = listener.getsockname()[1]
    probe = '''import errno, socket, sys
try:
    socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=2)
except OSError as error:
    sys.exit(0 if error.errno in (errno.EPERM, errno.EACCES) else 2)
sys.exit(1)
'''
    result = subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)',
                             sys.executable, '-I', '-c', probe, str(port)], timeout=10, check=False)
    assert result.returncode == 0, 'No-network OS sandbox did not reject the local socket'
print('PASS: helper OS sandbox denied loopback socket access')
