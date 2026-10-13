# Dot — floating local companion

A native macOS floating companion. Click to talk; click during an answer to interrupt and listen again. Drag to move without starting the microphone. Right-click for Pin, screen privacy, Clear conversation, or Quit. The menu-bar paw recalls Dot.

## Build status

The merged source implements a single floating dot with a small right-click menu. There are no app settings, setup, folder-selection or chat windows, or persistent text label below the dot. Verification progress, issues and screen use have small indicators on the character; detailed errors remain in the menu and accessibility value. Shift-F10 and the accessibility Options action open the same menu; Escape stops the current action.

**A complete personal test app is installed and working on the owner’s Mac; a generally validated public installer is not available yet.** The bundled voice dependency closure, local speech/model components, relocation and screen-aware reply path have passed native checks, and the owner reports voice working. Ordinary CI/development DMGs still omit the neural payload and cannot talk. See [the current contributor checklist](docs/PROGRESS.md) for tested behavior, uninstalled feature work and remaining release gates.

The shipped product must contain Splash 1.3.1, English Whisper base.en, the Bionic-derived Kokoro voice, all runtime dependencies and the complete 19,930,313,310-byte Qwen3.8-27B Q4 / draft / vision model selection. There is no first-launch downloader, external folder picker, borrowed Python installation or server discovery. At launch, Dot verifies the embedded payload, with pause/retry in its context menu. Missing or damaged files remain a visible error; the app never downloads a repair. Copying the complete app carries its immutable assets with it. Native relocation/component checks have passed; clean second-Mac installation and the full public-release acceptance matrix remain open.

## Interaction and privacy

- Splash is the only LLM runtime. The exact target is `mlx-community/Qwen3.8-27B-4bit`; this is a checkpoint publisher name, not use of the MLX inference engine. No automatic model or runtime substitution.
- Thinking remains on at low effort, with a 1,536-token budget. Reasoning is not spoken.
- Microphone capture starts only after an explicit click and OS microphone permission. Three seconds without detected speech activity ends capture. English transcription uses the bundled Whisper C library locally, with a one-minute recording bound.
- A new click cancels the old capture, generation and audio. Stale results cannot restart the microphone or replace the new turn.
- Screen context is captured only for an explicit conversation, just before its reply, after macOS Screen Recording permission. Its on/off preference persists. Images are bounded, used once, excluded from conversation history, and never uploaded to a remote model. A denied/unavailable capture is reported honestly; turn off Screen context to continue voice-only.
- The Bionic-derived Kokoro helper uses CPU inference and denies network access. No built-in voice fallback is selected silently.
- Varied within-display roaming pauses for interaction, speech, pressed mouse buttons, pinning and Reduce Motion. Reduce Transparency provides an opaque body.
- File, browser and autonomous computer actions are not implemented. Dot does not execute instructions from screen content.

Conversation state stays in memory and disappears on quit. No analytics or conversation upload. The app has no model provisioning network path. Its owned Splash endpoint is loopback-only; the voice helper denies network access.

## Development and verification

The UI development target builds on macOS 15+. The complete Splash runtime requires macOS 26.4+. The requested product target is M4 Pro-class or newer with at least 36 GB RAM, with 48 GB recommended. The 36 GB target follows upstream Q4 guidance but has not passed Dot’s full workload acceptance. The personal test hardware is reported as M5 Pro/48 GB. See [hardware and release gaps](docs/PROGRESS.md#hardware-and-distribution-targets); other-Mac support is not yet certified.

- Open `Dot.xcodeproj`, choose shared `Dot` scheme, then Product → Test.
- `swift test` runs the portable pure-core suite. The Xcode target additionally runs mocked network and pipe tests.
- `python3 -B -m unittest discover -s Tests/Python -v` runs model-free protocol, assembly and supervisor fixtures.
- `bash scripts/verify_macos.sh` runs Python/sandbox tests, SwiftPM, Debug XCTest, Release and development packaging, then rejects warnings in all logs.
- `bash build.sh` creates `build/Dot.dmg`, an ad-hoc signed, unnotarized **development build without neural runtimes**.
- `DOT_WHISPER_FRAMEWORK=/verified/macos/whisper.framework bash scripts/verify_whisper_link.sh` compiles the real native recognizer branch without executing the app or models.
- `DOT_RUNTIME_PAYLOAD=/audited/payload DOT_MODEL_PAYLOAD=/verified/models DOT_WHISPER_FRAMEWORK=/verified/macos/whisper.framework bash scripts/build_complete.sh` requires all three local inputs and a complete runtime manifest/import probe. It verifies model hashes before and after copying, embeds the native recognizer, signs and stages `build-complete/Dot.app` for native acceptance. It does not produce a distributable installer yet.
- After real native relocation/offline/conversation/cancellation tests, `DOT_OFFLINE_ACCEPTANCE=/verified/evidence/acceptance.json bash scripts/package_complete.sh` binds the test evidence to the exact app fingerprint, rechecks the relocated staging copy, and creates the unnotarized test DMG. See [acceptance record contract](docs/offline-acceptance.md).


Standard CI does not download models or establish real neural speech, microphone quality, screen permissions, interactive UI correctness or offline inference. Those are separate native device gates. See [self-contained build plan](docs/self-contained-build-plan.md), [voice bridge](docs/voice-bridge.md), [screen contract](docs/screen-context-contract.md), and [roaming policy](docs/roaming-policy.md).

This rebuild starts from `56041cf00d1d6b7c2f87590fdd1fbbbbb216e996`. Original Mac-only edits were not copied and their tests do not validate this branch. Removed generated binaries remain recoverable in the original history and preservation manifest. The reviewed rebuild is now merged into main, with the original history preserved.
