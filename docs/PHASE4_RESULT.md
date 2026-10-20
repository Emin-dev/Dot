# Phase 4 result — compiled, verified, offline checked, DMG rebuilt (2026-10-21)

## Outcome

The work merged from `claude/app-dot-behavior-faax19` at `181756c6` is now **compiled and executed
on macOS arm64 in GitHub Actions**. Phase 4 added an explicit focused-suite gate, converted the
owner-log fixes into named tests/guardrails, added offline source and model-reuse contracts, and
rebuilt the default DMG from the current source.

- Phase 4 code/test commits: `c7c4ca6` (focused suites, offline contracts, 60 guardrails) and
  `7e5c6b5` (safety-approver and memory-list guardrails, 62 total); docs at `69ecfbd`.
- CI run [`39513636141`](https://github.com/Emin-dev/Dot/actions/runs/39513636141) at `69ecfbd`
  (all 62 guardrails): all four jobs green. The earlier evidence run is
  [`39511199762`](https://github.com/Emin-dev/Dot/actions/runs/39511199762) at `c7c4ca6`.
- Release run [`39515511382`](https://github.com/Emin-dev/Dot/actions/runs/39515511382) built the
  DMG from the same `69ecfbd` source.
- Environment: the Pi compiles/tests Rust and Python only. Swift, XCTest, `dot-voice` and the DMG
  are macOS arm64 CI jobs; nothing here claims native microphone/speaker/screen behaviour.

## Verification (macOS arm64 CI `39513636141`, all 62 guardrails)

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check` | pass |
| `cargo check -p dot-research -p dot-runtime` | pass |
| `cargo test -p dot-research -p dot-runtime` | pass (18 tests) |
| `cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings` | pass |
| `swift build` + `swift test --parallel` | pass, **608 / 0** |
| Focused XCTest (eight named suites) | pass, **86 tests / 0 failures** |
| Full XCTest lane | pass, **936 tests / 0 failures, 1 skipped** (opt-in live model test) |
| `dot-voice` build + protocol tests | pass |
| Python suite | pass, **614 / 4 skipped** |
| Static contracts | pass, **62/62** |
| Debug + Release builds, zero warnings | pass |
| Hosted runtime-finalizer canary | by-design failure; recorded, hosted packaging skipped |

Focused-suite evidence from the same run:

| Suite | Tests | Failures |
| --- | ---: | ---: |
| `VoiceEventTests` | 10 | 0 |
| `SpokenQuestionTests` | 2 | 0 |
| `SpokenTranscriptTests` | 2 | 0 |
| `TypedInteractionTests` | 26 | 0 |
| `VoiceCoordinatorTests` | 16 | 0 |
| `EngineIntegrationTests` | 14 | 0 |
| `ProactiveBehaviorTests` | 11 | 0 |
| `ProactiveIntegrationTests` | 5 | 0 |

`scripts/verify_macos.sh` now runs these eight suites explicitly before the full lane, so a future
regression names the real-log class immediately. The full lane still includes them; that duplicate
execution is deliberate and fits the 30-minute job timeout.

## Owner-log fixes: claim → proof

| Owner-log fix | Proof | Result |
| --- | --- | --- |
| All four British voices accepted; missing voice falls back to Isabella | `VoiceEventTests.testVoiceHandshakeAcceptsEveryBritishVoiceOnly`, `testMissingVoiceEmbeddingFallsBackToTheBundledVoice`; guardrail "every British voice passes the voice handshake" | Verified |
| Idle sleep no longer blocks; one "I'm back."; roaming is not vetoed afterwards | `TypedInteractionTests.testIdleSleepNeverBlocksAndResumeGreetsOnce`, `testSystemWakeClearsTheSleepBlockAndSaysItIsBack`, `testScreenOffPausesAutonomousWorkAndSpeech`; guardrail "log noise …" (roam veto dedupe) | Verified in tests; owner session still required for the real sleep/wake observation |
| Spoken commands ignore Whisper punctuation; "What do you remember?" lists core facts and R5 key points | `TypedInteractionTests.testSpokenCommandsIgnoreWhisperPunctuation`; guardrail "memory list includes core facts and R5 key points" | Verified |
| Non-speech annotations never become turns | `SpokenTranscriptTests.testWhisperNonSpeechAnnotationsAreNotATurn`, `testRealSpeechSurvivesAroundAnnotations` | Verified |
| No double question after content already asked one | `SpokenQuestionTests.testToolQuestionIsNotAppendedAfterTheAnswerAlreadyAsked`, `testToolQuestionIsSpokenWhenTheAnswerAskedNothing` | Verified |
| "I can't hear you." removed; Dot knows it is heard; no forced question share | `EngineIntegrationTests.testProductionChatRequestAndFragmentedFinalQuestionContract`; guardrail "Dot knows it is heard and never forces a question"; `ProactiveBehaviorTests.testProactivePromptNeverForcesAQuestion` | Verified |
| R7 gap: model `delete_file` and automatic destructive commands pass the safety approver first | guardrail "model file mutations pass the R16 safety approver first" | Verified at source level; real approver behaviour needs the owner's session |
| Log noise: one `[HEALTH]` per change, SYSTEM role for context skips, roam veto once, no sync self-upload | guardrail "log noise is bounded and labelled honestly"; `LogSyncPolicyTests`; offline log-sync contract | Verified |
| R17 proactive comments keep cadence, ask only when the reply is needed | `ProactiveBehaviorTests.testProactivePromptNeverForcesAQuestion`; `ProactiveIntegrationTests`; guardrail above | Verified |

## Offline behaviour

What the new contracts prove (`Tests/Python/test_offline_runtime_contract.py` and
`OfflineIntegrationTests.testCompleteModelFilesAreReusedWithoutANetworkRequest`):

- Speech (`dot-voice`), Whisper and Splash inference reference **no HTTP endpoint**; Splash is
  TLS-pinned loopback.
- Only five source modules create `URLSession`s: loopback `Engine`, first-launch
  `OfflinePreparation`, optional `DotLogSync`, user-requested own-source `SourceReference`, and the
  optional keyed `WebSearchProviders`. Raw sockets are limited to the bounded source reader and the
  keyed providers.
- No cloud STT/TTS/LLM endpoint is referenced; `SFSpeechRecognizer` is not used.
- After the model exists at the exact size, `ModelProvisioner.ensureModels` creates **no** URLSession
  task (Swift test). `OfflinePreparation` still re-hashes every file before `state = .ready`, and the
  ordering is asserted separately.
- Log sync is token-gated: without a token it queues and returns; network failures use the persistent
  queue with exponential backoff; uploader diagnostics go to `dot-sync.log`, never to the uploaded
  chat log. Offline it is silent, with no alert or blocked turn.

**Not proven here:** a real disconnected Mac run (launch, voice turn, memory, screen capture with the
network physically off) and the full 19.9 GB first download. Those remain owner gates in
[offline-acceptance.md](offline-acceptance.md) and `QUESTIONS_FOR_EMIN.md`.

## Checklist walk

Every current promise in the live documents is classified below. `BUILD_CHECKLIST.txt` is a
2026-10-14 snapshot, explicitly superseded; its unchecked boxes are historical and are not counted
as current promises or failures.

| Promise area | Status | Evidence / limit |
| --- | --- | --- |
| Real-log fixes and R17 | **Verified (automated)** | table above |
| Launch gate M5 Pro class / 48 GB / macOS 27+ | **Verified (source + tests)** | `HardwareCompatibility`, checks in CI; no override, no smaller model |
| Rust runtime gates | **Verified** | CI `rust-gates` |
| SwiftPM and XCTest lanes | **Verified** | CI `swift-test` + `macos` |
| Python suite and static contracts | **Verified** | 614/4 skipped, 62 guardrails |
| `dot-voice` | **Verified (build + protocol)** | CI `dot-voice` |
| Five-minute listen, follow-up, cap notice | **Verified (tests)** | `VoiceTimingTests`, `VoiceFollowupTests`, `TypedInteractionTests`; device audio owner-gated |
| Memory tiers, FTS archive, voice-only recall | **Verified (tests)** | `MemoryTierTests`, `LocalFTSTests`, typed tests |
| File tools, safety approver, trusted apps | **Verified (source/tests)** | guardrails + `InteractionCoreTests`; real model decision owner-gated |
| Placement/roam/OCR clicks | **Verified (tests)** | `RoamingTests`, `InteractionCoreTests`; WindowServer owner-gated |
| Calendar create/edit/move and cards | **Verified (source/tests)** | interface tests; EventKit owner-gated |
| Research providers and cache | **Verified (source/tests)** | `ResearchEngineTests`, `WebSearchProviderTests`, `WebResearchStoreTests` |
| Screen watching, screen-off/lock pause | **Verified (tests)** | `ScreenContextTests`, typed tests; permission/device owner-gated |
| Battery/timers/mic mode/trusted apps | **Verified (source/tests)** | focused suites |
| Text log channel, offline queue, token path | **Verified (source/tests)** | `DotLogSync`, `LogSyncPolicyTests`, offline contract; actual upload needs owner token |
| First-launch downloader | **Partial** | manifest/hash/resume/repair tested; full 19.9 GB run not done |
| Default DMG | **Verified by release workflow** | Phase 4 release (tag/SHA below) |
| Pinned model-part primary route | **Blocked** | parts not uploaded; hash-checked HF fallback active |
| Complete all-in-one parts | **Broken/blocked** | needs the verified 22.4 GB payload on the owner Mac |
| Notarisation / Gatekeeper-clean public build | **Broken** | no Developer ID/notary credentials; ad-hoc signed |
| R9 self-healing | **Broken/not built** | no snapshots/self-test/rollback/watcher |
| R4 voice picker | **Partial** | four voices accepted; only Isabella always bundled |
| R10 local index/offline encyclopedia | **Partial** | keyless search + cache; no local index/snapshot |
| Siri/App Intents discovery | **Partial** | metadata packaged; invocation unrun |
| Owner acceptance (real session) | **Open** | requires a Mac at/above the gate |
| Second-Mac clean install | **Open** | requires the owner's second Mac |

## Default DMG rebuild

The Phase 4 release workflow rebuilds the current source, verifies the pinned runtime donor SHA-256,
runs contracts and split/join checks, packages the model-less default DMG, and uploads
`Dot.dmg`, `Dot.dmg.sha256`, `join-dot-dmg.command`, `join_release.py` and `README.txt`.

| Item | Value |
| --- | --- |
| Release tag | [`v1.1.0-phase4`](https://github.com/Emin-dev/Dot/releases/tag/v1.1.0-phase4) (source `69ecfbd`) |
| Release workflow run | [`39515511382`](https://github.com/Emin-dev/Dot/actions/runs/39515511382), success |
| DMG bytes | **1,005,188,103** |
| DMG SHA-256 | `dc9561facbf2fbafb91531a79b4d09c95250c5abaa18c47b33e34ab7794978c6` |
| `Dot.dmg.sha256` | uploaded; content matches the SHA above |
| Remote asset digest | GitHub API digest `sha256:dc9561fa…4978c6` — matches exactly |
| Other assets | `join-dot-dmg.command` (1,238 B), `join_release.py` (4,746 B), `README.txt` (1,108 B) |

The DMG is **ad-hoc signed and not notarised**. GitHub caps each asset at 2 GB; the complete
all-in-one installer is split by the existing tools but its parts cannot be produced on the Pi
because the 22.4 GB verified payload is not present. That remains the owner step in
`QUESTIONS_FOR_EMIN.md` §9.

## Still open (owner decisions, not decided here)

- Wake greeting policy (every wake / long absence / never) and idle life while blocked.
- Self-reflection frequency/content and clipboard overwrite.
- Public log-sync token storage (the code and queue are ready).
- R4 payload decision and R9 self-healing approach.
- Model-part hosting and complete all-in-one parts.
- Developer ID signing/notarisation and second-Mac acceptance.
- Native offline run and the owner acceptance session.

## Pi notes

The Python suite is green on macOS CI. On the Pi it needs a 022 umask and a disk-backed `TMPDIR`:
the reconstruction fixtures reserve 1 GB of scratch space, `/tmp` is a 768 MB tmpfs, and a
group-writable checkout is correctly rejected as an unsafe runtime mode. Example:

```bash
umask 022
TMPDIR=$PWD/.tmp/pytmp python3 -B -m unittest discover -s Tests/Python -v
```
