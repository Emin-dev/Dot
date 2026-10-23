> **SUPERSEDED (2026-10-17).** This document describes the retired Python Search proxy/SearXNG canary
> stage, which no longer exists. See [the Rust-only runtime](docs/rust-runtime.md) for the current
> runtime. Every input it names is deleted: `profile-bootstrap-basis.json`,
> `Tests/Fixtures/search_proxy_canary.sb`, `Tests/Native/search-proxy-bootstrap-canary.c`,
> `Tests/Native/search_proxy_bootstrap_probe.py`, `scripts/search_proxy_canary_support.py`,
> `scripts/test_search_proxy_sandbox_canary.py`, `scripts/test_search_proxy_bootstrap_canary.py` and
> `Resources/Search/search.sb`. The recorded counts and hashes below are preserved unchanged as the
> record of that work; no canary described here can be run today.

# Independent profile and bootstrap canaries

This stage adds uniquely named test files only. Existing native gate scripts and their original C/Python dependencies remain unchanged. The inspected `/workspace/shared/dot-cloud-build` source is read-only. `profile-bootstrap-basis.json` binds the six source files used and the reviewed proposal. The production `Resources/Search/search.sb`, native bootstrap and packaging are unchanged.

## What is prepared

- `Tests/Fixtures/search_proxy_canary.sb`: deny-default fixture with one inherited inbound `localhost:<owned-port>` and one outbound `localhost:<owned-egress-port>`, both restricted to AF_INET TCP. No wildcard, resolver socket/Mach, DNS-file, UDP, IPv6 or new-bind grants. The actual sockets use numeric IPv4 `127.0.0.1`; `localhost` is profile parameter syntax and never a resolver query.
- `Tests/Native/search-proxy-bootstrap-canary.c`: standalone test-only derivative of the pinned production source. No include of production code, DNS substitution, production flag, acceptance event or packaging registration. It preserves pre-Python sandbox entry, canonical paths, private state, startup bound, a continuously owned listener inherited as fd 3 and closefrom discipline. A strict nonsecret `--egress-port` scalar replaces the numeric whitelist only in this fixture.
- `Tests/Native/search_proxy_bootstrap_probe.py`: shared runtime probe with an exact CPython 3.11.17 check, preserved file/map/state/private/inference/symlink/shell and supervised-child assertions. It checks positive inbound exchange and two connections to the parent-held egress endpoint. Negative socket probes demand EPERM/EACCES, not timeout/refusal, for unrelated loopback, the helper's own listener, another loopback address, public/private/LAN/link-local TCP, DNS TCP/UDP, resolver Unix socket, UDP to the allowed TCP port, IPv6/mapped-IPv6 and fresh binds. No hostname lookup or HTTP/live-provider request is issued. If the policy is broken, denial probes may attempt an outbound socket operation; that is a failed canary, never a pass.
- Both runner scripts use the same support module, keep fixture listeners continuously held, check competing binds yield EADDRINUSE, ensure the forbidden loopback listener never accepts, observe control EOF and process/thread settlement, and reverify source bytes. Bootstrap-only checks include strict malformed scalar/argument rejection, a deliberately inherited decoy fd and a poisoned incoming proxy/CA/Python environment that must not reach the interpreter.

The bootstrap runner copies only the verified interpreter tree into a temporary fixture, copies its own probe/profile, and compiles/ad-hoc signs only its own test binary with identifier `app.dot.search-bootstrap-canary`. It never signs the input payload and never copies or writes a production manifest/acceptance report.

## Exact input requirement

Both runners require an independent, canonical, unaccepted static assembly and a previously reviewed receipt SHA-256. `verify_payload` checks every recorded file's path, size and hash, rejects symlinks/hardlinks/special files, unrecorded files, missing files and production admission files, and records the receipt lock identity, interpreter hash and full recorded tree hash. It imports/executes no payload code. Runtime probes use only that bundled interpreter, never system Python or Splash. Runner orchestration may use host Python.

The shared module is `scripts/search_proxy_canary_support.py`. There is no platform guard at import. Public helpers are `verify_payload(path, expected_receipt_sha256) -> (Path, evidence)`, `verify_source_lock(path, assembly_lock_sha256) -> (lock, evidence)`, `sha_file(path)`, `fixture_hashes(root, relative_paths)`, and `require_native()`. Native output additionally records macOS version/build/kernel/architecture; the bootstrap output records compiler, SDK and signed test-binary hash.

The transport companion uses `verify_source_lock` to compare the receipt's canonical JSON lock identity, matching the assembly writer's `json.dumps(lock, sort_keys=True, separators=(",", ":")).encode()` digest. It reads/parses/hashes the same bytes and records canonical `lock_sha256` separately from raw `lock_file_sha256`; formatting differences can match at startup, but changes to either identity during a run fail closed. The profile/bootstrap runners do not receive a separate lock file and continue recording the receipt's canonical `assembly_lock_sha256`. Frozen `canary-inputs.json` and `profile-bootstrap-basis.json` values remain exact raw-file provenance, not canonical lock identities. See [the lock-domain correction](docs/verification/search-proxy-canaries.md#lock-digest-domain-correction) for portable evidence and historical-input limits.

## Commands on the exact target macOS arm64 executor

Use the expected receipt hash already reviewed for the selected independent payload; do not replace this with an unchecked hash of a different candidate.

```sh
python3 -B scripts/test_search_proxy_sandbox_canary.py \
  --search-payload /canonical/path/to/unaccepted-Search \
  --expected-receipt-sha256 <reviewed-64-hex-receipt-sha256>
python3 -B scripts/test_search_proxy_bootstrap_canary.py \
  --search-payload /canonical/path/to/unaccepted-Search \
  --expected-receipt-sha256 <same-reviewed-receipt-sha256>
```

The output JSON is build-only evidence. It must not be fed to production acceptance tooling. A native error is a failed or blocked canary; never loosen a grant or convert it to a pass. These tests do not compile or execute the production Swift-owned broker. Even a future native pass does not establish CONNECT, TLS, SearXNG, production-bootstrap, live-provider, app-generation, assembly or distribution acceptance.

## Checks run here

`python3 -B Tests/Python/test_search_proxy_profile_contract.py`: eight portable tests passed. The C scalar parser was extracted exactly from the fixture, compiled with the installed portable C compiler and exercised on five valid and fifteen invalid/null forms. That small harness does not compile or execute the macOS bootstrap.

Both native entrypoints returned explicit skip code 77 on Linux. No native profile/bootstrap pass is claimed. `profile-bootstrap-evidence/report.json` and its log bind the passed/unrun scope and exact fixture hashes.

Read-only input verification also checked the existing `unaccepted-native-owner-2158` assembly: 4,824 recorded files, receipt SHA-256 `4268358594bf02881357334812b8f7ee84764940752071b1febd3ace26adbbab`, interpreter SHA-256 `bfb00f17c254d903fac15265ad47653724c3a753d2c36414062fa2025b9ac523`. That was file hashing on Linux, not target interpreter execution, and does not assert that this historical candidate is the final future integration input.
