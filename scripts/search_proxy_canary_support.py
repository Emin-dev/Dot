"""Shared BUILD-ONLY native canary support. No imports execute a target binary."""
from pathlib import Path, PurePosixPath
import argparse
import errno
import hashlib
import json
import os
import platform
import re
import select
import socket
import stat
import subprocess
import sys
import threading
import time


def sha_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_source_lock(path, assembly_lock_sha256):
    """Bind parsed lock semantics and exact file bytes to distinct digest domains."""
    data = Path(path).read_bytes()
    lock = json.loads(data)
    # Match scripts/search_payload.py's assembly receipt writer exactly. Parse
    # and hash the same read so reported raw provenance describes this object.
    canonical = hashlib.sha256(json.dumps(lock, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if canonical != assembly_lock_sha256:
        raise ValueError("exact payload lock differs from canary lock")
    return lock, {"lock_sha256": canonical, "lock_file_sha256": hashlib.sha256(data).hexdigest()}


def fixture_hashes(root, relative_paths):
    return {name: sha_file(Path(root) / name) for name in relative_paths}


def require_native():
    if sys.platform != "darwin" or platform.machine() != "arm64":
        print("SKIP: native Search proxy canaries require exact macOS arm64 and independent unaccepted payload; no native execution performed")
        raise SystemExit(77)


def native_host_identity():
    require_native()
    return {"os": sys.platform, "architecture": platform.machine(),
            "macos_version": platform.mac_ver()[0], "kernel_release": platform.release(),
            "kernel_version": platform.version(),
            "macos_build": subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip()}


def parse_args(description):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--search-payload", type=Path, required=True)
    parser.add_argument("--expected-receipt-sha256", required=True,
                        help="previously reviewed SHA-256 of evidence/assembly-input-receipt.json")
    return parser.parse_args()


def verify_payload(path, expected_receipt_sha256):
    """Verify an exact unaccepted tree without importing or executing its code."""
    if not re.fullmatch(r"[a-f0-9]{64}", expected_receipt_sha256):
        raise ValueError("expected receipt SHA-256 must be 64 lowercase hexadecimal digits")
    source = Path(path).absolute()
    payload = source.resolve(strict=True)
    if source != payload or not payload.is_dir() or ".app" in {part[-4:] for part in payload.parts}:
        raise ValueError("require canonical independent payload outside an app bundle")
    receipt_path = payload / "evidence/assembly-input-receipt.json"
    if receipt_path.is_symlink() or sha_file(receipt_path) != expected_receipt_sha256:
        raise ValueError("unaccepted assembly receipt does not match reviewed identity")
    receipt = json.loads(receipt_path.read_text())
    if receipt.get("schema") != 1 or receipt.get("status") != "unaccepted-static-assembly" or receipt.get("native_executed") is not False:
        raise ValueError("only an independent unaccepted static assembly is supported")
    if not re.fullmatch(r"[a-f0-9]{64}", str(receipt.get("lock_sha256", ""))):
        raise ValueError("assembly must identify its exact source lock")
    expected = {}
    for item in receipt.get("files", []):
        name = item["path"]
        parts = PurePosixPath(name)
        if not name or parts.is_absolute() or ".." in parts.parts or str(parts) != name or name in expected:
            raise ValueError("unsafe or duplicate receipt path")
        if not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]) or type(item["size"]) is not int or item["size"] < 0:
            raise ValueError("invalid assembly file record")
        expected[name] = item
    if "python/bin/python3" not in expected or "dot_search.py" not in expected:
        raise ValueError("independent Search interpreter/helper absent from receipt")
    actual = set()
    for entry in payload.rglob("*"):
        info = entry.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("payload contains a symlink")
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("payload contains a special file or multiply linked file")
        name = entry.relative_to(payload).as_posix()
        if entry.name in ("search-runtime-manifest.json", "search-acceptance.json"):
            raise ValueError("production admission files are not allowed in a build-only input")
        if name == "evidence/assembly-input-receipt.json":
            continue
        actual.add(name)
        item = expected.get(name)
        if item is None or info.st_size != item["size"] or sha_file(entry) != item["sha256"]:
            raise ValueError("payload differs from unaccepted receipt: " + name)
    if actual != set(expected):
        raise ValueError("receipt files are missing from unaccepted payload")
    records = [{"path": name, "sha256": expected[name]["sha256"], "size": expected[name]["size"]} for name in sorted(expected)]
    # Defined digest: SHA-256 of canonical JSON records, sorted by relative path.
    tree_hash = hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return payload, {"assembly_receipt_sha256": expected_receipt_sha256,
                     "assembly_lock_sha256": receipt["lock_sha256"],
                     "interpreter_sha256": expected["python/bin/python3"]["sha256"],
                     "payload_tree_sha256": tree_hash, "payload_file_count": len(records),
                     "tree_hash_format": "sha256(canonical-json-sort_keys-compact(sorted-path-size-sha256-records))"}


def minimal_env(state):
    return {"PATH": "/usr/bin:/bin", "HOME": str(state), "TMPDIR": str(state),
            "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}


def fixture_directories(base):
    state, outside, inference = [base / name for name in ('state ü "fixture', "Documents", "Offline")]
    for directory in (state, outside, inference):
        directory.mkdir(mode=0o700)
    (outside / "private.fixture").write_bytes(b"synthetic-private")
    (inference / "model.fixture").write_bytes(b"synthetic-model")
    (state / "escape").symlink_to(outside / "private.fixture")
    return state, outside, inference


def owned_listener():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        server.bind(("127.0.0.1", 0))
        server.listen(4)
        assert server.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR) == 0
        assert server.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT) == 0
        return server
    except BaseException:
        server.close()
        raise


def assert_owned(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as competitor:
        try:
            competitor.bind(("127.0.0.1", port))
        except OSError as error:
            assert error.errno == errno.EADDRINUSE, repr(error)
        else:
            raise AssertionError("listener lost continuous ownership")


def receive(sock, length):
    data = bytearray()
    while len(data) < length:
        part = sock.recv(length - len(data))
        assert part, "short synthetic socket frame"
        data.extend(part)
    return bytes(data)


PROBE_PROGRESS_FILE = ".dot-search-canary-progress-v1"
PROBE_PROGRESS_LIMIT = 1024
PROBE_PROGRESS_STAGES = (
    'helper-entry',
    'imports-complete',
    'fixture-validated',
    'file-probes-complete',
    'shell-denial-complete',
    'child-cleanup-complete',
    'listener-validated',
    'socket-denials-complete',
    'egress-reconnect-complete',
    'control-start-validated',
    'ready-emitted',
    'inbound-exchange-complete',
    'control-eof-observed',
    'stopped-emitted',
)


def read_probe_progress(state):
    """Read only a bounded fixed-label prefix; never emit file bytes or paths."""
    result = {"status": "unavailable", "last_observed_stage": None, "stage_count": 0}
    directory_fd = descriptor = None
    try:
        root = Path(state)
        if root != root.resolve(strict=True):
            result["status"] = "invalid"
            return result
        directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        directory = os.fstat(directory_fd)
        if not stat.S_ISDIR(directory.st_mode) or stat.S_IMODE(directory.st_mode) != 0o700 or directory.st_uid != os.geteuid():
            result["status"] = "invalid"
            return result
        descriptor = os.open(PROBE_PROGRESS_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                             dir_fd=directory_fd)
        node = os.fstat(descriptor)
        if (not stat.S_ISREG(node.st_mode) or node.st_nlink != 1 or node.st_uid != os.geteuid()
                or stat.S_IMODE(node.st_mode) != 0o600 or not 0 < node.st_size <= PROBE_PROGRESS_LIMIT):
            result["status"] = "invalid"
            return result
        data = os.read(descriptor, PROBE_PROGRESS_LIMIT + 1)
        after = os.fstat(descriptor)
        if (len(data) != node.st_size or after.st_size != node.st_size or after.st_mtime_ns != node.st_mtime_ns
                or after.st_ctime_ns != node.st_ctime_ns):
            result["status"] = "invalid"
            return result
        for count in range(1, len(PROBE_PROGRESS_STAGES) + 1):
            expected = ("\n".join(PROBE_PROGRESS_STAGES[:count]) + "\n").encode("ascii")
            if data == expected:
                return {"status": "observed", "last_observed_stage": PROBE_PROGRESS_STAGES[count - 1], "stage_count": count}
        result["status"] = "invalid"
    except OSError as error:
        if error.errno == errno.ENOENT:
            result["status"] = "absent"
        elif error.errno in (errno.ELOOP, errno.ENOTDIR):
            result["status"] = "invalid"
    except (ValueError, RuntimeError):
        result["status"] = "invalid"
    finally:
        for opened in (descriptor, directory_fd):
            if opened is not None:
                try:
                    os.close(opened)
                except OSError:
                    pass
    return result


def event_failure(process, stage, reason, *, stdout_bytes=0, settle=False, progress_state=None):
    """Report observations only; never print child output, argv, paths or env.

    EOF can race waitpid. Give an already-closing child a bounded settlement
    window, but distinguish a still-running child from an observed exit. Never
    attribute the later cleanup kill to the original failure.
    """
    stages = {kind + "-" + phase for kind in ("native", "profile")
              for phase in ("send-start", "await-ready", "await-stopped", "wait-exit")}
    reasons = {"stdout-eof", "event-timeout", "oversized-event", "invalid-event",
               "control-pipe-closed", "nonzero-exit"}
    if stage not in stages or reason not in reasons:
        raise ValueError("unknown fixed canary diagnostic stage or reason")
    if settle:
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
    returncode = process.poll()
    # Even an exited direct child may have descendants holding stderr open.
    # One readiness check and one raw read cannot wait for their pipe EOF.
    stderr_bytes = 0
    if select.select([process.stderr], [], [], 0)[0]:
        stderr_bytes = len(os.read(process.stderr.fileno(), 4096))
    diagnostic = {"kind": "build-only-native-canary-failure", "controller_stage": stage,
        "reason": reason, "returncode": returncode,
        "exit_status": returncode if returncode is not None and returncode >= 0 else None,
        "signal": -returncode if returncode is not None and returncode < 0 else None,
        "stdout_bytes_observed": stdout_bytes, "stderr_bytes_sampled": stderr_bytes,
        "stderr_sample_limit": 4096, "production_acceptance": False}
    if progress_state is not None:
        diagnostic["probe_progress"] = read_probe_progress(progress_state)
    return AssertionError("native canary failed: " + json.dumps(diagnostic, sort_keys=True))


def event(process, timeout=35, *, stage="native-await-ready", progress_state=None):
    deadline, data = time.monotonic() + timeout, bytearray()
    while time.monotonic() < deadline:
        if select.select([process.stdout], [], [], min(0.1, max(0, deadline - time.monotonic())))[0]:
            part = os.read(process.stdout.fileno(), 1)
            if not part:
                raise event_failure(process, stage, "stdout-eof", stdout_bytes=len(data), settle=True, progress_state=progress_state)
            data.extend(part)
            if len(data) > 4096:
                raise event_failure(process, stage, "oversized-event", stdout_bytes=len(data), progress_state=progress_state)
            if part == b"\n":
                try:
                    return json.loads(data)
                except (ValueError, UnicodeError):
                    raise event_failure(process, stage, "invalid-event", stdout_bytes=len(data), progress_state=progress_state) from None
    raise event_failure(process, stage, "event-timeout", stdout_bytes=len(data), progress_state=progress_state)


def drive_probe(command, payload, state, outside, inference, foreign, egress, *, pass_fds=(), env=None, probe_kind="native"):
    """Parents hold all fixture endpoints continuously until child settlement."""
    if probe_kind not in ("native", "profile"):
        raise ValueError("unknown fixed canary probe kind")
    # Never consume a pre-existing file as this invocation's progress.
    if os.path.lexists(Path(state) / PROBE_PROGRESS_FILE):
        raise AssertionError("native canary progress path already exists")
    failures = []
    egress_port = egress.getsockname()[1]
    assert_owned(egress_port)
    (state / "fixture.json").write_text(json.dumps({"outside": str(outside), "inference": str(inference),
        "foreign_port": foreign.getsockname()[1], "egress_port": egress_port}))

    def echo():
        try:
            egress.settimeout(35)
            for sequence in range(2):
                client, peer = egress.accept()
                with client:
                    client.settimeout(5)
                    assert peer[0] == "127.0.0.1"
                    assert receive(client, 7) == b"egress" + bytes([sequence])
                    client.sendall(b"reply")
        except BaseException as error:
            failures.append(repr(error))

    thread = threading.Thread(target=echo, name="owned-synthetic-egress")
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=state, env=env if env is not None else minimal_env(state), pass_fds=pass_fds)
    thread.start()
    try:
        try:
            process.stdin.write(b'{"protocol":1,"command":"start","generation":"native-canary"}\n')
            process.stdin.flush()
        except BrokenPipeError:
            raise event_failure(process, probe_kind + "-send-start", "control-pipe-closed", settle=True, progress_state=state) from None
        ready = event(process, stage=probe_kind + "-await-ready", progress_state=state)
        assert ready["event"] == "native_canary_ready" and ready["pid"] == process.pid, "unexpected native canary ready event"
        assert_owned(ready["port"])
        assert_owned(egress_port)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(("127.0.0.1", ready["port"]))
            client.sendall(b"fixture")
            assert receive(client, 5) == b"reply"
        process.stdin.close()
        assert event(process, timeout=10, stage=probe_kind + "-await-stopped", progress_state=state) == {"event": "native_canary_stopped"}
        if process.wait(timeout=5) != 0:
            raise event_failure(process, probe_kind + "-wait-exit", "nonzero-exit", progress_state=state)
        assert process.stderr.read() == b""
        thread.join(timeout=5)
        assert not thread.is_alive() and not failures, failures
        assert_owned(egress_port)
        # A permission error is required in the child; this is independent proof
        # no forbidden loopback connection actually reached the held listener.
        foreign.setblocking(False)
        try:
            extra, _ = foreign.accept()
        except BlockingIOError:
            pass
        else:
            extra.close()
            raise AssertionError("unrelated loopback listener received a connection")
        assert (outside / "private.fixture").read_bytes() == b"synthetic-private"
        assert (inference / "model.fixture").read_bytes() == b"synthetic-model"
        assert not any((directory / "write.fixture").exists() for directory in (outside, inference, payload))
        progress = read_probe_progress(state)
        assert progress == {"status": "observed", "last_observed_stage": PROBE_PROGRESS_STAGES[-1],
                            "stage_count": len(PROBE_PROGRESS_STAGES)}, "native canary progress incomplete after successful probe"
        return ready["checks"] + ["continuously-owned-listener", "continuously-owned-egress", "unrelated-listener-no-accept", "control-eof-clean-stop"]
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream and not stream.closed:
                try:
                    stream.close()
                except BrokenPipeError:
                    # Closing buffered stdin may retry the same failed flush.
                    # Preserve the original, pre-cleanup exit diagnostic.
                    pass
        if thread.is_alive():
            # Closing the listener settles a still-blocked accept on failure.
            try:
                egress.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            egress.close()
            thread.join(timeout=36)
        if thread.is_alive():
            raise AssertionError("synthetic egress thread did not drain")
