# dot: current continuation handoff

Checkpoint: 2026-10-13 17:58 UTC. This note describes unfinished local work and verified historical evidence; it is not a release or installation receipt. Read the [canonical checklist](BUILD_CHECKLIST.md), [13-item reliability order](BUILD_CHECKLIST.md#reliability-review-and-next-acceptance-order) and [verified progress](PROGRESS.md) first. Recheck live Git and writers before resuming: these are active files, not permission to overwrite them.

## Revisions and repository rule

- Main immediately before this documentation checkpoint: `a23435443ec2d7f925c34149777c7d0add455e03` (reliability review publication). Resolve this note's enclosing documentation commit through Git; it changes no app behavior.
- Main is the sole local/remote ongoing/default branch. PR #2 merged at `f718e870cd14148c1b20c03c7adc822f9981bf31`; exact assembled/tested milestone source is `6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc`. No feature branches should be recreated.
- Installed working source remains `b26a14505bd2bc8e57264f1dfc934f778a8bd781`. Its executable SHA-256 remains `28a5bc43233266be7ecb488b58c438823ee371c9f4ed6f490ca30d5463fa1ac5`. No replacement installation is authorized merely by a source/docs checkpoint.
- Complete separate candidate: `/private/tmp/dot-voice-batch-20261013/build-complete/Dot.app`, exact source `6aa5b89`, ad-hoc signed/not notarized, executable SHA-256 `537b472c4c3487f2b00cddc15a1a502875eb45c4ee40038078660ea375f366f3`. Do not overwrite it or confuse the development DMG with a complete installer.

## Workspace, recovery and ownership

Active main checkout: `/private/tmp/dot-next-stage-20261013`. One integration owner controls manifests, staging, commits and non-forced publication. All six agent slots plus integration are in use; no additional concurrent slots are available.

Recovery snapshot: `/private/tmp/dot-checkpoints/20261013T175819Z` contains 47 changed/untracked files, `working.patch` and `manifest.json`; manifest SHA-256 `bfda5b54a5e8eb97902fd375ea25756c479aea0e66e428429c4959c30d96502c`. This is a per-file recovery capture of active writers, not a transactional tested source tree; inspect and reconcile rather than restore over newer edits. `/private/tmp/dot-latest-checkpoint.txt` records the newest local snapshot. Prior consolidation recovery is `/private/tmp/dot-main-consolidation-20261013`; original patch remains `/private/tmp/dot-voice-unpublished-preserved.patch` (SHA-256 `7f5a5c80d90466c5e9db0634bb043b99edcbc1756fc338bc2cac4ea21c57ac04`). Local scratch paths are operational handoff information, not public downloadable artifacts.

| Owner | Current files/work |
| --- | --- |
| Integration | App/CompanionPanel/Engine, native typed/source panels, project/package registration, aggregate tests, docs/checkpoints and commits. |
| Voice/UI lane (`voice_review`) | ChatView: real compact status/countdowns/recovery, typed submission, useful facial feedback, history events; preserved proactivity/idle integration; production coordinator test seam. |
| Capture/coordinator lane (`question_playback`) | Speech/VoiceTiming completed source and focused tests; now real ChatModel fixture/coordinator tests. NativeActions draft preserved, action panel not yet written. |
| Screenshot/sandbox lane (`capture_timing`) | Screenshot acquisition-time fix completed; now sandbox profiles and required/forbidden-operation tests. Research notebook/panel work preserved and paused behind reliability. |
| Expression/launch lane (`native_skins`) | Expression/contrast files frozen for aggregate verification; now minimal helper launch/bootstrap and inherited socket boundaries coordinated with sandbox lane. |
| History lane (`planning_publication`) | ConversationHistory/HistoryPanel schema and tests: generation/playback status, migration/legacy unknown, interrupted/failed text. LocalMemory draft preserved, panel not yet written. |
| Runtime lane (`native_verification`) | Bounded real shipping-runtime harness; owns the only heavy model testing slot and cleanup. PersistentTasks draft preserved, task panel/tests not yet written. |

**Durable restart recovery:** the same verified snapshot is also stored in the saved workspace at `~/Documents/Codex/2026-10-12/task/work/checkpoints/20261013T175819Z` (the workspace `work/.gitignore` excludes `checkpoints/`). Its base remains `a23435443ec2d7f925c34149777c7d0add455e03`; all 47 file hashes and manifest bytes were rechecked after copying. Manifest SHA-256 is `bfda5b54a5e8eb97902fd375ea25756c479aea0e66e428429c4959c30d96502c`. Temporary snapshots are retained too. This source-only recovery copy excludes microphone/screenshot/runtime/model/credential data and is not published as working app code.

To recover: inspect the durable manifest and verify file hashes, then compare its base and each saved file with live main, the current worktree and active writers. Reconcile intended changes in a clean temporary detached checkout if necessary; validate the saved patch before applying it. Never copy the snapshot over a newer or dirty checkout, reset main, recreate feature branches or infer that this per-file capture is a tested commit. Re-run appropriate checks after reconciliation. Future checkpoints must retain a verified durable workspace copy as well as any temporary copy.

Do not edit another lane's files concurrently. Before handing off a frozen file, communicate ownership explicitly. No new user-owned chats, extra branches, force pushes or dirty resets.

## Current evidence and gaps

- Exact `6aa5b89`: 129 Python, 175 SwiftPM, 277 native XCTest, 49 guards, exact sandboxes, Debug/Release/development packaging with zero warnings; complete offline assembly and strict signature verification passed. These historical results do not cover current dirty source.
- A development integration SwiftPM run passed 243 tests before the latest reliability edits. The earlier native aggregate failed on a HistoryPanel error-variable shadowing compile error; that error was corrected, but the latest complete native aggregate has not yet been rerun. Do not hide this gap or call current source fully tested.
- Current screenshot lane: 16 focused tests and warnings-as-errors native typecheck passed; typed Engine submission validation is integrated by root and new transport freshness tests await aggregate execution.
- Current capture lane: 33 focused tests, including three actual synthetic AVAudioPCMBuffer replays, passed with zero warnings. Physical microphone/permission/route acceptance is separate.
- Expression lane: 120 authored shared trajectories, 3,600 native frame renders, 36 opposing/complex-background contrast cases and 2,400 bounds samples passed their render checks. Aggregate expression XCTest and full character-specific perceptual/device/runtime acceptance remain pending; amplitude is not phoneme alignment.
- Real `6aa5b89` harness: actual British Kokoro fixture, native Whisper, owned Qwen/Splash generation and two actual Bionic playback segments passed. Intermediate drain did not invite; one final playback and one invitation (419 ms later) observed. No physical microphone in that first run; no claim that the user heard the output. Receipt: `/private/tmp/dot-runtime-acceptance-6aa5b89-20261013/runtime-report.json` plus harness provenance. Actual capture follow-up is in progress.
- Native actual candidate windows: 11 skins rendered without clipping; glass-on-light contrast finding is fixed only in current source, pending candidate acceptance. Host Accessibility/input access remains unavailable; browser inventory empty. Existing microphone authorization was detected, allowing a bounded capture attempt without a new prompt. Never change TCC/security settings to work around this.
- Helper policies currently have overly broad read/loopback boundaries; tightening is being implemented with required/forbidden fixture tests before real-runtime validation. Do not claim the new boundary is already accepted.
- Research modules' focused fixtures passed, but URL reading is not a complete searched/cross-checked research answer. Search provider/cost remains unresolved; no paid provider commitment. Memory/tasks/action drafts are not integrated features.

## Next executable steps

1. Finish history status and coordinator test seams; register new pure/native sources/tests without pulling paused drafts into a claimed milestone. Preserve all drafts/recovery assets.
2. Run current SwiftPM and native XCTest integration, resolve actual failures, and update old compact-caption/static assertions to the newly authorized readable status contract without removing meaningful capture/privacy guards.
3. Finish helper parameter/socket restrictions; run required/forbidden fixtures and real shipping-runtime acceptance under the exact new profiles. Keep one heavy model instance.
4. Freeze a reviewed exact source increment on main, rerun repository-required checks, assemble a separate candidate from verified assets and record hashes. Recheck native status/footer/typed controls, light/dark/contrast and applicable device paths. Do not install over the working app.
5. Resolve the real search-provider/cost prerequisite and complete one question → search → source reading → checks/citations → local evidence workflow, then resume preserved retrieval/memory/tasks/actions/proactivity in the reliability order.
6. Approximately every ten minutes, publish a meaningful checklist/progress/continuation checkpoint and affected docs while work proceeds. Preserve uncommitted code separately; do not make timestamp-only commits or claim unfinished work complete.

The user has already approved the full build, all eleven designs, fixed timers and broad relevant context/tool use. Do not ask again for start/theme/default permission. Ask only for a real unresolved choice or inaccessible external prerequisite; continue independent work. Fixed local Splash/Qwen and British `bf_isabella`, native-first implementation, warm expressions, current installed app and exact evidence remain constraints.
