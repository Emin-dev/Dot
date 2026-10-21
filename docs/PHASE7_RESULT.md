# Phase 7 result — Emin can test everything today

**Status 2026-10-22:** release **`v1.1.0`** is Latest and owner-testable. The model
parts are published by CI, the quarantined first open is verified, and the exact
owner test is [TEST_TODAY.md](TEST_TODAY.md). The only owner-only steps left are
Developer ID notarisation (paid Apple account), the log-upload token, and running
TEST_TODAY.md on a minimum-spec Mac.

## M1 — review findings fixed

All five findings in `~/dev/agent/reviews/selftest-20261021-2153.md` were fixed and
re-read in the diff:

1. `GOAL_STATUS.md` now records P6-1…P6-6 fixed, P6-7 fixed on the client, and
   P6-8/P6-9 as the two accepted residuals.
2. The re-review is three findings across two fix areas (GOAL_STATUS and
   REVIEW_FINDINGS).
3. `CHANGELOG.md` records the fixture hardening 2 MiB → 16 MiB → 32 MiB at `559294b`.
4. `PHASE6_RESULT.md` says the fixture waits at least 15 s, not up to 15 s.
5. The macOS `macos` job was completed by a full rerun (attempt 2, all four jobs),
   stated in AI_HANDOFF and PHASE6_RESULT.

## M2 — model delivery without Emin

`.github/workflows/model-parts.yml` (`workflow_dispatch`, `contents: write`,
built-in `GITHUB_TOKEN`, no secret) runs
[`scripts/fetch_model_parts.py`](../scripts/fetch_model_parts.py). It:

- streams one manifest file at a time (peak disk ~ largest file, 5.4 GB),
- verifies every file against `Resources/bundled-models.json` (22,420,071,166 bytes),
- re-hashes every part after writing, all below 2 GB,
- uploads 25 parts plus `model-parts.json`, `.sha256` and `model-parts.sha256`,
- refuses to replace an existing parts release and only deletes a partial release
  it created (a published manifest marks the set complete).

Evidence, run [`39661861719`](https://github.com/Emin-dev/Dot/actions/runs/39661861719),
**success**:

- Release `model-parts-v1`, not Latest, 28 assets, 25 of them model parts.
- Total part bytes **22,420,071,166**, maximum part **1,900,000,000**.
- Manifest SHA-256 `3f355155ab45df5f359b69a3cbeb9389de244acf8d63329d2b6cd93b6d8ba765`;
  the published `.sha256` matches the downloaded manifest.
- `Resources/model-parts.json` is committed `ready`, so the app's primary route is
  the pinned parts; the revision-pinned Hugging Face files remain the hash-checked
  fallback.

The all-in-one 22 GB DMG parts are still not published. The default DMG plus the
published model parts is the supported install today; the app does not need the
all-in-one parts.

## M3 — fresh-Mac first open

- `scripts/quarantine_launch_check.sh` mounts `Dot.dmg`, installs `Dot.app` to a
  fresh Applications directory, writes `com.apple.quarantine`, then runs
  `real_app_launch_check.sh` with `DOT_REQUIRE_QUARANTINE=1` and
  `DOT_MINIMUM_ALIVE_SECONDS=60`.
- `real_app_launch_check.sh` fails if the attribute is missing, measures the alive
  window, and fails if the app dies before the minimum.
- `release.yml` and `real-app-check.yml` run the check. The release job moved to
  `macos-26` because the app deployment floor is macOS 26.4; on `macos-15` the
  bundle cannot load.
- Release run [`39668810492`](https://github.com/Emin-dev/Dot/actions/runs/39668810492)
  shows **✓ Install from the DMG with quarantine and stay alive for 60 s**.
- `README.txt`, `docs/TEST_TODAY.md` and `join-dot-dmg.command` explain the real
  first open: right-click > Open, System Settings > Privacy & Security > Open
  Anyway, or `xattr -dr com.apple.quarantine /Applications/Dot.app`.

Limit, stated honestly: a hosted runner cannot click the Gatekeeper dialog, so CI
launches the executable directly with the quarantine attribute present. The dialog
interaction itself is the owner's step 2 in TEST_TODAY.md. Developer ID signing and
notarisation remain owner-only (paid Apple Developer account).

## M4 — owner test script

[docs/TEST_TODAY.md](TEST_TODAY.md) has nine numbered sections with a pass line
each and a final checklist: download/SHA, install/first open, 22.4 GB model,
voice, Wi-Fi-off turn, screen context, `force it`, logs, done. A contract test
(`Tests/Python/test_phase7_contract.py`) asserts the commands, asset names and
required phrases stay present.

## M5 — one gate run

Commit `349fd8c`, CI run
[`39668799150`](https://github.com/Emin-dev/Dot/actions/runs/39668799150),
**success in all four jobs**: `rust-gates`, `swift-test`, `dot-voice`, `macos`.

Pi gates on the same tree:

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check` | pass |
| `cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings` | pass |
| `cargo test -p dot-research -p dot-runtime` | pass (18 tests) |
| Python `unittest discover -s Tests/Python` | **656 OK / 28 skipped** |
| `scripts/check_contracts.py` | **76/76** |

New tests: `Tests/Python/test_model_parts_fetch.py` (stream split, pinned hash
rejection, unknown prefix, repository URL mapping) and
`Tests/Python/test_phase7_contract.py`.

## M6 — release v1.1.0

- Release: <https://github.com/Emin-dev/Dot/releases/tag/v1.1.0> (**Latest**).
- Release run: [`39668810492`](https://github.com/Emin-dev/Dot/actions/runs/39668810492),
  **success**, commit `349fd8c`.
- `Dot.dmg`: **793,382,400 bytes**, SHA-256
  `273c724bdfbdbc2dba9ec34edf48d4e09104e0ff2d62d9162db493d01f31e4f3`.
  The downloaded asset matches the published `Dot.dmg.sha256`.
- Assets: `Dot.dmg`, `Dot.dmg.sha256`, `model-parts.json`,
  `model-parts.json.sha256`, `TEST_TODAY.md`, `join-dot-dmg.command`,
  `join_release.py`, `README.txt`. The 25 model part assets are on the linked,
  immutable `model-parts-v1` release.
- Release notes are the content of `TEST_TODAY.md`.
- The DMG bundles the published plan (`model_primary: pinned Emin-dev/Dot release
  parts`) and **no weights** (`models_bundled: false`).
- Known provenance detail: v1.1.0 was built while the just-published
  `model-parts.json` was copied into `Resources/`, so its
  `build-provenance.json` has `source_dirty: true`. The exact source commit is
  still recorded. The plan is committed from the accompanying docs commit onward,
  so the next release builds with `source_dirty: false`. This only affects the
  in-app "view source" panel, not launch, model download, voice or safety.

## What is verified and what still needs Emin

Verified in CI or on the Pi:

- model parts downloaded from the official public repositories, SHA-256 checked,
  split and published;
- the app bundle built from source with the audited runtime, ad-hoc signed, DMG
  checksummed;
- DMG installed with quarantine and alive for 60 s;
- Rust/Python/static gates, model-free Swift tests and the full macOS lane;
- the exact owner instructions and their commands.

Still owner-only (one run of [TEST_TODAY.md](TEST_TODAY.md) covers 1–3):

1. the real 22.4 GB first download and a successful conversation/voice turn on a
   Mac at or above the minimum;
2. the Wi-Fi-off turn, screen context and the live three-refusal `force it` flow;
3. confirming the log folder/upload;
4. Developer ID signing + notarisation with Emin's paid Apple Developer account.
