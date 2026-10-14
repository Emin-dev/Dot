#!/usr/bin/env python3
"""Own one pinned offline Splash process tree. No discovery or user-cache access."""
import argparse
import errno
import importlib.util
import json
import os
import resource
from pathlib import Path
import select
import secrets
import shutil
import stat
import signal
import socket
import subprocess
import sys
import time

PROTOCOL = 1
MODEL = 'mlx-community/Qwen3.8-27B-4bit'
REVISION = '10c35caafbb80f7dc6a7a432cdd11af10a6d4818'
_spec = importlib.util.spec_from_file_location('_dot_tls', Path(__file__).with_name('dot_tls.py'))
tls = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(tls)
_process_spec = importlib.util.spec_from_file_location('_dot_process', Path(__file__).with_name('dot_process.py'))
_process = importlib.util.module_from_spec(_process_spec); _process_spec.loader.exec_module(_process)
child_exited = _process.child_exited


class FailureTail:
    """Keep only a small private tail; publish fixed codes, never library text."""
    limit = 8192
    def __init__(self): self.data = bytearray()
    def append(self, data):
        self.data.extend(data[-self.limit:]); del self.data[:-self.limit]
    def drain(self, stream, maximum_reads=4):
        # One bounded nonblocking drain per loop; a noisy child cannot starve Stop.
        for _ in range(maximum_reads):
            try: data = os.read(stream.fileno(), 4096)
            except BlockingIOError: return True
            if not data: return False
            self.append(data)
        return True
    def reason(self):
        value = bytes(self.data).lower()
        for code, markers in (
            ('module_missing', (b'modulenotfounderror', b'no module named')),
            ('permission_denied', (b'permission denied', b'operation not permitted')),
            ('out_of_memory', (b'out of memory', b'memoryerror', b'failed to allocate')),
            ('file_missing', (b'no such file or directory', b'filenotfounderror')),
            ('argument_rejected', (b'unrecognized arguments', b'unknown option')),
            ('device_unsupported', (b'unsupported device', b'unsupported gpu')),
        ):
            if any(marker in value for marker in markers): return code
        return 'process_exited'


class RuntimeDiagnosticError(Exception):
    def __init__(self, stage, reason):
        self.stage, self.reason = stage, reason
        super().__init__('bundled_runtime_failed')


def exception_reason(error):
    if isinstance(error, FileNotFoundError): return 'file_missing'
    if isinstance(error, PermissionError): return 'permission_denied'
    if isinstance(error, MemoryError): return 'out_of_memory'
    return 'startup_failed'


def report_failure(stage, reason, status=None):
    value = {'protocol': PROTOCOL, 'event': 'failed', 'stage': stage, 'reason': reason}
    if status is not None and -255 <= status <= 255: value['exit_status'] = status
    print(json.dumps(value), flush=True)


def local_snapshot(models, state, manifest):
    target = [(item['path'].removeprefix('llm-target/'), models / item['path'])
              for item in manifest['files'] if item['path'].startswith('llm-target/')]
    names = {name for name, _ in target}
    if len(names) != len(target) or not target:
        raise ValueError('invalid_snapshot')
    for name in names:
        parts = Path(name).parts
        if name.startswith('/') or '..' in parts or any('/'.join(parts[:n]) in names for n in range(1, len(parts))):
            raise ValueError('invalid_snapshot')
    snapshot = state / 'hf/hub/models--mlx-community--Qwen3.8-27B-4bit/snapshots' / REVISION
    snapshot.mkdir(parents=True, exist_ok=False)
    for name, source in target:
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(models):
            raise ValueError('invalid_source')
        destination = snapshot / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(source)
    draft = models / 'llm-draft'
    if any(not (draft / name).is_file() or (draft / name).is_symlink() for name in ('config.json', 'model.safetensors')):
        raise ValueError('missing_draft')
    return draft


def stop_group(child):
    # The child is started in a fresh session. Never signal a discovered PID/name.
    try: child_exited(child)
    except ChildProcessError: return
    try: os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        child.wait(); return
    except PermissionError as error:
        # Darwin reports EPERM for a group whose only member is an unreaped zombie.
        # Continue to the final group signal only with the owned leader confirmed dead.
        if sys.platform != 'darwin' or error.errno != errno.EPERM or not child_exited(child): raise
    # Keep the child unreaped until after group cleanup, preventing PID reuse.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            if child_exited(child): break
        except ChildProcessError: return
        time.sleep(0.05)
    try: os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    except PermissionError as error:
        if sys.platform != 'darwin' or error.errno != errno.EPERM or not child_exited(child): raise
        child.wait()
        # After releasing the PID anchor, never send another nonzero signal.
        # A reused or surviving group produces a conservative failure, not a kill.
        try: os.killpg(child.pid, 0)
        except ProcessLookupError: return
        raise
    child.wait()


def close_unrelated_descriptors(kept):
    """Retain stdio/control and the two listeners, even if a caller leaked an FD."""
    maximum = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
    if maximum == resource.RLIM_INFINITY: maximum = os.sysconf('SC_OPEN_MAX')
    first = 3
    for descriptor in sorted(kept):
        os.closerange(first, descriptor)
        first = descriptor + 1
    os.closerange(first, maximum)


def bootstrap(args, payload, models, state, manifest):
    """Only stdlib/path validation and prebinding occur outside the sandbox.

    exec keeps this PID, its control pipe and both exact listening descriptors.
    No model, launcher or manifest contents are loaded before the sandbox.
    """
    scripts = Path(__file__).resolve(strict=True).parent
    profile = Path(args.sandbox_profile).resolve(strict=True)
    if profile != scripts / 'splash.sb' or not profile.is_file():
        raise ValueError('invalid_sandbox_profile')
    runtime = (payload / 'Splash').resolve(strict=True)
    python_root = (runtime / 'python').resolve(strict=True)
    python = (runtime / 'python/bin/python3').resolve(strict=True)
    if not python.is_relative_to(python_root) or not python.is_file():
        raise ValueError('invalid_bundled_interpreter')
    for readable in (runtime, scripts, models, manifest, python_root):
        if state.is_relative_to(readable) or readable.is_relative_to(state):
            raise ValueError('state_not_disjoint')
    backend = endpoint = None
    try:
        backend = tls.owned_listener(); endpoint = tls.owned_listener()
        backend_port, tls_port = backend.getsockname()[1], endpoint.getsockname()[1]
        parameters = {'DOT_RUNTIME': runtime, 'DOT_RUNTIME_SCRIPTS': scripts, 'DOT_MODELS': models,
                      'DOT_MANIFEST': manifest, 'DOT_STATE': state, 'DOT_PYTHON_ROOT': python_root,
                      # Seatbelt only accepts the localhost token for concrete ports.
                      # Socket adoption independently requires IPv4 127.0.0.1 exactly.
                      'DOT_BACKEND_ADDRESS': f'localhost:{backend_port}', 'DOT_TLS_ADDRESS': f'localhost:{tls_port}'}
        command = ['/usr/bin/sandbox-exec']
        for name, value in parameters.items(): command.extend(['-D', name + '=' + str(value)])
        command.extend(['-f', str(profile), str(python), '-I', '-S', '-B', str(scripts / 'dot_runtime.py'),
                        '--payload', str(payload), '--models', str(models), '--state', str(state), '--manifest', str(manifest),
                        '--backend-fd', str(backend.fileno()), '--backend-port', str(backend_port),
                        '--tls-fd', str(endpoint.fileno()), '--tls-port', str(tls_port)])
        environment = {'PATH': '/usr/bin:/bin', 'HOME': str(state), 'TMPDIR': str(state), 'PYTHONDONTWRITEBYTECODE': '1'}
        backend.set_inheritable(True); endpoint.set_inheritable(True)
        os.chdir(state)
        close_unrelated_descriptors((backend.fileno(), endpoint.fileno()))
        os.execve(command[0], command, environment)
        raise RuntimeError('sandbox_exec_returned')
    finally:
        # Reached only if setup/exec failed. A successful exec continuously owns both.
        if endpoint is not None: endpoint.close()
        if backend is not None: backend.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--payload', required=True); parser.add_argument('--models', required=True)
    parser.add_argument('--state', required=True); parser.add_argument('--manifest', required=True)
    parser.add_argument('--sandbox-profile')
    parser.add_argument('--backend-fd', type=int); parser.add_argument('--backend-port', type=int)
    parser.add_argument('--tls-fd', type=int); parser.add_argument('--tls-port', type=int)
    args = parser.parse_args()
    payload = Path(args.payload).resolve(strict=True); models = Path(args.models).resolve(strict=True)
    state = Path(args.state).resolve(strict=True)
    manifest_path = Path(args.manifest).resolve(strict=True)
    if state.is_relative_to(payload) or state.is_relative_to(models) or payload.is_relative_to(state) or models.is_relative_to(state):
        raise ValueError('state_not_disjoint')
    if not state.is_dir() or state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o077:
        raise ValueError('private_state_required')
    # Only adopt the fresh private directory made for this invocation, never user data.
    if Path(args.state).is_symlink() or any(state.iterdir()): raise ValueError('fresh_state_required')
    identity = state.stat()
    if args.sandbox_profile:
        if any(value is not None for value in (args.backend_fd, args.backend_port, args.tls_fd, args.tls_port)):
            raise ValueError('mixed_bootstrap_arguments')
        return bootstrap(args, payload, models, state, manifest_path)
    if (args.backend_fd is None or args.tls_fd is None or args.backend_port is None or args.tls_port is None
        or args.backend_fd == args.tls_fd or args.backend_port == args.tls_port):
        raise ValueError('owned_listeners_required')
    stopped = False
    def request_stop(*_):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGTERM, request_stop); signal.signal(signal.SIGINT, request_stop)
    child = None; listener = None; endpoint = None; relay = None
    stage = 'snapshot'; tail = FailureTail(); unexpected_exit = False
    try:
        # Invalid descriptors fail before snapshot/model reads or subprocesses.
        listener = tls.adopt_listener(args.backend_fd, args.backend_port)
        endpoint = tls.adopt_listener(args.tls_fd, args.tls_port)
        manifest = json.loads(manifest_path.read_text())
        draft = local_snapshot(models, state, manifest)
        runtime = payload / 'Splash'
        # Never release/rebind this backend socket. Only the patched Splash child accepts.
        port = listener.getsockname()[1]
        stage = 'tls'
        api_key = secrets.token_hex(32)
        relay = tls.TLSRelay(listener, state, api_key=api_key, listener=endpoint)
        home = state / 'home'; home.mkdir()
        environment = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TMPDIR': str(state),
                       'HF_HOME': str(state / 'hf'), 'HF_HUB_CACHE': str(state / 'hf/hub'),
                       'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'PYTHONNOUSERSITE': '1',
                       'HF_HUB_DISABLE_TELEMETRY': '1', 'HF_HUB_DISABLE_IMPLICIT_TOKEN': '1',
                       'PYTHONDONTWRITEBYTECODE': '1'}
        command = [str(runtime / 'python/bin/python3'), '-B', str(runtime / 'install/launcher.py'),
                   'serve', '--model', MODEL, '--revision', REVISION, '--draft-model', str(draft),
                   '--offline', '--no-webui', '--host', '127.0.0.1', '--port', str(port), '--listen-fd', str(listener.fileno()), '--max-cache-disk', '0']
        if stopped: return 0
        stage = 'launcher'
        with _process.api_key_pipe(api_key) as key_fd:
            command.extend(['--api-key-fd', str(key_fd)])
            child = subprocess.Popen(command, cwd=runtime, env=environment, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True,
                                     pass_fds=(listener.fileno(), key_fd))
        os.set_blocking(child.stderr.fileno(), False)
        stderr_open = True
        print(json.dumps({'protocol': PROTOCOL, 'event': 'started', 'pid': child.pid, 'port': relay.port, 'backend_port': port, 'api_key': api_key, 'tls_certificate_sha256': relay.certificate_sha256}), flush=True)
        while not stopped:
            if child_exited(child):
                tail.drain(child.stderr); unexpected_exit = True; break
            watched = [sys.stdin] + ([child.stderr] if stderr_open else [])
            readable, _, _ = select.select(watched, [], [], 0.2)
            if child.stderr in readable: stderr_open = tail.drain(child.stderr)
            if sys.stdin in readable:
                # Any explicit control byte or parent EOF requests shutdown.
                if sys.stdin.buffer.read(1) is not None: break
    except Exception as error:
        raise RuntimeDiagnosticError(stage, exception_reason(error)) from None
    finally:
        try:
            try:
                if relay is not None: relay.close()
            finally:
                if child is not None:
                    try: stop_group(child)
                    finally:
                        if child.stderr is not None:
                            try:
                                # No owned writer survives successful group cleanup. Preserve
                                # at most 256 KB of queued bytes, retaining only the last 8 KB.
                                if unexpected_exit: tail.drain(child.stderr, maximum_reads=64)
                            finally: child.stderr.close()
                # A failed relay shutdown retains its socket through live worker references.
                if listener is not None and (relay is None or relay.closed): listener.close()
                if endpoint is not None and relay is None: endpoint.close()
        finally:
            # The supervisor outlives a quitting app and cleans its own private state.
            # Never follow a replaced path or remove another invocation's directory.
            try:
                current = state.lstat()
                if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                    shutil.rmtree(state)
            except FileNotFoundError: pass
    if unexpected_exit:
        report_failure('launcher', tail.reason(), child.returncode)
        return 2
    return 0


if __name__ == '__main__':
    try: raise SystemExit(main())
    except RuntimeDiagnosticError as error:
        report_failure(error.stage, error.reason)
        raise SystemExit(2)
    except Exception as error:
        report_failure('supervisor', exception_reason(error))
        raise SystemExit(2)
