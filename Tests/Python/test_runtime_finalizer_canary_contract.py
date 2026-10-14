"""Portable contracts for a native capability harness, not native acceptance.

The actual Darwin command is run separately by verify_macos.sh. These tests do
not simulate successful macOS metadata, signing, dyld or sandbox observations.
"""
import ast
import base64
import contextlib
import copy
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / 'scripts/test_runtime_finalizer_native.py'
spec = importlib.util.spec_from_file_location('runtime_finalizer_canary_contract', PATH)
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


def successful(stdout=b''):
    return {'reason': None, 'returncode': 0, 'stdout': stdout, 'stderr': b'',
            'cleanup': {'complete': True, 'remaining_owned_processes': 0, 'open_output_pipes': 0}}


class CapabilityContractTests(unittest.TestCase):
    def test_receipts_are_explicitly_nonauthorizing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            h.Receipt().emit('test', sample=h.raw_record(b'actual raw\x00\n'))
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        value = json.loads(lines[0])
        self.assertIs(value['production_acceptance'], False)
        self.assertIs(value['owner_runtime_acceptance'], False)
        self.assertEqual(value['scope'], 'temporary_synthetic_fixture_only')
        self.assertEqual(value['kind'], 'runtime_finalizer_capability_canary')
        raw = base64.b64decode(value['sample']['base64'])
        self.assertEqual(raw, b'actual raw\x00\n')
        self.assertEqual(value['sample']['sha256'], h.m.digest(raw))
        self.assertEqual(value['sample']['bytes'], len(raw))

    def test_receipt_cannot_override_authority_boundary(self):
        for field in ('schema_version', 'kind', 'scope', 'production_acceptance', 'owner_runtime_acceptance'):
            with self.subTest(field=field), self.assertRaisesRegex(AssertionError, 'reserved receipt field'):
                h.Receipt().emit('test', **{field: True})

    def test_receipt_aggregate_is_bounded(self):
        receipt = h.Receipt(); receipt.bytes = h.RECEIPT_BYTES
        with self.assertRaisesRegex(AssertionError, 'receipt byte bound'):
            receipt.emit('test')

    def test_gate_failure_is_failure_not_skip(self):
        def unsupported():
            raise h.m.Rejected('UNSUPPORTED_REAL_CAPABILITY', h.m.UNSUPPORTED)
        receipt = h.Receipt()
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertFalse(receipt.gate('real', unsupported))
        record = json.loads(out.getvalue())
        self.assertEqual(record['status'], 'fail')
        self.assertEqual(record['code'], h.m.UNSUPPORTED)
        self.assertEqual(receipt.gates, {'real': 'fail'})

    def test_deadline_cannot_be_swallowed_as_gate_failure(self):
        def timed_out():
            raise h.CanaryDeadline('deadline')
        with self.assertRaises(h.CanaryDeadline):
            h.Receipt().gate('real', timed_out)

    def test_denial_requires_both_explicit_errno_results(self):
        self.assertEqual(h.validate_creation(successful(b'FORK_DENIED 1\nSPAWN_DENIED 13\n'), True),
                         ['FORK_DENIED 1', 'SPAWN_DENIED 13'])
        for raw in (b'', b'FORK_DENIED 1\n', b'FORK_DENIED 1\nSPAWN_OK 0\n',
                    b'FORK_DENIED 22\nSPAWN_DENIED 1\n', b'FORK_DENIED 1\nSPAWN_DENIED 1\nextra\n'):
            with self.subTest(raw=raw), self.assertRaises(AssertionError):
                h.validate_creation(successful(raw), True)

    def test_crash_timeout_cleanup_failure_never_counts_as_denial(self):
        original = successful(b'FORK_DENIED 1\nSPAWN_DENIED 1\n')
        mutations = [('returncode', -9), ('returncode', None), ('returncode', 73),
                     ('returncode', False), ('reason', 'deadline'), ('reason', 'incomplete_cleanup'),
                     ('stderr', b'failed\n')]
        for key, value in mutations:
            result = copy.deepcopy(original); result[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                h.validate_creation(result, True)
        for key, value in [('complete', False), ('remaining_owned_processes', 1), ('open_output_pipes', 1)]:
            result = copy.deepcopy(original); result['cleanup'][key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                h.validate_creation(result, True)

    def test_positive_controls_are_required_and_exact(self):
        h.validate_creation(successful(b'1\nFORK_OK 17\nSPAWN_OK 0\n'), False)
        for raw in (b'FORK_OK 17\nSPAWN_OK 0\n', b'1\nFORK_OK 0\nSPAWN_OK 0\n',
                    b'FORK_DENIED 1\nSPAWN_DENIED 1\n'):
            with self.subTest(raw=raw), self.assertRaises(AssertionError):
                h.validate_creation(successful(raw), False)

    def test_rejection_matches_reason_and_code(self):
        def rejected():
            raise h.m.Rejected('expected', h.m.INVALID)
        self.assertEqual(h.expect_rejected(rejected, 'expected', h.m.INVALID), {'reason': 'expected', 'code': 2})
        with self.assertRaises(AssertionError): h.expect_rejected(lambda: None, 'expected')
        with self.assertRaises(AssertionError): h.expect_rejected(rejected, 'different')
        with self.assertRaises(AssertionError): h.expect_rejected(rejected, 'expected', h.m.UNSUPPORTED)

    def test_no_production_approval_or_writer_calls(self):
        source = PATH.read_text()
        tree = ast.parse(source)
        called = {node.func.attr for node in ast.walk(tree)
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                  and isinstance(node.func.value, ast.Name) and node.func.value.id == 'm'}
        self.assertFalse(called & {'_commit_native_finalization', '_finalize', 'finalize',
                                  '_read_native_approval', '_native_marker'})
        self.assertTrue({'Root', 'tree', '_native_empty_xattrs', '_NativeToolset', '_ns_profile',
                         '_native_run_bounded', '_verify_native_static', '_parse_native_static_evidence',
                         '_ns_system_cache', '_native_system_targets', 'write_new', 'no_replace'} <= called)
        self.assertNotIn('unittest.mock', source)
        self.assertNotIn('runtime-native-build.json', source)
        self.assertNotIn('native-acceptance.json', source)
        self.assertNotIn('runtime-manifest.json', source)

    def test_fixed_compiler_signer_and_process_fixture(self):
        source = PATH.read_text()
        fixture = (ROOT / h.FIXTURE).read_text()
        self.assertIn('/Applications/Xcode_26.3.app/Contents/Developer', source)
        self.assertIn("'-Wall', '-Wextra', '-Werror'", source)
        self.assertIn("'--sign', '-'", source)
        self.assertIn("'--timestamp=none'", source)
        self.assertIn('dlsym(library, "sandbox_init")', fixture)
        self.assertIn('dlopen("/usr/lib/libsandbox.1.dylib",', fixture)
        self.assertIn('"/usr/sbin/sysctl", "-n", "hw.optional.arm64"', fixture)
        self.assertIn('posix_spawn(&child, spawn_argv[0]', fixture)
        self.assertNotIn('execvp(', fixture)
        self.assertNotIn('system(', fixture)
        self.assertNotIn('setsid(', fixture)
        self.assertNotIn('setpgid(', fixture)
        self.assertNotIn('diagnostic ignored', fixture)
        self.assertNotIn('-Wno-', source)

    def test_profile_is_passed_unmodified_after_positive_control(self):
        source = ast.get_source_segment(PATH.read_text(), next(node for node in ast.parse(PATH.read_text()).body
            if isinstance(node, ast.FunctionDef) and node.name == 'creation'))
        self.assertLess(source.index("'creation_positive'"), source.index('m._ns_profile('))
        self.assertIn("[binary, 'deny', profile]", source)
        self.assertNotIn('.replace(', source)

    def test_fixture_metadata_uses_fixed_darwin_abi(self):
        source = PATH.read_text()
        self.assertNotIn('os.setxattr(', source)
        self.assertNotIn('os.removexattr(', source)
        self.assertIn("ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)", source)
        self.assertIn('operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]', source)
        self.assertIn('ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]', source)
        self.assertIn('result = operation(encoded, name, value, len(value), 0, 1)', source)
        self.assertIn('result = operation(encoded, name, 1)', source)
        self.assertIn('error = ctypes.get_errno()', source)
        if sys.platform != 'darwin':
            with self.assertRaisesRegex(h.m.Rejected, 'Darwin fixture xattr API required'):
                h.fixture_xattr('/not-a-fixture')

    def test_fixture_xattr_failure_injection_is_fail_closed(self):
        # Portable ABI/error-path injection only. No successful native metadata
        # observation or production finalizer primitive is substituted here.
        class FailingOperation:
            def __init__(self): self.calls = []
            def __call__(self, *args):
                self.calls.append(args)
                return -1
        for remove in (False, True):
            operation = FailingOperation()
            library = SimpleNamespace(setxattr=operation, removexattr=operation)
            with self.subTest(remove=remove), patch.object(h.sys, 'platform', 'darwin'), \
                    patch.object(h.ctypes, 'CDLL', return_value=library) as loader, \
                    patch.object(h.ctypes, 'get_errno', return_value=errno.EACCES):
                with self.assertRaises(OSError) as caught:
                    h.fixture_xattr('/tmp/test-only-unaccessed-fixture', remove=remove)
                self.assertEqual(caught.exception.errno, errno.EACCES)
                loader.assert_called_once_with('/usr/lib/libSystem.B.dylib', use_errno=True)
                self.assertEqual(operation.restype, h.ctypes.c_int)
                self.assertEqual(len(operation.argtypes), 3 if remove else 6)
                expected = (b'/tmp/test-only-unaccessed-fixture', b'com.dot.runtime-canary')
                expected += (1,) if remove else (b'test-only', 9, 0, 1)
                self.assertEqual(operation.calls, [expected])

    def test_fixture_xattr_missing_api_does_not_skip(self):
        with patch.object(h.sys, 'platform', 'darwin'), \
                patch.object(h.ctypes, 'CDLL', side_effect=OSError(errno.ENOENT, 'missing library')):
            with self.assertRaises(OSError): h.fixture_xattr('/tmp/test-only-unaccessed-fixture')
        with patch.object(h.sys, 'platform', 'darwin'), \
                patch.object(h.ctypes, 'CDLL', return_value=SimpleNamespace()):
            with self.assertRaises(AttributeError): h.fixture_xattr('/tmp/test-only-unaccessed-fixture')

    def test_lifecycle_uses_reviewed_helper_and_real_children(self):
        source = PATH.read_text()
        fixture = (ROOT / h.FIXTURE).read_text()
        self.assertIn("getattr(m, '_native_darwin_exited_singleton', None)", source)
        self.assertIn("subprocess.Popen([str(base / 'payload/canary'), mode]", source)
        self.assertIn("('lifecycle-exit', True)", source)
        self.assertIn("('lifecycle-live', False)", source)
        self.assertIn("('lifecycle-mixed', False)", source)
        self.assertIn('child.wait(timeout=12)', source)
        self.assertIn('helper(child) is False', source)
        self.assertIn('helper(nonchild) is False', source)
        self.assertIn('const struct timespec lifetime = {10, 0}', fixture)
        self.assertIn("'enumeration_failure_injected': False", source)
        self.assertNotIn('proc_listpids', source)

    def test_existing_verify_pipeline_has_failing_native_gate(self):
        source = (ROOT / 'scripts/verify_macos.sh').read_text()
        line = 'python3 -B scripts/test_runtime_finalizer_native.py 2>&1 | tee "$LOGS/runtime-finalizer-canary.log"'
        self.assertEqual(source.count(line), 1)
        self.assertIn('set -euo pipefail', source)
        self.assertNotIn('|| true', line)

    def test_hard_limits_and_internal_modes(self):
        self.assertLessEqual(h.TOTAL_SECONDS, 180)
        self.assertLessEqual(h.COMMAND_SECONDS, 30)
        self.assertLessEqual(h.OUTPUT_BYTES, 65536)
        self.assertLessEqual(h.RECEIPT_BYTES, 4_000_000)
        self.assertEqual(set(h.CRASHES), {'crash_after_write', 'crash_after_publish', 'crash_after_commit'})
        self.assertEqual(len(h.GATES), 7)
        with self.assertRaises(AssertionError): h.main(['--arbitrary-command'])
        with self.assertRaises(AssertionError): h.main(['--transaction-worker', '0', 'resume'])

    def test_non_darwin_native_cli_is_explicit_failure(self):
        if sys.platform == 'darwin' and os.uname().machine == 'arm64':
            # Actual Darwin execution is a separate mandatory verify_macos gate.
            return
        result = subprocess.run([sys.executable, '-I', '-B', str(PATH)], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, h.m.UNSUPPORTED)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(records[-1]['status'], 'fail')
        self.assertIn('no portable substitute', records[-1]['error'])
        self.assertFalse(any(record.get('status') == 'pass' for record in records))

    def test_actual_portable_primitive_crash_replay(self):
        # This really spawns workers and calls platform IO primitives. On Linux
        # it proves only portable harness behavior, never Darwin capabilities.
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            context, receipt = h.make_context(), h.Receipt()
            with contextlib.redirect_stdout(io.StringIO()) as out:
                details = h.transactions(context, receipt, Path(temporary))
            self.assertEqual(len(details['cases']), 3)
            self.assertIs(details['production_transaction_exercised'], False)
            self.assertIs(details['power_loss_durability_proven'], False)
            commands = [json.loads(line) for line in out.getvalue().splitlines()]
            self.assertEqual(len(commands), 12)
            self.assertTrue(all(record['result']['cleanup']['complete'] for record in commands))
            self.assertEqual([record['result']['returncode'] for record in commands],
                             [0, 81, 0, 0, 0, 82, 0, 0, 0, 83, 0, 0])

    def test_worker_refuses_unmarked_directory_and_unknown_mode(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            with h.m.Root(temporary) as root:
                with self.assertRaises(AssertionError): h.transaction_worker(root.fd, 'not-a-mode')
                with self.assertRaises(FileNotFoundError): h.transaction_worker(root.fd, 'resume')


if __name__ == '__main__':
    unittest.main()
