# dot design artifacts

The owner reviewed the directions, selected all ten new skins alongside Original, and authorized building the checklist in tested stages. The earlier hold and first-voice-only implementation limit are superseded. Begin with voice and a separate reviewable native skin/settings batch; no repeat start/theme approval is needed. Installation remains separate. See the [canonical checklist](../BUILD_CHECKLIST.md#design-comparison-prepared-for-discussion).

**Native Settings choices: Original plus ten new skins = 11 choices. Original remains default until changed.** The new lineup is Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo and Nova. Veil replaces Fold at position 8: a thin, nearly invisible transparent bubble/lens like Dew but more transparent, with a sparse face, faint rim and visible backdrop. The split is **4 rounded / 3 glass / 1 Sprout / 2 AI**.

## Current delivered artifacts

| Artifact | Status and scope |
| --- | --- |
| **[V3 concept board](dot-face-directions-v3.png)** | Delivered generated concept art showing the approved Veil-inclusive lineup. Not native app screenshots or implemented skins. |
| [V3 generation prompt](dot-face-directions-v3-prompt.txt) | Preserved unchanged; records the intended local Fold-to-Veil edit. Prompt instructions are provenance, not proof that all other pixels are identical. |
| **[Interactive motion study](dot-face-motion-directions.html)** | Delivered standalone HTML. [Download](https://raw.githubusercontent.com/Emin-dev/Dot/main/docs/design/dot-face-motion-directions.html), save and open in a browser; GitHub file view shows source. Silent procedural design exploration, not native UI or real audio alignment. |
| [Motion validation report](dot-face-motion-validation.md) | Supplied handler/browser evidence and limits, with a publication clarification that optional wrapper helpers use a CDN. |

The report records **1,200** actual activity/expression event-handler configurations and **120 distinct painted CSS parameter tuples per face**, excluding labels from uniqueness checks. It also records eight synthetic speaking-mouth shapes, state-echo preservation, no autoplay and deterministic Reduce Motion handling. Actual browser review covered all ten faces at 736, 390 and 320 px with interaction, pause, local selection, no navigation autoplay and no horizontal overflow. Dark appearance was reviewed; light appearance and OS-level Reduce Motion were not visually tested.

Those checks do not establish 120 individually authored or perceptually reviewed production animations, real Kokoro phonemes, Apple's native Liquid Glass, frame-time/energy behavior or end-to-end voice speed. The motion study is procedural artwork, not animation of the concept-board pixels. The authored study has no model/microphone/screen/research access; the exported wrapper loads optional CDN presentation helpers and is not fully offline-bundled.

## Historical artifacts

| Artifact | Status and scope |
| --- | --- |
| [V2 concept board](dot-face-directions-v2.png) | Historical pre-Veil artwork: position 8 still depicts the replaced Fold. Not the current final lineup. |
| [V2 generation prompt](dot-face-directions-v2-prompt.txt) | Preserved unchanged with Fold and the superseded 4/2/2/2 split as provenance. |
| [First interactive preview](dot-ui-options.html) | Historical exploratory shortlist. Illustrative silent motion with optional CDN helpers. Its older desktop/mobile review and syntax-only echo fix are distinct from current motion-study evidence. |

Native rendering and production animation still need implementation. Each new skin requires at least **120 reviewed, visibly distinct, context-appropriate named animation recipes**, with trigger, duration, compatible states and cancellation behavior. Verify actual playback alignment and runtime performance separately; Cartesian-product counts alone do not complete the library. Preserve Original and its default behavior.

Record new decisions in the canonical checklist and publish them as discussed; distinguish delivered design artifacts, implementation, automated/native checks, installation and owner acceptance.
