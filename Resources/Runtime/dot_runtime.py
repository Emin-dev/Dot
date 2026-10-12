#!/usr/bin/env python3
"""Own one pinned offline Splash process tree. No discovery or user-cache access."""
import argparse
import errno
import importlib.util
import json
import os
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--payload', required=True); parser.add_argument('--models', required=True)
    parser.add_argument('--state', required=True); parser.add_argument('--manifest', required=True)
    args = parser.parse_args()
    payload = Path(args.payload).resolve(strict=True); models = Path(args.models).resolve(strict=True)
    state = Path(args.state).resolve(strict=True)
    if state.is_relative_to(payload) or state.is_relative_to(models) or payload.is_relative_to(state) or models.is_relative_to(state):
        raise ValueError('state_not_disjoint')
    if state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o077:
        raise ValueError('private_state_required')
    # Only adopt the fresh private directory made for this invocation, never user data.
    if Path(args.state).is_symlink() or any(state.iterdir()): raise ValueError('fresh_state_required')
    identity = state.stat()
    stopped = False
    def request_stop(*_):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGTERM, request_stop); signal.signal(signal.SIGINT, request_stop)
    child = None; listener = None; relay = None
    try:
        manifest = json.loads(Path(args.manifest).read_text())
        draft = local_snapshot(models, state, manifest)
        runtime = payload / 'Splash'
        # Never release/rebind this backend socket. Only the patched Splash child accepts.
        listener = tls.owned_listener(); port = listener.getsockname()[1]
        relay = tls.TLSRelay(listener, state)
        home = state / 'home'; home.mkdir()
        api_key = secrets.token_hex(32)
        environment = {'SPLASH_API_KEY': api_key, 'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TMPDIR': str(state),
                       'HF_HOME': str(state / 'hf'), 'HF_HUB_CACHE': str(state / 'hf/hub'),
                       'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'PYTHONNOUSERSITE': '1',
                       'HF_HUB_DISABLE_TELEMETRY': '1', 'HF_HUB_DISABLE_IMPLICIT_TOKEN': '1',
                       'PYTHONDONTWRITEBYTECODE': '1'}
        command = [str(runtime / 'python/bin/python3'), '-B', str(runtime / 'install/launcher.py'),
                   'serve', '--model', MODEL, '--revision', REVISION, '--draft-model', str(draft),
                   '--offline', '--no-webui', '--host', '127.0.0.1', '--port', str(port), '--listen-fd', str(listener.fileno()), '--max-cache-disk', '0']
        if stopped: return 0
        child = subprocess.Popen(command, cwd=runtime, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(listener.fileno(),))
        print(json.dumps({'protocol': PROTOCOL, 'event': 'started', 'pid': child.pid, 'port': relay.port, 'backend_port': port, 'api_key': api_key, 'tls_certificate_sha256': relay.certificate_sha256}), flush=True)
        while not stopped:
            if child_exited(child): break
            readable, _, _ = select.select([sys.stdin], [], [], 0.2)
            if readable:
                # Any explicit control byte or parent EOF requests shutdown.
                if sys.stdin.buffer.read(1) is not None: break
    finally:
        try:
            try:
                if relay is not None: relay.close()
            finally:
                if child is not None: stop_group(child)
                # A failed relay shutdown retains its socket through live worker references.
                if listener is not None and (relay is None or relay.closed): listener.close()
        finally:
            # The supervisor outlives a quitting app and cleans its own private state.
            # Never follow a replaced path or remove another invocation's directory.
            try:
                current = state.lstat()
                if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                    shutil.rmtree(state)
            except FileNotFoundError: pass
    return 0


if __name__ == '__main__':
    try: raise SystemExit(main())
    except Exception:
        print(json.dumps({'protocol': PROTOCOL, 'event': 'failed'}), flush=True)
        raise SystemExit(2)
