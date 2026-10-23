curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash

# Test Dot on your Mac

One pass over every feature. Tick each box when its **Pass** line is true. If a box fails, copy the
last lines of the log (section 14) and note the box number.

Needs: Apple Silicon M5 Pro class or newer, 48 GB, macOS 27+, about 35 GB free disk. Below that
Dot shows one clear message and stops, on purpose. Allow about an hour; most of it is the one-time
22.4 GB model download.

## 1. Install

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash
```

- [ ] 1.1 Paste the line into Terminal. **Pass:** it ends with
  `PASS: Dot is installed at ~/Applications/Dot.app` and the dot appears on screen.
- [ ] 1.2 Run the same line again. **Pass:** it passes again and nothing is duplicated.
- [ ] 1.3 Optional manual check: download `Dot.dmg` and `Dot.dmg.sha256` from the latest release
  into `~/Downloads`, then run `cd ~/Downloads && shasum -a 256 -c Dot.dmg.sha256`.
  **Pass:** `Dot.dmg: OK`.

If it prints `FAIL:`, stop and send that line. Do not change any System Setting: the release is not
notarised yet. The installer downloads with curl (no quarantine flag), clears quarantine only on
Dot's own app, and prints Gatekeeper's exact text if macOS still refuses.

## 2. Model download (one time)

- [ ] 2.1 Watch the first launch. **Pass:** a progress ring with stage text (verify, download,
  load) moves forward; no SHA-256 error.
- [ ] 2.2 Mid-download, turn Wi-Fi off for a minute, then on. **Pass:** the download continues from
  where it stopped, not from zero.
- [ ] 2.3 Mid-download, quit Dot (Command-Q, or **Quit Dot** in its menu-bar icon) and open it
  again. **Pass:** it resumes, and parts already verified are not downloaded again.
- [ ] 2.4 Wait for the end. **Pass:** Dot says it is ready and answers a click.

## 3. Talking

- [ ] 3.1 Click the dot once and say "Hello Dot, what are you?". **Pass:** a listening cue, then a
  short spoken answer in a British voice.
- [ ] 3.2 Click again while it speaks. **Pass:** it stops and listens.
- [ ] 3.3 Hold Fn and speak, then release (first right-click Dot, **Tools & History**, **Enable
  hold-Fn and global gestures (Accessibility)…**). **Pass:** same as 3.1.
- [ ] 3.4 Ask a question that needs a reply from you. **Pass:** after answering, it listens again
  without a click.
- [ ] 3.5 Speak for a long time without stopping. **Pass:** at 5 minutes it says it stopped
  listening and answers what it heard.
- [ ] 3.6 Right-click, **Type to Dot…**, type a question. **Pass:** it answers in text and voice.
- [ ] 3.7 Play a video with sound for a few minutes. **Pass:** Dot makes no comments over it.
- [ ] 3.8 Right-click Dot, **Voice settings**: change a setting. **Pass:** the next turn uses it.

## 4. Coming back (wake greeting)

- [ ] 4.1 Lock the Mac or let it sleep for 12 minutes, then return. **Pass:** most times (about 4
  of 5) a warm greeting that fits the time of day; never a fixed "I'm back".
- [ ] 4.2 Lock for 1 minute only. **Pass:** no greeting.
- [ ] 4.3 While locked or asleep. **Pass:** Dot does not talk.

## 5. Memory

- [ ] 5.1 Say "Remember that my dentist is on Friday". **Pass:** it confirms in one line.
- [ ] 5.2 Have a short normal chat, then say "What do you remember?". **Pass:** a short list of key
  points (5 to 10 per conversation), not whole sentences you said.
- [ ] 5.3 Say "Forget about the dentist". **Pass:** only the dentist point is gone; ask 5.2 again
  to check.
- [ ] 5.4 Quit and reopen Dot, then ask 5.2. **Pass:** the remaining points are still there.

## 6. Files

Use a test folder: `mkdir -p ~/Desktop/DotTest && echo hello > ~/Desktop/DotTest/note.txt`

- [ ] 6.1 Right-click, **Tools & History**, **Mac actions & receipts…**, choose `~/Desktop/DotTest`.
  **Pass:** the panel shows the folder.
- [ ] 6.2 Say "Read note.txt". **Pass:** it reads "hello".
- [ ] 6.3 Say "Create a file plan.txt with the text test plan". **Pass:** the file appears.
- [ ] 6.4 Say "Move note.txt into a folder called archive" and "Copy plan.txt to plan-copy.txt".
  **Pass:** both happen inside DotTest.
- [ ] 6.5 Say "Delete plan-copy.txt". **Pass:** the safety check approves, then it is gone.
- [ ] 6.6 Ask for `rm -rf ~/Desktop/DotTest` three times. **Pass:** refused each time, nothing
  deleted. Then say "force it" and ask once more. **Pass:** only then does that exact command run.
- [ ] 6.7 Quit and reopen Dot, then say "Read plan.txt". **Pass:** works without choosing the
  folder again.
- [ ] 6.8 Ask it to change a file on your Desktop outside DotTest. **Pass:** it says it cannot
  write there.
- [ ] 6.9 Say "Find file note". **Pass:** it finds names in Desktop, Documents or Downloads.

## 7. Screen

Allow Screen Recording for Dot when macOS asks.

- [ ] 7.1 Right-click, turn **Screen awareness** on. Ask "What is on my screen?". **Pass:** a short
  true description.
- [ ] 7.2 Turn **Screen awareness** off and ask again. **Pass:** it says screen context is off and
  does not guess.
- [ ] 7.3 Say "Read screen text". **Pass:** it reads visible text.
- [ ] 7.4 Open a page in Safari, Chrome or TextEdit and say "Read this page". **Pass:** it reads that
  page. In Chrome it may first ask you to allow JavaScript from Apple Events.
- [ ] 7.5 Say "Highlight window". **Pass:** an outline around the front window.
- [ ] 7.6 Take a screenshot (Command-Shift-3 or 4). **Pass:** Dot hides itself from the shot.

## 8. Comments on its own

- [ ] 8.1 Right-click Dot, **Proactivity**: set High. Work normally for 5 minutes. **Pass:** about
  one short comment a minute; a question only when it really needs your answer.
- [ ] 8.2 Set Low. **Pass:** about one comment every 10 minutes.
- [ ] 8.3 Right-click Dot, **Proactivity**, **Pause suggestions**. **Pass:** no comments until you
  resume.
- [ ] 8.4 Leave the same app error on screen for a few minutes (Screen awareness on). **Pass:** Dot
  offers help with that error.
- [ ] 8.5 Leave Dot idle for 10 minutes. **Pass:** at most one sentence like "I noted an idea to
  improve myself."; the clipboard is unchanged.

## 9. Calendar

Allow Calendar access when macOS asks.

- [ ] 9.1 Say "Upcoming meetings". **Pass:** today's events are read.
- [ ] 9.2 Say "Add a meeting called Dot test tomorrow at 3 pm for 30 minutes". **Pass:** a
  confirmation card; the event appears only after you confirm.
- [ ] 9.3 Say "Move Dot test to 4 pm". **Pass:** a card, then the event moves.
- [ ] 9.4 Make an event that starts in 10 minutes. **Pass:** about 5 minutes before, Dot says it
  starts in 5 minutes.
- [ ] 9.5 Say "Next meeting brief". **Pass:** a short brief of the next event.

## 10. Mac controls

- [ ] 10.1 "Volume up", "Mute", "Unmute". **Pass:** each works.
- [ ] 10.2 "Dark mode on", then "Light mode". **Pass:** the system appearance changes.
- [ ] 10.3 "Set a timer for 1 minute to stretch". **Pass:** it speaks when the minute ends.
  "Show timers" lists running timers.
- [ ] 10.4 With a Finder window in front: "Snap window left", then "Maximize window". **Pass:** the
  window moves.
- [ ] 10.5 Click into a TextEdit document and say "Type hello world". **Pass:** the text appears
  there; the log says only "Typed 11 characters".
- [ ] 10.6 "Press enter" in TextEdit. **Pass:** a new line.
- [ ] 10.7 "Lock screen". **Pass:** the Mac locks.
- [ ] 10.8 "Move to the left", "Go to the top right", "Center". **Pass:** Dot moves. "Volume up"
  never moves it.

## 11. Battery (off by default)

- [ ] 11.1 Say "Battery level". **Pass:** it says the percentage.
- [ ] 11.2 Say "Battery alerts on" (or right-click Dot, **Battery alerts**); unplug, then plug in the
  charger. **Pass:** one spoken alert per event.
- [ ] 11.3 Say "Battery alerts off". **Pass:** no more alerts.

## 12. Research

- [ ] 12.1 Say "Look up the tallest building in Europe". **Pass:** an answer that names its sources.
- [ ] 12.2 Ask the same again. **Pass:** faster, from the 6-hour cache.
- [ ] 12.3 Right-click Dot, **Tools & History**, **Web research…**. **Pass:** the panel opens and
  searches.

## 13. Errors and offline

- [ ] 13.1 Turn Wi-Fi off, quit and reopen Dot, ask a question. **Pass:** it starts and answers with
  no network.
- [ ] 13.2 With Wi-Fi off, ask for a web lookup. **Pass:** Dot says the web is not reachable and keeps
  moving; any red banner above it clears by itself.
- [ ] 13.3 Turn Wi-Fi on again. **Pass:** the next lookup works.
- [ ] 13.4 Right-click Dot, **Tools & History**, turn **Prewarm local model at launch** on, then
  reopen Dot. **Pass:** the first answer comes faster.
- [ ] 13.5 Right-click Dot, **Tools & History**, **Hardware compatibility check…**. **Pass:** it
  shows your Mac passes.

## 14. Logs

Log folder:
`~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/`

- [ ] 14.1 Open `dot_chat_log.txt`. **Pass:** your questions and Dot's answers are there, plus app
  events.
- [ ] 14.2 Say "My password is test1234" and type a card number in a test chat. **Pass:** the log
  shows them masked; no images, no typed text from 10.5, no clipboard.
- [ ] 14.3 Optional upload: store the token as described in
  [LOG_READING_GUIDE.md](LOG_READING_GUIDE.md). **Pass:** logs appear on the `dot-logs` branch under
  `dot/<install-id>/<launch-time>/`. Without a token they wait on the Mac; that is not a failure.

## 15. Remove

- [ ] 15.1 Right-click, **Remove Dot completely…** (or run the line below). **Pass:** it ends with
  `PASS: your Mac is back to how it was`.

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash
```

- [ ] 15.2 Check. **Pass:** no `~/Applications/Dot.app`, no `~/Library/Containers/app.dot.local`,
  no `.dot-actions` inside `~/Desktop/DotTest`, no Dot tile in the Dock, and Dot is gone from
  System Settings, Privacy & Security (Microphone, Screen Recording, Calendars).
- [ ] 15.3 Open `~/Desktop/DotTest`. **Pass:** your own files are still there. Delete the test folder
  yourself.

What removal covers and what macOS keeps for itself: [UNINSTALL_COVERAGE.md](UNINSTALL_COVERAGE.md).
