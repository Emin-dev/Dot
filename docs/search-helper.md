# Owned SearXNG helper: source contract and packaging gates

2026-10-13. This slice adds a portable supervisor and restrictive WSGI boundary, with injected offline fixtures. It does **not** deliver a bundled Apple Silicon Python/SearXNG runtime, native Search sandbox, signed helper, live search acceptance, or a complete research feature. Production remains unavailable when its independent, verified Search payload is absent. Splash's Python, sandbox, offline environment and model are unchanged.

## Private launch protocol

The Swift manager owns one generation and one `Process` for each launch. Start only for research, never ordinary local chat. Use an independently audited Search Python at `Search/python/bin/python3`, not a system interpreter, Homebrew, or Splash fallback:

```
<Search/python/bin/python3> -I -B <Resources/Search/dot_search.py> \
  --payload <Search> --state-root <private Search state root>
```

The final product also requires a verified native sandbox bootstrap. This portable CLI does not implement Seatbelt. The manager must keep production admission closed until that bootstrap is supplied and its exact artifact is verified. Manifest evidence flags are assembly requirements, not proof that a process is sandboxed merely by launching this script.

Connect private stdin/stdout pipes. Send exactly one bounded ASCII JSON line:

```
{"protocol":1,"command":"start","generation":"<fresh UUID>"}
```

Generation accepts 1–64 ASCII letters, digits, underscore or hyphen and is echoed unchanged. No parent-supplied query, endpoint, secret or arbitrary child command is accepted by the production CLI. The fixture-injection `supervise` function is an internal test seam, not a CLI option.

When the owned WSGI server has initialized, receive one bounded JSON line:

```
{"protocol":1,"event":"ready","generation":"<same UUID>","endpoint":"http://127.0.0.1:<port>/search","capability":"<64 lowercase hex>","helper_pid":123,"server_pid":124}
```

The capability is generated separately from SearXNG's secret key. It crosses private pipes only, never arguments, environment or logs. The endpoint port is selected by binding IPv4 `127.0.0.1:0`; the supervisor keeps that socket open while its child inherits the same listener. There is no close/rebind window, port scanning, service adoption, generic process-name killing or automatic provider fallback.

The manager must match protocol, generation, Process PID, exact endpoint, capability syntax and current launch lifetime before admitting HTTP. `ready` proves local initialized service ownership only. It sends no search and does not prove upstream availability or live JSON compatibility. Do not expose capability/endpoint receipts in user diagnostics, history or analytics.

After start, **any additional stdin byte or EOF requests stop**. Stop/cancel, app quit and sleep invalidate the Swift generation immediately, cancel URLSession work, close stdin or write one byte, and await process exit. The supervisor stops only its owned child's process group, closes the continuously owned listener and deletes its verified per-launch directory. Group cleanup keeps the leader unreaped until the final nonzero signal, preventing PID-reuse targeting.

A normal stop emits `{"protocol":1,"event":"stopped","generation":"..."}`. Failure emits `event=failed` with a fixed `reason` and, when available, generation; exceptions/library text are not forwarded. Initialization has a 30-second worker timeout and reacts to parent EOF during initialization. Cancellation kills actual upstream worker execution; it is not merely dropping HTTP response bytes. Resume is a **new launch and capability**, not revival of a cancelled worker. The manager decides when the user explicitly resumes; no automatic relaunch is performed.

The server also watches a private supervisor lifeline pipe. A killed/crashed supervisor closes the pipe, and the worker kills its own verified session/process group. Normal EOF/Quit cleanup removes state. A catastrophic supervisor SIGKILL can leave a private per-launch directory, even though the listener/worker are terminated. A future startup reaper must verify ownership and exclude live launches before deleting abandoned directories; this slice does not silently delete discovered directories.

## HTTP boundary

- Exact POST `http://127.0.0.1:<owned-port>/search`; no query string, alternative paths, `/healthz`, `/config`, prefix, absolute-form target or redirect. Host must exactly equal `127.0.0.1:<owned-port>` and remote peer must be IPv4 `127.0.0.1`.
- `X-Dot-Search-Capability: <per-launch capability>`, compared with `hmac.compare_digest`.
- Exact `Content-Type: application/x-www-form-urlencoded; charset=utf-8` and `Accept: application/json`.
- Exactly seven unique form fields: `q`, `format=json`, `categories=general`, `pageno=1`, `language=auto`, `safesearch=1`, `engines=duckduckgo`. Strict percent/UTF-8 decoding, canonical re-encoding, no duplicate or additional fields. No query is put in a URL.
- Nonblank q, at most 2,048 UTF-8 bytes and **fewer than 500 Unicode code points**. The pinned DDG engine silently skips longer queries; reject rather than truncate or misreport empty success. SearXNG `!engine`/`!!bang` directives at token boundaries are rejected. Plain punctuation such as `Hello!` remains allowed.
- Reject Origin (including null/empty), CORS/preflight, cookies, Authorization, forwarding headers, transfer encoding and content encoding. Never return CORS, cookies or Location headers.
- Waitress enforces 8 KiB request headers and 16 KiB request bodies. The boundary independently checks the declared length/body, serializes admission and returns a bounded busy response. Output is buffered to at most 1 MiB and 512 result entries. Waitress disk rollover is disabled; a 2 MiB channel high-water mark provides backpressure, and its request buffer ceiling is above the 16 KiB body cap. A maximum-sized real-Waitress response was tested with temporary disk-buffer creation forbidden. HTTP parsing uses pinned Waitress, not a custom production HTTP parser or Flask development server.
- Only bounded JSON `results` and `unresponsive_engines` survive. Result objects keep only URL, title, content, publication hint and engines. Reflected query, answers, infoboxes, cookies and diagnostics are removed. Non-JSON, malformed/oversized envelopes, redirects, errors and exceptions yield fixed failures. 403/429/503 remain distinct statuses; validated Retry-After is retained without shortening a long cooldown. The Swift adapter owns normalized URLs, warning coverage and semantic result validation.
- Debug/access/query logging is disabled; child stdout/stderr are not diagnostic streams. All child HTTP header values except the exact required host/accept are stripped before entering SearXNG, including the capability. HTTP content and capability are not written by this wrapper.

The generated YAML uses `use_default_settings.engines.keep_only: [duckduckgo]`, disables plugins/autocomplete/favicons/metrics/debug/limiter/image proxy, and limits timeouts. A post-import assertion requires the loaded engine set to equal exactly `duckduckgo`. Merely submitting an `engines` parameter is not treated as a safe engine boundary. Adding Brave, Wikipedia or another destination requires a separately reviewed shared contract change; `braveapi` is never selected.

## Private state and retention limit

Each launch gets new 0700 HOME/cache/config/tmp directories; settings are 0600. Environment is rebuilt from an allowlist, with no proxies, API keys, inherited Python paths, user caches or credentials. Configuration resolves explicitly to the generated private settings file. The child has no reason to receive chats, screenshots, models, prompts, browser profiles or user documents. Actual denial of their filesystem access still requires the native sandbox and canary tests.

**Important pinned-source discovery:** DDG's `set_vqd` stores a query-derived validation token in the engine SQLite cache under a secret-hashed query+user-agent key. SearXNG initializes engine/data SQLite databases in TMPDIR. Per-launch TMPDIR confines these writes, but ephemeral disk is not RAM-only storage. This slice provides the narrow build-only `searxng-transient-cache.patch`: make `set_vqd` a no-op for the fixed page-one-only contract. Later pages need cached VQD but are rejected by the gateway. The patch script verifies both original and patched full-file SHA-256, is idempotent, and refuses unknown source. Production additionally checks the loaded DDG source hash. Its isolated interpreter redirects bytecode lookup to a fresh private prefix and disables bytecode writes, preventing stale packaged bytecode from bypassing the source patch.

The original-function synthetic disk canary writes a query-derived token; the patched-function canary never accesses the cache or creates a file. The exact downloaded pinned DDG source also passes the patch/hash fixture. These are source/function evidence, not a full SearXNG run. An actual whole-helper disk canary remains required before `transient_cache_verified` can be true. Empty/private infrastructure SQLite files may still exist. The Swift session's memory-only retention setting cannot by itself certify the helper's complete cache behavior.

## Deterministic packaging plan and remaining gates

`Resources/Search/search-dependency-pins.json` records source candidates, not an assembled payload:

- SearXNG exact source revision `22c64b8d394b680c7ea96be25f36dad14126420a` and downloaded source-archive SHA-256.
- Waitress 3.0.2 official PyPI wheel/source hashes. The pure-Python wheel and source were downloaded and hash-checked for the isolated Linux fixture; no production or Splash environment was modified.
- SearXNG's exact direct requirements at that commit. This is **not** a transitive lock and is not installable release proof.
- No Python distribution was selected or bundled. No target-arm64 wheel/dylib closure, clean-Mac, signing or notarization acceptance is claimed.

Next executable packaging work:

1. Select a separately redistributable arm64 macOS CPython/OpenSSL artifact with exact URLs, hashes, build inputs and corresponding license/source material. Materialize internal symlinks as audited regular files or explicitly review a safe future manifest format; current payload audit rejects symlinks.
2. In a build-only isolated environment, resolve the pinned SearXNG source and every transitive dependency for the exact Python/arm64/macOS target. Produce a hash-locked wheelhouse, record ABI/deployment targets, inspect native lxml/curl_cffi dependencies and TLS certificates, then assemble using only that wheelhouse. No pip/network resolution at app launch.
3. Include exact source, patches, notices and redistribution/network-use obligations for SearXNG (AGPL-3.0-or-later), Waitress (ZPL-2.1), Python/OpenSSL and all transitive components. Review Dot's distribution as a whole; a separate process is not an automatic license exception, nor permission to retain upstream snippets.
4. Implement an exact Search sandbox bootstrap using the prebound owned listener. Allow only its payload, own fresh state, required public OS/runtime/TLS data and needed DNS/HTTPS. Deny personal files, sibling/inference state, LAN listeners and unnecessary network classes. Exercise positive and negative/symlink canaries on the target Mac. Keep Splash/voice policies unchanged.
5. Apply the supplied exact-source token-cache patch during assembly (never live runtime), then prove the promised retention model with synthetic canaries through run/pause/cancel/crash/restart and all cache/history/export paths.
6. Exercise real pinned SearXNG behind the real pinned Waitress boundary. Run a small explicitly authorized non-sensitive search smoke suite, including empty/partial/all-engine failures, challenge/cooldown and actual cancellation. Startup health alone is insufficient.
7. Hash every regular payload file into `search-runtime-manifest.json`, including executable/library/data/source/notice/profile/launcher artifacts as applicable. Set the acceptance fields only after exact-artifact evidence exists. Verify no unlisted files or symlinks, interpreter ownership, every size/hash and pins at launch. Sign nested code, verify/notarize, and test relocation/clean-Mac installation before production activation.

Expected manifest fields: `protocol: 1`, exact `searxng_revision`, exact `waitress_version`, `ddg_transient_patch_sha256` matching the source delta, boolean `native_boundary_verified`, `source_license_verified`, `transient_cache_verified`, `searxng_waitress_compatibility_verified`, and `files: [{path, size, sha256}]`. **No completed manifest is shipped by this slice.** A manifest flag does not replace its underlying evidence or the actual native launcher.

## Verification

Run portable fixtures:

```
python3 -B -m unittest discover -s Tests/Python -p 'test_search*.py' -v
```

An additional offline real-Waitress socket fixture runs when `DOT_SEARCH_WAITRESS_TEST_PATH` points at an independently hash-verified extraction of the pinned wheel. That path is used only by the test harness and never by production:

```
DOT_SEARCH_WAITRESS_TEST_PATH=<verified test wheel extraction> \
  python3 -B -m unittest discover -s Tests/Python -p 'test_search*.py' -v
```

The optional full-file patch fixture uses `DOT_SEARCH_SEARXNG_SOURCE=<verified pinned duckduckgo.py>`; it sends no network request.

The fixture-only default HTTP server is Python `wsgiref`; it is never the production server. The optional test runs actual Waitress 3.0.2 with the production socket/boundary settings and a synthetic WSGI application. Neither fixture imports SearXNG or queries the internet.

Checked 2026-10-13 on Linux: 32 tests passed with the pinned Waitress and downloaded full-source patch fixtures enabled. The default stdlib suite runs 30 tests and explicitly skips those two optional dependency/source fixtures. Covered form encoding/options, hostile route/Host/Origin/capability/proxy/CORS, body/header/output limits, redaction, cooldown preservation, admission, manifest tampering/gates, private-state identity, continuous listener ownership, EOF during startup, cancel while a request is in flight, stale capability, two instances, worker crash, supervisor crash, and a descendant ignoring SIGTERM. Native sleep/wake, full sandbox, installed payload, live engines, source reading/citations and whole-product acceptance remain unrun.

## Primary sources

- [Waitress prebound sockets](https://docs.pylonsproject.org/projects/waitress/en/stable/socket-activation.html)
- [Waitress 3.0.2 release metadata](https://pypi.org/pypi/waitress/3.0.2/json)
- [Pinned SearXNG settings merge](https://github.com/searxng/searxng/blob/22c64b8d394b680c7ea96be25f36dad14126420a/searx/settings_loader.py)
- [Pinned DDG query limits and cache](https://github.com/searxng/searxng/blob/22c64b8d394b680c7ea96be25f36dad14126420a/searx/engines/duckduckgo.py)
- [Pinned web application initialization](https://github.com/searxng/searxng/blob/22c64b8d394b680c7ea96be25f36dad14126420a/searx/webapp.py)
- [Pinned dependency requirements](https://github.com/searxng/searxng/blob/22c64b8d394b680c7ea96be25f36dad14126420a/requirements.txt)
- [Pinned SearXNG license](https://github.com/searxng/searxng/blob/22c64b8d394b680c7ea96be25f36dad14126420a/LICENSE)
