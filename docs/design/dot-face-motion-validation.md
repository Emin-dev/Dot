# dot face motion study — validation

**Owner design acceptance:** the owner subsequently accepted the corrected preview and said “yes all good build app now.” This is design acceptance and continued implementation authorization, not a fresh browser technical pass or native/hardware acceptance. The rerun author checks and earlier browser-version limits below remain unchanged.

Design prototype only. No app source, installed app, microphone, speech engine, model, or repository was changed by this work.

## Ten selectable identities

1. Pearl — rounded pearl ceramic.
2. Mochi — rounded plush pebble.
3. Cloudlet — rounded sculpted cloud.
4. Pip — rounded little bird.
5. Dew — transparent glass bubble.
6. Ripple — transparent liquid droplet.
7. Sprout — sculptural leaf.
8. Veil — a more transparent clear lens, replacing Fold at the user's request.
9. Halo — flowing AI voice orb.
10. Nova — luminous AI visor.

The current original app design remains a separate retained option in the plan. All ten new identities are intended to be available from app Settings; choosing a face in this prototype records only a local design preference.

## Interactive coverage

- Ten activities: Idle, Listening, Thinking, Researching, Speaking, Working, Question, Success, Uncertain, Resting.
- Twelve expressions: Calm, Curious, Warm, Focused, Delighted, Playful, Surprised, Concerned, Determined, Apologetic, Tired, Proud.
- Every face offers all 120 activity/expression combinations. The rig changes eyes, brow position and angle, gaze, mouth width and height, head pose, cheeks, and applicable appendages.
- Opt-in motion adds breathing, blinking, small eye/head movement, researching scans, listening lean, working gestures, success movement, and eight articulated speaking mouth shapes.
- Activity remains explicitly labeled independently from expression.
- Motion is off on initial load, including restored saved state. Leaving a face stops its motion. Navigation does not start animation.

## Warmth and layout revision

The user requested that every face and situation remain smiling, warm, and friendly. This revision updates the same preview and keeps all activity and expression names.

- Replaced sharp solid eyebrow bars with relaxed arches. Left brows cannot turn downward toward the center; right brows cannot produce the corresponding glare. Removed the large animated asymmetric brow offsets.
- Replaced narrowed attentive/working eyes with fuller rounded eyes and added a second soft highlight. Resting still allows sleepy eyes and all states still blink.
- Every static combination now retains an upturned mouth, at least 27 units wide and 12 units high, with a rounded smile curve. Speaking uses eight rounded open/closed mouth poses rather than freezing in a smile.
- Focused, Determined, Concerned, and Apologetic now retain attentive or reassuring facial ranges. The truthful activity label remains visible independently of mood.
- New unsaved previews open with the Warm expression. Previously saved expressions keep their selected names and use the new friendly rendering.
- Lowered Sprout's leaf arms away from the mouth and brought its eyes and brows closer to the body center. Pip has a softer curved beak seam; Nova's eyes are rounded with gentler glow.
- Shortened action labels and made the two action buttons equal width. Selected-state text no longer lengthens the button. Retained face-specific accessible labels.
- Reduced excess stage height while preserving the large face. Added an explicit reserved status-label area and shorter footer labels, retaining equal heights across carousel variants.
- Kept the three glass treatments and Veil's almost clear material unchanged.

### Checks rerun after the warmth revision

- JavaScript syntax, all 1,200 configurations, 120 distinct painted parameter tuples per face, eight speaking poses, finite values, host-echo motion preservation, no initial autoplay, and Reduce Motion behavior passed again.
- New checks cover the actual composed and painted parameters for every combination: gentle brow directions, no narrowed awake eyes, smile width/height/curvature, and warm cheek ranges. Uniqueness checks exclude activity labels, so clamping did not silently collapse coverage.
- No fresh browser verification was possible for this correction. The browser inventory was empty, direct access to the user's known in-app preview URL reported the browser unavailable, and native access to the Codex app was blocked. No restriction was bypassed.
- The layout corrections address defects visible in the earlier screenshots and the source geometry. They still require a fresh visual pass at the user's actual window size and at 736, 390, and 320 px. Earlier screenshots and browser checks below apply to the pre-warmth revision, not proof that the revised appearance has been visually accepted.

## Earlier browser baseline and rig checks

- JavaScript parsed successfully.
- A deterministic harness executed the actual prototype script and drove the activity/expression event handlers across all ten faces: 1,200 configurations, with 120 distinct painted CSS parameter tuples per face. Labels were excluded from uniqueness checks. All values were finite and defined.
- Speaking produced eight distinct mouth width/height/open combinations. Animated gaze, head rotation, and vertical movement changed over time.
- The harness verified that a host state echo preserves explicitly enabled motion, initial restoration does not autoplay, and Reduce Motion disables the loop.
- In-app browser inspection confirmed all ten identities render and sample state/expression selections change the face and visible activity label.
- Browser inspection verified actual speaking movement, pause, local selection, and navigation without autoplay.
- Responsive browser checks of the earlier revision at 736 px, 390 px, and 320 px found no horizontal overflow. All ten faces' controls remained within their containers at both narrow widths; interactive controls at 390 px were at least 44 px high. The 320 px header height was equalized and rechecked after inspection.
- Veil was visually checked with the underlying window visible through the body. Its material is lighter and clearer than Dew.
- No browser console errors were observed during the functional review.

## What this does not prove

- These are 120 composed parameter combinations per face, not 120 individually authored or perceptually reviewed animation clips. Production acceptance still requires at least 120 reviewed, visibly distinct, context-appropriate named expression/animation recipes for every selected skin.
- The procedural motion study is a separate illustration from the realistic concept-art board. It does not animate the pixels in that board or claim to reproduce final production materials.
- Glass is illustrated with CSS transparency and backdrop effects; it is not Apple's native Liquid Glass implementation or physical refraction.
- The speaking cycle is silent and synthetic. It is not synchronized to Kokoro phonemes or real audio. Production speech alignment still needs implementation and validation.
- This is not a native rendering, energy, frame-time, or end-to-end voice-latency benchmark. Browser review was in the active dark appearance; the light appearance and OS-level Reduce Motion interaction were not visually tested. Reduce Motion logic was tested in the deterministic harness.

The authored prototype script makes no network requests and does not access the microphone, screen, files, or a model. **Export clarification:** the supplied standalone HTML wrapper loads optional presentation helpers from a CDN; opening the entire export can make those resource requests. This is not an offline-bundled export. No app implementation approval is inferred from a prototype button.
