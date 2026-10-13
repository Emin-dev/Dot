# Dot: implementation and next steps

Updated 2026-10-13. **[Canonical product roadmap and build checklist](BUILD_CHECKLIST.md)** records the agreed future behavior, full stack, open decisions and explicit permission gate before implementation. This page is the verified status ledger, not a release certification. The documentation update changes no app behavior. Update checkboxes only with evidence.

## Current source and personal test app

- Default and only remote branch: `main`. The reviewed development history is merged and preserved. Do not recreate a parallel release branch just to update this checklist.
- Current installed personal-app source: [`b26a14505bd2bc8e57264f1dfc934f778a8bd781`](https://github.com/Emin-dev/Dot/commit/b26a14505bd2bc8e57264f1dfc934f778a8bd781). It was fully assembled, signed with the same approved development identity, installed and opened on 2026-10-13. Subsequent documentation-only commits do not change that installed source identity.
- The complete personal app contains the model/runtime assets and needs no external voice folder or model server. The owner reported voice working, and earlier real screen-aware turns reached generation and playback after the code-identity/OS-permission repair. The installed movement repair now also accepts a real permitted placement map; a fresh owner-led spoken/placement smoke test remains distinct from these component checks.
- There is no generally validated complete public installer yet. `build.sh` and ordinary CI produce a clearly incomplete UI/development DMG without the neural payload. Do not offer that artifact as a working AI companion.

## Implemented and verified

- [x] Native SwiftUI/AppKit floating companion, one character-sized panel, small right-click menu, no Settings/Connection/chat windows or persistent caption.
- [x] Manual dragging with a six-point threshold and no accidental microphone activation; pin, menu-bar recall, keyboard/accessibility options and Escape/Stop.
- [x] Explicit click to listen; a click during speech interrupts and listens again. Three-second trailing speech silence and one-minute capture bound remain.
- [x] Local Whisper base.en speech recognition and Kokoro 82M `bf_isabella` voice, with bundled Python/dependencies and private network-denied voice execution. Each selected speech model is under 6 GB.
- [x] Splash-only Qwen3.8-27B Q4 target, draft and vision assets. The checkpoint publisher's name does not change the inference runtime to MLX or llama.cpp.
- [x] Thinking enabled at low effort, bounded response streaming, sentence chunking, cancellation and stale-generation protection.
- [x] Ephemeral screen image before the reply, persistent Screen context opt-out, visible capture indicator, honest permission failures. Images are omitted from conversation history and are not sent to a cloud model.
- [x] In-memory recent text conversation, cleared on Quit or Clear conversation. No durable personal memory is claimed.
- [x] Full embedded runtime/model integrity verification on each app process, bounded parallel verification, and recording-time backend warmup. Existing verification measurements improved from median 13.13 to 7.27 seconds in six cached-filesystem samples; this is not an end-to-end response-speed guarantee.
- [x] Owned runtime cleanup, authenticated pinned local TLS, client response limits, private voice-output canonicalization, and relocated long-path voice initialization.
- [x] Native component acceptance: real voice PCM/playback/drain, cancellation/EOF, relocated voice, production Swift model text and synthetic-image answers, loopback identity and owned process shutdown.
- [x] Exact installed-source [CI](https://github.com/Emin-dev/Dot/actions/runs/38417684255): 190 XCTest, 109 SwiftPM, 129 Python and 44 static checks, with zero build/test/package warnings. The Mac repeated those checks and passed real Whisper linking and complete-payload assembly. Model-free CI remains separate from live device acceptance.

## Installed safe-placement repair

- [x] Random bounds/cursor-only wandering is removed. Movement now requires fresh permitted local analysis; it protects other-app windows, detected text, visually occupied tiles and cursor clearance across the full panel/path. Manual dragging remains independent.
- [x] Nonopaque pixels protect their entire padded tile as unknown occupancy instead of rejecting the whole map. New windows appearing during capture are accepted only when every earlier rectangle remains unchanged; all new rectangles are also protected. Any later geometry change still invalidates the map.
- [x] Native image-row orientation and synthetic occupancy tests passed. A real additive-window capture and a real map from the installed app passed on the owner's Mac. Original capture timestamps, bounded cadence, cancellation and the persistent Screen context switch remain enforced.
- [x] Privacy documentation covers sparse local placement analysis: no idle permission prompt, no retained screenshots/OCR text, and no placement image sent to the LLM.
- [ ] Broader mixed-monitor, dynamic desktop and sustained CPU/UX acceptance. A map can validly yield no safe route; Dot then stays still. Initial launch position is not guaranteed content-safe, and this is not perfect semantic understanding of useful content.
- [ ] Fresh owner-led smoke test of the newly installed personal build, including speech, interruption, screen context, dragging and placement during normal work.

## Agreed future work — pending implementation

The [canonical checklist](BUILD_CHECKLIST.md) is the source of truth for contracts and open choices. These summaries supersede earlier narrower roadmap wording; none is a completion claim.

- [ ] Integrate and test the preserved compact-error/Show Dot–Quit Dot UI work. The latest nine-file patch is already rebased on `1d04b89`, reviewed, unpublished and uninstalled, with result tree `d0f53b46f9b4573fb6d4383caae8185ddab31dbe`. Its receipt records historical 129 Python/48 static passes; new native Swift/UI tests have not run. Question policy/parser scaffolding remains inert, without Engine/STT/TTS or automatic microphone integration.
- [ ] Native options: trailing silence 2/3/5/8 seconds, default 3; question invitation 3/6/9/12/20 seconds to begin speaking, default 6; proactive Low 10 / Normal 4 / High 1 minute, default High. Resumed speech resets silence. No reasoning/research on an unfinished turn. Random proactive questions use the same validated final-audio/echo/cancellation mic gate; no unrelated random mic activation.
- [ ] Proactive screen awareness, broad relevant accessible file/context use, background discovery and researched factual answers. Relevant screen/file data in web requests is explicitly authorized; local reasoning does not make online queries network-free. Provider, time budget and provisional-answer choices remain open.
- [ ] Richer expressions and movement; normal routes avoid useful content and swept-path hazards, with a distinct tiny slow local fallback after at most one minute still. Fallback form, amplitude, cursor/accessibility behavior and possible overlap remain open. Current installed conservative holding behavior remains unchanged.
- [ ] Preserve existing visual design and compare ten new alternatives, several with native Liquid Glass/transparency and circular/fluid voice-mode treatments, larger expressive faces and speech-aligned mouth motion. No design is approved or implemented. Settings presentation and animation detail remain to design.
- [ ] Apple-native frameworks first; staged Rust core/coordination/tool/research/history services with thin Swift adapters. Retain Splash/Qwen. Benchmark streaming Parakeet EOU/Apple SpeechAnalyzer and native Core ML Kokoro against the British `bf_isabella` quality reference; no fastest pipeline or automatic Rust speedup is established.
- [ ] Measure full speech-end-to-audible latency including selected silence, post-silence processing, p50/p95, cold/warm readiness, quality, interruption and shared GPU/ANE/RAM/heat/battery use. Evaluate resident models, prefix caching, streaming, lower copying/IPC and scheduling without weakening integrity or cancellation.
- [ ] Mac/Accessibility/browser/file/coding tools with verified execution, bounded recovery, cancellation/action history and undo where possible. Maximum autonomy/no repeated app confirmations is the requested direction; actual OS/provider constraints remain. Do not present historic blanket confirmation rules as newly agreed policy.
- [ ] Durable local text history Read/Copy/Delete, editable memory, project/task context and preference learning; current history is RAM-only. Existing plans exclude stored mic audio/screenshots; learned-fact retention and long-report presentation remain open.
- [ ] Version-matched own-source access, Siri/App Intents and separate T3-Video-Wan2.2-5B research. Video is not a fast voice-path dependency.

## Hardware and distribution targets

- Requested target: native macOS, **M4 Pro-class or newer** Apple Silicon and **at least 36 GB RAM**. This is a target, not a verified support claim or a currently implemented hardware gate. It does not imply support for every base M4/M5 Mac.
- The selected Splash runtime requires macOS 26.4 or newer. Its published Q4 guidance is at least 36 GB, with 48 GB recommended. A 36 GB device has not passed this app's full workload/resource acceptance. M4 Pro commonly ships in 24/48 GB configurations, so the requested threshold normally means a 48 GB Pro configuration.
- The owner's reported test hardware is M5 Pro/48 GB; OS and actual app behavior were tested, but no blanket claim for all other Macs follows.
- Keep a complete all-in-one offline build. A future public small installer may automatically provision verified assets with visible progress if a single large download is impractical, as requested; no such public downloader is implemented today. Do not revive external folder/server setup.
- [ ] Clean supported second-Mac installation, relocation, offline voice/vision, denial/recovery, resources and mic/speaker quality acceptance.
- [ ] Public redistribution notices/licenses, appropriate distribution signing/notarization, and exact-artifact release checks. Existing personal-development signing does not establish public distribution readiness.

## Verification and working order

1. Publish and explain the roadmap, research open choices, show the existing design plus ten new options, and ask remaining questions.
2. Present the concise stack/features checklist and ask for final permission to build. Documentation is authorized now; app implementation, builds and installation wait for that explicit go-ahead.
3. After permission, coordinate the [future parallel lanes](BUILD_CHECKLIST.md#future-parallel-work-lanes), preserve the installed baseline and unpublished patch, and integrate measured slices with exact tests/device evidence.
4. Record source, automated tests, native acceptance, installation and owner acceptance separately; complete hardware/distribution gates before claiming a public release.

Use `python3 -B -m unittest discover -s Tests/Python -v`, `swift test`, and `bash scripts/verify_macos.sh`. Real payload assembly uses `scripts/build_complete.sh`; complete packaging requires exact-artifact native evidence via `scripts/package_complete.sh`. Never replace full payload hashes with size/mtime-only trust, weaken sandbox/TLS checks to make a test pass, or claim model-free CI proves physical microphone/speaker or screen permission behavior.

References: [startup measurements](startup-performance.md), [screen contract](screen-context-contract.md), [placement policy](roaming-policy.md), [complete assembly](self-contained-build-plan.md), [offline acceptance](offline-acceptance.md), [Splash guidance](https://github.com/incoai/splash/blob/f91c91e21dda483f8c59a248a444d0989a560d31/README.md), [M4 Pro MacBook Pro specifications](https://support.apple.com/en-us/121553).
