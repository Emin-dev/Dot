# Companion roaming policy

The new source replaces narrow horizontal drift with seeded, bounded wandering within the current display. It selects varied 3×3 cells/edge destinations after 8–18-second idle intervals, remembers the last three target cells, and uses 2.5–7-second eased trips. These are tunable design hypotheses, not measured UX optima. It does not switch Spaces, activate windows, warp the cursor or cross monitor gaps.

NSScreen.visibleFrame is refreshed each tick. The complete panel stays within a 16-point margin; a too-small display disables wandering. Display changes cancel the old trajectory. Negative screen origins are supported. A long wake interval is clamped to avoid a giant animation jump.

Hovering the pet or its visible bubble, interacting with menus/popovers, pressed mouse buttons, voice activity, Pin, VoiceOver and Reduce Motion pause travel immediately. Approaching the visible pet stops it rather than making it flee a click. Planned paths crossing a 120-point cursor exclusion zone are rejected, as are destinations within 180 points. No screen-content sensing is used: Dot cannot claim to know which document/control it is avoiding.

The timer runs at 60 Hz only while travelling and 2 Hz while idle/paused. Menu-bar recall remains. This patch does not add manual drag, automatic inter-display travel, persistent display positions or new screen/Accessibility permissions.

Apple sources: [visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe), [screen changes](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification), [cursor coordinates](https://developer.apple.com/documentation/appkit/nsevent/mouselocation), [Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion), [accessibility changes](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification), [menu tracking](https://developer.apple.com/documentation/appkit/nsmenu/didbegintrackingnotification).

Pure seeded tests cover geometry, variety, pause/release, approaching-pointer stop, stale trajectory cancellation and long-wake bounds. Interactive Mac observation is still required, especially transparent-panel hit testing and actual Dock/display changes.
