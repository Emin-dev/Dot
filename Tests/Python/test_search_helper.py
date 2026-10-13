"""Portable owned-search boundary/lifecycle fixtures. No external query is sent."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Resources/Search/dot_search.py"
spec = importlib.util.spec_from_file_location("dot_search", HELPER)
search = importlib.util.module_from_spec(spec)
spec.loader.exec_module(search)
TOKEN = "a" * 64


def form(query="synthetic fixture"):
    return urlencode({"q": query, "format": "json", "categories": "general", "pageno": "1",
                      "language": "auto", "safesearch": "1", "engines": "duckduckgo"}).encode()


def environ(body=None, **changes):
    body = form() if body is None else body
    result = {"REMOTE_ADDR": "127.0.0.1", "HTTP_HOST": "127.0.0.1:12345",
              "wsgi.url_scheme": "http", "HTTP_X_DOT_SEARCH_CAPABILITY": TOKEN,
              "REQUEST_METHOD": "POST", "PATH_INFO": "/search", "REQUEST_URI": "/search",
              "QUERY_STRING": "", "SCRIPT_NAME": "", "HTTP_ACCEPT": "application/json",
              "CONTENT_TYPE": "application/x-www-form-urlencoded; charset=utf-8",
              "CONTENT_LENGTH": str(len(body)), "wsgi.input": io.BytesIO(body), "wsgi.errors": io.StringIO()}
    result.update(changes)
    return result


def invoke(app, env):
    captured = {}
    def start(status, headers, exc_info=None):
        captured.update(status=status, headers=dict(headers))
    result = b"".join(app(env, start))
    return captured["status"], captured["headers"], result


def fixture_app(environ, start_response):
    if b"fixture+slow" in environ["wsgi.input"].getvalue():
        time.sleep(60)
    if b"fixture+large" in environ["wsgi.input"].getvalue():
        prefix = b'{"results":[{"url":"https://example.org","title":"x","content":"'
        suffix = b'"}]}'
        body = prefix + b"x" * (search.MAX_RESPONSE - len(prefix) - len(suffix)) + suffix
        start_response("200 OK", [("Content-Type", "application/json")])
        return [body]
    start_response("200 OK", [("Content-Type", "application/json")])
    return [b'{"results":[{"url":"https://example.org/","title":"Fixture","content":"synthetic"}],"unresponsive_engines":[]}']


class ListenerTests(unittest.TestCase):
    def test_platform_probe_accepts_only_exact_listening_state(self):
        cases = (("darwin", (socket.IPPROTO_TCP, 0x106, 1),
                  (b"\x01", b"\x00", b"\x04", b"", b"\x01\x00")),
                 ("linux", (socket.SOL_SOCKET, socket.SO_ACCEPTCONN), (1, 0, 2)))
        for platform, arguments, states in cases:
            for index, state in enumerate(states):
                with self.subTest(platform=platform, state=state):
                    listener = mock.Mock()
                    listener.getsockopt.return_value = state
                    with mock.patch.object(search.sys, "platform", platform), \
                            mock.patch.object(search.socket, "TCP_CONNECTION_INFO", 0x106, create=True):
                        self.assertEqual(search.listener_is_listening(listener), index == 0)
                    listener.getsockopt.assert_called_once_with(*arguments)
                    listener.bind.assert_not_called()
                    listener.listen.assert_not_called()
                    listener.close.assert_not_called()

    def test_unsupported_probe_raises_without_fallback_or_mutation(self):
        for platform in ("darwin", "linux"):
            with self.subTest(platform=platform):
                listener = mock.Mock()
                error = OSError(42, "unsupported socket option")
                listener.getsockopt.side_effect = error
                with mock.patch.object(search.sys, "platform", platform), \
                        mock.patch.object(search.socket, "TCP_CONNECTION_INFO", 0x106, create=True):
                    with self.assertRaises(OSError) as failure:
                        search.listener_is_listening(listener)
                self.assertIs(failure.exception, error)
                self.assertEqual(listener.getsockopt.call_count, 1)
                listener.bind.assert_not_called()
                listener.listen.assert_not_called()
                listener.close.assert_not_called()

    def test_real_socket_states_remain_unchanged_by_probe(self):
        with socket.socket() as listener:
            self.assertFalse(search.listener_is_listening(listener))
            listener.bind(("127.0.0.1", 0))
            self.assertFalse(search.listener_is_listening(listener))
            listener.listen(1)
            address = listener.getsockname()
            self.assertTrue(search.listener_is_listening(listener))
            with socket.create_connection(address, timeout=2) as client:
                accepted, _ = listener.accept()
                with accepted:
                    self.assertFalse(search.listener_is_listening(client))
                    self.assertFalse(search.listener_is_listening(accepted))
                    self.assertTrue(search.listener_is_listening(listener))
                    client.sendall(b"fixture")
                    self.assertEqual(accepted.recv(7), b"fixture")
            self.assertEqual(listener.getsockname(), address)
            self.assertTrue(search.listener_is_listening(listener))

    def test_rejected_nonlisteners_remain_open_and_are_not_promoted(self):
        with socket.socket() as bound, search.owned_listener() as server:
            bound.bind(("127.0.0.1", 0))
            with socket.create_connection(server.getsockname(), timeout=2) as client:
                accepted, _ = server.accept()
                with accepted:
                    for original in (bound, client, accepted):
                        descriptor = os.dup(original.fileno())
                        try:
                            with self.assertRaisesRegex(ValueError, "invalid_listener"):
                                search.adopt_listener(descriptor, original.getsockname()[1])
                            os.fstat(descriptor)
                            self.assertFalse(search.listener_is_listening(original))
                        finally:
                            os.close(descriptor)

    def test_adoption_probe_error_preserves_callers_descriptor(self):
        with search.owned_listener() as original:
            descriptor = os.dup(original.fileno())
            try:
                os.set_inheritable(descriptor, True)
                with mock.patch.object(search, "listener_is_listening", side_effect=OSError(42, "probe failed")):
                    with self.assertRaises(OSError):
                        search.adopt_listener(descriptor, original.getsockname()[1])
                os.fstat(descriptor)
                self.assertTrue(os.get_inheritable(descriptor))
                self.assertTrue(search.listener_is_listening(original))
            finally:
                os.close(descriptor)

    def test_adoption_setup_error_detaches_without_closing(self):
        listener = mock.Mock(family=socket.AF_INET, type=socket.SOCK_STREAM)
        listener.getsockname.return_value = ("127.0.0.1", 12345)
        listener.set_inheritable.side_effect = OSError("descriptor setup failed")
        with mock.patch.object(search.socket, "socket", return_value=listener), \
                mock.patch.object(search, "listener_is_listening", return_value=True):
            with self.assertRaises(OSError):
                search.adopt_listener(123, 12345)
        listener.detach.assert_called_once_with()
        listener.close.assert_not_called()
        listener.bind.assert_not_called()
        listener.listen.assert_not_called()


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        def app(env, start):
            self.calls.append(env)
            return fixture_app(env, start)
        self.boundary = search.SearchBoundary(app, 12345, TOKEN)

    def test_valid_unicode_plus_form_and_private_capability_removed(self):
        query = "C++ & café=界 100%\n😀!"
        status, headers, body = invoke(self.boundary, environ(form(query)))
        self.assertEqual(status, "200 OK")
        inner = self.calls[0]
        self.assertNotIn(search.CAPABILITY_HEADER, inner)
        self.assertEqual(dict(search.parse_qsl(inner["wsgi.input"].read().decode()))["q"], query)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(len(json.loads(body)["results"]), 1)

    def test_foreign_hosts_origins_cors_tokens_and_proxy_headers(self):
        cases = [{"HTTP_HOST": host} for host in ("localhost:12345", "127.0.0.1", "evil.example", "127.0.0.1:12346", "127.0.0.1:12345,evil")]
        cases += [{key: value} for key, value in (
            ("HTTP_ORIGIN", "null"), ("HTTP_ORIGIN", ""), ("HTTP_ACCESS_CONTROL_REQUEST_METHOD", "POST"),
            ("HTTP_ACCESS_CONTROL_REQUEST_HEADERS", "X-Dot-Search-Capability"),
            ("HTTP_X_DOT_SEARCH_CAPABILITY", "b" * 64), ("HTTP_X_DOT_SEARCH_CAPABILITY", ""),
            ("HTTP_X_DOT_SEARCH_CAPABILITY", "é"), ("HTTP_COOKIE", "cookie=fixture"),
            ("HTTP_AUTHORIZATION", "Basic fixture"), ("HTTP_FORWARDED", "host=evil.example"),
            ("HTTP_X_FORWARDED_FOR", "127.0.0.1"), ("HTTP_TRANSFER_ENCODING", "chunked"),
            ("REMOTE_ADDR", "127.0.0.2"), ("wsgi.url_scheme", "https"))]
        for changes in cases:
            with self.subTest(changes=list(changes)):
                status, headers, _ = invoke(self.boundary, environ(**changes))
                self.assertEqual(status, "403 Forbidden")
                self.assertFalse(any(name.lower().startswith("access-control") for name in headers))
        self.assertEqual(self.calls, [])

    def test_routes_and_methods_are_exact_and_never_health_or_configuration(self):
        for changes in ([{"REQUEST_METHOD": value} for value in ("GET", "OPTIONS", "HEAD", "PUT", "post")]
                        + [{"PATH_INFO": value} for value in ("/", "/config", "/healthz", "/search/")]
                        + [{"QUERY_STRING": "q=secret"}, {"SCRIPT_NAME": "/prefix"},
                           {"REQUEST_URI": "/%73earch"}, {"REQUEST_URI": "http://127.0.0.1:12345/search"}]):
            self.assertEqual(invoke(self.boundary, environ(**changes))[0], "404 Not Found")
        self.assertEqual(self.calls, [])

    def test_form_type_length_and_encoding_rejections(self):
        for changes in ({"CONTENT_TYPE": "application/json"}, {"CONTENT_TYPE": "application/x-www-form-urlencoded"},
                        {"HTTP_ACCEPT": "text/html"}, {"HTTP_CONTENT_ENCODING": "gzip"}):
            self.assertEqual(invoke(self.boundary, environ(**changes))[0], "415 Unsupported Media Type")
        for length in ("", "0", "-1", "+1", "001", "99,99", "NaN"):
            self.assertEqual(invoke(self.boundary, environ(CONTENT_LENGTH=length))[0], "400 Bad Request")
        self.assertEqual(invoke(self.boundary, environ(CONTENT_LENGTH="16385"))[0], "413 Payload Too Large")
        self.assertEqual(invoke(self.boundary, environ(CONTENT_LENGTH="999"))[0], "400 Bad Request")
        for body in (form() + b"&q=duplicate", form().replace(b"q=synthetic", b"q=%ZZ"),
                     form().replace(b"q=synthetic", b"q=%FF"), b"q=x", form().replace(b"q=synthetic", b"q=\xff")):
            self.assertEqual(invoke(self.boundary, environ(body))[0], "400 Bad Request")
        self.assertEqual(self.calls, [])

    def test_options_query_limits_and_bangs_rejected(self):
        for query in ("", " ", "界" * 683, "x" * 500, "\x00", "!google fixture", "fixture !!google", "! fixture"):
            self.assertEqual(invoke(self.boundary, environ(form(query)))[0], "400 Bad Request")
        for old, new in ((b"engines=duckduckgo", b"engines=braveapi"), (b"format=json", b"format=html"),
                         (b"categories=general", b"categories=images"), (b"pageno=1", b"pageno=2"),
                         (b"language=auto", b"language=all"), (b"safesearch=1", b"safesearch=0")):
            self.assertEqual(invoke(self.boundary, environ(form().replace(old, new)))[0], "400 Bad Request")
        self.assertEqual(self.calls, [])

    def test_upstream_headers_and_extra_content_never_escape(self):
        def app(env, start):
            start("200 OK", [("Content-Type", "application/json"), ("Set-Cookie", "fixture=1"),
                             ("Access-Control-Allow-Origin", "*")])
            return [json.dumps({"results": [{"url": "https://example.org", "title": "ok", "raw": "DROP"}],
                                "query": "DROP", "answers": ["DROP"], "infoboxes": ["DROP"]}).encode()]
        status, headers, body = invoke(search.SearchBoundary(app, 12345, TOKEN), environ())
        self.assertEqual(status, "200 OK")
        self.assertNotIn(b"DROP", body)
        self.assertNotIn("Set-Cookie", headers)
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_bad_upstream_results_are_fixed_redacted_failures(self):
        cases = [("200 OK", "text/html", b"private query"), ("302 Found", "text/html", b"private query"),
                 ("200 OK", "application/json", b'{"error":"private query","results":[]}'),
                 ("200 OK", "application/json", b'{"errors":["private query"],"results":[]}'),
                 ("200 OK", "application/json", b'{"results":null}'),
                 ("200 OK", "application/json", b'{"results":[],"query":NaN}'),
                 ("200 OK", "application/json", b"{"),
                 ("200 OK", "application/json", json.dumps({"results": [None] * 513}).encode()),
                 ("200 OK", "application/json", b"x" * (search.MAX_RESPONSE + 1))]
        for status, mime, data in cases:
            def app(env, start):
                start(status, [("Content-Type", mime), ("Location", "https://example.org/?q=private")])
                return [data]
            actual, headers, body = invoke(search.SearchBoundary(app, 12345, TOKEN), environ())
            self.assertEqual(actual, "502 Bad Gateway")
            self.assertEqual(json.loads(body), {"error": "upstream_failure"})
            self.assertNotIn("Location", headers)

    def test_upstream_cooldown_is_preserved_and_no_raw_diagnostics(self):
        for status in ("429 Too Many Requests", "503 Service Unavailable"):
            for value in ("120", "Wed, 21 Oct 2026 07:28:00 GMT", "1000000000"):
                def app(env, start):
                    start(status, [("Retry-After", value)])
                    return [b"private upstream error"]
                actual, headers, body = invoke(search.SearchBoundary(app, 12345, TOKEN), environ())
                self.assertEqual(actual, status)
                self.assertEqual(headers["Retry-After"], value)
                self.assertNotIn(b"private", body)

    def test_busy_request_dispatches_no_second_search(self):
        self.boundary.admission.acquire()
        try:
            status, headers, _ = invoke(self.boundary, environ())
            self.assertEqual(status, "429 Too Many Requests")
            self.assertEqual(headers["Retry-After"], "1")
            self.assertEqual(self.calls, [])
        finally:
            self.boundary.admission.release()

    def test_closes_iterator_on_oversize_and_releases_admission(self):
        closed = []
        def app(env, start):
            start("200 OK", [("Content-Type", "application/json")])
            try:
                yield b"x" * (search.MAX_RESPONSE + 1)
            finally:
                closed.append(True)
        boundary = search.SearchBoundary(app, 12345, TOKEN)
        self.assertEqual(invoke(boundary, environ())[0], "502 Bad Gateway")
        self.assertEqual(closed, [True])
        self.assertTrue(boundary.admission.acquire(False))
        boundary.admission.release()


class ConfigurationTests(unittest.TestCase):
    def test_configuration_removes_other_engines_and_uses_separate_secret(self):
        text = search.settings_text(12345, "b" * 64)
        self.assertIn("keep_only: [duckduckgo]", text)
        self.assertIn("formats: [json]", text)
        self.assertNotIn("braveapi", text)
        self.assertNotIn(TOKEN, text)
        self.assertIn("debug: false", text)
        self.assertIn("limiter: false", text)

    def test_environment_drops_keys_proxies_python_paths_and_home(self):
        with tempfile.TemporaryDirectory() as root:
            clean = search.clean_environment(Path(root))
            for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "OPENAI_API_KEY", "PYTHONPATH", "PYTHONHOME"):
                self.assertNotIn(key, clean)
            self.assertEqual(clean["HOME"], str(Path(root) / "home"))
            self.assertEqual(clean["XDG_CACHE_HOME"], str(Path(root) / "cache"))

    def test_state_is_private_and_replaced_directory_is_not_removed(self):
        with tempfile.TemporaryDirectory() as root:
            state, identity = search.private_state(Path(root))
            self.assertEqual(state.stat().st_mode & 0o777, 0o700)
            old = state.with_name("preserved")
            state.rename(old)
            state.mkdir()
            (state / "canary").write_text("do not delete")
            search.remove_owned_state(state, identity)
            self.assertTrue((state / "canary").exists())

    def test_unprivate_and_symlink_roots_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "target"
            target.mkdir(mode=0o755)
            with self.assertRaises(ValueError):
                search.private_state(target)
            alias = Path(root) / "alias"
            alias.symlink_to(target)
            with self.assertRaises(ValueError):
                search.private_state(alias)

    def test_owned_listener_cannot_be_rebound_and_adoption_is_exact(self):
        first = search.owned_listener()
        try:
            second = socket.socket()
            with contextlib.closing(second):
                with self.assertRaises(OSError):
                    second.bind(first.getsockname())
            duplicate = os.dup(first.fileno())
            os.set_inheritable(duplicate, True)
            adopted = search.adopt_listener(duplicate, first.getsockname()[1])
            self.assertEqual(adopted.fileno(), duplicate)
            self.assertFalse(adopted.get_inheritable())
            adopted.close()
            self.assertEqual(first.getsockname()[0], "127.0.0.1")
            duplicate = os.dup(first.fileno())
            try:
                with self.assertRaises(ValueError):
                    search.adopt_listener(duplicate, first.getsockname()[1] + 1)
            finally:
                os.close(duplicate)
        finally:
            first.close()

    def test_verified_manifest_rejects_tampering_extra_files_and_missing_acceptance(self):
        with tempfile.TemporaryDirectory() as root:
            payload = Path(root)
            executable = payload / "python/bin/python3"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture interpreter bytes")
            manifest = {"protocol": 1, "searxng_revision": search.SEARXNG_REVISION,
                        "waitress_version": search.WAITRESS_VERSION, "ddg_transient_patch_sha256": search.DDG_TRANSIENT_SHA256,
                        "native_boundary_verified": True,
                        "source_license_verified": True, "transient_cache_verified": True,
                        "searxng_waitress_compatibility_verified": True,
                        "files": [{"path": "python/bin/python3", "size": executable.stat().st_size,
                                   "sha256": search.hashlib.sha256(executable.read_bytes()).hexdigest()}]}
            path = payload / "search-runtime-manifest.json"
            def write():
                path.write_text(json.dumps(manifest))
            write()
            with mock.patch.object(search.sys, "executable", str(executable)):
                search.verify_payload(payload)
                manifest["protocol"] = True
                write()
                with self.assertRaises(search.SearchFailure):
                    search.verify_payload(payload)
                manifest["protocol"] = 1
                size = manifest["files"][0]["size"]
                for invalid in (True, -1, "24", 5_000_000_001):
                    manifest["files"][0]["size"] = invalid
                    write()
                    with self.assertRaises(search.SearchFailure):
                        search.verify_payload(payload)
                manifest["files"][0]["size"] = size
                for flag in ("native_boundary_verified", "source_license_verified", "transient_cache_verified",
                             "searxng_waitress_compatibility_verified"):
                    manifest[flag] = False
                    write()
                    with self.assertRaises(search.SearchFailure):
                        search.verify_payload(payload)
                    manifest[flag] = True
                write()
                unexpected = payload / "unexpected.py"
                unexpected.write_text("fixture")
                with self.assertRaises(search.SearchFailure):
                    search.verify_payload(payload)
                unexpected.unlink()
                executable.write_bytes(b"tampered interpreter bytes")
                with self.assertRaises(search.SearchFailure):
                    search.verify_payload(payload)

    def test_worker_lifeline_rejects_nonowned_process_group(self):
        read, write = os.pipe()
        try:
            with mock.patch.object(search.os, "getpgrp", return_value=-1):
                with self.assertRaises(search.SearchFailure):
                    search.watch_supervisor(read)
        finally:
            os.close(read)
            os.close(write)

    def test_production_fails_closed_without_a_payload(self):
        result = subprocess.run([sys.executable, "-I", "-B", str(HELPER), "--payload", "/absent-search-payload",
                                 "--state-root", "/unused-search-state"], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["reason"], "payload_unavailable")
        self.assertEqual(result.stderr, b"")


def read_event(process, timeout=8):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while time.monotonic() < deadline:
        if select.select([process.stdout], [], [], 0.1)[0]:
            piece = os.read(process.stdout.fileno(), 1)
            if not piece:
                raise AssertionError("helper exited before event")
            data.extend(piece)
            if piece == b"\n":
                return json.loads(data)
    raise AssertionError("helper event timed out")


def start_fixture(root, mode="normal", waitress=""):
    process = subprocess.Popen([sys.executable, "-I", "-B", str(Path(__file__).resolve()),
                                "supervisor", str(root), mode, waitress], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(b'{"protocol":1,"command":"start","generation":"fixture-generation"}\n')
    process.stdin.flush()
    return process


def finish_fixture(process):
    if process.stdin is not None and not process.stdin.closed:
        process.stdin.close()
    try:
        process.wait(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()


def request(event, path="/search", extra_headers=(), token=None, query="synthetic fixture"):
    port = urlsplit(event["endpoint"]).port
    token = event["capability"] if token is None else token
    body = form(query)
    with socket.create_connection(("127.0.0.1", port), timeout=3) as client:
        client.sendall((f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                        f"X-Dot-Search-Capability: {token}\r\nAccept: application/json\r\n"
                        "Content-Type: application/x-www-form-urlencoded; charset=utf-8\r\n"
                        f"Content-Length: {len(body)}\r\nConnection: close\r\n"
                        + "".join(f"{name}: {value}\r\n" for name, value in extra_headers)
                        + "\r\n").encode() + body)
        data = bytearray()
        while True:
            try:
                piece = client.recv(65536)
            except ConnectionResetError:
                if data:
                    return bytes(data)
                raise
            if not piece:
                return bytes(data)
            data.extend(piece)


class LifecycleTests(unittest.TestCase):
    def test_owned_http_eof_shutdown_and_state_removal(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root)
            try:
                ready = read_event(process)
                self.assertEqual(ready["event"], "ready")
                self.assertEqual(ready["helper_pid"], process.pid)
                self.assertEqual(ready["generation"], "fixture-generation")
                self.assertIn(b"200 OK", request(ready))
                self.assertIn(b"403 Forbidden", request(ready, token="b" * 64))
                process.stdin.close()
                self.assertEqual(read_event(process)["event"], "stopped")
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertEqual(list(Path(root).iterdir()), [])
                with self.assertRaises(OSError):
                    socket.create_connection(("127.0.0.1", urlsplit(ready["endpoint"]).port), timeout=0.2)
                self.assertEqual(process.stderr.read(), b"")
            finally:
                finish_fixture(process)

    def test_explicit_cancel_stops_listener_without_foreign_process_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            foreign = socket.socket()
            foreign.bind(("127.0.0.1", 0))
            foreign.listen()
            process = start_fixture(root)
            try:
                ready = read_event(process)
                self.assertNotEqual(urlsplit(ready["endpoint"]).port, foreign.getsockname()[1])
                process.stdin.write(b"cancel\n")
                process.stdin.flush()
                self.assertEqual(read_event(process)["event"], "stopped")
                process.wait(timeout=5)
                self.assertTrue(search.listener_is_listening(foreign))
            finally:
                foreign.close()
                finish_fixture(process)

    def test_two_instances_have_distinct_live_ports_capabilities_and_state(self):
        with tempfile.TemporaryDirectory() as root:
            first = start_fixture(root)
            second = start_fixture(root)
            try:
                one, two = read_event(first), read_event(second)
                self.assertNotEqual(one["endpoint"], two["endpoint"])
                self.assertNotEqual(one["capability"], two["capability"])
                self.assertEqual(len(list(Path(root).iterdir())), 2)
                self.assertIn(b"403 Forbidden", request(two, token=one["capability"]))
                first.stdin.close()
                first.wait(timeout=5)
                self.assertIn(b"200 OK", request(two))
            finally:
                finish_fixture(first)
                finish_fixture(second)

    def test_server_crash_is_reported_and_its_listener_is_closed(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root)
            try:
                ready = read_event(process)
                os.kill(ready["server_pid"], signal.SIGKILL)
                failure = read_event(process)
                self.assertEqual(failure["event"], "failed")
                self.assertIn(failure["reason"], ("server_exited", "invalid_worker"))
                self.assertEqual(process.wait(timeout=5), 2)
                self.assertEqual(list(Path(root).iterdir()), [])
            finally:
                finish_fixture(process)

    def test_eof_during_startup_does_not_wait_for_readiness_timeout(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root, "hang")
            try:
                time.sleep(0.2)
                started = time.monotonic()
                process.stdin.close()
                process.wait(timeout=5)
                self.assertLess(time.monotonic() - started, 3)
                self.assertEqual(list(Path(root).iterdir()), [])
            finally:
                finish_fixture(process)

    def test_supervisor_crash_closes_worker_lifeline_and_listener(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root)
            try:
                ready = read_event(process)
                process.kill()
                process.wait(timeout=5)
                port = urlsplit(ready["endpoint"]).port
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            time.sleep(0.02)
                    except OSError:
                        break
                else:
                    self.fail("worker listener survived supervisor crash")
            finally:
                finish_fixture(process)

    def test_descendant_ignoring_term_is_killed_with_only_owned_group(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root, "descendant")
            try:
                read_event(process)
                state = next(Path(root).iterdir())
                descendant = json.loads((state / "cache/descendant.json").read_text())
                with socket.create_connection(("127.0.0.1", descendant["port"]), timeout=1):
                    pass
                process.stdin.close()
                process.wait(timeout=5)
                with self.assertRaises(OSError):
                    socket.create_connection(("127.0.0.1", descendant["port"]), timeout=0.2)
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(descendant["pid"])], capture_output=True, text=True)
                self.assertTrue(not status.stdout.strip() or status.stdout.strip().startswith("Z"))
            finally:
                finish_fixture(process)

    def test_cancel_inflight_stops_request_and_next_launch_rejects_old_token(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root)
            result = []
            try:
                ready = read_event(process)
                def run_request():
                    try:
                        result.append(request(ready, query="fixture slow"))
                    except OSError:
                        result.append(b"cancelled")
                thread = threading.Thread(target=run_request)
                thread.start()
                time.sleep(0.1)
                process.stdin.close()
                process.wait(timeout=5)
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertNotIn(b"200 OK", b"".join(result))
                replacement = start_fixture(root)
                try:
                    new = read_event(replacement)
                    self.assertIn(b"403 Forbidden", request(new, token=ready["capability"]))
                    self.assertIn(b"200 OK", request(new))
                finally:
                    finish_fixture(replacement)
            finally:
                finish_fixture(process)

    @unittest.skipUnless(os.environ.get("DOT_SEARCH_WAITRESS_TEST_PATH"), "optional pinned Waitress fixture not provided")
    def test_pinned_waitress_real_socket_boundary(self):
        with tempfile.TemporaryDirectory() as root:
            process = start_fixture(root, waitress=os.environ["DOT_SEARCH_WAITRESS_TEST_PATH"])
            try:
                ready = read_event(process)
                self.assertIn(b"200 OK", request(ready))
                large = request(ready, query="fixture large")
                self.assertIn(b"200 OK", large)
                self.assertEqual(len(large.split(b"\r\n\r\n", 1)[1]), search.MAX_RESPONSE)
                for path in ("/%73earch", "//search", "/search?q=fixture", "/healthz"):
                    self.assertIn(b"404 Not Found", request(ready, path=path))
                for headers in ((('Origin', 'https://example.org'),), (('X-Forwarded-Host', 'example.org'),),
                                (('Cookie', 'fixture=1'),), (('Access-Control-Request-Method', 'POST'),)):
                    self.assertIn(b"403 Forbidden", request(ready, extra_headers=headers))
                self.assertIn(b"431 Request Header Fields Too Large", request(ready, extra_headers=(("X-Padding", "x" * 9000),)))
            finally:
                finish_fixture(process)


def fixture_main():
    command, root_or_listener, *args = sys.argv[1:]
    if command == "supervisor":
        mode, waitress = args
        def worker(listener, bootstrap, lifeline):
            return [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "worker", str(listener),
                    str(bootstrap), str(lifeline), mode, waitress]
        return search.supervise(root_or_listener, worker)
    listener_fd = int(root_or_listener)
    bootstrap_fd, lifeline_fd = int(args[0]), int(args[1])
    mode, waitress = args[2:]
    search.watch_supervisor(lifeline_fd)
    info = search.read_control_line(bootstrap_fd, 5)
    os.close(bootstrap_fd)
    listener = search.adopt_listener(listener_fd, info["port"])
    if mode == "descendant":
        code = ("import json,os,signal,socket,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); "
                "open('cache/descendant.json','w').write(json.dumps({'pid':os.getpid(),'port':s.getsockname()[1]})); "
                "time.sleep(120)")
        subprocess.Popen([sys.executable, "-I", "-B", "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while not Path("cache/descendant.json").exists():
            time.sleep(0.01)
    if mode == "hang":
        time.sleep(60)
    boundary = search.SearchBoundary(fixture_app, info["port"], info["capability"])
    if waitress:
        sys.path.insert(0, waitress)
        import importlib.metadata
        assert importlib.metadata.version("waitress") == search.WAITRESS_VERSION
        from waitress import create_server
        from waitress.buffers import TempfileBasedBuffer
        def forbidden_disk_buffer(self):
            raise AssertionError("search response spilled to disk")
        TempfileBasedBuffer.newfile = forbidden_disk_buffer
        server = create_server(boundary, **search.waitress_options(listener))
        search.send_event(sys.stdout.buffer, {"event": "serving"})
        server.run()
    else:
        from wsgiref.simple_server import WSGIServer, WSGIRequestHandler
        class Quiet(WSGIRequestHandler):
            def log_message(self, *_):
                pass
        server = WSGIServer(("127.0.0.1", info["port"]), Quiet, bind_and_activate=False)
        server.socket.close()
        server.socket = listener
        server.server_name = "127.0.0.1"
        server.server_port = info["port"]
        server.setup_environ()
        server.set_app(boundary)
        search.send_event(sys.stdout.buffer, {"event": "serving"})
        server.serve_forever(poll_interval=0.1)
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("supervisor", "worker"):
        raise SystemExit(fixture_main())
    unittest.main()
