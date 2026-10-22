curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash

# Dot — test everything today

For Emin on a MacBook at or above the minimum: **Apple Silicon M5 Pro class,
48 GB Unified Memory, macOS 27+**. Dot refuses to start below that, on purpose;
there is no smaller model and no override.

Allow about 45–75 minutes: most of it is the one-time 22.4 GB model download.

## 1. Install (one Terminal line)

Copy this exact line into Terminal and press Return:

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash
```

The line is plain ASCII with no smart quotes. If Terminal asks to confirm pasting,
choose **Paste Anyway** (or type the line); if macOS blocks the app after that, the
installer prints the exact macOS/Gatekeeper text instead of hiding it.

The script downloads `Dot.dmg` (and every part when the release uses split
parts) with curl, which adds no `com.apple.quarantine`; verifies every SHA-256;
mounts the DMG; copies `Dot.app` to **`~/Applications`** (never `/Applications`);
clears quarantine from Dot's own staged bundle only; verifies the App Sandbox
entitlements and signature; detaches the DMG; and opens Dot. It prints
`PASS:`/`FAIL:` lines, is idempotent and never uses sudo. It creates
`~/Applications` only when it is missing.

**Pass:** the script prints `PASS: Dot is installed at ~/Applications/Dot.app`
and Dot appears. If it prints `FAIL:`, send that line back; do not continue. On
a refusal it also prints the exact macOS/Gatekeeper text, so do not change any
System Setting.

### If macOS still blocks the first open

Do not change any System Setting. The installer already removes quarantine from
Dot's own staged bundle and verifies the sandbox entitlements and signature. If
macOS still refuses, the installer prints the exact `open`/Gatekeeper text; send
that `FAIL:` block back. A no-warning double-click for every Mac still needs
Developer ID signing plus notarisation, which is owner-only.

### Owner-only fallback: build and sign on this Mac

If the public download is blocked by policy, run from a checkout:

```bash
bash scripts/build-and-sign-on-mac.sh
```

It builds Dot locally with Xcode/SwiftPM and the Rust runtime, signs with the
first `Apple Development` identity from
`security find-identity -v -p codesigning` (ad-hoc fallback when none exists),
installs to `~/Applications` and opens Dot. This works because an Apple
Development signature is trusted on the Mac that owns the certificate; it is
not a public release.

**Plainly:** a no-warning double-click for every Mac needs **Developer ID
signing plus notarisation**. That needs Emin's paid Apple Developer account and
is owner-only, not available today.

## 2. Download and verify manually (optional)

1. Open <https://github.com/Emin-dev/Dot/releases/latest>.
2. Download `Dot.dmg` and `Dot.dmg.sha256` into `~/Downloads`.
3. In Terminal:

   ```bash
   cd ~/Downloads
   shasum -a 256 -c Dot.dmg.sha256
   ```

   **Pass:** prints `Dot.dmg: OK`. If it prints `FAILED`, delete the file and
   download again; do not install it.

## 3. Model download (one time, online)

1. Dot verifies `bundled-models.json`, then downloads the exact Qwen3.8 27B Q4
   target, DFlash2 draft and the safety aux model from the pinned
   `model-parts-v1` release (Hugging Face is the hash-checked fallback).
2. Size: **22.4 GB**. Free disk needed: **at least 35 GB**.
3. Time: roughly **30 minutes at 100 Mbps**, **6 minutes at 500 Mbps**. The
   progress ring and detail text advance; the download resumes after a network
   drop or relaunch.

   **Pass:** the panel reaches the ready state with no SHA-256 error. Open
   `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/dot_chat_log.txt` and confirm it
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
2. In Dot's menu open **Tools & History → Mac actions & receipts…** and choose
   `~/Desktop/DotSafetyTest` as the folder. That is the user-selected folder the
   sandbox allows Dot to act in; Dot cannot touch the rest of your home.
3. Ask Dot to run: `rm -rf ~/Desktop/DotSafetyTest`
4. Let the local safety approver refuse it **three separate times** (ask again
   each time).
5. After the third refusal, say **"force it"**, then ask for the same command
   and approve once more.
6. Optional: move the folder and retry — the armed override must not apply to a
   different action, must expire after 120 seconds, and is one-shot.

   **Pass:** the first three attempts are never executed; the exact refusal and
   "force it" prompt are visible; only the exact action runs after the override.
   Anything else — an early execution, a silent run, or a permanent override —
   is a failure.

## 8. Logs and where to send them

- Main log:
  `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/dot_chat_log.txt`
- Whole folder:
  `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/`
- Uploads go to the `dot-logs` branch of `Emin-dev/Dot` under
  `dot/<install-id>/<launch-timestamp-UTC>/` when a log-upload token is in
  Keychain. Without a token they stay queued locally; that is not a failure.

  **Pass:** the log contains the conversation text and app/system events, and
  no keys, tokens, passwords or images.

## 9. What "done" looks like

All of these are true:

- [ ] the one-line installer printed `PASS: Dot is installed`
- [ ] `Dot.dmg: OK` from `shasum` when checking manually (step 2)
- [ ] Dot launched after the first-open warning
- [ ] 22.4 GB model downloaded and verified once
- [ ] Voice question answered aloud; interruption works
- [ ] Wi-Fi off: relaunch, voice question and answer still work
- [ ] Screen context describes one turn; off state is honest
- [ ] Safety refusal three times, then one-shot `force it` on the scratch folder
- [ ] Logs contain text only

## 10. Remove Dot completely

When testing is finished, remove Dot with the same release-URL style:

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash
```

The in-app menu also has **Remove Dot completely…** (Options / right-click menu);
it opens Terminal for the same removal because a sandboxed app cannot delete its
own bundle or container.

**Pass:** it prints `PASS: your Mac is back to how it was`. It quits Dot and
removes the app, `~/Library/Containers/app.dot.local/`, group containers,
caches, saved state, HTTP/WebKit stores, preferences, the 22.4 GB model, the
legacy `Application Support/Dot` folder, LaunchServices registration and resets
Dot's microphone/screen-recording approvals with `tccutil reset All
app.dot.local`. It removes `~/Applications` only when the installer created it
and it is empty. If anything remains it prints a precise `FAIL:` line instead.

Remaining owner-only step: Developer ID signing and notarisation. That needs a
paid Apple Developer account; it is not required for this test and is tracked in
[QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md).
