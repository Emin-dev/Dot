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

class RuntimeOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.payload = self.root / 'payload'; splash = self.payload / 'Splash'
        (splash / 'python/bin').mkdir(parents=True); (splash / 'install').mkdir()
        (splash / 'python/bin/python3').symlink_to(sys.executable)
        (splash / 'install/launcher.py').write_text('import time\ntime.sleep(120)\n')
        self.models = self.root / 'models'; self.state = self.root / 'state'; self.state.mkdir(mode=0o700)
        entries = []
        for name in ('llm-target/config.json', 'llm-target/model.safetensors', 'llm-draft/config.json', 'llm-draft/model.safetensors'):
            file = self.models / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(b'fixture'); entries.append({'path': name})
        self.manifest = self.root / 'manifest.json'; self.manifest.write_text(json.dumps({'files': entries}))
    def tearDown(self): self.temp.cleanup()
    def launch(self):
        import subprocess
        # Call the same production main with test-only traceback diagnostics. No model code runs.
        entry = "import runpy,sys,traceback; sys.argv=sys.argv[1:]; scope=runpy.run_path(sys.argv[0],run_name='dot_runtime_fixture');\ntry: sys.exit(scope['main']())\nexcept Exception: traceback.print_exc(); sys.exit(2)"
        return subprocess.Popen([sys.executable, '-B', '-c', entry, str(path), '--payload', str(self.payload), '--models', str(self.models), '--state', str(self.state), '--manifest', str(self.manifest)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    def test_parent_eof_stops_child_and_removes_private_state(self):
        import os
        process = self.launch()
        try:
            event = json.loads(process.stdout.readline()); self.assertEqual(event['event'], 'started')
            process.stdin.close(); process.stdin = None
            _, errors = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 0, errors); self.assertFalse(self.state.exists())
            with self.assertRaises(ProcessLookupError): os.kill(event['pid'], 0)
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=8)
    def test_startup_failure_removes_only_owned_fresh_state(self):
        self.manifest.write_text('{invalid')
        process = self.launch(); process.communicate(timeout=8)
        self.assertEqual(process.returncode, 2); self.assertFalse(self.state.exists())
        self.assertTrue(self.models.exists()); self.assertTrue(self.payload.exists())
    def test_nonempty_state_is_rejected_without_deletion(self):
        marker = self.state / 'preserve'; marker.write_text('private existing data')
        process = self.launch(); process.communicate(timeout=8)
        self.assertEqual(process.returncode, 2); self.assertEqual(marker.read_text(), 'private existing data')
