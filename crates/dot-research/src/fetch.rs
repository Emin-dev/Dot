//! dot-fetch: one pinned public-source GET, with no discovery, redirects, retries
//! or persistent state.
//!
//! The host validates DNS, makes exactly one numeric TCP connection and passes that
//! connected socket as this process's stdin (fd 0). This reader never resolves a
//! name, never creates a socket and never reads proxy/config/cookie/auth state:
//!
//! * it re-validates the inherited descriptor (stream socket, exact pinned IPv4 peer,
//!   exact URL port) before a single request byte leaves the process,
//! * it completes a rustls handshake with SNI for the original hostname and the
//!   hostname's certificate chain verified against the shipped system root bundle
//!   (`/etc/ssl/cert.pem`). SecTrust is deliberately not used: Apple trust evaluation
//!   may fetch missing issuers (AIA) over the network, which this path forbids,
//! * it sends exactly one HTTP/1.1 GET with no cookies, authorization or proxy
//!   headers and never follows a redirect,
//! * it bounds the header block, the transferred body and the decoded body, and it
//!   requires complete framing (declared length, terminating chunk, gzip trailer),
//! * body bytes go to stdout and one bounded JSON metadata object goes to stderr.
//!
//! Exit status: 0 success (metadata and, for 2xx, the complete decoded body),
//! 63 a size limit was exceeded, 1 every other failure. Nothing is written for a
//! failure beyond the metadata that was already emitted for an accepted response:
//! no URL, body, peer, path, certificate or diagnostic is ever logged.

use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd};
use std::time::{Duration, Instant};

/// Same body bound as `ResearchExtraction.maxBytes` in the host.
const MAX_BYTES: usize = 4_194_304;
/// Bound on the complete response header block (all informational responses included).
const MAX_HEADERS: usize = 65_536;
/// Bound on one unterminated header or chunk-control line.
const MAX_HEADER_LINE: usize = 8_192;
const MAX_TIMEOUT: f64 = 30.0;
const IDLE_TIMEOUT: f64 = 10.0;
/// The system trust bundle OpenSSL/Python used for this path. Read-only, no keychain,
/// no trust daemon and no network issuer fetching.
const TRUST_BUNDLE: &str = "/etc/ssl/cert.pem";
const MAX_TRUST_BUNDLE: u64 = 4_194_304;
const INTERESTING_HEADERS: [&str; 6] = [
    "content-type",
    "content-length",
    "content-encoding",
    "transfer-encoding",
    "last-modified",
    "location",
];

/// RFC 1918 / special-purpose IPv4 space that is never an admissible peer. IPv6 is
/// never admitted: global NAT64 prefixes can embed private IPv4 in a form that cannot
/// be classified from the address bytes alone.
const DENIED_V4: [(u32, u32); 17] = [
    (0x0000_0000, 8),
    (0x0a00_0000, 8),
    (0x6440_0000, 10),
    (0x7f00_0000, 8),
    (0xa9fe_0000, 16),
    (0xac10_0000, 12),
    (0xc000_0000, 24),
    (0xc000_0200, 24),
    (0xc01f_c400, 24),
    (0xc034_c100, 24),
    (0xc058_6300, 24),
    (0xc0a8_0000, 16),
    (0xc0af_3000, 24),
    (0xc612_0000, 15),
    (0xc633_6400, 24),
    (0xcb00_7100, 24),
    (0xe000_0000, 3),
];

#[derive(Debug, PartialEq, Eq)]
enum Failure {
    /// Exit 63: a declared, transferred or decoded size bound was exceeded.
    Limit,
    /// Exit 1: malformed input, refused peer, refused policy or transport failure.
    Protocol,
}

type Outcome = Result<(), Failure>;

fn main() {
    // Fail closed and silently: a panic must not print a URL, body, peer or path.
    std::panic::set_hook(Box::new(|_| {}));
    let status = match run() {
        Ok(()) => 0,
        Err(Failure::Limit) => 63,
        Err(Failure::Protocol) => 1,
    };
    std::process::exit(status);
}

fn run() -> Outcome {
    let arguments: Vec<String> = std::env::args_os()
        .map(|argument| argument.into_string().map_err(|_| Failure::Protocol))
        .collect::<Result<_, _>>()?;
    if arguments.len() != 4 {
        return Err(Failure::Protocol);
    }
    let target = parse_target(&arguments[1])?;
    let pin = public_ipv4(&arguments[2]).ok_or(Failure::Protocol)?;
    let timeout: f64 = arguments[3].parse().map_err(|_| Failure::Protocol)?;
    if !timeout.is_finite() || timeout <= 0.0 || timeout > MAX_TIMEOUT {
        return Err(Failure::Protocol);
    }
    let deadline = Instant::now() + Duration::from_secs_f64(timeout);

    // Adopt exactly the inherited descriptor. No socket is ever created here, so the
    // connected peer cannot be changed and no resolver can be consulted.
    let stream = unsafe { TcpStream::from_raw_fd(0) };
    verify_peer(&stream, pin, target.port)?;
    stream.set_nonblocking(false).map_err(|_| Failure::Protocol)?;
    let idle = Some(Duration::from_secs_f64(timeout.min(IDLE_TIMEOUT)));
    stream.set_read_timeout(idle).map_err(|_| Failure::Protocol)?;
    stream.set_write_timeout(idle).map_err(|_| Failure::Protocol)?;

    let config = tls_config()?;
    let server_name = rustls::pki_types::ServerName::try_from(target.host.clone())
        .map_err(|_| Failure::Protocol)?;
    let connection = rustls::ClientConnection::new(config, server_name)
        .map_err(|_| Failure::Protocol)?;
    let mut transport = rustls::StreamOwned::new(connection, stream);
    // Complete the handshake (certificate chain and hostname) before any HTTP byte.
    transport
        .conn
        .complete_io(&mut transport.sock)
        .map_err(|_| Failure::Protocol)?;

    let stdout = io::stdout();
    let stderr = io::stderr();
    let mut body = io::BufWriter::with_capacity(32_768, stdout.lock());
    let mut metadata = stderr.lock();
    exchange(
        &mut transport,
        &target,
        &mut body,
        &mut metadata,
        deadline,
    )?;
    body.flush().map_err(|_| Failure::Protocol)?;
    Ok(())
}

/// The inherited descriptor must be a connected stream socket whose peer is exactly
/// the pinned address and the URL port. Nothing else is admissible.
fn verify_peer(stream: &TcpStream, pin: Ipv4Addr, port: u16) -> Outcome {
    let descriptor = stream.as_raw_fd();
    let mut socket_type: libc::c_int = 0;
    let mut length = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    let queried = unsafe {
        libc::getsockopt(
            descriptor,
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            &mut socket_type as *mut libc::c_int as *mut libc::c_void,
            &mut length,
        )
    };
    if queried != 0 || socket_type != libc::SOCK_STREAM {
        return Err(Failure::Protocol);
    }
    match stream.peer_addr() {
        Ok(SocketAddr::V4(peer)) if *peer.ip() == pin && peer.port() == port => Ok(()),
        _ => Err(Failure::Protocol),
    }
}

struct Target {
    host: String,
    port: u16,
    request_target: String,
}

impl Target {
    fn host_header(&self) -> String {
        if self.port == 443 {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }
}

/// Strict HTTPS origin policy, matching the host's `ResearchWebReader.allowed`:
/// https only, no credentials, no fragment, a public registrable-looking DNS name
/// (never a numeric literal in any spelling) and a real port.
fn parse_target(url: &str) -> Result<Target, Failure> {
    if url.is_empty() || url.len() > 8_192 {
        return Err(Failure::Protocol);
    }
    let parsed = url::Url::parse(url).map_err(|_| Failure::Protocol)?;
    if parsed.scheme() != "https"
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
    {
        return Err(Failure::Protocol);
    }
    // A numeric literal host never becomes a resolver input; `url` normalises decimal,
    // octal, hexadecimal and short IPv4 spellings into `Host::Ipv4`, so this rejects
    // all of them.
    let host = match parsed.host() {
        Some(url::Host::Domain(name)) => name.to_ascii_lowercase(),
        _ => return Err(Failure::Protocol),
    };
    let port = parsed.port().unwrap_or(443);
    if !(1..=65_535).contains(&port) {
        return Err(Failure::Protocol);
    }
    if host.len() > 253 || host.is_empty() {
        return Err(Failure::Protocol);
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 {
        return Err(Failure::Protocol);
    }
    for label in &labels {
        if label.is_empty() || label.len() > 63 || label.starts_with('-') || label.ends_with('-') {
            return Err(Failure::Protocol);
        }
        if !label
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        {
            return Err(Failure::Protocol);
        }
    }
    if ["localhost", "local", "internal", "home.arpa"]
        .iter()
        .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")))
    {
        return Err(Failure::Protocol);
    }
    if host.bytes().all(|byte| byte.is_ascii_digit() || byte == b'.') {
        return Err(Failure::Protocol);
    }
    let path = if parsed.path().is_empty() {
        "/"
    } else {
        parsed.path()
    };
    let request_target = match parsed.query() {
        Some(query) => format!("{path}?{query}"),
        None => path.to_string(),
    };
    if request_target.len() > 8_192 {
        return Err(Failure::Protocol);
    }
    Ok(Target {
        host,
        port,
        request_target,
    })
}

/// Strict dotted-quad parser with `inet_pton` semantics: four decimal octets, no
/// leading zeros, no shorthand, no hexadecimal, no scope and no NUL.
fn public_ipv4(text: &str) -> Option<Ipv4Addr> {
    if text.is_empty() || text.len() > 45 || text.contains('%') || text.contains('\0') {
        return None;
    }
    let octets: Vec<&str> = text.split('.').collect();
    if octets.len() != 4 {
        return None;
    }
    let mut address = [0u8; 4];
    for (index, octet) in octets.iter().enumerate() {
        if octet.is_empty() || octet.len() > 3 || (octet.len() > 1 && octet.starts_with('0')) {
            return None;
        }
        if !octet.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        let value: u16 = octet.parse().ok()?;
        if value > 255 {
            return None;
        }
        address[index] = value as u8;
    }
    let value = u32::from_be_bytes(address);
    if DENIED_V4
        .iter()
        .any(|(base, bits)| value >> (32 - bits) == base >> (32 - bits))
    {
        return None;
    }
    Some(Ipv4Addr::from(address))
}

fn tls_config() -> Result<std::sync::Arc<rustls::ClientConfig>, Failure> {
    let roots = system_roots()?;
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|_| Failure::Protocol)?
        .with_root_certificates(roots)
        .with_no_client_auth();
    // HTTP/1.1 only: no ALPN downgrade to a protocol this reader never implements.
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(std::sync::Arc::new(config))
}

fn system_roots() -> Result<rustls::RootCertStore, Failure> {
    let metadata = std::fs::metadata(TRUST_BUNDLE).map_err(|_| Failure::Protocol)?;
    if !metadata.is_file() || metadata.len() > MAX_TRUST_BUNDLE {
        return Err(Failure::Protocol);
    }
    let bundle = std::fs::read(TRUST_BUNDLE).map_err(|_| Failure::Protocol)?;
    let mut roots = rustls::RootCertStore::empty();
    let mut anchors = 0usize;
    for der in pem_certificates(&bundle) {
        if roots.add(der).is_ok() {
            anchors += 1;
        }
    }
    if anchors == 0 {
        return Err(Failure::Protocol);
    }
    Ok(roots)
}

fn pem_certificates(pem: &[u8]) -> Vec<rustls::pki_types::CertificateDer<'static>> {
    const BEGIN: &[u8] = b"-----BEGIN CERTIFICATE-----";
    const END: &[u8] = b"-----END CERTIFICATE-----";
    let mut certificates = Vec::new();
    let mut remaining = pem;
    while let Some(start) = find(remaining, BEGIN) {
        let body = &remaining[start + BEGIN.len()..];
        let Some(end) = find(body, END) else { break };
        let encoded: Vec<u8> = body[..end]
            .iter()
            .copied()
            .filter(|byte| !byte.is_ascii_whitespace())
            .collect();
        if let Ok(der) = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &encoded)
        {
            certificates.push(rustls::pki_types::CertificateDer::from(der));
        }
        remaining = &body[end + END.len()..];
        if certificates.len() >= 4_096 {
            break;
        }
    }
    certificates
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

/// One request, one response, no redirect following, no retry and no second request.
fn exchange<T: Read + Write>(
    io: &mut T,
    target: &Target,
    body: &mut dyn Write,
    metadata: &mut dyn Write,
    deadline: Instant,
) -> Outcome {
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nAccept: text/html, text/plain, application/pdf\r\nAccept-Encoding: gzip, deflate\r\nConnection: close\r\n\r\n",
        target.request_target,
        target.host_header()
    );
    io.write_all(request.as_bytes())
        .map_err(|_| Failure::Protocol)?;
    io.flush().map_err(|_| Failure::Protocol)?;

    let mut source = Source::new(io, deadline);
    let (status, headers) = read_head(&mut source)?;

    let transfer_encoding = header(&headers, "transfer-encoding")
        .map(|value| value.trim().to_ascii_lowercase());
    if let Some(coding) = &transfer_encoding {
        if coding != "chunked" {
            return Err(Failure::Protocol);
        }
    }
    if transfer_encoding.is_some() && header(&headers, "content-length").is_some() {
        return Err(Failure::Protocol);
    }
    let declared = match header(&headers, "content-length") {
        Some(value) => {
            if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(Failure::Protocol);
            }
            let length: u64 = value.parse().map_err(|_| Failure::Protocol)?;
            if length > MAX_BYTES as u64 {
                return Err(Failure::Limit);
            }
            Some(length as usize)
        }
        None => None,
    };

    // Metadata precedes any body byte: the host learns the exact status and the
    // bounded header subset even when the body is later refused.
    let mut object = serde_json::Map::new();
    for (name, value) in &headers {
        object.insert(name.clone(), serde_json::Value::String(value.clone()));
    }
    let encoded_metadata = serde_json::to_vec(&serde_json::json!({
        "status": status,
        "headers": object,
    }))
    .map_err(|_| Failure::Protocol)?;
    metadata
        .write_all(&encoded_metadata)
        .map_err(|_| Failure::Protocol)?;
    metadata.flush().map_err(|_| Failure::Protocol)?;

    // The host owns redirect policy; a non-2xx response consumes no further bytes.
    if !(200..300).contains(&status) {
        return Ok(());
    }

    let encoding = header(&headers, "content-encoding")
        .map(|value| value.trim().to_ascii_lowercase())
        .unwrap_or_else(|| "identity".to_string());
    if !["identity", "gzip", "deflate"].contains(&encoding.as_str()) {
        return Err(Failure::Protocol);
    }

    let framing = if transfer_encoding.is_some() {
        Framing::Chunked
    } else if let Some(length) = declared {
        Framing::Length(length)
    } else {
        Framing::Eof
    };
    let mut transferred = Vec::new();
    read_body(&mut source, framing, &mut transferred, MAX_BYTES)?;
    if let Some(length) = declared {
        if transferred.len() != length {
            return Err(Failure::Protocol);
        }
    }

    let mut decoded = Vec::new();
    decode_body(&encoding, &transferred, &mut decoded)?;
    body.write_all(&decoded).map_err(|_| Failure::Protocol)?;
    body.flush().map_err(|_| Failure::Protocol)?;
    Ok(())
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a String> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value)
}

/// Read the final response head, consuming any number of bounded informational
/// responses (100/103) and refusing a protocol upgrade.
fn read_head<T: Read>(source: &mut Source<'_, T>) -> Result<(u16, Vec<(String, String)>), Failure> {
    let mut consumed_headers = 0usize;
    loop {
        let parsed = {
            let mut raw = [httparse::EMPTY_HEADER; 128];
            let mut response = httparse::Response::new(&mut raw);
            match response.parse(source.pending()) {
                Ok(httparse::Status::Complete(used)) => {
                    let status = response.code.ok_or(Failure::Protocol)?;
                    let headers = collect_headers(response.headers)?;
                    Some((used, status, headers))
                }
                Ok(httparse::Status::Partial) => None,
                Err(_) => return Err(Failure::Protocol),
            }
        };
        match parsed {
            Some((used, status, headers)) => {
                consumed_headers += used;
                if consumed_headers > MAX_HEADERS {
                    return Err(Failure::Limit);
                }
                source.consume(used);
                if status == 101 {
                    return Err(Failure::Protocol);
                }
                if status < 200 {
                    continue;
                }
                return Ok((status, headers));
            }
            None => {
                if source.pending().len() + consumed_headers > MAX_HEADERS
                    || source.unterminated_line() > MAX_HEADER_LINE
                {
                    return Err(Failure::Limit);
                }
                if !source.fill()? {
                    return Err(Failure::Protocol);
                }
            }
        }
    }
}

/// Keep only the six headers the host can interpret, and refuse ambiguity: a repeated
/// interesting header, a control character or a non-UTF-8-safe byte ends the exchange.
fn collect_headers(raw: &[httparse::Header<'_>]) -> Result<Vec<(String, String)>, Failure> {
    let mut headers: Vec<(String, String)> = Vec::new();
    for header in raw {
        let name = header.name.to_ascii_lowercase();
        if !INTERESTING_HEADERS.contains(&name.as_str()) {
            continue;
        }
        let mut value = String::with_capacity(header.value.len());
        for &byte in header.value {
            if (byte < 32 && byte != b'\t') || byte == 127 {
                return Err(Failure::Protocol);
            }
            // HTTP header values are bytes; the host decodes ISO-8859-1 text the same
            // way the retired stdlib reader did.
            value.push(byte as char);
        }
        if headers.iter().any(|(existing, _)| *existing == name) {
            return Err(Failure::Protocol);
        }
        headers.push((name, value));
    }
    Ok(headers)
}

enum Framing {
    Length(usize),
    Chunked,
    Eof,
}

/// Read the complete transferred body, bounded by `cap`. Framing must terminate
/// legitimately: a declared length, the terminating zero chunk with its trailer, or
/// connection close. A premature end is a protocol failure, never a short body.
fn read_body<T: Read>(
    source: &mut Source<'_, T>,
    framing: Framing,
    out: &mut Vec<u8>,
    cap: usize,
) -> Outcome {
    match framing {
        Framing::Length(length) => {
            read_exact_body(source, length, out, cap)?;
            Ok(())
        }
        Framing::Chunked => loop {
            let line = source.read_line(MAX_HEADER_LINE)?;
            let size = parse_chunk_size(&line)?;
            if size == 0 {
                let mut trailer = 0usize;
                loop {
                    let line = source.read_line(MAX_HEADER_LINE)?;
                    trailer += line.len();
                    if trailer > MAX_HEADERS {
                        return Err(Failure::Limit);
                    }
                    if line.as_slice() == b"\r\n" {
                        return Ok(());
                    }
                }
            }
            read_exact_body(source, size, out, cap)?;
            if source.read_line(3)? != b"\r\n" {
                return Err(Failure::Protocol);
            }
        },
        Framing::Eof => {
            let mut buffer = [0u8; 16_384];
            loop {
                let read = source.read_some(&mut buffer)?;
                if read == 0 {
                    return Ok(());
                }
                extend_bounded(out, &buffer[..read], cap)?;
            }
        }
    }
}

fn read_exact_body<T: Read>(
    source: &mut Source<'_, T>,
    length: usize,
    out: &mut Vec<u8>,
    cap: usize,
) -> Outcome {
    let mut remaining = length;
    let mut buffer = [0u8; 16_384];
    while remaining > 0 {
        let wanted = remaining.min(buffer.len());
        let read = source.read_some(&mut buffer[..wanted])?;
        if read == 0 {
            return Err(Failure::Protocol);
        }
        extend_bounded(out, &buffer[..read], cap)?;
        remaining -= read;
    }
    Ok(())
}

fn extend_bounded(out: &mut Vec<u8>, data: &[u8], cap: usize) -> Outcome {
    if out.len() + data.len() > cap {
        return Err(Failure::Limit);
    }
    out.extend_from_slice(data);
    Ok(())
}

fn parse_chunk_size(line: &[u8]) -> Result<usize, Failure> {
    if line.len() < 3 || !line.ends_with(b"\r\n") {
        return Err(Failure::Protocol);
    }
    let digits = &line[..line.len() - 2];
    let digits = match digits.iter().position(|&byte| byte == b';') {
        Some(index) => &digits[..index],
        None => digits,
    };
    if digits.is_empty() || digits.len() > 8 {
        return Err(Failure::Protocol);
    }
    let mut size: usize = 0;
    for &byte in digits {
        let digit = match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            b'A'..=b'F' => byte - b'A' + 10,
            _ => return Err(Failure::Protocol),
        };
        size = size * 16 + digit as usize;
    }
    Ok(size)
}

fn decode_body(encoding: &str, transferred: &[u8], out: &mut Vec<u8>) -> Outcome {
    match encoding {
        "identity" => {
            if transferred.len() > MAX_BYTES {
                return Err(Failure::Limit);
            }
            out.extend_from_slice(transferred);
            Ok(())
        }
        "gzip" => gzip_body(transferred, out),
        "deflate" => {
            // A zlib stream ends with its Adler-32 trailer: any byte after it is
            // refused, exactly like an incomplete stream.
            if inflate(transferred, true, out)? != transferred.len() {
                return Err(Failure::Protocol);
            }
            Ok(())
        }
        _ => Err(Failure::Protocol),
    }
}

/// gzip framing (RFC 1952) with its CRC32/ISIZE trailer, decoded through raw DEFLATE.
/// A truncated stream, a mismatched trailer or any byte after the trailer is refused.
fn gzip_body(input: &[u8], out: &mut Vec<u8>) -> Outcome {
    let header = gzip_header_len(input)?;
    let consumed = inflate(&input[header..], false, out)?;
    let trailer = &input[header + consumed..];
    if trailer.len() != 8 {
        return Err(Failure::Protocol);
    }
    let declared_crc = u32::from_le_bytes([trailer[0], trailer[1], trailer[2], trailer[3]]);
    let declared_size = u32::from_le_bytes([trailer[4], trailer[5], trailer[6], trailer[7]]);
    let mut hasher = crc32fast::Hasher::new();
    hasher.update(out);
    if hasher.finalize() != declared_crc || out.len() as u32 != declared_size {
        return Err(Failure::Protocol);
    }
    Ok(())
}

fn gzip_header_len(input: &[u8]) -> Result<usize, Failure> {
    if input.len() < 10 || input[0] != 0x1f || input[1] != 0x8b || input[2] != 8 || input[3] & 0xe0 != 0
    {
        return Err(Failure::Protocol);
    }
    let flags = input[3];
    let mut offset = 10usize;
    if flags & 0x04 != 0 {
        if input.len() < offset + 2 {
            return Err(Failure::Protocol);
        }
        let extra = u16::from_le_bytes([input[offset], input[offset + 1]]) as usize;
        offset += 2 + extra;
        if offset > input.len() {
            return Err(Failure::Protocol);
        }
    }
    for flag in [0x08u8, 0x10u8] {
        if flags & flag != 0 {
            let end = input[offset..]
                .iter()
                .position(|&byte| byte == 0)
                .ok_or(Failure::Protocol)?;
            offset += end + 1;
        }
    }
    // A header CRC is skipped: the DEFLATE stream and the CRC32 trailer still cover
    // the complete decoded body.
    if flags & 0x02 != 0 {
        offset += 2;
    }
    if offset >= input.len() {
        return Err(Failure::Protocol);
    }
    Ok(offset)
}

/// Bounded DEFLATE decoding. Returns the number of input bytes the stream consumed;
/// every produced byte counts against the same decoded-body cap.
fn inflate(input: &[u8], zlib_header: bool, out: &mut Vec<u8>) -> Result<usize, Failure> {
    let mut decompressor = flate2::Decompress::new(zlib_header);
    let mut buffer = vec![0u8; 65_536];
    let mut consumed_total = 0usize;
    loop {
        let (consumed, produced, status) = {
            let before_in = decompressor.total_in();
            let before_out = decompressor.total_out();
            let status = decompressor
                .decompress(
                    &input[consumed_total..],
                    &mut buffer,
                    flate2::FlushDecompress::None,
                )
                .map_err(|_| Failure::Protocol)?;
            (
                (decompressor.total_in() - before_in) as usize,
                (decompressor.total_out() - before_out) as usize,
                status,
            )
        };
        out.extend_from_slice(&buffer[..produced]);
        if out.len() > MAX_BYTES {
            return Err(Failure::Limit);
        }
        consumed_total += consumed;
        match status {
            flate2::Status::StreamEnd => return Ok(consumed_total),
            _ if consumed == 0 && produced == 0 => return Err(Failure::Protocol),
            _ => {}
        }
    }
}

/// Transport with a bounded read window. Every fill also rechecks the caller deadline,
/// so a peer that stops sending cannot hold the process past its budget.
struct Source<'a, T: Read> {
    io: &'a mut T,
    deadline: Instant,
    buffer: Vec<u8>,
    position: usize,
}

impl<'a, T: Read> Source<'a, T> {
    fn new(io: &'a mut T, deadline: Instant) -> Self {
        Self {
            io,
            deadline,
            buffer: Vec::with_capacity(16_384),
            position: 0,
        }
    }

    fn pending(&self) -> &[u8] {
        &self.buffer[self.position..]
    }

    fn consume(&mut self, count: usize) {
        self.position += count;
        if self.position == self.buffer.len() {
            self.buffer.clear();
            self.position = 0;
        }
    }

    /// Length of the header line still waiting for its terminator.
    fn unterminated_line(&self) -> usize {
        let pending = self.pending();
        match pending.windows(2).rposition(|window| window == b"\r\n") {
            Some(index) => pending.len() - (index + 2),
            None => pending.len(),
        }
    }

    fn fill(&mut self) -> Result<bool, Failure> {
        if Instant::now() >= self.deadline {
            return Err(Failure::Protocol);
        }
        let mut chunk = [0u8; 16_384];
        loop {
            match self.io.read(&mut chunk) {
                Ok(0) => return Ok(false),
                Ok(read) => {
                    self.buffer.extend_from_slice(&chunk[..read]);
                    return Ok(true);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(Failure::Protocol),
            }
        }
    }

    fn read_some(&mut self, out: &mut [u8]) -> Result<usize, Failure> {
        if self.pending().is_empty() && !self.fill()? {
            return Ok(0);
        }
        let available = self.pending();
        let count = available.len().min(out.len());
        out[..count].copy_from_slice(&available[..count]);
        self.consume(count);
        Ok(count)
    }

    /// One CRLF-terminated control line, including its terminator.
    fn read_line(&mut self, limit: usize) -> Result<Vec<u8>, Failure> {
        loop {
            if let Some(index) = self.pending().iter().position(|&byte| byte == b'\n') {
                if index + 1 > limit {
                    return Err(Failure::Limit);
                }
                let line = self.pending()[..=index].to_vec();
                self.consume(index + 1);
                return Ok(line);
            }
            if self.pending().len() > limit {
                return Err(Failure::Limit);
            }
            if !self.fill()? {
                return Err(Failure::Protocol);
            }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Test-only transport: canned response bytes in, request bytes captured out.
    struct Fixture {
        response: Cursor<Vec<u8>>,
        request: Vec<u8>,
    }

    impl Fixture {
        fn new(response: Vec<u8>) -> Self {
            Self {
                response: Cursor::new(response),
                request: Vec::new(),
            }
        }
    }

    impl Read for Fixture {
        fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
            self.response.read(out)
        }
    }

    impl Write for Fixture {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.request.extend_from_slice(data);
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn target(url: &str) -> Target {
        parse_target(url).expect("fixture target")
    }

    fn deadline() -> Instant {
        Instant::now() + Duration::from_secs(5)
    }

    /// Run one exchange against canned response bytes.
    fn run(url: &str, response: &[u8]) -> (Outcome, Vec<u8>, String, Vec<u8>) {
        let mut fixture = Fixture::new(response.to_vec());
        let mut body = Vec::new();
        let mut metadata = Vec::new();
        let outcome = exchange(
            &mut fixture,
            &target(url),
            &mut body,
            &mut metadata,
            deadline(),
        );
        let metadata = String::from_utf8(metadata).expect("utf-8 metadata");
        (outcome, body, metadata, fixture.request)
    }

    fn response(headers: &[&str], body: &[u8]) -> Vec<u8> {
        let mut head = String::from("HTTP/1.1 200 OK\r\n");
        for header in headers {
            head.push_str(header);
            head.push_str("\r\n");
        }
        head.push_str("\r\n");
        let mut raw = head.into_bytes();
        raw.extend_from_slice(body);
        raw
    }

    fn gzip(data: &[u8]) -> Vec<u8> {
        use flate2::write::GzEncoder;
        let mut encoder = GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(data).expect("gzip fixture");
        encoder.finish().expect("gzip fixture")
    }

    fn zlib(data: &[u8]) -> Vec<u8> {
        use flate2::write::ZlibEncoder;
        let mut encoder = ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(data).expect("zlib fixture");
        encoder.finish().expect("zlib fixture")
    }

    #[test]
    fn special_purpose_ipv4_is_never_admitted() {
        for denied in [
            "0.0.0.0",
            "0.1.2.3",
            "10.0.0.1",
            "100.64.0.1",
            "100.127.255.255",
            "127.0.0.1",
            "127.255.255.255",
            "169.254.1.1",
            "172.16.0.1",
            "172.31.255.255",
            "192.0.0.9",
            "192.0.2.1",
            "192.31.196.1",
            "192.52.193.1",
            "192.88.99.1",
            "192.168.1.1",
            "192.175.48.1",
            "198.18.0.1",
            "198.19.255.255",
            "198.51.100.1",
            "203.0.113.1",
            "224.0.0.1",
            "239.255.255.255",
            "240.0.0.1",
            "255.255.255.255",
        ] {
            assert!(public_ipv4(denied).is_none(), "{denied}");
        }
        for allowed in [
            "1.1.1.1",
            "8.8.8.8",
            "93.184.216.34",
            "172.15.255.255",
            "172.32.0.1",
            "100.63.255.255",
            "100.128.0.1",
        ] {
            assert!(public_ipv4(allowed).is_some(), "{allowed}");
        }
        // No IPv6 pin, no shorthand, no NUL or scope suffix, no ambiguity.
        for refused in [
            "::1",
            "::ffff:127.0.0.1",
            "64:ff9b::7f00:1",
            "127.1",
            "0x7f000001",
            "010.0.0.1",
            "1.1.1.1\u{0}9",
            "1.1.1.1%en0",
            "1.1.1.1 ",
            " 1.1.1.1",
            "1.1.1",
            "1.1.1.1.1",
            "garbage",
        ] {
            assert!(public_ipv4(refused).is_none(), "{refused}");
        }
    }

    #[test]
    fn origin_policy_rejects_downgrade_credentials_and_literal_hosts() {
        for refused in [
            "http://example.org/source",
            "HTTP://example.org/source",
            "file:///etc/passwd",
            "https://user:pass@example.org/",
            "https://example.org/#fragment",
            "https://localhost/",
            "https://foo.local/",
            "https://x.internal/",
            "https://a.home.arpa/",
            "https://127.0.0.1/",
            "https://2130706433/",
            "https://0x7f000001/",
            "https://127.1/",
            "https://[::1]/",
            "https://example.org:0/",
            "https://example.org:65536/",
            "https://a..example/",
            "https://-bad.example/",
            "https://bad-.example/",
            "https://single/",
            "",
        ] {
            assert!(parse_target(refused).is_err(), "{refused}");
        }
        let custom = target("https://example.org:8443/source?a=b");
        assert_eq!(custom.port, 8443);
        assert_eq!(custom.host_header(), "example.org:8443");
        assert_eq!(custom.request_target, "/source?a=b");
        let plain = target("https://EXAMPLE.org/");
        assert_eq!(plain.host_header(), "example.org");
        assert_eq!(plain.request_target, "/");
    }

    #[test]
    fn one_request_carries_no_cookie_proxy_or_auth_header() {
        let (outcome, body, metadata, request) = run(
            "https://example.org/plain",
            &response(&["Content-Type: text/plain", "Content-Length: 4"], b"body"),
        );
        assert!(outcome.is_ok());
        assert_eq!(body, b"body");
        assert_eq!(metadata, r#"{"headers":{"content-length":"4","content-type":"text/plain"},"status":200}"#);
        let request = String::from_utf8(request).expect("utf-8 request");
        assert!(request.starts_with("GET /plain HTTP/1.1\r\n"));
        assert!(request.contains("Host: example.org\r\n"));
        assert!(request.contains("Accept-Encoding: gzip, deflate\r\n"));
        assert!(request.contains("Connection: close\r\n"));
        for forbidden in ["Cookie", "Authorization", "Proxy-", "Referer", "Origin"] {
            assert!(!request.contains(forbidden), "{forbidden}");
        }
        assert_eq!(request.matches("GET ").count(), 1);
    }

    #[test]
    fn informational_responses_are_skipped_and_upgrade_is_refused() {
        // Several informational heads are consumed before the single final head.
        let mut hints =
            b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\n".to_vec();
        hints.extend_from_slice(&response(&["Content-Length: 8"], b"evidence"));
        let (outcome, body, metadata, _) = run("https://example.org/early-hints", &hints);
        assert!(outcome.is_ok());
        assert_eq!(body, b"evidence");
        assert!(metadata.contains(r#""status":200"#));

        let mut upgrade = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\n\r\n".to_vec();
        upgrade.extend_from_slice(&response(&["Content-Length: 0"], b""));
        let (outcome, body, metadata, _) = run("https://example.org/upgrade", &upgrade);
        assert!(outcome.is_err());
        assert!(body.is_empty());
        assert!(metadata.is_empty());
    }

    #[test]
    fn non_success_status_reports_metadata_and_reads_no_body() {
        for (status, location) in [(302, "Location: /next"), (401, "WWW-Authenticate: Basic"), (500, "")] {
            let mut raw = format!(
                "HTTP/1.1 {status} X\r\nContent-Length: 4\r\n{}\r\n",
                if location.is_empty() {
                    String::new()
                } else {
                    format!("{location}\r\n")
                }
            )
            .into_bytes();
            raw.extend_from_slice(b"body");
            let (outcome, body, metadata, _) = run("https://example.org/redirect", &raw);
            assert!(outcome.is_ok(), "{status}");
            assert!(body.is_empty(), "{status}");
            assert!(metadata.contains(&format!(r#""status":{status}"#)), "{metadata}");
            if status == 302 {
                assert!(metadata.contains(r#""location":"/next""#), "{metadata}");
            }
        }
    }

    #[test]
    fn chunked_transfer_is_decoded_and_must_terminate() {
        let chunked = response(
            &["Transfer-Encoding: chunked"],
            b"8\r\nevidence\r\n17;ext=1\r\n and more decoded bytes\r\n0\r\nX-Trailer: 1\r\n\r\n",
        );
        let (outcome, body, metadata, _) = run("https://example.org/chunked", &chunked);
        assert!(outcome.is_ok());
        assert_eq!(body, b"evidence and more decoded bytes");
        assert!(metadata.contains(r#""transfer-encoding":"chunked""#));

        for truncated in [
            response(&["Transfer-Encoding: chunked"], b"8\r\nevid"),
            response(&["Transfer-Encoding: chunked"], b"8\r\nevidence\r\n"),
            response(&["Transfer-Encoding: chunked"], b"zz\r\nevidence\r\n0\r\n\r\n"),
            response(&["Transfer-Encoding: chunked"], b"8\r\nevidence\n0\r\n\r\n"),
            response(
                &["Transfer-Encoding: chunked"],
                format!("8\r\nevidence\r\n{}\r\n", "a".repeat(8_193)).as_bytes(),
            ),
        ] {
            let (outcome, _, _, _) = run("https://example.org/chunked", &truncated);
            assert!(outcome.is_err(), "truncated chunked body accepted");
        }
    }

    #[test]
    fn framing_ambiguity_and_repeated_headers_are_refused() {
        for headers in [
            vec!["Transfer-Encoding: gzip, chunked"],
            vec!["Transfer-Encoding: chunked", "Content-Length: 8"],
            vec!["Content-Length: 8", "Transfer-Encoding: chunked"],
            vec!["Content-Length: 8a"],
            vec!["Content-Length: -1"],
            vec!["Content-Length: "],
            vec!["Location: /a", "Location: /b"],
            vec!["Content-Encoding: br", "Content-Length: 1"],
            vec!["Content-Type: text/pl\x01ain", "Content-Length: 1"],
        ] {
            let (outcome, _, _, _) = run("https://example.org/x", &response(&headers, b"12345678"));
            assert!(outcome.is_err(), "{headers:?}");
        }
    }

    #[test]
    fn declared_transferred_and_decoded_caps_fail_with_limit() {
        let (outcome, _, _, _) = run(
            "https://example.org/large",
            &response(
                &[&format!("Content-Length: {}", MAX_BYTES + 1)],
                b"",
            ),
        );
        assert_eq!(outcome, Err(Failure::Limit));

        let mut oversized = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_vec();
        oversized.extend(std::iter::repeat(b'x').take(MAX_BYTES + 2));
        let (outcome, _, _, _) = run("https://example.org/large", &oversized);
        assert_eq!(outcome, Err(Failure::Limit));

        let bomb = gzip(&vec![b'x'; MAX_BYTES + 1]);
        let (outcome, _, _, _) = run(
            "https://example.org/bomb",
            &response(
                &[
                    "Content-Encoding: gzip",
                    &format!("Content-Length: {}", bomb.len()),
                ],
                &bomb,
            ),
        );
        assert_eq!(outcome, Err(Failure::Limit));
    }

    #[test]
    fn gzip_and_deflate_bodies_are_decoded_with_verified_trailers() {
        let payload = b"decoded evidence".repeat(100);
        let packed = gzip(&payload);
        let (outcome, body, _, _) = run(
            "https://example.org/gzip",
            &response(
                &[
                    "Content-Encoding: gzip",
                    &format!("Content-Length: {}", packed.len()),
                ],
                &packed,
            ),
        );
        assert!(outcome.is_ok());
        assert_eq!(body, payload);

        let packed = zlib(&payload);
        let (outcome, body, _, _) = run(
            "https://example.org/deflate",
            &response(
                &[
                    "Content-Encoding: DEFLATE",
                    &format!("Content-Length: {}", packed.len()),
                ],
                &packed,
            ),
        );
        assert!(outcome.is_ok());
        assert_eq!(body, payload);

        // Truncated stream, corrupted trailer and trailing bytes are all refused.
        let packed = gzip(&payload);
        let mut truncated = packed.clone();
        truncated.truncate(packed.len() - 5);
        let (outcome, body, _, _) = run(
            "https://example.org/truncated-gzip",
            &response(
                &[
                    "Content-Encoding: gzip",
                    &format!("Content-Length: {}", truncated.len()),
                ],
                &truncated,
            ),
        );
        assert!(outcome.is_err());
        assert!(body.is_empty());

        let mut corrupted = packed.clone();
        let last = corrupted.len() - 1;
        corrupted[last] ^= 0xff;
        let (outcome, _, _, _) = run(
            "https://example.org/corrupt-gzip",
            &response(
                &[
                    "Content-Encoding: gzip",
                    &format!("Content-Length: {}", corrupted.len()),
                ],
                &corrupted,
            ),
        );
        assert!(outcome.is_err());

        let mut trailing = packed.clone();
        trailing.push(0x00);
        let (outcome, _, _, _) = run(
            "https://example.org/trailing-gzip",
            &response(
                &[
                    "Content-Encoding: gzip",
                    &format!("Content-Length: {}", trailing.len()),
                ],
                &trailing,
            ),
        );
        assert!(outcome.is_err());

        let mut trailing_zlib = zlib(&payload);
        trailing_zlib.push(0x00);
        let (outcome, _, _, _) = run(
            "https://example.org/trailing-deflate",
            &response(
                &[
                    "Content-Encoding: deflate",
                    &format!("Content-Length: {}", trailing_zlib.len()),
                ],
                &trailing_zlib,
            ),
        );
        assert!(outcome.is_err());
    }

    #[test]
    fn declared_length_must_be_delivered_completely() {
        let (outcome, body, _, _) = run(
            "https://example.org/short",
            &response(&["Content-Length: 16"], b"evidence"),
        );
        assert!(outcome.is_err());
        assert!(body.is_empty());
    }

    #[test]
    fn connection_close_delimited_body_is_accepted_within_the_cap() {
        let (outcome, body, _, _) = run(
            "https://example.org/eof",
            &response(&[], b"evidence"),
        );
        assert!(outcome.is_ok());
        assert_eq!(body, b"evidence");
    }

    #[test]
    fn header_block_budget_is_bounded() {
        let mut huge = b"HTTP/1.1 200 OK\r\n".to_vec();
        for index in 0..200 {
            huge.extend_from_slice(format!("X-Pad-{index}: {}\r\n", "p".repeat(900)).as_bytes());
        }
        huge.extend_from_slice(b"Content-Length: 0\r\n\r\n");
        let (outcome, _, _, _) = run("https://example.org/huge-header", &huge);
        assert!(outcome.is_err());
    }

    #[test]
    fn a_peer_that_stops_sending_cannot_hold_the_exchange_past_the_deadline() {
        // A head that never terminates: the reader must stop on its own deadline.
        let mut fixture = Fixture::new(b"HTTP/1.1 200 OK\r\n".to_vec());
        let mut body = Vec::new();
        let mut metadata = Vec::new();
        let outcome = exchange(
            &mut fixture,
            &target("https://example.org/plain"),
            &mut body,
            &mut metadata,
            Instant::now(),
        );
        assert!(outcome.is_err());
    }
}

