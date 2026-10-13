import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from audit_runtime_payload import audit_runtime, REQUIRED

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
