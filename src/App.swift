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
    private let placement = PlacementCapture()
    private let voiceEnvironment = VoiceEnvironmentMonitor()
    private let historyPanel = ConversationHistoryPanel()
    private let typedPanel = TypedInteractionPanel()
    private let sourcePanel = SourceReferencePanel()
    private let researchPanel = ResearchPanel()
    private let actionPanel = NativeActionPanel()
    private var webResearchPanel: WebResearchPanel?
    private var visibleUtilities = Set<String>()
    private var terminating = false
    private var movement: Timer?
    private var statusItem: NSStatusItem?
    private var roam = RoamingCore(seed: UInt64.random(in: .min ... .max), now: ProcessInfo.processInfo.systemUptime)
    private var menuTracking = 0
    private var observations: [NSObjectProtocol] = []
    private var movementInterval = 0.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = ChatModel(); self.model = model
        let webResearch = WebResearchPanel(model: WebResearchModel(synthesize: { [weak model] session in
            guard let model else { throw CancellationError() }
            return try await model.engine.researchSynthesis(session: session)
        }))
        webResearchPanel = webResearch
        webResearch.onVisibility = { [weak self] in self?.utilityVisibility("webResearch", visible: $0) }
        model.onForegroundInteraction = { [weak webResearch] in webResearch?.foregroundPause() }
        historyPanel.onVisibility = { [weak self] in self?.utilityVisibility("history", visible: $0) }
        typedPanel.onVisibility = { [weak self] in self?.utilityVisibility("typed", visible: $0) }
        sourcePanel.onVisibility = { [weak self] in self?.utilityVisibility("source", visible: $0) }
        researchPanel.onVisibility = { [weak self] in self?.utilityVisibility("research", visible: $0) }
        actionPanel.onVisibility = { [weak self] in self?.utilityVisibility("actions", visible: $0) }
        voiceEnvironment.isActive = { [weak model] in model?.phase.isActive == true || model?.followupPending == true }
        voiceEnvironment.onChange = { [weak model, weak webResearch] reason in
            webResearch?.foregroundPause(); model?.cancelForEnvironment(reason: reason)
        }
        voiceEnvironment.start()
        placement.onCaptureChanged = { [weak model] active in model?.placementCapturing = active }
        model.placementInvalidated = { [weak self] in self?.cancelMovement() }
        let panel = surface.present(content: NSHostingView(rootView: PetView(model: model, stt: model.stt, tts: model.tts, skins: model.skinPreferences)), size: PetLayout.panelSize)
        panel.visibilityChanged = { [weak model, weak webResearch] visible in
            if !visible { webResearch?.foregroundPause() }; model?.visible = visible
        }
        panel.stopAction = { [weak self] in self?.stopCurrentAction() }
        panel.optionsAction = { [weak self] in self?.showOptions() }
        panel.primaryAction = { [weak model] in model?.clicked() }
        panel.primaryHitTest = { point in
            NSBezierPath(ovalIn: NSRect(x: (PetLayout.panelSize.width - PetLayout.petSize.width) / 2,
                                       y: PetLayout.petBottom, width: PetLayout.petSize.width,
                                       height: PetLayout.petSize.height)).contains(point)
        }
        panel.controlHitTest = { point in
            point.x >= 0 && point.x <= PetLayout.panelSize.width && point.y >= 0 && point.y < PetLayout.petBottom
        }
        panel.controlInteraction = { [weak self, weak model] active in
            model?.setControlInteraction(active)
            self?.cancelMovement()
        }
        panel.pointerInteraction = { [weak self, weak model] active in
            model?.interactionPaused = active
            self?.placement.invalidate()
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
        item.button?.toolTip = "Dot: Show, Options, Type or Quit"
        item.menu = CompanionStatusMenu.make(target: self, show: #selector(showPet), quit: #selector(quit),
            options: #selector(openOptions), type: #selector(typeMessage))
        statusItem = item
        observations.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.model?.cancelForInteraction(); self.menuTracking += 1; self.moveGently()
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
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelMovement() }
            })
        }
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak model, weak webResearch] _ in
            Task { @MainActor in webResearch?.foregroundPause(); model?.cancelForEnvironment(reason: .systemSleep) }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak model, weak webResearch] _ in
            Task { @MainActor in webResearch?.foregroundPause(); model?.visible = false }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.visible = true }
        })
        scheduleMovement(interval: 0.5)
        DotIntentRouter.shared.configure(talk: { [weak self] in
            guard let self, let model = self.model, OfflinePreparation.shared.ready, !self.terminating else { throw DotIntentError.unavailable }
            self.surface.recall(); model.clicked()
        }, stop: { [weak self] in
            guard let self, !self.terminating else { throw DotIntentError.unavailable }
            self.stopCurrentAction()
        }, show: { [weak self] in
            guard let self, !self.terminating else { throw DotIntentError.unavailable }
            self.showPet()
        })
    }

    private func utilityVisibility(_ name: String, visible: Bool) {
        if visible { visibleUtilities.insert(name) } else { visibleUtilities.remove(name) }
        model?.historyPresented = !visibleUtilities.isEmpty
    }

    private func scheduleMovement(interval: Double) {
        movement?.invalidate(); movementInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.moveGently() }
        }
        RunLoop.main.add(timer, forMode: .common); movement = timer
    }
    private func cancelMovement() { placement.invalidate(); roam.cancel(now: ProcessInfo.processInfo.systemUptime) }

    @objc private func showPet() { model?.cancelTurn(); model?.visible = true; cancelMovement(); surface.recall() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func stopCurrentAction() {
        cancelMovement()
        model?.stopCurrentTurn()
        sourcePanel.stop(); researchPanel.cancel(); webResearchPanel?.cancel(); actionPanel.stop()
        OfflinePreparation.shared.pause()
    }
    @objc private func talk() { model?.clicked() }
    @objc private func openOptions() { showOptions() }
    @objc private func typeMessage() {
        guard let model else { return }
        model.cancelForInteraction(); typedPanel.show(model: model)
    }
    @objc private func runActions() {
        model?.cancelForInteraction(); actionPanel.show()
    }
    @objc private func readResearch() {
        model?.cancelForInteraction(); researchPanel.show()
    }
    @objc private func runWebResearch() {
        model?.cancelForInteraction(); webResearchPanel?.show()
    }
    @objc private func readSource() {
        model?.cancelForInteraction(); sourcePanel.show()
    }
    @objc private func retryPreparation() { OfflinePreparation.shared.retry() }
    @objc private func togglePin() { model?.pinned.toggle() }
    @objc private func toggleScreen() { model?.screenEnabled.toggle() }
    @objc private func clearConversation() { model?.reset() }
    @objc private func copyDetails() {
        let summary = CompanionIssue.copiedDiagnostic(readiness: OfflinePreparation.shared.state, issue: model?.issue)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }
    @objc private func setSilence(_ sender: NSMenuItem) {
        model?.cancelTurn(); _ = model?.voiceTiming.setSilenceSeconds(Double(sender.tag))
    }
    @objc private func setInvitation(_ sender: NSMenuItem) {
        model?.cancelTurn(); _ = model?.voiceTiming.setInvitationSeconds(Double(sender.tag))
    }
    @objc private func readHistory() {
        guard let model else { return }
        model.cancelForInteraction(); historyPanel.show(model: model.textHistory)
    }
    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let skin = DotSkin(rawValue: value) else { return }
        model?.skinPreferences.selected = skin
    }
    @objc private func selectMotion(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let detail = SkinMotionDetail(rawValue: value) else { return }
        model?.skinPreferences.motionDetail = detail
    }
    private func showOptions() {
        guard let panel, let view = panel.contentView, let model else { return }
        model.dismissFirstUseHint(); model.cancelForInteraction(); panel.cancelPointerGesture(); cancelMovement(); panel.makeKey()
        let menu = NSMenu()
        let readiness = OfflinePreparation.shared.state
        let hasDetails = readiness.detail != nil || model.issue != nil
        if let header = CompanionIssue.menuHeader(readiness: readiness, issue: model.issue,
                                                   progress: OfflinePreparation.shared.progress) {
            let item = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); menu.addItem(.separator())
        }
        for action in CompanionMenuAction.available(readiness: readiness, busy: model.phase.isActive, hasDetails: hasDetails) {
            let title = action.title(busy: model.phase.isActive, pinned: model.pinned, issue: model.issue)
            let selector: Selector
            switch action {
            case .talk: selector = #selector(talk)
            case .stop: selector = #selector(stopCurrentAction)
            case .pause: selector = #selector(stopCurrentAction)
            case .retry: selector = #selector(retryPreparation)
            case .pin: selector = #selector(togglePin)
            case .screen: selector = #selector(toggleScreen)
            case .clear: selector = #selector(clearConversation)
            case .copyDetails: selector = #selector(copyDetails)
            case .quit: selector = #selector(quit)
            }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: action == .quit ? "q" : "")
            item.target = self
            if action == .screen { item.state = model.screenEnabled ? .on : .off }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let history = NSMenuItem(title: "Read local history…", action: #selector(readHistory), keyEquivalent: "")
        history.target = self; menu.addItem(history)
        let typed = NSMenuItem(title: "Type to Dot…", action: #selector(typeMessage), keyEquivalent: "t")
        typed.target = self; menu.addItem(typed)
        let source = NSMenuItem(title: "Read this version's source…", action: #selector(readSource), keyEquivalent: "")
        source.target = self; menu.addItem(source)
        let research = NSMenuItem(title: "Read sources and notebooks…", action: #selector(readResearch), keyEquivalent: "")
        research.target = self; menu.addItem(research)
        let webResearch = NSMenuItem(title: "Web research…", action: #selector(runWebResearch), keyEquivalent: "")
        webResearch.target = self; menu.addItem(webResearch)
        let actions = NSMenuItem(title: "Mac actions and receipts…", action: #selector(runActions), keyEquivalent: "")
        actions.target = self; menu.addItem(actions)
        menu.addItem(VoiceOptionsMenu.make(settings: model.voiceTiming, target: self,
            silence: #selector(setSilence(_:)), invitation: #selector(setInvitation(_:))))
        menu.addItem(AppearanceOptionsMenu.make(settings: model.skinPreferences, target: self,
            skin: #selector(selectSkin(_:)), motion: #selector(selectMotion(_:))))
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    private func moveGently() {
        guard let panel, let model else { return }
        let paused = !panel.isVisible || panel.isKeyWindow || model.hovered || model.interactionPaused
            || model.historyPresented || model.pinned || model.phase.isActive || model.followupPending || menuTracking > 0 || NSEvent.pressedMouseButtons != 0
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.isVoiceOverEnabled
        guard let screen = panel.screen, let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            cancelMovement(); return
        }
        let eligible = !paused && model.screenEnabled && model.phase == .idle && OfflinePreparation.shared.ready
        if !eligible { placement.invalidate() }
        let snapshot = eligible ? placement.current(screen: screen) : nil
        if eligible && snapshot == nil { placement.request(screen: screen, eligible: eligible) }
        let visible = screen.visibleFrame
        let origin = roam.step(frame: panel.frame, visible: visible, cursor: NSEvent.mouseLocation,
                               paused: !eligible, now: ProcessInfo.processInfo.systemUptime, displayID: displayID, snapshot: snapshot)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let interval = roam.isTravelling ? 1.0 / 60 : 0.5
        if interval != movementInterval { scheduleMovement(interval: interval) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true; sourcePanel.stop(); researchPanel.close(); webResearchPanel?.close(); actionPanel.closeAdmissions(); DotIntentRouter.shared.clear(); model?.beginShutdown()
        Task {
            await model?.textHistory.flush()
            await webResearchPanel?.model.flush()
            await actionPanel.model.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceEnvironment.stop(); movement?.invalidate(); placement.invalidate(); model?.shutdown()
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observations.removeAll()
        // No pkill, process-name matching, or shutdown of borrowed services.
    }
}
