# Start here

For any AI or developer continuing Dot. Read this, then [OWNER_DECISIONS.md](OWNER_DECISIONS.md)
(never re-ask or revert a decision) and the rules in [DEV_TEAM_PROMPT.md](DEV_TEAM_PROMPT.md).
Working rules for agents are in [AGENTS.md](../AGENTS.md).

## State (2026-10-24)

- Every documented promise was audited against the code on 2026-10-22/23 and every finding is fixed
  with a test or guardrail: [AUDIT_2026-10-22.md](AUDIT_2026-10-22.md). The delete, speed, security
  and Apple-native audit is [AUDIT_2026-10-23.md](AUDIT_2026-10-23.md): its "Done" rows shipped in
  v1.1.6 and v1.1.7. Still open: security S1 (high) and S15, which change behaviour and wait for
  the owner's answer, the other owner decisions, speed work (P2 to P19), Apple-native swaps and small
  dead code (D5 to D9).
- Latest published release: **v1.1.7** (2026-10-24, run `40095306072`, commit `e128cc2`):
  `Dot.dmg` 548,516,352 bytes, SHA-256
  `d177afe2263b4ebdf77ce776509b61936723ec0edf73ac56b3d1f697d1ef9db8`. Every release gate passed
  (package, quarantine install, `spctl`/`codesign`, one-line installer, no-trace, publish). It adds
  security fixes S8 and S10 to S14 to v1.1.6 (run `40086010216`, 548,590,592 bytes; v1.1.5
  was 793,125,376).
- Speech-to-text: Apple SpeechAnalyzer once macOS has installed its English model; whisper.cpp
  stays as the fallback until the owner's real-Mac check (TEST_TODAY step 3.9) confirms Apple's
  recognizer, then R25 step 2 removes it.
- Owner test: [TEST_TODAY.md](TEST_TODAY.md) is a 73-step checklist of every feature; the release
  page shows the same file.
- Gates: Native CI green (Swift build, XCTest, SwiftPM, Rust, Python, 137 static guardrails);
  every release passes install, quarantine, `spctl`/`codesign` and the no-trace lane.
- Production blocker: Developer ID signing and notarisation, owner-only
  ([QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md) section 2).
- Owner-only checks: a real run on a minimum-spec Mac ([TEST_TODAY.md](TEST_TODAY.md)) and storing
  the log token.

## Commands

```bash
# Linux or macOS
python3 -B -m unittest discover -s Tests/Python
python3 -B scripts/check_contracts.py
CARGO_BUILD_JOBS=2 cargo test -p dot-research -p dot-runtime
CARGO_BUILD_JOBS=2 cargo clippy -p dot-research -p dot-runtime --all-targets -- -D warnings

# macOS only (CI runs these on every push)
bash scripts/verify_macos.sh
```

Release: dispatch `.github/workflows/release.yml` on `main` with a new tag (a tag push from a cloud
session is blocked; `workflow_dispatch` works). It publishes only after every gate passes.

## Where things live

| Path | What |
| --- | --- |
| `src/ChatView.swift` | turn pipeline, voice and speech gates, proactive ticker, memory summary, errors |
| `src/InteractionCore.swift` | shared policy and tools: commands, redaction, hardware gate, file scope |
| `src/Engine.swift` | system prompt and tool schemas |
| `src/App.swift` | menus, windows, movement, launch, removal |
| `src/OfflinePreparation.swift` | runtime and model verification, first-launch download |
| `src/ActionPanel.swift`, `src/NativeActions.swift` | file actions in the chosen folder |
| `src/MemoryTiers.swift`, `src/LocalFTSStore.swift` | memory tiers and the SQLite store |
| `src/DotLogSync.swift` | text log upload to the `dot-logs` branch |
| `crates/` | Rust: research, voice, runtime, safety approver |
| `scripts/` | install, uninstall, packaging, signing, guardrails |
| `Tests/` | XCTest (`DotCoreTests`) and Python contracts |

All app data lives in `~/Library/Containers/app.dot.local/Data/Library/Application Support/Dot/`.

## Rules that are easy to break

- `main` is the only development branch; `dot-logs` holds uploaded logs. Never force-push or delete
  branches.
- The model is fixed (Qwen3.8 27B Q4 on Splash). No smaller fallback, no lower hardware gate.
- Logs: text only; never keys, tokens, passwords, typed text, clipboard or raw screen text.
- Every change gets a test or a guardrail in `scripts/check_contracts.py`.
- Swift cannot be compiled on Linux; read CI before saying it works.
