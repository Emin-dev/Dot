import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from audit_runtime_payload import audit_runtime, REQUIRED
from verify_whisper_input import source_pin

class RuntimeAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        names = [name for group in REQUIRED.values() for name in group] + ['LICENSE']
        files = []
        for name in names:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
            files.append({'path': name, 'kind': 'file', 'bytes': 7, 'sha256': hashlib.sha256(b'fixture').hexdigest()})
        self.manifest = {'schema_version': 1, 'kind': 'verified_runtime_payload', 'files': files,
                         'components': [{'role': role, 'files': paths.copy(), 'license_paths': ['LICENSE'], 'license': 'fixture'} for role, paths in REQUIRED.items()]}
    def tearDown(self): self.temp.cleanup()
    def audit(self):
        (self.root / 'runtime-manifest.json').write_text(json.dumps(self.manifest))
        return audit_runtime(self.root, enforce_pins=False)
    def test_complete_fixture(self): self.assertEqual(self.audit()['files'], 10)
    def test_unmanifested_code_rejected(self):
        (self.root / 'extra.py').write_bytes(b'bad')
        with self.assertRaises(ValueError): self.audit()
    def test_readable_unhashed_required_file_rejected(self):
        self.manifest['files'] = [x for x in self.manifest['files'] if x['path'] != 'Splash/engine/splash']
        with self.assertRaises(ValueError): self.audit()
    def test_wrong_component_coverage_rejected(self):
        self.manifest['components'][0]['files'].remove('Splash/engine/splash')
        with self.assertRaises(ValueError): self.audit()
    def test_model_pin_gate_rejects_fake_fixture(self):
        self.audit()
        with self.assertRaises(ValueError): audit_runtime(self.root)
    def test_tampering_rejected(self):
        (self.root / 'Voice/python/bin/python3').write_bytes(b'changed')
        with self.assertRaises(ValueError): self.audit()
    def test_external_manifest_symlink_rejected(self):
        self.audit()
        external = self.root.parent / (self.root.name + '-external.json')
        self.addCleanup(lambda: external.unlink(missing_ok=True))
        external.write_text(json.dumps(self.manifest))
        path = self.root / 'runtime-manifest.json'; path.unlink(); path.symlink_to(external)
        with self.assertRaises(ValueError): audit_runtime(self.root, enforce_pins=False)
    def test_oversized_manifest_rejected_before_json_decode(self):
        path = self.root / 'runtime-manifest.json'
        with path.open('wb') as file: file.truncate(16_000_001)
        with self.assertRaises(ValueError): audit_runtime(self.root, enforce_pins=False)


class WhisperProvenanceAssemblyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / 'Dot.app'
        self.resources = self.app / 'Contents/Resources'
        (self.resources / 'Offline').mkdir(parents=True)
        framework = self.app / 'Contents/Frameworks/whisper.framework'
        framework.mkdir(parents=True)
        (framework / 'whisper').write_bytes(b'native fixture')
        (self.resources / 'Offline/runtime-manifest.json').write_bytes(b'{}')
        (self.resources / 'bundled-models.json').write_bytes(b'{}')
        pin, source_sha = source_pin()
        self.whisper_receipt = self.app.parent / 'whisper-input.json'
        self.whisper_receipt.write_text(json.dumps({
            'schema_version': 1, 'kind': 'verified_whisper_archive_input',
            'archive_filename': pin['filename'], 'archive_bytes': pin['bytes'], 'archive_sha256': pin['sha256'],
            'source_manifest_sha256': source_sha, 'library_identifier': 'macos-arm64_x86_64',
            'architectures': ['arm64', 'x86_64'], 'framework_relative_path': 'whisper.framework',
            'framework_entries': 3, 'framework_closure_sha256': 'a' * 64}))

    def assemble_metadata(self):
        source = (Path(__file__).resolve().parents[2] / 'scripts/build_complete.sh').read_text()
        program = source.split("<<'PYCODE'\n", 1)[1].split('\nPYCODE', 1)[0]
        with mock.patch.object(sys, 'argv', ['-', str(self.app), 'a' * 40, str(self.whisper_receipt)]):
            exec(compile(program, 'build_complete.sh:metadata', 'exec'), {})
        return json.loads((self.resources / 'build-provenance.json').read_text())

    def test_missing_whisper_receipt_rejects_metadata_assembly(self):
        self.whisper_receipt.unlink()
        with self.assertRaises(OSError): self.assemble_metadata()
        self.assertFalse((self.resources / 'build-provenance.json').exists())

    def test_inconsistent_whisper_receipt_rejects_metadata_assembly(self):
        receipt = json.loads(self.whisper_receipt.read_text())
        receipt['archive_sha256'] = '0' * 64
        self.whisper_receipt.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'disagrees with repository pin'): self.assemble_metadata()
        self.assertFalse((self.resources / 'build-provenance.json').exists())
