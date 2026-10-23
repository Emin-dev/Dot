# Dot — AI continuation handoff (2026-10-22)

**Read this first.** This is the current, evidence-based state for any AI developer continuing Dot.
The binding owner rules are in [DEV_TEAM_PROMPT.md](DEV_TEAM_PROMPT.md) (R1–R21). Every owner
question, the exact answer and the reason for each behavior is in
[OWNER_DECISIONS.md](OWNER_DECISIONS.md): read it before changing behavior, never re-ask a decided
question and never revert a decided behavior. Where this file and an
older document disagree, this file and `DEV_TEAM_PROMPT.md` win. `HANDOVER.md`, `CONTINUATION.md` and
`BUILD_CHECKLIST.md` contain history that is partly superseded; their top notes point here.

## Start here (next worker, 2026-10-22, owner decisions R18 to R21)

0. Open work and every audit finding: [AUDIT_2026-10-22.md](AUDIT_2026-10-22.md) (blocker F1, the
   movement parser, first). The next steps are at the end of [OWNER_DECISIONS.md](OWNER_DECISIONS.md).
1. Read [OWNER_DECISIONS.md](OWNER_DECISIONS.md). It quotes the owner's answers for R17 to R21,
   the branch policy and the offline/hardware limit, and lists the defects fixed on 2026-10-22
   with the test or guardrail for each.
2. Behavior now: wake greeting per R18 (random 3 to 10 minute threshold, 80%, warm and
   time-aware, never "I'm back."); errors per R19 (Dot keeps living, big red banner, logged,
   engine self-heal); reflection per R20 (one short sentence, no clipboard); sandbox per R21.
3. Pi gates for this tree: `python3 -B scripts/check_contracts.py` (103 guardrails) and the Python
   suite. Swift changes were reviewed by hand; macOS CI compiles and runs XCTest.
4. Owner scope for this phase: no new features. Make every documented promise true, then publish
   a new DMG. `main` is the only development branch; `dot-logs` stays for log upload.

## Phase 6 notes (2026-10-21, kept as history)

1. Phase 6 ran three independent read-only reviews over the whole product source, fixed every
   verified blocker/major with regression coverage, and added a real-launch lane. The findings
   table is in [REVIEW_FINDINGS.md](REVIEW_FINDINGS.md#phase-6-multi-model-review-2026-10-21);
   the release/gate evidence is in [PHASE6_RESULT.md](PHASE6_RESULT.md).
2. Phase 6 code commits: `aa4c642` (Swift review fixes), `fe3aaba` (scripts review fixes),
   `7e397c4` (real-app launch lane), `fc0fd1a`/`e69135a` (lane fixes). Phase 6 docs: `697ed73`
   and this handoff commit. The Phase 6 tag is created only on the final green CI commit.
3. The real-launch lane [`.github/workflows/real-app-check.yml`](../.github/workflows/real-app-check.yml)
   built the actual donor-runtime app and launched it on arm64 macOS 26.6.2; run `39628139773`
   observed the exact below-minimum refusal and the durable launch log. It does **not** prove a
   successful conversation, model download, mic/screen/voice, notarisation or owner acceptance.
4. The eight named suites still run explicitly in `scripts/verify_macos.sh` before the full XCTest
   lane: `VoiceEventTests`, `SpokenQuestionTests`, `SpokenTranscriptTests`,
   `TypedInteractionTests`, `VoiceCoordinatorTests`, `EngineIntegrationTests`,
   `ProactiveBehaviorTests`, `ProactiveIntegrationTests`.
5. Owner acceptance after install is still the only unautomated proof: talk with the default voice
   (Emma), sleep and wake the Mac while idle (after more than 10 minutes Dot greets warmly most of
   the time, never "I'm back.", and keeps roaming, per R18), say
   "What do you remember?", watch one proactive comment end without a forced question.
6. Remaining owner gates (not decided here) stay in "Open owner questions" and
   [QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md): model-part upload, complete all-in-one parts,
   Developer ID/notarisation, log token, R4 and R9 decisions.

## Owner decisions recorded 2026-10-22 (R18 to R21)

Full questions, verbatim answers and code locations: [OWNER_DECISIONS.md](OWNER_DECISIONS.md).

- **R18 wake greeting:** random 3 to 10 minute threshold per sleep, 80% chance, warm lines by time
  of day, no repeats, no "I'm back.".
- **R19 errors:** Dot keeps idle motion, roaming and its idle face; a large red banner shows the
  error; every error is logged and uploaded; engine errors retry at 15, 45 and 120 s.
- **R20 reflection:** one short spoken sentence, full idea in the file and log, clipboard untouched.
- **R21 sandbox:** read-only Downloads, Desktop and Documents; Apple Events to System Events,
  Safari, Chrome, TextEdit, Music and Spotify.

## Owner decision recorded 2026-10-20

- **R17. Proactive comments: regular, no forced question.** Dot keeps commenting on the cadence the
  owner picked (Low 10 / Normal 4 / High 1 minute) and asks a question only when the comment genuinely
  needs the owner's reply. Implemented in `ProactiveReplyBuffer.prompt` and the main system prompt
  (the old "ask questions in >60% of interactions" rule is gone); covered by
  `ProactiveBehaviorTests.testProactivePromptNeverForcesAQuestion`,
  `EngineIntegrationTests.testProductionChatRequestAndFragmentedFinalQuestionContract` and the
  guardrail "Dot knows it is heard and never forces a question".

## Open owner questions (behavior and "life")

Ask one at a time, numbered options, record the answer in OWNER_DECISIONS.md. Answered on
2026-10-22 and closed: wake greeting (R18), idle life while blocked (R19), self-reflection (R20),
sandbox exceptions (R21). Not yet answered:

- Public log sync: **resolved 2026-10-20** — text-only conversation/app logs auto-upload to the
  dedicated `dot-logs` branch under `dot/<install-id>/<launch>/`, with secrets masked and no images,
  screenshots, audio or memory database. The owner still needs to store the token
  (`docs/QUESTIONS_FOR_EMIN.md`). `main` is PR-protected.
- Personality: how Dot should "live" between turns (idle animations, reactions, mood, greetings).

## Current launch and logging rules (2026-10-20)

- Minimum: Apple Silicon M5 Pro class, 48 GB Unified Memory, macOS 27+. The launch gate refuses a
  lower Mac with one clear message; the exact Qwen3.8 27B Q4 Splash model has no smaller fallback.
- Text logs auto-upload to `Emin-dev/Dot@dot-logs` under `dot/<install-id>/<launch>/` via
  `DotLogSync`; see [the log reading guide](LOG_READING_GUIDE.md).

## Fixes from the owner's real log (2026-10-20, verified 2026-10-21)

Found by reading the old `dots/macbook16-m5-pro-48gb-mac17-8/logs/dot_chat_log.txt` (the channel now
writes `dot/<install-id>/<launch>/`). The fixes are merged at `181756c6` and were **compiled and run on
macOS arm64 in Phase 4**. Each claim below names the test or static guardrail that proves it; the full
evidence table is in [PHASE4_RESULT.md](PHASE4_RESULT.md).

- **Voice was dead for every voice except Isabella.** `VoiceEvent.parse` required `bf_isabella` in the
  `hello` event while the default is `bf_emma`, so every turn ended in "Unsupported Bionic voice
  protocol". Any of the four British voices is now accepted; a missing voice file falls back to the
  always-bundled Isabella with a log line (`DotVoice`). Proven by
  `VoiceEventTests.testVoiceHandshakeAcceptsEveryBritishVoiceOnly`,
  `testMissingVoiceEmbeddingFallsBackToTheBundledVoice` and the guardrail "every British voice passes
  the voice handshake".
- **Stuck after sleep.** An idle sleep blocked Dot with "Listening stopped when your Mac went to sleep";
  the wake greeting then refused to speak and the block stayed, so idle roaming was vetoed for hours
  (`[ROAM] skip: phase=blocked`). Idle sleep no longer blocks, wake clears a sleep block, and both wake
  paths share one greeting (the fixed "I'm back." was later replaced by R18). Proven by
  `TypedInteractionTests.testIdleSleepNeverBlocksAndResumeGreetsOnce`,
  `testSystemWakeClearsTheSleepBlockAndSaysItIsBack` and `testScreenOffPausesAutonomousWorkAndSpeech`.
- **Spoken commands never matched.** Whisper ends transcripts with "." or "?", so "What do you
  remember?", "Copy that.", "List voices." went to the model. Command phrases drop trailing punctuation;
  the memory list now also shows the R5 key points. Proven by
  `TypedInteractionTests.testSpokenCommandsIgnoreWhisperPunctuation` and the guardrail "memory list
  includes core facts and R5 key points".
- **Non-speech became turns.** `[BLANK_AUDIO]`, `[SOUND]`, `[coughs]`, `[MUSIC PLAYING]` are stripped.
  Proven by `SpokenTranscriptTests.testWhisperNonSpeechAnnotationsAreNotATurn` and
  `testRealSpeechSurvivesAroundAnnotations`.
- **Double questions.** The `ask_user` question is no longer spoken after content that already asked
  one. Proven by `SpokenQuestionTests.testToolQuestionIsNotAppendedAfterTheAnswerAlreadyAsked` and
  `testToolQuestionIsSpokenWhenTheAnswerAskedNothing`.
- **"I can't hear you."** The system prompt now says the owner talks by voice and replies are spoken.
  Proven by `EngineIntegrationTests.testProductionChatRequestAndFragmentedFinalQuestionContract` and
  the guardrail "Dot knows it is heard and never forces a question".
- **R7 gap.** Model-chosen `delete_file` and automatic destructive file commands now pass the safety
  approver before running (they ran unchecked before). Proven by the guardrail "model file mutations
  pass the R16 safety approver first"; the native approver decision itself still needs the owner's
  real session.
- **Log noise.** One `[HEALTH]` line per real change (was 4 to 8 per turn, `engine=unknown` when ready),
  "Context extraction skipped" is logged as SYSTEM not DOT, repeated `[ROAM] skip` reasons are logged
  once, and the `[SYNC] pushed` line no longer makes the log sync re-upload itself every five minutes.
  Proven by the guardrail "log noise is bounded and labelled honestly", and the offline log-sync
  contracts in `Tests/Python/test_offline_runtime_contract.py`.

## Resolved: uncommitted work in the tree (2026-10-18)

Resolved by 2026-10-20: no call site of `MemoryTierStore(directory:)` remains in `src/` or `Tests/`.
Kept as history. At the time this note was written, the working tree contains an **uncommitted, in-progress
refactor** by another worker:
- `MemoryTierStore.init(facts:)` (MS-1) and related `LocalFTSStore` busy-timeout/step logging,
  web-research changes, stricter `package_public_release.sh`/`verify_macos.sh` scripts.
- `ChatView` and `MemoryTierTests` still call `MemoryTierStore(directory:)`, so **`swift test` does not
  currently compile** until that refactor is finished. This broken state is **not** in the published
  release and was not committed by the documentation pass.
- Do not revert or overwrite these files. Coordinate with the other worker, finish the initializer
  call sites, then run the full gates and `install_local.sh`.
- The public downloads are now **`v1.1.1`** (Latest): ad-hoc signed, not notarised,
  installed through `scripts/install-dot.sh`. Its release workflow drafts the release and
  publishes only after the one-line install, quarantined-DMG and `spctl` jobs are green.
  The older `public-f6cc73d` was Apple Development signed on Emin's Mac, which is why it
  opened there; `scripts/build-and-sign-on-mac.sh` reproduces that owner-only path.
  Developer ID notarisation remains required for a no-warning double-click anywhere.

## Current build and gates

- Release **`v1.1.3`** (published 2026-10-22, run `39858375138`, commit `6224aa3`): `Dot.dmg` **793,384,448 bytes**, SHA-256 `831c5a0ffb03db35dd783aab47fb920c23a8fa8cb0328caf8f7901f652c88b20`. It carries R18 to R21 and the public-log privacy fixes. Every release gate passed: install, quarantine, `spctl`/`codesign` and the no-trace lane. Release **`v1.1.4`** (run `39949028372`, commit `265abd6`) adds the audit fixes F1 to F10 and D1 to D6; check that run, and when it is green record its DMG here.
- Phase 7b release **`v1.1.1`** (Latest) is owner-testable from one Terminal line:
  `curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash`.
  It keeps the 25 model parts on `model-parts-v1` and records the three acceptance
  jobs in [PHASE7B_RESULT.md](PHASE7B_RESULT.md); `v1.1.0` evidence stays in
  [PHASE7_RESULT.md](PHASE7_RESULT.md).
- Branch **main only**; the Pi checkout is `/home/emin/dev/Dot`. Run `git log -1` and
  `scripts/install_local.sh`; the installed app's `build-provenance.json` must equal that HEAD.
  The Phase 6 tag **`v1.1.0-phase5`** points at **`88ab9fb`**, the exact commit whose full CI run
  was green. The Phase 4 tag stays at `69ecfbd`; neither tag was moved.
- Final Phase 6 green macOS gate (CI run `39636742798`, commit `88ab9fb`, all four jobs):
  **XCTest 945 / 0 failures / 1 skipped**, **Python 648 / 4 skipped**, **76 static guardrails**,
  the eight focused suites, `dot-voice`, SwiftPM and Debug/Release builds. The `macos` job was
  cancelled once while queued and completed green on a rerun (run attempt 2 re-ran all
  four jobs). The hosted
  runtime-finalizer canary is still a by-design failure; `verify_macos.sh` records it and skips
  hosted packaging, while every independent Swift/Xcode/Python check continues.
- Pi gates on the Phase A tree: Python **645 OK / 28 skipped**, **76 contracts**, and the four
  Rust gates pass. Details and exact commands: [PHASE6_RESULT.md](PHASE6_RESULT.md).
- Phase 6 public release **`v1.1.0-phase5`** was built by release run `39642486991`:
  `Dot.dmg` **1,007,296,565 bytes**, SHA-256
  `8d76e6aebc92b0b8a962359efead6b00211ecd4bc47c49435a21b523019a590a`. The downloaded asset
  matches the published `.sha256` exactly. It contains the audited runtime, **no model weights**
  (`models_bundled: false`), and the manifest-verified first-launch downloader. It is ad-hoc signed,
  **not notarised** (no Developer ID Application identity or notary credentials).
- Phase 4 release **`v1.1.0-phase4`** remains at `69ecfbd` with `Dot.dmg` 1,005,188,103 bytes,
  SHA-256 `dc9561facbf2fbafb91531a79b4d09c95250c5abaa18c47b33e34ab7794978c6`.
- The 22,420,071,166-byte model is published as 25 parts on `model-parts-v1` and pinned in
  `Resources/model-parts.json` (CI run `39661861719`); the app uses those parts first.
  The end-to-end 22.4 GB download on a minimum-spec Mac is the owner's first step in
  [TEST_TODAY.md](TEST_TODAY.md); the downloader's hash/reuse/resume units are tested.
  After the download, core conversation/voice/memory reuse local files and require no network;
  see [PHASE4_RESULT.md](PHASE4_RESULT.md) and [offline acceptance](offline-acceptance.md).
- The complete all-in-one DMG still needs owner acceptance and a 22 GB build
  (`QUESTIONS_FOR_EMIN.md` §9). The default DMG plus the published model parts is the
  supported install today.

## What genuinely works

- **Voice/typed conversation**, 5-minute listening cap with a spoken cap notice, sleep re-arm,
  screen-off/lock pause, video silence, follow-up listening after a genuine final question (retries
  transient readiness for 8 s; direct spoken-question fallback).
- **Mic mode**: reads macOS Standard/Voice Isolation/Wide Spectrum, shows it in the menu, offers the
  system selector, nudges once. macOS has **no public setter**; the owner chooses Wide Spectrum.
- **Memory**: five tiers, single SQLite owner, 5–10 key points per conversation into T3, full transcript
  archive in FTS, explicit “remember…” preferences in core, voice-only recall/forget.
- **Files**: read a named text file (Spotlight suggestion on miss), Spotlight name/content search,
  autonomous simple file utilities and `delete_file`. Inside the folder chosen in Tools & History,
  rm, rmdir, mkdir, touch, mv, cp and trash run in-process (2026-10-22); ln, tee, truncate, echo,
  printf, cat and `find -delete` run in the sandboxed shell, which reaches only Dot's container. The
  chosen folder is kept in memory only and must be chosen again after a relaunch; shells/sudo/substitutions and non-file destructive
  commands still card. Recent-file proactive awareness (Desktop/Documents/Downloads, names only).
- **Placement/clicks**: full window bounds protected, no overlapping fallback target, swept-path checks
  for trips and the two-minute roam, immediate coverage escape after the short rest, captured-display
  OCR coordinates, exact-label matching, raise-window-before-click.
- **Calendar**: briefs, create event, edit a named upcoming event (new start/duration), move next
  meeting — all mutations through the confirmation card.
- **Proactive/research/UI**: bounded adaptive screen watching; DDG + Wikipedia + Google News + 6-hour
  result cache; cold-start progress/prewarm; battery alerts; trusted-app allowlist; calendar/battery/
  timer/screen/video/sleep features; Diagnostics in Application Support.
- **Public app path**: README Download/DMG instructions, `scripts/package_public_release.sh`
  (DMG+zip), first-launch `ModelProvisioner`, `scripts/publish_public_release.sh`, and
  `scripts/store_github_token.sh` for persistent Keychain release auth.

## Partial or bounded

- **R7 depth**: recent-file awareness, no full-disk index, iCloud placeholders, relevance ranking or
  content-semantic search.
- **R8 depth**: 32×24 fingerprints + final OCR; no per-frame/video understanding.
- **R10**: news/cache/providers above; **no offline encyclopedia snapshot or local research index**.
- **R13**: edit by title for start/duration; renaming, recurring series and past events are not exposed.
- **Clicking**: requires Accessibility + Screen Recording; icon-only controls rely on the AX fallback.
- **A5**: fixed (visible text-only-model notice); OCR/page-reading still limited to available text.

## Missing / not built

- **R9 self-healing** (runtime snapshots, self-test, automatic rollback, Rust watcher) — none.
- **R4 voice picker** — only `bf_isabella.pt` ships; blocked on the payload decision.
- **B8** dead-code deletions (~540 audited lines).
- **Splash supervisor port slices 2–5** in `crates/dot-runtime`; supervisor/TLS still Python.
- **Public release**: notarisation, licence closure, clean second-Mac acceptance (the asset upload is done).
- **Owner acceptance session after the latest changes** (the only unautomated proof).

## Decisions needed before those can finish

1. **R4**: keep the payload fixed (defer the picker) or explicitly approve adding
   `bf_emma.pt`/`bf_alice.pt` (a payload revision).
2. **R9**: recommended writable plugin/config layer + snapshots/self-test/rollback + Rust watchdog
   (compatible with the signed bundle); alternative is an unsigned self-modifying build that breaks the
   notarised release.
3. **Notarisation**: requires a Developer ID Application certificate and App Store Connect notary
   credentials; the current Mac has only an Apple Development identity.

## Suggested next order

1. Owner acceptance session on a Mac at or above the gate: install the Phase 4 DMG → first-launch
   model download → voice with Emma, sleep/wake (R18 greeting, roaming resumes), "What do you
   remember?", one proactive comment without a forced question, then the broader checklist
   (follow-up, cap, file op, calendar card, video silence, screen-off pause, battery/timer).
2. Store the log token and confirm one queued upload; verify offline startup with the network disabled
   and the model already present.
3. R9 decision and implementation (plugin layer + watchdog).
4. R4 decision.
5. Upload the verified model parts and produce the complete all-in-one parts (owner Mac).
6. Supervisor slices 2–5; R10 local index/offline snapshot; full-disk index; B8.
7. Notarisation, licence closure, second-Mac acceptance, final docs truth pass.

## Commands (verified in this environment)

```bash
# typecheck
xcrun swiftc -typecheck -target arm64-apple-macosx15.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-name DotProbe src/*.swift

# focused XCTest (replace Suite)
DOT_TEST_PYTHON=/private/tmp/dot-py313/bin/python xcodebuild -project Dot.xcodeproj \
  -scheme Dot -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/dot-full-dd CODE_SIGNING_ALLOWED=NO \
  test -only-testing:DotTests/Suite

# full lanes
DOT_TEST_PYTHON=/private/tmp/dot-py313/bin/python xcodebuild -project Dot.xcodeproj \
  -scheme Dot -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/dot-full-dd CODE_SIGNING_ALLOWED=NO test
swift test --disable-sandbox --scratch-path /private/tmp/dot-swiftpm-N \
  --cache-path /private/tmp/dot-swiftpm-N-c --config-path /private/tmp/dot-swiftpm-N-cfg \
  --security-path /private/tmp/dot-swiftpm-N-sec
/private/tmp/dot-py313/bin/python -B scripts/check_contracts.py

# install (must be run after every commit; provenance must match HEAD)
bash scripts/install_local.sh

# public DMG/zip (requires an existing complete app at ~/Applications/Dot.app)
bash scripts/package_public_release.sh
bash scripts/store_github_token.sh          # one time, Keychain
bash scripts/publish_public_release.sh      # stable release + Dot.dmg/Dot.zip

# release gate; expected failure is only the by-design finalizer canary
PATH=/private/tmp/dot-py313/bin:$PATH bash scripts/verify_macos.sh
```

## Environment traps

- `python3` is 3.9 on the owner Mac; use `/private/tmp/dot-py313/bin/python`.
- On the Linux Pi, the Python suite assumes a 022 umask and a disk-backed TMPDIR. Run it as
  `(umask 022; TMPDIR=$PWD/.tmp/pytmp python3 -B -m unittest discover -s Tests/Python -v)`;
  `/tmp` is a 768 MB tmpfs and the runtime-reconstruction fixtures reserve 1 GB of scratch space,
  and a group-writable checkout is correctly rejected as an unsafe runtime mode.
- Checkout is cloud-synced: use `/private/tmp` scratch paths and `xattr -cr` before codesign.
- Re-signing resets TCC: install with `scripts/install_local.sh` (stable Apple Development identity).
- Never weaken `startupSeconds` (10 s) or `PlacementSnapshot.lifetime` (10 s); guard tests exist.
- Main only; never force-push or create branches. Inspect `git status`/HEAD before committing.
- The opt-in live model test runs only when `/private/tmp/dot-live-model-test` exists or
  `DOT_LIVE_MODEL_TEST=1`; it is skipped in the normal lane.
- Timer/search tests can flake under heavy load or a locked display; rerun isolated before treating as
  a regression (they pass alone and in a clean full lane).
- The runtime-finalizer canary is a mandated failure on hosted toolchains; do not remove it. The
  warning gates are unfiltered: every warning line is fatal, and if the AppKit test-process QoS
  advisory recurs, record the exact line with a dated removal condition — never a blanket class filter.

## Where things live

- `src/ChatView.swift`: turn pipeline, speech/voice gates, proactive ticker, memory summary, screen watch,
  follow-up wiring, screen-off pause.
- `src/InteractionCore.swift`: shared policy/tools (clicks, calendar, memory helpers, video/mic mode,
  file insight, placement geometry, etc.).
- `src/Engine.swift`: system prompt and tool schemas.
- `src/App.swift`: menus, window/display notifications, movement/placement application.
- `src/RoamingCore.swift` + `src/PlacementCapture.swift`: placement map and movement policy.
- `src/OfflinePreparation.swift`: payload/model verification, `ModelProvisioner` downloader.
- `src/VoiceTiming.swift`, `src/Speech.swift`, `src/VoiceFollowup.swift`: listening/follow-up.
- `src/MemoryTiers.swift`, `src/LocalFTSStore.swift`: memory tiers + single SQLite connection.
- `scripts/`: install, verification, public DMG/zip, release publishing, token storage.

## Data layout under Application Support

All durable Dot state lives under `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/` (mode 0700), never `~/Downloads`
(which a notarised/sandboxed build cannot write):

- `Dot/Soul/` — soul archives: compaction snapshots and the export/import targets (`DotSoulManager`).
- `Dot/Logs/dot_chat_log.txt` — the conversation log every turn writes (`DiagnosticChatLogger`),
  rotated at 2 MB to `dot_chat_log.1.txt`; migrated once from the old Downloads location. The
  10-minute self-reflection reads only this file.
- `Dot/.screen_permission_configured` — marker that the Screen Recording prompt was *offered*, never
  evidence of a grant; the re-ask-after-denial guard clears it while access is still ungranted.
- `Dot/Models/` — the first-launch `ModelProvisioner` download target for the manifest-verified weights.
- The self-reflections file (`dot_self_reflections.txt`) is being relocated from `~/Downloads` under
  this root by the reflections batch; until that lands, no section of this file pins its old location.

## Recent commits (newest first)

Phase 6: `88ab9fb` always open history + final green commit · `559294b` TLS fixture ceiling ·
`0eaf419` history test seed · `f9edbda` Phase 6 docs/gates · `e69135a` macOS 26 real-launch lane ·
`fc0fd1a` lane invocation fix · `7e397c4` real-launch workflow · `697ed73` review docs ·
`fe3aaba` scripts review fixes · `aa4c642` Swift review fixes.
Phase 5: `cc2cd7c` status pointer · `dfb2011` green run · `d5cc583` fresh review fixes · `9bff09c`
Phase 5 findings · `dd091cd` review fixes.
Phase 4: `96d67f1` release evidence · `69ecfbd` Phase 4 result/checklists · `7e5c6b5` safety/memory
guardrails · `c7c4ca6` focused suites + offline contracts · `4916071` Phase 3 result. Earlier:
`f03d608` Keychain release auth · `a6fe2eb` public DMG packaging · `8afab50` screen-off/lock pause ·
`e0fb2a7` visible text-only notice + named calendar edit · `398cb5f` immediate coverage escape ·
`b0cc3aa` safe path for the 2-minute roam/random relocation · `fca8e7f` placement/click accuracy ·
`951b939` answer-length prompt · `e31a466` mic-mode guidance · `9425744` downloader timeout ·
`df272ec` first-launch model provisioning/DMG path · `5d94e19` follow-up listening fix.
