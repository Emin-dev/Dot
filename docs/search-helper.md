# dot-search runtime: source contract

Current as of 2026-10-17. Web search is the Rust binary `dot-search`, built from
`crates/dot-research/src/main.rs` (`[[bin]] name = "dot-search"`) and copied into `Contents/MacOS` by
`build.sh` and `scripts/build_complete.sh`. The retired SearXNG/Waitress Python stack
(`Resources/Search/**`, `packaging/search/**`, its 31 pinned wheels, notices, canary workflow and
`Tests/Portable/**` contracts) no longer exists, and there is no AGPL search-server obligation and no
API key. See the [Rust runtime reference](rust-runtime.md); the retired design is kept only as
[history](verification/search-proxy-canaries.md).

The Swift host is `src/WebSearchProviders.swift` (`LocalDotSearchProvider`) plus the control-protocol
decoder in `src/SearchRuntimeProtocol.swift`. One process is launched per search; the binary is a
sibling of the app executable, so a missing runtime is reported as a setup failure instead of a
different search path.

## Launch and control protocol

```
<Contents/MacOS/dot-search> [--egress-port <port>]
```

The host writes exactly one bounded ASCII JSON line to the child's stdin:

```
{"protocol":1,"command":"start","generation":"<fresh UUID>"}
```

If no generation arrives the binary uses the fixed placeholder
`00000000-0000-0000-0000-000000000001`. `--egress-port` (or `egress_port` in the command) routes
outbound requests through a local HTTP proxy; `proxy_authorization: "Basic <base64 user:pass>"` adds
optional proxy credentials. Nothing else in the command is honoured, and no caller-supplied endpoint,
path, query, secret or child command is accepted.

The capability token is 32 random bytes from the OS entropy source rendered as 64 lowercase hex
characters, generated fresh per launch. It appears only in the `ready` event and in the request
header; it is never written to a file, argument, environment variable or log.

One bounded `ready` line follows once the loopback listener is bound:

```json
{"protocol":1,"event":"ready","generation":"<same UUID>","endpoint":"http://127.0.0.1:<port>/search","capability":"<64 lowercase hex>","helper_pid":123,"server_pid":124}
```

The listener binds IPv4 `127.0.0.1:0` and the runtime serves it in-process, so `server_pid` is
reported as `helper_pid + 1`; the host requires a distinct positive PID but does not treat it as an
independent process. `ready` proves local ownership only — it sends no search and proves nothing about
upstream availability. The host also bounds the ready line (4,096 bytes) and the startup wait
(10 seconds), and validates generation, capability syntax, endpoint shape and PID before any HTTP.

Closing the child's stdin (which the host does once a search settles, and on cancellation) makes the
runtime emit one `stopped` line and exit 0. The host then waits briefly, sends `SIGTERM`, and finally
`SIGKILL`, so no runtime outlives its search. There is no automatic provider fallback or relaunch.

## HTTP boundary

- Exactly `POST http://127.0.0.1:<owned-port>/search`; any other method or path returns 404. The
  request head must be complete and the declared `Content-Length` body must have arrived before the
  request is handled; chunked framing is rejected explicitly with 400 instead of being treated as an
  empty body. A request head or body that exceeds 128 KiB returns 413, and a read that stalls for
  10 seconds closes the connection.
- `X-Dot-Search-Capability: <per-launch capability>` must equal the token exactly; a missing or
  different value returns 403. The comparison is byte equality of the trimmed header value.
- The body is `application/x-www-form-urlencoded` and must contain a nonempty `q`; a missing or empty
  query returns 400. The host additionally rejects queries longer than 2,048 UTF-8 bytes, queries
  containing NUL, and limits outside 1…8 before launching.
- The response is one JSON object with `Content-Length`, `Content-Type: application/json` and
  `Connection: close`: `{"results":[{"url":…,"title":…,"content":…,"published_date":…}],"unresponsive_engines":[]}`.
  The host bounds the response at 1 MiB and rejects malformed or empty result sets.

Fixed request-read behaviour worth preserving: the head and the body may arrive in separate TCP
segments (CFNetwork/URLSession does exactly that), so the runtime reads until both are complete. The
earlier single-`read()` version returned 400 to those clients; that regression is covered by
`Tests/DotCoreTests/SearchRuntimeTests.swift` and the split-segment check recorded in
[PROGRESS](PROGRESS.md).

## Engines and result shape

- Primary: DuckDuckGo HTML endpoint (`https://html.duckduckgo.com/html/?q=…`), up to 6 results,
  redirect targets unwrapped from `uddg=`.
- Secondary: the Wikipedia OpenSearch API when the primary returned fewer than 3 results, deduplicated
  by URL.
- Results are truncated to 8 and returned with `url`, `title`, `content` (snippet text) and an
  optional `published_date`. Requests use a desktop browser user agent and a 12-second timeout.

## What the runtime does not implement

The retired Python boundary had checks this runtime does not have. Do not describe them as current:
there is no query-length or `!engine`/bang validation inside the binary (the host caps query bytes),
no `Origin`/`Host`/`Cookie`/`Authorization`/forwarding-header rejection, no CORS or redirect-header
policy, no response-size or entry-count cap inside the binary, no challenge/CAPTCHA or rate-limit
handling, no bounded backoff, and no `dot-search` Seatbelt profile (the retired `Resources/Search/search.sb`
was deleted). `unresponsive_engines` is currently always empty, so an upstream failure is reported as
an empty or short result set, not per-engine provenance. Adding providers, fallback ordering and
failure classification is open work in the
[owner decisions](BUILD_CHECKLIST.md#owner-decisions--2026-10-17-rust-only-runtime-and-accepted-corrections).

## Evidence and limits

Recorded on 2026-10-17 ([PROGRESS](PROGRESS.md)): `dot-search` started, emitted its `ready` event with
a per-launch capability, and returned live DuckDuckGo/Wikipedia results through its capability-gated
loopback endpoint; a deliberately split-segment request returned `HTTP/1.1 200 OK` with real results.

Not established and not claimed: native sandbox containment, live-provider acceptance across
challenge/cooldown paths, rate-limit behaviour, sustained concurrency, response determinism, and any
installed-app or device acceptance.
