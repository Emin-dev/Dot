# Phase 3 result — CI and release (2026-10-20)

## Outcome

Phase 3 is complete for everything that can be built and published without the owner's
private payload or Apple Developer credentials. The public CI is green and a release is
published.

- **CI run** [`39499667589`](https://github.com/Emin-dev/Dot/actions/runs/39499667589) on
  `main@8189a28`: `rust-gates`, `swift-test`, `dot-voice` and the full `macos` lane all
  **succeeded**.
- **Release** [`v1.1.0-phase3.1`](https://github.com/Emin-dev/Dot/releases/tag/v1.1.0-phase3.1) (supersedes `v1.1.0-phase3`):
  `Dot.dmg` (1,011,993,151 bytes), `Dot.dmg.sha256`, `join-dot-dmg.command`,
  `join_release.py`, `README.txt`.
  `Dot.dmg` SHA-256: `207676a4a9c562f387c4428a0bf67edc3775c47d3d91a3ee4352f78b234bdbda`.

## What the release contains

The default DMG is built from the current source and contains the audited runtime but
**no model weights** (`models_bundled: false`, `llm_weights_download_on_first_launch: true`).
The external runtime payload is reused from the previously published, SHA-256-pinned
`public-f6cc73d` app; the donor hash is verified before extraction and its model payload
is never copied.

First launch downloads the exact manifest files:

1. **Primary:** pinned `<2 GB` split parts from the `Emin-dev/Dot` release, with per-part
   SHA-256, persisted URLSession resume data plus HTTP Range resume, bounded retries with
   backoff and automatic repair.
2. **Fallback:** revision-pinned Hugging Face files (target, draft and aux Gemma) only when
   the same signed SHA-256 matches `Resources/bundled-models.json`.

Disk space is checked before download (including the largest staging part), every file is
re-verified on every launch, and progress is visible in Dot's menu and status text. The app still refuses to launch below
Apple Silicon M5 Pro class, 48 GB Unified Memory or macOS 27; CI uses the macOS 15 runner
with the Xcode 26 SDK, which is the honest SDK/build floor.

## All-in-one installer

`split_release.py`, `join_release.py`, `join-dot-dmg.command` and
`package_all_in_one.sh` produce and verify `<2 GiB` parts with per-part and whole-file
SHA-256. The joiner downloads missing parts, verifies them, joins the DMG, verifies it
and opens it.

The complete DMG is not published yet: producing its parts requires the 22.4 GB verified
model payload on the owner's Mac. That is the only missing input; the commands are ready
in `docs/QUESTIONS_FOR_EMIN.md` §8–10.

## Verification

| Gate | Result |
|---|---|
| `cargo fmt --all -- --check` | pass |
| `cargo test -p dot-research -p dot-runtime` | 18 pass, 0 fail |
| `cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings` | pass |
| `python3 -B -m unittest Tests/Python/test_release_parts.py` | 4 pass |
| `python3 -B scripts/check_contracts.py` | 56/56 |
| macOS CI `swift-test` | pass (Xcode 26.3 SDK) |
| macOS CI `dot-voice` | build + 2 protocol tests pass |
| macOS CI full `verify_macos.sh` | independent stages pass; the hosted runtime-finalizer canary is recorded as the known hosted-toolchain limitation and hosted packaging is skipped |
| Release workflow | pass; donor SHA verified, contracts run, DMG packaged and published |

`dot-voice` cannot be built on the Pi (`instruction requires: fullfp16`), which is why it
runs only on arm64 macOS.

## Honest limitations / owner gates

1. **Model parts** are not uploaded; the app currently uses the hash-checked Hugging Face
   fallback. `Resources/model-parts.json` is `pending`.
2. **All-in-one parts** are not uploaded; the owner must run `package_all_in_one.sh` after
   native acceptance.
3. **Signing/notarization:** the published DMG is ad-hoc signed and not notarized. A
   Gatekeeper-clean public build needs Emin's Developer ID identity and notarization
   credentials. The release notes say this rather than claiming otherwise.
4. The hosted runtime-finalizer canary still fails by design; `verify_macos.sh` records it
   and continues the independent Swift/Xcode checks on GitHub-hosted runners. It remains
   mandatory for a local complete packaging run.

See `docs/QUESTIONS_FOR_EMIN.md` §8–10 for the exact owner steps.
