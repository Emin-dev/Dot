"""BUILD-ONLY synthetic probe shared by the profile and bootstrap canaries."""
import argparse
import errno
import json
import mmap
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--payload", type=Path, required=True)
parser.add_argument("--state-root", type=Path, required=True)
parser.add_argument("--owned-listener", type=int, required=True)
parser.add_argument("--egress-port", type=int, required=True)
parser.add_argument("--probe-kind", choices=("profile", "bootstrap"), required=True)
args = parser.parse_args()
payload, state = args.payload, args.state_root
assert sys.platform == "darwin" and platform.machine() == "arm64"
assert sys.version_info[:3] == (3, 11, 17), "exact independent CPython 3.11.17 required"
assert Path(sys.executable).resolve() == payload / "python/bin/python3"
assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
assert set(os.environ) <= {"PATH", "HOME", "TMPDIR", "LANG", "PYTHONDONTWRITEBYTECODE", "LC_CTYPE"}
if args.probe_kind == "bootstrap":
    assert args.owned_listener == 3
    try:
        os.fstat(4)
    except OSError as error:
        assert error.errno == errno.EBADF
    else:
        raise AssertionError("native closefrom leaked an inherited descriptor")
fixture = json.loads((state / "fixture.json").read_text())
assert fixture["egress_port"] == args.egress_port
outside, inference = Path(fixture["outside"]), Path(fixture["inference"])
checks = []


def denied(label, operation):
    try:
        operation()
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), (label, repr(error))
        checks.append(label)
        return
    raise AssertionError("Search canary permitted forbidden operation: " + label)


def receive(sock, count):
    value = bytearray()
    while len(value) < count:
        chunk = sock.recv(count - len(value))
        assert chunk, "short synthetic socket reply"
        value.extend(chunk)
    return bytes(value)


def connect(address, family=socket.AF_INET, kind=socket.SOCK_STREAM):
    with socket.socket(family, kind) as sock:
        sock.settimeout(1)
        sock.connect(address)


def bind(address, family=socket.AF_INET):
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        sock.bind(address)


def udp(address, family=socket.AF_INET):
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.sendto(b"synthetic-denial-probe", address)


assert (payload / "dot_search.py").read_bytes()
with (payload / "python/bin/python3").open("rb") as executable:
    with mmap.mmap(executable.fileno(), 0, access=mmap.ACCESS_READ) as data:
        assert data[:4]
(state / "own.tmp").write_bytes(b"synthetic-state")
assert (state / "own.tmp").read_bytes() == b"synthetic-state"
(state / "own.tmp").unlink()
checks.extend(("payload-read-map", "private-state-read-write"))
for name, path in (
    ("private-file-read", outside / "private.fixture"),
    ("inference-file-read", inference / "model.fixture"),
    ("state-symlink-read", state / "escape"),
    ("parent-traversal-read", state / "../Documents/private.fixture"),
):
    denied(name, path.read_bytes)
if args.probe_kind == "bootstrap":
    denied("payload-symlink-read", (payload / "escape").read_bytes)
for name, directory in (("private-directory", outside), ("inference-directory", inference), ("tmp-directory", Path("/private/tmp"))):
    denied(name, lambda: list(directory.iterdir()))
for name, path in (
    ("private-file-write", outside / "write.fixture"),
    ("inference-file-write", inference / "write.fixture"),
    ("payload-file-write", payload / "write.fixture"),
    ("state-symlink-write", state / "escape"),
):
    denied(name, lambda: path.write_bytes(b"forbidden"))
denied("shell-exec", lambda: subprocess.run(["/bin/sh", "-c", "exit 0"], check=True))
# Preserve the existing same-interpreter and same-sandbox child cleanup canary.
child = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c", "import time; time.sleep(60)"],
                         start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    os.killpg(child.pid, signal.SIGTERM)
    child.wait(timeout=3)
finally:
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=3)
checks.append("same-sandbox-child-cleanup")

with socket.socket(fileno=args.owned_listener) as listener:
    address = listener.getsockname()
    assert listener.family == socket.AF_INET and address[0] == "127.0.0.1"
    assert 1 <= address[1] <= 65535 and address[1] != args.egress_port
    assert listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) == 1
    assert listener.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR) == 0
    assert listener.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT) == 0
    for label, target in (
        ("unrelated-loopback", ("127.0.0.1", fixture["foreign_port"])),
        ("listener-self-egress", address),
        ("other-loopback-address", ("127.0.0.2", args.egress_port)),
        ("public-tcp", ("8.8.8.8", 443)),
        ("private-tcp", ("10.0.0.1", 443)),
        ("lan-tcp", ("192.168.1.1", 443)),
        ("link-local-tcp", ("169.254.1.1", 443)),
        ("dns-tcp-public", ("8.8.8.8", 53)),
        ("dns-tcp-loopback", ("127.0.0.1", 53)),
    ):
        denied(label, lambda: connect(target))
    denied("new-loopback-bind", lambda: bind(("127.0.0.1", 0)))
    denied("new-wildcard-bind", lambda: bind(("0.0.0.0", 0)))
    denied("new-ipv6-bind", lambda: bind(("::1", 0), socket.AF_INET6))
    denied("udp-egress-port", lambda: udp(("127.0.0.1", args.egress_port)))
    denied("udp-unrelated-loopback", lambda: udp(("127.0.0.1", fixture["foreign_port"])))
    denied("dns-udp-public", lambda: udp(("8.8.8.8", 53)))
    denied("dns-udp-private", lambda: udp(("192.168.1.1", 53)))
    denied("ipv6-owned-egress-port", lambda: connect(("::1", args.egress_port), socket.AF_INET6))
    denied("ipv6-mapped-loopback", lambda: connect(("::ffff:127.0.0.1", args.egress_port), socket.AF_INET6))
    denied("ipv6-public", lambda: connect(("2606:4700:4700::1111", 443), socket.AF_INET6))
    denied("ipv6-dns-udp", lambda: udp(("::1", 53), socket.AF_INET6))
    # Exercise the resolver's socket surface without issuing a hostname query.
    denied("mdns-resolver-socket", lambda: connect("/private/var/run/mDNSResponder", socket.AF_UNIX))
    # Two fresh connections prove reconnect is allowed only to the held endpoint.
    for sequence in range(2):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(("127.0.0.1", args.egress_port))
            client.sendall(b"egress" + bytes([sequence]))
            assert receive(client, 5) == b"reply"
    checks.append("owned-af-inet-egress-reconnect")
    control = json.loads(sys.stdin.buffer.readline(2049))
    assert control == {"protocol": 1, "command": "start", "generation": "native-canary"}
    # Deliberately not a production ready event. It cannot admit a runtime.
    print(json.dumps({"event": "native_canary_ready", "pid": os.getpid(), "port": address[1], "checks": checks}), flush=True)
    listener.settimeout(5)
    connection, peer = listener.accept()
    with connection:
        connection.settimeout(5)
        assert peer[0] == "127.0.0.1"
        assert receive(connection, 7) == b"fixture"
        connection.sendall(b"reply")
    assert sys.stdin.buffer.read(1) == b""
print(json.dumps({"event": "native_canary_stopped"}), flush=True)
