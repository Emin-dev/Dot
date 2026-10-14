"""Model-free pipe transfer, exec inheritance, metadata and managed-patch checks."""
import argparse
import ast
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import selectors
import socket
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import patch_splash_listener as patcher

spec = importlib.util.spec_from_file_location('dot_secret_process', ROOT / 'Resources/Runtime/dot_process.py')
process = importlib.util.module_from_spec(spec); spec.loader.exec_module(process)
KEY = 'a7' * 32


def helpers():
    scope = dict(argparse=argparse, fcntl=fcntl, os=os, selectors=selectors, stat=stat, time=time)
    exec(patcher.SECRET_HELPER, scope)
    return scope


@contextmanager
def pinned_options(source):
    """Load actual patched options with only three unrelated pure-module stubs."""
    package = types.ModuleType('_dot_pinned_test'); package.__path__ = []
    images = types.ModuleType(package.__name__ + '.images')
    images.MIN_PIXELS = 1; images.MAX_PIXELS = 1024
    origins = types.ModuleType(package.__name__ + '.origins'); origins.ANY_ORIGIN = '*'
    origins.parse_allowed_origin = lambda value: value
    security = types.ModuleType(package.__name__ + '.http_security')
    security.validate_api_key = lambda value: value
    options = types.ModuleType(package.__name__ + '.serve_options')
    options.__package__ = package.__name__
    with patch.dict(sys.modules, {module.__name__: module for module in (package, images, origins, security, options)}):
        exec(compile(source, 'pinned/serve_options.py', 'exec'), options.__dict__)
        yield options


class CredentialPipeTests(unittest.TestCase):
    def setUp(self): self.helper = helpers()
    def take(self, fd):
        return self.helper['dot_take_api_key'](['--listen-fd=200', '--api-key-fd=' + str(fd)])
    def raw(self, value):
        reader, writer = os.pipe()
        os.write(writer, value); os.close(writer)
        return reader
    def closed(self, fd):
        with self.assertRaises(OSError): os.fstat(fd)
    def test_exact_key_consumed_and_descriptor_closed(self):
        fd = self.raw(KEY.encode())
        os.set_inheritable(fd, True)
        self.assertEqual(self.take(fd), KEY)
        self.closed(fd)
    def test_producer_preloads_anonymous_read_pipe_and_closes_parent_after_use(self):
        with process.api_key_pipe(KEY) as fd:
            self.assertFalse(os.get_inheritable(fd))
            self.assertTrue(stat.S_ISFIFO(os.fstat(fd).st_mode))
            self.assertEqual(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDONLY)
            duplicate = os.dup(fd)
            self.assertEqual(self.take(duplicate), KEY)
            # EOF proves no writer is retained by the producer after preload.
            self.assertEqual(os.read(fd, 1), b'')
        self.closed(fd)
    def test_producer_closes_pipe_if_spawn_fails(self):
        descriptor = None
        with self.assertRaisesRegex(OSError, 'fixture'):
            with process.api_key_pipe(KEY) as descriptor:
                raise OSError('fixture spawn failure')
        self.closed(descriptor)
    def test_mutable_producer_transfer_is_wiped_before_spawn(self):
        observed = []
        write = os.write
        def inspect(fd, value):
            observed.append(value)
            return write(fd, value)
        with patch.object(process.os, 'write', side_effect=inspect):
            with process.api_key_pipe(KEY) as fd:
                self.assertEqual(observed, [bytearray(64)])
                self.assertEqual(os.read(fd, 65), KEY.encode())
        self.assertEqual(observed, [bytearray(64)])
    def test_mutable_consumer_transfer_is_wiped_after_success_and_failure(self):
        for value in (KEY.encode(), b'Z' * 64):
            with self.subTest(valid=value == KEY.encode()):
                observed = []
                readv = os.readv
                def inspect(fd, buffers):
                    observed.append(buffers[0].obj)
                    return readv(fd, buffers)
                fd = self.raw(value)
                with patch.object(os, 'readv', side_effect=inspect):
                    if value == KEY.encode(): self.assertEqual(self.take(fd), KEY)
                    else:
                        with self.assertRaises(ValueError): self.take(fd)
                self.assertTrue(observed)
                self.assertTrue(all(buffer == bytearray(65) for buffer in observed))
    def test_bad_producer_keys_rejected_before_creating_a_pipe(self):
        for value in (None, b'a' * 64, '', 'a' * 63, 'a' * 65, 'A' * 64, '\n' + 'a' * 63):
            with self.subTest(value=type(value).__name__), patch.object(process.os, 'pipe') as create:
                with self.assertRaises(ValueError):
                    with process.api_key_pipe(value): pass
                create.assert_not_called()
    def test_short_write_closes_both_ends(self):
        descriptors = os.pipe()
        with patch.object(process.os, 'pipe', return_value=descriptors), patch.object(process.os, 'write', return_value=1):
            with self.assertRaises(OSError):
                with process.api_key_pipe(KEY): self.fail('short write accepted')
        for fd in descriptors: self.closed(fd)
    def test_truncated_oversized_nonhex_and_newline_fail_closed(self):
        for value in (b'', b'a' * 63, b'a' * 65, b'Z' * 64, b'a' * 63 + b'\n', b'\xff' * 64):
            with self.subTest(length=len(value)):
                fd = self.raw(value)
                with self.assertRaises(ValueError): self.take(fd)
                self.closed(fd)
    def test_missing_eof_has_absolute_deadline_and_closes_pipe(self):
        reader, writer = os.pipe()
        os.write(writer, KEY.encode())
        started = time.monotonic()
        try:
            with self.assertRaisesRegex(ValueError, 'timed out'): self.take(reader)
            self.assertLess(time.monotonic() - started, 3)
            self.closed(reader)
        finally: os.close(writer)
    def test_timeout_does_not_restart_after_partial_reads(self):
        class Ready:
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def register(self, *_): pass
            def select(self, timeout):
                self.timeouts.append(timeout); return [object()]
        ready = Ready(); ready.timeouts = []
        reader, writer = os.pipe(); os.write(writer, b'a'); os.close(writer)
        with patch.object(time, 'monotonic', side_effect=[10, 10, 11, 12]), patch.object(selectors, 'DefaultSelector', return_value=ready), patch.object(os, 'readv', side_effect=[1, BlockingIOError()]):
            with self.assertRaisesRegex(ValueError, 'timed out'): self.take(reader)
        self.assertEqual(ready.timeouts, [2, 1]); self.closed(reader)
    def test_regular_file_socket_and_write_pipe_rejected_and_closed(self):
        with tempfile.TemporaryFile() as file, socket.socket() as connection:
            reader, writer = os.pipe()
            for fd in (os.dup(file.fileno()), os.dup(connection.fileno()), writer):
                with self.subTest(fd=fd):
                    with self.assertRaises(ValueError): self.take(fd)
                    self.closed(fd)
            os.close(reader)
    def test_prepare_clears_exec_inheritance_without_consuming(self):
        fd = self.raw(KEY.encode()); os.set_inheritable(fd, True)
        self.assertEqual(self.helper['dot_prepare_api_key_fd'](fd), fd)
        self.assertFalse(os.get_inheritable(fd))
        self.assertEqual(self.take(fd), KEY)
    def test_unmanaged_options_do_not_create_a_key_or_touch_environment(self):
        with patch.dict(os.environ, {'SPLASH_API_KEY': KEY}):
            self.assertIsNone(self.helper['dot_take_api_key'](['--model', 'fixture']))
    def test_ambiguous_or_unpaired_managed_flags_fail(self):
        for argv in (['--listen-fd=10'], ['--api-key-fd=11'],
                     ['--listen-fd=10', '--api-key-fd=11', '--api-key-fd=12'],
                     ['--listen-fd=10', '--listen-fd=12', '--api-key-fd=11'],
                     ['--listen-fd=10', '--api-key-fd=-1'],
                     ['--listen-fd=10', '--api-key-fd=\u0663']):
            with self.subTest(argv=argv), patch.object(os, 'fstat') as inspect:
                with self.assertRaises(ValueError): self.helper['dot_take_api_key'](argv)
                inspect.assert_not_called()


class MetadataAndExecTests(unittest.TestCase):
    def test_key_stays_out_of_both_exec_environments_and_arguments(self):
        # The source under test is the exact generated consumer, run after a
        # launcher-style exec. This remains a model-free fixture, not a payload.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            consumer = root / 'consumer.py'
            consumer.write_text('import argparse,fcntl,hashlib,json,os,selectors,stat,sys,time\n' + patcher.SECRET_HELPER + '''
fd = int(sys.argv[-1])
key = dot_take_api_key(['--listen-fd=200', '--api-key-fd=' + str(fd)])
try: os.fstat(fd)
except OSError: closed = True
else: closed = False
print(json.dumps({'closed': closed, 'hash': hashlib.sha256(key.encode()).hexdigest(),
                  'argv': sys.argv, 'environment': dict(os.environ)}), flush=True)
sys.stdin.buffer.read(1)
''')
            launcher = root / 'launcher.py'
            launcher.write_text('import argparse,fcntl,os,selectors,stat,sys,time\n' + patcher.SECRET_HELPER + '''
fd = int(sys.argv[-1])
dot_prepare_api_key_fd(fd)
# An exec launched before the final server must not inherit the capability.
import subprocess
probe = subprocess.run([sys.executable, '-I', '-S', '-c',
    'import os,sys; fd=int(sys.argv[1]);\\ntry: os.fstat(fd)\\nexcept OSError: sys.exit(0)\\nelse: sys.exit(1)', str(fd)], close_fds=False)
if probe.returncode: sys.exit(90)
os.set_inheritable(fd, True)
os.execve(sys.executable, [sys.executable, '-I', '-S', sys.argv[1], str(fd)], dict(os.environ))
''')
            with process.api_key_pipe(KEY) as fd:
                child = subprocess.Popen([sys.executable, '-I', '-S', str(launcher), str(consumer), str(fd)],
                                         pass_fds=(fd,), env={'PATH': '/usr/bin:/bin'}, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                with selectors.DefaultSelector() as ready:
                    ready.register(child.stdout, selectors.EVENT_READ)
                    self.assertTrue(ready.select(5), 'fixture did not initialize')
                line = child.stdout.readline()
                self.assertTrue(line, child.stderr.read() if child.poll() is not None else 'fixture stopped')
                report = json.loads(line)
                self.assertTrue(report['closed'])
                self.assertEqual(report['hash'], hashlib.sha256(KEY.encode()).hexdigest())
                self.assertNotIn(KEY, json.dumps(report))
                self.assertNotIn('SPLASH_API_KEY', report['environment'])
                if sys.platform == 'linux':
                    for metadata in ('environ', 'cmdline'):
                        raw = Path('/proc', str(child.pid), metadata).read_bytes()
                        self.assertNotIn(KEY.encode(), raw)
                        self.assertNotIn(b'SPLASH_API_KEY', raw)
                    self.assertFalse(Path('/proc', str(child.pid), 'fd', str(fd)).exists())
                child.stdin.close(); child.stdin = None
                _, errors = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, errors)
            finally:
                if child.poll() is None: child.kill(); child.communicate(timeout=5)

    def test_production_supervisor_metadata_and_per_launch_key_rotation(self):
        # Exercise the production supervisor and pipe producer. The backend is
        # deliberately a small fixture; full pinned Splash acceptance is separate.
        from test_runtime_supervisor import RuntimeOwnershipTests
        fixture = RuntimeOwnershipTests(); fixture.setUp()
        self.addCleanup(fixture.tearDown)
        (fixture.payload / 'Splash/install/launcher.py').write_text(
            'import argparse,fcntl,hashlib,hmac,json,os,selectors,socket,stat,sys,time\n' + patcher.SECRET_HELPER + '''
key_fd = int(sys.argv[sys.argv.index('--api-key-fd') + 1])
key = dot_take_api_key(sys.argv[1:])
assert 'SPLASH_API_KEY' not in os.environ
assert key not in repr(sys.argv) and key not in repr(dict(os.environ))
try: os.fstat(key_fd)
except OSError: closed = True
else: closed = False
with open(os.path.join(os.environ['TMPDIR'], 'fixture-ready.json'), 'w') as output:
    json.dump({'closed': closed, 'hash': hashlib.sha256(key.encode()).hexdigest()}, output)
listener = socket.socket(fileno=int(sys.argv[sys.argv.index('--listen-fd') + 1]))
while True:
    connection, _ = listener.accept()
    with connection:
        value = connection.recv(1024)
        valid = hmac.compare_digest(value, ('Bearer ' + key).encode())
        connection.sendall(b'accepted' if valid else b'unauthorized')
''')
        previous = None
        for launch in range(2):
            if launch: fixture.state.mkdir(mode=0o700)
            child = fixture.launch()
            try:
                with selectors.DefaultSelector() as ready:
                    ready.register(child.stdout, selectors.EVENT_READ)
                    self.assertTrue(ready.select(5), 'supervisor did not initialize')
                event = json.loads(child.stdout.readline())
                self.assertEqual(event['event'], 'started')
                report = fixture.state / 'fixture-ready.json'
                deadline = time.monotonic() + 5
                while not report.exists() and time.monotonic() < deadline: time.sleep(0.01)
                record = json.loads(report.read_text())
                self.assertTrue(record['closed'])
                self.assertEqual(record['hash'], hashlib.sha256(event['api_key'].encode()).hexdigest())
                self.assertNotEqual(event['api_key'], previous)
                if sys.platform == 'linux':
                    for field in ('environ', 'cmdline'):
                        metadata = Path('/proc', str(event['pid']), field).read_bytes()
                        self.assertNotIn(event['api_key'].encode(), metadata)
                        self.assertNotIn(b'SPLASH_API_KEY', metadata)
                for credential, reply in ((event['api_key'], b'accepted'),
                                          (previous or '0' * 64, b'unauthorized')):
                    with socket.create_connection(('127.0.0.1', event['backend_port']), timeout=2) as client:
                        client.sendall(('Bearer ' + credential).encode())
                        self.assertEqual(client.recv(100), reply)
                previous = event['api_key']
                child.stdin.close(); child.stdin = None
                _, errors = child.communicate(timeout=8)
                self.assertEqual(child.returncode, 0, errors)
                self.assertFalse(fixture.state.exists())
            finally:
                if child.poll() is None: child.terminate(); child.communicate(timeout=8)


class PatchIntegrityTests(unittest.TestCase):
    def test_v2_manifest_and_swift_gate_are_identical(self):
        record = json.loads((ROOT / 'Resources/Runtime/splash-managed-listener-patch.json').read_text())
        swift = (ROOT / 'src/OfflinePayload.swift').read_text()
        self.assertEqual(record['id'], patcher.PATCH_ID)
        self.assertIn('manifest.transport_patch == "' + patcher.PATCH_ID + '"', swift)
        self.assertEqual(record['upstream_revision'], patcher.REVISION)
        for entry in record['files']:
            self.assertEqual(entry['upstream_sha256'], patcher.PINNED[entry['path'].removeprefix('Splash/')])
            self.assertIn('"' + entry['path'] + '": "' + entry['sha256'] + '"', swift)
    def test_supervisor_has_no_environment_secret_and_explicit_pipe_capability(self):
        source = (ROOT / 'Resources/Runtime/dot_runtime.py').read_text()
        tree = ast.parse(source)
        self.assertNotIn('SPLASH_API_KEY', source)
        self.assertIn('_process.api_key_pipe(api_key)', source)
        self.assertIn('pass_fds=(listener.fileno(), key_fd)', source)
        self.assertTrue(any(isinstance(node, ast.With) for node in ast.walk(tree)))
    @unittest.skipUnless(os.environ.get('DOT_SPLASH_UPSTREAM_SOURCE'), 'pinned external source is not bundled')
    def test_exact_upstream_reproduces_recorded_overlay(self):
        values = patcher.overlay(os.environ['DOT_SPLASH_UPSTREAM_SOURCE'])
        record = json.loads((ROOT / 'Resources/Runtime/splash-managed-listener-patch.json').read_text())
        for entry in record['files']:
            source = values[entry['path'].removeprefix('Splash/')]
            self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), entry['sha256'])
        server = values['server/server.py']
        self.assertLess(server.index('serve_options.dot_take_api_key'), server.index('from transformers'))
        self.assertIn('args.api_key = _dot_managed_api_key', server)
        self.assertIn('os.set_inheritable(args.api_key_fd, True)', values['install/launcher.py'])

    @unittest.skipUnless(os.environ.get('DOT_SPLASH_UPSTREAM_SOURCE'), 'pinned external source is not bundled')
    def test_exact_patched_launcher_closes_on_prepare_and_exec_failure(self):
        import signal
        values = patcher.overlay(os.environ['DOT_SPLASH_UPSTREAM_SOURCE'])
        nodes = [node for node in ast.parse(values['install/launcher.py']).body
                 if isinstance(node, ast.FunctionDef) and node.name in ('serve', '_dot_serve')]
        self.assertEqual(len(nodes), 2)
        with pinned_options(values['server/serve_options.py']) as options, tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for failure in ('prepare', 'exec'):
                with self.subTest(failure=failure), socket.socket() as listener, tempfile.TemporaryFile() as record:
                    listener.bind(('127.0.0.1', 0)); listener.listen(1)
                    reader, writer = os.pipe(); os.write(writer, KEY.encode()); os.close(writer)
                    parser = argparse.ArgumentParser(); options.add_serve_arguments(parser)
                    args = parser.parse_args(['--listen-fd', str(listener.fileno()), '--api-key-fd', str(reader)])
                    options.check_serve_arguments(parser, args)
                    args.offline = True; args.port = listener.getsockname()[1]
                    args.model = 'fixture/model'; args.revision = 'fixture'; args.language_only = False; args.draft_model = None
                    class FixtureFailure(Exception): pass
                    reached = []
                    def preparation(_):
                        self.assertFalse(os.get_inheritable(reader))
                        reached.append('prepare')
                        if failure == 'prepare': raise FixtureFailure()
                    def execute(executable, command, environment):
                        reached.append('exec')
                        self.assertTrue(os.get_inheritable(reader))
                        self.assertIn('--api-key-fd=' + str(reader), command)
                        self.assertNotIn('SPLASH_API_KEY', environment)
                        self.assertNotIn(KEY, repr(command) + repr(environment))
                        duplicate = os.dup(reader)
                        self.assertEqual(options.dot_take_api_key(['--listen-fd=200', '--api-key-fd=' + str(duplicate)]), KEY)
                        raise FixtureFailure()
                    scope = dict(os=os, signal=signal, socket=socket, fcntl=fcntl, json=json,
                                 serve_options=options, RUNTIME_DIR=root, ROOT=root, STOP_SIGNALS=(),
                                 _interrupt=lambda *_: None, _ensure_installed=preparation,
                                 _check_port=lambda *_: self.fail('managed port was probed'),
                                 model_artifacts=types.SimpleNamespace(Selection=types.SimpleNamespace(of=lambda *_, **__: types.SimpleNamespace(link=root, models_root=root))),
                                 assembly=types.SimpleNamespace(hold=lambda *_: (root, record)),
                                 paths=types.SimpleNamespace(MODELS=root, PYTHON=sys.executable, BINARY=root / 'engine'))
                    exec(compile(ast.Module(body=nodes, type_ignores=[]), 'pinned/launcher.py', 'exec'), scope)
                    with patch.object(os, 'execve', side_effect=execute), patch.dict(os.environ, {}, clear=True):
                        with self.assertRaises(FixtureFailure): scope['serve'](args)
                    self.assertEqual(reached, ['prepare'] if failure == 'prepare' else ['prepare', 'exec'])
                    with self.assertRaises(OSError): os.fstat(reader)

    @unittest.skipUnless(os.environ.get('DOT_SPLASH_UPSTREAM_SOURCE'), 'pinned external source is not bundled')
    def test_exact_patched_server_injects_only_consumed_memory_key(self):
        values = patcher.overlay(os.environ['DOT_SPLASH_UPSTREAM_SOURCE'])
        tree = ast.parse(values['server/server.py'])
        prelude = [node for node in tree.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == '_dot_managed_api_key' for target in node.targets)]
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ('parse_args', 'main')]
        self.assertEqual(len(prelude), 1); self.assertEqual(len(functions), 2)
        with pinned_options(values['server/serve_options.py']) as options:
            reader, writer = os.pipe(); os.write(writer, KEY.encode()); os.close(writer)
            argv = ['fixture', 'model-root', '--tokenizer=fixture', '--model=fixture/model', '--listen-fd=200', '--api-key-fd=' + str(reader)]
            observed = []
            class StopInspection(BaseException): pass
            def server(*_, **kwargs):
                observed.append(kwargs['api_key'])
                with self.assertRaises(OSError): os.fstat(reader)
                raise StopInspection()
            signal = types.SimpleNamespace(SIGTERM=15, SIGINT=2, SIG_IGN=1, SIG_UNBLOCK=1,
                                           signal=lambda *_: None, pthread_sigmask=lambda *_: None)
            scope = dict(__name__='__main__', sys=types.SimpleNamespace(argv=argv), argparse=argparse,
                         serve_options=options, ROOT=ROOT, signal=signal, _interrupt=lambda *_: None,
                         _raise_descriptor_limit=lambda: None, FrontendServer=server,
                         engine_runtime=types.SimpleNamespace(EngineRuntimeError=RuntimeError),
                         ThinkingKeyError=RuntimeError, ChatTemplateError=RuntimeError)
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, {}, clear=True):
                exec(compile(ast.Module(body=prelude + functions, type_ignores=[]), 'pinned/server.py', 'exec'), scope)
                with self.assertRaises(StopInspection): scope['main']()
            self.assertEqual(observed, [KEY])
            self.assertIsNone(scope['_dot_managed_api_key'])

    @unittest.skipUnless(os.environ.get('DOT_SPLASH_UPSTREAM_SOURCE'), 'pinned external source is not bundled')
    def test_exact_managed_options_reject_environment_and_argument_keys(self):
        values = patcher.overlay(os.environ['DOT_SPLASH_UPSTREAM_SOURCE'])
        with pinned_options(values['server/serve_options.py']) as options:
            for mode in ('environment', 'argument', 'same_descriptor'):
                with self.subTest(mode=mode), patch.dict(os.environ, {}, clear=True):
                    if mode == 'environment': os.environ['SPLASH_API_KEY'] = KEY
                    parser = argparse.ArgumentParser(); options.add_serve_arguments(parser)
                    argv = ['--listen-fd=30', '--api-key-fd=' + ('30' if mode == 'same_descriptor' else '31')]
                    if mode == 'argument': argv += ['--api-key=' + KEY]
                    args = parser.parse_args(argv)
                    errors = io.StringIO()
                    with patch.object(sys, 'stderr', errors):
                        with self.assertRaises(SystemExit): options.check_serve_arguments(parser, args)
                    self.assertNotIn(KEY, errors.getvalue())


if __name__ == '__main__': unittest.main()
