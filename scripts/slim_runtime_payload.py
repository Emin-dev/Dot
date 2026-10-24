#!/usr/bin/env python3
"""Drop the retired Python voice runtime from a copied `Offline` payload (audit N1).

`dot-voice` (Rust) reads only `Voice/model`; nothing starts `Voice/python`, and
`Voice/provenance` only describes that interpreter. Both are removed and the
manifest is rewritten to match: their entries, their component files and license
paths, and the top-level keys that describe the Python voice. The Kokoro license
text is kept from the audited payload as `Voice/model/LICENSE`. Every other entry
is unchanged, so `audit_runtime_payload.py` and the app's launch audit still hash
every shipped file. Run it on a copy only; running it again on a slimmed payload is a
no-op, and a run that stopped midway is refused rather than guessed at.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil

REMOVED_ROOTS = ('Voice/python', 'Voice/provenance')
PYTHON_VOICE_KEYS = ('dependency_lock_complete', 'dependency_lock_path', 'dependency_lock_sha256',
                     'import_probe', 'voice_acceptance')
KOKORO_LICENSE = re.compile(r'^Voice/python/lib/python3\.\d+/site-packages/kokoro-[^/]+\.dist-info/(licenses/)?LICENSE[^/]*$')
MODEL_LICENSE = 'Voice/model/LICENSE'


def removed(name):
    return any(name == root or name.startswith(root + '/') for root in REMOVED_ROOTS)


def resolves_into_removed(entry):
    if entry.get('kind') != 'symlink':
        return False
    parts = list(PurePosixPath(entry['path']).parent.parts)
    for part in PurePosixPath(entry.get('target', '')).parts:
        if part == '..':
            if parts: parts.pop()
        elif part != '.':
            parts.append(part)
    return removed('/'.join(parts))


def on_disk(root, name):
    """Every file and link under one removed root, as manifest paths (directories excluded)."""
    found = set()
    top = root / name
    if top.is_symlink() or top.is_file():
        return {name}
    for folder, folders, names in os.walk(top, followlinks=False):
        here = Path(folder)
        for item in names + [f for f in folders if (here / f).is_symlink()]:
            found.add((here / item).relative_to(root).as_posix())
    return found


def slim(root):
    root = Path(root).resolve(strict=True)
    manifest_path = root / 'runtime-manifest.json'
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    if manifest.get('schema_version') != 1 or manifest.get('kind') != 'verified_runtime_payload':
        raise ValueError('complete runtime manifest required')
    files = manifest['files']
    gone = [entry for entry in files if removed(entry['path'])]
    if not gone:
        if any((root / name).exists() or (root / name).is_symlink() for name in REMOVED_ROOTS):
            raise ValueError('removed runtime is on disk but not in the manifest')
        return {'removed_files': 0, 'removed_bytes': 0}
    for name in REMOVED_ROOTS + ('Voice/model',):
        # A linked folder would let deletion or the license write leave the payload.
        if os.path.realpath(root / name) != str(root / name):
            raise ValueError(name + ' must be a real folder inside the payload')
    kept = [entry for entry in files if not removed(entry['path'])]
    removed_paths = [root / name for name in REMOVED_ROOTS]
    def physically_inside(entry):
        target = Path(os.path.realpath(root / entry['path']))
        return any(target == path or path in target.parents for path in removed_paths)
    if any(resolves_into_removed(entry) or physically_inside(entry) for entry in kept):
        raise ValueError('a kept link points into the removed runtime')
    if set().union(*(on_disk(root, name) for name in REMOVED_ROOTS)) != {entry['path'] for entry in gone}:
        raise ValueError('the removed runtime on disk does not match the manifest')
    voice = next((c for c in manifest['components'] if c.get('role') == 'speech_synthesis'), None)
    if voice is None:
        raise ValueError('speech_synthesis component missing')
    licenses = [name for name in voice.get('license_paths', []) if KOKORO_LICENSE.match(name)]
    if len(licenses) != 1:
        nearby = [e['path'] for e in gone if 'kokoro' in e['path'].lower() and 'license' in e['path'].lower()][:8]
        raise ValueError(f'the Kokoro license must appear exactly once in the voice licenses; found {nearby}')
    source = next(entry for entry in gone if entry['path'] == licenses[0])
    text = (root / source['path']).read_bytes()
    if source.get('kind') != 'file' or len(text) != source.get('bytes') or hashlib.sha256(text).hexdigest() != source.get('sha256'):
        raise ValueError('the Kokoro license does not match the manifest')
    if any(entry['path'] == MODEL_LICENSE for entry in kept) or os.path.lexists(root / MODEL_LICENSE):
        raise ValueError(MODEL_LICENSE + ' already exists')

    license_entry = {'path': MODEL_LICENSE, 'kind': 'file', 'bytes': len(text), 'sha256': hashlib.sha256(text).hexdigest()}
    for component in manifest['components']:
        component['files'] = [name for name in component['files'] if not removed(name)]
        component['license_paths'] = [name for name in component.get('license_paths', []) if not removed(name)]
    voice['files'].append(MODEL_LICENSE)
    voice['license_paths'].append(MODEL_LICENSE)
    voice['license'] = 'Apache-2.0 (Kokoro-82M model and voices)'
    for key in PYTHON_VOICE_KEYS:
        manifest.pop(key, None)
    manifest['files'] = kept + [license_entry]
    manifest['slimmed'] = {'removed_roots': list(REMOVED_ROOTS), 'removed_files': len(gone),
                           'removed_bytes': sum(entry.get('bytes') or 0 for entry in gone),
                           'source_manifest_sha256': hashlib.sha256(raw).hexdigest()}

    (root / MODEL_LICENSE).write_bytes(text)
    os.chmod(root / MODEL_LICENSE, 0o644)
    staged = manifest_path.with_name('runtime-manifest.json.slim')
    staged.write_text(json.dumps(manifest) + '\n')
    os.replace(staged, manifest_path)
    for name in REMOVED_ROOTS:
        path = root / name
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)
    return {'removed_files': len(gone), 'removed_bytes': manifest['slimmed']['removed_bytes']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload')
    print(json.dumps(slim(parser.parse_args().payload)))
