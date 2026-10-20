# Dot — working rules

Dot is a local, offline-first macOS AI companion: Swift/AppKit app + Rust crates
(`dot-research`, `dot-voice`, `dot-runtime`, `dot-safety`).

## Goal

Make every promise in `README.md`, `docs/AI_HANDOFF.md`, `docs/BUILD_CHECKLIST.md` and
`docs/GOAL_STATUS.md` actually work and be tested. No new features except the logging system.

## Owner rules

- Main is the only kept branch. Never delete branches; never `git push --force`.
- Never create keys, tokens or accounts. The log-upload token comes from Emin; read it from
  Keychain/config and ask in `docs/QUESTIONS_FOR_EMIN.md`.
- Logs: full conversation text and app/system events; no images. Screenshots only as anonymized
  OCR/description with personal details masked. Never log keys, tokens or passwords.
- Auto-upload to `Emin-dev/Dot` on a dedicated logs branch under
  `dot/<install-id>/<launch-timestamp-UTC>/`; stable anonymous install id; offline queue, retries
  with backoff, bounded rotation.
- Model is exactly Qwen3.8 27B Q4 on Splash — no smaller fallback. Minimum hardware: Apple
  Silicon M5 Pro class, 48 GB RAM, macOS 27+, checked at launch with a clear message.
- Update docs/notes/tests at least every 5 hours. Write findings to files, not chat.

## Build and test

```bash
# Rust (Pi: keep jobs at 2)
CARGO_BUILD_JOBS=2 cargo fmt --all -- --check
CARGO_BUILD_JOBS=2 cargo check -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo test -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings

# Python and static contracts (model-free)
python3 -B -m unittest discover -s Tests/Python -v
python3 -B scripts/check_contracts.py
```

`dot-voice` needs macOS `fullfp16`; Swift/macOS builds, DMGs and XCTest run only in GitHub
Actions macOS runners (`gh run list`, `gh run view --log-failed`). Use `CARGO_BUILD_JOBS=2` on
the Pi. Use repo-local `.tmp/` instead of `/tmp`.

## Quality gate

For each change, run parallel reviewer and tester subagents (plus a CI watcher when CI is
relevant) before committing. Commit small; push normally to main.
