# Authenticated bundled Splash transport

Status: implemented source and model-free cloud tests; native acceptance is still required. This does not establish a complete voice dependency closure or an offline working app.

## Threat and ownership

A loopback URL, a `Server: Splash` header and self-reported PID/model are not server authentication. The original bind/probe/close sequence allowed another local process to take the selected port before Splash bound it. A bearer token sent to that listener would disclose the token before proving its identity.

The managed runtime now retains one bound, listening IPv4 socket on literal `127.0.0.1` with `SO_REUSEADDR` and `SO_REUSEPORT` disabled. The supervisor keeps its descriptor open throughout the runtime lifetime. Only the patched Splash child accepts on that same inherited socket; no close/rebind, address substitution or discovered daemon is permitted.

A bounded TLS relay in the supervisor is the app-facing endpoint. It generates an ephemeral certificate/key for each launch through `/usr/bin/openssl`, loads the identity into memory, and removes its on-disk key/certificate/config immediately. The existing private parent pipe carries the leaf certificate SHA-256 to Swift. Each new URLSession has an immutable exact certificate pin; every TLS connection/reconnect must satisfy it before HTTP authorization, transcript or screen bytes can be delivered. No keychain, system trust, browser certificate exception or persistent credential is created.

The recognized system utility is checked at launch and fails clearly if missing or incompatible. Presence on one Mac is not evidence for every supported OS. The macOS runtime sandbox must also permit this bounded local operation; the production-profile acceptance test remains required.

The generator explicitly requests `ec_param_enc:named_curve` for P-256. Native diagnosis on macOS 27.0.1 with LibreSSL 3.3.6 found that the previous command emitted explicit EC parameters: Security.framework could parse the certificate but could not extract its key, and URLSession failed before the pin challenge. Adding only the named-curve option produced the prime256v1 OID and a readable 256-bit key. A regression checks both the command and actual public-key SPKI encoding. The positive/negative native TLS fixtures must still pass; key parsing alone is not a successful handshake. [LibreSSL option implementation](https://github.com/libressl/openbsd/blob/libressl-v3.3.6/src/lib/libcrypto/ec/ec_pmeth.c#L405-L413).

The private backend still uses Splash's API-key client authentication. TLS authenticates the app-facing server; PID/model checks are additional consistency checks, not the cryptographic trust anchor. A hostile local process can deny service, but cannot obtain application bytes by presenting a different certificate. Same-user debugger/root compromise is outside this process-level boundary.

## Exact upstream patch

Pinned upstream: Splash 1.3.1, commit `f91c91e21dda483f8c59a248a444d0989a560d31`.

`python3 -B scripts/patch_splash_listener.py --source SOURCE_DIRECTORY --output NEW_OVERLAY_DIRECTORY` creates a three-file overlay only after verifying all original SHA-256 values and unique source anchors. It does not execute upstream code. An unexpected source revision fails closed.

- `install/launcher.py`: validate managed `--listen-fd` instead of probing its already-owned port; retain the descriptor across launcher exec.
- `server/serve_options.py`: declare/forward `--listen-fd` and strictly validate family, type, literal address, port, listening state and disabled socket reuse.
- `server/server.py`: close HTTPServer's unused placeholder socket, adopt the managed descriptor without rebinding, set HTTP server address fields, and mark the descriptor non-inheritable before launching the native engine.

The plaintext Splash admission/MSG_PEEK/disconnect code remains unchanged behind the relay. Wrapping its listening socket directly in TLS would not be compatible with those paths.

Darwin uses its read-only `TCP_CONNECTION_INFO` state byte for listener validation because `SO_ACCEPTCONN` returns ENOPROTOOPT there. The native diagnostic verified unbound/bound-only/listening/connected states as 0/0/1/4. Linux retains its SO_ACCEPTCONN check. Query errors fail closed. Native competition tests also verified that wildcard/dual-stack/mapped-address binds cannot divert literal loopback traffic even when the OS permits coexistence; the original parent's descriptor remains owned after a duplicate child descriptor closes.

The original and resulting hashes are in `Resources/Runtime/splash-managed-listener-patch.json`. Apply the overlay during assembly before generating the runtime file manifest and signing. Preserve upstream Apache-2.0 LICENSE, THIRD_PARTY_NOTICES and the inserted modification notices. Both Swift and Python runtime audits require the exact patched hashes and `transport_patch: dot-splash-owned-listener-v1`.

## Bounds and shutdown

- At most eight pending TLS/header admissions, independent of four authenticated forwarding slots. Pending admissions have one two-second absolute deadline from accept through handshake and the complete first HTTP/1 header block, capped at 16 KiB. Trickle reads do not restart that deadline. Overflow is closed immediately; invalid, missing, duplicate, folded, or incorrect bearer authorization closes without opening upstream or acquiring a forwarding slot.
- The supervisor passes the existing per-launch API key directly into the relay in memory. Standard-library HTTP header parsing plus strict field syntax and constant-time exact bearer comparison gate initial admission. This adds no credential file, log, trust exception, token publication, or second credential. The existing private control-pipe handoff and Splash API-key check remain unchanged.
- After admission, the buffered header/body prefix and all later bytes are forwarded unchanged. Splash remains the HTTP server and authenticates subsequent keep-alive requests. The gate does not buffer whole requests/responses or reinterpret body framing; content-length/chunked uploads, 100-continue, SSE, backend EOF, and client cancellation retain the streaming path. Forwarding uses 32 KiB copy buffers, two-second socket I/O timeouts, and a 180-second forwarding-loop deadline.
- These bounds fix the specific four-idle-session exhaustion: four held unauthenticated TLS sessions open zero upstreams and leave room for an authenticated fifth connection. They do not establish general denial-of-service resistance: eight pending clients or a sustained local flood can still saturate pending capacity/backlog. Authenticated clients can consume the four forwarding slots.
- TLS listener stops and all forwarding connections/workers are closed/joined before the retained backend descriptor may close. Never call `shutdown()` on the inherited backend listener, which would affect the child descriptor too.
- Darwin may return EPERM when a process group contains only the intentionally unreaped zombie leader. The cleanup still attempts its final group SIGKILL before reaping. Only for a confirmed-dead leader may it then reap and perform a signal-zero existence check, accepting cleanup only on ESRCH. No nonzero signal follows reaping; a remaining/reused group or real permission failure stays an error. A TERM-resistant descendant regression protects the final KILL requirement.
- Child exit stops the TLS front end. Host EOF/quit tears down only its owned session/process group. The supervisor removes only the fresh private directory it adopted, after process teardown; directory replacement is rejected by device/inode checks.
- Status responses: one million bytes. SSE: 256 KiB line, four million total bytes, 64 KiB combined content/reasoning. Budgets are enforced incrementally before accumulation.
- Every exception path explicitly cancels URLSession streams. Final SSE `[DONE]` remains required.

## Evidence and required native acceptance

Cloud Python tests include executable admission regressions (`python3 -B Tests/Python/test_tls_admission.py -v`) covering four held idle TLS clients plus a valid fifth, no pending/rejected upstreams, both capacity overflows, malformed/oversized headers, shared handshake/header and trickle deadlines, body/SSE/100-continue/chunked forwarding, cancellation, and Stop races/ownership. They also cover exact-source rejection, descriptor adoption checks, IPv4/wildcard competing binds, TLS round trips/reconnects, wrong-pin application-byte suppression, bounded shutdown and supervisor EOF cleanup. They use synthetic data and do not load a model or execute Splash.

Native XCTest fixtures exercise the actual URLSession authentication delegate against the production relay, including a wrong certificate and forced reconnects. The forwarding test delegate must observe an actual server-trust challenge and its accepted/rejected disposition, so a generic pre-certificate TLS failure cannot pass the wrong-pin gate. `scripts/verify_macos.sh` explicitly selects its current Python3.11+ interpreter with supported OpenSSL and passes its absolute path through the test scheme's DOT_TEST_PYTHON setting; unsupported/missing interpreters fail, never skip or silently fall back. This is test infrastructure only. Production always uses its audited bundled Python3.13 runtime. Apple's legacy system Python3.9/LibreSSL is outside that supported runtime contract; no TLS downgrade or trust exception is added to accommodate it. These tests have been added but must pass on macOS before publication claims. Additional target-device acceptance must cover:

1. Exact patched launcher exec and server descriptor adoption under the production sandbox, using the verified bundled Python/runtime.
2. Competing IPv4/wildcard/dual-stack listener attempts cannot take the held backend address; server exit/reconnect cannot send bytes to another owner.
3. Quit/cancel during certificate generation, startup, streaming and relaunch leaves no child process, private key or temporary state behind.
4. Runtime/model integrity, full offline local voice and screen-context flows pass after relocation with empty external caches and networking denied.

The model-free CI build is intentionally not a complete installer. Packaging still requires the full dependency lock, licenses, runtime/model manifests and genuine device acceptance evidence.
