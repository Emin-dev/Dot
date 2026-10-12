#!/usr/bin/env python3
"""Construct an isolated local HF snapshot plan from audited bundled files only.
No executable is launched, no download is attempted, and no user cache is searched.
Actual Splash assembly/load still requires the supported Mac validation gate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import unicodedata
from audit_offline_bundle import audit, relative


def prepare(payload, manifest, state):
    payload = Path(payload).resolve(strict=True)
    audit(payload, manifest)
    target = next(item for item in manifest['components'] if item['role'] == 'llm_target')
    draft = next(item for item in manifest['components'] if item['role'] == 'llm_draft')
    repo, revision = target.get('repository'), target.get('revision')
    if not isinstance(repo, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('invalid pinned model repository')
    if not isinstance(revision, str) or not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('immutable model revision required')
    entries = {entry['path']: entry for entry in manifest['files']}
    if any(entries[name].get('kind') != 'file' for name in target['files']):
        raise ValueError('snapshot sources must be audited regular files')
    mappings = [(relative(entries[name]['source_path']), payload / name) for name in target['files']]
    destinations = [unicodedata.normalize('NFC', name).casefold() for name, _ in mappings]
    destination_set = set(destinations)
    if len(destination_set) != len(destinations):
        raise ValueError('duplicate snapshot destination')
    for name in destinations:
        parts = name.split('/')
        if any('/'.join(parts[:count]) in destination_set for count in range(1, len(parts))):
            raise ValueError('ancestor-colliding snapshot destination')
    if not isinstance(draft.get('revision'), str) or not re.fullmatch('[0-9a-f]{40}', draft['revision']):
        raise ValueError('immutable draft revision required')
    if any(entries[name].get('kind') != 'file' for name in draft['files']):
        raise ValueError('draft sources must be audited regular files')
    draft_paths = [payload / name for name in draft['files'] if Path(name).name in ('config.json', 'model.safetensors')]
    if {path.name for path in draft_paths} != {'config.json', 'model.safetensors'} or len(draft_paths) != 2 or len({path.parent for path in draft_paths}) != 1:
        raise ValueError('pinned local draft layout incomplete')
    state = Path(state).resolve(strict=False)
    if state.is_relative_to(payload) or payload.is_relative_to(state):
        raise ValueError('state and immutable payload must be disjoint')
    # Refuse rather than replace an existing state tree or unrelated cache.
    state.mkdir(mode=0o700, parents=False, exist_ok=False)
    hf = state / 'hf'
    snapshot = hf / 'hub' / ('models--' + repo.replace('/', '--')) / 'snapshots' / revision
    snapshot.mkdir(parents=True)
    for upstream, source in mappings:
        link = snapshot / upstream; link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(source)
    manifest_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    plan = {
        'manifest_sha256': manifest_hash,
        'environment': {'HOME': str(state / 'home'), 'HF_HOME': str(hf), 'HF_HUB_CACHE': str(hf / 'hub'), 'HF_HUB_OFFLINE': '1',
                        'TRANSFORMERS_OFFLINE': '1', 'PYTHONNOUSERSITE': '1', 'HF_HUB_DISABLE_IMPLICIT_TOKEN': '1', 'HF_HUB_DISABLE_TELEMETRY': '1', 'PYTHONDONTWRITEBYTECODE': '1'},
        'launcher_arguments': ['serve', '--model', repo, '--revision', revision, '--draft-model', str(draft_paths[0].parent), '--offline', '--host', '127.0.0.1'],
        'status': 'prepared_plan_only_not_executed_or_runtime_validated'
    }
    (state / 'launch-plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload'); parser.add_argument('manifest'); parser.add_argument('new_state_directory')
    args = parser.parse_args()
    manifest = json.loads(Path(args.manifest).read_text())
    plan = prepare(args.payload, manifest, args.new_state_directory)
    print(json.dumps({'status': plan['status'], 'manifest_sha256': plan['manifest_sha256']}))


if __name__ == '__main__': main()
