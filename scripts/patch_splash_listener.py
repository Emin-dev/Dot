#!/usr/bin/env python3
"""Produce a narrowly patched Splash1.3.1 source overlay. Does not execute upstream code."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

REVISION = 'f91c91e21dda483f8c59a248a444d0989a560d31'
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
    values[name] = once(values[name], 'import re\n', 'import re\nimport socket\nimport sys\n')
    values[name] = once(values[name], 'SERVE_OPTIONS = (\n', HELPER + '''SERVE_OPTIONS = (
    ServeOption("--listen-fd", "network", dict(type=int, default=None,
                help="Dot managed inherited listener; no bind fallback")),
''')
    name = 'install/launcher.py'
    values[name] = once(values[name], '            _check_port(args.host, args.port)\n', '''            # Dot modification: retain the supervisor-owned listener across exec.
            if args.listen_fd is None:
                _check_port(args.host, args.port)
            else:
                listener = serve_options.dot_owned_listener(args.listen_fd, args.host, args.port)
                listener.detach()
                os.set_inheritable(args.listen_fd, True)
''')
    name = 'server/server.py'
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
    record = {'id': 'dot-splash-owned-listener-v1', 'upstream_revision': REVISION, 'license': 'Apache-2.0',
              'notice': 'Dot modifies listener adoption only. Preserve upstream LICENSE and THIRD_PARTY_NOTICES. Overlay must precede runtime manifest/signing.', 'files': files}
    (output / 'patch-record.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
