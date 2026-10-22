import SwiftUI
import AppKit
import QuartzCore
import Combine
import Darwin

/// CI proof that the installed process really is inside the App Sandbox.
/// It runs before AppKit starts so a hosted runner can check the kernel-enforced
/// container without needing a desktop session: the app must have a container
/// HOME, it must be able to write inside that container, and a write to the real
/// user home must be denied.
enum DotSandboxSelfCheck {
    static func runIfRequested() -> Int32? {
        guard ProcessInfo.processInfo.environment["DOT_SANDBOX_SELF_CHECK"] == "1" else { return nil }
        let fileManager = FileManager.default
        let containerID = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? ""
        let home = NSHomeDirectory()
        let inContainer = home.contains("/Library/Containers/app.dot.local/")
        var containerWrite = false
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let probe = support.appendingPathComponent("sandbox-probe-\(getpid()).txt")
            do {
                try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
                try Data("dot".utf8).write(to: probe)
                try fileManager.removeItem(at: probe)
                containerWrite = true
            } catch {
                containerWrite = false
            }
        }
        var outsideDenied = false
        var realHome = home.components(separatedBy: "/Library/Containers/").first
        if realHome?.hasPrefix("/Users/") != true {
            realHome = nil
            if let password = getpwuid(getuid()), let directory = password.pointee.pw_dir {
                realHome = String(cString: directory)
            }
        }
        if let realHome {
            let outside = URL(fileURLWithPath: realHome, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Dot-sandbox-probe-\(getpid()).txt")
            do {
                try Data("dot".utf8).write(to: outside)
                try? fileManager.removeItem(at: outside)
                outsideDenied = false
            } catch {
                // Only a sandbox permission denial proves confinement. Disk-full,
                // read-only media or a missing home must not pass the self-check.
                let failure = error as NSError
                let posix = (failure.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? failure.code
                outsideDenied = posix == Int(EPERM) || posix == Int(EACCES) || failure.code == 513
            }
        }
        let sandboxed = (containerID == "app.dot.local" || inContainer) && containerWrite && outsideDenied
        let record: [String: Any] = [
            "event": "sandbox_self_check",
            "sandboxed": sandboxed,
            "container_id": containerID,
            "home": home,
            "container_write": containerWrite,
            "outside_write_denied": outsideDenied
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        return sandboxed ? 0 : 1
    }
}

@main
struct DotApp {
    @MainActor static func main() {
        if let status = DotSandboxSelfCheck.runIfRequested() { exit(status) }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let surface = CompanionSurface()
    private let issueBanner = IssueBanner()
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
    private var idleRoamTimer: Timer?
    private var isAnimatingRoam = false
    /// Monotonic glide identity: a mid-animation abort bumps it so a stale
    /// animation completion can never pin Dot at a covered destination.
    private var roamGeneration = 0
    private var lastRoamRelocationAt: Double = 0
    private var lastRoamRefusal: String?
    private var statusItem: NSStatusItem?
    private var statusObservations: [AnyCancellable] = []
    private var lastMenuReadiness: CompanionReadiness?
    private var wideSpectrumNudges = 0
    private var lastWideSpectrumNudgeAt = 0.0
    private static let maximumWideSpectrumNudges = 3
    /// Random wandering is deliberately disabled: Dot stays in its safe spot while
    /// idle and only glides away when a window or the cursor actually covers it.
    /// RoamingCore is used for those escape trips (`performIdleRoam`).
    private var roam = RoamingCore()
    private var menuTracking = 0 {
        didSet { model?.menuIsOpen = menuTracking > 0 }
    }
    private var observations: [NSObjectProtocol] = []
    private var displayAsleep = false
    private var screenLocked = false
    private var screenIsOff: Bool { displayAsleep || screenLocked }
    private var movementInterval = 0.5
    private var lastEscapeAttemptAt = 0.0
    /// One-time options-menu notice for repeated placement capture failures, set
    /// only while screen awareness is on.
    private var placementNotice: String?
    private var placementFailureStreak = 0
    private var documentWorker: WatchedDocumentWorker?
    private var activityAssertion: NSObjectProtocol?
    private var keyMonitor: Any?
    private var flagsMonitorGlobal: Any?
    private var flagsMonitorLocal: Any?
    private var screenshotMonitorGlobal: Any?
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
        docWorker.start()
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
        model.onShowHistory = { [weak self] in self?.readHistory() }
        model.startProactivity()
        installScreenPowerObservers()
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
        placement.onDiagnostic = { [weak self, weak model] diagnostic in
            guard let self else { return }
            if diagnostic.outcome == .ready { self.placementFailureStreak = 0 }
            guard model?.screenEnabled == true,
                  diagnostic.reason == .permission || diagnostic.reason == .framework else { return }
            self.placementFailureStreak += 1
            if self.placementFailureStreak >= 3, self.placementNotice == nil {
                self.placementNotice = "Screen awareness: enable Screen Recording in System Settings → Privacy & Security."
            }
        }
        model.placementInvalidated = { [weak self] in self?.cancelMovement() }
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
                if let safeSpot = RoamingCore.findRandomEmptySpace(frame: panel.frame, bounds: bounds, cursor: cursor, regions: protectedRegions, minDistance: 160),
                   RoamingCore.safePath(from: panel.frame, to: safeSpot, regions: protectedRegions) {
                    target = safeSpot
                    reply = "Relocating to a new spot!"
                } else {
                    target = current
                    reply = "I can't find a clear empty spot right now, so I'll stay here."
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            self.isAnimatingRoam = true
            self.lastRoamRelocationAt = now
            self.roam.cancel(now: now, longRest: true)
            let targetFrame = NSRect(origin: target, size: panel.frame.size)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.65
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    panel.setFrameOrigin(target)
                    self?.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: true)
                    self?.isAnimatingRoam = false
                }
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
        panel.primaryAction = { [weak self] in self?.talk() }
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
                    // Only claim "indexed" after the worker has really scanned.
                    await self.documentWorker?.scanAndMaintainBrief()
                    self.model?.speakDirect("I have indexed \(url.lastPathComponent). Ask me anything about it!")
                }
            } catch {
                self.model?.speakDirect("I couldn't index \(url.lastPathComponent).")
            }
        }
        panel.primaryHitTest = { point in
            NSBezierPath(ovalIn: NSRect(x: (PetLayout.panelSize.width - PetLayout.petSize.width) / 2,
                                       y: PetLayout.petBottom, width: PetLayout.petSize.width,
                                       height: PetLayout.petSize.height)).contains(point)
        }
        // While an approval card is presented it covers the pet, so mouse input must
        // reach the card's buttons instead of being consumed as a click-to-talk.
        panel.controlHitTest = { [weak model] _ in model?.pendingApproval != nil }
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
        statusItem = item
        applyStatusMenu(OfflinePreparation.shared.state)
        VideoPlaybackDetector.recordFrontmostApp()
        if !MicrophoneMode.isWideSpectrum,
           !UserDefaults.standard.bool(forKey: "dot.wideSpectrumPrompted") {
            // The prompted flag is persisted only once the picker outcome is
            // known (see offerWideSpectrum); the picker never opens at the lock
            // screen.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.offerWideSpectrum()
            }
        }
        let preparation = OfflinePreparation.shared
        statusObservations.append(preparation.$progress.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle(engineStage: self?.model?.engineStage) }
        })
        statusObservations.append(preparation.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle(engineStage: self?.model?.engineStage) }
        })
        statusObservations.append(model.$engineStage.receive(on: RunLoop.main).sink { [weak self] stage in
            Task { @MainActor in self?.updateStatusTitle(engineStage: stage) }
        })
        statusObservations.append(model.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            guard phase == .listening else { return }
            Task { @MainActor in self?.recheckWideSpectrumDuringCapture() }
        })
        // R19: an error keeps Dot's look and life; its words float above Dot.
        statusObservations.append(model.$phase.combineLatest(preparation.$state)
            .receive(on: RunLoop.main).sink { [weak self] phase, readiness in
                Task { @MainActor in self?.showIssue(phase: phase, readiness: readiness) }
            })
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
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // Monotonic timer sleeps do not advance through Mac sleep; fire a
                // missed timer once on wake instead of making the owner wait the
                // sleep duration. Never at the lock screen: timer notices speak.
                guard !ChatModel.screenIsCurrentlyLocked() else { return }
                SmartTimerScheduler.shared.handleWake()
            }
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in
                // Never speak or resume capture at the lock screen: the unlock
                // notification performs the resume. The distributed lock flag can
                // lag a wake, so read the session state directly.
                guard !ChatModel.screenIsCurrentlyLocked() else { return }
                // Let the audio route settle before the greeting.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                model?.handleSystemWake()
            }
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak model, weak webResearch] _ in
            // cancelForEnvironment is the single sleep owner: it ends an active
            // capture (or blocks the turn) synchronously during notification
            // delivery, so the capture's own willSleep observer can never end the
            // same capture a second time.
            MainActor.assumeIsolated {
                webResearch?.foregroundPause()
                model?.cancelForEnvironment(reason: .systemSleep)
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak model, weak webResearch] _ in
            Task { @MainActor in webResearch?.foregroundPause(); model?.visible = false }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.visible = true }
        })
        placement.onSnapshotUpdated = { [weak self] snapshot in
            guard let self, !self.screenIsOff, !self.isAnimatingRoam,
                  let panel = self.panel, let model = self.model,
                  model.screenEnabled, !model.pinned, model.phase.isResting,
                  !model.hovered, model.menuIsOpen == false,
                  NSEvent.pressedMouseButtons == 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // This snapshot is fresh by construction, and the overlap proof below
            // overrides the post-roam rest so Dot never parks over content for
            // up to 45 s after a roam finished.
            guard !self.roam.isTravelling, now - self.lastEscapeAttemptAt > 1.5 else { return }
            guard let screen = panel.screen else { return }
            let frame = panel.frame
            if !RoamingCore.clear(frame, regions: snapshot.protected) {
                self.lastEscapeAttemptAt = now
                self.lastRoamRelocationAt = now
                _ = self.roam.evadeToEmptySpace(frame: frame, visible: screen.visibleFrame,
                                                cursor: NSEvent.mouseLocation,
                                                now: now,
                                                displayID: snapshot.displayID,
                                                snapshot: snapshot)
                self.scheduleMovement(interval: 1.0 / 60)
            }
        }
        scheduleMovement(interval: 0.5)
        DotIntentRouter.shared.configure(talk: { [weak self] in
            guard let self, let model = self.model, !self.terminating else { throw DotIntentError.unavailable }
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
        setupScreenshotAutoHide()
        ScreenScribbleTracker.shared.startMonitoring { [weak model] region in
            model?.handleCircleToAsk(region: region)
        }
    }

    private func showIssue(phase: PetPhase, readiness: CompanionReadiness) {
        guard let panel else { return }
        var text = phase.blockedMessage
        if text == nil, case .unavailable(let message) = readiness { text = message }
        issueBanner.update(text: text, above: panel)
    }

    private func setupScreenshotAutoHide() {
        screenshotMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift])
            if flags == [.command, .shift] {
                // Key code 20 is '3', 21 is '4', 23 is '5'
                if event.keyCode == 20 || event.keyCode == 21 || event.keyCode == 23 {
                    self?.hideTemporarilyForScreenshot()
                }
            }
        }
    }

    private func hideTemporarilyForScreenshot() {
        guard let panel = self.panel, panel.alphaValue > 0 else { return }
        panel.alphaValue = 0.0
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let panel = self?.panel, self?.terminating != true else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1.0
            }
        }
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

    private func updateStatusTitle(engineStage: String?) {
        guard let item = statusItem else { return }
        let preparation = OfflinePreparation.shared
        let title = CompanionIssue.statusTitle(preparing: preparation.state == .checking,
                                               progress: preparation.progress,
                                               engineStage: engineStage)
        item.button?.title = title ?? ""
        item.length = title == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        item.button?.toolTip = title.map { "Dot: \($0)" } ?? "Dot: Show, Options, Type or Quit"
        // The status menu mirrors the options menu's pause/retry actions for the
        // current readiness, so "retry from the menu" exists outside the panel too.
        if preparation.state != lastMenuReadiness {
            applyStatusMenu(preparation.state)
        }
    }

    private func applyStatusMenu(_ readiness: CompanionReadiness) {
        lastMenuReadiness = readiness
        statusItem?.menu = CompanionStatusMenu.make(target: self, show: #selector(showPet), quit: #selector(quit),
            options: #selector(openOptions), type: #selector(typeMessage),
            readiness: readiness, pauseAction: #selector(pausePreparation), retryAction: #selector(retryPreparation))
    }

    /// Offer the system mic-mode selector. The "prompted" flag is only persisted
    /// once the picker outcome is known: the mode is Wide Spectrum, or the bounded
    /// nudges are exhausted. Never opens at the lock screen.
    private func offerWideSpectrum() {
        guard !MicrophoneMode.isWideSpectrum,
              !UserDefaults.standard.bool(forKey: "dot.wideSpectrumPrompted"),
              !ChatModel.screenIsCurrentlyLocked() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard wideSpectrumNudges < Self.maximumWideSpectrumNudges else {
            UserDefaults.standard.set(true, forKey: "dot.wideSpectrumPrompted")
            return
        }
        guard now - lastWideSpectrumNudgeAt >= 60 else { return }
        wideSpectrumNudges += 1
        lastWideSpectrumNudgeAt = now
        MicrophoneMode.openSystemSelector()
    }

    /// While Dot is capturing, re-check the mode: persist the flag the moment the
    /// owner switched to Wide Spectrum, or nudge again (bounded) if they did not.
    private func recheckWideSpectrumDuringCapture() {
        if MicrophoneMode.isWideSpectrum {
            UserDefaults.standard.set(true, forKey: "dot.wideSpectrumPrompted")
            return
        }
        guard !UserDefaults.standard.bool(forKey: "dot.wideSpectrumPrompted") else { return }
        offerWideSpectrum()
    }

    @objc private func showPet() { model?.cancelTurn(); model?.visible = true; cancelMovement(); surface.recall() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Full removal from inside the sandbox. A sandboxed process cannot delete
    /// its own bundle or container, so this writes the bundled uninstaller into
    /// Dot's own private container and asks Terminal to run it once. There is no
    /// helper, LaunchAgent or privileged tool. If Terminal cannot be opened, the
    /// exact one-line command is copied to the clipboard instead.
    @objc private func removeDotCompletely() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Dot completely?"
        alert.informativeText = "This quits Dot and deletes the app, its sandbox container, logs, downloaded model, preferences and caches. It also resets Dot's microphone and screen-recording approvals. Terminal opens for this one action; nothing is left running afterwards."
        let remove = alert.addButton(withTitle: "Remove Dot completely")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let download = "curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/uninstall-dot.sh | bash"
        let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent().path
        // A quarantined app opened in place can run from App Translocation. Remove
        // the real per-user install, never the read-only translocated copy.
        let realHome = NSHomeDirectory().components(separatedBy: "/Library/Containers/").first ?? NSHomeDirectory()
        let installDir = bundlePath.contains("/AppTranslocation/")
            ? (realHome as NSString).appendingPathComponent("Applications")
            : bundlePath
        guard let bundled = Bundle.main.url(forResource: "uninstall-dot", withExtension: "sh"),
              let uninstaller = try? String(contentsOf: bundled, encoding: .utf8) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(download, forType: .string)
            let fallback = NSAlert()
            fallback.messageText = "The bundled uninstaller is missing"
            fallback.informativeText = "The exact removal command is on your clipboard. Paste it into Terminal to remove Dot: " + download
            fallback.runModal()
            return
        }
        let quotedInstallDir = "'" + installDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let wrapper = """
        #!/bin/bash
        export DOT_INSTALL_DIR=\(quotedInstallDir)
        export DOT_BUNDLE_ID=app.dot.local
        /usr/bin/env bash -s <<'DOT_UNINSTALL_EMBEDDED'
        \(uninstaller)
        DOT_UNINSTALL_EMBEDDED
        """
        let commandURL = FileManager.default.temporaryDirectory.appendingPathComponent("Remove Dot.command")
        var opened = false
        do {
            try? FileManager.default.removeItem(at: commandURL)
            try wrapper.write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandURL.path)
            opened = NSWorkspace.shared.open(commandURL)
        } catch {
            // Fall through to the clipboard command; never claim removal started.
        }
        // A file written by a sandboxed app can be quarantined, so Terminal may
        // refuse it even when open() succeeds. Always leave the exact command ready.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(download, forType: .string)
        let fallback = NSAlert()
        fallback.messageText = opened ? "Removal opened in Terminal" : "Terminal could not be opened"
        fallback.informativeText = opened
            ? "If Terminal shows a warning instead of removing Dot, paste the command on your clipboard into Terminal."
            : "The exact removal command is on your clipboard. Paste it into Terminal to remove Dot."
        fallback.runModal()
    }

    @objc private func stopCurrentAction() {
        cancelMovement()
        model?.stopCurrentTurn()
        sourcePanel.stop(); researchPanel.cancel(); webResearchPanel?.cancel(); actionPanel.stop()
        OfflinePreparation.shared.pause()
    }
    /// A click on an incomplete app is the retry offer: .unavailable restarts the
    /// file check before the click reports readiness.
    @objc private func talk() {
        if OfflinePreparation.shared.state.isIssue { OfflinePreparation.shared.retry() }
        model?.clicked()
    }
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
    /// The one reachable request for the grant global key/gesture monitors need.
    @objc private func requestAccessibilityAccess() {
        _ = InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: true)
    }
    @objc private func retryPreparation() { OfflinePreparation.shared.retry() }
    @objc private func pausePreparation() { OfflinePreparation.shared.pause() }
    @objc private func togglePin() { model?.pinned.toggle() }
    @objc private func openMicrophoneModes() { MicrophoneMode.openSystemSelector() }
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
    @objc private func toggleTrustedFrontmost(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let store = TrustedAppStore()
        if store.isTrusted(name) { store.untrust(name) } else { store.trust(name) }
    }
    @objc private func removeTrustedApps() { TrustedAppStore().removeAll() }
    @objc private func togglePrewarm() {
        let key = ChatModel.prewarmDefaultsKey
        let next = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(next, forKey: key)
        model?.prewarmIfEnabled()
    }
    @objc private func toggleBatteryAlerts() { model?.batteryAlerts.enabled.toggle() }
    @objc private func setBatteryThreshold(_ sender: NSMenuItem) { model?.batteryAlerts.lowThreshold = sender.tag }
    @objc private func toggleChargingAlerts() { model?.batteryAlerts.chargingAlerts.toggle() }
    private func showOptions() {
        guard let panel, let view = panel.contentView, let model else { return }
        model.cancelForInteraction(); panel.cancelPointerGesture(); cancelMovement(); panel.makeKey()
        let menu = NSMenu()
        if model.firstUseHint {
            // The hint must survive opening this menu: that was the only surface that
            // could show it, and the old code dismissed it on the way in.
            let hint = NSMenuItem(title: InPlaceAppTyping.isAccessibilityTrusted()
                ? "Click Dot to talk, or hold Fn anywhere."
                : "Click Dot to talk. Hold Fn needs Accessibility (see Tools & History).",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false; menu.addItem(hint); menu.addItem(.separator())
        }
        let readiness = OfflinePreparation.shared.state
        let hasDetails = readiness.detail != nil || model.issue != nil
        if let header = CompanionIssue.menuHeader(readiness: readiness, issue: model.issue,
                                                   progress: OfflinePreparation.shared.progress,
                                                   engineStage: model.engineStage,
                                                   detail: OfflinePreparation.shared.detail) {
            let item = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); menu.addItem(.separator())
        }

        let talkItem = NSMenuItem(title: model.phase.isActive ? "Interrupt and listen" : "Talk", action: #selector(talk), keyEquivalent: "")
        talkItem.target = self; menu.addItem(talkItem)

        if model.phase.isActive {
            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopCurrentAction), keyEquivalent: ".")
            stopItem.target = self; menu.addItem(stopItem)
        }

        if readiness.canPause {
            let pauseItem = NSMenuItem(title: CompanionMenuAction.pause.title(busy: false, pinned: false, issue: nil),
                                       action: #selector(pausePreparation), keyEquivalent: "")
            pauseItem.target = self; menu.addItem(pauseItem)
        }
        if readiness.canRetry {
            let retryItem = NSMenuItem(title: CompanionMenuAction.retry.title(busy: false, pinned: false, issue: nil),
                                       action: #selector(retryPreparation), keyEquivalent: "")
            retryItem.target = self; menu.addItem(retryItem)
        }

        let typed = NSMenuItem(title: "Type to Dot…", action: #selector(typeMessage), keyEquivalent: "t")
        typed.target = self; menu.addItem(typed)

        menu.addItem(.separator())

        let pinItem = NSMenuItem(title: model.pinned ? "Roam freely" : "Pin in place", action: #selector(togglePin), keyEquivalent: "p")
        pinItem.target = self; menu.addItem(pinItem)

        let screenItem = NSMenuItem(title: "Screen awareness", action: #selector(toggleScreen), keyEquivalent: "")
        screenItem.target = self; screenItem.state = model.screenEnabled ? .on : .off; menu.addItem(screenItem)

        let micTitle = MicrophoneMode.isWideSpectrum
            ? "Microphone mode: Wide Spectrum (change…)"
            : "Microphone mode: \(MicrophoneMode.displayName) — choose Wide Spectrum…"
        let micItem = NSMenuItem(title: micTitle, action: #selector(openMicrophoneModes), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        if let visionNotice = model.visionNotice {
            let noticeItem = NSMenuItem(title: visionNotice, action: nil, keyEquivalent: "")
            noticeItem.isEnabled = false
            menu.addItem(noticeItem)
        }
        if let placementNotice {
            let noticeItem = NSMenuItem(title: placementNotice, action: nil, keyEquivalent: "")
            noticeItem.isEnabled = false
            menu.addItem(noticeItem)
        }

        let clearItem = NSMenuItem(title: "Clear conversation", action: #selector(clearConversation), keyEquivalent: "k")
        clearItem.target = self; menu.addItem(clearItem)

        menu.addItem(.separator())
        menu.addItem(AppearanceOptionsMenu.make(settings: model.skinPreferences, target: self,
            skin: #selector(selectSkin(_:)), motion: #selector(selectMotion(_:))))
        menu.addItem(VoiceOptionsMenu.make(settings: model.voiceTiming, target: self,
            silence: #selector(setSilence(_:)), invitation: #selector(setInvitation(_:))))
        menu.addItem(ProactivityOptionsMenu.make(proactive: model.proactive, target: self,
            action: #selector(setProactivityFrequency(_:)), pauseAction: #selector(toggleProactivityPause)))
        menu.addItem(BatteryOptionsMenu.make(settings: model.batteryAlerts, target: self,
            toggle: #selector(toggleBatteryAlerts), threshold: #selector(setBatteryThreshold(_:)),
            charging: #selector(toggleChargingAlerts)))
        let front = NSWorkspace.shared.frontmostApplication
        let frontName = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front?.localizedName
        menu.addItem(TrustedAppsMenu.make(store: TrustedAppStore(), frontmost: frontName, target: self,
            trust: #selector(toggleTrustedFrontmost(_:)), removeAll: #selector(removeTrustedApps)))

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
        // Global Fn/screenshot/circle-to-ask monitoring delivers no events at all
        // without Accessibility, and no user action can reveal that dead monitor.
        // This is the reachable request for the grant those features depend on.
        if !InPlaceAppTyping.isAccessibilityTrusted() {
            toolsMenu.addItem(.separator())
            let accessibility = NSMenuItem(title: "Enable hold-Fn and global gestures (Accessibility)…",
                                           action: #selector(requestAccessibilityAccess), keyEquivalent: "")
            accessibility.target = self; toolsMenu.addItem(accessibility)
        }
        let prewarm = NSMenuItem(title: "Prewarm local model at launch",
                                 action: #selector(togglePrewarm), keyEquivalent: "")
        prewarm.target = self
        prewarm.state = UserDefaults.standard.bool(forKey: ChatModel.prewarmDefaultsKey) ? .on : .off
        toolsMenu.addItem(prewarm)
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

        let removeItem = NSMenuItem(title: "Remove Dot completely…", action: #selector(removeDotCompletely), keyEquivalent: "")
        removeItem.target = self; menu.addItem(removeItem)

        let quitItem = NSMenuItem(title: "Quit Dot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    private func handleWindowOrAppChange() {
        VideoPlaybackDetector.recordFrontmostApp()
        guard !isAnimatingRoam, let panel, let model, model.screenEnabled, !model.pinned, model.phase.isResting else { return }
        guard let screen = panel.screen else { return }

        placement.invalidate()
        placement.request(screen: screen, eligible: true, immediate: true)

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRoamRelocationAt > 30.0,
           let snap = placement.current(screen: screen) ?? placement.fastWindowSnapshot(screen: screen),
           !snap.protected.isEmpty {
            let frame = panel.frame
            if !RoamingCore.clear(frame, regions: snap.protected) {
                performIdleRoam()
            }
        }
        model.updateProactiveContext()
    }

    /// Refresh a placement map before validating it. The map's lifetime and the
    /// capture cadence are both ten seconds, so validating first rejects the
    /// first check of every cycle and cancels the refresh that would replace it.
    private func placementSnapshot(for screen: NSScreen, eligible: Bool) -> PlacementSnapshot? {
        if eligible, placement.needsRefresh(screen: screen) {
            placement.request(screen: screen, eligible: true)
        }
        let current = placement.current(screen: screen)
        if eligible, current == nil { placement.request(screen: screen, eligible: true) }
        return current ?? placement.fastWindowSnapshot(screen: screen)
    }

    private func installScreenPowerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observations.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyScreenPower(displayAsleep: true, locked: self?.screenLocked ?? false) }
        })
        observations.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyScreenPower(displayAsleep: false, locked: self?.screenLocked ?? false) }
        })
        let distributed = DistributedNotificationCenter.default()
        observations.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyScreenPower(displayAsleep: self?.displayAsleep ?? false, locked: true) }
        })
        observations.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyScreenPower(displayAsleep: self?.displayAsleep ?? false, locked: false) }
        })
        // A launch at the login screen must not start autonomous work.
        let locked = ChatModel.screenIsCurrentlyLocked()
        screenLocked = locked
        if locked {
            model?.pauseForScreenOff()
            OfflinePreparation.shared.pause(keepingDownload: true)
        }
    }

    private func applyScreenPower(displayAsleep: Bool, locked: Bool) {
        self.displayAsleep = displayAsleep
        self.screenLocked = locked
        if displayAsleep || locked {
            model?.pauseForScreenOff()
            OfflinePreparation.shared.pause(keepingDownload: true)
        } else {
            model?.resumeAfterScreenOn()
            OfflinePreparation.shared.retry()
        }
    }

    private func moveGently() {
        if screenIsOff {
            cancelMovement()
            return
        }
        guard !isAnimatingRoam, let panel, let model else { return }
        let cursor = NSEvent.mouseLocation
        if model.hovered && !panel.frame.insetBy(dx: -8, dy: -8).contains(cursor) {
            model.hovered = false
        }
        if model.interactionPaused && NSEvent.pressedMouseButtons == 0 {
            model.interactionPaused = false
        }
        let paused = !panel.isVisible || model.hovered || model.interactionPaused
            || model.historyPresented || model.pinned || model.phase.isActive || model.followupPending || menuTracking > 0 || NSEvent.pressedMouseButtons != 0
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || NSWorkspace.shared.isVoiceOverEnabled
        guard let screen = panel.screen, let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            cancelMovement(); return
        }
        let eligible = !paused && model.screenEnabled
        if !eligible { placement.invalidate() }
        let snapshot = eligible ? placementSnapshot(for: screen, eligible: true) : nil
        let visible = screen.visibleFrame
        let now = ProcessInfo.processInfo.systemUptime

        let checkRegions = snapshot?.protected ?? []
        let isCovered = !checkRegions.isEmpty && !RoamingCore.clear(panel.frame, regions: checkRegions)
        // A fresh snapshot that proves overlap overrides the post-roam rest, so
        // Dot never sits over content for up to 45 s after a roam finished.
        let freshOverlap = snapshot?.valid(displayID: displayID, visible: visible, now: now) == true && isCovered
        let isCursorNear = panel.frame.insetBy(dx: -24, dy: -24).contains(cursor)
        if eligible && isCovered, !isAnimatingRoam, !roam.isTravelling, model.phase.isResting,
           (freshOverlap || !roam.isResting(now: now)), now - lastEscapeAttemptAt > 1.5, let snapshot {
            // Content is under Dot: leave immediately, not after a two-minute cadence.
            lastEscapeAttemptAt = now
            lastRoamRelocationAt = now
            _ = roam.evadeToEmptySpace(frame: panel.frame, visible: visible, cursor: cursor,
                                       now: now, displayID: displayID, snapshot: snapshot)
            scheduleMovement(interval: 1.0 / 60)
            return
        }
        if eligible && isCursorNear, !isAnimatingRoam, model.phase.isResting {
            performIdleRoam()
            return
        }

        let origin = roam.step(frame: panel.frame, visible: visible, cursor: cursor,
                               paused: !eligible || !model.phase.isResting || isAnimatingRoam, now: now, displayID: displayID, snapshot: snapshot)
        let moved = panel.frame.origin != origin
        if moved && !isAnimatingRoam { panel.setFrameOrigin(origin) }
        let pointerNearby = panel.frame.insetBy(dx: -40, dy: -40).contains(cursor)
        _ = model.updateIdleMotion(now: now, externallyPaused: paused, pointerNearby: pointerNearby,
                                   reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, moved: moved)
        let interval = roam.isTravelling ? 1.0 / 60 : 0.5
        if interval != movementInterval { scheduleMovement(interval: interval) }
    }

    private func startIdleRoaming() {
        idleRoamTimer?.invalidate()
        // The owner's cadence: Dot moves to a new clear spot every 2 minutes while
        // idle. (It was 12-18 seconds until 2026-10-17, which moved far too often.)
        let interval = 120.0
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
        var refusal: String? = nil
        defer {
            // Log each veto once until it changes; the same reason every two
            // minutes buried the log and re-triggered the GitHub sync.
            let reason = refusal.map { $0.hasPrefix("cadence") ? "cadence" : $0 }
            if let refusal, reason != lastRoamRefusal {
                DiagnosticChatLogger.record(role: "system", text: "[ROAM] skip: \(refusal)")
            }
            lastRoamRefusal = reason
        }
        guard !screenIsOff else { refusal = "display off"; return }
        guard !isAnimatingRoam else { refusal = "already animating"; return }
        guard let panel, let model else { refusal = "panel/model missing"; return }
        let cursor = NSEvent.mouseLocation
        if model.hovered && !panel.frame.insetBy(dx: -8, dy: -8).contains(cursor) {
            model.hovered = false
        }
        if model.interactionPaused && NSEvent.pressedMouseButtons == 0 {
            model.interactionPaused = false
        }
        if !model.phase.isResting { refusal = "phase=\(model.phase)"; return }
        if !model.screenEnabled { refusal = "screen awareness off"; return }
        if model.pinned { refusal = "pinned"; return }
        if model.hovered { refusal = "pointer on Dot"; return }
        if model.interactionPaused { refusal = "interaction paused"; return }
        if model.historyPresented { refusal = "history presented"; return }
        if model.followupPending { refusal = "followup pending"; return }
        if !panel.isVisible { refusal = "panel hidden"; return }
        if menuTracking != 0 { refusal = "menu tracking"; return }
        if NSEvent.pressedMouseButtons != 0 { refusal = "mouse button held"; return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { refusal = "reduce motion"; return }
        if NSWorkspace.shared.isVoiceOverEnabled { refusal = "voiceover"; return }
        let now = ProcessInfo.processInfo.systemUptime
        if !RoamingCore.autonomousMoveAllowed(now: now, lastMoveAt: lastRoamRelocationAt) {
            refusal = "cadence (waited \(Int(now - lastRoamRelocationAt))s of 115s)"; return
        }
        guard let screen = panel.screen ?? NSScreen.main else { refusal = "no screen"; return }
        let visible = screen.visibleFrame
        guard let bounds = RoamingCore.originBounds(window: panel.frame.size, visible: visible) else { refusal = "no bounds"; return }

        // No verified map means no autonomous move: a blind roam can cover content.
        guard let snap = placementSnapshot(for: screen, eligible: model.screenEnabled) else { refusal = "no verified placement map"; return }
        let protectedRegions = snap.protected

        // Roam on the agreed cadence to a clear safe zone. The destination must be
        // clear *and* the whole swept path must not cross content.
        let currentOrigin = panel.frame.origin
        let currentFrame = panel.frame
        let target = RoamingCore.findRandomEmptySpace(
            frame: currentFrame,
            bounds: bounds,
            cursor: cursor,
            regions: protectedRegions,
            minDistance: 120
        ).flatMap { candidate in
            RoamingCore.safePath(from: currentFrame, to: candidate, regions: protectedRegions) ? candidate : nil
        } ?? RoamingCore.findEmptySpace(
            frame: currentFrame,
            bounds: bounds,
            cursor: cursor,
            regions: protectedRegions,
            preferredNear: currentOrigin,
            minDistance: 120
        ).flatMap { candidate in
            RoamingCore.safePath(from: currentFrame, to: candidate, regions: protectedRegions) ? candidate : nil
        }
        guard let target, target != currentOrigin else { refusal = "no clear safe spot (screen busy)"; return }

        self.isAnimatingRoam = true
        self.lastRoamRelocationAt = now
        self.roam.cancel(now: now, longRest: true)
        self.roamGeneration += 1
        let generation = self.roamGeneration
        let targetFrame = NSRect(origin: target, size: panel.frame.size)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 3.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.roamGeneration == generation else { return }
                panel.setFrameOrigin(target)
                self.roam.cancel(now: ProcessInfo.processInfo.systemUptime, longRest: true)
                self.isAnimatingRoam = false
            }
        })
        // Re-validate the glide destination mid-animation: if a fresh map shows
        // the destination covered, stop the glide in place and let the coverage
        // escape relocate Dot instead of parking it over content for up to 45 s.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.roamGeneration == generation, self.isAnimatingRoam,
                  let model = self.model, model.screenEnabled,
                  let panel = self.panel, let screen = panel.screen,
                  let fresh = self.placementSnapshot(for: screen, eligible: true),
                  !RoamingCore.clear(targetFrame, regions: fresh.protected) else { return }
            self.roamGeneration += 1
            self.isAnimatingRoam = false
            panel.setFrameOrigin(panel.frame.origin)
        }
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
        idleRoamTimer?.invalidate()
        model?.stopProactivity(); voiceEnvironment.stop(); movement?.invalidate(); placement.invalidate(); model?.shutdown()
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
            DistributedNotificationCenter.default().removeObserver(observation)
        }
        observations.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitorGlobal { NSEvent.removeMonitor(flagsMonitorGlobal) }
        if let flagsMonitorLocal { NSEvent.removeMonitor(flagsMonitorLocal) }
        if let screenshotMonitorGlobal { NSEvent.removeMonitor(screenshotMonitorGlobal) }
        ScreenScribbleTracker.shared.stopMonitoring()
        // No pkill, process-name matching, or shutdown of borrowed services.
    }
}
