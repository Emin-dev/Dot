#!/usr/bin/env python3
"""Print the shape of a runtime-manifest.json: top-level keys, components with their file
counts, bytes and license paths, and bytes per top-level folder. Read-only; used in CI to
plan payload changes (audit N1) without shipping the 793 MB donor in the repository.
Output stays bounded whatever the manifest holds."""
import collections
import json
import sys

FOLDERS_SHOWN = 40
SAMPLES_SHOWN = 8
COMPONENTS_SHOWN = 10


def size_of(entry) -> int:
    value = entry.get('bytes') if isinstance(entry, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def path_of(entry) -> str:
    value = entry.get('path') if isinstance(entry, dict) else None
    return value if isinstance(value, str) else ''


def show_list(label: str, values) -> None:
    if not isinstance(values, list):
        print(f'  {label}:', json.dumps(values)[:300])
        return
    sample = [str(value)[:200] for value in values[:SAMPLES_SHOWN]]
    more = f' ... {len(values) - SAMPLES_SHOWN} more' if len(values) > SAMPLES_SHOWN else ''
    print(f'  {label}: {len(values)}', sample, more)


def main(path: str) -> None:
    with open(path, encoding='utf-8') as handle:
        manifest = json.load(handle)
    if not isinstance(manifest, dict):
        print('manifest is not a JSON object:', type(manifest).__name__)
        return
    files = manifest.get('files', [])
    files = files if isinstance(files, list) else []
    by_path = {path_of(entry): entry for entry in files}
    print('top-level keys:', len(manifest), [key[:80] for key in sorted(manifest)[:40]])
    for key, value in sorted(manifest.items())[:40]:
        if key not in ('files', 'components'):
            print(f'  {key[:80]}: {json.dumps(value)[:300]}')
    print('files:', len(files), 'bytes:', sum(size_of(entry) for entry in files))
    folders = collections.Counter()
    counts = collections.Counter()
    for entry in files:
        parts = path_of(entry).split('/')
        folder = '/'.join(parts[:2]) if len(parts) > 2 else parts[0]
        folders[folder] += size_of(entry)
        counts[folder] += 1
    for folder, size in folders.most_common(FOLDERS_SHOWN):
        print(f'  {folder[:200]}: {counts[folder]} files, {size} bytes')
    if len(folders) > FOLDERS_SHOWN:
        print(f'  ... {len(folders) - FOLDERS_SHOWN} more folders')
    components = manifest.get('components', [])
    components = components if isinstance(components, list) else []
    if len(components) > COMPONENTS_SHOWN:
        print(f'components: {len(components)}, showing {COMPONENTS_SHOWN}')
    for component in components[:COMPONENTS_SHOWN]:
        if not isinstance(component, dict):
            continue
        names = component.get('files', [])
        names = [name for name in names if isinstance(name, str)] if isinstance(names, list) else []
        size = sum(size_of(by_path.get(name) or {}) for name in names)
        print('component', str(component.get('role'))[:100], 'keys:', [key[:80] for key in sorted(component)[:40]],
              'files:', len(names), 'bytes:', size)
        show_list('license_paths', component.get('license_paths'))
        roots = collections.Counter('/'.join(name.split('/')[:2]) for name in names)
        print('  roots:', {root[:200]: count for root, count in roots.most_common(12)})


if __name__ == '__main__':
    main(sys.argv[1])
