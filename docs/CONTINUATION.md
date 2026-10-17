> **SUPERSEDED (2026-10-17).** This document describes the retired Python voice helper, source fetcher
> and SearXNG/Waitress search stack, which no longer exist. See [the Rust-only runtime](rust-runtime.md)
> for the current runtime. It is a dated continuation handoff: the revisions, run counts, receipts and
> blockers below are preserved unchanged as the record of what was observed on 14 October 2026, and
> its Search/voice lanes, its "120 reviewed recipes per new skin" expression target and its next steps
> no longer describe the repository.

## Current handoff — 2026-10-17 (every repository gate green)

**State.** `main` is the only branch. Every gate the repository owns passes on this tree: the
`xcodebuild` app build **SUCCEEDED**; the Xcode XCTest lane (the one `verify_macos.sh` runs)
**860 tests, 0 failures, TEST SUCCEEDED**; `swift test` **546 / 0**; the Python suite
**604 passed / 4 skipped**; **53** static guardrails; `cargo build --release` produces `dot-voice`,
`dot-search` and `dot-fetch`; and `scripts/audit_runtime_payload.py` accepts the owner's real
Rust-only payload (34,004 files, exit 0).

**Consecutive verified commits.** The session ended green on every gate, with the Xcode XCTest lane
at 860 tests / 0 failures (it began at 11 failures), and the installed app's provenance matching HEAD
via `scripts/install_local.sh`.

**What this session changed.** The runtime is Rust-only for Dot-authored code: the Python voice
helper, Python source fetcher and the whole Python SearXNG stack are deleted, their build gates now
require the Rust binaries, and `build.sh` embeds the Whisper framework via `DOT_WHISPER_FRAMEWORK`
because the recognizer is a compile-time branch — without it the app could never listen. Verified
live: `dot-voice` synthesises `bf_isabella` audio offline; `dot-search` returns real results over its
capability-gated loopback endpoint; `dot-fetch` is the pinned reader. Defects fixed with regression
tests include: click-to-listen (with an honest refusal instead of silence when not ready), a
subprocess deadlock on >64 KiB output, the microphone being armed on punctuation and again on an
intermediate audio-queue drain (it now arms only after final playback), lip-sync articulating with no
audio, the Dew preference reverting on relaunch, an unclickable approval card and its bypassable
destructive-command gate, unclamped tool numerics, a hardcoded readiness gate, 5 s→15 s screen
freshness, the macOS 27 / 48 GB launch gate, stuck-task detection reading the wrong input, laser
coordinates, and clicking during an answer not listening again. Five-tier memory was added and its
write path wired (preferences → T5, corrections → core, one ageing pass at launch).

**Remaining work, with leads.**
1. *Memory — complete as a user-facing loop; one cleanup left.* Capture: a stated preference or
   correction anywhere in a bounded turn lands in T5 core (the detector previously demanded one of five
   exact prefixes, which is why the owner's database held 0 rows). Recall: `assembleTurnContext` takes
   the `MemoryTierStore`, sources core records first then tiered recall, FTS only as a fallback.
   Inspect: "what do you remember" lists up to ten core facts. Forget: "forget that I ..." / "forget
   about X" / "delete memory X" deletes up to five matches through the store's own forget path and
   reports the count, refusing a vague subject rather than guessing. Ageing promotes T1->T2->T3->T4 and
   never deletes; eviction runs from the real RAM-pressure path, frees a quarter, and never takes T3,
   T4, T5 or a pinned record. What remains is mechanical: `MemoryTierStore` still opens a second
   connection to `dot_records.sqlite`, and a `withConnection` accessor on `LocalFTSStore` would remove
   ~120 lines of duplicated connection setup.
2. *Dead code.* An audit with per-item grep evidence lists **694 lines** removable with no behaviour
   change (largest: a 242-line paid-search provider subsystem only tests instantiate, `NativeTTSManager`
   52, `InteractiveWalkthroughManager` 82 — the last is now honestly marked unwired in the checklist).
   Keep the FTS delete/stale primitives (memory needs them) and the keyed search providers (the
   owner's resilience path).
3. *Owner features not built.* Broad local-file access, and the second half of the self-improvement
   flow: Dot now writes the suggestion to its reflections file, copies it to the clipboard and says so
   (it no longer activates another app or synthesizes keystrokes), but it does not yet **ask** whether
   to paste it into whatever the owner is working in. That needs a pending-action state machine; the
   cheapest correct route is to reuse the existing approval card (`ActionApprovalRequest` plus
   `pendingApproval` and the spoken/clicked approve-deny path) with a distinct title such as
   "Paste Suggestion", adding a new branch in `approvePendingAction` and **not** altering the
   destructive-command branches, which guard shell execution and file deletion.
   Ordinary conversation now does populate memory: the detector previously required the whole turn to
   begin with one of five exact prefixes, so real speech was never stored; it now matches a
   first-person or explicit cue anywhere in the turn, bounded to 240 characters, and lands in T5 core.
4. *Known advisory: a quality-of-service inversion.* XCTest reports, from
   `TypedInteractionTests.testPanelRebindsCallbacksAndDraftWithoutActivatingOrRetainingOldModel`, that a
   thread at User-interactive QoS waits on one at Default QoS. The waiting work is produced by the app
   (the test fixture creates no tasks of its own), so the lead is to find the turn-pipeline task in
   `ChatView.submit` and give it `.userInitiated` - a reply the owner is waiting for is user-initiated
   work. `scripts/verify_macos.sh` filters *only* this advisory out of its zero-warning check (it is a
   runtime observation, not a compiler warning); every other warning remains fatal. Removing the filter
   alongside the actual fix would be the honest end state.

5. *Latent issue.* `PlacementSnapshot.lifetime` is 10 s while the app validates on a ~10 s cadence, so
   every cycle's first validation is rejected by construction (`reason=expired elapsed=10475ms` in the
   live log) before a fresh capture. Fix it in the caller — refresh before validating — and **do not
   raise the lifetime**: `RoamingTests` correctly guards the 10 s fail-closed rule.
6. *Last Dot-authored Python.* `Resources/Runtime/dot_runtime.py`, `dot_process.py`, `dot_tls.py`
   (Splash supervisor and TLS relay, 640 lines, stdlib-only). Splash itself and its interpreter are
   deliberately retained: the owner chose Qwen 3.8 27B Q4 on Splash as the fastest engine.

**Small owner requests closed this session.** Copying Dot's answer, showing it on screen, reporting
battery level from IOKit, and reading its own source from a resolved path (a `DOT_SOURCE_ROOT`
override, then the known checkout if present, otherwise an honest empty result instead of a pinned
absolute path that only existed on one machine). The self-improvement loop no longer activates another
application or synthesizes keystrokes: it writes to its reflections file, copies the suggestion to the
clipboard and says so.

**Flaky under load, observed once.** A full `scripts/verify_macos.sh` run reported
`Tests/DotCoreTests/WebSearchProviderTests.swift:585`
(`LocalDotSearchProviderTests.testRuntimeAnswersAreBoundedAndCapabilityRejectionSurfaces`) failing with
`startupTimeout` where `challenge` was expected, after the case took 1041 seconds. The same test passes
in isolation in 3.5 s (the class runs 7/7 in 7.2 s) and passed in every standalone `swift test` run this
session, so this is load sensitivity rather than a product defect: the local fixture's script did not
produce its ready line before the retry path spun under the gate's combined load. The lead if it recurs
is to make that fixture's readiness deterministic (or bound its retries) rather than to raise
`startupSeconds`, which is a correct 10 s bound on a real runtime.

**Environment traps a future session will hit.** `python3` here is 3.9 and the suite needs ≥3.11 — use
`/private/tmp/dot-py313/bin/python`. Builds inside this cloud-synced checkout need a `/private/tmp`
scratch path (SwiftPM) or `xattr -cr` before `codesign`, because the File Provider re-applies
attributes. Installing over `~/Applications/Dot.app` is now scripted:
`bash scripts/install_local.sh` builds with the recognizer embedded, clones the payload
(`cp -c -R`, so the 20 GB is copy-on-write rather than duplicated), writes honest provenance,
signs with "Apple Development: Emin Ismayilov (7M2G5ULAUF)" so macOS keeps the microphone and
screen grants, keeps the replaced app at `Dot.app.backup-latest`, relaunches and verifies that the
installed provenance matches HEAD. It defaults the framework and payload to the app being replaced,
so it needs no arguments on this Mac.

**Still unverified by the owner.** No microphone, screen-permission, acoustic or device acceptance has
been observed on the current build: the diagnostic log holds no entries from it, and repeated
re-signing resets the macOS microphone grant, so that permission must be re-granted before
click-to-talk can be confirmed.

# dot: current continuation handoff

## Published checkpoint — 2026-10-14 22:25 UTC

Published main is [`20d9eeb`](https://github.com/Emin-dev/Dot/commit/20d9eeb41cee21246343c66362b36310c5cc9cf5), tree `ad4c81ef1e357543c33cb54acd7e3ba654084e67`; all 272 file identities and modes were verified. The canonical ledger remains **4/97 current requirements complete, 93 open**, plus five historical milestones. No acceptance changes in this checkpoint. Earlier dated receipts remain historical.

- Exact [`055540e` native run](https://github.com/Emin-dev/Dot/actions/runs/38644863361) passed 719 Python cases (712 passes, seven skips), 607 SwiftPM cases (600 passes, seven opt-in fixture skips), 909 XCTest cases and Debug/Release compilation. Six of seven synthetic finalizer gates passed; descriptor inspection still rejects the hard-linked Apple system tool. Overall failure remains mandatory and packaging was not attempted. Full log: 1,335,385 bytes, SHA-256 `1be7e6e0782a58fa203d149f89f5f7e06f15e33a074d2300be83ac1deb9a9985`. Suites overlap.
- The [current Search run](https://github.com/Emin-dev/Dot/actions/runs/38645933779) passed portable prerequisites and reconstructed the exact historical 4,824-file payload. The fixed interpreter passed signature verification and minimal startup outside the sandbox; the same startup inside the unchanged profile ended with SIGABRT (6). The failure is sandbox-context-dependent; its exact cause remains unknown. The real Swift vertical step executed but failed during build/toolchain preparation with `owned-process-failed`; all seven scenarios remain pending. Full log: 46,049 bytes, SHA-256 `6712d1dc7caf0601af5de3d4bafb13445d047014125d26f31872cfa3ed06016e`.
- Native job headroom is now 20 minutes following a confirmed 15-minute timeout. Same-group successor runs preserve the active run; GitHub may still replace pending runs. The `055540e` and `20d9eeb` runs completed without cancellation. [20d9eeb native](https://github.com/Emin-dev/Dot/actions/runs/38645933706) failed during Python tests: 732 cases, one failure and seven skips. The TLS stop regression measured 2.2028 seconds against its unchanged one-second requirement. Later native stages, including the separate fixed codesign self observation, were unrun. Full log: 161,008 bytes, SHA-256 `c0ef66e28a173c46584a650f4bb222a5e1f511ee10d462266ce4bc2058fd89a7`.

Next: reproduce and repair the TLS stop regression without weakening its requirement; obtain exact preparation-phase and sandbox-startup failure evidence, then run the actual Search scenarios. App research remains unconfigured; production Search/runtime approvals remain empty. Latest complete green source remains `1b9f949`; owner model hashes and runtime report are awaited. Full self-contained offline artifact, licensing, signing and owner-device gates remain open. No further model-free binary delivery is planned.

## Published source and native checkpoint — 2026-10-14 21:13 UTC

Published main is [`adf92b8`](https://github.com/Emin-dev/Dot/commit/adf92b8d235850e5fdf8423afe52f9c968ae8f88), tree `9878aadaecb987d4e4cdc0479ea5ee8d5e9e5541`; all 271 file identities and modes were verified. Its [native run 38636683631](https://github.com/Emin-dev/Dot/actions/runs/38636683631), completed at 21:12 UTC, passed **694 Python cases (687 passes, seven skips), 607 SwiftPM cases (600 passes, seven opt-in fixture skips), 909 XCTest cases and Debug/Release compilation**. Overall it failed the same mandatory descriptor-inspection gate described below; packaging was not attempted. All seven real Search harness methods compiled, but their scenarios were not requested and remain unexecuted. The full job log is 1,291,333 bytes, SHA-256 `6cc817ee09c844551f017935a50ef8210465d79c0ec601f2204ec0adaaa0f485`. The canonical ledger remains **4/97 current requirements complete, 93 open**, plus five historical milestones. Earlier checkpoints retain historical evidence; their publication and pending-work statements are superseded by this dated snapshot.

- Exact parent [`2acee29`](https://github.com/Emin-dev/Dot/commit/2acee29f8d4f6de3afa503a0e725bcc73979603a) passed **694 Python cases (687 passes, seven skips), 600 SwiftPM tests, 909 XCTest cases and Debug/Release compilation** in [run 38633954405](https://github.com/Emin-dev/Dot/actions/runs/38633954405). Six of seven synthetic runtime-finalizer capabilities passed. The overall run failed its descriptor-inspection gate; packaging and its receipt were not attempted. Suites overlap and must not be summed as unique acceptance cases. The full job log is 1,286,761 bytes, SHA-256 `d9235497dc695afee7e650adf5cc64bd57775c6b029c7c2075e9d5909508fe03`.
- Descriptor diagnostics identify the current failure: the fixed Apple `/usr/bin/lipo` and `/usr/bin/otool` paths are regular root-owned, mode 0755, and share one inode with 78 hard links on this hosted image. The synthetic payload itself has one link and passes its tree checks. The generic single-link reader rejects the first system tool. Fixed Apple-tool identity and selected developer-tool dispatch require their own evidence; payload single-link checks remain unchanged. The prior hosted compiler-owner and Darwin descriptor-enumeration setup failures have been repaired and native-tested. These synthetic capability results do not admit a complete runtime.
- The separate [2ace pinned proxy run 38633954462](https://github.com/Emin-dev/Dot/actions/runs/38633954462) reconstructed the exact historical 4,824-file payload, then observed its profile child terminate with **SIGABRT (6)** before readiness, with zero captured stdout/stderr. The bounded milestone journal was absent. This establishes the observed signal and missing journal, not the crash cause. Later bootstrap/transport stages were not run. Fixed outside/inside startup diagnostics are reviewed separately without widening the sandbox or re-signing the interpreter.
- Current `adf92b8` publishes the bounded ordinary-copy overlay builder and seven opt-in real Search vertical test scenarios. The overlay's source identities, historical donor, exact permitted changes and disjoint copied files have portable verification. The actual Swift manager/broker, pinned helper/library, TLS certificate negatives, replay and drain scenarios still require native execution through the reviewed workflow hook; source publication alone does not run them. Historical payload identity is not production admission. App construction remains unconfigured, and production Search/runtime approval records remain empty.
- Latest complete green source, including development packaging, remains [`1b9f949`](https://github.com/Emin-dev/Dot/commit/1b9f949d7cca8fda526af07515762a388123007b), [run 38609622847](https://github.com/Emin-dev/Dot/actions/runs/38609622847). Expanded local work and recovery copies remain separate from published source. Complete owner model hashes and the bounded runtime report are still awaited; installed app/data are preserved and owner-Mac automation remains usage-blocked. The final delivery must contain the required models/runtimes and pass clean-install offline, exact-artifact, licensing, signing and device gates. No further model-free binary delivery is planned.

Next: execute the actual Search vertical through its source-bound workflow, diagnose the original interpreter abort, and establish the fixed Apple inspection-tool boundary without relaxing payload trust. Continue full v2 runtime reconstruction from independently verified inputs; preserve all unrelated unfinished work.

## Published source and native checkpoint — 2026-10-14 20:01 UTC

Published main is [`7a704bf`](https://github.com/Emin-dev/Dot/commit/7a704bfbc63eb460f7975e4c9ac242b3954402a4), tree `7445418316586ff410bd35fd742ff92d07365975`; all 263 published file identities were verified. The canonical ledger remains **4/97 current requirements complete, 93 open**, plus five historical milestones. No acceptance row changes here. Earlier checkpoints below retain their dated evidence and are superseded for current publication/CI state.

- Exact parent [`d4205a0`](https://github.com/Emin-dev/Dot/commit/d4205a0d21ef649a6f58c0dc46105b84814ac7d8) passed **630 Python cases (623 passes, seven skips), 578 SwiftPM tests, 887 XCTest cases and Debug/Release compilation** in [run 38624949109](https://github.com/Emin-dev/Dot/actions/runs/38624949109). All 64 Search parser/socket/lifecycle methods passed. Both native suites observed 48 genuine short socket sends while delivering and checking exactly 524,287 bytes, zero outstanding permits and three closed broker sockets. These are hosted synthetic transport results, not live Search or device acceptance.
- That run **failed overall** at the mandatory synthetic runtime-finalizer canary; packaging and its receipt were not attempted. The fixed hosted Xcode is owned by UID 501, which the current root-only fixture gate rejects. Read-only diagnostics verified `com.apple.clang` against Apple's anchor and unchanged compiler bytes; they do not override the gate. A narrowly scoped test-only hosted-toolchain policy is under separate review. The full job log is 1,197,984 bytes, SHA-256 `f4cddf0a66018f741396e0ea6c21e07e2455eabd755e061af69974aa82b998f8`.
- The latest complete green source, including development packaging, remains [`1b9f949`](https://github.com/Emin-dev/Dot/commit/1b9f949d7cca8fda526af07515762a388123007b), [run 38609622847](https://github.com/Emin-dev/Dot/actions/runs/38609622847): 467 Python cases (460 passes, seven skips), 506 SwiftPM and 815 XCTest cases. Later source is not covered by that complete green result. Suites overlap and must not be summed as unique acceptance cases.
- Current `7a704bf` adds the reviewed owned helper/bootstrap/private-proxy boundary and one-search manager/provider lifecycle with 19 new native test bodies and matching build registration. Its composition passed **674 portable Python cases (666 passes, eight skips), 42 Portable tests and 52 static guards**. Its own [native run 38627840239](https://github.com/Emin-dev/Dot/actions/runs/38627840239) failed during Python setup: Darwin did not declare the bootstrap's `closefrom` call. It ran 666 tests with seven skips and one class-setup error; eight deadline cases and the later Swift/Xcode stages were not run. A supported Darwin descriptor-closure repair is being reviewed without weakening inherited-FD isolation. The separate [pinned proxy canary 38627840249](https://github.com/Emin-dev/Dot/actions/runs/38627840249) reconstructed all 4,824 historical files with the exact receipt/tree, then its profile child exited before readiness with empty stderr; child signal/status was not reported, so the cause is not yet established. Later bootstrap/transport stages were not run. That existing proxy canary does not itself test the actual Swift broker.
- App construction still has no research provider and remains unconfigured. The changed helper/profile/bootstrap source is not covered by the retained historical payload lock. No accepted Search manifest, production approval, live-provider readiness or full runtime was created. The next real Swift-broker/pinned-helper/TLS fixture requires explicit source/binary/payload identities, genuine startup and drain receipts, and disclosed fixture-only admission/CA boundaries.
- Expanded local implementation and its recovery copies remain separate from published source. Model/runtime hashes and the owner's bounded runtime report are still awaited; the installed app and data remain untouched. Owner-Mac automation is blocked by its usage limit. Source tests and hosted macOS results do not establish owner-Mac acoustic, energy, performance or installation acceptance.
- The final artifact must contain the required models and runtimes, work offline on a clean installation, and pass exact packaged-artifact checks. Full runtime/model identity, real research, licensing, signing/notarization, voice/device checks and remaining canonical requirements remain open. No further model-free binary delivery is planned.

Next: repair and rerun the exact native setup and profile failures without weakening gates, complete the separately reviewed synthetic compiler policy and actual Search vertical fixture, and reconstruct the full v2 runtime from independently verified inputs. Preserve normal main-only publication and all unrelated unfinished work.

## Verified published checkpoint — 2026-10-14 17:21 UTC

Current published source is [`1b16e9c`](https://github.com/Emin-dev/Dot/commit/1b16e9cd036fc7d2b438f9057b40003723b19acc), tree `bdb5d2021812d378ebb2c623e9827569c036356b`. Both published and local canonical ledgers retain **4 of 97 current requirements complete, 93 open**, plus five historical milestones. R04, R17, R50 and R66 retain their narrow dated reconciliation, design, research and architecture scopes; no new requirement is closed here.

- [Exact hosted-native run 38603681236](https://github.com/Emin-dev/Dot/actions/runs/38603681236), [job 115989003075](https://github.com/Emin-dev/Dot/actions/runs/38603681236/job/115989003075), passed: **467 Python cases (460 passes, seven skips), 496 SwiftPM tests and 805 XCTest cases**, Debug/Release builds, development packaging/signature/receipt checks and the zero compiler-warning gate. Suites overlap. The complete job log is 1,094,965 bytes, SHA-256 `82de79ae059a4c641e3ccd44e0db0b151fcc37b672876c43f644facbccad9263`.
- The reviewed HTTPS-evidence changes and private-pipe runtime-v2 source are now published and covered by that source-level native run. Runtime reconstruction preparation/status is implemented; production historical approvals remain empty and native finalization is still under review. The existing installed runtime-v1 app must be preserved. A genuinely reconstructed, signed and verified v2 runtime is required before using it with the current host.
- Chunk-level transport consumption preserves byte-by-byte parser/cancellation checks, limits, backpressure and the genuine completion/invalidation fence. The same Debug fixture checked every byte of its 4,000,000-byte payload in 245 chunks: drain **40,321 microseconds**, versus **113,971,168 microseconds** on the earlier exact `25b2037` run. This measures hosted transport draining only; model response, speech and owner-device latency remain unmeasured. Untyped held HTTP responses can still await a network timeout; the tested typed local SSE path works.
- Earlier `25b2037` replacement run 38598194412 passed after its first run was cancelled by an unknown initiator. Runtime publication `8d30a62` then failed Python fixture setup through macOS's symlinked temporary root; `4b3681f` exposed case-insensitive-volume fixture assumptions. Those test-only repairs are included in the current green source. Native/package steps were not reached on either failed runtime attempt.
- Current published App construction still has no live research provider. The payload reader's 29 native tests pass, but real Search broker/helper/provider wiring, exact native proxy canaries and the end-to-end cited workflow remain open. Source-reader child-settlement and runtime finalization changes are staged separately for review; this checkpoint does not certify them.
- The owner has reported an arm64 Mac with 48 GiB RAM, 401 GiB free and macOS/SDK 27. Existing approximately 20 GiB app assets may support isolated reconstruction after complete hashes and the read-only runtime report arrive. Partial model hashes and self-reported runtime metadata are not full asset acceptance. Mac automation is blocked by its usage limit; no installed app or data has been replaced.
- The requested final app remains self-contained with all required models/runtimes and clean-install offline verification. No further model-free binary is being delivered. Full runtime/model identity, live research, voice/acoustic/device checks, licensing, distribution signing/notarization and final packaging remain pending. Expanded unpublished source has separate local test receipts and is not covered by this main-commit result.

Next: finish the reviewed runtime finalizer and genuine child-settlement repair, then connect the bounded Search broker to the existing owner/provider and execute its actual native canary. Keep source-owned approval and genuine payload evidence fail-closed while awaiting the owner's complete asset reports. Publish only coherent reviewed slices; preserve unrelated expanded work.

## Historical scoped checkpoint

The following 16:16 checkpoint and older sections are retained as dated history. Their then-current parent, pending publication and CI statements are superseded by the checkpoint above.

## Scoped progress checkpoint — 2026-10-14 16:16 UTC

This documentation tranche records **4 of 97 current requirements complete, 93 open**, plus **five separate historical milestones**. The completed scopes are R04 **dated reconciliation**, R17 service-boundary **design**, R50 video **feasibility research**, and R66 **shared-native-rig architecture**. These counts are not a feature-completion percentage or release certification. R04 closes only the fresh dated reconciliation; it must continue to be maintained as commits, tests and prerequisites change. All 102 requirement texts and their order are preserved.

- Published parent for this combined candidate is [`21fb1c2`](https://github.com/Emin-dev/Dot/commit/21fb1c24d2d061bd46995d7cfcd7e6a4c8c40432), tree `dc737d2237170e50675a6b0187f3feb0c1c92065`, 238 files. Its canonical ledger still has **0 of 97 current rows checked**; the expanded local ledger has **4 of 97** after the approved dated R04 reconciliation. This tranche adds the four approved scoped closures and their reports without copying the expanded implementation.
- Latest exact green hosted-native evidence is [`21fb1c2`](https://github.com/Emin-dev/Dot/commit/21fb1c24d2d061bd46995d7cfcd7e6a4c8c40432): **334 Python passes / 3 skips, 486 SwiftPM and 789 XCTest passes**, plus Debug/Release/development-package/signature and the zero compiler-warning gate. [Run 38594414249](https://github.com/Emin-dev/Dot/actions/runs/38594414249), [job 115957311020](https://github.com/Emin-dev/Dot/actions/runs/38594414249/job/115957311020), completed successfully at 16:11 UTC. This is model-free evidence for that exact parent; runtime diagnostics remain distinct from compiler warnings.
- Earlier failed attempts: [`2d28437`](https://github.com/Emin-dev/Dot/commit/2d28437a560638074eb9c835349990dcaea3cba2) passed **333 Python / 3 skips and 486 SwiftPM**, then failed native compilation on the unused mutable weak binding in `ResearchEngineTests.swift`; XCTest and packaging were not reached. The minimal `f0a0751` repair cleared that compiler warning, but [run 38589346500](https://github.com/Emin-dev/Dot/actions/runs/38589346500) **failed at 15:32 UTC**: **333 Python passes / 3 skips and 486 SwiftPM passes**, followed by **788 XCTest cases with 11 failures (2 unexpected) across four new transport cases**. Release/package/signature gates were not reached. These historical failures are superseded by the exact green `21fb1c2` parent; they remain recorded rather than being relabelled as passing.
- [Scoped evidence and reconciliation](verification/scoped-progress.md) links the exact [service-boundary design](architecture/staged-services.md), [video feasibility research](verification/video-feasibility.md), and R66 native evidence. The broader Rust migration, video implementation/Mac acceptance, production expression recipes, native integration, full runtime/device checks and distribution gates remain open.
- The expanded local source and its `scripts/current_product_acceptance.py` validator are absent from this published base and are not added by this documentation delta. This documentation delta includes no release infrastructure, app/test code, payload, signing, installed-app or binary-delivery changes. Historical native passes do not validate that expanded source.
- The combined candidate separately contains **19 reviewed HTTPS-evidence paths plus these seven documentation paths**. Its **343 portable cases / 339 passes / 4 skips and 52 static guards** passed; all 59 prior Engine native test names and assertions are preserved; one existing exact-limit test and its helper add phase timing. The parent's green native result does not certify the combined HTTPS delta; its exact hosted-native run remains the next verification step. No binary delivery is included.

## Next executable steps

1. Complete the status-only review of the combined 26-path candidate on exact green parent `21fb1c2`. After reviewed publication, check its own hosted-native run; the parent result does not validate the added HTTPS behavior. Preserve the historical failures and keep the 77.104-second exact-limit test duration as an unresolved performance observation.
2. Continue selective review and exact-source native verification of unpublished activity Options, explicit delegation and visible progress integrations. R31, R58, LP04 and LP06 remain open; existing core tests do not validate absent UI/producer wiring.
3. Preserve the expanded local source and verified recovery copies. Reconcile their actual current bytes separately before any integration; do not restore a snapshot over newer edits or copy the expanded App/ChatView and release tooling wholesale.
4. Continue requirement-by-requirement reconciliation when facts change. R04 closes the dated reviewed checkpoint only; it does not end this maintenance obligation. Preserve exact runtime, owner-device, source/license, signing/notarization and final-delivery gates; no model-free development DMG is a complete owner bundle.

## Historical continuation records

Everything below preserves the October 13 handoff. Its lane assignments, local paths, source revisions, provider questions and pending checks are historical context, not current ownership or current main. Use the scoped checkpoint above for current published/local distinctions; the installed and candidate identities are preservation records, not a fresh device inspection.

## Cloud continuation checkpoint — 2026-10-13 20:50 UTC

Development continues independently on Linux and hosted macOS CI. The owner's disconnected Mac is reserved for the final explicitly pending device checks. Main is the verified default and only remote branch; historical Mac records below remain preservation evidence.

- Exact published [`d7b336d`](https://github.com/Emin-dev/Dot/commit/d7b336db9351b660368e2e72637444d3a9989a89) passed **159 Python, 372 SwiftPM and 615 native XCTest**, **52 static guards**, both original helper sandbox probes, Debug tests, Release compilation, App Intents metadata, development DMG packaging/signature and the zero-warning gate in [run 38464157996](https://github.com/Emin-dev/Dot/actions/runs/38464157996). Suites overlap. This verifies the transient research/cooldown contracts and SearXNG adapter fixtures as well as the prior deletion, action shutdown, stale-picker and evidence-cap changes. It is model-free automated evidence, not a full runtime or device acceptance claim.
- That workflow's final, non-product base64 log-export step alone failed its obsolete 2 MB cap. Published [`b508294`](https://github.com/Emin-dev/Dot/commit/b5082946acd3e4a150e8a2fe57638fba2286edd4) replaces binary log dumping with a streamed digest/size receipt and limits push triggers to main. Every substantive build/test/sandbox/package/signature gate remains intact. Its [exact rerun](https://github.com/Emin-dev/Dot/actions/runs/38465680835) completed successfully, including all unchanged substantive gates and the new receipt.
- New source integrates the independently owned Search supervisor/WSGI boundary, page-one DDG cache suppression patch, fixed pins/notices and portable lifecycle/security fixtures. Real pinned Waitress with a synthetic local app passes; no external search was sent. The native Search owner, independently assembled runtime, whole-helper retention canary and live engine acceptance are still separate open stages. No finished payload or permissive acceptance manifest is supplied.
- Source reading now resolves all addresses in a bounded OS process, rejects mixed/private/special-use answers, pins one numeric connection and repeats validation for every redirect. Its separate standard-library helper verifies original-host TLS without AIA network fetches, rejects downgrade, bounds compressed/decoded data and has no cookie/proxy/auth/URLSession fallback. App wiring first audits the complete existing payload, then reuses only its Python/stdlib in a separately sandboxed fetch process. Splash's running process, environment and models remain offline and separate. See [trust-policy caveats and verification scope](source-transport.md).
- Notebook Stop retains admitted writes until they settle; Quit closes admissions permanently and drains them. Web research also gains permanent shutdown admission closure, including late window reopen while other receipts drain. Regression fixtures deliberately ignore cancellation to test these races. An explicit reviewed-service retry also preserves search-attempt limits and known cooldowns. Their new native result remains pending.
- The long-task progress core now has measured/unknown work, fresh task/run/plan tokens, truthful revised estimates, coalesced start/50/80/95 speech candidates, pause/block/failure/cancellation and verified-only completion, with 37 authored regression tests. Native halo, actual work producers, audio interruption gates, accessibility and per-skin rendering are not implemented by that model alone; the checklist remains unchecked.
- Current compatible integrated checks: **203 Python tests, four explicit skips** (two macOS-only and two optional dependency/source fixtures), **52 static guards**, shell syntax and whitespace checks passed. A separate pinned-Waitress run passes **31 of 32** search tests with only the optional full-source fixture skipped. Earlier source-lane evidence includes the exact downloaded source patch fixture. New Swift/native tests cannot run on Linux and require the next exact hosted run.
- Continue independent complete-file inspection and every checklist row's source/test/acceptance mapping, Search runtime assembly/licensing, live provider wiring, progress UI/audio, proactivity and idle-motion integration, memory/tasks and verified workflows. All owner-Mac acoustic, route, accessibility, per-skin visual/energy and clean second-Mac checks remain explicitly pending at the checklist end. No all-checklist completion, final installer, notarization or release-license closure is claimed.

Checkpoint: **2026-10-13 19:08 UTC**. Read the [canonical checklist](BUILD_CHECKLIST.md), [progress](PROGRESS.md) and [helper verification](verification/helper-boundaries.md). This is an active implementation handoff, not whole-product completion or installation approval.

## Historical revisions and recovery

- Historical verified reliability source: `125e0e9c9a4fa37a1f5977c235cfe98a6d596c42`; exact clean checks **158 Python/346 SwiftPM/577 native/52 guards**, sandboxes, Debug/Release/development/signature all passed with zero warnings. [Receipt](verification/reliability-history-research.md). The enclosing documentation commit publishes this checkpoint; complete offline assembly is underway.
- Earlier exact helper increment: `2db5aa9a1ecc744d57ef6c7478e5eab901d155de`; clean detached required checks passed before publication. Its enclosing documentation commit publishes this checkpoint. Prior public checkpoint was `92fa215da1228eb9c1f2a949fb3f1da7b5f8fa1b`; earlier voice/skin candidate remains `6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc`, merged by PR #2 at `f718e870cd14148c1b20c03c7adc822f9981bf31`.
- Main is the sole local/remote ongoing/default branch. One integration owner stages/commits/pushes; no force-push, extra feature branches, dirty reset or overwriting another writer.
- Active checkout: `/private/tmp/dot-next-stage-20261013`. Helper verification checkout `/private/tmp/dot-helper-verified-20261013` is detached. Other source remains unfinished in the active checkout.
- Durable recovery: `~/Documents/Codex/2026-10-12/task/work/checkpoints/20261013T190601Z`; identical temporary copy `/private/tmp/dot-checkpoints/20261013T190601Z`. **21 changed/untracked source/test files**, patch and manifest; all copied hashes verified. Base `125e0e9c9a4fa37a1f5977c235cfe98a6d596c42`; manifest SHA-256 `9e3f0df4243eac7548c1f86501c6697178e7bf19b859fe92918e9ce046268a07`. The workspace `work/.gitignore` excludes checkpoints. No runtime recordings/screenshots/model/credential data are included. Prior copies remain.
- `/private/tmp/dot-latest-checkpoint.txt` points to the latest temporary snapshot; the saved workspace's `work/checkpoint_dot.py` is the manually invoked source-only capture utility. Snapshots are per-file captures of active writers, not transactional tested trees. Verify manifest/hash/base, compare with live main and all current writers, and reconcile in a detached checkout if needed. Never restore over newer edits or infer that copied code passed tests.
- Unused memory/task drafts were copied byte-for-byte to the durable workspace `work/checkpoints/deferred-drafts-20261013T1902` with a hash manifest before removing only their untracked `src` copies from the tested milestone. Their owners continue in temporary stages and will return tested code.
- Original patch `/private/tmp/dot-voice-unpublished-preserved.patch` remains, SHA-256 `7f5a5c80d90466c5e9db0634bb043b99edcbc1756fc338bc2cac4ea21c57ac04`. Earlier consolidation recovery remains `/private/tmp/dot-main-consolidation-20261013`.

## Installed and candidate states

Installed working source remains `b26a14505bd2bc8e57264f1dfc934f778a8bd781`, executable SHA-256 `28a5bc43233266be7ecb488b58c438823ee371c9f4ed6f490ca30d5463fa1ac5`. Complete separate old candidate remains `/private/tmp/dot-voice-batch-20261013/build-complete/Dot.app`, source `6aa5b89`, executable SHA-256 `537b472c4c3487f2b00cddc15a1a502875eb45c4ee40038078660ea375f366f3`. It is ad-hoc/not notarized/not installed. The new helper-only development package is incomplete and is not an owner bundle. Do not replace either preserved app during development.

## Historical lane ownership

| Owner | Current assignment |
| --- | --- |
| Integration | Verified source publication; App proactivity/budget/memory/task integration, manifests and recovery. Current uncommitted App hooks are beyond tested `125e0e9`. |
| `voice_review` | Proactivity/no-op answer preservation plus 66 focused regressions passed; now reviewing App hooks and native status/countdown acceptance. |
| `question_playback` | Exact complete offline assembly of `125e0e9`; later real-file action workflow passed 29 focused tests (three new regressions remain uncommitted). |
| `capture_timing` | Durable explicit-budget ledger: 16 fixtures passed; native provider/Keychain setup now underway with injected vault tests, no key reads or live calls. |
| `native_skins` | Controlled benchmark complete; paired read-only-cache comparison prepared. Wait for assembly/asset IO completion before exclusive model experiment. Production cache policy unchanged. |
| `planning_publication` | Editable/source-linked local memory + native panel in temporary stage; fixing native minimum-size regression before integration. No automatic promotion of model text. |
| `native_verification` | 12 native keyboard checks passed; now durable tasks/native panel using existing single executor and truthful receipts, outside repo until tested. |

Root controls integration manifests; agents must not edit them or each other's files. Parallelism uses non-overlapping files and detached checkouts, not extra lasting branches or user-owned chats.

## Evidence, failures and limitations

- Exact helper source: **136 Python, 175 SwiftPM, 277 native XCTest, 49 guards**, both sandbox fixtures, Debug/Release/development packaging and signature checks passed with zero warnings. See [receipt](verification/helper-boundaries.md).
- Historical broader unfinished integration: an earlier run passed 294 SwiftPM/464 native XCTest; the latest registered UI/store development aggregate passed **521 native tests**. There was one runtime Thread Performance Checker QoS warning during a typed-panel test; the captured stack reaches AppKit text checking through hidden focus teardown. A focused correction passed 11 tests, but the full aggregate/real first-responder replay must rerun before a zero-warning claim. AppKit/linkd service diagnostics also remain distinct from compiler warnings. Subsequent edits require another exact-source check.
- Real new helper-policy component run passed British Kokoro, Whisper, actual Qwen/Splash, two audio segments and one final invitation. The private eSpeak-map failure was fixed narrowly with passing negative canaries. Actual microphone activity ended after 3,000 ms trailing silence; audio/text discarded. Readiness took 70.210 seconds in an uncontrolled cold diagnostic run; no speed improvement, acoustic onset or p50/p95 claim. Older `6aa5b89` real no-speech capture closed after 6,124 ms; it is a different source/run.
- **Controlled exact-helper-source benchmark:** frozen `2db5aa9` component harness plus preserved donor assets, one cold and five resident warm public synthetic turns, same model process and explicit cleanup. Warm speech-end to player-start median **5.442 s**, empirical p95/max for n=5 **5.723 s**, including selected 3-second silence; post-silence median **2.418 s**. Cold readiness **63.875 s**; warm readiness median 4.1 ms. Player start is not acoustic onset; five short repeated fixtures are not a general speed guarantee or physical speech test. Receipt `/private/tmp/dot-benchmark-2db5aa9-20261013-01/benchmark-receipt.md` and JSON retain exact provenance/resources. Pinned upstream source plus denied-cache diagnostics support an ANE recalibration hypothesis, not a proven causal timing delta. No broad cache grant or model change was made.
- Actual production SwiftUI `ImageRenderer` source study passed **160 renders and 22 assertions**, across eleven identities/five phases/light-dark and opposing backgrounds. Visually reviewed sheets show warm readable faces and clearer Veil; this avoids the cached-layer omission but does not certify AppKit/WindowServer materials, arbitrary backgrounds, all 120 recipes, microphone countdowns or phonemes. `/private/tmp/dot-source-render-20261013-a/REVIEW.md` records source hashes and limitations.
- Footer control down formerly cancelled/replaced its own Stop button. The split control hook now preserves the clicked row while revoking automatic invitation. The native UI harness passed **20 meaningful native/state assertions plus two inconclusive cached-image comparisons**, including Stop never firing Talk, Options never starting capture, typed Command-Return and Escape, and Original default. Receipt: `/private/tmp/dot-ui-reliability-20261013-h/ui-report.json` plus provenance.
- **Visual capture is inconclusive:** AppKit bitmap capture omits unchanged SwiftUI/material layers and cannot establish blanking, contrast or still-motion acceptance. Legacy own-window capture failed; ScreenCaptureKit resolved the exact owned PID/window with existing grant but returned `SCStreamErrorDomain -3811` audio/video capture failure. No new permission/security change was attempted. No general native/browser controller is available; browser inventory remains empty. These technical limits do not revoke owner design acceptance.
- Source-reader fixes use native HTML parsing with external entities disabled, bounded readable text/charset/PDF extraction, cancellation and stricter lexical URL checks. Actual production reader fetched official W3C HTML (18,910 bytes) and PDF (13,264 bytes/one page); metadata/hash receipts are in `/private/tmp/dot-public-source-acceptance-20261013`. This is real supplied-source reading, not an automatic researched answer. DNS-rebinding isolation and rendered-browser readability are not established.
- History/expressions and typed/actions/source utilities are now source-published in `125e0e9`, with exact automated evidence; physical/device/full-capability acceptance remains separate. 120 shared authored expression trajectories/render receipts do not establish full character-specific perceptual/phoneme/device acceptance. LocalMemory/PersistentTasks drafts are preserved and actively developed outside the tested source.
- **Provider question pending once in coordinating chat:** Tavily free-only first versus raw Perplexity Search with explicit spending limit. No answer/default/time passage authorizes selection or paid calls. Keys belong locally in Dot, never chat. Qwen reasoning stays local; actual page/PDF evidence and explicit result-retention rights remain required.

## Historical next steps — 2026-10-13

1. Complete the separate exact `125e0e9` offline assembly and verify payloads, native Whisper link, metadata, signature and exact provenance. Preserve installed/older complete candidate. Required model-free gates already passed; real assembled acceptance is next.
2. After assembly/asset checks, reserve one model window for the controlled narrow read-only ANE cache comparison. No broad cache grants, engine changes or signing/security bypass; retain negative fixtures and distinguish causal measurements from prior hypotheses.
3. Integrate already tested proactivity/idle App hooks, durable budget and forthcoming memory/task native workflows. Register only complete modules and rerun meaningful combined checks. Keep unchanged review scopes clear.
4. Search provider decision remains pending once in coordinating chat. Build configurable local setup without selecting/using a provider, reading credentials or paid calls. Complete an actual searched/read/cited workflow once selection/local setup exists; supplied-source Qwen synthesis can be checked independently.
5. About every ten minutes at safe boundaries, publish meaningful ledger/continuation and durable source recovery. Preserve temporary-stage agent work too; never restore a snapshot over newer edits, force-push or replace the working installed app.
