# Startup and first-turn latency

## Observed baseline

The owner's Mac measured the unchanged `ba6cc7a55d9ab6d56057ef083d2492e7e52da1b4` app on 2026-10-13. One same-payload, cache-warm sample took 8.495 seconds to verify the runtime and 8.571 seconds to verify models, serially (17.066 seconds total). An earlier combined sample was 24.260 seconds. These are integrity-check durations, not exact first-paint measurements.

Cold Splash readiness was about 18.1 seconds; a second turn reused the same process and reached readiness in about 5 milliseconds. Voice initialization was 6.396 seconds in a separate native acceptance run. Recent owner turns failed screen permission after transcription and backend startup, so those turns are not successful end-to-end response benchmarks.

## Bounded changes

- Run runtime verification and model verification as exactly two structured tasks. Keep every content hash, exact file-closure, path, size, symlink and cancellation check. Model files are still checked serially. Either failure cancels and drains its sibling. Neither progress completion nor talk readiness is published until both pass.
- At an explicit accepted click, check/request screen permission before microphone startup when Screen context is enabled. Actual capture still happens just before the reply, rechecks permission and never silently falls back. Disabling Screen context persists and skips both checks/capture.
- After microphone recording actually starts, initialize the existing app-owned Splash and voice processes while the user talks. The final transcript awaits that same warm attempt; chat still verifies current runtime identity. Stop invalidates the turn and cancels its pending work. Ready processes remain owned by the app for reuse until Quit.
- Keep the user's three-second silence interval. No microphone, screenshot, permission request or inference starts on app launch. Clicking while file checks are incomplete never queues recording; the compact checking indicator and right-click progress remain available.

This overlaps work; it does not remove cold loading, full validation or the silence interval. It also moves CPU/GPU work into the listening interval, so native contention, microphone delivery and memory use must be measured. No persistent metadata-only trust cache is used.

## Measurements and acceptance

Fixed-category logs contain only phase names, outcomes and monotonic elapsed milliseconds:

- `DOT_PREPARATION stage=payload|runtime|models event=started|ended`
- `DOT_READINESS event=started|ended`
- `DOT_TIMING capture_started`, `warmup_started`, `warmup_ready`, `final_transcript`, `first_reasoning`, `first_answer`, `playback_started`

Playback timing means scheduled player start, not measured sound reaching the listener. No transcript, screenshot, response, credential or model path is logged.

Run `scripts/verify_macos.sh` for model-free native compilation, concurrency/permission regressions and warning gates. Then benchmark the exact complete candidate against the same verified payload and unchanged baseline, with comparable cache state. Record verification branch and total durations, explicit-click to recording/transcription, cold and warm backend wait, response/playback, process memory and cancellation. Preserve the previous implementation if concurrency gives no useful improvement or harms responsiveness. OS permission refusal must fail before recording/backend startup; grant, opt-out, repeated turn, Stop during warmup and Quit require actual app checks.

No measured speedup is claimed by this source change alone.
