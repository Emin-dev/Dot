# Verification ledger

Base: 56041cf00d1d6b7c2f87590fdd1fbbbbb216e996. Separate cloud reconstruction; no byte-identity claim for earlier uncommitted Mac patches.

At initial preparation: source, plist/XML, workflow and shell static checks only on Linux. No Swift compiler or Xcode exists on that cloud computer. GitHub macOS checks and their exact final commit SHA must be recorded before delivery. Never substitute prior CI or Mac tests.

Real unit coverage: three-second silence boundary/reset, no-speech behavior, stale turn rejection, endpoint privacy policy, exact Splash model/engine/readiness checks, unsupported schema/port rejection, sentence boundaries/decimals/final fragments, bounded chunks and SSE parsing.

Device validation still required: floating-panel hit testing, multiple monitors/Spaces, VoiceOver and display accessibility settings, microphone permission interruption, actual silence/VAD timing in ambient noise, real on-device English recognition, actual Splash thought/answer latency, audible output and Bionic/Kokoro integration. No app-action/file/browser tools are claimed.

Manual harness migration: `tests/main.swift` now targets the new TTS API and requires explicit audio opt-in, failing rather than passing instantaneous silent completion. `tests/stt/main.swift` targets the new STT API, requires explicit microphone opt-in, and fails when capture never starts. Both remain manual/device-only. Compile with `swiftc -parse-as-library -o <output> src/InteractionCore.swift src/Speech.swift <harness> -framework AppKit -framework AVFoundation -framework Speech`. Do not run via CI; the launching host must have appropriate TCC permission. The old engine-download shell test is replaced by a proxy-free, redirect-free, read-only direct Splash identity check. None of these manual checks has run in the cloud.

Timing instrumentation logs only milliseconds since the explicit click: final transcript, first reasoning token, first answer token, first audio delegate start and generation completion. These are separate stages; no latency measurement is claimed until a real device run. Generation keeps thinking on at low effort.

Packaging: after all CI checks succeed, an ad-hoc DMG of at most 2 MB can be exported as a delimited base64 section in the public job log with its exact byte count and SHA-256. No model or private data is included. Delivery requires the entire delimiter pair, exact bytes and digest verification; truncation is a delivery failure, never an implicit pass. No release tag or release write credential is required.
