# Dot implementation and delivery handover

**Development and monitoring are stopped.** The owner's latest instruction is: “stop all work , stop all tasks. upload latest edits to GitHub so team can continue. then don't touch anything. send me handover now”. This supersedes earlier instructions to continue autonomously. Only the final safe publication/handover is authorized now. All four project automations were verified disabled at 23:37 UTC. The incumbent integration owner relinquishes implementation ownership after that final handoff. The continuation plan below is a plan for a newly authorized receiving team, not permission for the current team to resume. Reconcile ownership and access before any future edits.

Prepared for the next AI or human engineering team continuing **Emin-dev/Dot**. This is a product specification, evidence ledger and continuation guide. It is deliberately detailed so that work can continue without reconstructing the project from scattered conversations.

**Document version:** 1.0, checked 14 October 2026 at 23:38 UTC. Application/source content is frozen at `2714811`; latest main and evolving test evidence are separated in the dated addendum. Two review passes checked requirement completeness and source/evidence accuracy; the exact 102 ledger texts and stable IDs were matched independently.

**Bottom line:** the product direction is agreed and implementation was previously authorized in tested stages; the current session is stopped. The complete new product and final working DMG are not finished. The canonical checklist accepts **4 of 97 current requirements**, with **93 open**, plus **5 historical milestones** recorded separately. Those numbers describe scoped acceptance, not a completion percentage or the amount of code already written.

**Frozen application/source reference:** [`2714811cb75bb5af935bd33997eebc78c0a63d96`](https://github.com/Emin-dev/Dot/commit/2714811cb75bb5af935bd33997eebc78c0a63d96), tree `3a93cfcd4b661599d31c7ba9bd8fd1078143cab9`. **Latest verified main at 23:35 UTC:** [`a811f6da5acbe12700be899d7dcddd113ca8fefe`](https://github.com/Emin-dev/Dot/commit/a811f6da5acbe12700be899d7dcddd113ca8fefe), tree `ce0d98eed8efecb8e11043b2221e6dc0cbd33e6f`. The follow-on changes one TLS test fixture, not application/runtime behavior. Final publication and CI may advance; verify the final receipt instead of assuming it is captured here.

**Scope:** Dot only. This document does not authorize work on Rentbutik, Emin-dev/Rentbutik, Emin-dev/figma or any other repository. Do not change the installed application, acquire paid services, bypass security gates or treat a planning document as runtime approval.

## Instructions to receiving AI or team

Use the following short prompt to begin. Read the detailed specification before acting. This handover transfers project context, not access, assets or permissions. The incumbent controls final safe publication only, then relinquishes ownership. Resume requires a fresh owner instruction and a coordinated new writer.

### Copy and paste start prompt

> The previous development session was stopped at the owner's request. Once the owner authorizes your receiving team to resume, continue the native macOS companion in Emin-dev/Dot using this handover and the latest canonical docs/BUILD_CHECKLIST.md. First inspect current main, working-tree changes, ownership, exact CI results and preserved unpublished work. Establish an explicit coordinated ownership handover; do not begin competing edits or pushes. Main is the only ongoing branch. Preserve unfinished work and the installed app; never force-push, discard/reset work or weaken an assertion/security gate to obtain green tests.
>
> Preserve the fixed local Qwen3.8-27B-4bit plus DFlash2 target/draft/vision selection, Splash 1.3.1 and warm British female Kokoro bf_isabella reference. The next working owner DMG must include the required models and runtimes and work offline without external folders, server setup or a first-run model download. Online research is a separate network-capable feature with local reasoning, free-only search and safe source reading. Keep Original as the default and all ten approved new skins, including Veil replacing Fold. Keep exact silence/invitation timings, final-audible-question gating, foreground priority, friendly faces, real progress and privacy boundaries.
>
> Treat the 97 current checklist rows, 5 historical rows and 6 broader workflow obligations below as distinct. Only R04, R17, R50 and R66 have scoped current acceptance. Separate source, portable tests, hosted-native tests, real runtime/device behavior, installation, owner acceptance and public distribution. Start by establishing the current exact-source native and Search failures/results, then close the runtime/Search/asset prerequisites without bypasses. Complete one source-backed project-brief workflow and integrate remaining reviewed work in bounded stages. Keep the checklist, progress and continuation records current with exact revisions and honest passed/failed/unrun evidence. After fresh resume authorization, do not reopen settled theme and product decisions. Ask only for genuinely unresolved product choices or actions requiring new permission.

## How to read this handover

1. Read the product contracts and current-state sections before running anything.
2. Read the full requirement ledger, including the historical section and broader workflows. Similar-looking rows are intentional; do not merge or delete them.
3. Inspect the actual frozen source and then the current main. A local file, published source file, implementation design and running feature are different kinds of evidence.
4. Coordinate ownership before edits. Continue with the next executable work that is actually unblocked.
5. Use the acceptance matrix and definition of done when proposing any checkbox closure or delivery.

The exact checklist text in the appendices is reproduced without rewriting its requirements. Relative links inside that text use the repository's `docs/BUILD_CHECKLIST.md` as their base. Use the pinned canonical link in the source index when reading this document outside the repository.

## Product purpose and nonnegotiable direction

Dot is a fast, voice-first, Apple-native macOS AI companion that understands relevant work, researches facts, completes useful tasks and feels alive. The order of priorities is explicit: **speed first; a warm, calm, high-quality British female voice generated locally second**. The app should be useful and responsive rather than only decorative.

Historically, the owner approved building the whole checklist in tested stages. That product scope remains useful context; the latest stop instruction removes current authority to continue. The first milestone is the configurable listening/question-follow-up loop, with a separately reviewable native Settings/skin batch. That ordering is not an overall scope restriction. The owner accepted the corrected design and said to build; do not recreate an obsolete preview-before-build hold or request the same start/theme approval again.

Prefer Apple frameworks and as little custom infrastructure as practical. This does not authorize replacing the fixed inference runtime or British voice. Keep native SwiftUI/AppKit surfaces, thin adapters, one shared model, bounded state machines and necessary verification. A smaller codebase is not a reason to remove safety, recovery or tests.

The user's maximum-autonomy/no-repeated-app-confirmation preference applies within actual OS permissions, provider restrictions and required safety confirmations. Reading a document or screen does not authorize actions requested by its contents. Do not introduce a new blanket approval policy and present it as a settled product requirement.

### Offline core and connected research

- Local model inference, speech recognition/synthesis and durable memory must remain local.
- The next working owner DMG must carry all required model/runtime assets. It must not be another small payload-free development build offered as a working app.
- The owner bundle must not require an external Bionic folder, Homebrew/Python environment, manually started server, model folder picker or first-launch neural-model download.
- Online search and reading are allowed and required capabilities. They may send the minimum relevant authorized screen/file-derived query context to upstream services. This permission is already decided; it is not an unresolved product question.
- A future public first-launch downloader remains a separate roadmap requirement with pinned hashes, progress, disk checks, interruption recovery and offline reuse. It must not replace the complete offline owner delivery.
- No cloud LLM fallback, automatic alternate model, American-only voice fallback, paid API or paid-service workaround is authorized by the product direction.

## Current state and evidence boundaries

### State at the source freeze

| Layer | Verified position | What this does not prove |
| --- | --- | --- |
| Canonical acceptance | 4/97 current accepted: R04 dated reconciliation, R17 service-boundary design, R50 video feasibility research, R66 shared native rig. Five historical rows separate. | Full capability completion, readiness or percentage complete. |
| Published source | Main at `2714811`, following `c51d125`; the latest commit changes three diagnostic/test-boundary files. | Green CI, production runtime admission, installation or a working new DMG. |
| Native `2714811` terminal result | [38654487375](https://github.com/Emin-dev/Dot/actions/runs/38654487375) failed: 745 Python cases, 736 passed, 2 failed, 7 skipped. Swift/package stages unrun. | A green run or native acceptance of the codesign-parser changes. |
| Search `2714811` terminal result | [38654487192](https://github.com/Emin-dev/Dot/actions/runs/38654487192) passed portable gates, payload reconstruction and real C/Swift build under Xcode 26.3/SDK 26.2. The first success-close runtime scenario failed `owned-process-failed`; six remained pending. Original profile startup still exited SIGABRT 6. | Actual Search runtime/citation acceptance, a confirmed root cause or an overall pass. |
| Latest native `a811f6d` terminal result | [38654917413](https://github.com/Emin-dev/Dot/actions/runs/38654917413), job 116162281606, failed at 23:36:53 UTC: 745 Python cases, 737 passed, 1 failure, 7 skips. The actual refused-connect fixture passed; the backpressure `wait_workers == 0` assertion still failed. Swift/package stages were unrun. Search did not retrigger for this path. | A pass, confirmed production root cause or authority to resume monitoring. |
| Previous exact native `c51d125` | [38653461141](https://github.com/Emin-dev/Dot/actions/runs/38653461141) failed: 742 Python cases, 733 passed, 1 failure, 1 error, 7 skips. It stopped before the later Swift stages. | Later-stage results or acceptance of that source. |
| Previous exact Search `c51d125` | [38653461155](https://github.com/Emin-dev/Dot/actions/runs/38653461155) failed in portable prerequisites: 147 cases, 145 passed, 1 failure, 1 skip. Payload/native stages were unrun. | A Search-runtime failure diagnosis from stages that never executed. |
| Earlier native `86028d5` | 725 Python passes/7 skips, 600 SwiftPM passes/7 skips, 909 XCTest passes, Debug/Release compiled. Mandatory runtime-finalizer descriptor gate failed; packaging was unrun. | An overall green run or current runtime/installer certification. |
| Latest fully green historical native source | [`1b9f949`](https://github.com/Emin-dev/Dot/commit/1b9f949d7cca8fda526af07515762a388123007b), [38609622847](https://github.com/Emin-dev/Dot/actions/runs/38609622847): 467 Python cases, 460 passed/7 skipped; 506 SwiftPM and 815 XCTest passes; development packaging/signature and zero-warning gate passed. | Later changes, real neural runtime or whole-product/device acceptance. |
| Installed personal baseline | Historical source `b26a14505bd2bc8e57264f1dfc934f778a8bd781`; owner reported voice and screen-aware replies working. Later read-only observation reports v1.1.0 build 2, approximately 20 GB. | That current source is installed or that every installed asset/hash has been freshly validated. |
| Preserved earlier assembled candidate | Exact `6aa5b89`, later merged through PR #2, had model/runtime assembly and native source checks. It was ad-hoc signed, unnotarized and uninstalled. | Current final delivery or final owner acceptance. |
| Current complete working DMG | Not delivered or accepted. | Any inference that a model-free CI artifact is sufficient. |

Suites overlap. Never add Python, SwiftPM and XCTest totals and describe the sum as unique cases or end-to-end coverage. A skipped opt-in real fixture is unrun, even when the surrounding suite passes.

### What the latest three-file change actually does

The published `2714811` correction:

1. Observes the scrubbed shell environment directly with `/usr/bin/env`, rather than through the macOS Python shim that can add developer-tool environment variables. It strengthens exact expected-map checks, includes empty/nonempty runner labels and hostile caller variables, and does not authorize forwarded caller state.
2. Accepts the observed narrow no-break space U+202F only within a strictly bounded optional `Signed Time` diagnostic field from codesign. It preserves raw bytes and rejects malformed, duplicate, oversized or unrelated Unicode/control text.
3. Adds positive/negative regression coverage. The timestamp is diagnostic text, not identity, trust, an Apple anchor, a runtime admission or a substitute for the original mandatory gate.

`c51d125` already contained a reviewed nonblocking TLS shutdown change and the fixed Xcode 26.3 Search toolchain selection. Their existence in source is not native acceptance. The separate TLS failures still need exact-source diagnosis: Darwin can leave a bound but non-listening TCP endpoint dropping SYNs rather than producing immediate refusal, and a send-deadline fixture was anchored to an earlier transient WANT event. These are investigation leads, not permission to loosen deadlines or assertions.

### Published source versus preserved expanded work

This distinction is essential. The expanded local work includes files and composition that are **not in the frozen published tree**. The architecture design explicitly inspected a dirty expanded source snapshot. Its type inventory is useful as a design/handoff, but it must not be relabeled as a description of what main currently runs.

At `2714811`, `src/App.swift` constructs `WebResearchModel` with a source reader and local synthesizer **without a provider**. It does not yet configure the full owned Search provider in the app. A source-defined manager, broker or test harness does not make live research available in the product.

The following expanded files were specifically confirmed absent from published `2714811`: `src/EvidenceMemory.swift`, `src/ProjectSourceIndex.swift`, `src/LocalRecordDatabase.swift`, `src/TaskProgressController.swift`, `src/NativeDelegation.swift` and `src/ProactiveSuggestionPanel.swift`. Local copies must be preserved and reconciled with current main; do not import them wholesale or imply that their existing local tests validate their eventual integration. Likewise, `docs/current-product-acceptance.md`, `docs/search-runtime-owner.md` and `packaging/search/search-lock.json` are not published at this freeze, despite local copies.

The final handover should include a portable, source-only recovery manifest for unpublished work: base revision, intended file ownership, file hashes, review status, tests actually run and unresolved dependencies. Recover by comparing changes with current files, not by restoring an old snapshot over newer code. No secrets, personal runtime data or model weights belong in an ordinary source recovery bundle.

## Model and dependency contract

### Fixed inference and speech selection

| Component | Exact source-confirmed selection | Role and constraint |
| --- | --- | --- |
| LLM runtime | Splash **1.3.1**, source `f91c91e21dda483f8c59a248a444d0989a560d31` | Single app-owned local inference runtime; not an interchangeable endpoint. |
| Target model | `mlx-community/Qwen3.8-27B-4bit`, revision `10c35caafbb80f7dc6a7a432cdd11af10a6d4818` | Preserve the unusual **3.8** spelling. Do not silently change it to Qwen3.5 or Qwen3. The publisher namespace does not mean MLX is the chosen inference engine. |
| Draft model | `incoai/Qwen3.8-27B-DFlash2`, revision `015e795645c74b1a0eeef3b570031fb62e769bc5` | Preserve the pinned speculative-draft selection with its target/vision configuration. |
| Model inventory | `Resources/bundled-models.json`: **15 files, 19,930,313,310 bytes** | This is target/draft/vision model-payload size, not RAM requirement, complete runtime size or final installer size. Verify bytes, sizes and hashes rather than trusting a filename. |
| Reasoning baseline | Thinking enabled, low effort, 1,536-token budget | Reasoning is not spoken. Preserve baseline behavior unless a separately agreed change is made. |
| Current STT | whisper.cpp **v1.7.6**, English `base.en` / `ggml-base.en.bin` | Bundled native recognition, local batch transcription. Native link/input authenticity and actual acoustic quality remain separate gates. |
| TTS | Bionic-derived Kokoro **82M v1.0**, `bf_isabella`, CPU | Warm British female quality reference; current bridge names `kokoro`, `bf_isabella`, 24,000 Hz and offline mode. No silent system-voice substitution. |
| Speech model source | `hexgrad/Kokoro-82M`, revision `9871713c6a29032f914cee65b617e2b6b3323770` | Config, model and Isabella voice pins are explicit in the source manifest/runtime policy. |
| Voice Python | Standalone CPython **3.11.17**, ARM64 | Separate from Splash's Python 3.13 runtime. Do not merge environments or borrow a developer Python installation. |

The authoritative model identities are in `packaging/splash-vision-source-manifest.json`; physical expected files/hashes are in `Resources/bundled-models.json`. Publisher metadata pins are expected identities. They are not proof that an assembled app contains those bytes. Record independent acquired-byte and final-bundle verification separately.

### Voice dependency closure

`packaging/voice/complete-voice-lock.json` contains **92 target-specific wheels** for CPython 3.11.17/macOS ARM64, and `complete-closure-audit.json` records a passing static closure audit with no unresolved graph items. That audit explicitly performed no package execution and does not certify runtime imports, synthesis, native loading, relocation, signing or final assembly.

Important exact direct pins include Kokoro 0.9.4, Misaki 0.9.4, torch 2.14.1, transformers 5.19.0, tokenizers 0.23.3, huggingface-hub 2.2.0, safetensors 0.8.0, NumPy 2.4.6, spaCy 3.8.16, `en-core-web-sm` 3.8.0, espeakng-loader 0.2.4, num2words 0.5.14 and phonemizer-fork 3.3.2. Curated constraints include spacy-curated-transformers 0.3.1, curated-transformers 0.1.1 and curated-tokenizers 0.0.9. Use the full lock, not this shortened list, to assemble anything.

The older `packaging/voice-source-manifest.json` is explicitly research-only and contains earlier unresolved-closure language and a superseded M3-class note. The later 92-wheel lock supersedes that closure uncertainty for its static scope; it does not supersede native/runtime/licensing gates. The current product hardware target remains M4 Pro-class/36 GB minimum, 48 GB recommended.

### Search selection and source status

`Resources/Search/search-dependency-pins.json` selects SearXNG revision `22c64b8d394b680c7ea96be25f36dad14126420a`, Waitress 3.0.2 and an initial DuckDuckGo engine. Its status is source/server candidate only and `production_payload_assembled` is false. That older pin file is not a production runtime-admission record.

Search is a separate owned loopback helper with explicitly controlled egress and request lifecycle. The source includes manager/broker/protocol/payload code and real-fixture tooling; production Search/runtime approvals remain empty. A reconstructed 4,824-file historical payload is a diagnostic basis, not production approval. Retain exact patched-source, binary, dependency, profile and corresponding-source identities when moving from a historical fixture to a ship candidate.

### Alternatives that remain research or conditional choices

- Jointly benchmark **Parakeet EOU** and **Apple SpeechAnalyzer** for streaming STT, offline provisioning, recognition quality and contention with Splash. No winner has been selected.
- Evaluate native Core ML Kokoro only if full-pipeline quality and performance satisfy the required British voice. Exact Isabella identity versus sufficiently similar British voice remains open. An American-only alternative is unacceptable.
- Apple built-in speech may be an optional profile. Do not promise the exact Siri voice.
- Rust is a staged measured core experiment, not an inference-runtime replacement or a claimed speed multiplier.
- **T3-Video-Wan2.2-5B** is a separately researched optional feature. R50 accepts feasibility research only. Its implementation, packaging, resource budget and hardware acceptance remain open; it must not delay or replace the fast voice path's models.

## Architecture and source navigation

### Native application and effect ownership

The app is Swift/SwiftUI/AppKit with native macOS audio, screen, placement and accessibility adapters. `Dot.xcodeproj` is the app/native-test entry point; `Package.swift` exposes a selected `DotCore` subset, not the entire application. The package declares a macOS 15 development floor. The complete selected Splash runtime requires macOS 26.4+, and new APIs/toolchain choices must be evaluated against the full product target.

The following paths are published at the frozen source and identify responsibilities, not completed product acceptance:

| Area | Primary paths | Read with these boundaries |
| --- | --- | --- |
| Composition and floating shell | `src/App.swift`, `src/CompanionPanel.swift`, `src/ChatView.swift` | App lifecycle, panel, turn orchestration and menu/typed/native utility surfaces. Current web-research construction lacks a provider. |
| Turn logic and timing | `src/InteractionCore.swift`, `src/VoiceFollowup.swift`, `src/VoiceTiming.swift`, `src/VoiceEnvironment.swift` | Explicit turn identity, silence/invitation gates, final playback, route/environment cancellation. |
| Inference | `src/Engine.swift`, `src/BundledSplash.swift`, `src/OfflinePayload.swift`, `src/OfflinePreparation.swift` | Shared runtime ownership, readiness/integrity, source reader admission and bounded transport. The file is BundledSplash.swift, not BundledSplashRuntime.swift. |
| Audio | `src/Speech.swift`, `src/WhisperRecognizer.swift`, `src/BionicVoice.swift`, `src/VoicePipeWriter.swift`, `src/VoiceAudioReader.swift` | Native capture/recognition, ordered synthesis, bounded private audio transfer, playback and cancellation. |
| Character and placement | `src/NativeCharacter.swift`, `src/NativeExpressionLibrary.swift`, `src/SkinPreferences.swift`, `src/ScreenContext.swift`, `src/PlacementCapture.swift`, `src/RoamingCore.swift` | Appearance and visual state remain distinct from semantic task truth and actual device acceptance. |
| History and source material | `src/ConversationHistory.swift`, `src/HistoryPanel.swift`, `src/SourceReference.swift`, `src/SourcePanel.swift` | Delivery-aware records, safe deletion, bounded source references and native UI. The installed old app still has its older history behavior. |
| Research planning and records | `src/WebResearch.swift`, `src/WebResearchStore.swift`, `src/WebResearchPanel.swift`, `src/ResearchNotebook.swift`, `src/ProjectBrief.swift`, `src/ResearchPanel.swift` | State/budget/citation/retention contracts and local synthesis are not proof of live configured search. |
| Search | `src/SearchRuntimeManager.swift`, `src/SearchRuntimeProtocol.swift`, `src/SearchRuntimePayload.swift`, `src/SearchEgressBroker.swift`, `src/SearXNGSearchProvider.swift` | Exact owned processes, protocol, private transport, payload admission and provider adapter. The broker file is SearchEgressBroker.swift, not SearchConnectBroker.swift. |
| Source retrieval | `src/ResearchHTTPTransport.swift`, `Resources/Research/dot_source_fetch.py`, `Resources/Research/source_fetch.sb` | DNS/public-address validation, pinned connections, redirect/TLS/resource/cancellation controls. |
| Native actions | `src/NativeActions.swift`, `src/ActionPanel.swift`, `src/DotIntents.swift` | Typed supported actions, target/precondition checks and receipts. This is not a complete general Accessibility/browser/coding agent. |
| Progress core | `src/LongTaskProgress.swift`, `src/ResearchTaskProgress.swift` | Pure state/progress and speech-candidate logic; full producer/UI/audio integration is a separate open scope. |
| Runtime helpers | `Resources/Runtime/dot_runtime.py`, `dot_tls.py`, `dot_process.py`, `splash.sb`; `Resources/Voice/bionic_helper.py`, `voice.sb` | Isolation, authenticated local transport, process ownership, private assets and fail-closed behavior. |

PDFKit isolation/extraction work, project-index/SQLite/evidence-memory/delegation/proactivity additions and their publication status must be inspected per exact path before integration. The presence of these responsibilities in the staged architecture design does not establish that every implementation file is on current main.

### Lifecycle contract to preserve

Every operation needs one authoritative owner, a bounded input, operation/turn identity, owner generation, ordered events and revision checks where persistence is involved.

1. **Admit:** validate availability, actual native target, authorization, capacity and current revision; retain the task handle before publishing busy state.
2. **Run:** only the owner transitions state. Native adapters perform typed admitted effects. Recheck generation/cancellation after suspension and before further effects.
3. **Interrupt or cancel:** stop future effects and stale publication immediately, cancel owned children, but retain admitted writes/actions until settlement. Cancellation is not rollback of an effect already committed.
4. **Settle:** distinguish verified completion, handoff, failure before effect, stopped before effect and unknown outcome. Do not erase actual effects because a late cancellation arrived.
5. **Resume or restart:** validate saved checkpoints and use new run generations. Reconcile a started-but-unconfirmed external effect before retrying. A UUID is not proof a competing owner is dead.
6. **Quit:** close admissions permanently, invalidate callbacks, cancel and asynchronously drain owned operations/receipts/helpers before termination. Avoid main-thread blocking, unowned detached work and process-name-wide kills.

`@MainActor` UI ownership does not mean parsing or disk work is automatically off-main. An inherited `Task {}` is not proof of background execution. Move measured blocking work under explicit bounded ownership and use Instruments to validate responsiveness. Coalesce replaceable display updates, never terminal receipts or delivery/cancellation events.

### Staged Swift and Rust design

R17's accepted design is **one in-process Rust static library**, preserving thin native Swift adapters and current effect/store ownership. No new daemon, database server, generic plugin platform or model instance is implied.

The proposed first pilot is replay-only `BoundedSSELines` framing, comparing unchanged Swift behavior with a bounded C ABI wrapper. It is not live stream dispatch and does not touch speech, persistence or tools. Preserve exact UTF-8, LF/CRLF, line/stream limits, EOF behavior, allocation ownership and cancellation semantics. Benchmark current Swift placement, Swift on the proposed worker and Rust on the same worker so executor/copy improvements are not attributed automatically to the language.

The proposed parser limits in the design are 16 KiB input chunks, 262,144-byte line output and 4,000,000-byte total stream. Proposed ABI names are design material, not a shipped API. Panics must not unwind across the boundary; no retained Swift pointer or cross-allocator ownership. Do not switch implementations midstream after output may have reached history or speech.

Only after equivalence, native ABI/sanitizer evidence and measured value should optional parser integration proceed. Later domain reducers can cover tasks/progress, research budgets/citations, retrieval and tools one at a time. Framework adapters and actual native effects remain Swift-owned. Storage convergence has a separate migration gate. No Rust migration is accepted merely because the design is accepted.

### Records and storage direction

The intended destination is one local SQLite/FTS5 store, with namespaces and one owner per record family. The staged expanded implementation's SQLite file currently covers project-source indexing; it is not a completed migration of history, research, actions or memory, and those expanded files are absent from published main at the freeze.

Preserve existing formats until a reviewed migration specifies exact UUID/date/Unicode/null/revision mappings, bounded import, interruption/corruption recovery, old/new client behavior, deletion, backups, export and downgrade. Do not add a second authoritative writer, indefinite dual writes or a shadow database. A SQLite transaction cannot atomically include an arbitrary GUI action or external filesystem effect.

The architecture design identifies these existing or staged record families: delivery-aware conversation history, research notebooks with source receipts, research-session checkpoints and retention, source-backed fact revisions/corrections, selected-root action receipts/recovery, and project/source FTS entries. Treat its default capacities and schemas as snapshot-specific implementation evidence to reverify, not new product limits. In particular, transient search-discovery data must not become durable memory or notebook evidence merely because a generic store supports persistence.

## Voice interaction contract

### Exact options

| Setting | Choices | Default | Meaning |
| --- | --- | --- | --- |
| Trailing silence | 2, 3, 5, 8 seconds | 3 seconds | Continuous silence after speech before submitting the next completed turn. Resumed speech resets it. |
| Question invitation | 3, 6, 9, 12, 20 seconds | 6 seconds | Time to begin speaking after dot's final audible question, not utterance length. |
| Activity | Low 10 minutes, Normal 4 minutes, High 1 minute | High | Opportunity/scheduling preset, not an unconditional instruction to speak. |

The current capture bound is one minute. Reaching a capture/sample bound must not submit an unfinished utterance as if silence had completed. Streaming transcription may run during listening; reasoning and research for that turn may not begin before the selected silence boundary. Foreground interaction pauses/deprioritizes background reasoning.

### Final question and microphone authority

Automatic continuation requires validated explicit question intent, the current turn identity, successful terminal generation, all final ordered synthesis and actual playback completion, fresh microphone permission, echo handling and a one-use continuation authority. A question mark, quotation, rhetorical question, an intermediate queue drain or a speech task merely scheduled to play is insufficient.

After an invitation opens:

- No speech before expiry closes the microphone.
- Speech that starts before expiry may continue past that invitation deadline until the selected trailing silence, subject to normal capture/sample bounds.
- Proactive questions use the same final-audible-question and bounded invitation rules. There is no independent random microphone opening.
- An automatic continuation must not prompt for OS microphone permission.
- Stop/replacement click, drag/menu, hiding, Quit, sleep, route change and permission loss cancel pending listening and stale callbacks.

Click-to-interrupt and Stop remain required. The historical source's 400 ms settling interval and three-auto-reply cap are provisional implementation choices; hands-free interruption, wake word, final chain policy and measured echo behavior remain open.

### Voice transport and recovery

The current Bionic-derived bridge uses bounded UTF-8 JSON lines over private owned-process stdin/stdout. Protocol 1 hello names Kokoro, bf_isabella, 24 kHz and offline mode. Speak frames are turn/session bound and bounded. Its documented limits include 1,000 text characters per request, 24 queued items, 60 seconds of audio per item and a 60-second expected-synthesis-response bound. These implementation bounds should be reverified against the exact candidate before changing related tests.

The Swift host must stop audio immediately and reject old-turn output; a CPU synthesis kernel may finish before the helper can process cancellation. Do not claim hard kernel preemption. WAV transfer uses a private owner-only location, no-follow regular-file checks, bounded off-main reads and deletion. Protocol stdout must not be contaminated by library diagnostics. Do not log spoken text, microphone data or audio contents.

Expose honest distinctions between cancellation, no speech, route failure, audio failure and unavailable screen context. Provide bounded recovery, readable status and typed fallback. If Retry starts a new recording, label it accordingly. Keep generated text distinct from what was actually spoken, interrupted or failed; durable history must survive relaunch without inventing successful delivery.

### Performance acceptance

Record speech-end to first **audible** response including the selected silence, post-silence processing separately, cold/warm readiness, p50/p95, stop-to-silence and next-turn readiness. Measure actual acoustic onset rather than scheduled playback or an amplitude event.

Compare the same complete workload against the preserved baseline on the same hardware/toolchain where possible: STT, model readiness/generation, TTS, playback queue, cancellation, CPU/GPU/ANE/RAM, thermals, battery and idle energy. Include quiet speech, background noise, speaker echo, headphones and Bluetooth. Component benchmarks do not establish a fastest pipeline, guaranteed three-to-five-second reply or Rust speed multiplier.

## Screen context and local information

The target expands beyond explicit-turn screen capture to automatic pre-answer context and background observation that can discover useful work. The owner permits relevant screen, documents/files, Work/Downloads, iCloud Drive and other accessible-folder information to support research and assistance. Keep actual macOS consent, visible capture/pause controls, denied/unavailable reporting and protected-system boundaries.

Do not use this direction to claim universal access or to bypass permissions. iCloud placeholders are not necessarily local bytes. Index with native file-change events, debounce incomplete writes, deduplicate and rank relevance, and recover from missed/coalesced events. Avoid constant whole-screen OCR, repeated full-disk scans and deep research on unchanged context every minute.

Screenshots are transient and bounded; do not persist them or microphone recordings in history/memory under the current plan. Preserve capture freshness based on monotonic acquisition time through encoding/submission. Slow, stale, cancelled or unavailable capture must not masquerade as current context. Screen content is untrusted data and cannot issue tools or expand authority.

## Research and verified useful work

### Research policy

Online/deep research should precede most factual answers and support background work. The exact time/usage budget and whether a quick provisional answer precedes full research remain open. Continue local reasoning and make failures explicit rather than inventing successful search.

The complete pipeline needs multiple searches, selected actual pages/PDFs, original sources, publication/event dates, follow-up queries, contradiction checks and citations supporting individual claims. Search snippets are discovery material, not supporting passages. A matching quote or hash establishes provenance, not truth. Similar usefulness to Perplexity/ChatGPT is an aspiration, not proven parity.

### Search helper and source reader boundaries

- Keep the local SearXNG endpoint separate from offline inference/speech and from arbitrary fetched result URLs. No LAN exposure or alternate undisclosed server discovery.
- Free-only engines; no paid fallback. Bound query count, time, concurrency, response sizes and retry/backoff. Respect engine terms, rate limits, blocks and CAPTCHA. Do not bypass them or create retry storms.
- Derive the smallest relevant outgoing query locally. Exclude credentials and unnecessary personal/file/screen material; upstream engines receive the query. Disable query/body logging by default and verify redaction without retaining raw content.
- Validate all DNS answers and public destinations, pin actual numeric connections, and revalidate every redirect. Prevent private/loopback/link-local/metadata destinations, mixed unsafe resolution, credential-bearing URLs and downgrade routes.
- Preserve original-host TLS/certificate checks, bounded transport/extraction, cancellation and complete-helper cleanup. Do not substitute an unrestricted URLSession/curl/proxy/auth path when the safe transport rejects a request.
- Establish per-engine/source retention before persistence. Keep transient discovery separate from evidence permitted to be retained, with local expiry/deletion. The pinned SearXNG license does not grant rights to fetched content.
- Test startup health, port conflict, failure recovery, Stop, stale events and shutdown without orphans using the actual pinned helper and native manager/broker. A mock server or compiled scenario alone does not satisfy this.

### First complete autonomy milestone

Finish **research and maintain a local project brief** before widening the tool catalogue:

1. Admit an explicit project/input scope and a persistent mission goal.
2. Retrieve bounded relevant local documents with source identity, dates and passages.
3. Research current sources through the admitted Search/source pipeline.
4. Link each important claim to supporting evidence; identify contradictions and uncovered claims.
5. Write a useful source-linked local brief using a typed action with preconditions.
6. Reread/verify the actual saved output and create an accurate receipt.
7. Preserve evidence, task progress and incomplete/unknown outcomes according to retention policy.
8. Pause for conversation and resume without repeating completed effects.
9. On changed inputs or stale findings, refresh affected conclusions rather than rerunning everything blindly.

Acceptance must include restart, changed files, failed requests, stale native views and embedded malicious source instructions. Measure complete task success, unsupported claims, wrong file changes, duplicate effects, recovery, unnecessary prompts, model-call count and foreground voice latency. Do not declare the workflow complete from synthetic fixtures alone.

### Actions and native integrations

The broad target includes native app launching, supported Accessibility click/type/navigation, browser operations, local file/document creation/editing/organization, coding/build/test tools and document/web search. Implement concrete typed adapters with observable outcomes, not a generic claim of unlimited computer use.

Prefer native APIs, supported scripting and installed Shortcuts before Accessibility/visual automation. App Intents expose Dot's actions; they do not grant universal control of third-party apps. Check app/version/target preconditions and invalidate stale recipes instead of reusing old screen coordinates. Validate outputs, retain recoverable versions where supported and preserve unknown outcome when verification is unavailable. Undo for a local edit does not mean an external communication can be unsent.

## UI and companion behavior

### Accepted identities and presentation

The exact native Settings order is **Original, Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo, Nova**. **Original stays default until the user changes it.** Do not rename identities or omit a choice because a prototype differs.

| New-skin category | Names | Intended distinction |
| --- | --- | --- |
| Four rounded | Pearl, Mochi, Cloudlet, Pip | Ceramic pearl, soft plush pebble, cloud puff, rounded bird; distinct silhouettes/materials/proportions. |
| Three glass | Dew, Ripple, Veil | Clear bubble, tri-lobed droplet, and an even thinner nearly invisible lens/bubble. |
| One organic | Sprout | Sculptural leaf companion with anatomy-specific motion. |
| Two AI-style | Halo, Nova | Luminous voice orb and dark luminous visor with original faces. |

**Veil replaces Fold at new-skin position 8.** It is similar to Dew but more transparent, with a faint rim, sparse face and visible backdrop. It must not remain a fox, angular paper character or folded-paper silhouette under a new name. The current grouping is 4/3/1/2; older Fold boards are historical.

Every face remains smiling, warm and friendly in every state, including focus/thinking/research. Use rounded open eyes with highlights, relaxed gently arched brows and a gentle upturned resting mouth. Exclude angry inward V-brows, glare/slit eyes and scowls. Friendly speech articulation and truthful task labels coexist; the label carries status, not the smile.

### Animation production target

Each of the **ten new skins** needs at least **120 individually reviewed, visibly distinct, context-appropriate named animation recipes**. Each recipe needs name, trigger, duration, compatible states and cancellation/interruption behavior. Original is retained; the 120-per-new-skin target must not be silently generalized into a different requirement.

The 1,200 prototype configurations are state/expression combinations, not 1,200 authored/perceptually accepted clips. Parameter uniqueness, five shared starter recipes, screenshots or static render contact sheets do not close production coverage. Review motion in context, anatomy and state compatibility, event truth, interruption, actual speech timing, frame time and energy.

Activity states are Idle, Listening, Thinking, Researching, Speaking, Working, Question, Success, Uncertain and Resting. Expression presets are Calm, Curious, Warm, Focused, Delighted, Playful, Surprised, Concerned, Determined, Apologetic, Tired and Proud. These are presentation concepts, not claims of human feelings or authority to make an angry face.

Animate using task events and deterministic local timing, not Qwen calls per blink. Prefer SwiftUI phase/keyframe animation and Core Animation before a custom renderer. Keep actual audio time and locally available/derived phoneme/viseme alignment; an amplitude-driven mouth is a fallback, not accurate lip sync. Pause/cancel facial speech with audio. Reduce hidden rendering and measure hitches/energy beside voice latency.

### Readability and interaction

Keep the face as the fast surface, with readable actual status and discoverable Stop, quiet/mute, keyboard/Options and typed fallback. Use compact task/result cards with Open result, Sources, Pause/Stop, Resume and Undo where actually supported. Show incomplete steps and real outcomes.

Long research needs a readable native panel or document preview and short spoken summaries. Use opaque text surfaces when glass compromises readability. Provide “Why this suggestion?” with the relevant evidence, dismissal and remembered dismissals. Explicit delegation should support drop/selection/macOS Services/keyboard where implemented, with no dependency on a microphone, hover or animation for essential controls.

Native Liquid Glass, Reduce Transparency, Increase Contrast, Reduce Motion and VoiceOver require actual app/device testing. Check eyes/mouth/buttons/status on white documents, dark editors and photos, mixed displays, clipping and control placement. The corrected warm-face motion study was owner-accepted, but its fresh technical browser pass remained unrun; earlier 736/390/320 px checks apply only to the earlier version. Do not conflate design acceptance, browser review, native renders and live hardware behavior.

### Movement and proactive timing

Normal roaming must avoid useful content, text/buttons and unsafe swept paths. Preserve conservative placement, manual drag, pin, menu-bar recall and keyboard/accessibility access. Missing/stale/uncertain analysis currently means hold position; never claim semantic safe placement for every app/display.

The newly requested **tiny local idle fallback** is distinct: do not stay still more than one minute; if no normal safe route exists, very slowly move a very small amount near the current place. Character-only animation versus whole-panel motion, amplitude, speed, cursor/pin/accessibility/pause behavior remain unresolved. The exception cannot promise zero overlap; do not erase it by restoring indefinite stillness as the target.

Low 10/Normal 4/High 1-minute activity, default High, defines opportunities to help. Use cheap change signals, pending work, relevance, deduplication and remembered dismissals. Resolve quiet/busy/fullscreen/call/unchanged-context behavior rather than inventing an unconditional spoken timer. Conversation has priority over background inference; waking from sleep must not release a burst of overdue prompts.

### Long-task halo and spoken checkpoints

For tasks expected to take more than two minutes, use one slim halo inside existing hit/placement bounds. No progress bar or visible percentage numbers. An initially short task that crosses two minutes is promoted once. Do not add a ring for every background task.

Derive determinate progress from actual completed work and an explicit remaining plan, never elapsed time alone. If scope is unknown, show a distinct restrained activity arc plus actual stage. Start with goal, first step and a calibrated estimate range; say timing is unknown if no reasonable estimate exists.

The requested start/50%/80%/95% checkpoints are **real plan milestones**, deduplicated per task and plan version. Spoken updates are brief done-and-next sentences and **do not say percentage numbers**. Use 95% only when final verification is genuinely underway. Complete/success requires verified result; new work must revise stage/estimate honestly.

Never overlap checkpoint speech with listening, user speech or another voice response. Coalesce crossed milestones; avoid catch-up bursts after restart/resume; Stop cancels queued speech. Respect mute/quiet/calls, keep text equivalents, and never open an automatic microphone invitation from a declarative progress update. Distinguish paused/blocked/failed with actionable reasons and supported Resume. Static status, non-color-only contrast and calm VoiceOver exposure are required.

## Security and trust boundaries

### Preserve the boundaries while diagnosing failures

- Treat screen, website, PDF, document, model and stored evidence text as untrusted data. Content cannot override user goals, enable tools, expand a folder scope or alter credentials/permissions.
- Keep one app-owned inference runtime and explicit process identities. No kill-by-name cleanup, arbitrary server discovery or second model instance to conceal cancellation delay.
- Keep inference/speech offline isolation separate from research egress. Environment flags alone are not a sandbox.
- Keep private protocol secrets in their approved bounded channels; do not expose credentials/tokens in URLs, command arguments, logs, screenshots or this handover. Preserve source-bound authentication and private request lifecycle checks.
- Keep descriptor-rooted/no-follow filesystem validation, exact identity/mode/link checks, bounded traversal and atomic revision-aware commits. Candidate-generated manifests do not grant trust to their own bytes.
- Do not weaken runtime payload single-link rules because fixed Apple tools on a hosted image use hard links. The Apple-tool observation/dispatch boundary is separate from payload trust.
- Preserve TLS original-host/certificate/pin checks, public-address validation and redirect checks; no permissive trust callback, broad sandbox/network exception or warning bypass.
- Bound child startup, pipe input/output, sockets, queues, DNS, parse/decompress/extract resources and cleanup. Stop must revoke future authority and settle owned operations.
- Keep native permission denial/revocation and route/sleep transitions explicit. No permission-reprompt loop or stale capture restart.
- Record stage/error IDs and bounded diagnostic measurements, not raw prompts, full conversations, screenshots, audio or secrets.

### Runtime reconstruction is not runtime approval

`scripts/reconstruct_runtime_payload.py` and `packaging/runtime/reconstruction-policy.json` describe guarded preparation/finalization. The source policy has **zero accepted historical baselines**. No production runtime has been accepted at this snapshot.

Preparation may create inert bounded bytes only from independently admitted inputs; successful preparation is not native acceptance. A rewritten checkpoint or self-generated digest cannot authorize different bytes. The native finalizer requires exact source-owned evidence and all mandatory gates before any acceptance marker. It must not create its own approval.

The archive basis retains pins but reports `ARCHIVE_LAYOUT_UNREVIEWED`; archive extraction/installation is not an implemented alternative admission route. A random Python tree plus an invented report is not a valid substitute. The `copy` admission path remains reserved/unimplemented for accepted copy. Do not mistake a CLI subcommand's existence for an operational release path.

### Known security and diagnostic uncertainty

The handover does not claim a clean new security scan or closed findings. Existing security reconciliation remains open and must be tied to exact source, severity, proposed fix, regression and runtime evidence before closure. A diagnostic observation, static guard or synthetic canary is not a security attestation.

Current work includes the mandatory native descriptor/tool identity gate, true TLS bounded shutdown/deadlines, the actual Search helper's startup/profile/toolchain behavior, private authenticated proxy lifecycle and final source/runtime integrity. Resolve causes narrowly with preserved negative cases. Do not allow a passing static lock, copied historical payload or observation parser to bypass production approval.

## Packaging licensing and distribution

### Artifact identity chain

Bind the exact source commit/tree, clean/dirty source state, build toolchain/SDK, runtime/model/Whisper identities, dependency closure, native build, app resource tree, executable, signatures, acceptance report and final DMG hash. A later signing, source, payload, resource or packaging change can invalidate earlier acceptance and must trigger the applicable rechecks.

The expected model inventory must be independently hashed from acquired bytes and again in the final bundle. Runtime preparation must audit architecture, minimum OS, load commands, RPATHs, dependencies, license material and offline import/synthesis. No unresolved developer-home/Homebrew paths or externally borrowed runtimes in the final owner app.

`bash build.sh` is a development-packaging path and produces a neural-payload-free app/DMG. It is not the requested working owner delivery. The complete build/package scripts require verified inputs and exact-artifact acceptance; their presence does not mean a fully admitted new bundle exists.

### Licensing work that must remain visible

Dot's repository has an MIT license. Dependency and model terms are separate. Preserve exact notices, modifications and source correspondence rather than relying on top-level package names or process separation.

- Splash and selected Qwen target/draft/vision sources require their pinned redistribution/license review.
- Bionic-derived helper source carries its MIT provenance and notice.
- Kokoro/Misaki/model/voice material carries Apache-2.0 obligations and applicable data notices.
- whisper.cpp/Whisper model notices must accompany the selected artifacts.
- eSpeak NG is GPL-3.0-or-later; phonemizer-fork and num2words have their applicable GPL/LGPL obligations. MIT licensing of a loader does not relicense its bundled native library. Establish exact corresponding source and review the combined distribution.
- SearXNG is AGPL-3.0-or-later, including modification/corresponding-source and relevant network-use obligations. Waitress is ZPL-2.1. Preserve selected dependency notices and matching source inventories.
- CPython, PyTorch, NumPy, spaCy/data, native libraries and every wheel need the actual shipped notices/SBOM. Do not bundle proprietary training corpora simply because a model references them.
- Upstream page/search retention and reuse rights remain independent of the search engine's software license.

The existing static closure is useful engineering evidence, not legal clearance. Public distribution still requires appropriate signing/notarization, nested-code verification, clean supported second-Mac installation and exact-artifact tests. Stable signing identity matters for permissions and updates; do not replace or strip it casually.

## Owner hardware and physical acceptance

The latest available owner-device observation reports **macOS 27.0.1, Apple Silicon arm64, M5 Pro, 48 GiB RAM, approximately 401 GiB free and SDK 27**. Treat free space as time-sensitive. The intended supported product target remains **M4 Pro-class or newer, 36 GB minimum and 48 GB recommended**, with macOS 26.4+ for Splash. A 48 GB development machine does not certify 36 GB behavior or every newer/older device.

Owner-computer execution is currently blocked by the supported execution route's usage constraint. This is not a blanket absence of permission to perform the requested bounded model-asset/runtime checks. Do not promise that a connection will work or retry an unavailable route indefinitely. After a fresh owner instruction to resume, independent cloud/source/hosted-macOS work can proceed while the installed app/data remain preserved; arrange the specific remaining owner checks only when execution is actually available.

Pending inputs include complete owner-model hashes and the bounded runtime collector report. Existing installed-app observations do not establish every required asset identity. Use supported, read-only/approved collection with a bounded report, not a generic personal-computer dump. No credentials or unrelated personal files are required.

All nine MAC rows in the exact ledger remain open. The physical matrix must include:

- Complete offline readiness and exact commit/app/model/runtime/Whisper/signing hashes.
- Real microphone → Whisper → fixed Qwen/Splash → audible bf_isabella; repeated, interrupted and near-expiry turns across every timer setting.
- Actual acoustic onset, stop-to-silence, next-turn latency, recognition quality, p50/p95, RAM/CPU/GPU/ANE/thermals/energy; noise, echo, headphones and Bluetooth.
- Permission denial/revocation, route changes, sleep/wake, foreground interruption, helper cleanup and no stale capture restart.
- All 11 skins, all accessibility modes, light/dark/photo backgrounds, mixed displays, keyboard/Options/typed fallback, real playback alignment and perceptually reviewed recipes.
- Real research/index/memory/actions/tasks and interruption/restart/delete/Quit/export behavior using actually admitted integrations.
- App Intents/Siri discovery and permission-gated EventKit/Accessibility/browser features actually shipped.
- Separately authorized recoverable replacement preserving the old app and all data, followed by installed-path smoke tests.
- Clean supported second-Mac installation, relocation and offline operation; downloader recovery where relevant; public signing/notarization and exact installer acceptance.

## Open decisions and concrete blockers

### Product choices still genuinely open

1. Whether a replacement voice must be exact Isabella identity or a sufficiently similar warm British female voice; all candidate changes still need full-pipeline quality/performance proof.
2. Final native Settings presentation and how longer findings/reports fit compact panels. Required controls, skin lineup/default and timing values are already fixed.
3. Randomized proactive questions under busy/quiet/fullscreen/calls, unchanged context and no useful idea. Do not turn activity presets into unconditional speech.
4. Tiny fallback as character animation versus panel movement, amplitude/speed, cursor behavior and pin/accessibility/pause interactions.
5. Hands-free interruption, wake word, maximum automatic reply chain and measured echo-settle policy.
6. Research budgets and quick provisional answers. Free-only SearXNG direction and authorized relevant-context transmission are already fixed.
7. Learned text-fact retention, automatic learning, memory review/presentation, backup/deletion/export/downgrade policy and any later store migration.
8. The separately gated video implementation and resource/delivery fit after feasibility research.

Do not convert these into invented defaults or reopen settled choices. After new resume authorization, independent engineering may proceed where an unresolved choice does not affect its contract.

### Engineering and release blockers at freeze

- Obtain terminal exact-source native/Search results and diagnose failures without weakening required bounds.
- Complete actual pinned Search helper/broker/TLS lifecycle and live search-to-original-source citation evidence; current app provider remains unconfigured.
- Satisfy native descriptor/tool identity/finalizer requirements and independent runtime admission; production approval lists are empty.
- Obtain independently verified model/runtime inputs and close complete offline assembly. No complete new working DMG exists.
- Reconcile and selectively integrate expanded unpublished memory/index/delegation/proactivity/progress/PDF and other source with current main and its tests.
- Complete native UI/audio/progress producer wiring, animation recipe acceptance and measured performance.
- Resolve retention/corresponding-source/license/signing/notarization/distribution gates.
- Obtain actual owner hardware/installation and second-Mac acceptance rather than reusing historical or synthetic passes.

## Safe continuation workflow and verification commands

### First read only checks

During final handoff, the incumbent remains the sole safe-publication writer. Afterward, no implementation resumes until the owner authorizes it and the receiving team establishes a new sole integration owner. Read the checkout without changing branches or overwriting files. These commands are ordinary read-only Git inspection from the intended Dot checkout:

```sh
git status --short --branch
git rev-parse HEAD
git branch --show-current
git log -8 --oneline
git diff --stat
git diff --name-status
git ls-files docs src Resources scripts Tests packaging .github
```

Compare local HEAD and changes with verified GitHub main separately; a local checkout is not proof of current remote state. Inspect file ownership before staging. Main remains the only ongoing working/default branch. If isolation is needed, coordinate a temporary detached checkout or disjoint file ownership, not a new feature/release branch. Do not use reset/clean/force-push or broad checkout replacement as onboarding.

### Verified test entry points after ownership and environment checks

The following entry points are present in the repository/README and are for an authorized engineering environment. They create temporary/build outputs and run code; they are **not read-only onboarding checks** and were not executed to prepare this handover.

```sh
python3 -B -m unittest discover -s Tests/Python -v
python3 -B scripts/check_contracts.py
swift test
bash scripts/verify_macos.sh
```

Use an appropriate macOS/Xcode setup for native work. Hosted workflow source selects Xcode 26.3 and records toolchain/SDK provenance; the test Python requirement includes Python 3.11+ with supported OpenSSL. Do not point product runtime code at the test Python as a fallback.

`verify_macos.sh` runs Python, voice/Splash sandbox checks, the mandatory runtime-finalizer canary, static contracts, SwiftPM, Debug XCTest, Release and, only after mandatory gates permit it, development packaging/signature/provenance and zero-warning checks. It may collect independent Swift/Xcode evidence after a finalizer failure, but must fail overall and stop before packaging. An earlier Python failure stops later stages. Preserve that distinction when reporting a run.

Search real-vertical testing is a separate source-bound workflow and driver, including `scripts/verify_search_real_vertical_canary.sh` and `.github/workflows/search-proxy-canary.yml`. Read its exact pinned fixture inputs and all prerequisites before running it. Do not invent a permissive environment variable, CA, approval file or payload manifest to make the fixture pass; keep fixture-only admissions visibly separate from production.

For complete-runtime build/package work, read `docs/offline-voice-assembly.md`, `docs/runtime-reconstruction.md`, `docs/self-contained-build-plan.md` and `docs/offline-acceptance.md` first. The README's `build_complete.sh`/`package_complete.sh` examples require actual verified payload/model/Whisper/acceptance paths. This handover intentionally does not supply pretend paths or an unsafe one-line release command. Inspect the exact current scripts, obtain inputs through the approved route and preserve the installed application.

### Reporting and repository hygiene

For newly authorized implementation, at meaningful safe checkpoints approximately every ten minutes, publish useful exact state in the canonical checklist/text companion, PROGRESS, CONTINUATION and affected documents. Do not create empty timestamp-only commits or publish broken code just to checkpoint. Preserve reviewed source-only recovery copies and their hashes. Keep old evidence dated; add a clearly newer current-state summary rather than silently relabeling old results.

When newly authorized work resumes, for every meaningful change record: base/new commit, intended paths, source implemented, focused tests, required suite outcomes, skipped/unrun stages, warnings, runtime/device evidence, remaining blocker and next executable step. One integration owner stages only intended reviewed files and uses normal non-forced main publication. Keep signing paths or other actively owned files with their assigned owner until explicitly released.

## Prioritized next work after fresh owner authorization

This is an informational backlog for the receiving team. It does not authorize the stopped session to perform or monitor these steps.

### Priority 0 Establish the actual baseline

Coordinate the handover, freeze current main and collect the latest terminal native/Search evidence. Preserve all dirty/unpublished source and installed assets. Reconcile the current ledger without changing accepted scopes. Determine whether the latest fix cured the environment-observer issue and what the unchanged TLS/descriptor gates report. If main advances, bind every claim to the correct source.

### Priority 1 Close runtime and Search prerequisites

Repair only the demonstrated native failures with targeted tests and independent review. Keep deadlines, payload trust and sandbox isolation intact. Run the actual source-bound Search vertical through real manager/broker/pinned-helper startup, TLS negatives, cancellation and drain. Then enable product provider wiring only with the required runtime/source/retention admission. Continue independent model hashing, runtime collector, 92-wheel/native closure and exact source-license work.

### Priority 2 Preserve and verify a complete offline voice candidate

Assemble only independently verified inputs, with one fixed shared runtime, actual Whisper, British Kokoro and complete target/draft/vision assets. Check cold offline relocation, cancellation and exact signed resource identity. Establish real audible/device performance and fallback recovery. Do not substitute a payload-free app while waiting for assets.

### Priority 3 Integrate useful workflows in bounded slices

Reconcile expanded records/index/memory/source/progress/delegation and other preserved work. Prioritize one end-to-end maintained project brief with original-source citations, verified local output, interruption/restart and changed-input refresh. Wire actual UI state/producers and receipts. Admit broader native actions only as typed tested adapters with truthful outcomes.

### Priority 4 Finish companion quality and proactivity

Complete friendly native recipes for every new skin, actual speech alignment, transparency/contrast/motion/accessibility, tiny-motion product choice and safe placement. Resolve activity/quiet/call/no-useful-idea behavior, deduplication and relevant suggestions. Add long-task halo and gated speech using real progress, then test native rendering/energy and voice priority.

### Priority 5 Complete owner delivery and public release separately

Run the whole exact-artifact physical matrix, preserve the previous app/data, perform the separately authorized recoverable installed-path test and deliver the complete working owner DMG. Public release additionally needs supported second-Mac evidence, final licensing/source distribution, appropriate signing/notarization, downloader behavior where applicable and exact final installer checks. Do not equate personal installation with public release.

## Definition of done and acceptance record

A requirement closes only for the scope actually stated. R04/R17/R50/R66 are deliberately narrow: reconciliation, design, feasibility research and shared rig. They do not close adjacent implementation or release rows.

For every proposed closure, retain:

| Evidence field | Required meaning |
| --- | --- |
| Requirement ID and text | Exact stable row and stated scope. |
| Source identity | Commit/tree plus any dirty/unpublished files and hashes; no ambiguous “latest.” |
| Implementation | Concrete files/behavior and limitations. |
| Automated evidence | Exact commands, environment, tests/counts, warnings, failures, skips and logs/receipts. |
| Native evidence | Exact toolchain/SDK/architecture and compiled/executed paths; clarify mock, synthetic, opt-in, real-helper and real-model scopes. |
| Physical evidence | Device/OS, actual audio/permissions/UI/resource/interaction observations as applicable. |
| Artifact | App/runtime/model/resource/signature and final DMG identity; acceptance is invalidated by relevant changes. |
| Installation | Whether and where separately authorized installation occurred, rollback preservation and installed-path verification. |
| Owner acceptance | The actual reviewed behavior/design/delivery accepted, without expanding its scope. |
| Release status | Licensing/corresponding-source/signing/notarization/second-Mac and public delivery separately. |

Whole-product completion requires all agreed current requirements and broader workflows to have their applicable evidence or an explicit owner-approved scope change. A feature box does not close because a design exists, code compiles, a source file is published, a synthetic test passes or a developer DMG is built. Every failed/unrun check remains visible. Preserve the final hardware and distribution gates rather than lowering the bar to fit available infrastructure.

## Broader workflows without their own checkbox rows

The canonical roadmap includes obligations in prose/tables as well as checkboxes. These six grouped workflows must remain in scope even though they do not increase the 97-row denominator. They are not claimed complete.

| Workflow | Intended behavior | Minimum continuation and acceptance evidence |
| --- | --- | --- |
| EventKit meeting preparation and follow through | Use authorized calendar context, relevant project files and open questions to prepare for meetings; turn user-provided notes into tasks. | Implement permission-gated EventKit/store-change adapters. Verify revocation, refresh and source-linked task creation. Calendar metadata is not meeting transcript content. |
| Watched-folder PDF and Vision document work | Detect new/changed documents, summarize/extract useful tables/lists and produce checked project output. | FSEvents/native change discovery, debounce partially written files, native PDF text first, Vision for scans, numeric validation and source-page links; recover missed/coalesced events and test changed inputs. |
| Services and drop delegation | Explicitly select text/drop a file and ask Dot to explain, compare or make a task. | Native Services/pasteboard/drop plus keyboard/VoiceOver access; show exact selected source, bound/sanitize input and reject stale selection. Expanded local code is not published wiring. |
| Shared SQLite full-text records | Compact local retrieval over project/evidence/history/task records, with corrections and stale-source handling. | System SQLite/FTS5 first, one owner, namespaced schemas, explicit retention/delete/export/migration; no duplicate authoritative store or unsupported all-records migration claim. |
| Persistent missions and effect reconciliation | Work survives interruption/sleep/restart and does not blindly repeat completed/uncertain effects. | Journal goal/inputs/steps/output/pending effects, typed receipts and actual result rereads, unknown-outcome reconciliation, recoverable edits and duplicate-effect/restart tests. A journal cannot guarantee exactly-once arbitrary GUI actions. |
| Maintained project brief and changed-input refresh | Build a source-linked local brief, remember supporting evidence and refresh only changed/stale findings. | End-to-end admitted local retrieval → real web evidence → claim support → verified file → evidence/task persistence → foreground pause/resume → targeted refresh after source/file change. |

The canonical table also calls out evidence-backed memory, reusable research notebooks, reusable native action recipes, event-aware suggestions and project/handoff context. Those are covered across the six workflows and exact rows below; this grouping does not remove any of their detailed obligations.

## Complete current requirement ledger

The following **97 current requirements** retain their stable IDs and exact canonical requirement text. A checked box means only the scoped acceptance described above. An unchecked box may have substantial source or focused tests; it is not a claim that no implementation exists. Canonical row order is preserved within this current-only section; the five historical rows follow separately.

### R01

- [ ] Complete the above reliability and interaction corrections with focused regression tests.

### R02

- [ ] Complete exact assembled-app and actual-runtime voice acceptance and reproducible acoustic/resource measurements.

### R03

- [ ] Complete the first end-to-end research workflow before claiming broad autonomous research/tool capability.

### R04

- [x] Reconcile this ledger with exact commits, tests, device checks and concrete unresolved prerequisites as work proceeds.

### R05

- [ ] **Fast voice first:** keep the chosen local model and British voice; measure the complete conversation path and let background work yield immediately to conversation.

### R06

- [ ] **Finish useful work:** persistent missions with a clear result, progress, pause/resume, restart recovery and checked outputs.

### R07

- [ ] **Remember with evidence:** editable local memory tied to source passages and dates, including corrections and stale information.

### R08

- [ ] **Research once, refresh intelligently:** a local evidence notebook with sources for individual claims, dates, disagreements and reusable findings.

### R09

- [ ] **Resume a project:** relevant files, recent decisions, unfinished tasks and a concise next-step or handoff pack.

### R10

- [ ] **Make documents useful:** watched-folder workflows, native PDF text and structured on-device recognition of scanned tables and lists.

### R11

- [ ] **Reuse reliable actions:** small tested native workflows for supported apps, with observable success and recovery where possible.

### R12

- [ ] **Offer timely help:** the requested 1 / 4 / 10-minute presets, default 1; prioritize useful changes, remember dismissals and avoid duplicate work.

### R13

- [ ] **Make the UI actionable:** old design plus ten new looks, expressive speech, clear activity states, source chips, task results and keyboard access.

### R14

- [ ] **Build less custom infrastructure:** Apple frameworks first, thin adapters, one shared model, one local store and measured staged Rust migration.

### R15

- [ ] **Candidate hardware/owner acceptance:** microphone/speaker echo, Bluetooth/headphone route changes, denied/revoked permissions, interruption transitions, full bundled conversations and measured actual-audible latency. Native static light/dark/opaque contact sheets were reviewed; they do not certify runtime motion, accessibility delivery or GPU/energy behavior.

### R16

- [ ] **Installation/release:** the installed `b26a145` app remains unchanged. Candidate source availability, tests, assembly, installation and owner acceptance are separate states; no public release is claimed.

### R17

- [x] Design staged Swift/Rust service boundaries for coordination, tool execution, research, indexing, history and memory; keep Apple framework adapters thin and the UI responsive.

### R18

- [ ] Keep Qwen 3.8 27B Q4, Splash 1.3.1 baseline and pinned target/draft/vision assets. No alternate cloud LLM or Apple Foundation Models replacement has been authorized. The `mlx-community` checkpoint publisher name is not an inference-engine switch.

### R19

- [ ] Jointly benchmark streaming STT candidates **Parakeet EOU** and **Apple SpeechAnalyzer**, including recognition quality, offline asset provisioning and contention with Splash. No winner is established.

### R20

- [ ] Evaluate native Core ML Kokoro only if it matches the desired British female voice and outperforms the working path. Keep `bf_isabella` as the quality reference. Exact identity versus a sufficiently similar British voice is open; an American-only substitution is unacceptable.

### R21

- [ ] Consider Apple built-in speech as an optional native speech profile; do not promise access to Siri's exact voice. Core ML is being considered for speech, not as a replacement for Splash/Qwen.

### R22

- [ ] Measure resident-model policies, prefix caching, streaming STT, sentence TTS, reduced copying/IPC, prioritization and cancellation. Keep animation/placement cheap and independent of the 27B model; do not run multiple 27B models for background tasks.

### R23

- [ ] Benchmark speech and Splash together across GPU/ANE/memory contention, quality, heat, battery and RAM. Keep full payload integrity, process ownership and cancellation checks.

### R24

- [ ] Report speech-end to **first audible response including the selected silence interval** (default three seconds), post-silence processing separately, cold/warm readiness, interruption latency and p50/p95. Scheduled playback is not measured audible sound. Deep research can take longer. No fastest-pipeline result, guaranteed three-to-five-second answer or Rust speed multiplier is established.

### R25

- [ ] Expose trailing-silence choices **2, 3, 5, 8 seconds, default 3**. Require uninterrupted silence for the selected duration before reasoning or web research on that turn. Resumed speech resets the timer. Streaming transcription may run while listening; do not reason on an unfinished utterance. Pause/deprioritize background reasoning on foreground interaction.

### R26

- [ ] Expose question invitation choices **3, 6, 9, 12, 20 seconds, default 6**. This is the time to **begin speaking after dot's final audible question**, not TTS duration or maximum utterance length. No speech closes the microphone; speech begun in time continues until the selected trailing-silence threshold, subject to ordinary capture/sample limits (current overall bound: one minute).

### R27

- [ ] Use validated explicit question intent and successful complete generation plus **all final question audio actually finished** before arming the mic. Punctuation, quotations or rhetorical questions alone cannot arm it. An intermediate audio-queue drain is not final completion.

### R28

- [ ] Bind intent, synthesis, playback and capture to the current turn with stale callback cancellation, one-time continuation authority, echo protection and fresh microphone permission. No automatic OS permission prompt. Stop/click replacement, drag/menu, hiding, Quit, sleep, route changes and permission loss cancel pending listening.

### R29

- [ ] Apply the same bounded invitation to random proactive questions after their audible completion. There is no independent random microphone opening without a question.

### R30

- [ ] Preserve click-to-interrupt/Stop. Decide hands-free speech interruption, wake word, maximum automatic reply chain and measured echo-settle behavior; scaffold constants are not agreed product limits.

### R31

- [ ] Add these controls and the activity presets below in native settings/options. A compact native surface may preserve the style; exact presentation remains open. Earlier no-Settings-window wording must not erase the requested controls.

### R32

- [ ] Provide automatic screen awareness before answering and background observation without a fresh request, to discover useful context and proactively help. This expands the installed explicit-turn capture plus sparse local placement behavior; it is not installed today.

### R33

- [ ] Keep native permission grants, visible capture/pause controls and honest unavailable-context reporting. Broad autonomy does not bypass macOS consent, protected-system/keychain restrictions, provider rules or actual accessibility.

### R34

- [ ] Build a local file/document index with event/change-driven updates, relevance ranking, deduplication and background opportunity discovery. Avoid repeated whole-disk scans. Handle iCloud placeholders/downloads explicitly; accessible cloud documents are not necessarily already offline.

### R35

- [ ] Make online research/deep research the default before most factual answers and support automatic background research. Keep internet available as a product capability; report connectivity/provider failures honestly.

### R36

- [ ] Use multiple searches, actual page/PDF reading, original sources, publication/event dates, follow-up queries, conflict cross-checks and citations. Similar usefulness to Perplexity/ChatGPT is an aspiration, not proven parity.

### R37

- [ ] Add the requested free-only SearXNG option below; set research time/usage budgets and whether a quick provisional answer precedes full research. Do not imply permission to send relevant context remains undecided.

### R38

- [ ] Treat screen, website, PDF, document and model content as untrusted data. Reading it never grants authority to override the user's goals, expand permissions or issue tool commands.

### SX01

- [ ] **Isolate the local search helper.** Run SearXNG on a validated loopback-only endpoint, separate from offline Qwen/Splash inference and speech. Keep reasoning local; search still contacts upstream internet engines. Use free-only engines, with no paid API or cloud LLM fallback.

### SX02

- [ ] **Connect the provider adapter.** Enable JSON in SearXNG's `search.formats` and integrate `/search?format=json` with the existing provider-neutral research pipeline. Normalize URLs, titles, snippets and engine provenance; test malformed/empty/partial responses and disabled JSON (403). See the [official Search API](https://docs.searxng.org/dev/search_api.html).

### SX03

- [ ] **Bound requests and fail honestly.** Enforce query/time/concurrency limits, timeouts, cancellation and bounded backoff. Respect upstream rate limits and engine terms; surface CAPTCHA, blocking and unavailable engines as recoverable failures, without bypassing them, retry storms or paid fallback. Self-hosting does not promise unlimited searches or availability; upstream [blocking/CAPTCHA limits](https://docs.searxng.org/admin/searx.limiter.html) still apply.

### SX04

- [ ] **Minimize outgoing context.** Derive the smallest relevant query locally from authorized context; exclude credentials and unnecessary personal/file/screen content. Explain that enabled upstream engines receive queries. Disable query/body logging by default and test redaction without retaining raw screenshots, microphone audio or whole conversations.

### SX05

- [ ] **Read and cite original evidence safely.** Fetch selected original pages/PDFs through the bounded source reader, validating public HTTP(S) destinations, DNS resolution and every redirect against private-network/loopback access. The explicitly configured local search endpoint is separate from fetched result URLs. Preserve cancellation, size/time limits and untrusted-content boundaries; check dates, conflicting claims and citations against actually read source passages rather than search snippets.

### SX06

- [ ] **Set retention and licensing explicitly.** Document permitted caching/retention for each upstream engine and fetched source before persisting results; provide local expiry and deletion for permitted evidence. Review SearXNG's [AGPL-3.0 obligations](https://github.com/searxng/searxng/blob/master/LICENSE), dependency notices and corresponding-source/distribution/network-use requirements before shipping; do not assume its license grants rights to upstream content.

### SX07

- [ ] **Package and verify on the target Mac.** Pin and verify helper/runtime dependencies, document update/licensing support, and test startup health, port conflicts, failure recovery, Stop/cancel and clean shutdown without orphan processes. Verify signed/package helper boundaries, no unintended LAN exposure, offline Qwen/Splash operation without search, and a live search → original-page reading → supported-citation workflow on the native Mac. Record exact source/package and automated/native evidence separately; installation remains a separate step.

### R39

- [ ] Offer activity presets **Low/minimum every 10 minutes, Normal/average every 4 minutes, High/maximum every 1 minute; default High**. These replace the earlier two-to-five-minute cadence. Define how randomized proactive questions relate to presets, busy/quiet/fullscreen/call states and times with no useful idea; do not invent an unconditional speaking timer.

### R40

- [ ] Add very proactive context-aware suggestions, useful questions, breathing, blinking, gaze/head motion and varied reactions across idle/listening/thinking/researching/speaking states. Keep every face warm and smiling while using articulated friendly speech animation: varied mouth shapes/visemes timed to actual speech where supported or aligned locally, rounder open eyes/highlights and relaxed gently arched brows. Focus, thinking and research must not introduce angry inward V-brows, glaring slit eyes or scowls. Treat prototype expressions as illustrative, not proof of lip-sync accuracy. Keep pointer/gaze responsiveness distinct from mouth movement; prioritize relevance and avoid duplicate suggestions.

### R41

- [ ] Provide **11 selectable native Settings choices: Original plus Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo and Nova**. Original remains default until changed. Veil replaces Fold; preserve the existing appearance while implementing skins as a separate reviewable batch with shared interfaces. Several skins use native Liquid Glass/transparent or circular/fluid voice-mode treatments, with a larger expressive face. Prefer SwiftUI/Core Animation, configurable animation detail/motion and Apple accessibility. Selection of all ten for the roadmap is not evidence that any new skin is implemented.

### R42

- [ ] Avoid text, buttons, useful content and unsafe swept movement paths during normal roaming; preserve the installed conservative placement fixes, manual drag/pin/menu-bar recall, keyboard/accessibility access and compact native UI.

### R43

- [ ] Add a **distinct tiny local idle-motion fallback**: do not remain still for more than one minute; when no normal safe route exists, move very slowly by a very small amount around the current place so the pet feels alive. Decide whether this is character animation within the existing panel or movement of the whole panel, along with amplitude, speed, cursor handling and accessibility/pin/pause interactions. Do not claim the exception guarantees zero content overlap or silently restore indefinite stillness as the target.

### R44

- [ ] Test normal safe routing and this fallback separately across changing content/displays. Installed behavior still holds position on uncertainty or no safe route; it does not yet implement the new fallback. Exact safe semantic placement for every app/display is not complete.

### R45

- [ ] Provide native app launching, Accessibility-based click/type/navigation, supported browser operations, local file/document creation/editing/organization, coding/build/test tools, local document search and live web research.

### R46

- [ ] Build an executor that plans, executes, verifies results, recovers/retries within bounds and reports honestly. Honor the user's maximum-autonomy/no-repeated-app-confirmation preference within actual OS/provider restrictions. Validate tool arguments and targets; support action history, cancellation and recovery/undo where possible. Do not invent additional approval policies as already agreed. The broader tools roadmap is authorized in tested stages; it remains a separate implementation milestone from the first voice slice.

### R47

- [ ] Add durable **local text history with Read / Copy / Delete**, editable local memory, project/task context and useful preference learning. Current history is RAM-only. Define bounded storage, learned-fact retention, review/edit/delete, failure and recovery behavior; do not store microphone audio or screenshots under the existing plan.

### R48

- [ ] Decide how long findings/reports fit the compact UI and requested native options without losing readable detail.

### R49

- [ ] Add version-matched access to dot's own source and Siri/App Intents integration.

### R50

- [x] Research the separate **T3-Video-Wan2.2-5B** feature and Apple Silicon resource/runtime fit. It is not a dependency of the fast voice path and must not silently replace its models.

### R51

- [ ] Preserve a complete bundled offline owner app. Implement a public first-launch downloader for pinned, verified assets with progress, disk-space checks, interruption/retry, corruption handling and offline reuse; no external folder/server setup requirement. Offline core operation and online research are separate acceptance cases.

### R52

- [ ] Implement hardware/OS gates and test the intended **M4 Pro-class/36 GB minimum, 48 GB recommended**, with macOS 26.4+ for the selected Splash runtime. Reported personal test class is M5 Pro/48 GB. These targets are not universal certification or proof on a 36 GB device.

### R53

- [ ] Complete clean supported second-Mac acceptance, license/redistribution notices, suitable asset delivery, distribution signing/notarization and exact-artifact installer tests. Existing personal development signing and payload-free CI DMGs do not establish a public release.

### R54

- [ ] Keep the face as the quick interaction surface, with readable state text for listening, waiting, researching, acting, speaking, paused and unavailable. Distinguish real progress from decorative animation.

### R55

- [ ] Add a compact task/result card with **Open result**, **Sources**, **Pause/Stop**, **Resume** and **Undo where supported**. Show the action's actual outcome and any incomplete step.

### R56

- [ ] Show “Why this suggestion?” with the relevant file, screen context or research evidence; make suggestions dismissible and remember dismissals.

### R57

- [ ] Keep spoken summaries short and let longer research expand into a readable native panel or document preview. Use opaque readable text surfaces where transparency would hurt contrast.

### R58

- [ ] Offer drag-and-drop and a keyboard shortcut/macOS Service for explicit delegation; keep vital controls usable without facial animation, hover or a microphone.

### R59

- [ ] Preserve Original as the default and offer all ten accepted new skins in native Settings. The delivered v3 board and motion study guide implementation; artwork remains illustrative, and native glass, accurate speech synchronization and runtime performance require implementation and device checks.

### R60

- [ ] For each implemented slice, run relevant focused tests and required repository gates; document failures/unrun checks and any warning. Validate concurrency, cancellation, permission loss, errors and recovery.

### R61

- [ ] Exercise all selected silence and invitation values: resumed-speech resets; no LLM/research before the boundary; no-speech timeout; speech starting near invitation expiry; final-audio ordering; intermediate/repeated drains; invalid intent; stale turns; echo; route changes; Stop and permission revocation.

### R62

- [ ] Verify settings persistence, randomized proactive scheduling, foreground priority, fallback motion/accessibility and research/tool outcomes on the actual target Mac. Test offline speech/local memory separately from connected research and provider failures.

### R63

- [ ] Compare full-pipeline p50/p95, actual audible output, quality and resource use against the preserved baseline before replacing a working component. Keep device/display limitations explicit.

### R64

- [ ] Before installation, review the integrated exact candidate and run applicable native acceptance; preserve stable signing/permissions and recoverable prior app. Before public release, satisfy the separate [exact-artifact acceptance contract](offline-acceptance.md).

### R65

- [ ] **Keep all faces friendly in every state.** Apply rounder open eyes/highlights, relaxed gently arched brows and a gentle upturned resting mouth to Original and all ten new skins, including focused, thinking and researching states. Exclude angry inward V-brows, glaring slit eyes and scowls; preserve each identity and friendly articulated speech. Verify truthful task labels independently. Complete a fresh browser review of the corrected preview and verify native expressions; even rerun parameter-uniqueness/friendliness checks are not visual acceptance.

### R66

- [x] **Use a shared native rig for ten new identities while retaining Original.** Combine brows, eyelids, pupils/gaze, cheeks, mouth, head and body posture, with anatomy-specific controls such as wings or leaves. Prefer SwiftUI phase/keyframe animation and Core Animation before adding a custom rendering engine. A genuine 3D implementation would be a separate measured choice. [Apple animation timing](https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations)

### R67

- [ ] **Set a real production acceptance target:** at least **120 reviewed, visibly distinct, context-appropriate named animation recipes per new skin**. Every recipe needs a name, trigger, duration, compatible states and cancellation/interruption behavior. Exclude misleading combinations; counting a state/expression Cartesian product alone does not establish 120 useful animations. The delivered interactive prototype's 120 selectable combinations are exploration, not 120 individually authored clips, a completed production library or real audio/phoneme synchronization.

### R68

- [ ] **Tie reactions to actual events.** Glance toward relevant content, respond visibly to listening, and celebrate only a verified result. [EMO](https://living.ai/emo/) advertises many combined expressions/actions; [Eilik](https://www.energizelab.com/eilik/) documents touch- and motion-triggered reactions. These are product examples, not evidence of proprietary rig architecture or a transferable performance benchmark.

### R69

- [ ] **Separate emotion from status.** Always expose clear listening/microphone, silence-countdown, researching, acting/verifying, speaking and reply-window state. A smile does not prove that the mic is off or that a task succeeded. Keep Stop, quiet/mute and keyboard access discoverable. [Apple feedback](https://developer.apple.com/design/human-interface-guidelines/feedback), [documented ChatGPT voice controls](https://help.openai.com/en/articles/8400625-voice-mode-faq)

### R70

- [ ] **Synchronize speaking to playback.** Use actual audio time and available or locally derived phoneme/viseme alignment; pause/cancel the face with audio. An amplitude-driven mouth is a fallback, not accurate phoneme synchronization. An audio player timeline does not itself generate visemes. [Apple audio timeline](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)

### R71

- [ ] **Keep glass readable on real desktops.** Clear bodies may reveal underlying content, but eyes, mouth, activity labels and buttons need reliable contrast. Native material adaptation, Reduce Transparency/Increase Contrast alternatives and non-glass research surfaces are required. Illustrative refraction in artwork is not a native Liquid Glass implementation. [Apple Liquid Glass guidance](https://developer.apple.com/videos/play/wwdc2025/219/)

### R72

- [ ] **Make motion varied and bounded.** Use irregular blinking, small gaze shifts, short reactions and tiny idle movement; avoid constant large bouncing or repeated attention demands. Preserve the user's one-minute stillness requirement while resolving character motion versus whole-window drift. Reduce Motion needs a calmer alternative. [Apple motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion), [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)

### R73

- [ ] **Keep animation independent of Qwen.** Animate from task events and local deterministic timers; never invoke the LLM for each blink. Limit redraws to the pet, reduce hidden rendering and measure frame hitches and energy alongside voice latency. Native APIs alone do not prove a battery or speed advantage. [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)

### LP01

- [ ] Use one slim halo inset within the existing character hit and placement bounds. Do not add a ring for every background task. Keep the actual task stage readable on focus and available to accessibility. If an initially short task exceeds two minutes, promote it once to long-task presentation.

### LP02

- [ ] Derive a determinate arc from measurable completed work and an explicit remaining plan, never elapsed time alone. When scope is unknown, show a distinct restrained activity arc and the actual stage rather than inventing 50%, 80% or 95% progress. Map the requested speech checkpoints to real plan milestones and deduplicate them per task and plan version.

### LP03

- [ ] Start with the goal, first step and a calibrated estimate range; say timing is unknown when no reasonable estimate exists. Each milestone update should be one brief sentence covering done and next, with a revised estimate only when it materially changes. Do not speak percentage numbers.

### LP04

- [ ] Use the 95% milestone only when final verification is genuinely underway. Complete the ring and show success only after the result is verified. Newly discovered work must revise the stage and estimate transparently; no artificial near-complete stall.

### LP05

- [ ] Never overlap these updates with the user speaking, listening capture or another voice response. Coalesce crossed thresholds and avoid catch-up bursts after resume or restart. Stop cancels queued updates; mute, quiet and calls are respected. Supply an equivalent text status.

### LP06

- [ ] Show paused, blocked and failed states distinctly, with an actionable reason. Preserve Stop and Resume where supported. Declarative progress updates do not open an automatic microphone invitation.

### LP07

- [ ] Make contrast independent of color alone, keep static status under Reduce Motion, and expose task/stage to VoiceOver without constant announcements. Stop hidden animation and measure energy use.

### LP08

- [ ] Test threshold deduplication, jumps, revised estimates, unknown scope, foreground interruptions, mute, cancellation, restart, multiple tasks, stale events and false completion. Native review across all eleven skins, contrast and clipping belongs to the later owner-Mac acceptance list.

### MAC01

- [ ] Verify complete Apple Silicon/macOS 26.4+ bundle readiness, model/runtime/Whisper integrity, stable signing identity, exact commit and artifact hashes on suitable target hardware.

### MAC02

- [ ] Run actual microphone → Whisper → selected local Qwen/Splash → audible British `bf_isabella`; repeat and interrupt turns, including no-speech, near-expiry invitations and all silence/invitation settings.

### MAC03

- [ ] Measure real acoustic onset, speech-end and post-silence p50/p95, stop-to-silence/next-turn delay, recognition quality and CPU/GPU/ANE/RAM/thermal/battery usage; include noise, echo, headphones and Bluetooth.

### MAC04

- [ ] Verify microphone/screen permission denial and revocation, route changes, sleep/wake, foreground preemption, no stale capture restart, and helper cleanup after Quit/relaunch.

### MAC05

- [ ] Review all 11 native skins on light/dark/photo desktops, Increase Contrast/Reduce Transparency/Reduce Motion, mixed displays, keyboard/Options/typed fallback, actual playback alignment, and per-skin perceptual animation coverage.

### MAC06

- [ ] Exercise real local source/index/memory/task/research/action workflows, interruption/restart recovery, safe deletion, quit during an action, artifact verification and permitted export/sharing. No fake-source or synthetic-only test substitutes for these.

### MAC07

- [ ] Verify native App Intents/Siri discovery and permission-gated EventKit/Accessibility/browser integrations actually used by the completed product.

### MAC08

- [ ] Preserve the previous installed app and all user data, then perform a separately authorized recoverable replacement and installed-path smoke test. No current cloud activity changes the installed app.

### MAC09

- [ ] Run clean supported second-Mac installation, relocation, offline behavior, downloader recovery and distribution signing/notarization acceptance before public release.


## Historical milestone ledger

These five checked rows belong to exact historical candidate `6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc`, later merged through PR #2. They are excluded from the 97-current denominator. They do not certify current main, an installed replacement or public release.

### H01

- [x] **Candidate source/checks:** persisted native silence choices 2/3/5/8 seconds (default 3) and question invitations 3/6/9/12/20 seconds (default 6); monotonic capture deadlines, resumed-speech resets and serialized boundary handling. Only satisfied silence submits the next transcription/LLM turn; the 60-second limit does not submit an unfinished utterance.

### H02

- [x] **Candidate source/checks:** explicit validated turn-bound question intent, successful terminal generation and final ordered synthesis/playback barrier, bounded invitation and cancellation. A reply begun in time continues to selected silence within capture bounds. Permission/route/stale-callback protections are implemented; actual echo and device-route behavior remain hardware gates.

### H03

- [x] **Candidate source/checks:** compact diagnostics/Show Dot/Quit integration and 11 persisted native appearance choices with Original default. Five shared named friendly phase recipes and current-player amplitude-driven mouth motion are implemented; this is not phoneme alignment or 120 reviewed recipes per skin.

### H04

- [x] **Exact-revision verification:** `verify_macos.sh` passed **129 Python, 175 SwiftPM, 277 native XCTest and 49 static guards**, exact voice/Splash sandbox checks, Debug/Release and development packaging, with **zero warnings**. Suites overlap; do not sum them as unique tests. These results do not certify real microphone/speaker behavior.

### H05

- [x] **Candidate assembly:** complete offline candidate assembled from existing assets; real Whisper linking, full runtime/model audits and strict signature verification passed. No model downloads, runtime upgrades or asset replacements. The candidate is ad-hoc signed, not notarized or installed.


## Source authority and reading order

1. The user's latest explicit direction governs within applicable safety and OS/provider restrictions. The latest direction stops development; the next team must establish its own authorization and ownership before resuming. This handover does not transfer credentials, publishing rights, computer access or installation authority.
2. `docs/BUILD_CHECKLIST.md` is the canonical future-product checklist. Preserve exact requirements and scoped status; the text companion is not a competing specification.
3. Exact source at a commit establishes what is published. Match app composition and build registration to claimed capabilities.
4. Exact CI logs, source/artifact manifests and physical acceptance establish their respective scope. A prose summary cannot overrule a failed mandatory gate.
5. Dated PROGRESS and CONTINUATION records explain provenance. Older checkpoint paragraphs remain historical even when fetched from a new commit.
6. Staged designs and preserved unpublished work show proposed architecture or implementation candidates. Local tests do not validate later integration automatically.
7. Concept boards, motion studies and component references guide design; they do not certify native behavior or full-pipeline performance.

### Access and missing material

Repository access is required where GitHub restricts the project. This Markdown contains context and the full checklist, not repository code, preserved patches, model weights, runtime payloads, signing identities or full CI logs. Obtain them through owner-authorized project channels and verify identities. Do not manufacture missing assets or treat a source link as a grant of access. Some larger preserved implementation remains unpublished; its verified final inventory must accompany the actual code handover.

### Pinned source index


- [docs/BUILD_CHECKLIST.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/BUILD_CHECKLIST.md)

- [docs/PROGRESS.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/PROGRESS.md)

- [docs/CONTINUATION.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/CONTINUATION.md)

- [README.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/README.md)

- [CONTRIBUTING.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/CONTRIBUTING.md)

- [Package.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/Package.swift)

- [src/App.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/App.swift)

- [src/Engine.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/Engine.swift)

- [src/BundledSplash.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/BundledSplash.swift)

- [src/SearchRuntimeManager.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/SearchRuntimeManager.swift)

- [src/SearchEgressBroker.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/SearchEgressBroker.swift)

- [src/SearchRuntimePayload.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/SearchRuntimePayload.swift)

- [src/ResearchHTTPTransport.swift](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/src/ResearchHTTPTransport.swift)

- [docs/verification/scoped-progress.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/verification/scoped-progress.md)

- [docs/architecture/staged-services.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/architecture/staged-services.md)

- [docs/verification/video-feasibility.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/verification/video-feasibility.md)

- [packaging/splash-vision-source-manifest.json](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/packaging/splash-vision-source-manifest.json)

- [Resources/bundled-models.json](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/Resources/bundled-models.json)

- [docs/voice-bridge.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/voice-bridge.md)

- [packaging/voice/complete-voice-lock.json](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/packaging/voice/complete-voice-lock.json)

- [packaging/voice/complete-closure-audit.json](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/packaging/voice/complete-closure-audit.json)

- [docs/offline-voice-assembly.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/offline-voice-assembly.md)

- [docs/runtime-reconstruction.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/runtime-reconstruction.md)

- [packaging/runtime/reconstruction-policy.json](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/packaging/runtime/reconstruction-policy.json)

- [docs/self-contained-build-plan.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/self-contained-build-plan.md)

- [docs/offline-acceptance.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/offline-acceptance.md)

- [docs/authenticated-splash-transport.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/authenticated-splash-transport.md)

- [docs/search-helper.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/search-helper.md)

- [docs/source-transport.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/source-transport.md)

- [docs/verification/search-proxy-canary-ci.md](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/docs/verification/search-proxy-canary-ci.md)

- [scripts/verify_macos.sh](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/scripts/verify_macos.sh)

- [scripts/verify_search_real_vertical_canary.sh](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/scripts/verify_search_real_vertical_canary.sh)

- [.github/workflows/ci.yml](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/.github/workflows/ci.yml)

- [.github/workflows/search-proxy-canary.yml](https://github.com/Emin-dev/Dot/blob/2714811cb75bb5af935bd33997eebc78c0a63d96/.github/workflows/search-proxy-canary.yml)

## Final stopped session addendum

At 23:38 UTC the last verified main is `a811f6da5acbe12700be899d7dcddd113ca8fefe`. The native terminal failure and Search terminal result are recorded above. Development, child implementation work and project automations are stopped; no claim is made that autonomous monitoring will continue. Final safe source preservation/publication is separate from implementation.

The integration owner verified the preserved expanded checkpoint as 310 files totaling 6,640,396 bytes, unchanged from its 14 October 18:54 UTC snapshot. This is source preservation, not an integrated or tested final tree. Its final portable inventory/location belongs in the repository handoff receipt. Never restore that snapshot over newer main files. Latest remaining TLS test failure is bounded backpressure-worker settlement; the actual Search runtime failure cause remains unconfirmed.
