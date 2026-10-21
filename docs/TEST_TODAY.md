# Dot — test everything today

For Emin on a MacBook at or above the minimum: **Apple Silicon M5 Pro class,
48 GB Unified Memory, macOS 27+**. Dot refuses to start below that, on purpose;
there is no smaller model and no override.

Allow about 45–75 minutes: most of it is the one-time 22.4 GB model download.

## 1. Download and verify

1. Open <https://github.com/Emin-dev/Dot/releases/latest>.
2. Download `Dot.dmg` and `Dot.dmg.sha256` into `~/Downloads`.
3. In Terminal:

   ```bash
   cd ~/Downloads
   shasum -a 256 -c Dot.dmg.sha256
   ```

   **Pass:** prints `Dot.dmg: OK`. If it prints `FAILED`, delete the file and
   download again; do not install it.

## 2. Install and first open

1. Open `Dot.dmg`, drag **Dot** to **Applications**, and eject the DMG.
2. The DMG is ad-hoc signed and **not notarised**, so macOS will warn on the
   first launch. Allow it once, in this order of preference:
   - Finder: right-click (or Control-click) **Dot** → **Open** → **Open**; or
   - **System Settings → Privacy & Security → Open Anyway**; or
   - Terminal: `xattr -dr com.apple.quarantine /Applications/Dot.app`
3. Launch **Dot**.

   **Pass:** Dot appears on screen and does not quit. A blocking "Hardware Does
   Not Meet Dot's Minimum" panel means this Mac is below the minimum — record
   the exact text and stop.

No join step is needed for this DMG. The 22+ GB all-in-one split installer is
not published yet; `join-dot-dmg.command` is only for those parts when they
exist.

## 3. Model download (one time, online)

1. Dot verifies `bundled-models.json`, then downloads the exact Qwen3.8 27B Q4
   target, DFlash2 draft and the safety aux model from the pinned
   `model-parts-v1` release (Hugging Face is the hash-checked fallback).
2. Size: **22.4 GB**. Free disk needed: **at least 35 GB**.
3. Time: roughly **30 minutes at 100 Mbps**, **6 minutes at 500 Mbps**. The
   progress ring and detail text advance; the download resumes after a network
   drop or relaunch.

   **Pass:** the panel reaches the ready state with no SHA-256 error. Open
   `~/Library/Application Support/Dot/Logs/dot_chat_log.txt` and confirm it
   records model verification success. A "Not enough free disk space" message
   is a real failure — free space and retry from the menu.

## 4. Voice conversation

1. Click the dot once (do not drag), wait for the listening cue, and say:
   "Hello Dot, tell me in one sentence what you are."
2. Let the answer finish. Click the dot again while it is speaking.

   **Pass:** your speech is transcribed locally, Dot answers aloud in the warm
   British voice, and clicking during the answer interrupts and listens again.
   If macOS asks for Microphone permission, grant it to Dot.

## 5. Offline test (Wi-Fi physically off)

1. Turn Wi-Fi off (Control Centre → Wi-Fi off; also unplug Ethernet).
2. Quit Dot, relaunch it, and repeat one voice question.

   **Pass:** Dot starts, loads the model from disk, transcribes, answers aloud
   and moves normally with no network. Nothing says it is waiting for a
   connection. Logs may queue uploads; that is expected and is retried later.
3. Turn Wi-Fi back on after the test.

## 6. Screen context

1. Right-click Dot and make sure **Screen awareness** is on.
2. When macOS asks, allow **System Settings → Privacy & Security → Screen
   Recording** for Dot, then relaunch Dot if macOS asks.
3. Put a distinctive window on screen (for example this checkout in an editor),
   click Dot and ask: "What is on my screen right now?"

   **Pass:** Dot describes the visible content for that one turn and says
   plainly if it cannot see or permission is missing. Turn **Screen awareness**
   off and ask again: it must say screen context is off, not invent a view.

## 7. Safety override ("force it")

Use a disposable folder only.

1. In Terminal: `mkdir -p ~/Desktop/DotSafetyTest && touch ~/Desktop/DotSafetyTest/keep.txt`
2. Ask Dot to run: `rm -rf ~/Desktop/DotSafetyTest`
3. Let the local safety approver refuse it **three separate times** (ask again
   each time).
4. After the third refusal, say **"force it"**, then ask for the same command
   and approve once more.
5. Optional: move the folder and retry — the armed override must not apply to a
   different action, must expire after 120 seconds, and is one-shot.

   **Pass:** the first three attempts are never executed; the exact refusal,
   "force it" prompt and approval card are visible; only the exact action runs
   after the override. Anything else — an early execution, a silent run, or a
   permanent override — is a failure.

## 8. Logs and where to send them

- Main log: `~/Library/Application Support/Dot/Logs/dot_chat_log.txt`
- Whole folder: `~/Library/Application Support/Dot/Logs/`
- Uploads go to the `dot-logs` branch of `Emin-dev/Dot` under
  `dot/<install-id>/<launch-timestamp-UTC>/` when a log-upload token is in
  Keychain. Without a token they stay queued locally; that is not a failure.

  **Pass:** the log contains the conversation text and app/system events, and
  no keys, tokens, passwords or images.

## 9. What "done" looks like

All of these are true:

- [ ] `Dot.dmg: OK` from `shasum` (step 1)
- [ ] Dot installed from the DMG and launched after the first-open warning
- [ ] 22.4 GB model downloaded and verified once
- [ ] Voice question answered aloud; interruption works
- [ ] Wi-Fi off: relaunch, voice question and answer still work
- [ ] Screen context describes one turn; off state is honest
- [ ] Safety refusal three times, then one-shot `force it` on the scratch folder
- [ ] Logs contain text only

Remaining owner-only step: Developer ID signing and notarisation. That needs a
paid Apple Developer account; it is not required for this test and is tracked in
[QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md).
