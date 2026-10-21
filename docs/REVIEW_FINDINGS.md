# Phase 5 independent review — findings and verified fixes

**Status 2026-10-21 — CI green.** Final commit `d5cc583`; run
[`39552385832`](https://github.com/Emin-dev/Dot/actions/runs/39552385832) passed
all four jobs (rust-gates, swift-test, macos, dot-voice): SwiftPM **616 / 0**,
full XCTest **944 / 0 with 1 skipped** (opt-in live model test), Python **636**
on the Pi and **636 / 4 skipped** on macOS. The earlier `9bff09c` attempt had a
stale expectation (`[REDACTED]` vs `[REDACTED_ENV]`) and one flaky
TLS-backpressure test; both were resolved before this run.

Scope: the diff from merge base `0aeb7fd`
(`claude/app-dot-behavior-faax19`) to main, plus the live checklists. Reviews ran
in fresh processes/read-only sessions; this file keeps only findings that were
verified by code, a test, or a run.

## Short summary

Verified and fixed in this phase:

1. The model-less default DMG's safety approver could never find the downloaded
   Gemma aux model, so every safety-gated file/shell action failed closed.
2. Uploads could publish legacy log bytes without re-applying redaction, and
   several common credential formats (Basic auth, env-style keys, JSON keys, PGP
   blocks) were not masked.
3. The split-part downloader ignored task cancellation, so pause/retry/shutdown
   could wait on a network transfer for up to 24 h.
4. The `"force it"` safety override could be armed without three refusals and
   could be re-armed forever; it now requires three refusals of the exact
   action, expires after 120 seconds, and is one-shot.
5. The release workflow could overwrite published assets, build from an off-main
   tag, or create a tag at a newer main commit than the built artifact.
6. The all-in-one joiner trusted part names/URLs from the manifest (path
   traversal, foreign host).
7. The manual log script could push to `main` via an environment override, and
   its multiline PEM rule was a no-op.
8. Launch metadata could be permanently suppressed by one disk-write failure.
9. `model_primary` provenance claimed the pinned parts route while the parts plan
   is still `pending`.
10. JWT-shaped tokens were not masked by either redactor.
11. An exhausted log upload was parked for a year; stable logs now retry at the
   1 h backoff cap.
12. The safety override policy is now executable in DotCore and covered by
   XCTest (exact action, expiry, one-shot, strike reset).
13. The splitter and joiner now refuse silent overwrite (unless `--force`), the
   splitter re-hashes each written part, and downloads may only redirect to
   GitHub release hosting.

Remaining owner-only gates (not code review findings):

- Upload the verified 22.4 GB model payload and produce the all-in-one parts.
- Developer ID signing + notarisation for a Gatekeeper-clean public DMG.
- Supply the log-upload token via Keychain and run a real end-to-end upload.
- Run a real disconnected Mac install (launch, voice turn, memory, screen
  capture with the network physically off) and the full 19.9 GB first download.
- Observe the real safety approver verdicts and the "force it" flow on the owner
  Mac; local tests cover source order and gating only.

## Fresh independent round (2026-10-21, after the first fixes)

A second Phase 5 pass ran three fresh, read-only processes against the same
merge base `0aeb7fd..HEAD`; each saw only the diff and the live checklists, not
the earlier findings or this chat.

| Reviewer | Exact id | Outcome |
| --- | --- | --- |
| Correctness | `opencode-go/deepseek-v4.1-flash` | 2 findings, both verified and fixed |
| Security | `opencode-go/qwen3.8-flash` (GLM slot) | 2 findings: 1 verified and fixed, 1 accepted residual |
| Accuracy | `opencode-go/qwen3.8-max` (Jev slot) | 3 minor findings, all verified and fixed; docs claims rated honest |
| GLM-5.3-Flash | not offered | **unavailable**: `opencode models` lists no `glm*` id; no paid or unlisted model was used |
| Jev 1.13 Free | not offered | **skipped**: no `jev*` id in `opencode models`; no paid Zen model was used |

Verified and fixed in this round:

| # | Reviewer | Finding | Evidence | Fix |
| --- | --- | --- | --- | --- |
| R4-1 | security | `LogRedaction`/`redact_log.pl` had no JWT rule, so `eyJ…` tokens could be uploaded raw | `printf '…eyJ…' \| perl scripts/redact_log.pl` left the token intact | JWT rule added to both redactors; Perl and Swift-source tests |
| R4-2 | correctness | An upload that spent its 8-attempt budget was parked for 365 days, and a stable log was only retried after it changed | `LogUploadQueue.failed` set `now + 365 * 86_400`; `enqueueCurrentFiles` only re-enqueues changed files | exhausted entries now retry at the 1 h backoff cap; XCTest asserts the cap retry |
| R4-3 | correctness | The safety override had no executable test (static text checks only) | `rg` found no XCTest for `armForce`/three strikes/expiry | logic moved to `ForceOverridePolicy` in DotCore; three XCTests cover exact action, expiry, one-shot and strike reset |
| R4-4 | accuracy | `split_release.py` silently overwrote an existing part set and did not re-read written parts | unconditional `open("wb")` and manifest write | refuses existing outputs unless `--force`; re-hashes every part after writing; tests |
| R4-5 | accuracy | `join_release.py` silently replaced an existing regular output | `staging.replace(output)` with only a symlink guard | refuses existing output unless `--force`; the double-click wrapper asks before passing `--force`; tests |
| R4-6 | accuracy | Part downloads followed redirects away from GitHub after validating only the manifest URL | `safe_url` checked the initial URL; `urlopen` followed redirects | `SafeRedirectHandler` allows only HTTPS GitHub/object hosts; test covers foreign and HTTP downgrade |

Targeted round 2 re-review found three residual gaps in those fixes; all were
verified and fixed:

| # | Finding | Evidence | Fix |
| --- | --- | --- | --- |
| R4-7 | The JWT rule required long segments, so `…e30.` and JWE tokens leaked | Perl probes left the short token raw and partly masked a 5-segment JWE | pattern matches 2–4 dot segments with optional empty segments; short/JWE tests |
| R4-8 | A forced re-split purged only the same filename's old parts; a renamed DMG left old manifests for upload | split `Dot-1.0.dmg`, then `Dot-1.1.dmg --force` in one directory | force purges stale `*.partNNN` and `*.parts.{json,sha256}`; renamed-DMG test |
| R4-9 | The legacy-queue normalization had no boundary test | only a 365-day value was covered | XCTest keeps the 1 h cap and resets only values above it |

Accepted residual / not changed:

- **The Keychain write still passes the token in argv**
  (`security add-generic-password -w "$TOKEN"`, `scripts/store_github_token.sh`).
  This was already listed below; the fresh reviewer repeated it. AGENTS.md
  requires that the token is never logged or stored in the repo/DMG, which
  holds. It does not require "never argv", and the macOS `security` CLI has no
  non-interactive Keychain write that avoids an argument without adding a
  helper. The owner-run script remains documented.
- The aux `gemma-3-4b` safety model is **not** a chat fallback; the main model is
  pinned to `mlx-community/Qwen3.8-27B-4bit`. The accuracy reviewer confirmed the
  docs disclose this, so no change was made.

## Reviewers

| Reviewer | Model | Outcome |
| --- | --- | --- |
| Correctness | `opencode-go/deepseek-v4.1-flash` | ran, 7 findings |
| Security | `opencode-go/deepseek-v4.1-flash` (fresh session; GLM substitute) | ran, 7 findings |
| GLM | `opencode-go/glm-5.3-flash` | **unavailable**: every listed GLM id returned `Unexpected server error` (`err_e843dfa1`, `err_712a97c3`, `err_1aaa9407`, `err_a9abeca9`); recorded and continued |
| Jev 1.13 Free | none listed | **skipped**: `opencode models` has no `jev*` entry, so no free Zen Jev id exists; no paid id was used |
| Re-review | `opencode-go/deepseek-v4.1-flash` | ran after fixes, 14 findings; all but accepted residuals fixed below |

## Verified findings and fixes

| # | Reviewer | Finding (file:line at review time) | Evidence | Fix |
| --- | --- | --- | --- | --- |
| C1 | correctness | `src/SafetyApprover.swift:25` read the aux model only from the bundle; the default DMG strips `OfflineModels` and downloads to `Application Support/Dot/Models` | `package_default_release.sh` rejects `OfflineModels`; `OfflinePreparation` writes `.../Dot/Models`; `SafetyApprover` returned `.unavailable` | `SafetyApprover.modelURL()` checks both the bundle and `OfflinePreparation.shared.root`; source contract + Swift compile in CI |
| C2 | correctness | `src/DotLogSync.swift:187/231` uploaded snapshots without re-masking; legacy lines could leak | `LogRedaction` was applied only at write time; shell fallback already sanitised old logs | `LogRedaction.masked(Data)` and `DotLogSync` masks at the upload boundary; non-UTF-8 bytes are dropped; Swift tests |
| C3 | correctness | `src/OfflinePreparation.swift:533` wrapped `URLSessionDownloadTask` in a continuation with no cancellation handler | `waitsForConnectivity = true`, resource timeout 86,400 s; `pause`/`retry` only cancelled the outer task | `withTaskCancellationHandler` + `PartDownloadCancellation` cancels the actual download task |
| C4 | correctness | `.github/workflows/release.yml` used `gh release upload --clobber` and had no main guard | quoted workflow lines | no clobber; main/ancestor guard; tag commit check; `--target "$GITHUB_SHA"` |
| C5 | correctness | `docs/PHASE4_RESULT.md:114` claimed resume/repair tested | `rg ModelPartPlan\|repair Tests` showed plan tests but no repair/resume transfer test | docs now say manifest/hash/reuse tested, split-part resume/repair source-checked only |
| C6 | correctness | `scripts/package_default_release.sh:53` claimed the pinned parts route while `Resources/model-parts.json` is `pending` | provenance string vs `"status":"pending"` | provenance reads the plan status and names the active route honestly |
| C7 | correctness | `src/DotLogSync.swift:138` set `metadataQueued = true` before the write | `try? data.write(...)` after the flag | flag set only after a successful write |
| S1 | security | redaction missed Basic auth, env-style keys, JSON keys, PGP blocks | Perl probes left them unchanged; Swift used the same rules | patterns added to `LogRedaction` and `scripts/redact_log.pl`; Swift + Python tests |
| S2 | security | `scripts/dot_log_sync.sh` allowed `DOT_LOGS_BRANCH=main` | `git push origin "HEAD:$DOT_LOGS_BRANCH"` | branch must be `dot-logs` or `dot-*` |
| S3 | security | `scripts/join_release.py` joined `part["name"]` and fetched `part["url"]` without validation | path traversal and foreign host possible | `safe_name`/`safe_url`, repeated URL decoding, release-path prefix; tests |
| S4 | security | `"force it"` armed the override with no three-strike check | `ChatView` set `forceNext` unconditionally | `armForce()` requires 3 refusals of the exact action, expires after 120 s, matches only that action, and is one-shot (strikes reset) |
| S5 | security | tag-push releases could publish from any commit | `on: push: tags`, no ancestry check | release commit must be an ancestor of main; existing tag must equal `$GITHUB_SHA` |
| R1 | re-review | the override could be re-armed forever | strikes were never reset | `consumeForce`/allowed verdict clear the action's strikes |
| R2 | re-review | the new Perl PEM rule used `perl -pe` (line mode) and never matched | reproduced on a 5-line PEM | `scripts/redact_log.pl` slurps with `local $/`, size-capped at 4 MB; Python runs the real script |
| R3 | re-review | new tests were substring-only | inspection | added behavioral Perl test and Swift `LogRedaction` tests; Swift-only `SafetyApprover` behaviour is not unit-tested because the file is outside the `DotCore` SwiftPM target |
| R4 | re-review | an existing input tag could point off-main | `gh release create`/upload used the tag without a target check | tag must resolve to `$GITHUB_SHA`; `--target` pins a new tag |
| R5 | re-review | `safe_url` accepted `..` segments | normalized-path test | path is decoded repeatedly and normalized before the prefix check |
| R6 | re-review | `scripts/package_all_in_one.sh` still used `--clobber` | quoted script | removed; no silent replacement |
| R7 | re-review | the tag check failed open on an API error | `if tag_commit=$(gh api ...)` | replaced with `git ls-remote` that fails closed |
| R8 | re-review | PGP private-key blocks were not matched | Perl probe | `PRIVATE KEY(?: BLOCK)?` in both redactors |
| R9 | re-review | the armed override had no expiry and could be reused | `forceKey` had no lifetime | 120 s expiry, exact-action match, one-shot; the automatic path may consume it because that is the action the owner just asked to repeat |
| R10 | re-review | the new test file was not run in CI | both workflows ran only `test_release_parts.py` | `test_review_pipeline_contract.py` added to both workflows |
| R11 | re-review | the Perl redactor slurped unbounded input | inspection | 4 MB cap matching the app's upload limit |

## Accepted residuals / not fixed

- **Queue overflow drops the oldest snapshot** (`InteractionCore.swift` ~6330 and
  `DotLogSync` overflow removal). This is the intended bounded-queue behaviour
  (64 entries, 32 MB snapshots); deleting an unsent oldest entry is the price of
  the hard bound. The pruning pass itself never deletes a queued entry.
- **Rotation can discard `dot_chat_log.1.txt` before it is snapshotted** if a
  rotation happens between syncs. Rotation is bounded by contract; the uploader
  copies the current files on every sync. Not changed.
- **`security add-generic-password -w "$TOKEN"` still passes the token in argv**
  in `scripts/store_github_token.sh`. It is an owner-run, local, one-time step;
  the `curl` verification now uses `--config -` so the token is not in argv
  there. There is no non-interactive Keychain API that avoids argv without
  adding a helper.
- **The downloaded aux model is hash-verified at launch, then existence-checked
  at each approval.** Re-hashing ~4 GB before every action is impractical; a
  post-launch swap is a same-user threat. Not changed.
- **Redirects from an accepted GitHub release URL can leave the host**, but each
  part is still checked against the manifest SHA-256 and the joined file against
  the whole SHA-256. Not changed.

## Disagreements kept visible

- The correctness reviewer called the missing approver model a **major** defect;
  the security reviewer's check confirmed the fix later. No majority vote was
  used.
- The security reviewer rated the redaction gap **major**; the re-review rated
  the remaining formats **high** on evidence. Both were fixed.
- The re-review rated the forced-override lifetime **medium-low**; the owner
  rule ("one free pass after three refusals") made it a real logic fix.

## Gates run on the Pi

```text
umask 0022; TMPDIR=$PWD/.tmp/pytmp python3 -B -m unittest discover -s Tests/Python -q
  -> Ran 636 tests, OK (28 skipped)
python3 -B scripts/check_contracts.py
  -> 76 static guardrails passed
CARGO_BUILD_JOBS=2 cargo fmt --all -- --check                     -> pass
CARGO_BUILD_JOBS=2 cargo test -p dot-research -p dot-runtime      -> 18 passed
CARGO_BUILD_JOBS=2 cargo clippy ... --all-targets -- -D warnings  -> pass
```

`/tmp` on this Pi is a 768 MB tmpfs, so the Python suite needs
`TMPDIR=$PWD/.tmp/pytmp`; without it the runtime-reconstruction disk-reserve
tests fail with `insufficient free space`. That is an environment limit, not a
code failure. `swift-test`, the full `macos` XCTest/Python lane and `dot-voice` passed in
the green run above (616 SwiftPM tests, 944 full XCTest, 636 Python tests, 4 skipped).
Notarisation and a real DMG install remain owner gates.

## Round 3 (final targeted re-review)

| Finding | Outcome |
| --- | --- |
| `git fetch origin main` was ambiguous if a `main` tag existed | fixed: fetch `refs/heads/main:refs/remotes/origin/main` and compare that ref |
| The double-click joiner trusted the manifest `output` path | fixed: wrapper rejects empty/dot/separator/backslash names before `--output`; join_release rejects symlink outputs |
| Env-style and JSON keys could still leak (`SECRET_KEY`, `PASSWORD_HASH`, `aws_secret_access_key`, `SecretAccessKey`) | fixed in both redactors and verified by running `redact_log.pl` |
| The human-approved-only force gate made the override unusable for automatic file actions | revised: exact-action, 3-strike, 120 s, one-shot; the automatic path may consume it because the owner just asked to repeat that action |
| `DOT_LOGS_REPO` could point at another repository | fixed: only `Emin-dev/Dot` (https or ssh) and `dot-logs`/`dot-*` branches |
| Provenance readiness was looser than `ModelPartPlan.isReady` | fixed: schema 1 + ready + parts + tag + matching base URL |
| `retry()` did not cancel in-flight work | fixed: cancels the generation and restarts after exit |
| Perl 4 MB cap did not apply to pipes | fixed: bounded 64 KiB reads |
| URL decode loop stopped after 3 passes | fixed: 8 passes |
