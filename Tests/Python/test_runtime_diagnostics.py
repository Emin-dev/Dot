"""Model-free checks of the stderr-to-allowlist privacy boundary."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[2] / 'Resources/Runtime/dot_runtime.py'
spec = importlib.util.spec_from_file_location('diagnostic_runtime', path)
runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)


class RuntimeDiagnosticTests(unittest.TestCase):
    def test_tail_is_bounded_even_for_one_large_write(self):
        tail = runtime.FailureTail(); tail.append(b'private' * 100000)
        self.assertEqual(len(tail.data), 8192)
        tail.append(b'last'); self.assertEqual(len(tail.data), 8192)
        self.assertTrue(tail.data.endswith(b'last'))
    def test_split_marker_produces_only_fixed_reason(self):
        tail = runtime.FailureTail(); tail.append(b'Bearer secret /private/path\nModuleNot')
        tail.append(b'FoundError: private_module')
        self.assertEqual(tail.reason(), 'module_missing')
    def test_unknown_output_never_becomes_a_diagnostic(self):
        tail = runtime.FailureTail(); tail.append(b'private transcript screenshot token')
        self.assertEqual(tail.reason(), 'process_exited')
    def test_exception_text_is_never_published(self):
        self.assertEqual(runtime.exception_reason(PermissionError('private secret')), 'permission_denied')
        self.assertEqual(runtime.exception_reason(ValueError('private secret')), 'startup_failed')
    def test_report_contains_only_fixed_fields(self):
        with patch('builtins.print') as output:
            runtime.report_failure('launcher', 'module_missing', 7)
        self.assertEqual(json.loads(output.call_args.args[0]), {
            'protocol': 1, 'event': 'failed', 'stage': 'launcher', 'reason': 'module_missing', 'exit_status': 7})
    def test_nonblocking_read_work_is_bounded(self):
        class Stream:
            def fileno(self): return 12
        tail = runtime.FailureTail()
        with patch.object(runtime.os, 'read', return_value=b'x' * 4096) as read:
            self.assertTrue(tail.drain(Stream()))
        self.assertEqual(read.call_count, 4); self.assertEqual(len(tail.data), 8192)
    def test_nonblocking_read_yields_and_eof_closes_watch(self):
        class Stream:
            def fileno(self): return 12
        tail = runtime.FailureTail()
        with patch.object(runtime.os, 'read', side_effect=BlockingIOError):
            self.assertTrue(tail.drain(Stream()))
        with patch.object(runtime.os, 'read', return_value=b''):
            self.assertFalse(tail.drain(Stream()))
