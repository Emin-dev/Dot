# Dot Audit — Logical Issues & Real-Life Limitations

Read-only audit at commit `555d504` (repo untouched). Three sections: what is
broken by logic, what works but has hidden bounds, and what cannot be done at all.
Each item ends with a suggested fix; the owner's answers to the questions at the
end decide which fixes become spec.

## 1. Logical issues that make features not work

These are the "code exists, tests pass, but in practice it cannot fire" defects.

### Fixed this week (context, not regressions)

- **Microphone never requested.** The app only *checked* `authorizationStatus`; the one
  `requestAccess` call sat behind readiness and screen preparation, so it never ran and every turn
  reported "microphone access is off". Fix shipped: the first click / hold-Fn asks for the microphone
  and Screen Recording before any readiness gate.
- **Screen permission lied to itself.** `markPermanentlyConfigured()` wrote
  `screenAccessGrantedInSettings = true` *before* the prompt was answered, and that key plus an
  on-disk marker decide whether to ask again — so from the first launch the app believed access was
  granted, never asked, and every capture failed into a `notice` log line. Fix shipped: the marker now
  records that the prompt was *offered*; a stored "granted" claim is trusted only while preflight
  agrees; a stale marker self-heals; a refusal is reported to the owner with the exact Settings pane.

### Still open

1. **Quality-of-service inversion.** A User-interactive thread waits on a Default-QoS thread (the turn
   pipeline task in `ChatView.submit`). `verify_macos.sh` currently filters *only* this advisory out of
   its zero-warning check. Fix: `.userInitiated` on the turn task, and remove the filter in the same
   commit.
2. **Placement wastes a capture every cycle.** `PlacementSnapshot.lifetime` is 10 s and validation runs
   on a ~10 s cadence, so the first validation of each cycle is rejected by construction
   (`reason=expired elapsed=10475ms`). Fix: refresh before validating in the caller — never raise the
   lifetime (a roaming test guards that).
3. **Calendar and reminders fail silently.** `_ = await CalendarMeetingAssistant.shared.requestAccess()`
   discards the result; a denied calendar then produces nothing and says nothing. Fix: surface the
   denial (message + Settings pane), and only take the fast path when access is real.
4. **Screen is prepared with `requestPermission: false` at the typed and proactive sites**, so those
   paths can never produce the prompt; only the click path asks (via the new first-interaction fix).
   Fix: one consistent ask-on-need policy, not three site-specific flags.
5. **Accessibility denials are half-visible.** Typing/clicking/paste paths prompt only when an action is
   attempted, and a refusal is surfaced in some paths and swallowed in others. Fix: one visible,
   Settings-linking message for every Accessibility-dependent action.
6. **Splash has no health loop.** The log holds 16× "Splash stopped answering" with no auto-restart in
   sight; a hung engine stalls a turn. Fix: readiness-time liveness probe with one bounded restart
   attempt and an honest message.
7. **Memory has two stores and a heuristic heart.** Capture is cue-word + 240-character heuristics
   (over/under-captures), ageing is concatenation rather than an LLM summary, and `MemoryTierStore`
   opens a second SQLite connection. Fix: single connection via `withConnection`; optional model
   summarisation at ageing; "don't remember that" correction path.
8. **Diagnostic logging is invisible until a real session happens, and lives in Downloads**
   (`dot_chat_log.txt`). Fix: move to Application Support, rotate it, and log every turn outcome by
   default.
9. **~540 audited dead lines remain** plus two overlapping mechanisms (FTS store and tier store).
   Fix: one verified batch of deletions per commit.
10. **`verify_macos.sh`** fails only on: the by-design runtime-finalizer canary (blocks packaging on a
    hosted toolchain), and one load-flaky search fixture test (passes 7/7 in isolation; hung 1041 s
    once under full load). Fix: deterministic fixture readiness or bounded retries; do not raise
    `startupSeconds`.

## 2. Hidden limits — things that work, but not the way the owner assumed

- **Listening is capped at 60 seconds per turn** (`VoiceTiming.maximumDuration = 60.0`), ends on
  system sleep, and stops on silence. There is no continuous or unlimited listening. The owner believed
  listening was unlimited. Fix: raise or remove the cap, or make it a setting, with a clear notice when
  the cap cuts a turn short.
- **No wake word.** "hey dot" only strips a prefix from typed text; there is no hotword detection and
  the microphone is never open in the background. Fix: optional always-on hotword behind an explicit
  switch (battery and privacy are the trade-off).
- **Voice is English-only.** Kokoro `bf_isabella` (EN) plus an `en-GB`/`en-US` system fallback; the
  recognizer is English-centric. Fix: language picker first, multilingual later.
- **One voice.** No voice selection, speed or pitch. Fix: a small voice picker (high value, low cost).
- **Screen understanding is one snapshot per turn, 15-second freshness.** It cannot watch a video,
  compare two windows over time, or track changes. Fix: multi-frame capture on demand (bounded), plus
  an explicit "watch for X seconds" mode.
- **Cold start is ~90 seconds.** Payload verification ~14–16 s + Splash model load ~73 s; the app is
  unusable for the first minute after launch, with a blocked message rather than live progress. Fix:
  show stage progress, and optionally prewarm at login.
- **Research is DuckDuckGo + Wikipedia only**, on static, JavaScript-free pages; logins, paywalls and
  dynamic pages are out of reach, and results are size-capped. Fix: keep the two sources (privacy,
  keyed), add more sources only as an option.
- **File access is narrow.** Reads are UTF-8 text ≤256 KB, displayed at 4,000 characters; content
  search sees only what Spotlight has indexed; there is no first-class write/create/rename/move; delete
  exists behind the approval card; shell commands exist behind the approval card. Fix: first-class
  write/create/rename tools with per-action approval, and folder indexing for one or two named roots.
- **Memory capture is heuristic** (cue words, 240-character bound), inspection is voice-only, and
  "forget" deletes at most five matches. No browse/edit UI. Fix: small memory panel; "don't remember
  that"; LLM summarisation at ageing.
- **Battery is on-ask only.** No low-battery or charging alerts, no history. Fix: optional alerts.
- **Self-improvement does not improve itself.** The 10-minute idle reflection writes a suggestion to a
  file in Downloads, copies it to the clipboard and offers to paste — paste is *typed* through
  Accessibility, not a real paste, and nothing is applied to Dot's own files. Fix: show-diff and apply
  to Dot's own runtime files on approval.
- **Every turn carries all 14 tool schemas**, enlarging the prompt and slowing time-to-first-token.
  Fix: a small always-on tool set with the rest loaded on demand (owner decision pending).
- **Movement never interacts with windows.** Dot roams and stays put during interaction, but cannot
  drag, drop, point at a window or move windows. Fix: decide whether "acting on screen" is a goal at all.
- **Sleep ends the turn.** A sleeping Mac stops capture (`systemSleep`); recovery after wake is not
  proven. Fix: one automatic re-arm after wake with a spoken note.
- **Approval is per command only.** No per-application allowlist; repeated shell actions re-prompt.
  Fix: optional allowlist for trusted apps, still with the card for everything destructive elsewhere.

## 3. Cannot do at all today

- Hands-free use (no wake word, no background listening).
- Continuous or ambient screen awareness; understanding video beyond one frame.
- Multilingual voice; voice cloning; voice selection.
- First-class file creation/editing (only approved shell and approved delete exist).
- Reading logins, paywalls, JavaScript-heavy pages; reading PDFs/documents beyond plain text.
- Indexing arbitrary folder trees or iCloud placeholders.
- Auto-updates; first-launch payload downloader; notarised public release.
- Editing its own source (reflection produces text suggestions only).
- A memory browse/edit UI.
- Battery/calendar notifications (calendar briefs exist; no proactive alerts).
- A "trusted app" allowlist for actions.

## 4. What must stay (owner decisions, non-negotiable)

- Engine and model fixed: Splash + Qwen3.8 27B Q4 with its DFlash draft; payload byte-identical.
- Rust for all Dot-authored code; no new Python; Splash supervisor port continues in slices.
- Memory never auto-deletes except under real RAM pressure (T1→T2 only; never T3/T4/T5, never pinned).
- Approvals are a card, and only for destructive actions; "yes" accepted only for non-destructive.
- Dew default; no movement during interaction; idle roam 2 minutes; proactive Normal.
- Single branch `main`; push + reinstall after testing; fewer lines of code.
