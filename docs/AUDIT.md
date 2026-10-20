# Dot audit — 2026-10-20

Base: `6b70eb2` (main). Environment: Linux aarch64 Cortex-A72, 4 GB, Rust only.
Swift/Xcode, macOS permissions, audio, screen capture and DMG installation cannot run here.

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
| No conversation upload / no analytics | **BROKEN** | `src/DotLogSync.swift:103` uploads conversation log to `Emin-dev/Dot`; new owner rule *does* authorize upload, but only to a logs branch with launch folders (not implemented) |
| Minimum hardware M5 Pro / 48 GB / macOS 27+ | **BROKEN** | `src/InteractionCore.swift:990-1002,1070-1084` still requires 36 GB / macOS 26.4 and lets the owner continue |
| CI green on main | **BROKEN** | five latest `Native companion checks` runs failed; mandatory canary exits non-zero at `scripts/verify_macos.sh:61` on hosted macOS |
| Rust gates green | **BROKEN** | `cargo fmt --all -- --check` fails (49 hunks); `cargo clippy -p dot-research --all-targets -- -D warnings` fails on `crates/dot-research/src/fetch.rs:1146` (`manual_repeat_n`) |

## Promises from docs/AI_HANDOFF.md

| Promise | State | Evidence |
|---|---|---|
| 5-min listening cap, follow-up, sleep/wake, screen-off pause | UNVERIFIABLE-ON-LINUX | source + unit tests; native run required |
| Five-tier memory, FTS archive, voice-only recall | UNVERIFIABLE-ON-LINUX | `src/MemoryTiers.swift`, `src/LocalFTSStore.swift` |
| File read/search/autonomous utilities, safety gate | UNVERIFIABLE-ON-LINUX | source + tests; `dot-safety` check did not finish on the Pi (llama.cpp build > 15 min) |
| Conservative placement/roam, OCR clicks | UNVERIFIABLE-ON-LINUX | source + tests; no WindowServer |
| Research providers and cache | UNVERIFIABLE-ON-LINUX | Rust `dot-research` tests pass |
| Full XCTest / SwiftPM / Python lanes green | UNVERIFIABLE-ON-LINUX | no `swift`/`xcodebuild` on this host; CI currently red |
| Logs in `Application Support/Dot/Logs`, 2 MB rotation | WORKS (source) | `src/InteractionCore.swift:5159-5230` |
| Token only from a file created by Emin | WORKS (source) | `src/DotLogSync.swift:56`; Keychain not used |
| Release published `public-f6cc73d` | UNVERIFIABLE-ON-LINUX | GitHub release exists; artifact not exercised |

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
| Hardware/OS gate M4 Pro/36 GB/26.4+ | **BROKEN vs new owner rule** | superseded by M5 Pro/48 GB/27+ requirement |
| GitHub log system, one folder per Dot | **BROKEN** | uploads to `dots/<machine>/` on main; owner now requires `dot/<install-id>/<launch-timestamp>/` on a logs branch, offline queue, retries, launch rotation |

## Promises from docs/GOAL_STATUS.md

| Promise | State | Evidence |
|---|---|---|
| In-app automatic GitHub sync | WORKS (source) / **BROKEN vs new layout** | `DotLogSync` runs, wrong branch/path and no queue |
| R1, R5, R7, R10, R11, R14, R15, R16 marked complete | UNVERIFIABLE-ON-LINUX | same rows above |
| XCTest 915 / SwiftPM / Python 604 / 53 guards | UNVERIFIABLE-ON-LINUX | CI red; counts are from a macOS run |
| Rust green | **BROKEN** | fmt/clippy failures above |
| Installed provenance equals HEAD | UNVERIFIABLE-ON-LINUX | no installed app here |
| R4, notarisation, owner session owner-gated | UNVERIFIABLE-ON-LINUX | requires Emin |

## Branch diff: `origin/claude/app-dot-behavior-faax19` vs `main`

Branch is **2 commits ahead** of main (`main..branch`), 21 files, +411/−89:

- `e51943b` fixes real-log defects: every British voice accepted, missing voice embedding falls back
  safely, Whisper non-speech annotations dropped, sleep/wake no longer leaves Dot stuck, spoken
  commands ignore punctuation, automatic file mutations pass the safety approver, roam vetoes logged
  once, no duplicate spoken question.
- `0aeb7fd` implements R17: proactive comments ask only when a reply is genuinely needed; adds prompt
  and contract tests.
- Docs/checklists updated in the branch.

**Recommendation: merge the branch into main** (fast-forward is possible), then run Linux Rust gates
and macOS CI. The changes are small, reviewed, covered by new tests and align with the owner's
2026-10-20 decisions. No conflicting local work exists. Do not force-push.

## Ordered fix plan

1. Efficiency setup: `AGENTS.md`, `opencode.json`.
2. Merge `origin/claude/app-dot-behavior-faax19` into main.
3. Make Rust gates green: `cargo fmt --all`, fix `manual_repeat_n`, re-run check/test/clippy for
   `dot-research`, `dot-runtime`; best-effort `dot-safety` on the Pi (document if it cannot finish).
4. Fix the launch hardware gate to **M5 Pro class, 48 GB, macOS 27+**, with a clear blocking message;
   update tests, README and checklist.
5. Replace `DotLogSync` paths with `dot/<stable-install-id>/<launch-UTC>/` on a dedicated logs branch;
   add token read from Keychain then config file, offline queue, bounded retries/backoff, rotation;
   write the token request to `docs/QUESTIONS_FOR_EMIN.md` and stop.
6. Fix macOS CI: keep the runtime-finalizer canary mandatory for packaging but do not fail the
   verification job solely on its hosted-runner failure; record it and skip packaging.
7. Add Swift tests for the hardware gate and log-sync path derivation/queue; keep Rust tests green.
8. Update PROGRESS/checklists; push to main and watch CI.
