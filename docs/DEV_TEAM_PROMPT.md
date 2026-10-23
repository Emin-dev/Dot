# Dot rules (R1 to R22)

Binding rules from the owner. The exact questions and answers behind them are in
[OWNER_DECISIONS.md](OWNER_DECISIONS.md); the current state is in [AI_HANDOFF.md](AI_HANDOFF.md).
A rule changes only when Emin gives a new answer. The longer 2026-10-17 brief, with its old state
and work plan, is in [archive/DEV_TEAM_PROMPT_FULL.md](archive/DEV_TEAM_PROMPT_FULL.md).

## 1. Product vision and end goal

Dot is a local-first macOS AI companion that acts, not one that only answers. The end
goal is a signed, notarised public release where every listed capability genuinely
works for a real user. "Works" means exercised in practice, not merely compiling or
passing a mocked test. The owner has been burned repeatedly by features marked done
that silently do nothing, so **observed behaviour is the only currency**:
- after each change: typecheck → focused suite → full gate → `bash scripts/install_local.sh`;
- a feature is not "done" until the owner has exercised it once in a real session.

## 2. Binding rules

**R1. Listening.** A turn may listen for up to **5 minutes**, then Dot answers with
whatever was heard and says the cap was reached. Never a silent cut-off.

**R2. Hands-free.** **No wake word.** Click or hold-Fn only. The microphone is never
open in the background.

**R3. Language.** **English only, always.** No multilingual voice scope creep.

**R4. Voice.** High quality matters more than speed, but everything must stay **local
and fast**. Target: a calm, warm, realistic **British woman**. Immediate step: expose
the Kokoro British female voices (`bf_emma`, `bf_isabella`, `bf_alice`) behind a small
picker — zero-cost, already local. Next step: evaluate **Chatterbox** (MIT) and
**Orpheus 3B** (Apache-2.0, Metal via llama.cpp) against Kokoro by listening test and
adopt the winner behind the same `any-tts` interface; keep Kokoro as the fallback for
speed. Never add a cloud TTS.

**R5. Memory capture.** **Remember everything, but never raw conversations.** After
each conversation, produce **5–10 short key points** that keep the details (an LLM
summarisation, not concatenation), and store them in the tier system. The full
conversation stays in a separate searchable archive; the five tiers hold key points.

**R6. Memory UI.** **Voice only.** No memory panel. "What do you remember" and
"forget about X" remain the interface.

**R7. File autonomy.** Dot must be able to do with files **everything the owner can —
create, write, rename, move, delete — automatically, without asking**. This overrides
any earlier "card for destructive actions" rule for file operations. Dot should also
proactively suggest things based on what it sees across files and folders.

**R8. Adaptive screen watching.** Idle: one simple snapshot **every few minutes**.
When something changes — screen content changes or the mouse moves — capture
**continuously for 10–50 seconds** (extend if still changing), and understand what
happened. Bounded by the Screen Recording permission, battery state, and a visible
pause switch; never continuous capture while completely idle.

**R9. Self-healing (owner's spec, expanded).** Dot may modify its own runtime files,
protected by the following machinery:
1. Before any self-modification, create a **timestamped snapshot** of the files being
   changed (git commit and/or copy into `.dot-backups/`).
2. Apply the change.
3. Run a built-in **self-test** (compile + smoke test) after the change.
4. On failure, **automatically restore the last known-good snapshot** and report
   exactly what broke.
5. On success, keep the change and log it.
6. **One risky change per pass** — one change, one test, one rollback point. Never a
   batch.
7. Keep the **10 most recent snapshots**; prune older ones automatically.
8. Add a **tiny fixed Rust watcher worker** (no LLM inside it) that runs alongside the
   app: it receives a heartbeat, and if the main app crashes or the LLM breaks
   something mid-change, the watcher restores the last known-good state itself and
   asks the main LLM what went wrong on next boot.
9. Keep a **sealed last-known-good fallback** (a read-only copy the watcher can
   relaunch if even the snapshots fail), and an **emergency canary flag** that
   disables all self-modification if the watcher sees repeated failures.

**R10. Research.** Add **all and more** search options: more web providers (news,
optional keyed providers), plus **local solutions** so Dot can research in any
situation — its own folder index, cached web results, and optionally an offline
encyclopedia snapshot. DuckDuckGo + Wikipedia stay as the default pair.

**R11. Cold start.** Show **live progress** of payload verification and model load
(stage by stage), and offer an **optional prewarm at login** so Dot is ready before
it is clicked.

**R12. Sleep/wake.** After the Mac wakes, Dot **automatically re-arms and says it is
back**. No manual click required. *(The greeting is refined by R18: no fixed "I'm back.")*

**R13. Calendar.** Briefs **plus create/edit events, each with a confirmation card**
(calendar mutations keep confirmation even though file mutations in R7 do not).

**R14. Battery.** Optional low-battery and charging alerts at owner-set thresholds,
**off by default**.

**R15. Action approvals.** Add a **trusted-app allowlist**: actions for allowlisted
apps skip the card. Everything outside the allowlist keeps the per-command card. File
operations are automatic per R7.

**R16. Auxiliary model (2026-10-19).** A small local model, Gemma-3-4B Q4 (~4 GB), handles
fast narrow tasks and is the R7 safety approver: every file mutation Dot chooses, including the
model's own `delete_file` and automatic destructive file commands, is checked before it runs.
No approver means no execution. The main engine and model stay untouched.

**R17. Proactive comments (2026-10-20).** Keep commenting on the owner's chosen cadence
(Low 10 / Normal 4 / High 1 minute), but end with a question only when the comment genuinely needs
the owner's reply. No rule may force a question into a share of replies.

**R18. Wake greeting (2026-10-22, refines R12).** Each sleep picks a new random threshold of
3 to 10 minutes. On wake Dot greets only after an absence longer than that threshold, and then
with an 80% chance. The line is warm and human, depends on the time of day and on a long absence
(2 hours or more), and never repeats a recent line. No fixed "I'm back.", no greeting after a few
seconds, no 30-minute wait. Code: `WakeGreeting` (`src/ProactiveBehavior.swift`),
`beginAbsence`/`greetAfterWake` (`src/ChatView.swift`).

**R19. Errors keep Dot living (2026-10-22).** An error never changes Dot's look or behavior: idle
motion, the two-minute roam and the idle face continue. The error shows as large white-on-red text
in a click-through banner above Dot, is logged as a `dot (error)` line that DotLogSync uploads to
`dot-logs`, and an engine error heals itself (retries at 15, 45 and 120 s, each logged as
`[HEAL]`). Code: `PetPhase.isResting`, `IssueBanner`, `scheduleEngineHeal`.

**R20. Self-reflection (2026-10-22).** The 10-minute idle reflection writes the full idea to its
file and the log, then says one short sentence ("I noted an idea to improve myself."). It never
touches the clipboard and never offers a paste.

**R21. Sandbox exceptions (2026-10-22).** Keep the App Sandbox and add only: read-only Downloads,
read-only `~/Desktop/` and `~/Documents/`, and Apple Events to System Events, Safari, Chrome,
TextEdit, Music and Spotify. Writes stay inside the folder the owner selects. `~` means the
owner's real home, never the sandbox container.

**R22. Folder across launches (2026-10-23).** The folder the owner picks for file actions is kept
as a security-scoped bookmark (`com.apple.security.files.bookmarks.app-scope`) and reopened at
launch. The automatic container folder is never saved.

## 3. Fixed constraints (never change without the owner)

- Engine and model: **Splash + Qwen3.8 27B Q4** with its `DFlash2DraftModel` draft;
  payload byte-identical. No engine, model, quantisation or "smaller for speed"
  substitution — the draft is where the speed comes from.
- **Rust for all Dot-authored code**; no new Python; the Splash supervisor port
  continues in `crates/dot-runtime` (slice 1 committed; slices 2–5 remain).
- Fewer lines of code, not more; delete dead code; no second mechanism where one exists.
- Dew default; Dot never moves during interaction; idle roam every 2 minutes.
- Memory never auto-deletes except under real RAM pressure (T1→T2 only; never
  T3/T4/T5, never pinned) — explicit owner "forget" is the only other deletion.
- Single branch `main`; commit + push after testing; installed app provenance must
  match HEAD via `scripts/install_local.sh`.

## 4. Never do

- Never raise a timeout, delete a test, relax an assertion or widen a filter to make a
  gate green. Fix the cause; if a filter must exist, record it and remove it with the fix.
- Never weaken `startupSeconds` (10 s) or `PlacementSnapshot.lifetime` (10 s).
- Never claim completion without the owner having exercised the feature once.
- Never substitute the engine, the model or the draft.
- Never leave the repo, the installed app and the docs out of step with each other.
