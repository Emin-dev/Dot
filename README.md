# Dot

A small local AI companion for macOS. It floats on your screen, listens when you click it, answers
aloud, remembers key points, comments on what you are doing and acts on your Mac. After a one-time
model download it works fully offline.

## Requirements

- Apple Silicon M5 Pro class or newer, 48 GB Unified Memory, macOS 27 or newer.
- About 35 GB free disk for the one-time 22.4 GB model download.

Dot uses one fixed model, Qwen3.8 27B Q4 on Splash, with no smaller fallback. A Mac below the
minimum gets one clear message.

## Install

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/install-dot.sh | bash
```

The installer verifies every SHA-256, installs Dot into `~/Applications` (no sudo) and opens it.
The release is ad-hoc signed and not notarised yet; see
[docs/QUESTIONS_FOR_EMIN.md](docs/QUESTIONS_FOR_EMIN.md) section 2.

## Remove

Use **Remove Dot completely…** in Dot's menu, or:

```bash
curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash
```

It removes the app and everything Dot created and ends with `PASS: your Mac is back to how it was`.
What it covers: [docs/UNINSTALL_COVERAGE.md](docs/UNINSTALL_COVERAGE.md).

## Privacy

- Apple App Sandbox. All data stays in `~/Library/Containers/app.dot.local/`.
- Read-only access to Desktop, Documents and Downloads; writes only in the folder you choose.
- Logs are text only, with passwords, tokens and personal details masked. They upload only after
  you store a token ([docs/LOG_READING_GUIDE.md](docs/LOG_READING_GUIDE.md)).

## Build and test

```bash
python3 -B -m unittest discover -s Tests/Python
python3 -B scripts/check_contracts.py
cargo test -p dot-research -p dot-runtime
```

Swift builds, XCTest and the DMG run in GitHub Actions on macOS (`.github/workflows`).

## Docs

| File | For |
| --- | --- |
| [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md) | start here: state, commands, next steps |
| [docs/OWNER_DECISIONS.md](docs/OWNER_DECISIONS.md) | the owner's answers; do not re-ask or revert |
| [docs/DEV_TEAM_PROMPT.md](docs/DEV_TEAM_PROMPT.md) | binding rules R1 to R25 |
| [docs/BUILD_CHECKLIST.md](docs/BUILD_CHECKLIST.md) | what Dot does and how each part is proved |
| [docs/TEST_TODAY.md](docs/TEST_TODAY.md) | the owner's test on a real Mac |
| [docs/QUESTIONS_FOR_EMIN.md](docs/QUESTIONS_FOR_EMIN.md) | what only the owner can provide |
| [docs/AUDIT_2026-10-23.md](docs/AUDIT_2026-10-23.md) | the latest audit: delete, speed up, secure, Apple-native |
| [docs/AUDIT_2026-10-22.md](docs/AUDIT_2026-10-22.md) | the promise audit and its fixes |
| [CHANGELOG.md](CHANGELOG.md) | what changed |

Technical notes are in [docs/reference](docs/reference); history is in [docs/archive](docs/archive).
