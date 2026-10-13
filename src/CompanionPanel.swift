import AppKit

/// The application owns one reusable surface. Menus and OS permission prompts are separate system UI.
@MainActor
final class CompanionPanel: NSPanel {
    var stopAction: (() -> Void)?
    var optionsAction: (() -> Void)?
    var primaryAction: (() -> Void)?
    var primaryHitTest: ((NSPoint) -> Bool)?
    var pointerInteraction: ((Bool) -> Void)?
    var constrainDrag: ((NSPoint, NSPoint) -> NSPoint)?
    var visibilityChanged: ((Bool) -> Void)?
    private var pointer = CompanionDragState()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    func cancelPointerGesture() {
        let wasPressed = pointer.isPressed; pointer.cancel()
        if wasPressed { pointerInteraction?(false) }
    }
    private func openOptions() { cancelPointerGesture(); optionsAction?() }
    override func cancelOperation(_ sender: Any?) { cancelPointerGesture(); stopAction?() }
    override func resignKey() { cancelPointerGesture(); super.resignKey() }
    override func close() { cancelPointerGesture(); visibilityChanged?(false); super.close() }
    override func orderOut(_ sender: Any?) { visibilityChanged?(false); super.orderOut(sender) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 109, event.modifierFlags.contains(.shift) { openOptions(); return }
        super.keyDown(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)) {
            keyDown(with: event); return
        }
        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            cancelPointerGesture(); makeKey(); openOptions(); return
        }
        if event.type == .leftMouseDown {
            cancelPointerGesture()
            guard primaryHitTest?(event.locationInWindow) == true else { return }
            makeKey()
            pointer.begin(point: convertPoint(toScreen: event.locationInWindow), origin: frame.origin)
            pointerInteraction?(true); return
        }
        if event.type == .leftMouseDragged {
            let point = convertPoint(toScreen: event.locationInWindow)
            if let origin = pointer.update(point: point) {
                setFrameOrigin(constrainDrag?(origin, point) ?? origin)
            }
            return
        }
        if event.type == .leftMouseUp {
            let wasPressed = pointer.isPressed
            let click = pointer.release(point: convertPoint(toScreen: event.locationInWindow),
                                        inside: primaryHitTest?(event.locationInWindow) == true)
            if wasPressed { pointerInteraction?(false) }
            if click { primaryAction?() }
            return
        }
        super.sendEvent(event)
    }
    override func rightMouseDown(with event: NSEvent) { openOptions() }
}

@MainActor
final class CompanionSurface {
    private(set) var panel: CompanionPanel?
    @discardableResult
    func present(content: NSView, size: NSSize) -> CompanionPanel {
        let window: CompanionPanel
        if let panel { window = panel }
        else {
            window = CompanionPanel(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("dot.companion")
            window.title = "Dot companion"
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.level = .floating; window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false; window.becomesKeyOnlyIfNeeded = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = window
        }
        window.contentView = content; window.orderFrontRegardless()
        return window
    }
    func recall(visibleFrames: [CGRect]? = nil) {
        guard let panel else { return }
        let frames = visibleFrames ?? NSScreen.screens.map { $0.visibleFrame }
        // Explicit recall is a user-requested visibility recovery, never a claim of sensed empty content.
        if !frames.contains(where: { $0.contains(panel.frame) }), let visible = frames.first {
            if let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: visible) {
                panel.setFrameOrigin(RoamingCore.clamp(panel.frame.origin, to: bounds))
            } else if PlacementSnapshot.validRect(visible) {
                panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }
}


@MainActor
enum CompanionStatusMenu {
    static func make(target: AnyObject, show: Selector, quit: Selector) -> NSMenu {
        let menu = NSMenu()
        let recall = NSMenuItem(title: "Show Dot", action: show, keyEquivalent: "")
        recall.target = target; menu.addItem(recall)
        menu.addItem(.separator())
        let exit = NSMenuItem(title: "Quit Dot", action: quit, keyEquivalent: "q")
        exit.target = target; menu.addItem(exit)
        return menu
    }
}

/// Native menu controls keep the companion's single-surface design.
@MainActor
enum VoiceOptionsMenu {
    static func make(settings: VoiceTimingSettings, target: AnyObject, silence: Selector, invitation: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "Voice settings", action: nil, keyEquivalent: "")
        let menu = NSMenu(); item.submenu = menu
        for (title, choices, selected, action) in [
            ("Silence before responding", VoiceTimingSettings.silenceChoices, settings.silenceSeconds, silence),
            ("Time to begin a reply", VoiceTimingSettings.invitationChoices, settings.invitationSeconds, invitation)
        ] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""), options = NSMenu()
            parent.submenu = options
            for seconds in choices {
                let choice = NSMenuItem(title: "\(Int(seconds)) seconds", action: action, keyEquivalent: "")
                choice.tag = Int(seconds); choice.target = target; choice.state = seconds == selected ? .on : .off
                options.addItem(choice)
            }
            menu.addItem(parent)
        }
        let hint = NSMenuItem(title: "Reply time limits when speech starts, not its length", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        return item
    }
}


@MainActor
enum AppearanceOptionsMenu {
    static func make(settings: SkinPreferences, target: AnyObject, skin: Selector, motion: Selector) -> NSMenuItem {
        let root = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: ""), menu = NSMenu()
        for value in DotSkin.allCases {
            let item = NSMenuItem(title: value.displayName, action: skin, keyEquivalent: "")
            item.target = target; item.representedObject = value.rawValue
            item.state = settings.selected == value ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let detail = NSMenuItem(title: "Animation detail", action: nil, keyEquivalent: ""), choices = NSMenu()
        for value in SkinMotionDetail.allCases {
            let item = NSMenuItem(title: value.displayName, action: motion, keyEquivalent: "")
            item.target = target; item.representedObject = value.rawValue
            item.state = settings.motionDetail == value ? .on : .off; choices.addItem(item)
        }
        detail.submenu = choices; menu.addItem(detail); root.submenu = menu; return root
    }
}
