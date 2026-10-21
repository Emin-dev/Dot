# Changelog

## 2026-10-21 — Phase 6 multi-model review fixes

Three independent read-only reviews (deepseek-v4.1-flash, qwen3.8-flash,
qwen3.8-max) covered the whole product source. Verified fixes:

- Proactive fallback: the tip is spoken after resetting the turn to idle instead
  of being silently dropped while `.thinking`, which had vetoed proactive work.
- Safety: interpreter executors (`python3`, `osascript`, `perl`, `ruby`, `node`,
  `env`) now require the approval/safety path; `env python3 -c` cannot bypass it.
- Direct replies: stale detached file-read/forget/memory-list results cannot
  overwrite a newer turn, while the show-history confirmation uses the new turn
  after the panel advances the gate.
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
