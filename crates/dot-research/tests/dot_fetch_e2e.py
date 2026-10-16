#!/usr/bin/env python3
"""End-to-end driver for the native `dot-fetch` source reader (test-only).

This file is a development fixture: it is never packaged (packaging copies
`Resources/Research`, not this directory) and the product path contains no Python.
It exercises the exact shipped artifact:

  1. a real public HTTPS origin, resolved by the OS, pinned to one numeric address
     and handed to the reader as an already-connected socket on stdin,
  2. the identical exchange under `/usr/bin/sandbox-exec` with the shipped
     `Resources/Research/source_fetch.sb` profile,
  3. refusals: a private pin, a peer that is not the pin and a descriptor that is not
     a stream socket all end with status 1 and zero request bytes.

Usage:
    crates/dot-research/tests/dot_fetch_e2e.py [--binary target/release/dot-fetch]
"""
import argparse
import json
import pathlib
import socket
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
PROFILE = ROOT / 'Resources/Research/source_fetch.sb'
MAX_BYTES = 4_194_304


def resolve_ipv4(host):
    result = subprocess.run(['/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', host],
                            capture_output=True, text=True, timeout=10)
    addresses = [line.split(':', 1)[1].strip() for line in result.stdout.splitlines()
                 if line.startswith('ip_address:')]
    if not addresses:
        raise SystemExit(f'no IPv4 answer for {host}')
    return addresses[0]


def run(binary, url, pin, seconds, prefix=(), stdin=None):
    """Spawn the reader with one inherited socket (or an explicit descriptor)."""
    if stdin is None:
        stdin = socket.create_connection((pin, 443), timeout=10)
        owned = True
    else:
        owned = False
    try:
        return subprocess.run([*prefix, str(binary), url, pin, str(seconds)],
                              stdin=stdin, capture_output=True, timeout=45, close_fds=True)
    finally:
        if owned:
            stdin.close()


def loopback_listener():
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(2)
    listener.settimeout(2)
    return listener


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT / 'target/release/dot-fetch'))
    parser.add_argument('--url', default='https://example.com/')
    parser.add_argument('--seconds', type=float, default=20)
    options = parser.parse_args()

    binary = pathlib.Path(options.binary).resolve()
    if not binary.is_file():
        raise SystemExit(f'build the reader first: {binary}')
    host = options.url.split('/')[2]
    address = resolve_ipv4(host)
    print(f'origin {options.url} pinned to {address}')

    plain = run(binary, options.url, address, options.seconds)
    assert plain.returncode == 0, (plain.returncode, plain.stderr[:400])
    assert 0 < len(plain.stdout) <= MAX_BYTES
    assert not plain.stdout.startswith(b'\x1f\x8b'), 'compressed bytes reached stdout'
    assert b'<html' in plain.stdout.lower(), plain.stdout[:200]
    head = json.loads(plain.stderr.decode('utf-8'))
    assert head['status'] == 200, head
    assert head['headers'].get('content-encoding') == 'gzip', head
    print(f'PASS direct: status {head["status"]}, {len(plain.stdout)} decoded bytes, '
          f'headers {sorted(head["headers"])}')

    sandboxed = run(binary, options.url, address, options.seconds,
                    prefix=['/usr/bin/sandbox-exec', '-f', str(PROFILE),
                            '-D', 'DOT_SOURCE_HELPER=' + str(binary)])
    assert sandboxed.returncode == 0, (sandboxed.returncode, sandboxed.stderr[:400])
    assert sandboxed.stdout == plain.stdout, 'sandboxed body differs'
    assert sandboxed.stderr == plain.stderr, 'sandboxed metadata differs'
    print(f'PASS sandboxed: identical body and metadata under {PROFILE.name}')

    # A private pin is refused before the inherited descriptor is adopted.
    listener = loopback_listener()
    try:
        port = listener.getsockname()[1]
        client = socket.create_connection(('127.0.0.1', port), timeout=5)
        try:
            private = run(binary, f'https://fixture.invalid:{port}/private', '127.0.0.1', 1,
                          stdin=client)
        finally:
            client.close()
        assert (private.returncode, private.stdout, private.stderr) == (1, b'', b''), private
        listener.settimeout(0.3)
        try:
            server, _ = listener.accept()
        except socket.timeout:
            server = None
        if server is not None:
            try:
                assert server.recv(1) == b'', 'private pin sent request bytes'
            finally:
                server.close()
    finally:
        listener.close()

    # A connected peer that is not the pin is refused before any request byte.
    listener = loopback_listener()
    try:
        port = listener.getsockname()[1]
        client = socket.create_connection(('127.0.0.1', port), timeout=5)
        try:
            mismatched = run(binary, f'https://fixture.invalid:{port}/private', '1.1.1.1', 1,
                             stdin=client)
        finally:
            client.close()
        assert (mismatched.returncode, mismatched.stdout, mismatched.stderr) == (1, b'', b''), mismatched
        server, _ = listener.accept()
        try:
            server.settimeout(0.5)
            assert server.recv(1) == b'', 'mismatched peer received request bytes'
        finally:
            server.close()
    finally:
        listener.close()
    print('PASS refusals: private pin and mismatched peer send zero request bytes')

    # A descriptor that is not a stream socket never becomes a request.
    pipe = subprocess.run([str(binary), options.url, address, str(options.seconds)],
                          input=b'', capture_output=True, timeout=10)
    assert (pipe.returncode, pipe.stdout, pipe.stderr) == (1, b'', b''), pipe
    for refused in ['http://example.org/', f'https://user:pass@{host}/', f'https://127.0.0.1/']:
        result = subprocess.run([str(binary), refused, address, '1'],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        assert (result.returncode, result.stdout, result.stderr) == (1, b'', b''), refused
    print('PASS refusals: non-socket stdin and http, credential and literal URLs')

    print('PASS: native reader verified end to end')


if __name__ == '__main__':
    sys.exit(main())
