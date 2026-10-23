# What Dot does

Status of every feature. "Tested" means a unit test, XCTest or guardrail proves the code path; only
the owner's run on a real Mac ([TEST_TODAY.md](TEST_TODAY.md)) proves it end to end. The rule numbers
point to [DEV_TEAM_PROMPT.md](DEV_TEAM_PROMPT.md). The long history is in
[archive/BUILD_CHECKLIST_HISTORY.md](archive/BUILD_CHECKLIST_HISTORY.md).

## Works (tested)

- **Conversation:** click or hold Fn, no wake word (R2); English only (R3); up to 5 minutes of
  listening with a spoken notice at the cap (R1); follow-up listening after a real question; typed
  turns; quiet over video; pauses when the screen sleeps or locks.
- **Voice:** local Kokoro British voices; a missing voice falls back to the bundled Isabella (R4).
- **Wake greeting:** warm, time-aware, about 80% of wakes after a random 3 to 10 minute absence (R18).
- **Errors:** Dot keeps living, shows a large banner, logs the error, heals the engine and clears
  one-off errors by itself (R19).
- **Memory:** 5 to 10 key points per conversation, never raw sentences (R5); "what do you remember"
  and "forget about X" by voice, matching every word (R6).
- **Files (R7, R16, R22):** read, search, and create, move, copy, delete inside the folder you choose
  (kept across launches); every file change passes the local safety approver; other risky commands
  show an approval card that expires when you move on.
- **Screen:** adaptive watching with a pause switch (R8); read screen text; read the Safari, Chrome
  or TextEdit page; highlight the active window.
- **Proactive:** comments at Low 10 / Normal 4 / High 1 minute, question only when needed (R17);
  stuck-error help; meeting reminders; short self-reflection note (R20).
- **Calendar (R13):** briefs, create, edit and move events, each with a confirmation card.
- **Battery (R14):** optional low and charging alerts, off by default.
- **Trusted apps (R15):** allowlisted app actions skip the card.
- **Research (R10):** DuckDuckGo, Wikipedia and news with a 6-hour cache.
- **Mac controls:** volume, dark mode, lock screen (Control-Command-Q), timers, window layouts,
  typing and key presses into apps, clicks.
- **Cold start (R11):** live progress; optional prewarm at launch.
- **Install and removal:** one-line install into `~/Applications`; full removal
  ([UNINSTALL_COVERAGE.md](UNINSTALL_COVERAGE.md)); App Sandbox (R21).
- **Offline:** after the one-time 22.4 GB download, nothing needs the network; the download resumes
  after a pause, quit or network drop.
- **Logs:** text only, masked, uploaded to `dot-logs` when a token is stored.

## Bounded on purpose

- File awareness covers names in Desktop, Documents and Downloads; no full-disk index.
- Screen watching uses Apple Vision feature prints plus OCR (R23); no video understanding.
- Calendar edits change start and duration of a named upcoming event; no recurring series.
- Clicks need Accessibility and Screen Recording.

## Not built (owner decision needed)

- R9 self-modification with snapshots and a watcher.
- R4 voice upgrade (Chatterbox or Orpheus against Kokoro).
- R10 offline encyclopedia snapshot.
- Developer ID signing and notarisation ([QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md) section 2).
