#!/usr/bin/env python3
"""Bounded offline runtime preparation. Prepared bytes are never native approval.

The production CLI has no policy/source/digest override. Historical bases must
already be independently approved in the source-owned policy. Archive extraction
and native finalization deliberately fail closed until their outstanding real
input/native contracts are implemented and reviewed. No candidate code is run.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
from decimal import Decimal, InvalidOperation
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import unicodedata
import uuid

SOURCE_ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = 'packaging/runtime/reconstruction-policy.json'
NATIVE_PATH = 'packaging/runtime/runtime-native-build.json'
MANIFEST = 'runtime-manifest.json'
INVALID, MISSING, UNSUPPORTED, MUTATION = 2, 3, 4, 5
MAX_JSON = 16_000_000
MAX_DEPTH = 32
FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
DIR_FLAGS = FLAGS | os.O_DIRECTORY
SHA = re.compile(r'^[0-9a-f]{64}$')


class Rejected(ValueError):
    def __init__(self, message, code=INVALID):
        super().__init__(message)
        self.code = code


def require(condition, message, code=INVALID):
    if not condition:
        raise Rejected(message, code)


def keys(value, required, optional=()):
    require(type(value) is dict and set(required) <= set(value)
            and set(value) <= set(required) | set(optional), 'unexpected or missing JSON keys')


def integer(value, low, high):
    require(type(value) is int and low <= value <= high, 'integer outside permitted bound')
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pin(value):
    keys(value, ('bytes', 'sha256'))
    integer(value['bytes'], 0, 5_000_000_000)
    require(type(value['sha256']) is str and SHA.fullmatch(value['sha256']), 'invalid digest')
    return value


def _json_types(value, depth=0):
    require(depth <= MAX_DEPTH, 'JSON nesting bound', MUTATION)
    if type(value) is dict:
        require(all(type(k) is str for k in value), 'non-string JSON key')
        for k, v in value.items():
            k.encode('utf-8', 'strict')
            _json_types(v, depth + 1)
    elif type(value) is list:
        for v in value:
            _json_types(v, depth + 1)
    elif type(value) is str:
        value.encode('utf-8', 'strict')
    else:
        require(value is None or type(value) in (bool, int), 'non-integer JSON number/type')
        if type(value) is int:
            require(-10**20 < value < 10**20, 'JSON integer digit bound', MUTATION)


def canonical(value):
    _json_types(value)
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                       allow_nan=False) + '\n').encode('utf-8')


def strict_json(data):
    require(type(data) is bytes and 0 < len(data) <= MAX_JSON, 'JSON byte bound', MUTATION)
    # Enforce nesting before json.loads, which would otherwise recurse on input.
    depth, quoted, escaped = 0, False, False
    for ch in data:
        if quoted:
            if escaped:
                escaped = False
            elif ch == 92:
                escaped = True
            elif ch == 34:
                quoted = False
        elif ch == 34:
            quoted = True
        elif ch in (91, 123):
            depth += 1
            require(depth <= MAX_DEPTH, 'JSON nesting bound', MUTATION)
        elif ch in (93, 125):
            depth -= 1
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    def number(_):
        raise Rejected('floating point/non-finite JSON forbidden')
    def bounded_integer(text):
        require(len(text.lstrip('-')) <= 20, 'JSON integer digit bound', MUTATION)
        return int(text)
    try:
        value = json.loads(data.decode('utf-8'), object_pairs_hook=pairs,
                           parse_float=number, parse_constant=number, parse_int=bounded_integer)
        _json_types(value)
        return value
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise Rejected('invalid bounded JSON') from exc


def relative(name, root=False):
    require(type(name) is str and name, 'empty/non-string path')
    if root and name == '.':
        return name
    require(not name.startswith('/') and '\\' not in name and ':' not in name,
            'absolute/backslash/drive path forbidden')
    require(not any(ord(c) < 32 or ord(c) == 127 for c in name), 'control character in path')
    try:
        raw = name.encode('utf-8', 'strict')
    except UnicodeError as exc:
        raise Rejected('invalid Unicode path') from exc
    parts = name.split('/')
    require(len(raw) <= 4096 and len(parts) <= 64, 'path bound', MUTATION)
    require(all(p not in ('', '.', '..') and len(p.encode('utf-8')) <= 255 for p in parts),
            'invalid path component')
    require(unicodedata.normalize('NFC', name) == name, 'non-NFC path')
    return name


def folded(name):
    return unicodedata.normalize('NFC', name).casefold()


def safe_mode(mode, directory=False):
    integer(mode, 0, 0o7777)
    require(not mode & 0o7022, 'unsafe mode')
    require(mode & 0o400 and (not directory or mode & 0o100), 'unreadable node mode')
    return mode


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
            info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def same_node(a, b):
    require(identity(a) == identity(b), 'filesystem mutation observed', MUTATION)


def directory_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)


class Budget:
    def __init__(self, bounds):
        self.bounds = bounds
        self.deadline = time.monotonic() + bounds['portable_operation_seconds']

    def check(self):
        require(time.monotonic() <= self.deadline, 'operation deadline exceeded', MUTATION)


class Root:
    """No-follow directory capability, retaining/rechecking every ancestor edge."""
    def __init__(self, path):
        path = os.path.abspath(os.fspath(path))
        require(path == os.path.normpath(path), 'noncanonical absolute path')
        self.path = Path(path)
        self.fds, self.edges = [], []
        try:
            self.fds.append(os.open('/', DIR_FLAGS))
            for part in self.path.parts[1:]:
                relative(part)
                before = os.stat(part, dir_fd=self.fds[-1], follow_symlinks=False)
                require(stat.S_ISDIR(before.st_mode), 'symlink/non-directory ancestor')
                fd = os.open(part, DIR_FLAGS, dir_fd=self.fds[-1])
                same_node(before, os.fstat(fd))
                self.edges.append((self.fds[-1], part, fd, directory_identity(before)))
                self.fds.append(fd)
            self.fd = self.fds[-1]
        except BaseException:
            self.close()
            raise

    def check(self):
        for parent, name, fd, expected in self.edges:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            require(directory_identity(current) == expected
                    and directory_identity(os.fstat(fd)) == expected,
                    'directory capability replaced or moved', MUTATION)

    def close(self):
        for fd in reversed(self.fds):
            os.close(fd)
        self.fds = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


@contextlib.contextmanager
def parent_at(root_fd, name):
    parts = relative(name).split('/')
    fds = []
    parent = root_fd
    edges = []
    try:
        for part in parts[:-1]:
            before = os.stat(part, dir_fd=parent, follow_symlinks=False)
            require(stat.S_ISDIR(before.st_mode), 'non-directory physical ancestor')
            child = os.open(part, DIR_FLAGS, dir_fd=parent)
            same_node(before, os.fstat(child))
            fds.append(child)
            edges.append((parent, part, child, directory_identity(before)))
            parent = child
        yield parent, parts[-1]
        for fd, part, child, expected in edges:
            require(directory_identity(os.stat(part, dir_fd=fd, follow_symlinks=False)) == expected
                    and directory_identity(os.fstat(child)) == expected,
                    'parent replaced during operation', MUTATION)
    finally:
        for fd in reversed(fds):
            os.close(fd)


def regular_at(root_fd, name, budget, expected=None, collect=False, output_fd=None, maximum=None):
    maximum = maximum if maximum is not None else budget.bounds['regular_file_bytes']
    with parent_at(root_fd, name) as (parent, leaf):
        before = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                'single-link regular file required')
        safe_mode(stat.S_IMODE(before.st_mode))
        require(before.st_size <= maximum, 'regular file byte bound', MUTATION)
        fd = os.open(leaf, FLAGS, dir_fd=parent)
        try:
            same_node(before, os.fstat(fd))
            hasher, size, chunks = hashlib.sha256(), 0, []
            while True:
                budget.check()
                data = os.read(fd, min(1024 * 1024, maximum - size + 1))
                if not data:
                    break
                size += len(data)
                require(size <= maximum, 'streamed file byte bound', MUTATION)
                hasher.update(data)
                if collect:
                    chunks.append(data)
                if output_fd is not None:
                    view = memoryview(data)
                    while view:
                        written = os.write(output_fd, view)
                        require(written > 0, 'short output write', MUTATION)
                        view = view[written:]
            same_node(before, os.fstat(fd))
            same_node(before, os.stat(leaf, dir_fd=parent, follow_symlinks=False))
            require(size == before.st_size, 'file size changed', MUTATION)
            row = {'path': name, 'kind': 'file', 'mode': stat.S_IMODE(before.st_mode),
                   'bytes': size, 'sha256': hasher.hexdigest()}
            if expected is not None:
                require(all(row.get(k) == v for k, v in expected.items()), 'pinned file mismatch: ' + name)
            return row, b''.join(chunks) if collect else None
        finally:
            os.close(fd)


def read_path(path, budget, expected=None, maximum=None):
    maximum = budget.bounds.get('json_bytes', MAX_JSON) if maximum is None else maximum
    path = Path(path)
    with Root(path.parent) as root:
        row, data = regular_at(root.fd, path.name, budget, expected, True, maximum=maximum)
        root.check()
        return row, data


def validate_rows(rows, bounds, exclude_manifest=True):
    require(type(rows) is list and 1 <= len(rows) <= bounds['all_nodes'], 'node count bound', MUTATION)
    index, aliases, size, entries = {}, set(), 0, 0
    for row in rows:
        require(type(row) is dict, 'closure row object required')
        kind = row.get('kind')
        if kind == 'file':
            keys(row, ('path', 'kind', 'mode', 'bytes', 'sha256'))
            integer(row['bytes'], 0, bounds['regular_file_bytes'])
            pin({'bytes': row['bytes'], 'sha256': row['sha256']})
            size += row['bytes']; entries += 1
            safe_mode(row['mode'])
        elif kind == 'directory':
            keys(row, ('path', 'kind', 'mode'))
            safe_mode(row['mode'], True)
        elif kind == 'symlink':
            keys(row, ('path', 'kind', 'target'))
            entries += 1
            target = row['target']
            require(type(target) is str and target and not target.startswith('/') and '\\' not in target
                    and ':' not in target and not any(ord(c) < 32 or ord(c) == 127 for c in target),
                    'invalid relative link')
            require(len(target.encode('utf-8')) <= bounds['path_utf8_bytes'], 'link target bound', MUTATION)
        else:
            raise Rejected('unsupported node type')
        name = relative(row['path'], root=True)
        require(not exclude_manifest or folded(name) != folded(MANIFEST),
                'manifest or case alias cannot enter closure identity')
        alias = folded(name)
        require(name not in index and alias not in aliases, 'duplicate/aliased node')
        aliases.add(alias); index[name] = row
    require(size <= bounds['runtime_bytes'] and entries <= bounds['regular_and_link_entries'],
            'runtime size/count bound', MUTATION)
    require(index.get('.', {}).get('kind') == 'directory', 'root directory row required')
    for name in index:
        if name != '.':
            parent = name.rpartition('/')[0] or '.'
            require(index.get(parent, {}).get('kind') == 'directory', 'missing/non-directory parent')
    def resolve(parts, hops=0):
        result = []
        while parts:
            item, parts = parts[0], parts[1:]
            if item in ('', '.'):
                continue
            if item == '..':
                require(result, 'escaping symlink')
                result.pop(); continue
            result.append(item)
            name = '/'.join(result)
            require(name in index, 'dangling symlink')
            node = index[name]
            if node['kind'] == 'symlink':
                hops += 1
                require(hops <= bounds['symlink_hops'], 'cyclic/deep symlink', MUTATION)
                parts = node['target'].split('/') + parts
                result.pop()
            elif parts:
                require(node['kind'] == 'directory', 'symlink through non-directory')
        return '/'.join(result) or '.'
    for name, row in index.items():
        if row['kind'] == 'symlink':
            resolve((name.rpartition('/')[0].split('/') if '/' in name else []) + row['target'].split('/'))
    return index


def names_at(fd, maximum, budget):
    names = []
    with os.scandir(fd) as entries:
        for entry in entries:
            budget.check()
            require(len(names) < maximum, 'directory entry bound', MUTATION)
            names.append(entry.name)
    return names


def tree(root, budget, manifest_pin=None):
    rows = []
    total_bytes = 0
    total_entries = 0
    with Root(root) as cap:
        def walk(fd, prefix):
            nonlocal total_bytes, total_entries
            budget.check()
            before = os.fstat(fd)
            mode = safe_mode(stat.S_IMODE(before.st_mode), True)
            rows.append({'path': prefix or '.', 'kind': 'directory', 'mode': mode})
            names = names_at(fd, budget.bounds['all_nodes'] - len(rows), budget)
            require(len(rows) + len(names) <= budget.bounds['all_nodes'], 'node bound', MUTATION)
            for leaf in sorted(names, key=lambda s: s.encode('utf-8', 'strict')):
                relative(leaf)
                name = prefix + '/' + leaf if prefix else leaf
                relative(name)
                require(len(name.encode('utf-8')) <= budget.bounds['path_utf8_bytes']
                        and len(name.split('/')) <= budget.bounds['path_depth']
                        and all(len(p.encode('utf-8')) <= budget.bounds['component_utf8_bytes'] for p in name.split('/')),
                        'source-policy path bound', MUTATION)
                info = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
                require(folded(name) != folded(MANIFEST) or name == MANIFEST,
                        'reserved manifest case alias forbidden')
                if name == MANIFEST:
                    require(manifest_pin is not None, 'unexpected runtime manifest')
                    regular_at(fd, leaf, budget, manifest_pin, maximum=MAX_JSON)
                elif stat.S_ISDIR(info.st_mode):
                    child = os.open(leaf, DIR_FLAGS, dir_fd=fd)
                    try:
                        same_node(info, os.fstat(child))
                        walk(child, name)
                        same_node(info, os.stat(leaf, dir_fd=fd, follow_symlinks=False))
                    finally:
                        os.close(child)
                elif stat.S_ISREG(info.st_mode):
                    total_bytes += info.st_size; total_entries += 1
                    require(total_bytes <= budget.bounds['runtime_bytes']
                            and total_entries <= budget.bounds['regular_and_link_entries'], 'runtime bound', MUTATION)
                    row, _ = regular_at(fd, leaf, budget)
                    row['path'] = name; rows.append(row)
                elif stat.S_ISLNK(info.st_mode):
                    total_entries += 1
                    require(total_entries <= budget.bounds['regular_and_link_entries'], 'link count bound', MUTATION)
                    target = os.readlink(leaf, dir_fd=fd)
                    same_node(info, os.stat(leaf, dir_fd=fd, follow_symlinks=False))
                    rows.append({'path': name, 'kind': 'symlink', 'target': target})
                else:
                    raise Rejected('special filesystem node forbidden')
                require(len(rows) <= budget.bounds['all_nodes'], 'node bound', MUTATION)
            same_node(before, os.fstat(fd))
        walk(cap.fd, '')
        cap.check()
    rows.sort(key=lambda r: r['path'].encode('utf-8'))
    validate_rows(rows, budget.bounds)
    return rows


def write_new(root_fd, name, data, mode=0o600):
    with parent_at(root_fd, name) as (parent, leaf):
        fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=parent)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, 'new regular output required')
            view = memoryview(data)
            while view:
                count = os.write(fd, view)
                require(count > 0, 'short write', MUTATION)
                view = view[count:]
            os.fchmod(fd, mode); os.fsync(fd)
            after = os.fstat(fd)
            require(after.st_nlink == 1, 'new output hardlink forbidden')
            same_node(after, os.stat(leaf, dir_fd=parent, follow_symlinks=False))
        finally:
            os.close(fd)
        os.fsync(parent)


def reserve(fd, size, budget):
    info = os.fstatvfs(fd)
    needed = size + budget.bounds['scratch_reserve_bytes'] + budget.bounds['all_nodes'] * 4096
    require(info.f_bavail * info.f_frsize >= needed, 'insufficient disk reserve', MUTATION)


def copy_tree(source, output, rows, budget):
    """Copy an already-admitted complete closure using the same hashed descriptors."""
    index = validate_rows(rows, budget.bounds)
    with Root(source) as src, Root(output) as dst:
        reserve(dst.fd, sum(r.get('bytes', 0) for r in rows), budget)
        for row in sorted(rows, key=lambda r: (r['path'].count('/'), r['path'].encode('utf-8'))):
            budget.check()
            name = row['path']
            if name == '.':
                continue
            with parent_at(dst.fd, name) as (parent, leaf):
                if row['kind'] == 'directory':
                    os.mkdir(leaf, 0o700, dir_fd=parent)
                elif row['kind'] == 'symlink':
                    with parent_at(src.fd, name) as (sp, sl):
                        old = os.stat(sl, dir_fd=sp, follow_symlinks=False)
                        require(stat.S_ISLNK(old.st_mode) and os.readlink(sl, dir_fd=sp) == row['target'],
                                'source link changed', MUTATION)
                        os.symlink(row['target'], leaf, dir_fd=parent)
                        same_node(old, os.stat(sl, dir_fd=sp, follow_symlinks=False))
                else:
                    fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 0o600, dir_fd=parent)
                    try:
                        regular_at(src.fd, name, budget, row, output_fd=fd)
                        os.fchmod(fd, row['mode']); os.fsync(fd)
                        require(os.fstat(fd).st_nlink == 1, 'output hardlink forbidden')
                    finally:
                        os.close(fd)
                os.fsync(parent)
        for row in sorted(rows, key=lambda r: r['path'].count('/'), reverse=True):
            if row['kind'] == 'directory':
                if row['path'] == '.':
                    os.fchmod(dst.fd, row['mode']); os.fsync(dst.fd)
                else:
                    with parent_at(dst.fd, row['path']) as (parent, leaf):
                        fd = os.open(leaf, DIR_FLAGS, dir_fd=parent)
                        try:
                            os.fchmod(fd, row['mode']); os.fsync(fd)
                        finally:
                            os.close(fd)
        src.check()
        # The intentional root mode update is checked using the open descriptor.
        require(stat.S_IMODE(os.fstat(dst.fd).st_mode) == index['.']['mode'], 'output root mode mismatch')
    require(tree(output, budget) == rows, 'copied closure mismatch', MUTATION)


def no_replace(parent_fd, source, destination):
    """Atomic directory publication, never check-then-rename replacement."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'linux' and hasattr(library, 'renameat2'):
        function = library.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(parent_fd, source.encode(), parent_fd, destination.encode(), 1)
    elif sys.platform == 'darwin' and hasattr(library, 'renameatx_np'):
        function = library.renameatx_np
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(parent_fd, source.encode(), parent_fd, destination.encode(), 4)
    else:
        raise Rejected('atomic no-replace publication unavailable', UNSUPPORTED)
    if result != 0:
        error = ctypes.get_errno()
        raise Rejected('atomic publication refused: ' + os.strerror(error),
                       INVALID if error in (errno.EEXIST, errno.ENOTEMPTY) else MUTATION)
    os.fsync(parent_fd)


def disjoint(output, inputs):
    output = Path(os.path.abspath(output))
    require(not any(p.lower().endswith('.app') for p in output.parts), 'stage/copy beneath .app forbidden')
    # Casefold comparison conservatively protects case-insensitive destination volumes.
    out = folded(str(output)).rstrip('/') + '/'
    for source in inputs:
        source = Path(os.path.abspath(source))
        name = folded(str(source)).rstrip('/') + '/'
        require(not out.startswith(name) and not name.startswith(out), 'source/output overlap')


def reject_descriptor_overlap(destination_parent, protected_directories, budget):
    """Reject lexical aliases such as bind mounts/firmlinks before creating a stage.

    Compare every physical protected-directory identity, including descendants,
    with all held destination-parent ancestors. A descendant-rooted bind alias
    may omit the protected root from its visible ancestor chain.
    """
    destination_ids = {(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in destination_parent.fds}
    for path in protected_directories:
        with Root(path) as protected:
            count = 0
            def walk(fd, depth):
                nonlocal count
                budget.check()
                require(depth <= budget.bounds['path_depth'], 'protected directory depth bound', MUTATION)
                before = os.fstat(fd)
                require((before.st_dev, before.st_ino) not in destination_ids,
                        'descriptor source/output overlap')
                names = names_at(fd, budget.bounds['all_nodes'] - count, budget)
                for name in names:
                    count += 1
                    require(count <= budget.bounds['all_nodes'], 'protected directory node bound', MUTATION)
                    relative(name)
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if stat.S_ISDIR(info.st_mode):
                        child = os.open(name, DIR_FLAGS, dir_fd=fd)
                        try:
                            same_node(info, os.fstat(child))
                            walk(child, depth + 1)
                            same_node(info, os.stat(name, dir_fd=fd, follow_symlinks=False))
                        finally:
                            os.close(child)
                same_node(before, os.fstat(fd))
            walk(protected.fd, 0)
            protected.check()
    destination_parent.check()


COLLECTOR_SHA = 'c9af9c56a4a89707110e53bce1007d0cc8bef301a024eafd020140eda37a7f9a'
COLLECTOR_ARTIFACTS = {'collection-start.json': 65536, 'runtime-manifest.original.json': 16000000,
    'runtime-inventory.json': 120000000, 'support-inventory.json': 120000000,
    'apple-tools.json': 120000000, 'report.json': 120000000, 'COMPLETE.txt': 4096}
COLLECTOR_SCOPES = ('Contents/MacOS', 'Contents/Frameworks', 'Contents/Helpers',
                    'Contents/Resources/Runtime', 'Contents/Resources/Voice')
COLLECTOR_RUNTIME = 'Contents/Resources/Offline'
COLLECTOR_NATIVE_OPS = {'architecture', 'dependencies', 'load_commands',
                        'signature_display', 'signature_verify_strict'}


def validate_collector_policy(value):
    keys(value, ('schema_version','collector_source_sha256','aggregate_bytes','artifact_bytes','nodes',
                 'path_bytes','native_files','tool_output_bytes','tool_output_total_bytes',
                 'elapsed_seconds_max','seal_weight_max','json_nesting'))
    require(type(value['schema_version']) is int and value['schema_version'] == 2
            and value['collector_source_sha256'] == COLLECTOR_SHA, 'unknown collector protocol')
    keys(value['artifact_bytes'], tuple(COLLECTOR_ARTIFACTS))
    for name, maximum in COLLECTOR_ARTIFACTS.items():
        integer(value['artifact_bytes'][name], 1, maximum)
    for name, maximum in {'aggregate_bytes':120000000,'nodes':100000,'path_bytes':16000000,
            'native_files':2048,'tool_output_bytes':262144,'tool_output_total_bytes':32000000,
            'elapsed_seconds_max':1802,'seal_weight_max':1000000000,'json_nesting':32}.items():
        integer(value[name], 1, maximum)


def validate_collector_bundle(value, limits):
    keys(value, ('schema_version','collector_source_sha256','artifacts'))
    require(type(value['schema_version']) is int and value['schema_version'] == 2
            and value['collector_source_sha256'] == limits['collector_source_sha256'], 'collector pin protocol')
    keys(value['artifacts'], tuple(COLLECTOR_ARTIFACTS))
    total = 0
    for name, item in value['artifacts'].items():
        pin(item)
        require(0 < item['bytes'] <= limits['artifact_bytes'][name], 'collector artifact pin bound', MUTATION)
        total += item['bytes']
    require(total <= limits['aggregate_bytes'], 'collector aggregate pin bound', MUTATION)


def collector_json(raw, artifact, limits):
    """Only two exact diagnostic locations accept Decimal; canonical JSON is unchanged."""
    require(0 < len(raw) <= limits['artifact_bytes'][artifact], 'collector JSON byte bound', MUTATION)
    depth, quoted, escaped = 0, False, False
    for character in raw:
        if quoted:
            if escaped: escaped = False
            elif character == 92: escaped = True
            elif character == 34: quoted = False
        elif character == 34: quoted = True
        elif character in (91,123):
            depth += 1
            require(depth <= limits['json_nesting'], 'collector JSON nesting bound', MUTATION)
        elif character in (93,125): depth -= 1
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate collector JSON key')
            result[key] = value
        return result
    def whole(text):
        require(len(text.lstrip('-')) <= 20, 'collector integer digit bound', MUTATION)
        return int(text)
    def decimal(text):
        require(len(text) <= 64, 'collector decimal lexeme bound', MUTATION)
        try:
            value = Decimal(text)
            require(value.is_finite() and value.adjusted() <= 12 and value.adjusted() >= -100,
                    'collector decimal magnitude bound', MUTATION)
            return value
        except (InvalidOperation, ValueError) as exc:
            raise Rejected('invalid collector decimal') from exc
    def nonfinite(_):
        raise Rejected('nonfinite collector number forbidden')
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_int=whole,
                           parse_float=decimal, parse_constant=nonfinite)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise Rejected('invalid bounded collector JSON') from exc
    def validate(value, path=()):
        if isinstance(value, Decimal):
            elapsed = (artifact == 'apple-tools.json' and len(path) == 3 and type(path[0]) is int
                       and path[1:] == ('result','elapsed_seconds'))
            weight = (artifact == 'report.json' and len(path) == 6
                      and path[:3] == ('metadata','Contents/_CodeSignature/CodeResources','rules')
                      and path[3] in ('rules','rules2') and type(path[4]) is str
                      and len(path[4].encode('utf-8')) <= 4096 and path[5] == 'weight')
            require(elapsed or weight, 'collector decimal at unexpected location')
            maximum = limits['elapsed_seconds_max'] if elapsed else limits['seal_weight_max']
            require(0 <= value <= maximum, 'collector diagnostic decimal range', MUTATION)
        elif type(value) is dict:
            for key, child in value.items():
                require(type(key) is str and len(key.encode('utf-8')) <= MAX_JSON, 'collector JSON key bound')
                validate(child, path + (key,))
        elif type(value) is list:
            for index, child in enumerate(value): validate(child, path + (index,))
        elif type(value) is str:
            require(len(value.encode('utf-8')) <= MAX_JSON, 'collector string bound', MUTATION)
        else:
            require(value is None or type(value) in (bool,int), 'collector JSON value type')
    try:
        validate(value)
    except UnicodeError as exc:
        raise Rejected('invalid collector Unicode') from exc
    return value


def _collector_inventory(value, context, counts):
    keys(value, ('entries','directories'))
    require(type(value['entries']) is dict and type(value['directories']) is dict,
            'collector inventory maps required')
    limits = context.policy['collector_v2']
    rows, native, names = [], {}, set()
    def token(value, kind):
        require(type(value) is list and len(value) == 6, 'collector stat token shape')
        for number in value: require(type(number) is int and -10**20 < number < 10**20, 'collector stat integer')
        require(value[0] >= 0 and value[1] >= 0 and value[3] >= 0, 'collector stat value')
        expected = {'file':stat.S_IFREG,'directory':stat.S_IFDIR,'symlink':stat.S_IFLNK}[kind]
        require(stat.S_IFMT(value[2]) == expected, 'collector stat/type mismatch')
        return stat.S_IMODE(value[2])
    for name, observed in value['directories'].items():
        relative(name, root=True)
        mode = token(observed, 'directory')
        rows.append({'path':name,'kind':'directory','mode':mode})
    for name, observed in value['entries'].items():
        relative(name)
        require(type(observed) is dict, 'collector observed entry')
        kind = observed.get('kind')
        mode = token(observed.get('stat'), kind) if kind in ('file','symlink') else None
        if kind == 'file':
            keys(observed, ('kind','bytes','stat','hardlink_count','sha256','mach_o_magic'))
            integer(observed['bytes'], 0, context.bounds['regular_file_bytes'])
            require(type(observed['hardlink_count']) is int and observed['hardlink_count'] == 1,
                    'collector mutable hardlink rejected')
            require(observed['bytes'] == observed['stat'][3] and type(observed['mach_o_magic']) is bool,
                    'collector file size/magic mismatch')
            pin({'bytes':observed['bytes'],'sha256':observed['sha256']})
            rows.append({'path':name,'kind':'file','mode':mode,
                         'bytes':observed['bytes'],'sha256':observed['sha256']})
            counts['bytes'] += observed['bytes']
            if observed['mach_o_magic']: native[name] = observed['sha256']
        elif kind == 'symlink':
            keys(observed, ('kind','target','resolved','resolved_kind','stat'))
            relative(observed['resolved'], root=True)
            require(observed['resolved_kind'] in ('directory','file'), 'collector link resolution type')
            rows.append({'path':name,'kind':'symlink','target':observed['target']})
        else:
            raise Rejected('collector special/unknown node')
    for row in rows:
        name = row['path']; alias = folded(name)
        require(alias not in names, 'collector duplicate/aliased physical node')
        names.add(alias)
        if name != '.':
            counts['nodes'] += 1; counts['paths'] += len(name.encode('utf-8'))
    require(counts['nodes'] <= limits['nodes'] and counts['paths'] <= limits['path_bytes']
            and counts['bytes'] <= context.bounds['runtime_bytes'], 'collector inventory aggregate bound', MUTATION)
    # Include the manifest for this physical inventory validation, then explicitly
    # reserve its folded spelling before excluding it from runtime identity.
    for row in rows:
        require(folded(row['path']) != folded(MANIFEST) or row['path'] == MANIFEST,
                'collector reserved manifest alias')
    index=validate_rows(rows, context.bounds, exclude_manifest=False)
    for name,observed in value['entries'].items():
        if observed['kind']!='symlink':continue
        pending=(name.rpartition('/')[0].split('/') if '/' in name else [])+observed['target'].split('/')
        resolved=[];hops=0
        while pending:
            item=pending.pop(0)
            if item in ('','.'):continue
            if item=='..':
                require(resolved,'collector escaping link');resolved.pop();continue
            resolved.append(item);node=index['/'.join(resolved)]
            if node['kind']=='symlink':
                hops+=1;require(hops<=context.bounds['symlink_hops'],'collector link hop bound',MUTATION)
                pending=node['target'].split('/')+pending;resolved.pop()
        final='/'.join(resolved) or '.'
        require(observed['resolved']==final and observed['resolved_kind']==index[final]['kind'],
                'collector reported link resolution mismatch')
    return sorted(rows, key=lambda r:r['path'].encode('utf-8')), native


def _collector_metadata(value, limits):
    paths=('Contents/Info.plist','Contents/Resources/build-provenance.json','Contents/_CodeSignature/CodeResources')
    keys(value, paths)
    info_fields={'CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion',
                 'CFBundleExecutable','DotRuntimeManifestSHA256','DotModelManifestSHA256'}
    provenance_fields={'commit','source_dirty','signing','notarized','runtime_bundled','models_bundled','search_bundled',
                       'runtime_manifest_sha256','model_plan_sha256','embedded_whisper_binary_sha256'}
    bool_fields={'source_dirty','notarized','runtime_bundled','models_bundled','search_bundled'}
    for name,entry in value.items():
        if type(entry) is dict and 'status' in entry:
            keys(entry,('status',),('error_type',))
            require(entry['status'] in ('missing','unreadable_or_invalid')
                    and ('error_type' not in entry or type(entry['error_type']) is str), 'collector metadata failure schema')
            continue
        if name.endswith('CodeResources'):
            keys(entry,('bytes','sha256','manifest_entries','rules','seal_coverage_conclusion'))
            require(entry['seal_coverage_conclusion']=='unreviewed', 'collector seal cannot self-approve coverage')
            keys(entry['manifest_entries'],(),('files','files2'))
            def seal_bytes(item):
                keys(item,('bytes_hex',))
                require(type(item['bytes_hex']) is str and len(item['bytes_hex']) <= 128
                        and len(item['bytes_hex'])%2 == 0
                        and re.fullmatch('[0-9a-f]*',item['bytes_hex']) is not None,'collector seal digest encoding')
            for item in entry['manifest_entries'].values():
                if item is None:continue
                require(type(item) is dict,'collector seal manifest entry')
                if 'bytes_hex' in item:seal_bytes(item);continue
                keys(item,(),('hash','hash2','cdhash','optional','nested','requirement','symlink'))
                for label,field in item.items():
                    if label in ('hash','hash2','cdhash'):seal_bytes(field)
                    elif label in ('optional','nested'):require(type(field) is bool,'collector seal entry flag')
                    else:require(type(field) is str,'collector seal entry string')
            keys(entry['rules'],('rules','rules2'))
            for rule_set in entry['rules'].values():
                require(rule_set is None or type(rule_set) is dict, 'collector seal rules map')
                if rule_set is None:continue
                for pattern,rule in rule_set.items():
                    require(type(pattern) is str and len(pattern.encode('utf-8')) <= 4096, 'collector seal rule key')
                    if type(rule) is bool:continue
                    keys(rule,(),('omit','optional','nested','weight'))
                    for key,item in rule.items():
                        if key=='weight':
                            require(type(item) is int or isinstance(item,Decimal), 'collector seal weight type')
                            require(0 <= item <= limits['seal_weight_max'], 'collector seal weight bound',MUTATION)
                        else:require(type(item) is bool,'collector seal rule flag type')
        else:
            keys(entry,('bytes','sha256','selected_fields'))
            allowed=info_fields if name.endswith('Info.plist') else provenance_fields
            keys(entry['selected_fields'],(),allowed)
            for key,item in entry['selected_fields'].items():
                require(type(item) is (bool if key in bool_fields else str), 'collector selected metadata type')
        pin({'bytes':entry['bytes'],'sha256':entry['sha256']})
        require(0 < entry['bytes'] <= (MAX_JSON if name.endswith('CodeResources') else 1000000),
                'collector small metadata byte bound',MUTATION)


def _collector_result_argv(event, app_path):
    operation=event['operation'];target=event['target'];argv=event['result']['argv']
    if target=='chip_family_only':expected=['/usr/sbin/sysctl','-n','machdep.cpu.brand_string']
    elif target=='app':
        prefix={'outer_signature_display':['--display','--verbose=4','--requirements','-'],
                'outer_signature_verify_strict':['--verify','--strict','--verbose=4'],
                'outer_signature_verify_deep_strict':['--verify','--deep','--strict','--verbose=4']}[operation]
        expected=['/usr/bin/codesign']+prefix+[app_path]
    else:
        prefixes={'architecture':['/usr/bin/lipo','-archs'],'dependencies':['/usr/bin/otool','-L'],
                  'load_commands':['/usr/bin/otool','-l'],
                  'signature_display':['/usr/bin/codesign','--display','--verbose=4','--requirements','-'],
                  'signature_verify_strict':['/usr/bin/codesign','--verify','--strict','--verbose=4']}
        require(re.fullmatch(r'/dev/fd/[0-9]{1,10}',argv[-1]) is not None,'collector descriptor argument')
        expected=prefixes[operation]+[argv[-1]]
    require(argv==expected,'collector tool argv mismatch')


def _collector_tool_event(event, limits):
    keys(event, ('target','operation','result'), ('sha256','descriptor_bound','parsed_load_commands'))
    require(type(event['target']) is str and type(event['operation']) is str, 'collector tool identity')
    result = event['result']
    keys(result, ('argv','returncode','reason','stdout','stderr'),
         ('error_type','errno','cleanup_incomplete','output_bytes','elapsed_seconds',
          'sandbox','sandbox_profile_sha256','exit_code_scope'))
    require(type(result['argv']) is list and result['argv'] and all(type(x) is str for x in result['argv']),
            'collector actual argv required')
    require(result['returncode'] is None or type(result['returncode']) is int, 'collector exit code type')
    require(result['reason'] is None or type(result['reason']) is str, 'collector failure reason type')
    for label in ('stdout','stderr'):
        require(type(result[label]) is str and len(result[label].encode('utf-8')) <= 3*limits['tool_output_bytes'],
                'collector decoded tool output bound', MUTATION)
    if 'output_bytes' in result: integer(result['output_bytes'], 0, limits['tool_output_bytes'])
    reported_bytes=result.get('output_bytes',0)
    require(len(result['stdout'])+len(result['stderr']) <= reported_bytes
            and len(result['stdout'].encode('utf-8'))+len(result['stderr'].encode('utf-8')) <= 3*reported_bytes,
            'collector decoded/output byte accounting mismatch')
    if 'elapsed_seconds' in result:
        value = result['elapsed_seconds']
        require(type(value) is int or isinstance(value, Decimal), 'collector elapsed type')
        require(0 <= value <= limits['elapsed_seconds_max'], 'collector elapsed bound', MUTATION)
    if 'cleanup_incomplete' in result: require(type(result['cleanup_incomplete']) is bool, 'collector cleanup type')
    if 'errno' in result: require(type(result['errno']) is int, 'collector errno type')
    if 'error_type' in result: require(type(result['error_type']) is str, 'collector error type')
    for field in ('sandbox','sandbox_profile_sha256','exit_code_scope'):
        if field in result:require(type(result[field]) is str,'collector tool diagnostic type')
    if 'sandbox_profile_sha256' in result:
        require(SHA.fullmatch(result['sandbox_profile_sha256']) is not None,'collector sandbox digest')
    if 'parsed_load_commands' in event:
        require(event['operation'] == 'load_commands' and type(event['parsed_load_commands']) is list,
                'collector load command shape')
        for command in event['parsed_load_commands']:
            keys(command, ('cmd',), ('name','path','platform','minos','sdk','version'))
            require(all(type(v) is str for v in command.values()), 'collector load command types')
    succeeded = (result['returncode'] == 0 and type(result['returncode']) is int
                 and result['reason'] is None and result.get('cleanup_incomplete',False) is False
                 and result.get('sandbox') == 'deny_writes_network_and_bundle_execution_v1'
                 and type(result.get('sandbox_profile_sha256')) is str
                 and SHA.fullmatch(result['sandbox_profile_sha256']) is not None
                 and result.get('exit_code_scope') == 'observed sandbox-exec process; target tool may not have started'
                 and 'output_bytes' in result and 'elapsed_seconds' in result
                 and 'error_type' not in result and 'errno' not in result)
    return bool(succeeded), result.get('output_bytes',0)


def read_collector_v2(report_root, context, approved_bundle=None):
    """Observe exact collector bytes. Even an eligible result is not approval."""
    limits = context.policy['collector_v2']
    if approved_bundle is not None: validate_collector_bundle(approved_bundle, limits)
    parsed, pins = {}, {}
    with Root(report_root) as report:
        directory_before=os.fstat(report.fd)
        require(set(names_at(report.fd, len(COLLECTOR_ARTIFACTS), context.budget)) == set(COLLECTOR_ARTIFACTS),
                'complete seven-artifact collector shape required; partial reports unsupported')
        declared, initial = 0, {}
        for name in COLLECTOR_ARTIFACTS:
            info = os.stat(name, dir_fd=report.fd, follow_symlinks=False)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'regular single-link collector artifact required')
            require(0 < info.st_size <= limits['artifact_bytes'][name], 'collector artifact byte bound', MUTATION)
            declared += info.st_size
            initial[name] = info
        require(declared <= limits['aggregate_bytes'], 'collector aggregate byte bound', MUTATION)
        actual = 0
        for name in COLLECTOR_ARTIFACTS:
            same_node(initial[name],os.stat(name,dir_fd=report.fd,follow_symlinks=False))
            expected = approved_bundle['artifacts'][name] if approved_bundle else None
            row, raw = regular_at(report.fd, name, context.budget, expected, collect=True,
                                  maximum=min(limits['artifact_bytes'][name],limits['aggregate_bytes']-actual))
            same_node(initial[name],os.stat(name,dir_fd=report.fd,follow_symlinks=False))
            actual += row['bytes']
            require(actual <= limits['aggregate_bytes'],'collector actual aggregate byte bound',MUTATION)
            pins[name] = {'bytes':row['bytes'],'sha256':row['sha256']}
            parsed[name] = raw if name == 'COMPLETE.txt' else collector_json(raw, name, limits)
        require(set(names_at(report.fd,len(COLLECTOR_ARTIFACTS),context.budget)) == set(COLLECTOR_ARTIFACTS),
                'collector artifact closure changed',MUTATION)
        for name in COLLECTOR_ARTIFACTS:
            same_node(initial[name],os.stat(name,dir_fd=report.fd,follow_symlinks=False))
        same_node(directory_before,os.fstat(report.fd))
        report.check()
    bundle = {'schema_version':2,'collector_source_sha256':limits['collector_source_sha256'],'artifacts':pins}
    validate_collector_bundle(bundle,limits)
    if approved_bundle is not None: require(bundle == approved_bundle, 'collector pin set mismatch')
    start, summary = parsed['collection-start.json'], parsed['report.json']
    common = ('schema_version','started_utc','app_path','status','trust_conclusion','scope','limits','limitations')
    keys(start, common)
    keys(summary, common + ('finished_utc','collector_exit_code'),
         ('runtime_manifest','runtime_comparison','speech_assets','metadata','direct_hashed_bytes',
          'actual_entries_including_directories','trusted_tool_availability','native_file_count',
          'metadata_stable_across_collection','all_tool_invocations_completed','all_tool_returncodes_zero',
          'error_type','error'))
    for value in (start,summary):
        require(type(value['schema_version']) is int and value['schema_version'] == 2
                and value['trust_conclusion'] == 'not_established', 'collector summary schema/trust claim')
        require(type(value['app_path']) is str and value['app_path'].startswith('/')
                and len(value['app_path'].encode('utf-8')) <= 4096, 'collector app locator')
        require(type(value['started_utc']) is str and 0 < len(value['started_utc']) <= 100, 'collector start time')
        require(type(value['limitations']) is list and all(type(x) is str for x in value['limitations']),
                'collector limitations shape')
        keys(value['scope'], ('runtime','support','excluded'))
        require(value['scope']['runtime'] == COLLECTOR_RUNTIME and value['scope']['support'] == list(COLLECTOR_SCOPES)
                and type(value['scope']['excluded']) is list
                and all(type(x) is str for x in value['scope']['excluded']), 'collector scope mismatch')
        keys(value['limits'], ('manifest_bytes','entries','closure_bytes','native_files','wall_seconds',
                              'cumulative_path_bytes','tool_output_each','tool_output_total'))
        fixed_limits={'manifest_bytes':16000000,'entries':100000,'closure_bytes':5000000000,'native_files':2048,
                      'wall_seconds':1800,'cumulative_path_bytes':16000000,'tool_output_each':262144,'tool_output_total':32000000}
        require(value['limits']==fixed_limits and all(type(v) is int for v in value['limits'].values()),
                'collector fixed limits mismatch')
    require(start['status'] == 'collecting' and summary['status'] in ('collected','incomplete'), 'collector status')
    for key in ('schema_version','started_utc','app_path','scope','limits','limitations','trust_conclusion'):
        require(start[key] == summary[key], 'collector start/final observation mismatch')
    for field in ('error_type','error'):
        if field in summary:require(type(summary[field]) is str,'collector summary error type')
    integer(summary['collector_exit_code'],0,2)
    require(type(summary['finished_utc']) is str and 0 < len(summary['finished_utc']) <= 100,'collector finish time')
    for field in ('metadata_stable_across_collection','all_tool_invocations_completed','all_tool_returncodes_zero'):
        if field in summary:require(type(summary[field]) is bool,'collector summary boolean type')
    if 'trusted_tool_availability' in summary:
        keys(summary['trusted_tool_availability'],('codesign','otool','lipo','sysctl','sandbox'))
        require(all(type(v) is bool for v in summary['trusted_tool_availability'].values()),'collector tool availability types')
    if 'runtime_manifest' in summary:
        item=summary['runtime_manifest']
        keys(item,('bytes','sha256','historical_report_digest_matches','historical_digest_is_not_vendor_provenance',
                   'entries','transport_patch','components'))
        pin({'bytes':item['bytes'],'sha256':item['sha256']})
        integer(item['entries'],1,100000)
        require(type(item['historical_report_digest_matches']) is bool
                and item['historical_digest_is_not_vendor_provenance'] is True
                and (item['transport_patch'] is None or type(item['transport_patch']) is str)
                and type(item['components']) is list,'collector manifest summary types')
    if 'runtime_comparison' in summary:
        item=summary['runtime_comparison'];keys(item,('matches','missing','extra','mismatches'))
        require(type(item['matches']) is bool and all(type(item[k]) is list for k in ('missing','extra','mismatches')),
                'collector comparison types')
        for name in item['missing']+item['extra']:relative(name)
        for row in item['mismatches']:
            keys(row,('path','fields'));relative(row['path'])
            require(type(row['fields']) is list and all(k in ('kind','bytes','sha256','target') for k in row['fields']),
                    'collector mismatch fields')
    if 'metadata' in summary:_collector_metadata(summary['metadata'],limits)
    for field,maximum in (('direct_hashed_bytes',5000000000),('actual_entries_including_directories',100000),('native_file_count',2048)):
        if field in summary:integer(summary[field],0,maximum)
    expected_marker = ('Collection finished; inspect report.json. Exit code: %d\n'
                       'A complete report is not an admission or vendor-origin approval.\n' % summary['collector_exit_code']).encode()
    require(parsed['COMPLETE.txt'] == expected_marker, 'collector completion marker mismatch')
    counts = {'bytes':0,'nodes':0,'paths':0}
    runtime, runtime_native = _collector_inventory(parsed['runtime-inventory.json'],context,counts)
    runtime_index = {row['path']:row for row in runtime}
    original = parsed['runtime-manifest.original.json']
    require(type(original) is dict and original.get('schema_version') == 1 and type(original['schema_version']) is int
            and original.get('kind') == 'verified_runtime_payload' and type(original.get('files')) is list,
            'historical manifest schema')
    manifest_entry = runtime_index.get(MANIFEST,{})
    require(manifest_entry.get('kind') == 'file' and all(manifest_entry.get(k) == v for k,v in pins['runtime-manifest.original.json'].items()),
            'collector original manifest cross-file mismatch')
    closure = [row for row in runtime if row['path'] != MANIFEST]
    validate_rows(closure,context.bounds)
    require(len(canonical(closure)) <= MAX_JSON, 'normalized closure identity bound; no flattened report', MUTATION)
    expected_files, aliases = {}, set()
    require(1 <= len(original['files']) <= context.bounds['regular_and_link_entries'], 'historical manifest count')
    for row in original['files']:
        require(type(row) is dict, 'historical manifest row')
        name = relative(row.get('path'))
        require(folded(name) not in aliases and folded(name) != folded(MANIFEST), 'historical manifest alias/self entry')
        aliases.add(folded(name))
        if row.get('kind') == 'file':
            keys(row, ('path','kind','bytes','sha256'), ('mode',))
            pin({'bytes':row['bytes'],'sha256':row['sha256']})
        elif row.get('kind') == 'symlink': keys(row, ('path','kind','target'), ('mode',))
        else: raise Rejected('historical manifest entry kind')
        expected_files[name] = row
    actual_files = {row['path']:row for row in closure if row['kind'] != 'directory'}
    missing = sorted(set(expected_files)-set(actual_files)); extra = sorted(set(actual_files)-set(expected_files))
    mismatches = []
    for name in sorted(set(expected_files)&set(actual_files)):
        fields = ('kind','bytes','sha256') if expected_files[name]['kind']=='file' else ('kind','target')
        differences = [key for key in fields if expected_files[name].get(key) != actual_files[name].get(key)]
        if differences:mismatches.append({'path':name,'fields':differences})
    comparison={'matches':not(missing or extra or mismatches),'missing':missing,'extra':extra,'mismatches':mismatches}
    support=parsed['support-inventory.json']; keys(support,COLLECTOR_SCOPES)
    native_targets={COLLECTOR_RUNTIME+'/'+name:sha for name,sha in runtime_native.items()}
    for scope,value in support.items():
        if value == {'status':'missing'}:continue
        _, native = _collector_inventory(value,context,counts)
        native_targets.update({scope+'/'+name:sha for name,sha in native.items()})
    require(len(native_targets) <= limits['native_files'], 'collector native count bound', MUTATION)
    tools=parsed['apple-tools.json']
    require(type(tools) is list and len(tools) <= 4 + 5*limits['native_files'], 'collector tool event count', MUTATION)
    required_events={('chip_family_only','sysctl'),('app','outer_signature_display'),
                     ('app','outer_signature_verify_strict'),('app','outer_signature_verify_deep_strict')}
    required_events |= {(target,operation) for target in native_targets for operation in COLLECTOR_NATIVE_OPS}
    seen=set(); all_success=True; output_total=0
    for event in tools:
        success, output_bytes = _collector_tool_event(event,limits)
        pair=(event['target'],event['operation'])
        require(pair not in seen and pair in required_events, 'duplicate/unexpected collector tool event')
        seen.add(pair);_collector_result_argv(event,summary['app_path'])
        all_success &= success;output_total+=output_bytes
        if event['target'] in native_targets:
            require(event.get('sha256') == native_targets[event['target']] and event.get('descriptor_bound') is True,
                    'collector native descriptor/hash mismatch')
        else:require('sha256' not in event and 'descriptor_bound' not in event, 'unexpected non-native event binding')
    require(output_total <= limits['tool_output_total_bytes'], 'collector aggregate output bound', MUTATION)
    conditions=[]
    if not summary.get('trusted_tool_availability') or not all(summary['trusted_tool_availability'].values()):
        conditions.append('trusted_tool_availability_incomplete')
    if summary['status']!='collected' or summary['collector_exit_code']!=0:conditions.append('collector_did_not_complete_successfully')
    if seen != required_events:conditions.append('mandatory_tool_event_coverage_incomplete')
    if not all_success:conditions.append('tool_failure_or_incomplete_observation')
    if summary.get('metadata_stable_across_collection') is not True:conditions.append('stable_metadata_not_observed')
    if summary.get('all_tool_invocations_completed') is not True or summary.get('all_tool_returncodes_zero') is not True:
        conditions.append('tool_summary_not_successful')
    if summary.get('runtime_comparison') != comparison or not comparison['matches']:conditions.append('manifest_closure_comparison_failed')
    observed_manifest=summary.get('runtime_manifest',{})
    if (type(observed_manifest) is not dict or observed_manifest.get('bytes') != pins['runtime-manifest.original.json']['bytes']
        or observed_manifest.get('sha256') != pins['runtime-manifest.original.json']['sha256']
        or observed_manifest.get('entries') != len(original['files'])
        or observed_manifest.get('transport_patch') != original.get('transport_patch')
        or observed_manifest.get('components') != original.get('components',[])):
        conditions.append('manifest_summary_identity_mismatch')
    assets=summary.get('speech_assets',{})
    if type(assets) is not dict:raise Rejected('collector speech comparison shape')
    require(set(assets) == {p['path'] for p in context.policy['speech_asset_pins']}, 'collector speech pin coverage')
    for asset in context.policy['speech_asset_pins']:
        observed=assets[asset['path']]; row=runtime_index.get(asset['path'],{})
        expected={'expected_bytes':asset['bytes'],'expected_sha256':asset['sha256'],
                  'actual_bytes':row.get('bytes'),'actual_sha256':row.get('sha256'),
                  'matches':row.get('kind')=='file' and row.get('bytes')==asset['bytes'] and row.get('sha256')==asset['sha256']}
        require(observed == expected and type(observed.get('matches')) is bool, 'collector speech cross-file mismatch')
        if not expected['matches']:conditions.append('speech_asset_mismatch')
    if (summary.get('direct_hashed_bytes') != counts['bytes'] or type(summary.get('direct_hashed_bytes')) is not int
        or summary.get('actual_entries_including_directories') != counts['nodes']
        or type(summary.get('actual_entries_including_directories')) is not int
        or summary.get('native_file_count') != len(native_targets) or type(summary.get('native_file_count')) is not int):
        conditions.append('collector_count_summary_mismatch')
    metadata=summary.get('metadata',{})
    if type(metadata) is not dict:raise Rejected('collector metadata shape')
    seal=metadata.get('Contents/_CodeSignature/CodeResources',{})
    info=metadata.get('Contents/Info.plist',{})
    if (type(seal) is not dict or type(info) is not dict or 'manifest_entries' not in seal
        or seal.get('seal_coverage_conclusion') != 'unreviewed' or type(seal.get('sha256')) is not str
        or SHA.fullmatch(seal['sha256']) is None or type(info.get('selected_fields')) is not dict
        or not info['selected_fields'].get('CFBundleIdentifier')):
        conditions.append('original_app_or_seal_observations_missing')
    return {'kind':'unaccepted_collector_observation','bundle':bundle,'closure':closure,
            'native_inventory':[{'path':name,'sha256':sha} for name,sha in sorted(runtime_native.items())],
            'eligible_for_reviewed_preparation':not conditions,
            'missing_conditions':sorted(set(conditions)),
            'trust_conclusion':'not_established','native_accepted':False}


def copy_collector_v2(source, destination, context, bundle):
    validate_collector_bundle(bundle,context.policy['collector_v2'])
    with Root(source) as src, Root(destination) as dst:
        for name, expected in bundle['artifacts'].items():
            fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=dst.fd)
            try:
                regular_at(src.fd,name,context.budget,expected,output_fd=fd,
                           maximum=context.policy['collector_v2']['artifact_bytes'][name])
                os.fchmod(fd,0o600);os.fsync(fd)
                same_node(os.fstat(fd),os.stat(name,dir_fd=dst.fd,follow_symlinks=False))
            finally:os.close(fd)
        os.fsync(dst.fd);src.check();dst.check()
    read_collector_v2(destination,context,bundle)


class Context:
    """A source tree is a trust root, never an inventory-controlled parameter.

    Tests may construct isolated source trees; production CLI always uses
    SOURCE_ROOT. Integration must use the fixed-root public entry points.
    """
    def __init__(self, source_root=SOURCE_ROOT, phase='prepare'):
        require(phase in ('prepare', 'native'), 'unknown source phase')
        self.phase = phase
        self.source_root = Path(source_root)
        defaults = {'portable_operation_seconds': 600, 'regular_file_bytes': 1_000_000_000}
        self.budget = Budget(defaults)
        self.policy_row, raw = read_path(self.source_root / POLICY_PATH, self.budget)
        self.policy = strict_json(raw)
        keys(self.policy, ('schema_version', 'kind', 'bounds', 'source_bindings', 'phase_source_paths', 'collector_v2',
                          'archive_basis', 'accepted_historical_baselines', 'overlay', 'speech_asset_pins',
                          'required_native_evidence', 'native_finalizer', 'component_roles',
                          'unaccepted_historical_manifest_observation'))
        require(type(self.policy['schema_version']) is int and self.policy['schema_version'] == 1
                and self.policy['kind'] == 'source_owned_runtime_reconstruction_policy', 'wrong policy schema')
        self.bounds = self.policy['bounds']
        required_bounds = {'json_bytes':MAX_JSON,'json_nesting':32,'regular_and_link_entries':100000,
            'all_nodes':200000,'runtime_bytes':5_000_000_000,'regular_file_bytes':1_000_000_000,
            'path_utf8_bytes':4096,'component_utf8_bytes':255,'path_depth':64,'symlink_hops':64,
            'wheel_count':150,'wheel_bytes_each':512_000_000,'wheel_bytes_total':3_000_000_000,
            'native_objects':4096,'native_command_seconds':30,'native_command_output_bytes':2097152,
            'native_static_total_seconds':300,'portable_operation_seconds':600,
            'scratch_reserve_bytes':1_000_000_000}
        keys(self.bounds, tuple(required_bounds) + ('callers_may_raise',))
        for key, maximum in required_bounds.items():
            integer(self.bounds[key], 1, maximum)
        require(self.bounds['callers_may_raise'] is False, 'caller-adjustable bounds forbidden')
        self.budget.bounds = self.bounds
        require(type(self.policy['source_bindings']) is dict, 'source binding map required')
        keys(self.policy['phase_source_paths'], ('prepare', 'native'))
        for names in self.policy['phase_source_paths'].values():
            require(type(names) is list and all(type(n) is str for n in names)
                    and len(names) == len(set(names)), 'source identity list invalid')
        selected = self.policy['phase_source_paths'][phase]
        require(set(self.policy['phase_source_paths']['prepare']) <= set(self.policy['phase_source_paths']['native'])
                and POLICY_PATH in selected and 'scripts/reconstruct_runtime_payload.py' in selected
                and 'scripts/patch_splash_listener.py' in selected
                and 'Resources/Runtime/splash-managed-listener-patch.json' in selected
                and NATIVE_PATH not in selected, 'incomplete/circular source identity')
        require(set(selected) - {POLICY_PATH, 'scripts/reconstruct_runtime_payload.py'} <= set(self.policy['source_bindings']),
                'active source pin missing')
        validate_collector_policy(self.policy['collector_v2'])
        self.sources = {}
        for name in sorted(selected):
            relative(name)
            expected = self.policy['source_bindings'].get(name)
            if expected is not None:
                pin(expected)
            row, _ = read_path(self.source_root / name, self.budget, expected)
            self.sources[name] = {'bytes': row['bytes'], 'sha256': row['sha256']}
        require(self.sources[POLICY_PATH]['sha256'] == digest(raw), 'policy changed while opening', MUTATION)
        _, patch_raw = read_path(self.source_root / 'Resources/Runtime/splash-managed-listener-patch.json', self.budget,
                                self.sources['Resources/Runtime/splash-managed-listener-patch.json'])
        patch_record = strict_json(patch_raw)
        require(patch_record.get('id') == self.policy['overlay']['to_id']
                and patch_record.get('upstream_revision') == self.policy['overlay']['upstream_revision']
                and patch_record.get('files') == [{'path': row['path'], 'upstream_sha256': row['upstream_sha256'],
                     'sha256': row['new_v2_sha256']} for row in self.policy['overlay']['files']],
                'policy/patch-record incongruence')
        require(type(self.policy['accepted_historical_baselines']) is list, 'historical basis list required')
        ids = [b.get('id') for b in self.policy['accepted_historical_baselines']]
        require(all(type(x) is str and x for x in ids) and len(ids) == len(set(ids)), 'duplicate/invalid basis ID')

    @property
    def policy_sha(self):
        return self.sources[POLICY_PATH]['sha256']

    def recheck(self):
        for name, expected in self.sources.items():
            read_path(self.source_root / name, self.budget, expected)

    def basis(self, basis_id):
        if basis_id == self.policy['archive_basis']['id']:
            raise Rejected('ARCHIVE_LAYOUT_UNREVIEWED: ' + self.policy['archive_basis']['reason'], UNSUPPORTED)
        matches = [b for b in self.policy['accepted_historical_baselines'] if b['id'] == basis_id]
        require(len(matches) == 1, 'ACCEPTED_HISTORICAL_BASELINE_REQUIRED', MISSING)
        value = matches[0]
        keys(value, ('id','mode','historical_manifest','collector_bundle','acceptance','closure',
                     'components','bytecode_removals','module_inventory_review','native_inventory'))
        require(value['mode'] == 'reviewed_owner_historical_closure', 'wrong historical basis mode')
        pin(value['historical_manifest'])
        validate_collector_bundle(value['collector_bundle'], self.policy['collector_v2'])
        require(value['historical_manifest'] == value['collector_bundle']['artifacts']['runtime-manifest.original.json'],
                'historical and collector manifest pins differ')
        keys(value['acceptance'], ('scope','decision_id'))
        require(value['acceptance']['scope'] == 'personal_candidate'
                and type(value['acceptance']['decision_id']) is str and value['acceptance']['decision_id'],
                'explicit scoped historical acceptance required')
        keys(value['module_inventory_review'], ('collector_bundle_identity','alternate_module_paths'))
        require(value['module_inventory_review']['collector_bundle_identity'] == digest(canonical(value['collector_bundle']))
                and value['module_inventory_review']['alternate_module_paths'] == [],
                'unreviewed sourceless/frozen/zip alternative modules')
        closure_index = validate_rows(value['closure'], self.bounds)
        for asset in self.policy['speech_asset_pins']:
            keys(asset, ('path','bytes','sha256'))
            entry = closure_index.get(asset['path'], {})
            require(entry.get('kind') == 'file' and entry.get('bytes') == asset['bytes']
                    and entry.get('sha256') == asset['sha256'], 'pinned neural asset missing or changed')
        require(type(value['native_inventory']) is list, 'reviewed native inventory required')
        self.components(value['components'], value['closure'])
        self.expected_prepared(value)  # validates the complete exact transform allowlist
        return value

    def expected_prepared(self, basis):
        rows = {row['path']: dict(row) for row in basis['closure']}
        transforms = []
        overlay = self.policy['overlay']
        for item in overlay['files']:
            old = rows.get(item['path'])
            require(old is not None and old['kind'] == 'file'
                    and old['sha256'] == item['old_v1_sha256'], 'exact old v1 bytes required')
            # New length is independently determined from pinned upstream by the existing patcher;
            # status obtains it from the preserved admitted upstream sources, never stage-state.
            transforms.append({'path': item['path'], 'before_sha256': item['old_v1_sha256'],
                               'after_sha256': item['new_v2_sha256'], 'operation':'replace_source'})
        require(type(basis['bytecode_removals']) is list, 'exact bytecode removal list required')
        removed = set()
        modules = [item['path'][:-3] for item in overlay['files']]
        cache_directories = {folded(module.rpartition('/')[0] + '/__pycache__') for module in modules}
        for row in rows.values():
            require(not (folded(row['path']) in cache_directories and row['kind'] == 'symlink'),
                    'affected-module cache directory symlink forbidden')
        for item in basis['bytecode_removals']:
            keys(item, ('path','bytes','sha256'))
            name = relative(item['path'])
            allowed = False
            for module in modules:
                directory, _, stem = module.rpartition('/')
                allowed |= (name == module + '.pyc' or bool(re.fullmatch(
                    re.escape(directory + '/__pycache__/' + stem) + r'\.cpython-[0-9]+(?:\.opt-[12])?\.pyc', name)))
            require(allowed and name not in removed, 'unapproved/duplicate bytecode removal')
            old = rows.get(name)
            require(old is not None and old['kind'] == 'file'
                    and old['bytes'] == item['bytes'] and old['sha256'] == item['sha256'],
                    'bytecode baseline mismatch')
            removed.add(name)
            transforms.append({'path':name,'before_sha256':item['sha256'],'operation':'remove_bytecode'})
            del rows[name]
        for name in rows:
            for module in modules:
                directory, _, stem = module.rpartition('/')
                affected = folded(name) == folded(module + '.pyc') or bool(re.fullmatch(
                    re.escape(folded(directory + '/__pycache__/' + stem)) + r'(?:\.[^/]+)?\.pyc', folded(name)))
                require(not affected, 'unlisted affected bytecode survives overlay')
        return rows, sorted(transforms, key=lambda r:r['path'].encode('utf-8'))

    def components(self, components, rows):
        index = validate_rows(rows, self.bounds)
        require(type(components) is list and len(components) == 3, 'three components required')
        roles, owned = set(), set()
        for component in components:
            keys(component, ('role','license','license_paths','files'))
            require(component['role'] in self.policy['component_roles'] and component['role'] not in roles,
                    'unknown/duplicate component role')
            roles.add(component['role'])
            require(type(component['license']) is str and component['license'], 'license attribution required')
            require(type(component['files']) is list and component['files'], 'component file list required')
            require(type(component['license_paths']) is list and component['license_paths'], 'license paths required')
            for name in component['files']:
                require(name in index and name != '.' and name not in owned, 'duplicate/missing component ownership')
                owned.add(name)
            for name in component['license_paths']:
                require(index.get(name, {}).get('kind') == 'file' and index[name]['bytes'] > 0,
                        'nonempty hashed notice required')
        require(owned == set(index) - {'.'}, 'unmapped payload entries')
        return components


def validate_inventory(raw):
    value = strict_json(raw)
    keys(value, ('schema_version','locations'))
    require(type(value['schema_version']) is int and value['schema_version'] == 1, 'inventory version')
    keys(value['locations'], ('runtime','collector_report','upstream'))
    for location in value['locations'].values():
        require(type(location) is str and os.path.isabs(location), 'absolute locator required')
    return value['locations']


class _PinnedOverlayPath:
    """Minimal read-only adapter for the existing patcher's Path dependency.

    The patcher sees only bytes already read and hashed through bounded descriptors;
    its legacy read_bytes call must not reopen a mutable input pathname.
    """
    def __init__(self, sources, name=''):
        self.sources, self.name = sources, name

    def __truediv__(self, name):
        return _PinnedOverlayPath(self.sources, (self.name + '/' if self.name else '') + name)

    def is_symlink(self):
        return False

    def is_file(self):
        return self.name in self.sources

    def read_bytes(self):
        require(self.name in self.sources, 'patcher requested an unowned source path')
        return self.sources[self.name]


def overlay_bytes(context, upstream):
    """Execute the existing pinned source-owned patcher on admitted in-memory bytes."""
    sources = {}
    with Root(upstream) as cap:
        for item in context.policy['overlay']['files']:
            name = item['path'].removeprefix('Splash/')
            _, sources[name] = regular_at(cap.fd, name, context.budget,
                {'sha256':item['upstream_sha256']}, collect=True, maximum=MAX_JSON)
        cap.check()
    _, patcher = read_path(context.source_root / 'scripts/patch_splash_listener.py', context.budget,
                          context.sources['scripts/patch_splash_listener.py'])
    namespace = {'__name__':'_source_owned_splash_overlay', '__file__':str(context.source_root / 'scripts/patch_splash_listener.py')}
    exec(compile(patcher, namespace['__file__'], 'exec'), namespace)
    namespace['Path'] = lambda _: _PinnedOverlayPath(sources)
    result = namespace['overlay'](upstream)
    require(set(result) == {x['path'].removeprefix('Splash/') for x in context.policy['overlay']['files']},
            'patcher changed source ownership')
    output = {}
    for item in context.policy['overlay']['files']:
        raw = result[item['path'].removeprefix('Splash/')].encode('utf-8')
        require(digest(raw) == item['new_v2_sha256'], 'patcher output mismatch')
        output[item['path']] = raw
    return output


def prepared_rows(context, basis, upstream):
    rows, delta = context.expected_prepared(basis)
    outputs = overlay_bytes(context, upstream)
    for name, data in outputs.items():
        rows[name].update(bytes=len(data), sha256=digest(data))
    result = sorted(rows.values(), key=lambda r:r['path'].encode('utf-8'))
    validate_rows(result, context.bounds)
    return result, delta, outputs


def checkpoint(context, basis, rows, delta):
    return {'schema_version':1,'kind':'runtime_reconstruction_prepared',
            'basis_id':basis['id'],'basis_identity':digest(canonical(basis)),
            'trust_basis':basis['mode'],'policy_sha256':context.policy_sha,
            'source_identities':context.sources,'closure_sha256':digest(canonical(rows)),
            'delta':delta,'native_accepted':False}


def _prepare(context, basis_id, inputs, stage):
    basis = context.basis(basis_id)
    _, raw = read_path(inputs, context.budget)
    locations = validate_inventory(raw)
    stage = Path(os.path.abspath(stage))
    disjoint(stage, [context.source_root, inputs, *locations.values()])
    relative(stage.name)
    with Root(stage.parent) as parent:
        require(not os.path.lexists(stage), 'fresh stage required')
        reject_descriptor_overlap(parent, [context.source_root, locations['runtime'], locations['upstream'], locations['collector_report']],
                                  context.budget)
        # Admission precedes any writes. Historical labels are never trusted.
        with Root(locations['runtime']) as source:
            _, historical = regular_at(source.fd, MANIFEST, context.budget, basis['historical_manifest'], True,
                                       maximum=MAX_JSON)
            source.check()
        observed = read_collector_v2(locations['collector_report'], context, basis['collector_bundle'])
        require(observed['eligible_for_reviewed_preparation'], 'collector observations ineligible: ' + ','.join(observed['missing_conditions']))
        require(observed['closure'] == basis['closure'] and observed['native_inventory'] == basis['native_inventory'],
                'collector/baseline closure or native inventory mismatch')
        before = tree(locations['runtime'], context.budget, basis['historical_manifest'])
        require(before == basis['closure'], 'historical full closure mismatch')
        expected, delta, outputs = prepared_rows(context, basis, locations['upstream'])
        temporary = '.' + stage.name + '.reconstruct-' + uuid.uuid4().hex
        os.mkdir(temporary, 0o700, dir_fd=parent.fd)
        transaction = stage.parent / temporary
        created = os.stat(temporary, dir_fd=parent.fd, follow_symlinks=False)
        transaction_fd = os.open(temporary, DIR_FLAGS, dir_fd=parent.fd)
        same_node(created, os.fstat(transaction_fd))
        owned = directory_identity(os.fstat(transaction_fd))
        try:
            for name in ('payload','inputs','evidence','work'):
                os.mkdir(name, 0o700, dir_fd=transaction_fd)
            copy_tree(locations['runtime'], transaction / 'payload', before, context.budget)
            with Root(transaction / 'inputs') as source_inputs:
                os.mkdir('upstream', 0o700, dir_fd=source_inputs.fd)
            with Root(transaction / 'inputs/upstream') as retained:
                for folder in ('install','server'):
                    os.mkdir(folder, 0o700, dir_fd=retained.fd)
                with Root(locations['upstream']) as upstream:
                    for item in context.policy['overlay']['files']:
                        name = item['path'].removeprefix('Splash/')
                        _, data = regular_at(upstream.fd, name, context.budget,
                                             {'sha256':item['upstream_sha256']}, True, maximum=MAX_JSON)
                        write_new(retained.fd, name, data)
                    upstream.check()
            # Compare patch output obtained from retained immutable inputs as well.
            require(overlay_bytes(context, transaction / 'inputs/upstream') == outputs,
                    'upstream changed during preparation', MUTATION)
            with Root(transaction / 'payload') as payload:
                for item in delta:
                    name = item['path']
                    regular_at(payload.fd, name, context.budget, {'sha256':item['before_sha256']})
                    with parent_at(payload.fd, name) as (fd, leaf):
                        # A copied baseline can legitimately have read-only directories.
                        # Grant owner-write only to this private transform parent, then
                        # restore its exact baseline mode before any checkpoint/closure.
                        parent_name = name.rpartition('/')[0] or '.'
                        parent_mode = next(row['mode'] for row in before if row['path'] == parent_name)
                        require(stat.S_IMODE(os.fstat(fd).st_mode) == parent_mode,
                                'transform parent mode changed', MUTATION)
                        changed_mode = not parent_mode & 0o200
                        if changed_mode:
                            os.fchmod(fd, parent_mode | 0o200)
                        try:
                            os.unlink(leaf, dir_fd=fd)
                            os.fsync(fd)
                            if item['operation'] == 'replace_source':
                                mode = next(row['mode'] for row in before if row['path'] == name)
                                write_new(payload.fd, name, outputs[name], mode)
                        finally:
                            if changed_mode:
                                os.fchmod(fd, parent_mode)
                            os.fsync(fd)
                payload.check()
            with Root(transaction / 'evidence') as evidence:
                write_new(evidence.fd, 'historical-manifest.json', historical)
                os.mkdir('collector', 0o700, dir_fd=evidence.fd)
                copy_collector_v2(locations['collector_report'], transaction / 'evidence/collector', context, basis['collector_bundle'])
                write_new(evidence.fd, 'delta.json', canonical(delta))
            require(tree(transaction / 'payload', context.budget) == expected, 'unexpected preparation delta', MUTATION)
            require(tree(locations['runtime'], context.budget, basis['historical_manifest']) == before,
                    'original runtime changed', MUTATION)
            context.recheck()
            state = checkpoint(context, basis, expected, delta)
            write_new(transaction_fd, 'stage-state.json', canonical(state))
            require(directory_identity(os.stat(temporary, dir_fd=parent.fd, follow_symlinks=False)) == owned
                    and directory_identity(os.fstat(transaction_fd)) == owned,
                    'transaction directory replaced', MUTATION)
            os.fsync(transaction_fd)
            parent.check()
            no_replace(parent.fd, temporary, stage.name)
            require(directory_identity(os.stat(stage.name, dir_fd=parent.fd, follow_symlinks=False)) == owned,
                    'published stage replaced', MUTATION)
            parent.check()
            return state
        except BaseException as exc:
            # Never recursively clean a path potentially exchanged by another writer.
            # Retained hidden transactions are explicitly unaccepted; inputs stay intact.
            if isinstance(exc, Rejected):
                exc.args = (str(exc) + '; unaccepted transaction retained at ' + str(transaction),)
            raise
        finally:
            os.close(transaction_fd)


def prepare(basis_id, inputs, stage):
    return _prepare(Context(), basis_id, inputs, stage)


def _status(context, stage):
    stage = Path(os.path.abspath(stage))
    disjoint(stage, [context.source_root])
    with Root(stage) as root:
        info = os.fstat(root.fd)
        require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
                'private owned stage required')
        names = set(names_at(root.fd, 5, context.budget))
        require(names == {'payload','inputs','evidence','work','stage-state.json'}, 'unexpected stage entries')
        _, raw = regular_at(root.fd, 'stage-state.json', context.budget, collect=True, maximum=MAX_JSON)
        state = strict_json(raw)
        keys(state, ('schema_version','kind','basis_id','basis_identity','trust_basis','policy_sha256',
                     'source_identities','closure_sha256','delta','native_accepted'))
        require(type(state['schema_version']) is int and state['schema_version'] == 1
                and state['native_accepted'] is False and state['kind'] == 'runtime_reconstruction_prepared',
                'prepared checkpoint schema')
        basis = context.basis(state['basis_id'])
        regular_at(root.fd, 'evidence/historical-manifest.json', context.budget, basis['historical_manifest'])
        observed = read_collector_v2(stage / 'evidence/collector', context, basis['collector_bundle'])
        require(observed['eligible_for_reviewed_preparation'] and observed['closure'] == basis['closure']
                and observed['native_inventory'] == basis['native_inventory'], 'retained collector observation mismatch')
        expected, delta, _ = prepared_rows(context, basis, stage / 'inputs/upstream')
        require(tree(stage / 'payload', context.budget) == expected, 'prepared payload changed')
        _, delta_raw = regular_at(root.fd, 'evidence/delta.json', context.budget, collect=True, maximum=MAX_JSON)
        require(delta_raw == canonical(delta), 'delta evidence changed')
        require(state == checkpoint(context, basis, expected, delta), 'checkpoint mismatch; journal is not authority')
        # No unaccounted cache/work/install output may be resumed.
        for folder, expected_names in [('evidence', {'historical-manifest.json','collector','delta.json'}),
                                       ('inputs', {'upstream'}), ('work', set())]:
            with parent_at(root.fd, folder + '/_unused') as (fd, _):
                require(set(names_at(fd, len(expected_names), context.budget)) == expected_names, 'unexpected stage evidence/work input')
        upstream = tree(stage / 'inputs/upstream', context.budget)
        allowed = {'.','install','server'} | {x['path'].removeprefix('Splash/') for x in context.policy['overlay']['files']}
        require({r['path'] for r in upstream} == allowed, 'unrecognized upstream inputs')
        context.recheck(); root.check()
    return {'kind':'runtime_reconstruction_status','state':'prepared_only','basis_id':basis['id'],
            'closure_sha256':state['closure_sha256'],'native_accepted':False,
            'missing_gates':list(context.policy['required_native_evidence']) + ['independently_reviewed_native_build_record',
                                'implemented_and_reviewed_native_finalizer','builder_and_auditor_integration']}


def status(stage):
    return _status(Context(), stage)


def verify_native_contract(context, basis, final_rows, evidence_dir):
    """Validate a future independently reviewed native record, never bless pass JSON.

    This interface is structural admission only. It does not perform native
    verification, write manifests, or return an accepted-runtime success kind.
    """
    require(context.phase == 'native', 'native source phase required')
    path = context.source_root / NATIVE_PATH
    require(path.exists(), 'SOURCE_OWNED_NATIVE_BUILD_RECORD_REQUIRED', MISSING)
    _, raw = read_path(path, context.budget)
    record = strict_json(raw)
    keys(record, ('schema_version','kind','basis_id','basis_identity','policy_sha256','source_identities',
                  'final_closure','final_signed_closure_sha256','receipts','review_decision'))
    require(type(record['schema_version']) is int and record['schema_version'] == 1
            and record['kind'] == 'runtime_native_build_approval', 'native approval schema')
    validate_rows(final_rows, context.bounds)
    closure = digest(canonical(final_rows))
    bindings = {'basis_identity':digest(canonical(basis)), 'policy_sha256':context.policy_sha,
                'source_identities':context.sources, 'final_signed_closure_sha256':closure}
    require(record['basis_id'] == basis['id'] and record['final_closure'] == final_rows
            and all(record[k] == v for k,v in bindings.items()), 'native approval source/closure mismatch')
    require(type(record['review_decision']) is str and record['review_decision'], 'independent native decision missing')
    receipts = record['receipts']
    require(type(receipts) is list and len(receipts) == len(context.policy['required_native_evidence']),
            'all native receipts required')
    gates, paths = set(), set()
    with Root(evidence_dir) as evidence:
        for entry in receipts:
            keys(entry, ('gate','path','bytes','sha256'))
            require(entry['gate'] in context.policy['required_native_evidence'] and entry['gate'] not in gates,
                    'unknown/duplicate native gate')
            relative(entry['path']); require(entry['path'] not in paths, 'duplicate receipt path')
            gates.add(entry['gate']); paths.add(entry['path'])
            _, receipt_raw = regular_at(evidence.fd, entry['path'], context.budget,
                    pin({'bytes':entry['bytes'],'sha256':entry['sha256']}), True, maximum=MAX_JSON)
            receipt = strict_json(receipt_raw)
            keys(receipt, ('schema_version','kind','gate','bindings','outcome','argv','environment_policy_sha256',
                          'host','started','ended','outputs','before_closure_sha256','after_closure_sha256','observations'))
            require(type(receipt['schema_version']) is int and receipt['schema_version'] == 1
                    and receipt['kind'] == 'observed_native_runtime_gate' and receipt['gate'] == entry['gate'],
                    'native receipt schema/gate')
            require(receipt['bindings'] == bindings and receipt['before_closure_sha256'] == closure
                    and receipt['after_closure_sha256'] == closure, 'native receipt binding mismatch')
            require(receipt['outcome'] == {'kind':'exited','exit_status':0}
                    and type(receipt['outcome']['exit_status']) is int,
                    'timeout/signal/launch-error/unrun is not success')
            keys(receipt['host'], ('os','os_version','sdk','architecture','chip'))
            require(receipt['host']['os'] == 'macOS' and receipt['host']['architecture'] == 'arm64'
                    and all(type(v) is str and v for v in receipt['host'].values()), 'native host facts missing')
            require(type(receipt['argv']) is list and receipt['argv']
                    and all(type(v) is str and v for v in receipt['argv']), 'actual argv required')
            require(type(receipt['environment_policy_sha256']) is str
                    and SHA.fullmatch(receipt['environment_policy_sha256']), 'environment policy identity missing')
            require(type(receipt['started']) is str and receipt['started'] and type(receipt['ended']) is str
                    and receipt['ended'], 'start/end observations missing')
            require(type(receipt['observations']) is dict and receipt['observations'], 'raw observations missing')
            require(type(receipt['outputs']) is list and receipt['outputs'], 'raw outputs required')
            for output in receipt['outputs']:
                keys(output, ('path','bytes','sha256'))
                relative(output['path'])
                regular_at(evidence.fd, output['path'], context.budget,
                           pin({'bytes':output['bytes'],'sha256':output['sha256']}),
                           maximum=context.bounds['native_command_output_bytes'])
        evidence.check()
    context.recheck()
    return {'kind':'native_contract_structurally_bound_not_accepted','record_sha256':digest(raw),
            'closure_sha256':closure}


def finalize(stage, evidence_dir):
    if sys.platform != 'darwin':
        raise Rejected('NATIVE_REQUIRED: finalization requires actual macOS verification', UNSUPPORTED)
    context = Context()
    _status(context, stage)
    require((context.source_root / NATIVE_PATH).exists(), 'SOURCE_OWNED_NATIVE_BUILD_RECORD_REQUIRED', MISSING)
    # Source-owned acceptance cannot substitute for a verified native implementation.
    # There is deliberately no supported=true bypass or portable platform switch.
    raise Rejected('NATIVE_FINALIZER_NOT_IMPLEMENTED: reviewed native verification and atomic acceptance commit required',
                   UNSUPPORTED)


def audit_accepted_payload(payload):
    context = Context()
    require((context.source_root / NATIVE_PATH).exists(), 'SOURCE_OWNED_NATIVE_BUILD_RECORD_REQUIRED', MISSING)
    raise Rejected('NATIVE_ADMISSION_NOT_IMPLEMENTED: a manifest or pass flag is not acceptance', UNSUPPORTED)


def copy(payload, destination):
    disjoint(destination, [payload, SOURCE_ROOT])
    require(not os.path.lexists(destination), 'fresh copy destination required')
    audit_accepted_payload(payload)
    # This code is intentionally unreachable until accepted admission is implemented.
    raise Rejected('ACCEPTED_COPY_NOT_IMPLEMENTED: no approved payload can currently be copied', UNSUPPORTED)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest='command', required=True)
    cmd = commands.add_parser('prepare', allow_abbrev=False)
    cmd.add_argument('--basis-id', required=True); cmd.add_argument('--inputs', required=True)
    cmd.add_argument('--stage', required=True)
    cmd = commands.add_parser('status', allow_abbrev=False); cmd.add_argument('--stage', required=True)
    cmd = commands.add_parser('finalize', allow_abbrev=False)
    cmd.add_argument('--stage', required=True); cmd.add_argument('--evidence-dir', required=True)
    cmd = commands.add_parser('copy', allow_abbrev=False)
    cmd.add_argument('--payload', required=True); cmd.add_argument('--destination', required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'prepare':
            result = prepare(args.basis_id, args.inputs, args.stage)
        elif args.command == 'status':
            result = status(args.stage)
        elif args.command == 'finalize':
            result = finalize(args.stage, args.evidence_dir)
        else:
            result = copy(args.payload, args.destination)
        sys.stdout.buffer.write(canonical(result))
        return 0
    except Rejected as exc:
        sys.stderr.write(str(exc) + '\n')
        return exc.code
    except (OSError, UnicodeError, RecursionError) as exc:
        sys.stderr.write('FILESYSTEM_OR_RESOURCE_FAILURE: ' + str(exc) + '\n')
        return MUTATION
    except KeyboardInterrupt:
        sys.stderr.write('CANCELLED: no acceptance committed\n')
        return MUTATION


if __name__ == '__main__':
    sys.exit(main())
