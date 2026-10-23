> **SUPERSEDED (2026-10-17).** This document describes the retired Python SearXNG search stack, which
> no longer exists. See [the Rust-only runtime](../rust-runtime.md) for the current runtime. The
> SearXNG revision, Waitress, curl_cffi, wheel and payload numbers below are kept unchanged as the
> record of what was inspected and run at the time; `Resources/Search/**`, `packaging/search/**`,
> `Tests/Portable/**`, `profile-bootstrap-basis.json`, the fixtures and the canary workflow are all
> deleted.

# Search proxy canaries: build-only and native-unrun

Prepared on Linux x86_64, 2026-10-14. The production broker remains unimplemented in this stage. `currentnativeblocked` and `usercancelhold` are preserved. Nothing was published, installed, assembled into the app, admitted, downloaded, or run against a live provider. The separate frozen interpreter publication candidate and `/workspace/shared/dot-cloud-build` were only read.

## Reviewed basis

- Proposal `/workspace/shared/dot-search-egress-review-stage/PROPOSAL.md`: SHA-256 `97713396d164835b95a1ddd44dc869df7a04aa5c6666c7a339295cc7ecd8476b`.
- SearXNG revision `22c64b8d394b680c7ea96be25f36dad14126420a`, original archive SHA-256 `8a037582fea10538e54dbcb4fabb11038c912ba3c887fd403fcdd8e5ddc36df8`.
- curl_cffi `0.16.3`, original archive SHA-256 `d15d0c2a35f2d75bec430c28946c2a833f421c85773bdb0795182cc5c515665b`.
- Exact inspected native/profile inputs are in `profile-bootstrap-basis.json`. Eight exact transport source hashes are in `Tests/Fixtures/search_proxy_pinned_hashes.json`. `canary-inputs.json` also identifies the unchanged old native fixture and wrapper used as design bases.

These are the previously verified source archives already present in the review stage; this task did not redownload them. Portable checks rehash the extracted transport sources and compare all eight with the existing unaccepted payload.

## Isolated test changes

New additive profile/bootstrap entrypoints `scripts/test_search_proxy_sandbox_canary.py` and `scripts/test_search_proxy_bootstrap_canary.py` point only at `Tests/Fixtures/search_proxy_canary.sb` and the uniquely named standalone `Tests/Native/search-proxy-bootstrap-canary.c` / `search_proxy_bootstrap_probe.py`. The existing native gate scripts and their original C/Python probe dependencies are unchanged. They use `localhost:<owned-port>` in profile parameters and actual AF_INET `127.0.0.1` sockets. Negative probes require policy denial, not merely refusal/timeout, for unrelated loopback, helper listener, another loopback address, public/private/LAN/link-local, DNS TCP/UDP/resolver socket, UDP to the permitted TCP port, IPv6/mapped-IPv6 and new binds. Existing private files, inference, symlink, map/read, shell and supervised-child checks remain. See `PROFILE_BOOTSTRAP.md` for native commands and exact scope.

`verify_search_proxy_native_fixture.sh` is an additive companion to the existing `verify_search_native_fixture.sh`. It does not modify, replace or reuse the old monkeypatched fixture's passing report. Its worker uses the actual pinned `searx.network.initialize`, public `searx.network.request`, `Network.request`, and underlying curl_cffi AsyncSession. There is no transport/request monkeypatch, alternate HTTP implementation or live destination. The client runs inside the independent fixture profile and can connect only to the parent-owned endpoint.

The endpoint is a temporary in-process Python test fixture, not a daemon, production broker or Swift implementation. It accepts only the fixed CONNECT authority, authenticates a fresh synthetic capability before any upstream allocation, and relays to its own numeric loopback TLS fixture. Local TLS trust files/private keys are generated offline, remain in temporary test directories, are not user credentials, and are never installed into a trust store. Capability text passes only through a private start pipe and in-memory proxy setting. Reports redact proxy credentials; the origin and state snapshots are checked for leakage.

The native runner prepares these assertions:

1. Two real consecutive requests, recording actual CONNECT shape/authentication and forced close/reconnect.
2. Wrong authentication rejected before any TLS/upstream allocation.
3. Trusted correct-host certificate succeeds; unknown certificate and trusted wrong-host certificate fail with curl code 60; original-host SNI is observed.
4. Proxy credential absent from origin request.
5. Private-target redirect is returned as 302 with zero extra CONNECT requests.
6. A first-connection empty reply measures the pinned built-in reconnect: exactly two authenticated CONNECTs, no silent allowance for a third.
7. Oversized TLS response closes at the fixed encrypted-byte boundary; only bytes actually forwarded count.
8. Poisoned proxy/NO_PROXY/CA/Python environment does not reach the client. The wrapper uses an empty positive-list environment; the host also injects poison immediately before creating the child environment.
9. Host fixture/source/interpreter hashes and exact full payload identity are verified before and after the run. The OS Python performs hash-only verification before any payload interpreter is executed. It is never substituted for the Search runtime.

## Bounded fixture behavior and reconnect refinement

Pinned `searx/network/network.py` catches ConnectionError (including some TLS failures) and tries a newly created client once even with `retries=0`. The fixture therefore fixes a total two-authenticated-CONNECT admission budget and a single absolute 12-second request/generation lifetime. Reconnect cannot reset this clock or the shared byte ceilings. This is a conservative test threshold within the proposal's 30-second tunnel maximum, not a measured production recommendation.

- At most four simultaneous handler slots, including unauthenticated readers and active tunnels; this fixture is stricter than independent 4+2 concurrency.
- Header cap 8 KiB; two-second absolute header deadline; no unbounded waiter/thread queue. The TCP backlog is four. A local attacker can temporarily deny service, but one silent set of four clients expires and the next valid request recovers. The portable test observes that recovery with zero unauthenticated upstream allocations.
- At most two active tunnels and at most two total authenticated admissions per finite fixture generation.
- Five-second connect maximum, 32 KiB per-copy buffer, 64 KiB upstream and 8 MiB downstream per tunnel **and shared across reconnects**. Counters increment only after actual successful socket sends. Overflow closes instead of widening caps.
- Stop closes admission and all registered sockets, including incomplete headers and handshakes; handlers and the accept thread must settle. Portable tests invalidate with active and unauthenticated connections present.

The fixture serializes budget accounting and writes under one lock with one-second I/O waits. It is deliberately small and bounded, not a performance or production fd-race proof. It does not validate Swift dispatch queue semantics, OS resolver lifetime, numeric public-peer vetting or user-visible Stop/Quit.

## Original canary-stage checks (historical)

- 19 portable CONNECT/TLS/transport-contract tests using actual local socket/TLS bytes and ephemeral certificates.
- Eight portable profile/bootstrap contract tests, including an exact extracted C port parser compiled with the installed C compiler and source/payload drift checks.
- Shell syntax and Python AST checks.
- Three native entrypoints each explicitly return 77 on Linux; no native pass is inferred from that exit.
- Historical `unaccepted-native-owner-2158`: all 4,824 recorded files hash correctly; receipt `4268358594bf02881357334812b8f7ee84764940752071b1febd3ace26adbbab`, interpreter `bfb00f17c254d903fac15265ad47653724c3a753d2c36414062fa2025b9ac523`, canonical tree `c144cd5f64885f264baf1700c8ec51d221c1f6332c973763ec79d1c09fc74369`. Its interpreter is Mach-O arm64 and was not executed here.

`evidence/portable-tests.log` and `evidence/checks.json` preserve the final executions and exact outputs/status. `canary-artifacts.json`, `search-proxy-canaries.patch` and `SHA256SUMS` bind the deliverable; the patch adds only uniquely named test/verification files, never replaces existing gates or changes production Resources, packaging, Swift, project registration, manifests or acceptance changes.

## Exact-native blocker and command

The historical payload's assembly receipt binds the **canonical JSON** lock digest `0f094efe0cd2dc4d459a87ec9618884bd4f05bacd6c834ddd1036e813f2a4b80`. Reinspection found its matching historical `packaging/search/search-lock-native-owner.json`, whose **raw-file** SHA-256 is `25394a63db4084d606e56e25c7cec6a8fc979b03901c3b9739f2754e104a8920`. The earlier missing-lock diagnosis and raw-versus-canonical comparison were incorrect; see the correction below.

The frozen `canary-inputs.json` value `7cb53e3b734dc82537b8512ec0bb70931855c639c2557f6f6a10fd882e6c7041` remains the valid **raw-file** hash of `packaging/search/search-lock.json`; that file's canonical digest is `eaf493f1d29762f8bb432bfe36e7e98d33dbcb2008c6506598176eb504d81959`. The complete-app selected `search-lock-bounded-reader.json` has raw-file hash `1e317fa883f30dbf6d3db11b318a3a1947fc5ea811e087931ffcae023c5c1400` and canonical digest `7ec9921b6351686ceeaf6df1325055f83c33c5e5252deb2c92c5d3c0f6418240`. Neither matches the historical payload. Its static verification cannot certify either current production lock or current helper/profile/bootstrap bytes. A controlled future native run must use a separately reviewed payload and the exact canonical lock it actually binds; copied reference locks are excluded from this correction patch.

On the exact target Mac, after independently reviewing the selected unaccepted assembly receipt and its matching lock:

```sh
bash scripts/verify_search_proxy_native_fixture.sh \
  /canonical/path/to/unaccepted-Search \
  <reviewed-assembly-receipt-sha256> \
  /canonical/path/to/exact-source-lock.json \
  /new/path/build-only-proxy-result.json
```

Run the independent profile canary first, then bootstrap, then transport. Any compile denial, missing native package, unexpected CONNECT header, timeout, extra reconnect, certificate bypass, cap overflow or lock mismatch is a failed/blocked canary. Unknown headers and budgets must not be silently relaxed.

## Still unrun or outside this artifact

Native macOS profile compilation/enforcement, compiled bootstrap execution/signing, exact pinned curl transport behavior, full SearXNG/Waitress/DDG parsing, actual Swift host integration, native app/process cancellation and fd-reuse races, DNS/public-peer/rebind behavior, source-reader egress repair, representative real DDG first-page sizes, encrypted-to-inflated response allocation behavior, payload reassembly/admission/signing, and end-to-end cited research remain unverified. A future native fixture pass is still not production acceptance. Do not change release gates or current blocked/cancelled state from these artifacts.

## Independent correction review

The integrated test-only candidate includes three reviewed corrections: detect both raw capability bytes and their on-wire Basic encoding in origin/output/state/report data; require an observed invalid-auth rejection rather than any generic client error; and keep portable provenance checks self-contained instead of depending on the author’s staging paths. The corrected suite has **27 portable passes (19 transport and eight profile checks)**. All three native entrypoints remain explicit skip 77 on Linux; production broker acceptance remains false.

## Lock-digest-domain correction

2026-10-14, isolated Linux-only correction. `scripts/search_payload.py` writes the assembly receipt's `lock_sha256` as SHA-256 of `json.dumps(lock, sort_keys=True, separators=(",", ":")).encode()`. Both the shell wrapper's hash-only preflight and the native transport fixture previously compared that value with raw lock-file bytes. The original wrapper rejects the intact historical payload and its matching pretty-printed owner lock; compact canonical serialization happened to evade the defect.

Both entrypoints now use the same `verify_source_lock` helper and compare canonical JSON identity. The parsed lock and raw provenance derive from one read. The transport report keeps canonical `lock_sha256` and separately records `lock_file_sha256` for exact input bytes, then rechecks both before writing a report. Whitespace/key-order/Unicode-escape equivalents may be supplied initially; semantic mutations reject, and even equivalent reformatting during a run rejects as provenance drift. No production report was generated, and the historical assembly receipt is unchanged.

Correction checks: **37 portable passes** (10 new lock-domain regressions, 19 existing transport checks, eight existing profile checks). The new regressions exercise the real wrapper hash-only body with host Python and the transport preflight stopped before its dependency probe, plus the actual final report statements in isolation. This instrumentation does not execute or validate native dependencies. The original before-fix implementation fails both equivalent-JSON entrypoint regressions. All 4,824 historical payload records and all eight pinned transport-source files rehash successfully; the actual historical wrapper preflight changes from exit 1 to exit 0. Both nonmatching current lock candidates still reject. Three native entrypoints remain explicit skip 77 on Linux.

The frozen `canary-inputs.json`, `profile-bootstrap-basis.json` and `search_proxy_pinned_hashes.json` records were revalidated and remain unchanged. Their original-stage history is not relabeled as new evidence. The isolated correction package's `exact-base-manifest.json`, `search-proxy-lock-digest.patch`, `SHA256SUMS` and `evidence/` logs bind this six-path delta separately from the original canary artifact. No live checkout, historical payload, production broker/profile/bootstrap, sandbox grant, acceptance gate or installed app was changed. Native macOS enforcement and actual pinned transport behavior remain unrun; a passing hash preflight is not a native canary pass or current production acceptance.
