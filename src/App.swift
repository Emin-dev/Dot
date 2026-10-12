import SwiftUI
import AppKit

@main
struct DotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PetPanel?
    private var model: ChatModel?
    private var movement: Timer?
    private var statusItem: NSStatusItem?
    private var tickCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = ChatModel(); self.model = model
        let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PetView(model: model, stt: model.stt))
        self.panel = panel
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 350, y: frame.minY + 12))
        }
        panel.orderFrontRegardless()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Dot")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Dot", action: #selector(showPet), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Dot", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }; item.menu = menu; statusItem = item
        movement = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.moveGently() }
        }
    }

    @objc private func showPet() { panel?.orderFrontRegardless() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func moveGently() {
        guard let panel, let model,
              !model.hovered, !model.bubbleHovered, !model.interactionPaused, !model.pinned, !model.phase.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !NSWorkspace.shared.isVoiceOverEnabled else { return }
        tickCount += 1
        let frame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let mouse = NSEvent.mouseLocation
        // The character is at the bottom center of the transparent panel.
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.minY + 90)
        let distance = hypot(mouse.x - center.x, mouse.y - center.y)
        var origin = panel.frame.origin
        if distance < 120, distance > 75 {
            origin.x += mouse.x < center.x ? 1.8 : -1.8
        } else if tickCount % 8 == 0 {
            origin.x += sin(Double(tickCount) * 0.028) * 0.8
        }
        origin.x = min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - panel.frame.width))
        origin.y = min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }

    func applicationWillTerminate(_ notification: Notification) {
        movement?.invalidate(); model?.shutdown()
        // No pkill, process-name matching, or shutdown of borrowed services.
    }
}
