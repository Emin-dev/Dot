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
import stat
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

    def test_toolchain_fd_path_has_fixed_darwin_buffer_contract(self):
        raw = b'/Applications/Xcode_26.3.app\0'.replace(b'\0', b'\0')
        raw = raw.ljust(1024, b'\0')
        with patch.object(h.sys, 'platform', 'darwin'), patch.object(h.fcntl, 'fcntl', return_value=raw) as call:
            result = h.toolchain_fd_path(17)
        self.assertEqual(result, {'fd_path': '/Applications/Xcode_26.3.app', 'fd_path_error': None})
        call.assert_called_once_with(17, 50, b'\0' * 1024)

    def test_toolchain_fd_path_errors_are_bounded_observations(self):
        for output in (b'/short\0', b'x' * 1024, b'not-absolute\0'.ljust(1024, b'\0'),
                       b'/\xff\0'.ljust(1024, b'\0')):
            with self.subTest(output=output[:20]), patch.object(h.sys, 'platform', 'darwin'), \
                    patch.object(h.fcntl, 'fcntl', return_value=output):
                result = h.toolchain_fd_path(17)
                self.assertIsNone(result['fd_path'])
                self.assertIsNotNone(result['fd_path_error'])
        with patch.object(h.sys, 'platform', 'darwin'), \
                patch.object(h.fcntl, 'fcntl', side_effect=OSError(errno.EACCES, 'diagnostic denied')):
            result = h.toolchain_fd_path(17)
            self.assertEqual(result['fd_path_error']['errno'], errno.EACCES)
        with patch.object(h.sys, 'platform', 'linux'), patch.object(h.fcntl, 'fcntl') as call:
            self.assertIsNone(h.toolchain_fd_path(17)['fd_path'])
            call.assert_not_called()

    def test_toolchain_configuration_is_fixed_and_not_an_environment_dump(self):
        environment = {'ImageOS': 'macos15', 'ImageVersion': 'v' * 500, 'RUNNER_OS': 'macOS',
                       'RUNNER_ARCH': 'ARM64', 'UNRELATED_SECRET': 'must-not-appear'}
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(h.Path, 'resolve', side_effect=[Path(h.CLANG), Path(h.SDK)]), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            h.toolchain_configuration(h.Receipt())
        value = json.loads(output.getvalue())
        self.assertEqual(value['paths']['compiler']['configured'], h.CLANG)
        self.assertEqual(value['paths']['compiler']['resolved'], h.CLANG)
        self.assertEqual(value['paths']['sdk']['configured'], h.SDK)
        self.assertEqual(value['paths']['sdk']['resolved'], h.SDK)
        self.assertEqual(set(value['hosted_image']), {'ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH'})
        self.assertEqual(len(value['hosted_image']['ImageVersion']), 256)
        self.assertNotIn('UNRELATED_SECRET', output.getvalue())
        self.assertNotIn('must-not-appear', output.getvalue())
        with patch.object(h.Path, 'resolve', side_effect=FileNotFoundError(errno.ENOENT, 'missing')), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            h.toolchain_configuration(h.Receipt())
        self.assertEqual(json.loads(output.getvalue())['paths']['compiler']['resolution_error']['errno'], errno.ENOENT)

    def test_toolchain_diagnostics_preserve_exact_trust_predicates(self):
        tree = ast.parse(PATH.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == 'trusted_toolchain')
        predicates = [ast.unparse(node.args[0]) for node in ast.walk(function)
                      if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                      and node.func.id == 'check']
        self.assertCountEqual(predicates, ["str(resolved).startswith(DEVELOPER + '/')",
                                     'info.st_uid == 0 and (not info.st_mode & 2)',
                                     'info.st_uid == 0 and (not info.st_mode & 18)'])
        build = ast.get_source_segment(PATH.read_text(), next(node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == 'build'))
        self.assertIn('trusted_toolchain(CLANG, receipt)', build)
        self.assertIn('trusted_toolchain(SDK, receipt)', build)
        self.assertNotIn("['resolved']", build)

    def test_toolchain_rejection_reports_exact_held_node_without_bypass(self):
        def info(uid, mode, inode):
            return SimpleNamespace(st_uid=uid, st_gid=20, st_mode=stat.S_IFDIR | mode,
                                   st_dev=7, st_ino=inode)
        class HeldRoot:
            fds = [10, 11]
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def check(self): raise AssertionError('unsafe toolchain must not pass')
        for bad in (info(501, 0o755, 11), info(0, 0o777, 12)):
            with self.subTest(uid=bad.st_uid, mode=bad.st_mode), \
                    patch.object(h.Path, 'resolve', return_value=Path(h.CLANG)), \
                    patch.object(h.m, 'Root', return_value=HeldRoot()), \
                    patch.object(h.os, 'fstat', side_effect=[info(0, 0o755, 10), bad]), \
                    patch.object(h, 'toolchain_fd_path', return_value={
                        'fd_path': None, 'fd_path_error': {'type': 'OSError', 'errno': errno.EACCES}}), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaisesRegex(AssertionError, 'untrusted toolchain ancestry:') as caught:
                    h.trusted_toolchain(h.CLANG, h.Receipt())
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            node = records[-1]['node']
            self.assertEqual(node['held_path'], '/Applications')
            self.assertEqual(node['uid'], bad.st_uid)
            self.assertEqual(node['gid'], 20)
            self.assertEqual(node['mode'], format(stat.S_IMODE(bad.st_mode), '04o'))
            self.assertEqual(node['inode'], bad.st_ino)
            self.assertIn('"held_path": "/Applications"', str(caught.exception))
            self.assertIs(records[-1]['production_acceptance'], False)

    def test_toolchain_target_predicate_stays_stricter_than_ancestor(self):
        class HeldRoot:
            fds = [10]
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def check(self): raise AssertionError('unsafe target must not pass')
        root = SimpleNamespace(st_uid=0, st_gid=20, st_mode=stat.S_IFDIR | 0o775, st_dev=7, st_ino=10)
        for uid, mode in ((501, 0o755), (0, 0o775)):
            target = SimpleNamespace(st_uid=uid, st_gid=20, st_mode=stat.S_IFREG | mode, st_dev=7, st_ino=20)
            with self.subTest(uid=uid, mode=mode), patch.object(h.Path, 'resolve', return_value=Path(h.CLANG)), \
                    patch.object(h.m, 'Root', return_value=HeldRoot()), patch.object(h.os, 'fstat', return_value=root), \
                    patch.object(h.Path, 'stat', return_value=target), \
                    patch.object(h, 'toolchain_fd_path', return_value={'fd_path': '/', 'fd_path_error': None}), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaisesRegex(AssertionError, 'untrusted toolchain node:'):
                    h.trusted_toolchain(h.CLANG, h.Receipt())
            record = json.loads(output.getvalue().splitlines()[-1])
            self.assertEqual(record['role'], 'target_nofollow_stat')
            self.assertEqual(record['node']['uid'], uid)

    def run_verification_shell_fixture(self, canary_status, *, tee_status=0, swift_status=0, warning=False):
        # Run the actual shell control flow with inert temporary commands. These
        # fixtures never execute Swift, Xcode, codesign, a compiler or packaging.
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            root = Path(temporary); scripts = root / 'scripts'; scripts.mkdir()
            (scripts / 'verify_macos.sh').write_bytes((ROOT / 'scripts/verify_macos.sh').read_bytes())
            commands = root / 'commands'; commands.mkdir()
            logs = root / 'logs'; logs.mkdir()
            trace = root / 'trace'
            stub = r'''#!/bin/sh
name=${0##*/}
printf '%s\n' "$name $*" >> "$STUB_TRACE"
case "$name" in
  python3)
    case "$*" in
      *'print(sys.executable)'*) printf '%s\n' "$STUB_PYTHON" ;;
      *scripts/test_runtime_finalizer_native.py*)
        echo 'actual shell fixture canary diagnostic' >&2
        if [ "$STUB_WARNING" = 1 ]; then echo 'warning: shell fixture diagnostic' >&2; fi
        exit "$STUB_CANARY_STATUS" ;;
    esac ;;
  tee)
    /usr/bin/tee "$@"
    case "$*" in *runtime-finalizer-canary.log*) exit "$STUB_TEE_STATUS" ;; esac ;;
  swift) exit "$STUB_SWIFT_STATUS" ;;
esac
exit 0
'''
            for name in ('python3', 'xcrun', 'xcodebuild', 'swift', 'codesign', 'file', 'bash', 'tee'):
                path = commands / name; path.write_text(stub); path.chmod(0o700)
            environment = {'PATH': str(commands) + ':/usr/bin:/bin', 'TMPDIR': str(logs), 'LC_ALL': 'C',
                           'STUB_TRACE': str(trace), 'STUB_PYTHON': str(commands / 'python3'),
                           'STUB_CANARY_STATUS': str(canary_status), 'STUB_TEE_STATUS': str(tee_status),
                           'STUB_SWIFT_STATUS': str(swift_status), 'STUB_WARNING': '1' if warning else '0'}
            result = subprocess.run(['/bin/bash', str(scripts / 'verify_macos.sh')], env=environment,
                                    capture_output=True, timeout=10)
            return result, trace.read_text().splitlines()

    def test_failed_canary_keeps_status_runs_independent_lanes_and_blocks_packaging(self):
        result, trace = self.run_verification_shell_fixture(5, warning=True)
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        self.assertTrue(any(line == 'swift test' for line in trace))
        self.assertTrue(any('-configuration Debug' in line for line in trace))
        self.assertTrue(any('-configuration Release' in line for line in trace))
        self.assertFalse(any(line == 'bash build.sh' for line in trace))
        self.assertFalse(any(line.startswith('codesign ') for line in trace))
        self.assertIn(b'actual shell fixture canary diagnostic', result.stdout)
        self.assertIn(b'warning: shell fixture diagnostic', result.stdout)
        self.assertIn(b'FAIL: warning detected in verification before packaging', result.stdout)
        self.assertIn(b'packaging was not attempted', result.stdout)
        self.assertNotIn(b'PASS: all build/test/package', result.stdout)

    def test_canary_tee_failure_remains_mandatory_pipefail(self):
        result, trace = self.run_verification_shell_fixture(0, tee_status=9)
        self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
        self.assertTrue(any('-configuration Release' in line for line in trace))
        self.assertFalse(any(line == 'bash build.sh' for line in trace))
        self.assertNotIn(b'PASS: all build/test/package', result.stdout)

    def test_successful_canary_preserves_original_packaging_and_warning_gates(self):
        result, trace = self.run_verification_shell_fixture(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('bash build.sh', trace)
        self.assertTrue(any(line.startswith('codesign ') for line in trace))
        self.assertIn(b'PASS: all build/test/package', result.stdout)
        warning_result, _ = self.run_verification_shell_fixture(0, warning=True)
        self.assertEqual(warning_result.returncode, 1)
        self.assertIn(b'FAIL: warning detected', warning_result.stdout)
        self.assertNotIn(b'PASS: all build/test/package', warning_result.stdout)

    def test_unrelated_build_failure_is_not_suppressed(self):
        result, trace = self.run_verification_shell_fixture(0, swift_status=6)
        self.assertEqual(result.returncode, 6)
        self.assertFalse(any('-configuration Debug' in line for line in trace))
        self.assertNotIn('bash build.sh', trace)

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
