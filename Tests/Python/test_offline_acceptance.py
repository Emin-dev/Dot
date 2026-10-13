import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from offline_acceptance import CHECKS, fingerprint, verify

class OfflineAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.app = self.root / 'Dot.app'; resources = self.app / 'Contents/Resources'; resources.mkdir(parents=True)
        (resources / 'build-provenance.json').write_text(json.dumps({'commit': 'abc', 'runtime_bundled': True, 'models_bundled': True, 'llm_weights_download_on_first_launch': False}))
        self.evidence = self.root / 'native-test.log'; self.evidence.write_text('fixture only, never product acceptance\n')
        self.record = {'schema_version': 1, 'commit': 'abc', 'app_fingerprint_sha256': fingerprint(self.app),
                       'checks': {name: {'passed': True, 'evidence_path': 'native-test.log', 'evidence_sha256': hashlib.sha256(self.evidence.read_bytes()).hexdigest()} for name in CHECKS}}
        self.receipt = self.root / 'acceptance.json'
    def tearDown(self): self.temp.cleanup()
    def save(self): self.receipt.write_text(json.dumps(self.record))
    def test_complete_fixture_receipt_binds_app(self):
        self.save(); self.assertTrue(verify(self.app, self.receipt)['verified'])
    def test_missing_native_check_rejected(self):
        self.record['checks'].pop(CHECKS[0]); self.save()
        with self.assertRaises(ValueError): verify(self.app, self.receipt)
    def test_failed_native_check_rejected(self):
        self.record['checks'][CHECKS[0]]['passed'] = False; self.save()
        with self.assertRaises(ValueError): verify(self.app, self.receipt)
    def test_app_change_invalidates_acceptance(self):
        self.save(); (self.app / 'new').write_text('changed')
        with self.assertRaises(ValueError): verify(self.app, self.receipt)
    def test_evidence_change_invalidates_acceptance(self):
        self.save(); self.evidence.write_text('changed')
        with self.assertRaises(ValueError): verify(self.app, self.receipt)
    def test_external_symlink_rejected(self):
        (self.app / 'external').symlink_to(self.evidence)
        with self.assertRaises(ValueError): fingerprint(self.app)
    def test_model_free_provenance_rejected(self):
        path = self.app / 'Contents/Resources/build-provenance.json'; value = json.loads(path.read_text()); value['models_bundled'] = False; path.write_text(json.dumps(value))
        self.record['app_fingerprint_sha256'] = fingerprint(self.app); self.save()
        with self.assertRaises(ValueError): verify(self.app, self.receipt)
