# Dot — floating local companion

A native macOS companion with a transparent floating glass-style character, a small speech bubble, and no conventional main window. Click to speak; click during an answer to interrupt and listen again. Right-click for Pin, Connection, Clear conversation, or Quit. The menu-bar paw brings Dot back into view.

## Current development status

The requested final product is fully self-contained: bundled Splash/Qwen Q4, vision, local recognition and Kokoro voice, without external setup or discovery. The current test build is a foundation and **does not yet meet that requirement**. See [the self-contained build gates](docs/self-contained-build-plan.md), [screen-context contract](docs/screen-context-contract.md), and [roaming policy](docs/roaming-policy.md). No full-bundle completion or measured speed improvement is claimed.

## This review branch

This rebuild begins at `56041cf00d1d6b7c2f87590fdd1fbbbbb216e996`. It was implemented separately on a cloud computer. Uncommitted Mac changes were not recovered or copied, and their tests do not validate this branch. Old binaries at the base revision are **not** builds of this source.

- Splash is the only inference engine. No llama.cpp or MLX-engine fallback; no engine downloads, launches, or borrowed-process shutdown.
- English speech recognition must support on-device operation. Audio is never intentionally submitted to a network recognizer; unavailable support fails closed.
- Microphone capture begins only after a click. A full three seconds without speech activity ends capture; resumed speech resets that interval. A short final-transcription drain follows.
- Every new click invalidates earlier microphone, stream and speech callbacks. Replies never automatically restart the microphone.
- Thinking is on by default with low effort and a bounded 1,536-token generation budget. Reasoning is not spoken.
- Reduce Motion freezes autonomous roaming/bobbing; Reduce Transparency uses an opaque body/bubble. Varied within-display roaming pauses for hovering, voice activity, menus, popovers and pressed mouse buttons. Pin persists between launches.
- **Bionic/Kokoro is the default voice through a bundled warm CPU helper. Select your trusted existing Bionic voice-engine folder in Connection.** The environment/model files are not bundled yet; missing setup fails closed. Built-in English is an explicit interim option, never a silent fallback. See [the bridge contract](docs/voice-bridge.md).
- File actions, browser control and autonomous computer actions are not implemented. This slice is a conversation companion.

## Splash connection

Run an already-installed, offline-configured Splash server separately. Right-click Dot → Connection and enter its loopback address (released default `http://127.0.0.1:8000`) and its **exact** `/status.instance.model` value. Alternatively set `DOT_SPLASH_URL` and `DOT_SPLASH_MODEL` before direct launch. Settings saved through Connection take priority.

The tested protocol fixture follows [Splash 1.3.1's source](https://github.com/incoai/splash/tree/f91c91e21dda483f8c59a248a444d0989a560d31). Dot requires `Server: Splash`, schema 6, ready state, an instance ID/PID, loopback binding, matching port and exact model ID before each turn. It refuses redirects. These are self-reported consistency checks, **not cryptographic attestation** and not proof of a binary version. A generic Bionic/OpenAI-compatible proxy will be rejected unless it genuinely exposes this direct contract.

A checkpoint whose ID starts `mlx-community/` can still be served by Splash; a weight publisher name does not choose the runtime. Dot never substitutes a model automatically.

## Build and test

Requires a Mac with Xcode and macOS 15+ to compile the UI. Splash hardware/OS requirements are separate from the companion shell and depend on the installed Splash release.

- Open `Dot.xcodeproj`, choose shared `Dot` scheme, then Product → Test.
- `python3 -B -m unittest discover -s Tests/Python -v` checks the helper protocol and mocked warm/cancellation lifecycle without neural models.
- `swift test` runs the deterministic portable core suite.
- `xcodebuild -project Dot.xcodeproj -scheme Dot -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test` builds the app and runs the actual `DotTests` XCTest target.
- `bash build.sh` creates `build/Dot.dmg`, an **ad-hoc signed, unnotarized test build**. It does not launch the app, download models, or record audio.

CI uses a standard public-repository macOS runner, a ten-minute job limit, read-only token permissions and no model downloads. Unit tests do not establish microphone quality, audible output, real Splash inference, accessibility behavior or interactive UI correctness. Those remain device tests. No local cloud-Linux execution is presented as an Xcode result.

## Architecture

`App.swift`: floating panel and motion policy. `ChatView.swift`: character, UI and turn coordinator. `Speech.swift`: local STT and labelled interim TTS. `BionicVoice.swift`: owned offline helper and ordered cancellable audio. `Engine.swift`: direct Splash transport. `InteractionCore.swift`: pure endpoint, identity, silence, generation and stream/chunk rules. `Tests/DotCoreTests`: real regression tests shared by SwiftPM and Xcode.

Conversation state stays in memory and disappears on quit. No analytics or conversation upload. No persistent broad filesystem or app-control access.
