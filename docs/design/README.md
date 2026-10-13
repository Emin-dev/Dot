# dot design artifacts

The owner reviewed and liked all ten directions and confirmed continuation of the first voice batch. The earlier preview-before-build hold is resolved; no repeat approval is needed. Native skin UI is a separate batch after the revised preview and shared interfaces are stable. Installation remains separate. See the [canonical checklist](../BUILD_CHECKLIST.md#design-comparison-prepared-for-discussion).

**Accepted future native Settings choices: Original plus ten new skins = 11 choices. Original remains default until changed.** The new lineup is Pearl, Mochi, Cloudlet, Pip, Dew, Ripple, Sprout, Veil, Halo and Nova. Veil replaces Fold at position 8: a thin, nearly invisible transparent bubble/lens like Dew but more transparent, with a sparse face, faint rim and visible backdrop; no fox or folded-paper shape. The split is **4 rounded / 3 glass / 1 Sprout / 2 AI**.

| Artifact | Status and scope |
| --- | --- |
| [Historical v2 concept board](dot-face-directions-v2.png) | Complete, inspected and shown to the owner. **Pre-Veil concept art: position 8 still depicts Fold, now superseded.** Not the final lineup or a screenshot of an implemented app. |
| [Historical v2 generation prompt](dot-face-directions-v2-prompt.txt) | Preserved byte-for-byte as provenance for that board, including the superseded Fold and 4/2/2/2 split; not the current implementation requirement. |
| Revised v3 concept board | Pending delivery; must include Veil replacing Fold. Do not claim a completed export or validation. |
| Revised interactive motion study | Pending delivery/export and validation. Proposed 10 states × 12 presets = 120 selectable combinations per face are not 120 individually authored clips, a production library or real speech synchronization. |
| [First interactive preview](dot-ui-options.html) | Historical exploratory shortlist, superseded by later directions. Save HTML and open in a browser. Illustrative silent motion; optional CDN helpers. Prior desktop/mobile checks and later syntax-only fix do not establish current native app behavior. |

Native glass and animation remain future implementation. Each **new skin** requires at least **120 reviewed, visibly distinct, context-appropriate named animation recipes**, with trigger, duration, compatible states and cancellation behavior. Validate actual playback alignment and runtime performance separately. Cartesian-product counts alone do not satisfy the library requirement. Preserve Original and its default behavior while developing the additional choices.

Record new feature decisions in the canonical checklist and publish them as discussed; link new artifacts here only after delivery, with their actual validation limits.
