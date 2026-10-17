# Fix-issues prompt for the AI development team

> **STATUS (2026-10-18):** this is the original 2026-10-17 defect list. A1–A10, B1–B7 and B9 are fixed
> (A5 completed with a visible text-only notice). **B8 (dead code) remains; B10 is by design.** Do not
> re-fix items without checking the current code. Current state, remaining product rules (R1–R15) and
> next steps are in [AI_HANDOFF.md](AI_HANDOFF.md).

You are fixing Dot (macOS SwiftUI companion, repo at
`/Users/mac/Documents/deepseek-harness/default-workspace/Dot`, branch `main`).
Read `docs/DEV_TEAM_PROMPT.md` (rules R1–R15 are binding), `docs/DOT_AUDIT.md`,
`docs/HANDOVER.md` and `docs/CONTINUATION.md` first. This file lists the concrete
logical issues and code errors found by audit, each with evidence and a suggested
solution. Fix them in the order given; verify every fix; do not change the engine,
model or payload.

## A. Confirmed logical defects (verified against source)

**A1. The paste offer overwrites an in-flight approval card.**
`ChatView.swift:1405` `offerPasteIfAvailable()` assigns `pendingApproval = …` without
checking for an existing one. A 10-minute reflection firing while a destructive
approval is pending silently replaces it; the owner then "approves" a paste while the
original command is dropped.
Fix: `guard pendingApproval == nil else { return }` (or queue the offer). Never
overwrite a pending destructive request.

**A2. Memory saves the instruction phrasing, not the fact.**
`ChatView.swift:2264` — the cue detector accepts mid-sentence "can you remember that…",
but the strip regexes at 2266–2269 are anchored to `^`, so the whole sentence
("can you remember that I like tea") is stored verbatim as the fact.
Fix: strip the cue wherever it occurs, then save only the remainder; add a unit test
with a mid-sentence cue.

**A3. Recall surfaces superseded records.**
`MemoryTiers.swift:239` `recall(query:)` returns FTS hits directly with no
superseded filter, while `records(tier:includeSuperseded:)` does filter. Corrected
facts (explicit corrections supersede earlier ones) can therefore reappear in recall
and be "forgotten" as the wrong record.
Fix: filter superseded records in `recall` (mirror the tier-list logic); test that a
corrected fact replaces the old one in recall results.

**A4. `.restricted` microphone state is invisible.**
`ChatView.swift:1446` asks only for `.notDetermined`; `1461` reports only `.denied`.
A Screen Time / parental-controls restriction shows nothing at all.
Fix: treat `.restricted` like `.denied` in the refusal message, and mention
Screen Time in the pane hint.

**A5. Silent failures the owner can never see.**
- `ScreenContext.capture` throws `.unsupported` when the model lacks vision — nothing
  surfaces it.
- `WholeContextExtractor.extractActiveDocumentOrWebpageText()` returns nil when
  Accessibility is untrusted, so "read my current page" fails with no explanation.
- `CalendarMeetingAssistant.shared.requestAccess()` results are discarded (`_ =`).
Fix: one visible, Settings-linking message per capability when its precondition
(permission, vision capability, accessibility) is unmet.

**A6. A dead or hung engine is reported as a preparation problem.**
`reportNotReady()` (ChatView) reports `OfflinePreparation.state` even when the payload
is ready but Splash died after readiness ("Splash stopped answering" ×16 in the log).
Fix: distinguish "still preparing" from "engine not answering"; add a liveness probe
with one bounded restart and an honest message.

**A7. Diagnostics live in Downloads, unrotated, and break under a future sandbox.**
`dot_chat_log.txt` is written into `~/Downloads`; a notarised/sandboxed release will
lose write access there, silently killing the only observability the app has.
Fix: move to Application Support (or Logs), rotate by size/age, log every turn outcome
by default.

**A8. Self-reflection reads the Downloads log and analyses empty content.**
`performReflectionAndWriteToAntigravity` reads `dot_chat_log.txt`; if it is missing or
empty it analyses "" and can emit a junk suggestion; moving the log (A7) breaks it.
Fix: derive the log path from one constant, skip reflection when there is nothing new
since the last reflection, and never emit a suggestion from empty input.

**A9. Timers across sleep are unverified.**
`SmartTimerScheduler` (verify file) — if deadlines use wall-clock math, a Mac that
sleeps fires all missed timers at wake; if monotonic, timers silently die during
sleep. Either behaviour is wrong unannounced.
Fix: fire a missed timer once at wake with a spoken note (or skip it and say it was
skipped), and test both behaviours.

**A10. "read file" requires the exact spoken path.**
The fast path resolves `expandingTildeInPath` only; "read my notes file" fails while
Spotlight name search would have found it.
Fix: on exact-path miss, fall back to a Spotlight name query and ask "did you mean
<top match>?" before reading.

## B. Previously documented defects (details in docs/DOT_AUDIT.md)

B1 QoS priority inversion — turn task `.userInitiated`; remove the gate's warning filter in the same commit.
B2 Placement validates after its 10 s lifetime each cycle — refresh before validating; never raise the lifetime.
B3 Screen `requestPermission: false` at typed/proactive sites — one ask-on-need policy.
B4 Two memory stores; second SQLite connection — `withConnection` accessor (~120 lines).
B5 Heuristic memory capture — replaced by R5 (5–10 key points per conversation).
B6 60-second listening cap — replaced by R1 (5 minutes with a spoken notice).
B7 No Splash health loop — covered by A6.
B8 ~540 audited dead lines — one verified batch of deletions per commit.
B9 Load-flaky search fixture test — deterministic readiness or bounded retries; never raise `startupSeconds`.
B10 `verify_macos.sh` by-design finalizer canary — leave; document as expected on hosted toolchains.

## C. Verification ritual (non-negotiable)

1. `xcrun swiftc -typecheck -target arm64-apple-macosx15.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-name DotProbe src/*.swift`
2. `swift test --disable-sandbox --scratch-path /private/tmp/dot-XX --cache-path /private/tmp/dot-XX-c --config-path /private/tmp/dot-XX-cfg --security-path /private/tmp/dot-XX-sec` (546 tests must be 0 failures)
3. Focused XCTest suites for the touched area
4. `/private/tmp/dot-py313/bin/python -B scripts/check_contracts.py` (53 must pass)
5. `bash scripts/install_local.sh` — installed app provenance must match HEAD
6. Commit + push to `main` only, after tests pass

Never: raise a timeout, delete a test, relax an assertion or widen a filter to make a
gate green. Never weaken `startupSeconds` (10 s) or `PlacementSnapshot.lifetime` (10 s).
A feature is done only when the owner has exercised it once in a real session.
