# Perception models

Owner question (2026-10-23, verbatim): "explain how you used deception models like Laya or jjev in
dot to improve app speed and make it more useful? if not how here you will add this new kind of
models? and which local alternative you will use instead of jev?" Read as LLaVA (image and text
models) and V-JEPA (Meta's video model).

Decision: option 1, Apple Vision feature prints, recorded as R23 in
[OWNER_DECISIONS.md](../OWNER_DECISIONS.md). Steps 1, 2 and 5 below are built; steps 3 and 4 wait
for measured distances from real use.

## What Dot uses before R23

| Job | Model or API | Code |
| --- | --- | --- |
| Answers, and reading a screenshot | Qwen3.8 27B Q4 on Splash. It takes images, so it already is Dot's LLaVA-type model. One screenshot goes with each turn you start (voice, typed, circle-to-ask, dropped file) only when Screen awareness is on, Screen Recording is granted and Splash reports `vision: true` with `image` input. | `src/Engine.swift` (`visionAvailable`, `performChat`), `src/ChatView.swift` (`screenImage`) |
| Speed | DFlash2 draft model (3.8 GB): it proposes the next tokens and the 27B checks them in one pass (speculative decoding). Optional prewarm at launch (R11). | `llm-draft/` |
| Safety checks | Gemma 3 4B Q4 (2.5 GB file), the R16 approver | `crates/dot-safety`, `src/SafetyApprover.swift` |
| Screen text | Apple Vision `VNRecognizeTextRequest`, on device | `src/InteractionCore.swift`, `src/ScreenContext.swift` |
| Is the screen changing | an exact hash of a 32x24 grayscale frame (mouse pointer hidden): one every 3 minutes when idle; after a change or mouse movement, one every 2 s for 10 to 50 s, then a 60 s cooldown | `ScreenContext.captureFingerprint` (removed by R23), `ScreenWatchState` |

There is no separate LLaVA and no V-JEPA. A separate LLaVA would repeat what the 27B already does and
take RAM from it.

## Where a video signal would help

The hash is all or nothing: any changed pixel (a menu-bar clock, a blinking text caret) counts as a
change, and it cannot tell "the same error for five minutes" from "a new task". A graded signal would let Dot comment when the
scene really changed, stay quiet when it did not, and call the 27B less often.

## Why not V-JEPA

- V-JEPA 2 and 2.1 (Meta, about 1B parameters) output embeddings, not words. Every use needs its own
  trained probe.
- It runs on PyTorch. Dot's runtime carries PyTorch only for the Kokoro voice; V-JEPA would add a
  second large model next to the 27B, with its own loader, disk and several GB of RAM on a 48 GB
  minimum Mac.
- Reports of its license conflict (CC-BY-NC or Apache 2.0); it would have to be checked first.

## Local alternative (recommended)

Apple Vision feature prints (`VNGenerateImageFeaturePrintRequest`). They are part of macOS, need no
download, run on device, and give a distance between two frames. This fits the owner's stated
preference for Apple's own tools (chat, 2026-10-23).

1. Replace the hash with a feature print of a 256x160 capture, computed off the main thread; keep
   only the last print in memory.
2. Count a change only at or above a distance threshold (0.1 to start). The fixture test prints the
   measured distances in CI: on 2026-10-23 (run `40003269001`) a clock tick measured 0.068 and a new
   window 0.935. Retune from those and from real screens.
3. "Same scene for N minutes" feeds stuck-error help; "large change" feeds proactive comments at the
   chosen Proactivity cadence.
4. Send a screenshot to the 27B only on a large change.
5. Prove it: XCTest on fixture images for the thresholds; a guardrail that no frame or print is
   stored or logged (R8 and the logging rule).

Cost: no new model, no extra RAM, a few milliseconds per check.

Possible later step: Apple FastVLM (0.5B, 1.5B or 7B, MLX) for live captions without the 27B. It is a
second model, so it needs the owner's approval and a RAM budget.

## Sources

- V-JEPA 2 code: <https://github.com/facebookresearch/vjepa2>
- V-JEPA 2 coverage: <https://pureai.com/Articles/2025/06/18/Meta-VJEP-2.aspx>,
  <https://the-decoder.com/metas-latest-model-highlights-the-challenge-ai-faces-in-long-term-planning-and-causal-reasoning/>
- FastVLM and MobileCLIP2: <https://9to5mac.com/?p=1000935>, <https://news.smol.ai/issues/25-08-29-not-much>
- Vision feature prints: <https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest>
