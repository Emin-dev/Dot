import SwiftUI
import AppKit
import QuartzCore

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
    private let researchPanel = ResearchPanel(model: ResearchNotebookModel(webReader: OfflinePayload.sourceReader()))
    private let actionPanel = NativeActionPanel()
    private var webResearchPanel: WebResearchPanel?
    private var visibleUtilities = Set<String>()
    private var terminating = false
    private var movement: Timer?
    private var thinkingRelocationTimer: Timer?
    private var idleRoamTimer: Timer?
    private var statusItem: NSStatusItem?
    private var roam = RoamingCore(seed: UInt64.random(in: .min ... .max), now: ProcessInfo.processInfo.systemUptime, initialWanderDelay: 8.0)
    private var menuTracking = 0
    private var observations: [NSObjectProtocol] = []
    private var movementInterval = 0.5
    private var documentWorker: WatchedDocumentWorker?
    private var activityAssertion: NSObjectProtocol?
    private var keyMonitor: Any?
    private var flagsMonitorGlobal: Any?
    private var flagsMonitorLocal: Any?
    private var fnKeyDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HardwareCompatibility.verifyOnLaunch() else { return }
        NSApp.setActivationPolicy(.accessory)
        DiagnosticChatLogger.record(role: "system", text: "Dot application started")
        activityAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Dot desktop pet simulation and responsive voice"
        )
        let model = ChatModel(); self.model = model
        let docWorker = WatchedDocumentWorker(ftsStore: model.ftsStore)
        self.documentWorker = docWorker
        let searchProvider = LocalDotSearchProvider()
        let webResearch = WebResearchPanel(model: WebResearchModel(provider: searchProvider, reader: OfflinePayload.sourceReader(), synthesize: { [weak model] session in
            guard let model else { throw CancellationError() }
            return try await model.engine.researchSynthesis(session: session)
        }))
        webResearchPanel = webResearch
        webResearch.model.onTaskProgress = { [weak model] event in
            model?.handleTaskProgress(event)
        }
        model.onExecuteAction = { [weak self] action in
            guard let self, !self.terminating else { return nil }
            if self.actionPanel.model.documentRoot == nil {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                let docDir = support?.appendingPathComponent("Dot/Documents", isDirectory: true)
                if let docDir {
                    try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
                    _ = await self.actionPanel.model.selectFolder(docDir)
                }
            }
            return await self.actionPanel.model.execute(action)
        }
        model.onRequestResearch = { [weak self] query in
            guard let self, !self.terminating else { return }
            self.webResearchPanel?.show()
            self.webResearchPanel?.model.question = query
            self.webResearchPanel?.model.start()
        }
        model.startProactivity()
        webResearch.onVisibility = { [weak self] in self?.utilityVisibility("webResearch", visible: $0) }
        model.onForegroundInteraction = { [weak webResearch] in webResearch?.foregroundPause() }
        historyPanel.onVisibility = { [weak self] in self?.utilityVisibility("history", visible: $0) }
        typedPanel.onVisibility = { [weak self] in self?.utilityVisibility("typed", visible: $0) }
        sourcePanel.onVisibility = { [weak self] in self?.utilityVisibility("source", visible: $0) }
        researchPanel.onVisibility = { [weak self] in self?.utilityVisibility("research", visible: $0) }
        actionPanel.onVisibility = { [weak self] in self?.utilityVisibility("actions", visible: $0) }
        voiceEnvironment.isActive = { [weak model] in model?.phase.isActive == true }
        voiceEnvironment.onChange = { [weak model, weak webResearch] reason in
            webResearch?.foregroundPause(); model?.cancelForEnvironment(reason: reason)
        }
        voiceEnvironment.start()
        placement.onCaptureChanged = { [weak model] active in model?.placementCapturing = active }
        model.placementInvalidated = { [weak self] in self?.cancelMovement() }
        model.onPhaseChanged = { [weak self] newPhase in
            self?.handlePhaseChanged(newPhase)
        }
        model.onMove = { [weak self] command in
            guard let self, let panel = self.panel else { return nil }
            guard let screen = panel.screen ?? NSScreen.main else { return nil }
            let visible = screen.visibleFrame
            guard let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: visible) else { return nil }
            let current = panel.frame.origin
            let margin: CGFloat = 20
            let stepDistance: CGFloat = 260

            let target: CGPoint
            let reply: String

            switch command {
            case .left:
                target = RoamingCore.clamp(CGPoint(x: current.x - stepDistance, y: current.y), to: bounds)
                reply = "Moving to the left."
            case .right:
                target = RoamingCore.clamp(CGPoint(x: current.x + stepDistance, y: current.y), to: bounds)
                reply = "Moving to the right."
            case .up:
                target = RoamingCore.clamp(CGPoint(x: current.x, y: current.y + stepDistance), to: bounds)
                reply = "Moving up."
            case .down:
                target = RoamingCore.clamp(CGPoint(x: current.x, y: current.y - stepDistance), to: bounds)
                reply = "Moving down."
            case .topLeft:
                target = CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin)
                reply = "Moving to the top left."
            case .topRight:
                target = CGPoint(x: bounds.maxX - margin, y: bounds.maxY - margin)
                reply = "Moving to the top right."
            case .bottomLeft:
                target = CGPoint(x: bounds.minX + margin, y: bounds.minY + margin)
                reply = "Moving to the bottom left."
            case .bottomRight:
                target = CGPoint(x: bounds.maxX - margin, y: bounds.minY + margin)
                reply = "Moving to the bottom right."
            case .center:
                target = CGPoint(x: bounds.midX, y: bounds.midY)
                reply = "Centering myself on the screen."
            case .away:
                let cursor = NSEvent.mouseLocation
                let center = CGPoint(x: current.x + panel.frame.width / 2, y: current.y + panel.frame.height / 2)
                let dx = center.x - cursor.x
                let dy = center.y - cursor.y
                let dist = hypot(dx, dy)
                if dist > 1 {
                    let moveX = (dx / dist) * 320
                    let moveY = (dy / dist) * 320
                    target = RoamingCore.clamp(CGPoint(x: current.x + moveX, y: current.y + moveY), to: bounds)
                } else {
                    target = CGPoint(x: current.x > bounds.midX ? bounds.minX + margin : bounds.maxX - margin, y: current.y)
                }
                reply = "Stepping out of the way!"
            case .random:
                let snap = self.placement.current(screen: screen) ?? self.placement.fastWindowSnapshot(screen: screen)
                let protectedRegions = snap?.protected ?? []
                let cursor = NSEvent.mouseLocation
                if let safeSpot = RoamingCore.findRandomEmptySpace(frame: panel.frame, bounds: bounds, cursor: cursor, regions: protectedRegions, minDistance: 160) {
                    target = safeSpot
                } else {
                    let spots: [CGPoint] = [
                        CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin),
                        CGPoint(x: bounds.maxX - margin, y: bounds.maxY - margin),
                        CGPoint(x: bounds.minX + margin, y: bounds.minY + margin),
                        CGPoint(x: bounds.maxX - margin, y: bounds.minY + margin),
                        CGPoint(x: bounds.midX, y: bounds.midY),
                        CGPoint(x: bounds.minX + margin, y: bounds.midY),
                        CGPoint(x: bounds.maxX - margin, y: bounds.midY)
                    ]
                    let farSpots = spots.filter { hypot($0.x - current.x, $0.y - current.y) >= 160 }
                    target = farSpots.randomElement() ?? spots.max(by: { hypot($0.x - current.x, $0.y - current.y) < hypot($1.x - current.x, $1.y - current.y) }) ?? current
                }
                reply = "Relocating to a new spot!"
            }

            self.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: false)
            let targetFrame = NSRect(origin: target, size: panel.frame.size)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.65
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: {
                panel.setFrameOrigin(target)
            })
            self.scheduleMovement(interval: 0.5)
            return reply
        }
        let panel = surface.present(content: NSHostingView(rootView: PetView(model: model, stt: model.stt, tts: model.tts, skins: model.skinPreferences)), size: PetLayout.panelSize)
        panel.visibilityChanged = { [weak model, weak webResearch] visible in
            if !visible { webResearch?.foregroundPause() }; model?.visible = visible
        }
        panel.stopAction = { [weak self] in self?.stopCurrentAction() }
        panel.optionsAction = { [weak self] in self?.showOptions() }
        panel.primaryAction = { [weak model] in model?.clicked() }
        panel.secondaryAction = { [weak self] in self?.typeMessage() }
        panel.onFileDropped = { [weak self] url in
            guard let self, !self.terminating else { return }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let docDir = support?.appendingPathComponent("Dot/Documents", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            let destURL = docDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: url, to: destURL)
                Task { @MainActor in
                    self.model?.speakDirect("I have indexed \(url.lastPathComponent). Ask me anything about it!")
                    await self.documentWorker?.scanAndMaintainBrief()
                }
            } catch {
                // Fallback
            }
        }
        panel.primaryHitTest = { point in
            NSBezierPath(ovalIn: NSRect(x: (PetLayout.panelSize.width - PetLayout.petSize.width) / 2,
                                       y: PetLayout.petBottom, width: PetLayout.petSize.width,
                                       height: PetLayout.petSize.height)).contains(point)
        }
        panel.controlHitTest = { _ in false }
        panel.controlInteraction = { [weak self, weak model] active in
            model?.setControlInteraction(active)
            self?.cancelMovement()
        }
        panel.pointerInteraction = { [weak self, weak model] active in
            model?.interactionPaused = active
            self?.placement.invalidate()
            self?.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: false)
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
        let appEvents = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for event in appEvents {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWindowOrAppChange() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
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
        placement.onSnapshotUpdated = { [weak self] snapshot in
            guard let self, let panel = self.panel, let model = self.model,
                  model.screenEnabled, !model.pinned, model.phase == .idle else { return }
            guard let screen = panel.screen else { return }
            let frame = panel.frame
            if !RoamingCore.clear(frame, regions: snapshot.protected) {
                let origin = self.roam.evadeToEmptySpace(frame: frame, visible: screen.visibleFrame,
                                                         cursor: NSEvent.mouseLocation,
                                                         now: ProcessInfo.processInfo.systemUptime,
                                                         displayID: snapshot.displayID,
                                                         snapshot: snapshot)
                if origin != frame.origin {
                    panel.setFrameOrigin(origin)
                }
                self.scheduleMovement(interval: 1.0 / 60)
            }
        }
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
        documentWorker?.start()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 && event.modifierFlags.contains(.option) {
                self?.typeMessage()
                return nil
            }
            return event
        }
        startIdleRoaming()
        setupPushToTalk()
    }

    private func setupPushToTalk() {
        flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        flagsMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard UserDefaults.standard.bool(forKey: "dot.pushToTalkDisabled") != true else { return }
        let isFn = event.modifierFlags.contains(.function)
        if isFn && !fnKeyDown {
            fnKeyDown = true
            model?.beginPushToTalk()
        } else if !isFn && fnKeyDown {
            fnKeyDown = false
            model?.finishPushToTalk()
        }
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

    @objc private func showPet() { stopThinkingRelocation(); model?.cancelTurn(); model?.visible = true; cancelMovement(); surface.recall() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func stopCurrentAction() {
        stopThinkingRelocation()
        cancelMovement()
        model?.stopCurrentTurn()
        sourcePanel.stop(); researchPanel.cancel(); webResearchPanel?.cancel(); actionPanel.stop()
        OfflinePreparation.shared.pause()
    }
    @objc private func talk() { model?.clicked() }
    @objc private func openOptions() { showOptions() }
    @objc private func typeMessage() {
        guard let model else { return }
        model.cancelForInteraction(); typedPanel.show(model: model, anchorFrame: panel?.frame)
    }
    @objc private func runActions() {
        model?.cancelForInteraction(); actionPanel.show()
    }
    @objc private func readResearch() {
        model?.cancelForInteraction(); researchPanel.show()
    }
    @objc private func runWebResearch() {
        guard !terminating else { return }
        model?.cancelForInteraction(); webResearchPanel?.show()
    }
    @objc private func readSource() {
        model?.cancelForInteraction(); sourcePanel.show()
    }
    @objc private func openRepository() {
        if let url = URL(string: "https://github.com/Emin-dev/Dot") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func checkHardware() {
        HardwareCompatibility.showStatusAlert()
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
    @objc private func setProactivityFrequency(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let freq = ProactiveFrequency(rawValue: raw) else { return }
        model?.proactive.setFrequency(freq)
        model?.proactive.setPaused(false)
    }
    @objc private func toggleProactivityPause() {
        guard let model else { return }
        model.proactive.setPaused(!model.proactive.paused)
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

        let talkItem = NSMenuItem(title: model.phase.isActive ? "Interrupt and listen" : "Talk", action: #selector(talk), keyEquivalent: "")
        talkItem.target = self; menu.addItem(talkItem)

        if model.phase.isActive {
            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopCurrentAction), keyEquivalent: ".")
            stopItem.target = self; menu.addItem(stopItem)
        }

        let typed = NSMenuItem(title: "Type to Dot…", action: #selector(typeMessage), keyEquivalent: "t")
        typed.target = self; menu.addItem(typed)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(title: model.pinned ? "Roam freely" : "Pin in place", action: #selector(togglePin), keyEquivalent: "p")
        pinItem.target = self; menu.addItem(pinItem)

        let screenItem = NSMenuItem(title: "Screen awareness", action: #selector(toggleScreen), keyEquivalent: "")
        screenItem.target = self; screenItem.state = model.screenEnabled ? .on : .off; menu.addItem(screenItem)

        let clearItem = NSMenuItem(title: "Clear conversation", action: #selector(clearConversation), keyEquivalent: "k")
        clearItem.target = self; menu.addItem(clearItem)

        menu.addItem(.separator())
        menu.addItem(AppearanceOptionsMenu.make(settings: model.skinPreferences, target: self,
            skin: #selector(selectSkin(_:)), motion: #selector(selectMotion(_:))))
        menu.addItem(VoiceOptionsMenu.make(settings: model.voiceTiming, target: self,
            silence: #selector(setSilence(_:)), invitation: #selector(setInvitation(_:))))
        menu.addItem(ProactivityOptionsMenu.make(proactive: model.proactive, target: self,
            action: #selector(setProactivityFrequency(_:)), pauseAction: #selector(toggleProactivityPause)))

        let toolsItem = NSMenuItem(title: "Tools & History", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        let history = NSMenuItem(title: "Read local history…", action: #selector(readHistory), keyEquivalent: "")
        history.target = self; toolsMenu.addItem(history)
        let research = NSMenuItem(title: "Notebooks & research…", action: #selector(readResearch), keyEquivalent: "")
        research.target = self; toolsMenu.addItem(research)
        let webResearch = NSMenuItem(title: "Web research…", action: #selector(runWebResearch), keyEquivalent: "")
        webResearch.target = self; toolsMenu.addItem(webResearch)
        let actions = NSMenuItem(title: "Mac actions & receipts…", action: #selector(runActions), keyEquivalent: "")
        actions.target = self; toolsMenu.addItem(actions)
        let source = NSMenuItem(title: "Version source…", action: #selector(readSource), keyEquivalent: "")
        source.target = self; toolsMenu.addItem(source)
        let hardwareCheck = NSMenuItem(title: "Hardware compatibility check…", action: #selector(checkHardware), keyEquivalent: "")
        hardwareCheck.target = self; toolsMenu.addItem(hardwareCheck)
        let repoSubItem = NSMenuItem(title: "GitHub repository (latest code)…", action: #selector(openRepository), keyEquivalent: "")
        repoSubItem.target = self; toolsMenu.addItem(repoSubItem)
        toolsItem.submenu = toolsMenu
        menu.addItem(toolsItem)

        if hasDetails {
            menu.addItem(.separator())
            let copyItem = NSMenuItem(title: "Copy diagnostics", action: #selector(copyDetails), keyEquivalent: "")
            copyItem.target = self; menu.addItem(copyItem)
        }

        menu.addItem(.separator())
        let repoItem = NSMenuItem(title: "View Dot repository on GitHub…", action: #selector(openRepository), keyEquivalent: "")
        repoItem.target = self; menu.addItem(repoItem)

        let quitItem = NSMenuItem(title: "Quit Dot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    private func handleWindowOrAppChange() {
        guard let panel, let model, model.screenEnabled, !model.pinned, model.phase == .idle else { return }
        guard let screen = panel.screen else { return }

        placement.invalidate()
        placement.request(screen: screen, eligible: true, immediate: true)

        let snap = placement.current(screen: screen) ?? placement.fastWindowSnapshot(screen: screen)
        if let snap, !snap.protected.isEmpty {
            let frame = panel.frame
            if !RoamingCore.clear(frame, regions: snap.protected) {
                let origin = roam.evadeToEmptySpace(frame: frame, visible: screen.visibleFrame,
                                                    cursor: NSEvent.mouseLocation,
                                                    now: ProcessInfo.processInfo.systemUptime,
                                                    displayID: snap.displayID,
                                                    snapshot: snap)
                if origin != frame.origin {
                    panel.setFrameOrigin(origin)
                }
                scheduleMovement(interval: 1.0 / 60)
            }
        }
        model.updateProactiveContext()
    }

    private func moveGently() {
        guard let panel, let model else { return }
        let paused = !panel.isVisible || model.hovered || model.interactionPaused
            || model.historyPresented || model.pinned || model.phase.isActive || model.followupPending || menuTracking > 0 || NSEvent.pressedMouseButtons != 0
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.isVoiceOverEnabled
        guard let screen = panel.screen, let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            cancelMovement(); return
        }
        let eligible = !paused && model.screenEnabled
        if !eligible { placement.invalidate() }
        let currentSnapshot = eligible ? placement.current(screen: screen) : nil
        let snapshot = eligible ? (currentSnapshot ?? placement.fastWindowSnapshot(screen: screen)) : nil
        if eligible && currentSnapshot == nil { placement.request(screen: screen, eligible: eligible) }
        let visible = screen.visibleFrame
        let now = ProcessInfo.processInfo.systemUptime
        let origin = roam.step(frame: panel.frame, visible: visible, cursor: NSEvent.mouseLocation,
                               paused: !eligible || model.phase != .idle, now: now, displayID: displayID, snapshot: snapshot)
        let moved = panel.frame.origin != origin
        if moved { panel.setFrameOrigin(origin) }
        let pointerNearby = panel.frame.insetBy(dx: -40, dy: -40).contains(NSEvent.mouseLocation)
        _ = model.updateIdleMotion(now: now, externallyPaused: paused, pointerNearby: pointerNearby,
                                   reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, moved: moved)
        let interval = roam.isTravelling ? 1.0 / 60 : 0.5
        if interval != movementInterval { scheduleMovement(interval: interval) }
    }

    private func handlePhaseChanged(_ phase: PetPhase) {
        if phase == .thinking {
            startThinkingRelocation()
        } else {
            stopThinkingRelocation()
        }
    }

    private func startThinkingRelocation() {
        stopThinkingRelocation()
        relocateDuringThinking()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.relocateDuringThinking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        thinkingRelocationTimer = timer
    }

    private func stopThinkingRelocation() {
        thinkingRelocationTimer?.invalidate()
        thinkingRelocationTimer = nil
    }

    private func relocateDuringThinking() {
        guard let panel, let model, model.phase == .thinking, !model.pinned, !model.hovered,
              panel.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        guard let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: visible) else { return }

        if model.screenEnabled {
            placement.request(screen: screen, eligible: true, immediate: true)
        }

        let snap = placement.current(screen: screen) ?? placement.fastWindowSnapshot(screen: screen)
        let protectedRegions = snap?.protected ?? []

        let cursor = NSEvent.mouseLocation
        let currentOrigin = panel.frame.origin
        let currentFrame = panel.frame

        guard let target = RoamingCore.findRandomEmptySpace(
            frame: currentFrame,
            bounds: bounds,
            cursor: cursor,
            regions: protectedRegions,
            minDistance: 140
        ) else { return }

        guard target != currentOrigin else { return }

        self.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: false)
        let targetFrame = NSRect(origin: target, size: panel.frame.size)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: {
            panel.setFrameOrigin(target)
        })
    }

    private func startIdleRoaming() {
        idleRoamTimer?.invalidate()
        let interval: Double = 5.0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performIdleRoam()
                self?.startIdleRoaming()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleRoamTimer = timer
    }

    private func performIdleRoam() {
        guard let panel, let model, model.phase == .idle, !model.pinned, !model.hovered,
              !model.interactionPaused, panel.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        guard let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: visible) else { return }

        if model.screenEnabled {
            placement.request(screen: screen, eligible: true, immediate: true)
        }

        let snap = placement.current(screen: screen) ?? placement.fastWindowSnapshot(screen: screen)
        let protectedRegions = snap?.protected ?? []

        let cursor = NSEvent.mouseLocation
        let currentOrigin = panel.frame.origin
        let currentFrame = panel.frame

        guard let target = RoamingCore.findRandomEmptySpace(
            frame: currentFrame,
            bounds: bounds,
            cursor: cursor,
            regions: protectedRegions,
            minDistance: 120
        ) else { return }

        guard target != currentOrigin else { return }

        self.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: false)
        let targetFrame = NSRect(origin: target, size: panel.frame.size)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.85
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: {
            panel.setFrameOrigin(target)
        })
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true; sourcePanel.stop(); researchPanel.closeAdmissions(); webResearchPanel?.closeAdmissions(); actionPanel.closeAdmissions(); DotIntentRouter.shared.clear(); model?.beginShutdown()
        Task {
            await model?.textHistory.flush()
            await researchPanel.model.flush()
            await webResearchPanel?.model.flush()
            await actionPanel.model.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        documentWorker?.stop()
        stopThinkingRelocation()
        idleRoamTimer?.invalidate()
        model?.stopProactivity(); voiceEnvironment.stop(); movement?.invalidate(); placement.invalidate(); model?.shutdown()
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observations.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitorGlobal { NSEvent.removeMonitor(flagsMonitorGlobal) }
        if let flagsMonitorLocal { NSEvent.removeMonitor(flagsMonitorLocal) }
        // No pkill, process-name matching, or shutdown of borrowed services.
    }
}
