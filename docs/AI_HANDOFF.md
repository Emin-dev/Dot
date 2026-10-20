# Dot — AI continuation handoff (2026-10-18)

**Read this first.** This is the current, evidence-based state for any AI developer continuing Dot.
The binding owner rules are in [DEV_TEAM_PROMPT.md](DEV_TEAM_PROMPT.md) (R1–R15). Where this file and an
older document disagree, this file and `DEV_TEAM_PROMPT.md` win. `HANDOVER.md`, `CONTINUATION.md` and
`BUILD_CHECKLIST.md` contain history that is partly superseded; their top notes point here.

## Fixes from the owner's real log (2026-10-20)

Found by reading `dots/macbook16-m5-pro-48gb-mac17-8/logs/dot_chat_log.txt`. Source and tests changed;
the Swift build and XCTest lanes were **not run** (Linux session, no Swift toolchain). Static guardrails
53/53 and the Python suite (604, 2 IPv6-only errors that also fail on the untouched tree) were run.

- **Voice was dead for every voice except Isabella.** `VoiceEvent.parse` required `bf_isabella` in the
  `hello` event while the default is `bf_emma`, so every turn ended in "Unsupported Bionic voice
  protocol". Any of the four British voices is now accepted; a missing voice file falls back to the
  always-bundled Isabella with a log line (`DotVoice`).
- **Stuck after sleep.** An idle sleep blocked Dot with "Listening stopped when your Mac went to sleep";
  the wake greeting then refused to speak and the block stayed, so idle roaming was vetoed for hours
  (`[ROAM] skip: phase=blocked`). Idle sleep no longer blocks, wake clears a sleep block, and both wake
  paths share one "I'm back."
- **Spoken commands never matched.** Whisper ends transcripts with "." or "?", so "What do you
  remember?", "Copy that.", "List voices." went to the model. Command phrases drop trailing punctuation;
  the memory list now also shows the R5 key points.
- **Non-speech became turns.** `[BLANK_AUDIO]`, `[SOUND]`, `[coughs]`, `[MUSIC PLAYING]` are stripped.
- **Double questions.** The `ask_user` question is no longer spoken after content that already asked one.
- **"I can't hear you."** The system prompt now says the owner talks by voice and replies are spoken.
- **R7 gap.** Model-chosen `delete_file` and automatic destructive file commands now pass the safety
  approver before running (they ran unchecked before).
- **Log noise.** One `[HEALTH]` line per real change (was 4 to 8 per turn, `engine=unknown` when ready),
  "Context extraction skipped" is logged as SYSTEM not DOT, repeated `[ROAM] skip` reasons are logged
  once, and the `[SYNC] pushed` line no longer makes the log sync re-upload itself every five minutes.

## ⚠️ Uncommitted work in the tree (2026-10-18)

At the time this handoff was written, the working tree contains an **uncommitted, in-progress
refactor** by another worker:
- `MemoryTierStore.init(facts:)` (MS-1) and related `LocalFTSStore` busy-timeout/step logging,
  web-research changes, stricter `package_public_release.sh`/`verify_macos.sh` scripts.
- `ChatView` and `MemoryTierTests` still call `MemoryTierStore(directory:)`, so **`swift test` does not
  currently compile** until that refactor is finished. This broken state is **not** in the published
  release and was not committed by the documentation pass.
- Do not revert or overwrite these files. Coordinate with the other worker, finish the initializer
  call sites, then run the full gates and `install_local.sh`.
- The published `Dot.dmg`/`Dot.zip` were built before this refactor, with an **Apple Development**
  signature. The in-progress packaging script now refuses Apple Development for public distribution;
  notarisation with a Developer ID remains required for a proper release.

## Current build and gates

- Repo: `/Users/mac/Documents/deepseek-harness/default-workspace/Dot`, branch **main only**.
- App source last changed at **`8afab50`** (screen-off/lock pause); `f03d608` added release scripts;
  later commits are docs. Run `git log -1` and `scripts/install_local.sh`; the installed app's
  `build-provenance.json` must equal that HEAD. Do not assume an older installed provenance from any
  document.
- Last full green automated gate: **XCTest 904 / 0 failures (1 opt-in live test skipped)**,
  **`swift test` 580 / 0**, **Python 604 passed / 4 skipped**, **53 static guardrails**, Debug + Release
  builds. The full `verify_macos.sh` run at `e0fb2a7` was clean apart from its **by-design
  runtime-finalizer canary**; rerun it after the latest placement/screen-off changes (the full XCTest
  and SwiftPM lanes are green, but the complete script has not been rerun since `8afab50`).
- Public package **published** as GitHub release **`public-f6cc73d`** (latest, non-prerelease):
  `Dot.dmg` (~1.0 GB) and `Dot.zip` (~785 MB) plus SHA-256 files. Remote GitHub asset digests match
  the local SHA-256 exactly. The assets were built at app-source `850fa98` (same binary as `f6cc73d`);
  the README latest-download links resolve. They contain the runtime, no `OfflineModels`, and the
  manifest-verified downloader. The build is **Apple Development signed, not notarised** (no Developer
  ID Application identity or notary credentials on this Mac).
- The full 19.9 GB first-launch model download has **not** been run end to end; a gated live test
  downloaded and SHA-verified one real file from Hugging Face through the same code path.

## What genuinely works

- **Voice/typed conversation**, 5-minute listening cap with a spoken cap notice, sleep re-arm,
  screen-off/lock pause, video silence, follow-up listening after a genuine final question (retries
  transient readiness for 8 s; direct spoken-question fallback).
- **Mic mode**: reads macOS Standard/Voice Isolation/Wide Spectrum, shows it in the menu, offers the
  system selector, nudges once. macOS has **no public setter**; the owner chooses Wide Spectrum.
- **Memory**: five tiers, single SQLite owner, 5–10 key points per conversation into T3, full transcript
  archive in FTS, explicit “remember…” preferences in core, voice-only recall/forget.
- **Files**: read a named text file (Spotlight suggestion on miss), Spotlight name/content search,
  autonomous simple file utilities (rm/mv/cp/touch/mkdir/ln/trash/echo/printf/cat/tee/truncate, `find
  -delete` without `-exec`) and `delete_file`; shells/sudo/substitutions and non-file destructive
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

1. Clean-Mac test of the published release: download `Dot.dmg` → drag to Applications → first-launch
   20 GB model download → voice turn.
2. Owner acceptance session: voice, follow-up, cap, file op, calendar card, video silence, screen-off
   pause, screen watching, battery/timer.
3. R9 decision and implementation (plugin layer + watchdog).
4. R4 decision.
5. Supervisor slices 2–5; R10 local index/offline snapshot; full-disk index; B8.
6. Notarisation, licence closure, second-Mac acceptance, final docs truth pass.

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

- `python3` is 3.9; use `/private/tmp/dot-py313/bin/python`.
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

All durable Dot state lives under `~/Library/Application Support/Dot/` (mode 0700), never `~/Downloads`
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

`f03d608` Keychain release auth · `a6fe2eb` public DMG packaging · `8afab50` screen-off/lock pause ·
`e0fb2a7` visible text-only notice + named calendar edit · `398cb5f` immediate coverage escape ·
`b0cc3aa` safe path for the 2-minute roam/random relocation · `fca8e7f` placement/click accuracy ·
`951b939` answer-length prompt · `e31a466` mic-mode guidance · `9425744` downloader timeout ·
`df272ec` first-launch model provisioning/DMG path · `5d94e19` follow-up listening fix.
