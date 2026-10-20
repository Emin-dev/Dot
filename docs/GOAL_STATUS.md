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

## Verification evidence (last full runs)

- Full Xcode lane: **915 tests, 1 skipped, 0 failures — TEST SUCCEEDED**
- SwiftPM suites: green (62 suite lines, 0 failures)
- Python suite: **604 tests OK, 4 skipped** (admission-contract indentation updated to the nested readiness block)
- Static guardrails: **53/53**
- Rust: dot-research 15, dot-runtime 3, dot-voice/dot-safety build clean
- `verify_macos.sh`: passes every stage; **0 warnings**; the only failure is the
  **runtime finalizer canary**, which fails by design on a hosted toolchain
  (`unsupported hosted toolchain image`) and blocks packaging
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
