"""Portable build-only reconstruction checks; no downloads or payload execution."""
from pathlib import Path
from unittest import mock
import ast
import copy
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
