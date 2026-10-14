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
import plistlib
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

    def test_hosted_owner_exception_is_fixed_and_strictly_inside_xcode(self):
        def info(uid, mode):
            return SimpleNamespace(st_uid=uid, st_mode=stat.S_IFDIR | mode)
        for path in (h.XCODE, h.CLANG, h.SDK):
            for uid in (0, 501):
                with self.subTest(path=path, uid=uid):
                    self.assertTrue(h.toolchain_owner(info(uid, 0o755), path))
                    for mode in (0o775, 0o757, 0o777, 0o4755, 0o2755, 0o1755):
                        self.assertFalse(h.toolchain_owner(info(uid, mode), path))
            for uid in (1, 500, 502, 1000):
                self.assertFalse(h.toolchain_owner(info(uid, 0o755), path))
        for path in ('/', '/Applications', h.XCODE + '-other/clang', '/tmp/clang'):
            self.assertFalse(h.toolchain_owner(info(501, 0o755), path))
            self.assertTrue(h.toolchain_owner(info(0, 0o775), path))
            self.assertFalse(h.toolchain_owner(info(0, 0o777), path))

    def test_policy_pins_exact_observed_compiler_image_and_requirement(self):
        self.assertEqual(h.COMPILER_PIN, {'bytes': 272034048,
            'sha256': '15339439a6be4a9d33d281ec040a7e0092190b1c8d7de5f94d824b50ffae0769'})
        self.assertEqual(h.COMPILER_REQUIREMENT, '=identifier "com.apple.clang" and anchor apple')
        self.assertEqual(h.HOSTED_IMAGE, {'ImageOS': 'macos15', 'ImageVersion': '20260907.0337.1',
            'RUNNER_OS': 'macOS', 'RUNNER_ARCH': 'ARM64', 'GITHUB_ACTIONS': 'true'})
        source = PATH.read_text()
        self.assertIn("'--no-default-config'", source)
        self.assertIn('no hostile same-UID', ' '.join(h.TOOLCHAIN_ASSUMPTIONS))
        self.assertIn('not a cryptographic closure inventory', ' '.join(h.TOOLCHAIN_ASSUMPTIONS))
        owner_source = ast.get_source_segment(source, next(node for node in ast.parse(source).body
            if isinstance(node, ast.FunctionDef) and node.name == 'toolchain_owner'))
        self.assertNotIn('os.getuid(', owner_source)
        self.assertNotIn('os.geteuid(', owner_source)
        self.assertNotIn('os.chown(', source)

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



class CompilerIdentityDiagnosticContractTests(unittest.TestCase):
    """Portable mock runner contracts only, never native signing acceptance."""

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as directory:
            base = Path(directory)
            developer = base / 'Xcode_26.3.app/Contents/Developer'
            compiler = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
            compiler.parent.mkdir(parents=True)
            compiler.write_bytes(b'portable test-only compiler-shaped bytes\x00')
            compiler.chmod(0o755)
            with patch.object(h, 'DEVELOPER', str(developer)), patch.object(h, 'CLANG', str(compiler)):
                yield base, compiler, h.make_context()

    def observe(self, context, effect=None):
        def result(argv, deadline, **kwargs):
            value = successful(b'portable mock output only\x00\n')
            value.update(argv=argv, stderr=b'Identifier=mock-only\nAuthority=not-native-evidence\n')
            return value
        with patch.object(h.m, '_native_run_bounded', side_effect=effect or result) as runner, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertIsNone(h.compiler_identity_diagnostic(context, h.Receipt()))
        return [json.loads(line) for line in output.getvalue().splitlines()], runner

    def test_exact_fixed_read_only_argv_and_positive_environment_bounds(self):
        with self.fixture() as (_, compiler, context):
            records, runner = self.observe(context)
            self.assertEqual([call.args[0] for call in runner.call_args_list], [
                ['/usr/bin/codesign', '-d', '--verbose=4', '--requirements', '-', str(compiler)],
                ['/usr/bin/codesign', '--verify', '--strict', '--verbose=4',
                 '--test-requirement', '=anchor apple', str(compiler)]])
            for call in runner.call_args_list:
                self.assertLessEqual(call.args[1], context.budget.deadline)
                self.assertEqual(call.kwargs, {'pass_fds': (), 'env': h.m._NS_ENV, 'cap': h.OUTPUT_BYTES})
            snapshots = [r for r in records if r['event'] == 'compiler_identity_snapshot']
            self.assertEqual([r['phase'] for r in snapshots], ['before', 'after'])
            self.assertEqual(snapshots[0]['node'], snapshots[1]['node'])
            self.assertEqual(snapshots[0]['node']['sha256'], h.m.digest(compiler.read_bytes()))
            for key in ('device', 'inode', 'uid', 'gid', 'mode', 'bytes', 'mtime_ns', 'ctime_ns'):
                self.assertIn(key, snapshots[0]['node'])
            commands = [r for r in records if r['event'] == 'command']
            self.assertEqual(len(commands), 2)
            self.assertEqual(base64.b64decode(commands[0]['result']['stdout']['base64']),
                             b'portable mock output only\x00\n')
            self.assertEqual(base64.b64decode(commands[0]['result']['stderr']['base64']),
                             b'Identifier=mock-only\nAuthority=not-native-evidence\n')
            self.assertEqual(commands[0]['result']['returncode'], 0)
            self.assertEqual(records[-1]['status'], 'observed')
            self.assertIs(records[-1]['authorizes_build'], False)
            self.assertIs(records[-1]['compiler_identity_policy_applied'], False)
            self.assertTrue(all(r['production_acceptance'] is False for r in records))

    def test_missing_nonregular_oversized_and_outside_symlink_never_spawn(self):
        for kind in ('missing', 'directory', 'oversized', 'symlink_outside', 'prefix_collision'):
            with self.subTest(kind=kind), self.fixture() as (base, compiler, context):
                compiler.unlink()
                if kind == 'directory': compiler.mkdir()
                elif kind == 'oversized':
                    with compiler.open('wb') as stream: stream.truncate(h.COMPILER_DIAGNOSTIC_BYTES + 1)
                elif kind in ('symlink_outside', 'prefix_collision'):
                    target = (base / 'outside') if kind == 'symlink_outside' else Path(h.DEVELOPER + '-other/clang')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b'outside')
                    compiler.symlink_to(target)
                records, runner = self.observe(context)
                runner.assert_not_called()
                self.assertEqual(records[-1]['status'], 'fail')
                self.assertIs(records[-1]['authorizes_build'], False)

    def test_symlink_after_resolution_is_rejected_without_following(self):
        with self.fixture() as (base, compiler, context):
            target = base / 'outside'; target.write_bytes(b'outside')
            compiler.unlink(); compiler.symlink_to(target)
            with patch.object(h.Path, 'resolve', return_value=compiler):
                records, runner = self.observe(context)
            runner.assert_not_called()
            self.assertEqual(records[-1]['status'], 'fail')
            self.assertIn('regular file required', records[-1]['error'])

    def test_mutation_during_signing_is_rejected_and_hashes_retained(self):
        with self.fixture() as (_, compiler, context):
            def mutate(argv, deadline, **kwargs):
                compiler.write_bytes(b'mutated portable bytes')
                result = successful(); result['argv'] = argv
                return result
            records, runner = self.observe(context, mutate)
            self.assertEqual(runner.call_count, 1)
            snapshots = [r for r in records if r['event'] == 'compiler_identity_snapshot']
            self.assertEqual(len(snapshots), 2)
            self.assertNotEqual(snapshots[0]['node']['sha256'], snapshots[1]['node']['sha256'])
            self.assertEqual(records[-1]['status'], 'fail')
            self.assertIn('compiler changed', records[-1]['error'])

    def test_bad_exit_limit_timeout_cleanup_and_warning_preserve_raw_failure(self):
        for field, value in (('returncode', 1), ('reason', 'output_limit'), ('reason', 'deadline'),
                             ('cleanup', {'complete': False, 'remaining_owned_processes': 1, 'open_output_pipes': 1}),
                             ('stderr', b'warning: mock signing diagnostic\n')):
            with self.subTest(field=field, value=value), self.fixture() as (_, _, context):
                def failed(argv, deadline, **kwargs):
                    result = successful(b'raw failure\x00\n'); result.update(argv=argv)
                    result[field] = value
                    return result
                records, runner = self.observe(context, failed)
                self.assertEqual(runner.call_count, 1)
                command = next(r for r in records if r['event'] == 'command')
                self.assertEqual(base64.b64decode(command['result']['stdout']['base64']), b'raw failure\x00\n')
                self.assertEqual(records[-1]['status'], 'fail')
                self.assertIs(records[-1]['authorizes_build'], False)

    def test_expired_budget_never_spawns_and_whole_canary_deadline_propagates(self):
        with self.fixture() as (_, _, context):
            context.budget.deadline = 0
            records, runner = self.observe(context)
            runner.assert_not_called()
            self.assertEqual(records[-1]['status'], 'fail')
        with self.fixture() as (_, _, context), \
                patch.object(context.budget, 'check', side_effect=h.CanaryDeadline('whole canary deadline')):
            with self.assertRaises(h.CanaryDeadline): self.observe(context)

    def test_observation_never_overrides_separate_fixture_policy_failure(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(h, 'toolchain_configuration'), \
                patch.object(h, 'compiler_identity_diagnostic', return_value=True) as diagnostic, \
                patch.object(h, 'fixture_toolchain', side_effect=AssertionError('unsupported compiler bytes/hash')) as trust, \
                patch.object(h, 'run') as command, contextlib.redirect_stdout(io.StringIO()) as output:
            context = h.make_context(); receipt = h.Receipt()
            self.assertFalse(receipt.gate('fixture_build', lambda: h.build(context, receipt, Path(directory))))
            diagnostic.assert_called_once_with(context, receipt)
            trust.assert_called_once_with(context, receipt)
            command.assert_not_called()
            self.assertEqual(receipt.gates, {'fixture_build': 'fail'})
            self.assertIn('unsupported compiler bytes/hash', output.getvalue())

    def test_diagnostic_has_no_caller_path_or_trust_state(self):
        tree = ast.parse(PATH.read_text())
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                        and n.name == 'compiler_identity_diagnostic')
        self.assertEqual([a.arg for a in function.args.args], ['context', 'receipt'])
        source = ast.get_source_segment(PATH.read_text(), function)
        self.assertNotIn('os.environ', source)
        self.assertNotIn('receipt.gates', source)
        self.assertNotIn('chown', source)
        self.assertNotIn('chmod', source)
        self.assertNotIn('=anchor apple generic', source)
        self.assertNotIn('return True', source)
        self.assertEqual(h.COMPILER_DIAGNOSTIC_BYTES, 512 * 1024 * 1024)
        self.assertEqual(h.COMPILER_DIAGNOSTIC_SECONDS, 30)

class HostedCompilerPolicyContractTests(unittest.TestCase):
    """Portable control-flow/filesystem tests; mock signing is never native evidence."""

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as directory:
            base = Path(directory)
            xcode = base / 'Xcode_26.3.app'
            developer = xcode / 'Contents/Developer'
            compiler = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
            sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
            version = xcode / 'Contents/version.plist'
            compiler.parent.mkdir(parents=True)
            sdk.mkdir(parents=True)
            compiler.write_bytes(b'portable compiler-shaped fixture, not native code')
            compiler.chmod(0o755)
            (sdk / 'SDKSettings.json').write_text('{"Version":"26.2"}')
            version.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '26.3',
                                               'ProductBuildVersion': '17C529'}))
            original_owner = h.toolchain_owner
            def portable_owner(info, path):
                # Only ownership/external-ancestor assumptions are injected;
                # held edges, no-follow IO, hashes and mutation checks are real.
                if not Path(path).is_relative_to(xcode):
                    return True
                return original_owner(SimpleNamespace(st_uid=501, st_mode=info.st_mode), path)
            with contextlib.ExitStack() as stack:
                for key, value in {'XCODE': str(xcode), 'DEVELOPER': str(developer),
                                   'CLANG': str(compiler), 'SDK': str(sdk),
                                   'XCODE_VERSION': str(version), 'COMPILER_PIN': h.source_pin(compiler)}.items():
                    stack.enter_context(patch.object(h, key, value))
                stack.enter_context(patch.object(h, 'toolchain_owner', side_effect=portable_owner))
                stack.enter_context(patch.dict(os.environ, h.HOSTED_IMAGE, clear=True))
                yield base, compiler, sdk, version, h.make_context()

    @staticmethod
    def signing_result(argv, deadline, **kwargs):
        # Deliberately irrelevant display text: authorization must be the exact
        # codesign requirement argument and successful command contract.
        return {**successful(b'portable mock, not a native signing result'), 'argv': argv}

    def exercise(self, context, operation=None, effect=None):
        with patch.object(h.m, '_native_run_bounded', side_effect=effect or self.signing_result) as runner, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            receipt = h.Receipt()
            error = None
            try:
                with h.fixture_toolchain(context, receipt) as selected:
                    if operation:
                        operation(selected)
            except Exception as caught:
                error = caught
        return error, [json.loads(line) for line in output.getvalue().splitlines()], runner

    def test_signature_requires_exact_identity_anchor_and_post_build_snapshots(self):
        with self.fixture() as (_, compiler, sdk, _, context):
            chosen = []
            error, records, runner = self.exercise(context, chosen.append)
            self.assertIsNone(error)
            self.assertEqual(len(chosen), 1)
            self.assertEqual(chosen[0][:2], (str(compiler), str(sdk)))
            self.assertLessEqual(chosen[0][2], context.budget.deadline)
            self.assertEqual(runner.call_count, 1)
            call = runner.call_args
            self.assertEqual(call.args[0], ['/usr/bin/codesign', '--verify', '--strict', '--verbose=4',
                '--test-requirement', '=identifier "com.apple.clang" and anchor apple', str(compiler)])
            self.assertLessEqual(call.args[1], context.budget.deadline)
            self.assertEqual(call.kwargs, {'pass_fds': (), 'env': h.m._NS_ENV, 'cap': h.OUTPUT_BYTES})
            snapshots = [r for r in records if r['event'] == 'fixture_toolchain_snapshot']
            self.assertEqual([r['phase'] for r in snapshots], ['before', 'after_signature', 'after_build'])
            self.assertTrue(all(r['nodes'] == snapshots[0]['nodes'] for r in snapshots))
            policy = next(r for r in records if r['event'] == 'fixture_toolchain_policy')
            self.assertEqual(policy['assumptions'], h.TOOLCHAIN_ASSUMPTIONS)
            self.assertIs(policy['production_acceptance'], False)
            self.assertIs(policy['owner_runtime_acceptance'], False)
            self.assertIs(policy['authorizes_synthetic_fixture_build'], True)

    def test_image_missing_or_drift_never_opens_toolchain_or_spawns(self):
        for key in h.HOSTED_IMAGE:
            for value in ('unsupported', None):
                with self.subTest(key=key, value=value), self.fixture() as (_, _, _, _, context):
                    if value is None: os.environ.pop(key)
                    else: os.environ[key] = value
                    with patch.object(h.m, 'Root') as root:
                        error, _, runner = self.exercise(context)
                    self.assertIn('unsupported hosted toolchain image', str(error))
                    root.assert_not_called()
                    runner.assert_not_called()

    def test_wrong_hash_size_sdk_version_or_xcode_build_never_spawns(self):
        for kind in ('hash', 'size', 'sdk_version', 'xcode_version', 'xcode_build', 'sdk_duplicate_version'):
            with self.subTest(kind=kind), self.fixture() as (_, _, sdk, version, context):
                if kind == 'hash': h.COMPILER_PIN = {**h.COMPILER_PIN, 'sha256': '0' * 64}
                elif kind == 'size': h.COMPILER_PIN = {**h.COMPILER_PIN, 'bytes': h.COMPILER_PIN['bytes'] + 1}
                elif kind == 'sdk_version': (sdk / 'SDKSettings.json').write_text('{"Version":"27.0"}')
                elif kind == 'sdk_duplicate_version':
                    (sdk / 'SDKSettings.json').write_text('{"Version":"27.0","Version":"26.2"}')
                else:
                    metadata = plistlib.loads(version.read_bytes())
                    metadata['CFBundleShortVersionString' if kind == 'xcode_version' else 'ProductBuildVersion'] = 'other'
                    version.write_bytes(plistlib.dumps(metadata))
                error, _, runner = self.exercise(context)
                self.assertIsNotNone(error)
                runner.assert_not_called()

    def test_alias_nonregular_hardlink_and_unsafe_mode_never_spawn(self):
        for kind in ('compiler_alias', 'sdk_alias', 'ancestor_alias', 'directory', 'hardlink',
                     'group_writable', 'world_writable', 'sdk_writable', 'metadata_alias', 'metadata_oversized'):
            with self.subTest(kind=kind), self.fixture() as (base, compiler, sdk, _, context):
                if kind == 'compiler_alias':
                    target = compiler.with_name('other-clang'); compiler.rename(target); compiler.symlink_to(target)
                elif kind == 'sdk_alias':
                    target = sdk.with_name('other-sdk'); sdk.rename(target); sdk.symlink_to(target, target_is_directory=True)
                elif kind == 'ancestor_alias':
                    target = compiler.parent.with_name('other-bin'); compiler.parent.rename(target)
                    compiler.parent.symlink_to(target, target_is_directory=True)
                elif kind == 'directory': compiler.unlink(); compiler.mkdir()
                elif kind == 'hardlink': os.link(compiler, base / 'second-link')
                elif kind == 'group_writable': compiler.chmod(0o775)
                elif kind == 'world_writable': compiler.parent.chmod(0o757)
                elif kind == 'sdk_writable': sdk.chmod(0o775)
                elif kind == 'metadata_alias':
                    metadata = sdk / 'SDKSettings.json'; target = base / 'settings'; metadata.rename(target)
                    metadata.symlink_to(target)
                elif kind == 'metadata_oversized':
                    (sdk / 'SDKSettings.json').write_bytes(b' ' * (h.TOOLCHAIN_METADATA_BYTES + 1))
                error, _, runner = self.exercise(context)
                self.assertIsNotNone(error)
                runner.assert_not_called()

    def test_signature_wrong_identity_bad_exit_timeout_warning_or_cleanup_blocks_body(self):
        for field, value in (('returncode', 1), ('returncode', False), ('reason', 'deadline'),
                             ('reason', 'output_limit'), ('stderr', b'warning: portable failure'),
                             ('cleanup', {'complete': False, 'remaining_owned_processes': 1, 'open_output_pipes': 0})):
            with self.subTest(field=field, value=value), self.fixture() as (_, _, _, _, context):
                def rejected(argv, deadline, **kwargs):
                    result = self.signing_result(argv, deadline, **kwargs); result[field] = value
                    return result
                body = []
                error, records, runner = self.exercise(context, body.append, rejected)
                self.assertIsNotNone(error)
                self.assertFalse(body)
                self.assertEqual(runner.call_count, 1)
                self.assertFalse(any(r['event'] == 'fixture_toolchain_policy' for r in records))

    def test_changes_during_signature_or_build_are_rejected(self):
        for when in ('signature', 'build'):
            for kind in ('compiler_bytes', 'compiler_mode', 'compiler_replace', 'ancestor_replace',
                         'sdk_settings', 'sdk_replace', 'xcode_version'):
                with self.subTest(when=when, kind=kind), self.fixture() as (_, compiler, sdk, version, context):
                    def mutate():
                        if kind == 'compiler_bytes': compiler.write_bytes(b'changed compiler bytes')
                        elif kind == 'compiler_mode': compiler.chmod(0o700)
                        elif kind == 'compiler_replace':
                            data = compiler.read_bytes(); compiler.unlink(); compiler.write_bytes(data); compiler.chmod(0o755)
                        elif kind == 'ancestor_replace':
                            old = compiler.parent.with_name('old-bin'); compiler.parent.rename(old)
                            compiler.parent.mkdir()
                            (compiler.parent / compiler.name).write_bytes((old / compiler.name).read_bytes())
                        elif kind == 'sdk_settings':
                            (sdk / 'SDKSettings.json').write_text('{"Version":"26.2","changed":true}')
                        elif kind == 'sdk_replace': sdk.rename(sdk.with_name('old-sdk')); sdk.mkdir()
                        elif kind == 'xcode_version':
                            metadata = plistlib.loads(version.read_bytes()); metadata['Changed'] = True
                            version.write_bytes(plistlib.dumps(metadata))
                    def signing(argv, deadline, **kwargs):
                        if when == 'signature': mutate()
                        return self.signing_result(argv, deadline, **kwargs)
                    body = []
                    def operation(selected):
                        body.append(selected)
                        if when == 'build': mutate()
                    error, _, runner = self.exercise(context, operation, signing)
                    self.assertIsNotNone(error)
                    self.assertEqual(runner.call_count, 1)
                    self.assertEqual(len(body), 0 if when == 'signature' else 1)

    def test_expired_policy_and_whole_canary_deadlines_cannot_admit(self):
        with self.fixture() as (_, _, _, _, context):
            context.budget.deadline = 0
            error, _, runner = self.exercise(context)
            self.assertIsNotNone(error); runner.assert_not_called()
        with self.fixture() as (_, _, _, _, context), \
                patch.object(context.budget, 'check', side_effect=h.CanaryDeadline('whole deadline')):
            with self.assertRaises(h.CanaryDeadline): self.exercise(context)

    def test_whole_deadline_during_signing_or_build_is_not_swallowed_by_cleanup(self):
        for when in ('signature', 'build'):
            with self.subTest(when=when), self.fixture() as (_, _, _, _, context):
                def expired(*args, **kwargs):
                    raise h.CanaryDeadline('whole deadline')
                runner = expired if when == 'signature' else self.signing_result
                operation = expired if when == 'build' else None
                with self.assertRaises(h.CanaryDeadline): self.exercise(context, operation, runner)

    def test_unconfigured_toolchain_path_is_not_a_general_user_tool_allowance(self):
        with self.fixture() as (base, _, _, _, _), patch.object(h.m, 'Root') as root:
            with self.assertRaisesRegex(AssertionError, 'unconfigured toolchain path'):
                with h.trusted_toolchain(str(base / 'other-tool'), h.Receipt()): pass
            root.assert_not_called()


class DescriptorDiagnosticContractTests(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            base = Path(temporary)
            (base / 'payload').mkdir(mode=0o700)
            canary = base / 'payload/canary'; canary.write_bytes(b'portable diagnostic fixture')
            tools = {}
            for name in ('lipo', 'otool', 'codesign', 'sysctl', 'sandbox'):
                path = base / name; path.write_bytes(b'portable tool fixture')
                tools[name] = str(path)
            with patch.dict(h.m._NS_TOOLS, tools, clear=True):
                yield base, canary, tools, h.make_context()

    def observe(self, context, base):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertIsNone(h.descriptor_identity_diagnostic(context, h.Receipt(), base))
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_actual_held_metadata_reports_hardlinks_without_reading_or_admitting(self):
        with self.fixture() as (base, canary, tools, context):
            os.link(tools['lipo'], base / 'lipo-alias')
            with patch.object(h.os, 'read', side_effect=AssertionError('diagnostic read bytes')), \
                    patch.object(h.m, 'regular_at') as reader, \
                    patch.object(h.m, '_native_run_bounded') as runner:
                records = self.observe(context, base)
                reader.assert_not_called(); runner.assert_not_called()
            self.assertEqual(len(records), 6)
            self.assertEqual([r['role'] for r in records], ['synthetic_canary', 'fixed_tool_lipo',
                'fixed_tool_otool', 'fixed_tool_codesign', 'fixed_tool_sysctl', 'fixed_tool_sandbox'])
            for record in records:
                self.assertEqual(record['status'], 'observed')
                self.assertFalse(record['authorizes_inspection'])
                self.assertFalse(record['production_acceptance'])
                self.assertEqual(record['nofollow'], record['after'])
                for key in record['nofollow']:
                    self.assertEqual(record['held'][key], record['nofollow'][key])
                self.assertEqual(record['held']['file_type'], 'regular')
            self.assertEqual(records[0]['held']['nlink'], 1)
            self.assertEqual(records[1]['held']['nlink'], 2)
            with h.m.Root(base) as root, self.assertRaisesRegex(h.m.Rejected, 'single-link regular file required'):
                h.m.regular_at(root.fd, 'lipo', context.budget)

    def test_nonregular_nodes_are_observed_but_never_opened(self):
        with self.fixture() as (base, canary, tools, context):
            Path(tools['lipo']).unlink(); Path(tools['lipo']).symlink_to(canary)
            Path(tools['otool']).unlink(); os.mkfifo(tools['otool'], 0o600)
            Path(tools['codesign']).unlink(); Path(tools['codesign']).mkdir()
            with patch.object(h.os, 'open', wraps=os.open) as opener:
                records = self.observe(context, base)
            for record, kind in zip(records[1:4], ('symlink', 'fifo', 'directory')):
                self.assertEqual(record['nofollow']['file_type'], kind)
                self.assertIsNone(record['held'])
                self.assertEqual(record['status'], 'observed')
            self.assertFalse(any(call.args[0] in ('lipo', 'otool', 'codesign')
                                 for call in opener.call_args_list))

    def test_missing_node_is_bounded_diagnostic_and_remaining_nodes_are_observed(self):
        with self.fixture() as (base, canary, tools, context):
            Path(tools['lipo']).unlink()
            records = self.observe(context, base)
            self.assertEqual(records[1]['status'], 'fail')
            self.assertEqual(records[1]['errno'], errno.ENOENT)
            self.assertIsNone(records[1]['nofollow'])
            self.assertLessEqual(len(records[1]['error']), 512)
            self.assertEqual(records[-1]['status'], 'observed')

    def test_held_descriptor_closes_on_success_and_observation_failure(self):
        for failure in (False, True):
            with self.subTest(failure=failure), self.fixture() as (base, _, _, context):
                descriptors = []
                def fd_path(fd):
                    descriptors.append(fd)
                    if failure: raise OSError(errno.EIO, 'portable injected diagnostic failure')
                    return {'fd_path': None, 'fd_path_error': {'type': 'portable_only', 'errno': None}}
                with patch.object(h, 'toolchain_fd_path', side_effect=fd_path):
                    records = self.observe(context, base)
                self.assertEqual(len(descriptors), 6)
                for fd in descriptors:
                    with self.assertRaises(OSError) as caught: os.fstat(fd)
                    self.assertEqual(caught.exception.errno, errno.EBADF)
                self.assertTrue(all(r['status'] == ('fail' if failure else 'observed') for r in records))

    def test_mutation_is_reported_and_does_not_forge_stable_metadata(self):
        with self.fixture() as (base, canary, _, context):
            def mutate(fd):
                canary.write_bytes(b'changed portable diagnostic fixture')
                return {'fd_path': None, 'fd_path_error': {'type': 'portable_only', 'errno': None}}
            with patch.object(h, 'toolchain_fd_path', side_effect=mutate):
                records = self.observe(context, base)
            self.assertEqual(records[0]['status'], 'fail')
            self.assertEqual(records[0]['code'], h.m.MUTATION)
            self.assertIn('filesystem mutation', records[0]['error'])

    def test_whole_and_local_deadlines_are_not_downgraded_to_observations(self):
        with self.fixture() as (base, _, _, context), \
                patch.object(context.budget, 'check', side_effect=h.CanaryDeadline('whole deadline')):
            with self.assertRaises(h.CanaryDeadline): self.observe(context, base)
        with self.fixture() as (base, _, _, context), \
                patch.object(h.time, 'monotonic', side_effect=[1, 1, 7]):
            with self.assertRaisesRegex(AssertionError, 'descriptor diagnostic deadline exceeded'):
                self.observe(context, base)

    def test_original_payload_gate_still_rejects_hardlinked_canary_after_diagnostic(self):
        with self.fixture() as (base, canary, _, context):
            os.link(canary, base / 'canary-alias')
            with patch.object(h.m, '_NativeToolset') as tools, \
                    patch.object(h, 'fixed_tool_identity_diagnostic'), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    self.assertRaisesRegex(h.m.Rejected, 'single-link regular file required'):
                h.static_inspection(context, h.Receipt(), base)
            tools.assert_not_called()
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(records[0]['held']['nlink'], 2)
            self.assertEqual(len(records), 6)
            self.assertFalse(any(r['event'] == 'descriptor_payload_tree' for r in records))

    def test_payload_tree_completion_is_recorded_before_original_toolset_rejection(self):
        with self.fixture() as (base, _, _, context):
            with patch.object(h.m, '_NativeToolset', side_effect=h.m.Rejected('single-link regular file required')), \
                    patch.object(h, 'fixed_tool_identity_diagnostic'), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    self.assertRaisesRegex(h.m.Rejected, 'single-link regular file required'):
                h.static_inspection(context, h.Receipt(), base)
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(records[-1]['event'], 'descriptor_payload_tree')
            self.assertEqual(records[-1]['status'], 'observed')
            self.assertEqual(records[-1]['entries'], 2)

    def test_diagnostic_paths_and_bounds_are_fixed_without_acceptance_calls(self):
        source = PATH.read_text()
        function = next(node for node in ast.parse(source).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'descriptor_identity_diagnostic')
        body = ast.get_source_segment(source, function)
        self.assertIn("base / 'payload/canary'", body)
        self.assertIn('m._NS_TOOLS.items()', body)
        self.assertIn('len(targets) == 6', body)
        self.assertIn('os.open(path.name, m.FLAGS, dir_fd=root.fd)', body)
        self.assertNotIn('os.environ', body)
        self.assertNotIn('.resolve(', body)
        self.assertNotIn('regular_at(', body)
        self.assertNotIn('_native_run_bounded(', body)
        self.assertLessEqual(h.DESCRIPTOR_DIAGNOSTIC_SECONDS, 5)


class FixedToolIdentityDiagnosticContractTests(unittest.TestCase):
    """Synthetic ownership/signatures/mount flags; real bounded descriptor IO."""

    @contextlib.contextmanager
    def fixture(self, owner=0):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            base = Path(temporary)
            system = base / 'system'; system.mkdir()
            paths = {}
            for role in h.FIXED_TOOL_DIAGNOSTIC_PATHS:
                path = system / role; path.write_bytes(b'portable mock system file\x00')
                path.chmod(0o755); paths[role] = str(path)
            developer = base / 'Xcode.app/Contents/Developer'
            toolchain = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
            toolchain.mkdir(parents=True)
            selected = {}
            for role in ('lipo', 'otool'):
                path = toolchain / role; path.write_bytes(b'portable mock selected tool\x00')
                path.chmod(0o755); selected[role] = path
            original_stat, original_fstat = os.stat, os.fstat

            def metadata(info):
                values = {key: getattr(info, key) for key in dir(info) if key.startswith('st_')}
                values.update(st_uid=owner, st_gid=0)
                # Synthetic external-ancestor protection only; leaf modes and
                # all held-edge/inode/byte mutation checks remain real.
                if stat.S_ISDIR(info.st_mode): values['st_mode'] &= ~0o022
                return SimpleNamespace(**values)

            with patch.dict(h.FIXED_TOOL_DIAGNOSTIC_PATHS, paths, clear=True), \
                    patch.object(h, 'DEVELOPER', str(developer)), \
                    patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_APPLICATIONS', str(base)), \
                    patch.object(h.os, 'stat', side_effect=lambda *a, **k: metadata(original_stat(*a, **k))), \
                    patch.object(h.os, 'fstat', side_effect=lambda fd: metadata(original_fstat(fd))), \
                    patch.object(h.os, 'fstatvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY)):
                yield base, paths, developer, selected, h.make_context()

    def result(self, paths, developer, selected, argv):
        executable = argv[3]
        if executable == paths['xcode_select']:
            stdout, stderr = str(developer).encode() + b'\n', b''
        elif executable == paths['xcrun']:
            stdout, stderr = str(selected[argv[-1]]).encode() + b'\n', b''
        else:
            self.assertEqual(executable, paths['codesign'])
            stdout, stderr = b'', b'Identifier=portable.mock.only\nAuthority=not-native-evidence\n'
        return {**successful(stdout), 'stderr': stderr, 'argv': argv}

    def observe(self, fixture, effect=None):
        base, paths, developer, selected, context = fixture
        descriptors = []
        def descriptor(fd):
            descriptors.append(fd)
            return {'fd_path': None, 'fd_path_error': {'type': 'portable_mock_only', 'errno': None}}
        def command(argv, deadline, **kwargs):
            if effect is not None:
                value = effect(argv, deadline, kwargs)
                if value is not None: return value
            return self.result(paths, developer, selected, argv)
        with patch.object(h.m, '_native_run_bounded', side_effect=command) as runner, \
                patch.object(h, 'toolchain_fd_path', side_effect=descriptor), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            receipt = h.Receipt()
            self.assertIsNone(h.fixed_tool_identity_diagnostic(context, receipt))
            self.assertEqual(receipt.gates, {})
        for fd in descriptors:
            with self.assertRaises(OSError) as error: os.fstat(fd)
            self.assertEqual(error.exception.errno, errno.EBADF)
        return [json.loads(line) for line in output.getvalue().splitlines()], runner

    def test_fixed_commands_raw_evidence_and_no_delegated_execution(self):
        with self.fixture() as fixture:
            _, paths, developer, selected, context = fixture
            records, runner = self.observe(fixture)
            self.assertEqual(runner.call_count, 22)
            scope = records[0]
            self.assertEqual(scope['event'], 'fixed_tool_identity_scope')
            self.assertEqual(scope['discovery_context'], 'scrubbed_system_default')
            self.assertEqual(scope['inspector_environment'], h.m._NS_ENV)
            self.assertNotIn('DEVELOPER_DIR', scope['inspector_environment'])
            self.assertEqual(scope['fixture_configured_developer'], str(developer))
            commands = [r for r in records if r['event'] == 'command']
            self.assertEqual(len(commands), 22)
            self.assertEqual([r['result']['argv'][3:] for r in commands if 'find_' in r['label']],
                             [[paths['xcrun'], '--find', 'lipo'], [paths['xcrun'], '--find', 'otool']])
            self.assertEqual(next(r for r in commands if r['label'] == 'fixed_tool_selected_developer')
                             ['result']['argv'][3:], [paths['xcode_select'], '-p'])
            for call in runner.call_args_list:
                argv = call.args[0]
                self.assertEqual(argv[:2], [paths['sandbox'], '-p'])
                self.assertIn(argv[3], (paths['codesign'], paths['xcrun'], paths['xcode_select']))
                self.assertIn('(deny file-write*)', argv[2])
                self.assertIn('(deny network*)', argv[2])
                self.assertIn('(deny process-fork)', argv[2])
                execution = argv[2].split('(allow process-exec ', 1)[1].split('(allow sysctl-read)', 1)[0]
                self.assertNotIn(str(developer), execution)
                self.assertLessEqual(call.args[1], context.budget.deadline)
                self.assertEqual(call.kwargs, {'pass_fds': (), 'env': h.m._NS_ENV, 'cap': h.OUTPUT_BYTES})
            verifies = [r for r in commands if r['label'].endswith('_apple_anchor')]
            self.assertEqual(len(verifies), 9)
            for row in verifies:
                self.assertEqual(row['result']['argv'][4:-1], ['--verify', '--strict', '--all-architectures',
                                 '--verbose=4', '--test-requirement', '=anchor apple'])
                self.assertEqual(base64.b64decode(row['result']['stderr']['base64']),
                                 b'Identifier=portable.mock.only\nAuthority=not-native-evidence\n')
            snapshots = [r for r in records if r['event'] == 'fixed_tool_identity_snapshot']
            self.assertEqual(len(snapshots), 18)
            for role in (*paths, 'selected_lipo', 'selected_otool'):
                pair = [r for r in snapshots if r['role'] == role]
                self.assertEqual([r['phase'] for r in pair], ['before', 'after'])
                self.assertEqual(pair[0]['snapshot'], pair[1]['snapshot'])
                self.assertEqual(pair[0]['snapshot']['sha256'], h.m.digest(Path(pair[0]['resolved']).read_bytes()))
                self.assertTrue(all(row['flags'] & os.ST_RDONLY for row in pair[0]['snapshot']['mounts']))
            self.assertTrue(all(r['production_acceptance'] is False and r['owner_runtime_acceptance'] is False
                                for r in records))
            self.assertTrue(all(r['authorizes_delegated_execution'] is False for r in records
                                if 'authorizes_delegated_execution' in r))

    def test_hardlinked_fixed_tools_are_observed_but_generic_reader_still_rejects(self):
        with self.fixture() as fixture:
            base, paths, _, _, context = fixture
            Path(paths['otool']).unlink(); os.link(paths['lipo'], paths['otool'])
            records, _ = self.observe(fixture)
            pair = [r for r in records if r['event'] == 'fixed_tool_identity_snapshot'
                    and r['phase'] == 'before' and r['role'] in ('lipo', 'otool')]
            self.assertEqual([r['snapshot']['nlink'] for r in pair], [2, 2])
            self.assertEqual(pair[0]['snapshot']['identity'], pair[1]['snapshot']['identity'])
            with h.m.Root(Path(paths['lipo']).parent) as root, self.assertRaisesRegex(h.m.Rejected, 'single-link'):
                h.m.regular_at(root.fd, 'lipo', context.budget)

    def test_internal_selected_symlink_is_observed_without_becoming_an_executable(self):
        with self.fixture() as fixture:
            _, paths, _, selected, _ = fixture
            target = selected['lipo'].with_name('llvm-lipo')
            selected['lipo'].rename(target); selected['lipo'].symlink_to(target.name)
            records, runner = self.observe(fixture)
            event = next(r for r in records if r['event'] == 'fixed_tool_dispatch' and r['role'] == 'lipo')
            self.assertEqual(event['configured'], str(selected['lipo']))
            self.assertEqual(event['resolved'], str(target))
            self.assertFalse(any(call.args[0][3] == str(target) for call in runner.call_args_list))

    def test_unsafe_missing_and_nonregular_bootstrap_never_executes(self):
        for kind in ('missing', 'directory', 'fifo', 'symlink', 'writable', 'setuid', 'nonexecutable', 'oversized'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                base, paths, _, _, _ = fixture
                path = Path(paths['codesign'])
                if kind in ('missing', 'directory', 'fifo', 'symlink'): path.unlink()
                if kind == 'directory': path.mkdir()
                elif kind == 'fifo': os.mkfifo(path)
                elif kind == 'symlink': path.symlink_to(paths['lipo'])
                elif kind == 'writable': path.chmod(0o775)
                elif kind == 'setuid': path.chmod(0o4755)
                elif kind == 'nonexecutable': path.chmod(0o644)
                elif kind == 'oversized':
                    with path.open('wb') as stream: stream.truncate(h.FIXED_TOOL_DIAGNOSTIC_FILE_BYTES + 1)
                records, runner = self.observe(fixture)
                runner.assert_not_called()
                self.assertTrue(any(r.get('status') == 'fail' and r.get('role') == 'codesign' for r in records))
        with self.fixture(owner=501) as fixture:
            _, runner = self.observe(fixture)
            runner.assert_not_called()

    def test_failed_apple_anchor_cannot_authorize_discovery(self):
        with self.fixture() as fixture:
            _, paths, _, _, _ = fixture
            def effect(argv, deadline, kwargs):
                if argv[3] == paths['codesign'] and '--verify' in argv and argv[-1] == paths['xcrun']:
                    return {**successful(), 'argv': argv, 'returncode': 3,
                            'stderr': b'Identifier=com.apple.fake\nAuthority=Apple\n'}
            records, runner = self.observe(fixture, effect)
            self.assertFalse(any(call.args[0][3] == paths['xcrun'] for call in runner.call_args_list))
            self.assertTrue(any(r.get('role') == 'xcrun' and r.get('status') == 'fail' for r in records))
            self.assertTrue(any(r.get('role') == 'xcrun' and r.get('apple_anchor_verified') is False for r in records))

    def test_discovery_output_is_bounded_canonical_and_contained(self):
        for kind in ('outside', 'prefix_collision', 'relative', 'multiline', 'nul', 'bad_utf8', 'oversized', 'wrong_name'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                base, paths, developer, selected, _ = fixture
                outside = base / 'lipo'; outside.write_bytes(b'outside must not be inspected')
                outputs = {'outside': str(outside).encode() + b'\n',
                           'prefix_collision': str(developer).encode() + b'-other/Toolchains/lipo\n',
                           'relative': b'lipo\n', 'multiline': b'/a\n/b\n', 'nul': b'/a\x00\n',
                           'bad_utf8': b'/\xff\n', 'oversized': b'/' + b'a' * 4096 + b'\n',
                           'wrong_name': str(selected['otool']).encode() + b'\n'}
                def effect(argv, deadline, kwargs):
                    if argv[3:] == [paths['xcrun'], '--find', 'lipo']:
                        return {**successful(outputs[kind]), 'argv': argv}
                records, runner = self.observe(fixture, effect)
                self.assertFalse(any(r.get('event') == 'fixed_tool_identity_snapshot'
                                     and r.get('role') == 'selected_lipo' for r in records))
                self.assertFalse(any(call.args[0][-1] == str(outside) for call in runner.call_args_list))
                self.assertTrue(any(r.get('role') == 'selected_lipo' and r.get('status') == 'fail' for r in records))

    def test_selected_escape_and_alias_retarget_never_authorize_or_execute(self):
        for kind in ('outside', 'retarget'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                base, paths, _, selected, _ = fixture
                outside = base / 'outside'; outside.write_bytes(b'outside')
                target = selected['lipo'].with_name('llvm-lipo')
                selected['lipo'].rename(target)
                selected['lipo'].symlink_to(outside if kind == 'outside' else target)
                def effect(argv, deadline, kwargs):
                    if kind == 'retarget' and argv[3] == paths['codesign'] and argv[-1] == str(target):
                        selected['lipo'].unlink(); selected['lipo'].symlink_to(outside)
                records, runner = self.observe(fixture, effect)
                self.assertTrue(any(r.get('role') == 'selected_lipo' and r.get('status') == 'fail' for r in records))
                self.assertFalse(any(call.args[0][3] in (str(target), str(outside)) for call in runner.call_args_list))
                self.assertFalse(any(call.args[0][-1] == str(outside) for call in runner.call_args_list))

    def test_wrong_developer_selection_does_not_invoke_xcrun(self):
        with self.fixture() as fixture:
            _, paths, _, _, _ = fixture
            def effect(argv, deadline, kwargs):
                if argv[3] == paths['xcode_select']:
                    return {**successful(b'/Applications/Other.app/Contents/Developer\n'), 'argv': argv}
            records, runner = self.observe(fixture, effect)
            self.assertFalse(any(call.args[0][3] == paths['xcrun'] for call in runner.call_args_list))
            self.assertTrue(any(r.get('role') == 'dispatch' and r.get('status') == 'fail' for r in records))

    def test_default_xcode_can_differ_from_fixture_without_authorizing_execution(self):
        with self.fixture() as fixture:
            _, _, developer, _, _ = fixture
            with patch.object(h, 'DEVELOPER', '/Applications/Xcode_26.3.app/Contents/Developer'):
                records, runner = self.observe(fixture)
            scope = records[0]
            self.assertEqual(scope['fixture_configured_developer'], '/Applications/Xcode_26.3.app/Contents/Developer')
            dispatch = [r for r in records if r['event'] == 'fixed_tool_dispatch']
            self.assertEqual(len(dispatch), 2)
            self.assertTrue(all(r['developer'] == str(developer) and
                                r['selection_context'] == 'scrubbed_system_default' for r in dispatch))

    def test_clt_and_canonical_selected_developer_alias_are_read_only_observations(self):
        for kind in ('clt', 'alias'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                base, paths, developer, selected, context = fixture
                if kind == 'clt':
                    replacement = base / 'CommandLineTools'
                    (replacement / 'usr/bin').mkdir(parents=True)
                    for role in ('lipo', 'otool'):
                        selected[role].rename(replacement / 'usr/bin' / role)
                        selected[role] = replacement / 'usr/bin' / role
                    fixture = (base, paths, replacement, selected, context)
                    with patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_CLT', str(replacement)):
                        records, runner = self.observe(fixture)
                else:
                    real_app = base / 'Xcode_16.4.app'
                    (base / 'Xcode.app').rename(real_app)
                    (base / 'Xcode.app').symlink_to(real_app.name)
                    records, runner = self.observe(fixture)
                dispatch = [r for r in records if r['event'] == 'fixed_tool_dispatch']
                self.assertEqual(len(dispatch), 2)
                self.assertTrue(all(r['authorizes_delegated_execution'] is False for r in dispatch))
                self.assertFalse(any(call.args[0][3] in [r['resolved'] for r in dispatch]
                                     for call in runner.call_args_list))

    def test_changed_selected_developer_is_reported(self):
        with self.fixture() as fixture:
            _, paths, developer, _, _ = fixture
            selections = 0
            def effect(argv, deadline, kwargs):
                nonlocal selections
                if argv[3] == paths['xcode_select']:
                    selections += 1
                    if selections == 2:
                        return {**successful(b'/Applications/Xcode_17.app/Contents/Developer\n'), 'argv': argv}
            records, _ = self.observe(fixture, effect)
            self.assertEqual(selections, 2)
            self.assertTrue(any(r.get('role') == 'dispatch' and 'changed during discovery' in r.get('error', '')
                                for r in records))

    def test_full_byte_digest_catches_mutation_even_with_hidden_metadata_change(self):
        with self.fixture() as fixture:
            _, paths, _, _, _ = fixture
            changed = False
            def effect(argv, deadline, kwargs):
                nonlocal changed
                if argv[3] == paths['codesign'] and argv[-1] == paths['lipo'] and not changed:
                    path = Path(paths['lipo']); data = path.read_bytes()
                    path.write_bytes(b'x' * len(data)); changed = True
            with patch.object(h.m, 'same_node'):
                records, _ = self.observe(fixture, effect)
            snapshots = [r for r in records if r['event'] == 'fixed_tool_identity_snapshot' and r['role'] == 'lipo']
            self.assertEqual(len(snapshots), 2)
            self.assertNotEqual(snapshots[0]['snapshot']['sha256'], snapshots[1]['snapshot']['sha256'])
            self.assertTrue(any(r.get('role') == 'lipo' and 'bytes/metadata/mounts changed' in r.get('error', '')
                                for r in records))

    def test_system_path_and_mount_mutation_are_detected(self):
        for kind in ('bytes', 'replace', 'ancestor', 'mount'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                base, paths, _, _, _ = fixture
                def effect(argv, deadline, kwargs):
                    path = Path(paths['lipo'])
                    if kind == 'bytes': path.write_bytes(b'mutated')
                    elif kind == 'replace':
                        replacement = path.with_name('replacement'); replacement.write_bytes(path.read_bytes())
                        replacement.chmod(0o755); replacement.replace(path)
                    elif kind == 'ancestor':
                        path.parent.rename(base / 'old-system'); path.parent.mkdir()
                    else: h.os.fstatvfs.return_value = SimpleNamespace(f_flag=0)
                records, runner = self.observe(fixture, effect)
                self.assertEqual(runner.call_count, 1)
                self.assertTrue(any(r.get('status') == 'fail' for r in records))
                self.assertFalse(any(r.get('apple_anchor_verified') is True for r in records))

    def test_resource_failures_preserve_raw_evidence_without_discovery(self):
        for field, value in (('returncode', 1), ('reason', 'deadline'), ('reason', 'output_limit'),
                             ('cleanup', {'complete': False, 'remaining_owned_processes': 1, 'open_output_pipes': 1})):
            with self.subTest(field=field), self.fixture() as fixture:
                _, paths, _, _, _ = fixture
                def effect(argv, deadline, kwargs):
                    result = {**successful(b'raw mock failure\x00'), 'argv': argv}; result[field] = value
                    return result
                records, runner = self.observe(fixture, effect)
                self.assertFalse(any(call.args[0][3] in (paths['xcrun'], paths['xcode_select'])
                                     for call in runner.call_args_list))
                command = next(r for r in records if r['event'] == 'command')
                self.assertEqual(base64.b64decode(command['result']['stdout']['base64']), b'raw mock failure\x00')

    def test_aggregate_and_deadline_bounds_stop_without_admission(self):
        with self.fixture() as fixture, patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_TOTAL_BYTES', 1):
            records, runner = self.observe(fixture)
            runner.assert_not_called()
            self.assertTrue(any('byte bound' in r.get('error', '') for r in records))
        with self.fixture() as fixture:
            fixture[-1].budget.deadline = 0
            _, runner = self.observe(fixture); runner.assert_not_called()
        with self.fixture() as fixture, \
                patch.object(fixture[-1].budget, 'check', side_effect=h.CanaryDeadline('whole deadline')):
            with self.assertRaises(h.CanaryDeadline): self.observe(fixture)

    def test_exhausted_aggregate_never_starts_another_read_or_eof_sentinel(self):
        for limit in (0, 26, 52):
            with self.subTest(limit=limit), self.fixture() as fixture, \
                    patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_TOTAL_BYTES', limit):
                original_read = os.read
                observations, consumed = [], 0
                def read(fd, amount):
                    nonlocal consumed
                    self.assertGreater(limit - consumed, 0)
                    self.assertLessEqual(amount, limit - consumed)
                    data = original_read(fd, amount)
                    observations.append((amount, len(data))); consumed += len(data)
                    return data
                with patch.object(h.os, 'read', side_effect=read):
                    records, _ = self.observe(fixture)
                self.assertEqual(consumed, limit)
                self.assertEqual(observations, [(26, 26)] * (limit // 26))
                self.assertTrue(any('aggregate byte bound before read' in r.get('error', '') for r in records))

    def test_each_chunk_obeys_exact_remaining_aggregate_allowance(self):
        with self.fixture() as fixture:
            _, paths, _, _, _ = fixture
            limit = 1024 * 1024 + 17
            Path(paths['codesign']).write_bytes(b'x' * limit)
            original_read = os.read
            observations, consumed = [], 0
            def read(fd, amount):
                nonlocal consumed
                self.assertGreater(limit - consumed, 0)
                self.assertLessEqual(amount, min(1024 * 1024, limit - consumed))
                data = original_read(fd, amount)
                observations.append((amount, len(data))); consumed += len(data)
                return data
            with patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_TOTAL_BYTES', limit), \
                    patch.object(h.os, 'read', side_effect=read):
                _, runner = self.observe(fixture)
            runner.assert_not_called()
            self.assertEqual(consumed, limit)
            self.assertEqual(observations, [(1024 * 1024, 1024 * 1024), (17, 17)])

    def test_insufficient_aggregate_rejects_known_file_before_any_read(self):
        with self.fixture() as fixture, patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_TOTAL_BYTES', 24), \
                patch.object(h.os, 'read', side_effect=AssertionError('no aggregate capacity')) as reader:
            records, runner = self.observe(fixture)
            reader.assert_not_called(); runner.assert_not_called()
            self.assertTrue(any('aggregate byte bound before read' in r.get('error', '') for r in records))

    def test_optional_diagnostic_skips_without_reading_or_spawning_when_reserve_would_be_spent(self):
        for remaining in (10, 80, 87):
            with self.subTest(remaining=remaining), self.fixture() as fixture, \
                    patch.object(h.time, 'monotonic', return_value=100), \
                    patch.object(h.m, 'Root') as root, patch.object(h.os, 'read') as reader:
                fixture[-1].budget.deadline = 100 + remaining
                records, runner = self.observe(fixture)
                root.assert_not_called(); reader.assert_not_called(); runner.assert_not_called()
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]['status'], 'skipped_for_budget')
                self.assertEqual(records[0]['remaining_ms'], remaining * 1000)
                self.assertEqual(records[0]['original_gate_reserve_seconds'], 80)
                self.assertFalse(records[0]['authorizes_inspection'])

    def test_timeout_and_cleanup_leave_original_gate_reserve_intact(self):
        with self.fixture() as fixture:
            context = fixture[-1]; now = [100.0]; context.budget.deadline = 195
            deadlines = []
            def timeout(argv, deadline, kwargs):
                deadlines.append(deadline)
                self.assertLessEqual(deadline, context.budget.deadline - 80 - 2 - 1)
                now[0] = deadline + 2  # Exercise the runner's complete cleanup allowance.
                return {**successful(), 'argv': argv, 'reason': 'deadline'}
            with patch.object(h.time, 'monotonic', side_effect=lambda: now[0]):
                records, runner = self.observe(fixture, timeout)
                context.budget.check()
            self.assertEqual(len(deadlines), 2)
            self.assertLessEqual(now[0], context.budget.deadline - 81)
            self.assertTrue(any(r.get('status') == 'fail' for r in records))
            self.assertFalse(any(r.get('apple_anchor_verified') is True for r in records))

    def test_fractional_clock_budget_skip_emits_canonical_integer_milliseconds(self):
        for budget_deadline, expected_ms in ((110.875, 10750), (100.125, 0)):
            with self.subTest(deadline=budget_deadline), self.fixture() as fixture, \
                    patch.object(h.time, 'monotonic', return_value=100.125), \
                    patch.object(h.m, 'Root') as root, patch.object(h.os, 'read') as reader:
                fixture[-1].budget.deadline = budget_deadline
                records, runner = self.observe(fixture)
                root.assert_not_called(); reader.assert_not_called(); runner.assert_not_called()
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]['status'], 'skipped_for_budget')
                self.assertEqual(records[0]['remaining_ms'], expected_ms)
                self.assertIs(type(records[0]['remaining_ms']), int)
                self.assertEqual(h.m.strict_json(h.m.canonical(records[0])), records[0])

    def test_budget_skip_preserves_original_single_link_gate_attribution(self):
        with self.fixture() as fixture:
            base, _, _, _, context = fixture
            (base / 'payload').mkdir(); (base / 'payload/canary').write_bytes(b'portable payload')
            context.budget.deadline = 110
            with patch.object(h.time, 'monotonic', return_value=100), \
                    patch.object(h, 'descriptor_identity_diagnostic'), \
                    patch.object(h.m, '_native_run_bounded') as runner, \
                    patch.object(h.m, '_NativeToolset', side_effect=h.m.Rejected('single-link regular file required')) as tools, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                receipt = h.Receipt()
                self.assertFalse(receipt.gate('descriptor_inspection', lambda: h.static_inspection(context, receipt, base)))
            runner.assert_not_called(); tools.assert_called_once()
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(records[0]['status'], 'skipped_for_budget')
            self.assertEqual(records[-1]['gate'], 'descriptor_inspection')
            self.assertEqual(records[-1]['error'], 'single-link regular file required')
            self.assertEqual(records[-1]['code'], h.m.INVALID)

    def test_diagnostic_does_not_override_original_toolset_rejection(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            base = Path(temporary); (base / 'payload').mkdir()
            (base / 'payload/canary').write_bytes(b'portable payload')
            with patch.object(h, 'descriptor_identity_diagnostic'), \
                    patch.object(h, 'fixed_tool_identity_diagnostic', return_value=True) as diagnostic, \
                    patch.object(h.m, '_NativeToolset', side_effect=h.m.Rejected('single-link regular file required')), \
                    contextlib.redirect_stdout(io.StringIO()), \
                    self.assertRaisesRegex(h.m.Rejected, 'single-link regular file required'):
                h.static_inspection(h.make_context(), h.Receipt(), base)
            diagnostic.assert_called_once()

    def test_source_owned_scope_and_production_profile_are_separate(self):
        source = PATH.read_text()
        function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef)
                        and n.name == 'fixed_tool_identity_diagnostic')
        body = ast.get_source_segment(source, function)
        self.assertEqual([arg.arg for arg in function.args.args], ['context', 'receipt'])
        for forbidden in ('os.environ', 'receipt.gates', 'm._ns_profile', 'regular_at(',
                          'chown(', 'chmod(', 'anchor apple generic', 'return True', '--kill-cache'):
            self.assertNotIn(forbidden, body)
        self.assertEqual(h.FIXED_TOOL_DIAGNOSTIC_PATHS,
                         {'codesign': '/usr/bin/codesign', 'sandbox': '/usr/bin/sandbox-exec',
                          'xcrun': '/usr/bin/xcrun', 'xcode_select': '/usr/bin/xcode-select',
                          'lipo': '/usr/bin/lipo', 'otool': '/usr/bin/otool', 'sysctl': '/usr/sbin/sysctl'})
        self.assertLessEqual(h.FIXED_TOOL_DIAGNOSTIC_SECONDS, 45)
        self.assertLessEqual(h.FIXED_TOOL_DIAGNOSTIC_COMMAND_SECONDS, 5)
        self.assertEqual(h.FIXED_TOOL_DIAGNOSTIC_GATE_RESERVE_SECONDS,
                         h.make_context().bounds['native_static_total_seconds'] + h.COMMAND_SECONDS)
        self.assertEqual(h.FIXED_TOOL_DIAGNOSTIC_CLEANUP_SECONDS, 2)
        self.assertLessEqual(h.FIXED_TOOL_DIAGNOSTIC_FILE_BYTES, 64 * 1024 * 1024)
        self.assertLessEqual(h.FIXED_TOOL_DIAGNOSTIC_TOTAL_BYTES, 256 * 1024 * 1024)

    def test_original_toolset_rejection_fixture_uses_physical_aliased_temp_parent(self):
        with tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            base = Path(temporary)
            physical = base / 'physical'; physical.mkdir()
            alias = base / 'alias'; alias.symlink_to(physical, target_is_directory=True)
            with patch.object(tempfile, 'tempdir', str(alias)):
                self.test_diagnostic_does_not_override_original_toolset_rejection()


class FixedCodesignSelfObservationContractTests(unittest.TestCase):
    """Portable fault injection only; no native signature/containment acceptance."""

    fixture = FixedToolIdentityDiagnosticContractTests.fixture
    observe = FixedToolIdentityDiagnosticContractTests.observe
    result = FixedToolIdentityDiagnosticContractTests.result

    # Exact historical display bytes from native source
    # 86028d5cc25f3af5f8a31d37a39d4e8ba2eac236. Replaying text is not a fresh
    # native signature, anchor, snapshot or capability acceptance result.
    observed_display = (
        'Executable=/usr/bin/codesign\n'
        'Identifier=com.apple.security.codesign\n'
        'Format=Mach-O universal (x86_64 arm64e)\n'
        'CodeDirectory v=20400 size=1588 flags=0x0(none) hashes=44+2 location=embedded\n'
        'Platform identifier=16\nVersionPlatform=1\nVersionMin=984832\nVersionSDK=984832\n'
        'Hash type=sha256 size=32\n'
        'CandidateCDHash sha256=5d10564fb97ea909933732e280eae350f2c40424\n'
        'CandidateCDHashFull sha256=5d10564fb97ea909933732e280eae350f2c4042479a4387bf6158e7d17115e90\n'
        'Hash choices=sha256\n'
        'CMSDigest=5d10564fb97ea909933732e280eae350f2c4042479a4387bf6158e7d17115e90\n'
        'CMSDigestType=2\nExecutable Segment base=0\nExecutable Segment limit=114688\n'
        'Executable Segment flags=0x1\nPage size=4096\n'
        'CDHash=5d10564fb97ea909933732e280eae350f2c40424\nSignature size=4442\n'
        'Authority=Software Signing\nAuthority=Apple Code Signing Certification Authority\n'
        'Authority=Apple Root CA\nSigned Time=Jun 23, 2026 at 4:04:51\u202fAM\n'
        'Info.plist entries=5\nTeamIdentifier=not set\nSealed Resources=none\n').encode('utf-8')
    observed_requirement = b'designated => identifier "com.apple.security.codesign" and anchor apple\n'

    def self_result(self, argv):
        target = argv[0]
        if argv[1] == '-d':
            return {**successful(b'designated => identifier "portable.mock.only" and anchor apple\n'),
                    'stderr': ('Executable=' + target + '\nIdentifier=portable.mock.only\n'
                               'Authority=portable mock, never native evidence\n').encode(), 'argv': argv}
        return {**successful(), 'argv': argv, 'stderr': ''.join(target + ': ' + line + '\n' for line in (
            'valid on disk', 'satisfies its Designated Requirement', 'explicit requirement satisfied')).encode()}

    def observe_self(self, fixture, effect=None):
        target = fixture[1]['codesign']
        def command(argv, deadline, kwargs):
            if argv[0] != target:
                return {**successful(), 'argv': argv, 'returncode': -6}
            if effect is not None:
                value = effect(argv, deadline, kwargs)
                if value is not None: return value
            return self.self_result(argv)
        # Source owns the actual OS target. Only this portable fixture patches
        # it to a disposable file, while every execution result is synthetic.
        with patch.object(h, 'FIXED_CODESIGN_SELF_PATH', target):
            return self.observe(fixture, command)

    def observation(self, records):
        return next(r for r in records if r['event'] == 'fixed_codesign_self_identity_observation')

    def test_exact_historical_signed_time_bytes_parse_without_normalization(self):
        self.assertEqual(len(self.observed_display), 936)
        self.assertEqual(h.m.digest(self.observed_display),
                         'ad818e484ce5e9c57e9dff7b88c7e3106b9206069ba53201009fe3cc3f5175fe')
        self.assertEqual(len(self.observed_requirement), 72)
        self.assertEqual(h.m.digest(self.observed_requirement),
                         '3dfbc5792b2971ab23b00948fb51aa0a7471e5543f5f295666fd4c194dd496a3')
        lines = h.codesign_self_display_lines(self.observed_display)
        self.assertEqual(('\n'.join(lines) + '\n').encode('utf-8'), self.observed_display)
        self.assertEqual([c for c in ''.join(lines) if ord(c) > 127], ['\u202f'])
        with self.fixture() as fixture:
            def effect(argv, deadline, kwargs):
                if argv[1] == '-d':
                    # Only redirect the displayed target to the disposable
                    # portable fixture; retain every other historical byte.
                    return {**self.self_result(argv), 'stdout': self.observed_requirement,
                            'stderr': self.observed_display.replace(b'/usr/bin/codesign', argv[0].encode())}
            records, runner = self.observe_self(fixture, effect)
            self.assertEqual(runner.call_count, 9)
            observation = self.observation(records)
            self.assertEqual(observation['status'], 'observed')
            self.assertEqual(observation['displayed_identifier'], 'com.apple.security.codesign')
            self.assertFalse(observation['codesign_identity_policy_applied'])
            display = next(r for r in records if r.get('label') == 'fixed_codesign_self_display')['result']
            raw = self.observed_display.replace(b'/usr/bin/codesign', fixture[1]['codesign'].encode())
            self.assertEqual(display['stderr'], h.raw_record(raw))
            self.assertEqual(display['stdout'], h.raw_record(self.observed_requirement))

    def test_signed_time_is_optional_and_accepts_only_bounded_diagnostic_text(self):
        for signed_time in (b'', b'Signed Time=Jun 23, 2026 at 4:04:51 AM\n',
                            b'Signed Time=' + b'x' * 244 + b'\n',
                            b'Signed Time=' + b'x' * 241 + '\u202f\n'.encode()):
            with self.subTest(signed_time=signed_time), self.fixture() as fixture:
                def effect(argv, deadline, kwargs):
                    result = self.self_result(argv)
                    if argv[1] == '-d': result['stderr'] += signed_time
                    return result
                records, runner = self.observe_self(fixture, effect)
                self.assertEqual(runner.call_count, 9)
                self.assertEqual(self.observation(records)['status'], 'observed')
                display = next(r for r in records if r.get('label') == 'fixed_codesign_self_display')['result']
                self.assertTrue(base64.b64decode(display['stderr']['base64']).endswith(signed_time))

    def test_invalid_signed_time_or_unicode_never_runs_anchor(self):
        prefix = b'Executable=TARGET\nIdentifier=x\n'
        narrow = '\u202f'.encode()
        displays = [
            prefix + b'Signed Time=x\nSigned Time=x\n',
            prefix + b'Signed Time=x\nSigned Time=x' + narrow + b'\n',
            prefix + b'Signed Time=\n',
            prefix + b'Signed Time=' + b'x' * 245 + b'\n',
            prefix + b'Signed Time=' + b'x' * 242 + narrow + b'\n',
            prefix + b'Signed Time=x' + narrow * 2 + b'AM\n',
            prefix + b'Signed Time=x' + narrow + b'AM',
            prefix + b'Signed Time=x\xff\n',
            b'Executable=TARGET' + narrow + b'\nIdentifier=x\n',
            b'Executable=TARGET\nIdentifier=x' + narrow + b'\n',
            prefix + b'Authority=Apple' + narrow + b'\n',
            prefix + b'Other=' + narrow + b'\n',
            prefix + b'Signed' + narrow + b'Time=x\n',
            prefix + b'Signed Time =' + narrow + b'\n',
        ]
        for character in ('\x00', '\t', '\r', '\x1b', '\x7f', '\x85', '\u00a0',
                          '\u2009', '\u200b', '\u2028', '\u2029', '\u202e', '\ufffd', '\u00e9'):
            displays.append(prefix + ('Signed Time=x' + character + '\n').encode())
        mutations = [('stderr', raw) for raw in displays] + [
            ('stdout', b'designated => identifier "x' + narrow + b'" and anchor apple\n'),
            ('stdout', b'designated => x\xff\n')]
        for field, raw in mutations:
            with self.subTest(field=field, raw=raw), self.fixture() as fixture:
                def effect(argv, deadline, kwargs):
                    result = self.self_result(argv)
                    result[field] = raw.replace(b'TARGET', argv[0].encode())
                    return result
                records, runner = self.observe_self(fixture, effect)
                self.assertEqual(runner.call_count, 8)
                self.assertEqual(self.observation(records)['status'], 'fail')
                self.assertFalse(any(r.get('label') == 'fixed_codesign_self_apple_anchor' for r in records))
                self.assertFalse(any(r.get('apple_anchor_verified') is True for r in records))

    def test_independent_success_keeps_all_seven_sandbox_failures_unchanged(self):
        with self.fixture() as fixture:
            records, runner = self.observe_self(fixture)
            target = fixture[1]['codesign']
            self.assertEqual(runner.call_count, 9)
            commands = [r for r in records if r['event'] == 'command']
            original, direct = commands[:7], commands[7:]
            self.assertEqual([r['label'] for r in original],
                             ['fixed_tool_' + role + '_display' for role in h.FIXED_TOOL_DIAGNOSTIC_PATHS])
            for row in original:
                self.assertEqual(row['result']['returncode'], -6)
                self.assertEqual(row['result']['stdout']['bytes'], 0)
                self.assertEqual(row['result']['stderr']['bytes'], 0)
                self.assertIsNone(row['result']['reason'])
            self.assertEqual([r['result']['argv'] for r in direct], [
                [target, '-d', '--verbose=4', '--requirements', '-', target],
                [target, '--verify', '--strict', '--verbose=4', '--test-requirement', '=anchor apple', target]])
            for call in runner.call_args_list[7:]:
                self.assertLessEqual(call.args[1], fixture[-1].budget.deadline - 83)
                self.assertEqual(call.kwargs, {'pass_fds': (), 'env': h.m._NS_ENV, 'cap': h.OUTPUT_BYTES})
            original_results = [r for r in records if r['event'] == 'fixed_tool_identity_diagnostic']
            failures = [r for r in original_results if r['status'] == 'fail']
            self.assertEqual([r['role'] for r in failures], [*h.FIXED_TOOL_DIAGNOSTIC_PATHS, 'dispatch'])
            self.assertEqual(failures[-1]['error'], 'discovery system signature not verified')
            observations = [r for r in original_results if r['status'] == 'observed']
            self.assertEqual(len(observations), 7)
            self.assertTrue(all(r['apple_anchor_verified'] is False for r in observations))
            self.assertLess(max(records.index(r) for r in original_results), records.index(direct[0]))
            pair = [r for r in records if r['event'] == 'fixed_codesign_self_identity_snapshot']
            self.assertEqual([r['phase'] for r in pair], ['before', 'after'])
            self.assertEqual(pair[0]['snapshot'], pair[1]['snapshot'])
            observation = self.observation(records)
            self.assertEqual(observation['status'], 'observed')
            self.assertEqual(observation['displayed_identifier'], 'portable.mock.only')
            self.assertTrue(observation['sandbox_probe_result_unchanged'])
            for field in ('production_acceptance', 'owner_runtime_acceptance', 'authorizes_inspection',
                          'authorizes_delegated_execution', 'fixed_tool_policy_applied',
                          'codesign_identity_policy_applied'):
                self.assertIs(observation[field], False)

    def test_nonzero_deadline_output_and_cleanup_failures_remain_failures(self):
        mutations = [('returncode', -6), ('returncode', 1), ('returncode', False), ('returncode', None),
                     ('reason', 'deadline'), ('reason', 'output_limit'), ('reason', 'incomplete_cleanup'),
                     ('cleanup', {'complete': False, 'remaining_owned_processes': 1, 'open_output_pipes': 1})]
        for suffix in ('-d', '--verify'):
            for field, value in mutations:
                with self.subTest(suffix=suffix, field=field, value=value), self.fixture() as fixture:
                    def effect(argv, deadline, kwargs):
                        result = self.self_result(argv)
                        if argv[1] == suffix: result[field] = value
                        return result
                    records, runner = self.observe_self(fixture, effect)
                    self.assertEqual(runner.call_count, 8 if suffix == '-d' else 9)
                    self.assertEqual(self.observation(records)['status'], 'fail')
                    raw = [r for r in records if r['event'] == 'command'][-1]['result']
                    self.assertEqual(raw[field], value)
                    self.assertFalse(any(r.get('apple_anchor_verified') is True for r in records))

    def test_malformed_display_never_runs_anchor(self):
        for field, value in (
            ('stdout', b''), ('stdout', b'designated => x\nextra\n'),
            ('stdout', b'designated => \x00\n'), ('stdout', b'designated => ' + b'x' * 4097 + b'\n'),
            ('stderr', b''), ('stderr', b'Executable=/arbitrary/payload\nIdentifier=x\n'),
            ('stderr', b'Executable=TARGET\nIdentifier=x\nIdentifier=y\n'),
            ('stderr', b'Executable=TARGET\nIdentifier=bad identifier\n'),
            ('stderr', b'Executable=TARGET\nIdentifier=x'),
            ('stderr', b'Executable=TARGET\nIdentifier=x\n\x00\n'),
            ('stderr', b'Executable=TARGET\nIdentifier=x\n\xff\n'),
            ('stderr', b'Executable=TARGET\nIdentifier=x\nExecutable=TARGET\n')):
            with self.subTest(field=field, value=value[:100]), self.fixture() as fixture:
                def effect(argv, deadline, kwargs):
                    result = self.self_result(argv)
                    result[field] = value.replace(b'TARGET', argv[0].encode())
                    return result
                records, runner = self.observe_self(fixture, effect)
                self.assertEqual(runner.call_count, 8)
                self.assertEqual(self.observation(records)['status'], 'fail')

    def test_malformed_anchor_output_never_becomes_observed(self):
        for kind in ('empty', 'extra', 'wrong_target', 'stdout', 'missing_explicit', 'no_newline'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                def effect(argv, deadline, kwargs):
                    result = self.self_result(argv)
                    if argv[1] == '--verify':
                        if kind == 'empty': result['stderr'] = b''
                        elif kind == 'extra': result['stderr'] += b'extra\n'
                        elif kind == 'wrong_target': result['stderr'] = result['stderr'].replace(argv[0].encode(), b'/payload')
                        elif kind == 'stdout': result['stdout'] = b'extra\n'
                        elif kind == 'missing_explicit': result['stderr'] = b'\n'.join(result['stderr'].split(b'\n')[:2]) + b'\n'
                        else: result['stderr'] = result['stderr'][:-1]
                    return result
                records, runner = self.observe_self(fixture, effect)
                self.assertEqual(runner.call_count, 9)
                self.assertEqual(self.observation(records)['status'], 'fail')

    def test_self_path_must_match_held_source_fixed_target(self):
        with self.fixture() as fixture:
            def sandbox_failure(argv, deadline, kwargs):
                return {**successful(), 'argv': argv, 'returncode': -6}
            records, runner = self.observe(fixture, sandbox_failure)
            self.assertEqual(runner.call_count, 7)
            self.assertEqual(self.observation(records)['error'], 'fixed codesign self target unavailable')

    def test_self_identity_and_mount_drift_stop_before_anchor(self):
        for kind in ('bytes', 'replace', 'ancestor', 'mount'):
            with self.subTest(kind=kind), self.fixture() as fixture:
                def effect(argv, deadline, kwargs):
                    path = Path(argv[0])
                    if kind == 'bytes': path.write_bytes(b'mutated')
                    elif kind == 'replace':
                        replacement = path.with_name('replacement'); replacement.write_bytes(path.read_bytes())
                        replacement.chmod(0o755); replacement.replace(path)
                    elif kind == 'ancestor':
                        path.parent.rename(fixture[0] / 'old-system'); path.parent.mkdir()
                    else: h.os.fstatvfs.return_value = SimpleNamespace(f_flag=0)
                records, runner = self.observe_self(fixture, effect)
                self.assertEqual(runner.call_count, 8)
                self.assertEqual(self.observation(records)['status'], 'fail')

    def test_self_full_digest_catches_hidden_metadata_change(self):
        with self.fixture() as fixture:
            def effect(argv, deadline, kwargs):
                if argv[1] == '-d':
                    path = Path(argv[0]); path.write_bytes(b'x' * path.stat().st_size)
            with patch.object(h.m, 'same_node'):
                records, runner = self.observe_self(fixture, effect)
            self.assertEqual(runner.call_count, 9)
            self.assertEqual(self.observation(records)['error'], 'codesign self bytes/metadata/mounts changed')
            pair = [r for r in records if r['event'] == 'fixed_codesign_self_identity_snapshot']
            self.assertNotEqual(pair[0]['snapshot']['sha256'], pair[1]['snapshot']['sha256'])

    def test_self_shares_aggregate_budget_without_any_extra_read(self):
        with self.fixture() as fixture:
            original_bytes = sum(Path(p).stat().st_size for p in fixture[1].values()) * 2
            with patch.object(h, 'FIXED_TOOL_DIAGNOSTIC_TOTAL_BYTES', original_bytes):
                records, runner = self.observe_self(fixture)
            self.assertEqual(runner.call_count, 7)
            self.assertEqual(self.observation(records)['error'], 'fixed tool diagnostic aggregate byte bound before read')

    def test_full_original_command_budget_skips_independent_observation(self):
        with self.fixture() as fixture:
            with patch.object(h, 'FIXED_CODESIGN_SELF_PATH', fixture[1]['codesign']):
                records, runner = self.observe(fixture)
            self.assertEqual(runner.call_count, 22)
            self.assertEqual(self.observation(records)['status'], 'skipped_for_budget')

    def test_self_timeout_preserves_absolute_gate_cleanup_and_return_reserves(self):
        with self.fixture() as fixture:
            context = fixture[-1]; now = [100.0]; context.budget.deadline = 195
            def effect(argv, deadline, kwargs):
                self.assertLessEqual(deadline, context.budget.deadline - 83)
                now[0] = 114.0  # The shared absolute deadline (112) plus owned cleanup.
                return {**self.self_result(argv), 'reason': 'deadline'}
            with patch.object(h.time, 'monotonic', side_effect=lambda: now[0]):
                records, runner = self.observe_self(fixture, effect)
                context.budget.check()
            self.assertEqual(runner.call_count, 8)
            self.assertEqual(self.observation(records)['status'], 'fail')
            self.assertLessEqual(now[0], context.budget.deadline - 81)

    def test_global_deadline_propagates_from_independent_observation(self):
        with self.fixture() as fixture:
            def effect(argv, deadline, kwargs):
                raise h.CanaryDeadline('whole deadline')
            with self.assertRaises(h.CanaryDeadline): self.observe_self(fixture, effect)

    def test_success_does_not_override_original_descriptor_gate_rejection(self):
        with self.fixture() as fixture:
            base, paths, _, _, context = fixture
            (base / 'payload').mkdir(); (base / 'payload/canary').write_bytes(b'portable payload')
            def command(argv, deadline, **kwargs):
                if argv[0] == paths['codesign']: return self.self_result(argv)
                return {**successful(), 'argv': argv, 'returncode': -6}
            with patch.object(h, 'FIXED_CODESIGN_SELF_PATH', paths['codesign']), \
                    patch.object(h, 'descriptor_identity_diagnostic'), \
                    patch.object(h.m, '_native_run_bounded', side_effect=command), \
                    patch.object(h.m, '_NativeToolset', side_effect=h.m.Rejected('single-link regular file required')) as tools, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                receipt = h.Receipt()
                self.assertFalse(receipt.gate('descriptor_inspection', lambda: h.static_inspection(context, receipt, base)))
            tools.assert_called_once()
            records = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(self.observation(records)['status'], 'observed')
            self.assertEqual(records[-1]['error'], 'single-link regular file required')
            self.assertEqual(receipt.gates, {'descriptor_inspection': 'fail'})

    def test_source_has_no_caller_target_or_verified_set_write(self):
        self.assertEqual(h.FIXED_CODESIGN_SELF_PATH, '/usr/bin/codesign')
        source = PATH.read_text()
        function = next(n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.FunctionDef)
                        and n.name == 'codesign_self_observation')
        self.assertEqual(function.args.args, [])
        body = ast.get_source_segment(source, function)
        for forbidden in ('verified.add', 'verified.update', 'receipt.gates', 'm._ns_profile',
                          'developer', '--sign', '--force', 'lifecycle-', 'os.environ', 'return True'):
            # The docstring explains the excluded developer scope.
            executable_body = body[body.index('nonlocal command_count'):]
            self.assertNotIn(forbidden, executable_body)
        self.assertIn('[FIXED_CODESIGN_SELF_PATH, *args, FIXED_CODESIGN_SELF_PATH]', body)
        self.assertIn('command_count + 2 > 22', body)
        self.assertIn('deadline=deadline', body)


if __name__ == '__main__':
    unittest.main()
