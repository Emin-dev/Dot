# Phase 6 result — multi-model review, real launch, gates and release

**Status 2026-10-21:** Phase A, the real-launch lane, Phase C and the Phase D
release are complete. The released DMG is ad-hoc signed and **not** notarised;
the model and all-in-one parts remain owner-gated.

## Phase A — multi-model review

Three independent read-only sessions covered the whole product source. The
model-by-model table, evidence, fixed findings and accepted residuals are in
[REVIEW_FINDINGS.md](REVIEW_FINDINGS.md#phase-6-multi-model-review-2026-10-21).

| Model | Findings | Result |
| --- | --- | --- |
| `opencode-go/deepseek-v4.1-flash` | 3 | all verified and fixed (proactive phase trap, interpreter approval bypass, stale direct replies) |
| `opencode-go/qwen3.8-flash` | 5 | 3 fixed, 1 fixed on the client side with a server-side residual, 1 accepted residual (`security` argv) |
| `opencode-go/qwen3.8-max` | 0 final | partial only: its 20-minute bound expired mid-review; no claim was counted |

A targeted re-review of the fixes found two further issues (show-history gate
advance; launcher/assignment interpreter bypass) which were fixed before the
Phase A commits. Fixes: `aa4c642`, `fe3aaba`; docs: `697ed73`.

## Phase B — real GitHub build and real app launch

Workflow: [`.github/workflows/real-app-check.yml`](../.github/workflows/real-app-check.yml)
(`workflow_dispatch` only). It builds the real default bundle from source with
the pinned donor runtime (`DONOR_URL` + `DONOR_SHA256` from `release.yml`) via
`scripts/package_default_release.sh`, then launches
`build/Dot.app/Contents/MacOS/Dot` through `scripts/real_app_launch_check.sh`.

- Run: [`39628139773`](https://github.com/Emin-dev/Dot/actions/runs/39628139773), **success**, commit `e69135a`.
- Runner: arm64 `macos-26`, **macOS 26.6.2**, Apple M1 (Virtual), 7 GB RAM.
- Result: the app started, wrote
  `~/Library/Application Support/Dot/Logs/dot_chat_log.txt`, and showed the
  exact below-minimum refusal:
  `Hardware Does Not Meet Dot's Minimum: Dot needs Apple Silicon M5 Pro class or newer, 48 GB Unified Memory and macOS 27.0 or newer. The exact Qwen3.8 27B Q4 model runs locally and has no smaller fallback, so Dot cannot start on this Mac.`
  The log also lists all three unmet reasons (M1, 7 GB, macOS 26.6.2) and the
  blocking alert was terminated only after the evidence was captured
  (exit 143, `alive_until_terminated=1`).
- Artifact: `dot-real-app-launch-evidence` (launch transcript, console,
  `dot_chat_log.txt`, state file listing). Local copy:
  `.tmp/phase6/real-app/` (not committed).

What this proves: the same kind of source-built, donor-runtime, model-less app
bundle the public DMG ships can start on a real macOS arm64 runner; the hardware
gate is reachable before any model/screen/mic work; it refuses with the exact
documented text and leaves durable state.

What this does **not** prove: no model download or inference, no microphone,
screen, voice or memory session, no successful conversation, no notarisation, no
Gatekeeper-clean install, and no owner acceptance. A hosted runner is below the
product minimum by design; this lane proves the refusal, not the product.

An earlier `macos-15` attempt (`39624942444`) failed honestly with
`Library not loaded: /usr/lib/swift/libswift_DarwinFoundation1.dylib` because
the app's deployment floor is macOS 26.4. The lane was moved to `macos-26`; the
script still reports that dyld case as `UNSUPPORTED` and exits non-zero, so a
future runner mismatch cannot be silently green.

## Phase C — gates

Pi gates run serially on the final Phase A tree:

| Gate | Command | Result |
| --- | --- | --- |
| Python | `umask 0022; TMPDIR=$PWD/.tmp/pytmp python3 -B -m unittest discover -s Tests/Python -v` | **645 tests OK, 28 skipped** |
| Static contracts | `python3 -B scripts/check_contracts.py` | **76 passed** |
| Rust format | `CARGO_BUILD_JOBS=2 cargo fmt --all -- --check` | pass |
| Rust check | `CARGO_BUILD_JOBS=2 cargo check -p dot-research -p dot-runtime` | pass |
| Rust test | `CARGO_BUILD_JOBS=2 cargo test -p dot-research -p dot-runtime` | pass (18 tests) |
| Rust clippy | `CARGO_BUILD_JOBS=2 cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings` | pass |

CI run `39628138310` at `e69135a` was green in `rust-gates`, `swift-test` and
`dot-voice`, and failed the `macos` lane only on the known timing-sensitive
`test_authenticated_tls_backpressure_keeps_total_send_deadline`. The fixture
eventually sent 32 MiB and waits at least 15 s (bounded below by 15 s and above
by the reported queue capacity) for a production send to exhaust its absolute
budget; the deadline assertions themselves are unchanged. A second
failure exposed that typed/voice `show history` reset `answer` before dispatch,
so the panel never opened; that product bug is fixed and covered by
`testShowHistoryConfirmationSurvivesThePanelGateAdvance`.

Final CI run [`39636742798`](https://github.com/Emin-dev/Dot/actions/runs/39636742798)
at `88ab9fb` is **green in all four jobs**: `rust-gates`, `swift-test`, `macos`,
`dot-voice`. The `macos` lane ran **945 XCTest / 0 failures / 1 skipped**,
**648 Python tests / 4 skipped**, **76 static guardrails**, zero warnings and
the Debug/Release packaging checks. The `macos` job was initially cancelled
while queued on the hosted runner; a rerun (run attempt 2) re-ran all four jobs
and finished green.

## Phase D — release

- Tag: **`v1.1.0-phase5`** at **`88ab9fbece7730ed2369143b83f7eaa32d83b8e7`**
  (the exact green CI commit; the Phase 4 tag was not moved or reused).
- Release: <https://github.com/Emin-dev/Dot/releases/tag/v1.1.0-phase5>
- Release run: [`39642486991`](https://github.com/Emin-dev/Dot/actions/runs/39642486991), **success**.
- Assets present: `Dot.dmg`, `Dot.dmg.sha256`, `join-dot-dmg.command`,
  `join_release.py`, `README.txt`.
- `Dot.dmg` size: **1,007,296,565 bytes**.
- Published `.sha256`: `8d76e6aebc92b0b8a962359efead6b00211ecd4bc47c49435a21b523019a590a`.
- Downloaded the published `Dot.dmg` from the release and computed
  `8d76e6aebc92b0b8a962359efead6b00211ecd4bc47c49435a21b523019a590a`; it matches
  the published `.sha256` exactly. The release README has no digest field; the
  published `.sha256` asset is the release's digest record. The GitHub API returned
  `digest: null` for these assets, so the byte-level `shasum -a 256` check is the
  authoritative verification.
- The DMG is the default model-less bundle: audited runtime included,
  `models_bundled: false`, first-launch manifest-verified Qwen3.8 27B Q4 download.
  It is **ad-hoc signed and not notarised**; the pinned model parts and all-in-one
  parts are still **not uploaded** at this tag. The installed-app acceptance remains
  owner-only.

## Remaining owner-only gates

- Install the DMG on a Mac at or above the minimum and run the real acceptance
  session (voice with Emma, sleep/wake, memory recall, file action, calendar
  card, video silence, screen-off pause, battery/timer).
- The full 19.9 GB first-launch model download on the owner's Mac; the pinned
  parts and all-in-one parts are not uploaded.
- Developer ID Application certificate and notarisation; the DMG is ad-hoc
  signed and **not** notarised.
- Store the log-upload token in Keychain and confirm one real upload.
- Observe the real safety-approver verdicts and the `"force it"` flow.
