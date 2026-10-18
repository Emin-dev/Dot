# dot — floating local companion

> **AI/contributor handoff:** read [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md) for the current build,
> verified gates, what works/partial/missing and the next steps. Older planning documents are dated
> history and may be superseded.

See **[docs/ROADMAP.md](docs/ROADMAP.md)** for current plans, goals and the new
per-Dot GitHub log system; **[docs/DEV_TEAM_PROMPT.md](docs/DEV_TEAM_PROMPT.md)** carries the
binding rules R1–R16.

## Install Dot

[![Download Dot for macOS](https://img.shields.io/badge/Download-Dot%20for%20macOS-2ea44f?style=for-the-badge&logo=apple)](https://github.com/Emin-dev/Dot/releases/latest)

**Current release: [public-f6cc73d](https://github.com/Emin-dev/Dot/releases/tag/public-f6cc73d).**
**[Download `Dot.dmg`](https://github.com/Emin-dev/Dot/releases/latest/download/Dot.dmg)**, open it,
drag **Dot** into **Applications**, and launch it. The app verifies its signed runtime, then downloads
the exact 19.9 GB local model from Hugging Face on first launch, checking every file's SHA-256 against
the bundled manifest. Allow about 25 GB of free disk and a stable connection; progress appears in the
menu bar and context menu.

DMG one-line install (after a clean macOS install):

```bash
curl -L -o /tmp/Dot.dmg https://github.com/Emin-dev/Dot/releases/latest/download/Dot.dmg \
  && hdiutil attach /tmp/Dot.dmg -nobrowse -quiet \
  && cp -R "/Volumes/Dot/Dot.app" /Applications/ \
  && hdiutil detach "/Volumes/Dot" -quiet \
  && xattr -dr com.apple.quarantine /Applications/Dot.app \
  && open /Applications/Dot.app
```

A zip is also published (`Dot.zip`) with the equivalent `ditto` installer.

The public build is **Apple Development signed, not notarised yet**, so macOS may warn on first open;
the command clears the quarantine flag. The button resolves once the `Dot.zip` asset is uploaded to a
release (`GITHUB_TOKEN=… bash scripts/publish_public_release.sh` or upload it manually).

Developers with an existing complete payload can build from source:

```bash
git clone https://github.com/Emin-dev/Dot.git && cd Dot && bash scripts/install_local.sh
```

**[Product roadmap and build checklist](docs/BUILD_CHECKLIST.md)** — full stack, ranked workflows, configurable timing/activity and accepted design direction. **[View the final-lineup v3 concept board](docs/design/dot-face-directions-v3.png)** · **[interactive motion study](docs/design/dot-face-motion-directions.html)** ([download HTML](https://raw.githubusercontent.com/Emin-dev/Dot/main/docs/design/dot-face-motion-directions.html); save and open in a browser) · [prototype validation](docs/design/dot-face-motion-validation.md) · [artifact index](docs/design/README.md) · [plain-text checklist](docs/BUILD_CHECKLIST.txt). [Verified progress](docs/PROGRESS.md) separates source, tests, installation and unpublished work. [Current continuation handoff](docs/CONTINUATION.md) records active ownership, recovery and next steps, with meaningful checkpoints approximately every ten minutes during implementation.

**Checklist implementation is authorized in tested stages.** After design review, the user explicitly said “yes build app based on our checklist.” The listening/question-follow-up loop is the first milestone, alongside a separate reviewable native skin/settings batch; it is no longer the overall scope limit. Do not repeat settled start/theme questions. Keep the working app and fixed Splash/Qwen/British Kokoro baseline intact; installation remains a separate step.

**Native Settings will offer 11 skins: Original plus Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo and Nova. Original stays default until changed.** Veil replaces Fold at position 8 as a nearly invisible transparent bubble/lens. The v3 board, motion study and validation report are delivered; the v2 Fold board/prompt remain historical. The prototype covers 120 composed state/expression combinations per face, not 120 reviewed production animation clips or real speech synchronization. Initial native rendering exists in the candidate below; the 120-reviewed-recipe library per new skin, phoneme alignment and full performance/device acceptance remain open. Record and publish new decisions as discussed.

**Latest expression direction:** all faces stay smiling, warm and friendly, including focus, thinking and research; use open rounded eyes/highlights, relaxed arched brows and an upturned resting mouth, with friendly articulated speech and independent truthful task labels. The corrected warm-face/layout motion export is published with rerun author logic checks, but **no fresh browser review was available**. Earlier 736/390/320 px checks apply to the pre-correction version; the owner has accepted the corrected design and confirmed building, while fresh technical browser and candidate hardware acceptance remain separate.

**Merged milestone:** [PR #2](https://github.com/Emin-dev/Dot/pull/2) at [`6aa5b89`](https://github.com/Emin-dev/Dot/commit/6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc) adds configurable listening, the bounded final-question reply loop, compact diagnostics and eleven persisted native appearance choices. **129 Python / 175 SwiftPM / 277 native XCTest / 49 guards**, sandbox checks, Debug/Release/development packaging and complete offline assembly passed with zero warnings. PR #2 merged normally at [`f718e87`](https://github.com/Emin-dev/Dot/commit/f718e870cd14148c1b20c03c7adc822f9981bf31), while its exact tested candidate remains uninstalled, not notarized and not hardware-accepted; the installed `b26a145` app is unchanged. [Candidate receipt and native contact sheets](https://github.com/Emin-dev/Dot/blob/6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc/docs/verification/voice-and-native-skins.md). Five shared friendly recipes and amplitude-driven speaking are an initial implementation, not the 120-per-skin production library or phoneme alignment.

**Development workflow:** main is the single ongoing working/default branch. Parallel agents use file ownership or temporary detached checkouts; one integration owner reviews and publishes without force-push or discarding work. Continue the full checklist through testing and delivery before final hand-off, keeping conditional gates and remaining acceptance explicit.

The description below is the current installed baseline. The target adds proactive screen/file context, online research, native settings/options and staged Rust services; those capabilities are not installed by this documentation update.

A native macOS floating companion. Click to talk; click during an answer to interrupt and listen again. Drag to move without starting the microphone. Right-click for Pin, screen privacy, Clear conversation, or Quit. The menu-bar paw recalls Dot.

## Build status

The installed baseline implements a single floating dot with a small right-click menu. That installed build has no app settings, setup, folder-selection or chat windows, or persistent text label below the dot; the newer timer/appearance options are merged source, not installed behavior. Verification progress, issues and screen use have small indicators on the character; detailed errors remain in the menu and accessibility value. Shift-F10 and the accessibility Options action open the same menu; Escape stops the current action.

**The complete personal build was installed and opened on the owner’s Mac; a runtime-only public package with first-launch model download is prepared, but the signed/notarised release and uploaded `Dot.zip` asset remain gates.** The bundled voice dependency closure, local speech/model components, relocation and screen-aware reply path have passed native checks, and the owner reports voice working. The safe-placement repair passed 190 native XCTest checks, complete assembly and an installed real screen-map check; broader mixed-display behavior and a fresh owner smoke test remain open. Ordinary CI/development DMGs still omit the neural payload and cannot talk. See [the current contributor checklist](docs/PROGRESS.md) for tested behavior, uninstalled feature work and remaining release gates.

The current complete personal build contains Splash 1.3.1, English Whisper base.en, the Bionic-derived Kokoro voice, all runtime dependencies and the complete 19,930,313,310-byte Qwen3.8-27B Q4 / draft / vision model selection. Unified provisioning: the owner bundle remains complete and offline-capable; the public runtime-only download fetches the same manifest-verified 19,930,313,310-byte model files on first launch. At launch, Dot verifies the embedded runtime and (when present) the embedded models, with pause/retry in its context menu. A failed download is a visible error; no substitute model or external folder is ever accepted. Copying the complete app carries its immutable assets with it. Native relocation/component checks have passed; clean second-Mac installation and the full public-release acceptance matrix remain open.

## Installed interaction and privacy

- Splash is the only LLM runtime. The exact target is `mlx-community/Qwen3.8-27B-4bit`; this is a checkpoint publisher name, not use of the MLX inference engine. No automatic model or runtime substitution.
- Thinking remains on at low effort, with a 1,536-token budget. Reasoning is not spoken.
- Microphone capture starts only after an explicit click and OS microphone permission. Three seconds without detected speech activity ends capture. English transcription uses the bundled Whisper C library locally, with a one-minute recording bound.
- A new click cancels the old capture, generation and audio. Stale results cannot restart the microphone or replace the new turn.
- Screen context is captured for an explicit conversation just before its reply, and sparse local placement checks can analyze the screen while idle after macOS Screen Recording permission. Placement never requests permission and uses the same off switch. Its on/off preference persists. Images are bounded, used once, excluded from conversation history, and never uploaded to a remote model. A denied/unavailable capture is reported honestly; turn off Screen context to continue voice-only.
- The Bionic-derived Kokoro helper uses CPU inference and denies network access. No built-in voice fallback is selected silently.
- Random roaming is disabled. Conservative local placement protects other windows, text and visually occupied regions; missing/stale/uncertain screen analysis means staying still. Short clear escape paths pause for interaction, speech, pinning and Reduce Motion. Manual drag works without screen access. Reduce Transparency provides an opaque body.
- File, browser and autonomous computer actions are not implemented. Dot does not execute instructions from screen content.

Conversation state stays in memory and disappears on quit. No analytics or conversation upload. The public app's only provisioning network path is the manifest-verified model download from the two reviewed Hugging Face repositories. Its owned Splash endpoint is loopback-only; the voice helper denies network access. The [future research/context contract](docs/BUILD_CHECKLIST.md#screen-files-and-online-research) adds online retrieval and explicitly authorized use of relevant screen/file data in web requests while retaining local AI, speech and memory.

## Development and verification

The UI development target builds on macOS 15+. The complete Splash runtime requires macOS 26.4+. The requested product target is M4 Pro-class or newer with at least 36 GB RAM, with 48 GB recommended. The 36 GB target follows upstream Q4 guidance but has not passed Dot’s full workload acceptance. The personal test hardware is reported as M5 Pro/48 GB. See [hardware and release gaps](docs/PROGRESS.md#hardware-and-distribution-targets); other-Mac support is not yet certified.

- Open `Dot.xcodeproj`, choose shared `Dot` scheme, then Product → Test.
- `swift test` runs the portable pure-core suite. The Xcode target additionally runs mocked network and pipe tests.
- `python3 -B -m unittest discover -s Tests/Python -v` runs model-free protocol, assembly and supervisor fixtures.
- `bash scripts/verify_macos.sh` runs Python/sandbox tests, SwiftPM, Debug XCTest, Release and development packaging, then rejects warnings in all logs.
- `bash build.sh` creates `build/Dot.dmg`, an ad-hoc signed, unnotarized **development build without neural runtimes**.
- `DOT_WHISPER_FRAMEWORK=/verified/macos/whisper.framework bash scripts/verify_whisper_link.sh` compiles the real native recognizer branch without executing the app or models.
- `DOT_RUNTIME_PAYLOAD=/audited/payload DOT_MODEL_PAYLOAD=/verified/models DOT_WHISPER_ARCHIVE=/verified/whisper-v1.7.6-xcframework.zip bash scripts/build_complete.sh` requires all three local inputs and a complete runtime manifest/import probe. It verifies model hashes before and after copying, embeds the native recognizer, signs and stages `build-complete/Dot.app` for native acceptance. It does not produce a distributable installer yet. The recognizer framework is derived from the pinned archive by `scripts/verify_whisper_input.py`; a bare framework directory is deliberately rejected.
- After real native relocation/offline/conversation/cancellation tests, `DOT_OFFLINE_ACCEPTANCE=/verified/evidence/acceptance.json bash scripts/package_complete.sh` binds the test evidence to the exact app fingerprint, rechecks the relocated staging copy, and creates the unnotarized test DMG. See [acceptance record contract](docs/offline-acceptance.md).


Standard CI does not download models or establish real neural speech, microphone quality, screen permissions, interactive UI correctness or offline inference. Those are separate native device gates. See [self-contained build plan](docs/self-contained-build-plan.md), [voice bridge](docs/voice-bridge.md), [screen contract](docs/screen-context-contract.md), and [roaming policy](docs/roaming-policy.md).

This rebuild starts from `56041cf00d1d6b7c2f87590fdd1fbbbbb216e996`. Original Mac-only edits were not copied and their tests do not validate this branch. Removed generated binaries remain recoverable in the original history and preservation manifest. The reviewed rebuild is now merged into main, with the original history preserved.
