# Dot — floating local companion

A native macOS floating companion. Click to talk; click during an answer to interrupt and listen again. Right-click for Pin, screen privacy, Clear conversation, or Quit. The menu-bar paw recalls Dot.

## Build status

The review branch contains the app-owned runtime integration and automatic first-launch model download. **The complete installer is not yet validated or available:** the redistributable voice dependency lock, offline import probe, real native-framework build and end-to-end device checks remain gates. A development DMG lacks these runtimes and clearly reports that limitation. It must not be presented as a working voice replacement.

The intended complete installer includes Splash 1.3.1, English Whisper base.en recognition, and the Bionic-derived Kokoro voice with their runtimes and licenses. On first launch it downloads 19,930,313,310 bytes of pinned Qwen3.8-27B Q4 / draft model data with progress, Pause/Resume, size/SHA256 verification and remaining-space checks. No existing Python installation, voice folder or server is adopted. Once setup succeeds, conversation runs locally without internet. An app-only copy does not carry models stored in Application Support; a portable complete build can include the verified models with `DOT_MODEL_PAYLOAD`. In-app export is still pending.

## Interaction and privacy

- Splash is the only LLM runtime. The exact target is `mlx-community/Qwen3.8-27B-4bit`; this is a checkpoint publisher name, not use of the MLX inference engine. No automatic model or runtime substitution.
- Thinking remains on at low effort, with a 1,536-token budget. Reasoning is not spoken.
- Microphone capture starts only after an explicit click and OS microphone permission. Three seconds without detected speech activity ends capture. English transcription uses the bundled Whisper C library locally, with a one-minute recording bound.
- A new click cancels the old capture, generation and audio. Stale results cannot restart the microphone or replace the new turn.
- Screen context is captured only for an explicit conversation, just before its reply, after macOS Screen Recording permission. Its on/off preference persists. Images are bounded, used once, excluded from conversation history, and never uploaded to a remote model. A denied/unavailable capture is reported honestly; turn off Screen context to continue voice-only.
- The Bionic-derived Kokoro helper uses CPU inference and denies network access. No built-in voice fallback is selected silently.
- Varied within-display roaming pauses for interaction, speech, pressed mouse buttons, pinning and Reduce Motion. Reduce Transparency provides an opaque body/bubble.
- File, browser and autonomous computer actions are not implemented. Dot does not execute instructions from screen content.

Conversation state stays in memory and disappears on quit. No analytics or conversation upload. Download traffic contains public asset requests, not conversation data.

## Development and verification

The UI development target builds on macOS 15+. The complete Splash installer targets Apple Silicon M3 or newer and macOS 26.4+, with enough RAM for the selected model. Device performance and voice quality require measurement.

- Open `Dot.xcodeproj`, choose shared `Dot` scheme, then Product → Test.
- `swift test` runs the portable pure-core suite. The Xcode target additionally runs mocked network and pipe tests.
- `python3 -B -m unittest discover -s Tests/Python -v` runs model-free protocol, assembly and supervisor fixtures.
- `bash scripts/verify_macos.sh` runs Python/sandbox tests, SwiftPM, Debug XCTest, Release and development packaging, then rejects warnings in all logs.
- `bash build.sh` creates `build/Dot.dmg`, an ad-hoc signed, unnotarized **development build without neural runtimes**.
- `DOT_WHISPER_FRAMEWORK=/verified/macos/whisper.framework bash scripts/verify_whisper_link.sh` compiles the real native recognizer branch without executing the app or models.
- `DOT_RUNTIME_PAYLOAD=/audited/payload DOT_WHISPER_FRAMEWORK=/verified/macos/whisper.framework bash scripts/build_complete.sh` fails closed unless the local payload audit, exact neural pins, dependency-lock status and offline import probe pass. It embeds the real framework and produces `build-complete/Dot.dmg`. Optionally set `DOT_MODEL_PAYLOAD` to the verified staged model root to embed data as `OfflineModels`, producing a portable app rather than a first-launch download installer. It verifies hashes before and after copying. No download or installation is performed by that build script.

Standard CI does not download models or establish real neural speech, microphone quality, screen permissions, interactive UI correctness or offline inference. Those are separate native device gates. See [self-contained build plan](docs/self-contained-build-plan.md), [voice bridge](docs/voice-bridge.md), [screen contract](docs/screen-context-contract.md), and [roaming policy](docs/roaming-policy.md).

This rebuild starts from `56041cf00d1d6b7c2f87590fdd1fbbbbb216e996`. Original Mac-only edits were not copied and their tests do not validate this branch. Removed generated binaries remain recoverable in the original history and preservation manifest. Main is unchanged.
