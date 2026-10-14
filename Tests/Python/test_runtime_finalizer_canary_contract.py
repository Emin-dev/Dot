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


if __name__ == '__main__':
    unittest.main()
