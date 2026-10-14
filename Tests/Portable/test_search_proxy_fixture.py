"""Portable offline harness tests. A pass is never native/provider acceptance."""
from pathlib import Path
import ast
import base64
import json
import subprocess
import os
import socket
import ssl
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests/Fixtures"))
import search_proxy_fixture_support as fixture

CREDENTIAL = b"1" * 64


def wait_for(predicate, seconds=3):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.005)
    raise AssertionError("bounded wait did not establish expected fixture state")


def connection(endpoint):
    sock = socket.create_connection(endpoint.address, timeout=3)
    sock.sendall(fixture.connect_frame(CREDENTIAL))
    header = fixture.read_header(sock, time.monotonic() + 3)
    if not header.startswith(b"HTTP/1.1 200 "):
        sock.close()
        raise AssertionError("fixture rejected valid test tunnel")
    return sock


class Sink(fixture.OwnedServer):
    def __init__(self, response_size=0):
        super().__init__()
        self.received = 0
        self.response_size = response_size
        self.release_extra = threading.Event()

    def handle(self, sock):
        sock.settimeout(3)
        if self.response_size:
            remaining = self.response_size
            while remaining:
                part = b"x" * min(32768, remaining)
                sock.sendall(part)
                remaining -= len(part)
            if self.release_extra.wait(3):
                sock.sendall(b"!")
        while True:
            data = sock.recv(32768)
            if not data:
                return
            with self.lock:
                self.received += len(data)


class ParserTests(unittest.TestCase):
    def test_raw_and_basic_encoded_credential_leaks_are_rejected(self):
        encoded = base64.b64encode(b"dot:" + CREDENTIAL)
        for leak in (CREDENTIAL, encoded, b"Authorization: Basic " + encoded,
                     b'"logged_proxy_auth":"' + encoded + b'"'):
            with self.subTest(leak_kind=leak[:14]):
                self.assertTrue(fixture.contains_proxy_credential(leak, CREDENTIAL))
        self.assertFalse(fixture.contains_proxy_credential(b"Proxy-Authorization: <redacted>", CREDENTIAL))

    def test_exact_header_and_redaction(self):
        headers = fixture.parse_connect(fixture.connect_frame(CREDENTIAL), CREDENTIAL)
        self.assertEqual(headers["host"], "html.duckduckgo.com:443")
        self.assertEqual(headers["proxy-authorization"], "<redacted>")
        self.assertNotIn(CREDENTIAL.decode(), json.dumps(headers))

    def test_authority_aliases_and_method_rejected(self):
        raw = fixture.connect_frame(CREDENTIAL)
        for target in (b"html.duckduckgo.com:80", b"html.duckduckgo.com.:443", b"127.0.0.1:443", b"[::1]:443",
                       b"10.0.0.1:443", b"evil.invalid:443", b"https://html.duckduckgo.com:443", b"x@html.duckduckgo.com:443",
                       b"html%2educkduckgo.com:443", b"HTML.duckduckgo.com:443"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                fixture.parse_connect(raw.replace(fixture.AUTHORITY, target, 1), CREDENTIAL)
        with self.assertRaises(ValueError):
            fixture.parse_connect(raw.replace(b"CONNECT", b"GET", 1), CREDENTIAL)

    def test_duplicates_bodies_controls_unknown_fields_rejected(self):
        raw = fixture.connect_frame(CREDENTIAL)
        for extra in (b"Host: html.duckduckgo.com:443", b"Proxy-Authorization: Basic QQ==", b"Content-Length: 0",
                      b"Transfer-Encoding: chunked", b" User-Agent: folded", b"User-Agent: bad\tvalue",
                      b"X-Unreviewed: any", b"Host : html.duckduckgo.com:443"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                fixture.parse_connect(raw[:-2] + extra + b"\r\n\r\n", CREDENTIAL)
        with self.assertRaises(ValueError):
            fixture.parse_connect(raw + b"body", CREDENTIAL)

    def test_wrong_or_stale_auth_rejected(self):
        with self.assertRaises(PermissionError):
            fixture.parse_connect(fixture.connect_frame(b"2" * 64), CREDENTIAL)

    def test_split_header_and_real_cap(self):
        first, second = socket.socketpair()
        with first, second:
            raw = fixture.connect_frame(CREDENTIAL)
            def send():
                for at in range(0, len(raw), 3):
                    second.sendall(raw[at:at + 3])
            thread = threading.Thread(target=send)
            thread.start()
            self.assertEqual(fixture.read_header(first, time.monotonic() + 2), raw)
            thread.join()
        first, second = socket.socketpair()
        with first, second:
            second.sendall(b"x" * fixture.HEADER_CAP)
            with self.assertRaisesRegex(ValueError, "header-cap"):
                fixture.read_header(first, time.monotonic() + 2)


class LifecycleTests(unittest.TestCase):
    def test_wrong_auth_allocates_no_upstream(self):
        with Sink() as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            with socket.create_connection(endpoint.address, timeout=2) as sock:
                sock.sendall(fixture.connect_frame(b"0" * 64))
                self.assertTrue(fixture.read_header(sock, time.monotonic() + 2).startswith(b"HTTP/1.1 407"))
            fixture.settle(endpoint)
            self.assertEqual(endpoint.snapshot()["upstream_allocations"], 0)
            self.assertEqual(endpoint.snapshot()["authentication_rejections"], 1)
            self.assertEqual(origin.received, 0)

    def test_four_unauthenticated_slots_recover_without_upstream(self):
        with Sink() as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            clients = [socket.create_connection(endpoint.address, timeout=2) for _ in range(4)]
            try:
                wait_for(lambda: len(endpoint.handlers) == 4)
                with socket.create_connection(endpoint.address, timeout=2) as extra:
                    extra.settimeout(1)
                    self.assertEqual(extra.recv(1), b"")
                wait_for(lambda: endpoint.snapshot()["header_timeouts"] == 4, fixture.HEADER_SECONDS + 2)
                fixture.settle(endpoint)
                self.assertEqual(endpoint.snapshot()["upstream_allocations"], 0)
                self.assertEqual(endpoint.snapshot()["authentication_rejections"], 0)
                with connection(endpoint) as sock:
                    sock.sendall(b"recovered")
                    wait_for(lambda: origin.received == 9)
            finally:
                for client in clients:
                    client.close()

    def test_active_and_total_connect_admission_bounds(self):
        with Sink() as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            clients = [connection(endpoint) for _ in range(2)]
            try:
                with socket.create_connection(endpoint.address, timeout=2) as extra:
                    extra.sendall(fixture.connect_frame(CREDENTIAL))
                    self.assertEqual(extra.recv(1), b"")
                self.assertEqual(endpoint.snapshot()["peak_active"], 2)
            finally:
                for client in clients:
                    client.close()
            fixture.settle(endpoint)
            with socket.create_connection(endpoint.address, timeout=2) as extra:
                extra.sendall(fixture.connect_frame(CREDENTIAL))
                self.assertEqual(extra.recv(1), b"")
            self.assertEqual(endpoint.snapshot()["upstream_allocations"], 2)

    def test_real_upstream_budget_shared_across_reconnect(self):
        with Sink() as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            with connection(endpoint) as first:
                first.sendall(b"x" * (fixture.UP_CAP - 1))
                wait_for(lambda: endpoint.snapshot()["total_upstream_bytes"] == fixture.UP_CAP - 1)
            fixture.settle(endpoint)
            with connection(endpoint) as second:
                second.sendall(b"x")
                wait_for(lambda: endpoint.snapshot()["total_upstream_bytes"] == fixture.UP_CAP)
                second.sendall(b"!")
                self.assertEqual(second.recv(1), b"")
            fixture.settle(endpoint)
            wait_for(lambda: origin.received == fixture.UP_CAP)
            evidence = endpoint.snapshot()
            self.assertEqual(evidence["total_upstream_bytes"], fixture.UP_CAP)
            self.assertTrue(any(t["reason"] == "generation-upstream_bytes-cap" for t in evidence["tunnels"]))

    def test_real_downstream_budget_does_not_forward_overflow(self):
        with Sink(fixture.DOWN_CAP) as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            with connection(endpoint) as sock:
                received = 0
                while received < fixture.DOWN_CAP:
                    data = sock.recv(min(65536, fixture.DOWN_CAP - received))
                    self.assertTrue(data)
                    received += len(data)
                self.assertEqual(endpoint.snapshot()["total_downstream_bytes"], fixture.DOWN_CAP)
                origin.release_extra.set()
                self.assertEqual(sock.recv(1), b"")
            fixture.settle(endpoint)
            self.assertEqual(received, fixture.DOWN_CAP)
            self.assertTrue(any(t["reason"] == "downstream_bytes-cap" for t in endpoint.snapshot()["tunnels"]))

    def test_invalidation_closes_active_and_unauthenticated_connections(self):
        with Sink() as origin:
            endpoint = fixture.ConnectEndpoint(origin.address, CREDENTIAL).start()
            active = connection(endpoint)
            waiting = socket.create_connection(endpoint.address, timeout=2)
            try:
                wait_for(lambda: len(endpoint.handlers) == 2)
                before = endpoint.snapshot()["upstream_allocations"]
                started = time.monotonic()
                endpoint.close()
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(active.recv(1), b"")
                self.assertEqual(waiting.recv(1), b"")
                self.assertFalse(endpoint.handlers)
                self.assertEqual(endpoint.snapshot()["active"], 0)
                self.assertEqual(endpoint.snapshot()["upstream_allocations"], before)
            finally:
                active.close()
                waiting.close()
                endpoint.close()

    def test_absolute_deadline_survives_reconnect_and_invalidation_drains(self):
        with Sink() as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            endpoint.deadline = time.monotonic() + 0.4  # narrow test clock only
            with connection(endpoint) as first:
                first.sendall(b"x")
                wait_for(lambda: origin.received == 1)
            fixture.settle(endpoint)
            with connection(endpoint) as second:
                second.settimeout(1)
                self.assertEqual(second.recv(1), b"")
            fixture.settle(endpoint)
            self.assertTrue(any(t["reason"] == "tunnel-deadline" for t in endpoint.snapshot()["tunnels"]))
        self.assertFalse(endpoint.handlers)
        self.assertFalse(endpoint.thread.is_alive())


class SourceContractTests(unittest.TestCase):
    def test_native_transport_has_no_request_monkeypatch_or_tls_bypass(self):
        source = (ROOT / "Tests/Fixtures/search_proxy_transport_fixture.py").read_text()
        tree = ast.parse(source)
        assignments = [ast.unparse(target) for node in ast.walk(tree) if isinstance(node, ast.Assign) for target in node.targets]
        self.assertNotIn("searx.network.request", assignments)
        self.assertNotIn("searx.network.client.new_client", assignments)
        self.assertNotIn("verify=False", source.replace(" ", ""))
        self.assertIn("searx.network.request(\"post\"", source)
        self.assertIn("expected-receipt-sha256", source)
        self.assertIn("production_broker_tested", source)

    @unittest.skipIf(sys.platform == "darwin", "Linux-only native-unrun contract")
    def test_native_transport_wrapper_explicit_skip(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/verify_search_proxy_native_fixture.sh")], capture_output=True)
        self.assertEqual(result.returncode, 77)
        self.assertIn(b"no native execution performed", result.stderr)

    def test_transport_pins_are_exact_and_complete(self):
        pins = json.loads((ROOT / "Tests/Fixtures/search_proxy_pinned_hashes.json").read_text())
        self.assertEqual(pins["searxng_revision"], "22c64b8d394b680c7ea96be25f36dad14126420a")
        self.assertEqual(pins["curl_cffi_version"], "0.16.3")
        self.assertEqual(len(pins["files"]), 8)
        for name, value in pins["files"].items():
            self.assertTrue(name.startswith(("searx/", "curl_cffi/")))
            self.assertEqual(len(value), 64)


class TLSFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="dot-proxy-portable-")
        cls.certificates = fixture.create_certificates(Path(cls.temporary.name))

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_actual_tls_sni_verification_and_no_auth_at_origin(self):
        cert, key = self.certificates["trusted"]
        with fixture.TLSOrigin(cert, key) as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            with connection(endpoint) as sock:
                context = ssl.create_default_context(cafile=str(cert))
                with context.wrap_socket(sock, server_hostname=fixture.HOST) as tls:
                    tls.sendall(b"GET /html/ HTTP/1.1\r\nHost: html.duckduckgo.com\r\n\r\n")
                    response = bytearray()
                    while part := tls.recv(8192):
                        response.extend(part)
                    self.assertTrue(response.endswith(b"fixture"))
            fixture.settle(endpoint)
            self.assertEqual(origin.sni, [fixture.HOST])
            self.assertNotIn(b"proxy-authorization", origin.requests[0].lower())
            self.assertFalse(fixture.contains_proxy_credential(origin.requests[0], CREDENTIAL))
            self.assertGreater(endpoint.snapshot()["total_upstream_bytes"], len(origin.requests[0]))

    def test_untrusted_certificate_rejected(self):
        cert, key = self.certificates["untrusted"]
        trusted = self.certificates["trusted"][0]
        with fixture.TLSOrigin(cert, key) as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            with connection(endpoint) as sock:
                context = ssl.create_default_context(cafile=str(trusted))
                with self.assertRaises(ssl.SSLCertVerificationError):
                    context.wrap_socket(sock, server_hostname=fixture.HOST)
            fixture.settle(endpoint)
            self.assertFalse(origin.requests)

    def test_trusted_wrong_hostname_rejected(self):
        cert, key = self.certificates["wrong-host"]
        with fixture.TLSOrigin(cert, key) as origin, fixture.ConnectEndpoint(origin.address, CREDENTIAL) as endpoint:
            with connection(endpoint) as sock:
                context = ssl.create_default_context(cafile=str(cert))
                with self.assertRaises(ssl.SSLCertVerificationError):
                    context.wrap_socket(sock, server_hostname=fixture.HOST)
            fixture.settle(endpoint)
            self.assertFalse(origin.requests)


if __name__ == "__main__":
    unittest.main()
