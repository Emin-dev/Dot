# Rust-only runtime (current)

This is the current runtime reference, written 2026-10-17 after the Python voice helper, the Python
source fetcher and the entire Python SearXNG search stack were deleted. It describes what exists in
this source tree; it is not an installation, device or release acceptance record. Product intent and
the owner's 2026-10-17 decisions are in the [canonical checklist](BUILD_CHECKLIST.md#owner-decisions--2026-10-17-rust-only-runtime-and-accepted-corrections);
recorded runs are in [PROGRESS](PROGRESS.md).

## The three runtime binaries

`build.sh` runs `cargo build --release --manifest-path Cargo.toml --bin dot-voice --bin dot-search --bin dot-fetch`
and copies all three into `Contents/MacOS`, beside the app executable. `scripts/build_complete.sh`
requires all three `target/release/<name>` artifacts and refuses to assemble a complete app without
them. The shipped app carries no interpreter launcher or script payload for any of the three.

| Binary | Source | Role | Host side |
| --- | --- | --- | --- |
| `dot-voice` | `crates/dot-voice/src/main.rs`, Rust `any-tts` crate with the `kokoro` feature | Kokoro TTS, `bf_isabella`, 24 kHz mono WAV output | `src/BionicVoice.swift` |
| `dot-search` | `crates/dot-research/src/main.rs` (`[[bin]] name = "dot-search"`) | DuckDuckGo + Wikipedia behind a per-launch capability token on a loopback `POST /search` endpoint | `src/WebSearchProviders.swift` (`LocalDotSearchProvider`), `src/SearchRuntimeProtocol.swift` |
| `dot-fetch` | `crates/dot-research/src/fetch.rs` (`[[bin]] name = "dot-fetch"`) | one pinned HTTPS GET of an original source over a host-supplied connected socket | `src/ResearchHTTPTransport.swift`, `src/OfflinePayload.swift`, profile `Resources/Research/source_fetch.sb` |

Per-binary contracts: [voice bridge](voice-bridge.md), [search runtime](search-helper.md),
[source transport](source-transport.md).

## Recorded verification

The 2026-10-17 checkpoint in [PROGRESS](PROGRESS.md) records these runs on the owner's machine. They
are component checks, not installation, acoustic, device-matrix or release acceptance:

- `dot-voice` loaded the bundled Kokoro `bf_isabella` assets and synthesized one turn fully offline:
  `{"protocol":1,"event":"audio",…,"samples":78000,"sample_rate":24000}` into a 156,044-byte WAV.
- `dot-search` started, emitted its `ready` event with a per-launch 64-hex capability, and returned
  live DuckDuckGo/Wikipedia results through its capability-gated loopback endpoint.
- A deliberately split-segment search request (head and body in separate TCP segments) returns
  `HTTP/1.1 200 OK` with real results after the request-read fix described in
  [search runtime](search-helper.md).

No `dot-fetch` run result is recorded in this documentation set. The in-tree end-to-end driver is
`crates/dot-research/tests/dot_fetch_e2e.py`; it is a development fixture, is not packaged, and
exercises the shipped binary plus the shipped Seatbelt profile against a real public HTTPS origin.

## Deleted Python stack

Deleted on 2026-10-17 and referenced by no shipped source path:

- Python voice: `Resources/Voice/bionic_helper.py`, `Resources/Voice/voice.sb`, `packaging/voice/**`,
  the Python voice dependency closure, and `packaging/candidates/voice-*`.
- Python source fetch: `Resources/Research/dot_source_fetch.py`.
- Python search: `Resources/Search/**` (including `dot_search.py`, `search.sb`, its dependency pins
  and AGPL/Waitress notices), `packaging/search/**`, its 31 pinned wheels and its
  `Tests/Portable/**` contracts.
- Python-era tests and scripts for all three, `profile-bootstrap-basis.json`, the voice
  source manifest `packaging/voice-source-manifest.json` (its Whisper pin was retained verbatim in
  [packaging/whisper-source-manifest.json](../packaging/whisper-source-manifest.json)) and the
  `.github/workflows/search-proxy-canary.yml` workflow.

The scripts that remain reference these names only as negative guards (`assert not …exists()` in
`scripts/verify_macos.sh`, `scripts/check_contracts.py` and `Tests/Python/test_research_transport_contract.py`)
so the retired helpers cannot silently return to the bundle.

## Retained Python (deliberate)

Dot's own Splash supervisor and TLS relay remain Python and stdlib-only:
`Resources/Runtime/dot_runtime.py`, `Resources/Runtime/dot_process.py`,
`Resources/Runtime/dot_tls.py`. Porting them to Rust is the next migration step. Splash's own
interpreter and launcher are part of the external offline payload and are retained because Qwen 3.8
27B Q4 on Splash is the owner-approved fastest engine. The supervisor/TLS boundary is described in
[authenticated Splash transport](authenticated-splash-transport.md).

## Search stack policy

No SearXNG, no waitress, no AGPL obligation from a search server, and no API keys by default. The
Rust `dot-search` runtime queries DuckDuckGo and Wikipedia with keyless access. Additional free
providers and fallback ordering are open work; a keyed provider may be added later without removing
the free path.

## Documents that describe the retired stack

These are kept only as historical records; each carries a superseded banner and none of them
describes current behaviour: [offline voice assembly](offline-voice-assembly.md),
[bundled voice research](bundled-voice-research.md), [verification ledger](verification.md),
[search proxy canaries](verification/search-proxy-canaries.md),
[search proxy canary CI](verification/search-proxy-canary-ci.md),
[research recovery](verification/research-recovery.md), the [team handover](verification/DOT_TEAM_HANDOVER.md),
[profile bootstrap](../PROFILE_BOOTSTRAP.md), the [plain-text checklist](BUILD_CHECKLIST.txt) and
[continuation handoff](CONTINUATION.md). [Runtime reconstruction](runtime-reconstruction.md) is partly
superseded: its tool contract still exists, but its native voice gates still describe the deleted
Python voice closure. The Python-era half of
[helper boundary verification](verification/helper-boundaries.md) is labelled as history there.

## Known packaging-side inconsistencies (outside this documentation change)

Two source files outside `docs/**` still require the deleted Python voice stack. They are recorded
here so the Rust-only claim is not read as complete:

- `scripts/audit_runtime_payload.py` requires a `speech_synthesis` component containing
  `Voice/python/bin/python3`, a passed offline voice import probe and a complete voice dependency
  lock, so `scripts/build_complete.sh` cannot audit a Rust-only payload until it is updated.
- `packaging/runtime/reconstruction-policy.json` still pins the retired standalone CPython voice
  archive and its 92-wheel lock/audit hashes as inert context, and the reconstruction tool's native
  gates 2, 5 and 8 still describe Python voice evidence.

Both are named in [offline acceptance](offline-acceptance.md) and
[runtime reconstruction](runtime-reconstruction.md). Neither is a documentation defect and neither has
been changed here.

## Not claimed

Nothing in this document claims an installed app, an audible/acoustic result, a device matrix,
notarization, a public release, or a complete offline acceptance. The remaining migration work and
all release gates are listed in [PROGRESS](PROGRESS.md) and the
[canonical checklist](BUILD_CHECKLIST.md#owner-decisions--2026-10-17-rust-only-runtime-and-accepted-corrections).
