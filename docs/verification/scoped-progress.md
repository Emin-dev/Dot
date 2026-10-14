# Scoped progress and native-rig evidence

Checkpoint: **2026-10-14 16:16 UTC**. Scope: documentation and four approved requirement closures only. R04 covers the dated reviewed all-row reconciliation; this is not a fresh full semantic source audit, runtime build, device acceptance or release receipt. Continue reconciliation as work proceeds.

## Published and expanded source remain distinct

The integration owner verified the published parent as `21fb1c24d2d061bd46995d7cfcd7e6a4c8c40432`, tree `dc737d2237170e50675a6b0187f3feb0c1c92065`. This status update independently reconstructed that exact tree from all 238 supplied parent source files. Before this tranche its canonical Markdown/text companions have 0 checked current requirements and 97 open, plus five checked historical milestones.

The expanded local ledger has R04, R17, R50 and R66 complete after the dated R04 review: 4 of 97 current requirements, 93 open. This tranche carries exactly those four scoped closures into the canonical companions, without changing the requirement wording, order or any other checkbox. It includes the approved R17 and R50 reports verbatim. References in those reports to their original staged publication state, inspected local source or accompanying evidence archives describe their dated review context. Those larger source/evidence archives are not included here, and the reports do not establish native acceptance of that expanded source.

The expanded source, its current-product acceptance validator (`scripts/current_product_acceptance.py`), and its changed complete-build/package enforcement are **not added by this documentation delta** and are absent from the 238-file base as an integrated capability. This documentation delta leaves the base's existing complete-build/package scripts byte-identical and includes no new code, tests, workflow, release infrastructure, signing changes, payload or binary delivery. These scope statements do not describe separately reviewed source/test changes in a combined commit. Existing installed and candidate apps remain outside this documentation delta.

## R04: dated reconciliation complete, maintenance continues

Exact requirement:

> Reconcile this ledger with exact commits, tests, device checks and concrete unresolved prerequisites as work proceeds.

The fresh **2026-10-14 15:28 UTC** all-row reconciliation and independent recheck cover all **102 canonical rows**, the **306-file preserved checkpoint**, all **199 mapped source-file hashes**, and exact native/portable receipts. The reconciliation records the distinct published 0/97 and pre-R04 expanded 3/97 counts; approved R04 closure then makes the expanded and this documentation tranche's counts 4/97. It explicitly distinguishes `1fbd42f` green, superseded `2d28437` compile failure and `f0a0751` CI running at the time of that review, rather than transferring an older pass to new code. The terminal `f0a0751` failure at 15:32 UTC and the later green `21fb1c2` parent supersede that pending observation and are recorded below; the dated R04 maintenance obligation continues.

The saved reconciliation JSON SHA-256 is `7b7abb85c8550fdb876c68cedf444afff2124f39b615c3e628b90b7affc1e0bb`; its 306-file checkpoint-manifest SHA-256 is `51f8dcb719ad54b6beb9844a9744d443d74d42e9176c4ef51009c8a745e32af3`. The independent 15:28:59 UTC recheck passed (addendum SHA-256 `f592fc3d699e2b29207eecd506a2efc88f9695d48fd4d60d6d9dddd0952600df`). The subsequent 15:29:30 UTC closure ledger records the four scoped completions (SHA-256 `241652f73c994d90834d8ae4739a13f5bf8ab27b260a7e5b3eff1102beca6ab8`). Approval is bound to the preserved reviewed inputs; later local edits are separate deltas. Expanded portable evidence is **818 cases / 816 passes / 2 macOS skips**, **52 static guards**, and **50 acceptance-contract tests**, with a later focused **57-test** contract receipt after R66. These are saved scope-specific results, not a new aggregate or native pass for the full expanded tree. Earlier source-coverage counts that mention only R17/R50 describe an older receipt and are not current completion counts.

The reconciliation preserves owner-provided device evidence and unresolved prerequisites: incomplete model-hash closure and runtime reconstruction/native probes; exact Whisper input; current Search canary and provider acceptance; unpublished Swift integrations; owner-device acoustics/accessibility; Developer ID/notarization and full distribution. The installed app is unchanged. This closes the **dated maintenance deliverable only**. Reconcile again whenever source, tests, device evidence or prerequisites materially change; no other requirement is promoted.

## R17: design complete

Exact requirement:

> Design staged Swift/Rust service boundaries for coordination, tool execution, research, indexing, history and memory; keep Apple framework adapters thin and the UI responsive.

The [service-boundary design](../architecture/staged-services.md) covers the requested owners and staged boundaries, retaining thin Apple adapters, one resident Qwen/Splash engine and existing authority/persistence contracts. Its status is **design complete only**. No Rust migration, performance improvement, native compiler pass or current complete-runtime acceptance is implied; R14 and related implementation/performance requirements remain open.

Preserved report SHA-256: `78ce31b33b17e579ddf80974435899090e8927211b7499d87db193d48e63fe04`.

## R50: bounded research complete

Exact requirement:

> Research the separate **T3-Video-Wan2.2-5B** feature and Apple Silicon resource/runtime fit. It is not a dependency of the fast voice path and must not silently replace its models.

The [video feasibility report](video-feasibility.md) identifies the requested T3 checkpoint, published dependencies, licensing/provenance limits, CUDA-oriented execution path, Apple backend uncertainty, resource estimates and a gated optional experiment. Its conclusion leaves both 36 GB and 48 GB hardware **unaccepted for video**. No model download, execution, Mac port, video implementation or measured Dot/video benchmark is claimed. The fixed voice/model stack and fast-voice priority remain unchanged.

Preserved report SHA-256: `a52c0c34819f9aa79850aa6113a67895a0f4b5a5423862d6d6f6fc7df01a261b`.

## R66: shared-native-rig architecture complete

Exact requirement:

> **Use a shared native rig for ten new identities while retaining Original.** Combine brows, eyelids, pupils/gaze, cheeks, mouth, head and body posture, with anatomy-specific controls such as wings or leaves. Prefer SwiftUI phase/keyframe animation and Core Animation before adding a custom rendering engine. A genuine 3D implementation would be a separate measured choice. [Apple animation timing](https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations)

Exact green source `1fbd42f4855fafdc0a204215c0e61fc948794397` retains Original as the default and routes the ten new identities through a shared native SwiftUI pose/artwork path. `SkinPreferences.swift` defines the eleven choices; `NativeCharacter.swift` preserves Original, maps brows/eyelids/gaze/cheeks/mouth/head/body channels and supplies Pip wings and Sprout leaves; `NativeExpressionLibrary.swift` supplies common poses and deterministic keyframes/interpolation. The real app already uses that native rig. A genuine 3D engine is not introduced or required by this closure.

The [exact native job](https://github.com/Emin-dev/Dot/actions/runs/38580226726/job/115907856013) passed **13 NativeSkinTests** and **11 NativeExpressionLibraryTests**, including all-eleven native rendering, persistence/default identity, distinct appearances, shared trajectories, replacement/cancellation/motion suppression and bounded geometry. These three source files and both test files remain byte-identical in the `21fb1c2` parent and this combined candidate:

| File | SHA-256 |
| --- | --- |
| `src/SkinPreferences.swift` | `5599ab8a20955820362de81614af07be4bf43f75e7b8cd469cd1cdf2c6b3ff72` |
| `src/NativeCharacter.swift` | `0c6c0420766d014b165401af1ae3314b4e9019f791c3fbde4d53cd01fc6adb80` |
| `src/NativeExpressionLibrary.swift` | `61a4a64318538db34f2dd11340948aabade4e515ed9037cb0999f368a65a5b99` |
| `Tests/DotCoreTests/NativeSkinTests.swift` | `93e302110acc75ea3c9c869d680d8ef112d298e496cf6b5f407906901caebfac` |
| `Tests/DotCoreTests/NativeExpressionLibraryTests.swift` | `725694f7888f2be8075c9ca2f9f2fe29d8ef50b9622b433fd93e12766b026ffa` |

This closes **architecture only**. Owner-device appearance, friendly-face/perceptual acceptance, 120 reviewed meaningful recipes per new identity, phoneme/audio synchronization, actual glass compositing and energy/performance remain separate open requirements. Pixel-distinct rendering does not close those scopes.

## Commit-specific native chronology

- **`1fbd42f` green:** [run 38580226726](https://github.com/Emin-dev/Dot/actions/runs/38580226726), job 115907856013: 320 Python cases, **317 passed / 3 skipped**; **486 SwiftPM** and **759 XCTest** passes. Debug/Release/development packaging/signature and the zero compiler-warning diagnostic gate passed. The complete log SHA-256 is `1ac54c65ee668cee828fe91aca648d13fcd58065a5205a449dcf1e18326fb8c8`. RenderBox/cache runtime diagnostics remain in the log. The package was model-free, ad-hoc signed and unnotarized; no binary artifact was delivered.
- **`2d28437` failed:** [run 38587675693](https://github.com/Emin-dev/Dot/actions/runs/38587675693), job 115933909146, commit `2d28437a560638074eb9c835349990dcaea3cba2`: **333 Python passed / 3 skipped**, **486 SwiftPM passed**, then native compilation stopped on `ResearchEngineTests.swift:752`, where mutable `weakTransfer` was never mutated under warnings-as-errors. XCTest and packaging did not execute. Complete log SHA-256: `ef4b6f7fb8398fb62ca99a33a5af5b8a5ff452fd1ddd0ad897415cd0561bc6ba`.
- **`f0a0751` failed at 15:32 UTC:** [run 38589346500](https://github.com/Emin-dev/Dot/actions/runs/38589346500), exact commit `f0a07513c3dde21b3638207c2b63343035366185`: the weak-binding compile warning is resolved; **336 Python cases / 333 passes / 3 skips** and **486 SwiftPM cases passed**. The native suite executed **788 XCTest cases with 11 failures (2 unexpected)** across four new transport cases: redirect denial/error handling, cancellation of a pending byte consumer, completion/invalid-response transport settlement, and research cancellation/Quit drain joining the actual transport. The test build exited 65; Release, packaging and signature gates were not reached. Complete log SHA-256: `30962731a106ea460f9dfad7718c01eb6ef0a522d3ec045d3f108e8b4c1d1d26`. This historical failure is superseded by the exact green `21fb1c2` parent below; it is not relabelled as passing.

- **`21fb1c2` green at 16:11 UTC:** [run 38594414249](https://github.com/Emin-dev/Dot/actions/runs/38594414249), [job 115957311020](https://github.com/Emin-dev/Dot/actions/runs/38594414249/job/115957311020), exact commit `21fb1c24d2d061bd46995d7cfcd7e6a4c8c40432`, tree `dc737d2237170e50675a6b0187f3feb0c1c92065`: **337 Python cases / 334 passes / 3 skips**, **486 SwiftPM** and **789 XCTest** passes. Debug/Release/development packaging/signature and the zero compiler-warning gate passed. Complete log SHA-256: `72ca5f9e5a48f125936ffe1b36be69ea8b0a7bf30e3ea304f77b835b8f28d7d4`. This exact parent resolves the earlier native failures; it does not certify the additional HTTPS changes in the combined candidate.

## Transport observations and combined-candidate boundary

The native MIME counterfactual recorded **untyped held empty/small responses timing out at 577/601 ms**, while typed responses delivered headers immediately (**0 ms recorded**) for both bodies. All four actual transport receipts recorded completion and invalidation. This is the observed fixture behavior, not a universal network-timeout or header-latency guarantee.

The exact-limit/large-callback/post-suspend-overflow test passed but took **77.104 seconds**. That remains an **unresolved performance observation**; the functional pass is not a speed claim or evidence of acceptable user-visible latency.

The prepared combined candidate contains **19 independently reviewed HTTPS-evidence paths plus this seven-document delta**, all 26 paths checked. Its saved portable run passed **343 cases / 339 passes / 4 skips**, with **52 static guards**, and preserves all **59 prior Engine native test names and assertions**, with phase timing added to one existing exact-limit test and its helper. The documentation delta itself changes no source behavior. The previous Engine-green publication prerequisite is satisfied and the candidate is based on that exact parent; its combined HTTPS behavior still needs its own hosted-native verification after reviewed publication. No new binary delivery, complete-runtime acceptance or product/release closure follows.

Suites overlap and must not be added as unique test counts. Model-free hosted checks do not establish full neural-runtime inference/voice/search behavior, owner-Mac acoustics or accessibility, clean second-Mac installation, license/source closure, signing/notarization or final DMG acceptance. Those gates remain open. R31 activity Options, R58 explicit delegation, LP04 visible verified-progress integration and LP06 distinct status/control/no-microphone-invitation integration also remain open pending their exact selective native acceptance.
