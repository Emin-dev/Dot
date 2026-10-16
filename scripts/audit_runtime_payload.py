#!/usr/bin/env python3
"""Audit a completed local runtime payload; never downloads or executes files."""
import argparse
import json
from pathlib import Path
import stat
import unicodedata
from audit_offline_bundle import digest, relative

REQUIRED = {
    'splash_runtime': ['Splash/python/bin/python3', 'Splash/install/launcher.py', 'Splash/engine/splash', 'Splash/engine/splash.metallib'],
    # The Rust dot-voice engine reads these model files directly; the deleted Python
    # helper's interpreter is no longer part of a complete payload.
    'speech_synthesis': ['Voice/model/config.json', 'Voice/model/kokoro-v1_0.pth', 'Voice/model/voices/bf_isabella.pt'],
    'speech_recognition': ['STT/ggml-base.en.bin'],
}
PINS = {
    'Voice/model/config.json': (2351, '5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f'),
    'Voice/model/kokoro-v1_0.pth': (327212226, '496dba118d1a58f5f3db2efc88dbdc216e0483fc89fe6e47ee1f2c53f18ad1e4'),
    'Voice/model/voices/bf_isabella.pt': (523440, 'cdd4c37003805104d1d08fb1e05855c8fb2c68de24ca6e71f264a30aaa59eefd'),
    'STT/ggml-base.en.bin': (147964211, 'a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002'),
}


def audit_runtime(root, enforce_pins=True):
    root = Path(root).resolve(strict=True)
    manifest_path = root / 'runtime-manifest.json'
    manifest_info = manifest_path.lstat()
    if not stat.S_ISREG(manifest_info.st_mode) or not 0 < manifest_info.st_size <= 16_000_000:
        raise ValueError('bounded regular manifest required')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schema_version') != 1 or manifest.get('kind') != 'verified_runtime_payload':
        raise ValueError('complete runtime manifest required')
    files = manifest.get('files', [])
    if not 1 <= len(files) <= 100000: raise ValueError('invalid file count')
    entries = {}
    canonical = set()
    total = 0
    for entry in files:
        name = relative(entry['path'])
        folded = unicodedata.normalize('NFC', name).casefold()
        if folded in canonical: raise ValueError('duplicate/aliased file')
        canonical.add(folded)
        entries[name] = entry
        path = root / name
        if not path.resolve(strict=True).is_relative_to(root): raise ValueError('external runtime path')
        info = path.lstat()
        if entry['kind'] == 'file':
            if not stat.S_ISREG(info.st_mode) or type(entry.get('bytes')) is not int or info.st_size != entry['bytes']:
                raise ValueError('file size/type mismatch')
            total += info.st_size
            if total > 5_000_000_000 or digest(path) != entry.get('sha256'): raise ValueError('hash/size bound failed')
        elif entry['kind'] == 'symlink':
            target = entry.get('target', '')
            if not stat.S_ISLNK(info.st_mode) or Path(target).is_absolute() or str(path.readlink()) != target:
                raise ValueError('invalid symlink')
        else: raise ValueError('unsupported file type')
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_symlink() or not p.is_dir()}
    if actual != set(entries) | {'runtime-manifest.json'}: raise ValueError('runtime closure incomplete')
    components = manifest.get('components', [])
    if len(components) != 3 or {x.get('role') for x in components} != set(REQUIRED): raise ValueError('required component missing')
    for component in components:
        names = component.get('files', []); licenses = component.get('license_paths', [])
        if not names or not licenses or not component.get('license') or any(x not in entries for x in names + licenses):
            raise ValueError('license/file coverage incomplete')
        for name in REQUIRED[component['role']]:
            if name not in names: raise ValueError('required input not in its component')
            resolved = (root / name).resolve(strict=True)
            if not any(entries[x]['kind'] == 'file' and (root / x).resolve(strict=True) == resolved for x in names):
                raise ValueError('required input not covered by hash')
    if enforce_pins:
        patch = json.loads((Path(__file__).resolve().parents[1] / 'Resources/Runtime/splash-managed-listener-patch.json').read_text())
        if manifest.get('transport_patch') != patch['id']: raise ValueError('authenticated listener patch missing')
        for entry in patch['files']:
            if entries.get(entry['path'], {}).get('sha256') != entry['sha256']:
                raise ValueError('wrong managed listener source')
        for name, (size, sha) in PINS.items():
            if entries.get(name, {}).get('bytes') != size or entries[name].get('sha256') != sha:
                raise ValueError('wrong pinned neural asset')
        imports = manifest.get('import_probe', {})
        if imports.get('status') != 'passed_offline' or imports.get('kokoro') != '0.9.4' or imports.get('misaki') != '0.9.4':
            raise ValueError('offline voice import probe has not passed')
        if manifest.get('dependency_lock_complete') is not True: raise ValueError('voice dependency lock incomplete')
    return {'files': len(entries), 'bytes': total}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('payload'); args = parser.parse_args()
    print(json.dumps(audit_runtime(args.payload)))
