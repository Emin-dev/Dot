import importlib.util
import errno
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

class RuntimeSignalTests(unittest.TestCase):
    def test_term_resistant_descendant_is_killed_before_leader_reaped(self):
        import os, select, signal, subprocess
        reader, writer = os.pipe()
        grandchild = "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(int(sys.argv[1]),b'ready'); time.sleep(5)"
        leader = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[2],sys.argv[1]],pass_fds=(int(sys.argv[1]),),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(10)"
        child = subprocess.Popen([sys.executable, '-c', leader, str(writer), grandchild], pass_fds=(writer,), start_new_session=True)
        os.close(writer)
        try:
            self.assertTrue(select.select([reader], [], [], 3)[0], 'descendant did not start')
            self.assertEqual(os.read(reader, 5), b'ready')
            runtime.stop_group(child)
            self.assertIsNotNone(child.returncode)
            self.assertTrue(select.select([reader], [], [], 2)[0], 'descendant survived group shutdown')
            self.assertEqual(os.read(reader, 1), b'', 'descendant still owns inherited pipe')
        finally:
            os.close(reader)
            if child.returncode is None:
                try: os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                child.wait(timeout=3)
    def child(self):
        class Child:
            pid = 12345
            returncode = None
            waited = False
            def wait(self): self.waited = True; self.returncode = 0
        return Child()
    def test_live_leader_permission_failure_is_not_hidden(self):
        child = self.child()
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.object(runtime, 'child_exited', return_value=False), patch.object(runtime.os, 'killpg', side_effect=PermissionError(errno.EPERM, 'fixture')):
            with self.assertRaises(PermissionError): runtime.stop_group(child)
        self.assertFalse(child.waited)
    def test_zombie_only_darwin_group_requires_post_reap_absence(self):
        import signal
        child = self.child()
        def deliver(pid, number):
            self.assertEqual(pid, child.pid)
            self.assertEqual(child.waited, number == 0, 'no nonzero signal may follow reap')
            if number == signal.SIGKILL: raise PermissionError(errno.EPERM, 'fixture')
            if number == 0: raise ProcessLookupError()
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.object(runtime, 'child_exited', return_value=True), patch.object(runtime.os, 'killpg', side_effect=deliver) as kill:
            runtime.stop_group(child)
        self.assertTrue(child.waited)
        self.assertEqual([call.args[1] for call in kill.call_args_list], [signal.SIGTERM, signal.SIGKILL, 0])
    def test_remaining_group_after_reap_is_not_reported_clean(self):
        child = self.child()
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.object(runtime, 'child_exited', return_value=True), patch.object(runtime.os, 'killpg', side_effect=[None, PermissionError(errno.EPERM, 'fixture'), None]):
            with self.assertRaises(PermissionError): runtime.stop_group(child)
        self.assertTrue(child.waited)

    def test_post_reap_permission_failure_is_not_hidden(self):
        child = self.child()
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.object(runtime, 'child_exited', return_value=True), patch.object(runtime.os, 'killpg', side_effect=[None, PermissionError(errno.EPERM, 'fixture'), PermissionError(errno.EPERM, 'fixture')]):
            with self.assertRaises(PermissionError): runtime.stop_group(child)
        self.assertTrue(child.waited)
    def test_darwin_already_exited_group_still_attempts_final_kill(self):
        import signal
        child = self.child()
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.object(runtime, 'child_exited', return_value=True), patch.object(runtime.os, 'killpg', side_effect=[PermissionError(errno.EPERM, 'fixture'), PermissionError(errno.EPERM, 'fixture'), ProcessLookupError()]) as kill:
            runtime.stop_group(child)
        self.assertEqual([call.args[1] for call in kill.call_args_list], [signal.SIGTERM, signal.SIGKILL, 0])
    def test_non_darwin_permission_failure_is_not_hidden(self):
        child = self.child()
        with patch.object(runtime.sys, 'platform', 'linux'), patch.object(runtime, 'child_exited', return_value=True), patch.object(runtime.os, 'killpg', side_effect=[None, PermissionError(errno.EPERM, 'fixture')]):
            with self.assertRaises(PermissionError): runtime.stop_group(child)
        self.assertFalse(child.waited)

    def test_other_permission_errno_does_not_use_darwin_exception(self):
        child = self.child()
        with patch.object(runtime.sys, 'platform', 'darwin'), patch.object(runtime, 'child_exited', return_value=True), patch.object(runtime.os, 'killpg', side_effect=PermissionError(errno.EACCES, 'fixture')):
            with self.assertRaises(PermissionError): runtime.stop_group(child)
        self.assertFalse(child.waited)
