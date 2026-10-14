"""Portable identity/negative tests. Synthetic bytes are never imported or run.

The tiny positive fixture exercises copy/inventory mechanics only. Patching its
source-owned hashes is test instrumentation, not approval for a real wrapper,
bootstrap, certificate, transport, or native acceptance case.
"""
from pathlib import Path
from unittest import mock
import ast
import contextlib
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import prepare_search_real_canary_payload as builder
import search_proxy_canary_support as legacy_support


class RealCanaryContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='real-search-overlay-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve(strict=True)
        self.source = self.root / 'source'
        self.source.mkdir()
        for name in (*builder.SOURCE_PINS, builder.BUILDER_SOURCE):
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
            target.chmod((ROOT / name).stat().st_mode & 0o777)
        entry = self.source / builder.ENTRYPOINT
        entry.parent.mkdir(parents=True, exist_ok=True)
        entry.write_bytes(b"raise AssertionError('synthetic wrapper must never execute')\n")
        self.donor = self.root / 'donor'
        self.donor.mkdir()
        for name, raw in {
            'dot_search.py': b"raise AssertionError('historical helper must never execute')\n",
            'search.sb': b'(deny default)',
            'python/bin/python3': b'non-executable synthetic interpreter bytes',
            'python/lib/dependency.txt': b'pinned dependency bytes',
        }.items():
            path = self.donor / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        (self.donor / 'python/bin/python3').chmod(0o755)
        records = [{k: v for k, v in item.items() if k != 'mode'} for item in builder.inventory(self.donor)]
        receipt = {'schema': 1, 'status': 'unaccepted-static-assembly', 'native_executed': False,
                   'lock_sha256': builder.LOCK_SHA256, 'files': records}
        receipt_path = self.donor / builder.RECEIPT
        receipt_path.parent.mkdir()
        receipt_path.write_bytes(builder.canonical(receipt) + b'\n')
        self.patchers = [mock.patch.object(builder, 'ROOT', self.source),
                        mock.patch.object(builder, 'REVIEWED_ENTRYPOINT_SHA256', builder.sha(entry.read_bytes())),
                        mock.patch.object(builder, 'RECEIPT_SHA256', builder.sha(receipt_path.read_bytes())),
                        mock.patch.object(builder, 'DONOR_TREE_SHA256', builder.sha(builder.canonical(records))),
                        mock.patch.object(builder, 'DONOR_FILES', len(records)),
                        mock.patch.object(builder, 'DONOR_INVENTORY_SHA256', builder.sha(builder.canonical(builder.inventory(self.donor))))]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.output = self.root / 'overlay'

    def build(self):
        return builder.prepare(self.donor, self.output)

    def assert_invalid(self, callback=None, pattern=None):
        with self.assertRaisesRegex((ValueError, OSError), pattern or '.'):
            (callback or self.build)()

    def test_exact_copy_delta_historical_provenance_and_external_inventory_digest(self):
        before = builder.inventory(self.donor)
        result = self.build()
        self.assertEqual(before, builder.inventory(self.donor))
        self.assertEqual(result, builder.verify_overlay(self.donor, self.output, result['inventory_sha256']))
        manifest = json.loads((self.output / builder.INVENTORY).read_bytes())
        self.assertEqual({item['path'] for item in manifest['delta']}, {
            'dot_search.py', 'search.sb', builder.HOST_HELPER,
            builder.RECEIPT, builder.HISTORICAL_RECEIPT})
        self.assertFalse((self.output / builder.RECEIPT).exists())
        self.assertFalse((self.output / 'bin/dot-search-bootstrap').exists())
        self.assertEqual((self.output / builder.HISTORICAL_RECEIPT).read_bytes(),
                         (self.donor / builder.RECEIPT).read_bytes())
        self.assertEqual((self.output / builder.HOST_HELPER).read_bytes(),
                         (self.source / 'Resources/Search/dot_search.py').read_bytes())
        self.assertEqual((self.output / 'dot_search.py').read_bytes(),
                         (self.source / builder.ENTRYPOINT).read_bytes())
        self.assertEqual((self.output / 'search.sb').read_bytes(),
                         (self.source / 'Resources/Search/search.sb').read_bytes())
        for name in ('python/bin/python3', 'python/lib/dependency.txt'):
            self.assertEqual((self.output / name).read_bytes(), (self.donor / name).read_bytes())
            self.assertNotEqual((self.output / name).stat().st_ino, (self.donor / name).stat().st_ino)
        for path in self.output.rglob('*'):
            if path.is_file():
                self.assertEqual(path.stat().st_nlink, 1)
                self.assertFalse(path.is_symlink())
        for flag in ('native_executed', 'production_acceptance', 'production_admission_exercised', 'app_enabled', 'runtime_ready'):
            self.assertIs(manifest[flag], False)
        self.assertIn('non-launchable', manifest['status'])
        self.assertEqual(result['inventory_sha256'], hashlib.sha256((self.output / builder.INVENTORY).read_bytes()).hexdigest())
        self.assertNotEqual(result['inventory_sha256'], result['overlay_records_sha256'])
        self.assertNotIn(builder.INVENTORY, {item['path'] for item in manifest['files']})

    def test_source_owned_missing_entrypoint_is_pending_and_cannot_build(self):
        (self.source / builder.ENTRYPOINT).unlink()
        with mock.patch.object(builder, 'REVIEWED_ENTRYPOINT_SHA256', None):
            result = builder.check_inputs(self.donor)
            self.assertEqual(result['status'], 'pending-reviewed-entrypoint')
            self.assertIn(builder.ENTRYPOINT, result['missing_required_inputs'][0])
            self.assertIs(result['runtime_ready'], False)
            self.assert_invalid(pattern='missing reviewed fixture entrypoint')
        self.assertFalse(self.output.exists())

    def test_entrypoint_cannot_be_accepted_just_by_appearing(self):
        with mock.patch.object(builder, 'REVIEWED_ENTRYPOINT_SHA256', None):
            self.assert_invalid(pattern='without source-owned reviewed identity')
        (self.source / builder.ENTRYPOINT).write_bytes(b'wrong entrypoint')
        self.assert_invalid(pattern='entrypoint identity')

    def test_each_pinned_source_input_change_is_rejected_before_output(self):
        for name in builder.SOURCE_PINS:
            path = self.source / name
            before = path.read_bytes()
            with self.subTest(path=name):
                path.write_bytes(before + b'\nchanged')
                self.assert_invalid(pattern='source identity')
                self.assertFalse(self.output.exists())
                path.write_bytes(before)

    def test_wrong_helper_and_broadened_profile_are_rejected(self):
        helper = self.source / 'Resources/Search/dot_search.py'
        helper.write_bytes((self.donor / 'dot_search.py').read_bytes())
        self.assert_invalid(pattern='source identity')
        helper.write_bytes((ROOT / 'Resources/Search/dot_search.py').read_bytes())
        (self.source / 'Resources/Search/search.sb').write_bytes(b'(allow default)')
        self.assert_invalid(pattern='source identity')

    def test_raw_lock_reformatting_is_not_the_reviewed_lock_bytes(self):
        lock = self.source / 'packaging/search/search-lock-native-owner.json'
        lock.write_bytes(builder.canonical(json.loads(lock.read_bytes())))
        self.assert_invalid(pattern='source identity')

    def test_unrelated_docs_do_not_expand_executable_source_closure(self):
        (self.source / 'unrelated-document.md').write_text('not an execution dependency')
        result = self.build()
        self.assertIs(result['runtime_ready'], False)
        manifest = json.loads((self.output / builder.INVENTORY).read_bytes())
        self.assertEqual({item['path'] for item in manifest['source_inputs']},
                         set(builder.SOURCE_PINS) | {builder.ENTRYPOINT, builder.BUILDER_SOURCE})
        self.assertEqual(manifest['source_identity_scope'], 'pinned-overlay-inputs-only-not-entire-composed-tree')

    def test_source_hardlink_and_parent_alias_are_rejected(self):
        helper = self.source / 'Resources/Search/dot_search.py'
        link = self.root / 'linked-helper'
        os.link(helper, link)
        self.assert_invalid(pattern='singly linked')
        link.unlink()
        directory = self.source / 'Resources/Search'
        real = self.root / 'helper-source'
        directory.rename(real)
        directory.symlink_to(real, target_is_directory=True)
        self.assert_invalid(pattern='non-aliased')

    def test_source_and_donor_roots_must_be_independent(self):
        with mock.patch.object(builder, 'ROOT', self.root):
            with mock.patch.object(builder, 'source_inputs', return_value=([], {}, None, [])):
                self.assert_invalid(pattern='independent')

    def test_changed_missing_extra_and_mode_changed_donor_files_rejected(self):
        path = self.donor / 'python/lib/dependency.txt'
        before = path.read_bytes()
        path.write_bytes(b'changed')
        self.assert_invalid(pattern='differs')
        path.unlink()
        self.assert_invalid(pattern='missing|empty directories')
        path.write_bytes(before)
        path.chmod(0o755)
        self.assert_invalid(pattern='inventory or modes')
        path.chmod(0o644)
        extra = self.donor / 'extra.py'
        extra.write_bytes(b'extra')
        self.assert_invalid(pattern='differs')
        extra.unlink()
        (self.donor / 'empty-extra').mkdir()
        self.assert_invalid(pattern='empty directories')

    def test_wrong_receipt_and_wrong_historical_identity_rejected(self):
        receipt = self.donor / builder.RECEIPT
        receipt.write_bytes(receipt.read_bytes() + b' ')
        self.assert_invalid(pattern='receipt')
        receipt.write_bytes(receipt.read_bytes()[:-1])
        for name, value in [('DONOR_TREE_SHA256', '0' * 64), ('DONOR_FILES', 4000),
                            ('LOCK_SHA256', '1' * 64)]:
            with self.subTest(pin=name), mock.patch.object(builder, name, value):
                self.assert_invalid(pattern='identity|lock')

    def test_donor_symlinks_hardlinks_special_files_and_receipt_fifo_rejected(self):
        path = self.donor / 'python/lib/dependency.txt'
        target = self.root / 'target'
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_invalid(pattern='alias')
        path.unlink()
        os.link(target, path)
        self.assert_invalid(pattern='singly linked')
        path.unlink()
        os.mkfifo(path)
        self.assert_invalid(pattern='regular')
        path.unlink()
        shutil.copyfile(target, path)
        receipt = self.donor / builder.RECEIPT
        receipt.unlink()
        os.mkfifo(receipt)
        self.assert_invalid(pattern='regular')  # Must not block inside the historical verifier.

    def test_donor_root_and_parent_aliases_rejected(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.donor, target_is_directory=True)
        self.assert_invalid(lambda: builder.prepare(alias, self.output), 'non-aliased')
        parent_alias = self.root / 'parent-alias'
        parent_alias.symlink_to(self.root, target_is_directory=True)
        self.assert_invalid(lambda: builder.prepare(parent_alias / 'donor', self.output), 'non-aliased')

    def test_production_admission_and_extra_bootstrap_in_donor_rejected(self):
        for name in ('search-runtime-manifest.json', 'search-acceptance.json',
                     'nested/search-runtime-manifest.json', 'bin/dot-search-bootstrap'):
            path = self.donor / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'not accepted')
            with self.subTest(name=name):
                self.assert_invalid(pattern='admission|differs')
            path.unlink()
            if path.parent != self.donor:
                path.parent.rmdir()

    def test_existing_nested_ancestor_product_and_aliased_output_rejected(self):
        for output in (self.donor, self.source, self.root,
                       self.donor / 'child', self.source / 'child',
                       self.root / 'Dot.app' / 'Search', self.root / 'Dot.APP' / 'Search'):
            with self.subTest(output=output):
                self.assert_invalid(lambda: builder.prepare(self.donor, output))
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        self.assert_invalid(lambda: builder.prepare(self.donor, alias / 'new'), 'non-aliased')
        self.assert_invalid(lambda: builder.prepare(self.donor, self.root / 'missing/new'), 'parent')
        self.assertFalse(self.output.exists())

    def test_overlay_changed_missing_extra_alias_and_rehashed_self_inventory_rejected(self):
        result = self.build()
        verify = lambda: builder.verify_overlay(self.donor, self.output, result['inventory_sha256'])
        path = self.output / 'python/lib/dependency.txt'
        before = path.read_bytes()
        path.write_bytes(b'changed')
        self.assert_invalid(verify, 'allowlisted delta')
        path.unlink()
        self.assert_invalid(verify, 'empty directories|allowlisted delta')
        path.write_bytes(before)
        link = self.root / 'overlay-link'
        os.link(path, link)
        self.assert_invalid(verify, 'singly linked')
        link.unlink()
        for name in ('extra', 'search-runtime-manifest.json', 'search-acceptance.json',
                     'fixture/arbitrary-ca.pem', 'bin/dot-search-bootstrap'):
            extra = self.output / name
            extra.parent.mkdir(parents=True, exist_ok=True)
            extra.write_bytes(b'not part of allowed delta')
            self.assert_invalid(verify, 'allowlisted delta')
            extra.unlink()
            if extra.parent.name == 'bin':
                extra.parent.rmdir()
        manifest_path = self.output / builder.INVENTORY
        manifest = json.loads(manifest_path.read_bytes())
        manifest['production_acceptance'] = True
        manifest_path.write_bytes(builder.canonical(manifest) + b'\n')
        attacker_hash = builder.sha(manifest_path.read_bytes())
        self.assert_invalid(verify, 'inventory identity')
        self.assert_invalid(lambda: builder.verify_overlay(self.donor, self.output, attacker_hash), 'inventory identity')

    def test_inventory_external_digest_and_file_modes_are_checked(self):
        result = self.build()
        self.assert_invalid(lambda: builder.verify_overlay(self.donor, self.output, '0' * 64), 'inventory identity')
        (self.output / 'dot_search.py').chmod(0o755)
        self.assert_invalid(lambda: builder.verify_overlay(self.donor, self.output, result['inventory_sha256']), 'allowlisted delta')

    def test_inventory_mode_is_verified_even_though_its_bytes_are_excluded(self):
        result = self.build()
        (self.output / builder.INVENTORY).chmod(0o755)
        self.assert_invalid(lambda: builder.verify_overlay(self.donor, self.output, result['inventory_sha256']), 'inventory mode')

    def test_verifier_rejects_a_valid_overlay_moved_inside_source(self):
        result = self.build()
        moved = self.source / 'copied-overlay'
        self.output.rename(moved)
        self.assert_invalid(lambda: builder.verify_overlay(self.donor, moved, result['inventory_sha256']), 'independent')

    def test_mid_write_parent_symlink_swap_never_redirects_to_external_target(self):
        outside = self.root / 'outside'
        outside.mkdir()
        real_open = os.open
        swapped = False

        def swap_before_open(path, flags, *args, **kwargs):
            nonlocal swapped
            if path == 'dot_search_host.py' and kwargs.get('dir_fd') is not None and not swapped:
                swapped = True
                (self.output / 'fixture').rename(self.output / 'retained-fixture-dir')
                (self.output / 'fixture').symlink_to(outside, target_is_directory=True)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(builder.os, 'open', side_effect=swap_before_open):
            self.assert_invalid()
        self.assertTrue(swapped)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.output / builder.INVENTORY).exists())

    def test_mid_walk_parent_symlink_swap_is_rejected_without_external_write(self):
        outside = self.root / 'outside'
        outside.mkdir()
        real_open = os.open
        swapped = False

        def swap_before_open(path, flags, *args, **kwargs):
            nonlocal swapped
            if path == 'fixture' and flags == builder.DIRECTORY_FLAGS and kwargs.get('dir_fd') is not None and not swapped:
                swapped = True
                (self.output / 'fixture').rename(self.output / 'retained-fixture-dir')
                (self.output / 'fixture').symlink_to(outside, target_is_directory=True)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(builder.os, 'open', side_effect=swap_before_open):
            self.assert_invalid()
        self.assertTrue(swapped)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.output / builder.INVENTORY).exists())

    def test_output_parent_swap_before_root_creation_cannot_redirect_mkdir(self):
        parent = self.root / 'parent'
        parent.mkdir()
        self.output = parent / 'overlay'
        outside = self.root / 'outside'
        outside.mkdir()
        real_mkdir = os.mkdir
        swapped = False

        def swap_before_mkdir(path, *args, **kwargs):
            nonlocal swapped
            if path == 'overlay' and kwargs.get('dir_fd') is not None and not swapped:
                swapped = True
                parent.rename(self.root / 'retained-parent')
                parent.symlink_to(outside, target_is_directory=True)
            return real_mkdir(path, *args, **kwargs)

        with mock.patch.object(builder.os, 'mkdir', side_effect=swap_before_mkdir):
            self.assert_invalid()
        self.assertTrue(swapped)
        self.assertEqual(list(outside.iterdir()), [])

    def test_overlay_root_swap_before_file_copy_cannot_redirect_write(self):
        outside = self.root / 'outside'
        outside.mkdir()
        write = builder.write_copy
        swapped = False

        def swap_before_copy(directory, name, raw, mode):
            nonlocal swapped
            if not swapped:
                swapped = True
                self.output.rename(self.root / 'retained-overlay')
                self.output.symlink_to(outside, target_is_directory=True)
            return write(directory, name, raw, mode)

        with mock.patch.object(builder, 'write_copy', side_effect=swap_before_copy):
            self.assert_invalid()
        self.assertTrue(swapped)
        self.assertEqual(list(outside.iterdir()), [])

    def test_source_mutation_during_copy_leaves_no_inventory(self):
        write = builder.write_copy
        first = True

        def changed(directory, name, raw, mode):
            nonlocal first
            write(directory, name, raw, mode)
            if first:
                first = False
                (self.source / builder.ENTRYPOINT).write_bytes(b'changed during copy')

        with mock.patch.object(builder, 'write_copy', side_effect=changed):
            self.assert_invalid(pattern='entrypoint identity')
        self.assertFalse((self.output / builder.INVENTORY).exists())

    def test_donor_mutation_during_copy_leaves_no_inventory(self):
        write = builder.write_copy
        first = True

        def changed(directory, name, raw, mode):
            nonlocal first
            write(directory, name, raw, mode)
            if first:
                first = False
                (self.donor / 'python/lib/dependency.txt').write_bytes(b'changed during copy')

        with mock.patch.object(builder, 'write_copy', side_effect=changed):
            self.assert_invalid(pattern='donor changed')
        self.assertFalse((self.output / builder.INVENTORY).exists())

    def test_ambient_ca_proxy_target_and_fake_native_flags_do_not_change_copy(self):
        with mock.patch.dict(os.environ, {'SSL_CERT_FILE': '/evil-ca', 'REQUESTS_CA_BUNDLE': '/evil-ca',
                                        'HTTPS_PROXY': 'https://evil.invalid', 'DOT_SEARCH_TARGET': 'evil.invalid',
                                        'DOT_NATIVE_PASSED': 'true'}):
            result = self.build()
        raw = (self.output / builder.INVENTORY).read_bytes()
        self.assertNotIn(b'evil', raw)
        self.assertIs(result['native_executed'], False)
        self.assertIs(result['runtime_ready'], False)

    def test_cli_missing_input_is_pending_exit_two_not_pass_or_skip(self):
        (self.source / builder.ENTRYPOINT).unlink()
        with mock.patch.object(builder, 'REVIEWED_ENTRYPOINT_SHA256', None):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = builder.main(['--donor', str(self.donor), '--check-inputs'])
            self.assertEqual(code, 2)
            self.assertEqual(err.getvalue(), '')
            self.assertEqual(json.loads(out.getvalue())['status'], 'pending-reviewed-entrypoint')
            with contextlib.redirect_stderr(err):
                self.assertEqual(builder.main(['--donor', str(self.donor), '--output', str(self.output)]), 1)
        self.assertFalse(self.output.exists())

    def test_cli_rejects_generic_overrides_and_caller_provided_approval_hash(self):
        for flag in ('--ca', '--host', '--target', '--env', '--entrypoint', '--entrypoint-sha256',
                     '--source-inventory', '--bootstrap', '--expected-receipt-sha256',
                     '--max-file-bytes', '--max-tree-bytes', '--max-files', '--max-nodes'):
            with self.subTest(flag=flag), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    builder.main(['--donor', str(self.donor), '--check-inputs', flag, 'arbitrary'])
                self.assertEqual(error.exception.code, 2)

    def test_builder_has_no_payload_execution_network_or_native_process_path(self):
        tree = ast.parse((ROOT / 'scripts/prepare_search_real_canary_payload.py').read_text())
        imported = {alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names}
        self.assertTrue(imported <= {'argparse', 'hashlib', 'json', 'os', 'stat', 'sys'})
        calls = {ast.unparse(node.func) for node in ast.walk(tree) if isinstance(node, ast.Call)}
        self.assertFalse(calls & {'subprocess.run', 'subprocess.Popen', 'os.system', 'os.link', 'os.symlink',
                                 'socket.socket', 'urllib.request.urlopen'})
        # All source dependencies are data-only; even pinned support is never executed.
        self.assertEqual(sum(isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'exec'
                             for node in ast.walk(tree)), 0)
        source = (ROOT / 'scripts/prepare_search_real_canary_payload.py').read_text()
        self.assertNotIn('ConnectEndpoint', source)
        self.assertNotIn('verify=False', source)
        self.assertNotIn("REVIEWED_ENTRYPOINT_SHA256 = None", source)


    @contextlib.contextmanager
    def receipt_bytes(self, raw):
        path = self.donor / builder.RECEIPT
        before = path.read_bytes()
        path.write_bytes(raw)
        try:
            records = builder.inventory(self.donor)
            with mock.patch.object(builder, 'RECEIPT_SHA256', builder.sha(raw)):
                with mock.patch.object(builder, 'DONOR_INVENTORY_SHA256', builder.sha(builder.canonical(records))):
                    yield records
        finally:
            path.write_bytes(before)

    def test_bounded_valid_identity_is_identical_to_fixed_legacy_fixture(self):
        records = builder.inventory(self.donor)
        _, historical = legacy_support.verify_payload(self.donor, builder.RECEIPT_SHA256)
        self.assertEqual(builder.verify_donor_records(self.donor, records), historical)
        self.assertEqual(builder.inputs(self.donor)[2], historical)
        _, historical_lock = legacy_support.verify_source_lock(
            self.source / 'packaging/search/search-lock-native-owner.json', builder.LOCK_SHA256)
        self.assertEqual(builder.source_inputs()[2], historical_lock)

    def test_existing_receipt_refusals_match_fixed_small_legacy_fixtures(self):
        original = json.loads((self.donor / builder.RECEIPT).read_bytes())
        cases = [
            ('invalid-json', b'{'),
            ('array-root', b'[]'),
            ('null-root', b'null'),
        ]
        for key, value in [('schema', 2), ('status', 'accepted'), ('native_executed', True),
                           ('native_executed', 0), ('lock_sha256', 'not-a-digest'),
                           ('lock_sha256', 'A' * 64), ('files', None), ('files', False),
                           ('files', {}), ('files', []), ('files', [None]), ('files', [{}])]:
            cases.append((str((key, value)), builder.canonical({**original, key: value})))
        for key, value in [('path', ''), ('path', '/absolute'), ('path', '../escape'),
                           ('path', 'python//bin/python3'), ('path', 'python/./bin/python3'),
                           ('path', 3), ('sha256', 'x' * 64), ('sha256', 3),
                           ('size', True), ('size', -1), ('size', 1.5), ('size', '1'),
                           ('size', 2 ** 63)]:
            receipt = json.loads(builder.canonical(original))
            receipt['files'][0][key] = value
            cases.append((str((key, value)), builder.canonical(receipt)))
        for kind in ('duplicate-path', 'required-file-absent', 'extra-record', 'wrong-hash', 'wrong-size'):
            receipt = json.loads(builder.canonical(original))
            if kind == 'duplicate-path':
                receipt['files'].append(receipt['files'][0])
            elif kind == 'required-file-absent':
                receipt['files'] = [item for item in receipt['files'] if item['path'] != 'python/bin/python3']
            elif kind == 'extra-record':
                receipt['files'].append({'path': 'missing', 'size': 1, 'sha256': 'a' * 64})
            elif kind == 'wrong-hash':
                receipt['files'][0]['sha256'] = 'a' * 64
            else:
                receipt['files'][0]['size'] += 1
            cases.append((kind, builder.canonical(receipt)))
        # Only tiny, finite ordinary fixtures go through the legacy unbounded
        # verifier. Resource attacks and mutation tests exercise only the builder.
        for name, raw in cases:
            with self.subTest(case=name), self.receipt_bytes(raw) as records:
                with self.assertRaises((ValueError, TypeError, KeyError, AttributeError)):
                    legacy_support.verify_payload(self.donor, builder.RECEIPT_SHA256)
                with self.assertRaises(ValueError):
                    builder.verify_donor_records(self.donor, records)

    def test_boolean_float_schema_and_duplicate_keys_are_intentionally_stricter(self):
        original = json.loads((self.donor / builder.RECEIPT).read_bytes())
        cases = [builder.canonical({**original, 'schema': True}),
                 builder.canonical({**original, 'schema': 1.0}),
                 b'{"schema":0,' + builder.canonical(original)[1:]]
        for raw in cases:
            with self.subTest(raw=raw[:80]), self.receipt_bytes(raw) as records:
                _, accepted_legacy = legacy_support.verify_payload(self.donor, builder.RECEIPT_SHA256)
                self.assertEqual(accepted_legacy['payload_file_count'], builder.DONOR_FILES)
                with self.assertRaisesRegex(ValueError, 'static assembly|duplicate JSON'):
                    builder.verify_donor_records(self.donor, records)

    def test_receipt_utf16_utf32_and_utf8_bom_match_legacy_refusals(self):
        original = (self.donor / builder.RECEIPT).read_text(encoding='utf-8')
        for encoding in ('utf-16', 'utf-32', 'utf-8-sig'):
            with self.subTest(encoding=encoding), self.receipt_bytes(original.encode(encoding)) as records:
                with self.assertRaises((UnicodeDecodeError, json.JSONDecodeError)):
                    legacy_support.verify_payload(self.donor, builder.RECEIPT_SHA256)
                with self.assertRaisesRegex(ValueError, 'assembly receipt'):
                    builder.verify_donor_records(self.donor, records)
                self.assert_invalid(pattern='assembly receipt')
                self.assertFalse(self.output.exists())

    def test_integer_lock_sha256_is_an_intentionally_stricter_receipt_refusal(self):
        receipt = json.loads((self.donor / builder.RECEIPT).read_bytes())
        receipt['lock_sha256'] = int('1' * 64)
        with self.receipt_bytes(builder.canonical(receipt)) as records:
            _, accepted_legacy = legacy_support.verify_payload(self.donor, builder.RECEIPT_SHA256)
            self.assertIs(type(accepted_legacy['assembly_lock_sha256']), int)
            with self.assertRaisesRegex(ValueError, 'exact source lock'):
                builder.verify_donor_records(self.donor, records)
        # The former full builder also rejected this at its exact lock comparison;
        # the new receipt validator refuses the malformed type earlier.
        self.assertNotEqual(accepted_legacy['assembly_lock_sha256'], builder.LOCK_SHA256)

    def test_source_lock_preserves_separate_legacy_byte_encoding_semantics(self):
        name = 'packaging/search/search-lock-native-owner.json'
        path = self.source / name
        original = path.read_text(encoding='utf-8')
        for encoding in ('utf-16', 'utf-32', 'utf-8-sig'):
            raw = original.encode(encoding)
            path.write_bytes(raw)
            with self.subTest(encoding=encoding), mock.patch.dict(builder.SOURCE_PINS, {name: builder.sha(raw)}):
                _, historical = legacy_support.verify_source_lock(path, builder.LOCK_SHA256)
                self.assertEqual(builder.source_inputs()[2], historical)

    def test_receipt_count_and_aggregate_caps_reject_before_matching_inventory(self):
        records = builder.inventory(self.donor)
        with mock.patch.object(builder, 'MAX_FILES', 2):
            with self.assertRaisesRegex(ValueError, 'assembly file count'):
                builder.verify_donor_records(self.donor, records)
        receipt = json.loads((self.donor / builder.RECEIPT).read_bytes())
        total = sum(item['size'] for item in receipt['files'])
        with mock.patch.object(builder, 'MAX_TREE_BYTES', total - 1):
            with self.assertRaisesRegex(ValueError, 'assembly exceeds aggregate byte limit'):
                builder.verify_donor_records(self.donor, records)

    def test_receipt_mutation_between_inventory_and_bounded_read_is_rejected(self):
        real_inventory = builder.inventory

        def changed(root):
            records = real_inventory(root)
            if root == self.donor:
                receipt = self.donor / builder.RECEIPT
                receipt.write_bytes(receipt.read_bytes() + b' ')
            return records

        with mock.patch.object(builder, 'inventory', side_effect=changed):
            self.assert_invalid(pattern='receipt changed after inventory')
        self.assertFalse(self.output.exists())

    def test_source_lock_is_validated_from_bound_bytes_without_reopening(self):
        real_read = builder.read_regular
        lock = self.source / 'packaging/search/search-lock-native-owner.json'
        reads = []

        def tracked(path, **kwargs):
            reads.append(Path(path))
            raw, record = real_read(path, **kwargs)
            if Path(path) == lock:
                lock.write_bytes(b'changed after exact bounded read')
            return raw, record

        with mock.patch.object(builder, 'read_regular', side_effect=tracked):
            with self.assertRaisesRegex(ValueError, 'source changed during verification'):
                builder.source_inputs()
        self.assertEqual(reads.count(lock), 1)
        # Metadata binding preserves the former lock-change refusal without a
        # second read through the legacy unbounded source-lock verifier.
        self.assert_invalid(pattern='source identity')

    def test_malformed_source_lock_and_duplicate_keys_fail_closed(self):
        name = 'packaging/search/search-lock-native-owner.json'
        path = self.source / name
        for raw in (b'{', b'[]', b'null', b'{"wheels":[],"wheels":[]}'):
            path.write_bytes(raw)
            try:
                digest = builder.sha(builder.canonical(json.loads(raw)))
            except ValueError:
                digest = '0' * 64
            with self.subTest(raw=raw):
                with mock.patch.dict(builder.SOURCE_PINS, {name: builder.sha(raw)}):
                    with mock.patch.object(builder, 'LOCK_SHA256', digest):
                        with self.assertRaisesRegex(ValueError, 'source lock|duplicate JSON'):
                            builder.source_inputs()
        # Legacy canonical-hash validation accepted a duplicate-key object;
        # the stricter data-only builder deliberately rejects that malformed form.
        _, old = legacy_support.verify_source_lock(path, digest)
        self.assertEqual(old['lock_sha256'], digest)


class InputBoundsContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='real-search-input-bounds-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve(strict=True)

    def test_reviewed_rebind_hashes_actual_files_against_independent_exact_constants(self):
        source = (ROOT / 'scripts/prepare_search_real_canary_payload.py').read_text()
        assignments = {node.targets[0].id: node.value for node in ast.parse(source).body
                       if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)}
        source_pins = ast.literal_eval(assignments['SOURCE_PINS'])
        entrypoint_pin = ast.literal_eval(assignments['REVIEWED_ENTRYPOINT_SHA256'])
        exact = {
            'packaging/search/dot-search-bootstrap.c': '637c9778cfdf0a7e790f3a4fc43069da05cfd5eb299273a5aab01491fa77f55d',
            'scripts/search_proxy_canary_support.py': 'af366611ff5d9a9feacb314fa04b0e65bf27cb13072a81da9f771bb0f409bfb5',
            'Tests/Fixtures/search_real_vertical_entry.py': 'a9bef0fd8db827e2e8bf6cc29af208797a3d443794b2fc94461152555c8feda4',
        }
        for name, expected in exact.items():
            with self.subTest(path=name):
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), expected)
                self.assertEqual(entrypoint_pin if name == 'Tests/Fixtures/search_real_vertical_entry.py'
                                 else source_pins[name], expected)
        self.assertEqual(ast.literal_eval(assignments['SOURCE_COMPOSITION']),
                         '9d3c971fea249af4d73bd4b432584486be92beae')
        self.assertEqual((builder.MAX_FILE_BYTES, builder.MAX_TREE_BYTES, builder.MAX_FILES, builder.MAX_NODES),
                         (32 * 1024 * 1024, 256 * 1024 * 1024, 6000, 12000))

    def test_regular_file_growth_reads_only_observed_size_plus_one(self):
        path = self.root / 'growing'
        path.write_bytes(b'initial')
        real_fdopen = os.fdopen
        requested, returned = [], []

        @contextlib.contextmanager
        def growing_stream(*args, **kwargs):
            with real_fdopen(*args, **kwargs) as stream:
                class GrowingReader:
                    def read(self, size):
                        requested.append(size)
                        with path.open('ab') as writer:
                            writer.write(b'x' * 4096)
                        raw = stream.read(size)
                        returned.append(len(raw))
                        return raw
                yield GrowingReader()

        with mock.patch.object(builder.os, 'fdopen', side_effect=growing_stream):
            with self.assertRaisesRegex(ValueError, 'changed while reading'):
                builder.read_regular(path)
        self.assertEqual(requested, [len(b'initial') + 1])
        self.assertEqual(returned, requested)

    def test_regular_file_oversize_rejects_before_any_read(self):
        path = self.root / 'oversize'
        with path.open('wb') as stream:
            stream.truncate(builder.MAX_FILE_BYTES + 1)
        with mock.patch.object(builder.os, 'fdopen') as opened:
            with self.assertRaisesRegex(ValueError, 'file exceeds byte limit'):
                builder.read_regular(path)
        opened.assert_not_called()

    def test_regular_file_exact_limit_and_invalid_limits(self):
        path = self.root / 'bounded'
        path.write_bytes(b'12345678')
        with mock.patch.object(builder, 'MAX_FILE_BYTES', 8):
            self.assertEqual(builder.read_regular(path)[0], b'12345678')
            for limit in (True, -1, 9, 1.5, '8'):
                with self.subTest(limit=limit), self.assertRaisesRegex(ValueError, 'invalid file byte limit'):
                    builder.read_regular(path, limit=limit)
            with self.assertRaisesRegex(ValueError, 'file exceeds byte limit'):
                builder.read_regular(path, limit=7)
        path.write_bytes(b'')
        self.assertEqual(builder.read_regular(path, limit=0)[0], b'')

    def test_regular_file_short_read_and_path_replacement_are_rejected(self):
        path = self.root / 'changing'
        real_fdopen = os.fdopen
        for change in ('truncate', 'replace'):
            path.write_bytes(b'original')

            @contextlib.contextmanager
            def changed_stream(*args, **kwargs):
                with real_fdopen(*args, **kwargs) as stream:
                    class ChangingReader:
                        def read(self, size):
                            if change == 'truncate':
                                path.write_bytes(b'')
                            else:
                                replacement = path.with_name('replacement')
                                replacement.write_bytes(b'original')
                                replacement.replace(path)
                            return stream.read(size)
                    yield ChangingReader()

            with self.subTest(change=change), mock.patch.object(builder.os, 'fdopen', side_effect=changed_stream):
                with self.assertRaisesRegex(ValueError, 'changed while reading'):
                    builder.read_regular(path)

    def test_inventory_file_limit_is_checked_before_extra_read(self):
        for index in range(3):
            (self.root / str(index)).write_bytes(b'x')
        with mock.patch.object(builder, 'MAX_FILES', 2):
            with mock.patch.object(builder, 'read_regular', wraps=builder.read_regular) as read:
                with self.assertRaisesRegex(ValueError, 'tree exceeds file limit'):
                    builder.inventory(self.root)
        self.assertEqual(read.call_count, 2)

    def test_inventory_node_limit_is_incremental_before_stat_or_read(self):
        (self.root / 'one').write_bytes(b'x')
        observed = []

        @contextlib.contextmanager
        def endless_entries(_directory):
            def entries():
                while True:
                    observed.append('one')
                    if len(observed) > 4:
                        raise AssertionError('iterator consumed beyond bounded node failure')
                    yield type('Entry', (), {'name': 'one'})()
            yield entries()

        with mock.patch.object(builder, 'MAX_NODES', 3):
            with mock.patch.object(builder.os, 'scandir', side_effect=endless_entries):
                with mock.patch.object(builder, 'read_regular', wraps=builder.read_regular) as read:
                    with self.assertRaisesRegex(ValueError, 'tree exceeds node limit'):
                        builder.inventory(self.root)
        self.assertEqual(len(observed), 4)
        self.assertEqual(read.call_count, 3)

    def test_inventory_directories_alone_count_toward_node_limit(self):
        for index in range(4):
            (self.root / str(index)).mkdir()
        with mock.patch.object(builder, 'MAX_NODES', 3):
            with mock.patch.object(builder, 'read_regular') as read:
                with self.assertRaisesRegex(ValueError, 'tree exceeds node limit'):
                    builder.inventory(self.root)
        read.assert_not_called()

    def test_inventory_aggregate_limit_rejects_before_over_budget_read(self):
        for index in range(3):
            (self.root / str(index)).write_bytes(b'1234')
        with mock.patch.object(builder, 'MAX_TREE_BYTES', 7):
            with mock.patch.object(builder, 'read_regular', wraps=builder.read_regular) as read:
                with self.assertRaisesRegex(ValueError, 'tree exceeds aggregate byte limit'):
                    builder.inventory(self.root)
        self.assertEqual(read.call_count, 1)
        self.assertEqual(read.call_args.kwargs['limit'], 7)
        with mock.patch.object(builder, 'MAX_TREE_BYTES', 12):
            self.assertEqual(sum(item['size'] for item in builder.inventory(self.root)), 12)

    def test_inventory_growth_cannot_exceed_remaining_aggregate_budget(self):
        path = self.root / 'growing'
        path.write_bytes(b'1234')
        real_read = builder.read_regular
        limits = []

        def grow_before_read(path, *, limit=None):
            limits.append(limit)
            path.write_bytes(b'12345678')
            return real_read(path, limit=limit)

        with mock.patch.object(builder, 'MAX_TREE_BYTES', 7):
            with mock.patch.object(builder, 'read_regular', side_effect=grow_before_read):
                with self.assertRaisesRegex(ValueError, 'file exceeds byte limit'):
                    builder.inventory(self.root)
        self.assertEqual(limits, [7])

    def test_inventory_never_follows_a_directory_symlink(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'secret').write_bytes(b'external')
        tree = self.root / 'tree'
        tree.mkdir()
        (tree / 'alias').symlink_to(outside, target_is_directory=True)
        with mock.patch.object(builder, 'read_regular') as read:
            with self.assertRaisesRegex(ValueError, 'alias'):
                builder.inventory(tree)
        read.assert_not_called()

    def test_inventory_pending_directory_swap_cannot_redirect_traversal(self):
        tree = self.root / 'tree'
        tree.mkdir()
        child = tree / 'child'
        child.mkdir()
        (child / 'original').write_bytes(b'original')
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'secret').write_bytes(b'external')
        real_open_directory = builder.open_directory
        swapped = []

        def swap_pending(path):
            if path == child and not swapped:
                child.rename(self.root / 'retained-child')
                child.symlink_to(outside, target_is_directory=True)
                swapped.append(True)
            return real_open_directory(path)

        with mock.patch.object(builder, 'open_directory', side_effect=swap_pending):
            with mock.patch.object(builder, 'read_regular') as read:
                with self.assertRaisesRegex(ValueError, 'non-aliased'):
                    builder.inventory(tree)
        self.assertEqual(swapped, [True])
        read.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
