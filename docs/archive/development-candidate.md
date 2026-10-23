# Model-free macOS packaging validation

The model-free build is a native UI test build, **not the complete voice/research
app**. The normal macOS CI job still runs Python/sandbox tests, SwiftPM, native
XCTest, Release/development packaging, zero-warning checks and strict app-signature
verification. Only after those gates succeed does it validate and record the
exact-source packaging receipt. Test/build diagnostics and the printed receipt
remain available in the workflow logs.

CI no longer automatically uploads the model-free DMG, app or receipt as a
downloadable artifact. It does not launch the app or establish device acceptance.
The complete-release workflow and native offline acceptance gate remain closed
until their separate requirements are met. Removing automatic delivery does not
make the model-free build a complete app or waive any packaging test.

## Historical candidates and separate local tests

The earlier delivered `5753a4e` candidate remains historical model-free test
evidence; this change neither deletes that artifact nor upgrades its acceptance.
Its original artifact retention still applies. Current CI runs do not offer a
replacement download. These precautions apply only if testing a retained candidate
or a separately prepared local test build; a green CI run is not a request to
replace the working app.

1. Identify the candidate's exact source revision and successful native checks.
   Keep its `Dot.dmg` and `Dot-candidate-receipt.json` together. For a historical
   CI download, use its original workflow run and artifact rather than a newer
   run's logs or receipt.
2. Compare the receipt's commit with the exact source revision (and original
   workflow run for a historical artifact), and its DMG size/SHA-256 with the
   candidate file (`shasum -a 256 Dot.dmg`). Check
   `platform.executable_architectures` and `platform.minimum_version` against
   your Mac. This is a single-architecture build, not a universal installer;
   the receipt records the actual executable architecture and macOS build/SDK.
3. Keep the working Dot app. Do not replace it or drag this candidate onto its
   existing Applications entry. Quit the working app before testing. Mount the
   DMG and try its Dot app, or copy it into a separate test folder. Running from
   the mounted image is a smoke-test option, not a verified installation result.
4. **A separate filename does not isolate data.** Both builds use the same app
   identity (`app.dot.local`), preferences and `Application Support/Dot` data.
   To leave existing settings/history/notebooks untouched, test under a separate
   macOS user account. Do not run both copies together or delete existing data.
5. The app is ad-hoc signed and unnotarized. If macOS blocks it, stop and report
   the exact warning, macOS version, Mac chip and receipt commit. Do not disable
   Gatekeeper, remove quarantine or bypass a security warning to make it run.
6. If it opens, check the floating character, drag, menu-bar recall, Options,
   appearance/motion choices and keyboard access (Shift-F10 for Options; Escape
   to stop). Open and close Type, History, Sources, Web research and Mac actions
   panels. Expect the missing-recognizer/runtime notice and disabled sending.
   The UI-only smoke test does not need microphone or Screen Recording access.
   Quit the candidate when finished and reopen the original app.

Report the exact commit, macOS/chip, what you tried, what happened, and a screenshot
of any layout or error problem. Passing this check does not establish real voice,
model performance, screen-context accuracy, live research or complete installation.

## What the bundled code can and cannot exercise

- Native companion/menu/window layout; dragging and recall; eleven appearance
  choices and persisted voice-timer/motion preferences. Playback-aligned animation,
  acoustic quality and actual follow-up conversations still need the complete app.
- Typed editor and truthful readiness/status display. **No generated typed reply,
  microphone conversation or Kokoro speech:** the development target has no native
  Whisper framework and omits the offline neural runtimes and weights.
- Local history/notebook views and source-reading UI. Local text/PDF notebook
  reading is implemented without neural models; it writes local notebook data.
  The fixed-repository source viewer can request the exact published revision
  from GitHub over the network. Neither is a successful general research run.
- Explicit native app/URL and selected-folder text actions are implemented
  independently of neural readiness. They can change files/open apps. They are
  optional, outside the initial UI smoke test; use only disposable test documents.
- Web research UI is present, but the production app supplies no configured
  search provider and no verified Search payload. General web-source fetching
  requires the absent audited Splash Python runtime; answer synthesis requires
  the missing local Qwen stack. There is no automatic downloader or runtime fallback.

These statements follow `src/App.swift`, `src/OfflinePreparation.swift`,
`src/OfflinePayload.swift`, `src/TypedInteractionPanel.swift`, `src/ResearchPanel.swift`,
`src/SourceReference.swift`, `src/ActionPanel.swift` and `src/WebResearchPanel.swift`.

## What a complete candidate still requires

`scripts/build_complete.sh` requires three already verified local inputs:

- `DOT_RUNTIME_PAYLOAD`: the audited Splash runtime, isolated Python/native
  dependencies and licenses, English Whisper `base.en` data, and Kokoro voice
  model with British `bf_isabella` voice.
- `DOT_MODEL_PAYLOAD`: the exact target/draft/vision assets in
  `Resources/bundled-models.json`, currently **19,930,313,310 bytes** before runtime
  and app overhead. Do not silently substitute a model or change this inventory.
- `DOT_WHISPER_FRAMEWORK`: the verified native macOS framework. The complete build
  targets **arm64/macOS 26.4+**; development UI builds target macOS 15.0+.

Complete assembly still requires exact-app native relocation/offline/conversation/
cancellation acceptance and `scripts/package_complete.sh` before a complete test
DMG. General distribution additionally needs its signing/notarization and clean-Mac
acceptance. The separately audited Search interpreter/dependency closure, native
sandbox, source/license and retention evidence, production integration and real
provider acceptance are additional research requirements; see
[Search packaging gates](search-helper.md). None is certified by the model-free DMG.
