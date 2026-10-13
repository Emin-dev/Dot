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
    override func close() { cancelPointerGesture(); super.close() }
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
    func recall() { panel?.makeKeyAndOrderFront(nil) }
}
