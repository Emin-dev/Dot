#!/usr/bin/env python3
"""Owned search supervisor and restrictive WSGI gateway.

This module is independently fixture-testable with the Python standard library.
The production entry point requires a separately assembled and verified Search
payload. It never downloads packages, discovers a daemon, or changes Splash.
"""
from __future__ import annotations

import argparse
import email.utils
import errno
import hashlib
import hmac
import importlib.metadata
import io
import json
import logging
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qsl, urlencode

PROTOCOL = 1
WAITRESS_VERSION = "3.0.2"
SEARXNG_REVISION = "22c64b8d394b680c7ea96be25f36dad14126420a"
DDG_TRANSIENT_SHA256 = "e4683ebd1207d9011016123ba09f8dc72af19638f164304ef94d5349cb09489f"
ENGINES = ("duckduckgo",)
CAPABILITY_HEADER = "HTTP_X_DOT_SEARCH_CAPABILITY"
MAX_BODY = 16384
MAX_RESPONSE = 1048576
MAX_CONTROL = 2048
STARTUP_SECONDS = 30


class SearchFailure(Exception):
    """Only fixed public error codes cross the private control pipe."""


class NullWriter:
    def write(self, value):
        return len(value)

    def flush(self):
        pass


def strict_json(data):
    def reject_constant(_):
        raise ValueError("invalid_json")
    return json.loads(data, parse_constant=reject_constant)


def response(start_response, status, code, extra_headers=()):
    body = json.dumps({"error": code}, separators=(",", ":")).encode("ascii")
    start_response(status, [("Content-Type", "application/json"),
                            ("Content-Length", str(len(body))),
                            ("Cache-Control", "no-store"),
                            ("X-Content-Type-Options", "nosniff"), *extra_headers])
    return [body]


def validate_form(body):
    """Canonicalize an exact bounded form; reject parameter/engine overrides."""
    if not body or len(body) > MAX_BODY:
        raise ValueError("invalid_request")
    raw = body.decode("ascii")
    if re.search(r"%(?![0-9A-Fa-f]{2})", raw):
        raise ValueError("invalid_request")
    pairs = parse_qsl(raw, keep_blank_values=True, strict_parsing=True,
                      encoding="utf-8", errors="strict", max_num_fields=7)
    form = dict(pairs)
    if len(pairs) != 7 or len(form) != 7 or set(form) != {
        "q", "format", "categories", "pageno", "language", "safesearch", "engines"
    }:
        raise ValueError("invalid_request")
    if any(form[key] != value for key, value in {
        "format": "json", "categories": "general", "pageno": "1", "language": "auto",
        "safesearch": "1", "engines": ",".join(ENGINES)
    }.items()):
        raise ValueError("invalid_request")
    query = form["q"]
    if not query.strip() or len(query) >= 500 or len(query.encode("utf-8")) > 2048 or "\x00" in query:
        raise ValueError("invalid_request")
    # SearXNG's !engine/!category and !!external bang language is not this API.
    # keep_only and the post-import engine assertion remain the actual engine boundary.
    if re.search(r"(?:^|\s)!", query):
        raise ValueError("query_override")
    return urlencode(form, encoding="utf-8").encode("ascii")


class SearchBoundary:
    """One-route, authenticated, non-browser gateway around the pinned WSGI app."""

    def __init__(self, app, port, capability):
        if not 1 <= port <= 65535 or not re.fullmatch(r"[0-9a-f]{64}", capability):
            raise ValueError("invalid_boundary")
        self.app = app
        self.host = f"127.0.0.1:{port}"
        self.capability = capability.encode("ascii")
        self.admission = threading.Lock()

    def __call__(self, environ, start_response):
        # No middleware may rewrite these values from untrusted proxy headers.
        if (environ.get("REMOTE_ADDR") != "127.0.0.1"
                or environ.get("HTTP_HOST") != self.host
                or environ.get("wsgi.url_scheme") != "http"):
            return response(start_response, "403 Forbidden", "forbidden")
        if any(key in environ for key in (
            "HTTP_ORIGIN", "HTTP_ACCESS_CONTROL_REQUEST_METHOD", "HTTP_ACCESS_CONTROL_REQUEST_HEADERS",
            "HTTP_FORWARDED", "HTTP_X_FORWARDED_HOST", "HTTP_X_FORWARDED_FOR",
            "HTTP_X_FORWARDED_PROTO", "HTTP_COOKIE", "HTTP_AUTHORIZATION", "HTTP_TRANSFER_ENCODING"
        )):
            return response(start_response, "403 Forbidden", "forbidden")
        token = environ.get(CAPABILITY_HEADER, "")
        if not isinstance(token, str) or not hmac.compare_digest(token.encode("utf-8"), self.capability):
            return response(start_response, "403 Forbidden", "forbidden")
        if (environ.get("REQUEST_METHOD") != "POST" or environ.get("PATH_INFO") != "/search"
                or environ.get("SCRIPT_NAME", "") or environ.get("QUERY_STRING", "")):
            return response(start_response, "404 Not Found", "invalid_route")
        # WSGI PATH_INFO may have been unquoted. Check the raw target when supplied by Waitress.
        if environ.get("REQUEST_URI", "/search") != "/search":
            return response(start_response, "404 Not Found", "invalid_route")
        if (environ.get("CONTENT_TYPE") != "application/x-www-form-urlencoded; charset=utf-8"
                or environ.get("HTTP_ACCEPT") != "application/json"
                or "HTTP_CONTENT_ENCODING" in environ):
            return response(start_response, "415 Unsupported Media Type", "invalid_content_type")
        length = environ.get("CONTENT_LENGTH", "")
        if not isinstance(length, str) or not re.fullmatch(r"[1-9][0-9]{0,4}", length):
            return response(start_response, "400 Bad Request", "invalid_length")
        if int(length) > MAX_BODY:
            return response(start_response, "413 Payload Too Large", "request_too_large")
        if not self.admission.acquire(blocking=False):
            return response(start_response, "429 Too Many Requests", "busy", [("Retry-After", "1")])
        try:
            body = environ["wsgi.input"].read(int(length))
            if len(body) != int(length):
                return response(start_response, "400 Bad Request", "invalid_length")
            try:
                canonical = validate_form(body)
            except (ValueError, UnicodeError):
                return response(start_response, "400 Bad Request", "invalid_request")
            # Do not pass capability, ambient cookies, headers or error writers to SearXNG.
            inner = {key: value for key, value in environ.items() if not key.startswith("HTTP_")}
            inner.update({"HTTP_HOST": self.host, "HTTP_ACCEPT": "application/json",
                          "wsgi.input": io.BytesIO(canonical), "wsgi.errors": NullWriter(),
                          "CONTENT_LENGTH": str(len(canonical))})
            return self._run(inner, start_response)
        except Exception:
            return response(start_response, "502 Bad Gateway", "upstream_failure")
        finally:
            self.admission.release()

    def _run(self, environ, start_response):
        captured = {}
        output = bytearray()

        def append(data):
            if not isinstance(data, bytes) or len(output) + len(data) > MAX_RESPONSE:
                raise ValueError("invalid_response")
            output.extend(data)

        def capture(status, headers, exc_info=None):
            if captured and not exc_info:
                raise ValueError("duplicate_response")
            captured.update(status=status, headers=headers)
            return append

        iterator = self.app(environ, capture)
        try:
            for chunk in iterator:
                append(chunk)
        finally:
            close = getattr(iterator, "close", None)
            if close is not None:
                close()
        status = captured.get("status", "")
        headers = captured.get("headers", [])
        if not isinstance(status, str) or not re.fullmatch(r"[1-5][0-9]{2} [\x20-\x7e]+", status):
            raise ValueError("invalid_status")
        number = int(status[:3])
        if number != 200:
            # No Location, Set-Cookie, CORS, external bangs, HTML or diagnostic bodies escape.
            extras = []
            if number in (429, 503):
                for name, value in headers:
                    if name.lower() == "retry-after" and isinstance(value, str) and len(value) <= 128:
                        valid = re.fullmatch(r"[0-9]{1,10}", value)
                        if not valid:
                            try:
                                valid = email.utils.parsedate_to_datetime(value) is not None
                            except (ValueError, TypeError, OverflowError):
                                valid = False
                        if valid and "\r" not in value and "\n" not in value:
                            extras = [("Retry-After", value)]
                        break
            safe_status = {403: "403 Forbidden", 429: "429 Too Many Requests", 503: "503 Service Unavailable"}
            return response(start_response, safe_status.get(number, "502 Bad Gateway"), "upstream_failure", extras)
        content_types = [value for name, value in headers if name.lower() == "content-type"]
        if len(content_types) != 1 or content_types[0].split(";", 1)[0].strip().lower() != "application/json":
            raise ValueError("invalid_content_type")
        envelope = strict_json(output)
        if not isinstance(envelope, dict) or "error" in envelope or "errors" in envelope or not isinstance(envelope.get("results"), list):
            raise ValueError("invalid_envelope")
        if len(envelope["results"]) > 512:
            raise ValueError("invalid_envelope")
        # Suppress reflected query, answers, infoboxes and library diagnostics. Preserve
        # warning structure for the adapter's deliberately conservative coverage parser.
        reduced = {"results": [{key: item[key] for key in (
            "url", "title", "content", "publishedDate", "engines"
        ) if key in item} if isinstance(item, dict) else None for item in envelope["results"]]}
        if "unresponsive_engines" in envelope:
            reduced["unresponsive_engines"] = envelope["unresponsive_engines"]
        encoded = json.dumps(reduced, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        if len(encoded) > MAX_RESPONSE:
            raise ValueError("invalid_response")
        start_response("200 OK", [("Content-Type", "application/json"),
                                   ("Content-Length", str(len(encoded))),
                                   ("Cache-Control", "no-store"),
                                   ("X-Content-Type-Options", "nosniff")])
        return [encoded]


def owned_listener():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        # No SO_REUSEPORT and no close/rebind handoff. Both owners hold the same socket.
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        return listener
    except BaseException:
        listener.close()
        raise


def adopt_listener(descriptor, port):
    listener = socket.socket(fileno=descriptor)
    if (listener.family != socket.AF_INET or listener.type != socket.SOCK_STREAM
            or listener.getsockname() != ("127.0.0.1", port)
            or not listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN)):
        listener.detach()
        raise ValueError("invalid_listener")
    listener.set_inheritable(False)
    return listener


def child_exited(child):
    """Observe without reaping: the owned leader anchors its process-group identity."""
    if child.returncode is not None:
        raise ChildProcessError("already_reaped")
    if hasattr(os, "waitid"):
        return os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
    if not hasattr(select, "kqueue"):
        raise RuntimeError("process_observation_unavailable")
    queue = select.kqueue()
    try:
        event = select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                              flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
        try:
            events = queue.control([event], 1, 0)
        except ProcessLookupError:
            return True
        for item in events:
            if item.flags & select.KQ_EV_ERROR:
                if item.data == errno.ESRCH:
                    return True
                raise OSError(item.data, "process_observation_failed")
            if item.fflags & select.KQ_NOTE_EXIT:
                return True
        return False
    finally:
        queue.close()


def stop_group(child):
    if child.returncode is not None:
        raise ChildProcessError("unsafe_reaped_group")
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            break
        except PermissionError as error:
            if sys.platform != "darwin" or error.errno != errno.EPERM or not child_exited(child):
                raise
        if sig == signal.SIGTERM:
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline and not child_exited(child):
                time.sleep(0.02)
    # Reap only after the final nonzero group signal, never kill a reused PID.
    child.wait()


def private_state(root):
    root = Path(root)
    if not root.is_absolute() or root.is_symlink():
        raise ValueError("invalid_state_root")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = root.stat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077):
        raise ValueError("private_state_required")
    state = Path(tempfile.mkdtemp(prefix="launch-", dir=root))
    identity = state.stat()
    for name in ("home", "cache", "config", "tmp"):
        (state / name).mkdir(mode=0o700)
    return state, (identity.st_dev, identity.st_ino)


def remove_owned_state(state, identity):
    try:
        current = state.lstat()
        if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == identity:
            shutil.rmtree(state)
    except FileNotFoundError:
        pass


def settings_text(port, secret):
    # Values interpolated here are helper-generated only. Query input never enters YAML.
    if not 1 <= port <= 65535 or not re.fullmatch(r"[0-9a-f]{64}", secret):
        raise ValueError("invalid_settings")
    return f'''use_default_settings:
  engines:
    keep_only: [duckduckgo]
plugins: {{}}
general:
  debug: false
  enable_metrics: false
search:
  formats: [json]
  autocomplete: ""
  favicon_resolver: ""
  default_lang: "auto"
  max_page: 1
  safe_search: 1
server:
  bind_address: "127.0.0.1"
  port: {port}
  secret_key: "{secret}"
  limiter: false
  public_instance: false
  image_proxy: false
valkey:
  url: false
outgoing:
  request_timeout: 8.0
  max_request_timeout: 12.0
engines:
  - name: duckduckgo
    disabled: false
'''


def clean_environment(state):
    return {"PATH": "/usr/bin:/bin", "HOME": str(state / "home"),
            "TMPDIR": str(state / "tmp"), "XDG_CACHE_HOME": str(state / "cache"),
            "XDG_CONFIG_HOME": str(state / "config"), "XDG_DATA_HOME": str(state / "cache"),
            "SEARXNG_SETTINGS_PATH": str(state / "config/settings.yml"),
            "SEARXNG_DISABLE_ETC_SETTINGS": "1",
            "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "LANG": "en_US.UTF-8"}


def send_event(stream, value):
    data = json.dumps({"protocol": PROTOCOL, **value}, separators=(",", ":")).encode("ascii") + b"\n"
    if len(data) > MAX_CONTROL:
        raise ValueError("invalid_control")
    stream.write(data)
    stream.flush()


def read_control_line(descriptor, timeout, stop_requested=lambda: False):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if stop_requested():
            raise SearchFailure("cancelled")
        if not select.select([descriptor], [], [], 0.1)[0]:
            continue
        piece = os.read(descriptor, 1)
        if not piece:
            raise SearchFailure("parent_closed")
        data.extend(piece)
        if len(data) > MAX_CONTROL:
            raise SearchFailure("invalid_control")
        if piece == b"\n":
            return strict_json(data)
    raise SearchFailure("startup_timeout")


def supervise(state_root, worker_command, control_in=None, events_out=None):
    """worker_command(listener_fd, bootstrap_fd, lifeline_fd) supports local fixtures."""
    control_in = sys.stdin.buffer if control_in is None else control_in
    events_out = sys.stdout.buffer if events_out is None else events_out
    stopped = False

    def request_stop(*_):
        nonlocal stopped
        stopped = True

    old_signals = {sig: signal.signal(sig, request_stop) for sig in (signal.SIGINT, signal.SIGTERM)}
    state = listener = child = None
    bootstrap_r = bootstrap_w = lifeline_r = lifeline_w = None
    generation = None
    reason = "startup_failed"
    try:
        start = read_control_line(control_in.fileno(), STARTUP_SECONDS, lambda: stopped)
        if (not isinstance(start, dict) or set(start) != {"protocol", "command", "generation"}
                or type(start["protocol"]) is not int or start["protocol"] != PROTOCOL
                or start["command"] != "start" or not isinstance(start["generation"], str)
                or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", start["generation"])):
            raise SearchFailure("invalid_control")
        generation = start["generation"]
        state, identity = private_state(state_root)
        listener = owned_listener()
        port = listener.getsockname()[1]
        capability = secrets.token_hex(32)
        settings = state / "config/settings.yml"
        descriptor = os.open(settings, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(settings_text(port, secrets.token_hex(32)))
        bootstrap_r, bootstrap_w = os.pipe()
        lifeline_r, lifeline_w = os.pipe()
        child = subprocess.Popen(worker_command(listener.fileno(), bootstrap_r, lifeline_r),
                                 pass_fds=(listener.fileno(), bootstrap_r, lifeline_r),
                                 start_new_session=True, close_fds=True, cwd=state,
                                 env=clean_environment(state), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        os.close(bootstrap_r)
        bootstrap_r = None
        os.close(lifeline_r)
        lifeline_r = None
        with os.fdopen(bootstrap_w, "wb") as output:
            bootstrap_w = None
            send_event(output, {"port": port, "capability": capability})
        def startup_cancelled():
            return stopped or bool(select.select([control_in.fileno()], [], [], 0)[0])
        worker_ready = read_control_line(child.stdout.fileno(), STARTUP_SECONDS, startup_cancelled)
        if worker_ready != {"protocol": PROTOCOL, "event": "serving"}:
            raise SearchFailure("invalid_worker")
        if child_exited(child):
            raise SearchFailure("server_exited")
        send_event(events_out, {"event": "ready", "generation": generation,
                               "endpoint": f"http://127.0.0.1:{port}/search",
                               "capability": capability, "helper_pid": os.getpid(), "server_pid": child.pid})
        reason = "stopped"
        while not stopped:
            if child_exited(child):
                raise SearchFailure("server_exited")
            if select.select([control_in.fileno(), child.stdout.fileno()], [], [], 0.1)[0]:
                # Any parent byte/EOF cancels. Any further worker output is a protocol failure.
                readable = select.select([control_in.fileno(), child.stdout.fileno()], [], [], 0)[0]
                if control_in.fileno() in readable:
                    os.read(control_in.fileno(), 1)
                    break
                raise SearchFailure("invalid_worker")
    except SearchFailure as error:
        reason = "stopped" if str(error) == "cancelled" else str(error)
    except (OSError, ValueError, TypeError):
        reason = "startup_failed"
    finally:
        try:
            if child is not None:
                stop_group(child)
        finally:
            if child is not None and child.stdout is not None:
                child.stdout.close()
            for descriptor in (bootstrap_r, bootstrap_w, lifeline_r, lifeline_w):
                if descriptor is not None:
                    os.close(descriptor)
            if listener is not None:
                listener.close()
            if state is not None:
                remove_owned_state(state, identity)
            for sig, old in old_signals.items():
                signal.signal(sig, old)
    if reason != "stopped":
        send_event(events_out, {"event": "failed", "generation": generation, "reason": reason})
        return 2
    send_event(events_out, {"event": "stopped", "generation": generation})
    return 0


def watch_supervisor(descriptor):
    """A separate pipe remains open only in the supervisor, even after app exit."""
    if (os.getpgrp() != os.getpid() or os.getsid(0) != os.getpid()
            or descriptor < 3 or not stat.S_ISFIFO(os.fstat(descriptor).st_mode)):
        raise SearchFailure("invalid_worker")
    def monitor():
        try:
            while os.read(descriptor, 1):
                pass
        finally:
            # This worker is its own session/group leader. Never target another PID.
            os.killpg(os.getpgrp(), signal.SIGKILL)
    threading.Thread(target=monitor, name="search-lifeline", daemon=True).start()


def waitress_options(listener):
    # Waitress normally spills >=1 MiB output buffers into temporary disk files.
    # Disable disk rollover while keeping bounded output and channel backpressure.
    return {"sockets": [listener], "threads": 1, "connection_limit": 8,
            "max_request_header_size": 8192, "max_request_body_size": MAX_BODY,
            "inbuf_overflow": MAX_BODY + 1, "outbuf_overflow": sys.maxsize,
            "outbuf_high_watermark": 2 * MAX_RESPONSE,
            "channel_timeout": 15, "cleanup_interval": 1, "channel_request_lookahead": 0,
            "clear_untrusted_proxy_headers": False, "trusted_proxy": None,
            "expose_tracebacks": False, "ident": "dot-search"}


def serve_production(listener_fd, bootstrap_fd, lifeline_fd):
    if len({listener_fd, bootstrap_fd, lifeline_fd}) != 3 or min(listener_fd, bootstrap_fd, lifeline_fd) < 3:
        raise SearchFailure("invalid_worker")
    watch_supervisor(lifeline_fd)
    bootstrap = read_control_line(bootstrap_fd, STARTUP_SECONDS)
    os.close(bootstrap_fd)
    if not isinstance(bootstrap, dict) or set(bootstrap) != {"protocol", "port", "capability"} or bootstrap["protocol"] != PROTOCOL:
        raise SearchFailure("invalid_control")
    listener = adopt_listener(listener_fd, bootstrap["port"])
    # Library output cannot contaminate private readiness or disclose query diagnostics.
    events = os.fdopen(os.dup(sys.stdout.fileno()), "wb")
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), sys.stdout.fileno())
        os.dup2(sink.fileno(), sys.stderr.fileno())
    logging.disable(logging.CRITICAL)
    if importlib.metadata.version("waitress") != WAITRESS_VERSION:
        raise SearchFailure("payload_unverified")
    from searx.webapp import app
    from searx.engines import engines
    if set(engines) != set(ENGINES):
        raise SearchFailure("engine_boundary_failed")
    engine_source = Path(engines["duckduckgo"].__file__)
    if hashlib.sha256(engine_source.read_bytes()).hexdigest() != DDG_TRANSIENT_SHA256:
        raise SearchFailure("transient_cache_patch_missing")
    from waitress import create_server
    server = create_server(SearchBoundary(app, bootstrap["port"], bootstrap["capability"]),
                           **waitress_options(listener))
    send_event(events, {"event": "serving"})
    try:
        server.run()
    finally:
        events.close()


def verify_payload(payload):
    """Reject missing/unreviewed payloads, alternate interpreters and incomplete hashes.

    Native isolation and source/license acceptance are assembly gates, not facts
    created by this code. No completed manifest is shipped by this source slice.
    """
    payload = Path(payload).resolve(strict=True)
    manifest_path = payload / "search-runtime-manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink() or manifest_path.stat().st_size > 4 * 1024 * 1024:
        raise SearchFailure("payload_unverified")
    manifest = strict_json(manifest_path.read_bytes())
    if (not isinstance(manifest, dict) or type(manifest.get("protocol")) is not int or manifest.get("protocol") != PROTOCOL
            or manifest.get("searxng_revision") != SEARXNG_REVISION
            or manifest.get("waitress_version") != WAITRESS_VERSION
            or manifest.get("ddg_transient_patch_sha256") != DDG_TRANSIENT_SHA256
            or manifest.get("native_boundary_verified") is not True
            or manifest.get("source_license_verified") is not True
            or manifest.get("transient_cache_verified") is not True
            or manifest.get("searxng_waitress_compatibility_verified") is not True
            or not Path(sys.executable).resolve().is_relative_to(payload)):
        raise SearchFailure("payload_unverified")
    files = manifest.get("files")
    if not isinstance(files, list) or not files or len(files) > 50000:
        raise SearchFailure("payload_unverified")
    covered = set()
    for item in files:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "size"}:
            raise SearchFailure("payload_unverified")
        name = item["path"]
        if (type(item["size"]) is not int or not 0 <= item["size"] <= 5_000_000_000
                or not isinstance(item["sha256"], str)
                or not isinstance(name, str) or not name or name in covered or Path(name).is_absolute()
                or any(part in (".", "..") for part in name.split("/"))
                or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])):
            raise SearchFailure("payload_unverified")
        path = payload / name
        if path.is_symlink() or not path.resolve().is_relative_to(payload) or not path.is_file():
            raise SearchFailure("payload_unverified")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        if path.stat().st_size != item["size"] or digest.hexdigest() != item["sha256"]:
            raise SearchFailure("payload_unverified")
        covered.add(name)
    actual = set()
    for path in payload.rglob("*"):
        if path.is_symlink():
            raise SearchFailure("payload_unverified")
        if path.is_file() and path != manifest_path:
            actual.add(path.relative_to(payload).as_posix())
    if covered != actual or not Path(sys.executable).resolve().relative_to(payload).as_posix() in covered:
        raise SearchFailure("payload_unverified")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload")
    parser.add_argument("--state-root")
    parser.add_argument("--serve", nargs=3, type=int, metavar=("LISTENER", "BOOTSTRAP", "LIFELINE"))
    args = parser.parse_args()
    if args.serve is not None:
        if args.payload or args.state_root:
            raise SearchFailure("invalid_control")
        return serve_production(*args.serve)
    if not args.payload or not args.state_root:
        raise SearchFailure("payload_unverified")
    verify_payload(args.payload)
    def command(listener, bootstrap, lifeline):
        return [sys.executable, "-I", "-B", "-X", "pycache_prefix=.python-cache",
                str(Path(__file__).resolve()), "--serve",
                str(listener), str(bootstrap), str(lifeline)]
    return supervise(args.state_root, command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        send_event(sys.stdout.buffer, {"event": "failed", "reason": "payload_unavailable"})
        raise SystemExit(2)
