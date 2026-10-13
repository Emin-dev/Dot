# dot face motion study — validation

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

## Checks completed

- JavaScript parsed successfully.
- A deterministic harness executed the actual prototype script and drove the activity/expression event handlers across all ten faces: 1,200 configurations, with 120 distinct painted CSS parameter tuples per face. Labels were excluded from uniqueness checks. All values were finite and defined.
- Speaking produced eight distinct mouth width/height/open combinations. Animated gaze, head rotation, and vertical movement changed over time.
- The harness verified that a host state echo preserves explicitly enabled motion, initial restoration does not autoplay, and Reduce Motion disables the loop.
- In-app browser inspection confirmed all ten identities render and sample state/expression selections change the face and visible activity label.
- Browser inspection verified actual speaking movement, pause, local selection, and navigation without autoplay.
- Responsive browser checks at 736 px, 390 px, and 320 px found no horizontal overflow. All ten faces' controls remained within their containers at both narrow widths; interactive controls at 390 px were at least 44 px high. The 320 px header height was equalized after inspection.
- Veil was visually checked with the underlying window visible through the body. Its material is lighter and clearer than Dew.
- No browser console errors were observed during the functional review.

## What this does not prove

- These are 120 composed parameter combinations per face, not 120 individually authored or perceptually reviewed animation clips. Production acceptance still requires at least 120 reviewed, visibly distinct, context-appropriate named expression/animation recipes for every selected skin.
- The procedural motion study is a separate illustration from the realistic concept-art board. It does not animate the pixels in that board or claim to reproduce final production materials.
- Glass is illustrated with CSS transparency and backdrop effects; it is not Apple's native Liquid Glass implementation or physical refraction.
- The speaking cycle is silent and synthetic. It is not synchronized to Kokoro phonemes or real audio. Production speech alignment still needs implementation and validation.
- This is not a native rendering, energy, frame-time, or end-to-end voice-latency benchmark. Browser review was in the active dark appearance; the light appearance and OS-level Reduce Motion interaction were not visually tested. Reduce Motion logic was tested in the deterministic harness.

The authored prototype script makes no network requests and does not access the microphone, screen, files, or a model. **Export clarification:** the supplied standalone HTML wrapper loads optional presentation helpers from a CDN; opening the entire export can therefore make those resource requests. This is not an offline-bundled export. No app implementation approval is inferred from a prototype button.
