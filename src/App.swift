import SwiftUI
import AppKit

@main
struct DotApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let surface = CompanionSurface()
    private var panel: CompanionPanel? { surface.panel }
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
        let panel = surface.present(content: NSHostingView(rootView: PetView(model: model, stt: model.stt)), size: PetLayout.panelSize)
        panel.stopAction = { [weak self] in self?.stopCurrentAction() }
        panel.optionsAction = { [weak self] in self?.showOptions() }
        panel.primaryAction = { [weak model] in model?.clicked() }
        panel.primaryHitTest = { point in
            NSBezierPath(ovalIn: NSRect(x: (PetLayout.panelSize.width - PetLayout.petSize.width) / 2,
                                       y: PetLayout.petBottom, width: PetLayout.petSize.width,
                                       height: PetLayout.petSize.height)).contains(point)
        }
        panel.pointerInteraction = { [weak self, weak model] active in
            model?.interactionPaused = active
            self?.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: !active)
        }
        panel.constrainDrag = { [weak panel] origin, cursor in
            guard let panel else { return origin }
            let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? panel.screen ?? NSScreen.main
            guard let screen, let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: screen.visibleFrame) else { return panel.frame.origin }
            return RoamingCore.clamp(origin, to: bounds)
        }
        model.showOptions = { [weak self] in self?.showOptions() }
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - PetLayout.panelSize.width - 16, y: frame.minY + 16))
        }
        panel.orderFrontRegardless()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Dot")
        item.button?.action = #selector(showPet); item.button?.target = self
        statusItem = item
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

    @objc private func showPet() { cancelMovement(); surface.recall() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func stopCurrentAction() {
        if model?.phase.isActive == true { model?.cancelTurn() }
        OfflinePreparation.shared.pause()
    }
    @objc private func talk() { model?.clicked() }
    @objc private func retryPreparation() { OfflinePreparation.shared.retry() }
    @objc private func togglePin() { model?.pinned.toggle() }
    @objc private func toggleScreen() { model?.screenEnabled.toggle() }
    @objc private func clearConversation() { model?.reset() }
    private func showOptions() {
        guard let panel, let view = panel.contentView, let model else { return }
        panel.cancelPointerGesture(); cancelMovement(); panel.makeKey()
        let menu = NSMenu()
        if let message = OfflinePreparation.shared.state.detail {
            let item = NSMenuItem(title: String(message.prefix(160)), action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); menu.addItem(.separator())
        } else if case .blocked(let message) = model.phase {
            let item = NSMenuItem(title: String(message.prefix(160)), action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); menu.addItem(.separator())
        }
        for action in CompanionMenuAction.available(readiness: OfflinePreparation.shared.state, busy: model.phase.isActive) {
            let title: String, selector: Selector
            switch action {
            case .talk: title = model.phase.isActive ? "Interrupt and listen" : "Talk"; selector = #selector(talk)
            case .stop: title = "Stop"; selector = #selector(stopCurrentAction)
            case .pause: title = "Pause file check"; selector = #selector(stopCurrentAction)
            case .retry: title = "Retry file check"; selector = #selector(retryPreparation)
            case .pin: title = model.pinned ? "Roam" : "Pin here"; selector = #selector(togglePin)
            case .screen: title = "Screen context"; selector = #selector(toggleScreen)
            case .clear: title = "Clear conversation"; selector = #selector(clearConversation)
            case .quit: title = "Quit Dot"; selector = #selector(quit)
            }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: action == .quit ? "q" : "")
            item.target = self
            if action == .screen { item.state = model.screenEnabled ? .on : .off }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    private func moveGently() {
        guard let panel, let model else { return }
        let paused = !panel.isVisible || panel.isKeyWindow || model.hovered || model.bubbleHovered || model.interactionPaused
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
