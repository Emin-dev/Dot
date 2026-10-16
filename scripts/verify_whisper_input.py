#!/usr/bin/env python3
"""Stage whisper.framework only from repository-pinned XCFramework archive bytes.

No download, installation, native execution, signature change or pin override.
The build workspace/source is trusted; this is not a hostile-owner-UID defense.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import unicodedata
import zipfile

SOURCE_MANIFEST = Path(__file__).resolve().parents[1] / 'packaging/whisper-source-manifest.json'
ARCHIVE_NAME = 'whisper-v1.7.6-xcframework.zip'
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_MEMBERS = 100_000


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(path, maximum, expected_size=None):
    """Detach bounded bytes from one regular, non-followed final descriptor."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum or
                (expected_size is not None and info.st_size != expected_size)):
            raise ValueError('bounded regular input with expected size required')
        data = stream.read(maximum + 1)
        if len(data) != info.st_size or len(data) > maximum:
            raise ValueError('input changed size during read')
        return data


def source_pin():
    raw = read_regular(SOURCE_MANIFEST, 1_000_000)
    source = json.loads(raw)
    rows = [row for row in source.get('runtime_artifacts', []) if row.get('filename') == ARCHIVE_NAME]
    if len(rows) != 1:
        raise ValueError('exactly one repository-owned Whisper archive pin required')
    row = rows[0]
    if (row.get('version') != 'v1.7.6' or type(row.get('size_bytes')) is not int or
            not 0 < row['size_bytes'] <= MAX_ARCHIVE_BYTES or
            not isinstance(row.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', row['sha256'])):
        raise ValueError('invalid repository-owned Whisper archive pin')
    return {'filename': ARCHIVE_NAME, 'bytes': row['size_bytes'], 'sha256': row['sha256']}, sha(raw)


def clean_name(name):
    if (not isinstance(name, str) or not name or len(name.encode('utf-8')) > 4096 or
            name.startswith('/') or '\\' in name or ':' in name or '\0' in name or
            any(part in ('', '.', '..') for part in name.split('/'))):
        raise ValueError('unsafe archive path')
    return name


def archive_index(archive):
    rows = archive.infolist()
    if not 1 <= len(rows) <= MAX_MEMBERS:
        raise ValueError('archive entry count bound')
    entries, aliases, total = {}, set(), 0
    for row in rows:
        if row.filename != row.orig_filename:
            raise ValueError('truncated archive filename rejected')
        name = clean_name(row.filename[:-1] if row.is_dir() else row.filename)
        alias = unicodedata.normalize('NFD', name).casefold()
        if alias in aliases:
            raise ValueError('duplicate or Unicode/case-aliased archive path')
        aliases.add(alias)
        mode = (row.external_attr >> 16) & 0xffff
        kind = stat.S_IFMT(mode)
        if row.is_dir():
            if kind not in (0, stat.S_IFDIR) or row.file_size:
                raise ValueError('invalid archive directory')
            label = 'directory'
        elif kind == stat.S_IFLNK:
            if not 0 < row.file_size <= 4096:
                raise ValueError('symlink size bound')
            label = 'symlink'
        elif kind in (0, stat.S_IFREG):
            label = 'file'
        else:
            raise ValueError('archive special file rejected')
        if (row.flag_bits & 1 or row.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) or
                not 0 <= row.file_size <= MAX_MEMBER_BYTES):
            raise ValueError('unsupported or oversized archive member')
        total += row.file_size
        if total > MAX_EXPANDED_BYTES:
            raise ValueError('archive expansion bound')
        entries[name] = (row, label, 0o755 if mode & 0o111 else 0o644)
    return entries


def member_bytes(archive, entry, maximum=MAX_MEMBER_BYTES):
    row, kind, _ = entry
    if kind == 'directory' or row.file_size > maximum:
        raise ValueError('bounded data member required')
    with archive.open(row) as stream:
        data = stream.read(row.file_size + 1)
    if len(data) != row.file_size:
        raise ValueError('archive member size mismatch')
    return data


def resolve_node(name, nodes):
    remaining, resolved, links = name.split('/'), [], 0
    while remaining:
        part = remaining.pop(0)
        if part in ('', '.'):
            continue
        if part == '..':
            if not resolved:
                raise ValueError('framework link escapes authenticated subtree')
            resolved.pop()
            continue
        resolved.append(part)
        key = '/'.join(resolved)
        node = nodes.get(key)
        if node is None:
            raise ValueError('dangling framework link or missing path')
        if node['kind'] == 'symlink':
            links += 1
            if links > 40:
                raise ValueError('cyclic or excessive framework links')
            resolved.pop()
            remaining = node['target'].split('/') + remaining
        elif remaining and node['kind'] != 'directory':
            raise ValueError('non-directory framework ancestor')
    return '/'.join(resolved)


def framework_nodes(raw):
    # The exact detached bytes were authenticated before this parser is reached.
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive_index(archive)
        plists = [name for name, (_, kind, _) in entries.items()
                  if kind == 'file' and PurePosixPath(name).name == 'Info.plist'
                  and PurePosixPath(name).parent.name == 'whisper.xcframework']
        if len(plists) != 1:
            raise ValueError('one authenticated whisper.xcframework Info.plist required')
        info = plistlib.loads(member_bytes(archive, entries[plists[0]], 1_000_000))
        libraries = info.get('AvailableLibraries')
        if not isinstance(libraries, list) or not 1 <= len(libraries) <= 100:
            raise ValueError('invalid XCFramework library inventory')
        matches = []
        for row in libraries:
            if not isinstance(row, dict):
                raise ValueError('invalid XCFramework library entry')
            architectures = row.get('SupportedArchitectures')
            if (row.get('SupportedPlatform') == 'macos' and row.get('SupportedPlatformVariant') in (None, '') and
                    isinstance(architectures, list) and 'arm64' in architectures):
                matches.append(row)
        if len(matches) != 1:
            raise ValueError('exactly one macOS arm64 framework slice required')
        selected = matches[0]
        identifier = clean_name(selected.get('LibraryIdentifier'))
        if '/' in identifier or selected.get('LibraryPath') != 'whisper.framework':
            raise ValueError('unsupported XCFramework library location')
        architectures = selected['SupportedArchitectures']
        if (not all(isinstance(value, str) and re.fullmatch('[A-Za-z0-9_]+', value) for value in architectures) or
                len(set(architectures)) != len(architectures)):
            raise ValueError('invalid XCFramework architectures')
        root = str(PurePosixPath(plists[0]).parent / identifier / 'whisper.framework')
        nodes = {'': {'kind': 'directory'}}
        for name, entry in entries.items():
            if name == root:
                if entry[1] != 'directory':
                    raise ValueError('framework root must be a directory')
                continue
            if not name.startswith(root + '/'):
                continue
            relative = name[len(root) + 1:]
            node = {'kind': entry[1]}
            if entry[1] == 'file':
                node.update(data=member_bytes(archive, entry), mode=entry[2])
            elif entry[1] == 'symlink':
                target = member_bytes(archive, entry, 4096).decode('utf-8')
                if not target or target.startswith('/') or '\\' in target or '\0' in target or ':' in target:
                    raise ValueError('unsafe framework link target')
                node['target'] = target
            nodes[relative] = node
        for name in list(nodes):
            parent = PurePosixPath(name).parent
            while str(parent) != '.':
                key = str(parent)
                if key in nodes and nodes[key]['kind'] != 'directory':
                    raise ValueError('archive entry has link or file ancestor')
                nodes.setdefault(key, {'kind': 'directory'})
                parent = parent.parent
        # Include implicit directories in the same alias policy as explicit ones.
        aliases = [unicodedata.normalize('NFD', name).casefold() for name in nodes]
        if len(set(aliases)) != len(aliases):
            raise ValueError('aliased implicit framework directory')
        for name, node in nodes.items():
            if node['kind'] == 'symlink':
                resolve_node(name, nodes)
        for required in ('Modules/module.modulemap', 'Headers/whisper.h', 'whisper'):
            node = nodes.get(resolve_node(required, nodes))
            if node is None or node['kind'] != 'file' or not node['data']:
                raise ValueError('required framework file missing')
            if required == 'whisper' and node['mode'] != 0o755:
                raise ValueError('framework binary must retain executable mode')
        return nodes, identifier, architectures


def closure_rows(nodes):
    rows = []
    for name, node in sorted(nodes.items()):
        if not name:
            continue
        row = {'path': name, 'kind': node['kind']}
        if node['kind'] == 'file':
            row.update(bytes=len(node['data']), sha256=sha(node['data']), mode=node['mode'])
        elif node['kind'] == 'symlink':
            row['target'] = node['target']
        rows.append(row)
    return rows


def write_framework(output, nodes):
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('fresh output directory required')
    output.mkdir(mode=0o700)
    try:
        framework = output / 'whisper.framework'
        framework.mkdir(mode=0o755)
        for name, node in sorted(nodes.items(), key=lambda item: (item[0].count('/'), item[0])):
            if name and node['kind'] == 'directory':
                (framework / name).mkdir(mode=0o755)
        # Links are created last, so extraction never writes through an archive link.
        for name, node in nodes.items():
            if node['kind'] == 'file':
                path = framework / name
                with path.open('xb') as stream:
                    stream.write(node['data'])
                path.chmod(node['mode'])
        for name, node in nodes.items():
            if node['kind'] == 'symlink':
                (framework / name).symlink_to(node['target'])
        actual = set()
        for folder, directories, files in os.walk(framework, followlinks=False):
            for name in directories + files:
                path = Path(folder) / name
                relative = path.relative_to(framework).as_posix()
                actual.add(relative)
                node = nodes.get(relative)
                info = path.lstat()
                if node is None:
                    raise ValueError('unexpected staged framework entry')
                if node['kind'] == 'file':
                    if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != node['mode'] or
                            path.read_bytes() != node['data']):
                        raise ValueError('staged framework file mismatch')
                elif node['kind'] == 'symlink':
                    if not stat.S_ISLNK(info.st_mode) or str(path.readlink()) != node['target']:
                        raise ValueError('staged framework link mismatch')
                elif not stat.S_ISDIR(info.st_mode):
                    raise ValueError('staged framework directory mismatch')
        if actual != set(nodes) - {''}:
            raise ValueError('staged framework closure mismatch')
    except BaseException:
        shutil.rmtree(output)
        raise


def _prepare(archive_path, output, pin, source_manifest_sha256):
    """Private test seam. Production receives pins only from source_pin()."""
    expected_size = pin['bytes']
    if type(expected_size) is not int or not 0 < expected_size <= MAX_ARCHIVE_BYTES:
        raise ValueError('archive pin size bound')
    raw = read_regular(archive_path, expected_size, expected_size)
    if sha(raw) != pin['sha256']:
        raise ValueError('Whisper archive does not match repository pin')
    nodes, identifier, architectures = framework_nodes(raw)
    rows = closure_rows(nodes)
    closure = json.dumps(rows, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    write_framework(output, nodes)
    return {'schema_version': 1, 'kind': 'verified_whisper_archive_input',
            'archive_filename': pin['filename'], 'archive_bytes': len(raw), 'archive_sha256': sha(raw),
            'source_manifest_sha256': source_manifest_sha256, 'library_identifier': identifier,
            'architectures': architectures, 'framework_relative_path': 'whisper.framework',
            'framework_closure_sha256': sha(closure), 'framework_entries': len(rows)}


def prepare(archive_path, output):
    pin, source_sha = source_pin()
    return _prepare(archive_path, output, pin, source_sha)


def read_receipt(path):
    """Require the build's receipt to agree with the current source pin."""
    receipt = json.loads(read_regular(path, 64_000))
    pin, source_sha = source_pin()
    expected = {'schema_version': 1, 'kind': 'verified_whisper_archive_input',
                'archive_filename': pin['filename'], 'archive_bytes': pin['bytes'],
                'archive_sha256': pin['sha256'], 'source_manifest_sha256': source_sha,
                'framework_relative_path': 'whisper.framework'}
    if not isinstance(receipt, dict) or any(receipt.get(key) != value for key, value in expected.items()):
        raise ValueError('Whisper input receipt disagrees with repository pin')
    identifier = clean_name(receipt.get('library_identifier'))
    architectures = receipt.get('architectures')
    if ('/' in identifier or not isinstance(architectures, list) or not 1 <= len(architectures) <= 8 or
            not all(isinstance(value, str) and re.fullmatch('[A-Za-z0-9_]+', value) for value in architectures) or
            len(set(architectures)) != len(architectures) or 'arm64' not in architectures or
            type(receipt.get('framework_entries')) is not int or not 1 <= receipt['framework_entries'] <= MAX_MEMBERS or
            not isinstance(receipt.get('framework_closure_sha256'), str) or
            not re.fullmatch('[0-9a-f]{64}', receipt['framework_closure_sha256'])):
        raise ValueError('invalid Whisper framework receipt')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.archive, args.output), sort_keys=True))
