# Voice follow-up and native appearance milestone

This candidate advances the [canonical checklist](../BUILD_CHECKLIST.md). It is source for review, not an installed or released app. The installed `b26a145` app and the original compact-UI recovery patch are preserved.

## Implemented behavior

- Native menu options persist trailing silence 2/3/5/8 seconds (default 3) and the question invitation 3/6/9/12/20 seconds (default 6). The latter is time to **begin** speaking; accepted speech continues to the selected silence, within the existing 60-second capture bound.
- Capture uses monotonic audio timestamps, resets silence for resumed speech, serializes boundary decisions with incoming PCM and fails closed on missing/invalid/discontinuous audio. Only satisfied silence permits transcription and the next LLM turn; hitting the capture limit does not submit an unfinished turn.
- Splash returns explicit validated `ask_user` intent. A successful terminal response and all ordered synthesis/playback completions are required before one automatic invitation. Punctuation, intermediate drains, empty audio, failures and stale callbacks cannot authorize it. Automatic capture never requests a fresh OS permission prompt.
- A 400 ms playback-to-capture settling interval and fresh microphone/screen/route checks supplement same-turn cancellation. Stop, replacement, drag/menu interactions, hiding, Quit, sleep and route/permission loss revoke the conversation. The inherited provisional cap is three automatic replies per manual conversation; chain-length product policy remains open.
- Original remains the default alongside Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo and Nova. These are actual shared-rig SwiftUI renderers with persistent selection and Full/Subtle/Still motion options. Veil is clearer than Dew; reduce-transparency fallback and light/dark contrast are supported.
- Five initial shared named phase recipes cover idle, listening, thinking, speaking and blocked states with warm facial geometry. New-skin speaking aperture consumes current-player amplitude metering. This is **not phoneme alignment or a completed 120-recipe-per-skin library**. Original's established animated appearance remains available.
- The preserved compact diagnostic UI and Show Dot/Quit menu work are integrated. Opening options preserves blocked diagnostics for copying.

## Native render inspection

[Light appearance](native-skins-light.png), [dark appearance](native-skins-dark.png) and [opaque body fallback](native-skins-opaque-material.png) were generated from the actual SwiftUI renderer and visually reviewed. The contact sheets show static idle/thinking/speaking examples; speaking uses a constant test envelope of 0.2. The opaque image tests the body component, not delivery of an OS accessibility preference. They are separate from the browser concept study and do not certify motion, real playback synchronization, GPU cost or on-device accessibility.

## Acceptance still required

Real microphone/speaker echo, speaker/headphone/Bluetooth route switching, denied/revoked permissions, sleep/hide/drag/menu interruption, and the exact complete-bundle conversation loop still require hardware acceptance. Playback scheduling metrics are labelled as such; no acoustic first-audible latency improvement is claimed. Measure selected silence and post-silence processing separately, against the preserved baseline.

Full expression libraries, phoneme alignment, exact Liquid Glass rendering, proactive scheduling, tiny idle-motion fallback, persistent history/memory, research/files/tools, and Rust services remain open checklist milestones. Fixed Splash/Qwen and British Kokoro assets are unchanged. No model download, replacement, installation or public release is part of this candidate publication.
