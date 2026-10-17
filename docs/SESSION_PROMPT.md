# New-session prompt

> **Current state:** see [AI_HANDOFF.md](AI_HANDOFF.md). This file is a dated session brief; some items are fixed.

## Goal command (short form)

Pass this as the objective to the harness goal tool:

```
Finish Dot (repo /Users/mac/Documents/deepseek-harness/default-workspace/Dot, branch main only) so every
capability works in practice, not just in tests: find and fix the "compiles but can never fire" class
(unreachable permission requests, stale markers that suppress prompts, failures hidden in logs), and
verify each fix with typecheck, focused suite, full gate, then scripts/install_local.sh. Keep the engine
fixed at Splash + Qwen3.8 27B Q4 with its DFlash draft and the payload byte-identical, keep all
Dot-authored runtime code Rust (continue the supervisor port in crates/dot-runtime, no new Python), and
prefer deleting code to adding it. Finish with main pushed, the installed app's provenance matching HEAD,
and docs/HANDOVER.md, docs/CONTINUATION.md and docs/BUILD_CHECKLIST.md truthful. Completion requires one
real observed session from the owner plus verify_macos.sh free of non-by-design failures.
```

One-line variant:

```
Make Dot's capabilities actually fire in practice (fix unreachable/stale-marker/hidden-failure bugs),
keep Splash + Qwen3.8 27B Q4 fixed and all Dot code Rust, verify each change end-to-end and install it,
and leave main, the running app and the three docs in sync.
```

— copy everything below the line into a fresh session

---

You are continuing work on **Dot**, a macOS companion app at
`/Users/mac/Documents/deepseek-harness/default-workspace/Dot` (git remote
`git@github.com:Emin-dev/Dot.git`, branch `main` only, no feature branches ever).
Read `docs/HANDOVER.md`, `docs/CONTINUATION.md` and `docs/BUILD_CHECKLIST.md` first; they are
authoritative and this prompt summarises them.

## Who you are working with

The owner is building Dot as a personal AI companion that lives on their desktop, runs entirely
locally, and must actually *do* things — not describe them. They report symptoms in plain language
("the app doesn't work", "it doesn't ask for permissions") and expect you to find the real cause
rather than ask questions that reading the code would answer. They have been burned by features
marked done that silently do nothing, so **working in practice beats working in theory**. Their
standing expectations: fewer lines of code, a simple app that feels easy, and no pretending — if
something is only half done, say so.

## The end goal

A public, signed, notarised macOS release where:

1. Every capability in `docs/BUILD_CHECKLIST.md` genuinely works for a real user, not merely compiles.
2. The app is **Rust for all Dot-authored code**; the only Python left is inside the vendored Splash
   engine payload (see the constraint below).
3. Memory, voice, screen awareness, local actions, research, file access and self-improvement form one
   coherent, reliable assistant.
4. `scripts/verify_macos.sh` passes apart from the two documented non-code items.
5. Everything is committed and pushed to `main`, and the same build is installed locally via
   `bash scripts/install_local.sh`.

## Hard constraints — do not change these without the owner saying so explicitly

- **Engine and model are fixed: Splash + Qwen3.8 27B Q4.** The payload is
  `OfflineModels/llm-target` (`qwen3_5_text`, 64 layers, 4-bit affine group-64, ~15 GB) plus
  `llm-draft` (`DFlash2DraftModel`, 5 layers) which provides its speculative decoding — that draft is
  where the speed comes from, so **no engine, model, quantisation or "smaller for speed" substitution**.
  A generic Rust engine (llama.cpp, mistral.rs) does not implement this draft and would most likely be
  slower. Keep the payload byte-identical.
- **No new Python.** Dot's own remaining Python is the Splash supervisor/TLS relay being ported to Rust
  in `crates/dot-runtime` (slice 1 committed: wire contract + api key, 3 tests, binary refuses to run).
- **Rust runtime binaries** `dot-voice`, `dot-search`, `dot-fetch` are shipped in `Contents/MacOS/` and
  are audited by `scripts/audit_runtime_payload.py`.
- **Less code.** Prefer deleting to adding; no dead code, no second mechanism for something that exists.
- **Dew** (`NativeSkin.dew`) is the default skin and an explicit choice must persist.
- **Dot never moves** while its menu is open, the pointer is on it, or a mouse button is held.
  Idle roaming every **2 minutes** only. The 5-second thinking relocation was retired by the owner on
  2026-10-17 after Dot moved nonstop through long model loads; do not reintroduce it.
- **Memory** has five tiers, never deletes automatically (except eviction under real RAM pressure,
  T1→T2 only, never T3/T4/T5, never pinned), and the owner can delete explicitly.
- **Listening** is up to 5 minutes per turn with a spoken cap notice; there is no wake word (click or
  hold-Fn only). **English only.**
- **Memory** captures 5–10 LLM-written key points per conversation (details kept) with full text in a
  separate searchable archive.
- **Approvals** use a trusted-app allowlist; a per-command card remains outside it. File operations are
  automatic without asking (create/write/rename/move/delete); calendar mutations keep a confirmation
  card. A plain "yes" is accepted only for non-destructive offers.
- **Always** commit + push to `main` and reinstall locally after testing; never leave the repo and the
  installed app out of step.

## State you inherit (verified at commit `ae3bdce`)

- Gates green: Xcode app build SUCCEEDED; full XCTest lane **860 tests / 0 failures**; `swift test`
  **546 / 0**; Python suite **604 passed, 4 skipped**; **53** static guardrails; all three Rust binaries
  build; payload audit passes on the real payload.
- `verify_macos.sh` now runs here (it builds SwiftPM outside the checkout) and fails only on:
  the mandatory runtime-finalizer canary (`unsupported hosted toolchain image`, by design, blocks
  packaging) and one load-flaky search test (see below). Everything else in it passes.
- Installed app provenance matches HEAD (`scripts/install_local.sh` verifies this).
- Working and verified: Rust voice/search/fetch, click-to-listen with Whisper compiled in, mic arming
  only after final playback, approval gate (tokenised destructive detection, clickable card), the full
  memory loop (capture → tiered recall → "what do you remember" → "forget about X" → ageing → pressure
  eviction), copy/show Dot's answer, battery reporting, self-reflection (writes + copies + offers a
  paste), read a named text file, Spotlight content search, 2-minute idle roaming that stays put during
  interaction, Dew default with persistence, and the scripted install.
- **Permissions** were the biggest real defect and are now fixed for microphone and screen: both are
  requested on the first click / hold-Fn, before any readiness gate (see the audit class below).

## The bug class to keep hunting — this is the current priority

The owner's complaint is not crashes; it is **code that exists, compiles, has tests, and can never fire
in practice**. Two instances were found and fixed:

1. **Microphone** — the app only *checked* `AVCaptureDevice.authorizationStatus`. The single
   `requestAccess` call sat behind readiness verification and screen preparation, so it never ran, and
   every turn reported "microphone access is off".
2. **Screen** — `markPermanentlyConfigured()` wrote `screenAccessGrantedInSettings = true` *before* the
   prompt was answered, and that key plus an on-disk marker decide whether to ask again. The app
   therefore believed access was granted from the first launch, never asked, and every capture failed
   into a `notice`-level log line.

Apply this five-check audit to every capability:

- Is the OS request reachable from a **real user action**, before any readiness guard?
- Who writes each persisted flag/marker, and **in what order** relative to the prompt?
- Does a persisted flag **suppress** a future prompt forever?
- Does failure reach the **owner** (visible message), or only a log line?
- Does a `guard`/early `return` sit **before** the feature?

Queued next: calendar/reminders (`_ = await requestAccess()` discards the result → silent failure);
Accessibility for typing/clicking/pasting (is a refusal visible?); push-to-talk ordering; the
self-reflection timer's reachability; whether the diagnostic log records normal turns at all; the
placement snapshot that is guaranteed to expire every cycle; and memory's capture heuristic.

## Open work, in the order it should be tackled

1. **A real session.** No current build has ever been exercised by the owner (no log entries). Have them
   click Dot, grant mic + Screen Recording, and talk. Everything else is guesswork until then.
2. **Quality-of-service inversion** — a User-interactive thread waits on a Default-QoS one; the turn
   pipeline task in `ChatView.submit` should carry `.userInitiated`. `verify_macos.sh` filters *only*
   that advisory out of its zero-warning check: **remove the filter in the same commit as the fix**.
3. **Flaky search test** — `LocalDotSearchProviderTests.testRuntimeAnswersAreBoundedAndCapabilityRejectionSurfaces`
   hung 1041 s once under the gate's full load but passes 7/7 in 7.2 s in isolation. Make the fixture's
   readiness deterministic or bound its retries; **do not raise `startupSeconds`** (10 s is correct).
4. **Supervisor port slices 2–5** in `crates/dot-runtime`: own the Splash child in its own session and
   emit the real `started` line; port the TLS relay (the expensive slice — ~700 lines of Python contract
   tests move with it); socket handoff to the sandboxed child; switch `BundledSplash.swift` and delete
   the three `.py` files. `Resources/Runtime/splash.sb` and the 53 guardrails must stay green.
5. **Memory cleanup** — `MemoryTierStore` opens a second SQLite connection to `dot_records.sqlite`; a
   `withConnection` accessor on `LocalFTSStore` removes ~120 lines.
6. **Placement** — `PlacementSnapshot.lifetime` is 10 s and validation runs on a ~10 s cadence, so the
   first validation each cycle is rejected by construction. Fix it in the caller (refresh before
   validating); **never raise the lifetime** — `RoamingTests` guards that rule.
7. **~540 audited dead lines**, in the cases whose declarations are not cleanly separable.
8. **File access** — currently: read a named text file, Spotlight name/content search, one watched
   folder. Missing: arbitrary-tree indexing, iCloud placeholder handling, relevance ranking. The owner's
   ask was "everything on my disk".
9. **Public-release gates** — first-launch downloader for the payload, licence closure, notarisation,
   clean second-Mac acceptance.

## Environment facts and traps

- `python3` is 3.9 here; the suite needs ≥3.11 — use `/private/tmp/dot-py313/bin/python`.
- This checkout is cloud-synced. Build SwiftPM with a scratch path, e.g.
  `swift test --disable-sandbox --scratch-path /private/tmp/dot-XX --cache-path /private/tmp/dot-XX-c
  --config-path /private/tmp/dot-XX-cfg --security-path /private/tmp/dot-XX-sec`, and `xattr -cr`
  before `codesign`, or the File Provider's attributes make codesign reject the bundle.
- **Re-signing resets TCC.** Always install with `bash scripts/install_local.sh` (stable Apple
  Development identity) or the permission grants disappear.
- Full Xcode lane:
  `DOT_TEST_PYTHON=/private/tmp/dot-py313/bin/python xcodebuild -project Dot.xcodeproj -scheme Dot
  -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath /private/tmp/dot-XX-dd
  CODE_SIGNING_ALLOWED=NO test`.
- Typecheck before any suite: `xcrun swiftc -typecheck -target arm64-apple-macosx15.0 -sdk
  "$(xcrun --sdk macosx --show-sdk-path)" -module-name DotProbe src/*.swift`.
- A grep-verified "unreferenced" declaration can share a line with a live one (comma-declared
  properties) — verify every deletion with a typecheck immediately. This cost a real bug once
  (`RAMMetrics.usagePercent`).
- Broad subagent briefs over this 22k-line codebase consume a whole budget reading and write nothing.
  Narrow, single-fix scopes work; doing it directly works better.

## Rules of engagement

- Never silence a symptom: do not raise a timeout, relax an assertion, delete a test or widen a filter
  to make a gate green. Fix the cause, and if a filter must exist, record it and remove it with the fix.
- Verify, don't assume: typecheck → focused suite → full lane → contracts → install, and report what
  actually ran.
- If the owner reports "it doesn't work", go read the actual code path end-to-end before replying, and
  when you cannot reproduce it, ask for the single specific observation that would distinguish causes.
- Keep `docs/HANDOVER.md`, `docs/CONTINUATION.md` and `docs/BUILD_CHECKLIST.md` truthful as you go;
  they are how work survives a context reset.
