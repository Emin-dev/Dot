# Changelog

Short and newest first. Details are in each commit and in
[docs/AUDIT_2026-10-22.md](docs/AUDIT_2026-10-22.md). Older entries:
[docs/archive/CHANGELOG_EARLIER.md](docs/archive/CHANGELOG_EARLIER.md).

## v1.1.6 (2026-10-24)

- The unused Python voice runtime (872 MB) no longer ships, and the launch check
  hashes three model files at once ([docs/AUDIT_2026-10-23.md](docs/AUDIT_2026-10-23.md)).
- Speech-to-text runs on Apple's on-device SpeechAnalyzer once macOS has installed its English
  model (asked at first launch); until then the bundled whisper.cpp recognizer answers, and the log
  names the one used (R25). Screen watching measures change with Apple Vision feature prints, so
  a ticking clock stays below the change threshold (R23).
- Every command that is not a plain read goes to the safety approver; network,
  credential and launcher tools keep the card; the card shows the whole command; voice approval
  needs a whole phrase; commands stop after 30 s or 1 MB; the chosen folder itself is never removed.
- The public log keeps file and page text by size only and command output by its first line;
  conversation lines keep their existing masking of secrets and personal numbers.
- Unused code removed (paid search clients, an unused synthesizer).
- The chosen folder is remembered across launches (R22).
- Removal also deletes `.dot-actions` folders, a pinned Dock tile, Dot's download-history rows,
  crash records and the Keychain log token ([docs/UNINSTALL_COVERAGE.md](docs/UNINSTALL_COVERAGE.md)).
- Repository notes rewritten short; history moved to `docs/archive`.

## v1.1.5 (2026-10-23)

- Memory: "forget about X" matches every word; no raw sentences stored; each conversation
  summarised once.
- One-off errors clear by themselves; stale approval cards expire; file-writing commands keep the
  approver; battery alerts work while comments are paused; `delete_file` stays in the chosen folder;
  "highlight active window" outlines the real window.

## v1.1.4 (2026-10-23)

- Dot no longer moves on "volume up", "look up X" or "is this right?".
- Paused music stays paused; "copy screen text" copies the screen; Safari pages read with default
  settings; "lock screen" locks; screenshots keep Dot hidden.
- The model download resumes after a pause, quit or network drop; offline removal; Finder-like free
  space; installer warns below the minimum; `mv`, `cp`, `trash` work in the chosen folder.

## v1.1.3 (2026-10-22)

- Owner decisions R18 to R21: warm wake greeting, errors keep Dot living, short reflection note,
  narrow sandbox exceptions.
- Public-log privacy: no typed text, clipboard, screen text, credentials or personal details in logs.
