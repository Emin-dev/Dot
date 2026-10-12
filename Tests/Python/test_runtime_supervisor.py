import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[2] / 'Resources/Runtime/dot_runtime.py'
spec = importlib.util.spec_from_file_location('dot_runtime', path)
runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)


class RuntimeLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.models = self.root / 'models'; self.state = self.root / 'state'; self.state.mkdir()
        self.manifest = {'files': []}
        for name in ('llm-target/config.json', 'llm-target/model.safetensors', 'llm-draft/config.json', 'llm-draft/model.safetensors'):
            file = self.models / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(b'fixture')
            self.manifest['files'].append({'path': name})
    def tearDown(self): self.temp.cleanup()
    def test_only_owned_snapshot_links_created(self):
        draft = runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
        self.assertEqual(draft, self.models.resolve() / 'llm-draft')
        links = [p for p in self.state.rglob('*') if p.is_symlink()]
        self.assertEqual(len(links), 2)
        self.assertTrue(all(p.resolve().is_relative_to(self.models.resolve()) for p in links))
    def test_existing_snapshot_never_overwritten(self):
        runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
        with self.assertRaises(FileExistsError): runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
    def test_source_symlink_rejected(self):
        file = self.models / 'llm-target/config.json'; file.unlink(); file.symlink_to('../llm-draft/config.json')
        with self.assertRaises(ValueError): runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
    def test_destination_traversal_rejected(self):
        self.manifest['files'][0]['path'] = 'llm-target/../escape'
        with self.assertRaises(ValueError): runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
    def test_no_duplicate_mapping(self):
        self.manifest['files'].append(self.manifest['files'][0])
        with self.assertRaises(ValueError): runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
    def test_ancestor_mapping_rejected(self):
        self.manifest['files'].append({'path': 'llm-target/config.json/nested'})
        with self.assertRaises(ValueError): runtime.local_snapshot(self.models.resolve(), self.state, self.manifest)
    def test_process_cleanup_signals_only_owned_group(self):
        class Child:
            pid = 12345
            waited = False
            def wait(self): self.waited = True
        child = Child()
        with patch.object(runtime.os, 'killpg') as signal, patch.object(runtime, 'child_exited', return_value=True):
            runtime.stop_group(child)
        self.assertEqual([call.args[0] for call in signal.call_args_list], [12345, 12345]); self.assertTrue(child.waited)
