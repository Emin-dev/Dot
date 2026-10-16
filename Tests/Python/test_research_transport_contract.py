"""Offline contract for the shipped native source reader (`dot-fetch`).

The Python reader this module used to import was deleted together with the Python
source-fetch stack. The product path is now the Rust binary built from
`crates/dot-research/src/fetch.rs` and launched by `ResearchFetchRuntime`, so these
checks run that real artifact against loopback fixtures and guard the Swift/Seatbelt
boundary. The networked end-to-end lane is
`crates/dot-research/tests/dot_fetch_e2e.py`.
"""
import os
import pathlib
import socket
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
READER = ROOT / 'target/release/dot-fetch'
PROFILE = ROOT / 'Resources/Research/source_fetch.sb'
RUST = ROOT / 'crates/dot-research/src/fetch.rs'
SWIFT = ROOT / 'src/ResearchHTTPTransport.swift'
RETIRED = ['dot_source_fetch.py', 'bionic_helper.py', 'dot_search.py']


def reader_path():
    if not (READER.is_file() and os.access(READER, os.X_OK)):
        raise unittest.SkipTest('build the native reader first: cargo build --release --manifest-path Cargo.toml --bin dot-fetch')
    return str(READER)


def run_reader(url, pin, seconds, prefix=(), stdin=None):
    """Spawn the shipped reader with exactly the host's argument shape."""
    return subprocess.run([*prefix, reader_path(), url, pin, str(seconds)],
                          stdin=stdin, capture_output=True, timeout=20, close_fds=True)


def loopback_listener():
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(2)
    listener.settimeout(2)
    return listener


class NativeSourceReaderContractTests(unittest.TestCase):
    def assert_refused_without_request_bytes(self, pin, prefix=()):
        """A refused reader exits 1, prints nothing and puts zero bytes on the wire."""
        listener = loopback_listener()
        inherited = None
        try:
            port = listener.getsockname()[1]
            inherited = socket.create_connection(('127.0.0.1', port), timeout=5)
            peer, _ = listener.accept()
            try:
                result = run_reader(f'https://fixture.invalid:{port}/private-source-query', pin, 1,
                                    prefix=prefix, stdin=inherited)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b'', b''))
            finally:
                inherited.close()  # The parent's descriptor is the peer's only possible sender.
                inherited = None
            peer.settimeout(1)
            self.assertEqual(peer.recv(1), b'', 'Refused reader sent request bytes')
            peer.close()
            listener.settimeout(0.05)
            with self.assertRaises(socket.timeout):
                listener.accept()
        finally:
            if inherited is not None:
                inherited.close()
            listener.close()

    def test_retired_python_reader_is_unreachable_from_the_product(self):
        self.assertFalse((ROOT / 'Resources/Research/dot_source_fetch.py').exists())
        self.assertFalse((ROOT / 'Resources/Search').exists())
        for source in sorted((ROOT / 'src').glob('*.swift')):
            with self.subTest(source=source.name):
                text = source.read_text()
                for retired in RETIRED:
                    self.assertNotIn(retired, text)
        payload = (ROOT / 'src/OfflinePayload.swift').read_text()
        self.assertIn('appendingPathComponent("dot-fetch")', payload)
        self.assertIn('ResearchFetchRuntime(signedHelper:', payload)
        self.assertNotIn('auditedPythonRoot', payload)
        self.assertIn('name = "dot-fetch"', (ROOT / 'crates/dot-research/Cargo.toml').read_text())
        self.assertIn('TcpStream::from_raw_fd(0)', RUST.read_text())

    def test_reader_adopts_only_the_inherited_descriptor_and_never_dials(self):
        reader = RUST.read_text()
        # No dialing, resolving or ambient-proxy call site exists in the shipped reader.
        for absent in ['TcpStream::connect', 'to_socket_addrs', 'getaddrinfo', 'socket(', 'HTTP_PROXY', 'no_proxy',
                       'SecTrustEvaluate', 'SecPolicyCreateSSL']:
            self.assertNotIn(absent, reader, absent)
        self.assertEqual(reader.count('from_raw_fd'), 1)
        # Exactly one GET with no credential, cookie or proxy header, over the shipped
        # system trust bundle rather than a trust daemon that may fetch missing issuers.
        self.assertIn('"GET {} HTTP/1.1\\r\\nHost: {}\\r\\nAccept: text/html, text/plain, application/pdf\\r\\n', reader)
        self.assertIn('for forbidden in ["Cookie", "Authorization", "Proxy-", "Referer", "Origin"]', reader)
        self.assertIn('/etc/ssl/cert.pem', reader)

    def test_private_and_mismatched_pins_never_reach_the_peer(self):
        self.assert_refused_without_request_bytes('127.0.0.1')
        self.assert_refused_without_request_bytes('1.1.1.1')

    def test_invalid_targets_timeouts_and_argument_counts_fail_closed(self):
        for url in ['https://localhost/', 'https://127.0.0.1/', 'http://example.org/', 'https://user:pass@example.org/',
                    'file:///etc/passwd', 'https://example.org/#fragment', 'https://example.org:0/',
                    'https://example.org:65536/', 'garbage', 'https://2130706433/']:
            with self.subTest(url=url):
                result = run_reader(url, '1.1.1.1', 1)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b'', b''))
        for seconds in ['0', '-1', '31', 'nan', 'abc']:
            with self.subTest(seconds=seconds):
                result = run_reader('https://example.org/', '1.1.1.1', seconds)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b'', b''))
        for pin in ['10.0.0.1', '192.168.1.1', '0.0.0.0', '2606:4700:4700::1111', 'garbage']:
            with self.subTest(pin=pin):
                result = run_reader('https://example.org/', pin, 1)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, b'', b''))
        short = subprocess.run([reader_path(), 'https://example.org/', '1.1.1.1'], stdin=subprocess.DEVNULL,
                               capture_output=True, timeout=20)
        self.assertEqual((short.returncode, short.stdout, short.stderr), (1, b'', b''))

    @unittest.skipUnless(sys.platform == 'darwin', 'Exact Seatbelt profile requires macOS')
    def test_exact_sandbox_admits_only_the_pinned_reader_and_its_socket(self):
        prefix = ['/usr/bin/sandbox-exec', '-f', str(PROFILE), '-D', 'DOT_SOURCE_HELPER=' + reader_path()]
        # The exact profile admits one executable. A substituted child never runs.
        substituted = subprocess.run([*prefix, '/usr/bin/true'], capture_output=True, timeout=20)
        self.assertNotEqual(substituted.returncode, 0)
        self.assertEqual(substituted.stdout, b'')
        # Under the profile the reader still refuses a peer that is not the pin.
        self.assert_refused_without_request_bytes('1.1.1.1', prefix=prefix)

    def test_production_swift_has_no_unverified_runtime_or_urlsession_fallback(self):
        swift = SWIFT.read_text()
        self.assertIn('guard available else', swift)
        self.assertIn('let runtime = try await verifiedRuntime()', swift)
        self.assertIn('addresses.allSatisfy(ResearchPublicAddress.allowed)', swift)
        self.assertIn('"/usr/bin/sandbox-exec"', swift)
        self.assertIn('kill(process.processIdentifier, SIGKILL)', swift)
        self.assertIn('ResearchPinnedSocket.connect(address: address', swift)
        self.assertIn('standardInput: socket', swift)
        self.assertIn('process.standardInput = standardInput ?? FileHandle.nullDevice', swift)
        self.assertIn('Darwin.poll(&event, 1, 0)', swift)
        self.assertIn('FD_CLOEXEC', swift)
        self.assertIn('defer { if !transferred { Darwin.close(descriptor) } }', swift)
        self.assertIn('defer { try? socket.close() }', swift)
        self.assertIn('"DOT_SOURCE_HELPER=" + helper', swift)
        # No interpreter, script or endpoint override can reappear in the reader argv.
        for absent in ['"-I", "-S", "-B"', 'DOT_SOURCE_PYTHON', 'DOT_SOURCE_ENDPOINT', 'dot_source_fetch']:
            self.assertNotIn(absent, swift)
        reader = (ROOT / 'src/ResearchNotebook.swift').read_text()
        self.assertNotIn('URLSession(', reader)
        self.assertNotIn('"/usr/bin/curl"', swift)
        profile = PROFILE.read_text()
        for expected in ['(deny network*)', '(deny file-read*)', '(deny file-write*)', '(deny process-exec)']:
            self.assertIn(expected, profile)
        for forbidden in ['(allow network', 'DOT_SOURCE_PYTHON', 'DOT_SOURCE_ENDPOINT', 'DOT_MODELS', 'DOT_RUNTIME',
                          'DOT_STATE', '(subpath "/Users")', '(subpath "/tmp")']:
            self.assertNotIn(forbidden, profile)

    def test_swift_runtime_keeps_posix_paths_for_exact_sandbox_literals(self):
        # Portable source guard only: real Foundation/Seatbelt behavior is covered by XCTest.
        swift = SWIFT.read_text()
        runtime = swift.split('struct ResearchFetchRuntime: Sendable {', 1)[1].split('enum ResearchBoundedProcess {', 1)[0]
        self.assertIn('let resolved = realpath(url.path, nil)', runtime)
        self.assertIn('defer { free(resolved) }', runtime)
        self.assertIn('let path = String(cString: resolved)', runtime)
        self.assertIn('lstat(path, &info) == 0', runtime)
        self.assertIn('info.st_mode & S_IFMT == S_IFREG', runtime)
        self.assertNotIn('resolvingSymlinksInPath', runtime)
        self.assertNotIn('standardizedFileURL', runtime)
        self.assertIn('FileManager.default.isExecutableFile(atPath: helper)', runtime)
        self.assertIn('"DOT_SOURCE_HELPER=" + helper', runtime)
        # The retired interpreter argv is gone from the assembled reader arguments.
        for absent in ['"-I", "-S", "-B"', 'DOT_SOURCE_PYTHON', 'DOT_SOURCE_ENDPOINT']:
            self.assertNotIn(absent, runtime)

    def test_swift_source_admits_only_ipv4_and_counts_discarded_aaaa(self):
        # Source guard only; parseDNS and redirect behavior require native XCTest.
        source = SWIFT.read_text()
        policy = source.split('enum ResearchPublicAddress', 1)[1].split('enum ResearchSystemHTTP', 1)[0]
        self.assertNotIn('inet_pton(AF_INET6', policy)
        self.assertIn('return false // No IPv6 pins', policy)
        dns = source.split('static func parseDNS', 1)[1].split('static func exchange', 1)[0]
        self.assertIn('case "ipv6_address":', dns)
        self.assertIn('inet_pton(AF_INET6, $0, &address)', dns)
        self.assertIn('answerCount <= 64', dns)
        self.assertIn('guard !addresses.isEmpty', dns)
        self.assertNotIn('addresses.append(value)',
                         dns.split('case "ipv6_address":', 1)[1].split('case "name"', 1)[0])


if __name__ == '__main__':
    unittest.main()
