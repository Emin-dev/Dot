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
    private var roam = RoamingCore(seed: UInt64.random(in: .min ... .max), now: ProcessInfo.processInfo.systemUptime)
    private var menuTracking = 0
    private var observations: [NSObjectProtocol] = []
    private var movementInterval = 0.5

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
        observations.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.menuTracking += 1; self.moveGently()
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.menuTracking = max(0, self.menuTracking - 1); self.moveGently()
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelMovement(); self?.moveGently() }
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelMovement(); self?.moveGently() }
        })
        scheduleMovement(interval: 0.5)
    }

    private func scheduleMovement(interval: Double) {
        movement?.invalidate(); movementInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.moveGently() }
        }
        RunLoop.main.add(timer, forMode: .common); movement = timer
    }
    private func cancelMovement() { roam.cancel(now: ProcessInfo.processInfo.systemUptime) }

    @objc private func showPet() { cancelMovement(); panel?.orderFrontRegardless() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func moveGently() {
        guard let panel, let model else { return }
        let paused = !panel.isVisible || model.hovered || model.bubbleHovered || model.interactionPaused
            || model.pinned || model.phase.isActive || menuTracking > 0 || NSEvent.pressedMouseButtons != 0
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.isVoiceOverEnabled
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let origin = roam.step(frame: panel.frame, visible: visible, cursor: NSEvent.mouseLocation,
                               paused: paused, now: ProcessInfo.processInfo.systemUptime)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let interval = roam.isTravelling ? 1.0 / 60 : 0.5
        if interval != movementInterval { scheduleMovement(interval: interval) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        movement?.invalidate(); model?.shutdown()
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observations.removeAll()
        // No pkill, process-name matching, or shutdown of borrowed services.
    }
}
