#!/usr/bin/env python3
"""Stage an unaccepted, NON-LAUNCHABLE real-search fixture using ordinary copies.

This builder never builds or executes the bootstrap or payload. --check-inputs
verifies exact source-owned identities, including the separately reviewed
entrypoint. Construction produces only a statically verified ordinary copy;
native execution, runtime admission and production acceptance remain pending.
There are no caller-controlled target, trust, environment, or input-set knobs.

Usage: python3 -B scripts/prepare_search_real_canary_payload.py \
    --donor /canonical/historical/payload --check-inputs
To construct the unaccepted overlay, replace --check-inputs with --output /new/fixture.
The returned inventory SHA-256 must be held outside the overlay for rechecking.
This inventory is neither runtime admission nor a native execution receipt.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
# Approved diagnostics base tree; the separate overlay/harness additions are
# not a claim that this whole composition has production or native acceptance.
SOURCE_COMPOSITION = '9d3c971fea249af4d73bd4b432584486be92beae'
# Minimal execution-input closure, from the reviewed composition assessment.
SOURCE_PINS = {
    'Resources/Search/dot_search.py': 'c97c37e08301d0c081120fb2390d6ae67d994953c141bbba3be0dde7cc0b622a',
    'Resources/Search/search.sb': 'd0d952bb0df8fb74dc278f9085bd7558ea04c4e69be6746c5b9d3786907ab492',
    'packaging/search/dot-search-bootstrap.c': '637c9778cfdf0a7e790f3a4fc43069da05cfd5eb299273a5aab01491fa77f55d',
    'scripts/build_search_bootstrap.sh': '3307e84fbb7ca6911ae23f2a83baefccc0086f62ee484c6647227f5a12d427e2',
    'packaging/search/search-lock-native-owner.json': '25394a63db4084d606e56e25c7cec6a8fc979b03901c3b9739f2754e104a8920',
    'scripts/search_proxy_canary_support.py': '107edd91f27ed66d522e4721b41e433d55dbc2a6aae02fff6b32b10b147ed19d',
}
BUILDER_SOURCE = 'scripts/prepare_search_real_canary_payload.py'
ENTRYPOINT = 'Tests/Fixtures/search_real_vertical_entry.py'
REVIEWED_ENTRYPOINT_SHA256 = 'a9bef0fd8db827e2e8bf6cc29af208797a3d443794b2fc94461152555c8feda4'
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_TREE_BYTES = 256 * 1024 * 1024
MAX_FILES = 6000
MAX_NODES = 12000
LOCK_SHA256 = '0f094efe0cd2dc4d459a87ec9618884bd4f05bacd6c834ddd1036e813f2a4b80'
RECEIPT_SHA256 = '4268358594bf02881357334812b8f7ee84764940752071b1febd3ace26adbbab'
DONOR_TREE_SHA256 = 'c144cd5f64885f264baf1700c8ec51d221c1f6332c973763ec79d1c09fc74369'
# Includes the historical receipt and permission bits (the old receipt does not).
DONOR_INVENTORY_SHA256 = '2c86890170e4b8ff14c27069a8b694a09855513e337c792d2e084ecab670ae5b'
DONOR_FILES = 4824
RECEIPT = 'evidence/assembly-input-receipt.json'
HISTORICAL_RECEIPT = 'fixture/historical-assembly-input-receipt.json'
HOST_HELPER = 'fixture/dot_search_host.py'
INVENTORY = 'fixture/build-fixture-inventory.json'
PENDING_NATIVE_INPUTS = ['native fixture controller and certificate lifecycle execution',
                         'exact native bootstrap build and binary identity',
                         'native XCTest and all execution receipts']


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def is_sha256(value):
    return type(value) is str and len(value) == 64 and all(char in '0123456789abcdef' for char in value)


def decode_object(raw, label):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate JSON object key in ' + label)
            result[key] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        raise ValueError('invalid ' + label + ' JSON') from None
    if type(value) is not dict:
        raise ValueError(label + ' must be a JSON object')
    return value


def canonical_path(path, *, exists=True):
    path = Path(path).absolute()
    if path != path.resolve(strict=exists) or any(part.lower().endswith('.app') for part in path.parts):
        raise ValueError('require canonical non-aliased path outside app bundles')
    return path


def stat_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_regular(path, *, limit=None):
    """Read one non-aliased ordinary file; bind bytes and stat from one open FD."""
    path = canonical_path(path)
    limit = MAX_FILE_BYTES if limit is None else limit
    if type(limit) is not int or not 0 <= limit <= MAX_FILE_BYTES:
        raise ValueError('invalid file byte limit')
    parent = open_directory(path.parent)
    fd = None
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     dir_fd=parent)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('require singly linked regular file')
        if stat.S_IMODE(before.st_mode) not in (0o644, 0o755):
            raise ValueError('unexpected file mode')
        if not 0 <= before.st_size <= limit:
            raise ValueError('input file exceeds byte limit')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            # One extra byte detects growth without ever chasing a moving EOF.
            data = stream.read(before.st_size + 1)
        after = os.fstat(fd)
        if (stat_identity(before) != stat_identity(after) or
                stat_identity(canonical_path(path).lstat()) != stat_identity(after) or len(data) != before.st_size):
            raise ValueError('input changed while reading')
        return data, {'sha256': sha(data), 'size': len(data), 'mode': oct(stat.S_IMODE(before.st_mode))}
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def inventory(root):
    root = canonical_path(root)
    root_info = root.lstat()
    if not stat.S_ISDIR(root_info.st_mode):
        raise ValueError('input root is not a directory')
    records, directories = [], set()
    pending = [(root, stat_identity(root_info))]
    nodes = total = 0
    while pending:
        directory_path, expected_identity = pending.pop()
        directory = open_directory(directory_path)
        try:
            if stat_identity(os.fstat(directory)) != expected_identity:
                raise ValueError('input directory changed during traversal')
            # Consume entries incrementally; no recursive glob or directory
            # listing can allocate an unbounded list before the node cap.
            with os.scandir(directory) as entries:
                for entry in entries:
                    nodes += 1
                    if nodes > MAX_NODES:
                        raise ValueError('tree exceeds node limit')
                    path = directory_path / entry.name
                    name = path.relative_to(root).as_posix()
                    info = os.stat(entry.name, dir_fd=directory, follow_symlinks=False)
                    if stat.S_ISLNK(info.st_mode):
                        raise ValueError('tree contains an alias')
                    if stat.S_ISDIR(info.st_mode):
                        directories.add(name)
                        pending.append((path, stat_identity(info)))
                        continue
                    if len(records) >= MAX_FILES:
                        raise ValueError('tree exceeds file limit')
                    if info.st_size > MAX_TREE_BYTES - total:
                        raise ValueError('tree exceeds aggregate byte limit')
                    _, record = read_regular(path, limit=min(MAX_FILE_BYTES, MAX_TREE_BYTES - total))
                    if stat_identity(info) != stat_identity(os.stat(entry.name, dir_fd=directory, follow_symlinks=False)):
                        raise ValueError('input changed during traversal')
                    total += record['size']
                    records.append({'path': name, **record})
            if (stat_identity(os.fstat(directory)) != expected_identity or
                    stat_identity(canonical_path(directory_path).lstat()) != expected_identity):
                raise ValueError('input directory changed during traversal')
        finally:
            os.close(directory)
    expected_dirs = {str(parent) for item in records for parent in Path(item['path']).parents
                     if str(parent) != '.'}
    if directories != expected_dirs:
        raise ValueError('tree contains unexpected empty directories')
    return sorted(records, key=lambda item: item['path'])


def source_inputs():
    root = canonical_path(ROOT)
    records, data, observed = [], {}, {}
    def read_source(name):
        path = canonical_path(root / name)
        observed[name] = stat_identity(path.lstat())
        return read_regular(path)
    for name, expected in sorted(SOURCE_PINS.items()):
        raw, record = read_source(name)
        if record['sha256'] != expected:
            raise ValueError('reviewed source identity differs: ' + name)
        data[name] = raw
        records.append({'path': name, **record})
    # Self identity is descriptive and rechecked, not a self-issued approval pin.
    # The independently reviewed patch/inventory binds the builder itself.
    _, producer = read_source(BUILDER_SOURCE)
    records.append({'path': BUILDER_SOURCE, **producer})
    missing = []
    if REVIEWED_ENTRYPOINT_SHA256 is None:
        if (root / ENTRYPOINT).exists() or (root / ENTRYPOINT).is_symlink():
            raise ValueError('fixture entrypoint present without source-owned reviewed identity')
        missing.append(ENTRYPOINT + ' and its source-owned reviewed SHA-256')
    else:
        raw, record = read_source(ENTRYPOINT)
        if record['sha256'] != REVIEWED_ENTRYPOINT_SHA256:
            raise ValueError('reviewed fixture entrypoint identity differs')
        data[ENTRYPOINT] = raw
        records.append({'path': ENTRYPOINT, **record})
    # Validate the already bounded exact bytes. Do not reopen them through the
    # legacy support verifier or execute any source, donor or fixture module.
    # Support remains pinned as an input needed by the separately reviewed harness.
    raw_lock = data['packaging/search/search-lock-native-owner.json']
    lock = decode_object(raw_lock, 'source lock')
    if sha(canonical(lock)) != LOCK_SHA256:
        raise ValueError('exact payload lock differs from canary lock')
    lock_identity = {'lock_sha256': LOCK_SHA256, 'lock_file_sha256': sha(raw_lock)}
    for name, before in observed.items():
        if stat_identity(canonical_path(root / name).lstat()) != before:
            raise ValueError('source changed during verification: ' + name)
    return sorted(records, key=lambda item: item['path']), data, lock_identity, missing


def verify_donor_records(donor, records):
    """Validate historical receipt semantics using only bounded, bound records.

    The legacy verifier's valid identity format is unchanged. Malformed JSON
    shapes, duplicate keys and boolean schema values fail closed explicitly.
    """
    raw, receipt_record = read_regular(donor / RECEIPT)
    inventoried = next((item for item in records if item['path'] == RECEIPT), None)
    if inventoried != {'path': RECEIPT, **receipt_record}:
        raise ValueError('receipt changed after inventory')
    if sha(raw) != RECEIPT_SHA256:
        raise ValueError('unaccepted assembly receipt does not match reviewed identity')
    # Match legacy read_text()/json.loads() receipt encoding semantics. Passing
    # bytes directly would additionally admit UTF-16/32 and a UTF-8 BOM. Source
    # lock validation deliberately keeps its separate legacy byte-JSON behavior.
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        raise ValueError('invalid assembly receipt UTF-8') from None
    receipt = decode_object(text, 'assembly receipt')
    if (type(receipt.get('schema')) is not int or receipt.get('schema') != 1 or
            receipt.get('status') != 'unaccepted-static-assembly' or receipt.get('native_executed') is not False):
        raise ValueError('only an independent unaccepted static assembly is supported')
    if not is_sha256(receipt.get('lock_sha256')):
        raise ValueError('assembly must identify its exact source lock')
    files = receipt.get('files')
    if type(files) is not list or not 1 <= len(files) <= MAX_FILES:
        raise ValueError('invalid assembly file count')
    expected, total = {}, 0
    for item in files:
        if type(item) is not dict or not {'path', 'sha256', 'size'}.issubset(item):
            raise ValueError('invalid assembly file record')
        name = item['path']
        if type(name) is not str:
            raise ValueError('unsafe or duplicate receipt path')
        parts = PurePosixPath(name)
        if not name or parts.is_absolute() or '..' in parts.parts or str(parts) != name or name in expected:
            raise ValueError('unsafe or duplicate receipt path')
        if (not is_sha256(item['sha256']) or type(item['size']) is not int or
                not 0 <= item['size'] <= MAX_FILE_BYTES):
            raise ValueError('invalid assembly file record')
        total += item['size']
        if total > MAX_TREE_BYTES:
            raise ValueError('assembly exceeds aggregate byte limit')
        expected[name] = item
    if 'python/bin/python3' not in expected or 'dot_search.py' not in expected:
        raise ValueError('independent Search interpreter/helper absent from receipt')
    actual = set()
    for record in records:
        name = record['path']
        if PurePosixPath(name).name in ('search-runtime-manifest.json', 'search-acceptance.json'):
            raise ValueError('production admission files are not allowed in a build-only input')
        if name == RECEIPT:
            continue
        actual.add(name)
        item = expected.get(name)
        if item is None or record['size'] != item['size'] or record['sha256'] != item['sha256']:
            raise ValueError('payload differs from unaccepted receipt: ' + name)
    if actual != set(expected):
        raise ValueError('receipt files are missing from unaccepted payload')
    historical_records = [{'path': name, 'sha256': expected[name]['sha256'], 'size': expected[name]['size']}
                          for name in sorted(expected)]
    return {'assembly_receipt_sha256': RECEIPT_SHA256,
            'assembly_lock_sha256': receipt['lock_sha256'],
            'interpreter_sha256': expected['python/bin/python3']['sha256'],
            'payload_tree_sha256': sha(canonical(historical_records)),
            'payload_file_count': len(historical_records),
            'tree_hash_format': 'sha256(canonical-json-sort_keys-compact(sorted-path-size-sha256-records))'}


def inputs(donor):
    sources, data, _, missing = source_inputs()
    donor = canonical_path(donor)
    if donor == ROOT or donor.is_relative_to(ROOT) or ROOT.is_relative_to(donor):
        raise ValueError('donor must be independent of source checkout')
    records = inventory(donor)
    identity = verify_donor_records(donor, records)
    if (identity['assembly_lock_sha256'] != LOCK_SHA256 or
            identity['payload_tree_sha256'] != DONOR_TREE_SHA256 or
            identity['payload_file_count'] != DONOR_FILES):
        raise ValueError('exact historical donor identity differs')
    if sha(canonical(records)) != DONOR_INVENTORY_SHA256:
        raise ValueError('exact historical donor inventory or modes differ')
    return sources, data, identity, records, missing


def check_inputs(donor):
    sources, _, identity, records, missing = inputs(donor)
    return {'schema': 1, 'kind': 'real-search-overlay-input-check',
            'status': 'pending-reviewed-entrypoint' if missing else 'static-inputs-verified',
            'native_executed': False, 'production_acceptance': False,
            'runtime_ready': False, 'missing_required_inputs': missing,
            'pending_native_inputs': PENDING_NATIVE_INPUTS,
            'source_input_records_sha256': sha(canonical(sources)),
            'donor_inventory_sha256': sha(canonical(records)), 'donor': identity}


def expected_overlay(sources, data, donor_identity, donor_records):
    if ENTRYPOINT not in data:
        raise ValueError('missing reviewed fixture entrypoint; see --check-inputs')
    old = {item['path']: item for item in donor_records}
    if not {'dot_search.py', 'search.sb', RECEIPT}.issubset(old):
        raise ValueError('historical donor replacement closure differs')
    replacements = {'dot_search.py': data[ENTRYPOINT],
                    'search.sb': data['Resources/Search/search.sb'],
                    HOST_HELPER: data['Resources/Search/dot_search.py']}
    new = {name: item for name, item in old.items() if name != RECEIPT}
    for name, raw in replacements.items():
        if name == HOST_HELPER and name in old:
            raise ValueError('donor collides with fixture addition')
        new[name] = {'path': name, 'sha256': sha(raw), 'size': len(raw), 'mode': '0o644'}
    if HISTORICAL_RECEIPT in new or INVENTORY in new:
        raise ValueError('donor collides with fixture evidence')
    new[HISTORICAL_RECEIPT] = {**old[RECEIPT], 'path': HISTORICAL_RECEIPT}
    delta = [{'path': name, 'before': old.get(name), 'after': new.get(name)}
             for name in sorted(old.keys() | new.keys()) if old.get(name) != new.get(name)]
    files = [new[name] for name in sorted(new)]
    manifest = {'schema': 1, 'kind': 'build-fixture-pre-native-inventory',
                'status': 'unaccepted-non-launchable-overlay', 'native_executed': False,
                'production_acceptance': False, 'production_admission_exercised': False,
                'app_enabled': False, 'runtime_ready': False,
                'pending_native_inputs': PENDING_NATIVE_INPUTS,
                'source_composition_context': SOURCE_COMPOSITION,
                'source_identity_scope': 'pinned-overlay-inputs-only-not-entire-composed-tree',
                'source_inputs': sources, 'source_input_records_sha256': sha(canonical(sources)),
                'donor': donor_identity, 'donor_inventory_sha256': sha(canonical(donor_records)),
                'files': files, 'overlay_records_sha256': sha(canonical(files)), 'delta': delta,
                'inventory_excludes_only': INVENTORY,
                'tree_hash_format': 'sha256(canonical-json-sort_keys-compact(sorted-path-mode-size-sha256-records))'}
    return manifest, replacements


def independent_output(donor, output):
    if any(output == root or output.is_relative_to(root) or root.is_relative_to(output)
           for root in (canonical_path(ROOT), canonical_path(donor))):
        raise ValueError('overlay must be independent of donor and source checkout')


def verify_overlay(donor, output, expected_inventory_sha256):
    """External expected digest is required; never trust the overlay to bless itself."""
    output = canonical_path(output)
    independent_output(donor, output)
    sources, data, identity, records, missing = inputs(donor)
    if missing:
        raise ValueError('missing reviewed fixture entrypoint; see --check-inputs')
    expected, _ = expected_overlay(sources, data, identity, records)
    raw, inventory_record = read_regular(output / INVENTORY)
    if inventory_record['mode'] != '0o644':
        raise ValueError('build-fixture inventory mode differs')
    if sha(raw) != expected_inventory_sha256 or raw != canonical(expected) + b'\n':
        raise ValueError('build-fixture inventory identity differs')
    actual = inventory(output)
    files = [item for item in actual if item['path'] != INVENTORY]
    if files != expected['files']:
        raise ValueError('overlay differs from exact allowlisted delta')
    return {'schema': 1, 'kind': expected['kind'], 'status': expected['status'],
            'native_executed': False, 'production_acceptance': False,
            'runtime_ready': False, 'inventory_sha256': sha(raw),
            'overlay_records_sha256': expected['overlay_records_sha256'],
            'overlay_file_count': len(files), 'pending_native_inputs': PENDING_NATIVE_INPUTS}


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def open_directory(path):
    """Walk from / using no-follow directory FDs, never a mutable path prefix."""
    path = canonical_path(path)
    directory = os.open('/', DIRECTORY_FLAGS)
    try:
        for part in path.parts[1:]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=directory)
            os.close(directory)
            directory = child
        return directory
    except BaseException:
        os.close(directory)
        raise


def require_private_directory(directory):
    info = os.fstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError('overlay directories must remain private and owned')


def require_bound_output(directory, output):
    require_private_directory(directory)
    current = canonical_path(output).lstat()
    owned = os.fstat(directory)
    if (current.st_dev, current.st_ino) != (owned.st_dev, owned.st_ino):
        raise ValueError('owned overlay directory moved or replaced')


def create_output(output):
    parent = open_directory(output.parent)
    try:
        os.mkdir(output.name, mode=0o700, dir_fd=parent)
        directory = os.open(output.name, DIRECTORY_FLAGS, dir_fd=parent)
        try:
            require_private_directory(directory)
        except BaseException:
            os.close(directory)
            raise
        return directory
    finally:
        os.close(parent)


def write_copy(root, name, raw, mode):
    """Write only within the newly owned directory graph, never through aliases.

    The root and each child stay anchored by open directory descriptors. A
    same-UID actor can rename an owned directory, but cannot redirect these FDs
    into an unrelated symlink target. Final path/inventory checks reject such
    moved or aliased trees. We do not claim isolation from arbitrary same-UID
    modification of already opened files; partial trees are always unaccepted.
    """
    relative = Path(name)
    if relative.is_absolute() or str(relative) != name or not relative.parts or any(part in ('.', '..') for part in relative.parts):
        raise ValueError('unsafe overlay relative path')
    directory = os.dup(root)
    try:
        require_private_directory(directory)
        for part in relative.parts[:-1]:
            try:
                os.mkdir(part, mode=0o700, dir_fd=directory)
            except FileExistsError:
                pass
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=directory)
            os.close(directory)
            directory = child
            require_private_directory(directory)
        fd = os.open(relative.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, 'wb', closefd=False) as stream:
                stream.write(raw)
                stream.flush()
            os.fchmod(fd, int(mode, 8))
        finally:
            os.close(fd)
    finally:
        os.close(directory)


def prepare(donor, output):
    donor = canonical_path(donor)
    output = canonical_path(output, exists=False)
    if output.exists():
        raise ValueError('overlay output must be new')
    independent_output(donor, output)
    if not output.parent.is_dir():
        raise ValueError('overlay parent must already exist')
    sources, data, identity, records, missing = inputs(donor)
    if missing:
        raise ValueError('missing reviewed fixture entrypoint; see --check-inputs')
    expected, replacements = expected_overlay(sources, data, identity, records)
    directory = create_output(output)  # Exclusive; failed partial trees remain unaccepted.
    try:
        for record in expected['files']:
            name = record['path']
            if name in replacements:
                raw = replacements[name]
            else:
                raw, _ = read_regular(donor / (RECEIPT if name == HISTORICAL_RECEIPT else name))
            if sha(raw) != record['sha256'] or len(raw) != record['size']:
                raise ValueError('donor changed during ordinary copy')
            write_copy(directory, name, raw, record['mode'])
        require_bound_output(directory, output)
        if inventory(output) != expected['files']:
            raise ValueError('copied overlay differs before inventory creation')
        final_sources, _, final_identity, final_records, final_missing = inputs(donor)
        if (sources, identity, records, missing) != (final_sources, final_identity, final_records, final_missing):
            raise ValueError('source or donor changed during construction')
        require_bound_output(directory, output)
        raw = canonical(expected) + b'\n'
        write_copy(directory, INVENTORY, raw, '0o644')
        result = verify_overlay(donor, output, sha(raw))
        require_bound_output(directory, output)
        return result
    finally:
        os.close(directory)



def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--donor', type=Path, required=True, help='existing exact historical unaccepted payload')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check-inputs', action='store_true', help='verify available inputs without writing; pending exits 2')
    mode.add_argument('--output', type=Path, help='new independent non-launchable overlay directory')
    args = parser.parse_args(argv)
    try:
        result = check_inputs(args.donor) if args.check_inputs else prepare(args.donor, args.output)
    except (ValueError, OSError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 2 if result.get('missing_required_inputs') else 0


if __name__ == '__main__':
    raise SystemExit(main())
