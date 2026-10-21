# Changelog

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
- Docs/tests: 69 static guardrails, a new review-pipeline test file run in CI,
  Swift redaction tests, and corrected resume/repair and provenance claims.

Pi gates: 628 Python tests OK (28 skipped), 18 Rust tests, clippy
`-D warnings`, 69 contracts. macOS CI run `39541375214` at `2f0f79b` passed all
four jobs (rust-gates, swift-test, macos, dot-voice).

## Earlier

The Phase 4 record is in [docs/PHASE4_RESULT.md](docs/PHASE4_RESULT.md); the
live project status is [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md).
