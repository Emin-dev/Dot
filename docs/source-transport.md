# Connection-pinned source reading

Current as of 2026-10-17. The original-source reader is the Rust binary `dot-fetch`, built from
`crates/dot-research/src/fetch.rs` (`[[bin]] name = "dot-fetch"`) and run under the shipped Seatbelt
profile `Resources/Research/source_fetch.sb`. The retired Python helper
`Resources/Research/dot_source_fetch.py` no longer exists and is never executed by this path. See the
[Rust runtime reference](rust-runtime.md).

The host side is `src/ResearchHTTPTransport.swift` and `src/OfflinePayload.swift`: the app resolves the
host itself, makes one numeric TCP connection and hands that already-connected socket to the reader as
standard input. The reader owns no resolver, no proxy, no cookie or credential store and no ability to
open a second connection. There is no Python, URLSession or system-curl fallback, and a missing or
unaudited reader binary fails closed.

## Host admission

- HTTPS-only admission, independently repeated by the reader. HTTP input is rejected rather than
  upgraded; custom HTTPS ports remain supported. The URL is canonicalized (lowercased host, fragment
  removed) and bounded.
- The OS resolver `/usr/bin/dscacheutil` runs in a separate bounded process. Only IPv4 candidates are
  considered; the complete candidate set is rejected if any pin is unsafe, IPv6 candidates (including
  IPv6-only origins) are never admitted, and no unbounded resolver work is left behind.
- One literal connection to one vetted numeric peer: no alternate-address retry, no transparent
  re-resolution within a hop.
- The host owns redirect policy. The reader never follows a redirect; when the response is 301, 302,
  303, 307 or 308 the host re-resolves, re-pins and reconnects for the next hop, at most three hops,
  and `ResearchWebReader.allowed` admits only HTTPS so a downgrade fails. A non-2xx response that is
  not a redirect fails the fetch.
- One overall 30-second budget; cancellation or deadline kills the exact owned child and awaits real
  termination and pipe closure before the fetch settles.

## Reader contract (`dot-fetch`)

- Before a single request byte leaves the process it re-validates the inherited descriptor: it must be
  a stream socket whose peer is exactly the pinned IPv4 address and whose port is the URL port. A
  private pin, a mismatching peer or a non-stream descriptor exits with status 1 and zero request bytes.
- It completes a rustls handshake with SNI for the original hostname and verifies the hostname's
  certificate chain against the shipped system root bundle `/etc/ssl/cert.pem`. SecTrust is
  deliberately not used, because Apple trust evaluation may fetch missing issuers (AIA) over the
  network, which this path forbids. There is no insecure flag or verification bypass; sites that need
  user-keychain-only roots or fetchable intermediates fail closed.
- Exactly one HTTP/1.1 GET with `Host` and no cookies, authorization or proxy headers. No redirect is
  followed, no retry and no second request is made.
- Bounds: 4 MiB transferred body and 4 MiB decoded body, 64 KiB response header block, 8 KiB
  single header/chunk line, 30-second maximum and 10-second idle timeout. Exceeding a size bound exits
  with status 63; every other failure exits with status 1.
- Complete framing is required: a declared `Content-Length` must be satisfied, a chunked body must be
  terminated, and `identity`, `gzip` and `deflate` are the only accepted codings. gzip framing
  (RFC 1952) is checked including its CRC32/ISIZE trailer and zlib streams are checked to their
  Adler-32 trailer; truncated or trailer-mismatched bodies fail closed. Redirect and error bodies are
  not consumed beyond the header block.
- Body bytes go to stdout; one bounded JSON metadata object (including `content-type`,
  `content-length`, `content-encoding`, `transfer-encoding`, `last-modified` and `location`) goes to
  stderr. On failure nothing is written beyond that metadata: no URL, body, peer, path, certificate or
  diagnostic is logged, and the panics hook is silenced so a crash cannot leak them either.

## Seatbelt profile

`Resources/Research/source_fetch.sb` is the reader's profile: default-allow with file reads, file
writes, executable mapping, all network access and process execution denied, then narrowly re-allowed
for `/System/Library`, `/usr/lib`, the public TLS bundle, `/dev/null`-class devices and the reader
binary itself (parameter `DOT_SOURCE_HELPER`). There is no network exception at all — the reader
cannot connect, reconnect or choose another peer, and the binary contains no `socket()`/`connect()`
call site. The only executable it may run is itself; there is no interpreter or script. The profile
does not claim complete Mach/process containment.

## Verification status

The in-tree end-to-end driver `crates/dot-research/tests/dot_fetch_e2e.py` performs a real public
HTTPS exchange through the shipped binary, repeats the identical exchange under
`/usr/bin/sandbox-exec` with the shipped profile, and checks the private-pin, wrong-peer and
non-stream-descriptor refusals. It is a development fixture: it is not packaged, and this document
records no run result for it. `Tests/DotCoreTests/ResearchHTTPTransportTests.swift` and
`Tests/Python/test_research_transport_contract.py` exercise the host fixtures and the retired-helper
guards. Source policy, hosted fixtures, an audited complete runtime and an actual sourced-answer
acceptance remain separate gates; none of those gates is closed here. In particular there is no
recorded native Seatbelt enforcement receipt for the reader in this documentation set, and CFNetwork
proxy/PAC behaviour, real NAT64 networks, live search, upstream snippet-retention rights and installer
acceptance are not established.

## Historical evidence and new synthesis

New web receipts include an optional `httpsOnlyV1` transport-policy record after the HTTPS-only reader
succeeds. This records the app's retrieval checks; it is neither a cryptographic attestation nor
independent verification of source claims. A SHA-256 receipt still identifies only the bytes received.

Legacy source records, including HTTP results, remain structurally readable. Opening, copying and
exporting an old notebook does not rewrite its original brief or receipts; presentation adds an
unverified-transport warning. Saved research answers and quotations remain available with the same
warning. New briefs omit unverified web extracts while retaining labeled inventory receipts, and new
model evidence/citation admission excludes those sources. All older web receipts without the marker
are conservatively unverified, including HTTPS endpoints: the older receipt did not record
intermediate redirects. Local sources are unchanged.

To reuse excluded web material, start a new research pass and read it over HTTPS. There is no
automatic refetch, HTTP upgrade, silent migration or additional confirmation prompt. Resuming an old
pending HTTP read records a source failure without attempting network access. A mixed session can
synthesize from at least two eligible sources and two completed searches; retained legacy sources
still consume the original session budgets.

## Sources checked

- Apple DNS utility implementation, showing both AF_INET6 and AF_INET lookups and the exact output
  keys: https://github.com/apple-oss-distributions/DSTools/blob/main/dscacheutil/dscacheutil.m
- Apple trust network fetching behavior: https://developer.apple.com/documentation/security/sectrustsetnetworkfetchallowed(_:_:)
- IANA special-purpose policy references: https://www.iana.org/assignments/iana-ipv4-special-registry
