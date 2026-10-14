#!/usr/bin/env python3
"""Controller for the opt-in, BUILD-ONLY real Swift Search vertical.

No payload execution occurs on import or --preflight. --run is Darwin/arm64
only and remains gated by the overlay builder's SOURCE-OWNED entrypoint/C pins.
No downloads, signing, workflow dispatch, production manifest, or App action.
The owned origin uses TLSOrigin; there is no Python CONNECT endpoint.
"""
from pathlib import Path
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import platform
import re
import selectors
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'Tests/Fixtures'
SCENARIOS = {
    'success-close': 'testSuccessCloseReceipts', 'success-exit': 'testSuccessHelperExit',
    'startup-failure': 'testFullInitializationStartupFailure', 'cancellation': 'testInFlightCancellation',
    'untrusted': 'testUntrustedCertificate', 'wrong-host': 'testWrongHostname',
    'replay': 'testPrecedingManagerCapabilityReplay',
}
SOURCE_FIXED = (
    'Package.swift', 'Resources/Search/dot_search.py', 'Resources/Search/search.sb',
    'packaging/search/dot-search-bootstrap.c', 'packaging/search/search-lock-native-owner.json',
    'scripts/build_search_bootstrap.sh', 'scripts/prepare_search_real_canary_payload.py',
    'scripts/search_proxy_canary_support.py', 'scripts/verify_search_real_vertical_canary.sh',
    'Tests/Fixtures/search_real_vertical_entry.py', 'Tests/Fixtures/search_real_vertical_fixture.py',
    'Tests/Fixtures/search_proxy_fixture_support.py', 'Tests/Fixtures/search_proxy_pinned_hashes.json',
)
BOOTSTRAP_SOURCE_SHA256 = '637c9778cfdf0a7e790f3a4fc43069da05cfd5eb299273a5aab01491fa77f55d'
HELPER_SHA256 = 'c97c37e08301d0c081120fb2390d6ae67d994953c141bbba3be0dde7cc0b622a'
OWNER_SHA256 = 'af26f193829f7680d7d56b0c4c68141630538282c67842cd4d7d5a0e030ffa4f'
BODY = (b'<html><body><div id="links"><div class="web-result"><h2>'
        b'<a href="https://example.org/fixture">Synthetic result</a></h2>'
        b'<a class="result__snippet">Offline parser fixture</a></div></div></body></html>')
RESPONSE = (b'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ' +
            str(len(BODY)).encode() + b'\r\nConnection: close\r\n\r\n' + BODY)


class CanaryFailure(Exception):
    """Fixed category only. Never wrap native stdout/stderr or arbitrary values."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode() + b'\n'


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def builder_module():
    return load_module('real_search_overlay_builder', ROOT / 'scripts/prepare_search_real_canary_payload.py')


def canonical_path(path, exists=True):
    path = Path(path).absolute()
    if path != path.resolve(strict=exists) or any(part.lower().endswith('.app') for part in path.parts):
        raise CanaryFailure('aliased-path')
    return path


def private_directory(path):
    path = canonical_path(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise CanaryFailure('private-directory-required')
    return path


def new_directory(path):
    path = canonical_path(path, exists=False)
    path.mkdir(mode=0o700)
    return private_directory(path)


def read_regular(path):
    path = canonical_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 <= before.st_size <= 64 * 1024 * 1024:
            raise CanaryFailure('ordinary-file-required')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(before.st_size + 1)
        after = os.fstat(fd)
        identify = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identify(before) != identify(after) or identify(after) != identify(path.lstat()) or len(raw) != before.st_size:
            raise CanaryFailure('file-changed')
        return raw, {'sha256': sha(raw), 'size': len(raw), 'mode': oct(stat.S_IMODE(before.st_mode))}
    finally:
        os.close(fd)


def write_new(path, raw, mode=0o644):
    # All generated paths are below private controller-created roots. Reject all
    # aliases, including parent swaps, and bind the exact parent while writing.
    path = canonical_path(path, exists=False)
    parent = private_directory(path.parent)
    dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        inode = os.fstat(dfd)
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=dfd)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
        now = parent.lstat()
        if (inode.st_dev, inode.st_ino) != (now.st_dev, now.st_ino):
            raise CanaryFailure('output-parent-changed')
    finally:
        os.close(dfd)


def source_records():
    names = set(SOURCE_FIXED)
    names.update(path.relative_to(ROOT).as_posix() for path in (ROOT / 'src').glob('*.swift'))
    names.update(path.relative_to(ROOT).as_posix() for path in (ROOT / 'Tests/DotCoreTests').glob('*.swift'))
    records = [{'path': name, **read_regular(ROOT / name)[1]} for name in sorted(names)]
    if not any(item['path'] == 'Tests/DotCoreTests/RealSearchVerticalCanaryTests.swift' for item in records):
        raise CanaryFailure('native-tests-missing')
    return records


def inventory(kind, records):
    return {'schema': 1, 'kind': kind, 'files': records,
            'records_sha256': sha(json.dumps(records, sort_keys=True, separators=(',', ':')).encode())}


def preflight(donor):
    builder = builder_module()
    # Do not assign SOURCE_PINS, REVIEWED_ENTRYPOINT_SHA256, ROOT, or any other
    # builder policy. The separately reviewed source-owned rebind is mandatory.
    checked = builder.check_inputs(canonical_path(donor))
    if checked.get('missing_required_inputs') or checked.get('status') != 'static-inputs-verified':
        raise CanaryFailure('reviewed-overlay-identity-gate-pending')
    for name, expected in {
        'packaging/search/dot-search-bootstrap.c': BOOTSTRAP_SOURCE_SHA256,
        'Resources/Search/dot_search.py': HELPER_SHA256,
        'src/SearchRuntimeManager.swift': OWNER_SHA256,
    }.items():
        if read_regular(ROOT / name)[1]['sha256'] != expected:
            raise CanaryFailure('reviewed-native-source-mismatch')
    records = source_records()
    return builder, checked, records


def clean_environment(home, temporary, config=None, digest=None):
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(home), 'TMPDIR': str(temporary),
           'LANG': 'en_US.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'}
    if config is not None:
        env['DOT_REAL_SEARCH_FIXTURE_CONFIG'] = str(config)
        env['DOT_REAL_SEARCH_FIXTURE_CONFIG_SHA256'] = digest
    return env


def run_owned(command, *, cwd, env, seconds):
    """Bound drains; reuse the reviewed non-reaping process-group owner."""
    helper_path = ROOT / 'Resources/Search/dot_search.py'
    if read_regular(helper_path)[1]['sha256'] != HELPER_SHA256:
        raise CanaryFailure('reviewed-process-owner-mismatch')
    owner = load_module('real_search_reviewed_process_owner', helper_path)
    child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    streams = [bytearray(), bytearray()]
    selector = None
    try:
        selector = selectors.DefaultSelector()
        for index, pipe in enumerate((child.stdout, child.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, index)
        deadline = time.monotonic() + seconds
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise CanaryFailure('owned-process-deadline')
            for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                streams[key.data].extend(chunk)
                if sum(map(len, streams)) > 8 * 1024 * 1024:
                    raise CanaryFailure('owned-output-cap')
        # Preserve the unreaped leader even after its own exit. An inherited
        # pipe may still belong to an owned descendant; closing it is no receipt.
        while not owner.child_exited(child):
            if time.monotonic() >= deadline:
                raise CanaryFailure('owned-process-deadline')
            time.sleep(0.01)
    finally:
        try:
            # This exact reviewed implementation sends its final group signal
            # before reaping. It also runs after any selector/read exception.
            owner.stop_group(child)
        finally:
            if selector is not None:
                selector.close()
            for pipe in (child.stdout, child.stderr):
                pipe.close()
    if child.returncode != 0:
        raise CanaryFailure('owned-process-failed')
    return bytes(streams[0]), bytes(streams[1])


def build_artifacts(work, env):
    _, _ = run_owned(['/usr/bin/xcrun', 'swift', 'build', '--build-tests', '--configuration', 'debug',
                      '--scratch-path', str(work / 'build')], cwd=ROOT, env=env, seconds=600)
    candidates = list((work / 'build').glob('**/DotCorePackageTests.xctest/Contents/MacOS/DotCorePackageTests'))
    if len(candidates) != 1:
        raise CanaryFailure('exact-test-executable-not-found')
    executable = canonical_path(candidates[0])
    binary = read_regular(executable)[1]
    clang, _ = run_owned(['/usr/bin/xcrun', '--find', 'clang'], cwd=ROOT, env=env, seconds=10)
    swift, _ = run_owned(['/usr/bin/xcrun', '--find', 'swift'], cwd=ROOT, env=env, seconds=10)
    sdk, _ = run_owned(['/usr/bin/xcrun', '--show-sdk-path'], cwd=ROOT, env=env, seconds=10)
    clang_version, _ = run_owned(['/usr/bin/xcrun', 'clang', '--version'], cwd=ROOT, env=env, seconds=10)
    swift_version, _ = run_owned(['/usr/bin/xcrun', 'swift', '--version'], cwd=ROOT, env=env, seconds=10)
    sdk_version, _ = run_owned(['/usr/bin/xcrun', '--show-sdk-version'], cwd=ROOT, env=env, seconds=10)
    clang_path = Path(clang.decode().strip()).resolve(strict=True)
    swift_path = Path(swift.decode().strip()).resolve(strict=True)
    sdk_path = Path(sdk.decode().strip()).resolve(strict=True)
    def tool_hash(path):
        value = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                value.update(chunk)
        return value.hexdigest()
    sdk_settings = sdk_path / 'SDKSettings.json'
    if not sdk_settings.is_file():
        raise CanaryFailure('sdk-settings-identity-missing')
    return executable, {'test_executable_sha256': binary['sha256'], 'clang_path': str(clang_path),
        'clang_executable_sha256': tool_hash(clang_path), 'swift_executable_sha256': tool_hash(swift_path),
        'sdk_settings_sha256': tool_hash(sdk_settings),
        'swift_path': str(swift_path), 'sdk_path': str(sdk_path),
        'clang_version': clang_version.decode().strip(), 'swift_version': swift_version.decode().strip(),
        'sdk_version': sdk_version.decode().strip(), 'swift_flags': ['build', '--build-tests', '--configuration', 'debug'],
        'bootstrap_flags': ['-arch', 'arm64', '-mmacosx-version-min=15.0', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-lsandbox']}


CONTROL_REQUEST_SECONDS = 3.0


class OriginControl:
    """Nonsecret XCTest-only control channel. Helper policy cannot reach it."""
    def __init__(self, support, cert, key, scenario):
        self.scenario = scenario
        self.condition = threading.Condition()
        self.releases = 0
        self.stopping = False
        self.control_lock = threading.Lock()
        self.active_control = {}
        self.close_lock = threading.Lock()
        self.closed = False
        self.close_error = None
        def response(index):
            with self.condition:
                if not self.condition.wait_for(lambda: self.stopping or self.releases >= index, timeout=12):
                    raise TimeoutError('origin-release-deadline')
                if self.stopping:
                    return b''
            return RESPONSE
        self.origin = support.TLSOrigin(cert, key, response).start()
        parent = self
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *ignored):
                pass
            def handle_one_request(self):
                self.connection.settimeout(CONTROL_REQUEST_SECONDS)
                # The accept-time watchdog closes the owned socket at one
                # absolute deadline, even when bytes keep refreshing read timeouts.
                try:
                    super().handle_one_request()
                except (OSError, TimeoutError):
                    self.close_connection = True
            def reply(self, release=False):
                valid = (self.path == ('/release' if release else '/snapshot') and
                         self.headers.get('Content-Length', '0') == '0' and
                         self.headers.get('Transfer-Encoding') is None and len(self.headers) <= 16)
                if not valid:
                    self.send_error(400)
                    self.close_connection = True
                    return
                if release:
                    with parent.condition:
                        if parent.releases >= 2:
                            self.send_error(409)
                            self.close_connection = True
                            return
                        parent.releases += 1
                        parent.condition.notify_all()
                raw = canonical(parent.snapshot())
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(raw)
                self.close_connection = True
            def do_GET(self):
                self.reply()
            def do_POST(self):
                self.reply(release=True)
        class Server(http.server.HTTPServer):
            def get_request(self):
                connection, address = super().get_request()
                with parent.control_lock:
                    if parent.stopping:
                        parent.close_control_socket(connection)
                        raise OSError('control-stopping')
                    timer = threading.Timer(CONTROL_REQUEST_SECONDS, parent.expire_control, args=(connection,))
                    parent.active_control[connection] = timer
                    try:
                        timer.start()
                    except BaseException:
                        parent.active_control.pop(connection, None)
                        parent.close_control_socket(connection)
                        raise
                return connection, address
            def shutdown_request(self, connection):
                try:
                    super().shutdown_request(connection)
                finally:
                    with parent.control_lock:
                        timer = parent.active_control.pop(connection, None)
                    if timer is not None:
                        timer.cancel()
                        timer.join()
            def handle_error(self, request, client_address):
                # Control peers can force disconnects, never diagnostic dumps.
                pass
        try:
            self.server = Server(('127.0.0.1', 0), Handler)
            self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.05})
            self.thread.start()
        except BaseException:
            if hasattr(self, 'server'):
                self.server.server_close()
            self.origin.close()
            raise

    def snapshot(self):
        with self.origin.lock:
            requests = list(self.origin.requests)
            sni = list(self.origin.sni)
            handshakes = self.origin.handshakes
            handlers = len(self.origin.handlers)
        fixed = True
        clean = True
        for request in requests:
            header, separator, body = request.partition(b'\r\n\r\n')
            lines = header.split(b'\r\n')
            fields = [line.split(b':', 1) for line in lines[1:] if b':' in line]
            hosts = [value.strip() for name, value in fields if name.lower() == b'host']
            fixed &= bool(separator and lines[0] == b'POST /html/ HTTP/1.1' and hosts == [b'html.duckduckgo.com'])
            try:
                form = urllib.parse.parse_qs(body.decode('ascii'), keep_blank_values=True, strict_parsing=True)
                fixed &= (set(form) == {'q', 'b', 'kl'} and form['q'] == ['build-only-synthetic-query'] and
                          form['b'] == [''] and len(form['kl']) == 1 and bool(re.fullmatch('[a-z]{2}-[a-z]{2,3}', form['kl'][0])))
            except (UnicodeError, ValueError):
                fixed = False
            clean &= not any(name.lower() in (b'authorization', b'proxy-authorization', b'x-dot-search-capability') for name, _ in fields)
            # Query/body is fixed by XCTest. No origin request bytes are serialized.
            clean &= not re.search(rb'(?:[0-9a-f]{64}|Basic [A-Za-z0-9+/]{80,}=*)', request)
        return {'schema': 1, 'scenario': self.scenario, 'origin_port': self.origin.address[1],
                'requests': len(requests), 'handshakes': handshakes, 'sni_count': len(sni),
                'fixed_sni_only': all(value == 'html.duckduckgo.com' for value in sni),
                'fixed_request_only': bool(fixed), 'credential_free': bool(clean),
                'response_releases': self.releases, 'active_handlers': handlers}

    @staticmethod
    def close_control_socket(connection):
        # shutdown wakes a makefile/readline even when close alone would retain
        # the descriptor through the handler's buffered stream reference.
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        connection.close()

    def expire_control(self, connection):
        with self.control_lock:
            if connection not in self.active_control:
                return
        self.close_control_socket(connection)

    def close(self):
        # Concurrent/repeated close callers share completion. Every cleanup step
        # runs even if another step raises; a missed receipt remains a failure.
        with self.close_lock:
            if self.closed:
                if self.close_error is not None:
                    raise CanaryFailure(self.close_error)
                return
            errors = []
            with self.condition:
                self.stopping = True
                self.condition.notify_all()
            with self.control_lock:
                owned = list(self.active_control.items())
            for connection, timer in owned:
                try:
                    timer.cancel()
                except Exception:
                    errors.append('control-deadline-cancel-failed')
                try:
                    self.close_control_socket(connection)
                except OSError:
                    errors.append('control-socket-close-failed')
            try:
                self.server.server_close()
            except Exception:
                errors.append('control-listener-close-failed')
            try:
                # Active readers were interrupted before this synchronous wait.
                self.server.shutdown()
            except Exception:
                errors.append('control-shutdown-failed')
            try:
                self.thread.join(4)
            except Exception:
                errors.append('control-thread-join-failed')
            for _, timer in owned:
                try:
                    timer.join(4)
                except Exception:
                    errors.append('control-deadline-join-failed')
            try:
                self.origin.close()
            except Exception:
                errors.append('origin-close-failed')
            with self.control_lock:
                control_drained = not self.active_control
            with self.origin.lock:
                origin_drained = (not self.origin.handlers and not self.origin.connections and
                                  self.origin.closed.is_set() and not self.origin.thread.is_alive() and
                                  self.origin.listener.fileno() == -1)
            timers_drained = all(not timer.is_alive() for _, timer in owned)
            self.closed = (not self.thread.is_alive() and self.server.socket.fileno() == -1 and
                           control_drained and origin_drained and timers_drained)
            if not self.closed:
                errors.append('control-or-origin-not-drained')
            if errors or self.close_error is not None:
                self.close_error = self.close_error or errors[0]
                raise CanaryFailure(self.close_error)


def validate_result(result, scenario):
    keys = {'schema', 'kind', 'scenario', 'status', 'failure_category', 'observations', 'dependency_probe'}
    if (type(result) is not dict or set(result) != keys or type(result['schema']) is not int or result['schema'] != 1 or
            result['scenario'] != scenario or result['status'] != 'passed' or
            result['kind'] != 'build-only-real-search-vertical-canary' or result['failure_category'] is not None):
        raise CanaryFailure('missing-or-nonpassing-xctest-receipt')
    observations = result['observations']
    if (type(observations) is not dict or len(observations) > 64 or
            observations.get('identity_and_drain_verified') is not True or
            observations.get('generation_count') != (2 if scenario == 'replay' else 1) or
            any(type(key) is not str or not re.fullmatch('[a-z_0-9]{1,80}', key) or
                type(value) not in (bool, int) or type(value) is int and not 0 <= value <= 100_000_000
                for key, value in observations.items())):
        raise CanaryFailure('invalid-xctest-observations')
    for key in ('production_admission_exercised', 'production_acceptance', 'app_enabled', 'live_provider_tested',
                'owner_macos_26_4_accepted', 'full_neural_app_accepted'):
        if observations.get(key) is not False:
            raise CanaryFailure('invalid-admission-claim')
    for key in ('actual_swift_broker_executed', 'actual_owned_bootstrap_source_executed', 'actual_reviewed_helper_bodies_executed'):
        if observations.get(key) is not True:
            raise CanaryFailure('missing-actual-execution-observation')
    probe = result['dependency_probe']
    if (type(probe) is not dict or set(probe) != {'python', 'openssl', 'curl', 'versions', 'module_origins', 'pinned_sources', 'bundled_ca_sha256'} or
            probe['python'] != '3.11.17' or type(probe['openssl']) is not str or not probe['openssl'].startswith('OpenSSL 3.5.9 ') or
            type(probe['curl']) is not str or 'libcurl/' not in probe['curl'] or
            len(probe['openssl']) > 128 or len(probe['curl']) > 512 or
            any(ord(char) < 32 or ord(char) > 126 for char in probe['openssl'] + probe['curl']) or
            type(probe['bundled_ca_sha256']) is not str or not re.fullmatch('[0-9a-f]{64}', probe['bundled_ca_sha256'])):
        raise CanaryFailure('invalid-dependency-observation')
    lock = json.loads(read_regular(ROOT / 'packaging/search/search-lock-native-owner.json')[0])
    pins = json.loads(read_regular(FIXTURES / 'search_proxy_pinned_hashes.json')[0])
    origins = {'searx.webapp': 'searx/webapp.py', 'searx.network.network': 'searx/network/network.py',
               'searx.network.client': 'searx/network/client.py', 'duckduckgo': 'searx/engines/duckduckgo.py',
               'curl_cffi': 'curl_cffi/__init__.py'}
    if (probe['versions'] != {item['name']: item['version'] for item in lock['wheels']} or
            probe['pinned_sources'] != pins['files'] or
            probe['module_origins'] != {name: 'python/lib/python3.11/site-packages/' + path for name, path in origins.items()}):
        raise CanaryFailure('dependency-identity-mismatch')
    return result


def run_case(builder, donor, work, scenario, certificates, support, executable, build, sources_path, source_digest, env):
    case = new_directory(work / scenario)
    owner_tmp = new_directory(case / 'owner-tmp')
    overlay = case / 'overlay'
    pre = builder.prepare(donor, overlay)
    cert_name = 'untrusted' if scenario == 'untrusted' else 'wrong-host' if scenario == 'wrong-host' else 'trusted'
    cert, key = certificates[cert_name]
    trust = certificates['wrong-host' if scenario == 'wrong-host' else 'trusted'][0]
    run_owned(['/bin/bash', str(ROOT / 'scripts/build_search_bootstrap.sh'), str(overlay)],
              cwd=ROOT, env=env, seconds=60)
    bootstrap_hash = read_regular(overlay / 'bin/dot-search-bootstrap')[1]['sha256']
    for src, dst in ((trust, 'fixture/trust.pem'),
                     (ROOT / 'packaging/search/search-lock-native-owner.json', 'fixture/search-lock.json'),
                     (FIXTURES / 'search_proxy_pinned_hashes.json', 'fixture/pinned-hashes.json')):
        write_new(overlay / dst, read_regular(src)[0])
    descriptor = {'schema': 1, 'kind': 'unaccepted-real-search-fixture', 'scenario': scenario,
                  'trust_sha256': read_regular(trust)[1]['sha256'],
                  'pre_native_inventory_sha256': pre['inventory_sha256'], 'bootstrap_sha256': bootstrap_hash}
    write_new(overlay / 'fixture/vertical-fixture.json', canonical(descriptor))
    records = builder.inventory(overlay)
    overlay_manifest = inventory('real-search-runtime-overlay-inventory', records)
    inventory_path = case / 'overlay-inventory.json'
    inventory_raw = canonical(overlay_manifest)
    write_new(inventory_path, inventory_raw)
    control = OriginControl(support, cert, key, scenario)
    error = None
    result = None
    try:
        result_path = case / 'xctest-result.json'
        config = {'schema': 1, 'scenario': scenario, 'overlay_root': str(overlay),
            'overlay_inventory_path': str(inventory_path), 'overlay_inventory_sha256': sha(inventory_raw),
            'source_root': str(ROOT), 'source_records_path': str(sources_path), 'source_records_sha256': source_digest,
            'bootstrap_sha256': bootstrap_hash, 'test_executable_sha256': build['test_executable_sha256'],
            'origin_port': control.origin.address[1], 'control_port': control.server.server_port,
            'result_path': str(result_path), 'owner_state_parent': str(owner_tmp)}
        config_path = case / 'config.json'
        config_raw = canonical(config)
        write_new(config_path, config_raw)
        child_env = clean_environment(work, owner_tmp, config_path, sha(config_raw))
        out, err = run_owned(['/usr/bin/xcrun', 'swift', 'test', '--skip-build', '--configuration', 'debug',
                   '--scratch-path', str(work / 'build'), '--filter', 'DotCoreTests.RealSearchVerticalCanaryTests/' + SCENARIOS[scenario]],
                   cwd=ROOT, env=child_env, seconds=110)
        # No XCTest stdout/stderr is copied into evidence. Exact tokens are only
        # known inside XCTest, which performs its own in-memory secret scans.
        del out, err
        raw, _ = read_regular(result_path)
        if len(raw) > 65536:
            raise CanaryFailure('xctest-receipt-cap')
        decoded = json.loads(raw)
        if raw != canonical(decoded):
            raise CanaryFailure('noncanonical-xctest-receipt')
        result = validate_result(decoded, scenario)
        observed = control.snapshot()
        expected_requests = 2 if scenario == 'replay' else 0 if scenario in ('startup-failure', 'untrusted', 'wrong-host') else 1
        if (observed['requests'] != expected_requests or not observed['credential_free'] or
                not observed['fixed_sni_only'] or not observed['fixed_request_only']):
            raise CanaryFailure('origin-boundary-failed')
        if scenario == 'startup-failure' and (observed['handshakes'] or observed['sni_count']):
            raise CanaryFailure('startup-failure-origin-traffic')
        if scenario in ('untrusted', 'wrong-host') and observed['sni_count'] < 1:
            raise CanaryFailure('negative-tls-not-attempted')
        if source_digest != sha(read_regular(sources_path)[0]) or source_records() != json.loads(read_regular(sources_path)[0])['files']:
            raise CanaryFailure('source-changed-during-case')
        if builder.inventory(overlay) != records or read_regular(executable)[1]['sha256'] != build['test_executable_sha256']:
            raise CanaryFailure('execution-identity-changed')
        if list(owner_tmp.iterdir()):
            raise CanaryFailure('owned-state-not-drained')
    except BaseException as caught:
        error = caught
    finally:
        control.close()
    if error is not None:
        raise error
    return {'scenario': scenario, 'status': 'passed', 'xctest': result, 'origin': observed,
        'origin_owner_drained': True, 'control_owner_drained': True,
        'pre_native_inventory_sha256': pre['inventory_sha256'], 'overlay_inventory_sha256': sha(inventory_raw),
        'overlay_records_sha256': overlay_manifest['records_sha256'], 'bootstrap_sha256': bootstrap_hash,
        'interpreter_sha256': read_regular(overlay / 'python/bin/python3')[1]['sha256'],
        'trust_certificate_sha256': descriptor['trust_sha256'], 'served_certificate_sha256': read_regular(cert)[1]['sha256']}


def run(args):
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        print('SKIP: real Search vertical requires Darwin arm64; no native evidence')
        return 77
    builder, checked, sources = preflight(args.donor)
    donor = canonical_path(args.donor)
    work_path = canonical_path(args.work, exists=False)
    if any(work_path == root or work_path.is_relative_to(root) or root.is_relative_to(work_path) for root in (ROOT, donor)):
        raise CanaryFailure('independent-work-root-required')
    work = new_directory(work_path)
    env = clean_environment(work, new_directory(work / 'build-tmp'))
    sources_path = work / 'source-inventory.json'
    sources_raw = canonical(inventory('real-search-source-inventory', sources))
    write_new(sources_path, sources_raw)
    report_path = work / 'real-search-vertical-report.json'
    results = [{'scenario': scenario, 'status': 'pending'} for scenario in SCENARIOS]
    report = {'schema': 1, 'kind': 'build-only-real-search-vertical-canary', 'status': 'pending',
        'production_admission_exercised': False, 'production_acceptance': False, 'app_enabled': False,
        'live_provider_tested': False, 'owner_macos_26_4_accepted': False, 'full_neural_app_accepted': False,
        'gateway_capability_replay': 'pending-not-part-of-this-lane',
        'source_identity_scope': 'composed-source-inventory-no-invented-git-commit',
        'source_inventory_sha256': sha(sources_raw), 'donor': checked['donor'],
        'canonical_lock_sha256': builder.LOCK_SHA256,
        'raw_lock_file_sha256': builder.SOURCE_PINS['packaging/search/search-lock-native-owner.json'],
        'historical_assembly_receipt_sha256': builder.RECEIPT_SHA256,
        'wrapper_sha256': read_regular(FIXTURES / 'search_real_vertical_entry.py')[1]['sha256'],
        'reviewed_helper_sha256': HELPER_SHA256, 'reviewed_bootstrap_source_sha256': BOOTSTRAP_SOURCE_SHA256,
        'donor_inventory_sha256': checked['donor_inventory_sha256'], 'scenarios': results,
        'fixture_admission': 'DEBUG owner plus exact separately reviewed fixture entrypoint; production helper CLI audit not invoked',
        'trust_seam': 'original real pinned registration first, then exact synthetic CA path on only its DuckDuckGo Network',
        'origin_credential_check_scope': 'fixed query form, absent authentication headers and credential-shaped bytes; private capabilities remain only in XCTest and real runtime pipes',
        'unverified': ['production admission and signing', 'Release DNS/TLS route', 'live provider', 'App and owner device acceptance']}
    error = None
    try:
        executable, build = build_artifacts(work, env)
        report['build'] = build
        if source_records() != sources:
            raise CanaryFailure('source-changed-during-build')
        support = load_module('real_search_tls_support', FIXTURES / 'search_proxy_fixture_support.py')
        certificates = support.create_certificates(new_directory(work / 'synthetic-certificates'))
        identity = load_module('real_search_host_identity', ROOT / 'scripts/search_proxy_canary_support.py')
        report['native_host'] = identity.native_host_identity()
        report['hosted_image'] = {name: os.environ[name] for name in ('ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH') if name in os.environ}
        for index, scenario in enumerate(SCENARIOS):
            try:
                results[index] = run_case(builder, donor, work, scenario, certificates, support,
                                         executable, build, sources_path, sha(sources_raw), env)
            except BaseException:
                results[index] = {'scenario': scenario, 'status': 'failed'}
                raise
        if identity.native_host_identity() != report['native_host']:
            raise CanaryFailure('native-host-identity-changed')
        for key, relative in (('clang_executable_sha256', build['clang_path']),
                              ('swift_executable_sha256', build['swift_path']),
                              ('sdk_settings_sha256', str(Path(build['sdk_path']) / 'SDKSettings.json'))):
            with Path(relative).open('rb') as stream:
                value = hashlib.sha256()
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    value.update(chunk)
            if value.hexdigest() != build[key]:
                raise CanaryFailure('toolchain-identity-changed')
        final_builder, final_checked, final_sources = preflight(donor)
        del final_builder
        if (final_checked, final_sources) != (checked, sources):
            raise CanaryFailure('donor-or-source-changed-after-run')
        report.update(status='passed', actual_swift_broker_executed=True,
            actual_owned_bootstrap_source_executed=True, actual_reviewed_helper_bodies_executed=True,
            preceding_manager_broker_capability_replay='passed')
    except BaseException as caught:
        error = caught
        report['status'] = 'failed'
        report['failure_category'] = str(caught) if type(caught) is CanaryFailure else 'controller-failed'
    finally:
        write_new(report_path, canonical(report))
    if error is not None:
        raise CanaryFailure(report['failure_category']) from None
    print(json.dumps({'status': 'passed', 'kind': report['kind'], 'report': str(report_path),
                      'production_acceptance': False}, sort_keys=True))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preflight', action='store_true')
    mode.add_argument('--run', action='store_true')
    parser.add_argument('--donor', required=True, type=Path)
    parser.add_argument('--work', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.preflight:
            _, checked, records = preflight(args.donor)
            print(json.dumps({'status': 'static-inputs-verified', 'native_executed': False,
                              'source_records_sha256': sha(canonical(records)), 'donor': checked['donor']}, sort_keys=True))
            return 0
        if args.work is None:
            raise CanaryFailure('new-private-work-path-required')
        return run(args)
    except Exception as error:
        category = str(error) if type(error) is CanaryFailure else 'reviewed-input-or-controller-check-failed'
        print('FAIL: ' + category, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
