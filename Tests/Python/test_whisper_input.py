import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import verify_whisper_input as gate


def archive_bytes(binary=b'GOOD fixture binary', extra=(), libraries=None, links=None, versioned=True):
    libraries = libraries if libraries is not None else [{
        'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': 'whisper.framework',
        'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64', 'x86_64']}]
    prefix = 'whisper.xcframework/macos-arm64_x86_64/whisper.framework/'
    base = 'Versions/A/' if versioned else ''
    members = [('whisper.xcframework/Info.plist', plistlib.dumps({'AvailableLibraries': libraries}), stat.S_IFREG | 0o644),
               (prefix + base + 'whisper', binary, stat.S_IFREG | 0o755),
               (prefix + base + 'Headers/whisper.h', b'header fixture', stat.S_IFREG | 0o644),
               (prefix + base + 'Modules/module.modulemap', b'module fixture', stat.S_IFREG | 0o644),
               (prefix + base + 'Resources/LICENSE', b'license fixture', stat.S_IFREG | 0o644),
               (prefix + base + 'Resources/empty', b'', stat.S_IFREG | 0o644)]
    targets = {'Versions/Current': 'A', 'whisper': 'Versions/Current/whisper',
               'Headers': 'Versions/Current/Headers', 'Modules': 'Versions/Current/Modules',
               'Resources': 'Versions/Current/Resources'} if versioned else {}
    if links is not None:
        targets.update(links)
    members.extend((prefix + name, target.encode(), stat.S_IFLNK | 0o777) for name, target in targets.items())
    members.extend(extra)
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data, mode in members:
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = mode << 16
            entry.compress_type = zipfile.ZIP_STORED
            archive.writestr(entry, data)
    return output.getvalue()


class WhisperInputTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.archive = self.root / gate.ARCHIVE_NAME
        self.output = self.root / 'stage'

    def pin(self, data):
        self.archive.write_bytes(data)
        return {'filename': gate.ARCHIVE_NAME, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

    def prepare_fixture(self, data=None, **kwargs):
        data = data if data is not None else archive_bytes(**kwargs)
        return gate._prepare(self.archive, self.output, self.pin(data), '1' * 64)

    def rejected_fixture(self, **kwargs):
        with self.assertRaises((ValueError, zipfile.BadZipFile)):
            self.prepare_fixture(**kwargs)
        self.assertFalse(self.output.exists())

    def test_versioned_framework_is_derived_with_contained_links(self):
        receipt = self.prepare_fixture()
        root = self.output / 'whisper.framework'
        self.assertEqual((root / 'whisper').read_bytes(), b'GOOD fixture binary')
        self.assertEqual((root / 'Versions/Current').readlink(), Path('A'))
        self.assertEqual((root / 'Headers/whisper.h').read_bytes(), b'header fixture')
        self.assertEqual((root / 'Resources/empty').read_bytes(), b'')
        self.assertEqual(receipt['library_identifier'], 'macos-arm64_x86_64')
        self.assertEqual(receipt['source_manifest_sha256'], '1' * 64)
        self.assertRegex(receipt['framework_closure_sha256'], '^[0-9a-f]{64}$')

    def test_flat_framework_is_supported_without_following_untrusted_paths(self):
        self.prepare_fixture(versioned=False)
        self.assertFalse((self.output / 'whisper.framework/whisper').is_symlink())

    def test_self_consistent_replacement_archive_does_not_match_source_pin(self):
        original = archive_bytes()
        pin = self.pin(original)
        replacement = archive_bytes(binary=b'EVIL fixture binary')
        self.assertEqual(len(original), len(replacement))
        self.archive.write_bytes(replacement)
        with mock.patch.object(gate, 'framework_nodes') as parse:
            with self.assertRaisesRegex(ValueError, 'repository pin'):
                gate._prepare(self.archive, self.output, pin, '1' * 64)
            parse.assert_not_called()

    def test_wrong_archive_size_rejected_before_parse(self):
        pin = self.pin(archive_bytes())
        self.archive.write_bytes(self.archive.read_bytes() + b'x')
        with self.assertRaisesRegex(ValueError, 'expected size'):
            gate._prepare(self.archive, self.output, pin, '1' * 64)

    def test_archive_final_symlink_is_not_followed(self):
        pin = self.pin(archive_bytes())
        linked = self.root / 'link.zip'
        linked.symlink_to(self.archive)
        with self.assertRaises(OSError):
            gate._prepare(linked, self.output, pin, '1' * 64)

    def test_archive_is_not_reopened_after_authentication(self):
        pin = self.pin(archive_bytes())
        original = gate.framework_nodes
        def replace_path_then_parse_detached_bytes(raw):
            self.archive.write_bytes(archive_bytes(binary=b'EVIL fixture binary'))
            return original(raw)
        with mock.patch.object(gate, 'framework_nodes', side_effect=replace_path_then_parse_detached_bytes):
            gate._prepare(self.archive, self.output, pin, '1' * 64)
        self.assertEqual((self.output / 'whisper.framework/whisper').read_bytes(), b'GOOD fixture binary')

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / 'keep'
        sentinel.write_bytes(b'keep')
        with self.assertRaisesRegex(ValueError, 'fresh output'):
            self.prepare_fixture()
        self.assertEqual(sentinel.read_bytes(), b'keep')

    def test_output_symlink_is_rejected(self):
        existing = self.root / 'existing'
        existing.mkdir()
        self.output.symlink_to(existing, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'fresh output'):
            self.prepare_fixture()
        self.assertTrue(self.output.is_symlink())

    def test_relative_traversal_rejected(self):
        self.rejected_fixture(extra=[('../escape', b'x', stat.S_IFREG | 0o644)])

    def test_absolute_path_rejected(self):
        self.rejected_fixture(extra=[('/escape', b'x', stat.S_IFREG | 0o644)])

    def test_special_file_rejected(self):
        self.rejected_fixture(extra=[('device', b'x', stat.S_IFIFO | 0o600)])

    def test_case_alias_rejected(self):
        self.rejected_fixture(extra=[('WHISPER.xcframework/Info.plist', b'x', stat.S_IFREG | 0o644)])

    def test_unicode_alias_rejected(self):
        self.rejected_fixture(extra=[('caf\u00e9', b'x', stat.S_IFREG | 0o644),
                                     ('cafe\u0301', b'x', stat.S_IFREG | 0o644)])

    def test_duplicate_member_rejected(self):
        with self.assertWarns(UserWarning):
            raw = archive_bytes(extra=[('whisper.xcframework/Info.plist', b'x', stat.S_IFREG | 0o644)])
        self.rejected_fixture(data=raw)

    def test_implicit_directory_alias_rejected(self):
        prefix = 'whisper.xcframework/macos-arm64_x86_64/whisper.framework/'
        self.rejected_fixture(extra=[(prefix + 'Foo/a', b'x', stat.S_IFREG | 0o644),
                                     (prefix + 'foo/b', b'x', stat.S_IFREG | 0o644)])

    def test_file_under_link_rejected_without_writing_through_it(self):
        prefix = 'whisper.xcframework/macos-arm64_x86_64/whisper.framework/'
        self.rejected_fixture(extra=[(prefix + 'Headers/extra.h', b'x', stat.S_IFREG | 0o644)])

    def test_absolute_framework_link_rejected(self):
        self.rejected_fixture(links={'whisper': '/tmp/outside'})

    def test_escaping_framework_link_rejected(self):
        self.rejected_fixture(links={'whisper': '../outside'})

    def test_dangling_framework_link_rejected(self):
        self.rejected_fixture(links={'whisper': 'missing'})

    def test_cyclic_framework_link_rejected(self):
        self.rejected_fixture(links={'whisper': 'other', 'other': 'whisper'})

    def test_non_macos_slice_rejected(self):
        self.rejected_fixture(libraries=[{'LibraryIdentifier': 'ios-arm64', 'LibraryPath': 'whisper.framework',
                                         'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64']}])

    def test_multiple_macos_arm64_slices_rejected(self):
        row = {'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': 'whisper.framework',
               'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64']}
        self.rejected_fixture(libraries=[row, dict(row, LibraryIdentifier='duplicate')])

    def test_library_identifier_escape_rejected(self):
        self.rejected_fixture(libraries=[{'LibraryIdentifier': '../escape', 'LibraryPath': 'whisper.framework',
                                         'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64']}])

    def test_archive_count_bound(self):
        with mock.patch.object(gate, 'MAX_MEMBERS', 1):
            self.rejected_fixture()

    def test_archive_expansion_bound(self):
        with mock.patch.object(gate, 'MAX_EXPANDED_BYTES', 1):
            self.rejected_fixture()

    def test_post_write_mismatch_removes_only_new_output(self):
        actual_walk = os.walk
        def corrupt_then_walk(*args, **kwargs):
            (self.output / 'whisper.framework/Versions/A/whisper').write_bytes(b'changed')
            return actual_walk(*args, **kwargs)
        with mock.patch.object(gate.os, 'walk', side_effect=corrupt_then_walk):
            self.rejected_fixture()

    def test_production_pin_is_fixed_repository_source(self):
        pin, source_sha = gate.source_pin()
        self.assertEqual(pin, {'filename': gate.ARCHIVE_NAME, 'bytes': 41_291_976,
                              'sha256': '9fcb28106d0b94a525e59bec057e35b57033195ac7408d7e1ab8e4b597cdfeb5'})
        self.assertEqual(source_sha, hashlib.sha256(gate.SOURCE_MANIFEST.read_bytes()).hexdigest())

    def test_missing_ambiguous_or_malformed_source_pin_rejected(self):
        fixture = self.root / 'pins.json'
        row = {'filename': gate.ARCHIVE_NAME, 'version': 'v1.7.6', 'size_bytes': 100, 'sha256': 'a' * 64}
        for rows in ([], [row, row], [dict(row, sha256='A' * 64)], [dict(row, size_bytes=True)]):
            with self.subTest(rows=rows):
                fixture.write_text(json.dumps({'runtime_artifacts': rows}))
                with mock.patch.object(gate, 'SOURCE_MANIFEST', fixture):
                    with self.assertRaises(ValueError):
                        gate.source_pin()

    def test_cli_has_no_pin_override(self):
        outcome = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/verify_whisper_input.py'),
                                  '--archive', str(self.archive), '--output', str(self.output),
                                  '--expected-sha256', 'a' * 64], capture_output=True)
        self.assertEqual(outcome.returncode, 2)
        self.assertFalse(self.output.exists())


class WhisperBuildIntegrationTests(unittest.TestCase):
    def test_build_links_and_copies_only_derived_framework(self):
        source = (ROOT / 'scripts/build_complete.sh').read_text()
        self.assertIn('DOT_WHISPER_ARCHIVE', source)
        self.assertNotIn('DOT_WHISPER_FRAMEWORK', source)
        self.assertIn('FRAMEWORK_PARENT="$INTENTS_BUILD/whisper-input"', source)
        self.assertIn('/usr/bin/ditto "$VERIFIED_WHISPER_FRAMEWORK"', source)
        self.assertLess(source.index('scripts/verify_whisper_input.py --archive'), source.index('xcrun swiftc'))
        self.assertIn('git ls-files --error-unmatch -- packaging/voice-source-manifest.json scripts/verify_whisper_input.py', source)

    def test_actual_metadata_block_records_verified_input_and_final_binary_separately(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'Dot.app'
            resources = app / 'Contents/Resources'
            (resources / 'Offline').mkdir(parents=True)
            (resources / 'Offline/runtime-manifest.json').write_bytes(b'{}')
            (resources / 'bundled-models.json').write_bytes(b'{}')
            framework = app / 'Contents/Frameworks/whisper.framework'
            framework.mkdir(parents=True)
            (framework / 'whisper').write_bytes(b'final signed binary fixture')
            receipt = root / 'whisper-input.json'
            pin, source_sha = gate.source_pin()
            receipt.write_text(json.dumps({'schema_version': 1, 'kind': 'verified_whisper_archive_input',
                                          'archive_filename': pin['filename'],
                                          'archive_sha256': pin['sha256'], 'archive_bytes': pin['bytes'],
                                          'framework_closure_sha256': 'b' * 64,
                                          'library_identifier': 'macos-arm64', 'source_manifest_sha256': source_sha,
                                          'framework_relative_path': 'whisper.framework', 'framework_entries': 5,
                                          'architectures': ['arm64']}))
            source = (ROOT / 'scripts/build_complete.sh').read_text()
            program = source.split("<<'PYCODE'\n", 1)[1].split('\nPYCODE', 1)[0]
            with mock.patch.object(sys, 'argv', ['-', str(app), 'd' * 40, str(receipt)]):
                exec(compile(program, 'build_complete.sh:metadata', 'exec'), {})
            record = json.loads((resources / 'build-provenance.json').read_bytes())
            self.assertEqual(record['whisper_input_archive_sha256'], pin['sha256'])
            self.assertEqual(record['whisper_input_archive_bytes'], pin['bytes'])
            self.assertEqual(record['whisper_input_framework_closure_sha256'], 'b' * 64)
            self.assertEqual(record['whisper_source_manifest_sha256'], source_sha)
            self.assertEqual(record['embedded_whisper_binary_sha256'], hashlib.sha256(b'final signed binary fixture').hexdigest())


if __name__ == '__main__':
    unittest.main()
