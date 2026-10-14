"""Controller-only subprocess diagnostics; never executes the Search payload."""
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import contextlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import search_proxy_canary_support as support

spec = importlib.util.spec_from_file_location("proxy_profile_diagnostic_test", ROOT / "scripts/test_search_proxy_sandbox_canary.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ExitDiagnosticsTests(unittest.TestCase):
    def process(self, program, *, stderr=subprocess.PIPE):
        # Only the current portable test controller runs these synthetic programs.
        process = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c", program],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            for stream in (process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()
        self.addCleanup(cleanup)
        return process

    def failure(self, process, *, timeout=3, stage="profile-await-ready"):
        with self.assertRaises(AssertionError) as caught:
            support.event(process, timeout=timeout, stage=stage)
        message = str(caught.exception)
        self.assertLess(len(message), 1024)
        self.assertTrue(message.startswith("native canary failed: "))
        diagnostic = json.loads(message.removeprefix("native canary failed: "))
        self.assertEqual(set(diagnostic), {"kind", "controller_stage", "reason", "returncode", "exit_status",
            "signal", "stdout_bytes_observed", "stderr_bytes_sampled", "stderr_sample_limit", "production_acceptance"})
        self.assertEqual(diagnostic["controller_stage"], stage)
        self.assertEqual(diagnostic["kind"], "build-only-native-canary-failure")
        self.assertIs(diagnostic["production_acceptance"], False)
        self.assertNotIn("synthetic-secret", message)
        self.assertNotIn("native_canary_ready", message)
        return diagnostic

    def test_silent_nonzero_exit_reports_actual_status(self):
        result = self.failure(self.process("import os; os._exit(23)"))
        self.assertEqual((result["reason"], result["returncode"], result["exit_status"], result["signal"]),
                         ("stdout-eof", 23, 23, None))
        self.assertEqual(result["stderr_bytes_sampled"], 0)

    def test_zero_exit_before_ready_is_still_failure(self):
        result = self.failure(self.process("pass"))
        self.assertEqual(result["returncode"], 0)
        self.assertEqual(result["exit_status"], 0)
        self.assertIsNone(result["signal"])

    def test_actual_signal_is_separate_from_exit_status(self):
        result = self.failure(self.process("import os, signal; os.kill(os.getpid(), signal.SIGTERM)"))
        self.assertEqual(result["returncode"], -signal.SIGTERM)
        self.assertEqual(result["signal"], signal.SIGTERM)
        self.assertIsNone(result["exit_status"])

    def test_eof_race_waits_boundedly_for_actual_status(self):
        result = self.failure(self.process("import os, time; os.close(1); time.sleep(0.1); os._exit(21)"))
        self.assertEqual(result["exit_status"], 21)

    def test_stdout_closed_while_alive_is_not_claimed_as_exit(self):
        process = self.process("import os, time; os.close(1); time.sleep(60)")
        started = time.monotonic()
        result = self.failure(process)
        self.assertLess(time.monotonic() - started, 2)
        self.assertIsNone(process.poll())
        self.assertIsNone(result["returncode"])
        self.assertIsNone(result["exit_status"])
        self.assertIsNone(result["signal"])

    def test_partial_control_frame_and_stderr_are_never_printed(self):
        process = self.process("import os; os.write(1, b'{\"event\":\"native_canary_ready\",\"token\":\"synthetic-secret\"'); "
                               "os.write(2, b'synthetic-secret environment contents'); os._exit(19)")
        result = self.failure(process)
        self.assertEqual(result["exit_status"], 19)
        self.assertGreater(result["stdout_bytes_observed"], 0)
        self.assertGreater(result["stderr_bytes_sampled"], 0)

    def test_stderr_sampling_is_bounded(self):
        process = self.process("import os; os.write(2, b'x' * 4097); os._exit(17)")
        result = self.failure(process)
        self.assertEqual(result["exit_status"], 17)
        self.assertEqual(result["stderr_bytes_sampled"], 4096)
        self.assertEqual(result["stderr_sample_limit"], 4096)

    def test_retained_stderr_writer_cannot_block_diagnostic(self):
        reader, writer = os.pipe()
        self.addCleanup(os.close, writer)
        process = self.process("import os; os.write(2, b'synthetic-secret'); os._exit(12)", stderr=writer)
        process.stderr = os.fdopen(reader, "rb")
        started = time.monotonic()
        result = self.failure(process)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(result["exit_status"], 12)
        self.assertEqual(result["stderr_bytes_sampled"], len(b"synthetic-secret"))

    def test_timeout_is_observation_before_cleanup_kill(self):
        process = self.process("import time; time.sleep(60)")
        result = self.failure(process, timeout=0.05)
        self.assertEqual(result["reason"], "event-timeout")
        self.assertIsNone(result["returncode"])
        self.assertIsNone(result["signal"])
        self.assertIsNone(process.poll())

    def test_oversized_event_is_bounded_and_redacted(self):
        result = self.failure(self.process("import os, time; os.write(1, b'x' * 4097); time.sleep(60)"))
        self.assertEqual(result["reason"], "oversized-event")
        self.assertEqual(result["stdout_bytes_observed"], 4097)

    def test_malformed_event_is_redacted(self):
        result = self.failure(self.process("import os; os.write(1, b'synthetic-secret invalid JSON\\n')"))
        self.assertEqual(result["reason"], "invalid-event")

    def test_stopped_phase_is_distinct(self):
        result = self.failure(self.process("raise SystemExit(7)"), stage="profile-await-stopped")
        self.assertEqual(result["exit_status"], 7)

    def test_valid_event_contract_is_unchanged(self):
        process = self.process("print('{\"event\":\"native_canary_stopped\"}', flush=True)")
        self.assertEqual(support.event(process, stage="native-await-stopped"), {"event": "native_canary_stopped"})
        self.assertEqual(process.wait(timeout=3), 0)

    def test_arbitrary_stage_or_reason_is_rejected_without_output(self):
        for stage, reason in (("synthetic-secret", "stdout-eof"), ("profile-await-ready", "synthetic-secret")):
            with self.assertRaisesRegex(ValueError, "unknown fixed canary"):
                support.event_failure(None, stage, reason)

    def test_closed_control_pipe_keeps_original_exit_diagnostic_through_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="dot-proxy-closed-control-") as temporary:
            base = Path(temporary).resolve()
            state, outside, inference = support.fixture_directories(base)
            payload = base / "payload"
            payload.mkdir()
            process = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c", "raise SystemExit(29)"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            process.wait(timeout=3)
            with support.owned_listener() as foreign, support.owned_listener() as egress, \
                 mock.patch.object(support.subprocess, "Popen", return_value=process), \
                 mock.patch.object(support.threading, "Thread") as thread:
                thread.return_value.is_alive.return_value = False
                with self.assertRaises(AssertionError) as caught:
                    support.drive_probe(["never launched"], payload, state, outside, inference, foreign, egress,
                                        probe_kind="profile")
            result = json.loads(str(caught.exception).removeprefix("native canary failed: "))
            self.assertEqual(result["controller_stage"], "profile-send-start")
            self.assertEqual(result["reason"], "control-pipe-closed")
            self.assertEqual(result["exit_status"], 29)
            self.assertTrue(all(stream.closed for stream in (process.stdin, process.stdout, process.stderr)))

    def test_profile_prelaunch_records_only_verified_identity_and_fixed_stage(self):
        identity = {"assembly_receipt_sha256": "a" * 64, "interpreter_sha256": "b" * 64}
        sources = {"Tests/Fixtures/search_proxy_canary.sb": "c" * 64}
        with tempfile.TemporaryDirectory(prefix="dot-proxy-diagnostic-controller-") as temporary:
            payload = Path(temporary).resolve()
            args = SimpleNamespace(search_payload=payload, expected_receipt_sha256="a" * 64)
            output = io.StringIO()
            with mock.patch.object(profile, "require_native"), mock.patch.object(profile, "parse_args", return_value=args), \
                 mock.patch.object(profile, "verify_payload", return_value=(payload, identity)), \
                 mock.patch.object(profile, "fixture_hashes", return_value=sources), \
                 mock.patch.object(profile, "drive_probe", side_effect=RuntimeError("stop before execution")) as drive, \
                 contextlib.redirect_stderr(output):
                with self.assertRaisesRegex(RuntimeError, "stop before execution"):
                    profile.main()
            diagnostic = json.loads(output.getvalue())
            self.assertEqual(diagnostic, {"kind": "build-only-native-canary-stage", "controller_stage": "profile-prelaunch",
                "production_acceptance": False, "payload": identity, "fixture_sources": sources})
            self.assertNotIn(temporary, output.getvalue())
            self.assertEqual(drive.call_args.kwargs["probe_kind"], "profile")
            command = drive.call_args.args[0]
            # Preserve the reviewed launcher, literal path policy parameter,
            # flags and input payload. No fallback or framework substitution.
            self.assertEqual(command[0], "/usr/bin/sandbox-exec")
            self.assertIn("DOT_SEARCH_PYTHON=" + str(payload / "python/bin/python3"), command)
            index = command.index("-f")
            self.assertEqual(command[index + 1], str(ROOT / "Tests/Fixtures/search_proxy_canary.sb"))
            self.assertEqual(command[index + 2:index + 6], [str(payload / "python/bin/python3"), "-I", "-S", "-B"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
