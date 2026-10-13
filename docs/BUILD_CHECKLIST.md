# dot: product roadmap and build checklist

Agreed direction, updated 2026-10-13. **This is the canonical future-product checklist.** [PROGRESS](PROGRESS.md) records verified source, tests and installation; agreement here does not mean a feature is built. All future capabilities below remain unchecked. This update changes documentation only.

dot is a very fast, voice-first, Apple-native macOS AI companion. **Speed comes first; a warm, calm, high-quality British female voice generated locally comes second.** It should understand relevant work, research facts, act helpfully and feel alive. Prefer Apple-native solutions and frameworks for every subsystem; use custom components where necessary or demonstrably better under these requirements. This principle preserves the fixed Splash/Qwen LLM and the required British voice.

## At a glance

| Area | Agreed target; not a completion claim |
| --- | --- |
| Local AI | Qwen 3.8 27B Q4 through Splash; current pinned baseline Splash 1.3.1 with target, draft and vision assets |
| App architecture | SwiftUI/AppKit UI, Rust core/coordination/tools/research/history, thin Swift Apple-framework adapters; staged migration measured against the working app |
| Speech | Local British female voice, Kokoro `bf_isabella` quality reference; benchmark native speech candidates without silently substituting voices |
| Turn ending | Configurable continuous silence **2 / 3 / 5 / 8 seconds; default 3**, before reasoning or research on the utterance |
| Question replies | After an actual final audible question, **3 / 6 / 9 / 12 / 20 seconds; default 6**, to begin speaking |
| Proactive activity | Native options: **Low every 10 minutes / Normal every 4 minutes / High every 1 minute; default High**; randomized question timing still to design |
| Context and research | Automatic screen awareness, relevant accessible files and background observation; internet always available for research, local AI processing/speech/memory |
| Pet and UI | Compact native UI, richer personality, safe routes plus tiny local idle-motion fallback; preserve existing design and compare **ten new alternatives**, several using native Liquid Glass/transparent treatments |
| Tools and records | Mac/browser/file/coding tools, verified outcomes, durable local text history, editable memory and project/task context |
| Delivery | Preserve complete offline owner bundle; future public verified first-launch downloader, hardware gates and proper distribution acceptance |

## Required sequence before implementation

Documentation publication is authorized now. App code changes, rebuilds, installation and model changes are **not** authorized by this checklist publication.

1. Publish this plan and explain the app, stack, features, tradeoffs and current gaps.
2. Think/research the unresolved choices, show the existing design plus ten new selectable visual directions, and ask the remaining design/voice questions.
3. Present a concise complete stack/features checklist and **ask for final permission to build**.
4. Only after that explicit go-ahead, begin implementation with several parallel agents in the lanes below. Do not dispatch implementation agents before this gate.

Open decisions do not block publishing this plan. A design comparison is exploration, not ten implemented skins or approval of a theme.

## Verified baseline and preserved work

| State | Evidence and limits |
| --- | --- |
| Public source before this docs update | `main` at [`1d04b89`](https://github.com/Emin-dev/Dot/commit/1d04b89c4722efa9c88819aa598642369639db9d), rechecked 2026-10-13; that commit changes documentation only |
| Installed personal app | [`b26a145`](https://github.com/Emin-dev/Dot/commit/b26a14505bd2bc8e57264f1dfc934f778a8bd781), assembled, signed, installed and launched; later prose does not change its executable |
| Exact installed-source checks | [CI](https://github.com/Emin-dev/Dot/actions/runs/38417684255) and native verification: 190 XCTest, 109 SwiftPM, 129 Python, 44 static guards; zero warnings; real Whisper linking and complete assembly passed. Suites overlap; do not sum them as unique tests |
| Device/owner acceptance | Historical owner-confirmed voice and real screen-aware replies; the installed repair produced a permitted placement map. Fresh owner smoke test, broader physical drag/multi-display/Space use and clean second-Mac acceptance remain open |
| Preserved compact UI work | Already rebased onto `1d04b89`, reviewed, **unpublished and uninstalled**: nine-file patch, resulting tree `d0f53b46f9b4573fb6d4383caae8185ddab31dbe`. Receipt records 129 Python and 48 static guards historically passed; new Swift/UI tests not run. Compact errors, Show/Quit menu and question-policy/parser scaffolding exist; automatic question microphone integration remains inert |

Preserve original dirty workspaces, installed app, history and the unpublished patch. Inspect active writers and the intended integration base before applying it; never replace current files wholesale with an older snapshot. Do not reclassify historic checks as tests of a future merge.

## Architecture and performance

Current coordination is Swift. The working voice path is native whisper.cpp `base.en` batch transcription, a bundled Python/Kokoro helper, and AVAudioEngine/AVAudioPlayer; placement uses ScreenCaptureKit/Vision. The requested Rust service core is not implemented. Splash remains the inference runtime: changing orchestration language does not by itself make model inference faster.

- [ ] Design staged Swift/Rust service boundaries for coordination, tool execution, research, indexing, history and memory; keep Apple framework adapters thin and the UI responsive.
- [ ] Keep Qwen 3.8 27B Q4, Splash 1.3.1 baseline and pinned target/draft/vision assets. No alternate cloud LLM or Apple Foundation Models replacement has been authorized. The `mlx-community` checkpoint publisher name is not an inference-engine switch.
- [ ] Jointly benchmark streaming STT candidates **Parakeet EOU** and **Apple SpeechAnalyzer**, including recognition quality, offline asset provisioning and contention with Splash. No winner is established.
- [ ] Evaluate native Core ML Kokoro only if it matches the desired British female voice and outperforms the working path. Keep `bf_isabella` as the quality reference. Exact identity versus a sufficiently similar British voice is open; an American-only substitution is unacceptable.
- [ ] Consider Apple built-in speech as an optional native speech profile; do not promise access to Siri's exact voice. Core ML is being considered for speech, not as a replacement for Splash/Qwen.
- [ ] Measure resident-model policies, prefix caching, streaming STT, sentence TTS, reduced copying/IPC, prioritization and cancellation. Keep animation/placement cheap and independent of the 27B model; do not run multiple 27B models for background tasks.
- [ ] Benchmark speech and Splash together across GPU/ANE/memory contention, quality, heat, battery and RAM. Keep full payload integrity, process ownership and cancellation checks.
- [ ] Report speech-end to **first audible response including the selected silence interval** (default three seconds), post-silence processing separately, cold/warm readiness, interruption latency and p50/p95. Scheduled playback is not measured audible sound. Deep research can take longer. No fastest-pipeline result, guaranteed three-to-five-second answer or Rust speed multiplier is established.

## Conversation and native options

- [ ] Expose trailing-silence choices **2, 3, 5, 8 seconds, default 3**. Require uninterrupted silence for the selected duration before reasoning or web research on that turn. Resumed speech resets the timer. Streaming transcription may run while listening; do not reason on an unfinished utterance. Pause/deprioritize background reasoning on foreground interaction.
- [ ] Expose question invitation choices **3, 6, 9, 12, 20 seconds, default 6**. This is the time to **begin speaking after dot's final audible question**, not TTS duration or maximum utterance length. No speech closes the microphone; speech begun in time continues until the selected trailing-silence threshold, subject to ordinary capture/sample limits (current overall bound: one minute).
- [ ] Use validated explicit question intent and successful complete generation plus **all final question audio actually finished** before arming the mic. Punctuation, quotations or rhetorical questions alone cannot arm it. An intermediate audio-queue drain is not final completion.
- [ ] Bind intent, synthesis, playback and capture to the current turn with stale callback cancellation, one-time continuation authority, echo protection and fresh microphone permission. No automatic OS permission prompt. Stop/click replacement, drag/menu, hiding, Quit, sleep, route changes and permission loss cancel pending listening.
- [ ] Apply the same bounded invitation to random proactive questions after their audible completion. There is no independent random microphone opening without a question.
- [ ] Preserve click-to-interrupt/Stop. Decide hands-free speech interruption, wake word, maximum automatic reply chain and measured echo-settle behavior; scaffold constants are not agreed product limits.
- [ ] Add these controls and the activity presets below in native settings/options. A compact native surface may preserve the style; exact presentation remains open. Earlier no-Settings-window wording must not erase the requested controls.

## Screen, files and online research

The user has authorized broad autonomous use of relevant screen content, documents/files, Work/Downloads, iCloud Drive and other accessible folders, including relevant screen/file information in web research. **Web requests may contain screen data; this permission is decided.** Local reasoning does not mean network-free web queries: online services receive the requests needed for research. No cloud LLM replacement or conversation-upload feature is authorized by this direction.

- [ ] Provide automatic screen awareness before answering and background observation without a fresh request, to discover useful context and proactively help. This expands the installed explicit-turn capture plus sparse local placement behavior; it is not installed today.
- [ ] Keep native permission grants, visible capture/pause controls and honest unavailable-context reporting. Broad autonomy does not bypass macOS consent, protected-system/keychain restrictions, provider rules or actual accessibility.
- [ ] Build a local file/document index with event/change-driven updates, relevance ranking, deduplication and background opportunity discovery. Avoid repeated whole-disk scans. Handle iCloud placeholders/downloads explicitly; accessible cloud documents are not necessarily already offline.
- [ ] Make online research/deep research the default before most factual answers and support automatic background research. Keep internet available as a product capability; report connectivity/provider failures honestly.
- [ ] Use multiple searches, actual page/PDF reading, original sources, publication/event dates, follow-up queries, conflict cross-checks and citations. Similar usefulness to Perplexity/ChatGPT is an aspiration, not proven parity.
- [ ] Choose search provider/budget, research time budget and whether a quick provisional answer precedes full research. Do not imply permission to send relevant context remains undecided.
- [ ] Treat screen, website, PDF, document and model content as untrusted data. Reading it never grants authority to override the user's goals, expand permissions or issue tool commands.

AI processing, speech and durable memory remain local. Web retrieval is a separate network-capable service; keep the inference/speech isolation boundaries while designing it. Existing plans exclude stored microphone audio and screenshots; retention of learned text facts remains a design decision.

## Proactive personality, movement and visual design

- [ ] Offer activity presets **Low/minimum every 10 minutes, Normal/average every 4 minutes, High/maximum every 1 minute; default High**. These replace the earlier two-to-five-minute cadence. Define how randomized proactive questions relate to presets, busy/quiet/fullscreen/call states and times with no useful idea; do not invent an unconditional speaking timer.
- [ ] Add very proactive context-aware suggestions, useful questions, breathing, blinking, gaze/head motion and varied reactions across idle/listening/thinking/researching/speaking states. Give the face expressive speech animation rather than a fixed smile: varied mouth shapes/visemes timed to actual speech where supported or aligned locally. Treat prototype expressions as illustrative, not proof of lip-sync accuracy. Keep pointer/gaze responsiveness distinct from mouth movement; prioritize relevance and avoid duplicate suggestions.
- [ ] Preserve the existing design as a selectable direction and present **ten new distinct selectable UI alternatives**, several with native Liquid Glass/transparent treatments and circular/fluid voice-mode designs inspired by the general ChatGPT voice interaction, with a larger character/icon and an expressive face like the existing pet. Prefer SwiftUI/Core Animation; expose configurable animation detail/motion that respects Apple accessibility. No option is selected and no new theme is implemented. Choose appearance and settings presentation after comparison and questions.
- [ ] Avoid text, buttons, useful content and unsafe swept movement paths during normal roaming; preserve the installed conservative placement fixes, manual drag/pin/menu-bar recall, keyboard/accessibility access and compact native UI.
- [ ] Add a **distinct tiny local idle-motion fallback**: do not remain still for more than one minute; when no normal safe route exists, move very slowly by a very small amount around the current place so the pet feels alive. Decide whether this is character animation within the existing panel or movement of the whole panel, along with amplitude, speed, cursor handling and accessibility/pin/pause interactions. Do not claim the exception guarantees zero content overlap or silently restore indefinite stillness as the target.
- [ ] Test normal safe routing and this fallback separately across changing content/displays. Installed behavior still holds position on uncertainty or no safe route; it does not yet implement the new fallback. Exact safe semantic placement for every app/display is not complete.

## Mac tools, local records and delivery

- [ ] Provide native app launching, Accessibility-based click/type/navigation, supported browser operations, local file/document creation/editing/organization, coding/build/test tools, local document search and live web research.
- [ ] Build an executor that plans, executes, verifies results, recovers/retries within bounds and reports honestly. Honor the user's maximum-autonomy/no-repeated-app-confirmation preference within actual OS/provider restrictions. Validate tool arguments and targets; support action history, cancellation and recovery/undo where possible. Do not invent additional approval policies as already agreed; the explicit pre-build gate above remains required.
- [ ] Add durable **local text history with Read / Copy / Delete**, editable local memory, project/task context and useful preference learning. Current history is RAM-only. Define bounded storage, learned-fact retention, review/edit/delete, failure and recovery behavior; do not store microphone audio or screenshots under the existing plan.
- [ ] Decide how long findings/reports fit the compact UI and requested native options without losing readable detail.
- [ ] Add version-matched access to dot's own source and Siri/App Intents integration.
- [ ] Research the separate **T3-Video-Wan2.2-5B** feature and Apple Silicon resource/runtime fit. It is not a dependency of the fast voice path and must not silently replace its models.
- [ ] Preserve a complete bundled offline owner app. Implement a public first-launch downloader for pinned, verified assets with progress, disk-space checks, interruption/retry, corruption handling and offline reuse; no external folder/server setup requirement. Offline core operation and online research are separate acceptance cases.
- [ ] Implement hardware/OS gates and test the intended **M4 Pro-class/36 GB minimum, 48 GB recommended**, with macOS 26.4+ for the selected Splash runtime. Reported personal test class is M5 Pro/48 GB. These targets are not universal certification or proof on a 36 GB device.
- [ ] Complete clean supported second-Mac acceptance, license/redistribution notices, suitable asset delivery, distribution signing/notarization and exact-artifact installer tests. Existing personal development signing and payload-free CI DMGs do not establish a public release.

## Open decisions to resolve after explanation

| Decision | What is already fixed |
| --- | --- |
| British voice identity and speech candidates | Local warm/calm British female; `bf_isabella` reference, no American-only fallback; compare full-pipeline quality/latency before replacement |
| UI direction, settings and long reports | Existing design plus ten new alternatives; native controls for the agreed timer/activity values; no chosen theme |
| Randomized questions, busy/quiet/fullscreen/calls and no useful idea | Low 10 / Normal 4 / High 1 minute, default High; question completion must precede any automatic mic invitation |
| Idle-motion form, amplitude, speed, cursor/accessibility/pin behavior | Tiny slow local fallback after at most one minute still; normal routes avoid useful content; no zero-overlap guarantee for the exception |
| Hands-free interruption, wake word and reply-chain bounds | Click-to-interrupt/Stop and selected silence/invitation timers are retained |
| Search provider/costs, time budget and provisional answers | Research before most factual answers, internet available, relevant screen/file context in requests already authorized |
| Learned-fact retention and memory presentation | Local editable memory/history, Read/Copy/Delete, existing exclusion of stored mic audio/screenshots |

## Future parallel work lanes

Only begin after the explanation/questions and final explicit permission. Agree shared interfaces and one integration owner; each lane preserves the working app and unpublished patch.

| Lane | Scope and handoff |
| --- | --- |
| Voice/runtime | Configurable turn timing, validated question/final-audio gate, speech candidates and joint Splash benchmarks; no LLM substitution |
| Screen/pet | Native design/options, screen context, expressive states, safe routes and separately specified tiny-motion fallback |
| Research/files/memory | Retrieval quality, citations, indexed relevant context, background scheduling, local records and retention |
| Mac tools | Typed native/AX/browser/file/coding adapters, execution verification, cancellation, bounded recovery and action history |
| Integration/verification | Rust/Swift contracts, resource priorities, preserved patch integration, regression tests, device acceptance and release evidence |

## Definition of tested completion

A box can be checked only for its stated scope with exact revision/artifact and evidence. Record **source implemented**, **automated checks passed**, **native/device behavior verified**, **installed**, and **owner accepted** separately. Planning, scaffolding, review or green model-free CI does not complete a capability.

- [ ] For each implemented slice, run relevant focused tests and required repository gates; document failures/unrun checks and any warning. Validate concurrency, cancellation, permission loss, errors and recovery.
- [ ] Exercise all selected silence and invitation values: resumed-speech resets; no LLM/research before the boundary; no-speech timeout; speech starting near invitation expiry; final-audio ordering; intermediate/repeated drains; invalid intent; stale turns; echo; route changes; Stop and permission revocation.
- [ ] Verify settings persistence, randomized proactive scheduling, foreground priority, fallback motion/accessibility and research/tool outcomes on the actual target Mac. Test offline speech/local memory separately from connected research and provider failures.
- [ ] Compare full-pipeline p50/p95, actual audible output, quality and resource use against the preserved baseline before replacing a working component. Keep device/display limitations explicit.
- [ ] Before installation, review the integrated exact candidate and run applicable native acceptance; preserve stable signing/permissions and recoverable prior app. Before public release, satisfy the separate [exact-artifact acceptance contract](offline-acceptance.md).

See [contributor guidance](../CONTRIBUTING.md), [verified progress](PROGRESS.md), [current screen contract](screen-context-contract.md), [current placement policy](roaming-policy.md), [voice bridge](voice-bridge.md) and [assembly plan](self-contained-build-plan.md). Historical implementation details remain useful evidence; this checklist governs the newly agreed future direction.
