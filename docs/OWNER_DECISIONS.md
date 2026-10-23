# Owner decisions log (read before changing behavior)

This file records every question asked of the owner (Emin), the owner's exact answer, what was
built from it, where it lives, and why. It exists so a later AI or developer does not ask the
same question again and does not change a decided behavior back.

Rules for this file:

- A decision here is binding. Do not re-ask it and do not revert it.
- Only a new answer from Emin changes a decision. Then add a new dated entry and mark the old
  entry `Superseded by ...`. Never edit the quoted answer.
- Each entry names the code and the test or guardrail that proves it. If you touch that code,
  keep the test green. If a test seems wrong, read the entry first.
- The binding rule list is [DEV_TEAM_PROMPT.md](DEV_TEAM_PROMPT.md) (R1 to R24). The current
  state is [AI_HANDOFF.md](AI_HANDOFF.md).

## Owner instructions for the 2026-10-20 to 2026-10-22 sessions (verbatim)

1. "read all and fix app but ask questions about dot behavior how it should life and proactive
   life after reading all"
2. "update GitHub md files notes test too as code. so all team and other ai can continue this
   project"
3. "keep only one main default branch in repo. continue. this is end , we don't need new features
   but just make sure all from GitHub md files checklist and in code all works as expected. then
   update dmg file so I can instal and test app. make sure it will work on all new macOS devices
   always independently offline after installing."
4. "read all new code before editing" (given twice; the second time with "continue.")
5. "then also add our conversations and new rules new update to GitHub so other ai will know what
   and why we changed or fixed or improved, so it should know what I told your answer so it will
   not ask again or change back again to old one."

How these were applied:

- No new features. Work was limited to making documented promises true, fixing defects found
  while reading the code, and the behavior decisions below.
- Questions were asked one at a time with numbered options, after reading the code.

## Decision summary

| Rule | Date | Topic | Owner answer (short) | Status |
| --- | --- | --- | --- | --- |
| R17 | 2026-10-20 | Proactive comments | "Regular, no forced question" | Implemented |
| R18 | 2026-10-22 | Wake greeting | Human, warm, varied, time-aware, about 80%, only after a random 3 to 10 minute absence | Implemented |
| R19 | 2026-10-22 | Errors | Keep acting normal, big error text on top, log everything to GitHub, self-heal | Implemented |
| R20 | 2026-10-22 | Self-reflection | "Short spoken note" | Implemented |
| R21 | 2026-10-22 | Sandbox exceptions | "Allow them (Recommended)" | Implemented |
| Branches | 2026-10-22 | Repository branches | "keep only one main default branch" | Applied (see below) |
| R22 | 2026-10-23 | Folder across launches | "yes add" | Implemented |
| R23 | 2026-10-23 | Screen change detection | "1" (Apple Vision feature prints now) | Implemented |
| R24 | 2026-10-23 | Apple-native first | "use mostly apple native solutions only" | Standing rule |
| Full removal | 2026-10-23 | "delete itself ... same as after format ... only dot!" | Implemented, see [UNINSTALL_COVERAGE.md](UNINSTALL_COVERAGE.md) |
| Offline and Macs | 2026-10-22 | "work on all new macOS devices always independently offline" | Offline after first launch; hardware limit stays | Explained (see below) |

## R17. Proactive comments (2026-10-20)

- Question asked: "When should Dot speak up on its own? Today it comments on your screen every 4
  minutes and always ends with a question (the prompt forces it)."
- Options offered: 1. Only when useful (Recommended). 2. Regular, no forced question. 3. Keep as
  it is. 4. Quiet by default.
- Owner answer: "Regular, no forced question"
- Rule: Dot keeps commenting on the cadence the owner picked (Low 10, Normal 4, High 1 minute).
  It ends with a question only when the comment needs the owner's reply. No prompt may force a
  question into a share of replies.
- Code: `ProactiveReplyBuffer.prompt` (`src/ProactiveBehavior.swift`), main system prompt
  (`src/Engine.swift`). The old "ask questions in >60% of interactions" rule is removed.
- Proof: `ProactiveBehaviorTests.testProactivePromptNeverForcesAQuestion`,
  `EngineIntegrationTests.testProductionChatRequestAndFragmentedFinalQuestionContract`,
  guardrail "Dot knows it is heard and never forces a question".
- Do not: make Dot silent by default, or add "always end with a question" back.

## R18. Wake greeting (2026-10-22, refines R12)

- Question asked: "When your Mac wakes or unlocks, should Dot greet you? Today it says \"I'm
  back.\" after every display wake, even after a few seconds."
- Options offered: 1. Only after a long absence (30+ minutes) (Recommended). 2. Every wake.
  3. Never. 4. Time-aware greeting.
- Owner answer (typed, verbatim): "yes always but as real assistance human like randomly each
  time and time context aware so feel personal and warm not same robotic sentences. and not
  always but like 80%. and only if sleep more than 3-10  minutes randomly each time not 1 second
  not 30minutes."
- Rule:
  - Each time the display sleeps or the Mac sleeps, Dot picks a new random threshold between
    3 and 10 minutes.
  - On wake, Dot greets only if the absence was longer than that threshold, and then only with
    an 80% chance.
  - The line depends on the time of day (morning 5 to 11, afternoon 12 to 16, evening 17 to 21,
    night) and on whether the absence was long (2 hours or more).
  - The line is warm and human, and never repeats one of the recent lines. The fixed "I'm back."
    is gone.
  - Wake still clears a sleep block and re-arms proactivity and roaming (R12 stays true for that).
- Code:
  - `enum WakeGreeting` in `src/ProactiveBehavior.swift` (`shortestAbsence` 180 s,
    `longestAbsence` 600 s, `greetChance` 0.8, `longAbsence` 2 h, `threshold`, `shouldGreet`,
    `PartOfDay`, `lines`, `line`).
  - `beginAbsence()` and `greetAfterWake()` in `src/ChatView.swift`. `beginAbsence()` runs from
    `pauseForScreenOff` and from `cancelForEnvironment(.systemSleep)`.
- Proof: `ProactiveBehaviorTests.testWakeGreetingThresholdChanceAndTimeOfDay`,
  `testWakeGreetingNeverRepeatsARecentLine`, `TypedInteractionTests` wake tests including
  `testShortAbsenceOrUnluckyRollStaysSilent`, guardrail "R18 wake greeting is varied, time-aware and bounded".
- Do not: go back to "I'm back.", greet after a few seconds, wait for 30 minutes, greet 100% of
  the time, or use one fixed sentence.

## R19. Errors keep Dot living, show big text, log and self-heal (2026-10-22)

- Question asked: "When Dot shows an error (for example \"Microphone access is off\"), should it
  keep living, or freeze until you click it? Today it freezes: no roaming and no idle motion."
- Options offered: 1. Keep living (Recommended). 2. Idle motion only. 3. Freeze (today).
- Owner answer (typed, verbatim): "if something don't work anything anytime it should not change
  behavior and look act normal but show big text on top on it what is error. and log alll to
  GitHub so our ai dev can fix it automality then self heal dot."
- Rule:
  - Any error leaves Dot's look and behavior unchanged. It keeps idle motion and the two-minute
    roam, and its face shows the idle look, never "puzzled".
  - The error appears as large text (16 pt semibold, white on red) in a banner above Dot (below
    Dot near the top of the screen). The banner follows Dot and never takes mouse clicks.
  - Every error is written to the conversation log as a `dot (error)` line. DotLogSync uploads
    that log to the `dot-logs` branch, so the AI developers can read and fix it.
  - Self-heal: an engine failure retries by itself at 15, 45 and 120 seconds. Each attempt logs
    `[HEAL] engine retry n/3`, and the error clears as soon as the engine answers.
  - Permission errors (microphone, Screen Recording) need the owner in System Settings; macOS
    does not let an app grant itself permission. The banner text says what to do.
- Code:
  - `PetPhase.isResting` and `blockedMessage` (`src/Models.swift`).
  - `PetView.displayPhase` and `block()`, `scheduleEngineHeal(for:)`, `healTask`
    (`src/ChatView.swift`).
  - `IssueBanner` and `IssueBannerView` (`src/CompanionPanel.swift`).
  - `showIssue(phase:readiness:)` and every roam or motion gate using `model.phase.isResting`
    (`src/App.swift`).
- Proof: `TypedInteractionTests.testBlockedDotKeepsIdleMotionAndShowsItsMessage`, guardrail
  "R19 errors keep Dot living, show a banner and heal the engine".
- Do not: freeze Dot on error, stop roaming on error, show a puzzled face, hide the error in a
  tooltip, or stop logging errors.

## R20. Self-reflection is a short spoken note (2026-10-22)

- Question asked: "Every 10 minutes of quiet, Dot runs a \"self-reflection\": it speaks a long
  report, writes a suggestion file, and OVERWRITES your clipboard with the suggestion. What
  should it do?"
- Options offered: 1. Silent, log only (Recommended). 2. Short spoken note. 3. Keep as it is.
  4. Turn it off.
- Owner answer: "Short spoken note"
- Rule:
  - Dot keeps reflecting every 10 quiet minutes and writes the full idea to its suggestion file
    and to the log.
  - It says one short sentence: "I noted an idea to improve myself." If the file could not be
    written, it says "I had an idea to improve myself, but couldn't save it."
  - It never touches the clipboard and never offers to paste.
- Code: idle ticker in `src/ChatView.swift` calls
  `performReflectionAndWriteToAntigravity(copyToClipboard: false)`; `shortNote(wroteFile:)` in
  `src/InteractionCore.swift`. The `offerPasteIfAvailable` call is removed from that path.
- Proof: `InteractionCoreTests.testIdleReflectionSpeaksAShortNoteAndKeepsTheIdeaInItsFile`,
  guardrail "R20 idle self-reflection is a short spoken note and never touches the clipboard".
- Do not: speak the long report, copy to the clipboard, make it silent, or remove it.

## R21. Narrow sandbox exceptions so documented features work (2026-10-22)

- Question asked: "Under the new App Sandbox, some features marked \"done\" cannot work: reading
  your Safari/Chrome/TextEdit page, dark mode and sleep commands, pausing Music/Spotify while Dot
  speaks, and noticing new files in Downloads/Desktop/Documents. How should I fix this?"
- Options offered: 1. Allow them (Recommended). 2. Keep strict sandbox. 3. Folders only.
- Owner answer: "Allow them (Recommended)"
- Rule: keep the App Sandbox and add only these entitlements in `Resources/Dot.entitlements`:
  - `com.apple.security.files.downloads.read-only`
  - `com.apple.security.temporary-exception.files.home-relative-path.read-only` for
    `/Desktop/` and `/Documents/`
  - `com.apple.security.temporary-exception.apple-events` for `com.apple.systemevents`,
    `com.apple.Safari`, `com.google.Chrome`, `com.apple.TextEdit`, `com.apple.Music`,
    `com.spotify.client`
  - macOS still asks the owner once per app (Automation). The uninstaller still resets all of it.
  - Folder access is read-only. Writing, moving and deleting stay inside the folder the owner
    picks in Tools & History, then Mac actions & receipts (`UserFolderScope`).
- Related code: `UserFolderScope.userHome`, `expandingUserHome`, `userFolder`, `watchedFolders`
  (`src/InteractionCore.swift`). `~` means the owner's home, not the sandbox container. Open
  Downloads/Documents/Desktop, the recent-file scan and the Downloads scan use the real folders.
- Proof: `Tests/Python/test_phase7s_contract.py` (exact entitlement set),
  `InteractionCoreTests.testTildeIsTheOwnersHomeNotTheSandboxContainer`, guardrail "app sandbox
  entitlements are minimal and enforced" (it pins the exact R21 set).
- Do not: remove these exceptions (the features break again), widen them to the whole home
  folder, or add write access outside the selected folder.

## R22. Keep the chosen folder across launches (2026-10-23)

- Question asked: "Today Dot forgets the folder you choose for file actions each time it restarts.
  Keeping it needs one more sandbox permission, a saved folder bookmark."
- Options offered: 1. Add it, so Dot remembers the folder across restarts (Recommended). 2. Keep it as
  is, and choose the folder again after each restart.
- Owner answer (typed, verbatim): "yes add and improve dot as you recommending and suggesting, improve
  and finish building. make sure it is ready for production."
- Rule: the folder the owner picks in Tools & History, then Mac actions & receipts, is saved as a
  security-scoped bookmark and reopened at launch. A bookmark that no longer resolves is dropped.
  The automatic folder inside Dot's container is never saved.
- Code: `com.apple.security.files.bookmarks.app-scope` in `Resources/Dot.entitlements`;
  `NativeActionPanelModel.selectFolder(_:remember:)` and `restoreSavedFolder()`
  (`src/ActionPanel.swift`); restore at launch in `src/App.swift`.
- Proof: `NativeActionInterfaceTests.testChosenFolderIsRememberedAcrossLaunchesAndABadBookmarkIsDropped`,
  guardrail "R22 the chosen folder is kept across launches as a security-scoped bookmark", the exact
  entitlement set in `Tests/Python/test_phase7s_contract.py`.
- Do not: remove the bookmark entitlement, or save the automatic container folder.

## R23. Screen change measured by Apple Vision feature prints (2026-10-23)

- Owner question (verbatim): "explain how you used deception models like Laya or jjev in dot to
  improve app speed and make it more useful? if not how here you will add this new kind of models?
  and which local alternative you will use instead of jev?" Read as LLaVA and V-JEPA; the answer is
  [reference/perception-models.md](reference/perception-models.md).
- Options offered: 1. Add Apple Vision feature prints now (Recommended). 2. Feature prints now,
  FastVLM later. 3. Keep it as it is.
- Owner answer (typed, verbatim): "1 and find other issues that can be deleted or optimized to make
  app faster more secure more capable and use mostly apple native solutions only."
- Rule: the adaptive screen watch (R8) compares Apple Vision feature prints of a 256x160 capture.
  Only a distance at or above `ScreenFeaturePrint.changeThreshold` counts as a change, so a ticking
  clock or a blinking caret no longer keeps the watch running. Prints stay in memory only.
- Code: `ScreenFeaturePrint` and `ScreenContext.captureFeaturePrint()` (`src/ScreenContext.swift`);
  the watch loop in `startAdaptiveScreenWatch` (`src/ChatView.swift`).
- Proof: `ScreenContextTests.testFeaturePrintIgnoresATickingClockButSeesANewWindow`, guardrail
  "R23 screen change is measured by Apple Vision feature prints".
- Do not: bring back the exact pixel hash, store or log a print or frame, or add V-JEPA or another
  model for this.

## R24. Apple-native first (2026-10-23)

- Owner instruction (same answer as R23): "use mostly apple native solutions only."
- Rule: prefer macOS frameworks (Vision, Speech, AVFoundation, CoreAudio, Accessibility,
  EventKit, Network, Security, SQLite) over added libraries, scripts or models whenever they do the
  job. Changing a fixed constraint (model, voices, safety approver) still needs a new owner answer.
- Findings from the audit this started: [AUDIT_2026-10-23.md](AUDIT_2026-10-23.md).

## Branch policy (2026-10-22)

- Owner instruction: "keep only one main default branch in repo."
- Applied:
  - `main` is the only default branch and the only development branch. Commit and push to
    `main`.
  - `dot-logs` stays. The app uploads its text logs there (owner log rule), so deleting it breaks
    log upload. It is a data branch, not a development branch.
  - The old `claude/app-dot-behavior-faax19` branch is fully merged into `main`. Deleting it from
    this environment was refused, and `AGENTS.md` says never delete branches. Emin can delete it
    in the GitHub web page if wanted. Do not develop on it.
- Do not: create new long-lived branches, force-push, or delete `dot-logs`.

## "Work on all new macOS devices, always, offline" (2026-10-22)

- Owner instruction: "make sure it will work on all new macOS devices always independently
  offline after installing."
- What is true and must stay true:
  - The DMG does not contain the 22.4 GB model (GitHub limits release files to 2 GB). On first
    launch Dot downloads it once from the `model-parts-v1` release (25 parts, every SHA-256
    checked), with pinned Hugging Face files as the fallback.
  - After that one download, conversation, voice, memory and the safety approver run with no
    network. A relaunch with the model on disk needs no download and no free-space check (fixed
    2026-10-22, see below).
  - The fixed model (Qwen3.8 27B Q4 on Splash, no smaller fallback) needs an Apple Silicon M5 Pro
    class Mac with 48 GB and macOS 27 or later. A smaller Mac gets one clear refusal message at
    launch. This is a hardware limit of the owner's model choice, not a bug.
- Do not: add a smaller model to reach more Macs, lower the hardware gate, or bundle model files
  into the DMG without the owner's all-in-one decision (`QUESTIONS_FOR_EMIN.md` section 3).

## Defects fixed while reading the code (2026-10-22)

Each fix below closes a gap between a documented promise and the real code. Do not revert any of
them; each has a test or guardrail.

| Area | Problem found | Fix | Proof |
| --- | --- | --- | --- |
| Offline relaunch | A relaunch with the full model on disk still demanded about 6.9 GB free space and could block Dot offline | Budget check, "Downloading" text and `ensureModels` run only when `DownloadBudget.needsDownload` | `InteractionCoreTests.testCompleteModelOnDiskNeedsNoDownloadOrFreeSpace`, guardrail "an offline relaunch with the model on disk needs no download or free space" |
| First download | Display sleep or a locked launch cancelled the 22.4 GB download | `OfflinePreparation.pause(keepingDownload: true)`; the download holds a user-initiated activity; `retry()` never starts a second copy | guardrail "display sleep and lock never stop the one-time model download" |
| Safety approver (R16) | Gemma ran with llama.cpp's 512-token default context, so long conversations made every file action fail; its stderr pipe could fill and stall it; a harness error looked like the model saying no | 2,048-token context; request limited to the newest 3,000 conversation characters and 1,000 action characters, and the approver drops the oldest conversation text until the prompt fits; stderr discarded; `{"error":...}` or a non-zero exit means "approver unavailable" (no execution, no strike) | `TypedInteractionTests.testSafetyApproverRequestAlwaysFitsItsContext`, guardrails "safety approver request fits its context and harness failures never count as refusals" and "safety approver context is 2,048 tokens and trims the oldest conversation to fit" |
| Automatic file ops (R7, R16) | Some automatic file utilities ran without the approver | Every `FileOperationPolicy.isAutomaticFileOperation` command passes `safetyRefusal` first | guardrails "model file mutations pass the R16 safety approver first" and "automatic file utilities pass the R16 safety approver" |
| Scoped file ops | Flag parsing, `--`, relative paths and `~` were wrong inside the selected folder | `FileOperationPolicy.tokenize`, real flag clusters, exact `--recursive`/`--force`, relative paths from the selected root, `~` as the owner's home; shell commands run in the selected folder | `TypedInteractionTests.testScopedFileOperationsStayInsideTheSelectedFolder`, guardrail "scoped file operations parse options and paths inside the selected folder" |
| Spoken commands | A spoken "Scroll down." or "Turn on dark mode." kept Whisper's final period and missed many command matchers | `ChatView.spokenCommand(_:)` trims sentence-final `.?!…` for every command matcher; typing and clipboard keep the raw text | `TypedInteractionTests.testSpokenCommandsIgnoreWhisperPunctuation` |
| Voice approve or deny | A spoken "Approve" ran the action silently and left Dot listening, because the result is spoken only from idle | `cancelTurn()` before `approvePendingAction()`/`denyPendingAction()` | guardrail "voice approve and deny end the listening turn first" |
| Voice picker (R4) | The picker listed voices that were not installed and named the wrong voice | `DotVoice.installed(root:)`; Dot names the voice that is speaking and refuses a missing one | `DotVoice.installed` asserts in `InteractionCoreTests` |
| Read file | Under the sandbox a file outside the allowed folders failed with no guidance | Clear message: open Tools & History, then Mac actions & receipts, choose the folder, ask again | `Tests/Python/test_review_pipeline_contract.py` |
| Log upload | Without a token, launches were never queued, so early logs were lost | Metadata and files are queued before the token check; only the upload needs the token | guardrail "every launch is queued for log upload before the token check" |
| Remove Dot completely | Failure to open Terminal was silent | The command is always copied and an alert says whether Terminal opened | guardrail "Remove Dot always leaves the command and says what happened" |
| Docs | Soul export and log fetch instructions did not match the code | `BUILD_CHECKLIST.md` soul export line; `LOG_READING_GUIDE.md` uses `Accept: application/vnd.github.raw` | doc review |

## Current state and next steps

See [AI_HANDOFF.md](AI_HANDOFF.md). Every audit finding and its fix is in
[AUDIT_2026-10-22.md](AUDIT_2026-10-22.md).

## Questions not yet asked

Listed in [QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md) section 4. Ask one at a time, with 2 to 4
numbered options, and record the answer here before building.
