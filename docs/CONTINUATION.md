# dot: current continuation handoff

Checkpoint: **2026-10-13 18:39 UTC**. Read the [canonical checklist](BUILD_CHECKLIST.md), [progress](PROGRESS.md) and [helper verification](verification/helper-boundaries.md). This is an active implementation handoff, not whole-product completion or installation approval.

## Revisions and recovery

- Exact helper increment on main: `2db5aa9a1ecc744d57ef6c7478e5eab901d155de`; clean detached required checks passed before publication. Its enclosing documentation commit publishes this checkpoint. Prior public docs were `0977e4c`; earlier voice/skin candidate remains `6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc`, merged by PR #2 at `f718e870cd14148c1b20c03c7adc822f9981bf31`.
- Main is the sole local/remote ongoing/default branch. One integration owner stages/commits/pushes; no force-push, extra feature branches, dirty reset or overwriting another writer.
- Active checkout: `/private/tmp/dot-next-stage-20261013`. Helper verification checkout `/private/tmp/dot-helper-verified-20261013` is detached. Other source remains unfinished in the active checkout.
- Durable recovery: `~/Documents/Codex/2026-10-12/task/work/checkpoints/20261013T183919Z`; identical temporary copy `/private/tmp/dot-checkpoints/20261013T183919Z`. **64 changed/untracked source/test files**, patch and manifest; all copied hashes verified. Base `2db5aa9a1ecc744d57ef6c7478e5eab901d155de`; manifest SHA-256 `fcf1aab7e92175a5e43618fcdab4264ec661727a4a18bda3e68e52d98e307b3b`. The workspace `work/.gitignore` excludes checkpoints. No runtime recordings/screenshots/model/credential data are included. Prior copies remain.
- `/private/tmp/dot-latest-checkpoint.txt` points to the latest temporary snapshot; the saved workspace's `work/checkpoint_dot.py` is the manually invoked source-only capture utility. Snapshots are per-file captures of active writers, not transactional tested trees. Verify manifest/hash/base, compare with live main and all current writers, and reconcile in a detached checkout if needed. Never restore over newer edits or infer that copied code passed tests.
- Original patch `/private/tmp/dot-voice-unpublished-preserved.patch` remains, SHA-256 `7f5a5c80d90466c5e9db0634bb043b99edcbc1756fc338bc2cac4ea21c57ac04`. Earlier consolidation recovery remains `/private/tmp/dot-main-consolidation-20261013`.

## Installed and candidate states

Installed working source remains `b26a14505bd2bc8e57264f1dfc934f778a8bd781`, executable SHA-256 `28a5bc43233266be7ecb488b58c438823ee371c9f4ed6f490ca30d5463fa1ac5`. Complete separate old candidate remains `/private/tmp/dot-voice-batch-20261013/build-complete/Dot.app`, source `6aa5b89`, executable SHA-256 `537b472c4c3487f2b00cddc15a1a502875eb45c4ee40038078660ea375f366f3`. It is ad-hoc/not notarized/not installed. The new helper-only development package is incomplete and is not an owner bundle. Do not replace either preserved app during development.

## Current lane ownership

| Owner | Current assignment |
| --- | --- |
| Integration | App/CompanionPanel, project/package/build registration, exact-source checks, source increments, docs/checkpoints and publication. Footer native-control tracking now differs from pet drag cancellation. |
| `voice_review` | Frozen typed/status fixes and 11 focused tests; now same-Engine local-Qwen research synthesis and tests. Also diagnosing a native Thread Performance Checker QoS warning; no suppression. |
| `question_playback` | Frozen 15 coordinator tests and ActionPanel/26 executor-interface checks; now App Intents metadata/training verification. Existing packaging skips metadata and lacks English development region; verified fixes await root integration. |
| `capture_timing` | Frozen source notebook panel and reader corrections; 20 reader/brief plus 10 interface checks and actual official HTML/PDF reads passed. Next source/research reliability assignment coordinated with root. |
| `native_skins` | Helpers/expressions frozen; real tightened-policy component run passed and cleaned up. Preparing controlled cold/resident warm timing harness; only heavy-model slot, no model running at checkpoint. |
| `planning_publication` | Frozen history/research contract/private store (42 research tests); now one native resumable research panel/model with injected provider and same-Engine synthesis. No selected provider/key/live calls. |
| `native_verification` | Actual native UI routing/typed checks: 20 meaningful assertions passed; two image comparisons do not establish visual correctness. Own-window screenshot alternatives remain technically unavailable; evidence/report and alternative checks continue. |

Root controls integration manifests; agents must not edit them or each other's files. Parallelism uses non-overlapping files and detached checkouts, not extra lasting branches or user-owned chats.

## Evidence, failures and limitations

- Exact helper source: **136 Python, 175 SwiftPM, 277 native XCTest, 49 guards**, both sandbox fixtures, Debug/Release/development packaging and signature checks passed with zero warnings. See [receipt](verification/helper-boundaries.md).
- Broader unfinished integration: an earlier run passed 294 SwiftPM/464 native XCTest; the latest registered UI/store development aggregate passed **521 native tests**. There was one runtime Thread Performance Checker QoS warning during a typed-panel test; this is under investigation and prevents a zero-warning claim for that larger snapshot. AppKit/linkd service diagnostics also remain distinct from compiler warnings. Subsequent edits require another exact-source check.
- Real new helper-policy component run passed British Kokoro, Whisper, actual Qwen/Splash, two audio segments and one final invitation. The private eSpeak-map failure was fixed narrowly with passing negative canaries. Actual microphone activity ended after 3,000 ms trailing silence; audio/text discarded. Readiness took 70.210 seconds in an uncontrolled cold diagnostic run; no speed improvement, acoustic onset or p50/p95 claim. Older `6aa5b89` real no-speech capture closed after 6,124 ms; it is a different source/run.
- Footer control down formerly cancelled/replaced its own Stop button. The split control hook now preserves the clicked row while revoking automatic invitation. The native UI harness passed **20 meaningful native/state assertions plus two inconclusive cached-image comparisons**, including Stop never firing Talk, Options never starting capture, typed Command-Return and Escape, and Original default. Receipt: `/private/tmp/dot-ui-reliability-20261013-h/ui-report.json` plus provenance.
- **Visual capture is inconclusive:** AppKit bitmap capture omits unchanged SwiftUI/material layers and cannot establish blanking, contrast or still-motion acceptance. Legacy own-window capture failed; ScreenCaptureKit resolved the exact owned PID/window with existing grant but returned `SCStreamErrorDomain -3811` audio/video capture failure. No new permission/security change was attempted. No general native/browser controller is available; browser inventory remains empty. These technical limits do not revoke owner design acceptance.
- Source-reader fixes use native HTML parsing with external entities disabled, bounded readable text/charset/PDF extraction, cancellation and stricter lexical URL checks. Actual production reader fetched official W3C HTML (18,910 bytes) and PDF (13,264 bytes/one page); metadata/hash receipts are in `/private/tmp/dot-public-source-acceptance-20261013`. This is real supplied-source reading, not an automatic researched answer. DNS-rebinding isolation and rendered-browser readability are not established.
- History/expressions and typed/actions/source utilities have focused evidence and root wiring but remain unpublished source. 120 shared authored expression trajectories/render receipts do not establish full character-specific perceptual/phoneme/device acceptance. LocalMemory/PersistentTasks drafts remain preserved and paused.
- **Provider question pending once in coordinating chat:** Tavily free-only first versus raw Perplexity Search with explicit spending limit. No answer/default/time passage authorizes selection or paid calls. Keys belong locally in Dot, never chat. Qwen reasoning stays local; actual page/PDF evidence and explicit result-retention rights remain required.

## Next executable steps

1. Publish the verified helper increment/checkpoint; preserve all unfinished code. Finish the larger source increment's QoS/native UI limitations and required tests, with exact source/asset hashes. Do not call old/frozen components the current complete candidate.
2. Register validated App Intents metadata extraction and English locale training in Xcode and both shell builds; verify actual bundled artifacts before claiming Siri discovery. Existing router tests alone are insufficient.
3. Connect research panel/store to same-Engine synthesis and foreground cancellation. Keep provider configurable/unselected until the coordinating answer and local key setup. Complete actual searched/read/cited workflow before claiming broad autonomous research.
4. Recycle lanes into remaining approved workflows in reliability order; preserve fixed Qwen/Splash/British voice, Original default and all eleven identities. Keep runtime benchmark single-instance and separate from asset verification contention.
5. At safe checkpoints about every ten minutes, update meaningful checklist/text/progress/continuation and affected docs, create verified durable source recovery, and publish normally. No empty timestamp-only commits, broken-source publication or repeated start/design approvals.
