"""Host-only fixed startup differential contracts. Never execute the donor."""
from pathlib import Path
from unittest import mock
import ast
import contextlib
import errno
import hashlib
import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("startup_support", ROOT / "scripts/search_proxy_canary_support.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
SECRET = "synthetic-secret-not-for-diagnostics"


class StartupContextTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.base = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.state, self.outside, self.inference = support.fixture_directories(self.base)
        self.payload = self.base / "payload"
        self.python = self.payload / "python/bin/python3"
        self.python.parent.mkdir(parents=True)
        self.python.write_bytes(b"synthetic interpreter, never executed")
        self.receipt = self.payload / "evidence/assembly-input-receipt.json"
        self.receipt.parent.mkdir()
        self.receipt.write_bytes(b"synthetic receipt, not a native donor")
        self.helper = self.state / "profile_probe.py"
        self.helper.write_bytes((ROOT / "Tests/Native/search_proxy_bootstrap_probe.py").read_bytes())
        self.listener, self.foreign, self.egress = [self.stack.enter_context(support.owned_listener()) for _ in range(3)]
        self.fd = self.listener.fileno()
        self.stack.enter_context(mock.patch.object(support, "_startup_host", return_value=True))
        self.stack.enter_context(mock.patch.object(support, "STARTUP_INTERPRETER_SHA256", support.sha_file(self.python)))
        self.stack.enter_context(mock.patch.object(support, "STARTUP_RECEIPT_SHA256", support.sha_file(self.receipt)))
        self.stack.enter_context(mock.patch.object(support, "_startup_payloads", {self.payload}))
        self.stack.enter_context(mock.patch.object(support, "_startup_sources", {}))
        support.fixture_hashes(ROOT, support.STARTUP_SOURCES)
        self.env = support.minimal_env(self.state)
        self.command = ["/usr/bin/sandbox-exec"]
        for key, value in (("DOT_SEARCH_PAYLOAD", str(self.payload)), ("DOT_SEARCH_STATE", str(self.state)),
                           ("DOT_SEARCH_PYTHON", str(self.python)),
                           ("DOT_SEARCH_LISTENER", f"localhost:{self.listener.getsockname()[1]}"),
                           ("DOT_SEARCH_EGRESS", f"localhost:{self.egress.getsockname()[1]}")):
            self.command.extend(["-D", key + "=" + value])
        self.command.extend(["-f", str(ROOT / "Tests/Fixtures/search_proxy_canary.sb"), str(self.python), "-I", "-S", "-B",
            str(self.helper), "--payload", str(self.payload), "--state-root", str(self.state), "--owned-listener", str(self.fd),
            "--egress-port", str(self.egress.getsockname()[1]), "--probe-kind", "profile"])

    def context(self, **changes):
        args = dict(command=self.command, payload=self.payload, state=self.state, foreign=self.foreign,
                    egress=self.egress, pass_fds=(self.fd,), env=self.env, probe_kind="profile")
        args.update(changes)
        return support._startup_context(**args)

    def test_only_existing_successful_full_verification_registers_pinned_payload(self):
        helper = self.payload / "dot_search.py"
        helper.write_bytes(b"synthetic helper, never executed")
        receipt = {"schema": 1, "status": "unaccepted-static-assembly", "native_executed": False,
                   "lock_sha256": "a" * 64,
                   "files": [{"path": str(path.relative_to(self.payload)), "size": path.stat().st_size,
                              "sha256": support.sha_file(path)} for path in (self.python, helper)]}
        self.receipt.write_text(json.dumps(receipt))
        digest = support.sha_file(self.receipt)
        with mock.patch.object(support, "_startup_payloads", set()), \
             mock.patch.object(support, "STARTUP_RECEIPT_SHA256", digest):
            support.verify_payload(self.payload, digest)
            self.assertEqual(support._startup_payloads, {self.payload})
            support._startup_payloads.clear()
            helper.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                support.verify_payload(self.payload, digest)
            self.assertFalse(support._startup_payloads)
        helper.write_bytes(b"synthetic helper, never executed")
        with mock.patch.object(support, "_startup_payloads", set()), \
             mock.patch.object(support, "STARTUP_RECEIPT_SHA256", "0" * 64):
            support.verify_payload(self.payload, digest)
            self.assertFalse(support._startup_payloads)

    def test_drive_observes_original_signal_before_endpoint_cleanup(self):
        # Deliberately create only a current-host synthetic process. Popen for
        # the validated native command is mocked and cannot execute the donor.
        process = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c",
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        process.wait(timeout=3)
        def differential(context):
            self.assertEqual(process.poll(), -signal.SIGTERM)
            support.assert_owned(self.listener.getsockname()[1])
            support.assert_owned(self.egress.getsockname()[1])
            self.assertEqual(context["pass_fds"], (self.fd,))
            return {"status": "both-minimal-startups-succeeded"}
        with mock.patch.object(support.subprocess, "Popen", return_value=process) as spawn, \
             mock.patch.object(support.threading, "Thread") as thread, \
             mock.patch.object(support, "_startup_differential", side_effect=differential) as diff:
            thread.return_value.is_alive.return_value = False
            with self.assertRaises(AssertionError) as caught:
                support.drive_probe(self.command, self.payload, self.state, self.outside, self.inference,
                    self.foreign, self.egress, pass_fds=(self.fd,), probe_kind="profile")
        spawn.assert_called_once()
        self.assertEqual(spawn.call_args.args[0], self.command)
        diff.assert_called_once()
        result = json.loads(str(caught.exception).removeprefix("native canary failed: "))
        self.assertEqual(result["signal"], signal.SIGTERM)
        self.assertEqual(result["controller_stage"], "profile-send-start")
        self.assertEqual(result["probe_progress"]["status"], "absent")
        self.assertTrue(all(stream.closed for stream in (process.stdin, process.stdout, process.stderr)))

    def test_exact_context_uses_original_command_and_verified_sources(self):
        context = self.context()
        self.assertNotIn("invalid", context)
        self.assertEqual(context["prefix"], tuple(self.command[:13]))
        self.assertEqual(context["python"], str(self.python))
        self.assertEqual(context["cwd"], self.state)
        self.assertEqual(context["pass_fds"], (self.fd,))
        self.assertEqual(context["env"], self.env)
        self.assertIsNot(context["env"], self.env)
        self.assertEqual(len(context["files"]), 8)
        self.assertEqual(len(context["endpoints"]), 3)
        support._startup_verify(context, time.monotonic() + 2)

    def test_every_command_component_is_exact_not_caller_controlled(self):
        for index in range(len(self.command)):
            changed = self.command.copy()
            changed[index] = SECRET
            with self.subTest(index=index):
                self.assertEqual(self.context(command=changed), {"invalid": True, "used": False})
        for changed in (self.command + [SECRET], tuple(self.command), self.command[:-1]):
            self.assertIn("invalid", self.context(command=changed))

    def test_env_descriptor_source_and_identity_are_required(self):
        for values in ({"env": {**self.env, "SECRET": SECRET}}, {"env": {}}, {"pass_fds": ()},
                       {"pass_fds": [self.fd]}, {"pass_fds": (self.fd, self.fd)},
                       {"pass_fds": (True,)}, {"pass_fds": (self.foreign.fileno(),)}):
            self.assertIn("invalid", self.context(**values))
        with mock.patch.object(support, "_startup_sources", {}):
            self.assertIn("invalid", self.context())
        with mock.patch.object(support, "_startup_payloads", set()):
            self.assertIn("invalid", self.context())
        self.state.chmod(0o755)
        self.assertIn("invalid", self.context())

    def test_disabled_host_and_nonprofile_have_no_context(self):
        self.assertIsNone(self.context(probe_kind="native"))
        with mock.patch.object(support, "_startup_host", return_value=False):
            self.assertIsNone(self.context())

    def test_closed_and_nonlistener_descriptor_are_invalid(self):
        with socket.socket() as sock:
            self.assertIn("invalid", self.context(pass_fds=(sock.fileno(),)))
        self.assertIn("invalid", self.context(pass_fds=(sock.fileno(),)))

    def test_listener_platform_query_requires_exact_listening_state_without_mutation(self):
        cases = (("darwin", (socket.IPPROTO_TCP, 0x106, 1),
                  (b"\x01", b"\x00", b"\x04", b"", b"\x01\x00")),
                 ("linux", (socket.SOL_SOCKET, socket.SO_ACCEPTCONN), (1, 0, 2)))
        for platform, query, states in cases:
            for index, state in enumerate(states):
                with self.subTest(platform=platform, state=state):
                    listener = mock.MagicMock(family=socket.AF_INET)
                    listener.__enter__.return_value = listener
                    listener.getsockname.return_value = self.listener.getsockname()
                    def getsockopt(*args):
                        if args == (socket.SOL_SOCKET, socket.SO_TYPE):
                            return socket.SOCK_STREAM
                        self.assertEqual(args, query)
                        return state
                    listener.getsockopt.side_effect = getsockopt
                    with mock.patch.object(support.sys, "platform", platform), \
                         mock.patch.object(support.socket, "TCP_CONNECTION_INFO", 0x106, create=True), \
                         mock.patch.object(support.socket, "fromfd", return_value=listener):
                        if index == 0:
                            self.assertEqual(support._startup_listener(self.fd),
                                (support._startup_stamp(os.fstat(self.fd)), self.listener.getsockname()[1]))
                        else:
                            with self.assertRaises(ValueError):
                                support._startup_listener(self.fd)
                    self.assertEqual(listener.getsockopt.call_args_list[0], mock.call(*query))
                    self.assertEqual(listener.getsockopt.call_count, 2 if index == 0 else 1)
                    listener.bind.assert_not_called()
                    listener.listen.assert_not_called()
                    listener.connect.assert_not_called()
                    os.fstat(self.fd)

    def test_listener_query_error_fails_closed_without_fallback_or_mutation(self):
        for platform, query in (("darwin", (socket.IPPROTO_TCP, 0x106, 1)),
                                ("linux", (socket.SOL_SOCKET, socket.SO_ACCEPTCONN))):
            with self.subTest(platform=platform):
                listener = mock.MagicMock()
                listener.__enter__.return_value = listener
                error = OSError(errno.ENOPROTOOPT, "unsupported socket option")
                listener.getsockopt.side_effect = error
                with mock.patch.object(support.sys, "platform", platform), \
                     mock.patch.object(support.socket, "TCP_CONNECTION_INFO", 0x106, create=True), \
                     mock.patch.object(support.socket, "fromfd", return_value=listener):
                    with self.assertRaises(OSError) as caught:
                        support._startup_listener(self.fd)
                    self.assertIs(caught.exception, error)
                    self.assertEqual(self.context(), {"invalid": True, "used": False})
                self.assertEqual(listener.getsockopt.call_args_list, [mock.call(*query)] * 2)
                listener.bind.assert_not_called()
                listener.listen.assert_not_called()
                listener.connect.assert_not_called()
                os.fstat(self.fd)

    def test_real_unbound_bound_connected_and_accepted_sockets_stay_rejected(self):
        with socket.socket() as bound:
            with self.assertRaises(ValueError):
                support._startup_listener(bound.fileno())
            bound.bind(("127.0.0.1", 0))
            with self.assertRaises(ValueError):
                support._startup_listener(bound.fileno())
            os.fstat(bound.fileno())
            self.assertEqual(bound.getsockname()[0], "127.0.0.1")
        before = support._startup_listener(self.fd)
        with socket.create_connection(self.listener.getsockname(), timeout=2) as client:
            accepted, _ = self.listener.accept()
            with accepted:
                for connection in (client, accepted):
                    with self.assertRaises(ValueError):
                        support._startup_listener(connection.fileno())
                    os.fstat(connection.fileno())
                client.sendall(b"fixture")
                self.assertEqual(accepted.recv(7), b"fixture")
        self.assertEqual(support._startup_listener(self.fd), before)

    def test_target_mutation_and_same_bytes_replacement_are_rejected(self):
        for mutation in ("content", "replacement", "symlink", "hardlink", "mode"):
            with self.subTest(mutation=mutation):
                before = self.python.read_bytes()
                context = self.context()
                if mutation == "content":
                    self.python.write_bytes(b"changed bytes")
                elif mutation == "replacement":
                    self.python.unlink()
                    self.python.write_bytes(before)
                elif mutation == "symlink":
                    self.python.rename(self.python.with_name("old"))
                    self.python.symlink_to(self.python.with_name("old"))
                elif mutation == "hardlink":
                    os.link(self.python, self.python.with_name("alias"))
                else:
                    self.python.chmod(0o666)
                with self.assertRaises((ValueError, OSError)):
                    support._startup_verify(context, time.monotonic() + 2)
                self.python.unlink()
                for name in ("old", "alias"):
                    alias = self.python.with_name(name)
                    if alias.exists():
                        alias.unlink()
                self.python.write_bytes(before)

    def test_changed_during_read_is_rejected_and_descriptor_is_closed(self):
        context = self.context()
        context["files"] = [context["files"][-1]]
        original_read = os.read
        descriptors = []
        def read(fd, count):
            descriptors.append(fd)
            value = original_read(fd, count)
            self.python.write_bytes(b"changed")
            return value
        with mock.patch.object(support.os, "read", side_effect=read):
            with self.assertRaises(ValueError):
                support._startup_verify(context, time.monotonic() + 2)
        for fd in set(descriptors):
            with self.assertRaises(OSError):
                os.fstat(fd)

    def test_target_size_budget_and_special_files(self):
        for content in (b"", b"x" * 17):
            self.python.write_bytes(content)
            with self.assertRaises(ValueError):
                support._startup_file(self.python, "0" * 64, 16)
        self.python.unlink()
        os.mkfifo(self.python)
        with self.assertRaises(ValueError):
            support._startup_file(self.python, "0" * 64, 32)

    def test_receipt_helper_and_endpoint_changes_fail_closed(self):
        context = self.context()
        original_receipt = self.receipt.read_bytes()
        self.receipt.write_bytes(b"changed receipt")
        with self.assertRaises(ValueError):
            support._startup_verify(context, time.monotonic() + 2)
        self.receipt.write_bytes(original_receipt)
        context = self.context()
        self.helper.write_bytes(b"changed helper")
        with self.assertRaises(ValueError):
            support._startup_verify(context, time.monotonic() + 2)
        context["files"] = []
        self.listener.close()
        with self.assertRaises(OSError):
            support._startup_verify(context, time.monotonic() + 2)

    def test_cwd_mode_and_parent_directory_replacement_are_detected(self):
        context = self.context()
        self.state.chmod(0o755)
        with self.assertRaises(ValueError):
            support._startup_verify(context, time.monotonic() + 2)
        self.state.chmod(0o700)
        context = self.context()
        directory = self.python.parent
        saved = directory.with_name("saved-bin")
        directory.rename(saved)
        directory.mkdir()
        (saved / "python3").rename(self.python)
        with self.assertRaises(ValueError):
            support._startup_verify(context, time.monotonic() + 2)

    def test_original_fixture_writes_do_not_invalidate_cwd_identity(self):
        context = self.context()
        (self.state / "fixture.json").write_text("{}")
        (self.state / support.PROBE_PROGRESS_FILE).write_text("helper-entry\n")
        support._startup_verify(context, time.monotonic() + 2)

    def test_deadline_prevents_file_open(self):
        context = self.context()
        with mock.patch.object(support.os, "open") as opened:
            with self.assertRaises(TimeoutError):
                support._startup_verify(context, time.monotonic() - 1)
            opened.assert_not_called()

    def test_fixed_differential_arguments_and_original_context(self):
        context = self.context()
        results = [{"status": "accepted", "cleanup": "not-needed"},
                   {"status": "success", "cleanup": "not-needed"},
                   {"status": "success", "cleanup": "not-needed"}]
        with mock.patch.object(support, "_startup_child", side_effect=results) as child:
            result = support._startup_differential(context)
        self.assertEqual(result["status"], "both-minimal-startups-succeeded")
        self.assertEqual(result["post_identity"], "verified-targets-only")
        calls = child.call_args_list
        self.assertEqual(calls[0].args[0], ["/usr/bin/codesign", "--verify", "--strict", str(self.python)])
        literal = [str(self.python), "-I", "-S", "-B", "-c", 'print("dot-search-startup-v1")']
        self.assertEqual(calls[1].args[0], literal)
        self.assertEqual(calls[2].args[0], self.command[:13] + literal)
        for call in calls:
            self.assertIs(call.args[1], context)
        self.assertEqual(calls[0].args[3:], (5, 8192, 8192))
        self.assertEqual(calls[1].args[3:], (8, 128, 4096))
        self.assertIs(calls[0].kwargs["signature"], True)
        self.assertNotIn(SECRET, json.dumps(result))
        self.assertNotIn(str(self.base), json.dumps(result))

    def test_signature_gate_stops_every_nonaccepted_or_unsettled_check(self):
        for status, cleanup in (("rejected", "not-needed"), ("unavailable", "not-needed"),
                                ("timeout", "killed-and-reaped"), ("output-limit", "killed-and-reaped"),
                                ("accepted", "unconfirmed")):
            with self.subTest(status=status, cleanup=cleanup):
                with mock.patch.object(support, "_startup_child", return_value={"status": status, "cleanup": cleanup}) as child:
                    result = support._startup_differential(self.context())
                self.assertEqual(child.call_count, 1)
                self.assertEqual(result["status"], "signature-stopped")
                self.assertEqual(result["post_identity"], "verified-targets-only")

    def test_unconfirmed_outside_cleanup_prevents_inside(self):
        with mock.patch.object(support, "_startup_child", side_effect=[
                {"status": "accepted", "cleanup": "not-needed"}, {"status": "timeout", "cleanup": "unconfirmed"}]) as child:
            result = support._startup_differential(self.context())
        self.assertEqual(child.call_count, 2)
        self.assertEqual(result["status"], "cleanup-unconfirmed")
        self.assertNotIn("inside", result)

    def test_mutation_after_codesign_and_after_startups_is_not_repaired(self):
        for phase in (1, 3):
            with self.subTest(phase=phase):
                original = self.python.read_bytes()
                count = 0
                def child(*args, **kwargs):
                    nonlocal count
                    count += 1
                    if count == phase:
                        self.python.write_bytes(b"changed " + original)
                    return {"status": "accepted" if count == 1 else "success", "cleanup": "not-needed"}
                with mock.patch.object(support, "_startup_child", side_effect=child):
                    result = support._startup_differential(self.context())
                self.assertEqual(count, phase)
                self.assertEqual(result["status"], "identity-failed")
                self.assertEqual(result["post_identity"], "failed")
                self.assertEqual(self.python.read_bytes(), b"changed " + original)
                self.python.write_bytes(original)

    def test_interpretation_is_narrow_and_timeouts_remain_inconclusive(self):
        for outside, inside, status in (("signal", "signal", "failure-without-sandbox"),
                ("success", "signal", "sandbox-context-dependent-failure"),
                ("signal", "success", "inconclusive"), ("success", "timeout", "inconclusive"),
                ("timeout", "timeout", "inconclusive"), ("signal", "timeout", "inconclusive"),
                ("signal", "output-limit", "inconclusive"), ("nonzero-exit", "unavailable", "inconclusive")):
            outputs = [{"status": value, "cleanup": "not-needed"} for value in ("accepted", outside, inside)]
            with mock.patch.object(support, "_startup_child", side_effect=outputs):
                result = support._startup_differential(self.context())
            self.assertEqual(result["status"], status)
            self.assertIs(result["production_acceptance"], False)

    def test_total_budget_includes_identity_signature_children_and_postcheck(self):
        clock = [100.0]
        deadlines = []
        def verify(context, deadline):
            deadlines.append(deadline)
            if clock[0] >= deadline:
                raise TimeoutError
            clock[0] += 1
        def child(command, context, deadline, seconds, *args, **kwargs):
            self.assertLessEqual(deadline, 140.0)
            clock[0] += seconds + 2
            return {"status": "accepted" if kwargs.get("signature") else "success", "cleanup": "not-needed"}
        context = self.context()
        with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(support, "_startup_verify", side_effect=verify), \
             mock.patch.object(support, "_startup_child", side_effect=child):
            result = support._startup_differential(context)
        self.assertEqual(deadlines, [140, 130, 130, 145])
        self.assertEqual(result["elapsed_ms"], 31000)
        self.assertEqual(result["status"], "both-minimal-startups-succeeded")

    def test_slow_checks_prevent_later_launch_and_never_extend_total_deadline(self):
        clock = [100.0]
        context = self.context()
        def verify(context, deadline):
            if clock[0] >= deadline:
                raise TimeoutError
            clock[0] += 31
        with mock.patch.object(support.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(support, "_startup_verify", side_effect=verify), \
             mock.patch.object(support, "_startup_child", return_value={"status": "accepted", "cleanup": "not-needed"}) as child:
            result = support._startup_differential(context)
        self.assertEqual(child.call_count, 1)
        self.assertEqual(result["status"], "budget-exceeded")
        self.assertNotIn("outside", result)


class StartupChildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name).resolve()
        self.listener = support.owned_listener()
        self.addCleanup(self.listener.close)
        self.context = {"cwd": self.state, "env": support.minimal_env(self.state), "pass_fds": (self.listener.fileno(),)}

    def run_child(self, program, *, seconds=2, signature=False):
        command = [sys.executable, "-I", "-S", "-B", "-c", program]
        processes = []
        original = subprocess.Popen
        def spawn(*args, **kwargs):
            self.assertEqual(args[0], command)
            self.assertEqual(kwargs, {"stdin": subprocess.DEVNULL, "stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
                "cwd": self.state, "env": self.context["env"], "pass_fds": self.context["pass_fds"], "close_fds": True})
            process = original(*args, **kwargs)
            processes.append(process)
            return process
        with mock.patch.object(support.subprocess, "Popen", side_effect=spawn):
            result = support._startup_child(command, self.context, time.monotonic() + seconds + 2,
                                            seconds, 8192 if signature else 128, 8192 if signature else 4096,
                                            signature=signature)
        for process in processes:
            self.assertIsNotNone(process.poll())
            self.assertTrue(process.stdout.closed and process.stderr.closed)
        self.assertNotIn(SECRET, json.dumps(result))
        self.assertNotIn(program, json.dumps(result))
        return result

    def test_exact_marker_zero_exit_empty_stderr(self):
        self.assertEqual(self.run_child('print("dot-search-startup-v1")')["status"], "success")

    def test_wrong_marker_stderr_nonzero_signal_and_extra_output(self):
        for program, status in ((f'print("{SECRET}")', "wrong-output"),
                ('print("dot-search-startup-v1", end="")', "wrong-output"),
                (f'import os; print("dot-search-startup-v1"); os.write(2, b"{SECRET}")', "wrong-output"),
                ('raise SystemExit(27)', "nonzero-exit"),
                ('import os, signal; os.kill(os.getpid(), signal.SIGTERM)', "signal"),
                ('print("dot-search-startup-v1"); print("extra")', "wrong-output")):
            with self.subTest(status=status):
                result = self.run_child(program)
                self.assertEqual(result["status"], status)
                self.assertEqual(result["cleanup"], "not-needed")

    def test_stdout_and_stderr_overflow_are_capped_and_exact_child_reaped(self):
        for fd, length in ((1, 129), (2, 4097)):
            result = self.run_child(f'import os, time; os.write({fd}, b"x" * {length}); time.sleep(30)')
            self.assertEqual(result["status"], "output-limit")
            self.assertEqual(result["cleanup"], "killed-and-reaped")

    def test_signature_combined_cap_and_rejected_status(self):
        self.assertEqual(self.run_child('raise SystemExit(9)', signature=True)["status"], "rejected")
        self.assertEqual(self.run_child(f'print("{SECRET}")', signature=True)["status"], "accepted")
        result = self.run_child('import os, time; os.write(1, b"x" * 4096); os.write(2, b"y" * 4097); time.sleep(30)', signature=True)
        self.assertEqual(result["status"], "output-limit")
        self.assertEqual(result["cleanup"], "killed-and-reaped")

    def test_timeout_is_not_settlement(self):
        started = time.monotonic()
        result = self.run_child('import time; time.sleep(30)', seconds=0.05)
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(result["cleanup"], "killed-and-reaped")
        self.assertEqual(result["returncode"], -signal.SIGKILL)

    def test_spawn_failure_never_exposes_exception(self):
        with mock.patch.object(support.subprocess, "Popen", side_effect=OSError(SECRET)):
            result = support._startup_child(["unused"], self.context, time.monotonic() + 3, 1, 128, 4096)
        self.assertEqual(result, {"status": "unavailable", "returncode": None, "cleanup": "not-needed"})

    def test_unconfirmed_cleanup_closes_pipes_and_is_explicit(self):
        process = mock.Mock(pid=1234, returncode=None)
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired("hidden", 2)
        with mock.patch.object(support.subprocess, "Popen", return_value=process), \
             mock.patch.object(support.time, "monotonic", side_effect=[10, 20, 20]):
            result = support._startup_child(["unused"], self.context, 22, 1, 128, 4096)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(result["cleanup"], "unconfirmed")
        process.kill.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=2)
        process.stdout.close.assert_called_once_with()
        process.stderr.close.assert_called_once_with()

    def test_pipe_close_failure_still_closes_other_pipe(self):
        process = mock.Mock(pid=1234, returncode=-9)
        process.poll.return_value = -9
        process.stdout.close.side_effect = OSError(SECRET)
        with mock.patch.object(support.subprocess, "Popen", return_value=process), \
             mock.patch.object(support.time, "monotonic", side_effect=[10, 20, 20]):
            result = support._startup_child(["unused"], self.context, 22, 1, 128, 4096)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(result["cleanup"], "unconfirmed")
        process.stdout.close.assert_called_once_with()
        process.stderr.close.assert_called_once_with()
        self.assertNotIn(SECRET, json.dumps(result))

    def test_exact_environment_cwd_and_listener_are_inherited(self):
        program = 'import os, socket; '
        program += f'assert os.getcwd() == {str(self.state)!r}; '
        program += f'assert dict(os.environ) == {self.context["env"]!r}; '
        program += f's = socket.socket(fileno={self.listener.fileno()}); '
        if sys.platform == "darwin":
            program += 'assert s.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONNECTION_INFO, 1) == b"\\x01"; '
        else:
            program += 'assert s.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) == 1; '
        program += 'print("dot-search-startup-v1")'
        # Python can coerce the C locale by adding LC_CTYPE on the portable host.
        self.context["env"]["LC_CTYPE"] = "C.UTF-8"
        program = program.replace(repr(support.minimal_env(self.state)), repr(self.context["env"]))
        self.assertEqual(self.run_child(program)["status"], "success")
        support.assert_owned(self.listener.getsockname()[1])


class StartupOriginalFailureTests(unittest.TestCase):
    def test_native_probe_uses_exact_read_only_platform_listener_expression(self):
        # Parse the canary but execute only its allowlisted read-only expression.
        # Never import the native probe or execute its surrounding body.
        tree = ast.parse((ROOT / "Tests/Native/search_proxy_bootstrap_probe.py").read_text())
        block = next(node for node in tree.body if isinstance(node, ast.With)
                     and any(ast.unparse(item.context_expr) == "socket.socket(fileno=args.owned_listener)"
                             for item in node.items))
        index, assignment = next((index, node) for index, node in enumerate(block.body)
                                 if isinstance(node, ast.Assign)
                                 and [ast.unparse(target) for target in node.targets] == ["listening"])
        expression = ast.Expression(assignment.value)
        self.assertEqual(ast.unparse(expression),
            "listener.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONNECTION_INFO, 1) == b'\\x01' "
            "if sys.platform == 'darwin' else listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN) == 1")
        self.assertIsInstance(block.body[index + 1], ast.Assert)
        self.assertEqual(ast.unparse(block.body[index + 1].test), "listening")
        code = compile(expression, "<native-probe-listener-expression>", "eval")
        cases = (("darwin", (socket.IPPROTO_TCP, 0x106, 1),
                  (b"\x01", b"\x00", b"\x04", b"", b"\x01\x00")),
                 ("linux", (socket.SOL_SOCKET, socket.SO_ACCEPTCONN), (1, 0, 2)))
        for platform, query, states in cases:
            error = OSError(errno.ENOPROTOOPT, "unsupported socket option")
            for index, state in enumerate((*states, error)):
                with self.subTest(platform=platform, state=state):
                    listener = mock.Mock()
                    if state is error:
                        listener.getsockopt.side_effect = error
                    else:
                        listener.getsockopt.return_value = state
                    namespace = {"__builtins__": {}, "listener": listener, "socket": socket,
                                 "sys": mock.Mock(platform=platform)}
                    with mock.patch.object(socket, "TCP_CONNECTION_INFO", 0x106, create=True):
                        if state is error:
                            with self.assertRaises(OSError) as caught:
                                eval(code, namespace)
                            self.assertIs(caught.exception, error)
                        else:
                            self.assertIs(eval(code, namespace), index == 0)
                    listener.getsockopt.assert_called_once_with(*query)
                    listener.bind.assert_not_called()
                    listener.listen.assert_not_called()
                    listener.connect.assert_not_called()
                    listener.close.assert_not_called()

    def test_native_host_guard_requires_every_fixed_host_field(self):
        environment = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS",
                       "RUNNER_ARCH": "ARM64", "GITHUB_WORKFLOW": "Build-only native Search proxy canaries"}
        with mock.patch.object(support.sys, "platform", "darwin"), mock.patch.object(support.platform, "machine", return_value="arm64"):
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertTrue(support._startup_host())
            for key in environment:
                with mock.patch.dict(os.environ, {k: v for k, v in environment.items() if k != key}, clear=True):
                    self.assertFalse(support._startup_host())
            with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(support.platform, "machine", return_value="x86_64"):
                self.assertFalse(support._startup_host())
        with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(support.sys, "platform", "linux"):
            self.assertFalse(support._startup_host())

    def test_original_failure_fields_and_once_only_trigger(self):
        for returncode, stage, launches in ((-6, "profile-await-ready", 1), (0, "profile-await-ready", 0),
                (17, "profile-await-ready", 0), (None, "profile-await-ready", 0), (-6, "native-await-ready", 0)):
            process = mock.Mock()
            process.poll.return_value = returncode
            process._dot_startup_context = {"used": False}
            with mock.patch.object(support.select, "select", return_value=([], [], [])), \
                 mock.patch.object(support, "read_probe_progress", return_value={"status": "absent"}), \
                 mock.patch.object(support, "_startup_differential", return_value={"status": "both-minimal-startups-succeeded"}) as diff:
                error = support.event_failure(process, stage, "stdout-eof", stdout_bytes=3, settle=True, progress_state="unused")
                result = json.loads(str(error).removeprefix("native canary failed: "))
                self.assertEqual(diff.call_count, launches)
                support.event_failure(process, stage, "stdout-eof")
                self.assertEqual(diff.call_count, launches)
            self.assertEqual(result["returncode"], returncode)
            self.assertEqual(result["signal"], 6 if returncode == -6 else None)
            self.assertEqual(result["stdout_bytes_observed"], 3)
            self.assertEqual(result["stderr_bytes_sampled"], 0)
            self.assertEqual(result["probe_progress"], {"status": "absent"})
            self.assertEqual(result["reason"], "stdout-eof")
            self.assertIs(result["production_acceptance"], False)
            process.wait.assert_called_once_with(timeout=0.5)
            process.kill.assert_not_called()

    def test_original_stderr_and_progress_are_sampled_before_differential(self):
        process = mock.Mock()
        process.poll.return_value = -6
        process._dot_startup_context = {"used": False}
        order = []
        with mock.patch.object(support.select, "select", return_value=([process.stderr], [], [])), \
             mock.patch.object(support.os, "read", side_effect=lambda *args: order.append("stderr") or SECRET.encode()), \
             mock.patch.object(support, "read_probe_progress", side_effect=lambda *args: order.append("progress") or {"status": "absent"}), \
             mock.patch.object(support, "_startup_differential", side_effect=lambda *args: order.append("differential") or {"status": "inconclusive"}):
            error = support.event_failure(process, "profile-await-ready", "stdout-eof", progress_state="unused")
        self.assertEqual(order, ["stderr", "progress", "differential"])
        self.assertNotIn(SECRET, str(error))
        result = json.loads(str(error).removeprefix("native canary failed: "))
        self.assertEqual(result["stderr_bytes_sampled"], len(SECRET))

    def test_diagnostic_exception_cannot_replace_original_failure_or_leak_secret(self):
        process = mock.Mock()
        process.poll.return_value = -6
        process._dot_startup_context = {"used": False}
        with mock.patch.object(support.select, "select", return_value=([], [], [])), \
             mock.patch.object(support, "_startup_differential", side_effect=RuntimeError(SECRET)):
            error = support.event_failure(process, "profile-await-ready", "stdout-eof")
        self.assertNotIn(SECRET, str(error))
        result = json.loads(str(error).removeprefix("native canary failed: "))
        self.assertEqual(result["signal"], 6)
        self.assertEqual(result["startup_differential"]["status"], "unavailable")

    def test_existing_source_call_keeps_original_popen_arguments(self):
        tree = ast.parse((ROOT / "scripts/search_proxy_canary_support.py").read_text())
        drive = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "drive_probe")
        calls = [node for node in ast.walk(drive) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                 and node.func.attr == "Popen"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(ast.unparse(calls[0]),
            "subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=state, env=env if env is not None else minimal_env(state), pass_fds=pass_fds)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
