# Dot — Goal status & completion evidence (2026-10-19)

This file is the evidence record for the active goal. Every line below was verified
by actually running the gate, not by assumption.

## Phase 7 — Emin can test everything today (2026-10-22)

- **Model parts are public and owner-free.** `Publish model parts` run `39661861719`
  fetched the pinned payload, verified **22,420,071,166 bytes** against
  `Resources/bundled-models.json`, and published **25 parts (<2 GB)** plus the plan to
  release `model-parts-v1`. Manifest SHA-256
  `3f355155ab45df5f359b69a3cbeb9389de244acf8d63329d2b6cd93b6d8ba765`; all 25 part
  assets exist. `Resources/model-parts.json` is `ready`.
- **First open is verified in CI.** Release run `39668810492` installed `Dot.dmg` with
  `com.apple.quarantine` on macOS 26 and required the app to stay alive 60 s. The DMG is
  ad-hoc signed; Developer ID notarisation remains owner-only.
- **Owner test script:** [TEST_TODAY.md](TEST_TODAY.md) — download/verify, install/first
  open, 22.4 GB model, voice, offline, screen, `force it`, logs and pass criteria.
- Pi gates: Python **656 OK / 28 skipped**, **76 contracts**, Rust fmt/clippy/test pass.
  CI run `39668799150` at `349fd8c` is green in all four jobs.
- Release **`v1.1.0`** (Latest): `Dot.dmg` **793,382,400 bytes**, SHA-256
  `273c724bdfbdbc2dba9ec34edf48d4e09104e0ff2d62d9162db493d01f31e4f3`; assets include
  the checksum, `model-parts.json` + `.sha256`, `TEST_TODAY.md`, joiner and README.
  Evidence: [PHASE7_RESULT.md](PHASE7_RESULT.md).
- Still owner-only: install/acceptance on a minimum-spec Mac, the 22.4 GB first download,
  notarisation, the log token, and the live safety-approver session.

## Phase 6 — multi-model review, real launch and gates (2026-10-21)

- Three independent read-only reviews covered the whole product source
  (`deepseek-v4.1-flash`, `qwen3.8-flash`, `qwen3.8-max`). Nine findings were
  verified: P6-1…P6-6 fixed with regression coverage; P6-7 fixed on the client;
  P6-8 and P6-9 recorded as accepted residuals (stale remote part assets after a
  renamed re-split; owner-run `security` argv token); three re-review findings
  across two fix areas were also fixed. Details in
  [REVIEW_FINDINGS.md](REVIEW_FINDINGS.md#phase-6-multi-model-review-2026-10-21).
  `qwen3.8-max` hit its time bound with no final findings and is recorded as partial.
- The real-launch lane [`.github/workflows/real-app-check.yml`](../.github/workflows/real-app-check.yml)
  built the actual donor-runtime app via `scripts/package_default_release.sh` and
  launched it on arm64 macOS 26.6.2. Run `39628139773` observed the exact
  below-minimum refusal and the launch log; it does not prove a successful
  conversation, model download, voice/screen/mic, notarisation or owner acceptance.
- Pi gates: Python **645 OK / 28 skipped**, **76 contracts**, Rust fmt/check/test/
  clippy pass. Final CI run `39636742798` at `88ab9fb` is green in all four jobs:
  **945 XCTest / 0 failures / 1 skipped**, **648 Python / 4 skipped**, 76 contracts.
- Release **`v1.1.0-phase5`** at `88ab9fb` (release run `39642486991`):
  `Dot.dmg` **1,007,296,565 bytes**, SHA-256
  `8d76e6aebc92b0b8a962359efead6b00211ecd4bc47c49435a21b523019a590a`; the
  downloaded asset matches the published `.sha256`. Ad-hoc signed, **not
  notarised**, no model weights; model parts were still owner-gated at that tag. Evidence:
  [PHASE6_RESULT.md](PHASE6_RESULT.md).
- Still owner-only: install/acceptance on a minimum-spec Mac, the full 19.9 GB
  model download, notarisation, the log token and the real safety-approval session.

## Objective code items — status

| Item | State | Evidence |
|---|---|---|
| In-app automatic GitHub log sync | ✅ (source) / token pending | `DotLogSync` writes `dot/<install-id>/<launch>/` to the dedicated `dot-logs` branch with an offline queue and backoff; the owner must store the token (see `QUESTIONS_FOR_EMIN.md`). `main` is PR-protected. |
| R1 five-minute listening | ✅ | `VoiceCaptureDeadline.maximumDuration = 300.0`; recognizer bounds 301 s; spoken cap notice; VoiceTimingTests 37/0 |
| R14 battery/charging alerts | ✅ | policy + settings + idle-tick monitor + spoken configuration commands; BatteryAlertTests 3/0 |
| R11 cold-start progress + prewarm | ✅ | live stage messages follow `onReadinessStage`; `prewarm at login` / `stop prewarming` commands; off by default |
| Placement refresh-before-validate | ✅ | caller asks `needsRefresh` before `current`; 0 `reason=expired` rejections in the live log; RoamingTests 16/0 |
| Dead code | ✅ | audited backlog cleared (`recentConversations`, `forgetMatching`, `recordVoice` gone; `TypedInteractionStatus` wired) |
| R5 memory key-points + announcement | ✅ | 20 s lull → LLM key points → keyPoints tier; announcement speaks after each capture |
| R7 supervised autonomy + R16 approver | ✅ | `dot-safety` (llama.cpp + Metal, Gemma-3-4B Q4) ships; live verdicts: rename→YES, `rm -rf ~/`→NO, `ls`→YES; gate fails closed; 3-strikes → owner "force it" override |
| R15 trusted-app allowlist | ✅ | contextual cards unless trusted; menu toggle; empty by default |
| R10 keyless metasearch | ✅ | DuckDuckGo + Google News + Wikipedia + arXiv, live-verified; Mojeek/Marginalia blocked automation (documented) |

## Phase 3 — CI and release (2026-10-20)

- `ci.yml` now runs four independent jobs: Rust gates on Ubuntu, `swift build`/`swift test`
  with the Xcode 26 SDK, `dot-voice` build + protocol tests on arm64 macOS, and the
  full `verify_macos.sh` lane. Run `39493996358` on `main@d0c7662` is green in all four.
- Voice tests that used arbitrary absolute host times are now deterministic on a
  freshly booted runner; coordinator waits no longer assume a 4-second budget.
- Release [`v1.1.0-phase3.1`](https://github.com/Emin-dev/Dot/releases/tag/v1.1.0-phase3.1)
  publishes `Dot.dmg` (1,011,993,151 bytes, SHA-256 `207676a4…bdbda`), its checksum, the joiner
  and a README. `release.yml` packages the **default model-less DMG** from current source: it downloads
  the previously published audited runtime donor (`public-f6cc73d`, SHA-256 pinned),
  strips model weights, and re-signs. It refuses to ship `OfflineModels`.
- Model delivery: `Resources/model-parts.json` is `ready`; the CI workflow publishes the
  pinned parts to `model-parts-v1` and the app uses them first, with revision-pinned
  Hugging Face files as the hash-checked fallback. Retries/backoff, HTTP Range resume,
  per-part SHA-256, per-launch repair and disk checks are implemented.
- All-in-one: `split_release.py`, `join_release.py`, `join-dot-dmg.command` and
  `package_all_in_one.sh` produce/verify/join <2 GiB parts. The all-in-one DMG still
  needs owner acceptance before it can be built; the model parts no longer do.
- `verify_macos.sh` still records the hosted runtime-finalizer canary as a known
  hosted-toolchain limitation and skips packaging; the release job uses the pinned donor
  runtime instead of pretending that canary passed.

## Verification evidence (last full runs)

- Phase 7 CI run `39668799150` at `349fd8c`: `rust-gates`, `swift-test`, `dot-voice`
  and `macos` all **green**.
- Pi gates: Python **656 tests / 28 skipped**, **76/76 static guardrails**, Rust
  fmt/clippy/test pass (`dot-research` + `dot-runtime`; `dot-voice` builds only on macOS).
- First-open proof: release run `39668810492` installed `Dot.dmg` with
  `com.apple.quarantine` and the app stayed alive for 60 s.
- Model parts: 25 assets, 22,420,071,166 bytes, manifest SHA-256
  `3f355155…8ba765`; `gh release view model-parts-v1` lists every part.

## Remaining — all owner-gated (no code path exists without these)

1. **The goal's done-condition** — run [TEST_TODAY.md](TEST_TODAY.md) on a Mac at or
   above the minimum: 22.4 GB model download, voice, Wi-Fi-off turn, screen context
   and the `force it` flow.
2. **Phase D** — Developer ID Application certificate + notarisation requires the
   owner's paid Apple Developer account (`SIGN_IDENTITY` for
   `scripts/package_public_release.sh`). Ad-hoc signing works; this only removes the
   Gatekeeper warning.
3. **Log upload** — store the token in Keychain and confirm one real upload.
4. **R4 voice choice** — four Kokoro British-female samples are available; the owner
   picks the winner, or requests the Chatterbox/Orpheus evaluation.
