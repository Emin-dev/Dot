# How to continue Dot

Current state and evidence: [docs/PHASE7_RESULT.md](docs/PHASE7_RESULT.md),
[docs/GOAL_STATUS.md](docs/GOAL_STATUS.md) and
[docs/AI_HANDOFF.md](docs/AI_HANDOFF.md). Working rules: [AGENTS.md](AGENTS.md).
The owner test script is [docs/TEST_TODAY.md](docs/TEST_TODAY.md).

## Start here

1. `git switch main && git pull --ff-only`
2. Read `AGENTS.md`, `docs/AI_HANDOFF.md`, `docs/PHASE7_RESULT.md` and the newest
   file in `~/dev/agent/reviews/`. Do not re-read unchanged files.
3. Code model only: `opencode-go/deepseek-v4.1-flash`. Swift, `dot-voice`, the
   DMG and notarisation run only on GitHub Actions macOS.

## Current state (2026-10-22)

- Release **`v1.1.0`** is Latest: `Dot.dmg` 793,382,400 bytes, SHA-256
  `273c724bdfbdbc2dba9ec34edf48d4e09104e0ff2d62d9162db493d01f31e4f3`.
- Model parts are published by CI on `model-parts-v1`: 25 parts,
  22,420,071,166 bytes, manifest SHA-256 `3f355155…8ba765`.
  `Resources/model-parts.json` is committed as `ready`.
- First open from the quarantined DMG is verified for 60 s in the release job.
- Remaining owner-only: notarisation (paid Apple account), log-upload token,
  and the real-Mac run in `docs/TEST_TODAY.md`.

## Commands that change the release

```bash
# 1. Publish/refresh the model parts (no secret; refuses to replace an existing tag)
gh workflow run model-parts.yml --ref main -f tag=model-parts-v1

# 2. Build and publish a release at current main (tag must not exist yet)
gh workflow run release.yml --ref main -f tag=v1.1.0

# 3. Prove the quarantined first open independently
gh workflow run real-app-check.yml --ref main
```

Watch with `gh run watch <id> --exit-status` (blocking). Never delete a published
part set or overwrite a release asset; re-split under a new tag instead.

## Local gates (Pi / Linux)

```bash
CARGO_BUILD_JOBS=2 cargo fmt --all -- --check
CARGO_BUILD_JOBS=2 cargo check -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo test -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings

umask 0022
TMPDIR=$PWD/.tmp/pytmp python3 -B -m unittest discover -s Tests/Python -v
python3 -B scripts/check_contracts.py
```

Expected: **656 Python tests OK / 28 skipped**, **76/76 guardrails**, 18 Rust
tests, clippy clean. Full Python takes ~3 minutes; run it as a background job.

## CI

```bash
gh run list --branch main --limit 5
gh run view <run-id> --log-failed
```

A red CI run is a blocker. `ci.yml` is the gate; `release.yml` also runs the
quarantined first-open check on macOS 26, and `model-parts.yml` streams the
model. Final Phase 7 green run: `39668799150` at `349fd8c`.

## Rules that must not be weakened

- No smaller model or fallback; Qwen3.8 27B Q4 on Splash only.
- Minimum M5 Pro class, 48 GB RAM, macOS 27+; no override.
- Logs are text only, no images; never log keys, tokens or passwords; uploads go
  to the dedicated `dot-logs` branch under `dot/<install-id>/<launch-timestamp-UTC>/`.
- Only `main` is kept. Never delete branches, never force-push, never create
  keys/tokens/accounts.
- Never replace published release assets; a fresh tag or a deliberate owner
  decision is required.
