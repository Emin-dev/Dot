#!/usr/bin/env python3
"""Prepare a fresh, hash-locked local wheelhouse and an inert native install plan.

Never imports acquired packages, executes pip, downloads, or builds source archives.
The complete catalog/audit are reviewed assembly inputs, not inferred from filenames.
"""
import argparse
import email.parser
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import zipfile

MAX_ARCHIVES = 150
MAX_BYTES = 3_000_000_000
MAX_METADATA = 2_000_000
MAX_TREE_NODES = 200_000
NAME = re.compile(r'[a-z0-9]+(?:[-_.][a-z0-9]+)*\Z')
VERSION = re.compile(r'[A-Za-z0-9][A-Za-z0-9.!+_-]*\Z')
SHA = re.compile(r'[0-9a-f]{64}\Z')
PYTHON_ARCHIVE_SHA = '7b6068989d9b6a0e2a883352b7d0d141ce8670a61360bf4ddabac0e046a08e10'


def open_regular(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or not 0 <= info.st_size <= maximum:
            raise ValueError('bounded regular file required')
        return os.fdopen(descriptor, 'rb'), info.st_size
    except BaseException:
        os.close(descriptor)
        raise


def digest(path):
    value = hashlib.sha256()
    stream, size = open_regular(path, MAX_BYTES)
    total = 0
    with stream:
        while True:
            block = stream.read(min(1_048_576, size - total + 1))
            if not block: break
            total += len(block)
            if total > size: raise ValueError('file grew during hashing')
            value.update(block)
    if total != size: raise ValueError('file changed during hashing')
    return value.hexdigest()


def regular(path):
    return stat.S_ISREG(path.lstat().st_mode)


def canonical(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def json_bytes(path):
    stream, size = open_regular(path, 16_000_000)
    with stream: data = stream.read(size + 1)
    if not data or len(data) != size: raise ValueError('bounded stable JSON input required')
    return data


def read_json(path): return json.loads(json_bytes(path))


def sandbox_literal(path):
    text = str(path)
    if any(ord(character) < 32 or ord(character) == 127 for character in text):
        raise ValueError('control character in sandbox path')
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


def metadata(path, entry):
    stream, _ = open_regular(path, 512_000_000)
    with stream, zipfile.ZipFile(stream) as archive:
        members = archive.infolist()
        if not 1 <= len(members) <= 50_000: raise ValueError('wheel member count bound')
        names = [item.filename for item in members]
        candidates = [item for item in members if item.filename.count('/') == 1 and item.filename.endswith('.dist-info/METADATA')]
        if len(candidates) != 1 or not 0 < candidates[0].file_size <= MAX_METADATA:
            raise ValueError('one bounded wheel METADATA required')
        # Whole-archive hashes bind the prior full CRC/RECORD/path audit. This
        # additional check binds the installed dependency declarations to the lock.
        raw = archive.read(candidates[0])
        if hashlib.sha256(raw).hexdigest() != entry['metadata_sha256']:
            raise ValueError('wheel metadata hash mismatch')
        fields = email.parser.BytesParser().parsebytes(raw)
        if canonical(fields['Name'] or '') != entry['name'] or fields['Version'] != entry['version']:
            raise ValueError('wheel identity mismatch')
        if fields.get_all('Requires-Dist', []) != entry['requires_dist']:
            raise ValueError('wheel dependency declarations mismatch')
        return len(names)


def verify_python_tree(root, manifest):
    if (manifest.get('kind') != 'verified_standalone_python_tree' or
            manifest.get('source_archive_sha256') != PYTHON_ARCHIVE_SHA or
            manifest.get('source_archive_bytes') != 27_105_320):
        raise ValueError('verified standalone Python extraction manifest required')
    files = manifest.get('files', [])
    if not 1 <= len(files) <= 100_000: raise ValueError('Python tree file count bound')
    expected, aliases, total = set(), set(), 0
    for entry in files:
        name = entry['path']
        if (not isinstance(name, str) or not name or name.startswith('/') or '\\' in name or
                any(part in ('', '.', '..') for part in name.split('/')) or name.lower() in aliases):
            raise ValueError('invalid or duplicate Python tree path')
        aliases.add(name.lower()); expected.add(name); path = root / name
        if not path.resolve(strict=True).is_relative_to(root): raise ValueError('external Python tree link')
        if entry.get('kind') == 'file':
            size = entry.get('bytes')
            if type(size) is not int or not 0 <= size <= 1_000_000_000: raise ValueError('Python file size bound')
            total += size
            if total > 1_000_000_000 or not regular(path) or path.stat().st_size != size or digest(path) != entry.get('sha256'):
                raise ValueError('Python tree hash/type/size mismatch')
        elif entry.get('kind') == 'symlink':
            if (not path.is_symlink() or Path(entry.get('target', '/')).is_absolute() or
                    str(path.readlink()) != entry.get('target')):
                raise ValueError('Python tree symlink mismatch')
        else: raise ValueError('unsupported Python tree entry')
    actual, pending, nodes = set(), [root], 0
    while pending:
        with os.scandir(pending.pop()) as children:
            for child in children:
                nodes += 1
                if nodes > MAX_TREE_NODES: raise ValueError('Python tree total node bound')
                path = Path(child.path)
                if child.is_symlink() or not child.is_dir(follow_symlinks=False):
                    name = path.relative_to(root).as_posix()
                    if name not in expected: raise ValueError('unmanifested Python tree entry')
                    actual.add(name)
                else: pending.append(path)
    if actual != expected: raise ValueError('Python tree closure mismatch')


def prepare(lock_path, audit_path, inventory_path, python_root, python_manifest, python_sha, output):
    lock_path, audit_path, inventory_path = map(Path, (lock_path, audit_path, inventory_path))
    lock_bytes, audit_bytes, inventory_bytes = map(json_bytes, (lock_path, audit_path, inventory_path))
    lock, audit, inventory = map(json.loads, (lock_bytes, audit_bytes, inventory_bytes))
    lock_sha = hashlib.sha256(lock_bytes).hexdigest()
    target = {'implementation': 'cpython', 'python': '3.11.17', 'platform': 'macos-arm64'}
    if (lock.get('schema_version') != 1 or lock.get('kind') != 'complete_voice_wheel_lock' or
            lock.get('target') != target or lock.get('unresolved') != []):
        raise ValueError('complete target-specific voice lock required')
    if (audit.get('kind') != 'voice_closure_audit' or audit.get('passed') is not True or
            audit.get('catalog_sha256') != lock_sha or audit.get('unresolved') != [] or
            not isinstance(audit.get('checks'), int) or audit['checks'] <= 0):
        raise ValueError('matching completed closure audit required')
    entries = lock.get('wheels', [])
    if not 1 <= len(entries) <= MAX_ARCHIVES: raise ValueError('wheel count bound')
    names, filenames, total = set(), set(), 0
    sources = inventory.get('wheels', {})
    for entry in entries:
        name, version, filename = entry['name'], entry['version'], entry['filename']
        if (not NAME.fullmatch(name) or canonical(name) != name or not VERSION.fullmatch(version) or
                name in names or filename in filenames or Path(filename).name != filename or
                not filename.endswith('.whl') or not re.fullmatch(r'[A-Za-z0-9_.+-]+', filename)):
            raise ValueError('invalid/duplicate wheel identity')
        if (type(entry.get('bytes')) is not int or not 0 < entry['bytes'] <= 512_000_000 or
                not SHA.fullmatch(entry.get('sha256', '')) or not SHA.fullmatch(entry.get('metadata_sha256', ''))):
            raise ValueError('bounded hash-pinned wheel required')
        names.add(name); filenames.add(filename); total += entry['bytes']
        if total > MAX_BYTES: raise ValueError('wheelhouse byte bound')
        source = sources.get(filename, {})
        if source.get('inspection_passed') is not True or source.get('sha256') != entry['sha256']:
            raise ValueError('full archive inspection evidence missing')
        report_path = Path(source['inspection_report'])
        report_bytes = json_bytes(report_path)
        if not SHA.fullmatch(entry.get('inspection_report_sha256', '')) or hashlib.sha256(report_bytes).hexdigest() != entry['inspection_report_sha256']:
            raise ValueError('archive inspection report hash mismatch')
        report = json.loads(report_bytes)
        if (report.get('kind') != 'wheel' or report.get('crc_status') != 'ALL_MEMBERS_VERIFIED' or
                report.get('record_status') != 'ALL_REQUIRED_MEMBER_HASHES_AND_SIZES_VERIFIED' or
                report.get('verified_archive') != {'sha256': entry['sha256'], 'size': entry['bytes']}):
            raise ValueError('archive inspection did not pass')
        path = Path(source['path'])
        if not regular(path) or path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError('local wheel hash/type/size mismatch')
        metadata(path, entry)
    if set(sources) != filenames: raise ValueError('wheel inventory closure mismatch')
    python_root = Path(python_root).resolve(strict=True)
    python_manifest = Path(python_manifest)
    python_manifest_bytes = json_bytes(python_manifest)
    verify_python_tree(python_root, json.loads(python_manifest_bytes))
    python = (python_root / 'bin/python3.11').resolve(strict=True)
    if not python.is_relative_to(python_root) or not regular(python) or not os.access(python, os.X_OK) or not SHA.fullmatch(python_sha) or digest(python) != python_sha:
        raise ValueError('verified internal Python executable required')
    if lock.get('python_archive_sha256') != PYTHON_ARCHIVE_SHA:
        raise ValueError('wrong standalone Python archive')
    output = Path(output).absolute()
    if output.exists() or output.is_symlink(): raise ValueError('fresh output directory required')
    parent = output.parent.resolve(strict=True); output = parent / output.name
    if output.is_relative_to(python_root) or python_root.is_relative_to(output):
        raise ValueError('separate wheelhouse and interpreter roots required')
    for source in sources.values():
        if Path(source['path']).resolve(strict=True).is_relative_to(output): raise ValueError('output contains source input')
    if shutil.disk_usage(parent).free < total + 1_000_000_000: raise ValueError('insufficient staging space')
    output.mkdir(mode=0o700)
    try:
        wheelhouse = output / 'wheels'; wheelhouse.mkdir(mode=0o700)
        for entry in entries:
            target_file = wheelhouse / entry['filename']
            source, size = open_regular(sources[entry['filename']]['path'], entry['bytes'])
            with source, target_file.open('xb') as destination:
                copied = 0
                while True:
                    block = source.read(min(1_048_576, size - copied + 1))
                    if not block: break
                    copied += len(block)
                    if copied > size: raise ValueError('source grew during copy')
                    destination.write(block)
            if not regular(target_file) or target_file.stat().st_size != entry['bytes'] or digest(target_file) != entry['sha256']:
                raise ValueError('copied wheel changed or is not regular')
        (output / 'requirements.txt').write_text(''.join(f"{e['name']}=={e['version']} --hash=sha256:{e['sha256']}\n" for e in sorted(entries,key=lambda e:e['name'])))
        (output / 'voice-lock.json').write_bytes(lock_bytes)
        (output / 'closure-audit.json').write_bytes(audit_bytes)
        (output / 'python-tree.json').write_bytes(python_manifest_bytes)
        for name in ('home', 'tmp'): (output / name).mkdir(mode=0o700)
        profile = ('(version 1)(allow default)(deny network*)(deny file-write*)'
                   '(deny file-read-data (literal "/tmp") (literal "/private/tmp"))'
                   '(allow file-write* (subpath ' + sandbox_literal(python_root) + ')'
                   ' (subpath ' + sandbox_literal(output) + '))')
        plan = {'schema_version': 1, 'kind': 'offline_voice_install_plan_not_executed', 'target': target,
            'catalog_sha256': lock_sha, 'python_archive_sha256': PYTHON_ARCHIVE_SHA,
            'python_tree_manifest_sha256': hashlib.sha256(python_manifest_bytes).hexdigest(),
            'python_executable_sha256': python_sha, 'wheel_count': len(entries), 'wheel_bytes': total,
            'required_preflight_argv': ['/usr/bin/sandbox-exec', '-p', profile, str(python), '-I', '-B', '-c',
                'import pathlib,sys,sysconfig,pip; root=pathlib.Path(sys.argv[1]).resolve(); assert sys.version_info[:3] == (3,11,17); assert pathlib.Path(sys.prefix).resolve() == root; assert pip.__version__ == "26.2.1"; assert all(pathlib.Path(sysconfig.get_path(k)).resolve().is_relative_to(root) for k in ("purelib","platlib"))', str(python_root)],
            'argv': ['/usr/bin/sandbox-exec', '-p', profile, str(python),
                '-I', '-B', '-m', 'pip', '--isolated', '--disable-pip-version-check', '--no-input', '--no-cache-dir',
                'install', '--no-index', '--no-deps', '--no-compile', '--only-binary=:all:', '--require-hashes',
                '--force-reinstall', '--prefix', str(python_root), '--find-links', str(wheelhouse), '-r', str(output / 'requirements.txt')],
            'environment': {'HOME': str(output / 'home'), 'TMPDIR': str(output / 'tmp'), 'PATH': '/usr/bin:/bin',
                'LANG': 'en_US.UTF-8', 'PIP_CONFIG_FILE': '/dev/null', 'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1'},
            'required_following_checks': ['same-interpreter pip check with network denied',
                'exact installed distribution versions and full package data', 'Mach-O internal/system linkage and signing',
                'local bf_isabella synthesis with network denied and clean caches', 'relocation and owned-child cleanup'],
            'immutable_runtime_manifest_may_be_created': False}
        (output / 'install-plan.json').write_text(json.dumps(plan,indent=2)+'\n')
        return plan
    except BaseException:
        shutil.rmtree(output)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('lock', 'audit', 'inventory', 'python-root', 'python-manifest', 'python-sha256', 'output'): parser.add_argument('--'+name, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.lock,args.audit,args.inventory,args.python_root,args.python_manifest,args.python_sha256,args.output),indent=2))
