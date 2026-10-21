# How to continue Dot

Current source of truth: [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md). Phase 6
review results and gates: [docs/REVIEW_FINDINGS.md](docs/REVIEW_FINDINGS.md) and
[docs/PHASE6_RESULT.md](docs/PHASE6_RESULT.md). Working rules: [AGENTS.md](AGENTS.md).

## Start here

1. `git switch main && git pull --ff-only`
2. Read `AGENTS.md`, `docs/AI_HANDOFF.md`, `docs/REVIEW_FINDINGS.md` and the
   phase result files. Do not re-read unchanged files.
3. Code model only: `opencode-go/deepseek-v4.1-flash`. Swift, `dot-voice`, the
   DMG and notarisation run only on GitHub Actions macOS.
4. Before committing, launch `reviewer` and `tester` subagents in parallel (plus
   `ci-watcher` when CI matters), fix their findings, then commit small.

## Local gates (Pi / Linux)

```bash
# Rust: at most two builds at once, jobs at 2
CARGO_BUILD_JOBS=2 cargo fmt --all -- --check
CARGO_BUILD_JOBS=2 cargo check -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo test -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings

# Python: /tmp is a small tmpfs here, so point TMPDIR at the repo and keep a
# predictable umask (the runtime reconstruction fixtures reject group-writable
# directories).
umask 0022
TMPDIR=$PWD/.tmp/pytmp python3 -B -m unittest discover -s Tests/Python -v
python3 -B scripts/check_contracts.py
```

Expected current result: 645 Python tests OK (28 skipped), 18 Rust tests,
clippy clean, 76 static guardrails. The full Python suite takes about 2–3
minutes on this Pi; run it as a background job and poll it.

## CI

```bash
gh run list --branch main --limit 5
gh run view <run-id> --log-failed
```

A red CI run is a blocker. The Swift/XCTest, focused-suite, `dot-voice` and DMG
lanes are authoritative for macOS-only behaviour.

## Remaining owner-only gates

- Upload the verified model parts and the all-in-one DMG parts (the plan is
  `pending`; the Hugging Face hash-checked fallback is active).
- Developer ID signing + notarisation for a Gatekeeper-clean public DMG.
- Store the log-upload token in Keychain and run a real end-to-end upload.
- Run a real disconnected Mac install and the full 19.9 GB first download.
- Observe live safety-approver verdicts and the `"force it"` flow, and accept
  the real voice/screen/sleep behaviour. Automated tests cover source order and
  gating, not the hardware session.

## Rules that must not be weakened

- No smaller model or fallback; Qwen3.8 27B Q4 on Splash only.
- Minimum M5 Pro class, 48 GB RAM, macOS 27+; no override.
- Logs are text only, no images; never log keys, tokens or passwords; uploads go
  to the dedicated logs branch under `dot/<install-id>/<launch-timestamp-UTC>/`.
- Only `main` is kept. Never delete branches. Never force-push.
- Never create keys, tokens, accounts or branch rules.
