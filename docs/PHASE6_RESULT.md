# Phase 6 result — multi-model review, real launch, gates and release

**Status 2026-10-21:** Phase A and the real-launch lane are complete. Phase C is
being finished on the gate-fix commit; the Phase D release is recorded at the
bottom when it exists.

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
sent 2 MiB, which a fast Darwin receive buffer could absorb without ever
saturating a production send; it now sends 16 MiB and still asserts the same
absolute-deadline condition. The final green CI run is recorded at the top of
[AI_HANDOFF.md](AI_HANDOFF.md) and in the release record below.

## Phase D — release

Pending at the time this file was first committed. The tag is created only at
the commit whose full CI run is green; this section is updated with the tag
commit, release URL, asset list, DMG size and the downloaded SHA-256 check.

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
