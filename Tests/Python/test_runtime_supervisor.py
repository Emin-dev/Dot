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
        # Fixture uses the exact retained-listener supervisor path; no model runs.
        with runtime.tls.owned_listener() as backend, runtime.tls.owned_listener() as endpoint:
            return subprocess.Popen([sys.executable, '-B', '-c', entry, str(path), '--payload', str(self.payload), '--models', str(self.models), '--state', str(self.state), '--manifest', str(self.manifest),
                                     '--backend-fd', str(backend.fileno()), '--backend-port', str(backend.getsockname()[1]),
                                     '--tls-fd', str(endpoint.fileno()), '--tls-port', str(endpoint.getsockname()[1])],
                                    pass_fds=(backend.fileno(), endpoint.fileno()), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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

    def test_child_failure_is_classified_without_private_stderr(self):
        import select
        secret = 'FIXTURE_PRIVATE_CONTENT'
        (self.payload / 'Splash/install/launcher.py').write_text(
            "import os,sys\nsys.stderr.write(os.environ['SPLASH_API_KEY'] + ' " + secret + " ModuleNotFoundError: local_fixture\\n')\nsys.exit(7)\n")
        process = self.launch()
        try:
            started = json.loads(process.stdout.readline()); self.assertEqual(started['event'], 'started')
            self.assertTrue(select.select([process.stdout], [], [], 8)[0])
            failed_line = process.stdout.readline(); failed = json.loads(failed_line)
            self.assertEqual(failed['event'], 'failed'); self.assertEqual(failed['reason'], 'module_missing')
            self.assertEqual(failed['exit_status'], 7)
            self.assertNotIn(secret, failed_line); self.assertNotIn(started['api_key'], failed_line)
            _, errors = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 2, errors); self.assertFalse(self.state.exists())
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=8)
    def test_noisy_stderr_does_not_block_parent_eof(self):
        (self.payload / 'Splash/install/launcher.py').write_text(
            "import sys\nwhile True: sys.stderr.write('x'*4096); sys.stderr.flush()\n")
        process = self.launch()
        try:
            self.assertEqual(json.loads(process.stdout.readline())['event'], 'started')
            process.stdin.close(); process.stdin = None
            _, errors = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 0, errors); self.assertFalse(self.state.exists())
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=8)

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

class RuntimeBootstrapTests(unittest.TestCase):
    """No ML imports: fixture launcher only serves an authenticated local byte reply."""
    def setUp(self):
        import shutil
        RuntimeOwnershipTests.setUp(self)
        python_root = self.payload / 'Splash/python'
        shutil.rmtree(python_root)
        python_root.symlink_to(Path(sys.base_prefix).resolve(), target_is_directory=True)
    def tearDown(self): RuntimeOwnershipTests.tearDown(self)
    def arguments(self):
        import argparse
        return argparse.Namespace(sandbox_profile=str(path.with_name('splash.sb')))
    def test_bootstrap_passes_exact_paths_and_continuously_owned_fds(self):
        import os, socket
        captured = []
        def exec_fixture(executable, command, environment):
            self.assertEqual(executable, '/usr/bin/sandbox-exec')
            parameters = dict(command[index + 1].split('=', 1) for index, value in enumerate(command) if value == '-D')
            self.assertEqual(parameters['DOT_STATE'], str(self.state.resolve()))
            self.assertEqual(parameters['DOT_MODELS'], str(self.models.resolve()))
            self.assertEqual(parameters['DOT_MANIFEST'], str(self.manifest.resolve()))
            self.assertEqual(parameters['DOT_PYTHON_ROOT'], str(Path(sys.base_prefix).resolve()))
            for prefix, name in (('backend', 'DOT_BACKEND_ADDRESS'), ('tls', 'DOT_TLS_ADDRESS')):
                descriptor = int(command[command.index('--' + prefix + '-fd') + 1])
                port = int(command[command.index('--' + prefix + '-port') + 1])
                self.assertEqual(parameters[name], 'localhost:' + str(port))
                self.assertTrue(os.get_inheritable(descriptor))
                with socket.socket(fileno=os.dup(descriptor)) as held:
                    self.assertEqual(held.getsockname(), ('127.0.0.1', port))
                    with socket.socket() as contender:
                        with self.assertRaises(OSError) as error: contender.bind(held.getsockname())
                        self.assertEqual(error.exception.errno, errno.EADDRINUSE)
                captured.append(descriptor)
            self.assertEqual(environment, {'PATH': '/usr/bin:/bin', 'HOME': str(self.state.resolve()), 'TMPDIR': str(self.state.resolve()), 'PYTHONDONTWRITEBYTECODE': '1'})
            raise OSError(errno.ENOENT, 'fixture exec rejection')
        # No model/manifest contents are read on the unsandboxed bootstrap path.
        self.manifest.write_text('not JSON; must not be read before sandbox')
        with patch.object(runtime.os, 'execve', side_effect=exec_fixture), patch.object(runtime.os, 'chdir'), patch.object(runtime, 'close_unrelated_descriptors') as close:
            with self.assertRaises(OSError): runtime.bootstrap(self.arguments(), self.payload.resolve(), self.models.resolve(), self.state.resolve(), self.manifest.resolve())
            self.assertEqual(close.call_args.args[0], tuple(captured))
        self.assertEqual(len(captured), 2)
        for descriptor in captured:
            with self.assertRaises(OSError): os.fstat(descriptor)
        self.assertTrue(self.state.exists())
    def test_different_profile_is_rejected_before_binding(self):
        args = self.arguments(); args.sandbox_profile = str(self.manifest)
        with patch.object(runtime.tls, 'owned_listener') as bind:
            with self.assertRaises(ValueError): runtime.bootstrap(args, self.payload.resolve(), self.models.resolve(), self.state.resolve(), self.manifest.resolve())
            bind.assert_not_called()
    def test_unrelated_inheritable_descriptor_is_closed_before_exec(self):
        import os, subprocess
        reader, writer = os.pipe()
        os.set_inheritable(writer, True)
        code = """import importlib.util,os,sys
spec=importlib.util.spec_from_file_location('fixture_runtime',sys.argv[1])
runtime=importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)
with runtime.tls.owned_listener() as backend, runtime.tls.owned_listener() as endpoint:
    kept=(backend.fileno(),endpoint.fileno())
    runtime.close_unrelated_descriptors(kept)
    for fd in kept: os.fstat(fd)
    try: os.fstat(int(sys.argv[2]))
    except OSError: print('UNRELATED_FD_CLOSED',flush=True)
    else: raise AssertionError('unrelated descriptor survived')
"""
        try:
            result = subprocess.run([sys.executable, '-I', '-S', '-B', '-c', code, str(path), str(writer)],
                                    pass_fds=(writer,), capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout, b'UNRELATED_FD_CLOSED\n')
        finally: os.close(reader); os.close(writer)
    @unittest.skipUnless(sys.platform == 'darwin', 'real Seatbelt bootstrap requires macOS')
    def test_actual_bootstrap_sandbox_tls_roundtrip_and_eof_cleanup(self):
        import hashlib, os, select, socket, ssl, subprocess
        launcher = self.payload / 'Splash/install/launcher.py'
        launcher.write_text("""import os,socket,sys
fd = int(sys.argv[sys.argv.index('--listen-fd') + 1])
listener = socket.socket(fileno=fd)
while True:
    connection, _ = listener.accept()
    with connection:
        data = connection.recv(8192)
        expected = ('Bearer ' + os.environ['SPLASH_API_KEY']).encode()
        connection.sendall(b'fixture authenticated' if expected in data else b'unauthorized')
""")
        command = [sys.executable, '-I', '-S', '-B', str(path), '--sandbox-profile', str(path.with_name('splash.sb')),
                   '--payload', str(self.payload), '--models', str(self.models), '--state', str(self.state), '--manifest', str(self.manifest)]
        child = subprocess.Popen(command, cwd=self.state, env={'PATH': '/usr/bin:/bin', 'HOME': str(self.state), 'TMPDIR': str(self.state)},
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([child.stdout], [], [], 12)[0], 'bootstrap did not report ready')
            line = child.stdout.readline()
            if not line:
                _, errors = child.communicate(timeout=8)
                self.fail(f'bootstrap closed output before its started event; exit={child.returncode}; stderr={errors[-8192:]}')
            event = json.loads(line)
            self.assertEqual(event.get('event'), 'started', line)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
            with context.wrap_socket(socket.create_connection(('127.0.0.1', event['port']), timeout=3), server_hostname='dot.local') as secure:
                self.assertEqual(hashlib.sha256(secure.getpeercert(binary_form=True)).hexdigest(), event['tls_certificate_sha256'])
                secure.sendall(('Bearer ' + event['api_key']).encode())
                self.assertEqual(secure.recv(100), b'fixture authenticated')
            child.stdin.close(); child.stdin = None
            _, errors = child.communicate(timeout=8)
            self.assertEqual(child.returncode, 0, errors)
            self.assertFalse(self.state.exists())
            with self.assertRaises(ProcessLookupError): os.kill(event['pid'], 0)
        finally:
            # Reap and close all pipes even when bootstrap exited before readiness.
            if child.poll() is None: child.terminate()
            child.communicate(timeout=8)
