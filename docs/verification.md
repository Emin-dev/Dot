> **SUPERSEDED (2026-10-17).** Parts of this ledger describe the retired Python voice helper (the
> "Bionic bridge", its Python mocked helper tests and the Python helper lifecycle), which no longer
> exists. See [the Rust-only runtime](rust-runtime.md) for the current runtime. The ledger was already
> historical by design: entries, dates, revisions and numbers below are preserved unchanged as the
> record of what was run at the time, and none of them certifies the current Rust runtime.

# Verification ledger

This is a historical ledger: dates and exact revisions define each result. See [current verified progress](PROGRESS.md) for the installed baseline and [the canonical checklist](BUILD_CHECKLIST.md#definition-of-tested-completion) for future work and completion criteria. Older unverified statements below describe their original stages, not a reversal of later evidence.

Base: 56041cf00d1d6b7c2f87590fdd1fbbbbb216e996. Separate cloud reconstruction; no byte-identity claim for earlier uncommitted Mac patches.

At initial preparation: source, plist/XML, workflow and shell static checks only on Linux. No Swift compiler or Xcode exists on that cloud computer. GitHub macOS checks and their exact final commit SHA must be recorded before delivery. Never substitute prior CI or Mac tests.

Real unit coverage: three-second silence boundary/reset, no-speech behavior, stale turn rejection, endpoint privacy policy, exact Splash model/engine/readiness checks, unsupported schema/port rejection, sentence boundaries/decimals/final fragments, bounded chunks and SSE parsing.

Device validation still required: floating-panel hit testing, multiple monitors/Spaces, VoiceOver and display accessibility settings, microphone permission interruption, actual silence/VAD timing in ambient noise, real on-device English recognition, actual Splash thought/answer latency, audible output and Bionic/Kokoro integration. No app-action/file/browser tools are claimed.

Manual harness migration: `tests/main.swift` now targets the new TTS API and requires explicit audio opt-in, failing rather than passing instantaneous silent completion. `tests/stt/main.swift` targets the new STT API, requires explicit microphone opt-in, and fails when capture never starts. Both remain manual/device-only. Compile with `swiftc -parse-as-library -o <output> src/InteractionCore.swift src/Speech.swift <harness> -framework AppKit -framework AVFoundation -framework Speech`. Do not run via CI; the launching host must have appropriate TCC permission. The old engine-download shell test is replaced by a proxy-free, redirect-free, read-only direct Splash identity check. None of these manual checks has run in the cloud.

Timing instrumentation logs only milliseconds since the explicit click: final transcript, first reasoning token, first answer token, first audio delegate start and generation completion. These are separate stages; no latency measurement is claimed until a real device run. Generation keeps thinking on at low effort.

Packaging: after all CI checks succeed, an ad-hoc DMG of at most 2 MB can be exported as a delimited base64 section in the public job log with its exact byte count and SHA-256. No model or private data is included. Delivery requires the entire delimiter pair, exact bytes and digest verification; truncation is a delivery failure, never an implicit pass. No release tag or release write credential is required.

## First genuine cloud macOS build

Commit 3a4ed36a4de59c269b9faeaae0eebf7cf8b6037a passed GitHub run [38250357231](https://github.com/Emin-dev/Dot/actions/runs/38250357231): 17 pure tests and 22 total XCTest tests (the same 17 plus five mocked Engine tests), Debug app compile, Release compile and ad-hoc DMG packaging. First ARM64/macOS-15 DMG: 844081 bytes, SHA256 97e6f97d2ff8fe8cfc914029b186e3f0ef9bb58441e5cc109acd385ddb4af7c3. Compiler warnings-as-errors passed, but Xcode metadata/destination and checkout runtime warnings existed. That build predates the Bionic bridge. Later changes require their own CI evidence.

The Bionic delta adds eight pure Swift event-validation tests and Python mocked helper lifecycle tests. The CI sandbox socket probe verifies process network denial, not actual voice synthesis. The new zero-warning gate scans Xcode output; the unused AppIntents metadata phase is disabled with the source-verified LM_SKIP_METADATA_EXTRACTION control because this app defines no AppIntents.

AppIntents control provenance: [Apple Swift Build task producer](https://github.com/swiftlang/swift-build/blob/a685e4d11547273c98b7f12871cd4e6cbcf4ab4a/Sources/SWBApplePlatform/AppIntentsMetadataTaskProducer.swift#L49-L54). The zero-warning gate scans test, release and delivered-package logs; it does not filter warnings out of those logs. Three macOS pipe transport tests additionally check full-pipe close, broken-pipe failure without SIGPIPE, and ordered writes.
