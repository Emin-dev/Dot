import AppKit

/// The application owns one reusable surface. Menus and OS permission prompts are separate system UI.
@MainActor
final class CompanionPanel: NSPanel {
    var stopAction: (() -> Void)?
    var optionsAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { stopAction?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { stopAction?(); return }
        if event.keyCode == 109, event.modifierFlags.contains(.shift) { optionsAction?(); return }
        super.keyDown(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)) {
            keyDown(with: event); return
        }
        if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            makeKey(); optionsAction?(); return
        }
        if event.type == .leftMouseDown { makeKey() }
        super.sendEvent(event)
    }
    override func rightMouseDown(with event: NSEvent) { optionsAction?() }
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
