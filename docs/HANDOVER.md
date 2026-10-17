# Dot handover — 2026-10-17

**Spec superseded by `docs/DEV_TEAM_PROMPT.md` (owner answers R1–R15, 2026-10-17) — follow it wherever these documents conflict.**

First written at commit `f089231`; revised and reinstalled from the committed tree (installed app
provenance matches HEAD, `source_root` recorded). Read [CONTINUATION.md](CONTINUATION.md) for the dated record and
the supervisor-port slices; this file is the "what is solid, what is not, what is next" list.

## Verified working (each with the evidence that was actually gathered)

- **Repository gates.** Xcode app build SUCCEEDED; the XCTest lane `verify_macos.sh` runs is
  860 tests / 0 failures (it began at 11 failures); `swift test` 546 / 0; the Python suite 604 passed
  4 skipped; 53 static guardrails; `cargo build --release` produces `dot-voice`, `dot-search`,
  `dot-fetch`; `scripts/audit_runtime_payload.py` accepts the owner's real Rust-only payload
  (34,004 files, exit 0).
- **Rust runtime.** `dot-voice` synthesises `bf_isabella` at 24 kHz offline from the real model
  (78,000 samples, 156,044-byte WAV). `dot-search` returns live DuckDuckGo/Wikipedia results through
  its capability-gated loopback endpoint, and now survives a client that splits head and body across
  TCP segments (the shipped binary previously answered 400). `dot-fetch` is the pinned HTTPS reader
  with a verified sandbox canary (inherited socket only, `connect()` denied).
- **Click to listen.** Whisper is compiled in and embedded by `build.sh` via `DOT_WHISPER_FRAMEWORK`;
  a refused click now says why; **the app now asks for the microphone and Screen Recording on the
  first click or hold-Fn, before any readiness gate** (it previously only checked status, which is why
  the log held sixteen "microphone access is off" messages and the app never prompted). Measured on
  the installed build (`bb658bf`, 2026-10-17): payload preparation 17.1 s; the first cold engine
  readiness from supervisor start to `pipeline=readiness outcome=ready` was **70.9 s**, after which a
  proactive turn generated and logged an answer. Warm turns share that resident engine; readiness does
  not mean answer latency.
- **Global shortcut discovery.** Hold-Fn, screenshot auto-hide and Ctrl+Option circle-to-ask are
  global monitors; macOS delivers no events to them until Dot is trusted for Accessibility. That grant
  now has a reachable request: the first-use menu says so, and Tools & History offers "Enable hold-Fn
  and global gestures (Accessibility)…" while untrusted.
- **Microphone discipline.** It arms only after final playback: not from a question mark, not from an
  intermediate audio-queue drain.
- **File autonomy.** Simple file-utility commands (delete/move/copy/create/write/rename) and the
  `delete_file` tool execute without a card; shells, `sudo`, substitutions, pipes into other
  executables, `/dev`/`/System` targets and non-file destructive commands still card. Proactive
  suggestions from files/folders are not implemented.
- **Approvals.** Destructive detection is tokenized (paths, wrappers, `-exec/-delete`, unquoted
  redirects); the card is clickable; a plain "yes" is accepted only for the non-destructive paste
  offer, so the destructive wording stays strict. Contextual app actions are carded unless the app is
  in the **Trusted apps** list, which toggles the frontmost app; calendar create/move also card.
- **Memory (five tiers).** One SQLite owner: facts and tier state share `LocalFTSStore`'s
  connection (no second handle). After a conversation lull the local model extracts 5–10 key points into
  the key-points tier; the full transcript stays in the searchable FTS archive. Explicit "remember …"
  preferences go to core. Capture from natural speech, tier-aware recall with an FTS fallback,
  "what do you remember", bounded explicit "forget about X", ageing that promotes T1→T2→T3→T4 and
  never deletes, eviction only from the real RAM-pressure path (never T3/T4/T5, never pinned).
- **Cold start.** The menu-bar title shows "Preparing N%" during the payload check and "Loading
  model…" during Splash readiness; the menu header and accessibility value carry the full stage.
  Tools & History offers optional prewarm at launch (off by default).
- **Calendar.** Briefs and schedule reads work; creating an event and moving the next meeting now
  present a confirmation card and execute only after approval. Arbitrary event editing is not exposed.
- **Small owner requests.** Copy Dot's answer to the clipboard; "show that" opens the readable
  history; battery level from IOKit; self-reflection writes to its file, copies to the clipboard and
  offers a paste; read a named text file (with a Spotlight name suggestion when the exact path is
  missing); Spotlight **content** search; timers missed during Mac sleep fire once on wake; optional
  low-battery and charging-start alerts (off by default) with a threshold submenu.
- **Video silence.** Dot does not speak while a video is detected (known video app, a browser window
  titled for a video service, or audio playing in a browser/video app). The answer/notice stays as
  text; proactive suggestions and automatic follow-up listening are suppressed. Muted background
  videos are not detectable and are not guessed.
- **Screen watching.** Idle fingerprint every three minutes; a change or mouse move starts a
  10–50 s watch, gated by the Screen awareness switch, permission and low-power mode, and paused
  during video. The final OCR context is kept for the next turn.
- **Listening and sleep.** A turn listens for up to 5 minutes, then answers what was heard and says
  the cap was reached; a Mac wake clears the sleep block, re-arms proactivity and says "I'm back."
- **Movement.** Idle roam every 2 minutes only. The 5-second thinking relocation was retired by the
  owner on 2026-10-17 after Dot moved nonstop through a cold model load; Dot now stays put during a
  turn. Coverage escapes and snapshot evasions are rate-limited to the same cadence, so a persistently
  covered map cannot restart the 0.5 s move loop. It still never moves while the menu is open, the
  pointer is on Dot, or a mouse button is held.
- **Appearance.** Dew is the default; an explicit choice persists (the interim migration that
  reverted an explicit Dew choice is gone).
- **Install.** `bash scripts/install_local.sh` builds with the recognizer, clones the payload
  copy-on-write, writes honest provenance, signs with the stable Apple Development identity, keeps
  `Dot.app.backup-latest`, relaunches and verifies provenance against HEAD.

## Not fully working, or not stable

1. **Owner voice turn observed on 2026-10-17; acoustic/device acceptance is not measured.** On the
   installed build the log records an owner capture (`capture_started`), the selected 3 s silence,
   `final_transcript` at 8.4 s, screen capture, generation and `final_playback_complete`; Dot executed
   the command the turn requested. This is a real voice turn end-to-end, but loudness/onset, device
   routes, headphones/Bluetooth, echo and a clean second Mac are still unverified. Earlier the same
   build reached engine readiness cold in 70.9 s, captured the screen, and completed a proactive turn
   (`[DOT (PROACTIVE)]` at 15:37:41), proving the payload, supervisor and generation path.
2. **`verify_macos.sh` still exits nonzero** for the mandatory runtime-finalizer canary, which fails on
   a hosted toolchain image (`unsupported hosted toolchain image`) by design and blocks packaging.
   The former flaky search case was fixed on 2026-10-17: the fixture's readiness line now uses shell
   parameter expansion instead of spawning two `sed` processes, and its accept wait is bounded at 30 s
   so a case that never connects cannot pin a dispatch thread. `startupSeconds` is unchanged at 10 s.
   Evidence: `LocalDotSearchProviderTests` 7/7 in 7.4 s and the full lane 860/0 after the change.
3. **Quality-of-service advisory: diagnosed, not caused by the turn pipeline.** The turn task in
   `ChatView.submit` now carries `.userInitiated` (correct in its own right), but a controlled
   experiment on 2026-10-17 reproduced the XCTest warning with *only* `NSApplication.shared` plus an
   `NSHostingView(rootView:)` in a test process — no turn, no URLSession, no engine task — and the
   system log names the wait as `-[NSCondition waitUntilDate:]` inside AppKit/SwiftUI. The narrow
   filter in `verify_macos.sh` therefore records an Apple-framework inversion that product code cannot
   remove; every other warning stays fatal. Do not widen that filter.
4. **Memory rough edges.** `MemoryTierStore` opens a second SQLite connection to
   `dot_records.sqlite` (a `withConnection` accessor on `LocalFTSStore` removes ~120 lines). Capture is
   a heuristic (240-character bound plus cue words) and may over- or under-capture. "Compression"
   concatenates a bounded summary rather than summarising with the model. There is no UI to browse or
   edit memory beyond the spoken listing and "forget".
5. **Screen awareness.** The persisted-marker trap is fixed: the marker now records only that the
   prompt was *offered*, and `isPermanentlyConfigured` clears it whenever preflight still disagrees,
   so a denial or crash during the prompt is asked about again. The model prompt no longer asserts
   Screen Recording permission (it is resolved from `CGPreflightScreenCaptureAccess` each turn), and
   it no longer names a source path from another Mac. Actual capture and screenshot reasoning
   ("which of these videos is more useful?") remain unverified in a real session.
6. **Self-improvement paste.** The offer reuses the approval card and types the suggestion (it does not
   paste from the clipboard), requires Accessibility, and has never been exercised in a real session.
   The reflection now reports which writes actually succeeded instead of always claiming both, analyses
   only the current app session, skips when there is nothing new, and reads the log from
   `~/Library/Application Support/Dot/Logs/dot_chat_log.txt` (migrated once from Downloads, rotated at
   2 MB); test processes write to a temporary log, so fixture text cannot drive a suggestion.
7. **Broad file access is partial.** What exists: read a named text file, Spotlight name and content
   search, and a watched folder. What is missing: indexing arbitrary trees, iCloud placeholder handling,
   relevance ranking, and any scan budget. The owner's ask was "everything on my disk".
8. **Placement refresh: fixed 2026-10-17.** The map's 10 s lifetime and the 10 s capture cadence meant
   the first validation of each cycle was rejected by construction, and a caller that had just started
   a refresh could have it cancelled by that rejection. `PlacementCapture.needsRefresh` now lets the
   movement callers start a capture while the old map is still valid, and `current` no longer
   invalidates an in-flight refresh. Thinking relocation and the two-minute idle roam now request a
   refresh as well; the lifetime stays 10 s (`RoamingTests` guards it). Live check on the installed
   build: consecutive `DOT_PLACEMENT stage=validation outcome=ready` lines every ~10.5 s with **no**
   `reason=expired` rejections, where the old build logged one every cycle.
9. **Last Dot-authored Python.** The Splash supervisor, child observation and TLS relay (640 lines).
   Slice 1 of the Rust port is committed (`crates/dot-runtime`: wire contract, api key, 3 tests; the
   binary deliberately reports `failed/supervisor/not-implemented`). Remaining: child ownership,
   TLS relay (**the expensive slice** — ~700 lines of Python contract tests move with it), socket
   handoff, and switching `BundledSplash.swift`. Splash itself stays Python by the owner's decision.
10. **~540 audited dead lines remain**, in the cases whose declarations are not cleanly separable.
11. **Tool catalogue.** Every conversational turn carries fourteen tool schemas. That was a documented
    decision in the owner's absence; a smaller always-on set is still an option if turns feel slow.

## Traps that cost time here (do not rediscover them)

- `python3` on this Mac is 3.9; the suite needs ≥3.11 — use `/private/tmp/dot-py313/bin/python`.
- This checkout is cloud-synced: build SwiftPM with a `/private/tmp` scratch path, and `xattr -cr`
  before `codesign`, or the File Provider makes codesign reject the bundle.
- **Re-signing resets TCC.** Always install with `scripts/install_local.sh` (stable Apple Development
  identity) or the microphone grant silently disappears.
- Never silence a symptom by weakening a bound: `startupSeconds` (10 s) and
  `PlacementSnapshot.lifetime` (10 s) are correct; `RoamingTests` and the TLS contract tests exist to
  catch exactly that temptation.
- A grep-verified "unreferenced" declaration can still share a line with a live one (comma-declared
  properties): verify deletions with a typecheck immediately, as happened with `RAMMetrics.usagePercent`.
- Broad agent briefs over this 22k-line codebase consume whole budgets reading and write nothing.
  Narrow, single-fix scopes (or doing it directly) produced every commit in this session.

## Suggested order for the next session

1. Have the owner grant the microphone and screen prompts, then record **one real conversation** and
   the resulting `DOT_*` log lines. Everything else is guesswork until that exists.
2. Supervisor slices 2 → 3 → 4 → 5, with `splash.sb` and the 53 guardrails green at each step.
3. Memory second-connection cleanup; then dead-code batches; then file indexing.

Already closed on 2026-10-17: the turn task's `.userInitiated` priority (the advisory itself is an
AppKit/SwiftUI inversion, documented above), the search fixture's readiness and bounded accept wait,
and the placement refresh-before-validation cycle. `verify_macos.sh` still exits nonzero only for the
by-design runtime-finalizer canary.
