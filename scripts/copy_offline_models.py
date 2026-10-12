#!/usr/bin/env python3
"""Copy only pinned model data into a fresh portable app directory. No execution/network."""
import argparse
import json
from pathlib import Path
import shutil
import stat
from audit_offline_bundle import digest, relative


def copy_models(source, destination, manifest_path):
    source = Path(source).resolve(strict=True)
    destination = Path(destination).absolute()
    plan = json.loads(Path(manifest_path).read_text())
    files = plan.get('files', [])
    if plan.get('schema_version') != 1 or not 1 <= len(files) <= 100:
        raise ValueError('invalid model plan')
    names = [relative(x['path']) for x in files]
    if len(set(x.casefold() for x in names)) != len(names): raise ValueError('duplicate model path')
    total = 0
    for entry, name in zip(files, names):
        path = source / name
        if not path.resolve(strict=True).is_relative_to(source) or not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('nonregular/external model source')
        size = entry['bytes']
        if type(size) is not int or not 0 < size <= 25_000_000_000 or path.stat().st_size != size or digest(path) != entry['sha256']:
            raise ValueError('model hash/size mismatch')
        total += size
    if total != plan.get('total_bytes') or total > 25_000_000_000: raise ValueError('model total mismatch')
    canonical_destination = destination.resolve()
    if canonical_destination.is_relative_to(source) or source.is_relative_to(canonical_destination):
        raise ValueError('source and destination must be disjoint')
    if destination.exists() or destination.is_symlink(): raise ValueError('fresh destination required')
    parent = destination.parent.resolve(strict=True)
    if shutil.disk_usage(parent).free < total + 5_000_000_000: raise ValueError('insufficient free space')
    destination.mkdir()
    try:
        for entry, name in zip(files, names):
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, target, follow_symlinks=False)
            info = target.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size != entry['bytes'] or digest(target) != entry['sha256']:
                raise ValueError('copied model failed verification')
    except BaseException:
        # Remove only the new directory this invocation created, never the source.
        shutil.rmtree(destination)
        raise
    return {'files': len(files), 'bytes': total, 'verified_after_copy': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True); parser.add_argument('--destination', required=True)
    parser.add_argument('--manifest', required=True); args = parser.parse_args()
    print(json.dumps(copy_models(args.source, args.destination, args.manifest)))
