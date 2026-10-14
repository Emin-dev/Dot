"""Portable build-only reconstruction checks; no downloads or payload execution."""
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import ast
import copy
import contextlib
import importlib.util
import io
import fnmatch
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import prepare_search_proxy_canary_payload as prepare


class ReconstructionContract(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads(prepare.LOCK.read_text())

    def test_exact_historical_lock_and_complete_minimal_input_closure(self):
        lock, identity = prepare.verify_source_lock(prepare.LOCK, prepare.LOCK_SHA256)
        items = prepare.runtime_inputs(lock)
        self.assertEqual(len(items), 33)
        self.assertEqual(sum(pin['size'] for _, pin in items), 59551997)
        self.assertEqual(sum(name.startswith('wheels/') for name, _ in items), 31)
        for excluded in ('full', 'build_source'):
            self.assertNotIn(lock['python'][excluded]['filename'], [name for name, _ in items])
        self.assertEqual(identity['lock_sha256'], prepare.LOCK_SHA256)
        self.assertNotEqual(identity['lock_file_sha256'], identity['lock_sha256'])

    def test_historical_helpers_match_five_exact_lock_records(self):
        prepare.verify_helpers(self.lock)
        self.assertEqual(len(self.lock['helper_inputs']), 5)
        # No production bootstrap source or acceptance files are historical helpers.
        self.assertEqual({x['path'] for x in self.lock['helper_inputs']}, {
            'dot_search.py', 'search.sb', 'search-dependency-pins.json',
            'searxng-transient-cache.patch', 'searxng-transient-cache-patch.json'})

    def test_reject_changed_count_size_origin_and_duplicate(self):
        changed = copy.deepcopy(self.lock)
        changed['wheels'].pop()
        with self.assertRaisesRegex(ValueError, 'count or byte total'):
            prepare.runtime_inputs(changed)
        changed = copy.deepcopy(self.lock)
        changed['wheels'][0]['size'] += 1
        with self.assertRaisesRegex(ValueError, 'count or byte total'):
            prepare.runtime_inputs(changed)
        changed = copy.deepcopy(self.lock)
        changed['wheels'][0]['url'] = 'http://files.pythonhosted.org/untrusted'
        with self.assertRaisesRegex(ValueError, 'origin'):
            prepare.runtime_inputs(changed)
        changed = copy.deepcopy(self.lock)
        changed['wheels'][0]['filename'] = changed['wheels'][1]['filename']
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            prepare.runtime_inputs(changed)

    def test_offline_missing_and_changed_input_never_fetches(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(prepare, 'fetch') as fetch:
            # Canonicalize the trusted fixture root (macOS /var may be an alias).
            root = Path(temporary).resolve(strict=True)
            with self.assertRaisesRegex(ValueError, 'offline artifact'):
                prepare.acquire(self.lock, root, True)
            name, pin = prepare.runtime_inputs(self.lock)[0]
            target = root / name
            target.parent.mkdir()
            target.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'offline artifact'):
                prepare.acquire(self.lock, root, True)
            fetch.assert_not_called()

    def test_exact_offline_bytes_pass_and_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(prepare, 'fetch') as fetch:
            root = Path(temporary).resolve(strict=True)
            data = b'non-executable-fixture'
            pin = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            target = root / 'test'
            target.write_bytes(data)
            with mock.patch.object(prepare, 'runtime_inputs', return_value=[('test', pin)]):
                prepare.acquire({}, root, True)
                target.unlink()
                (root / 'other').write_bytes(data)
                target.symlink_to(root / 'other')
                with self.assertRaisesRegex(ValueError, 'symlink'):
                    prepare.acquire({}, root, True)
            fetch.assert_not_called()

    def test_aliased_input_parent_never_fetches(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(prepare, 'fetch') as fetch:
            root = Path(temporary).resolve(strict=True)
            inputs = root / 'inputs'
            inputs.mkdir()
            alias = root / 'input-alias'
            alias.symlink_to(inputs, target_is_directory=True)
            data = b'non-executable-fixture'
            (inputs / 'test').write_bytes(data)
            pin = {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            with mock.patch.object(prepare, 'runtime_inputs', return_value=[('test', pin)]):
                for offline in (True, False):
                    with self.subTest(offline=offline), self.assertRaisesRegex(ValueError, 'symlink artifact target or parent'):
                        prepare.acquire({}, alias, offline)
            fetch.assert_not_called()

    def test_changed_or_extra_historical_helper_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            helpers = Path(temporary).resolve(strict=True) / 'helpers'
            shutil.copytree(prepare.HELPERS, helpers)
            with mock.patch.object(prepare, 'HELPERS', helpers):
                (helpers / 'search.sb').write_text('changed')
                with self.assertRaisesRegex(ValueError, 'helper identity'):
                    prepare.verify_helpers(self.lock)
                (helpers / 'extra').write_text('extra')
                with self.assertRaisesRegex(ValueError, 'closure'):
                    prepare.verify_helpers(self.lock)

    def test_refuse_existing_or_product_output_before_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(prepare, 'acquire') as acquire:
            root = Path(temporary).resolve(strict=True)
            with self.assertRaisesRegex(ValueError, 'must be new'):
                prepare.prepare(root, root, offline=True)
            with self.assertRaisesRegex(ValueError, 'independent'):
                prepare.prepare(root, ROOT / 'Resources/Search/never-created', offline=True)
            with self.assertRaisesRegex(ValueError, 'independent'):
                prepare.prepare(root, root / 'Dot.app/Search', offline=True)
            acquire.assert_not_called()

    def test_aliased_output_parent_stops_before_lock_network_or_assembly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(strict=True)
            output_parent = root / 'outputs'
            output_parent.mkdir()
            alias = root / 'output-alias'
            alias.symlink_to(output_parent, target_is_directory=True)
            with mock.patch.object(prepare, 'verify_source_lock') as verify_lock, \
                 mock.patch.object(prepare, 'acquire') as acquire, mock.patch.object(prepare, 'assemble') as assemble:
                with self.assertRaisesRegex(ValueError, 'canary output parent must not be an alias'):
                    prepare.prepare(root / 'inputs', alias / 'payload', offline=True)
                verify_lock.assert_not_called()
                acquire.assert_not_called()
                assemble.assert_not_called()
            self.assertFalse((output_parent / 'payload').exists())

    def test_semantic_lock_mutation_stops_before_network_or_assembly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(strict=True)
            changed = copy.deepcopy(self.lock)
            changed['status'] = 'changed'
            lock = root / 'lock.json'
            lock.write_text(json.dumps(changed))
            with mock.patch.object(prepare, 'LOCK', lock), mock.patch.object(prepare, 'acquire') as acquire, \
                 mock.patch.object(prepare, 'assemble') as assemble:
                with self.assertRaisesRegex(ValueError, 'lock'):
                    prepare.prepare(root / 'inputs', root / 'output')
                acquire.assert_not_called()
                assemble.assert_not_called()

    def test_native_sequence_and_public_bounded_scope(self):
        workflow = (ROOT / '.github/workflows/search-proxy-canary.yml').read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertIn('  push:\n    branches: [main]\n    paths:', workflow)
        filters = [line.split("'")[1] for line in workflow.splitlines() if line.startswith("      - '")]
        self.assertEqual(len(filters), len(set(filters)))
        self.assertTrue(all((ROOT / path).is_file() for path in filters if '*' not in path))
        self.assertEqual([path for path in filters if '*' in path], ['Tests/DotCoreTests/**'])
        self.assertTrue(all(not path.startswith('docs/') for path in filters))
        self.assertIn('.github/workflows/search-proxy-canary.yml', filters)
        self.assertIn('packaging/search/search-lock-native-owner.json', filters)
        self.assertIn('Tests/Fixtures/search-proxy-native-owner/helpers/dot_search.py', filters)
        self.assertNotIn('.github/workflows/ci.yml', filters)
        self.assertNotIn('pull_request_target', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertIn('github.event.repository.private == false', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('test "$(uname -m)" = arm64', workflow)
        commands = workflow.split('    steps:\n', 1)[1]
        self.assertLess(commands.index('prepare_search_proxy_canary_payload.py'), commands.index('test_search_proxy_sandbox_canary.py'))
        self.assertLess(commands.index('test_search_proxy_sandbox_canary.py'), commands.index('test_search_proxy_bootstrap_canary.py'))
        self.assertLess(commands.index('test_search_proxy_bootstrap_canary.py'), commands.index('verify_search_proxy_native_fixture.sh'))
        self.assertEqual(workflow.count(prepare.RECEIPT_SHA256), 3)
        self.assertNotIn('search-lock.json', workflow)
        self.assertIn('scripts/build_search_bootstrap.sh', filters)
        self.assertNotIn('upload-artifact', workflow)


class WorkflowContract(unittest.TestCase):
    REAL_STEP = '4. Real Swift Search vertical'
    REPORT_STEP = 'Record available sanitized evidence, including partial failure'
    RECONSTRUCT_STEP = 'Reconstruct exact unaccepted historical Search payload'

    def setUp(self):
        self.workflow = (ROOT / '.github/workflows/search-proxy-canary.yml').read_text()
        self.filters = re.findall(r"^      - '([^']+)'$", self.workflow, re.MULTILINE)

    def step(self, name):
        match = re.search(r'^      - name: ' + re.escape(name) + r'\n(.*?)(?=^      - (?:name|uses):|\Z)',
                          self.workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, name)
        return match.group(1)

    def run_body(self, name):
        step = self.step(name)
        self.assertEqual(step.count('        run: |\n'), 1)
        return textwrap.dedent(step.split('        run: |\n', 1)[1])

    @staticmethod
    def source_constant(path, name):
        tree = ast.parse((ROOT / path).read_text())
        return next(ast.literal_eval(node.value) for node in tree.body
                    if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == name
                                                           for target in node.targets))

    def test_same_single_public_runner_budget_and_read_only_permissions(self):
        workflow = self.workflow
        self.assertIn('permissions:\n  contents: read\nconcurrency:', workflow)
        self.assertIn('  cancel-in-progress: false', workflow)
        self.assertEqual(re.findall(r'^  ([a-z][a-z-]+):$', workflow.split('jobs:\n', 1)[1], re.MULTILINE),
                         ['native-proxy-canary'])
        self.assertEqual(re.findall(r'^    runs-on: (.+)$', workflow, re.MULTILINE), ['macos-15'])
        self.assertIn('    timeout-minutes: 20', workflow)
        self.assertIn('    if: ${{ github.event.repository.private == false }}', workflow)
        self.assertNotIn('self-hosted', workflow)
        self.assertNotIn('upload-artifact', workflow)
        self.assertNotIn('secrets.', workflow)

    def test_exact_execution_trigger_closure_includes_all_compiled_sources(self):
        # The controller builds the whole DotCore test target before filtering
        # XCTest. Every compiled source matters, including the other test files.
        package = (ROOT / 'Package.swift').read_text()
        target = re.search(r'\.target\(name: "DotCore", path: "src", exclude: \[[^\]]*\], sources: \[([^\]]+)\]\)', package)
        self.assertIsNotNone(target, 'review changed SwiftPM source selection before updating this guard')
        compiled = {'src/' + name for name in re.findall(r'"([^"\n]+\.swift)"', target.group(1))}
        self.assertTrue(compiled)
        self.assertIn('.testTarget(name: "DotCoreTests", dependencies: ["DotCore"], path: "Tests/DotCoreTests")', package)
        # SwiftPM implicitly discovers this test target, including future files.
        # Permit only this narrow wildcard; all explicit sources stay exact.
        tests = {path.relative_to(ROOT).as_posix() for path in (ROOT / 'Tests/DotCoreTests').rglob('*.swift')}
        self.assertIn('Tests/DotCoreTests/RealSearchVerticalCanaryTests.swift', tests)
        tests.update({'Tests/DotCoreTests/FutureAddedTests.swift',
                      'Tests/DotCoreTests/FutureGroup/AddedTests.swift'})
        self.assertEqual([path for path in self.filters if '*' in path], ['Tests/DotCoreTests/**'])
        self.assertTrue(all(fnmatch.fnmatchcase(path, 'Tests/DotCoreTests/**') for path in tests))
        fixed = {
            'Tests/DotCoreTests/**',
            '.github/workflows/search-proxy-canary.yml',
            'Package.swift',
            'Resources/Search/dot_search.py',
            'Resources/Search/search.sb',
            'Tests/Fixtures/search-proxy-native-owner/helpers/dot_search.py',
            'Tests/Fixtures/search-proxy-native-owner/helpers/search-dependency-pins.json',
            'Tests/Fixtures/search-proxy-native-owner/helpers/search.sb',
            'Tests/Fixtures/search-proxy-native-owner/helpers/searxng-transient-cache-patch.json',
            'Tests/Fixtures/search-proxy-native-owner/helpers/searxng-transient-cache.patch',
            'Tests/Fixtures/search_proxy_canary.sb',
            'Tests/Fixtures/search_proxy_fixture_support.py',
            'Tests/Fixtures/search_proxy_pinned_hashes.json',
            'Tests/Fixtures/search_proxy_transport_fixture.py',
            'Tests/Fixtures/search_real_vertical_entry.py',
            'Tests/Fixtures/search_real_vertical_fixture.py',
            'Tests/Native/search-proxy-bootstrap-canary.c',
            'Tests/Native/search_proxy_bootstrap_probe.py',
            'Tests/Portable/test_search_proxy_ci_reconstruction.py',
            'Tests/Portable/test_search_proxy_exit_diagnostics.py',
            'Tests/Portable/test_search_proxy_fixture.py',
            'Tests/Portable/test_search_proxy_lock_identity.py',
            'Tests/Portable/test_search_proxy_probe_progress.py',
            'Tests/Portable/test_search_proxy_startup_diagnostics.py',
            'Tests/Portable/test_search_real_canary_contract.py',
            'Tests/Python/test_search_proxy_profile_contract.py',
            'canary-inputs.json',
            'packaging/search/dot-search-bootstrap.c',
            'packaging/search/portable-test-requirements.txt',
            'packaging/search/search-lock-native-owner.json',
            'profile-bootstrap-basis.json',
            'scripts/build_search_bootstrap.sh',
            'scripts/fetch_search_inputs.py',
            'scripts/prepare_search_proxy_canary_payload.py',
            'scripts/prepare_search_real_canary_payload.py',
            'scripts/search_download.py',
            'scripts/search_payload.py',
            'scripts/search_proxy_canary_support.py',
            'scripts/test_search_proxy_bootstrap_canary.py',
            'scripts/test_search_proxy_sandbox_canary.py',
            'scripts/verify_search_proxy_native_fixture.sh',
            'scripts/verify_search_real_vertical_canary.sh',
        }
        self.assertEqual(set(self.filters), fixed | compiled)
        # Source-owned native input pins cannot silently leave the trigger set.
        for path, constant in (('Tests/Fixtures/search_real_vertical_fixture.py', 'SOURCE_FIXED'),
                               ('scripts/prepare_search_real_canary_payload.py', 'SOURCE_PINS')):
            self.assertLessEqual(set(self.source_constant(path, constant)), set(self.filters))
        self.assertLessEqual({path.relative_to(ROOT).as_posix()
                              for path in (ROOT / 'Tests/Portable').glob('test_search_proxy*.py')}, set(self.filters))
        # Uncompiled UI and cosmetic documentation are deliberately not triggers.
        self.assertNotIn('src/ChatView.swift', self.filters)
        self.assertNotIn('docs/PROGRESS.md', self.filters)

    def test_all_portable_gates_still_precede_verified_reconstruction(self):
        portable = self.run_body('Test portable fixture and reconstruction contracts')
        self.assertEqual(portable.splitlines(), [
            "python3 -B -m unittest discover -s Tests/Portable -p 'test_search_proxy*.py'",
            'python3 -B Tests/Python/test_search_proxy_profile_contract.py',
            'python3 -B Tests/Portable/test_search_real_canary_contract.py'])
        self.assertLess(self.workflow.index('      - name: Test portable fixture'),
                        self.workflow.index('      - name: ' + self.RECONSTRUCT_STEP))
        reconstruction = self.step(self.RECONSTRUCT_STEP)
        self.assertIn('        id: reconstruct\n', reconstruction)
        self.assertNotIn('        if:', reconstruction)
        self.assertEqual(self.workflow.count('        id: reconstruct\n'), 1)

    def test_real_lane_is_independent_but_reconstruction_and_cancellation_remain_gates(self):
        real = self.step(self.REAL_STEP)
        self.assertEqual(re.findall(r'^        if: (.+)$', real, re.MULTILINE),
                         ["${{ always() && steps.reconstruct.outcome == 'success' && !cancelled() }}"])
        # always() removes the implicit prior-success gate. The exact reconstruction
        # outcome blocks failure/skipped/cancelled; cancellation blocks a new run.
        # Original synthetic failures remain mandatory, with no outcome rewriting.
        for name in ('1. Native fixture profile', '2. Native fixture bootstrap',
                     '3. Actual pinned curl and SearXNG transport'):
            self.assertNotIn('        if:', self.step(name))
            self.assertNotIn('||', self.run_body(name))
        self.assertLess(self.workflow.index('      - name: 3. Actual pinned curl'),
                        self.workflow.index('      - name: ' + self.REAL_STEP))
        self.assertEqual(re.findall(r'^        if: (.+)$', self.step(self.REPORT_STEP), re.MULTILINE),
                         ['${{ always() }}'])
        self.assertNotIn('continue-on-error', self.workflow)

    def test_real_driver_uses_only_exact_donor_and_new_work_root_and_preserves_status(self):
        body = self.run_body(self.REAL_STEP)
        self.assertEqual(body.splitlines(), [
            'set -euo pipefail',
            'bash scripts/verify_search_real_vertical_canary.sh \\',
            '  "$RUNNER_TEMP/search-proxy-canary-payload" \\',
            '  "$RUNNER_TEMP/search-real-vertical" > /dev/null 2>&1'])
        # Execute only a synthetic shell stub, never the real driver or payload.
        # A failure or non-native skip remains the step's exact nonzero status.
        for status in (0, 1, 23, 77):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(strict=True)
                (root / 'scripts').mkdir()
                donor = root / 'search-proxy-canary-payload'
                donor.mkdir()
                (donor / 'unchanged').write_bytes(b'historical donor remains untouched')
                stub = root / 'scripts/verify_search_real_vertical_canary.sh'
                stub.write_text("""set -euo pipefail
[ "$#" = 2 ]
[ "$1" = "$RUNNER_TEMP/search-proxy-canary-payload" ]
[ "$2" = "$RUNNER_TEMP/search-real-vertical" ]
[ ! -e "$2" ]
printf '%s\\n' 'synthetic-private-capability-stdout'
printf '%s\\n' 'synthetic-private-capability-stderr' >&2
exit "$STUB_STATUS"
""")
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', body], cwd=root,
                    env={**os.environ, 'RUNNER_TEMP': str(root), 'STUB_STATUS': str(status)},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, status)
                self.assertEqual((result.stdout, result.stderr), ('', ''))
                self.assertEqual((donor / 'unchanged').read_bytes(), b'historical donor remains untouched')
                self.assertFalse((root / 'search-real-vertical').exists())

    def test_report_path_matches_controller_and_only_reviewed_json_is_reported(self):
        controller = ast.parse((ROOT / 'Tests/Fixtures/search_real_vertical_fixture.py').read_text())
        report_assignment = next(node for node in ast.walk(controller) if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == 'report_path' for target in node.targets))
        self.assertIsInstance(report_assignment.value, ast.BinOp)
        self.assertEqual(ast.literal_eval(report_assignment.value.right), 'real-search-vertical-report.json')
        body = self.run_body(self.REPORT_STEP)
        self.assertIn('for report in host assembly profile bootstrap transport; do', body)
        self.assertIn('path="$RUNNER_TEMP/search-real-vertical/real-search-vertical-report.json"', body)
        # Failure reports are available too. Missing/empty preflight output has a
        # fixed diagnostic; never fabricate a passing receipt or fall back to logs.
        for state in ('missing', 'empty', 'passed', 'failed'):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(strict=True)
                work = root / 'search-real-vertical'
                work.mkdir(mode=0o700)
                (work / 'raw-stdout.log').write_text('synthetic-private-capability-stdout')
                (work / 'raw-stderr.log').write_text('synthetic-private-capability-stderr')
                (work / 'private-key.pem').write_text('synthetic-private-key')
                report = work / 'real-search-vertical-report.json'
                sanitized = json.dumps({'kind': 'build-only-real-search-vertical-canary',
                                         'status': state, 'production_acceptance': False}) + '\n'
                if state != 'missing':
                    report.write_text('' if state == 'empty' else sanitized)
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', body], cwd=root,
                    env={**os.environ, 'RUNNER_TEMP': str(root)}, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, '')
                self.assertEqual(result.stdout, ('\n--- real-search-vertical ---\n' + sanitized)
                    if state in ('passed', 'failed') else 'Real Search vertical sanitized report not produced.\n')
                self.assertNotIn('synthetic-private', result.stdout)


class RealVerticalBuildDiagnosticsContract(unittest.TestCase):
    """Only portable synthetic children run; xcrun and the real lane stay mocked."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('real_vertical_diagnostic_contract',
            ROOT / 'Tests/Fixtures/search_real_vertical_fixture.py')
        cls.vertical = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.vertical)

    def synthetic(self, program, *, seconds=3, phase='swift-build-tests', fail=True):
        vertical = self.vertical
        owner = vertical.load_module('real_vertical_contract_process_owner', ROOT / 'Resources/Search/dot_search.py')
        observations, cleanups = [], []

        def observe(child):
            self.assertIsNone(child.returncode, 'leader must remain unreaped before group cleanup')
            result = owner.child_exited(child)
            observations.append(result)
            return result

        def stop(child):
            self.assertIsNone(child.returncode, 'cleanup must own the unreaped leader')
            owner.stop_group(child)
            cleanups.append(child)

        reviewed = SimpleNamespace(child_exited=observe, stop_group=stop)
        command = [sys.executable, '-I', '-S', '-B', '-c', program]
        with mock.patch.object(vertical, 'load_module', return_value=reviewed), \
             mock.patch.object(vertical.subprocess, 'Popen', wraps=subprocess.Popen) as popen:
            if fail:
                with self.assertRaises(vertical.CanaryFailure) as caught:
                    vertical.run_owned(command, cwd=ROOT,
                        env={'PATH': '/usr/bin:/bin', 'SYNTHETIC_PRIVATE': 'synthetic-private-environment'},
                        seconds=seconds, phase=phase)
                result = caught.exception
                raw = vertical.canonical(result.build_failure)
                self.assertLess(len(raw), 512)
                for value in (b'synthetic-private', str(ROOT).encode(), program.encode()):
                    self.assertNotIn(value, raw)
            else:
                result = vertical.run_owned(command, cwd=ROOT, env={'PATH': '/usr/bin:/bin'},
                                            seconds=seconds, phase=phase)
        popen.assert_called_once_with(command, cwd=ROOT,
            env={'PATH': '/usr/bin:/bin', 'SYNTHETIC_PRIVATE': 'synthetic-private-environment'} if fail else {'PATH': '/usr/bin:/bin'},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.assertEqual(len(cleanups), 1)
        self.assertTrue(all(pipe.closed for pipe in (cleanups[0].stdout, cleanups[0].stderr)))
        return result, observations, cleanups[0].returncode

    def test_natural_nonzero_exit_and_signal_are_distinct_from_cleanup(self):
        for program, code in [('raise SystemExit(23)', 23),
                              ('import os, signal; os.kill(os.getpid(), signal.SIGTERM)', -signal.SIGTERM)]:
            with self.subTest(code=code):
                failure, observations, actual = self.synthetic(program)
                self.assertEqual(str(failure), 'owned-process-failed')
                self.assertEqual(actual, code)
                self.assertIn(True, observations)
                self.assertEqual(failure.build_failure, {
                    'phase': 'swift-build-tests', 'leader_exit_observed_before_cleanup': True,
                    'exit_status': code if code >= 0 else None,
                    'signal': -code if code < 0 else None,
                    'returncode_observed_only_after_cleanup': None})

    def test_deadline_does_not_misreport_cleanup_signal_as_natural_termination(self):
        started = time.monotonic()
        failure, observations, actual = self.synthetic('import time; time.sleep(60)', seconds=0.1)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(str(failure), 'owned-process-deadline')
        self.assertNotIn(True, observations)
        self.assertIn(actual, (-signal.SIGTERM, -signal.SIGKILL))
        self.assertEqual(failure.build_failure, {
            'phase': 'swift-build-tests', 'leader_exit_observed_before_cleanup': False,
            'exit_status': None, 'signal': None,
            'returncode_observed_only_after_cleanup': actual})

    @unittest.skipUnless(hasattr(os, 'fork'), 'requires portable POSIX synthetic process groups')
    def test_exited_leader_with_inherited_pipe_retains_real_status_before_cleanup(self):
        program = 'import os, time; pid = os.fork(); time.sleep(60) if pid == 0 else os._exit(31)'
        failure, observations, actual = self.synthetic(program, seconds=0.2)
        self.assertEqual(str(failure), 'owned-process-deadline')
        self.assertEqual(actual, 31)
        self.assertEqual(observations, [True])
        self.assertEqual(failure.build_failure['exit_status'], 31)
        self.assertIsNone(failure.build_failure['signal'])
        self.assertIsNone(failure.build_failure['returncode_observed_only_after_cleanup'])

    def test_output_cap_and_secret_bytes_remain_fail_closed(self):
        program = "import os, time; os.write(2, b'synthetic-private-output'); os.write(1, b'x' * (8 * 1024 * 1024 + 1)); time.sleep(60)"
        failure, _, _ = self.synthetic(program)
        self.assertEqual(str(failure), 'owned-output-cap')
        self.assertIsNone(failure.build_failure['exit_status'])
        self.assertIsNone(failure.build_failure['signal'])
        self.assertIs(failure.build_failure['leader_exit_observed_before_cleanup'], False)

    def test_success_returns_identical_bytes_and_nonbuild_failures_have_no_receipt(self):
        output, _, actual = self.synthetic("import os; os.write(1, b'fixed stdout'); os.write(2, b'fixed stderr')", fail=False)
        self.assertEqual(output, (b'fixed stdout', b'fixed stderr'))
        self.assertEqual(actual, 0)
        failure, _, _ = self.synthetic('raise SystemExit(9)', phase=None)
        self.assertEqual(str(failure), 'owned-process-failed')
        self.assertIsNone(failure.build_failure)

    def test_unknown_phase_rejected_before_identity_read_or_spawn(self):
        for phase in ('synthetic-private-phase', '', True, [], {}, 7):
            with self.subTest(phase=type(phase).__name__), \
                 mock.patch.object(self.vertical, 'read_regular') as read, \
                 mock.patch.object(self.vertical.subprocess, 'Popen') as popen:
                with self.assertRaisesRegex(self.vertical.CanaryFailure, '^unknown-build-phase$'):
                    self.vertical.run_owned(['never executed'], cwd=ROOT, env={}, seconds=1, phase=phase)
                read.assert_not_called()
                popen.assert_not_called()

    def test_malformed_status_and_observation_cannot_leak_or_forge_natural_exit(self):
        for code in (True, False, 'synthetic-private-status', [], {}, 1.5, -128, 256, None):
            with self.subTest(code=type(code).__name__):
                for observed in (False, True):
                    receipt = self.vertical.build_failure_receipt('swift-build-tests', observed, code)
                    self.assertIsNone(receipt['exit_status'])
                    self.assertIsNone(receipt['signal'])
                    self.assertIsNone(receipt['returncode_observed_only_after_cleanup'])
                    self.assertNotIn(b'synthetic-private', self.vertical.canonical(receipt))
        for observed in (1, 'synthetic-private-observation', [], None):
            receipt = self.vertical.build_failure_receipt('swift-build-tests', observed, -15)
            self.assertIs(receipt['leader_exit_observed_before_cleanup'], False)
            self.assertIsNone(receipt['signal'])
            self.assertEqual(receipt['returncode_observed_only_after_cleanup'], -15)
        for code in (0, 255, -1, -127):
            receipt = self.vertical.build_failure_receipt('swift-build-tests', True, code)
            self.assertEqual(receipt['exit_status'], code if code >= 0 else None)
            self.assertEqual(receipt['signal'], -code if code < 0 else None)

    def test_launch_and_selector_errors_keep_fixed_phase_and_cleanup(self):
        vertical = self.vertical
        with mock.patch.object(vertical.subprocess, 'Popen', side_effect=OSError('synthetic-private-launch')):
            with self.assertRaisesRegex(vertical.CanaryFailure, '^controller-failed$') as caught:
                vertical.run_owned(['never executed'], cwd=ROOT, env={}, seconds=1, phase='find-clang')
        self.assertEqual(caught.exception.build_failure, {
            'phase': 'find-clang', 'leader_exit_observed_before_cleanup': False,
            'exit_status': None, 'signal': None, 'returncode_observed_only_after_cleanup': None})
        with mock.patch.object(vertical.selectors, 'DefaultSelector', side_effect=OSError('synthetic-private-selector')):
            failure, _, _ = self.synthetic('import time; time.sleep(60)')
        self.assertEqual(str(failure), 'controller-failed')

    def test_failed_observation_still_uses_reviewed_group_cleanup(self):
        vertical = self.vertical
        owner = vertical.load_module('real_vertical_contract_observation_owner', ROOT / 'Resources/Search/dot_search.py')
        for error in (OSError('synthetic-private-observation'), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                stop = mock.Mock(wraps=owner.stop_group)
                reviewed = SimpleNamespace(child_exited=mock.Mock(side_effect=error),
                                           stop_group=stop)
                with mock.patch.object(vertical, 'load_module', return_value=reviewed), \
                     mock.patch.object(vertical.selectors, 'DefaultSelector', side_effect=OSError('synthetic-private-selector')):
                    with self.assertRaisesRegex(vertical.CanaryFailure, '^controller-failed$') as caught:
                        vertical.run_owned([sys.executable, '-I', '-S', '-B', '-c', 'import time; time.sleep(60)'],
                                           cwd=ROOT, env={}, seconds=1, phase='swift-build-tests')
                stop.assert_called_once()
                child = stop.call_args.args[0]
                self.assertIsNotNone(child.returncode)
                self.assertTrue(child.stdout.closed and child.stderr.closed)
                self.assertIs(caught.exception.build_failure['leader_exit_observed_before_cleanup'], False)
                self.assertIsNone(caught.exception.build_failure['signal'])

    def test_source_fixed_toolchain_matches_native_ci_and_ignores_caller_overrides(self):
        vertical = self.vertical
        fixed = '/Applications/Xcode_26.3.app/Contents/Developer'
        self.assertEqual(vertical.DEVELOPER_DIR, fixed)
        self.assertEqual(vertical.XCODE_VERSION, b'Xcode 26.3\nBuild version 17C529')
        self.assertEqual(vertical.MACOS_SDK_VERSION, '26.2')
        self.assertIn('      DEVELOPER_DIR: ' + fixed + '\n',
                      (ROOT / '.github/workflows/ci.yml').read_text())
        hostile = {name: 'synthetic-private-caller-override' for name in (
            'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'SWIFT_EXEC', 'SWIFT_DRIVER_SWIFT_FRONTEND_EXEC',
            'PYTHONPATH', 'HTTPS_PROXY', 'SSL_CERT_FILE', 'DOT_REAL_SEARCH_FIXTURE_CONFIG')}
        with mock.patch.dict(os.environ, hostile):
            env = vertical.clean_environment(Path('/synthetic/home'), Path('/synthetic/tmp'))
            child = vertical.clean_environment(Path('/synthetic/home'), Path('/synthetic/tmp'),
                                               Path('/synthetic/config'), 'a' * 64)
        self.assertEqual(env, {'PATH': '/usr/bin:/bin', 'HOME': '/synthetic/home', 'TMPDIR': '/synthetic/tmp',
                              'LANG': 'en_US.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1', 'DEVELOPER_DIR': fixed})
        self.assertEqual(child, {**env, 'DOT_REAL_SEARCH_FIXTURE_CONFIG': '/synthetic/config',
                                 'DOT_REAL_SEARCH_FIXTURE_CONFIG_SHA256': 'a' * 64})
        self.assertNotIn('synthetic-private', vertical.canonical([env, child]).decode())

    def test_shell_scrub_sets_fixed_toolchain_without_forwarding_caller_values(self):
        script = (ROOT / 'scripts/verify_search_real_vertical_canary.sh').read_text()
        # Observe the source shell boundary directly: the macOS Python shim can
        # add SDKROOT and other developer-tool variables after env -i dispatch.
        body = script[script.index('environment=('):script.index('"${environment[@]}" /usr/bin/python3')]
        self.assertIn('DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer)', body)
        self.assertIn('for name in ImageOS ImageVersion RUNNER_OS RUNNER_ARCH; do', body)
        probe = body + '\nexec "${environment[@]}" /usr/bin/env\n'
        hostile = {name: 'synthetic-private-caller-override' for name in (
            'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'SWIFT_EXEC', 'SWIFT_DRIVER_SWIFT_FRONTEND_EXEC',
            'PYTHONPATH', 'HTTPS_PROXY', 'SSL_CERT_FILE', 'DOT_REAL_SEARCH_FIXTURE_CONFIG',
            'CPATH', 'LIBRARY_PATH', 'MANPATH', 'HOME', 'TMPDIR')}
        image_labels = {'ImageOS': 'synthetic-image', 'ImageVersion': 'synthetic-version=fixture',
                        'RUNNER_OS': 'synthetic-os', 'RUNNER_ARCH': 'synthetic-arch'}
        for labels in ({}, dict.fromkeys(image_labels, ''), image_labels):
            with self.subTest(labels=labels):
                result = subprocess.run(['/bin/bash', '-e', '-u', '-c', probe],
                    env={'PATH': '/usr/bin:/bin', **hostile, **labels},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                entries = [line.split('=', 1) for line in result.stdout.splitlines()]
                observed = dict(entries)
                self.assertEqual(len(entries), len(observed))
                self.assertEqual(observed, {
                    'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1',
                    'DEVELOPER_DIR': self.vertical.DEVELOPER_DIR,
                    **{name: value for name, value in labels.items() if value}})
                for name in set(hostile) - {'DEVELOPER_DIR'}:
                    self.assertNotIn(name, observed)
                self.assertNotIn('synthetic-private', result.stdout + result.stderr)
        self.assertEqual(script.count('"${environment[@]}" /usr/bin/python3 -I -B'), 2)

    def test_fixed_xcode_query_and_seven_existing_commands_keep_exact_phases_and_budgets(self):
        vertical = self.vertical
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve(strict=True)
            executable = work / 'build/DotCorePackageTests.xctest/Contents/MacOS/DotCorePackageTests'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'synthetic test executable never executed')
            developer = work / 'Developer'
            tool_bin = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
            tool_bin.mkdir(parents=True)
            clang, swift = tool_bin / 'clang', tool_bin / 'swift'
            sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk'
            clang.write_bytes(b'synthetic clang never executed')
            swift.write_bytes(b'synthetic swift never executed')
            sdk.mkdir(parents=True)
            (sdk / 'SDKSettings.json').write_bytes(b'{"Version":"26.2"}')
            responses = [(vertical.XCODE_VERSION + b'\n', b''), (b'build stdout', b'build stderr'), (str(clang).encode(), b''),
                         (str(swift).encode(), b''), (str(sdk).encode(), b''),
                         (b'clang version fixture', b''), (b'swift version fixture', b''), (b'26.2\n', b'')]
            with mock.patch.object(vertical, 'DEVELOPER_DIR', str(developer)), \
                 mock.patch.object(vertical, 'run_owned', side_effect=responses) as run:
                found, build = vertical.build_artifacts(work, {'fixed': 'environment'})
            self.assertEqual(found, executable)
            commands = [
                (['xcodebuild', '-version'], 10, 'xcode-version'),
                (['swift', 'build', '--build-tests', '--configuration', 'debug', '--scratch-path', str(work / 'build')], 600, 'swift-build-tests'),
                (['--find', 'clang'], 10, 'find-clang'), (['--find', 'swift'], 10, 'find-swift'),
                (['--show-sdk-path'], 10, 'sdk-path'), (['clang', '--version'], 10, 'clang-version'),
                (['swift', '--version'], 10, 'swift-version'), (['--show-sdk-version'], 10, 'sdk-version'),
            ]
            self.assertEqual(set(vertical.BUILD_PHASES), {phase for _, _, phase in commands})
            self.assertEqual(run.call_args_list, [mock.call(['/usr/bin/xcrun', *command], cwd=ROOT,
                env={'fixed': 'environment'}, seconds=seconds, phase=phase) for command, seconds, phase in commands])
            self.assertEqual(build, {
                'developer_dir': str(developer), 'xcode_version': 'Xcode 26.3\nBuild version 17C529',
                'test_executable_sha256': vertical.sha(executable.read_bytes()), 'clang_path': str(clang),
                'clang_executable_sha256': vertical.sha(clang.read_bytes()), 'swift_executable_sha256': vertical.sha(swift.read_bytes()),
                'sdk_settings_sha256': vertical.sha((sdk / 'SDKSettings.json').read_bytes()), 'swift_path': str(swift),
                'sdk_path': str(sdk), 'clang_version': 'clang version fixture', 'swift_version': 'swift version fixture',
                'sdk_version': '26.2', 'swift_flags': ['build', '--build-tests', '--configuration', 'debug'],
                'bootstrap_flags': ['-arch', 'arm64', '-mmacosx-version-min=15.0', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-lsandbox']})
            for index, (_, _, phase) in enumerate(commands):
                failure = vertical.CanaryFailure('owned-process-failed')
                failure.build_failure = vertical.build_failure_receipt(phase, True, 23)
                with self.subTest(phase=phase), mock.patch.object(vertical, 'run_owned', side_effect=[*responses[:index], failure]) as run:
                    with self.assertRaises(vertical.CanaryFailure) as caught:
                        vertical.build_artifacts(work, {})
                    self.assertIs(caught.exception, failure)
                    self.assertEqual(run.call_count, index + 1)

            for index, changed, category in (
                    (0, b'Xcode 16.4\nBuild version 16F6\n', 'selected-xcode-version-mismatch'),
                    (2, str(executable).encode(), 'selected-toolchain-mismatch'),
                    (3, str(executable).encode(), 'selected-toolchain-mismatch'),
                    (4, str(work).encode(), 'selected-toolchain-mismatch'),
                    (7, b'15.5\n', 'selected-toolchain-mismatch')):
                bad = list(responses)
                bad[index] = (changed, b'')
                with self.subTest(index=index), mock.patch.object(vertical, 'DEVELOPER_DIR', str(developer)), \
                     mock.patch.object(vertical, 'run_owned', side_effect=bad) as run:
                    with self.assertRaisesRegex(vertical.CanaryFailure, '^' + category + '$'):
                        vertical.build_artifacts(work, {})
                    self.assertEqual(run.call_count, 1 if index == 0 else 8)
            for metadata in (b'{"Version":"15.5"}', b'{"Version":26.2}', b'{}', b'null',
                             b'[]', b'{', b'\xff', b' ' * 65537):
                (sdk / 'SDKSettings.json').write_bytes(metadata)
                with self.subTest(metadata=metadata[:40]), mock.patch.object(vertical, 'DEVELOPER_DIR', str(developer)), \
                     mock.patch.object(vertical, 'run_owned', side_effect=responses):
                    with self.assertRaisesRegex(vertical.CanaryFailure, '^selected-sdk-version-mismatch$'):
                        vertical.build_artifacts(work, {})

    def test_failure_report_keeps_all_seven_pending_and_never_starts_capabilities(self):
        vertical = self.vertical
        for phase in vertical.BUILD_PHASES:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(strict=True)
                donor = root / 'donor'
                donor.mkdir()
                work = root / 'work'
                builder = SimpleNamespace(LOCK_SHA256='a' * 64, SOURCE_PINS={
                    'packaging/search/search-lock-native-owner.json': 'b' * 64}, RECEIPT_SHA256='c' * 64)
                failure = vertical.CanaryFailure('owned-process-failed')
                failure.build_failure = vertical.build_failure_receipt(phase, True, 23)
                checked = {'donor': {}, 'donor_inventory_sha256': 'd' * 64}
                with mock.patch.object(vertical.sys, 'platform', 'darwin'), \
                     mock.patch.object(vertical.platform, 'machine', return_value='arm64'), \
                     mock.patch.object(vertical, 'preflight', return_value=(builder, checked, [])), \
                     mock.patch.object(vertical, 'build_artifacts', side_effect=failure), \
                     mock.patch.object(vertical, 'load_module') as load, \
                     mock.patch.object(vertical, 'run_case') as run_case, \
                     contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(vertical.main(['--run', '--donor', str(donor), '--work', str(work)]), 1)
                load.assert_not_called()
                run_case.assert_not_called()
                self.assertEqual(out.getvalue(), '')
                self.assertEqual(err.getvalue(), 'FAIL: owned-process-failed\n')
                raw = (work / 'real-search-vertical-report.json').read_bytes()
                report = json.loads(raw)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(report['failure_category'], 'owned-process-failed')
                self.assertEqual(report['build_failure'], failure.build_failure)
                self.assertEqual(report['scenarios'], [{'scenario': name, 'status': 'pending'} for name in vertical.SCENARIOS])
                for key in ('build', 'native_host', 'hosted_image', 'actual_swift_broker_executed'):
                    self.assertNotIn(key, report)
                for key in ('production_admission_exercised', 'production_acceptance', 'app_enabled',
                            'live_provider_tested', 'owner_macos_26_4_accepted', 'full_neural_app_accepted'):
                    self.assertIs(report[key], False)
                self.assertNotIn(temporary.encode(), raw)
                self.assertNotIn(b'synthetic-private', raw)

    def test_only_eight_pre_capability_calls_request_diagnostics_and_no_output_parser_exists(self):
        tree = ast.parse((ROOT / 'Tests/Fixtures/search_real_vertical_fixture.py').read_text())
        calls = [(function.name, node) for function in tree.body if isinstance(function, ast.FunctionDef)
                 for node in ast.walk(function) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == 'run_owned']
        tagged = [(name, ast.literal_eval(keyword.value)) for name, call in calls
                  for keyword in call.keywords if keyword.arg == 'phase']
        self.assertEqual(len(tagged), 8)
        self.assertEqual({name for name, _ in tagged}, {'build_artifacts'})
        self.assertEqual({phase for _, phase in tagged}, set(self.vertical.BUILD_PHASES))
        receipt = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'build_failure_receipt')
        self.assertEqual([arg.arg for arg in receipt.args.args], ['phase', 'observed_exit', 'returncode'])
        owner_calls = {ast.unparse(node.func) for node in ast.walk(next(node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == 'run_owned')) if isinstance(node, ast.Call)}
        self.assertFalse(owner_calls & {'child.wait', 'child.poll', 'child.communicate', 'os.waitpid', 'os.waitid', 'os.killpg'})


if __name__ == '__main__':
    unittest.main(verbosity=2)
