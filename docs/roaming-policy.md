# Conservative local placement

This is the implemented baseline as of 2026-10-17. The [movement checklist](BUILD_CHECKLIST.md#proactive-personality-movement-and-visual-design) still asks for a distinct tiny, slow local idle-motion fallback for the case where no safe route exists; its character-versus-panel form, speed/amplitude, cursor and accessibility behavior remain open, and zero overlap is not guaranteed by that exception. The rules below describe current behavior.

Idle roaming is periodic again, on the owner's agreed cadence: `AppDelegate.startIdleRoaming` in `src/App.swift` schedules a relocation **every 2 minutes** (120 seconds; it was 12–18 seconds until 2026-10-17, which moved far too often) while idle, and `performIdleRoam` moves the panel to a clear safe zone with a 3.2-second ease-in-ease-out glide. It runs only when the phase is `.idle`, the panel is visible, the menu is not tracking, no mouse button is down, and Dot is not pinned, hovered or interaction-paused; `RoamingCore.findRandomEmptySpace` rejects any target that would cover a protected region or the cursor, and if it finds no target the panel keeps its exact frame. The `RoamingCore` wander timer itself remains deliberately set to a disabled sentinel so the core cannot relocate on its own.

Roaming to a new clear spot follows the 2-minute idle cadence described above. Separately, Dot keeps its current position when the fresh local map is clear; if the map shows overlap it may make one short, deterministic, axis-aligned escape of at most 96 points over 0.6 seconds. The complete 148×156-point panel must end outside all protected regions. Its swept footprint cannot encounter new regions or increase overlap with existing ones. If no such route exists, Dot stays still; manual drag remains available.

Thinking does not schedule its own movement. Until 2026-10-17 Dot relocated every 5 seconds while `.thinking`;
the owner retired that after observing Dot move nonstop through long model loads and turns. Dot now keeps
its position through a turn and the 2-minute idle roam resumes when it is idle again. Necessary escape on
a covered map (line 7) is still allowed; there is no timed relocation while thinking.

The map protects entire visible non-Dot application/window rectangles, local Vision text rectangles, and high-contrast RGB image tiles (including their boundaries). All regions receive 12-point padding. Protecting whole windows deliberately sacrifices movement freedom: a full-screen app may leave no usable place. This is a conservative approximation, not a guarantee that all meaningful content has been identified. Initial launch/recall position is not content-certified; it is presented without waiting for analysis or asking for permission.

Placement analysis uses the existing persistent Screen context switch and existing macOS Screen Recording grant. It never requests permission. One analysis at most every 10 seconds runs only while ready, idle, unpinned, unhovered, not interacting, and after two seconds without mouse/key/scroll activity. One capture may be in flight; cancellation invalidates its result without creating a second overlapping task. A visible eye indicator remains during local analysis. Images are bounded to 2,097,152 pixels, processed locally, then discarded; only rectangles survive briefly. No OCR text, images, screen titles or window names are logged, saved, added to chat history or sent to Splash for placement.

A map expires after 10 seconds (`PlacementSnapshot.lifetime`); a refresh may already be in flight before
that, and its result replaces the old map without cancelling it. Every animation step rechecks permission,
input inactivity, the exact display/visible frame, onscreen window rectangles, map identity/freshness,
full-panel path and cursor exclusion. Input, menu, dragging, voice activity, Pin, screen opt-out,
app/Space/display changes, sleep/wake, VoiceOver and Reduce Motion invalidate or pause travel.
Missing/denied/uncertain/stale context leaves the frame exactly unchanged, even if it is outside a new
display's bounds; there is no unsensed automatic clamp. Explicit menu-bar recall brings an offscreen
companion back onto a current visible display without capturing the screen; it makes no content-safety
claim. Manual drag remains an independent recovery route.

Manual drag uses one AppKit pointer owner: displacement of at least 6 points latches dragging and prevents microphone activation, even after returning to the starting point. It may cross displays and clamps the whole panel to the destination visible frame. Manual placement imposes a 45-second autonomous rest. The three-second voice silence rule is unchanged.

Geometry uses AppKit points and fresh `NSScreen.visibleFrame`. Quartz window bounds are converted using the first screen's primary-display top, never keyboard-focus `NSScreen.main`. Vision boxes have a normalized lower-left origin; rendered raster rows are top-down. No backing-scale multiplier is applied twice. Pure fixtures cover negative/stacked displays and image scaling; the native synthetic-provider orientation probe confirms identity bitmap rendering preserves top-down rows; mixed-monitor behavior, actual capture, CPU cost and stale-content races require macOS acceptance. A changing screen can never be proven permanently empty from one frame.

Primary sources: [Quartz window coordinates](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds), [screen ordering](https://developer.apple.com/documentation/appkit/nsscreen/screens), [Vision bounds](https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox), [text detection](https://developer.apple.com/documentation/vision/vndetecttextrectanglesrequest), [single-frame capture](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager), [visible frame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe).
