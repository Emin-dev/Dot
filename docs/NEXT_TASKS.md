# Next tasks (handoff, 2026-10-24)

State: v1.1.7 is published (run `40095306072`, commit `e128cc2`, `Dot.dmg` 548,516,352 bytes,
SHA-256 `d177afe2263b4ebdf77ce776509b61936723ec0edf73ac56b3d1f697d1ef9db8`). Native CI and the
no-trace lane are green; 137 static guardrails; Python suite 698 tests (2 IPv6-only errors on Linux).
Read [AI_HANDOFF.md](AI_HANDOFF.md) first, then [AUDIT_2026-10-23.md](AUDIT_2026-10-23.md).

## Owner only (never done by an AI)

1. Developer ID signing and notarisation: [QUESTIONS_FOR_EMIN.md](QUESTIONS_FOR_EMIN.md) section 2.
2. Real-Mac run of [TEST_TODAY.md](TEST_TODAY.md) (73 steps). Step 3.9 must show
   `Speech-to-text: Apple SpeechAnalyzer (on device).` in the log.
3. Optional log-upload token: QUESTIONS_FOR_EMIN section 1.

## Questions to ask the owner, one at a time, numbered options

Record each answer verbatim in [OWNER_DECISIONS.md](OWNER_DECISIONS.md) as the next R number.

1. S1: on a turn that carries web page, screen, dropped-file or clipboard text, should typing, key
   presses and clicks need the approval card? 1) Yes (recommended) 2) No.
2. S3 (C): proactive screen comments in the public log: 1) masked like screen text (recommended)
   2) full.
3. S15: silent screen snapshot after each reply: 1) only when screen awareness is on, and reword
   the Screen Recording text (recommended) 2) keep as is.
4. N5, N7, N10: move search, page fetching and the Splash link to URLSession, Network.framework and
   a Unix socket: 1) yes, one at a time 2) no.
5. D9: remove the old `dots/` per-install logs from the public repository: 1) yes 2) no.
6. After Developer ID: S9 (XPC helper), N12 (Data Protection Keychain), S10 C (logs-only token).

## Engineering tasks that need no owner answer

- R25 step 2, only after owner step 2 above passes: remove whisper.cpp, `STT/ggml-base.en.bin`
  (148 MB) and `WhisperRecognizer`; update `OfflinePayload` `requiredByRole`, `audit_runtime_payload.py`,
  `slim_runtime_payload.py` (add `STT` to the removed roots) and the R25 guardrail.
- Speed (AUDIT "Speed and battery"): P2 character frame rate when idle or hidden; P3 AX timeout;
  P4/N8 CoreAudio volume; P5 parallel memory queries; P6 move the minute timestamp to the end of
  the prompt; P7/P8/P9/P10 fewer background wakeups; P11 precompiled log regexes; P12 log segments
  every 10 min; P13 watcher off the main thread; P15 approver verdict memo; P16 Rust release profile.
- Dead code D5 to D8 and unused scripts (D9 scripts part).
- R23: consider raising the feature-print threshold from 0.1 to about 0.15.

## Rules that stay binding

AGENTS.md: reviewer and tester agents in parallel after every change, commit only after both report,
push to main, never force-push, never create keys or tokens, write findings to files.
