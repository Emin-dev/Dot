# Changelog

## 2026-10-22 — Public-log privacy fixes and promise audit

- Typed text, clipboard text, screen text, command credentials, e-mail addresses, home-folder names
  and card-length numbers no longer reach the public `dot-logs` branch; every log line is capped.
- Failed file/model checks, voice failures in typed turns and refused launches are logged as
  `dot (error)` and uploaded (R19). The Keychain token is read once per launch.
- Promise audit with every finding and its status: [docs/AUDIT_2026-10-22.md](docs/AUDIT_2026-10-22.md).
- CI: the TLS total-deadline test no longer measures its own sleeps; an OS proxy database is
  allowlisted in the no-trace lane. Static guardrails: 103.

## 2026-10-22 — Owner decisions R18 to R21 and code-reading fixes

- Decision log for every AI and developer: [docs/OWNER_DECISIONS.md](docs/OWNER_DECISIONS.md)
  quotes each owner question and answer, the code it changed and the test that proves it.
- R18: the wake greeting picks a random 3 to 10 minute threshold per sleep, greets 80% of the
  time with a warm, time-aware line that never repeats a recent one. "I'm back." is gone.
- R19: an error no longer freezes Dot. Idle motion, roaming and the idle face continue, a large
  red banner above Dot shows the error, every error is logged for upload, and engine errors
  retry at 15, 45 and 120 s.
- R20: the idle self-reflection says one short sentence and never touches the clipboard.
- R21: narrow sandbox exceptions (read-only Downloads, Desktop, Documents; Apple Events to
  System Events, Safari, Chrome, TextEdit, Music, Spotify) so the documented page reading, dark
  mode, sleep, media pause and new-file awareness work under the App Sandbox.
- Fixes: offline relaunch no longer demands free space for a model already on disk; display
  sleep keeps the first download going; the safety approver runs a 2,048-token context with a
  bounded request and treats harness errors as "unavailable"; automatic file utilities pass the
  approver; scoped file operations parse `--`, flag clusters, relative paths and `~` correctly;
  spoken commands ignore Whisper's final period; a spoken approve or deny ends the listening turn
  first; the voice picker lists installed voices only; log metadata is queued before a token
  exists; "Remove Dot completely" always leaves the command and says what happened.
- Static guardrails: 99 (was 76).

## 2026-10-22 — Phase 7s: sandboxed, per-user, leave no trace

- Apple App Sandbox is now on for every packaging path: minimal entitlements,
  hardened runtime, nested runtime binaries and whisper signed first, and a
  read-back check for `com.apple.security.app-sandbox`. All app data, the model,
  logs, settings and caches live in `~/Library/Containers/app.dot.local/`.
- Install is per-user in `~/Applications`; never `/Applications`, never sudo,
  no LaunchAgents/login items/background items/profiles/PATH edits. The
  installer clears quarantine only on Dot's staged bundle and prints the exact
  macOS/Gatekeeper text on refusal.
- Added `scripts/uninstall-dot.sh` and the in-app **Remove Dot completely…**
  item. Both remove the app, container, group containers, caches, saved state,
  HTTP/WebKit data, preferences, model and legacy data, reset TCC with
  `tccutil reset All app.dot.local`, and end with
  `PASS: your Mac is back to how it was` or a precise `FAIL:`.
- Added `.github/workflows/privacy-clean.yml`: hosted macOS snapshot → install →
  sandbox/kernel proof → smoke test → uninstall → snapshot → empty diff with a
  documented Apple-transient allowlist. `release.yml` now requires this lane
  before publishing.
- Sandbox compatibility: Splash and `dot-fetch` avoid nested `sandbox-exec`
  under the app container; user-selected simple file utilities run in-process;
  `UserFolderScope` keeps shell/safety targets inside the selected folder.
- Hosted proof: release run `39716661710` published **v1.1.2** with every job
  green; final no-trace `39722187295` and native `39722187386` are green at
  `de14804`.
- Phase result: [docs/PHASE7S_RESULT.md](docs/PHASE7S_RESULT.md).

## 2026-10-22 — Phase 7b: Gatekeeper one-line install

- Root cause: `public-f6cc73d` opened on Emin's Mac because it was Apple
  Development signed on that Mac; the CI releases since 21 Oct are ad-hoc signed,
  so Gatekeeper rejects them and macOS 27 does not offer right-click > Open.
- Added `scripts/install-dot.sh`, published in the repo and as a release asset.
  The first line of `README.txt`, `docs/TEST_TODAY.md` and the release notes is
  now `curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash`.
  The script downloads every published part with curl (no quarantine), verifies
  every SHA-256, joins split parts, mounts the DMG, copies Dot to `/Applications`,
  clears `com.apple.quarantine`, verifies the ad-hoc signature deeply, detaches
  and opens Dot. It is idempotent and prints PASS/FAIL.
- Added `scripts/build-and-sign-on-mac.sh`: builds locally, signs with the first
  `Apple Development` identity from `security find-identity -v -p codesigning`
  (ad-hoc fallback), installs to `/Applications` and opens Dot.
- Release workflow now creates a **draft**, runs three independent macOS jobs
  (curl | bash + 60 s alive, quarantined DMG + 60 s alive, `spctl --assess -vv`
  plus `codesign --verify --deep --strict`), and publishes only when all three
  are green. `spctl` records `rejected` as expected until notarisation.
- Release **`v1.1.1`** (Latest, run `39685174351`, commit `b765892`): `Dot.dmg`
  **793,667,072 bytes**, SHA-256
  `0a409a17626a0d8897d574c67d9cd631b23a14d9eb20d75d45fd44e36104c61a`.
  Assets also include `install-dot.sh`, `build-and-sign-on-mac.sh`,
  `Dot.dmg.sha256`, `README.txt`, `TEST_TODAY.md`, the joiner and the parts plan.
  A no-warning double-click still requires Developer ID notarisation
  (owner-only). Details: [docs/PHASE7B_RESULT.md](docs/PHASE7B_RESULT.md).

## 2026-10-22 — Phase 7: Emin can test today

- Model delivery is owner-free: `Publish model parts` (run `39661861719`) fetched the
  pinned Qwen3.8 27B Q4 payload, verified all **22,420,071,166 bytes** against
  `Resources/bundled-models.json`, split it into **25 parts below 2 GB** and published
  the `model-parts-v1` release (manifest SHA-256
  `3f355155ab45df5f359b69a3cbeb9389de244acf8d63329d2b6cd93b6d8ba765`). The plan in
  `Resources/model-parts.json` is now `ready`; the app uses those parts first and keeps
  Hugging Face as the hash-checked fallback.
- First open from the DMG is proven in CI: the release job runs on macOS 26, installs
  the DMG with `com.apple.quarantine`, and requires the app to stay alive for 60 s.
  README and `join-dot-dmg.command` explain right-click > Open (and the `xattr`
  command). Ad-hoc signing stays; notarisation remains the only owner-only signing step.
- `docs/TEST_TODAY.md` is the exact owner test script: download/verify, install, 22.4 GB
  model, voice, offline, screen, `force it`, logs and a pass checklist.
- Gates: Python **656 / 28 skipped**, **76 contracts**, Rust fmt/clippy/test pass. CI
  `39668799150` at `349fd8c` is green in all four jobs.
- Release **`v1.1.0`** (Latest): `Dot.dmg` **793,382,400 bytes**, SHA-256
  `273c724bdfbdbc2dba9ec34edf48d4e09104e0ff2d62d9162db493d01f31e4f3`; assets also
  include `Dot.dmg.sha256`, `model-parts.json` + `.sha256`, `TEST_TODAY.md`, the joiner
  and README. The DMG is ad-hoc signed and not notarised. Its provenance records
  `source_dirty: true` because the just-published parts plan was bundled at release
  time; that plan is committed from this changelog commit onward, so the next build is
  clean. Owner remaining: notarisation, log token, and the real-Mac run in TEST_TODAY.md.

## 2026-10-21 — Phase 6 real-launch lane and gates

- Added `.github/workflows/real-app-check.yml` (dispatch only): it builds the
  same donor-runtime, model-less bundle as the public DMG and launches the real
  `Dot.app` executable on arm64 macOS. Run `39628139773` on macOS 26.6.2 observed
  the exact below-minimum refusal (`M5 Pro class / 48 GB / macOS 27+`, no smaller
  model fallback) and the durable launch log. A macOS 15 runner cannot load the
  macOS 26.4 binary; that case is reported as `UNSUPPORTED`, not green.
- Hardened the timing-sensitive TLS backpressure fixture (2 MiB → 16 MiB) after
  CI run `39628138310` failed to saturate a fast Darwin receive buffer; a second
  hardening at `559294b` raised it to 32 MiB with a ≥15 s wait bound. The
  absolute-deadline assertions are unchanged.
- Pi gates: 645 Python tests OK (28 skipped), 76 contracts, Rust fmt/check/test/
  clippy pass. Final CI run `39636742798` at `88ab9fb` is green: 945 XCTest /
  1 skipped, 648 Python / 4 skipped, 76 contracts.
- Released **`v1.1.0-phase5`** at `88ab9fb` (run `39642486991`): `Dot.dmg`
  1,007,296,565 bytes, SHA-256
  `8d76e6aebc92b0b8a962359efead6b00211ecd4bc47c49435a21b523019a590a`; the
  downloaded asset matches the published `.sha256`. Ad-hoc signed, not
  notarised, no model weights; model/all-in-one parts remain owner-gated.

## 2026-10-21 — Phase 6 multi-model review fixes

Three independent read-only reviews (deepseek-v4.1-flash, qwen3.8-flash,
qwen3.8-max) covered the whole product source. Verified fixes:

- Proactive fallback: the tip is spoken after resetting the turn to idle instead
  of being silently dropped while `.thinking`, which had vetoed proactive work.
- Safety: interpreter executors (`python3`, `osascript`, `perl`, `ruby`, `node`,
  `env`) now require the approval/safety path; `env python3 -c` cannot bypass it.
- Direct replies: stale detached file-read/forget/memory-list results cannot
  overwrite a newer turn, while "show history" now always opens the panel and
  uses the new turn after the panel advances the gate (a typed/voice command
  resets the visible answer before dispatch, so the old empty-answer check made
  the command a no-op).
- Safety follow-up: leading assignments and launchers (`FOO=1 python3`,
  `nohup`, `command`, `nice`, `xcrun`, `env -u`) cannot hide an interpreter;
  `echo env python3` stays harmless.
- Installer: the existing payload is cloned before the voice/aux fetch, so an
  upgrade with a runtime-only previous app keeps the fetched files.
- Publishing: the GitHub token is passed through a `curl --config -` pipe, never
  argv; model parts are re-hashed after writing; the double-click joiner refuses
  multiple part manifests.
- Residuals recorded: stale remote part assets on a deliberate renamed re-split
  (operator cleanup; client is now safe) and the existing owner-run `security`
  argv token step.

Details and the model-by-model table are in
[docs/REVIEW_FINDINGS.md](docs/REVIEW_FINDINGS.md).

## 2026-10-21 — Phase 5 independent review fixes

Verified by independent reviewers and fixed (details in
[docs/REVIEW_FINDINGS.md](docs/REVIEW_FINDINGS.md)):

- Safety: the model-less default DMG's approver now finds the downloaded Gemma
  model; `"force it"` requires three refusals of the same action, expires after
  120 seconds, matches only that exact action, and resets strikes.
- Logging/privacy: uploads re-mask legacy bytes; Basic auth, env-style keys,
  JSON keys and PGP/PEM private keys are masked; non-UTF-8 uploads are dropped;
  the manual uploader uses the same redactor and refuses non-log branches.
- Downloader: split-part transfers cancel with the task; launch metadata is
  retried after a disk-write failure.
- Release/supply chain: no `--clobber`, releases must come from main, tags must
  match the built commit, new tags are pinned to it, and the all-in-one joiner
  rejects path traversal and foreign part URLs.
- Docs/tests: 76 static guardrails, a new review-pipeline test file run in CI,
  Swift redaction tests, and corrected resume/repair and provenance claims.
- Fresh independent round (deepseek + qwen3.8-flash/max): JWT short/JWE
  redaction, hourly retry of exhausted log uploads with legacy-queue migration,
  executable `ForceOverridePolicy` tests, no silent split/join overwrite,
  whole-part-set cleanup on a forced or renamed re-split, and GitHub-only
  download redirects.

Pi gates: 636 Python tests OK (28 skipped), 18 Rust tests, clippy
`-D warnings`, 76 contracts. macOS CI run `39554065822` at `dfb2011` (source `d5cc583`) passed all
four jobs (rust-gates, swift-test, macos, dot-voice): SwiftPM 616, full XCTest
944 (1 skipped), Python 636.

## Earlier

The Phase 4 record is in [docs/PHASE4_RESULT.md](docs/PHASE4_RESULT.md); the
live project status is [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md).
