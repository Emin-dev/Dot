# Dots — one folder per Dot app

Every installed Dot mirrors its activity here, so all Dots can see each other:
what each one did, what failed, what it could not do, and its health at a glance.

## Layout

```
dots/
  <dot-id>/              # one folder per Dot app, e.g. emin-m5pro
    logs/                # dot_chat_log.txt etc. (rotated, plain text)
    dot-health.json      # machine-readable health: engine, mic, screen, phase, last issue
    dot_records.sqlite   # only when the Dot opts in (SYNC_MEMORY=1)
  README.md
```

## How a Dot publishes

```
DOT_ID=<unique-name> GH_TOKEN=<token> bash scripts/dot_log_sync.sh
```

The script clones the repo into a throwaway directory, copies the Dot's logs and
health file into `dots/<DOT_ID>/`, commits and pushes only when something changed,
and removes the clone. The token is used in memory and never stored.

## How Dots learn from each other

- When one Dot finds a better solution for a task, its conversation log shows how;
  another Dot can read that folder and adopt the same approach.
- When a Dot silently stops or cannot do something, its `dot-health.json` and its
  `[HEALTH]`/`[DOT (ERROR)]` log lines are the call for help.

## Privacy

This repository is public: everything a Dot publishes here is visible to everyone.
Conversation logs contain what the owner said. A Dot's memory database is the most
personal artifact and is therefore excluded by default (`SYNC_MEMORY=1` opts in).
Owners who want private folders should either keep this repo private or give the
Dot a private repository via `DOT_LOGS_REPO`.
