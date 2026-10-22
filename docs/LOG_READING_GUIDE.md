# Reading Dot logs so OpenCode can fix issues

Dot uploads **text only** to a dedicated data branch. Nothing in this channel can change `main`.

## Where

```
Emin-dev/Dot @ dot-logs
dot/<install-id>/<launch-timestamp-UTC>/
    meta.json          # install id, launch time, app version, macOS, chip, RAM
    dot_chat_log.txt   # current text log
    dot_chat_log.1.txt # previous 2 MB rotation, when present
    dot-health.json    # engine/mic/screen readiness snapshot
```

The install id is an anonymous stable value (8–32 lowercase alphanumeric characters, normally 16) stored at
`~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/install-id`. Each app launch creates a new timestamp folder.

## Fetch

```bash
gh api "repos/Emin-dev/Dot/contents/dot?ref=dot-logs" --jq '.[].name'          # install ids
gh api "repos/Emin-dev/Dot/contents/dot/<install-id>?ref=dot-logs" --jq '.[].name'  # launches
gh api "repos/Emin-dev/Dot/contents/dot/<install-id>/<launch>?ref=dot-logs" --jq '.[].name'
gh api "repos/Emin-dev/Dot/contents/dot/<install-id>/<launch>/dot_chat_log.txt?ref=dot-logs" \
  --jq '.content' | base64 -d > .tmp/dot-log.txt
```

Or clone only the data branch:

```bash
git clone --depth 1 --branch dot-logs https://github.com/Emin-dev/Dot.git .tmp/dot-logs
```

## Format

```
[2026-10-20T17:24:03.123Z] [USER] full user message
[2026-10-20T17:24:04.456Z] [DOT] full Dot reply
[2026-10-20T17:24:04.500Z] [TOOL] TOOL: name | TARGET: "..." | OUTCOME: ... | STATUS: SUCCESS
[2026-10-20T17:24:05.000Z] [SYSTEM] app/system event
```

Roles include `user`, `dot`, `dot (proactive)`, `dot (task)`, `tool`, `screen`, `system`,
`dot (self-improvement)` and `dot (stuck-guidance)`.

## Diagnose

1. Open the newest launch folder; start at the last `[SYSTEM]` failure or `[DOT (SELF-IMPROVEMENT)]`.
2. Compare with `meta.json` (OS/chip/RAM) and `dot-health.json` (engine ready, mic, screen).
3. Search for `TASK:`, `REASON:`, `MISSING:`, `PROPOSED_FIX:`, `[ROAM]` and `[HEALTH]`. Uploader-only
   diagnostics (including `[SYNC]`) are local in `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/Logs/dot-sync.log`.
4. Fix the source, add a test, and note the evidence in `docs/PROGRESS.md`.

## Privacy and safety

- Conversation text is uploaded by the owner's explicit decision; images, screenshots, audio and
  microphone recordings are never uploaded.
- Screenshots are described as OCR counts and text summaries only; raw images are never logged.
- Keys, tokens, passwords and `Authorization` headers are masked before writing.
- The upload token is read from Keychain service `dot-github-token` or the owner-created
  `Application Support/Dot/github.token` inside that container; it is never logged, committed or bundled.
- Uploads go to `dot-logs`, never `main`. `main` requires a pull request.
