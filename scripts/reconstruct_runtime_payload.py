#!/usr/bin/env python3
"""Bounded offline runtime preparation. Prepared bytes are never native approval.

The production CLI has no policy/source/digest override. Historical bases and
native approval must already be independently reviewed in the source-owned trust
root. Finalization runs only fixed bounded Darwin static inspection; retained
source-bound native probes supply dynamic evidence. No candidate code is run by
this command. Unavailable genuine inputs/capabilities and archive/copy reject.
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
                parent = self.fds[-1]
                fd = os.open(part, DIR_FLAGS, dir_fd=parent)
                self.fds.append(fd)  # own cleanup before any post-open rejection
                require(directory_identity(before) == directory_identity(os.fstat(fd)),
                        'directory capability changed during acquisition', MUTATION)
                self.edges.append((parent, part, fd, directory_identity(before)))
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
            fds.append(child)  # own cleanup before any post-open rejection
            require(directory_identity(before) == directory_identity(os.fstat(child)),
                    'parent capability changed during acquisition', MUTATION)
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


def no_replace(parent_fd, source, destination, destination_parent_fd=None):
    """Atomic file/directory publication; never check-then-rename replacement."""
    if destination_parent_fd is None:
        destination_parent_fd = parent_fd
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'linux' and hasattr(library, 'renameat2'):
        function = library.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(parent_fd, source.encode(), destination_parent_fd, destination.encode(), 1)
    elif sys.platform == 'darwin' and hasattr(library, 'renameatx_np'):
        function = library.renameatx_np
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(parent_fd, source.encode(), destination_parent_fd, destination.encode(), 4)
    else:
        raise Rejected('atomic no-replace publication unavailable', UNSUPPORTED)
    if result != 0:
        error = ctypes.get_errno()
        raise Rejected('atomic publication refused: ' + os.strerror(error),
                       INVALID if error in (errno.EEXIST, errno.ENOTEMPTY) else MUTATION)
    os.fsync(parent_fd)
    if destination_parent_fd != parent_fd:
        os.fsync(destination_parent_fd)


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
        require(NATIVE_PATH not in self.policy['source_bindings'], 'native approval cannot enter source bindings')
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


def prepare_sources(context):
    """Project a native Context onto the original preparation trust boundary."""
    names = context.policy['phase_source_paths']['prepare']
    require(set(names) <= set(context.sources), 'prepare source identities missing')
    return {name: context.sources[name] for name in sorted(names)}


def checkpoint(context, basis, rows, delta):
    return {'schema_version':1,'kind':'runtime_reconstruction_prepared',
            'basis_id':basis['id'],'basis_identity':digest(canonical(basis)),
            'trust_basis':basis['mode'],'policy_sha256':context.policy_sha,
            'source_identities':prepare_sources(context),'closure_sha256':digest(canonical(rows)),
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


def _read_prepared_basis(context, root):
    """Reconstruct preparation from retained, independently pinned inputs only.

    This intentionally does not bless the current payload. Prepared status must
    compare it separately; native admission must account for every exact delta.
    """
    stage = root.path
    info = os.fstat(root.fd)
    require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
            'private owned stage required')
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
    _, delta_raw = regular_at(root.fd, 'evidence/delta.json', context.budget, collect=True, maximum=MAX_JSON)
    require(delta_raw == canonical(delta), 'delta evidence changed')
    require(state == checkpoint(context, basis, expected, delta), 'checkpoint mismatch; journal is not authority')
    for folder, expected_names in [('evidence', {'historical-manifest.json','collector','delta.json'}),
                                   ('inputs', {'upstream'})]:
        with parent_at(root.fd, folder + '/_unused') as (fd, _):
            require(set(names_at(fd, len(expected_names), context.budget)) == expected_names,
                    'unexpected retained preparation input')
    upstream = tree(stage / 'inputs/upstream', context.budget)
    allowed = {'.','install','server'} | {x['path'].removeprefix('Splash/') for x in context.policy['overlay']['files']}
    require({r['path'] for r in upstream} == allowed, 'unrecognized upstream inputs')
    context.recheck(); root.check()
    return basis, state, expected


def _status(context, stage):
    stage = Path(os.path.abspath(stage))
    disjoint(stage, [context.source_root])
    with Root(stage) as root:
        require(set(names_at(root.fd, 5, context.budget)) ==
                {'payload','inputs','evidence','work','stage-state.json'}, 'unexpected stage entries')
        basis, state, expected = _read_prepared_basis(context, root)
        require(tree(stage / 'payload', context.budget) == expected, 'prepared payload changed')
        with parent_at(root.fd, 'work/_unused') as (fd, _):
            require(not names_at(fd, 0, context.budget), 'unexpected stage work input')
        context.recheck(); root.check()
    return {'kind':'runtime_reconstruction_status','state':'prepared_only','basis_id':basis['id'],
            'closure_sha256':state['closure_sha256'],'native_accepted':False,
            'missing_gates':list(context.policy['required_native_evidence']) + ['independently_reviewed_native_build_record',
                                'genuine_native_harnesses_and_capabilities','builder_and_auditor_integration']}


def status(stage):
    return _status(Context(), stage)


# Native format v2 has explicit identity domains. These pure helpers neither
# execute a native command nor grant approval or write a runtime manifest.
NATIVE_REQUIRED_FILES = {
    'splash_runtime': ('Splash/python/bin/python3', 'Splash/install/launcher.py',
                       'Splash/engine/splash', 'Splash/engine/splash.metallib'),
    'speech_synthesis': ('Voice/python/bin/python3', 'Voice/model/config.json',
                         'Voice/model/kokoro-v1_0.pth', 'Voice/model/voices/bf_isabella.pt'),
    'speech_recognition': ('STT/ggml-base.en.bin',),
}
NATIVE_TRANSFORMS = frozenset(('resign_macho', 'rewrite_macho_load_commands',
                             'write_bundle_code_resources', 'create_signature_directory'))


def native_canonical(value):
    raw = canonical(value)
    require(len(raw) <= MAX_JSON, 'native canonical identity/manifest byte bound', MUTATION)
    return raw


def prepared_identity(context, basis, rows):
    validate_rows(rows, context.bounds)
    return digest(native_canonical({'kind':'runtime_pre_sign_closure_v1',
        'basis_identity':digest(native_canonical(basis)), 'policy_sha256':context.policy_sha,
        'prepare_source_identities':prepare_sources(context), 'closure':rows}))


def signed_identity(context, rows):
    validate_rows(rows, context.bounds)
    require(rows == sorted(rows, key=lambda r:r['path'].encode('utf-8')), 'unsorted signed closure')
    return digest(native_canonical({'kind':'runtime_final_signed_closure_v1', 'closure':rows}))


def _validate_native_transforms(context, basis, before_rows, after_rows, transforms,
                                native_paths, code_bundles, final_components):
    """Require a complete exact signing diff, not a filename-pattern exemption.

    native_paths and code_bundles are independently approved inventory selections;
    the later native verifier must prove them against actual bounded descriptors.
    This function alone does not establish Mach-O/signature or native approval.
    """
    before = validate_rows(before_rows, context.bounds)
    after = validate_rows(after_rows, context.bounds)
    require(type(native_paths) is list and len(native_paths) <= context.bounds['native_objects']
            and all(type(n) is str for n in native_paths) and len(set(native_paths)) == len(native_paths),
            'exact native path inventory required')
    require(type(code_bundles) is list and len(code_bundles) <= context.bounds['native_objects']
            and all(type(n) is str for n in code_bundles) and len(set(code_bundles)) == len(code_bundles),
            'exact code bundle inventory required')
    for name in native_paths:
        relative(name)
        require(before.get(name, {}).get('kind') == 'file' and after.get(name, {}).get('kind') == 'file',
                'native signing path must preserve a regular file')
    for name in code_bundles:
        relative(name)
        require(before.get(name, {}).get('kind') == 'directory' and after.get(name, {}).get('kind') == 'directory',
                'code bundle must preserve a physical directory')
    changed = sorted((name for name in set(before) | set(after) if before.get(name) != after.get(name)),
                     key=lambda n:n.encode('utf-8'))
    require(type(transforms) is list and len(transforms) == len(changed), 'incomplete native transformation list')
    context.components(basis['components'], basis['closure'])
    owners = {name:c['role'] for c in basis['components'] for name in c['files'] if name in before}
    signature_dirs = {name+'/_CodeSignature':name for name in code_bundles}
    seals = {name+'/_CodeSignature/CodeResources':name for name in code_bundles}
    for name, entry in zip(changed, transforms):
        keys(entry, ('path','before','after','operation','reason'))
        require(entry['path'] == name and native_canonical(entry['before']) == native_canonical(before.get(name))
                and native_canonical(entry['after']) == native_canonical(after.get(name)),
                'native transformation exact row mismatch')
        operation = entry['operation']
        require(type(operation) is str and operation in NATIVE_TRANSFORMS, 'unreviewed native transformation')
        require(type(entry['reason']) is str and 0 < len(entry['reason'].encode('utf-8')) <= 4096,
                'bounded explicit native transformation reason required')
        old, new = entry['before'], entry['after']
        if operation in ('resign_macho', 'rewrite_macho_load_commands'):
            require(name in native_paths and old is not None and new is not None
                    and old['kind'] == new['kind'] == 'file' and old['mode'] == new['mode'],
                    'native signing must preserve path/type/mode')
        elif operation == 'write_bundle_code_resources':
            require(name in seals and new is not None and new['kind'] == 'file' and new['bytes'] > 0
                    and (old is None or old['kind'] == 'file' and old['mode'] == new['mode']),
                    'exact bundle CodeResources delta required')
            owners[name] = owners[seals[name]]
        else:
            require(name in signature_dirs and old is None and new is not None and new['kind'] == 'directory',
                    'only exact new signature directory permitted')
            require(seals.get(name+'/CodeResources') == signature_dirs[name]
                    and name+'/CodeResources' in changed, 'unpaired signature directory')
            owners[name] = owners[signature_dirs[name]]
    require(set(owners) == set(after) - {'.'}, 'native delta changed unmapped paths')
    expected_components = []
    for component in basis['components']:
        expected_components.append({**component,
            'files':sorted((name for name,role in owners.items() if role == component['role']), key=lambda n:n.encode('utf-8'))})
    expected_components.sort(key=lambda c:c['role'])
    require(final_components == expected_components, 'final component ownership/attribution changed')
    context.components(final_components, after_rows)
    return final_components


def _final_manifest_bytes(context, final_rows, verified_facts):
    """Serialize already-admitted facts; it does not perform or grant admission."""
    require(context.phase == 'native', 'native source phase required for manifest')
    index = validate_rows(final_rows, context.bounds)
    keys(verified_facts, ('approval_sha256','prepared_identity','signed_identity','evidence_identity',
                          'components','gates'))
    for key in ('approval_sha256','prepared_identity','signed_identity','evidence_identity'):
        require(type(verified_facts[key]) is str and SHA.fullmatch(verified_facts[key]), 'native admission identity required')
    require(verified_facts['signed_identity'] == signed_identity(context, final_rows), 'signed identity mismatch')
    require(verified_facts['gates'] == sorted(context.policy['required_native_evidence']), 'all admitted native gates required')
    components = context.components(verified_facts['components'], final_rows)
    owners = {name:c['role'] for c in components for name in c['files']}
    def resolved(name):
        parts, result, hops = name.split('/'), [], 0
        while parts:
            item, parts = parts[0], parts[1:]
            if item in ('', '.'):
                continue
            if item == '..':
                require(result, 'escaping required input'); result.pop(); continue
            result.append(item); current='/'.join(result)
            require(current in index, 'missing required input')
            row = index[current]
            if row['kind'] == 'symlink':
                hops += 1; require(hops <= context.bounds['symlink_hops'], 'required input link bound')
                result.pop(); parts = row['target'].split('/') + parts
        return '/'.join(result)
    for role, names in NATIVE_REQUIRED_FILES.items():
        for name in names:
            target = resolved(name)
            require(owners.get(name) == role and owners.get(target) == role and index[target]['kind'] == 'file'
                    and index[target]['bytes'] > 0, 'required component input not hash-covered')
    for entry in context.policy['speech_asset_pins']:
        row = index.get(entry['path'], {})
        require(row.get('kind') == 'file' and row.get('bytes') == entry['bytes']
                and row.get('sha256') == entry['sha256'], 'native manifest speech pin mismatch')
    for entry in context.policy['overlay']['files']:
        require(index.get(entry['path'], {}).get('sha256') == entry['new_v2_sha256'], 'native manifest v2 overlay mismatch')
    files = [{key:value for key,value in row.items() if key != 'mode'}
             for row in final_rows if row['kind'] != 'directory']
    projected = [{**c, 'files':[name for name in c['files'] if index[name]['kind'] != 'directory']}
                 for c in sorted(components, key=lambda c:c['role'])]
    for component in projected:
        component['files'].sort(key=lambda name:name.encode('utf-8'))
        component['license_paths'] = sorted(component['license_paths'], key=lambda name:name.encode('utf-8'))
    result = {'schema_version':1, 'kind':'verified_runtime_payload', 'files':files, 'components':projected,
              'transport_patch':context.policy['overlay']['to_id'],
              'import_probe':{'status':'passed_offline','kokoro':'0.9.4','misaki':'0.9.4'},
              'dependency_lock_complete':True,
              'native_admission':{key:verified_facts[key] for key in ('approval_sha256','prepared_identity','signed_identity','evidence_identity')}}
    result['native_admission'].update(policy_sha256=context.policy_sha, source_identities=context.sources)
    return native_canonical(result)


NATIVE_ARTIFACT_LIMITS = {'receipt':MAX_JSON, 'stdout':2_097_152, 'stderr':2_097_152,
                          'canonical_facts':MAX_JSON, 'wav':3_000_000}
NATIVE_ARTIFACT_TOTAL = 120_000_000


def _native_artifact_index(entries):
    require(type(entries) is list and 1 <= len(entries) <= 100_000, 'native artifact count bound', MUTATION)
    index, aliases, total, path_bytes = {}, set(), 0, 0
    for entry in entries:
        keys(entry, ('path','kind','bytes','sha256'))
        name = relative(entry['path']); kind = entry['kind']
        require(type(kind) is str and kind in NATIVE_ARTIFACT_LIMITS, 'unknown native artifact kind')
        integer(entry['bytes'], 0 if kind in ('stdout','stderr') else 1, NATIVE_ARTIFACT_LIMITS[kind])
        pin({'bytes':entry['bytes'],'sha256':entry['sha256']})
        require(name not in index and folded(name) not in aliases, 'duplicate/aliased native artifact')
        index[name] = entry; aliases.add(folded(name)); total += entry['bytes']; path_bytes += len(name.encode('utf-8'))
        require(total <= NATIVE_ARTIFACT_TOTAL and path_bytes <= 16_000_000, 'native evidence aggregate bound', MUTATION)
    require(list(index) == sorted(index, key=lambda name:name.encode('utf-8')), 'unsorted native artifacts')
    for name in index:
        parts = name.split('/')
        for end in range(1,len(parts)):
            require('/'.join(parts[:end]) not in index, 'native file/directory artifact collision')
    return index


def evidence_identity(entries):
    _native_artifact_index(entries)
    pins = [{key:entry[key] for key in ('path','bytes','sha256')} for entry in entries]
    return digest(native_canonical({'kind':'runtime_native_evidence_v1','artifact_pins':pins}))


def _read_native_artifacts(context, evidence_dir, entries):
    """Bound and pin every raw byte; no parsed output or pass label supplies trust."""
    expected = _native_artifact_index(entries)
    bounds = {**context.bounds, 'runtime_bytes':NATIVE_ARTIFACT_TOTAL,
              'regular_file_bytes':MAX_JSON, 'all_nodes':100_000}
    bounded = Budget(bounds)
    bounded.deadline = context.budget.deadline  # a phase is not a new deadline
    directories = {'.'}
    for name in expected:
        pieces = name.split('/')
        directories.update('/'.join(pieces[:end]) for end in range(1,len(pieces)))
    require(len(directories)+len(expected) <= bounds['all_nodes'], 'native evidence node bound', MUTATION)
    with Root(evidence_dir) as evidence:
        before = tree(evidence.path, bounded)
        index = {row['path']:row for row in before}
        require(set(index) == directories | set(expected), 'unrecognized native evidence paths')
        require(all(index[name]['kind'] == 'directory' for name in directories), 'native evidence directory type')
        for name, entry in expected.items():
            row = index[name]
            require(row['kind'] == 'file' and row['bytes'] == entry['bytes'] and row['sha256'] == entry['sha256'],
                    'native evidence artifact mismatch')
        artifacts, actual_bytes = {}, 0
        for name, entry in expected.items():
            _, raw = regular_at(evidence.fd, name, bounded, {'bytes':entry['bytes'],'sha256':entry['sha256']},
                                True, maximum=min(NATIVE_ARTIFACT_LIMITS[entry['kind']], NATIVE_ARTIFACT_TOTAL-actual_bytes))
            actual_bytes += len(raw)
            require(actual_bytes <= NATIVE_ARTIFACT_TOTAL, 'native evidence actual byte bound', MUTATION)
            artifacts[name] = raw
        require(tree(evidence.path, bounded) == before, 'native evidence changed during read', MUTATION)
        evidence.check()
    return artifacts


def _read_native_approval_envelope(context, basis, before_rows, final_rows, evidence_dir):
    """Read exact schema-2 approval plus all raw artifacts, not native acceptance.

    Gate semantics and fresh actual native verification remain mandatory callers.
    This cannot be used to write a manifest/marker or admit an accepted copy.
    """
    require(context.phase == 'native', 'native source phase required')
    try:
        approval_pin, raw = read_path(context.source_root / NATIVE_PATH, context.budget)
    except FileNotFoundError:
        raise Rejected('SOURCE_OWNED_NATIVE_BUILD_RECORD_REQUIRED', MISSING) from None
    record = strict_json(raw)
    keys(record, ('schema_version','kind','basis_id','basis_identity','policy_sha256','source_identities',
                  'prepared_identity','final_closure','signed_identity','transforms','final_components',
                  'native_inventory','probe_contract','receipts','evidence_artifacts','evidence_identity','review_decision'))
    integer(record['schema_version'], 2, 2)
    require(record['kind'] == 'runtime_native_build_approval', 'native approval kind')
    bindings = {'basis_identity':digest(native_canonical(basis)), 'policy_sha256':context.policy_sha,
                'source_identities':context.sources, 'prepared_identity':prepared_identity(context,basis,before_rows),
                'signed_identity':signed_identity(context,final_rows)}
    require(record['basis_id'] == basis['id'] and native_canonical(record['final_closure']) == native_canonical(final_rows)
            and all(native_canonical(record[key]) == native_canonical(value) for key,value in bindings.items()),
            'native approval basis/source/closure identity mismatch')
    keys(record['review_decision'], ('scope','decision_id'))
    require(record['review_decision']['scope'] == 'personal_candidate'
            and type(record['review_decision']['decision_id']) is str
            and 0 < len(record['review_decision']['decision_id'].encode('utf-8')) <= 4096,
            'independent scoped native review required')
    inventory = record['native_inventory']
    keys(inventory, ('objects','code_bundles','launch_contexts','system_roots','system_targets'))
    require(type(inventory['objects']) is list and type(inventory['code_bundles']) is list,
            'exact native object/bundle inventories required')
    native_paths = []
    for entry in inventory['objects']:
        require(type(entry) is dict and type(entry.get('path')) is str, 'native object path required')
        native_paths.append(entry['path'])
    seal_roots = []
    for entry in inventory['code_bundles']:
        require(type(entry) is dict and type(entry.get('seal_root')) is str, 'native bundle seal root required')
        seal_roots.append(entry['seal_root'])
    _validate_native_transforms(context,basis,before_rows,final_rows,record['transforms'],
                                native_paths,seal_roots,record['final_components'])
    # Complete inventory/probe schema semantics are checked by the next admission
    # layer. No opaque dictionaries here can confer acceptance on their own.
    require(type(record['probe_contract']) is dict and record['probe_contract'], 'native probe contract required')
    contract_sha = digest(native_canonical(record['probe_contract']))
    entries = record['evidence_artifacts']
    artifacts = _read_native_artifacts(context,evidence_dir,entries)
    require(record['evidence_identity'] == evidence_identity(entries), 'native evidence identity mismatch')
    artifact_index = _native_artifact_index(entries)
    receipts = record['receipts']
    require(type(receipts) is list and len(receipts) == len(context.policy['required_native_evidence']),
            'all exact native receipts required')
    names, gates, parsed = set(), set(), {}
    for entry in receipts:
        keys(entry, ('gate','path','bytes','sha256'))
        name = relative(entry['path']); gate = entry['gate']
        require(type(gate) is str and gate in context.policy['required_native_evidence'] and gate not in gates
                and name not in names, 'unknown/duplicate native receipt')
        pin({'bytes':entry['bytes'],'sha256':entry['sha256']})
        require(name in artifact_index and artifact_index[name]['kind'] == 'receipt'
                and native_canonical({key:artifact_index[name][key] for key in ('path','bytes','sha256')}) ==
                    native_canonical({key:entry[key] for key in ('path','bytes','sha256')}),
                'receipt artifact not independently pinned')
        receipt = strict_json(artifacts[name])
        require(type(receipt) is dict and type(receipt.get('schema_version')) is int
                and receipt['schema_version'] == 2 and receipt.get('kind') == 'observed_native_runtime_gate'
                and receipt.get('gate') == gate, 'native receipt schema-2/gate required')
        expected_bindings = {**bindings, 'probe_contract_identity':contract_sha}
        require(native_canonical(receipt.get('bindings')) == native_canonical(expected_bindings),
                'native receipt approval binding mismatch')
        parsed[gate] = receipt; names.add(name); gates.add(gate)
    require(names == {name for name,entry in artifact_index.items() if entry['kind']=='receipt'},
            'unreferenced native receipt artifact')
    require(gates == set(context.policy['required_native_evidence']), 'native gate coverage mismatch')
    read_path(context.source_root / NATIVE_PATH, context.budget,
              {'bytes':approval_pin['bytes'],'sha256':approval_pin['sha256']})
    context.recheck()
    return {'kind':'native_approval_envelope_not_accepted','record':record,
            'approval_pin':{'bytes':approval_pin['bytes'],'sha256':approval_pin['sha256']},
            'bindings':bindings,'receipts':parsed,'artifacts':artifacts}


NATIVE_FINALIZATION_DIR = 'native-finalization'
NATIVE_ACCEPTANCE = 'accepted-runtime.json'


def _native_stage_boundary(context, stage):
    allowed = {'payload','inputs','evidence','work','stage-state.json',NATIVE_FINALIZATION_DIR,NATIVE_ACCEPTANCE}
    names = set(names_at(stage.fd, len(allowed), context.budget))
    require({'payload','inputs','evidence','work','stage-state.json'} <= names and names <= allowed,
            'unrecognized native stage state')
    with parent_at(stage.fd, 'work/_unused') as (fd, _):
        require(not names_at(fd, 0, context.budget), 'native stage work must remain empty')
    require(NATIVE_ACCEPTANCE not in names or NATIVE_FINALIZATION_DIR in names,
            'acceptance marker lacks finalization evidence')
    return names


def _native_namespace_usage(context, stage):
    try:
        info = os.stat(NATIVE_FINALIZATION_DIR, dir_fd=stage.fd, follow_symlinks=False)
    except FileNotFoundError:
        return 0, 0
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
            'private native finalization evidence required')
    bounds = {**context.bounds, 'runtime_bytes':NATIVE_ARTIFACT_TOTAL,
              'regular_file_bytes':MAX_JSON, 'all_nodes':100_000}
    bounded = Budget(bounds); bounded.deadline = context.budget.deadline
    rows = tree(stage.path/NATIVE_FINALIZATION_DIR, bounded)
    for row in rows:
        require(row['kind'] in ('directory','file'), 'native attempt symlink forbidden')
        if row['path'] == '.': continue
        parts = row['path'].split('/')
        require(re.fullmatch(r'\.?attempt-[0-9a-f]{32}',parts[0]), 'unknown finalization attempt name')
        if len(parts) == 1:
            require(row['kind'] == 'directory' and row['mode'] == 0o700, 'invalid finalization attempt root')
        elif len(parts) >= 2:
            require(parts[1] in ('approved','fresh','attempt.json','manifest.pending','acceptance.pending'),
                    'unknown finalization attempt entry')
            if parts[1] in ('attempt.json','manifest.pending','acceptance.pending'):
                require(len(parts) == 2 and row['kind'] == 'file', 'invalid finalization transaction file')
            else:
                require(len(parts) > 2 or row['kind'] == 'directory', 'invalid finalization artifact root')
    return sum(row.get('bytes',0) for row in rows), len(rows)


def _native_write_files(root, files):
    """Write only exclusively created independent files in a private capability."""
    directories = set()
    for name in files:
        relative(name)
        parts = name.split('/')
        directories.update('/'.join(parts[:end]) for end in range(1,len(parts)))
    for name in sorted(directories,key=lambda n:(n.count('/'),n.encode('utf-8'))):
        with parent_at(root.fd,name) as (parent,leaf):
            os.mkdir(leaf,0o700,dir_fd=parent);os.fsync(parent)
    for name in sorted(files,key=lambda n:n.encode('utf-8')):
        write_new(root.fd,name,files[name])
    for name in sorted(directories,key=lambda n:(-n.count('/'),n.encode('utf-8'))):
        with parent_at(root.fd,name+'/_unused') as (fd,_): os.fsync(fd)
    os.fsync(root.fd);root.check()


def _native_manifest_state(context, payload, expected_raw):
    expected = {'bytes':len(expected_raw),'sha256':digest(expected_raw)}
    try:
        row,raw = regular_at(payload.fd,MANIFEST,context.budget,expected,True,maximum=MAX_JSON)
        require(row['mode']==0o644,'deterministic manifest mode mismatch')
    except FileNotFoundError:
        return None
    require(raw == expected_raw,'existing manifest differs from deterministic expected bytes')
    return expected


def _native_marker(context, admission, manifest_pin, attempt_path, attempt_pin):
    record=admission['record']
    return {'schema_version':1,'kind':'accepted_runtime_payload','scope':'personal_candidate',
            'basis_id':record['basis_id'],'bindings':admission['bindings'],
            'approval_pin':admission['approval_pin'],'manifest_pin':manifest_pin,
            'evidence_identity':record['evidence_identity'],
            'finalization_evidence':{'path':attempt_path,'bytes':attempt_pin['bytes'],'sha256':attempt_pin['sha256']}}


def _audit_committed_native_marker(context, stage, admission, manifest_pin):
    """A marker is only a bound checkpoint. Source approval remains the authority."""
    try:
        _,raw = regular_at(stage.fd,NATIVE_ACCEPTANCE,context.budget,collect=True,maximum=MAX_JSON)
    except FileNotFoundError:
        return None
    marker=strict_json(raw)
    keys(marker,('schema_version','kind','scope','basis_id','bindings','approval_pin','manifest_pin',
                 'evidence_identity','finalization_evidence'))
    evidence=marker['finalization_evidence'];keys(evidence,('path','bytes','sha256'))
    require(type(evidence['path']) is str and re.fullmatch(
            re.escape(NATIVE_FINALIZATION_DIR)+r'/attempt-[0-9a-f]{32}/attempt.json',evidence['path']),
            'invalid committed finalization evidence path')
    pin({'bytes':evidence['bytes'],'sha256':evidence['sha256']})
    expected=_native_marker(context,admission,manifest_pin,evidence['path'],evidence)
    require(native_canonical(marker)==native_canonical(expected),'acceptance checkpoint mismatch')
    _,attempt_raw=regular_at(stage.fd,evidence['path'],context.budget,
                            {'bytes':evidence['bytes'],'sha256':evidence['sha256']},True,maximum=MAX_JSON)
    attempt=strict_json(attempt_raw)
    keys(attempt,('schema_version','kind','approval_pin','signed_identity','evidence_identity',
                  'approved_artifacts','fresh_artifacts','fresh_static_facts'))
    require(type(attempt['schema_version']) is int and attempt['schema_version']==1
            and attempt['kind']=='runtime_native_finalization_evidence'
            and native_canonical(attempt['approval_pin'])==native_canonical(admission['approval_pin'])
            and attempt['signed_identity']==admission['bindings']['signed_identity']
            and attempt['evidence_identity']==admission['record']['evidence_identity'],
            'committed finalization facts mismatch')
    approved=[{**entry,'path':'approved/'+entry['path']} for entry in admission['record']['evidence_artifacts']]
    require(native_canonical(attempt['approved_artifacts'])==native_canonical(approved),
            'committed approval artifact mapping mismatch')
    fresh=attempt['fresh_artifacts'];_native_artifact_index(fresh)
    require(all(entry['path'].startswith('fresh/') and entry['kind'] in ('stdout','stderr','canonical_facts')
                for entry in fresh),'invalid committed fresh artifact')
    require(sum(entry['bytes'] for entry in fresh)<=32_000_000,'committed fresh output aggregate',MUTATION)
    all_entries=approved+fresh+[{'path':'attempt.json','kind':'canonical_facts',
                               'bytes':len(attempt_raw),'sha256':digest(attempt_raw)}]
    all_entries.sort(key=lambda entry:entry['path'].encode('utf-8'))
    retained=_read_native_artifacts(context,stage.path/evidence['path'].rsplit('/',1)[0],all_entries)
    previous=dict(attempt['fresh_static_facts'])
    previous['raw_artifacts']={entry['path'].removeprefix('fresh/'):retained[entry['path']] for entry in fresh}
    _validate_fresh_native_static(context,admission['record']['final_closure'],admission,previous)
    # Historical fresh output is not a substitute for the caller's new actual
    # static verifier. Its complete unchanged artifact bytes are checked here.
    return marker


def _commit_native_finalization(context, stage, admission, fresh):
    """Commit under the caller-held exclusive stage lock after genuine gates.

    No code here generates a native approval, signs, repairs or executes payload
    bytes. Unit tests may call this private writer with isolated synthetic source
    approvals and explicitly mocked native observations only.
    """
    require(context.phase=='native' and admission.get('kind')=='native_runtime_gates_verified',
            'validated native gate admission required before commit')
    record=admission['record'];rows=record['final_closure']
    _validate_fresh_native_static(context,rows,admission,fresh)
    manifest_raw=_final_manifest_bytes(context,rows,admission['verified_facts'])
    manifest_pin={'bytes':len(manifest_raw),'sha256':digest(manifest_raw)}
    _native_stage_boundary(context,stage)
    used_bytes,used_nodes=_native_namespace_usage(context,stage)
    with Root(stage.path/'payload') as payload:
        old_manifest=_native_manifest_state(context,payload,manifest_raw)
        require(tree(payload.path,context.budget,old_manifest)==rows,'signed payload changed before commit',MUTATION)
        old_marker=_audit_committed_native_marker(context,stage,admission,manifest_pin)
        require(old_marker is None or old_manifest is not None,'committed acceptance lacks manifest')
        keys(fresh,('native_objects','code_bundles','launch_contexts','resolved_edges','system_targets','tool_events','raw_artifacts',
                    'metadata_empty_before','metadata_empty_after'))
        for observed,approved in (('native_objects','objects'),('code_bundles','code_bundles'),('launch_contexts','launch_contexts')):
            require(native_canonical(fresh[observed])==native_canonical(record['native_inventory'][approved]),
                    'fresh static verification facts mismatch')
        require(native_canonical(fresh['resolved_edges']) ==
                native_canonical(admission['verified_static_facts']['resolved_edges']),
                'fresh resolved dependencies differ from reviewed static gate')
        require(native_canonical(fresh['system_targets'])==native_canonical(admission['verified_static_facts']['system_targets']),
                'fresh system target availability differs from reviewed static gate')
        raw_artifacts=fresh['raw_artifacts']
        require(type(raw_artifacts) is dict and 1<=len(raw_artifacts)<=100_000,'fresh static raw artifacts required')
        files={};fresh_entries=[];raw_total=0
        for name,raw in sorted(raw_artifacts.items()):
            relative(name);require(type(raw) is bytes and len(raw)<=2_097_152,'fresh static artifact bound',MUTATION)
            raw_total+=len(raw);require(raw_total<=32_000_000,'fresh static total output bound',MUTATION)
            require(name.endswith(('.stdout','.stderr')),'unknown fresh static stream artifact')
            kind=('canonical_facts' if name=='commands/native-system-targets.stdout' else
                  'stderr' if name.endswith('.stderr') else 'stdout')
            full='fresh/'+name;files[full]=raw
            fresh_entries.append({'path':full,'kind':kind,'bytes':len(raw),'sha256':digest(raw)})
        _native_artifact_index(fresh_entries)
        approved_entries=[]
        for entry in record['evidence_artifacts']:
            raw=admission['artifacts'].get(entry['path'])
            require(type(raw) is bytes and len(raw)==entry['bytes'] and digest(raw)==entry['sha256'],
                    'approved evidence changed before retention',MUTATION)
            full='approved/'+entry['path'];files[full]=raw;approved_entries.append({**entry,'path':full})
        attempt={'schema_version':1,'kind':'runtime_native_finalization_evidence',
                 'approval_pin':admission['approval_pin'],'signed_identity':admission['bindings']['signed_identity'],
                 'evidence_identity':record['evidence_identity'],'approved_artifacts':approved_entries,
                 'fresh_artifacts':fresh_entries,'fresh_static_facts':{k:v for k,v in fresh.items() if k!='raw_artifacts'}}
        attempt_raw=native_canonical(attempt);files['attempt.json']=attempt_raw
        needed=sum(map(len,files.values()))+len(manifest_raw)+MAX_JSON
        require(used_bytes+needed<=NATIVE_ARTIFACT_TOTAL,'all finalization attempts aggregate bound',MUTATION)
        parents={'.'}
        for name in files:
            parts=name.split('/');parents.update('/'.join(parts[:end]) for end in range(1,len(parts)))
        require(used_nodes+len(files)+len(parents)+4<=100_000,'all finalization attempt node bound',MUTATION)
        reserve(stage.fd,needed,context.budget)
        try:
            os.mkdir(NATIVE_FINALIZATION_DIR,0o700,dir_fd=stage.fd);os.fsync(stage.fd)
        except FileExistsError:
            pass
        with Root(stage.path/NATIVE_FINALIZATION_DIR) as namespace:
            token=uuid.uuid4().hex;temporary='.attempt-'+token;published='attempt-'+token
            os.mkdir(temporary,0o700,dir_fd=namespace.fd);os.fsync(namespace.fd)
            with Root(namespace.path/temporary) as transaction:
                _native_write_files(transaction,files)
                require(tree(payload.path,context.budget,old_manifest)==rows,'signed payload changed during evidence retention',MUTATION)
                read_path(context.source_root/NATIVE_PATH,context.budget,admission['approval_pin']);context.recheck()
                if old_manifest is None:
                    write_new(transaction.fd,'manifest.pending',manifest_raw,0o644)
                    original_mode=next(row['mode'] for row in rows if row['path']=='.')
                    require(stat.S_IMODE(os.fstat(payload.fd).st_mode)==original_mode,'payload root mode changed',MUTATION)
                    if not original_mode&0o200:os.fchmod(payload.fd,original_mode|0o200)
                    try:
                        no_replace(transaction.fd,'manifest.pending',MANIFEST,destination_parent_fd=payload.fd)
                    finally:
                        os.fchmod(payload.fd,original_mode);os.fsync(payload.fd)
                regular_at(payload.fd,MANIFEST,context.budget,manifest_pin,maximum=MAX_JSON)
                require(tree(payload.path,context.budget,manifest_pin)==rows,'final signed payload re-audit failed',MUTATION)
                read_path(context.source_root/NATIVE_PATH,context.budget,admission['approval_pin']);context.recheck()
                payload.check();stage.check();transaction.check()
                os.fsync(transaction.fd)
            no_replace(namespace.fd,temporary,published)
            attempt_pin={'bytes':len(attempt_raw),'sha256':digest(attempt_raw)}
            evidence_path=NATIVE_FINALIZATION_DIR+'/'+published+'/attempt.json'
            marker=_native_marker(context,admission,manifest_pin,evidence_path,attempt_pin)
            marker_raw=native_canonical(marker)
            with Root(namespace.path/published) as committed:
                if old_marker is None:
                    write_new(committed.fd,'acceptance.pending',marker_raw)
                    # Source/payload are checked again at the actual last commit edge.
                    read_path(context.source_root/NATIVE_PATH,context.budget,admission['approval_pin']);context.recheck()
                    require(tree(payload.path,context.budget,manifest_pin)==rows,'payload changed at acceptance edge',MUTATION)
                    no_replace(committed.fd,'acceptance.pending',NATIVE_ACCEPTANCE,destination_parent_fd=stage.fd)
                else:
                    marker=old_marker  # a fresh attempt never rewrites old accepted observations
                os.fsync(committed.fd)
            os.fsync(namespace.fd);os.fsync(stage.fd);stage.check();payload.check()
            read_path(context.source_root/NATIVE_PATH,context.budget,admission['approval_pin']);context.recheck()
            require(tree(payload.path,context.budget,manifest_pin)==rows,'payload changed after acceptance publication',MUTATION)
            require(_audit_committed_native_marker(context,stage,admission,manifest_pin)==marker,
                    'acceptance commit re-audit mismatch',MUTATION)
            return {'kind':'runtime_native_finalization','state':'revalidated' if old_marker else 'finalized',
                    'native_accepted':True,'scope':'personal_candidate','manifest':manifest_pin,
                    'approval_sha256':admission['approval_pin']['sha256'],'signed_identity':admission['bindings']['signed_identity']}












# BEGIN NATIVE COMPOSITION
import fcntl
"""Source-owned static verifier fragment; parent integrates into reconstruction.

Uses that module's Root/parent_at/tree/regular_at/require/Rejected helpers.
Only _verify_native_static is the production execution entry point. Private
runner/parser tests are synthetic; they cannot create native approval.
"""
import plistlib
import select
import selectors
import signal
import subprocess
import datetime
import struct

_NS_MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
             b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
             b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
_NS_TOOLS = {'lipo':'/usr/bin/lipo', 'otool':'/usr/bin/otool',
             'codesign':'/usr/bin/codesign', 'sysctl':'/usr/sbin/sysctl',
             'sandbox':'/usr/bin/sandbox-exec'}
_NS_SYSTEM_ROOTS = ('/usr/lib', '/System/Library/Frameworks', '/System/Library/PrivateFrameworks')
_NS_ENV = {'PATH':'/usr/bin:/usr/sbin', 'LANG':'C', 'LC_ALL':'C', 'TZ':'UTC'}
_NS_OUTPUT = 2_097_152
_NS_TOTAL_OUTPUT = 32_000_000
_NS_DEPENDENCIES = ('LC_LOAD_DYLIB','LC_LOAD_WEAK_DYLIB','LC_REEXPORT_DYLIB','LC_LOAD_UPWARD_DYLIB')
_NS_DYLIB = _NS_DEPENDENCIES + ('LC_ID_DYLIB',)
_NS_VERSION = r'[0-9]+(?:\.[0-9]+){0,2}'


def _native_child_exited(child):
    """Same non-reaping observation as source-pinned dot_process.child_exited.

    Kept local so inspecting the payload never imports candidate runtime code.
    Context pins the original helper as part of the native source identity.
    """
    if getattr(child, 'returncode', None) is not None:
        raise ChildProcessError('owned child already reaped')
    waitid = getattr(os, 'waitid', None)
    if callable(waitid):
        return waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
    if not hasattr(select, 'kqueue'):
        raise RuntimeError('non-reaping child observation unavailable')
    queue = select.kqueue()
    try:
        event = select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                              flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
        try:
            events = queue.control([event], 1, 0)
        except ProcessLookupError:
            return True
        for event in events:
            if event.flags & select.KQ_EV_ERROR:
                if event.data == errno.ESRCH:
                    return True
                raise OSError(event.data, 'owned process event registration failed')
            if event.fflags & select.KQ_NOTE_EXIT:
                return True
        return False
    finally:
        queue.close()


def _native_run_bounded(argv, deadline, pass_fds=(), env=None, cap=_NS_OUTPUT):
    """Raw bounded capture. Never poll/wait before killing the owned group.

    EOF is not exit. One absolute deadline remains active after output EOF.
    A child remains unreaped until SIGKILL has been sent to its owned group;
    the leader's reserved PID therefore cannot accidentally name another group.
    Completion additionally requires group disappearance and both output EOFs.
    This private primitive accounts for its owned process group; production
    additionally uses the fixed deny-process-fork sandbox, so a target cannot
    detach a descendant from that group. It is not a general subprocess reaper.
    """
    start = time.monotonic()
    require(type(cap) is int and 0 <= cap <= _NS_OUTPUT, 'native output cap', MUTATION)
    deadline = min(deadline, start + 30)
    result = {'argv':list(argv), 'returncode':None, 'reason':None,
              'stdout':b'', 'stderr':b'', 'duration_ms':0,
              'cleanup':{'remaining_owned_processes':0, 'open_output_pipes':0,
                         'complete':False, 'duration_ms':0}}
    if start >= deadline:
        result['reason'] = 'deadline'
        result['cleanup']['complete'] = True
        return result
    # Allocate the selector before spawning: failure owns no child to abandon.
    selector = selectors.DefaultSelector()
    try:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, close_fds=True, pass_fds=pass_fds,
                                 start_new_session=True, env=dict(_NS_ENV if env is None else env))
    except OSError as exc:
        selector.close()
        result.update(reason='spawn_failed', spawn_errno=exc.errno)
        result['cleanup']['complete'] = True
        return result
    except BaseException:
        selector.close()
        raise
    streams = {'stdout':bytearray(), 'stderr':bytearray()}
    total = 0
    cleanup_start = None
    cleanup_deadline = None
    killed = False
    leader_exited = False
    pending_exception = None

    def teardown(reason=None):
        nonlocal cleanup_start, cleanup_deadline, killed
        if result['reason'] is None and reason is not None:
            result['reason'] = reason
        if cleanup_start is None:
            cleanup_start = time.monotonic()
            cleanup_deadline = cleanup_start + 2
        if not killed:
            try:
                os.killpg(child.pid, signal.SIGKILL)
                killed = True
            except ProcessLookupError:
                # The unreaped child prevents PID reuse; no such group is safe.
                killed = True
            except OSError:
                result['reason'] = 'group_kill_failed'

    def drain(wait):
        nonlocal total
        if not selector.get_map():
            time.sleep(wait)
            return
        for key, _ in selector.select(wait):
            try:
                data = os.read(key.fd, 65536)
            except BlockingIOError:
                continue
            if not data:
                selector.unregister(key.fileobj)
                key.fileobj.close()
                continue
            available = max(0, cap - total)
            streams[key.data].extend(data[:available])
            total += min(available, len(data))
            if len(data) > available:
                teardown('output_limit')

    try:
        for label, pipe in (('stdout', child.stdout), ('stderr', child.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, label)
        while True:
            now = time.monotonic()
            if cleanup_deadline is not None and now >= cleanup_deadline:
                break
            if cleanup_deadline is None and now >= deadline:
                teardown('deadline')
            leader_exited = _native_child_exited(child)
            if leader_exited:
                teardown()
            if leader_exited and killed and not selector.get_map():
                break
            stop = cleanup_deadline if cleanup_deadline is not None else deadline
            drain(min(0.02, max(0, stop - time.monotonic())))
    except BaseException as exc:
        pending_exception = exc
        teardown('interrupted')
    finally:
        teardown()
        # Complete cleanup also after an exception while observing/draining.
        while time.monotonic() < cleanup_deadline and not leader_exited:
            try:
                leader_exited = _native_child_exited(child)
            except (OSError, RuntimeError):
                result['reason'] = 'exit_observation_failed'
                break
            if not leader_exited:
                time.sleep(min(0.01, max(0, cleanup_deadline-time.monotonic())))
        if killed and leader_exited:
            # First and only reaping call occurs after owned-group teardown.
            try:
                result['returncode'] = child.wait(timeout=max(0, cleanup_deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                result['reason'] = 'reap_timeout'
        while selector.get_map() and time.monotonic() < cleanup_deadline:
            try:
                drain(min(0.01, max(0, cleanup_deadline-time.monotonic())))
            except (OSError, ValueError):
                result['reason'] = 'pipe_cleanup_failed'
                break
        group_gone = False
        # Only probe group presence after leader reaping; zombie leader itself
        # would otherwise keep killpg(0) successful. Never signal this PID again.
        if result['returncode'] is not None:
            while time.monotonic() < cleanup_deadline:
                try:
                    os.killpg(child.pid, 0)
                except ProcessLookupError:
                    group_gone = True
                    break
                except PermissionError:
                    break
                time.sleep(min(0.01, max(0, cleanup_deadline-time.monotonic())))
        open_pipes = len(selector.get_map())
        result['cleanup'] = {'remaining_owned_processes':0 if group_gone else 1,
                             'open_output_pipes':open_pipes,
                             'complete':bool(killed and leader_exited and group_gone and not open_pipes),
                             'duration_ms':int((time.monotonic()-cleanup_start)*1000)}
        if result['cleanup']['duration_ms'] > 2000:
            result['cleanup']['complete'] = False
        if not result['cleanup']['complete']:
            result['reason'] = 'incomplete_cleanup'
        selector.close()
        child.stdout.close(); child.stderr.close()
        result['stdout'], result['stderr'] = bytes(streams['stdout']), bytes(streams['stderr'])
        result['duration_ms'] = int((time.monotonic()-start)*1000)
    if pending_exception is not None:
        # Caller may persist the bounded diagnostic capture before propagating.
        try:
            pending_exception.native_command_result = result
        except (AttributeError, TypeError):
            pass
        raise pending_exception
    return result


def _ns_text(raw):
    require(type(raw) is bytes and len(raw) <= _NS_OUTPUT, 'native parser byte bound', MUTATION)
    try:
        text = raw.decode('utf-8', 'strict')
    except UnicodeError as exc:
        raise Rejected('UNSUPPORTED_NATIVE_TOOL_OUTPUT: non-UTF8', UNSUPPORTED) from exc
    require('\x00' not in text and '\r' not in text and all(ord(c) >= 32 or c in '\n\t' for c in text),
            'UNSUPPORTED_NATIVE_TOOL_OUTPUT: control character', UNSUPPORTED)
    return text


def _parse_native_lipo(stdout, stderr):
    require(stderr == b'', 'UNSUPPORTED_NATIVE_LIPO_DIAGNOSTIC', UNSUPPORTED)
    text = _ns_text(stdout)
    require(re.fullmatch(r'(?:arm64|x86_64)(?: (?:arm64|x86_64))*\n', text) is not None,
            'UNSUPPORTED_NATIVE_LIPO_OUTPUT', UNSUPPORTED)
    arches = text.strip().split(' ')
    require(len(arches) == len(set(arches)) and 'arm64' in arches,
            'unsupported native architectures', UNSUPPORTED)
    return sorted(arches)


def _ns_sections(raw, target, architectures):
    """Split only exact otool object headings, never free-form warning text."""
    text = _ns_text(raw)
    require(text.endswith('\n'), 'UNSUPPORTED_NATIVE_OTOOL_TRUNCATED', UNSUPPORTED)
    result, current = {}, None
    pattern = re.compile(re.escape(target) + r'(?: \(architecture (arm64|x86_64)\))?:')
    for line in text.splitlines():
        match = pattern.fullmatch(line)
        if match:
            arch = match.group(1)
            if arch is None:
                require(len(architectures) == 1, 'UNSUPPORTED_NATIVE_FAT_HEADING', UNSUPPORTED)
                arch = architectures[0]
            require(arch in architectures and arch not in result, 'UNSUPPORTED_NATIVE_OTOOL_HEADING', UNSUPPORTED)
            result[arch] = []; current = result[arch]
        else:
            require(current is not None and line.strip(), 'UNSUPPORTED_NATIVE_OTOOL_LINE', UNSUPPORTED)
            current.append(line.strip())
    require(set(result) == set(architectures), 'UNSUPPORTED_NATIVE_OTOOL_SLICE_COVERAGE', UNSUPPORTED)
    return result


def _parse_native_otool_libraries(stdout, stderr, target, architectures):
    require(stderr == b'', 'UNSUPPORTED_NATIVE_OTOOL_DIAGNOSTIC', UNSUPPORTED)
    result = {}
    pattern = re.compile(r'(.+) \(compatibility version (' + _NS_VERSION +
                         r'), current version (' + _NS_VERSION + r')\)')
    for arch, lines in _ns_sections(stdout, target, architectures).items():
        values = []
        for line in lines:
            match = pattern.fullmatch(line)
            require(match is not None, 'UNSUPPORTED_NATIVE_OTOOL_LIBRARY', UNSUPPORTED)
            values.append({'name':match[1], 'compatibility_version':match[2], 'current_version':match[3]})
        result[arch] = values
    return result


# These commands affect object identity but introduce no loader search edge.
# Their complete normalized field lines remain in the approved inventory.
_NS_NONLINK_FIELDS = {
    'LC_UUID':(r'uuid [0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}',),
    'LC_SYMTAB':(r'symoff [0-9]+',r'nsyms [0-9]+',r'stroff [0-9]+',r'strsize [0-9]+'),
    'LC_DYSYMTAB':tuple(key+r' [0-9]+' for key in ('ilocalsym','nlocalsym','iextdefsym','nextdefsym',
        'iundefsym','nundefsym','tocoff','ntoc','modtaboff','nmodtab','extrefsymoff','nextrefsyms',
        'indirectsymoff','nindirectsyms','extreloff','nextrel','locreloff','nlocrel')),
    'LC_DYLD_INFO_ONLY':tuple(key+r' [0-9]+' for key in ('rebase_off','rebase_size','bind_off','bind_size',
        'weak_bind_off','weak_bind_size','lazy_bind_off','lazy_bind_size','export_off','export_size')),
    'LC_MAIN':(r'entryoff [0-9]+',r'stacksize [0-9]+'),
    'LC_SOURCE_VERSION':(r'version [0-9]+(?:\.[0-9]+){0,4}',),
    'LC_CODE_SIGNATURE':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_FUNCTION_STARTS':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_DATA_IN_CODE':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_DYLIB_CODE_SIGN_DRS':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_LINKER_OPTIMIZATION_HINT':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_DYLD_EXPORTS_TRIE':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_DYLD_CHAINED_FIXUPS':(r'dataoff [0-9]+',r'datasize [0-9]+'),
    'LC_LOAD_DYLINKER':(r'name /usr/lib/dyld \(offset [0-9]+\)',),
}
_NS_NONLINK_COMMANDS = tuple(sorted(_NS_NONLINK_FIELDS)) + ('LC_SEGMENT_64',)


def _ns_fields(lines, patterns):
    require(len(lines) == len(patterns) and all(re.fullmatch(pattern,line)
            for pattern,line in zip(patterns,lines)), 'UNSUPPORTED_NATIVE_LOAD_COMMAND_FIELDS', UNSUPPORTED)


def _ns_segment(lines):
    require(len(lines) >= 8, 'UNSUPPORTED_NATIVE_SEGMENT', UNSUPPORTED)
    _ns_fields(lines[:8], (r'segname(?: [A-Za-z0-9_.$]+)?',r'vmaddr 0x[0-9a-fA-F]+',
        r'vmsize 0x[0-9a-fA-F]+',r'fileoff [0-9]+',r'filesize [0-9]+',
        r'maxprot 0x[0-9a-fA-F]+',r'initprot 0x[0-9a-fA-F]+',r'nsects [0-9]+'))
    count = int(lines[7].split()[-1])
    require(count <= 1024 and len(lines) in (9+12*count,9+13*count),
            'UNSUPPORTED_NATIVE_SECTION_COUNT', UNSUPPORTED)
    section_size = (len(lines)-9)//count if count else 12
    _ns_fields(lines[8:9], (r'flags 0x[0-9a-fA-F]+',))
    patterns = (r'Section',r'sectname [A-Za-z0-9_.$]+',r'segname [A-Za-z0-9_.$]+',
        r'addr 0x[0-9a-fA-F]+',r'size 0x[0-9a-fA-F]+',r'offset [0-9]+',r'align 2\^[0-9]+ \([0-9]+\)',
        r'reloff [0-9]+',r'nreloc [0-9]+',r'flags 0x[0-9a-fA-F]+',
        r'reserved1 [0-9]+(?: \(index into indirect symbol table\))?',
        r'reserved2 [0-9]+(?: \(size of stubs\))?')
    if section_size == 13:
        patterns += (r'reserved3 [0-9]+',)
    for index in range(count):
        _ns_fields(lines[9+section_size*index:9+section_size*(index+1)],patterns)


def _ns_load_command(block):
    require(len(block) >= 2, 'UNSUPPORTED_NATIVE_LOAD_COMMAND', UNSUPPORTED)
    match = re.fullmatch(r'cmd (LC_[A-Z0-9_]+)',block[0])
    require(match is not None and re.fullmatch(r'cmdsize [0-9]+',block[1]),
            'UNSUPPORTED_NATIVE_LOAD_COMMAND_HEADER', UNSUPPORTED)
    command, lines = match[1], block[2:]
    if command in _NS_DYLIB:
        _ns_fields(lines, (r'name .+ \(offset [0-9]+\)',r'time stamp [0-9]+(?: .+)?',
            r'current version '+_NS_VERSION,r'compatibility version '+_NS_VERSION))
        name = re.fullmatch(r'name (.+) \(offset [0-9]+\)',lines[0])[1]
        return {'cmd':command,'name':name,'current_version':lines[2].split()[-1],
                'compatibility_version':lines[3].split()[-1]}
    if command == 'LC_RPATH':
        _ns_fields(lines,(r'path .+ \(offset [0-9]+\)',))
        return {'cmd':command,'path':re.fullmatch(r'path (.+) \(offset [0-9]+\)',lines[0])[1]}
    if command == 'LC_BUILD_VERSION':
        require(len(lines) >= 4, 'UNSUPPORTED_NATIVE_BUILD_VERSION', UNSUPPORTED)
        _ns_fields(lines[:4],(r'platform (?:macos|macOS|1)',r'minos '+_NS_VERSION,
                            r'sdk '+_NS_VERSION,r'ntools [0-9]+'))
        count = int(lines[3].split()[-1])
        require(count <= 16 and len(lines) == 4+2*count, 'UNSUPPORTED_NATIVE_BUILD_TOOLS', UNSUPPORTED)
        for index in range(count):
            _ns_fields(lines[4+2*index:6+2*index],(r'tool (?:LD|CLANG|SWIFT|[123])',r'version '+_NS_VERSION))
        return {'cmd':command,'platform':'macOS','minos':lines[1].split()[-1],'sdk':lines[2].split()[-1]}
    if command == 'LC_VERSION_MIN_MACOSX':
        _ns_fields(lines,(r'version '+_NS_VERSION,r'sdk '+_NS_VERSION))
        return {'cmd':command,'version':lines[0].split()[-1],'sdk':lines[1].split()[-1]}
    if command == 'LC_SEGMENT_64':
        _ns_segment(lines)
    elif command in _NS_NONLINK_FIELDS:
        _ns_fields(lines,_NS_NONLINK_FIELDS[command])
    else:
        raise Rejected('UNSUPPORTED_NATIVE_LOAD_COMMAND: '+command, UNSUPPORTED)
    return {'cmd':command,'fields':block[1:]}


def _parse_native_otool_loads(stdout, stderr, target, architectures):
    require(stderr == b'', 'UNSUPPORTED_NATIVE_OTOOL_DIAGNOSTIC', UNSUPPORTED)
    per_arch = {}
    for arch, lines in _ns_sections(stdout,target,architectures).items():
        commands, block = [], None
        for line in lines:
            match = re.fullmatch(r'Load command ([0-9]+)',line)
            if match:
                if block is not None:
                    commands.append(_ns_load_command(block))
                require(int(match[1]) == len(commands) and len(commands) < 4096,
                        'UNSUPPORTED_NATIVE_LOAD_COMMAND_SEQUENCE', UNSUPPORTED)
                block = []
            else:
                require(block is not None, 'UNSUPPORTED_NATIVE_LOAD_COMMAND_PREAMBLE', UNSUPPORTED)
                block.append(line)
        require(block is not None, 'UNSUPPORTED_NATIVE_NO_LOAD_COMMANDS', UNSUPPORTED)
        commands.append(_ns_load_command(block))
        versions = [c for c in commands if c['cmd'] in ('LC_BUILD_VERSION','LC_VERSION_MIN_MACOSX')]
        ids = [c['name'] for c in commands if c['cmd'] == 'LC_ID_DYLIB']
        require(len(versions) == 1 and len(ids) <= 1, 'UNSUPPORTED_NATIVE_PLATFORM_OR_ID', UNSUPPORTED)
        value = {'platform':'macOS','minimum_os':versions[0].get('minos',versions[0].get('version')),
                 'sdk':versions[0]['sdk'],'install_name':ids[0] if ids else None,
                 'rpaths':[c['path'] for c in commands if c['cmd'] == 'LC_RPATH'],'load_commands':commands}
        per_arch[arch] = value
    values = list(per_arch.values())
    require(all(canonical(value) == canonical(values[0]) for value in values),
            'UNSUPPORTED_NATIVE_DIFFERING_FAT_SLICES', UNSUPPORTED)
    return values[0]


def _ns_check_otool_agreement(loads, libraries):
    expected = [{k:c[k] for k in ('name','compatibility_version','current_version')}
                for c in loads['load_commands'] if c['cmd'] in _NS_DYLIB]
    require(all(canonical(lines) == canonical(expected) for lines in libraries.values()),
            'otool -L/-l load-command disagreement')


def _parse_native_codesign_display(stdout, stderr, target, executable_targets=()):
    requirements = _ns_text(stdout)
    require(len(stdout) <= 65536 and re.fullmatch(r'designated => [^\n]+\n',requirements),
            'UNSUPPORTED_NATIVE_REQUIREMENTS', UNSUPPORTED)
    lines = _ns_text(stderr).splitlines()
    require(lines and lines[0] in {'Executable='+value for value in (target,*executable_targets)},
            'UNSUPPORTED_NATIVE_CODESIGN_TARGET', UNSUPPORTED)
    values, authorities = {}, []
    patterns = {
        'Identifier':r'.+', 'Format':r'(?:Mach-O (?:thin|universal) \([a-zA-Z0-9_ ]+\)|(?:(?:app|framework|generic|XPC|appex) )?bundle with Mach-O (?:thin|universal) \([a-zA-Z0-9_ ]+\))',
        'CodeDirectory':r'v=[0-9]+ size=[0-9]+ flags=0x[0-9a-fA-F]+(?:\([a-zA-Z0-9_, -]+\))? hashes=[0-9]+\+[0-9]+ location=embedded',
        'VersionPlatform':r'1', 'VersionMin':r'[0-9]+', 'VersionSDK':r'[0-9]+',
        'Hash type':r'sha256 size=32', 'CandidateCDHash sha256':r'[0-9a-f]{40}',
        'CandidateCDHashFull sha256':r'[0-9a-f]{64}', 'Hash choices':r'sha256',
        'CMSDigest':r'[0-9a-f]{64}', 'CMSDigestType':r'2',
        'Executable Segment base':r'[0-9]+', 'Executable Segment limit':r'[0-9]+',
        'Executable Segment flags':r'0x[0-9a-fA-F]+', 'Page size':r'[0-9]+',
        'CDHash':r'[0-9a-f]{40}', 'Signature':r'adhoc', 'TeamIdentifier':r'(?:not set|[A-Z0-9]{10})',
        'Info.plist':r'(?:not bound|[0-9]+ entries)',
        'Sealed Resources':r'(?:none|version=[0-9]+ rules=[0-9]+ files=[0-9]+)',
        'Internal requirements count':r'[0-9]+ size=[0-9]+',
        'Timestamp':r'.+', 'Signed Time':r'.+', 'Runtime Version':_NS_VERSION,
    }
    for line in lines[1:]:
        name, sep, value = line.partition('=')
        if name == 'Authority' and sep:
            require(value and len(authorities) < 16, 'UNSUPPORTED_NATIVE_SIGNER_CHAIN', UNSUPPORTED)
            authorities.append(value)
            continue
        # CodeDirectory and several verbose records use a space before fields.
        if not sep or name not in patterns:
            matches = [key for key in patterns if line.startswith(key+' ')]
            require(len(matches) == 1, 'UNSUPPORTED_NATIVE_CODESIGN_FIELD', UNSUPPORTED)
            name = matches[0]; value = line[len(name)+1:]
        require(name not in values and name in patterns and re.fullmatch(patterns[name],value),
                'UNSUPPORTED_NATIVE_CODESIGN_VALUE', UNSUPPORTED)
        values[name] = value
    require({'Identifier','Format','CodeDirectory','Hash type','Hash choices','CDHash','TeamIdentifier',
             'Info.plist','Sealed Resources','Internal requirements count'} <= set(values),
            'UNSUPPORTED_NATIVE_CODESIGN_INCOMPLETE', UNSUPPORTED)
    ad_hoc = values.get('Signature') == 'adhoc'
    flags = int(re.search(r'flags=0x([0-9a-fA-F]+)',values['CodeDirectory'])[1],16)
    require(bool(flags & 2) == ad_hoc and (ad_hoc and not authorities or not ad_hoc and authorities),
            'UNSUPPORTED_NATIVE_SIGNER_AMBIGUITY', UNSUPPORTED)
    team = None if values['TeamIdentifier'] == 'not set' else values['TeamIdentifier']
    require(not ad_hoc or team is None, 'ad-hoc signature unexpectedly has team')
    if 'CandidateCDHash sha256' in values:
        require(values['CDHash'] == values['CandidateCDHash sha256'], 'signature cdhash disagreement')
    return {'strict':True,'ad_hoc':ad_hoc,'identifier':values['Identifier'],'team_id':team,
            'cdhash':values['CDHash'],'authorities':authorities,'requirements':requirements.rstrip('\n')}


def _parse_native_entitlements(stdout, stderr, target):
    require(stderr in (b'',('Executable='+target+'\n').encode()),
            'UNSUPPORTED_NATIVE_ENTITLEMENT_DIAGNOSTIC', UNSUPPORTED)
    require(type(stdout) is bytes and len(stdout) <= 65536, 'native entitlement bound', MUTATION)
    if not stdout:
        return {}
    require(stdout.startswith(b'<?xml ') and b'<!ENTITY' not in stdout and b'<![CDATA[' not in stdout,
            'UNSUPPORTED_NATIVE_ENTITLEMENT_FORMAT', UNSUPPORTED)
    try:
        # plistlib alone silently replaces duplicate dict keys. Enforce XML
        # duplicate-key and nesting constraints before its typed conversion.
        import xml.etree.ElementTree as ET
        root = ET.fromstring(stdout)
        def walk(element,depth=0):
            require(depth <= 16, 'native entitlement nesting bound', MUTATION)
            require(element.tag in ('plist','dict','key','string','integer','true','false','array'),
                    'UNSUPPORTED_NATIVE_ENTITLEMENT_TYPE', UNSUPPORTED)
            if element.tag == 'dict':
                children = list(element)
                require(len(children) % 2 == 0, 'invalid entitlement dictionary')
                seen = set()
                for index in range(0,len(children),2):
                    key = children[index]
                    require(key.tag == 'key' and key.text is not None and key.text not in seen,
                            'duplicate/invalid entitlement key')
                    seen.add(key.text)
            for child in element:
                walk(child,depth+1)
        walk(root)
        value = plistlib.loads(stdout)
    except (ValueError, OverflowError, plistlib.InvalidFileException, ET.ParseError) as exc:
        raise Rejected('UNSUPPORTED_NATIVE_ENTITLEMENT_PLIST', UNSUPPORTED) from exc
    require(type(value) is dict and len(canonical(value)) <= 65536, 'invalid native entitlements')
    return value


def _parse_native_codesign_verify(stdout, stderr, target):
    require(stdout == b'', 'UNSUPPORTED_NATIVE_VERIFY_STDOUT', UNSUPPORTED)
    expected = (target+': valid on disk\n'+target+': satisfies its Designated Requirement\n').encode()
    require(stderr == expected, 'UNSUPPORTED_NATIVE_VERIFY_OUTPUT', UNSUPPORTED)
    return True


def _native_empty_xattrs(context, payload, rows, manifest_pin=None):
    """Bounded empty-only Darwin inspection; never reads or clears values.

    fd metadata avoids following regular/dir targets. Symlink metadata uses
    Darwin XATTR_NOFOLLOW with retained ancestor capabilities and full parent
    and node before/after tokens. This detects observed mutation; as elsewhere,
    it is not an atomic same-UID pathname security boundary.
    """
    require(sys.platform == 'darwin', 'NATIVE_REQUIRED', UNSUPPORTED)
    try:
        libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
        flist = libc.flistxattr; llist = libc.listxattr
        flist.argtypes = [ctypes.c_int,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int]
        llist.argtypes = [ctypes.c_char_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int]
        flist.restype = llist.restype = ctypes.c_ssize_t
    except (AttributeError,OSError) as exc:
        raise Rejected('UNSUPPORTED_NOFOLLOW_NATIVE_METADATA',UNSUPPORTED) from exc
    observations = []
    inspected_rows = list(rows)
    if manifest_pin is not None:
        inspected_rows.append({'path':MANIFEST,'kind':'file'})
    for row in inspected_rows:
        context.budget.check(); payload.check()
        name = row['path']
        if name == '.':
            before = os.fstat(payload.fd)
            count = flist(payload.fd,None,0,0)
            same_node(before,os.fstat(payload.fd))
        else:
            with parent_at(payload.fd,name) as (parent,leaf):
                parent_before = os.fstat(parent)
                before = os.stat(leaf,dir_fd=parent,follow_symlinks=False)
                if stat.S_ISLNK(before.st_mode):
                    count = llist(os.fsencode(payload.path/name),None,0,1)  # XATTR_NOFOLLOW
                else:
                    flags = DIR_FLAGS if stat.S_ISDIR(before.st_mode) else FLAGS
                    require(stat.S_ISDIR(before.st_mode) or stat.S_ISREG(before.st_mode),
                            'unsupported metadata node')
                    fd = os.open(leaf,flags,dir_fd=parent)
                    try:
                        same_node(before,os.fstat(fd))
                        count = flist(fd,None,0,0)
                        same_node(before,os.fstat(fd))
                    finally:
                        os.close(fd)
                same_node(before,os.stat(leaf,dir_fd=parent,follow_symlinks=False))
                same_node(parent_before,os.fstat(parent))
        require(count >= 0, 'UNSUPPORTED_NOFOLLOW_NATIVE_METADATA', UNSUPPORTED)
        require(count == 0, 'UNREVIEWED_NATIVE_METADATA')
        payload.check()
        if name != MANIFEST:
            observations.append({'path':name,'nofollow':True,'supported':True,'attributes':[]})
    return observations


@contextlib.contextmanager
def _ns_open_object(context,payload,row):
    with parent_at(payload.fd,row['path']) as (parent,leaf):
        before = os.stat(leaf,dir_fd=parent,follow_symlinks=False)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,'single-link native file required')
        fd = os.open(leaf,FLAGS,dir_fd=parent)
        try:
            same_node(before,os.fstat(fd))
            hasher, size, magic = hashlib.sha256(), 0, b''
            while True:
                context.budget.check()
                data = os.read(fd,min(1024*1024,context.bounds['regular_file_bytes']-size+1))
                if not data:
                    break
                if size == 0:
                    magic = data[:4]
                size += len(data)
                require(size <= context.bounds['regular_file_bytes'],'native streamed byte bound',MUTATION)
                hasher.update(data)
            require(size == row['bytes'] and hasher.hexdigest() == row['sha256'],'native file identity mismatch',MUTATION)
            same_node(before,os.fstat(fd)); os.lseek(fd,0,os.SEEK_SET)
            yield fd, magic
            same_node(before,os.fstat(fd))
            same_node(before,os.stat(leaf,dir_fd=parent,follow_symlinks=False))
            payload.check()
        finally:
            os.close(fd)


def _ns_bundle_mapping(rows,object_names):
    index = {r['path']:r for r in rows}
    seals = [r for r in rows if r['kind']=='file' and r['path'].endswith('/_CodeSignature/CodeResources')]
    result, targets = [], set()
    suffixes = ('.app','.framework','.bundle','.xpc','.appex')
    for seal in seals:
        seal_root = seal['path'][:-len('/_CodeSignature/CodeResources')]
        if seal_root.endswith('/Contents') and seal_root[:-9].endswith(('.app','.bundle','.xpc','.appex')):
            target = seal_root[:-9]
        elif re.fullmatch(r'.+\.framework/Versions/[^/]+',seal_root):
            target = seal_root.rsplit('/Versions/',1)[0]
        elif seal_root.endswith(suffixes):
            target = seal_root
        else:
            raise Rejected('UNSUPPORTED_NATIVE_BUNDLE_LAYOUT: '+seal_root,UNSUPPORTED)
        require(target not in targets, 'UNSUPPORTED_NATIVE_MULTIPLE_BUNDLE_SEALS',UNSUPPORTED)
        require(index.get(target,{}).get('kind')=='directory' and index.get(seal_root,{}).get('kind')=='directory',
                'native bundle physical roots missing')
        require(any(name.startswith(target+'/') for name in object_names),'native seal has no discovered code object')
        targets.add(target)
        result.append({'path':target,'seal_root':seal_root,
                       'code_resources':{k:seal[k] for k in ('path','bytes','sha256')}})
    for row in rows:
        if row['kind']=='directory' and row['path'].endswith(suffixes):
            if any(name.startswith(row['path']+'/') for name in object_names):
                require(row['path'] in targets,'unsealed independent code bundle')
    return sorted(result,key=lambda b:b['path'].encode('utf-8'))


def _ns_resolve_payload(index,path):
    parts, resolved, hops = path.split('/'), [], 0
    while parts:
        part, parts = parts[0],parts[1:]
        if part == '.':
            continue
        require(part != '', 'empty native path component')
        if part == '..':
            require(resolved,'escaping native dependency')
            resolved.pop(); continue
        resolved.append(part)
        name = '/'.join(resolved)
        row = index.get(name)
        if row is None:
            return None
        if row['kind']=='symlink':
            hops += 1
            require(hops <= 64, 'native dependency symlink bound',MUTATION)
            parts = row['target'].split('/')+parts
            resolved.pop()
        elif parts:
            require(row['kind']=='directory','native dependency through non-directory')
    return '/'.join(resolved) or '.'


def _ns_system(path,roots):
    return (path.startswith('/') and all(part not in ('','.','..') for part in path.split('/')[1:])
            and any(path.startswith(root+'/') for root in roots))


def _ns_anchor(path,source,executable):
    for token,origin in (('@loader_path',source),('@executable_path',executable)):
        if path == token or path.startswith(token+'/'):
            parent = origin.rpartition('/')[0]
            suffix = path[len(token):].lstrip('/')
            return '/'.join(p for p in (parent,suffix) if p) or '.'
    return None


def _native_resolved_edges(rows,objects,contexts,roots,budget=None):
    require(type(objects) is list and all(type(o) is dict and type(o.get('path')) is str
            and type(o.get('rpaths')) is list and all(type(p) is str for p in o['rpaths'])
            and type(o.get('load_commands')) is list for o in objects),'native object graph type')
    index, native = {r['path']:r for r in rows},{o['path']:o for o in objects}
    require(type(roots) is list and all(type(root) is str for root in roots)
            and len(roots)==len(set(roots)) and set(roots)<=set(_NS_SYSTEM_ROOTS),
            'unknown native system roots')
    require(type(contexts) is list and 1<=len(contexts)<=4096,'native launch-context bound')
    edges = []
    covered, context_ids = set(), set()
    for context in contexts:
        if budget is not None: budget.check()
        keys(context,('id','executable','loaded_objects'))
        require(type(context['id']) is str and context['id'] and context['id'] not in context_ids,
                'duplicate/invalid native launch context')
        context_ids.add(context['id'])
        executable = context['executable']; loaded = context['loaded_objects']
        require(type(executable) is str and executable in native and type(loaded) is list
                and all(type(path) is str for path in loaded) and executable in loaded
                and len(loaded)==len(set(loaded)) and set(loaded)<=set(native),'invalid native launch coverage')
        covered.update(loaded)
        # dyld's rpath stack depends on the chain that loaded a dylib. This
        # bounded grammar admits only a unique target across the source and
        # executable search roots. Other loader-chain layouts fail closed.
        for source in loaded:
            if budget is not None: budget.check()
            obj = native[source]
            for rpath in obj['rpaths']:
                require(type(rpath) is str and 0<len(rpath.encode('utf-8'))<=4096
                        and not any(ord(c)<32 or ord(c)==127 for c in rpath), 'native rpath bound/type')
                require(_ns_anchor(rpath,source,executable) is not None or _ns_system(rpath+'/',roots)
                        or rpath in roots or _ns_system(rpath,roots), 'unsupported native rpath',UNSUPPORTED)
            for command_index,command in enumerate(obj['load_commands']):
                if budget is not None: budget.check()
                require(type(command) is dict and type(command.get('cmd')) is str,'native load-command graph type')
                if command['cmd'] not in _NS_DEPENDENCIES:
                    continue
                name = command.get('name'); candidates = set()
                require(type(name) is str and 0<len(name.encode('utf-8'))<=4096
                        and not any(ord(c)<32 or ord(c)==127 for c in name), 'native install-name bound/type')
                if _ns_system(name,roots):
                    candidates.add(('system',name))
                else:
                    anchored = _ns_anchor(name,source,executable)
                    if anchored is not None:
                        resolved = _ns_resolve_payload(index,anchored)
                        if resolved in native:
                            candidates.add(('payload',resolved))
                    elif name.startswith('@rpath/'):
                        for origin in dict.fromkeys((source,executable)):
                            for rpath in native[origin]['rpaths']:
                                joined = rpath.rstrip('/')+'/'+name[len('@rpath/'):]
                                if _ns_system(joined,roots):
                                    candidates.add(('system',joined))
                                else:
                                    anchored = _ns_anchor(joined,origin,executable)
                                    require(anchored is not None,'unsupported native rpath anchor',UNSUPPORTED)
                                    resolved = _ns_resolve_payload(index,anchored)
                                    if resolved in native:
                                        candidates.add(('payload',resolved))
                    else:
                        raise Rejected('unresolved/external native load name')
                require(len(candidates)==1,'unresolved/ambiguous native dependency')
                target_kind,target = next(iter(candidates))
                # Reject any additional target a different loaded parent could
                # supply through dyld's rpath stack. This grammar intentionally
                # does not guess an unrecorded dynamic loader ancestry.
                if name.startswith('@rpath/'):
                    for origin in loaded:
                        if budget is not None: budget.check()
                        for rpath in native[origin]['rpaths']:
                            joined = rpath.rstrip('/')+'/'+name[len('@rpath/'):]
                            alternate = None
                            if _ns_system(joined,roots):
                                alternate = ('system',joined)
                            else:
                                anchored = _ns_anchor(joined,origin,executable)
                                require(anchored is not None,'unsupported native rpath anchor',UNSUPPORTED)
                                resolved = _ns_resolve_payload(index,anchored)
                                if resolved in native: alternate = ('payload',resolved)
                            require(alternate is None or alternate==(target_kind,target),
                                    'UNSUPPORTED_NATIVE_LOADER_CHAIN_AMBIGUITY',UNSUPPORTED)
                require(target_kind!='payload' or target in loaded,'resolved dependency missing launch closure')
                require(len(edges)<100000,'native dependency-edge bound',MUTATION)
                edges.append({'context':context['id'],'source':source,'load_command_index':command_index,
                              'install_name':name,'target_kind':target_kind,'target':target})
    require(covered==set(native),'native objects lack launch contexts')
    return sorted(edges,key=lambda x:(x['context'],x['source'].encode('utf-8'),x['load_command_index']))


def _ns_profile(payload_root):
    require(type(payload_root) is str and payload_root.startswith('/') and payload_root!='/'
            and os.path.normpath(payload_root)==payload_root and '\x00' not in payload_root,
            'invalid native sandbox payload root')
    quote = lambda value: json.dumps(value,ensure_ascii=True)
    reads = ('/System','/usr/lib','/usr/share','/Library/Apple',payload_root,'/dev/fd')
    read_rules = ' '.join('(subpath '+quote(path)+')' for path in reads)
    executables = ' '.join('(literal '+quote(path)+')' for path in _NS_TOOLS.values())
    return ('(version 1)(deny default)(deny network*)(deny file-write*)(deny process-fork)'
            '(allow file-read* '+read_rules+' (literal "/dev/null") '+executables+')'
            '(allow process-exec '+executables+')'
            '(allow sysctl-read)(allow mach-lookup)')


def _ns_target_pin(rows,path):
    if path == '.':
        return {'path':'.','bytes':0,'sha256':digest(b'')}
    row = next((row for row in rows if row['path']==path),None)
    require(row is not None,'unknown native tool target')
    if row['kind']=='file':
        return {k:row[k] for k in ('path','bytes','sha256')}
    require(row['kind']=='directory','native target is not physical file/directory')
    raw = canonical([row for row in rows if row['path']==path or row['path'].startswith(path+'/')])
    return {'path':path,'bytes':len(raw),'sha256':digest(raw)}


_NS_ROLES = {
    'host_arm64':('sysctl',('-n','hw.optional.arm64')),
    'lipo':('lipo',('-archs',)),
    'otool_libraries':('otool',('-L',)),
    'otool_loads':('otool',('-l',)),
    'codesign_display':('codesign',('-d','--verbose=4','-r-')),
    'codesign_entitlements':('codesign',('-d','--entitlements','-')),
    'codesign_verify':('codesign',('--verify','--strict','--verbose=2')),
}


class _NativeToolset:
    """Fixed Apple-tool capability, not a caller-extensible command runner."""
    def __init__(self,context,payload,rows):
        require(sys.platform=='darwin','NATIVE_REQUIRED',UNSUPPORTED)
        self.context,self.payload,self.rows = context,payload,rows
        self.deadline = min(context.budget.deadline,time.monotonic()+min(300,context.bounds['native_static_total_seconds']))
        self.events,self.artifacts,self.tools = [],{},{}
        self.output_bytes,self.counts = 0,{}
        self.stack = contextlib.ExitStack()
        try:
            for name,path in _NS_TOOLS.items():
                root = self.stack.enter_context(Root(Path(path).parent))
                for ancestor in root.fds:
                    info = os.fstat(ancestor)
                    require(info.st_uid==0 and not info.st_mode&0o022,
                            'UNSUPPORTED_UNTRUSTED_APPLE_TOOL_ANCESTOR',UNSUPPORTED)
                info = os.stat(Path(path).name,dir_fd=root.fd,follow_symlinks=False)
                require(stat.S_ISREG(info.st_mode) and info.st_uid==0 and not info.st_mode&0o022
                        and info.st_mode&0o111,'UNSUPPORTED_UNTRUSTED_APPLE_TOOL',UNSUPPORTED)
                row,_ = regular_at(root.fd,Path(path).name,context.budget)
                self.tools[name] = {'root':root,'info':info,
                    'identity':{'path':path,'bytes':row['bytes'],'sha256':row['sha256'],
                                'uid':0,'mode':stat.S_IMODE(info.st_mode)}}
        except BaseException:
            self.stack.close()
            raise

    def close(self):
        self.stack.close()

    def _check_tools(self):
        for name,item in self.tools.items():
            item['root'].check()
            same_node(item['info'],os.stat(Path(_NS_TOOLS[name]).name,
                                          dir_fd=item['root'].fd,follow_symlinks=False))

    def call(self,role,path,descriptor=None):
        require(role in _NS_ROLES,'unknown native tool role')
        self.context.budget.check(); self.payload.check(); self._check_tools()
        require(time.monotonic()<self.deadline,'native static deadline',MUTATION)
        tool,args = _NS_ROLES[role]
        is_bundle = path!='.' and next(row for row in self.rows if row['path']==path)['kind']=='directory'
        maximum = 4 if is_bundle else 6
        self.counts[path] = self.counts.get(path,0)+1
        require(self.counts[path] <= (1 if path=='.' else maximum),'native command count bound',MUTATION)
        if role=='host_arm64':
            target = None
            require(path=='.' and descriptor is None,'invalid native host target')
        elif is_bundle:
            require(descriptor is None,'native bundle descriptor mismatch')
            target = str(self.payload.path/path)
        else:
            require(type(descriptor) is int and descriptor>=0,'native file descriptor required')
            target = '/dev/fd/'+str(descriptor)
        profile = _ns_profile(str(self.payload.path))
        argv = [_NS_TOOLS['sandbox'],'-p',profile,_NS_TOOLS[tool],*args]
        if target is not None: argv.append(target)
        start_wall = datetime.datetime.now(datetime.timezone.utc).isoformat()
        interrupted = None
        try:
            result = _native_run_bounded(argv,min(self.deadline,time.monotonic()+min(30,self.context.bounds['native_command_seconds'])),
                pass_fds=() if descriptor is None else (descriptor,),env=_NS_ENV,
                cap=min(_NS_OUTPUT,self.context.bounds['native_command_output_bytes'],_NS_TOTAL_OUTPUT-self.output_bytes))
        except BaseException as exc:
            result = getattr(exc,'native_command_result',None)
            if result is None:
                raise
            interrupted = exc
        end_wall = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.output_bytes += len(result['stdout'])+len(result['stderr'])
        event_id = 'native-'+str(len(self.events)+1).zfill(6)
        pins = {}
        for stream in ('stdout','stderr'):
            name = 'commands/'+event_id+'.'+stream
            raw = result[stream]; self.artifacts[name] = raw
            pins[stream] = {'path':name,'kind':stream,'bytes':len(raw),'sha256':digest(raw)}
        event = {'id':event_id,'role':role,'payload_root':str(self.payload.path),'argv':argv,
                 'source':{'path':'scripts/reconstruct_runtime_payload.py',**self.context.sources['scripts/reconstruct_runtime_payload.py']},
                 'tool_identity':self.tools[tool]['identity'],'sandbox_identity':self.tools['sandbox']['identity'],
                 'target':_ns_target_pin(self.rows,path),'environment':dict(_NS_ENV),
                 'stdout':pins['stdout'],'stderr':pins['stderr'],
                 'outcome':{'kind':'exited' if result['returncode'] is not None and result['returncode']>=0 else 'failed',
                            'exit_status':result['returncode']},'reason':result['reason'],
                 'cleanup':result['cleanup'],'duration_ms':result['duration_ms'],
                 'started':start_wall,'ended':end_wall}
        self.events.append(event)
        if interrupted is not None:
            raise interrupted
        self._check_tools(); self.payload.check(); self.context.budget.check()
        require(self.output_bytes<=_NS_TOTAL_OUTPUT,'native aggregate output bound',MUTATION)
        require(result['cleanup']['complete'] and result['reason'] is None,
                'native command resource/cleanup failure',MUTATION)
        require(result['returncode']==0,'UNSUPPORTED_NATIVE_TOOL_CAPABILITY_OR_VERIFICATION_FAILURE',UNSUPPORTED)
        return result['stdout'],result['stderr'],target


def _ns_event_stream(event,stream,artifacts):
    item = event[stream]
    keys(item,('path','kind','bytes','sha256'))
    relative(item['path']); pin({'bytes':item['bytes'],'sha256':item['sha256']})
    require(item['kind']==stream and item['bytes']<=_NS_OUTPUT,'native stream kind/size')
    raw = artifacts.get(item['path'])
    require(type(raw) is bytes and len(raw)==item['bytes'] and digest(raw)==item['sha256'],
            'native raw tool output pin mismatch')
    return raw


def _ns_validate_event(context,rows,event,artifacts):
    keys(event,('id','role','payload_root','argv','source','tool_identity','sandbox_identity','target',
                'environment','stdout','stderr','outcome','reason','cleanup','duration_ms','started','ended'))
    require(type(event['id']) is str and re.fullmatch(r'native-[0-9]{6}',event['id']),'invalid native event id')
    role = event['role']; require(type(role) is str and role in _NS_ROLES,'unrecognized native tool event')
    tool,args = _NS_ROLES[role]
    expected_source = {'path':'scripts/reconstruct_runtime_payload.py',**context.sources['scripts/reconstruct_runtime_payload.py']}
    require(canonical(event['source'])==canonical(expected_source),'native event source identity mismatch')
    for key,name in (('tool_identity',tool),('sandbox_identity','sandbox')):
        value = event[key]
        keys(value,('path','bytes','sha256','uid','mode'))
        pin({'bytes':value['bytes'],'sha256':value['sha256']})
        require(value['path']==_NS_TOOLS[name] and type(value['uid']) is int and value['uid']==0,
                'untrusted native tool identity')
        integer(value['mode'],0,0o7777)
        require(value['mode']&0o111 and not value['mode']&0o6022,'unsafe native tool mode')
    keys(event['target'],('path','bytes','sha256'))
    path = relative(event['target']['path'],root=True)
    require(canonical(event['target'])==canonical(_ns_target_pin(rows,path)),'native event target mismatch')
    require(event['environment']==_NS_ENV,'native event environment mismatch')
    argv = event['argv']; require(type(argv) is list and all(type(a) is str for a in argv),'native event argv')
    prefix = [_NS_TOOLS['sandbox'],'-p',_ns_profile(event['payload_root']),_NS_TOOLS[tool],*args]
    if role=='host_arm64':
        require(path=='.' and argv==prefix,'native host argv mismatch'); target = None
    else:
        require(len(argv)==len(prefix)+1 and argv[:-1]==prefix,'native tool argv mismatch')
        target = argv[-1]
        row = next(row for row in rows if row['path']==path)
        if row['kind']=='file':
            require(re.fullmatch(r'/dev/fd/[0-9]+',target),'native file descriptor target required')
        else:
            require(row['kind']=='directory' and target==event['payload_root']+'/'+path,'native bundle target mismatch')
    keys(event['outcome'],('kind','exit_status'))
    require(event['outcome']['kind']=='exited' and type(event['outcome']['exit_status']) is int
            and event['outcome']['exit_status']==0 and event['reason'] is None,'native command did not exit zero')
    cleanup = event['cleanup']; keys(cleanup,('remaining_owned_processes','open_output_pipes','complete','duration_ms'))
    integer(cleanup['remaining_owned_processes'],0,0); integer(cleanup['open_output_pipes'],0,0)
    require(cleanup['complete'] is True,'native tool cleanup incomplete',MUTATION)
    integer(cleanup['duration_ms'],0,2000); integer(event['duration_ms'],0,32000)
    for field in ('started','ended'):
        require(type(event[field]) is str and len(event[field])<=100,'invalid native diagnostic timestamp')
        try:
            parsed = datetime.datetime.fromisoformat(event[field])
        except ValueError as exc:
            raise Rejected('invalid native diagnostic timestamp') from exc
        require(parsed.utcoffset() is not None,'native diagnostic timestamp lacks timezone')
    stdout,stderr = _ns_event_stream(event,'stdout',artifacts),_ns_event_stream(event,'stderr',artifacts)
    require(len(stdout)+len(stderr)<=_NS_OUTPUT,'native combined output bound',MUTATION)
    return path,role,target,stdout,stderr


def _ns_inventory_shape(inventory):
    keys(inventory,('objects','code_bundles','launch_contexts','system_roots','system_targets'))
    require(type(inventory['objects']) is list and 1<=len(inventory['objects'])<=4096,'native object bound')
    require(type(inventory['code_bundles']) is list and len(inventory['code_bundles'])<=4096,'native bundle bound')
    require(type(inventory['launch_contexts']) is list and 1<=len(inventory['launch_contexts'])<=4096,'native context bound')
    for item in inventory['objects']:
        keys(item,('path','bytes','sha256','architectures','platform','minimum_os','sdk',
                   'install_name','rpaths','load_commands','signature'))
        relative(item['path']); pin({'bytes':item['bytes'],'sha256':item['sha256']})
        require(type(item['architectures']) is list and all(type(arch) is str for arch in item['architectures']),
                'native architecture type')
        require(type(item['rpaths']) is list and all(type(path) is str for path in item['rpaths']),
                'native rpath type')
        require(type(item['load_commands']) is list and 1<=len(item['load_commands'])<=4096
                and all(type(command) is dict and type(command.get('cmd')) is str for command in item['load_commands']),
                'native load-command type')
        require(type(item['signature']) is dict,'native signature type')
    for item in inventory['code_bundles']:
        keys(item,('path','seal_root','signature','code_resources'))
        relative(item['path']); relative(item['seal_root'])
        keys(item['code_resources'],('path','bytes','sha256'))
        relative(item['code_resources']['path'])
        pin({k:item['code_resources'][k] for k in ('bytes','sha256')})
        require(type(item['signature']) is dict,'native bundle signature type')
    for item in inventory['launch_contexts']:
        keys(item,('id','executable','loaded_objects'))
        require(type(item['id']) is str and 0<len(item['id'].encode('utf-8'))<=200,'native context id type')
        relative(item['executable'])
        require(type(item['loaded_objects']) is list and 1<=len(item['loaded_objects'])<=4096,
                'native loaded-object bound')
        for path in item['loaded_objects']: relative(path)
    roots = inventory['system_roots']
    require(type(roots) is list and 1<=len(roots)<=3 and all(type(root) is str for root in roots)
            and len(roots)==len(set(roots)) and set(roots)<=set(_NS_SYSTEM_ROOTS),'native system-root type')
    _ns_system_target_shape(inventory['system_targets'],roots)
    # Catch non-JSON nested scalar/container values before equality/hashing.
    canonical(inventory)


def _ns_system_target_shape(targets,roots):
    require(type(targets) is list and len(targets)<=100000,'native system-target bound')
    seen = set()
    for item in targets:
        keys(item,('context','architecture','target','availability','file','cache_uuid'))
        require(type(item['context']) is str and item['context'] and len(item['context'].encode())<=200,
                'native system-target context')
        require(item['architecture']=='arm64' and type(item['target']) is str
                and len(item['target'].encode())<=4096 and _ns_system(item['target'],roots),
                'native system-target architecture/path')
        key = item['context'],item['architecture'],item['target']
        require(key not in seen,'duplicate native system target'); seen.add(key)
        if item['availability']=='file':
            pin(item['file'])
            require(item['file']['bytes']>0 and item['cache_uuid'] is None,'native system-file availability facts')
        else:
            require(item['availability']=='dyld_shared_cache' and item['file'] is None
                    and type(item['cache_uuid']) is str and re.fullmatch('[0-9a-f]{32}',item['cache_uuid']),
                    'native system-cache availability facts')
    require(targets==sorted(targets,key=lambda item:(item['context'],item['architecture'],item['target'])),
            'native system targets must be sorted')


def _ns_system_cache(path):
    # Apple dyld.h declares bool (... const char*); dyld_priv.h declares
    # bool (... uuid_t), with XNU uuid_t an unsigned char[16]. Primary-source
    # declarations/links are recorded in integration notes. Never load path.
    require(sys.platform=='darwin','NATIVE_REQUIRED',UNSUPPORTED)
    require(type(path) is str and path.startswith('/') and '\x00' not in path
            and len(path.encode('utf-8'))<=4096,'invalid native cache path')
    try:
        system = ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
        contains = system._dyld_shared_cache_contains_path
        cache_uuid = system._dyld_get_shared_cache_uuid
        contains.argtypes=[ctypes.c_char_p]; contains.restype=ctypes.c_bool
        cache_uuid.argtypes=[ctypes.POINTER(ctypes.c_ubyte)]; cache_uuid.restype=ctypes.c_bool
    except (AttributeError,OSError) as exc:
        raise Rejected('UNSUPPORTED_DYLD_CACHE_API',UNSUPPORTED) from exc
    before=(ctypes.c_ubyte*16)(); after=(ctypes.c_ubyte*16)()
    require(cache_uuid(before),'UNSUPPORTED_DYLD_SHARED_CACHE_INACTIVE',UNSUPPORTED)
    present=bool(contains(path.encode('utf-8')))
    require(cache_uuid(after) and bytes(before)==bytes(after),'native dyld cache identity changed',MUTATION)
    require(any(before),'UNSUPPORTED_DYLD_CACHE_UUID',UNSUPPORTED)
    return present,bytes(before).hex()


def _ns_system_file(context,path):
    """Read only a held, root-owned physical system file; no alias fallback."""
    try:
        with Root(Path(path).parent) as root:
            for fd in root.fds:
                info = os.fstat(fd)
                require(info.st_uid==0 and not info.st_mode&0o022,'unsafe system target ancestor')
            info = os.stat(Path(path).name,dir_fd=root.fd,follow_symlinks=False)
            require(stat.S_ISREG(info.st_mode) and info.st_uid==0 and not info.st_mode&0o022,
                    'unsafe/nonregular system target')
            maximum=min(1_000_000_000,context.bounds['regular_file_bytes'])
            require(info.st_nlink==1 and 32<=info.st_size<=maximum,'native system-file size/link bound',MUTATION)
            fd=os.open(Path(path).name,FLAGS,dir_fd=root.fd)
            try:
                same_node(info,os.fstat(fd))
                header=os.read(fd,32)
                require(len(header)==32 and header[:4]==b'\xcf\xfa\xed\xfe',
                        'UNSUPPORTED_SYSTEM_TARGET_MACHO_LAYOUT',UNSUPPORTED)
                _,cpu,subtype,filetype,ncmds,command_bytes,_,_=struct.unpack('<8I',header)
                require(cpu==0x0100000c and subtype==0 and filetype==6 and 1<=ncmds<=4096
                        and ncmds*8<=command_bytes<=info.st_size-32,
                        'UNSUPPORTED_SYSTEM_TARGET_ARCHITECTURE_OR_LAYOUT',UNSUPPORTED)
                os.lseek(fd,0,os.SEEK_SET)
                size,hasher=0,hashlib.sha256()
                while True:
                    context.budget.check()
                    data=os.read(fd,min(1024*1024,maximum-size+1))
                    if not data: break
                    size+=len(data); require(size<=maximum,'native system-file streamed bound',MUTATION)
                    hasher.update(data)
                same_node(info,os.fstat(fd))
                same_node(info,os.stat(Path(path).name,dir_fd=root.fd,follow_symlinks=False))
                require(size==info.st_size,'native system file changed size',MUTATION)
            finally:
                os.close(fd)
            root.check()
            return {'bytes':size,'sha256':hasher.hexdigest()}
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise Rejected('UNSUPPORTED_SYSTEM_TARGET_FILE_INSPECTION',UNSUPPORTED) from exc


def _native_system_targets(context,objects,contexts,edges,roots):
    """Mandatory current-host proof after lexical dependency recomputation.

    No dlopen/dlsym is applied to dependency paths and no candidate executes.
    Cache lookup uses only a fixed verified system API. Disk targets are hashed
    through held no-follow capabilities and root-only ancestry.
    """
    require(sys.platform=='darwin','NATIVE_REQUIRED',UNSUPPORTED)
    require(os.uname().machine=='arm64','NATIVE_ARM64_FINALIZER_REQUIRED',UNSUPPORTED)
    object_index = {obj['path']:obj for obj in objects}
    context_index = {item['id']:item for item in contexts}
    requested = sorted({(edge['context'],edge['target']) for edge in edges if edge['target_kind']=='system'})
    require(len(requested)<=100000 and len({path for _,path in requested})<=4096,'native system-target bound',MUTATION)
    cache,output,total_file_bytes = {},[],0
    for context_id,path in requested:
        context.budget.check()
        require(context_id in context_index and object_index[context_index[context_id]['executable']]['architectures']==['arm64'],
                'native system-target launch architecture')
        require(_ns_system(path,roots),'native system target outside fixed roots')
        if path not in cache:
            api_supported = True
            try:
                present,cache_uuid = _ns_system_cache(path)
            except Rejected as exc:
                if exc.code!=UNSUPPORTED: raise
                api_supported=False; present=False; cache_uuid=None
            file_pin = _ns_system_file(context,path)
            if file_pin is not None:
                total_file_bytes += file_pin['bytes']
                require(total_file_bytes<=1_000_000_000,'native aggregate system-file bound',MUTATION)
            require(not (present and file_pin is not None),'UNSUPPORTED_AMBIGUOUS_SYSTEM_TARGET_REPRESENTATION',UNSUPPORTED)
            if present:
                require(type(cache_uuid) is str and re.fullmatch('[0-9a-f]{32}',cache_uuid),'invalid native cache UUID')
                facts = {'availability':'dyld_shared_cache','file':None,'cache_uuid':cache_uuid}
            elif file_pin is not None:
                facts = {'availability':'file','file':file_pin,'cache_uuid':None}
            else:
                require(api_supported,'UNSUPPORTED_DYLD_CACHE_INSPECTION',UNSUPPORTED)
                raise Rejected('unresolved system dependency: '+path)
            cache[path]=facts
        output.append({'context':context_id,'architecture':'arm64','target':path,**cache[path]})
    _ns_system_target_shape(output,roots)
    require(len(canonical(output))<=_NS_OUTPUT,'native system-target facts bound',MUTATION)
    return output


_NS_SYSTEM_API = 'darwin_system_targets_v1'


def _ns_system_event(context,targets,start,started):
    raw = canonical({'kind':'darwin_system_target_availability_v1','system_targets':targets})
    require(len(raw)<=_NS_OUTPUT,'native system-target artifact bound',MUTATION)
    path = 'commands/native-system-targets.stdout'
    event = {'id':'native-system-targets','role':'system_targets','source':{
        'path':'scripts/reconstruct_runtime_payload.py',**context.sources['scripts/reconstruct_runtime_payload.py']},
        'api':_NS_SYSTEM_API,'argv':[],'target_architecture':'arm64',
        'facts_artifact':{'path':path,'kind':'canonical_facts','bytes':len(raw),'sha256':digest(raw)},
        'cleanup':{'owned_processes_created':0,'open_descriptors':0,'complete':True},
        'duration_ms':int((time.monotonic()-start)*1000),'started':started,
        'ended':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    return event,path,raw


def _ns_validate_system_event(context,event,artifacts,roots):
    keys(event,('id','role','source','api','argv','target_architecture','facts_artifact','cleanup',
                'duration_ms','started','ended'))
    require(event['id']=='native-system-targets' and event['role']=='system_targets'
            and event['api']==_NS_SYSTEM_API and event['argv']==[] and event['target_architecture']=='arm64',
            'native system-target operation mismatch')
    source = {'path':'scripts/reconstruct_runtime_payload.py',**context.sources['scripts/reconstruct_runtime_payload.py']}
    require(canonical(event['source'])==canonical(source),'native system-target source mismatch')
    item = event['facts_artifact']; keys(item,('path','kind','bytes','sha256'))
    relative(item['path']); pin({k:item[k] for k in ('bytes','sha256')})
    require(item['kind']=='canonical_facts' and item['bytes']<=_NS_OUTPUT,'native system-target artifact kind/bound')
    raw = artifacts.get(item['path'])
    require(type(raw) is bytes and len(raw)==item['bytes'] and digest(raw)==item['sha256'],
            'native system-target raw artifact mismatch')
    value = strict_json(raw)
    require(canonical(value)==raw,'noncanonical native system-target facts')
    keys(value,('kind','system_targets'))
    require(value['kind']=='darwin_system_target_availability_v1','wrong native system-target parser kind')
    _ns_system_target_shape(value['system_targets'],roots)
    keys(event['cleanup'],('owned_processes_created','open_descriptors','complete'))
    integer(event['cleanup']['owned_processes_created'],0,0); integer(event['cleanup']['open_descriptors'],0,0)
    require(event['cleanup']['complete'] is True,'native API cleanup incomplete',MUTATION)
    integer(event['duration_ms'],0,300000)
    for field in ('started','ended'):
        require(type(event[field]) is str and 0<len(event[field])<=100,'native API diagnostic timestamp')
        try: parsed=datetime.datetime.fromisoformat(event[field])
        except ValueError as exc: raise Rejected('native API diagnostic timestamp') from exc
        require(parsed.utcoffset() is not None,'native API timestamp timezone missing')
    return value['system_targets'],raw


def _parse_native_static_evidence(context,rows,inventory,tool_events,artifacts):
    """Reparse retained genuine-tool evidence using exactly the fresh grammar.

    Artifacts are a bounded, already read path->bytes map. This function never
    treats observations or incoming native facts as a substitute for raw output.
    Source-owned approval still supplies provenance and expected identities.
    """
    _ns_inventory_shape(inventory)
    require(type(tool_events) is list and 1<=len(tool_events)<=1+6*4096+4*4096,'native event bound')
    object_index = {item['path']:item for item in inventory['objects']}
    bundle_index = {item['path']:item for item in inventory['code_bundles']}
    require(len(object_index)==len(inventory['objects']) and len(bundle_index)==len(inventory['code_bundles'])
            and not set(object_index)&set(bundle_index),'duplicate native targets')
    expected = {('.','host_arm64')}
    object_roles = ('lipo','otool_libraries','otool_loads','codesign_display','codesign_entitlements','codesign_verify')
    signature_roles = ('codesign_display','codesign_entitlements','codesign_verify')
    expected.update((path,role) for path in object_index for role in object_roles)
    expected.update((path,role) for path in bundle_index for role in signature_roles)
    parsed, event_ids, artifact_paths = {},set(),set()
    system_targets = None
    output_bytes,total_ms = 0,0
    payload_roots,tool_identities = set(),{}
    for event in tool_events:
        if hasattr(context,'budget'): context.budget.check()
        require(type(event) is dict,'native event object required')
        if event.get('role')=='system_targets':
            require(system_targets is None,'duplicate native system-target event')
            system_targets,raw = _ns_validate_system_event(context,event,artifacts,inventory['system_roots'])
            require(event['facts_artifact']['path'] not in artifact_paths,'native system-target artifact collision')
            artifact_paths.add(event['facts_artifact']['path']); event_ids.add(event['id'])
            output_bytes += len(raw); total_ms += event['duration_ms']
            require(output_bytes<=_NS_TOTAL_OUTPUT and total_ms<=300000,'native aggregate output/time bound',MUTATION)
            continue
        path,role,target,stdout,stderr = _ns_validate_event(context,rows,event,artifacts)
        key = path,role
        require(key in expected and key not in parsed and event['id'] not in event_ids,'duplicate/unexpected native tool event')
        parsed[key] = (target,stdout,stderr); event_ids.add(event['id'])
        payload_roots.add(event['payload_root'])
        for name in ('tool_identity','sandbox_identity'):
            tool = event[name]
            prior = tool_identities.setdefault(tool['path'],tool)
            require(canonical(tool)==canonical(prior),'native tool identity changed between events')
        for name in ('stdout','stderr'):
            require(event[name]['path'] not in artifact_paths,'native output artifact collision')
            artifact_paths.add(event[name]['path'])
        output_bytes += len(stdout)+len(stderr); total_ms += event['duration_ms']
        require(output_bytes<=_NS_TOTAL_OUTPUT and total_ms<=300000,'native aggregate output/time bound',MUTATION)
    require(set(parsed)==expected and len(payload_roots)==1 and system_targets is not None,
            'missing native static event coverage')
    _,stdout,stderr = parsed[('.','host_arm64')]
    require(stdout==b'1\n' and stderr==b'','NATIVE_ARM64_REQUIRED',UNSUPPORTED)
    objects = []
    for path in sorted(object_index,key=lambda p:p.encode('utf-8')):
        if hasattr(context,'budget'): context.budget.check()
        target,stdout,stderr = parsed[(path,'lipo')]
        architectures = _parse_native_lipo(stdout,stderr)
        require(architectures==['arm64'],'UNSUPPORTED_NATIVE_MULTIARCH_SIGNATURE_IDENTITY',UNSUPPORTED)
        target,stdout,stderr = parsed[(path,'otool_loads')]
        facts = _parse_native_otool_loads(stdout,stderr,target,architectures)
        target,stdout,stderr = parsed[(path,'otool_libraries')]
        libraries = _parse_native_otool_libraries(stdout,stderr,target,architectures)
        _ns_check_otool_agreement(facts,libraries)
        target,stdout,stderr = parsed[(path,'codesign_display')]
        payload_root = next(iter(payload_roots))
        signature = _parse_native_codesign_display(stdout,stderr,target,(payload_root+'/'+path,))
        target,stdout,stderr = parsed[(path,'codesign_entitlements')]
        signature['entitlements'] = _parse_native_entitlements(stdout,stderr,target)
        target,stdout,stderr = parsed[(path,'codesign_verify')]
        _parse_native_codesign_verify(stdout,stderr,target)
        obj = {**_ns_target_pin(rows,path),'architectures':architectures,**facts,'signature':signature}
        require(canonical(obj)==canonical(object_index[path]),'fresh/retained native object differs from source approval')
        objects.append(obj)
    bundles = []
    discovered_bundles = _ns_bundle_mapping(rows,set(object_index))
    require({b['path'] for b in discovered_bundles}==set(bundle_index),'independent code bundle inventory mismatch')
    for discovered in discovered_bundles:
        path = discovered['path']
        target,stdout,stderr = parsed[(path,'codesign_display')]
        allowed_executables = tuple(next(iter(payload_roots))+'/'+name for name in object_index
                                    if name.startswith(path+'/'))
        signature = _parse_native_codesign_display(stdout,stderr,target,allowed_executables)
        target,stdout,stderr = parsed[(path,'codesign_entitlements')]
        signature['entitlements'] = _parse_native_entitlements(stdout,stderr,target)
        target,stdout,stderr = parsed[(path,'codesign_verify')]
        _parse_native_codesign_verify(stdout,stderr,target)
        bundle = {**discovered,'signature':signature}
        require(canonical(bundle)==canonical(bundle_index[path]),'native bundle differs from source approval')
        bundles.append(bundle)
    contexts = inventory['launch_contexts']
    edges = _native_resolved_edges(rows,objects,contexts,inventory['system_roots'],getattr(context,'budget',None))
    requested = {(edge['context'],'arm64',edge['target']) for edge in edges if edge['target_kind']=='system'}
    require({(item['context'],item['architecture'],item['target']) for item in system_targets}==requested,
            'incomplete/extra native system-target proof coverage')
    require(canonical(system_targets)==canonical(inventory['system_targets']),
            'native system targets differ from source approval')
    facts = {'native_objects':objects,'code_bundles':bundles,'launch_contexts':contexts,
             'resolved_edges':edges,'system_targets':system_targets}
    return {'parsed_static_facts':facts,'verified_static_tool_events':tool_events}


def _verify_native_static(context,payload,approved_native_inventory,*,manifest_pin=None):
    """Fresh, purpose-specific Darwin verifier. Never signs or runs payload code.

    manifest_pin is supplied only by the parent's deterministic serializer on
    a validated resume path. The public finalize API has no manifest override.
    Failure exposes bounded raw capture as exception.native_static_capture so
    the parent can preserve it in its unaccepted private transaction directory.
    """
    require(sys.platform=='darwin','NATIVE_REQUIRED',UNSUPPORTED)
    require(context.phase=='native','native Context required')
    require('Resources/Runtime/dot_process.py' in context.sources,'native process helper not source-pinned')
    context.budget.check(); payload.check()
    before = tree(payload.path,context.budget,manifest_pin=manifest_pin)
    metadata_before = _native_empty_xattrs(context,payload,before,manifest_pin)
    native_names = []
    for row in before:
        if row['kind']=='file':
            with _ns_open_object(context,payload,row) as (_,magic):
                if magic in _NS_MAGIC:
                    native_names.append(row['path'])
                    require(len(native_names)<=min(4096,context.bounds['native_objects']),'native object bound',MUTATION)
    inventory = approved_native_inventory
    _ns_inventory_shape(inventory)
    require(native_names==[obj['path'] for obj in inventory['objects']],
            'byte-discovered native inventory mismatch')
    discovered = _ns_bundle_mapping(before,set(native_names))
    require(discovered==[{k:item[k] for k in ('path','seal_root','code_resources')}
                         for item in inventory['code_bundles']],'independent native bundle discovery mismatch')
    tools = None
    try:
        tools = _NativeToolset(context,payload,before)
        tools.call('host_arm64','.')
        index = {row['path']:row for row in before}
        for name in native_names:
            with _ns_open_object(context,payload,index[name]) as (fd,magic):
                require(magic in _NS_MAGIC,'native magic changed',MUTATION)
                for role in ('lipo','otool_libraries','otool_loads','codesign_display','codesign_entitlements','codesign_verify'):
                    tools.call(role,name,descriptor=fd)
        for bundle in discovered:
            with Root(payload.path/bundle['path']) as held_bundle:
                held_bundle.check()
                for role in ('codesign_display','codesign_entitlements','codesign_verify'):
                    tools.call(role,bundle['path'])
                held_bundle.check()
        system_start = time.monotonic()
        system_started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        lexical_edges = _native_resolved_edges(before,inventory['objects'],inventory['launch_contexts'],
                                               inventory['system_roots'],context.budget)
        targets = _native_system_targets(context,inventory['objects'],inventory['launch_contexts'],
                                         lexical_edges,inventory['system_roots'])
        event,path,raw = _ns_system_event(context,targets,system_start,system_started)
        require(path not in tools.artifacts,'fresh system-target output collision')
        tools.artifacts[path]=raw; tools.events.append(event); tools.output_bytes+=len(raw)
        require(tools.output_bytes<=_NS_TOTAL_OUTPUT and time.monotonic()<=tools.deadline,
                'native static aggregate bound',MUTATION)
        parsed = _parse_native_static_evidence(context,before,inventory,tools.events,tools.artifacts)
        metadata_after = _native_empty_xattrs(context,payload,before,manifest_pin)
        after = tree(payload.path,context.budget,manifest_pin=manifest_pin)
        require(canonical(before)==canonical(after),'payload changed during native verification',MUTATION)
        require(metadata_before==metadata_after,'payload metadata changed during native verification',MUTATION)
        context.budget.check(); payload.check()
        return {**parsed['parsed_static_facts'],'tool_events':tools.events,'raw_artifacts':tools.artifacts,
                'metadata_empty_before':metadata_before,'metadata_empty_after':metadata_after}
    except BaseException as exc:
        if tools is not None:
            try:
                exc.native_static_capture = {'tool_events':tools.events,'raw_artifacts':tools.artifacts}
            except (AttributeError,TypeError):
                pass
        raise
    finally:
        if tools is not None:
            tools.close()

"""Pure schema-2 gate fragment; integrate after reconstruct_runtime_payload helpers.

No IO or platform probes are performed here. ``artifacts`` is the parent's
already bounded retained path -> raw bytes map. Every referenced artifact is
nevertheless re-pinned here. ``expected`` is derived by the parent exclusively
from current Context, approved closure, lock and source-owned approval; it is not
read from a receipt. See INTEGRATION.md for the small exact interface.
"""

_NATIVE_GATE_IDS = (
    'actual_install_or_accepted_historical_basis',
    'installed_voice_distributions_and_pip_check',
    'final_nested_signatures_and_linkage',
    'product_profile_offline_import',
    'product_profile_real_voice_synthesis',
    'voice_cancellation_eof_cleanup',
    'splash_v2_listener_secret_pipe_tls_cleanup',
    'relocation_with_spaces_commas_unicode',
    'immutable_payload_before_after',
)
_NATIVE_GATE_FIELDS = (
    ('mode','basis_identity','collector_bundle_identity','historical_manifest',
     'prepared_identity','transform_identity'),
    ('interpreter','distributions','bootstrap_exceptions','package_origins','sys_path','pip_check_event'),
    ('native_objects','code_bundles','launch_contexts','resolved_edges','system_targets','tool_events',
     'metadata_empty_before','metadata_empty_after'),
    ('interpreter','profile_sha256','environment_artifact','initial_private_closure',
     'imports','package_data','denial_cases'),
    ('helper_sha256','model_pins','request','hello_event','audio_event','wav_artifact',
     'wav_facts','output_created_after_request'),
    ('helper_sha256','cancel_case','after_cancel_case','eof_case','shutdown_case','remaining_output_paths'),
    ('source_pins','profile_sha256','model_input_admission','listener_case','credential_case',
     'inference_case','tls_cases','cleanup_cases'),
    ('relative_test_path','espeak_absolute_path_utf8_bytes','relocated_signed_identity',
     'empty_private_roots','voice_case_artifacts','splash_case_artifacts','before_identity','after_identity'),
    ('gate_closures','metadata_empty_before','metadata_empty_after','external_input_rechecks'),
)

_NATIVE_EXPECTATION_FIELDS = dict(zip(_NATIVE_GATE_IDS, (
    (),
    ('interpreter','bootstrap_exceptions','package_origins','sys_path','facts_artifact',
     'facts_event_artifact','facts_event_id','probe_sources','probe_argv'),
    ('resolved_edges','pre_sign_inventory','pre_sign_tool_events_artifact','native_changes'),
    ('interpreter','voice_environment','imports','package_data','denial_cases','facts_artifact',
     'facts_event_artifact','facts_event_id','probe_sources','probe_argv'),
    ('voice_request','voice_trace_artifact','voice_trace_event_artifact','voice_launch','probe_sources','probe_argv'),
    ('case_event_ids','case_requests','case_producer_event_artifacts','voice_launch','probe_sources','probe_argv'),
    ('model_input_admission','splash_source_pins','case_event_ids','case_producer_event_artifacts',
     'probe_sources','probe_argv','tls_certificate_sha256','urlsession_harness'),
    ('relocation_relative_path','relocated_payload_root','relocated_espeak_path','relocated_contract'),
    ('model_input_admission','facts_artifact','facts_event_artifact','facts_event_id','probe_sources','probe_argv'),
)))


def _ng_text(value, label, maximum=4096):
    require(type(value) is str and 0 < len(value.encode('utf-8')) <= maximum
            and '\x00' not in value, 'invalid native ' + label)
    return value


def _ng_sha(value):
    require(type(value) is str and SHA.fullmatch(value), 'invalid native identity')
    return value


def _ng_equal(actual, expected, label):
    # Python's True == 1 must never weaken approval equality.
    require(canonical(actual) == canonical(expected), 'native ' + label + ' mismatch')


def _ng_list(value, low=0, high=100000):
    require(type(value) is list and low <= len(value) <= high, 'native list bound')
    return value


def _ng_file(item, files):
    keys(item, ('path','bytes','sha256'))
    name = relative(item['path'])
    pin({'bytes':item['bytes'],'sha256':item['sha256']})
    row = files.get(name)
    require(type(row) is dict and row.get('kind') == 'file', 'native regular closure file required')
    _ng_equal({'bytes':item['bytes'],'sha256':item['sha256']},
              {'bytes':row['bytes'],'sha256':row['sha256']}, 'closure file pin')
    return name


def _ng_artifact(item, kind, artifacts):
    keys(item, ('path','kind','bytes','sha256'))
    name = relative(item['path'])
    require(item['kind'] in ('receipt','stdout','stderr','canonical_facts','wav')
            and item['kind'] == kind, 'native artifact kind mismatch')
    maximum = {'receipt':MAX_JSON, 'stdout':2097152, 'stderr':2097152,
               'canonical_facts':MAX_JSON, 'wav':3000000}[kind]
    integer(item['bytes'], 0 if kind in ('stdout','stderr') else 1, maximum)
    _ng_sha(item['sha256'])
    raw = artifacts.get(name)
    require(type(raw) is bytes and len(raw) == item['bytes'] and digest(raw) == item['sha256'],
            'native raw artifact pin mismatch')
    return raw


def _ng_facts(item, artifacts):
    raw = _ng_artifact(item, 'canonical_facts', artifacts)
    value = strict_json(raw)
    require(canonical(value) == raw, 'native facts artifact not canonical')
    return value


def _ng_cleanup(value):
    keys(value, ('remaining_owned_processes','open_output_pipes','complete','duration_ms'))
    integer(value['remaining_owned_processes'], 0, 0)
    integer(value['open_output_pipes'], 0, 0)
    require(value['complete'] is True, 'native cleanup incomplete', MUTATION)
    integer(value['duration_ms'], 0, 2000)


def _ng_outcome(value):
    keys(value, ('kind','exit_status'))
    require(value['kind'] == 'exited', 'native non-exited outcome')
    integer(value['exit_status'], 0, 0)


def _ng_source(item, sources):
    keys(item, ('path','bytes','sha256'))
    name = relative(item['path'])
    pin({'bytes':item['bytes'],'sha256':item['sha256']})
    require(name in sources, 'native probe source not in Context identity map')
    _ng_equal({'bytes':item['bytes'],'sha256':item['sha256']}, sources[name], 'source pin')
    return name


def _ng_absolute(value):
    _ng_text(value, 'absolute path')
    require(value.startswith('/') and '//' not in value and '/./' not in value
            and '/..' not in value and not value.endswith('/'), 'noncanonical native absolute path')
    return value


def _ng_environment(item, expected, artifacts):
    value = _ng_facts(item, artifacts)
    require(type(value) is dict and len(value) <= 32
            and all(re.fullmatch('[A-Z][A-Z0-9_]{0,63}', k)
                    and type(v) is str and '\x00' not in v and len(v.encode('utf-8')) <= 4096
                    for k,v in value.items()), 'native environment map shape')
    # No receipt-provided regex, digest-only policy or unbounded inherited env.
    allowed = {'PATH','HOME','TMPDIR','XDG_CACHE_HOME','HF_HOME','HF_HUB_CACHE',
               'TRANSFORMERS_CACHE','HF_HUB_OFFLINE','TRANSFORMERS_OFFLINE',
               'HF_HUB_DISABLE_TELEMETRY','HF_HUB_DISABLE_IMPLICIT_TOKEN','PYTHONDONTWRITEBYTECODE','PYTHONNOUSERSITE',
               'ESPEAK_DATA_PATH','LANG','LC_ALL'}
    require(set(value) <= allowed and value.get('PATH') == '/usr/bin:/bin',
            'non-allowlisted native environment')
    for key in ('HOME','TMPDIR'):
        require(type(value.get(key)) is str and value[key].startswith('/'), 'private native environment root missing')
    require(value.get('PYTHONDONTWRITEBYTECODE') == '1', 'native bytecode writes enabled')
    _ng_equal(value, expected, 'allowlisted environment')
    return value


def _ng_event(event, expected, artifacts, role):
    """Validate one host event against the fixed expected invocation and raw IO.

    ``expected['events'][id]`` is an exact independently approved invocation,
    never a default copied from this event. Gate-specific argv grammar is checked
    in addition to byte equality with that approval.
    """
    keys(event, ('id','argv','source','target','environment_artifact','stdout','stderr',
                 'outcome','cleanup','duration_ms','started','ended'))
    event_id = _ng_text(event['id'], 'event id', 200)
    require(event_id in expected['events'], 'unapproved native event')
    invocation = expected['events'][event_id]
    keys(invocation, ('role','argv','source','target','environment'))
    require(invocation['role'] == role, 'native event role mismatch')
    _ng_source(event['source'], expected['source_identities'])
    if role == 'urlsession_probe':
        _ng_source(event['target'],expected['source_identities'])
        _ng_urlsession_build(expected,artifacts)
    else:
        _ng_file(event['target'], expected['files'])
    for name in ('argv','source','target'):
        _ng_equal(event[name], invocation[name], 'invocation ' + name)
    argv = _ng_list(event['argv'], 1, 128)
    for arg in argv: _ng_text(arg, 'argv item', 4096)
    _ng_environment(event['environment_artifact'], invocation['environment'], artifacts)
    if role == 'pip_check':
        require(argv == [expected['payload_root'] + '/' + event['target']['path'],
                         '-I','-B','-m','pip','check'], 'pip check launch grammar')
    elif role == 'voice_helper':
        require(event['source']['path'] == 'Resources/Voice/bionic_helper.py', 'wrong voice helper source')
        launch = expected['voice_launch']
        keys(launch, ('helper_path','profile_path','output_path','voice_root'))
        for path in launch.values(): _ng_absolute(path)
        require(launch['voice_root'] == expected['payload_root'] + '/Voice', 'external voice launch root')
        require(launch['helper_path'] == expected['source_root'] + '/Resources/Voice/bionic_helper.py'
                and launch['profile_path'] == expected['source_root'] + '/Resources/Voice/voice.sb',
                'voice launch not bound to current helper/profile source')
        require(event['target']['path'] == expected['interpreter']['path'], 'voice launch used other interpreter')
        fixed = ['/usr/bin/sandbox-exec','-D','DOT_OUTPUT=' + launch['output_path'],
                 '-D','DOT_VOICE_ROOT=' + launch['voice_root'],
                 '-D','DOT_VOICE_HELPER=' + launch['helper_path'],
                 '-D','DOT_PYTHON_ROOT=' + expected['payload_root'] + '/' + expected['voice_python_root'],
                 '-f',launch['profile_path'],expected['payload_root'] + '/' + event['target']['path'],
                 '-I','-B','-u',launch['helper_path'],'--root',launch['voice_root'],'--output',launch['output_path']]
        require(argv == fixed, 'voice product launch grammar')
        env = invocation['environment']
        require(env.get('HOME') == env.get('TMPDIR') == launch['output_path'], 'voice output/home mismatch')
        for flag in ('HF_HUB_OFFLINE','TRANSFORMERS_OFFLINE','HF_HUB_DISABLE_TELEMETRY','HF_HUB_DISABLE_IMPLICIT_TOKEN'):
            require(env.get(flag) == '1','voice offline environment missing')
    elif role == 'splash':
        require(event['source']['path'] == 'Resources/Runtime/dot_runtime.py', 'wrong Splash supervisor source')
        require(argv == expected['splash_argv'] and argv[0] == '/usr/bin/sandbox-exec'
                and all(flag in argv for flag in ('-I','-S','-B','-f'))
                and argv[argv.index('-f')+1] == expected['splash_profile_path'],
                'Splash product sandbox launch grammar')
    elif role in ('voice_probe','splash_probe','urlsession_probe','urlsession_builder'):
        require(event['source']['path'] == expected['probe_sources'][role], 'wrong fixed native probe program')
        require(argv == expected['probe_argv'][role], 'native probe launch grammar')
        forbidden = {'scripts/reconstruct_runtime_payload.py','scripts/patch_splash_listener.py','Resources/Voice/bionic_helper.py',
                     'Resources/Runtime/dot_runtime.py','Resources/Runtime/dot_process.py','Resources/Runtime/dot_tls.py'}
        require(event['source']['path'] not in forbidden, 'declared source does not implement a native observation probe')
        executable = expected['payload_root'] + '/' + event['target']['path']
        program = expected['source_root'] + '/' + event['source']['path']
        if role == 'urlsession_probe':
            harness = expected['urlsession_harness']
            _ng_equal(event['source'],harness['source'],'URLSession source binding')
            _ng_equal(event['target'],harness['binary'],'URLSession compiled target binding')
            require(argv == [expected['source_root'] + '/' + harness['binary']['path']],
                    'URLSession must execute exact source-owned compiled harness')
        else:
            require(event['source']['path'].endswith('.py'), 'native probe program is not Python source')
            if role in ('voice_probe','urlsession_builder'):
                require(event['target']['path'] == expected['interpreter']['path'], 'native probe uses wrong bundled interpreter')
            else:
                require(event['target']['path'] == _ng_resolve_required_interpreter(expected['files']),
                        'Splash probe did not use exact resolved bundled interpreter')
            direct = [executable,'-I','-B',program]
            wrapped = _ng_voice_probe_argv(event,expected,invocation['environment'])
            require(argv == direct or role == 'voice_probe' and argv == wrapped,
                    'native probe must execute exact source with fixed isolated-Python argv')
    else:
        raise Rejected('unknown native dynamic event role')
    _ng_outcome(event['outcome']); _ng_cleanup(event['cleanup'])
    integer(event['duration_ms'], 0, 600000)
    for name in ('started','ended'): _ng_text(event[name], 'wall diagnostic', 100)
    stdout = _ng_artifact(event['stdout'], 'stdout', artifacts)
    stderr = _ng_artifact(event['stderr'], 'stderr', artifacts)
    require(event['stdout']['path'] != event['stderr']['path'], 'native stdout/stderr collision')
    require(len(stdout) + len(stderr) <= 2097152, 'native command stream bound', MUTATION)
    if role in ('splash','splash_probe','urlsession_probe'):
        require(re.search(rb'"(?:api_key|access_token|private_key)"\s*:', stdout + stderr) is None,
                'secret-bearing raw process output cannot be retained')
    return stdout, stderr


def _ng_urlsession_build(expected, artifacts):
    require(type(expected.get('urlsession_harness')) is dict,
            'UNSUPPORTED_NATIVE_URLSESSION_HARNESS: source/binary/build provenance required',UNSUPPORTED)
    harness = expected['urlsession_harness']
    keys(harness, ('source','binary','build_artifact','build_event_artifact'))
    for field in ('source','binary'): _ng_source(harness[field],expected['source_identities'])
    require(harness['source']['path'].endswith('.swift')
            and harness['binary']['path'] != harness['source']['path'], 'URLSession source/binary identities')
    build_raw = _ng_artifact(harness['build_artifact'],'canonical_facts',artifacts)
    build = strict_json(build_raw)
    require(canonical(build) == build_raw,'URLSession build provenance not canonical')
    keys(build, ('schema_version','kind','source','binary','compiler','sdk','target','argv',
                 'environment_artifact','stdout','stderr','outcome','cleanup','duration_ms','started','ended',
                 'source_before_sha256','source_after_sha256','binary_absent_before',
                 'compiler_started_monotonic_ns','binary_created_monotonic_ns','compiler_exited_monotonic_ns'))
    integer(build['schema_version'],1,1)
    require(build['kind'] == 'observed_native_urlsession_harness_build','wrong native harness build provenance kind')
    for field in ('source','binary'): _ng_equal(build[field],harness[field],'harness build ' + field)
    keys(build['compiler'], ('path','bytes','sha256','uid','mode'))
    require(build['compiler']['path'] == '/usr/bin/swiftc','unapproved URLSession compiler')
    pin({key:build['compiler'][key] for key in ('bytes','sha256')})
    integer(build['compiler']['uid'],0,0); integer(build['compiler']['mode'],0,0o777)
    require(build['compiler']['mode'] & 0o111 and not build['compiler']['mode'] & 0o022,'untrusted compiler mode')
    keys(build['sdk'], ('path','version','identity'))
    sdk_path = _ng_absolute(build['sdk']['path']); _ng_sha(build['sdk']['identity'])
    require(sdk_path.startswith(('/Applications/Xcode.app/Contents/Developer/', '/Library/Developer/CommandLineTools/'))
            and sdk_path.endswith('.sdk'), 'unapproved native SDK location')
    require(type(build['sdk']['version']) is str and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',build['sdk']['version']),
            'native SDK version')
    require(type(build['target']) is str and re.fullmatch(r'arm64-apple-macos[0-9]+(?:\.[0-9]+){0,2}',build['target']),
            'native URLSession compiler target')
    fixed = ['/usr/bin/swiftc','-sdk',sdk_path,'-target',build['target'],'-o',
             expected['source_root'] + '/' + harness['binary']['path'],
             expected['source_root'] + '/' + harness['source']['path']]
    require(build['argv'] == fixed,'arbitrary URLSession build command')
    # The build observer is independently source-bound and emitted these exact
    # facts. Its own event is outside its stdout to avoid an identity cycle.
    producer = _ng_facts(harness['build_event_artifact'],artifacts)
    observed, _ = _ng_event(producer,expected,artifacts,'urlsession_builder')
    require(observed == build_raw,'URLSession build facts not emitted by exact source-bound builder')
    _ng_environment(build['environment_artifact'],expected['events'][producer['id']]['environment'],artifacts)
    stdout = _ng_artifact(build['stdout'],'stdout',artifacts)
    stderr = _ng_artifact(build['stderr'],'stderr',artifacts)
    require(len(stdout) + len(stderr) <= 2097152,'native compiler raw output bound',MUTATION)
    _ng_outcome(build['outcome']); _ng_cleanup(build['cleanup']); integer(build['duration_ms'],0,600000)
    for field in ('started','ended'): _ng_text(build[field],'compiler wall diagnostic',100)
    require(build['source_before_sha256'] == build['source_after_sha256'] == harness['source']['sha256']
            and build['binary_absent_before'] is True,'native compiler source/fresh-output provenance')
    for field in ('compiler_started_monotonic_ns','binary_created_monotonic_ns','compiler_exited_monotonic_ns'):
        integer(build[field],0,10**20-1)
    require(build['compiler_started_monotonic_ns'] < build['binary_created_monotonic_ns']
            <= build['compiler_exited_monotonic_ns'], 'native compiler output causality contradiction')


def _ng_resolve_required_interpreter(files):
    """Resolve only the fixed bundled Splash interpreter in approved rows."""
    pending = 'Splash/python/bin/python3'.split('/')
    resolved, hops = [], 0
    while pending:
        part, pending = pending[0], pending[1:]
        if part in ('','.'):
            continue
        if part == '..':
            require(resolved, 'Splash interpreter link escapes payload')
            resolved.pop()
            continue
        resolved.append(part)
        name = '/'.join(resolved)
        row = files.get(name)
        require(type(row) is dict, 'required Splash interpreter path missing')
        if row.get('kind') == 'symlink':
            target = row.get('target')
            require(type(target) is str and target and not target.startswith('/')
                    and '\\' not in target and ':' not in target
                    and len(target.encode('utf-8')) <= 4096, 'invalid Splash interpreter link')
            hops += 1
            require(hops <= 64, 'Splash interpreter link cycle/depth', MUTATION)
            resolved.pop()
            pending = target.split('/') + pending
        elif pending:
            require(row.get('kind') == 'directory', 'Splash interpreter traverses non-directory')
    name = '/'.join(resolved)
    require(name.startswith('Splash/python/') and files.get(name,{}).get('kind') == 'file',
            'required Splash interpreter resolves outside its approved Python closure')
    return name


def _ng_voice_probe_argv(event, expected, environment):
    output = _ng_absolute(environment['HOME'])
    require(environment['TMPDIR'] == output,'probe HOME/TMPDIR disagree')
    program = expected['source_root'] + '/' + event['source']['path']
    return ['/usr/bin/sandbox-exec','-D','DOT_OUTPUT=' + output,
            '-D','DOT_VOICE_ROOT=' + expected['payload_root'] + '/Voice',
            '-D','DOT_VOICE_HELPER=' + program,
            '-D','DOT_PYTHON_ROOT=' + expected['payload_root'] + '/' + expected['voice_python_root'],
            '-f',expected['source_root'] + '/Resources/Voice/voice.sb',
            expected['payload_root'] + '/' + event['target']['path'],'-I','-B',program]


def _ng_interpreter(value, expected):
    keys(value, ('path','file_pin','implementation','version','architecture','prefix','base_prefix'))
    relative(value['path']); pin(value['file_pin'])
    _ng_file({'path':value['path'], **value['file_pin']}, expected['files'])
    require(value['implementation'] == 'CPython' and value['version'] == '3.11.17'
            and value['architecture'] == 'arm64', 'bundled CPython identity mismatch')
    for field in ('prefix','base_prefix'):
        relative(value[field])
        require(value[field] == expected['voice_python_root'], 'external interpreter prefix')
    require(value['path'].startswith(expected['voice_python_root'] + '/'), 'external interpreter path')
    _ng_equal(value, expected['interpreter'], 'interpreter')


def _ng_distribution(item, expected):
    keys(item, ('name','version','dist_info','metadata'))
    require(type(item['name']) is str and re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*', item['name']),
            'distribution name not normalized')
    _ng_text(item['version'], 'distribution version', 200)
    path = relative(item['dist_info'])
    require(path.startswith(expected['voice_python_root'] + '/') and path.endswith('.dist-info'),
            'external/non-dist-info package metadata')
    _ng_file(item['metadata'], expected['files'])
    require(item['metadata']['path'] == path + '/METADATA', 'distribution metadata identity path')


def _ng_raw_subset(value, fields, expected, artifacts, role='voice_probe'):
    """Recompute concrete facts from a retained source-bound probe stdout.

    The producing program is a separately reviewed native source prerequisite.
    A current module hash plus an invented probe label is not a producer.
    """
    facts_raw = _ng_artifact(expected['facts_artifact'],'canonical_facts',artifacts)
    facts = strict_json(facts_raw)
    keys(facts,fields)
    require(canonical(facts) == facts_raw,'native subset facts not canonical')
    event = _ng_facts(expected['facts_event_artifact'],artifacts)
    require(type(event) is dict and event.get('id') == expected['facts_event_id'], 'native facts producer identity')
    stdout, _ = _ng_event(event,expected,artifacts,role)
    require(stdout == facts_raw,'native facts not the exact source-bound producer output')
    _ng_equal(facts,{key:value[key] for key in fields},'parsed native raw subset facts')
    return event


def _ng_historical(value, expected, artifacts):
    require(value['mode'] == 'reviewed_owner_historical_closure', 'unsupported installation admission mode')
    for field in ('basis_identity','collector_bundle_identity','prepared_identity','transform_identity'):
        _ng_sha(value[field]); _ng_equal(value[field], expected[field], field)
    pin(value['historical_manifest'])
    _ng_equal(value['historical_manifest'], expected['historical_manifest'], 'historical manifest')


def _ng_distributions(value, expected, artifacts):
    _ng_raw_subset(value,('interpreter','distributions','bootstrap_exceptions','package_origins','sys_path'),expected,artifacts)
    _ng_interpreter(value['interpreter'], expected)
    distributions = _ng_list(value['distributions'], 1, 150)
    exceptions = _ng_list(value['bootstrap_exceptions'], 0, 58)
    names, paths = set(), set()
    for item in distributions + exceptions:
        _ng_distribution(item, expected)
        require(item['name'] not in names and folded(item['dist_info']) not in paths,
                'duplicate distribution or aliased dist-info')
        names.add(item['name']); paths.add(folded(item['dist_info']))
    physical_dist_info = {name for name,row in expected['files'].items()
                          if name.startswith(expected['voice_python_root'] + '/')
                          and name.endswith('.dist-info') and row.get('kind') == 'directory'}
    metadata_dist_info = {name.rsplit('/',1)[0] for name,row in expected['files'].items()
                          if name.startswith(expected['voice_python_root'] + '/')
                          and name.endswith('.dist-info/METADATA') and row.get('kind') == 'file'}
    reported_dist_info = {item['dist_info'] for item in distributions + exceptions}
    require(physical_dist_info == metadata_dist_info == reported_dist_info,
            'unreported/missing physical installed dist-info or METADATA')
    locked = expected['locked_distributions']
    _ng_list(locked, 92, 92)
    require(len(distributions) == 92, 'all 92 locked distributions required')
    _ng_equal([{'name':x['name'],'version':x['version']} for x in distributions], locked, 'locked distributions')
    _ng_equal(exceptions, expected['bootstrap_exceptions'], 'approved exact bootstrap exceptions')
    origins = _ng_list(value['package_origins'], len(names), len(names))
    origin_names = set()
    for item in origins:
        keys(item, ('name','root','metadata_paths'))
        require(type(item['name']) is str and item['name'] in names and item['name'] not in origin_names, 'package origin identity')
        origin_names.add(item['name'])
        root = relative(item['root'])
        require(root.startswith(expected['voice_python_root'] + '/'), 'external package origin')
        for metadata in _ng_list(item['metadata_paths'], 1):
            _ng_file(metadata, expected['files'])
            require(metadata['path'].startswith(root + '/'), 'package metadata outside approved root')
    _ng_equal(origins, expected['package_origins'], 'package origins')
    for item in _ng_list(value['sys_path'], 1, 128):
        name = relative(item)
        require(name == expected['voice_python_root'] or name.startswith(expected['voice_python_root'] + '/'),
                'external sys.path entry')
        require(name in expected['files'], 'sys.path absent from final closure')
    _ng_equal(value['sys_path'], expected['sys_path'], 'sys.path')
    event = value['pip_check_event']
    stdout, stderr = _ng_event(event, expected, artifacts, 'pip_check')
    require(event['target']['path'] == value['interpreter']['path'], 'pip check used different interpreter')
    require(stdout == b'No broken requirements found.\n' and stderr == b'', 'pip check raw output mismatch')


def _ng_uuid(value):
    require(type(value) is str and re.fullmatch(
        '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', value),
        'native protocol ID is not canonical UUID')


def _ng_request(item):
    keys(item, ('protocol','type','id','turn','text'))
    integer(item['protocol'],1,1)
    require(item['type'] == 'speak', 'native voice request kind')
    _ng_uuid(item['id']); _ng_uuid(item['turn'])
    require(type(item['text']) is str and 0 < len(item['text'].strip()) <= 1000, 'empty/oversized speech text')


def _ng_voice_stdout(raw):
    require(type(raw) is bytes and len(raw) <= 2097152 and raw.endswith(b'\n'), 'helper protocol output framing')
    lines = raw.splitlines()
    require(1 <= len(lines) <= 10000 and all(0 < len(line) <= 8192 for line in lines), 'helper protocol line bound')
    return [strict_json(line) for line in lines]


def _ng_hello(item):
    keys(item, ('protocol','event','engine','voice','sample_rate','offline'))
    integer(item['protocol'],1,1); integer(item['sample_rate'],24000,24000)
    require(item['event'] == 'hello' and item['engine'] == 'kokoro'
            and item['voice'] == 'bf_isabella' and item['offline'] is True, 'real Kokoro helper hello missing')


def _ng_audio(item, request):
    keys(item, ('protocol','event','id','turn','file','samples','sample_rate'))
    integer(item['protocol'],1,1); integer(item['sample_rate'],24000,24000)
    integer(item['samples'],1,1440000)
    require(item['event'] == 'audio' and item['id'] == request['id']
            and item['turn'] == request['turn'], 'voice audio request correlation')
    relative(item['file'])
    require(re.fullmatch(r'audio-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.wav',
                         item['file']), 'helper WAV filename grammar')


def _ng_wav(raw):
    """Parse the exact RIFF PCM emitted by the current source-bound helper.

    Bounded ancillary RIFF chunks are allowed, with exact sizes/padding. Duplicate
    fmt/data chunks, unsupported formats and trailing bytes all reject.
    """
    require(type(raw) is bytes and 44 <= len(raw) <= 3000000, 'native WAV byte bound')
    require(raw[:4] == b'RIFF' and raw[8:12] == b'WAVE'
            and int.from_bytes(raw[4:8],'little') == len(raw)-8, 'native RIFF length/header mismatch')
    offset, fmt, pcm = 12, None, None
    while offset < len(raw):
        require(offset + 8 <= len(raw), 'truncated WAV chunk')
        name = raw[offset:offset+4]; size = int.from_bytes(raw[offset+4:offset+8], 'little')
        end = offset + 8 + size
        require(end + (size & 1) <= len(raw), 'WAV chunk length mismatch')
        data = raw[offset+8:end]
        if name == b'fmt ':
            require(fmt is None and size == 16, 'WAV fmt duplicate/unsupported')
            fmt = tuple(int.from_bytes(data[a:b],'little') for a,b in ((0,2),(2,4),(4,8),(8,12),(12,14),(14,16)))
        elif name == b'data':
            require(pcm is None, 'duplicate WAV data')
            pcm = data
        else:
            require(name in (b'JUNK',b'LIST') and size <= 65536, 'unapproved WAV chunk')
        if size & 1: require(raw[end] == 0, 'nonzero WAV padding')
        offset = end + (size & 1)
    require(offset == len(raw) and fmt == (1,1,24000,48000,2,16)
            and pcm is not None and 0 < len(pcm) <= 2880000 and len(pcm) % 2 == 0,
            'WAV must be nonempty mono 24 kHz little-endian PCM16')
    nonzero = sum(pcm[i:i+2] != b'\x00\x00' for i in range(0,len(pcm),2))
    require(nonzero > 0, 'silent all-zero WAV')
    return {'channels':1,'sample_rate':24000,'sample_width':2,'frames':len(pcm)//2,
            'data_bytes':len(pcm),'compression':'NONE','nonzero_samples':nonzero}


def _ng_synthesis(value, expected, artifacts):
    _ng_sha(value['helper_sha256'])
    require(value['helper_sha256'] == expected['source_identities']['Resources/Voice/bionic_helper.py']['sha256'],
            'wrong synthesis helper bytes')
    for item in _ng_list(value['model_pins'],3,3): _ng_file(item, expected['files'])
    _ng_equal(value['model_pins'], expected['voice_model_pins'], 'voice model/config/tensor pins')
    _ng_request(value['request']); _ng_equal(value['request'], expected['voice_request'], 'fixed voice request')
    _ng_hello(value['hello_event']); _ng_audio(value['audio_event'],value['request'])
    raw = _ng_artifact(value['wav_artifact'], 'wav', artifacts)
    require(value['wav_artifact']['path'].rsplit('/',1)[-1] == value['audio_event']['file'],
            'retained WAV does not match emitted filename')
    keys(value['wav_facts'], ('channels','sample_rate','sample_width','frames','data_bytes','compression','nonzero_samples'))
    _ng_equal(value['wav_facts'],_ng_wav(raw),'parsed WAV facts')
    require(value['audio_event']['samples'] == value['wav_facts']['frames'], 'WAV sample/frame disagreement')
    require(value['output_created_after_request'] is True, 'WAV fresh-output causality missing')
    # The timeline is raw source-bound probe output, not the boolean above.
    trace = _ng_facts(expected['voice_trace_artifact'], artifacts)
    trace_producer = _ng_facts(expected['voice_trace_event_artifact'],artifacts)
    trace_stdout, _ = _ng_event(trace_producer,expected,artifacts,'voice_probe')
    require(trace_stdout == _ng_artifact(expected['voice_trace_artifact'],'canonical_facts',artifacts),
            'voice causality trace not produced by exact source-bound probe')
    keys(trace, ('request','hello','audio','output_absent_before','request_monotonic_ns',
                 'output_created_monotonic_ns','output_closed_monotonic_ns','initial_output_paths','process_event'))
    stdout, _ = _ng_event(trace['process_event'],expected,artifacts,'voice_helper')
    require(trace_producer['id'] != trace['process_event']['id'], 'voice trace producer/subject identity collision')
    _ng_equal(_ng_voice_stdout(stdout),[value['hello_event'],value['audio_event']], 'helper raw protocol output')
    for field, actual in (('request',value['request']),('hello',value['hello_event']),('audio',value['audio_event'])):
        _ng_equal(trace[field],actual,'voice trace ' + field)
    require(trace['output_absent_before'] is True and trace['initial_output_paths'] == [], 'preexisting voice output')
    for field in ('request_monotonic_ns','output_created_monotonic_ns','output_closed_monotonic_ns'):
        integer(trace[field],0,10**20-1)
    require(trace['request_monotonic_ns'] < trace['output_created_monotonic_ns']
            <= trace['output_closed_monotonic_ns'], 'voice output causality contradiction')


def _ng_empty_metadata(value, expected):
    rows = _ng_list(value,1,200000)
    require(len(rows) == len(expected['files']), 'incomplete no-follow xattr coverage')
    seen = set()
    for item in rows:
        keys(item, ('path','nofollow','supported','attributes'))
        name = relative(item['path'], root=True)
        require(name in expected['files'] and name not in seen, 'duplicate/unknown metadata node')
        seen.add(name)
        require(item['nofollow'] is True and item['supported'] is True and item['attributes'] == [],
                'UNREVIEWED_NATIVE_METADATA')
    require(seen == set(expected['files']), 'missing no-follow metadata nodes')


def _ng_native_signature(value):
    keys(value, ('strict','ad_hoc','identifier','team_id','cdhash','authorities','entitlements','requirements'))
    require(value['strict'] is True and type(value['ad_hoc']) is bool, 'strict native signature missing')
    _ng_text(value['identifier'], 'signature identifier')
    require(value['team_id'] is None or type(value['team_id']) is str and value['team_id'], 'signature team type')
    require(type(value['cdhash']) is str and re.fullmatch('[0-9a-f]{40}',value['cdhash']), 'signature cdhash')
    require(type(value['entitlements']) is dict and len(canonical(value['entitlements'])) <= 65536,
            'native entitlements bound')
    _ng_text(value['requirements'], 'signature requirements',65536)
    authorities = _ng_list(value['authorities'],0,16)
    for authority in authorities: _ng_text(authority,'signature authority',4096)
    require(bool(authorities) is (not value['ad_hoc']), 'signature authority/ad-hoc mismatch')
    require(not value['ad_hoc'] or value['team_id'] is None, 'ad-hoc signature has a team')


def _ng_load_command(value):
    require(type(value) is dict and type(value.get('cmd')) is str, 'native load-command type')
    command = value['cmd']
    if command in ('LC_LOAD_DYLIB','LC_LOAD_WEAK_DYLIB','LC_REEXPORT_DYLIB','LC_LOAD_UPWARD_DYLIB','LC_ID_DYLIB'):
        keys(value, ('cmd','name','compatibility_version','current_version'))
        _ng_text(value['name'], 'install name')
        for key in ('compatibility_version','current_version'):
            require(type(value[key]) is str and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',value[key]), 'dylib version')
    elif command == 'LC_RPATH':
        keys(value, ('cmd','path')); _ng_text(value['path'],'rpath')
    elif command == 'LC_BUILD_VERSION':
        keys(value, ('cmd','platform','minos','sdk'))
        require(value['platform'] == 'macOS', 'non-macOS load command')
        for key in ('minos','sdk'):
            require(type(value[key]) is str and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',value[key]), 'build version')
    elif command == 'LC_VERSION_MIN_MACOSX':
        keys(value, ('cmd','version','sdk'))
        for key in ('version','sdk'):
            require(type(value[key]) is str and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',value[key]), 'minimum OS version')
    elif command in ('LC_UUID','LC_SYMTAB','LC_DYSYMTAB','LC_DYLD_INFO_ONLY','LC_MAIN',
                      'LC_SOURCE_VERSION','LC_CODE_SIGNATURE','LC_FUNCTION_STARTS','LC_DATA_IN_CODE',
                      'LC_DYLIB_CODE_SIGN_DRS','LC_LINKER_OPTIMIZATION_HINT','LC_DYLD_EXPORTS_TRIE',
                      'LC_DYLD_CHAINED_FIXUPS','LC_LOAD_DYLINKER','LC_SEGMENT_64'):
        keys(value, ('cmd','fields'))
        for field in _ng_list(value['fields'],1,65536): _ng_text(field,'native load-command field',4096)
    else:
        raise Rejected('unrecognized native load command')


def _ng_static(value, expected, artifacts):
    inventory = expected['native_inventory']
    keys(inventory, ('objects','code_bundles','launch_contexts','system_roots','system_targets'))
    allowed_roots = ('/usr/lib','/System/Library/Frameworks','/System/Library/PrivateFrameworks')
    roots = _ng_list(inventory['system_roots'],1,3)
    require(len(roots) == len(set(roots)) and all(root in allowed_roots for root in roots),
            'unapproved fixed system dependency root')
    objects = _ng_list(value['native_objects'],1,4096)
    names = set()
    required_edges = set()
    for item in objects:
        keys(item, ('path','bytes','sha256','architectures','platform','minimum_os','sdk',
                    'install_name','rpaths','load_commands','signature'))
        name = _ng_file({key:item[key] for key in ('path','bytes','sha256')}, expected['files'])
        require(name not in names, 'duplicate native object'); names.add(name)
        arches = _ng_list(item['architectures'],1,2)
        require(all(type(arch) is str for arch in arches) and arches == sorted(set(arches)) and 'arm64' in arches
                and set(arches) <= {'arm64','x86_64'}, 'unsupported native architecture')
        require(item['platform'] == 'macOS', 'wrong native platform')
        for field in ('minimum_os','sdk'):
            require(type(item[field]) is str and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',item[field]), 'native OS version')
        require(item['install_name'] is None or type(item['install_name']) is str and item['install_name'], 'native install name')
        for path in _ng_list(item['rpaths'],0,128):
            _ng_text(path,'rpath')
            require(path.startswith(('@loader_path','@executable_path'))
                    or any(path == root or path.startswith(root + '/') for root in roots),
                    'host/external rpath forbidden')
            if path.startswith('/'):
                require('/../' not in path and not path.endswith('/..') and '/./' not in path and '//' not in path,
                        'noncanonical system rpath')
            else:
                require(path == '@loader_path' or path.startswith('@loader_path/')
                        or path == '@executable_path' or path.startswith('@executable_path/'),
                        'invalid loader/executable rpath anchor')
        commands = _ng_list(item['load_commands'],1,4096)
        for command in commands: _ng_load_command(command)
        require([c['path'] for c in commands if c['cmd'] == 'LC_RPATH'] == item['rpaths'], 'rpath command disagreement')
        ids = [c['name'] for c in commands if c['cmd'] == 'LC_ID_DYLIB']
        require(ids == ([] if item['install_name'] is None else [item['install_name']]), 'install name command disagreement')
        versions = [c for c in commands if c['cmd'] in ('LC_BUILD_VERSION','LC_VERSION_MIN_MACOSX')]
        require(len(versions) == 1 and versions[0].get('minos',versions[0].get('version')) == item['minimum_os']
                and versions[0]['sdk'] == item['sdk'], 'minimum OS command disagreement')
        _ng_native_signature(item['signature'])
    _ng_equal(objects,inventory['objects'],'native object inventory')
    bundles = _ng_list(value['code_bundles'],0,4096)
    bundle_names = set()
    for item in bundles:
        keys(item, ('path','seal_root','signature','code_resources'))
        name = relative(item['path'])
        require(name in expected['files'] and expected['files'][name]['kind'] == 'directory'
                and name not in bundle_names, 'unknown/duplicate independent code bundle')
        seal_root = relative(item['seal_root'])
        require(seal_root in expected['files'] and expected['files'][seal_root]['kind'] == 'directory',
                'bundle seal root outside closure')
        require(seal_root == name or seal_root == name + '/Contents' and name.endswith('.app')
                or name.endswith('.framework') and re.fullmatch(re.escape(name) + r'/Versions/[^/]+',seal_root),
                'unrecognized code bundle seal layout')
        bundle_names.add(name); _ng_native_signature(item['signature'])
        _ng_file(item['code_resources'],expected['files'])
        require(item['code_resources']['path'] == seal_root + '/_CodeSignature/CodeResources', 'bundle signature resource path')
    _ng_equal(bundles,inventory['code_bundles'],'independent bundle inventory')
    contexts = _ng_list(value['launch_contexts'],1,4096)
    context_names = set()
    for item in contexts:
        keys(item, ('id','executable','loaded_objects'))
        context_id = _ng_text(item['id'],'launch context',200)
        require(context_id not in context_names, 'duplicate launch context'); context_names.add(context_id)
        require(relative(item['executable']) in names, 'external launch executable')
        loaded = _ng_list(item['loaded_objects'],1,4096)
        require(all(type(path) is str for path in loaded) and len(loaded) == len(set(loaded)) and set(loaded) <= names, 'unknown/duplicate launch object')
        for obj in objects:
            if obj['path'] not in loaded: continue
            required_edges.update((context_id,obj['path'],i) for i,c in enumerate(obj['load_commands'])
                                  if c['cmd'] in ('LC_LOAD_DYLIB','LC_LOAD_WEAK_DYLIB','LC_REEXPORT_DYLIB','LC_LOAD_UPWARD_DYLIB'))
    _ng_equal(contexts,inventory['launch_contexts'],'launch contexts')
    require(set().union(*(set(c['loaded_objects']) for c in contexts)) == names, 'native object lacks launch context')
    edges = _ng_list(value['resolved_edges'],0,100000)
    seen = set(); object_index = {x['path']:x for x in objects}
    for edge in edges:
        keys(edge, ('context','source','load_command_index','install_name','target_kind','target'))
        integer(edge['load_command_index'],0,4095)
        _ng_text(edge['context'],'dependency context',200); relative(edge['source'])
        key = (edge['context'],edge['source'],edge['load_command_index'])
        require(key in required_edges and key not in seen, 'unknown/ambiguous resolved dependency edge'); seen.add(key)
        command = object_index[edge['source']]['load_commands'][edge['load_command_index']]
        require(edge['install_name'] == command['name'], 'dependency edge load-command disagreement')
        target = _ng_text(edge['target'],'resolved dependency')
        if edge['target_kind'] == 'payload':
            require(relative(target) in names, 'dependency resolves outside approved Mach-O set')
        else:
            require(edge['target_kind'] == 'system' and any(target.startswith(root + '/') for root in roots)
                    and '/./' not in target and '/..' not in target and '//' not in target,
                    'unresolved/external system dependency')
    require(seen == required_edges,'incomplete resolved dependency coverage')
    _ng_equal(edges,expected['resolved_edges'],'resolved dependency expectations')
    targets = _ng_list(value['system_targets'],0,100000)
    requested = {(edge['context'],'arm64',edge['target']) for edge in edges if edge['target_kind']=='system'}
    available = set()
    for target in targets:
        keys(target, ('context','architecture','target','availability','file','cache_uuid'))
        _ng_text(target['context'],'system target context',200)
        _ng_text(target['target'],'system target path')
        identity = (target['context'],target['architecture'],target['target'])
        require(target['architecture']=='arm64' and identity in requested and identity not in available,
                'unknown/duplicate system target availability')
        available.add(identity)
        if target['availability']=='file':
            pin(target['file'])
            require(target['file']['bytes']>0 and target['cache_uuid'] is None,'system file availability identity')
        else:
            require(target['availability']=='dyld_shared_cache' and target['file'] is None
                    and type(target['cache_uuid']) is str and re.fullmatch('[0-9a-f]{32}',target['cache_uuid']),
                    'system shared-cache availability identity')
    require(available==requested,'unavailable system dependency target')
    require(targets==sorted(targets,key=lambda item:(item['context'],item['architecture'],item['target'])),
            'system target availability ordering')
    _ng_equal(targets,inventory['system_targets'],'reviewed system target availability')
    # The parent's fixed lipo/otool/codesign parser re-parses raw tool bytes; a
    # source approval value is never a substitute for this independently parsed
    # result. The concrete tool event checker belongs to that same parser.
    tool_events = _ng_list(value['tool_events'],2,2 + 6*4096 + 3*4096)
    operations = ('lipo','otool_libraries','otool_loads','codesign_display','codesign_entitlements','codesign_verify')
    required_tools = {('.', 'host_arm64')} | {(name,op) for name in names for op in operations}
    required_tools |= {(name,op) for name in bundle_names for op in operations[3:]}
    seen_tools = set(); system_seen = False
    for event in tool_events:
        if type(event) is dict and event.get('role')=='system_targets':
            keys(event, ('id','role','source','api','argv','target_architecture','facts_artifact','cleanup',
                         'duration_ms','started','ended'))
            require(not system_seen and event['id']=='native-system-targets'
                    and event['api']=='darwin_system_targets_v1' and event['argv']==[]
                    and event['target_architecture']=='arm64','system target API event identity')
            system_seen=True
            _ng_source(event['source'],expected['source_identities'])
            require(event['source']['path']=='scripts/reconstruct_runtime_payload.py','wrong system target observer source')
            facts=_ng_facts(event['facts_artifact'],artifacts)
            require(event['facts_artifact']['bytes']<=2097152,'system target API raw output bound',MUTATION)
            _ng_equal(facts,{'kind':'darwin_system_target_availability_v1','system_targets':targets},
                      'parsed system target availability')
            keys(event['cleanup'], ('owned_processes_created','open_descriptors','complete'))
            integer(event['cleanup']['owned_processes_created'],0,0)
            integer(event['cleanup']['open_descriptors'],0,0)
            require(event['cleanup']['complete'] is True,'system target API cleanup incomplete',MUTATION)
            integer(event['duration_ms'],0,300000)
            for field in ('started','ended'): _ng_text(event[field],'system API wall diagnostic',100)
            continue
        require(type(event) is dict and type(event.get('target')) is dict
                and type(event['target'].get('path')) is str and type(event.get('role')) is str,
                'native static raw event identity')
        pair = (event['target']['path'],event['role'])
        require(pair in required_tools and pair not in seen_tools, 'unknown/duplicate native static tool event')
        seen_tools.add(pair)
    require(seen_tools == required_tools and system_seen, 'incomplete native static tool event coverage')
    _ng_equal(tool_events,expected['verified_static_tool_events'],'verified static event coverage')
    _ng_equal({'native_objects':objects,'code_bundles':bundles,'launch_contexts':contexts,'resolved_edges':edges,'system_targets':targets},
              expected['parsed_static_facts'],'raw static parser facts')
    _ng_empty_metadata(value['metadata_empty_before'],expected)
    _ng_empty_metadata(value['metadata_empty_after'],expected)


def _ng_private_roots(value):
    keys(value, ('home','tmpdir','caches'))
    for paths in value.values():
        require(type(paths) is list and paths == [], 'private probe roots not initially empty')


def _ng_imports(value, expected, artifacts):
    event = _ng_raw_subset(value,('interpreter','profile_sha256','initial_private_closure','imports','package_data','denial_cases'),expected,artifacts)
    require(event['argv'] == _ng_voice_probe_argv(event,expected,expected['voice_environment']),
            'offline import did not use exact product sandbox profile')
    require(event['target']['path'] == value['interpreter']['path'],'offline import used other interpreter')
    _ng_interpreter(value['interpreter'],expected)
    require(value['profile_sha256'] == expected['source_identities']['Resources/Voice/voice.sb']['sha256'],
            'offline import used wrong product sandbox profile')
    _ng_environment(value['environment_artifact'],expected['voice_environment'],artifacts)
    _ng_private_roots(value['initial_private_closure'])
    imports = _ng_list(value['imports'],6,6)
    versions = expected['import_versions']
    require(set(versions) == {'kokoro','misaki','torch','numpy','spacy','en_core_web_sm'}, 'fixed product imports missing')
    require(versions['kokoro'] == versions['misaki'] == '0.9.4' and versions['en_core_web_sm'] == '3.8.0',
            'wrong product voice package versions')
    seen = set()
    for item in imports:
        keys(item, ('name','version','origin'))
        require(type(item['name']) is str and item['name'] in versions and item['name'] not in seen and item['version'] == versions[item['name']],
                'wrong/duplicate product import'); seen.add(item['name'])
        _ng_file(item['origin'],expected['files'])
        require(item['origin']['path'].startswith(expected['voice_python_root'] + '/'), 'host import origin')
    _ng_equal(imports,expected['imports'],'module origins and versions')
    data = _ng_list(value['package_data'],2)
    roles = set()
    for item in data:
        keys(item, ('role','path','bytes','sha256'))
        require(item['role'] in ('espeak_data','phonemizer_data'), 'unexpected voice package-data role')
        roles.add(item['role'])
        _ng_file({k:item[k] for k in ('path','bytes','sha256')},expected['files'])
        require(item['path'].startswith(expected['voice_python_root'] + '/'), 'external speech package data')
    require(roles == {'espeak_data','phonemizer_data'}, 'required speech package data missing')
    _ng_equal(data,expected['package_data'],'speech package-data inventory')
    cases = _ng_list(value['denial_cases'],3,3)
    operations = set()
    for case in cases:
        keys(case, ('operation','errno','event_id','target'))
        require(case['operation'] in ('network','read','write') and case['operation'] not in operations,
                'missing/duplicate sandbox denial case')
        operations.add(case['operation']); integer(case['errno'],1,13)
        require(case['errno'] in (1,13), 'timeout/DNS/unreachable is not sandbox denial')
        _ng_text(case['event_id'],'sandbox denial event',200); _ng_text(case['target'],'sandbox denial target')
    _ng_equal(cases,expected['denial_cases'],'fixed sandbox negative canaries')


def _ng_case(value, expected, artifacts, case_name):
    keys(value, ('event_ids','expected_ids','outcome','cleanup','artifacts'))
    ids = _ng_list(value['event_ids'],1,10000)
    require(all(type(x) is str and x for x in ids) and len(ids) == len(set(ids)), 'duplicate/invalid process-case IDs')
    _ng_equal(ids,value['expected_ids'],'process case observed/expected IDs')
    _ng_equal(ids,expected['case_event_ids'][case_name],'fixed process case event IDs')
    _ng_outcome(value['outcome']); _ng_cleanup(value['cleanup'])
    references = _ng_list(value['artifacts'],1,10000)
    paths = set(); facts = []
    for artifact in references:
        require(type(artifact) is dict and artifact.get('kind') in ('stdout','stderr','canonical_facts','wav'),
                'invalid process-case artifact')
        _ng_artifact(artifact,artifact['kind'],artifacts)
        require(artifact['path'] not in paths, 'duplicate process-case artifact'); paths.add(artifact['path'])
        if artifact['kind'] == 'canonical_facts': facts.append(_ng_facts(artifact,artifacts))
    require(len(facts) == 1,'one exact process case facts artifact required')
    observed = facts[0]
    require(type(observed) is dict,'concrete process case facts required')
    require(type(expected.get('case_producer_event_artifacts')) is dict
            and case_name in expected['case_producer_event_artifacts'], 'source-bound case producer missing')
    producer = _ng_facts(expected['case_producer_event_artifacts'][case_name],artifacts)
    role = ('urlsession_probe' if case_name.startswith('tls_') else
            'splash_probe' if case_name.startswith('splash_') else 'voice_probe')
    stdout, _ = _ng_event(producer,expected,artifacts,role)
    require(stdout == canonical(observed),'process case facts not produced by exact source-bound probe')
    if role == 'voice_probe':
        require('process_events' in observed,'source-bound voice subject events missing')
        events = _ng_list(observed['process_events'],1,1)
        subject_ids = [event.get('id') if type(event) is dict else None for event in events]
        require(producer['id'] not in subject_ids and subject_ids + [producer['id']] == ids,
                'voice subject/producer event coverage')
        for event in events: _ng_event(event,expected,artifacts,'voice_helper')
    else:
        require(ids == [producer['id']], 'native case producer event coverage')
    return observed


def _ng_voice_case_facts(facts, case_name, expected, artifacts):
    keys(facts, ('case','request','inputs','outputs','render_started_before_control','remaining_output_paths',
                 'remaining_session_state','completed_audio','process_events','timeline'))
    require(facts['case'] == case_name,'wrong voice lifecycle case')
    _ng_request(facts['request'])
    _ng_equal(facts['request'],expected['case_requests'][case_name],'voice lifecycle request')
    inputs = _ng_list(facts['inputs'],1,3); outputs = _ng_list(facts['outputs'],1,10000)
    require(facts['render_started_before_control'] is True, 'voice lifecycle did not exercise live render')
    require(facts['remaining_output_paths'] == [] and facts['remaining_session_state'] == [],
            'voice lifecycle leaked output/session state')
    _ng_hello(outputs[0])
    events = _ng_list(facts['process_events'],1,1)
    stdout, _ = _ng_event(events[0],expected,artifacts,'voice_helper')
    _ng_equal(_ng_voice_stdout(stdout),outputs,'voice lifecycle raw stdout')
    timeline = _ng_list(facts['timeline'],len(inputs)+len(outputs),len(inputs)+len(outputs))
    read_inputs, read_outputs, last_ns = [], [], -1
    for row in timeline:
        keys(row, ('direction','message','monotonic_ns'))
        integer(row['monotonic_ns'],0,10**20-1)
        require(row['monotonic_ns'] > last_ns,'non-increasing voice lifecycle timeline')
        last_ns = row['monotonic_ns']
        require(row['direction'] in ('input','output'),'invalid voice timeline direction')
        (read_inputs if row['direction'] == 'input' else read_outputs).append(row['message'])
    _ng_equal(read_inputs,inputs,'voice timeline input coverage'); _ng_equal(read_outputs,outputs,'voice timeline output coverage')
    if case_name in ('cancel','after_cancel'):
        canceled = expected['case_requests']['cancel']; subsequent = expected['case_requests']['after_cancel']
        _ng_request(canceled); _ng_request(subsequent)
        _ng_equal(inputs,[canceled,{'protocol':1,'type':'cancel'},subsequent],'live cancel/subsequent inputs')
        require(len(outputs) == 3,'cancel/subsequent protocol output count')
        _ng_equal(outputs[1],{'protocol':1,'event':'cancelled'},'cancel acknowledgment')
        _ng_audio(outputs[2],subsequent)
        expected_order = [('output',outputs[0]),('input',inputs[0]),('input',inputs[1]),
                          ('output',outputs[1]),('input',inputs[2]),('output',outputs[2])]
        _ng_equal([[r['direction'],r['message']] for r in timeline],
                  [[d,m] for d,m in expected_order],'live cancel/subsequent event order')
        require(facts['completed_audio'] is not None,'subsequent request audio missing')
        wav = _ng_wav(_ng_artifact(facts['completed_audio'],'wav',artifacts))
        require(wav['frames'] == outputs[2]['samples'],'subsequent audio sample count mismatch')
        require(facts['completed_audio']['path'].rsplit('/',1)[-1] == outputs[2]['file'],'subsequent WAV filename mismatch')
    elif case_name in ('eof','shutdown'):
        control = {'event':'stdin_eof'} if case_name == 'eof' else {'protocol':1,'type':'shutdown'}
        _ng_equal(inputs,[facts['request'],control],'live EOF/shutdown inputs')
        require(outputs == [outputs[0]] and facts['completed_audio'] is None,'voice EOF/shutdown emitted post-control audio')
        _ng_equal([[r['direction'],r['message']] for r in timeline],
                  [['output',outputs[0]],['input',inputs[0]],['input',control]],'live EOF/shutdown event order')
    else:
        raise Rejected('unknown voice lifecycle case')


def _ng_cancellation(value, expected, artifacts):
    require(value['helper_sha256'] == expected['source_identities']['Resources/Voice/bionic_helper.py']['sha256'],
            'wrong lifecycle helper bytes')
    requests = []; subject_ids = {}
    for case_name, field in (('cancel','cancel_case'),('after_cancel','after_cancel_case'),
                              ('eof','eof_case'),('shutdown','shutdown_case')):
        facts = _ng_case(value[field],expected,artifacts,case_name)
        _ng_voice_case_facts(facts,case_name,expected,artifacts)
        requests.append((facts['request']['id'],facts['request']['turn']))
        subject_ids[case_name] = [event['id'] for event in facts['process_events']]
    require(len(set(requests)) == 4 and requests[0][0] != requests[1][0]
            and requests[0][1] != requests[1][1], 'voice lifecycle requests not distinct')
    require(subject_ids['cancel'] == subject_ids['after_cancel'],
            'subsequent request did not use same live helper process')
    require(value['remaining_output_paths'] == [],'unreported leftover voice output')


def _ng_model_admission(value, expected, artifacts):
    keys(value, ('schema_version','kind','owner_source','decision_id','receipt','models','before_identity','after_identity'))
    integer(value['schema_version'],1,1)
    require(value['kind'] == 'independently_verified_complete_models', 'complete-model admission missing')
    _ng_text(value['decision_id'],'model owner decision',200)
    keys(value['owner_source'], ('path','bytes','sha256')); relative(value['owner_source']['path'])
    pin({k:value['owner_source'][k] for k in ('bytes','sha256')})
    models = _ng_list(value['models'],3,3)
    roles = set()
    for model in models:
        keys(model, ('role','identity','file_count','bytes'))
        require(model['role'] in ('target','draft','vision') and model['role'] not in roles,
                'missing/duplicate complete-model role'); roles.add(model['role'])
        _ng_sha(model['identity']); integer(model['file_count'],1,1000000); integer(model['bytes'],1,10**20-1)
    for field in ('before_identity','after_identity'): _ng_sha(value[field])
    require(value['before_identity'] == value['after_identity'], 'external model input changed')
    raw = _ng_artifact(value['receipt'],'canonical_facts',artifacts)
    reviewed = strict_json(raw)
    require(canonical(reviewed) == raw,'model owner receipt not canonical')
    keys(reviewed, ('schema_version','kind','owner_source','decision_id','models','before_identity','after_identity'))
    _ng_equal(reviewed,{k:v for k,v in value.items() if k != 'receipt'},'model owner receipt facts')
    _ng_equal(value,expected['model_input_admission'],'independently approved model input admission')


def _ng_listener_case(value, expected, artifacts):
    facts = _ng_case(value,expected,artifacts,'splash_listener')
    keys(facts, ('family','address','owned_before_spawn','listener_fd','adopted_fd',
                 'listener_identity_before','listener_identity_after','health','status'))
    require(facts['family'] == 'AF_INET' and facts['address'] == '127.0.0.1'
            and facts['owned_before_spawn'] is True,'literal owned IPv4 listener missing')
    integer(facts['listener_fd'],3,1000000); integer(facts['adopted_fd'],3,1000000)
    require(facts['listener_fd'] == facts['adopted_fd'],'Splash adopted different listener')
    for name in ('listener_identity_before','listener_identity_after'):
        keys(facts[name], ('device','inode','port'))
        integer(facts[name]['device'],0,10**20-1); integer(facts[name]['inode'],1,10**20-1)
        integer(facts[name]['port'],1,65535)
    _ng_equal(facts['listener_identity_before'],facts['listener_identity_after'],'listener ownership')
    for name in ('health','status'):
        keys(facts[name], ('authenticated','http_status','response_bytes'))
        require(facts[name]['authenticated'] is True,'unauthenticated Splash health/status')
        integer(facts[name]['http_status'],200,200); integer(facts[name]['response_bytes'],1,2097152)
    return facts


def _ng_credentials_case(value, expected, artifacts):
    facts = _ng_case(value,expected,artifacts,'splash_credential')
    keys(facts, ('argv_key_occurrences','environment_key_occurrences','file_key_occurrences',
                 'pipe_bytes','pipe_reads','pipe_eof','pipe_closed','second_read_bytes','key_remaining'))
    for field in ('argv_key_occurrences','environment_key_occurrences','file_key_occurrences','second_read_bytes'):
        integer(facts[field],0,0)
    integer(facts['pipe_bytes'],1,4096); integer(facts['pipe_reads'],1,1)
    require(facts['pipe_eof'] is True and facts['pipe_closed'] is True and facts['key_remaining'] is False,
            'secret pipe not one-shot/closed or key retained')
    return facts


def _ng_sse(raw):
    require(type(raw) is bytes and 0 < len(raw) <= 2097152,'inference stream byte bound')
    try: text = raw.decode('utf-8','strict')
    except UnicodeError as exc: raise Rejected('invalid inference stream UTF-8') from exc
    require('\r' not in text,'ambiguous inference SSE newlines')
    frames = text.split('\n\n')
    require(frames[-1] == '', 'unterminated inference SSE stream')
    frames = frames[:-1]
    require(len(frames) >= 2 and frames[-1] == 'data: [DONE]', 'inference lacks final DONE')
    characters = 0
    for frame in frames[:-1]:
        require(frame.startswith('data: ') and '\n' not in frame,'unsupported inference SSE frame')
        item = strict_json(frame[6:].encode('utf-8'))
        # OpenAI-compatible current Splash streams may carry these standard
        # fields only; content is read from choices[].delta.content.
        keys(item, ('choices',), ('id','object','created','model','usage','system_fingerprint'))
        for field in ('id','object','model'):
            if field in item: _ng_text(item[field], 'inference ' + field, 4096)
        if 'created' in item: integer(item['created'],0,10**20-1)
        if 'system_fingerprint' in item:
            require(item['system_fingerprint'] is None or type(item['system_fingerprint']) is str, 'inference fingerprint type')
        if 'usage' in item and item['usage'] is not None:
            keys(item['usage'], ('prompt_tokens','completion_tokens','total_tokens'))
            for count in item['usage'].values(): integer(count,0,10**20-1)
            require(item['usage']['total_tokens'] == item['usage']['prompt_tokens'] + item['usage']['completion_tokens'],
                    'inference usage count contradiction')
        for choice in _ng_list(item['choices'],1,1):
            keys(choice, ('index','delta','finish_reason'), ('logprobs',))
            integer(choice['index'],0,0)
            if 'logprobs' in choice: require(choice['logprobs'] is None, 'unreviewed inference logprobs')
            require(choice['finish_reason'] in (None,'stop','length'), 'inference stream failure finish reason')
            keys(choice['delta'], (), ('role','content'))
            if 'role' in choice['delta']: require(choice['delta']['role'] == 'assistant','unexpected inference role')
            if 'content' in choice['delta']:
                require(type(choice['delta']['content']) is str,'nontext inference delta')
                characters += len(choice['delta']['content'])
    require(characters > 0,'empty inference output')
    return characters


def _ng_inference_case(value, expected, artifacts):
    facts = _ng_case(value,expected,artifacts,'splash_inference')
    keys(facts, ('authenticated','http_status','stream','nonempty_characters','done'))
    require(facts['authenticated'] is True and facts['done'] is True,'unauthenticated/incomplete Splash inference')
    integer(facts['http_status'],200,200)
    chars = _ng_sse(_ng_artifact(facts['stream'],'stdout',artifacts))
    integer(facts['nonempty_characters'],1,2097152)
    require(chars == facts['nonempty_characters'],'inference character accounting mismatch')
    return facts


def _ng_tls_cases(value, expected, artifacts):
    keys(value, ('positive','reconnect','wrong_pin'))
    source = expected['probe_sources'].get('urlsession_probe')
    require(type(source) is str and source in expected['source_identities'],
            'SOURCE_BOUND_NATIVE_URLSESSION_HARNESS_REQUIRED',MISSING)
    for name in ('positive','reconnect','wrong_pin'):
        facts = _ng_case(value[name],expected,artifacts,'tls_' + name)
        keys(facts, ('case','harness_source','peer_certificate_sha256','expected_pin_sha256',
                     'certificate_observed','failure_stage','application_bytes_sent','application_bytes_received',
                     'connection_index'))
        require(facts['case'] == name,'wrong TLS case')
        _ng_source(facts['harness_source'],expected['source_identities'])
        require(facts['harness_source']['path'] == source,'generic TLS client substituted for URLSession harness')
        for field in ('peer_certificate_sha256','expected_pin_sha256'): _ng_sha(facts[field])
        require(facts['certificate_observed'] is True,'pre-certificate failure is not TLS pin evidence')
        integer(facts['application_bytes_sent'],0,2097152); integer(facts['application_bytes_received'],0,2097152)
        integer(facts['connection_index'],1,2)
        require(facts['peer_certificate_sha256'] == expected['tls_certificate_sha256'],'unexpected TLS server certificate')
        if name == 'wrong_pin':
            require(facts['peer_certificate_sha256'] != facts['expected_pin_sha256']
                    and facts['failure_stage'] == 'certificate_pin'
                    and facts['application_bytes_sent'] == facts['application_bytes_received'] == 0,
                    'wrong pin not rejected before application bytes')
        else:
            require(facts['peer_certificate_sha256'] == facts['expected_pin_sha256']
                    and facts['failure_stage'] is None and facts['application_bytes_sent'] > 0
                    and facts['application_bytes_received'] > 0
                    and facts['connection_index'] == (1 if name == 'positive' else 2),
                    'TLS positive/reconnect did not exchange authenticated application bytes')


def _ng_splash_cleanup(value, expected, artifacts):
    keys(value, ('eof','cancel','startup_failure'))
    for name in ('eof','cancel','startup_failure'):
        facts = _ng_case(value[name],expected,artifacts,'splash_' + name)
        keys(facts, ('case','control_observed','remaining_owned_descendants','remaining_key_bytes','remaining_state_paths'))
        require(facts['case'] == name and facts['control_observed'] is True,'Splash cleanup case not exercised')
        integer(facts['remaining_owned_descendants'],0,0); integer(facts['remaining_key_bytes'],0,0)
        require(facts['remaining_state_paths'] == [],'Splash leaked session state')


def _ng_splash(value, expected, artifacts):
    pins = _ng_list(value['source_pins'],6,16)
    seen = set()
    for item in pins:
        keys(item, ('path','bytes','sha256')); path = relative(item['path'])
        require(path not in seen,'duplicate Splash source pin'); seen.add(path)
        if path in expected['files']: _ng_file(item,expected['files'])
        else: _ng_source(item,expected['source_identities'])
    required = {'Splash/install/launcher.py','Splash/server/serve_options.py','Splash/server/server.py',
                'Resources/Runtime/dot_runtime.py','Resources/Runtime/dot_process.py','Resources/Runtime/dot_tls.py'}
    require(required <= seen,'exact v2 Splash sources/helpers missing')
    _ng_equal(pins,expected['splash_source_pins'],'v2 Splash source pins')
    require(value['profile_sha256'] == expected['source_identities']['Resources/Runtime/splash.sb']['sha256'],
            'Splash product sandbox profile mismatch')
    _ng_model_admission(value['model_input_admission'],expected,artifacts)
    _ng_listener_case(value['listener_case'],expected,artifacts)
    _ng_credentials_case(value['credential_case'],expected,artifacts)
    _ng_inference_case(value['inference_case'],expected,artifacts)
    _ng_tls_cases(value['tls_cases'],expected,artifacts)
    _ng_splash_cleanup(value['cleanup_cases'],expected,artifacts)


def _ng_relocated_cases(references, expected, artifacts, gate_names):
    values = _ng_list(references,len(gate_names),len(gate_names))
    seen = set()
    for reference in values:
        nested = _ng_facts(reference,artifacts)
        keys(nested, ('gate','payload_root','before_identity','after_identity','observations'))
        gate = nested['gate']
        require(gate in gate_names and gate not in seen,'missing/duplicate relocated gate'); seen.add(gate)
        require(nested['payload_root'] == expected['relocated_payload_root'],'relocated test launched old payload path')
        require(nested['before_identity'] == nested['after_identity'] == expected['signed_identity'],
                'relocated case changed signed closure')
        require(type(expected['relocated_expected']) is dict and gate in expected['relocated_expected'],
                'relocated gate-specific expectation context missing')
        relocated = expected['relocated_expected'][gate]
        require(relocated['payload_root'] == expected['relocated_payload_root'],'relocated invocation root mismatch')
        _validate_native_gate_observations(gate,nested['observations'],expected=relocated,artifacts=artifacts)


def _ng_relocation(value, expected, artifacts):
    name = relative(value['relative_test_path'])
    require(' ' in name and ',' in name and any(ord(c) > 127 for c in name),'relocation path lacks space/comma/Unicode')
    require(name == expected['relocation_relative_path'],'unapproved relocation test path')
    integer(value['espeak_absolute_path_utf8_bytes'],161,4096)
    require(value['espeak_absolute_path_utf8_bytes'] == len(expected['relocated_espeak_path'].encode('utf-8')),
            'relocated eSpeak path length not measured exactly')
    require(expected['relocated_espeak_path'].startswith(expected['relocated_payload_root'] + '/'),
            'relocated eSpeak data uses original/external path')
    for key in ('relocated_signed_identity','before_identity','after_identity'):
        _ng_sha(value[key]); require(value[key] == expected['signed_identity'],'relocation altered signed closure')
    _ng_private_roots(value['empty_private_roots'])
    _ng_relocated_cases(value['voice_case_artifacts'],expected,artifacts,(_NATIVE_GATE_IDS[4],_NATIVE_GATE_IDS[5]))
    _ng_relocated_cases(value['splash_case_artifacts'],expected,artifacts,(_NATIVE_GATE_IDS[6],))


def _ng_immutable(value, expected, artifacts):
    _ng_raw_subset(value,_NATIVE_GATE_FIELDS[8],expected,artifacts)
    closures = _ng_list(value['gate_closures'],9,9)
    seen = set()
    for row in closures:
        keys(row, ('gate','before_identity','after_identity'))
        require(row['gate'] in _NATIVE_GATE_IDS and row['gate'] not in seen,'missing/duplicate gate closure observation')
        seen.add(row['gate'])
        require(row['before_identity'] == row['after_identity'] == expected['signed_identity'],
                'native gate mutated signed payload')
    _ng_empty_metadata(value['metadata_empty_before'],expected)
    _ng_empty_metadata(value['metadata_empty_after'],expected)
    checks = _ng_list(value['external_input_rechecks'],3,3)
    roles = set(); models = {x['role']:x for x in expected['model_input_admission']['models']}
    for row in checks:
        keys(row, ('role','owner_receipt','before_identity','after_identity'))
        require(row['role'] in ('target','draft','vision') and row['role'] not in roles,'external model recheck coverage')
        roles.add(row['role'])
        _ng_artifact(row['owner_receipt'],'canonical_facts',artifacts)
        _ng_equal(row['owner_receipt'],expected['model_input_admission']['receipt'],'external model owner recheck receipt')
        require(row['before_identity'] == row['after_identity'] == models[row['role']]['identity'],
                'external complete-model input changed')


def _validate_native_gate_observations(gate, observations, *, expected, artifacts):
    """Validate one exact gate and its retained, source-bound raw facts.

    The parent must validate the receipt envelope/bindings and independently
    approved probe contract first. This function never interprets a fixture or
    a successful parse as genuine native provenance.
    """
    require(gate in _NATIVE_GATE_IDS,'unknown native gate')
    index = _NATIVE_GATE_IDS.index(gate)
    keys(observations,_NATIVE_GATE_FIELDS[index])
    require(type(expected) is dict and type(artifacts) is dict,'native validation inputs')
    require(all(field in expected for field in _NATIVE_EXPECTATION_FIELDS[gate]), 'native fixed gate expectations incomplete')
    validators = (_ng_historical,_ng_distributions,_ng_static,_ng_imports,_ng_synthesis,
                  _ng_cancellation,_ng_splash,_ng_relocation,_ng_immutable)
    validators[index](observations,expected,artifacts)
    return {'gate':gate,'observations_identity':digest(canonical(observations))}


def _validate_native_gate_set(receipts):
    """Exact nine-gate coverage; parent still validates each full receipt."""
    _ng_list(receipts,9,9)
    gates = [item.get('gate') if type(item) is dict else None for item in receipts]
    require(all(type(gate) is str for gate in gates) and len(set(gates)) == 9
            and set(gates) == set(_NATIVE_GATE_IDS),'all nine exact native gates required once')

"""Pure signing-delta semantic fragment; consumes independently replayed facts."""


def _validate_native_change_semantics(context,before_rows,final_rows,transforms,
                                      pre_facts,post_facts,native_changes):
    before = validate_rows(before_rows,context.bounds)
    after = validate_rows(final_rows,context.bounds)
    require(type(transforms) is list and type(native_changes) is list
            and len(native_changes)<=4096,'native change list type/bound')
    transform_index = {}
    for item in transforms:
        keys(item,('path','before','after','operation','reason'))
        path = relative(item['path'])
        require(path not in transform_index,'duplicate native transform')
        transform_index[path] = item
    objects = []
    for facts,rows in ((pre_facts,before),(post_facts,after)):
        require(type(facts) is dict and type(facts.get('native_objects')) is list
                and type(facts.get('resolved_edges')) is list,'replayed native facts required')
        index = {}
        for obj in facts['native_objects']:
            keys(obj,('path','bytes','sha256','architectures','platform','minimum_os','sdk',
                      'install_name','rpaths','load_commands','signature'))
            path = relative(obj['path'])
            require(path not in index,'duplicate replayed native object')
            row = rows.get(path)
            require(row is not None and row['kind']=='file','native facts are not a physical regular file')
            require(canonical({key:obj[key] for key in ('bytes','sha256')})
                    ==canonical({key:row[key] for key in ('bytes','sha256')}),'native facts row-pin mismatch')
            require(type(obj['load_commands']) is list and 1<=len(obj['load_commands'])<=4096
                    and all(type(cmd) is dict and type(cmd.get('cmd')) is str for cmd in obj['load_commands']),
                    'replayed native load commands required')
            require(type(obj['signature']) is dict and obj['signature'].get('strict') is True,
                    'replayed strict native signature required')
            index[path] = obj
        objects.append(index)
    old_objects,new_objects = objects
    require(set(old_objects)==set(new_objects),'native object addition/deletion forbidden')

    def edge_index(facts,path):
        result = {}
        for edge in facts['resolved_edges']:
            keys(edge,('context','source','load_command_index','install_name','target_kind','target'))
            require(type(edge['context']) is str and type(edge['source']) is str,'native edge context/source type')
            integer(edge['load_command_index'],0,4095)
            if edge['source']!=path:
                continue
            key = edge['context'],edge['load_command_index']
            require(key not in result,'duplicate replayed native edge')
            result[key] = edge
        return result

    def reason(value):
        require(type(value) is str and value.strip() and len(value.encode('utf-8'))<=4096
                and not any(ord(c)<32 and c not in '\n\t' or ord(c)==127 for c in value),
                'bounded explicit native change reason required')

    change_index = {}
    for change in native_changes:
        keys(change,('path','load_command_changes','edge_changes'))
        path = relative(change['path'])
        require(path not in change_index and type(change['load_command_changes']) is list
                and len(change['load_command_changes'])<=4096 and type(change['edge_changes']) is list
                and len(change['edge_changes'])<=100000,'native change annotation shape')
        change_index[path] = change
    require(list(change_index)==sorted(change_index,key=lambda path:path.encode('utf-8')),
            'native change annotations must be sorted')
    expected_rewrites = set()
    for path in sorted(old_objects,key=lambda path:path.encode('utf-8')):
        context.budget.check()
        old,new = old_objects[path],new_objects[path]
        if canonical(before[path])==canonical(after[path]):
            require(canonical(old)==canonical(new),'unchanged native bytes changed native facts')
            require(canonical(list(edge_index(pre_facts,path).values()))
                    ==canonical(list(edge_index(post_facts,path).values())),
                    'UNREVIEWED_NATIVE_TRANSFORMATION: unchanged object dependency resolution changed',UNSUPPORTED)
            require(path not in transform_index and path not in change_index,'no-op native transformation/annotation')
            continue
        transform = transform_index.get(path)
        require(transform is not None and transform['operation'] in ('resign_macho','rewrite_macho_load_commands'),
                'changed native file lacks approved native operation')
        require(canonical(transform['before'])==canonical(before[path])
                and canonical(transform['after'])==canonical(after[path])
                and before[path]['mode']==after[path]['mode'],'native change exact rows/mode mismatch')
        reason(transform['reason'])
        require(canonical(old['architectures'])==canonical(new['architectures']),
                'UNREVIEWED_NATIVE_TRANSFORMATION: architecture change',UNSUPPORTED)
        for field in ('platform','minimum_os','sdk'):
            require(canonical(old[field])==canonical(new[field]),
                    'UNREVIEWED_NATIVE_TRANSFORMATION: platform/version change',UNSUPPORTED)
        old_edges,new_edges = edge_index(pre_facts,path),edge_index(post_facts,path)
        if transform['operation']=='resign_macho':
            for field in ('platform','minimum_os','sdk','install_name','rpaths'):
                require(canonical(old[field])==canonical(new[field]),
                        'UNREVIEWED_NATIVE_TRANSFORMATION: resign changed '+field,UNSUPPORTED)
            old_commands = [cmd for cmd in old['load_commands'] if cmd['cmd']!='LC_CODE_SIGNATURE']
            new_commands = [cmd for cmd in new['load_commands'] if cmd['cmd']!='LC_CODE_SIGNATURE']
            require(canonical(old_commands)==canonical(new_commands),
                    'UNREVIEWED_NATIVE_TRANSFORMATION: resign changed load commands',UNSUPPORTED)
            # Index shifts solely from LC_CODE_SIGNATURE insertion/removal are
            # normalized here; targets and source/context relationships cannot change.
            without_index = lambda edges: sorted(
                (canonical({key:value for key,value in edge.items() if key!='load_command_index'})
                 for edge in edges.values()))
            require(without_index(old_edges)==without_index(new_edges),
                    'UNREVIEWED_NATIVE_TRANSFORMATION: resign changed dependency targets',UNSUPPORTED)
            require(path not in change_index,'resign cannot carry rewrite annotations')
            continue
        expected_rewrites.add(path)
        require(path in change_index,'missing exact native rewrite annotations')
        expected_commands = []
        for index in range(max(len(old['load_commands']),len(new['load_commands']))):
            a = old['load_commands'][index] if index<len(old['load_commands']) else None
            b = new['load_commands'][index] if index<len(new['load_commands']) else None
            if canonical(a)==canonical(b):
                continue
            # Pure signature-command deltas are not relocation annotations.
            if (a is None or a['cmd']=='LC_CODE_SIGNATURE') and (b is None or b['cmd']=='LC_CODE_SIGNATURE'):
                continue
            expected_commands.append({'index':index,'before':a,'after':b})
        require(expected_commands,'rewrite operation has no non-signature load-command change')
        supplied = change_index[path]['load_command_changes']
        require(len(supplied)==len(expected_commands),'incomplete/extra load-command changes')
        for actual,expected in zip(supplied,expected_commands):
            keys(actual,('index','before','after','reason'))
            integer(actual['index'],0,4095); reason(actual['reason'])
            require(canonical({key:actual[key] for key in expected})==canonical(expected),
                    'load-command rewrite annotation mismatch')
        expected_edges = []
        for key in sorted(set(old_edges)|set(new_edges)):
            a,b = old_edges.get(key),new_edges.get(key)
            if canonical(a)!=canonical(b):
                expected_edges.append({'context':key[0],'index':key[1],'before':a,'after':b})
        supplied = change_index[path]['edge_changes']
        require(len(supplied)==len(expected_edges),'incomplete/extra resolved-edge changes')
        for actual,expected in zip(supplied,expected_edges):
            keys(actual,('context','index','before','after','reason'))
            integer(actual['index'],0,4095); reason(actual['reason'])
            require(canonical({key:actual[key] for key in expected})==canonical(expected),
                    'resolved-edge rewrite annotation mismatch')
    require(set(change_index)==expected_rewrites,'extra/missing native rewrite annotation paths')
    return {'native_paths':sorted(old_objects,key=lambda path:path.encode('utf-8')),
            'rewrite_paths':sorted(expected_rewrites,key=lambda path:path.encode('utf-8'))}

def _native_resolve_required(rows, name):
    """Resolve only the independently validated closure; never consult the host."""
    index = {row['path']:row for row in rows}
    parts = name.split('/'); resolved = []; hops = 0
    while parts:
        part = parts.pop(0)
        if part in ('', '.'): continue
        if part == '..':
            require(resolved, 'required native path escapes closure'); resolved.pop(); continue
        resolved.append(part); current = '/'.join(resolved)
        require(current in index, 'required native path absent')
        row = index[current]
        if row['kind'] == 'symlink':
            hops += 1; require(hops <= 64, 'required native path link bound')
            resolved.pop(); parts = row['target'].split('/') + parts
        elif parts:
            require(row['kind'] == 'directory', 'required native path crosses non-directory')
    target = '/'.join(resolved)
    require(index.get(target,{}).get('kind') == 'file', 'required native executable is not regular')
    return target


def _native_probe_contract(context, contract, base, *, relocated=False):
    keys(contract, ('schema_version','kind','gates'))
    integer(contract['schema_version'],1,1)
    require(contract['kind']=='runtime_native_probe_contract','wrong native probe contract')
    permitted = (_NATIVE_GATE_IDS[4],_NATIVE_GATE_IDS[5],_NATIVE_GATE_IDS[6]) if relocated else _NATIVE_GATE_IDS
    keys(contract['gates'],permitted)
    result = {}
    for gate in permitted:
        specification = contract['gates'][gate]
        keys(specification,('invocations','expectations'))
        keys(specification['expectations'],_NATIVE_EXPECTATION_FIELDS[gate])
        expected = dict(base)
        # Only these fixed gate keys are admitted; derived identity fields cannot
        # be supplied by the approval or overridden by a receipt.
        for key in _NATIVE_EXPECTATION_FIELDS[gate]:
            expected[key] = specification['expectations'][key]
        invocations = _ng_list(specification['invocations'],0,10000)
        events = {}
        for invocation in invocations:
            keys(invocation,('id','role','argv','source','target','environment'))
            name = _ng_text(invocation['id'],'approved event id',200)
            require(name not in events,'duplicate approved native invocation')
            require(invocation['role'] in ('pip_check','voice_helper','voice_probe','splash_probe',
                    'urlsession_probe','urlsession_builder'), 'unsupported native invocation role')
            _ng_source(invocation['source'],context.sources)
            if invocation['role']=='urlsession_probe':
                _ng_source(invocation['target'],context.sources)
            else:
                _ng_file(invocation['target'],base['files'])
                required = ('Splash/python/bin/python3' if invocation['role']=='splash_probe'
                            else 'Voice/python/bin/python3')
                require(invocation['target']['path']==_native_resolve_required(list(base['files'].values()),required),
                        'native probe uses alternate bundled interpreter')
            _ng_list(invocation['argv'],1,128)
            for arg in invocation['argv']: _ng_text(arg,'approved argv item')
            require(type(invocation['environment']) is dict,'exact invocation environment required')
            events[name] = {key:value for key,value in invocation.items() if key!='id'}
        expected['events'] = events
        if 'interpreter' in specification['expectations']:
            _ng_equal(expected['interpreter'],base['interpreter'],'fixed shared voice interpreter')
        if 'model_input_admission' in expected:
            require(type(expected['model_input_admission']) is dict,'model admission map required')
            _ng_source(expected['model_input_admission'].get('owner_source'),context.sources)
        result[gate] = expected
    return result


def _native_receipt_event(gate, expected, static_events, artifacts):
    if gate in (_NATIVE_GATE_IDS[0],_NATIVE_GATE_IDS[2]):
        return next(event for event in static_events if event['role']=='host_arm64'), True
    if gate in (_NATIVE_GATE_IDS[1],_NATIVE_GATE_IDS[3],_NATIVE_GATE_IDS[8]):
        artifact = expected['facts_event_artifact']
    elif gate == _NATIVE_GATE_IDS[4]:
        artifact = expected['voice_trace_event_artifact']
    elif gate == _NATIVE_GATE_IDS[5]:
        artifact = expected['case_producer_event_artifacts']['cancel']
    elif gate == _NATIVE_GATE_IDS[6]:
        artifact = expected['case_producer_event_artifacts']['splash_listener']
    else:
        relocated = expected['relocated_expected'][_NATIVE_GATE_IDS[4]]
        artifact = relocated['voice_trace_event_artifact']
    return _ng_facts(artifact,artifacts), False


def _validate_native_receipt_header(receipt, expected, event, static, artifacts):
    keys(receipt,('schema_version','kind','gate','bindings','host','started','ended','duration_ms',
                  'outcome','cleanup','argv','environment_artifact','probe_source','outputs',
                  'before_signed_identity','after_signed_identity','observations'))
    keys(receipt['host'],('os','os_version','sdk','architecture','chip'))
    require(receipt['host']['os']=='macOS' and receipt['host']['architecture']=='arm64','actual macOS arm64 host required')
    for value in receipt['host'].values(): _ng_text(value,'host fact',200)
    for field in ('before_signed_identity','after_signed_identity'):
        require(receipt[field]==expected['signed_identity'],'receipt mutated signed closure')
    for field in ('started','ended','duration_ms','outcome','cleanup','argv'):
        _ng_equal(receipt[field],event[field],'receipt concrete execution '+field)
    _ng_equal(receipt['probe_source'],event['source'],'receipt concrete probe source')
    _ng_equal(receipt['outputs'],[event['stdout'],event['stderr']],'receipt raw output pins')
    if static:
        raw = _ng_artifact(receipt['environment_artifact'],'canonical_facts',artifacts)
        require(raw==native_canonical(event['environment']),'receipt static environment differs')
    else:
        _ng_equal(receipt['environment_artifact'],event['environment_artifact'],'receipt concrete environment')
    _ng_outcome(receipt['outcome']); _ng_cleanup(receipt['cleanup'])
    integer(receipt['duration_ms'],0,600000)
    for field in ('started','ended'):
        try: parsed = datetime.datetime.fromisoformat(receipt[field])
        except (TypeError,ValueError) as exc: raise Rejected('invalid native receipt wall diagnostic') from exc
        require(parsed.utcoffset() is not None,'native receipt wall diagnostic lacks timezone')


def _read_native_approval_impl(context,basis,before_rows,final_rows,evidence_dir,payload_root):
    """Full source-owned approval admission, with no execution or marker trust."""
    admission = _read_native_approval_envelope(context,basis,before_rows,final_rows,evidence_dir)
    record=admission['record']; artifacts=admission['artifacts']; receipts=admission['receipts']
    require(set(context.policy['required_native_evidence'])==set(_NATIVE_GATE_IDS),'fixed native gate set changed')
    _validate_native_gate_set(list(receipts.values()))
    files=validate_rows(final_rows,context.bounds)
    lock_path='packaging/voice/complete-voice-lock.json'
    require(lock_path in context.sources,'current source-owned voice lock required',MISSING)
    _,raw=read_path(context.source_root/lock_path,context.budget,context.sources[lock_path])
    lock=strict_json(raw)
    require(lock.get('kind')=='complete_voice_wheel_lock' and lock.get('target')==
            {'implementation':'cpython','python':'3.11.17','platform':'macos-arm64'},'voice lock target mismatch')
    wheels=_ng_list(lock.get('wheels'),92,92)
    locked=[]
    for wheel in wheels:
        require(type(wheel) is dict,'invalid locked distribution')
        name=_ng_text(wheel.get('name'),'locked distribution name',200)
        require(re.fullmatch('[a-z0-9]+(?:-[a-z0-9]+)*',name),'locked distribution name not normalized')
        locked.append({'name':name,'version':_ng_text(wheel.get('version'),'locked version',200)})
    locked.sort(key=lambda row:row['name'])
    require(len({row['name'] for row in locked})==92,'duplicate locked distribution')
    versions={row['name']:row['version'] for row in locked}
    import_names={'kokoro':'kokoro','misaki':'misaki','torch':'torch','numpy':'numpy','spacy':'spacy','en_core_web_sm':'en-core-web-sm'}
    require(set(import_names.values())<=set(versions),'fixed product imports absent from lock')
    interpreter_path=_native_resolve_required(final_rows,'Voice/python/bin/python3')
    interpreter={'path':interpreter_path,'file_pin':{key:files[interpreter_path][key] for key in ('bytes','sha256')},
                 'implementation':'CPython','version':'3.11.17','architecture':'arm64',
                 'prefix':'Voice/python','base_prefix':'Voice/python'}
    _ng_absolute(payload_root)
    model_paths=('Voice/model/config.json','Voice/model/kokoro-v1_0.pth','Voice/model/voices/bf_isabella.pt')
    asset_map={row['path']:row for row in context.policy['speech_asset_pins']}
    require(set(model_paths)<=set(asset_map),'all exact source-owned Voice model pins required')
    base={'files':files,'source_identities':context.sources,'basis_identity':admission['bindings']['basis_identity'],
          'collector_bundle_identity':digest(native_canonical(basis['collector_bundle'])),
          'historical_manifest':basis['historical_manifest'],'prepared_identity':admission['bindings']['prepared_identity'],
          'transform_identity':digest(native_canonical(record['transforms'])),
          'signed_identity':admission['bindings']['signed_identity'],'payload_root':payload_root,
          'source_root':str(context.source_root),'voice_python_root':'Voice/python','interpreter':interpreter,
          'locked_distributions':locked,'import_versions':{key:versions[name] for key,name in import_names.items()},
          'voice_model_pins':[asset_map[name] for name in model_paths],'native_inventory':record['native_inventory']}
    expected=_native_probe_contract(context,record['probe_contract'],base)
    static_gate=_NATIVE_GATE_IDS[2]; static_observations=receipts[static_gate]['observations']
    require(type(static_observations) is dict and type(static_observations.get('tool_events')) is list,
            'retained native static tool events required')
    parsed=_parse_native_static_evidence(context,final_rows,record['native_inventory'],static_observations['tool_events'],artifacts)
    expected[static_gate].update(parsed)
    pre_expected=expected[static_gate]
    pre_events=_ng_facts(pre_expected['pre_sign_tool_events_artifact'],artifacts)
    pre_parsed=_parse_native_static_evidence(context,before_rows,pre_expected['pre_sign_inventory'],pre_events,artifacts)
    _validate_native_change_semantics(context,before_rows,final_rows,record['transforms'],
        pre_parsed['parsed_static_facts'],parsed['parsed_static_facts'],pre_expected['native_changes'])
    relocated=expected[_NATIVE_GATE_IDS[7]]
    _ng_absolute(relocated['relocated_payload_root'])
    require(relocated['relocated_payload_root'].endswith('/'+relative(relocated['relocation_relative_path']))
            and relocated['relocated_payload_root']!=payload_root,'relocation root does not match reviewed distinct test path')
    relocated_base={**base,'payload_root':relocated['relocated_payload_root']}
    relocated['relocated_expected']=_native_probe_contract(context,relocated['relocated_contract'],relocated_base,relocated=True)
    model=expected[_NATIVE_GATE_IDS[6]]['model_input_admission']
    _ng_equal(expected[_NATIVE_GATE_IDS[8]]['model_input_admission'],model,'shared complete-model admission')
    relocated_model=relocated['relocated_expected'][_NATIVE_GATE_IDS[6]]['model_input_admission']
    _ng_equal({key:value for key,value in relocated_model.items() if key!='receipt'},
              {key:value for key,value in model.items() if key!='receipt'},'relocated complete-model admission')
    require(_ng_artifact(relocated_model['receipt'],'canonical_facts',artifacts)==
            _ng_artifact(model['receipt'],'canonical_facts',artifacts),'relocated model owner raw receipt changed')
    host=None
    for gate in _NATIVE_GATE_IDS:
        context.budget.check()
        receipt=receipts[gate]
        _validate_native_gate_observations(gate,receipt['observations'],expected=expected[gate],artifacts=artifacts)
        event,is_static=_native_receipt_event(gate,expected[gate],static_observations['tool_events'],artifacts)
        _validate_native_receipt_header(receipt,expected[gate],event,is_static,artifacts)
        if host is None: host=receipt['host']
        else: _ng_equal(receipt['host'],host,'shared actual native host')
    read_path(context.source_root/NATIVE_PATH,context.budget,admission['approval_pin']);context.recheck()
    admission['kind']='native_runtime_gates_verified'
    admission['verified_static_facts']=parsed['parsed_static_facts']
    admission['verified_facts']={'approval_sha256':admission['approval_pin']['sha256'],
        'prepared_identity':admission['bindings']['prepared_identity'],'signed_identity':admission['bindings']['signed_identity'],
        'evidence_identity':record['evidence_identity'],'components':record['final_components'],'gates':sorted(receipts)}
    return admission


def _validate_fresh_native_static(context,rows,admission,fresh):
    keys(fresh,('native_objects','code_bundles','launch_contexts','resolved_edges','system_targets','tool_events',
                'raw_artifacts','metadata_empty_before','metadata_empty_after'))
    parsed=_parse_native_static_evidence(context,rows,admission['record']['native_inventory'],fresh['tool_events'],fresh['raw_artifacts'])
    for field in ('native_objects','code_bundles','launch_contexts','resolved_edges','system_targets'):
        _ng_equal(fresh[field],parsed['parsed_static_facts'][field],'fresh parsed '+field)
        _ng_equal(fresh[field],admission['verified_static_facts'][field],'fresh approved '+field)
    for field in ('metadata_empty_before','metadata_empty_after'):
        _ng_empty_metadata(fresh[field],{'files':{row['path']:row for row in rows}})
    return fresh


def _finalize(context,stage,evidence_dir):
    require(sys.platform=='darwin','NATIVE_REQUIRED: finalization requires actual macOS verification',UNSUPPORTED)
    require(context.phase=='native','native source phase required')
    stage=Path(stage).absolute(); evidence_dir=Path(evidence_dir).absolute()
    disjoint(stage,[context.source_root,evidence_dir])
    disjoint(evidence_dir,[context.source_root])
    # Hold one existing checkpoint inode for the entire transaction. There is no
    # lock-file creation, stale-lock deletion or caller-provided lock bypass.
    with Root(stage) as root, parent_at(root.fd,'stage-state.json') as (parent,name):
        lock=os.open(name,FLAGS,dir_fd=parent)
        try:
            info=os.fstat(lock)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_uid==os.geteuid(),
                    'owned single-link checkpoint lock required')
            try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError as exc: raise Rejected('native finalization already active',MUTATION) from exc
            _native_stage_boundary(context,root)
            basis,state,before_rows=_read_prepared_basis(context,root)
            # Read approved closure from the source trust root, never from an
            # acceptance marker or candidate manifest. Full admission rereads it.
            try: approval_pin,raw=read_path(context.source_root/NATIVE_PATH,context.budget)
            except FileNotFoundError: raise Rejected('SOURCE_OWNED_NATIVE_BUILD_RECORD_REQUIRED',MISSING) from None
            approved=strict_json(raw)
            require(type(approved) is dict and 'final_closure' in approved,'source-owned final closure required')
            final_rows=approved['final_closure'];validate_rows(final_rows,context.bounds)
            admission=_read_native_approval(context,basis,before_rows,final_rows,evidence_dir,str(stage/'payload'))
            require(admission['approval_pin']=={key:approval_pin[key] for key in ('bytes','sha256')},
                    'source approval changed during admission',MUTATION)
            manifest_raw=_final_manifest_bytes(context,final_rows,admission['verified_facts'])
            with Root(stage/'payload') as payload:
                manifest_pin=_native_manifest_state(context,payload,manifest_raw)
                require(tree(payload.path,context.budget,manifest_pin)==final_rows,'actual final signed closure differs',MUTATION)
                try:
                    fresh=_verify_native_static(context,payload,admission['record']['native_inventory'],manifest_pin=manifest_pin)
                except (Rejected,OSError,KeyboardInterrupt) as exc:
                    capture=getattr(exc,'native_static_capture',None)
                    if capture is not None:
                        try: _retain_native_failure(context,root,admission,capture)
                        except (Rejected,OSError) as retention:
                            # Preserve the actual failure/cancellation and its
                            # deadline. Diagnostic retention cannot authorize a
                            # second attempt or extend the operation budget.
                            exc.native_capture_retention_error=str(retention)
                    raise
                _validate_fresh_native_static(context,final_rows,admission,fresh)
                same_node(info,os.stat(name,dir_fd=parent,follow_symlinks=False))
                context.recheck();root.check();payload.check()
                return _commit_native_finalization(context,root,admission,fresh)
        finally:
            os.close(lock)


def _retain_native_failure(context,stage,admission,capture):
    """Bounded unsuccessful native diagnostics, with no manifest or acceptance."""
    keys(capture,('tool_events','raw_artifacts'))
    require(type(capture['raw_artifacts']) is dict,'native failure capture map required')
    entries=[];files={};total=0
    for name,raw in sorted(capture['raw_artifacts'].items()):
        relative(name)
        require(name.endswith(('.stdout','.stderr')) and type(raw) is bytes and len(raw)<=2_097_152,
                'native failure raw stream bound',MUTATION)
        total+=len(raw);require(total<=32_000_000,'native failure aggregate bound',MUTATION)
        path='fresh/'+name;files[path]=raw
        entries.append({'path':path,'kind':('canonical_facts' if name=='commands/native-system-targets.stdout' else
                                'stderr' if name.endswith('.stderr') else 'stdout'),
                        'bytes':len(raw),'sha256':digest(raw)})
    _native_artifact_index(entries)
    report={'schema_version':1,'kind':'runtime_native_finalization_failed','approval_pin':admission['approval_pin'],
            'signed_identity':admission['bindings']['signed_identity'],'native_accepted':False,
            'fresh_artifacts':entries,'tool_events':capture['tool_events']}
    files['attempt.json']=native_canonical(report)
    used_bytes,used_nodes=_native_namespace_usage(context,stage)
    parents={'.'}
    for name in files:
        parts=name.split('/');parents.update('/'.join(parts[:end]) for end in range(1,len(parts)))
    need=sum(map(len,files.values()))
    require(used_bytes+need<=NATIVE_ARTIFACT_TOTAL and used_nodes+len(files)+len(parents)<=100000,
            'all finalization failure attempts bound',MUTATION)
    reserve(stage.fd,need,context.budget)
    try: os.mkdir(NATIVE_FINALIZATION_DIR,0o700,dir_fd=stage.fd);os.fsync(stage.fd)
    except FileExistsError: pass
    with Root(stage.path/NATIVE_FINALIZATION_DIR) as namespace:
        name='.attempt-'+uuid.uuid4().hex
        os.mkdir(name,0o700,dir_fd=namespace.fd);os.fsync(namespace.fd)
        with Root(namespace.path/name) as attempt:
            _native_write_files(attempt,files)
        os.fsync(namespace.fd);stage.check()


def _read_native_approval(context,basis,before_rows,final_rows,evidence_dir,payload_root):
    try:
        return _read_native_approval_impl(context,basis,before_rows,final_rows,evidence_dir,payload_root)
    except Rejected:
        raise
    except (TypeError,KeyError,IndexError,AttributeError) as exc:
        # Untrusted exact-schema JSON must never escape the declared rejection
        # interface through a nested type/missing-key dereference. Filesystem,
        # cancellation and actual native execution exceptions are not swallowed.
        raise Rejected('malformed native approval or gate expectation schema') from exc

# END NATIVE COMPOSITION

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
    return _finalize(Context(phase='native'),stage,evidence_dir)


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
        sys.stderr.write('CANCELLED: operation not confirmed; revalidation required\n')
        return MUTATION


if __name__ == '__main__':
    sys.exit(main())
