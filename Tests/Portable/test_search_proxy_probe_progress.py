"""Portable journal/diagnostic tests. Never executes a bundled interpreter."""
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import ast
import contextlib
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("progress_support", ROOT / "scripts/search_proxy_canary_support.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
PROBE = ROOT / "Tests/Native/search_proxy_bootstrap_probe.py"
TREE = ast.parse(PROBE.read_text())
# Extract only the exact journal definitions, stopping before the first marker.
# Do not import the native helper or run any of its probes on a portable host.
DEFINITIONS = []
for node in TREE.body:
    if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
        break
    DEFINITIONS.append(node)
WRITER_CODE = compile(ast.Module(body=DEFINITIONS, type_ignores=[]), str(PROBE), "exec")
WRITER_SOURCE = ast.unparse(ast.Module(body=DEFINITIONS, type_ignores=[]))
COMPLETION_SOURCE = ast.unparse(TREE.body[-1])


@contextlib.contextmanager
def in_directory(path):
    before = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(before)


class ProbeProgressTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dot-probe-progress-")
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.path = self.state / support.PROBE_PROGRESS_FILE
        self.namespace = {}
        exec(WRITER_CODE, self.namespace)

    def record(self, label):
        with in_directory(self.state):
            self.namespace["_record_progress"](label)

    def content(self, count):
        return ("\n".join(support.PROBE_PROGRESS_STAGES[:count]) + "\n").encode()

    def write(self, data):
        self.path.write_bytes(data)
        self.path.chmod(0o600)

    def assert_unobserved(self, expected):
        result = support.read_probe_progress(self.state)
        self.assertEqual(result, {"status": expected, "last_observed_stage": None, "stage_count": 0})
        self.assertNotIn(str(self.state), json.dumps(result))
        self.assertNotIn("synthetic-secret", json.dumps(result))

    def test_writer_reader_schema_and_calls_match_exactly(self):
        for name in ("PROBE_PROGRESS_FILE", "PROBE_PROGRESS_LIMIT", "PROBE_PROGRESS_STAGES"):
            self.assertEqual(self.namespace[name], getattr(support, name))
        calls = sorted((node.lineno, ast.literal_eval(node.args[0])) for node in ast.walk(TREE)
                       if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                       and node.func.id == "_record_progress")
        self.assertEqual(tuple(value for _, value in calls), support.PROBE_PROGRESS_STAGES)
        first_call = calls[0][0]
        initial_imports = [node.names[0].name for node in TREE.body if isinstance(node, ast.Import) and node.lineno < first_call]
        self.assertEqual(initial_imports, ["os", "stat"])
        self.assertLess(len(self.content(len(support.PROBE_PROGRESS_STAGES))), support.PROBE_PROGRESS_LIMIT)
        self.assertIsInstance(TREE.body[-1], ast.If)
        self.assertEqual(ast.dump(TREE.body[-1].test), "Name(id='_progress_failed', ctx=Load())")
        self.assertIsInstance(TREE.body[-1].body[0], ast.Raise)
        self.assertEqual(TREE.body[-2].value.args[0].value, "stopped-emitted")

    def test_exact_writer_records_every_prefix_without_descriptor_leaks(self):
        original_open = os.open
        descriptors = []
        def opened(*args, **kwargs):
            descriptor = original_open(*args, **kwargs)
            descriptors.append(descriptor)
            return descriptor
        for count, label in enumerate(support.PROBE_PROGRESS_STAGES, 1):
            with mock.patch.object(os, "open", side_effect=opened):
                self.record(label)
            self.assertFalse(self.namespace["_progress_failed"])
            for descriptor in descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
            self.assertEqual(self.path.read_bytes(), self.content(count))
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
            self.assertEqual(support.read_probe_progress(self.state),
                             {"status": "observed", "last_observed_stage": label, "stage_count": count})

    def test_initial_existing_file_is_never_overwritten(self):
        self.write(b"synthetic-secret")
        self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(self.path.read_bytes(), b"synthetic-secret")

    def test_initial_symlink_is_never_followed(self):
        target = self.state / "outside"
        target.write_bytes(b"synthetic-secret")
        self.path.symlink_to(target)
        self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(target.read_bytes(), b"synthetic-secret")
        self.assert_unobserved("invalid")

    def test_replacement_inode_is_not_written(self):
        self.record("helper-entry")
        self.path.rename(self.state / "original")
        self.write(self.content(1))
        self.record("imports-complete")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(self.path.read_bytes(), self.content(1))
        self.assertEqual((self.state / "original").read_bytes(), self.content(1))

    def test_hardlinked_journal_is_never_appended_or_observed(self):
        self.record("helper-entry")
        os.link(self.path, self.state / "alias")
        self.record("imports-complete")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(self.path.read_bytes(), self.content(1))
        self.assert_unobserved("invalid")

    def test_replaced_symlink_is_never_appended(self):
        self.record("helper-entry")
        self.path.rename(self.state / "original")
        self.path.symlink_to(self.state / "original")
        self.record("imports-complete")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual((self.state / "original").read_bytes(), self.content(1))

    def test_wrong_stage_disables_writer_without_arbitrary_content(self):
        self.record("synthetic-secret")
        self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertFalse(self.path.exists())

    def test_duplicate_and_oversized_existing_content_stop_writes(self):
        self.record("helper-entry")
        self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(self.path.read_bytes(), self.content(1))
        self.namespace = {}
        exec(WRITER_CODE, self.namespace)
        self.path.unlink()
        self.record("helper-entry")
        self.write(b"x" * (support.PROBE_PROGRESS_LIMIT + 1))
        self.record("imports-complete")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(self.path.stat().st_size, support.PROBE_PROGRESS_LIMIT + 1)

    def test_permission_failure_does_not_mask_later_probe_error(self):
        with mock.patch.object(os, "open", side_effect=PermissionError("synthetic-secret")):
            self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        with self.assertRaisesRegex(RuntimeError, "original probe failure"):
            self.record("imports-complete")
            raise RuntimeError("original probe failure")
        self.assert_unobserved("absent")

    def test_short_write_is_bounded_invalid_and_closes_descriptor(self):
        with mock.patch.object(os, "write", return_value=1), mock.patch.object(os, "close", wraps=os.close) as close:
            self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertEqual(close.call_count, 1)
        self.assert_unobserved("invalid")

    def test_writer_and_reader_require_private_state(self):
        self.state.chmod(0o755)
        self.record("helper-entry")
        self.assertTrue(self.namespace["_progress_failed"])
        self.assertFalse(self.path.exists())
        self.assert_unobserved("invalid")

    def test_reader_rejects_content_outside_exact_prefix_schema(self):
        for data in (b"", b"synthetic-secret\n", b"helper-entry", b"helper-entry\nhelper-entry\n",
                     b"imports-complete\n", self.content(2) + b"synthetic-secret\n", b"\xff\n",
                     b"x" * (support.PROBE_PROGRESS_LIMIT + 1)):
            with self.subTest(data_size=len(data)):
                self.write(data)
                self.assert_unobserved("invalid")

    def test_reader_rejects_directory_and_fifo_without_waiting(self):
        self.path.mkdir()
        self.assert_unobserved("invalid")
        self.path.rmdir()
        os.mkfifo(self.path, 0o600)
        start = time.monotonic()
        self.assert_unobserved("invalid")
        self.assertLess(time.monotonic() - start, 1)

    def test_reader_rejects_state_alias_and_relative_path(self):
        self.write(self.content(1))
        alias = self.state / "alias"
        alias.symlink_to(self.state, target_is_directory=True)
        for root in (alias, Path(".")):
            result = support.read_probe_progress(root)
            self.assertEqual(result["status"], "invalid")
            self.assertIsNone(result["last_observed_stage"])

    def test_reader_rejects_wrong_file_mode_and_owner(self):
        self.write(self.content(1))
        self.path.chmod(0o644)
        self.assert_unobserved("invalid")
        self.path.chmod(0o600)
        with mock.patch.object(os, "geteuid", return_value=os.geteuid() + 1):
            self.assert_unobserved("invalid")

    def test_reader_is_bounded_and_rejects_concurrent_change(self):
        self.write(self.content(1))
        original_read = os.read
        with mock.patch.object(os, "read", wraps=original_read) as read:
            self.assertEqual(support.read_probe_progress(self.state)["status"], "observed")
        self.assertEqual(read.call_count, 1)
        self.assertEqual(read.call_args.args[1], support.PROBE_PROGRESS_LIMIT + 1)
        def changed(descriptor, size):
            data = original_read(descriptor, size)
            with self.path.open("ab") as stream:
                stream.write(b"imports-complete\n")
            return data
        with mock.patch.object(os, "read", side_effect=changed):
            self.assert_unobserved("invalid")

    def test_reader_failure_cannot_mask_original_sigabrt_observation(self):
        reader, writer = os.pipe()
        os.close(writer)
        with os.fdopen(reader, "rb") as stream:
            process = SimpleNamespace(stderr=stream, poll=lambda: -6, wait=lambda timeout: -6)
            with mock.patch.object(os, "open", side_effect=PermissionError("synthetic-secret")):
                error = support.event_failure(process, "profile-await-ready", "stdout-eof",
                                              settle=True, progress_state=self.state)
        result = json.loads(str(error).removeprefix("native canary failed: "))
        self.assertEqual((result["returncode"], result["signal"], result["exit_status"]), (-6, 6, None))
        self.assertEqual(result["probe_progress"]["status"], "unavailable")
        self.assertEqual(result["controller_stage"], "profile-await-ready")
        self.assertNotIn("synthetic-secret", str(error))
        self.assertNotIn(str(self.state), str(error))

    def test_actual_host_signal_preserved_with_last_observed_stage(self):
        self.write(self.content(2))
        process = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c",
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with self.assertRaises(AssertionError) as caught:
                support.event(process, timeout=5, stage="profile-await-ready", progress_state=self.state)
            result = json.loads(str(caught.exception).removeprefix("native canary failed: "))
            self.assertEqual(result["returncode"], -signal.SIGTERM)
            self.assertEqual(result["probe_progress"], {"status": "observed", "last_observed_stage": "imports-complete", "stage_count": 2})
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_driver_rejects_existing_record_before_launch(self):
        self.write(self.content(len(support.PROBE_PROGRESS_STAGES)))
        with mock.patch.object(support.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(AssertionError, "progress path already exists"):
                support.drive_probe([], None, self.state, None, None, None, None)
        launch.assert_not_called()
        self.assertEqual(self.path.read_bytes(), self.content(len(support.PROBE_PROGRESS_STAGES)))

    def test_driver_failure_retains_progress_exit_and_cleanup(self):
        state, outside, inference = support.fixture_directories(self.state)
        payload = self.state / "payload"
        payload.mkdir()
        program = WRITER_SOURCE + '\n_record_progress("helper-entry")\nos._exit(31)\n'
        captured = []
        original_popen = subprocess.Popen
        def launch(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            captured.append(process)
            return process
        with support.owned_listener() as foreign, support.owned_listener() as egress, \
             mock.patch.object(support.subprocess, "Popen", side_effect=launch), \
             mock.patch.object(support.threading, "Thread") as thread:
            thread.return_value.is_alive.return_value = False
            with self.assertRaises(AssertionError) as caught:
                support.drive_probe([sys.executable, "-I", "-S", "-B", "-c", program],
                                    payload, state, outside, inference, foreign, egress, probe_kind="profile")
            support.assert_owned(egress.getsockname()[1])
        result = json.loads(str(caught.exception).removeprefix("native canary failed: "))
        self.assertEqual(result["exit_status"], 31)
        self.assertEqual(result["probe_progress"]["last_observed_stage"], "helper-entry")
        self.assertTrue(all(stream.closed for stream in (captured[0].stdin, captured[0].stdout, captured[0].stderr)))
        self.assertEqual(captured[0].poll(), 31)

    def synthetic_success(self, journal):
        with tempfile.TemporaryDirectory(prefix="dot-progress-driver-") as temporary:
            base = Path(temporary).resolve()
            state, outside, inference = support.fixture_directories(base)
            payload = base / "payload"
            payload.mkdir()
            # Host interpreter, synthetic private files and held loopback sockets only.
            with support.owned_listener() as listener, support.owned_listener() as foreign, support.owned_listener() as egress:
                program = '''import os, sys, socket, json
listener = socket.socket(fileno=int(sys.argv[1]))
egress_port = int(sys.argv[2])
for sequence in range(2):
    with socket.create_connection(("127.0.0.1", egress_port), timeout=3) as sock:
        sock.sendall(b"egress" + bytes([sequence]))
        assert sock.recv(5) == b"reply"
assert json.loads(sys.stdin.readline())["command"] == "start"
print(json.dumps({"event":"native_canary_ready", "pid":os.getpid(), "port":listener.getsockname()[1], "checks":[]}), flush=True)
with listener.accept()[0] as connection:
    assert connection.recv(7) == b"fixture"
    connection.sendall(b"reply")
assert sys.stdin.buffer.read(1) == b""
'''
                if journal:
                    program += WRITER_SOURCE + '\nfor label in PROBE_PROGRESS_STAGES[:-1]:\n    _record_progress(label)\n'
                program += 'print(json.dumps({"event":"native_canary_stopped"}), flush=True)\n'
                if journal:
                    # Use the actual helper's terminal check after its final write/close.
                    program += '_record_progress("stopped-emitted")\n' + COMPLETION_SOURCE + "\n"
                result = support.drive_probe([sys.executable, "-I", "-S", "-B", "-c", program,
                        str(listener.fileno()), str(egress.getsockname()[1])], payload, state, outside, inference,
                        foreign, egress, pass_fds=(listener.fileno(),), probe_kind="profile")
        self.assertFalse(base.exists())
        return result

    def test_driver_cannot_pass_without_complete_journal(self):
        with self.assertRaisesRegex(AssertionError, "progress incomplete after successful probe"):
            self.synthetic_success(False)

    def close_failure_diagnostic(self, count):
        injection = f"""
_original_progress_close = os.close
_injected_close_failure = False
def _close_with_reported_failure(descriptor):
    global _injected_close_failure
    _original_progress_close(descriptor)
    if _progress_count == {count} and not _injected_close_failure:
        _injected_close_failure = True
        raise OSError(5, "synthetic-secret close error")
os.close = _close_with_reported_failure
"""
        with mock.patch.dict(globals(), {"WRITER_SOURCE": WRITER_SOURCE + injection}):
            with self.assertRaises(AssertionError) as caught:
                self.synthetic_success(True)
        result = json.loads(str(caught.exception).removeprefix("native canary failed: "))
        self.assertEqual((result["controller_stage"], result["reason"], result["exit_status"], result["signal"]),
                         ("profile-wait-exit", "nonzero-exit", 1, None))
        self.assertNotIn("synthetic-secret", str(caught.exception))
        return result

    def test_final_marker_close_failure_cannot_produce_driver_success(self):
        result = self.close_failure_diagnostic(len(support.PROBE_PROGRESS_STAGES))
        self.assertEqual(result["probe_progress"], {"status": "observed",
            "last_observed_stage": "stopped-emitted", "stage_count": len(support.PROBE_PROGRESS_STAGES)})

    def test_earlier_close_failure_cannot_produce_driver_success(self):
        result = self.close_failure_diagnostic(1)
        self.assertEqual(result["probe_progress"], {"status": "observed",
            "last_observed_stage": "helper-entry", "stage_count": 1})

    def test_driver_success_keeps_original_checks_and_cleans_temporary_state(self):
        result = self.synthetic_success(True)
        self.assertEqual(result, ["continuously-owned-listener", "continuously-owned-egress",
                                 "unrelated-listener-no-accept", "control-eof-clean-stop"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
