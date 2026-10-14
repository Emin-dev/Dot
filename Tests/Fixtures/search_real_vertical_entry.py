#!/usr/bin/env python3
"""BUILD-ONLY entrypoint, copied as overlay/dot_search.py after separate review.

This is not production admission. It calls the exact reviewed supervisor and
serve_production bodies; it never calls or replaces verify_payload. Its only
transport seam wraps registration: the original must first accept the actual
pinned, fully started Network with verify=True and no clients, then that one
Network receives the fixed synthetic trust file. No request or socket patch.
"""
from pathlib import Path
import hashlib
import importlib.metadata
import importlib.util
import json
import os
import re
import stat
import sys
import time

HELPER_SHA256 = 'c97c37e08301d0c081120fb2390d6ae67d994953c141bbba3be0dde7cc0b622a'
PROFILE_SHA256 = 'd0d952bb0df8fb74dc278f9085bd7558ea04c4e69be6746c5b9d3786907ab492'
LOCK_SHA256 = '25394a63db4084d606e56e25c7cec6a8fc979b03901c3b9739f2754e104a8920'
PINS_SHA256 = '61491617b34dfb144adf97212578c9aa12248ae1bef45ef516314c818ce22d44'
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_TREE_BYTES = 256 * 1024 * 1024
MAX_FILES = 6000
SCENARIOS = frozenset(('success-close', 'success-exit', 'startup-failure', 'cancellation', 'untrusted', 'wrong-host', 'replay'))
DESCRIPTOR = 'fixture/vertical-fixture.json'
PRE_INVENTORY = 'fixture/build-fixture-inventory.json'
EXTRA_FILES = frozenset(('bin/dot-search-bootstrap', DESCRIPTOR, 'fixture/trust.pem',
                         'fixture/search-lock.json', 'fixture/pinned-hashes.json'))
POISON = frozenset(('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy',
                   'https_proxy', 'all_proxy', 'no_proxy', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
                   'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'PYTHONPATH', 'PYTHONHOME', 'PYTHONSTARTUP'))


class FixtureFailure(Exception):
    """Always converted to a fixed public failure, never exception formatting."""


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def unique_object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise FixtureFailure()
        out[key] = value
    return out


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def regular(path, limit=MAX_FILE_BYTES):
    path = Path(path)
    if path.absolute() != path.resolve(strict=True):
        raise FixtureFailure()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or
                type(limit) is not int or not 0 <= limit <= MAX_FILE_BYTES or before.st_size > limit):
            raise FixtureFailure()
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(before.st_size + 1)
        after = os.fstat(fd)
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mode, s.st_nlink, s.st_mtime_ns, s.st_ctime_ns)
        if fields(before) != fields(after) or fields(after) != fields(path.lstat()) or len(raw) != before.st_size:
            raise FixtureFailure()
        return raw
    finally:
        os.close(fd)


def checked_json(path, expected=None, limit=8 * 1024 * 1024):
    raw = regular(path, limit)
    if expected is not None and sha(raw) != expected:
        raise FixtureFailure()
    return decode(raw)


def verify_fixture(root):
    if (sys.platform != 'darwin' or os.uname().machine != 'arm64' or
            sys.version_info[:3] != (3, 11, 17) or not sys.flags.isolated or
            not sys.flags.no_site or not sys.dont_write_bytecode or POISON.intersection(os.environ) or
            Path(sys.executable).resolve() != root / 'python/bin/python3'):
        raise FixtureFailure()
    descriptor = checked_json(root / DESCRIPTOR, limit=4096)
    if (type(descriptor) is not dict or set(descriptor) != {'schema', 'kind', 'scenario', 'trust_sha256', 'pre_native_inventory_sha256', 'bootstrap_sha256'} or
            type(descriptor['schema']) is not int or descriptor['schema'] != 1 or descriptor['kind'] != 'unaccepted-real-search-fixture' or
            type(descriptor['scenario']) is not str or descriptor['scenario'] not in SCENARIOS or
            any(not isinstance(descriptor[key], str) or not re.fullmatch('[0-9a-f]{64}', descriptor[key])
                for key in ('trust_sha256', 'pre_native_inventory_sha256', 'bootstrap_sha256'))):
        raise FixtureFailure()
    manifest = checked_json(root / PRE_INVENTORY, descriptor['pre_native_inventory_sha256'])
    if (type(manifest) is not dict or type(manifest.get('schema')) is not int or manifest.get('schema') != 1 or manifest.get('kind') != 'build-fixture-pre-native-inventory' or
            manifest.get('production_acceptance') is not False or manifest.get('runtime_ready') is not False or
            manifest.get('status') != 'unaccepted-non-launchable-overlay'):
        raise FixtureFailure()
    records = manifest.get('files')
    if type(records) is not list or not 1 <= len(records) <= MAX_FILES:
        raise FixtureFailure()
    expected = {}
    total = 0
    for item in records:
        if (type(item) is not dict or set(item) != {'path', 'sha256', 'size', 'mode'} or
                type(item['path']) is not str or type(item['size']) is not int or not 0 <= item['size'] <= MAX_FILE_BYTES or
                type(item['sha256']) is not str or not re.fullmatch('[0-9a-f]{64}', item['sha256']) or
                item['mode'] not in ('0o644', '0o755')):
            raise FixtureFailure()
        total += item['size']
        if total > MAX_TREE_BYTES:
            raise FixtureFailure()
        name = item['path']
        relative = Path(name)
        if (not name or len(name) > 1024 or any(ord(char) < 32 or ord(char) >= 127 for char in name) or
                '\\' in name or relative.is_absolute() or '..' in relative.parts or relative.as_posix() != name or
                name in expected or set(item) != {'path', 'sha256', 'size', 'mode'}):
            raise FixtureFailure()
        expected[name] = item
    actual = set()
    actual_bytes = 0
    for index, path in enumerate(root.rglob('*')):
        if index >= 12000:
            raise FixtureFailure()
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        name = path.relative_to(root).as_posix()
        if name not in expected and name not in EXTRA_FILES and name != PRE_INVENTORY:
            raise FixtureFailure()
        if len(actual) >= MAX_FILES + len(EXTRA_FILES) + 1:
            raise FixtureFailure()
        raw = regular(path, expected[name]['size'] if name in expected else 8 * 1024 * 1024)
        actual.add(name)
        actual_bytes += len(raw)
        if actual_bytes > MAX_TREE_BYTES:
            raise FixtureFailure()
        if name in expected:
            item = expected[name]
            if (sha(raw) != item['sha256'] or len(raw) != item['size'] or
                    oct(stat.S_IMODE(info.st_mode)) != item['mode']):
                raise FixtureFailure()
    if actual != set(expected) | EXTRA_FILES | {PRE_INVENTORY}:
        raise FixtureFailure()
    for name, expected_hash in {
        'fixture/dot_search_host.py': HELPER_SHA256, 'search.sb': PROFILE_SHA256,
        'fixture/search-lock.json': LOCK_SHA256, 'fixture/pinned-hashes.json': PINS_SHA256,
        'fixture/trust.pem': descriptor['trust_sha256'],
        'bin/dot-search-bootstrap': descriptor['bootstrap_sha256'],
    }.items():
        if sha(regular(root / name)) != expected_hash:
            raise FixtureFailure()
    # The externally bound pre-native manifest must cover our exact copied bytes.
    if expected['dot_search.py']['sha256'] != sha(regular(Path(__file__))):
        raise FixtureFailure()
    site = root / 'python/lib/python3.11/site-packages'
    if not site.is_dir() or list(site.glob('*.pth')):
        raise FixtureFailure()
    sys.path.insert(0, str(site))
    return descriptor


def dependency_probe(root):
    import ssl
    import curl_cffi
    import certifi
    site = root / 'python/lib/python3.11/site-packages'
    lock = checked_json(root / 'fixture/search-lock.json', LOCK_SHA256)
    pins = checked_json(root / 'fixture/pinned-hashes.json', PINS_SHA256)
    if (type(lock) is not dict or type(lock.get('wheels')) is not list or not 1 <= len(lock['wheels']) <= 100 or
            type(lock.get('searxng')) is not dict or type(pins) is not dict or type(pins.get('files')) is not dict):
        raise FixtureFailure()
    versions = {}
    for package in lock['wheels']:
        if (type(package) is not dict or type(package.get('name')) is not str or
                type(package.get('version')) is not str):
            raise FixtureFailure()
        version = importlib.metadata.version(package['name'])
        if version != package['version']:
            raise FixtureFailure()
        versions[package['name']] = version
    for name, expected in pins['files'].items():
        if sha(regular(site / name)) != expected:
            raise FixtureFailure()
    if lock['searxng']['revision'] != pins['searxng_revision'] or not ssl.OPENSSL_VERSION.startswith('OpenSSL 3.5.9 '):
        raise FixtureFailure()
    origins = {}
    from searx.engines import engines
    for name in ('searx.webapp', 'searx.network.network', 'searx.network.client', 'duckduckgo', 'curl_cffi'):
        module = engines.get('duckduckgo') if name == 'duckduckgo' else sys.modules.get(name)
        if module is None or not getattr(module, '__file__', None):
            raise FixtureFailure()
        path = Path(module.__file__).resolve(strict=True)
        if not path.is_relative_to(site):
            raise FixtureFailure()
        origins[name] = path.relative_to(root).as_posix()
    cert = Path(certifi.where()).resolve(strict=True)
    if not cert.is_relative_to(root):
        raise FixtureFailure()
    curl = curl_cffi.Curl()
    try:
        version = curl.version().decode('ascii')
    finally:
        curl.close()
    if len(version) > 512 or any(ord(c) < 32 or ord(c) > 126 for c in version):
        raise FixtureFailure()
    return {'python': '3.11.17', 'openssl': ssl.OPENSSL_VERSION, 'curl': version,
            'versions': versions, 'module_origins': origins, 'pinned_sources': pins['files'],
            'bundled_ca_sha256': sha(regular(cert))}


def marker(root, name, content):
    if root.absolute() != root.resolve(strict=True) or root.stat().st_mode & 0o077:
        raise FixtureFailure()
    raw = json.dumps(content, sort_keys=True, separators=(',', ':')).encode() + b'\n'
    if len(raw) > 16384:
        raise FixtureFailure()
    destination = root / name
    # Publish complete bytes at one rename: XCTest never mistakes a partially
    # written observation for a failed native initialization. One fixed producer
    # owns each marker in this freshly created private state directory.
    if destination.exists() or destination.is_symlink():
        raise FileExistsError()
    temporary = root / (name + '.writing')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    if destination.exists() or destination.is_symlink():
        raise FileExistsError()
    os.rename(temporary, destination)


def configure_registration(helper, root, descriptor):
    original = helper.install_private_ddg_processor
    def register(capability, proxy_port):
        # Must run first on the actual Network created by actual searx.webapp.
        processor = original(capability, proxy_port)
        import searx.network
        from searx.network.network import Network
        network = searx.network.get_network('duckduckgo')
        if ('searx.webapp' not in sys.modules or type(network) is not Network or
                network.verify is not True or network._clients or
                network.proxies != {'all://': 'http://127.0.0.1:' + str(proxy_port)}):
            raise FixtureFailure()
        probe = dependency_probe(root)
        network.verify = str(root / 'fixture/trust.pem')
        state_root = Path.cwd().parent
        marker(state_root, 'fixture-initialized.json', {
            'schema': 1, 'original_registration_passed': True, 'actual_webapp_loaded': True,
            'empty_clients_guard_passed': True, 'dependency_probe': probe})
        if descriptor['scenario'] == 'startup-failure':
            raise helper.SearchFailure('invalid_worker')
        return processor
    helper.install_private_ddg_processor = register


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    root = Path(__file__).absolute().parent
    if root != root.resolve(strict=True):
        raise FixtureFailure()
    worker = len(arguments) == 4 and arguments[0] == '--serve'
    supervisor = (len(arguments) == 8 and arguments[::2] == ['--payload', '--state-root', '--owned-listener', '--egress-port']
                  and arguments[1] == str(root) and arguments[5] == '3')
    if not worker and not supervisor:
        raise FixtureFailure()
    numeric = arguments[1:] if worker else [arguments[7]]
    if any(not re.fullmatch('[1-9][0-9]{0,9}', value) or int(value) > 2147483647 for value in numeric):
        raise FixtureFailure()
    descriptor = verify_fixture(root)
    helper_path = root / 'fixture/dot_search_host.py'
    specification = importlib.util.spec_from_file_location('dot_search_host', helper_path)
    helper = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(helper)
    if worker:
        configure_registration(helper, root, descriptor)
        return helper.serve_production(*(int(value) for value in arguments[1:]))
    state_root = Path(arguments[3])
    if state_root.absolute() != state_root.resolve(strict=True) or state_root == root or state_root.is_relative_to(root):
        raise FixtureFailure()
    egress_port = helper.parse_egress_port(arguments[7])
    def command(listener, bootstrap, lifeline):
        return [sys.executable, '-I', '-S', '-B', str(root / 'dot_search.py'), '--serve',
                str(listener), str(bootstrap), str(lifeline)]
    result = helper.supervise(str(state_root), command, listener_fd=3, egress_port=egress_port)
    marker(state_root, 'fixture-supervisor-returned.json', {'schema': 1, 'supervisor_returned': True})
    if descriptor['scenario'] == 'success-exit':
        time.sleep(3)
    return result


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        # Never format exceptions, argv, private bootstrap frames, or endpoints.
        sys.stdout.buffer.write(b'{"protocol":1,"event":"failed","reason":"payload_unavailable"}\n')
        sys.stdout.buffer.flush()
        raise SystemExit(2)
