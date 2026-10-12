#!/usr/bin/env python3
"""Own one pinned offline Splash process tree. No discovery or user-cache access."""
import argparse
import json
import os
from pathlib import Path
import select
import secrets
import signal
import socket
import subprocess
import sys
import time

PROTOCOL = 1
MODEL = 'mlx-community/Qwen3.8-27B-4bit'
REVISION = '10c35caafbb80f7dc6a7a432cdd11af10a6d4818'


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
    try: os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        child.wait(); return
    # Keep the child unreaped until after group cleanup, preventing PID reuse.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            status = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if status is not None: break
        except ChildProcessError: break
        time.sleep(0.05)
    try: os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError: pass
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
    manifest = json.loads(Path(args.manifest).read_text())
    draft = local_snapshot(models, state, manifest)
    runtime = payload / 'Splash'
    # A single ephemeral owned bind attempt. No port scan or listener adoption.
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    home = state / 'home'; home.mkdir()
    api_key = secrets.token_hex(32)
    environment = {'SPLASH_API_KEY': api_key, 'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TMPDIR': str(state),
                   'HF_HOME': str(state / 'hf'), 'HF_HUB_CACHE': str(state / 'hf/hub'),
                   'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'PYTHONNOUSERSITE': '1',
                   'HF_HUB_DISABLE_TELEMETRY': '1', 'HF_HUB_DISABLE_IMPLICIT_TOKEN': '1',
                   'PYTHONDONTWRITEBYTECODE': '1'}
    command = [str(runtime / 'python/bin/python3'), '-B', str(runtime / 'install/launcher.py'),
               'serve', '--model', MODEL, '--revision', REVISION, '--draft-model', str(draft),
               '--offline', '--host', '127.0.0.1', '--port', str(port), '--max-cache-disk', '0']
    stopped = False
    def request_stop(*_):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGTERM, request_stop); signal.signal(signal.SIGINT, request_stop)
    if stopped: return 0
    child = None
    try:
        child = subprocess.Popen(command, cwd=runtime, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        print(json.dumps({'protocol': PROTOCOL, 'event': 'started', 'pid': child.pid, 'port': port, 'api_key': api_key}), flush=True)
        while not stopped:
            status = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if status is not None: break
            readable, _, _ = select.select([sys.stdin], [], [], 0.2)
            if readable:
                # Any explicit control byte or parent EOF requests shutdown.
                if sys.stdin.buffer.read(1) is not None: break
    finally:
        if child is not None: stop_group(child)
    return 0


if __name__ == '__main__':
    try: raise SystemExit(main())
    except Exception:
        print(json.dumps({'protocol': PROTOCOL, 'event': 'failed'}), flush=True)
        raise SystemExit(2)
