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
    hashes = {name: sha_file(Path(root) / name) for name in relative_paths}
    if Path(root) == Path(__file__).resolve().parents[1] and set(hashes) == set(STARTUP_SOURCES):
        _startup_sources.clear()
        _startup_sources.update(hashes)
    return hashes


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
    if (expected_receipt_sha256 == STARTUP_RECEIPT_SHA256
            and expected["python/bin/python3"]["sha256"] == STARTUP_INTERPRETER_SHA256):
        _startup_payloads.add(payload)
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


# This slice diagnoses only the already-reviewed public hosted fixture. These
# caches come from the runners' existing full verification, not caller input.
STARTUP_RECEIPT_SHA256 = "4268358594bf02881357334812b8f7ee84764940752071b1febd3ace26adbbab"
STARTUP_INTERPRETER_SHA256 = "bfb00f17c254d903fac15265ad47653724c3a753d2c36414062fa2025b9ac523"
STARTUP_SOURCES = (
    "scripts/test_search_proxy_sandbox_canary.py", "scripts/search_proxy_canary_support.py",
    "Tests/Native/search_proxy_bootstrap_probe.py", "Tests/Fixtures/search_proxy_canary.sb",
    "profile-bootstrap-basis.json",
)
STARTUP_MARKER = b"dot-search-startup-v1\n"
_startup_payloads = set()
_startup_sources = {}


def _startup_host():
    # An accidental-local-execution guard, not an authentication/trust claim.
    return (sys.platform == "darwin" and platform.machine() == "arm64"
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("RUNNER_OS") == "macOS"
            and os.environ.get("RUNNER_ARCH") == "ARM64"
            and os.environ.get("GITHUB_WORKFLOW") == "Build-only native Search proxy canaries")


def _startup_stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _startup_file(path, digest, limit):
    if path != path.resolve(strict=True):
        raise ValueError("identity")
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or info.st_uid != os.geteuid() or info.st_mode & 0o022 or not 0 < info.st_size <= limit):
        raise ValueError("identity")
    return (path, digest, limit, _startup_stamp(info))


def _startup_directory(path):
    if path != path.resolve(strict=True):
        raise ValueError("directory")
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError("directory")
        # Original fixture/progress writes legitimately change directory times.
        return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
    finally:
        os.close(descriptor)


def _startup_listener(descriptor):
    if type(descriptor) is not int or descriptor < 3:
        raise ValueError("listener")
    with socket.fromfd(descriptor, socket.AF_INET, socket.SOCK_STREAM) as listener:
        if (listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) != 1
                or listener.getsockname()[0] != "127.0.0.1"
                or listener.family != socket.AF_INET
                or listener.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM):
            raise ValueError("listener")
        return (_startup_stamp(os.fstat(descriptor)), listener.getsockname()[1])


def _startup_context(command, payload, state, foreign, egress, pass_fds, env, probe_kind):
    if probe_kind != "profile" or not _startup_host():
        return None
    try:
        root = Path(__file__).resolve().parents[1]
        python, helper = payload / "python/bin/python3", state / "profile_probe.py"
        profile = root / "Tests/Fixtures/search_proxy_canary.sb"
        if (payload not in _startup_payloads or payload != payload.resolve(strict=True)
                or ".app" in {part[-4:] for part in payload.parts}
                or state != state.resolve(strict=True) or stat.S_IMODE(state.stat().st_mode) != 0o700
                or state.stat().st_uid != os.geteuid() or type(pass_fds) is not tuple or len(pass_fds) != 1
                or env != minimal_env(state) or set(_startup_sources) != set(STARTUP_SOURCES)):
            raise ValueError("context")
        endpoints = [(fd, _startup_listener(fd)) for fd in (pass_fds[0], foreign.fileno(), egress.fileno())]
        if len({fd for fd, _ in endpoints}) != 3:
            raise ValueError("endpoints")
        listener_port, egress_port = endpoints[0][1][1], endpoints[2][1][1]
        expected = ["/usr/bin/sandbox-exec"]
        for key, value in (("DOT_SEARCH_PAYLOAD", str(payload)), ("DOT_SEARCH_STATE", str(state)),
                           ("DOT_SEARCH_PYTHON", str(python)), ("DOT_SEARCH_LISTENER", f"localhost:{listener_port}"),
                           ("DOT_SEARCH_EGRESS", f"localhost:{egress_port}")):
            expected.extend(["-D", key + "=" + value])
        expected.extend(["-f", str(profile), str(python), "-I", "-S", "-B", str(helper),
            "--payload", str(payload), "--state-root", str(state), "--owned-listener", str(pass_fds[0]),
            "--egress-port", str(egress_port), "--probe-kind", "profile"])
        if type(command) is not list or command != expected:
            raise ValueError("command")
        files = [_startup_file(root / name, _startup_sources[name], 256 * 1024) for name in STARTUP_SOURCES]
        files += [_startup_file(helper, _startup_sources["Tests/Native/search_proxy_bootstrap_probe.py"], 256 * 1024),
                  _startup_file(payload / "evidence/assembly-input-receipt.json", STARTUP_RECEIPT_SHA256, 2 * 1024 * 1024),
                  _startup_file(python, STARTUP_INTERPRETER_SHA256, 32 * 1024 * 1024)]
        directories = [(path, _startup_directory(path)) for path in sorted(
            {state, payload, root, python.parent.parent} | {item[0].parent for item in files})]
        return {"files": files, "directories": directories, "endpoints": endpoints, "python": str(python), "prefix": tuple(command[:13]),
                "cwd": state, "env": dict(env), "pass_fds": pass_fds, "used": False}
    except Exception:
        # Bad/missing diagnostic provenance must not alter the original probe.
        return {"invalid": True, "used": False}


def _startup_verify(context, deadline):
    """Targeted identity only: never claim that the whole donor was reverified."""
    for path, expected in context["directories"]:
        if time.monotonic() >= deadline:
            raise TimeoutError
        if _startup_directory(path) != expected:
            raise ValueError("directory")
    for path, expected, limit, stamp in context["files"]:
        if time.monotonic() >= deadline:
            raise TimeoutError
        if path != path.resolve(strict=True):
            raise ValueError("identity")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            before = os.fstat(descriptor)
            if _startup_stamp(before) != stamp or before.st_size > limit:
                raise ValueError("identity")
            digest, remaining = hashlib.sha256(), before.st_size
            while remaining:
                if time.monotonic() >= deadline:
                    raise TimeoutError
                part = os.read(descriptor, min(65536, remaining))
                if not part:
                    raise ValueError("identity")
                digest.update(part)
                remaining -= len(part)
            if (os.read(descriptor, 1) or _startup_stamp(os.fstat(descriptor)) != stamp
                    or _startup_stamp(path.lstat()) != stamp or digest.hexdigest() != expected):
                raise ValueError("identity")
        finally:
            os.close(descriptor)
    for fd, expected in context["endpoints"]:
        if time.monotonic() >= deadline:
            raise TimeoutError
        if _startup_listener(fd) != expected:
            raise ValueError("listener")
    if time.monotonic() >= deadline:
        raise TimeoutError


def _startup_child(command, context, deadline, seconds, stdout_limit, stderr_limit, *, signature=False):
    """Bound output and exact-child lifetime; never return pipe/exception text."""
    result = {"status": "unavailable", "returncode": None, "cleanup": "not-needed"}
    process = None
    output = [bytearray(), bytearray()]
    end = min(deadline - 2, time.monotonic() + seconds)
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=context["cwd"], env=context["env"], pass_fds=context["pass_fds"], close_fds=True)
        result["pid"] = process.pid
        streams = {process.stdout: 0, process.stderr: 1}
        while True:
            now = time.monotonic()
            if now >= end:
                result["status"] = "timeout"
                break
            ready = select.select(list(streams), [], [], min(0.05, end - now))[0]
            for stream in ready:
                index = streams[stream]
                limit = stdout_limit if index == 0 else stderr_limit
                # Read at most cap + one, including combined signature output.
                room = limit - len(output[index])
                if signature:
                    room = min(room, 8192 - sum(map(len, output)))
                part = os.read(stream.fileno(), min(4096, room + 1))
                if not part:
                    del streams[stream]
                else:
                    output[index].extend(part)
                if len(output[index]) > limit or (signature and sum(map(len, output)) > 8192):
                    result["status"] = "output-limit"
                    break
            if result["status"] == "output-limit":
                break
            returncode = process.poll()
            if returncode is not None and not streams:
                result["returncode"] = returncode
                if signature:
                    result["status"] = "accepted" if returncode == 0 else "rejected"
                elif returncode < 0:
                    result["status"] = "signal"
                elif returncode != 0:
                    result["status"] = "nonzero-exit"
                elif output[0] != STARTUP_MARKER or output[1]:
                    result["status"] = "wrong-output"
                else:
                    result["status"] = "success"
                break
    except Exception:
        result["status"] = "unavailable"
    finally:
        if process is not None:
            try:
                if process.poll() is None:
                    process.kill()
                    result["cleanup"] = "kill-sent"
                remaining = min(2, max(0, deadline - time.monotonic()))
                process.wait(timeout=remaining)
                result["returncode"] = process.returncode
                if result["cleanup"] == "kill-sent":
                    result["cleanup"] = "killed-and-reaped"
            except Exception:
                result["cleanup"] = "unconfirmed"
            finally:
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        try:
                            stream.close()
                        except Exception:
                            result["cleanup"] = "unconfirmed"
    return result


def _startup_differential(context):
    started = time.monotonic()
    deadline = started + 45
    result = {"schema": 1, "kind": "build-only-fixed-startup-differential", "production_acceptance": False,
              "status": "unavailable", "identity_scope": "targeted-files-and-held-listeners", "post_identity": "not-checked"}
    try:
        if context.get("invalid") or not _startup_host():
            return result
        _startup_verify(context, deadline - 5)
        # Keep a final five-second targeted check inside the same total budget.
        if deadline - time.monotonic() < 12:
            raise TimeoutError
        signature = _startup_child(["/usr/bin/codesign", "--verify", "--strict", context["python"]],
            context, deadline - 5, 5, 8192, 8192, signature=True)
        result["signature"] = signature
        if signature["status"] != "accepted" or signature["cleanup"] == "unconfirmed":
            result["status"] = "signature-stopped"
            return result
        # Literal source only. The prefix was validated against the entire
        # original command; no logs, payload source or caller command is run.
        command = [context["python"], "-I", "-S", "-B", "-c", 'print("dot-search-startup-v1")']
        for name, argv in (("outside", command), ("inside", list(context["prefix"]) + command)):
            _startup_verify(context, deadline - 15)
            if deadline - time.monotonic() < 15:
                raise TimeoutError
            result[name] = _startup_child(argv, context, deadline - 5, 8, 128, 4096)
            if result[name]["cleanup"] == "unconfirmed":
                result["status"] = "cleanup-unconfirmed"
                return result
        outside, inside = result["outside"]["status"], result["inside"]["status"]
        if outside == inside == "success":
            result["status"] = "both-minimal-startups-succeeded"
        elif outside == "success" and inside in ("signal", "nonzero-exit", "wrong-output"):
            result["status"] = "sandbox-context-dependent-failure"
        elif outside in ("signal", "nonzero-exit", "wrong-output") and inside in ("signal", "nonzero-exit", "wrong-output"):
            result["status"] = "failure-without-sandbox"
        else:
            result["status"] = "inconclusive"
    except TimeoutError:
        result["status"] = "budget-exceeded"
    except Exception:
        result["status"] = "identity-failed"
    finally:
        if not context.get("invalid"):
            try:
                _startup_verify(context, deadline)
                result["post_identity"] = "verified-targets-only"
            except TimeoutError:
                result["post_identity"] = "budget-exceeded"
                result["status"] = "budget-exceeded"
            except Exception:
                result["post_identity"] = "failed"
                result["status"] = "identity-failed"
        result["elapsed_ms"] = min(2147483647, max(0, int((time.monotonic() - started) * 1000)))
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
    context = getattr(process, "_dot_startup_context", None)
    if stage.startswith("profile-") and returncode is not None and returncode < 0 and context is not None and not context["used"]:
        context["used"] = True
        try:
            diagnostic["startup_differential"] = _startup_differential(context)
        except Exception:
            diagnostic["startup_differential"] = {"status": "unavailable", "production_acceptance": False}
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
    startup_context = _startup_context(command, payload, state, foreign, egress, pass_fds,
                                       env if env is not None else minimal_env(state), probe_kind)
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=state, env=env if env is not None else minimal_env(state), pass_fds=pass_fds)
    process._dot_startup_context = startup_context
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
