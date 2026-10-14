"""Real helper CLI deadline tests with isolated stalled-verifier seams.

Only the test process shortens the fixed production deadline. This does not
execute macOS sandboxing, native compilation, a real worker or real acceptance.
"""
import contextlib
import importlib.util
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Resources/Search/dot_search.py'


def cli_fixture(helper, mode):
    spec = importlib.util.spec_from_file_location('deadline_fixture', helper)
    search = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(search)
    search.PAYLOAD_VERIFY_SECONDS = 0.2  # Only this subprocess fixture alters time.
    if mode == 'blocked':
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    old_handler = signal.getsignal(signal.SIGALRM)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    def verify(_):
        os.write(2, b'V')
        if mode == 'failure': raise search.SearchFailure('payload_unverified')
        if mode == 'healthy': return
        time.sleep(60)
    def supervise(*_, **__):
        # The verification alarm must not survive into the real supervisor.
        if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0): return 90
        if signal.getsignal(signal.SIGALRM) != old_handler: return 91
        if signal.pthread_sigmask(signal.SIG_BLOCK, set()) != old_mask: return 92
        time.sleep(0.4)
        return 0
    with mock.patch.object(search, 'verify_payload', verify), mock.patch.object(search, 'supervise', supervise), \
            mock.patch.object(sys, 'argv', [str(helper), '--payload', '/synthetic', '--state-root', '/synthetic', '--owned-listener', '3', '--egress-port', '54321']):
        try:
            result = search.main()
        except Exception:
            search.send_event(sys.stdout.buffer, {'event': 'failed', 'reason': 'payload_unavailable'})
            result = 2
        raise SystemExit(result)


class VerificationDeadlineTests(unittest.TestCase):
    @contextlib.contextmanager
    def launch(self, mode='stall', full_output=False):
        output = None
        if full_output:
            read, write = os.pipe()
            output = (read, write)
            os.set_blocking(write, False)
            while True:
                try: os.write(write, b'X' * 4096)
                except BlockingIOError: break
            os.set_blocking(write, True)
        process = subprocess.Popen([sys.executable, '-I', '-B', str(Path(__file__).resolve()), '--cli', str(HELPER), mode],
            stdin=subprocess.PIPE, stdout=output[1] if output else subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([process.stderr], [], [], 3)[0], 'verifier seam not reached')
            self.assertEqual(os.read(process.stderr.fileno(), 1), b'V')
            yield process
        finally:
            if process.poll() is None: process.kill(); process.wait(timeout=3)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None: stream.close()
            if output:
                for descriptor in output: os.close(descriptor)

    def assert_expired(self, process):
        self.assertEqual(process.wait(timeout=2), 2)
        if process.stdout is not None: self.assertEqual(process.stdout.read(), b'')
        self.assertEqual(process.stderr.read(), b'')

    def test_stalled_verification_is_bounded_with_control_open(self):
        with self.launch() as process: self.assert_expired(process)

    def test_eof_during_verification_cannot_leave_helper_pending(self):
        with self.launch() as process:
            process.stdin.close()
            self.assert_expired(process)

    def test_ignored_and_blocked_inherited_alarm_cannot_disable_deadline(self):
        with self.launch('blocked') as process: self.assert_expired(process)

    def test_verification_failure_with_full_control_output_is_bounded(self):
        with self.launch('failure', full_output=True) as process:
            process.stdin.close()
            self.assert_expired(process)

    def test_alarm_cleared_before_supervisor_and_handler_mask_restored(self):
        with self.launch('healthy') as process:
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertEqual(process.stdout.read(), b'')
            self.assertEqual(process.stderr.read(), b'')

    def test_expiry_never_signals_unrelated_process(self):
        canary = subprocess.Popen([sys.executable, '-I', '-B', '-c', "import time; time.sleep(.7); print('unrelated alive')"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with self.launch() as process: self.assert_expired(process)
            output, errors = canary.communicate(timeout=3)
            self.assertEqual((canary.returncode, output, errors), (0, b'unrelated alive\n', b''))
        finally:
            if canary.poll() is None: canary.kill(); canary.communicate(timeout=2)

    def test_production_deadline_is_fixed_at_ten_seconds(self):
        spec = importlib.util.spec_from_file_location('deadline_constant_fixture', HELPER)
        search = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(search)
        self.assertEqual(search.PAYLOAD_VERIFY_SECONDS, 10)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--cli': cli_fixture(*sys.argv[2:])
    else: unittest.main()
