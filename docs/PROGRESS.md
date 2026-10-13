# Dot: implementation and next steps

Updated 2026-10-13. This is a public contributor handoff, not a release certification. Start here before changing behavior; update the checklist with evidence when a task is completed.

## Current source and personal test app

- Default and only remote branch: `main`. The reviewed development history is merged and preserved. Do not recreate a parallel release branch just to update this checklist.
- Current tested personal-app source: `ade313c38503d84fc7e201be2110a4a2aaa1cefb`, now in main. Later main changes before the next feature patch are documentation only.
- A complete, locally signed personal app is installed on the owner's Mac. It contains the model/runtime assets and does not need an external voice folder or model server. The owner reports voice working. Actual screen-aware turns now reach generation and playback after a code-identity/OS-permission repair.
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
- [x] Latest main CI before the next feature patch: 168 XCTest, 95 SwiftPM, 129 Python and 40 static checks, with no build/package warnings. These are model-free CI checks, separate from device acceptance.

## Current repair, not installed yet

- [ ] Replace random bounds/cursor-only movement. Conversation vision did not control placement; the installed app can still wander over useful content.
- [ ] Review/test the local placement candidate: protect whole other-app windows, text and visually occupied regions; require fresh permitted local analysis and clear full-panel routes; stay still on uncertainty; preserve manual drag.
- [ ] Validate image orientation, mixed-monitor coordinates, permission-off behavior, stale-result cancellation and runtime cost natively. Never describe a single-frame approximation as perfect semantic avoidance.
- [ ] Update privacy wording for sparse local placement analysis. It must use the existing opt-out, discard pixels, and never prompt for permission from an idle scan.

## Requested interaction work, next

- [ ] Compact typed errors and one clear recovery action, with optional copied diagnostic detail. No scrollable error page or additional app window.
- [ ] Question-only hands-free replies: explicit model/app question intent, final successful generation and all question audio played, then up to six seconds to begin speaking. Once speech starts, keep three seconds of trailing silence. Ordinary question marks, quotes or rhetorical questions must not activate the microphone.
- [ ] Regression tests for silence timeout, cancellation, permission denial/revocation, repeated drain callbacks, new turns and acoustic echo. The current local followup state-machine scaffold is not production microphone wiring.
- [ ] More expressive but accessible pet behavior, after the above repairs. Preserve Reduce Motion, hover catchability, pin and explicit interruption.

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

- Requested target: native macOS, **M4 Pro-class or newer** Apple Silicon and **at least 32 GB RAM**. This is a target, not a verified support claim or a currently implemented hardware gate. It does not imply support for every base M4/M5 Mac.
- The selected Splash runtime requires macOS 26.4 or newer. Its published Q4 guidance is at least 36 GB, with 48 GB recommended. A 32 GB device has not passed this app's full workload/resource acceptance. M4 Pro commonly ships in 24/48 GB configurations, so the requested threshold normally means a 48 GB Pro configuration.
- The owner's reported test hardware is M5 Pro/48 GB; OS and actual app behavior were tested, but no blanket claim for all other Macs follows.
- Keep a complete all-in-one offline build. A future public small installer may automatically provision verified assets with visible progress if a single large download is impractical, as requested; no such public downloader is implemented today. Do not revive external folder/server setup.
- [ ] Clean supported second-Mac installation, relocation, offline voice/vision, denial/recovery, resources and mic/speaker quality acceptance.
- [ ] Public redistribution notices/licenses, appropriate distribution signing/notarization, and exact-artifact release checks. Existing personal-development signing does not establish public distribution readiness.

## Verification and working order

1. Finish and independently review safe placement, then run the full native checks and user test without losing the current working personal app.
2. Finish compact errors and explicit-intent question followup; test actual audio completion and six-second/three-second behavior before enabling it.
3. Implement bounded action capabilities with explicit host validation and permission-aware user intent.
4. Validate hardware/distribution targets and produce a clearly labeled downloadable artifact.

Use `python3 -B -m unittest discover -s Tests/Python -v`, `swift test`, and `bash scripts/verify_macos.sh`. Real payload assembly uses `scripts/build_complete.sh`; complete packaging requires exact-artifact native evidence via `scripts/package_complete.sh`. Never replace full payload hashes with size/mtime-only trust, weaken sandbox/TLS checks to make a test pass, or claim model-free CI proves physical microphone/speaker or screen permission behavior.

References: [startup measurements](startup-performance.md), [screen contract](screen-context-contract.md), [placement policy](roaming-policy.md), [complete assembly](self-contained-build-plan.md), [offline acceptance](offline-acceptance.md), [Splash guidance](https://github.com/incoai/splash/blob/f91c91e21dda483f8c59a248a444d0989a560d31/README.md), [M4 Pro MacBook Pro specifications](https://support.apple.com/en-us/121553).
