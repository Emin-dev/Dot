"""Portable build-only reconstruction checks; no downloads or payload execution."""
from pathlib import Path
from unittest import mock
import copy
import hashlib
import json
import shutil
import sys
import tempfile
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
        self.assertEqual(len(filters), 28)
        self.assertEqual(len(set(filters)), 28)
        self.assertTrue(all((ROOT / path).is_file() for path in filters))
        self.assertTrue(all('*' not in path and not path.startswith('docs/') for path in filters))
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
        self.assertNotIn('build_search_bootstrap.sh', workflow)
        self.assertNotIn('upload-artifact', workflow)


if __name__ == '__main__':
    unittest.main(verbosity=2)
