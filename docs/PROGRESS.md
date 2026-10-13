# Dot: implementation and next steps

Updated 2026-10-13 after the installed movement-repair check. This is a public contributor handoff, not a release certification. Start here before changing behavior; update the checklist with evidence when a task is completed.

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

## Requested interaction work, next

- [ ] Ship the reviewed compact-error prototype: short typed status, contextual retry, sanitized Copy details and a clear menu-bar Show Dot / Quit Dot menu. It is local and uninstalled; current main still has the older menu behavior. No scrollable error page or additional app window.
- [ ] Question-only hands-free replies: explicit model/app question intent, final successful generation and all question audio played, then up to six seconds to begin speaking. Once speech starts, keep three seconds of trailing silence. Ordinary question marks, quotes or rhetorical questions must not activate the microphone.
- [ ] Finish and execute regression tests for silence timeout, cancellation, permission denial/revocation, repeated drain callbacks, new turns and acoustic echo. The reviewed local policy/parser scaffold is inert: it validates one completed `ask_user` intent and revocable continuation authority, but has no Engine/STT/TTS integration or automatic microphone path. Its new native Swift tests have not run.
- [ ] More expressive but accessible pet behavior, after the above repairs. Preserve Reduce Motion, hover catchability, pin and explicit interruption.

## Performance research, after current repairs

- [ ] Measure full click-to-audible latency, recording contention, cold/warm engine reuse and per-stage timing; improve safe worker reuse and overlap where measurements justify it.
- [ ] Evaluate bounded app-lifetime warmup and cache reuse without bypassing content integrity or holding unbounded resources. Full verification remains mandatory for the current mutable bundle.
- [ ] Research Apple-native APIs/Core ML for suitable speech components, including Core ML Kokoro and Parakeet candidates. This is research only: do not change the current speech models/runtime or the required Splash-only Qwen engine without a reviewed, measured migration decision.

## Larger capabilities still missing

- [ ] Host-validated file/workspace access, coding/research tools, browser/app actions and computer control. Current Dot has no general action adapter or unrestricted shell execution.
- [ ] Version-matched read/search access to Dot’s own source for explaining and improving the installed version.
- [ ] Siri/AppIntents integration; it is not currently implemented.
- [ ] Previews/confirmation before important actions and undo where possible.
- [ ] Persistent local text conversation history with compact Read/Copy/Delete controls, as requested. Current history remains in memory only. Do not persist raw microphone audio or screenshots, and keep the interface tiny without an extra app window.
- [ ] Durable user-controlled personal memory beyond that text history, with explicit storage/deletion controls.
- [ ] Optional Rust backend migration under parity tests. Current backend orchestration is Swift plus isolated Python/native inference components; no Rust performance claim is justified yet.
- [ ] The specifically requested T3-Video-Wan2.2 5B video feature. Its Apple Silicon runtime and resource fit are not verified. Keep it separate from the working English-only voice stack; do not silently substitute its model or the selected Splash/Qwen engine.

## Hardware and distribution targets

- Requested target: native macOS, **M4 Pro-class or newer** Apple Silicon and **at least 36 GB RAM**. This is a target, not a verified support claim or a currently implemented hardware gate. It does not imply support for every base M4/M5 Mac.
- The selected Splash runtime requires macOS 26.4 or newer. Its published Q4 guidance is at least 36 GB, with 48 GB recommended. A 36 GB device has not passed this app's full workload/resource acceptance. M4 Pro commonly ships in 24/48 GB configurations, so the requested threshold normally means a 48 GB Pro configuration.
- The owner's reported test hardware is M5 Pro/48 GB; OS and actual app behavior were tested, but no blanket claim for all other Macs follows.
- Keep a complete all-in-one offline build. A future public small installer may automatically provision verified assets with visible progress if a single large download is impractical, as requested; no such public downloader is implemented today. Do not revive external folder/server setup.
- [ ] Clean supported second-Mac installation, relocation, offline voice/vision, denial/recovery, resources and mic/speaker quality acceptance.
- [ ] Public redistribution notices/licenses, appropriate distribution signing/notarization, and exact-artifact release checks. Existing personal-development signing does not establish public distribution readiness.

## Verification and working order

1. Keep installed `b26a145` available for the owner's smoke test; resolve any concrete regression before replacing it. Reconcile the existing unpublished compact-UI/question-policy work with its maintainer before starting a competing rewrite.
2. Finish compact errors and explicit-intent question followup; test actual audio completion and six-second/three-second behavior before enabling it.
3. Implement bounded action capabilities with explicit host validation and permission-aware user intent.
4. Validate hardware/distribution targets and produce a clearly labeled downloadable artifact.

Use `python3 -B -m unittest discover -s Tests/Python -v`, `swift test`, and `bash scripts/verify_macos.sh`. Real payload assembly uses `scripts/build_complete.sh`; complete packaging requires exact-artifact native evidence via `scripts/package_complete.sh`. Never replace full payload hashes with size/mtime-only trust, weaken sandbox/TLS checks to make a test pass, or claim model-free CI proves physical microphone/speaker or screen permission behavior.

References: [startup measurements](startup-performance.md), [screen contract](screen-context-contract.md), [placement policy](roaming-policy.md), [complete assembly](self-contained-build-plan.md), [offline acceptance](offline-acceptance.md), [Splash guidance](https://github.com/incoai/splash/blob/f91c91e21dda483f8c59a248a444d0989a560d31/README.md), [M4 Pro MacBook Pro specifications](https://support.apple.com/en-us/121553).
