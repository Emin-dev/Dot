"""One pinned public-source GET; stdlib only, no discovery/redirects/retries/state.

The parent validates DNS and owns the process deadline. This helper independently
validates the literal, connects without hostname resolution, verifies the original
TLS hostname, and streams a bounded body. It never reads proxy/config/cookie/auth
state. OpenSSL verifies using a file trust store without network issuer fetching.
"""
import http.client
import ipaddress
import json
import socket
import ssl
import sys
import time
import urllib.parse
import zlib

MAX_BYTES = 4_194_304
MAX_HEADERS = 65_536
DENIED_V4 = tuple(map(ipaddress.ip_network, (
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
    '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.31.196.0/24', '192.52.193.0/24',
    '192.88.99.0/24', '192.168.0.0/16', '192.175.48.0/24', '198.18.0.0/15',
    '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/3')))
DENIED_V6 = tuple(map(ipaddress.ip_network, ('2001::/23', '2001:db8::/32', '2002::/16', '3ffe::/16', '3fff::/20', '2620:4f:8000::/48')))


class LimitExceeded(ValueError):
    pass


def public_address(text):
    if not isinstance(text, str) or '%' in text or len(text) > 45:
        return False
    try:
        address = ipaddress.ip_address(text)
    except ValueError:
        return False
    if address.version == 4:
        return not any(address in block for block in DENIED_V4)
    return (address in ipaddress.ip_network('2000::/3')
            and not any(address in block for block in DENIED_V6)
            and address.packed[8:12] not in (b'\x00\x00\x5e\xfe', b'\x02\x00\x5e\xfe'))


def parse_url(url):
    if not isinstance(url, str) or len(url.encode('utf-8')) > 8192:
        raise ValueError('invalid_url')
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname
    if (parsed.scheme not in ('http', 'https') or not host or parsed.username is not None or parsed.password is not None
            or parsed.fragment or not 1 <= (parsed.port if parsed.port is not None else (443 if parsed.scheme == 'https' else 80)) <= 65535):
        raise ValueError('invalid_url')
    labels = host.split('.')
    if (len(labels) < 2 or len(host) > 253 or any(not label or len(label) > 63 or label[0] == '-' or label[-1] == '-'
            or any(not ('a' <= c <= 'z' or '0' <= c <= '9' or c == '-') for c in label) for label in labels)
            or any(host == suffix or host.endswith('.' + suffix) for suffix in ('localhost', 'local', 'internal', 'home.arpa'))):
        raise ValueError('invalid_host')
    try:
        socket.inet_aton(host)
    except OSError:
        pass
    else:
        raise ValueError('literal_url')
    return parsed


class HeaderBoundedReader:
    """Bound stdlib header/chunk-control line parsing, without implementing HTTP."""
    def __init__(self, source):
        self.source, self.used = source, 0

    def readline(self, limit=-1):
        maximum = min(8193, limit) if limit >= 0 else 8193
        line = self.source.readline(maximum)
        self.used += len(line)
        if len(line) > 8192 or self.used > MAX_HEADERS:
            raise LimitExceeded('headers')
        return line

    def read(self, count=-1):
        if count < 0 or count > MAX_BYTES + 1:
            raise LimitExceeded('unbounded_read')
        return self.source.read(count)

    def readinto(self, buffer):
        return self.source.readinto(buffer)

    def flush(self):
        self.source.flush()

    def close(self):
        self.source.close()


class BoundedResponse(http.client.HTTPResponse):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fp = HeaderBoundedReader(self.fp)

    def begin(self):
        # The stdlib skips 100 but treats 103 as final. Consume other informational
        # headers on the same bounded reader; never follow hints or upgrade.
        while True:
            super().begin()
            if self.status == 101:
                raise ValueError('unsupported_upgrade')
            if self.status >= 200:
                return
            self.headers = self.msg = None


def connect_numeric(address, port, timeout):
    if not public_address(address):
        raise ValueError('private_address')
    family = socket.AF_INET6 if ':' in address else socket.AF_INET
    connection = socket.socket(family, socket.SOCK_STREAM)
    try:
        connection.settimeout(timeout)
        connection.connect((address, port))  # Literal only; no getaddrinfo or hostname retry.
        if ipaddress.ip_address(connection.getpeername()[0]) != ipaddress.ip_address(address):
            raise ValueError('wrong_peer')
        return connection
    except BaseException:
        connection.close()
        raise


def tls_context():
    # Apple's system LibreSSL may invoke SecTrust/AIA outside a pinned connection.
    # The audited bundled Python must use OpenSSL, never that system TLS backend.
    if not ssl.OPENSSL_VERSION.startswith('OpenSSL ') or ssl.OPENSSL_VERSION_INFO < (1, 1, 1):
        raise RuntimeError('unsupported_tls')
    context = ssl.create_default_context(cafile='/etc/ssl/cert.pem')
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def fetch(url, address, timeout, body, metadata, *, connector=connect_numeric, context_factory=tls_context):
    parsed = parse_url(url)
    if not public_address(address) or not 0 < timeout <= 30:
        raise ValueError('invalid_pin')
    deadline = time.monotonic() + timeout
    port = parsed.port if parsed.port is not None else (443 if parsed.scheme == 'https' else 80)
    raw = secure = connection = None
    try:
        raw = connector(address, port, min(10, timeout))
        if parsed.scheme == 'https':
            context = context_factory()
            if not context.check_hostname or context.verify_mode != ssl.CERT_REQUIRED:
                raise ValueError('invalid_tls_policy')
            secure = context.wrap_socket(raw, server_hostname=parsed.hostname)
        connection = http.client.HTTPConnection(parsed.hostname, port, timeout=min(10, timeout))
        connection.auto_open = False
        connection.response_class = BoundedResponse
        connection.sock = secure if secure is not None else raw
        target = urllib.parse.urlunsplit(('', '', parsed.path or '/', parsed.query, ''))
        connection.request('GET', target, headers={'Accept': 'text/html, text/plain, application/pdf', 'Accept-Encoding': 'gzip, deflate', 'Connection': 'close'})
        response = connection.getresponse()
        headers = {}
        for name, value in response.getheaders():
            key = name.lower()
            if key in ('content-type', 'content-length', 'content-encoding', 'transfer-encoding', 'last-modified', 'location'):
                if key in headers:
                    raise ValueError('ambiguous_headers')
                if any(ord(char) < 32 and char != '\t' or ord(char) == 127 for char in value):
                    raise ValueError('invalid_header')
                headers[key] = value
        if 'transfer-encoding' in headers and headers['transfer-encoding'].lower() != 'chunked':
            raise ValueError('unsupported_transfer_encoding')
        if 'content-length' in headers and 'transfer-encoding' in headers:
            raise ValueError('ambiguous_framing')
        declared = headers.get('content-length')
        if declared is not None:
            if not declared.isascii() or not declared.isdigit():
                raise ValueError('invalid_length')
            if int(declared) > MAX_BYTES:
                raise LimitExceeded('declared_body')
        metadata.write(json.dumps({'status': response.status, 'headers': headers}, separators=(',', ':')).encode('utf-8'))
        metadata.flush()
        if not 200 <= response.status < 300:
            return  # Parent handles redirects and errors; do not consume unneeded bodies.
        encoding = headers.get('content-encoding', 'identity').lower().strip()
        if encoding not in ('identity', 'gzip', 'deflate'):
            raise ValueError('unsupported_encoding')
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS if encoding == 'gzip' else zlib.MAX_WBITS) if encoding != 'identity' else None
        encoded = decoded = 0
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError('deadline')
            chunk = response.read(16_384)
            if not chunk:
                break
            encoded += len(chunk)
            if encoded > MAX_BYTES:
                raise LimitExceeded('encoded_body')
            output = decoder.decompress(chunk, MAX_BYTES - decoded + 1) if decoder else chunk
            decoded += len(output)
            if decoded > MAX_BYTES:
                raise LimitExceeded('decoded_body')
            body.write(output)
        if decoder and (not decoder.eof or decoder.unused_data or decoder.unconsumed_tail):
            raise ValueError('incomplete_encoding')
        if declared is not None and encoded != int(declared):
            raise ValueError('incomplete_body')
        body.flush()
    finally:
        if connection is not None:
            connection.close()
        for stream in (secure, raw):
            if stream is not None:
                stream.close()


def main():
    try:
        if len(sys.argv) != 4:
            return 1
        fetch(sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.stdout.buffer, sys.stderr.buffer)
        return 0
    except LimitExceeded:
        return 63
    except Exception:
        # No URL, body, certificates, environment, traceback or diagnostic logging.
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
