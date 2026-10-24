import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from audit_runtime_payload import audit_runtime, REQUIRED
from slim_runtime_payload import slim, MODEL_LICENSE, PYTHON_VOICE_KEYS

KOKORO = 'Voice/python/lib/python3.11/site-packages/kokoro-0.9.4.dist-info/licenses/LICENSE'
APACHE = b'Apache License\nVersion 2.0, January 2004\n'


class SlimRuntimePayloadTests(unittest.TestCase):
    """Audit N1: the retired Python voice runtime leaves the payload and the manifest together."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / 'Offline'
        self.files = []
        for name in [n for group in REQUIRED.values() for n in group]:
            self.file(name, b'fixture')
        for name in ('Splash/LICENSE', 'STT/WHISPER-CPP-LICENSE.txt', 'Voice/python/bin/python3',
                     'Voice/provenance/complete-voice-lock.json'):
            self.file(name, b'fixture ' + name.encode())
        self.file(KOKORO, APACHE)
        os.symlink('python3', self.root / 'Voice/python/bin/python')
        self.files.append({'path': 'Voice/python/bin/python', 'kind': 'symlink', 'target': 'python3'})
        voice = [e['path'] for e in self.files if e['path'].startswith('Voice/')]
        self.manifest = {
            'schema_version': 1, 'kind': 'verified_runtime_payload', 'files': self.files,
            'transport_patch': 'dot-splash-owned-listener-secret-pipe-v2',
            'import_probe': {'status': 'passed_offline'}, 'dependency_lock_complete': True,
            'dependency_lock_path': 'Voice/provenance/complete-voice-lock.json', 'dependency_lock_sha256': '0' * 64,
            'voice_acceptance': {'receipt_path': 'Voice/provenance/x.json'},
            'components': [
                {'role': 'splash_runtime', 'files': REQUIRED['splash_runtime'] + ['Splash/LICENSE'],
                 'license_paths': ['Splash/LICENSE'], 'license': 'Apache-2.0'},
                {'role': 'speech_synthesis', 'files': voice, 'license_paths': [KOKORO], 'license': 'mixed'},
                {'role': 'speech_recognition', 'files': REQUIRED['speech_recognition'] + ['STT/WHISPER-CPP-LICENSE.txt'],
                 'license_paths': ['STT/WHISPER-CPP-LICENSE.txt'], 'license': 'MIT'},
            ]}
        self.save()

    def file(self, name, data):
        path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        self.files.append({'path': name, 'kind': 'file', 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})

    def save(self):
        (self.root / 'runtime-manifest.json').write_text(json.dumps(self.manifest))

    def loaded(self):
        return json.loads((self.root / 'runtime-manifest.json').read_text())

    def test_python_voice_leaves_payload_and_manifest_and_the_audit_passes(self):
        before = audit_runtime(self.root, enforce_pins=False)
        with self.assertRaisesRegex(ValueError, 'retired Python voice runtime'):
            audit_runtime(self.root, enforce_pins=False, require_slim=True)
        result = slim(self.root)
        self.assertEqual(result['removed_files'], 4)
        self.assertFalse((self.root / 'Voice/python').exists())
        self.assertFalse((self.root / 'Voice/provenance').exists())
        self.assertEqual((self.root / MODEL_LICENSE).read_bytes(), APACHE)
        manifest = self.loaded()
        self.assertFalse(any(key in manifest for key in PYTHON_VOICE_KEYS))
        self.assertEqual(manifest['slimmed']['removed_roots'], ['Voice/python', 'Voice/provenance'])
        voice = next(c for c in manifest['components'] if c['role'] == 'speech_synthesis')
        self.assertEqual(voice['license_paths'], [MODEL_LICENSE])
        self.assertTrue(all(name.startswith('Voice/model/') for name in voice['files']))
        after = audit_runtime(self.root, enforce_pins=False, require_slim=True)
        self.assertEqual(after['files'], before['files'] - 4 + 1)

    def test_a_second_run_changes_nothing(self):
        slim(self.root)
        first = (self.root / 'runtime-manifest.json').read_bytes()
        self.assertEqual(slim(self.root), {'removed_files': 0, 'removed_bytes': 0})
        self.assertEqual((self.root / 'runtime-manifest.json').read_bytes(), first)

    def test_a_kept_link_into_the_removed_runtime_is_refused_before_anything_changes(self):
        os.symlink('../Voice/python/bin/python3', self.root / 'Splash/python-link')
        self.manifest['files'].append({'path': 'Splash/python-link', 'kind': 'symlink', 'target': '../Voice/python/bin/python3'})
        self.save()
        with self.assertRaisesRegex(ValueError, 'points into the removed runtime'):
            slim(self.root)
        self.assertTrue((self.root / 'Voice/python/bin/python3').exists())

    def test_a_kept_link_that_reaches_the_runtime_through_another_link_is_refused(self):
        os.symlink('../Voice/model', self.root / 'Splash/d')
        os.symlink('d/../python/bin/python3', self.root / 'Splash/e')
        self.manifest['files'] += [{'path': 'Splash/d', 'kind': 'symlink', 'target': '../Voice/model'},
                                   {'path': 'Splash/e', 'kind': 'symlink', 'target': 'd/../python/bin/python3'}]
        self.save()
        with self.assertRaisesRegex(ValueError, 'points into the removed runtime'):
            slim(self.root)
        self.assertTrue((self.root / 'Voice/python').exists())

    def test_a_linked_voice_folder_or_license_link_is_refused(self):
        outside = self.root.parent / 'outside'
        (self.root / 'Voice').rename(outside)
        os.symlink(outside, self.root / 'Voice')
        with self.assertRaisesRegex(ValueError, 'must be a real folder'):
            slim(self.root)
        self.assertTrue((outside / 'python/bin/python3').exists())
        (self.root / 'Voice').unlink(); outside.rename(self.root / 'Voice')
        os.symlink(self.root.parent / 'elsewhere', self.root / MODEL_LICENSE)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            slim(self.root)
        self.assertFalse((self.root.parent / 'elsewhere').exists())

    def test_an_unlisted_file_in_the_removed_runtime_is_refused(self):
        (self.root / 'Voice/python/extra.py').write_bytes(b'unlisted')
        with self.assertRaisesRegex(ValueError, 'does not match the manifest'):
            slim(self.root)
        self.assertTrue((self.root / 'Voice/python').exists())

    def test_a_missing_or_altered_kokoro_license_is_refused(self):
        voice = self.manifest['components'][1]
        voice['license_paths'] = []
        self.save()
        with self.assertRaisesRegex(ValueError, 'Kokoro license.*kokoro-0.9.4.dist-info/licenses/LICENSE'):
            slim(self.root)
        voice['license_paths'] = [KOKORO]
        self.save()
        (self.root / KOKORO).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            slim(self.root)
        self.assertTrue((self.root / 'Voice/python').exists())

    def test_removed_runtime_on_disk_but_not_in_the_manifest_is_refused(self):
        slim(self.root)
        (self.root / 'Voice/python').mkdir()
        with self.assertRaisesRegex(ValueError, 'not in the manifest'):
            slim(self.root)


if __name__ == '__main__':
    unittest.main()
