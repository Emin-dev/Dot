# Dot audit — 2026-10-20 (re-audited 2026-10-21)

Base: `6b70eb2`, re-audited at the Phase 4 source (`c7c4ca6` + guardrails). Environment: Linux
aarch64 Cortex-A72, 4 GB, Rust only. Swift/Xcode, macOS permissions, audio, screen capture and DMG
installation still cannot run on the Pi, but **macOS arm64 CI now compiles and runs them**.

## Phase 4 re-audit (2026-10-21)

- The merged real-log branch is **compiled and green**: CI `39511199762` passed `rust-gates`,
  `swift-test`, `dot-voice` and `macos` (936 XCTest / 0 failures, 1 skipped; 608 SwiftPM; 614 Python
  / 4 skipped; 60 guardrails at that commit; now 62).
- Every "FIXED (pending push)" / "UNVERIFIABLE-ON-LINUX" row below that concerns Swift compilation or
  the named suites is now **Verified (automated)** by that run; native permissions/audio/device
  behavior remains **owner-gated**, not proven by CI.
- Offline source contract added (`Tests/Python/test_offline_runtime_contract.py`) plus a Swift
  no-network model-reuse test; native disconnected acceptance stays owner-gated.
- The rows still **BROKEN** are unchanged and honest: R9 self-healing is not built, the complete
  all-in-one parts and pinned model parts are not uploaded, and the DMG is ad-hoc signed/not
  notarised. The hardware gate is still M5 Pro class / 48 GB / macOS 27+.
- `BUILD_CHECKLIST.txt` is historical (2026-10-14) and its old stacked-payload rows are not current
  promises; [PHASE4_RESULT.md](PHASE4_RESULT.md) is the current promise matrix.

Legend: **WORKS** = exercised on this host or unambiguous source+tests; **BROKEN** = documented
promise contradicted by current source/CI; **UNVERIFIABLE-ON-LINUX** = requires macOS/Swift or the
owner's real hardware/session.

## Promises from README.md

| Promise | State | Evidence |
|---|---|---|
| Local floating macOS companion, click/menu/drag | UNVERIFIABLE-ON-LINUX | Swift/AppKit target |
| Downloadable `Dot.dmg` / `Dot.zip`, first-launch model download | UNVERIFIABLE-ON-LINUX | release assets and macOS install path |
| Exact Qwen3.8 27B Q4 on Splash, no substitute | WORKS (source) | `src/BundledSplash.swift:8`, `src/OfflinePreparation.swift:229`; manifest-verified, no alternate model branch |
| Whisper local STT, five-minute capture | WORKS (source) | `src/VoiceTiming.swift:151`; native execution unverified |
| Local Kokoro British voice, no cloud TTS | WORKS (source) | `src/BionicVoice.swift`, `crates/dot-voice` (build needs macOS `fullfp16`) |
| Memory, files, calendar, research, safety approver | UNVERIFIABLE-ON-LINUX | source present; no native run here |
| No conversation upload / no analytics | **FIXED** | new owner rule authorizes text-only upload; `DotLogSync` now writes `dot/<install-id>/<launch>/` to `dot-logs`, never `main`, with masking and no images |
| Minimum hardware M5 Pro / 48 GB / macOS 27+ | **FIXED** | `HardwareCompatibility` now refuses anything below M5 Pro class / 48 GB / macOS 27 with a clear blocking message |
| CI green on main | **VERIFIED** | run [`39511199762`](https://github.com/Emin-dev/Dot/actions/runs/39511199762) passed all four jobs; the hosted runner records the by-design canary failure and skips packaging |
| Rust gates green | **FIXED** | `cargo fmt --all` applied; `manual_repeat_n` fixed; `dot-research` and `dot-runtime` check/test/clippy pass |

## Promises from docs/AI_HANDOFF.md

| Promise | State | Evidence |
|---|---|---|
| 5-min listening cap, follow-up, sleep/wake, screen-off pause | UNVERIFIABLE-ON-LINUX | source + unit tests; native run required |
| Five-tier memory, FTS archive, voice-only recall | UNVERIFIABLE-ON-LINUX | `src/MemoryTiers.swift`, `src/LocalFTSStore.swift` |
| File read/search/autonomous utilities, safety gate | UNVERIFIABLE-ON-LINUX | source + tests; `dot-safety` check did not finish on the Pi (llama.cpp build > 15 min) |
| Conservative placement/roam, OCR clicks | UNVERIFIABLE-ON-LINUX | source + tests; no WindowServer |
| Research providers and cache | UNVERIFIABLE-ON-LINUX | Rust `dot-research` tests pass |
| Full XCTest / SwiftPM / Python lanes green | **VERIFIED (macOS CI)** | 936 XCTest/0 (1 skipped), 608 SwiftPM/0, 614 Python/4 skipped in run `39511199762` |
| Logs in `Application Support/Dot/Logs`, 2 MB rotation | WORKS (source) | `src/InteractionCore.swift:5159-5230` |
| Token only from the owner (never bundled) | WORKS (source) | `DotLogSync` reads Keychain service `dot-github-token`, then the owner-created config file; no token exists in the repo |
| Default DMG published | **REBUILT (release workflow)** | Phase 4 tag/SHA in [PHASE4_RESULT.md](PHASE4_RESULT.md); asset not installed on a Mac here |
| Complete all-in-one parts | **BROKEN/blocked** | needs the owner's verified 22.4 GB payload |

## Promises from docs/BUILD_CHECKLIST.md / .txt

| Promise | State | Evidence |
|---|---|---|
| 11 skins, Original default, warm expressions | UNVERIFIABLE-ON-LINUX | `src/SkinPreferences.swift`, `NativeCharacter.swift`; visual acceptance owner-gated |
| Configurable listening + follow-up (R1) | WORKS (source) | `VoiceTiming.maximumDuration = 300` |
| No wake word, English only (R2/R3) | WORKS (source) | hold-Fn/click paths only |
| British voice picker (R4) | PARTIAL / owner-gated | `DotVoice.british`; only bundled voice available |
| 5–10 key points memory (R5) | UNVERIFIABLE-ON-LINUX | memory code + tests |
| Voice-only memory UI (R6) | WORKS (source) | no memory panel |
| Supervised file autonomy + safety approver (R7/R16) | UNVERIFIABLE-ON-LINUX | `src/SafetyApprover.swift`; model binary is macOS/Metal |
| Adaptive screen watching (R8) | UNVERIFIABLE-ON-LINUX | screen permission + capture paths |
| Self-healing snapshots/rollback/watchdog (R9) | **BROKEN (not built)** | no implementation; documented as missing |
| Offline/local research, keyless providers (R10) | WORKS (source) / partial | DDG+Wikipedia+news; no offline index |
| Cold-start progress/prewarm (R11) | UNVERIFIABLE-ON-LINUX | source present |
| Display-off pause, wake greeting (R12) | UNVERIFIABLE-ON-LINUX | source + tests |
| Calendar create/edit/move (R13) | UNVERIFIABLE-ON-LINUX | EventKit only |
| Battery/charging alerts (R14) | UNVERIFIABLE-ON-LINUX | source + tests |
| Trusted-app allowlist (R15) | WORKS (source) | `TrustedAppStore` |
| Hardware/OS gate M5 Pro class / 48 GB / macOS 27+ | **VERIFIED (source + tests)** | supersedes the old M4 Pro/36 GB/26.4 row; no override and no smaller model |
| GitHub log system, one folder per Dot | **FIXED** | `dot/<install-id>/<launch-timestamp>/` on `dot-logs`; offline queue, backoff, 64-entry bound, 2 MB rotation, text only; token request remains owner-gated |

## Promises from docs/GOAL_STATUS.md

| Promise | State | Evidence |
|---|---|---|
| In-app automatic GitHub log sync | **FIXED** | dedicated `dot-logs` branch, per-launch folders, queue/backoff, Keychain/config token; `main` is PR-protected |
| R1, R5, R7, R10, R11, R14, R15, R16 marked complete | UNVERIFIABLE-ON-LINUX | same rows above |
| Test/guardrail counts | **VERIFIED** | Phase 4: 936 XCTest, 608 SwiftPM, 614 Python, 62 guardrails; see PHASE4_RESULT |
| Rust green | **FIXED** | fmt/check/test/clippy pass for `dot-research` and `dot-runtime` on the Pi |
| Installed provenance equals HEAD | UNVERIFIABLE-ON-LINUX | no installed app here |
| R4, notarisation, owner session owner-gated | UNVERIFIABLE-ON-LINUX | requires Emin |

## Branch diff: `origin/claude/app-dot-behavior-faax19` vs `main` — merged

The branch was merged normally at `181756c6` (21 files, +411/−89) and is **no longer ahead**:

- `e51943b` fixes real-log defects: every British voice accepted, missing voice embedding falls back
  safely, Whisper non-speech annotations dropped, sleep/wake no longer leaves Dot stuck, spoken
  commands ignore punctuation, automatic file mutations pass the safety approver, roam vetoes logged
  once, no duplicate spoken question.
- `0aeb7fd` implements R17: proactive comments ask only when a reply is genuinely needed; adds prompt
  and contract tests.
- Docs/checklists updated in the branch.

**Phase 4 verification:** the merged code compiled and ran on macOS arm64 (CI `39511199762`), with
the focused eight-suite gate and the full lanes green. Installation and owner acceptance remain
separate.

## Ordered fix plan — status

1. [x] Efficiency setup: `AGENTS.md`, `opencode.json`.
2. [x] Merge `origin/claude/app-dot-behavior-faax19` into main (`181756c6`).
3. [x] Make Rust gates green: fmt/check/test/clippy for `dot-research`, `dot-runtime`.
4. [x] Fix the launch hardware gate to **M5 Pro class, 48 GB, macOS 27+**.
5. [x] Log channel: `dot/<stable-install-id>/<launch-UTC>/` on `dot-logs`, Keychain/config token,
   offline queue/backoff/rotation; token request in `docs/QUESTIONS_FOR_EMIN.md`.
6. [x] Hosted runtime-finalizer canary recorded; packaging skipped instead of a red verification job.
7. [x] Swift tests for the hardware gate and log-sync path derivation/queue.
8. [x] Phase 4 focused suites/offline contracts; docs and CI updated.

## Post-audit fixes (2026-10-20)

All BROKEN rows above were addressed in this pass, except owner-gated items:

- Merged `origin/claude/app-dot-behavior-faax19` (R17, voice/sleep/transcript fixes).
- Hardware gate is now M5 Pro class / 48 GB / macOS 27+ and refuses lower Macs.
- Logging channel moved to `dot-logs`, text-only, with install-id/launch folders, offline queue,
  backoff, rotation, redaction and a Keychain/config token request in `docs/QUESTIONS_FOR_EMIN.md`.
- Rust fmt/clippy fixed; `dot-research` and `dot-runtime` gates pass on the Pi.
- Hosted CI records the by-design canary failure and skips packaging instead of going red.
- Remaining owner gates: store the GitHub token, run macOS CI/Swift tests, and exercise the app on
  real M5 Pro hardware.
