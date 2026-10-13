# dot design artifacts

The owner reviewed the directions, selected all ten new skins alongside Original, and authorized building the checklist in tested stages. The earlier hold and first-voice-only implementation limit are superseded. Begin with voice and a separate reviewable native skin/settings batch; no repeat start/theme approval is needed. Installation remains separate. See the [canonical checklist](../BUILD_CHECKLIST.md#design-comparison-prepared-for-discussion).

**Native Settings choices: Original plus ten new skins = 11 choices. Original remains default until changed.** The new lineup is Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo and Nova. Veil replaces Fold at position 8: a thin, nearly invisible transparent bubble/lens like Dew but more transparent, with a sparse face, faint rim and visible backdrop. The split is **4 rounded / 3 glass / 1 Sprout / 2 AI**.

**Latest facial-expression requirement:** all 11 faces must remain smiling, warm and user-friendly across every state, including focus, thinking and research. Use rounder open eyes with highlights, relaxed gently arched brows and a gentle upturned resting mouth. No angry inward V-brows, glaring slit eyes or scowls. Speaking should articulate friendly mouth shapes; keep truthful task labels independent of facial expression. Preserve each identity, Veil, Original as default and the 120+ reviewed named animation-recipe target per new skin.

**Motion preview status:** the corrected warm-face HTML and updated validation report are now delivered. Rounded eyes/highlights, relaxed arched brows, upturned smiles, friendly speaking poses, Sprout arms, Pip beak and Nova eyes were revised; layout now uses aligned equal-width actions, shorter labels and less excess stage height. Author checks passed for all 1,200 configurations, 120 distinct painted tuples per face, friendly parameters, eight speaking shapes, state/echo, no autoplay and Reduce Motion. **The owner has accepted the corrected design and confirmed continued implementation.** No fresh browser pass was available: earlier 736/390/320 px checks apply only to the pre-correction version. Owner design acceptance, fresh technical browser verification and native/hardware acceptance are distinct.

**Owner design acceptance:** after viewing the corrected preview, the owner said **“yes all good build app now.”** The corrected design is accepted and implementation continues without another approval gate. This is separate from technical browser verification: no fresh browser pass was available for the correction, so earlier 736/390/320 px checks still apply only to the pre-correction version. It is not acceptance of the native candidate or installed hardware behavior.

## Current delivered artifacts

| Artifact | Status and scope |
| --- | --- |
| **[V3 concept board](dot-face-directions-v3.png)** | Delivered generated concept art showing the approved Veil-inclusive lineup. Not native app screenshots or implemented skins. |
| [V3 generation prompt](dot-face-directions-v3-prompt.txt) | Preserved unchanged; records the intended local Fold-to-Veil edit. Prompt instructions are provenance, not proof that all other pixels are identical. |
| **[Interactive motion study](dot-face-motion-directions.html)** | **Corrected warm-face/layout export delivered; fresh visual review pending.** Author logic checks passed; earlier browser checks do not validate this revision. [Download](https://raw.githubusercontent.com/Emin-dev/Dot/main/docs/design/dot-face-motion-directions.html), save and open in a browser; GitHub file view shows source. Silent procedural design exploration, not native UI or real audio alignment. |
| [Motion validation report](dot-face-motion-validation.md) | Supplied handler/browser evidence and limits, with a publication clarification that optional wrapper helpers use a CDN. |

The updated report records rerun checks for **1,200** actual activity/expression event-handler configurations and **120 distinct painted CSS parameter tuples per face**, excluding labels from uniqueness checks, plus friendly brow/eye/smile/cheek ranges, eight synthetic speaking-mouth shapes, state echo, no autoplay and deterministic Reduce Motion. **The owner accepted the corrected design; fresh technical browser review of this correction remains unavailable.** Earlier all-ten checks at 736, 390 and 320 px, interaction/pause/navigation and no horizontal overflow belong to the pre-warmth version only. The corrected layout still needs review at those widths and the actual owner window size. Earlier visual review used dark appearance; light appearance and OS-level Reduce Motion were not visually tested.

Those checks do not establish 120 individually authored or perceptually reviewed production animations, real Kokoro phonemes, Apple's native Liquid Glass, frame-time/energy behavior or end-to-end voice speed. The motion study is procedural artwork, not animation of the concept-board pixels. The authored study has no model/microphone/screen/research access; the exported wrapper loads optional CDN presentation helpers and is not fully offline-bundled.

## Historical artifacts

| Artifact | Status and scope |
| --- | --- |
| [V2 concept board](dot-face-directions-v2.png) | Historical pre-Veil artwork: position 8 still depicts the replaced Fold. Not the current final lineup. |
| [V2 generation prompt](dot-face-directions-v2-prompt.txt) | Preserved unchanged with Fold and the superseded 4/2/2/2 split as provenance. |
| [First interactive preview](dot-ui-options.html) | Historical exploratory shortlist. Illustrative silent motion with optional CDN helpers. Its older desktop/mobile review and syntax-only echo fix are distinct from current motion-study evidence. |

Initial native rendering, 11 persisted choices and five shared friendly phase recipes are implemented in [merged PR #2](https://github.com/Emin-dev/Dot/pull/2) at [`6aa5b89`](https://github.com/Emin-dev/Dot/commit/6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc); [actual-renderer contact sheets](https://github.com/Emin-dev/Dot/blob/6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc/docs/verification/voice-and-native-skins.md) were reviewed. Current-player amplitude drives candidate speaking mouths; it is not phoneme alignment. PR #2 merged to main at [`f718e87`](https://github.com/Emin-dev/Dot/commit/f718e870cd14148c1b20c03c7adc822f9981bf31); the assembled candidate remains uninstalled and not hardware-accepted, and later main edits are outside that exact-source evidence. The full production animation library remains open. Each new skin requires at least **120 reviewed, visibly distinct, context-appropriate named animation recipes**, with trigger, duration, compatible states and cancellation behavior. Verify actual playback alignment and runtime performance separately; Cartesian-product counts alone do not complete the library. Preserve Original and its default behavior.

Record new decisions in the canonical checklist and publish them as discussed; distinguish delivered design artifacts, implementation, automated/native checks, installation and owner acceptance.
