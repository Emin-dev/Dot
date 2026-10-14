"""Offline BUILD-ONLY endpoint, not the proposed production Swift broker.

Only connects to a continuously owned numeric 127.0.0.1 TLS fixture. Limits are
fixed proposal measurement thresholds. The endpoint has bounded slots, queues,
headers, bytes and deadlines; local peers can deny service temporarily but cannot
reserve slots forever. Neither this implementation nor its tests proves Swift
ownership/cancellation, public-peer vetting, or native Seatbelt acceptance.
"""
from __future__ import annotations
import base64
import hashlib
import hmac
import json
import select
import socket
import ssl
import subprocess
import threading
import time
from pathlib import Path

AUTHORITY = b"html.duckduckgo.com:443"
HOST = "html.duckduckgo.com"
HEADER_CAP = 8192
HEADER_SECONDS = 2.0
HEADER_SLOTS = 4
ACTIVE_SLOTS = 2
BUFFER_BYTES = 32768
UP_CAP = 65536
DOWN_CAP = 8 * 1024 * 1024
TUNNEL_SECONDS = 30.0
CONNECT_SECONDS = 5.0
REQUEST_SECONDS = 12.0
MAX_AUTH_CONNECTS = 2
MAX_OBSERVATIONS = 128
# A strict candidate set; actual curl output is recorded in redacted form.
# Unknown fields fail; they must not be silently added to make a canary pass.
HEADER_NAMES = {b"host", b"proxy-authorization", b"proxy-connection", b"user-agent"}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_header(sock, deadline):
    data = bytearray()
    while not data.endswith(b"\r\n\r\n"):
        if len(data) >= HEADER_CAP:
            raise ValueError("header-cap")
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("header-deadline")
        sock.settimeout(left)
        # Reading one byte avoids accepting pipelined TLS bytes as HTTP headers.
        part = sock.recv(1)
        if not part:
            raise ValueError("header-eof")
        data.extend(part)
    return bytes(data)


def parse_connect(raw, credential):
    if len(raw) > HEADER_CAP or not raw.endswith(b"\r\n\r\n"):
        raise ValueError("invalid-header")
    lines = raw[:-4].split(b"\r\n")
    if not lines or lines[0] != b"CONNECT " + AUTHORITY + b" HTTP/1.1":
        raise ValueError("invalid-authority")
    headers = {}
    for line in lines[1:]:
        if not line or line[:1] in (b" ", b"\t") or b":" not in line:
            raise ValueError("invalid-field")
        if any(c < 32 or c > 126 for c in line):
            raise ValueError("invalid-control")
        name, value = line.split(b":", 1)
        name = name.lower()
        if name not in HEADER_NAMES or name in headers:
            raise ValueError("unknown-or-duplicate-field")
        headers[name] = value.strip(b" ")
    if headers.get(b"host") != AUTHORITY:
        raise ValueError("invalid-host")
    if headers.get(b"proxy-connection", b"Keep-Alive").lower() != b"keep-alive":
        raise ValueError("invalid-proxy-connection")
    expected = b"Basic " + base64.b64encode(b"dot:" + credential)
    if not hmac.compare_digest(headers.get(b"proxy-authorization", b""), expected):
        raise PermissionError("invalid-auth")
    return {k.decode(): ("<redacted>" if k == b"proxy-authorization" else v.decode())
            for k, v in headers.items()}


def connect_frame(credential):
    return (b"CONNECT " + AUTHORITY + b" HTTP/1.1\r\nHost: " + AUTHORITY +
            b"\r\nProxy-Authorization: Basic " + base64.b64encode(b"dot:" + credential) + b"\r\n\r\n")


def contains_proxy_credential(data, credential):
    """Check both the raw capability and its actual on-wire Basic encoding."""
    return credential in data or base64.b64encode(b"dot:" + credential) in data


def create_certificates(root):
    """Ephemeral synthetic test keys; no user key/secret is loaded or transmitted."""
    root = Path(root)
    result = {}
    for name, hostname in (("trusted", HOST), ("untrusted", HOST), ("wrong-host", "wrong.invalid")):
        config = root / (name + ".cnf")
        config.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n"
                          "[dn]\nCN=" + hostname + "\n[ext]\nsubjectAltName=DNS:" + hostname +
                          "\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n")
        cert, key = root / (name + ".pem"), root / (name + ".key")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-config", str(config), "-keyout", str(key), "-out", str(cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        key.chmod(0o600)
        result[name] = (cert, key)
    return result


class OwnedServer:
    """Finite-lifetime fixture owner, at most four simultaneous handler threads."""
    def __init__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.listener.settimeout(0.1)
        self.address = self.listener.getsockname()
        self.closed = threading.Event()
        self.lock = threading.Lock()
        self.handlers = set()
        self.connections = set()
        self.errors = []
        self.thread = threading.Thread(target=self._accept, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def _accept(self):
        while not self.closed.is_set():
            try:
                client, peer = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if peer[0] != "127.0.0.1":
                client.close()
                continue
            with self.lock:
                if self.closed.is_set() or len(self.handlers) >= 4:
                    client.close()
                    continue
                thread = threading.Thread(target=self._handle, args=(client,), daemon=True)
                self.handlers.add(thread)
                self.connections.add(client)
            thread.start()

    def _handle(self, client):
        try:
            self.handle(client)
        except (OSError, ValueError, TimeoutError) as error:
            with self.lock:
                if len(self.errors) < MAX_OBSERVATIONS:
                    self.errors.append(type(error).__name__)
        finally:
            client.close()
            with self.lock:
                self.connections.discard(client)
                self.handlers.discard(threading.current_thread())

    def close(self):
        with self.lock:
            self.closed.set()
            owned = list(self.connections)
        self.listener.close()
        for connection in owned:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.thread.join(2)
        deadline = time.monotonic() + 3
        while True:
            with self.lock:
                threads = list(self.handlers)
            if not threads:
                break
            if time.monotonic() > deadline:
                raise AssertionError("fixture did not drain owned handlers")
            for thread in threads:
                thread.join(0.05)
        assert not self.thread.is_alive(), "fixture acceptor survived close"

    def __enter__(self):
        return self.start()

    def __exit__(self, *ignored):
        self.close()


class TLSOrigin(OwnedServer):
    def __init__(self, cert, key, response=None):
        super().__init__()
        self.sni = []
        self.requests = []
        self.handshakes = 0
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(str(cert), str(key))
        self.context.set_alpn_protocols(["http/1.1"])
        self.context.set_servername_callback(self._sni)
        self.response = response if response is not None else (b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture")

    def _sni(self, ssl_socket, name, context):
        with self.lock:
            if len(self.sni) >= MAX_OBSERVATIONS:
                raise ValueError("observation-cap")
            self.sni.append(name)

    def handle(self, client):
        client.settimeout(3)
        with self.context.wrap_socket(client, server_side=True, do_handshake_on_connect=False) as tls:
            with self.lock:
                self.connections.add(tls)
            try:
                tls.do_handshake()
                with self.lock:
                    self.handshakes += 1
                request = read_header(tls, time.monotonic() + 3)
                # All test requests are fixed-size POSTs; reject large input.
                lengths = [line.split(b":", 1)[1].strip() for line in request.split(b"\r\n")
                           if line.lower().startswith(b"content-length:")]
                if len(lengths) > 1:
                    raise ValueError("duplicate-body-length")
                length = int(lengths[0]) if lengths else 0
                if not 0 <= length <= 16384:
                    raise ValueError("origin-body-cap")
                body = bytearray()
                while len(body) < length:
                    chunk = tls.recv(length - len(body))
                    if not chunk:
                        raise ValueError("origin-short-body")
                    body.extend(chunk)
                with self.lock:
                    if len(self.requests) >= MAX_OBSERVATIONS:
                        raise ValueError("observation-cap")
                    self.requests.append(request + bytes(body))
                tls.sendall(self.response(len(self.requests)) if callable(self.response) else self.response)
            finally:
                with self.lock:
                    self.connections.discard(tls)


class ConnectEndpoint(OwnedServer):
    def __init__(self, origin, credential):
        super().__init__()
        if origin[0] != "127.0.0.1" or not 0 < origin[1] < 65536:
            raise ValueError("fixture upstream must be numeric owned loopback")
        self.origin = origin
        self.credential = credential
        self.header_slots = threading.BoundedSemaphore(HEADER_SLOTS)
        self.active_slots = threading.BoundedSemaphore(ACTIVE_SLOTS)
        self.headers = []
        self.tunnels = []
        self.upstream_allocations = 0
        self.header_timeouts = 0
        self.rejected = 0
        self.authentication_rejections = 0
        self.active = 0
        self.peak_active = 0
        self.deadline = time.monotonic() + min(REQUEST_SECONDS, TUNNEL_SECONDS)
        self.total_upstream_bytes = 0
        self.total_downstream_bytes = 0

    def handle(self, client):
        # The entire server has four handler slots, also bounding unauthenticated
        # readers. This fixture intentionally is stricter than 4+2 concurrency.
        if self.closed.is_set() or not self.header_slots.acquire(blocking=False):
            return
        acquired_header, active, counted = True, False, False
        upstream = None
        record = {"upstream_bytes": 0, "downstream_bytes": 0, "reason": "pending"}
        try:
            try:
                raw = read_header(client, time.monotonic() + HEADER_SECONDS)
                headers = parse_connect(raw, self.credential)
            except (ValueError, PermissionError, TimeoutError, OSError) as error:
                with self.lock:
                    self.rejected += 1
                    self.authentication_rejections += isinstance(error, PermissionError) and error.args == ("invalid-auth",)
                    self.header_timeouts += isinstance(error, (TimeoutError, socket.timeout))
                client.settimeout(0.1)
                try:
                    client.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                except OSError:
                    pass
                return
            if not self.active_slots.acquire(blocking=False):
                return
            active = True
            self.header_slots.release()
            acquired_header = False
            with self.lock:
                if self.closed.is_set() or self.upstream_allocations >= MAX_AUTH_CONNECTS or time.monotonic() >= self.deadline:
                    raise ValueError("generation-admission-cap-or-deadline")
                self.headers.append({"request_line": "CONNECT " + AUTHORITY.decode() + " HTTP/1.1", "headers": headers})
                self.active += 1
                counted = True
                self.peak_active = max(self.active, self.peak_active)
                self.upstream_allocations += 1
                upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.connections.add(upstream)
            upstream.settimeout(min(CONNECT_SECONDS, max(0.001, self.deadline - time.monotonic())))
            upstream.connect(self.origin)
            if upstream.getpeername() != self.origin:
                raise ValueError("fixture-peer-mismatch")
            client.settimeout(1)
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            # Single relay owner, fixed buffers; increment only bytes actually sent.
            end = min(time.monotonic() + TUNNEL_SECONDS, self.deadline)
            peers = {client: (upstream, "upstream_bytes", UP_CAP), upstream: (client, "downstream_bytes", DOWN_CAP)}
            while not self.closed.is_set():
                if time.monotonic() >= end:
                    record["reason"] = "tunnel-deadline"
                    break
                ready, _, _ = select.select(list(peers), [], [], min(0.1, end - time.monotonic()))
                for source in ready:
                    target, key, cap = peers[source]
                    source.settimeout(min(1, max(0.001, end - time.monotonic())))
                    chunk = source.recv(min(BUFFER_BYTES, cap - record[key] + 1))
                    if not chunk:
                        record["reason"] = "eof"
                        return
                    if record[key] + len(chunk) > cap:
                        record["reason"] = key + "-cap"
                        return
                    target.settimeout(min(1, max(0.001, end - time.monotonic())))
                    # Admission and bytes are shared across every reconnect in
                    # this finite fixture generation. No retry resets the budget.
                    with self.lock:
                        total_key = "total_" + key
                        if getattr(self, total_key) + len(chunk) > cap:
                            record["reason"] = "generation-" + key + "-cap"
                            return
                        view = memoryview(chunk)
                        while view:
                            if time.monotonic() >= end or self.closed.is_set():
                                record["reason"] = "generation-deadline-or-invalidation"
                                return
                            sent = target.send(view)
                            if sent <= 0:
                                raise OSError("relay-short-write")
                            record[key] += sent
                            setattr(self, total_key, getattr(self, total_key) + sent)
                            view = view[sent:]
            if record["reason"] == "pending":
                record["reason"] = "invalidated"
        except (OSError, ValueError, TimeoutError):
            record["reason"] = "closed-or-io-error"
        finally:
            if upstream:
                upstream.close()
                with self.lock:
                    self.connections.discard(upstream)
            if acquired_header:
                self.header_slots.release()
            if active:
                with self.lock:
                    if counted:
                        self.active -= 1
                        if len(self.tunnels) < MAX_OBSERVATIONS:
                            self.tunnels.append(record)
                self.active_slots.release()

    def snapshot(self):
        with self.lock:
            return {"connects": list(self.headers), "tunnels": [dict(x) for x in self.tunnels],
                    "upstream_allocations": self.upstream_allocations, "rejected": self.rejected,
                    "authentication_rejections": self.authentication_rejections,
                    "header_timeouts": self.header_timeouts, "active": self.active, "peak_active": self.peak_active,
                    "total_upstream_bytes": self.total_upstream_bytes, "total_downstream_bytes": self.total_downstream_bytes,
                    "absolute_deadline_seconds": min(REQUEST_SECONDS, TUNNEL_SECONDS),
                    "total_connect_admission_cap": MAX_AUTH_CONNECTS}


def settle(endpoint, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        with endpoint.lock:
            if not endpoint.handlers:
                return
        time.sleep(0.01)
    raise AssertionError("fixture handler settlement timed out")
