import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from audit_offline_bundle import audit, relative
from prepare_offline_layout import prepare


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name); self.payload = self.base / 'payload'; self.payload.mkdir()
        names = ['runtime/bin', 'target/config.json', 'target/model.safetensors', 'draft/config.json',
                 'draft/model.safetensors', 'stt/model', 'tts/model', 'LICENSE']
        entries = []
        for name in names:
            path = self.payload / name; path.parent.mkdir(parents=True, exist_ok=True)
            data = ('fixture:' + name).encode(); path.write_bytes(data)
            entries.append({'path': name, 'kind': 'file', 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'source_path': path.name})
        roles = {'splash_runtime': ['runtime/bin'], 'llm_target': names[1:3], 'llm_draft': names[3:5],
                 'vision': ['target/model.safetensors'], 'speech_recognition': ['stt/model'], 'speech_synthesis': ['tts/model']}
        self.manifest = {'schema_version': 1, 'kind': 'verified_offline_payload', 'files': entries,
                         'components': [{'role': role, 'files': files, 'license_paths': ['LICENSE'], 'license': 'test-fixture',
                                         'repository': 'owner/model', 'revision': 'a' * 40} for role, files in roles.items()]}
    def tearDown(self): self.temp.cleanup()
    def test_complete_fixture_passes(self): self.assertEqual(audit(self.payload, self.manifest)['files'], 8)
    def test_plan_is_not_a_bundle(self):
        self.manifest['kind'] = 'planning_inventory_not_a_complete_bundle_manifest'
        with self.assertRaises(ValueError): audit(self.payload, self.manifest)
    def test_tampering_fails(self):
        (self.payload / 'runtime/bin').write_bytes(b'bad')
        with self.assertRaises(ValueError): audit(self.payload, self.manifest)
    def test_extra_untracked_payload_fails(self):
        (self.payload / 'private-recording.wav').write_bytes(b'sensitive')
        with self.assertRaises(ValueError): audit(self.payload, self.manifest)
    def test_missing_component_fails(self):
        self.manifest['components'].pop()
        with self.assertRaises(ValueError): audit(self.payload, self.manifest)
    def test_missing_license_fails(self):
        self.manifest['components'][0]['license_paths'] = []
        with self.assertRaises(ValueError): audit(self.payload, self.manifest)
    def test_unsafe_paths_rejected(self):
        for value in ('../escape', '/absolute', 'a/../b', 'a\\b', 'a//b', '.'):
            with self.subTest(value=value), self.assertRaises(ValueError): relative(value)
    def test_external_symlink_fails(self):
        outside = self.base / 'outside'; outside.write_text('not bundled')
        link = self.payload / 'link'; link.symlink_to(outside)
        self.manifest['files'].append({'path': 'link', 'kind': 'symlink', 'target': str(outside)})
        with self.assertRaises(ValueError): audit(self.payload, self.manifest)
    def test_internal_relative_symlink_passes(self):
        (self.payload / 'link').symlink_to('runtime/bin')
        self.manifest['files'].append({'path': 'link', 'kind': 'symlink', 'target': 'runtime/bin'})
        self.assertEqual(audit(self.payload, self.manifest)['files'], 9)
    def test_offline_plan_uses_only_bundled_sources(self):
        state = self.base / 'state'; plan = prepare(self.payload, self.manifest, state)
        self.assertEqual(plan['environment']['HF_HUB_OFFLINE'], '1')
        self.assertIn('--offline', plan['launcher_arguments'])
        snapshot = state / 'hf/hub/models--owner--model/snapshots' / ('a' * 40)
        self.assertEqual((snapshot / 'config.json').resolve(), (self.payload / 'target/config.json').resolve())
        self.assertTrue((state / 'launch-plan.json').is_file())
    def test_existing_state_never_replaced(self):
        state = self.base / 'state'; state.mkdir(); (state / 'keep').write_text('keep')
        with self.assertRaises(FileExistsError): prepare(self.payload, self.manifest, state)
        self.assertEqual((state / 'keep').read_text(), 'keep')
    def test_unpinned_model_fails_before_creating_state(self):
        self.manifest['components'][1]['revision'] = 'main'
        state = self.base / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists())

    def test_directory_symlink_cannot_be_snapshot_source(self):
        (self.payload / 'directory-link').symlink_to('target', target_is_directory=True)
        self.manifest['files'].append({'path': 'directory-link', 'kind': 'symlink', 'target': 'target', 'source_path': 'subdir'})
        self.manifest['components'][1]['files'].append('directory-link')
        self.manifest['files'][1]['source_path'] = 'subdir/newfile'
        state = self.base / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists()); self.assertFalse((self.payload / 'target/newfile').exists())
    def test_snapshot_ancestor_collision_fails_before_state(self):
        self.manifest['files'][1]['source_path'] = 'directory'
        self.manifest['files'][2]['source_path'] = 'directory/nested'
        state = self.base / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists())

    def test_draft_directory_symlinks_cannot_satisfy_model_pair(self):
        directory = self.payload / 'placeholder'; directory.mkdir()
        for name in ('draft/config.json', 'draft/model.safetensors'):
            path = self.payload / name; path.unlink(); path.symlink_to('../placeholder')
            entry = next(item for item in self.manifest['files'] if item['path'] == name)
            entry.clear(); entry.update({'path': name, 'kind': 'symlink', 'target': '../placeholder'})
        state = self.base / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists())

    def test_nonadjacent_snapshot_ancestor_collision_fails(self):
        target = next(item for item in self.manifest['components'] if item['role'] == 'llm_target')
        entries = {entry['path']: entry for entry in self.manifest['files']}
        entries[target['files'][0]]['source_path'] = 'a'
        entries[target['files'][1]]['source_path'] = 'a/c'
        extra = self.payload / 'target-extra'; extra.write_bytes(b'extra')
        self.manifest['files'].append({'path': 'target-extra', 'kind': 'file', 'bytes': 5, 'sha256': hashlib.sha256(b'extra').hexdigest(), 'source_path': 'a-b'})
        target['files'].append('target-extra')
        state = self.base / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists())

    def test_state_may_not_mutate_payload(self):
        state = self.payload / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists())
    def test_state_symlink_parent_into_payload_rejected(self):
        alias = self.base / 'alias'; alias.symlink_to(self.payload, target_is_directory=True)
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, alias / 'state')
        self.assertFalse((self.payload / 'state').exists())
    def test_duplicate_draft_reference_not_complete_model(self):
        self.manifest['components'][2]['files'] = ['draft/config.json', 'draft/config.json']
        state = self.base / 'state'
        with self.assertRaises(ValueError): prepare(self.payload, self.manifest, state)
        self.assertFalse(state.exists())


if __name__ == '__main__': unittest.main()
