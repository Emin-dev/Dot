# Dot — Goal status & completion evidence (2026-10-19)

This file is the evidence record for the active goal. Every line below was verified
by actually running the gate, not by assumption.

## Objective code items — status

| Item | State | Evidence |
|---|---|---|
| In-app automatic GitHub log sync | ✅ (source) / token pending | `DotLogSync` writes `dot/<install-id>/<launch>/` to the dedicated `dot-logs` branch with an offline queue and backoff; the owner must store the token (see `QUESTIONS_FOR_EMIN.md`). `main` is PR-protected. |
| R1 five-minute listening | ✅ | `VoiceCaptureDeadline.maximumDuration = 300.0`; recognizer bounds 301 s; spoken cap notice; VoiceTimingTests 37/0 |
| R14 battery/charging alerts | ✅ | policy + settings + idle-tick monitor + spoken configuration commands; BatteryAlertTests 3/0 |
| R11 cold-start progress + prewarm | ✅ | live stage messages follow `onReadinessStage`; `prewarm at login` / `stop prewarming` commands; off by default |
| Placement refresh-before-validate | ✅ | caller asks `needsRefresh` before `current`; 0 `reason=expired` rejections in the live log; RoamingTests 16/0 |
| Dead code | ✅ | audited backlog cleared (`recentConversations`, `forgetMatching`, `recordVoice` gone; `TypedInteractionStatus` wired) |
| R5 memory key-points + announcement | ✅ | 20 s lull → LLM key points → keyPoints tier; announcement speaks after each capture |
| R7 supervised autonomy + R16 approver | ✅ | `dot-safety` (llama.cpp + Metal, Gemma-3-4B Q4) ships; live verdicts: rename→YES, `rm -rf ~/`→NO, `ls`→YES; gate fails closed; 3-strikes → owner "force it" override |
| R15 trusted-app allowlist | ✅ | contextual cards unless trusted; menu toggle; empty by default |
| R10 keyless metasearch | ✅ | DuckDuckGo + Google News + Wikipedia + arXiv, live-verified; Mojeek/Marginalia blocked automation (documented) |

## Phase 3 — CI and release (2026-10-20)

- `ci.yml` now runs four independent jobs: Rust gates on Ubuntu, `swift build`/`swift test`
  with the Xcode 26 SDK, `dot-voice` build + protocol tests on arm64 macOS, and the
  full `verify_macos.sh` lane. Run `39493996358` on `main@d0c7662` is green in all four.
- Voice tests that used arbitrary absolute host times are now deterministic on a
  freshly booted runner; coordinator waits no longer assume a 4-second budget.
- Release [`v1.1.0-phase3.1`](https://github.com/Emin-dev/Dot/releases/tag/v1.1.0-phase3.1)
  publishes `Dot.dmg` (1,011,993,151 bytes, SHA-256 `207676a4…bdbda`), its checksum, the joiner
  and a README. `release.yml` packages the **default model-less DMG** from current source: it downloads
  the previously published audited runtime donor (`public-f6cc73d`, SHA-256 pinned),
  strips model weights, and re-signs. It refuses to ship `OfflineModels`.
- Model delivery: `Resources/model-parts.json` is the primary pinned-part plan; when the
  owner uploads parts it becomes `ready`. Until then the app uses revision-pinned
  Hugging Face files and verifies the same signed SHA-256. Parts, retries/backoff,
  HTTP Range resume, per-part SHA-256, per-launch repair and disk checks are implemented.
- All-in-one: `split_release.py`, `join_release.py`, `join-dot-dmg.command` and
  `package_all_in_one.sh` produce/verify/join <2 GiB parts. Model and all-in-one parts are
  owner-gated (see `QUESTIONS_FOR_EMIN.md` §8–10).
- `verify_macos.sh` still records the hosted runtime-finalizer canary as a known
  hosted-toolchain limitation and skips packaging; the release job uses the pinned donor
  runtime instead of pretending that canary passed.

## Verification evidence (last full runs)

- Full Xcode lane: **915 tests, 1 skipped, 0 failures — TEST SUCCEEDED** (before phase 3;
  phase-3 CI reruns the portable SwiftPM lane and the audio-dependent Xcode lane)
- SwiftPM suites: green (62 suite lines, 0 failures)
- Python suite: **608 tests** (phase-3 release/parts contracts added; 4 skipped)
- Static guardrails: **56/56** (release workflow contract updated)
- Rust: 18 tests for dot-research/dot-runtime on the Pi; dot-voice build + 2 protocol tests on macOS CI
- `verify_macos.sh`: passes every independent stage; **0 warnings**; the only failure is the
  **runtime finalizer canary**, which fails by design on a hosted toolchain
  (`unsupported hosted toolchain image`) and blocks hosted packaging
- Installed app: provenance equals HEAD, all five binaries present, signed, running

## Remaining — all owner-gated (no code path exists without these)

1. **R4 voice choice** — four Kokoro British-female samples generated and waiting in
   `~/Downloads/Dot-voice-samples/` (bf_isabella, bf_emma, bf_alice, bf_lily); the
   owner picks the winner, or requests the Chatterbox/Orpheus evaluation.
2. **Phase D** — Developer ID Application certificate + notarisation requires the
   owner's Apple Developer account action (`SIGN_IDENTITY` for
   `scripts/package_public_release.sh`).
3. **The goal's done-condition** — the owner exercises the features in one real
   session (mic grant, a conversation, memory inspect, battery alerts, a file action
   through the safety approver).
