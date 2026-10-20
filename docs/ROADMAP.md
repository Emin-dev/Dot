# Dot — Roadmap, Goals & Current Plans

Last updated 2026-10-19. This is the public statement of where Dot is going; it is
kept in sync with the owner's binding rules in `docs/DEV_TEAM_PROMPT.md` (R1–R17)
and `docs/BUILD_CHECKLIST.md`.

## The goal

A signed, notarised **public release** of Dot: a local-first macOS companion that
acts, not just answers — listening, memory, screen awareness, research, file work,
self-improvement and self-healing — with every capability verified by the owner in a
real session, not just by tests. The engine and model are fixed: **Splash +
Qwen3.8 27B Q4** with its `DFlash2DraftModel` draft; all Dot-authored runtime code is
Rust; the only Python left is inside the vendored Splash engine.

## Current plan — phases A → B → C → D

- **Phase A — quick wins:** five-minute listening (R1, spoken cap notice); voice
  evaluation first — identical samples from Kokoro (British), Chatterbox and
  Orpheus 3B, the owner listens and picks the winner (R4); live cold-start progress
  + optional login prewarm (R11); optional battery/charging alerts (R14); placement
  refresh-before-validate; ~540 audited dead lines; the load-flaky search test.
**R10 status (2026-10-19):** the keyless metasearch ships four live, verified
sources — DuckDuckGo, Google News (RSS), Wikipedia and arXiv — merged with dedup
and the eight-result bound. Mojeek (403 to automated queries) and Marginalia
(no parseable results for automated requests) were tried and dropped; both are
recorded here so nobody re-attempts them. The optional vendored SearXNG instance
remains a documented later slice per the owner's "both" answer, and keyed
providers stay off unless the owner supplies keys.

**R16 slice plan:** (1) model — Gemma-3-4B Q4_K_M GGUF into
`OfflineModels/aux/`, fetched or copied by install_local.sh, pinned HF source ✅;
(2) harness — a `dot-safety` Rust binary (llama.cpp via the `llama-cpp-2` crate,
Metal) that reads a prompt (full conversation + proposed commands) and prints a
strict yes/no; (3) gating — the R7 flow routes every file/shell action through it,
re-asks with a safer solution on "no", and escalates to asking the owner after
three failed attempts.

**Real-log fixes and R17 (2026-10-20):** voice handshake for every British voice (Emma was
rejected), idle sleep no longer leaves Dot blocked, spoken commands ignore Whisper punctuation,
non-speech tags dropped, no double or forced questions (R17), Dot knows it is heard, model-chosen
file deletions pass the R16 approver, and the log/sync noise is gone. Code is on branch
`claude/app-dot-behavior-faax19`, not yet compiled or installed; see `AI_HANDOFF.md`.

**Phase A progress (2026-10-19):** R1 five-minute listening ✅ · R14 battery alerts
with spoken configuration ✅ · R11 live cold-start progress + prewarm toggle ✅ ·
placement refresh-before-validate ✅ (caller asks `needsRefresh` first; no
`reason=expired` rejections in the live log) · audited dead-code backlog cleared ✅
(`InteractiveWalkthroughManager` remains, deferred pending a first-run UX decision) ·
R4 voice pick awaiting the owner's judgment of the four Kokoro British samples.

- **Phase B — core value:** memory as 5–10 LLM key points per conversation with a
  full-text archive, announced to the owner on capture (R5); **supervised file
  autonomy (R7 revised)** — every file/shell action is decided by a small on-device
  safety model that receives the full conversation plus the exact commands and
  answers yes/no; on "no" Dot searches for a safer solution and re-asks; after three
  failed attempts Dot stops and asks the owner next time; trusted-app allowlist
  (R15); research expansion (R10) — every free keyless source plus a local Rust
  metasearch now, with an optional vendored SearXNG instance later.
- **Phase C — advanced:** adaptive screen watching (R8) — idle snapshot every few
  minutes, continuous 1–2 fps capture for 10–50 s (extendable) when the screen or
  mouse changes, battery-aware with a pause switch; self-healing (R9) over Dot's
  runtime files **and its own source** — snapshot → apply → self-test → rollback, one
  change per pass, ten snapshots, a fixed Rust watcher worker, a sealed
  last-known-good fallback and an emergency canary flag.
- **Phase D — release:** Developer ID signing + notarisation, first-launch model
  downloader, clean second-Mac acceptance, public release.

**R16 (starts with Phase A):** an auxiliary small local model — **Gemma-3-4B Q4**
(~4 GB) — added for two jobs: fast narrow tasks (classification, titling,
summarisation) and the R7 safety approver. The main conversational engine is
untouched.

## New capabilities just shipped

- **Engine liveness fix:** the readiness poll no longer kills Splash during its own
  cold start (connection-refused during load is progress, not a wedged engine); a
  silent engine still fails after the 180 s deadline with an honest message.
- **Health indicators:** every readiness-stage change and every blocked state
  rewrites `~/Library/Application Support/Dot/dot-health.json` (engine stage/ready,
  mic/screen/accessibility, phase, last issue, pid, timestamp) and writes a
  `[HEALTH]` line to the log — so Dot itself, the owner and an external agent can
  all tell what is broken at a glance.
- **The log system:** every conversation turn, tool action, screen summary, error,
  self-improvement note and health transition is recorded in
  `~/Library/Application Support/Dot/Logs/` (rotated). Screenshots are summarised as
  text (OCR lines and tool outcomes are already logged).
- **GitHub channel — one folder per launch:** `DotLogSync` (and the manual
  `scripts/dot_log_sync.sh`) publishes text logs, `dot-health.json` and launch
  metadata to the dedicated `dot-logs` branch under
  `dot/<install-id>/<launch-timestamp-UTC>/`. One new folder per launch, a stable
  anonymous install id, an offline queue with exponential backoff and 2 MB
  rotation. No images, screenshots, audio or memory database. The token is read
  from Keychain/config and is never bundled; `main` is PR-protected. See
  [the log reading guide](LOG_READING_GUIDE.md).

## What is already working (verified green)

Click/hold-Fn to talk with permission prompts on first interaction; answers via the
fixed local model; voice replies; the full five-tier memory loop (capture, recall,
inspect, forget, core-protected eviction); research over DuckDuckGo + Wikipedia +
news; file read and Spotlight name/content search; battery reporting; calendar
briefs and event editing with confirmation; timers; two-minute roaming that never
moves during interaction; screen snapshots; destructive-approval cards;
self-reflection (writes + copies + offers paste); display-off pause; wake greeting;
drag-to-Applications DMG packaging. Gates: full XCTest lane green, SwiftPM suites
green, 53 static guardrails, Rust crates green, installed-app provenance equals HEAD.
