#!/usr/bin/env python3
"""Produce a narrowly patched Splash1.3.1 source overlay. Does not execute upstream code."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

REVISION = 'f91c91e21dda483f8c59a248a444d0989a560d31'
PATCH_ID = 'dot-splash-owned-listener-secret-pipe-v2'
PINNED = {
    'install/launcher.py': '9f107bf8b80b9edae9489b4c569f167ea73a5d91daca74c0c68ab13430fce93e',
    'server/serve_options.py': '4777020405c895f0c17d8d27864ecc6d5124853214fa99ed7241d636b1c7bf15',
    'server/server.py': 'e8d45d7f30c13ad4e1ee049da481ad3125b33e8bf831c0ce83a4984636abbe81',
}
HELPER = '''
# Dot modification: inherited listener validation; upstream license remains Apache-2.0.
def dot_owned_listener(fd, host, port):
    if type(fd) is not int or fd < 3 or host != "127.0.0.1" or not 1 <= port <= 65535:
        raise ValueError("invalid managed listener")
    listener = socket.socket(fileno=fd)
    try:
        # Darwin does not implement SO_ACCEPTCONN; tcpi_state is its read-only listener state.
        listening = (listener.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONNECTION_INFO, 1) == b"\\x01"
                     if sys.platform == "darwin" else listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) == 1)
        if (listener.family != socket.AF_INET or listener.type != socket.SOCK_STREAM
            or listener.getsockname() != (host, port)
            or listener.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR) != 0
            or listener.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT) != 0
            or not listening):
            raise ValueError("unowned managed listener")
        return listener
    except BaseException:
        listener.detach()
        raise

'''

SECRET_HELPER = '''
# Dot modification: one-shot private credential pipe; never env/argv/file bytes.
def dot_prepare_api_key_fd(fd):
    if type(fd) is not int or fd < 3:
        raise ValueError("invalid managed credential descriptor")
    try:
        os.set_inheritable(fd, False)
        if (not stat.S_ISFIFO(os.fstat(fd).st_mode)
            or fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY):
            raise ValueError("invalid managed credential descriptor")
        return fd
    except BaseException:
        os.close(fd)
        raise


def dot_take_api_key(argv):
    """Consume before heavyweight imports. Exact lowercase hex + EOF, 2s total.

    Only a descriptor number is present in argv. The producer creates an
    anonymous pipe, preloads 64 bytes and closes its only writer before spawn.
    Mutable transfer storage is wiped; the server's in-memory key must remain.
    """
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--api-key-fd", action="append")
    parser.add_argument("--listen-fd", action="append")
    parsed, _ = parser.parse_known_args(argv)
    if parsed.api_key_fd is None and parsed.listen_fd is None:
        return None
    if (parsed.api_key_fd is None or len(parsed.api_key_fd) != 1
        or parsed.listen_fd is None or len(parsed.listen_fd) != 1):
        raise ValueError("managed listener and credential are required together")
    value = parsed.api_key_fd[0]
    if (not value.isascii() or not value.isdigit() or len(value) > 10):
        raise ValueError("invalid managed credential descriptor")
    fd = dot_prepare_api_key_fd(int(value))
    transfer = None
    try:
        transfer = bytearray(65)
        count = 0
        deadline = time.monotonic() + 2.0
        os.set_blocking(fd, False)
        with selectors.DefaultSelector() as ready:
            ready.register(fd, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not ready.select(remaining):
                    raise ValueError("managed credential transfer timed out")
                try:
                    received = os.readv(fd, [memoryview(transfer)[count:]])
                except BlockingIOError:
                    continue
                if not received:
                    if count != 64 or any(transfer[index] not in b"0123456789abcdef" for index in range(count)):
                        raise ValueError("invalid managed credential transfer")
                    return str(memoryview(transfer)[:count], "ascii")
                count += received
                if count > 64:
                    raise ValueError("invalid managed credential transfer")
    finally:
        if transfer is not None:
            transfer[:] = b"\\x00" * len(transfer)
        os.close(fd)

'''


def once(source, before, after):
    if source.count(before) != 1: raise ValueError('upstream source anchor mismatch')
    return source.replace(before, after, 1)


def overlay(root):
    values = {}
    for name, expected in PINNED.items():
        path = Path(root) / name
        if path.is_symlink() or not path.is_file(): raise ValueError('regular upstream source required')
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected: raise ValueError('unsupported upstream revision: ' + name)
        values[name] = data.decode()
    name = 'server/serve_options.py'
    values[name] = once(values[name], 'import re\n', 'import re\nimport fcntl\nimport selectors\nimport socket\nimport stat\nimport sys\nimport time\n')
    values[name] = once(values[name], 'SERVE_OPTIONS = (\n', HELPER + SECRET_HELPER + '''SERVE_OPTIONS = (
    ServeOption("--listen-fd", "network", dict(type=int, default=None,
                help="Dot managed inherited listener; no bind fallback")),
    ServeOption("--api-key-fd", "network", dict(type=int, default=None,
                help="Dot one-shot inherited credential pipe; no environment fallback")),
''')
    values[name] = once(values[name], '    if args.announce_served_name and not args.served_model_name:\n', '''    # Dot managed startup requires both capabilities and forbids ambient secrets.
    if (args.listen_fd is None) != (args.api_key_fd is None):
        parser.error("managed listener and credential are required together")
    if args.api_key_fd is not None:
        if args.api_key_fd < 3 or args.api_key_fd == args.listen_fd or args.api_key is not None:
            parser.error("invalid managed credential options")
    if args.announce_served_name and not args.served_model_name:
''')
    name = 'install/launcher.py'
    values[name] = once(values[name], 'def serve(args):\n', '''def serve(args):
    # Dot: do not leak the pipe into preparation subprocesses. Only the final
    # server exec receives it, and consumes/closes it before heavy imports.
    if args.api_key_fd is not None:
        serve_options.dot_prepare_api_key_fd(args.api_key_fd)
    try:
        return _dot_serve(args)
    finally:
        # A successful exec never returns. Every failed/aborted preparation or
        # exec closes the read capability, including callers that catch errors.
        if args.api_key_fd is not None:
            os.close(args.api_key_fd)


def _dot_serve(args):
''')
    values[name] = once(values[name], '            _check_port(args.host, args.port)\n', '''            # Dot modification: retain the supervisor-owned listener across exec.
            if args.listen_fd is None:
                _check_port(args.host, args.port)
            else:
                listener = serve_options.dot_owned_listener(args.listen_fd, args.host, args.port)
                listener.detach()
                os.set_inheritable(args.listen_fd, True)
''')
    values[name] = once(values[name], '        os.execve(command[0], command, environment)\n', '''        if args.api_key_fd is not None:
            os.set_inheritable(args.api_key_fd, True)
        os.execve(command[0], command, environment)
''')
    name = 'server/server.py'
    values[name] = once(values[name], 'from transformers import AutoTokenizer\n', '''# Dot modification: stdlib-only credential consumption before ML/server imports.
from . import serve_options
_dot_managed_api_key = serve_options.dot_take_api_key(sys.argv[1:]) if __name__ == "__main__" else None

from transformers import AutoTokenizer
''')
    values[name] = once(values[name], 'def main():\n    args = parse_args()\n', '''def main():
    global _dot_managed_api_key
    args = parse_args()
    if args.api_key_fd is not None:
        if _dot_managed_api_key is None:
            raise ValueError("managed credential transfer required")
        args.api_key = _dot_managed_api_key
        _dot_managed_api_key = None
''')
    values[name] = once(values[name], '        server.server_bind()\n', '''        # Dot modification: adopt the exact inherited kernel socket without rebinding.
        if args.listen_fd is None:
            server.server_bind()
        else:
            listener = serve_options.dot_owned_listener(args.listen_fd, args.host, args.port)
            listener.set_inheritable(False)
            server.socket.close()  # Dispose of TCPServer's unused constructor socket.
            server.socket = listener
            server.server_address = listener.getsockname()
            server.server_name = "localhost"
            server.server_port = server.server_address[1]
''')
    for name, value in values.items(): ast.parse(value, filename=name)
    return values


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True); parser.add_argument('--output', required=True); args = parser.parse_args()
    values = overlay(args.source); output = Path(args.output)
    if output.exists() or output.is_symlink(): raise ValueError('fresh overlay destination required')
    output.mkdir(parents=True)
    files = []
    for name, value in values.items():
        target = output / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(value)
        files.append({'path': 'Splash/' + name, 'upstream_sha256': PINNED[name], 'sha256': hashlib.sha256(value.encode()).hexdigest()})
    record = {'id': PATCH_ID, 'upstream_revision': REVISION, 'license': 'Apache-2.0',
              'notice': 'Dot modifies listener adoption and one-shot credential handoff. Preserve upstream LICENSE and THIRD_PARTY_NOTICES. Overlay must precede runtime manifest/signing.', 'files': files}
    (output / 'patch-record.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
