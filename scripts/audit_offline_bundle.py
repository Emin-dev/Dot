#!/usr/bin/env python3
"""Fail-closed audit of a staged offline payload. Does not download or execute it.
The manifest must itself be authenticated by the eventual app signature/build process.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import unicodedata

ROLES = {'splash_runtime', 'llm_target', 'llm_draft', 'vision', 'speech_recognition', 'speech_synthesis'}
MAX_FILES = 100_000
MAX_BYTES = 40_000_000_000


def relative(value):
    if not isinstance(value, str) or not value or '\\' in value:
        raise ValueError('invalid relative path')
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or str(path) != value or value == '.':
        raise ValueError('unsafe relative path')
    return value


def digest(path):
    if hasattr(hashlib, 'file_digest'):
        with path.open('rb') as source:
            return hashlib.file_digest(source, 'sha256').hexdigest()
    h = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(65536):
            h.update(chunk)
    return h.hexdigest()


def audit(root, manifest):
    root = Path(root).resolve(strict=True)
    if manifest.get('schema_version') != 1 or manifest.get('kind') != 'verified_offline_payload':
        raise ValueError('planning inventories are not complete offline manifests')
    entries = manifest.get('files')
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_FILES:
        raise ValueError('invalid file count')
    paths, folded, total = {}, set(), 0
    for entry in entries:
        name = relative(entry['path'])
        canonical = unicodedata.normalize('NFC', name).casefold()
        if canonical in folded:
            raise ValueError('duplicate or case-colliding payload path')
        folded.add(canonical); paths[name] = entry
        path = root / name
        info = path.lstat()
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(root):
            raise ValueError('payload escapes its bundle')
        if entry.get('kind') == 'symlink':
            target = entry.get('target')
            if not isinstance(target, str) or Path(target).is_absolute() or '\\' in target:
                raise ValueError('absolute or invalid symlink')
            if not stat.S_ISLNK(info.st_mode) or str(path.readlink()) != target:
                raise ValueError('symlink does not match manifest')
        elif entry.get('kind') == 'file':
            size, checksum = entry.get('bytes'), entry.get('sha256')
            if type(size) is not int or size < 0 or not isinstance(checksum, str) or not re.fullmatch('[0-9a-f]{64}', checksum):
                raise ValueError('missing exact size/hash')
            if not stat.S_ISREG(info.st_mode) or info.st_size != size:
                raise ValueError('file type/size mismatch')
            total += size
            if total > MAX_BYTES: raise ValueError('payload exceeds audited size limit')
            if digest(path) != checksum: raise ValueError('payload checksum mismatch')
        else:
            raise ValueError('unsupported payload entry')
    actual = set()
    # rglob does not follow directory symlinks; both their link and target are audited.
    for path in root.rglob('*'):
        if path.is_symlink() or not path.is_dir(): actual.add(path.relative_to(root).as_posix())
        if len(actual) > MAX_FILES: raise ValueError('payload file limit exceeded')
    if actual != set(paths): raise ValueError('unmanifested or missing payload files')
    components = manifest.get('components', [])
    if not isinstance(components, list) or len(components) != len(ROLES) or {item.get('role') for item in components} != ROLES:
        raise ValueError('required offline component missing')
    for item in components:
        for field in ('files', 'license_paths'):
            values = item.get(field)
            if not isinstance(values, list) or not values or len(values) != len(set(values)) or any(relative(name) not in paths for name in values):
                raise ValueError('component file/license closure missing')
        if not item.get('license'): raise ValueError('component license identifier missing')
    return {'files': len(entries), 'bytes': total, 'roles': sorted(ROLES)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload'); parser.add_argument('manifest')
    args = parser.parse_args()
    manifest = json.loads(Path(args.manifest).read_text())
    print(json.dumps(audit(args.payload, manifest), sort_keys=True))


if __name__ == '__main__': main()
