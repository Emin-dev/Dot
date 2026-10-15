import SwiftUI
import AppKit
import OSLog
import AVFoundation
import CoreGraphics

/// Replaceable boundary operations keep coordinator replays model-free. This
/// carries no turn state; production closures use the existing native managers.
@MainActor
struct ChatRuntime {
    var isReady: () -> Bool
    var startPreparation: () -> Void
    var microphoneAuthorized: () -> Bool
    var currentRoute: () -> VoiceAudioRoute?
    var screenAuthorized: () -> Bool
    var startVoice: (UUID) throws -> Void
    var enqueueVoice: (String, UUID) -> Void
    var completeVoice: (UUID) -> Void
    var stopVoice: () -> Void
    var ttsSpeaking: () -> Bool
    var startCapture: (UUID, VoiceTimingSettings, Bool) async -> Void
    var stopCapture: () -> Void
    var recording: () -> Bool
    var transcribing: () -> Bool
}

/// The native editor and coordinator share the same bounded input contract.
enum TypedMessageValidation {
    static func cleaned(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func problem(_ text: String) -> String? {
        let value = cleaned(text)
        guard !value.isEmpty else { return "Enter a message to send." }
        guard value.utf8.count <= 24_000, value.count <= 6_000 else {
            return "Shorten the message to 6,000 characters and 24,000 UTF-8 bytes."
        }
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains($0.value) }) else {
            return "Remove unsupported control characters from the message."
        }
        return nil
    }
}

/// Temporary diagnostic chat logger saving all messages to Downloads folder.
/// Will be removed in final production release per user request.
enum DiagnosticChatLogger {
    private static let lock = NSLock()
    private static let logURL: URL? = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dot_chat_log.txt")
    }()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func record(role: String, text: String) {
        guard let url = logURL else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(role.uppercased())] \(trimmed)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            let header = "# Dot Conversation Diagnostic Log (Temporary)\n# Created: \(timestamp)\n# Records all user prompts and assistant actions/responses for debugging.\n\n"
            var combined = header.data(using: .utf8) ?? Data()
            combined.append(data)
            try? combined.write(to: url, options: .atomic)
        }
    }
}

enum DotMovementCommand: String, Sendable {
    case left
    case right
    case up
    case down
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case center
    case away
    case random
}

@MainActor
final class ChatModel: ObservableObject {
    var onMove: ((DotMovementCommand) -> String?)?
    @Published private(set) var phase: PetPhase = .idle { didSet { if phase.isActive { placementInvalidated?() }; updateProactiveContext() } }
    @Published private(set) var issue: CompanionIssue?
    @Published private(set) var answer = ""
    /// Identity of the displayed text, retained on Stop so history can describe
    /// interrupted delivery without treating the replacement turn as its owner.
    @Published private(set) var displayedAnswerTurn: UUID?
    @Published private(set) var voiceDeliveryNotice: String?
    @Published private(set) var captureOutcome: String?
    private var captureOutcomeTask: Task<Void, Never>?
    @Published private(set) var firstUseHint: Bool
    private var lastAttemptedText: String?
    @Published var pinned: Bool {
        didSet { defaults.set(pinned, forKey: "petPinned"); placementInvalidated?() }
    }
    @Published var hovered = false { didSet { if hovered { placementInvalidated?() }; updateProactiveContext() } }
    @Published var interactionPaused = false { didSet { if interactionPaused { placementInvalidated?(); cancelForInteraction() }; updateProactiveContext() } }
    var placementInvalidated: (() -> Void)?
    @Published var placementCapturing = false
    var showOptions: (() -> Void)?
    /// The integration owner pauses optional research before foreground work.
    var onForegroundInteraction: (() -> Void)?
    let textHistory: ConversationHistoryModel
    let voiceTiming: VoiceTimingSettings
    let skinPreferences: SkinPreferences
    let proactive: ProactiveBehavior
    private let defaults: UserDefaults
    private let runtime: ChatRuntime
    let ftsStore: LocalFTSStore
    @Published private(set) var idleMotionOffset = IdleMotionOffset.zero
    private var idleMotion = IdleMotionCore()
    private var proactiveEvidence = ProactiveConversationEvidence()
    private var proactiveTurn: (opportunity: UUID, turn: UUID)?
    private var proactiveContextChange: ProactiveContextChange?
    private var proactiveContextChangedAfterUser = false
    private var externalInteractionBusy = false
    private var controlInteraction = false
    private var recentProactiveReplies: [String] = []
    private let followup: VoiceFollowup
    private var voiceRoute: VoiceAudioRoute?
    @Published private(set) var automaticReply = false
    @Published private(set) var expressionRevision: UInt64 = 0
    @Published private(set) var taskHalo: LongTaskProgress.Halo = .hidden
    @Published private(set) var taskStage: String?
    @Published private(set) var taskStatusText: String?
    private var taskProgress = ResearchTaskProgress()
    private var activeSpeechUpdateID: UUID?
    private var taskProgressTicker: Task<Void, Never>?
    private var shuttingDown = false
    var onExecuteAction: ((NativeAction) async -> NativeActionResult?)?
    var onRequestResearch: ((String) -> Void)?

    func speakDirect(_ text: String) {
        guard !shuttingDown, runtime.isReady(), phase == .idle else { return }
        DiagnosticChatLogger.record(role: "dot", text: text)
        let id = cancelTurn()
        answer = text
        displayedAnswerTurn = id
        phase = .speaking
        expressionRevision &+= 1
        do {
            try runtime.startVoice(id)
            runtime.enqueueVoice(text, id)
            runtime.completeVoice(id)
        } catch {
            phase = .idle
        }
    }

    private func detectNativeAction(_ text: String) -> NativeAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { return nil }
        let lower = trimmed.lowercased()

        // 1. Direct Web URLs
        if lower.hasPrefix("open http://") || lower.hasPrefix("open https://") {
            let url = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .openWebURL(url)
        }
        if lower.hasPrefix("open ") {
            let target = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            let siteMap: [String: String] = [
                "google": "https://www.google.com",
                "youtube": "https://www.youtube.com",
                "github": "https://www.github.com",
                "twitter": "https://x.com",
                "x": "https://x.com",
                "reddit": "https://www.reddit.com",
                "wikipedia": "https://www.wikipedia.org",
                "amazon": "https://www.amazon.com",
                "netflix": "https://www.netflix.com",
                "chatgpt": "https://chatgpt.com"
            ]
            if let siteURL = siteMap[target.lowercased()] {
                return .openWebURL(siteURL)
            }
            let domains = [".com", ".org", ".net", ".io", ".dev", ".app", ".ai", ".co", ".me", ".info", ".edu", ".gov"]
            if !target.contains(" ") && domains.contains(where: { target.lowercased().contains($0) }) {
                let validURL = target.hasPrefix("http://") || target.hasPrefix("https://") ? target : "https://" + target
                return .openWebURL(validURL)
            }
        }

        // 2. Folder Creation
        if lower.hasPrefix("create folder ") || lower.hasPrefix("make folder ") || lower.hasPrefix("new folder ") {
            let folderName = trimmed.components(separatedBy: " ").dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !folderName.isEmpty && !folderName.contains("/") {
                return .createFolder(path: folderName)
            }
        }

        // 3. File Creation
        if lower.hasPrefix("create file ") || lower.hasPrefix("new file ") {
            let remainder = trimmed.components(separatedBy: " ").dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = remainder.components(separatedBy: " with content ")
            let filename = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let content = parts.count > 1 ? parts[1] : ""
            if !filename.isEmpty && !filename.contains("/") {
                return .createText(path: filename, text: content)
            }
        }

        // 4. File Reading
        if lower.hasPrefix("read file ") || lower.hasPrefix("show file ") {
            let prefix = lower.hasPrefix("read file ") ? "read file " : "show file "
            let filename = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !filename.isEmpty && !filename.contains("/") {
                return .readText(path: filename)
            }
        }

        // 5. Applications
        if lower.hasPrefix("open ") || lower.hasPrefix("launch ") {
            let appName = lower.hasPrefix("open ") ? String(lower.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines) : String(lower.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            let appMap: [String: String] = [
                "safari": "com.apple.Safari",
                "terminal": "com.apple.Terminal",
                "finder": "com.apple.finder",
                "notes": "com.apple.Notes",
                "mail": "com.apple.mail",
                "calendar": "com.apple.iCal",
                "messages": "com.apple.MobileSMS",
                "music": "com.apple.Music",
                "maps": "com.apple.Maps",
                "calculator": "com.apple.calculator",
                "xcode": "com.apple.dt.Xcode",
                "settings": "com.apple.systempreferences",
                "system settings": "com.apple.systempreferences",
                "preferences": "com.apple.systempreferences",
                "system preferences": "com.apple.systempreferences",
                "textedit": "com.apple.TextEdit",
                "preview": "com.apple.Preview",
                "reminders": "com.apple.reminders",
                "photos": "com.apple.Photos",
                "chrome": "com.google.Chrome",
                "google chrome": "com.google.Chrome",
                "code": "com.microsoft.VSCode",
                "vs code": "com.microsoft.VSCode",
                "vscode": "com.microsoft.VSCode",
                "visual studio code": "com.microsoft.VSCode",
                "spotify": "com.spotify.client",
                "slack": "com.tinyspeck.slackmacgap",
                "discord": "com.hnc.Discord",
                "notion": "notion.id",
                "telegram": "ru.keepcoder.Telegram",
                "whatsapp": "net.whatsapp.WhatsApp",
                "docker": "com.docker.docker",
                "activity monitor": "com.apple.ActivityMonitor",
                "weather": "com.apple.weather",
                "podcasts": "com.apple.podcasts",
                "app store": "com.apple.AppStore",
                "keynote": "com.apple.iWork.Keynote",
                "pages": "com.apple.iWork.Pages",
                "numbers": "com.apple.iWork.Numbers"
            ]
            if let bundleID = appMap[appName] {
                return .launchApplication(bundleID: bundleID)
            }
            for base in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                for name in [appName.capitalized, appName.uppercased(), appName] {
                    let candidate = base + "/" + name + ".app"
                    if let bundle = Bundle(path: candidate), let id = bundle.bundleIdentifier {
                        return .launchApplication(bundleID: id)
                    }
                }
            }
        }
        return nil
    }

    private func detectWebSearchQuery(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = [
            "search the web for ",
            "search web for ",
            "search for ",
            "research ",
            "look up "
        ]
        for p in prefixes {
            if lower.hasPrefix(p) {
                let query = String(trimmed.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty { return query }
            }
        }
        return nil
    }

    func detectMovementCommand(_ text: String) -> DotMovementCommand? {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))
        guard clean.count <= 100 else { return nil }

        let prefixes = [
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "please ", "hey dot ", "dot ", "i want you to ", "try to ",
            "пожалуйста ", "дот "
        ]
        for p in prefixes {
            if clean.hasPrefix(p) {
                clean = String(clean.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))

        // Corner / Center checks
        if clean.contains("top left") || clean.contains("top-left") || clean.contains("upper left") ||
           clean == "left top" || clean == "влево вверх" || clean.contains("левый верхний") {
            return .topLeft
        }
        if clean.contains("top right") || clean.contains("top-right") || clean.contains("upper right") ||
           clean == "right top" || clean == "вправо вверх" || clean.contains("правый верхний") {
            return .topRight
        }
        if clean.contains("bottom left") || clean.contains("bottom-left") || clean.contains("lower left") ||
           clean == "left bottom" || clean == "влево вниз" || clean.contains("левый нижний") {
            return .bottomLeft
        }
        if clean.contains("bottom right") || clean.contains("bottom-right") || clean.contains("lower right") ||
           clean == "right bottom" || clean == "вправо вниз" || clean.contains("правый нижний") {
            return .bottomRight
        }
        if clean == "center" || clean == "middle" || clean.contains("to center") || clean.contains("to the center") ||
           clean.contains("center yourself") || clean.contains("to middle") || clean.contains("to the middle") ||
           clean == "в центр" || clean.contains("по центру") || clean.contains("посередине") {
            return .center
        }

        // Directional checks
        // Left
        if clean == "move left" || clean == "go left" || clean == "step left" || clean == "slide left" || clean == "shift left" ||
           clean == "to the left" || clean == "to left" || clean == "left" || clean.hasPrefix("move to the left") || clean.hasPrefix("go to the left") ||
           clean.hasPrefix("move left") || clean.hasPrefix("go left") || clean.hasPrefix("step left") ||
           clean == "влево" || clean == "налево" || clean.contains("подвинься влево") {
            return .left
        }
        // Right
        if clean == "move right" || clean == "go right" || clean == "step right" || clean == "slide right" || clean == "shift right" ||
           clean == "to the right" || clean == "to right" || clean == "right" || clean.hasPrefix("move to the right") || clean.hasPrefix("go to the right") ||
           clean.hasPrefix("move right") || clean.hasPrefix("go right") || clean.hasPrefix("step right") ||
           clean == "вправо" || clean == "направо" || clean.contains("подвинься вправо") {
            return .right
        }
        // Up
        if clean == "move up" || clean == "go up" || clean == "step up" || clean == "slide up" || clean == "shift up" ||
           clean == "higher" || clean == "up" || clean == "upwards" || clean.hasPrefix("move up") || clean.hasPrefix("go up") ||
           clean == "вверх" || clean == "наверх" || clean.contains("подвинься вверх") {
            return .up
        }
        // Down
        if clean == "move down" || clean == "go down" || clean == "step down" || clean == "slide down" || clean == "shift down" ||
           clean == "lower" || clean == "down" || clean == "downwards" || clean.hasPrefix("move down") || clean.hasPrefix("go down") ||
           clean == "вниз" || clean.contains("подвинься вниз") {
            return .down
        }

        // Away / Dodge
        if clean.contains("move away") || clean.contains("go away") || clean.contains("step aside") ||
           clean.contains("out of the way") || clean == "dodge" || clean == "evade" || clean.contains("scoot over") ||
           clean == "отойди" || clean == "уйди" || clean.contains("в сторону") {
            return .away
        }

        // General move / relocate / random
        if clean == "move" || clean == "move around" || clean == "relocate" || clean == "random move" ||
           clean == "change position" || clean == "move somewhere" || clean == "move somewhere else" ||
           clean == "go somewhere else" || clean == "wander" || clean == "move yourself" ||
           clean == "двигайся" || clean == "подвигайся" || clean == "переместись" || clean == "смени позицию" {
            return .random
        }

        return nil
    }

    func handleTaskProgress(_ event: ResearchTaskProgress.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = taskProgress.receive(event, now: now)
        if accepted {
            updateTaskProgressUI(now: now)
            ensureTaskProgressTicker()
        }
    }

    func updateTaskProgressUI(now: Double = ProcessInfo.processInfo.systemUptime) {
        taskHalo = taskProgress.progress.halo
        taskStage = taskProgress.progress.snapshot?.stage
        taskStatusText = taskProgress.progress.textStatus
        pollTaskSpeech(now: now)
    }

    private func ensureTaskProgressTicker() {
        guard taskProgressTicker == nil else { return }
        taskProgressTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                let now = ProcessInfo.processInfo.systemUptime
                self.updateTaskProgressUI(now: now)
                if self.taskHalo == .hidden && self.activeSpeechUpdateID == nil {
                    break
                }
            }
            self?.taskProgressTicker = nil
        }
    }

    private func pollTaskSpeech(now: Double) {
        var context = LongTaskProgress.SpeechContext()
        context.ready = runtime.isReady()
        context.muted = defaults.bool(forKey: "voiceMuted")
        context.userSpeaking = stt.recording && stt.level > 0.15
        context.listening = stt.recording || stt.transcribing
        context.voiceBusy = runtime.ttsSpeaking() && (activeSpeechUpdateID == nil)
        context.foregroundInterrupted = interactionPaused || hovered || historyPresented
        context.quiet = false
        context.callActive = false
        _ = taskProgress.setSpeechContext(context)

        guard activeSpeechUpdateID == nil else { return }
        guard let speech = taskProgress.takeSpeech(now: now) else { return }
        activeSpeechUpdateID = speech.id
        DiagnosticChatLogger.record(role: "dot (task)", text: speech.text)
        do {
            try runtime.startVoice(speech.id)
            runtime.enqueueVoice(speech.text, speech.id)
            runtime.completeVoice(speech.id)
        } catch {
            activeSpeechUpdateID = nil
        }
    }
    var historyPresented = false { didSet { if historyPresented { cancelForInteraction() }; updateProactiveContext() } }
    var visible = true { didSet { if !visible { cancelTurn() }; updateProactiveContext() } }
    var followupPending: Bool { followup.pending }
    var canSubmitTyped: Bool { !shuttingDown && runtime.isReady() }
    let stt: STTManager
    let tts: TTSManager
    let engine: EngineManager
    let screen = ScreenContext()
    @Published var screenEnabled: Bool { didSet { ScreenPrivacyPreference.setEnabled(screenEnabled, in: defaults); screen.enabled = screenEnabled; placementInvalidated?(); cancelTurn() } }
    @Published private(set) var screenContextUsed = false
    @Published private(set) var capturingScreen = false
    private var gate = TurnGate()
    private var work: Task<Void, Never>?
    private let warmup = TurnWarmup()
    private var generating = false
    private var currentTurnIsTyped = false
    private var voiceDeliveryFailed = false
    private var history: [ChatMessage] = []
    private var chunker = SentenceBuffer()
    private var clickedAt = 0.0
    private var firstReasoning = false
    private var firstAnswer = false
    private var firstAudio = false
    private var speechEndedAt: Double?
    private var silenceSatisfiedAt: Double?
    private static let timingLog = Logger(subsystem: "app.dot", category: "timing")
    private func timing(_ stage: String) {
        // Durations only. Never log speech, prompts, replies or model paths.
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - clickedAt) * 1000)
        Self.timingLog.notice("DOT_TIMING \(stage, privacy: .public)=\(milliseconds)ms")
    }

    private static let runtimeLog = Logger(subsystem: "app.dot", category: "runtime")
    private func logFailure(_ error: Error, stage: PipelineDiagnostic.Stage) {
        let actualStage: PipelineDiagnostic.Stage = error is ScreenContextGate.Failure ? .capture : stage
        let reason: PipelineDiagnostic.Reason
        if let value = error as? ScreenContext.ScreenFailure {
            switch value {
            case .permission: reason = .permission
            case .unsupported: reason = .unsupported
            case .unavailable: reason = .unavailable
            }
        } else if let value = error as? ScreenContextGate.Failure {
            switch value {
            case .permissionDenied: reason = .permission
            case .unsupportedModel: reason = .unsupported
            case .disabled, .unavailable, .stale, .invalidImage: reason = .captureFailed
            }
        } else if let value = error as? EngineError {
            switch value {
            case .configuration, .unavailable, .busy: reason = .unavailable
            case .identity: reason = .identity
            case .response: reason = .invalidResponse
            case .empty: reason = .emptyResponse
            }
        } else if error is ResponseLimit { reason = .resourceLimit }
        else if error is URLError { reason = .transport }
        else { reason = stage == .capture ? .captureFailed : stage == .voice ? .voiceFailed : .unknown }
        guard let diagnostic = PipelineDiagnostic.failure(stage: actualStage, reason: reason,
            cancelled: Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled) else { return }
        Self.runtimeLog.error("\(diagnostic.logLine, privacy: .public)")
    }

    init(engine: EngineManager? = nil, textHistory: ConversationHistoryModel? = nil,
         defaults: UserDefaults = .standard, followup: VoiceFollowup? = nil,
         proactive: ProactiveBehavior? = nil, runtime: ChatRuntime? = nil) {
        let stt = STTManager(), tts = TTSManager()
        self.stt = stt; self.tts = tts
        self.engine = engine ?? EngineManager()
        self.textHistory = textHistory ?? ConversationHistoryModel()
        self.ftsStore = (try? LocalFTSStore()) ?? (try! LocalFTSStore(inMemory: true))
        self.defaults = defaults
        voiceTiming = VoiceTimingSettings(defaults: defaults)
        skinPreferences = SkinPreferences(defaults: defaults)
        self.proactive = proactive ?? ProactiveBehavior(defaults: defaults)
        self.followup = followup ?? VoiceFollowup()
        firstUseHint = !defaults.bool(forKey: "dot.interactionHintDismissed.v1")
        pinned = defaults.bool(forKey: "petPinned")
        screenEnabled = ScreenPrivacyPreference.enabled(in: defaults)
        self.runtime = runtime ?? ChatRuntime(
            isReady: { OfflinePreparation.shared.ready },
            startPreparation: { OfflinePreparation.shared.start(nativeRecognizerAvailable: WhisperRecognizer.available) },
            microphoneAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            currentRoute: { VoiceAudioRoute.current() }, screenAuthorized: { CGPreflightScreenCaptureAccess() },
            startVoice: { try tts.start(id: $0) }, enqueueVoice: { tts.enqueue($0, id: $1) },
            completeVoice: { tts.markGenerationComplete(id: $0) }, stopVoice: { tts.stop() },
            ttsSpeaking: { tts.speaking }, startCapture: { await stt.start(id: $0, settings: $1, invitation: $2) },
            stopCapture: { stt.cancel() }, recording: { stt.recording }, transcribing: { stt.transcribing })
        let followup = self.followup, textHistory = self.textHistory, proactive = self.proactive
        textHistory.onDelete = { [weak self] in self?.reset() }
        followup.environment = { [weak self] in
            guard let self else { return .init(ready: false, microphoneAuthorized: false, screenAuthorized: false, interacting: true) }
            let current = self.runtime.currentRoute()
            let routeMatches = (self.voiceRoute == nil || current == nil || (self.voiceRoute?.input == current?.input && self.voiceRoute?.output == current?.output))
            return .init(ready: self.runtime.isReady() && self.visible && !self.runtime.ttsSpeaking() && !self.runtime.recording() && !self.runtime.transcribing() && routeMatches,
                microphoneAuthorized: self.runtime.microphoneAuthorized(),
                screenAuthorized: true,
                interacting: self.interactionPaused || self.historyPresented || self.controlInteraction)
        }
        followup.onInvite = { [weak self] previous, continuation in
            guard let self, self.gate.accepts(previous), self.visible, !self.interactionPaused, !self.controlInteraction else { return }
            self.beginListening(continuation: continuation)
        }
        stt.onCaptureEnded = { [weak self] id, reason in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn()
            if let message = reason.recoveryMessage { self.block(message, issue: .speech) }
            else { self.showCaptureOutcome(reason == .noSpeech ? "No reply" : "Stopped") }
        }
        stt.onSpeechEnded = { [weak self] id, evidence in
            guard let self, self.gate.accepts(id) else { return }
            guard [evidence.captureStartedAt, evidence.firstSpeechAt, evidence.speechEndedAt, evidence.silenceSatisfiedAt].allSatisfy(\.isFinite),
                  VoiceTimingSettings.silenceChoices.contains(evidence.selectedSilenceSeconds),
                  evidence.captureStartedAt <= evidence.firstSpeechAt,
                  evidence.firstSpeechAt <= evidence.speechEndedAt,
                  abs(evidence.silenceSatisfiedAt - evidence.speechEndedAt - evidence.selectedSilenceSeconds) < 0.000001 else { return }
            self.speechEndedAt = evidence.speechEndedAt
            self.silenceSatisfiedAt = evidence.silenceSatisfiedAt
            let milliseconds = Int(evidence.selectedSilenceSeconds * 1000)
            Self.timingLog.notice("DOT_TIMING selected_silence=\(milliseconds)ms")
        }
        screen.enabled = screenEnabled
        proactiveEvidence.recordUser(turn: UUID(), now: ProcessInfo.processInfo.systemUptime)
        self.runtime.startPreparation()
        stt.onFinal = { [weak self] id, text in
            guard let self, self.gate.accepts(id) else { return }
            guard let satisfied = self.silenceSatisfiedAt,
                  ProcessInfo.processInfo.systemUptime >= satisfied else {
                self.cancelTurn()
                self.block("Listening timing could not be verified. Please try again.", issue: .speech)
                return
            }
            self.submit(text, id: id)
        }
        stt.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn(); self.block(message, issue: .speech)
        }
        stt.onRecording = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.timing("capture_started")
            do { try self.runtime.startVoice(id) }
            catch {
                self.logFailure(error, stage: .voice)
                self.cancelTurn(); self.block(error.localizedDescription, issue: .voice); return
            }
            self.timing("warmup_started")
            self.warmup.start(turn: id) { [weak self] in
                guard let self, self.gate.accepts(id) else { throw CancellationError() }
                _ = try await self.engine.verifyConnection()
                guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                self.timing("warmup_ready")
            }
        }
        tts.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            if self.currentTurnIsTyped { self.continueTypedWithoutVoice(id: id); return }
            let diagnostic = PipelineDiagnostic(stage: .voice, outcome: .failed, reason: .voiceFailed)
            Self.runtimeLog.error("\(diagnostic.logLine, privacy: .public)")
            self.textHistory.recordAssistant(turn: id, text: self.answer, event: .failed(.voice))
            self.cancelTurn(); self.block(message, issue: .voice)
        }
        tts.onStarted = { [weak self] id in
            guard let self, self.gate.accepts(id), !self.voiceDeliveryFailed, !self.firstAudio else { return }
            self.firstAudio = true; self.timing("playback_started")
            self.textHistory.recordAssistant(turn: id, text: self.answer, event: .playbackStarted)
            // Player scheduling is not an acoustic measurement. Keep these metrics labelled.
            let now = ProcessInfo.processInfo.systemUptime
            if let ended = self.speechEndedAt, let satisfied = self.silenceSatisfiedAt {
                let total = Int((now - ended) * 1000), processing = Int((now - satisfied) * 1000)
                Self.timingLog.notice("DOT_TIMING speech_end_to_playback_scheduled=\(total)ms post_silence_to_playback_scheduled=\(processing)ms")
            }
        }
        tts.onFinalPlayback = { [weak self] id in
            guard let self else { return }
            if id == self.activeSpeechUpdateID {
                self.taskProgress.finishSpeech(id: id)
                self.activeSpeechUpdateID = nil
                self.phase = .idle
                return
            }
            guard self.gate.accepts(id), !self.voiceDeliveryFailed else { return }
            self.timing("final_playback_complete")
            self.textHistory.recordAssistant(turn: id, event: .playbackCompleted)
            self.followup.playbackFinished(turn: id)
            self.finishProactiveTurn(id: id)
        }
        tts.onDrained = { [weak self] id in
            guard let self else { return }
            if id == self.activeSpeechUpdateID {
                self.phase = .idle
                return
            }
            guard self.gate.accepts(id), !self.voiceDeliveryFailed else { return }
            self.phase = self.generating ? .thinking : .idle
            if !self.generating { self.followup.playbackFinished(turn: id) }
        }
        proactive.onOpportunity = { [weak self] in self?.suggest($0) }
        proactive.onCancel = { [weak self] opportunity in
            guard let self, self.proactiveTurn?.opportunity == opportunity else { return }
            self.cancelTurn()
        }
        proactive.onContextChange = { [weak self] change in
            guard let self, change.applicationIdentifier != Bundle.main.bundleIdentifier else { return }
            self.proactiveContextChange = change
            self.proactiveContextChangedAfterUser = true
            self.updateProactiveContext()
        }
    }

    func startProactivity() { proactive.start(); updateProactiveContext() }
    func stopProactivity() { proactive.stop() }
    /// Native control-down must not swap Stop for Talk before mouse-up dispatches
    /// the button action. Revoke future invitations, but let that action own any
    /// active-turn cancellation. This flag intentionally does not publish UI state.
    func setControlInteraction(_ active: Bool) {
        controlInteraction = active
        if active { followup.cancel() }
        updateProactiveContext()
    }
    /// Call from native menu/pointer/readiness maintenance. The engine's own
    /// background turn is not mistaken for foreground work and cancelled by itself.
    func updateProactiveContext(externalInteractionBusy: Bool? = nil) {
        if let externalInteractionBusy { self.externalInteractionBusy = externalInteractionBusy }
        let now = ProcessInfo.processInfo.systemUptime
        let userBusy = proactiveTurn == nil && (phase.isActive || runtime.recording() || runtime.transcribing() || followupPending)
        let context = ProactiveContext(
            ready: !shuttingDown && runtime.isReady() && issue == nil
                && (!screenEnabled || runtime.screenAuthorized()) && proactiveEvidence.isRecent(now: now),
            visible: visible, foregroundBusy: userBusy,
            interactionBusy: interactionPaused || historyPresented || hovered || self.externalInteractionBusy
                || (controlInteraction && proactiveTurn == nil),
            engineBusy: generating || work != nil || runtime.ttsSpeaking() || followupPending || controlInteraction)
        proactive.updateContext(context)
        if proactiveContextChange == nil {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                proactiveContextChange = .init(reason: .foregroundApplicationChanged, applicationIdentifier: frontApp.bundleIdentifier)
                proactiveContextChangedAfterUser = true
            }
        }
        if context.permitsBackgroundWork, !context.engineBusy, proactiveContextChangedAfterUser,
           let change = proactiveContextChange,
           let key = proactiveEvidence.key(change: change, now: now, ownIdentifier: Bundle.main.bundleIdentifier) {
            proactive.offerContext(key: key, reason: change.reason)
        }
    }

    /// The renderer moves inside its already allocated edge padding; this never
    /// changes the panel origin or bypasses safe roaming. Return value sets only
    /// the native animation tick rate while a visible offset is moving.
    @discardableResult
    func updateIdleMotion(now: Double, externallyPaused: Bool, pointerNearby: Bool, reduceMotion: Bool, moved: Bool) -> Bool {
        if moved { idleMotion.noteMovement(at: now) }
        let context = IdleMotionContext(visible: visible, idle: phase == .idle && !followupPending,
            paused: externallyPaused || proactive.paused || historyPresented,
            pinned: pinned, dragging: interactionPaused, pointerNearby: pointerNearby || hovered,
            reduceMotion: reduceMotion, motionScale: skinPreferences.motionDetail.movementScale,
            availablePadding: max(0, Double(PetLayout.edgePadding) - 2))
        let offset = idleMotion.sample(now: now, context: context)
        if idleMotionOffset != offset { idleMotionOffset = offset }
        return offset != .zero
    }

    private func suggest(_ opportunity: ProactiveOpportunity) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !shuttingDown, visible, phase == .idle, !followupPending,
              !interactionPaused, !historyPresented, !hovered, !externalInteractionBusy, !controlInteraction,
              runtime.isReady(),
              proactiveEvidence.isRecent(now: now), proactive.activeOpportunity?.id == opportunity.id else {
            proactive.complete(id: opportunity.id); return
        }
        // Advance only the single existing conversation owner. No second engine,
        // random microphone opening, or background permission request is created.
        let id = gate.advance()
        work?.cancel(); warmup.cancel(); runtime.stopCapture(); runtime.stopVoice(); screen.cancel()
        proactiveTurn = (opportunity.id, id)
        voiceRoute = runtime.currentRoute()
        followup.begin(turn: id)
        clickedAt = now; firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""; displayedAnswerTurn = nil; automaticReply = false
        currentTurnIsTyped = false; voiceDeliveryFailed = false; voiceDeliveryNotice = nil
        screenContextUsed = false; generating = true; phase = .thinking
        var promptText = ProactiveReplyBuffer.prompt
        if let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            promptText += "\n[Active Application: \(frontApp)]"
        }
        let snapshot = Array(history.suffix(10)) + [ChatMessage(role: "user", content: promptText)]
        work = Task(priority: .utility) { [weak self] in
            guard let self, self.gate.accepts(id), !Task.isCancelled else { return }
            var buffer = ProactiveReplyBuffer()
            var failureStage = ConversationHistoryFailureStage.generation
            do {
                if self.screenEnabled && self.runtime.screenAuthorized() {
                    try? self.screen.prepare(turn: id, requestPermission: false)
                }
                let question = try await self.engine.chat(history: snapshot, purpose: .background, onDelta: { [weak self] delta in
                    guard let self, self.gate.accepts(id), self.proactiveTurn?.turn == id else { return }
                    buffer.append(delta)
                }, screenImage: { [weak self] hasVision in
                    guard let self, self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    guard self.screenEnabled && self.runtime.screenAuthorized() else { return nil }
                    self.capturingScreen = true
                    defer { if self.gate.accepts(id) { self.capturingScreen = false } }
                    let image = try? await self.screen.capture(turn: id, modelHasVision: hasVision)
                    guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    self.screenContextUsed = image != nil
                    return image
                })
                guard self.gate.accepts(id), self.proactiveTurn?.turn == id, !Task.isCancelled else { return }
                let result = try buffer.completed(question: question?.text)
                guard case .speak(let content, let question) = result else {
                    self.finishProactiveTurn(id: id)
                    self.cancelTurn()
                    return
                }
                let fingerprint = result.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !self.recentProactiveReplies.contains(fingerprint) else {
                    self.finishProactiveTurn(id: id)
                    self.cancelTurn()
                    return
                }
                self.textHistory.beginAssistant(turn: id)
                self.displayedAnswerTurn = id
                self.answer = result.text
                self.textHistory.recordAssistant(turn: id, text: result.text, event: .generated)
                DiagnosticChatLogger.record(role: "dot (proactive)", text: result.text)
                failureStage = .voice
                try self.runtime.startVoice(id)
                self.followup.generationFinished(turn: id, hasQuestion: question != nil)
                var sentences = SentenceBuffer()
                for sentence in sentences.feed(content) { self.runtime.enqueueVoice(sentence, id) }
                if let tail = sentences.flush() { self.runtime.enqueueVoice(tail, id) }
                if let question, !content.contains(question) { self.runtime.enqueueVoice(question, id) }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.answer = result.text
                self.history.append(ChatMessage(role: "assistant", content: result.text))
                if self.history.count > 12 { self.history.removeFirst(self.history.count - 12) }
                self.recentProactiveReplies.append(fingerprint)
                if self.recentProactiveReplies.count > 16 { self.recentProactiveReplies.removeFirst() }
                self.generating = false
                self.runtime.completeVoice(id)
                self.phase = self.runtime.ttsSpeaking() ? .speaking : .idle
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: failureStage == .voice ? .voice : .response)
                self.textHistory.recordAssistant(turn: id, text: self.answer, event: .failed(failureStage))
                // An optional suggestion failure stays silent and cannot open a mic.
                self.finishProactiveTurn(id: id)
                self.cancelTurn()
            }
            if self.gate.accepts(id) { self.work = nil; self.updateProactiveContext() }
        }
    }

    private func finishProactiveTurn(id: UUID) {
        guard let active = proactiveTurn, active.turn == id else { return }
        proactiveTurn = nil
        proactive.complete(id: active.opportunity)
        updateProactiveContext()
    }

    /// Manual clicks interrupt; automatic capture requires the same-turn final-question gate.
    func clicked() {
        if !OfflinePreparation.shared.ready {
            if OfflinePreparation.shared.state == .paused {
                OfflinePreparation.shared.retry()
            }
            expressionRevision &+= 1
            return
        }
        guard !shuttingDown, runtime.isReady() else { return }
        dismissFirstUseHint()
        beginListening(continuation: nil)
    }
    func dismissFirstUseHint() {
        guard firstUseHint else { return }
        firstUseHint = false; defaults.set(true, forKey: "dot.interactionHintDismissed.v1")
    }
    /// Explicit typed submission is already a finished utterance. It neither
    /// requests microphone access nor waits for a speech-silence deadline.
    @discardableResult
    func submitTyped(_ text: String) -> Bool {
        let value = TypedMessageValidation.cleaned(text)
        guard canSubmitTyped, TypedMessageValidation.problem(value) == nil else { return false }
        onForegroundInteraction?()
        dismissFirstUseHint()
        let id = cancelTurn()
        currentTurnIsTyped = true; voiceDeliveryFailed = false; voiceDeliveryNotice = nil
        voiceRoute = runtime.currentRoute(); followup.begin(turn: id)
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""; displayedAnswerTurn = nil; lastAttemptedText = value
        do {
            try screen.prepare(turn: id, requestPermission: false)
        } catch {
            Self.runtimeLog.notice("Screen preparation skipped for typed turn: \(error.localizedDescription, privacy: .public)")
        }
        do { try runtime.startVoice(id) }
        catch { logFailure(error, stage: .voice); continueTypedWithoutVoice(id: id) }
        warmup.start(turn: id) { [weak self] in
            guard let self, self.gate.accepts(id) else { throw CancellationError() }
            _ = try await self.engine.verifyConnection()
            guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
        }
        submit(value, id: id, typed: true)
        return true
    }
    func retryLastTurn() {
        if let lastAttemptedText { _ = submitTyped(lastAttemptedText) }
        else { clicked() }
    }
    func continueWithoutScreen() {
        let text = lastAttemptedText
        screenEnabled = false
        if let text { _ = submitTyped(text) } else { clicked() }
    }
    private func beginListening(continuation: UUID?) {
        onForegroundInteraction?()
        let invitation = continuation != nil
        let id = cancelTurn(preserveFollowup: invitation)
        voiceDeliveryNotice = nil
        voiceRoute = runtime.currentRoute()
        followup.begin(turn: id, continuation: continuation)
        automaticReply = invitation
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""; displayedAnswerTurn = nil
        lastAttemptedText = nil
        phase = .listening
        work = Task { [weak self] in
            guard let self, !Task.isCancelled, self.gate.accepts(id) else { return }
            do { try self.screen.prepare(turn: id, requestPermission: !invitation) }
            catch {
                Self.runtimeLog.notice("Screen preparation skipped: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled, self.gate.accepts(id) else { return }
            await self.runtime.startCapture(id, self.voiceTiming, invitation)
        }
    }

    private func submit(_ text: String, id: UUID, typed: Bool = false) {
        guard gate.accepts(id) else { return }
        DiagnosticChatLogger.record(role: "user", text: text)
        timing(typed ? "text_submitted" : "final_transcript")
        lastAttemptedText = text
        proactiveEvidence.recordUser(turn: id, now: ProcessInfo.processInfo.systemUptime)
        proactiveContextChangedAfterUser = false
        phase = .thinking; generating = true
        answer = ""; displayedAnswerTurn = id; chunker = SentenceBuffer()
        history.append(ChatMessage(role: "user", content: text))
        textHistory.append(role: .user, text: text, turn: id)
        textHistory.beginAssistant(turn: id)
        if voiceDeliveryFailed { textHistory.recordAssistant(turn: id, event: .voiceFailedContinuing) }
        if history.count > 12 { history.removeFirst(history.count - 12) }

        if let moveCmd = self.detectMovementCommand(text), let replyText = self.onMove?(moveCmd) {
            respondDirectly(replyText, id: id)
            return
        }

        if let action = self.detectNativeAction(text) {
            work = Task { [weak self] in
                guard let self, self.gate.accepts(id) else { return }
                let result = await self.onExecuteAction?(action)
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                let replyText: String
                switch action {
                case .launchApplication:
                    replyText = result?.receipt.status == .succeeded ? "Opening application." : "Could not open that application."
                case .openWebURL(let url):
                    replyText = result?.receipt.status == .succeeded || result?.receipt.status == .handedOff ? "Opening \(url)." : "Could not open URL."
                case .createFolder(let path):
                    replyText = result?.receipt.status == .succeeded ? "Created folder \(path)." : "Could not create folder \(path)."
                case .createText(let path, _):
                    replyText = result?.receipt.status == .succeeded ? "Created file \(path)." : "Could not create file \(path)."
                case .readText(let path):
                    if let content = result?.text {
                        replyText = "File \(path): \(content)"
                    } else {
                        replyText = "Could not read file \(path)."
                    }
                default:
                    replyText = "Action completed."
                }
                DiagnosticChatLogger.record(role: "dot", text: replyText)
                self.answer = replyText
                self.history.append(ChatMessage(role: "assistant", content: replyText))
                self.textHistory.recordAssistant(turn: id, text: replyText, event: .generated)
                if !self.voiceDeliveryFailed {
                    self.enqueueVoice(replyText, id: id)
                    self.runtime.completeVoice(id)
                }
                self.generating = false
                self.phase = !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() ? .speaking : .idle
            }
            return
        }

        let cleanLower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
        if cleanLower == "what time is it" || cleanLower == "what is the time" || cleanLower == "what's the time" || cleanLower == "current time" || cleanLower == "time" {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let replyText = "It is \(formatter.string(from: Date()))."
            respondDirectly(replyText, id: id)
            return
        }
        if cleanLower == "what day is it" || cleanLower == "what's today" || cleanLower == "what is today" || cleanLower == "what's the date" || cleanLower == "what is the date" || cleanLower == "what is the date today" || cleanLower == "today's date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            let replyText = "Today is \(formatter.string(from: Date()))."
            respondDirectly(replyText, id: id)
            return
        }

        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("remember that ") || lower.hasPrefix("remember ") || lower.hasPrefix("my name is ") || lower.hasPrefix("i prefer ") || lower.hasPrefix("i like ") {
            var fact = text
            if let range = fact.range(of: "(?i)^remember that\\s+", options: .regularExpression) {
                fact.removeSubrange(range)
            } else if let range = fact.range(of: "(?i)^remember:?\\s+", options: .regularExpression) {
                fact.removeSubrange(range)
            }
            let factToSave = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            if !factToSave.isEmpty {
                Task { [weak self] in
                    _ = try? await self?.ftsStore.saveMemory(category: .userPreference, fact: factToSave, isCorrection: false)
                }
            }
        }

        if let query = self.detectWebSearchQuery(text) {
            self.onRequestResearch?(query)
        }

        let snapshot = history
        work = Task { [weak self] in
            guard let self else { return }
            var stage = PipelineDiagnostic.Stage.readiness
            do {
                try await self.warmup.wait(turn: id)
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                var chatInput = snapshot
                let facts = await (try? self.ftsStore.searchMemories(query: text, limit: 3)) ?? []
                let evidence = await (try? self.ftsStore.searchEvidence(query: text, limit: 2)) ?? []
                var memoryContext: [String] = []
                for f in facts { memoryContext.append("Memory: \(f.fact)") }
                for e in evidence { memoryContext.append("Document [\(e.title)]: \(e.snippet)") }
                if !memoryContext.isEmpty {
                    let ctxText = "\n[Context: " + memoryContext.joined(separator: " | ") + "]"
                    if let lastIdx = chatInput.indices.last {
                        chatInput[lastIdx] = ChatMessage(role: chatInput[lastIdx].role, content: chatInput[lastIdx].content + ctxText)
                    }
                }
                let snapshot = chatInput
                let question = try await self.engine.chat(history: snapshot, onDelta: { [weak self] content in
                    guard let self, self.gate.accepts(id) else { return }
                    if !self.firstAnswer { self.firstAnswer = true; self.timing("first_answer") }
                    self.answer += content
                    if !self.voiceDeliveryFailed {
                        for sentence in self.chunker.feed(content) { self.enqueueVoice(sentence, id: id) }
                        if !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() { self.phase = .speaking }
                    }
                }, onReasoning: { [weak self] in
                    guard let self, self.gate.accepts(id), !self.firstReasoning else { return }
                    self.firstReasoning = true; self.timing("first_reasoning")
                }, screenImage: { [weak self] hasVision in
                    guard let self, self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    stage = .capture
                    self.capturingScreen = self.screen.enabled
                    if self.screen.enabled {
                        let diagnostic = PipelineDiagnostic(stage: .capture, outcome: .started)
                        Self.runtimeLog.notice("\(diagnostic.logLine, privacy: .public)")
                    }
                    defer { if self.gate.accepts(id) { self.capturingScreen = false } }
                    let image: CapturedScreenImage?
                    do {
                        image = try await self.screen.capture(turn: id, modelHasVision: hasVision)
                    } catch {
                        Self.runtimeLog.notice("Screen capture unavailable, proceeding without screen image: \(error.localizedDescription, privacy: .public)")
                        image = nil
                    }
                    guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    if image != nil {
                        let diagnostic = PipelineDiagnostic(stage: .capture, outcome: .ready)
                        Self.runtimeLog.notice("\(diagnostic.logLine, privacy: .public)")
                    }
                    stage = .response
                    self.screenContextUsed = image != nil; return image
                })
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                if let tail = self.chunker.flush() { self.enqueueVoice(tail, id: id) }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                let shouldFollowup = !self.voiceDeliveryFailed
                if !self.voiceDeliveryFailed { self.followup.generationFinished(turn: id, hasQuestion: shouldFollowup) }
                if let question {
                    let qTrimmed = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let ansTrimmed = self.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ansTrimmed.hasSuffix(qTrimmed) && !ansTrimmed.localizedCaseInsensitiveContains(qTrimmed) {
                        self.answer += (self.answer.isEmpty ? "" : " ") + qTrimmed
                        self.enqueueVoice(qTrimmed, id: id)
                    }
                }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.history.append(ChatMessage(role: "assistant", content: self.answer))
                self.textHistory.recordAssistant(turn: id, text: self.answer, event: .generated)
                let finalAnswer = self.answer
                DiagnosticChatLogger.record(role: "dot", text: finalAnswer)
                Task { [weak self] in
                    guard let self else { return }
                    let uRec = ConversationHistoryRecord(id: UUID(), date: Date(), role: .user, text: text, turnID: id, generation: .complete, playback: .notApplicable, generationCompletedAt: nil, playbackStartedAt: nil, playbackCompletedAt: nil, endedAt: nil, failureStage: nil, textTruncated: false)
                    try? await self.ftsStore.indexConversation(record: uRec)
                    let aRec = ConversationHistoryRecord(id: UUID(), date: Date(), role: .assistant, text: finalAnswer, turnID: id, generation: .complete, playback: .completed, generationCompletedAt: nil, playbackStartedAt: nil, playbackCompletedAt: nil, endedAt: nil, failureStage: nil, textTruncated: false)
                    try? await self.ftsStore.indexConversation(record: aRec)
                }
                self.generating = false; self.timing("generation_complete")
                if !self.voiceDeliveryFailed { self.runtime.completeVoice(id) }
                self.phase = !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() ? .speaking : .idle
                if !self.voiceDeliveryFailed && !self.runtime.ttsSpeaking() {
                    self.followup.playbackFinished(turn: id)
                }
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: stage)
                self.textHistory.recordAssistant(turn: id, text: self.answer, event: .failed(.generation))
                let issue: CompanionIssue
                if let failure = error as? ScreenContext.ScreenFailure {
                    switch failure {
                    case .permission: issue = .screenPermission
                    case .unavailable: issue = .screenCapture
                    case .unsupported: issue = .vision
                    }
                } else { issue = stage == .capture || error is ScreenContextGate.Failure ? .screenCapture : .engine }
                self.cancelTurn()
                self.block(error.localizedDescription, issue: issue)
            }
            if self.gate.accepts(id) { self.work = nil; self.updateProactiveContext() }
        }
    }

    private func respondDirectly(_ replyText: String, id: UUID) {
        DiagnosticChatLogger.record(role: "dot", text: replyText)
        self.answer = replyText
        self.history.append(ChatMessage(role: "assistant", content: replyText))
        self.textHistory.recordAssistant(turn: id, text: replyText, event: .generated)
        if !self.voiceDeliveryFailed {
            self.enqueueVoice(replyText, id: id)
            self.runtime.completeVoice(id)
        }
        self.generating = false
        self.phase = !self.voiceDeliveryFailed && self.runtime.ttsSpeaking() ? .speaking : .idle
    }

    private func block(_ message: String, issue: CompanionIssue) {
        DiagnosticChatLogger.record(role: "dot (error)", text: "\(message) [\(issue)]")
        self.issue = issue; phase = .blocked(message)
    }

    private func enqueueVoice(_ text: String, id: UUID) {
        guard gate.accepts(id), !voiceDeliveryFailed else { return }
        runtime.enqueueVoice(text, id)
    }
    /// Audio failure is terminal for this turn's audio, not for explicitly typed
    /// text. The same engine task may finish; no alternate voice is selected.
    private func continueTypedWithoutVoice(id: UUID) {
        guard gate.accepts(id), currentTurnIsTyped, !voiceDeliveryFailed else { return }
        voiceDeliveryFailed = true
        voiceDeliveryNotice = "Voice unavailable. This reply is text only; automatic reply listening is off."
        issue = .voice
        followup.cancel(); automaticReply = false; voiceRoute = nil
        runtime.stopVoice(); chunker = SentenceBuffer()
        textHistory.recordAssistant(turn: id, text: answer, event: .voiceFailedContinuing)
        phase = generating ? .thinking : .idle
    }

    @discardableResult
    func cancelTurn(preserveFollowup: Bool = false) -> UUID {
        captureOutcomeTask?.cancel(); captureOutcomeTask = nil; captureOutcome = nil
        textHistory.recordAssistant(turn: gate.current, text: answer, event: .interrupted)
        proactiveContextChangedAfterUser = false
        let priorProactive = proactiveTurn; proactiveTurn = nil
        if let priorProactive { proactive.complete(id: priorProactive.opportunity) }
        proactive.clearContext()
        expressionRevision &+= 1
        if !preserveFollowup { followup.cancel() }
        automaticReply = false; voiceRoute = nil
        let id = gate.advance()
        work?.cancel(); work = nil; warmup.cancel()
        runtime.stopCapture(); runtime.stopVoice(); screen.cancel(); screenContextUsed = false; capturingScreen = false; generating = false
        currentTurnIsTyped = false; voiceDeliveryFailed = false
        if let speechID = activeSpeechUpdateID {
            activeSpeechUpdateID = nil
            runtime.stopVoice()
            taskProgress.finishSpeech(id: speechID)
        }
        chunker = SentenceBuffer(); issue = nil; phase = .idle
        return id
    }
    func stopCurrentTurn() { cancelTurn(); showCaptureOutcome("Stopped") }
    private func showCaptureOutcome(_ text: String) {
        captureOutcomeTask?.cancel(); captureOutcome = text
        let turn = gate.current
        captureOutcomeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.gate.accepts(turn) else { return }
            self.captureOutcome = nil; self.captureOutcomeTask = nil
        }
    }
    /// Menus and dragging revoke capture without erasing a diagnostic the user is inspecting.
    func cancelForInteraction() {
        let savedIssue = issue, savedPhase = phase
        cancelTurn()
        if case .blocked = savedPhase { issue = savedIssue; phase = savedPhase }
    }
    func cancelForEnvironment(reason: VoiceCaptureEndReason) {
        if stt.captureState != .idle {
            stt.cancel(reason: reason)
        } else if reason == .permissionLost {
            // A typed answer does not need microphone permission. Revoke only
            // the automatic invitation when no capture was using that grant.
            followup.cancel(); automaticReply = false; updateProactiveContext()
        } else {
            cancelTurn()
            if let message = reason.recoveryMessage { block(message, issue: .voice) }
        }
    }
    func reset() { proactiveEvidence.clear(); proactiveContextChangedAfterUser = false; recentProactiveReplies = []; cancelTurn(); history = []; answer = ""; displayedAnswerTurn = nil; voiceDeliveryNotice = nil; lastAttemptedText = nil }
    func beginShutdown() { shuttingDown = true; stopProactivity(); cancelTurn(); textHistory.closeAdmissions() }
    func shutdown() { stopProactivity(); cancelTurn(); stt.shutdown(); tts.shutdown(); engine.shutdown(); OfflinePreparation.shared.shutdown() }
}

struct PetView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var stt: STTManager
    @ObservedObject var tts: TTSManager
    @ObservedObject var skins: SkinPreferences
    @ObservedObject private var preparation = OfflinePreparation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var emotion: PetEmotion {
        if case .blocked = model.phase { return .puzzled }
        if model.issue != nil || preparation.state.isIssue { return .puzzled }
        if model.taskHalo != .hidden || stt.transcribing || preparation.state == .checking || model.capturingScreen || model.placementCapturing {
            return .working
        }
        switch model.phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .blocked: return .puzzled
        }
    }

    var body: some View {
        character
            .onHover { model.hovered = $0 }
            .padding(PetLayout.edgePadding)
            .frame(width: PetLayout.panelSize.width, height: PetLayout.panelSize.height)
            .onExitCommand { stop() }
    }

    private var character: some View {
        Button(action: model.clicked) {
            ZStack {
                taskHaloView
                PetCharacter(
                    emotion: emotion,
                    phase: model.phase,
                    level: stt.level,
                    still: reduceMotion || (model.pinned && !model.phase.isActive),
                    skin: skins.selected,
                    playbackLevel: tts.playbackLevel,
                    motionDetail: skins.motionDetail,
                    expressionRevision: model.expressionRevision
                )
                .frame(width: PetLayout.petSize.width, height: PetLayout.petSize.height)
                .offset(x: model.idleMotionOffset.x, y: model.idleMotionOffset.y)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Ellipse())
        .accessibilityLabel("Dot companion")
        .accessibilityValue(model.taskStatusText ?? emotion.caption)
        .accessibilityHint("Click to talk or interrupt. Drag to move. Right-click for options. Escape stops.")
        .accessibilityAction(named: Text("Options")) { openOptions() }
        .background(accessibilityContractIndicators)
    }

    @ViewBuilder private var accessibilityContractIndicators: some View {
        Group {
            Text(shortStatus)
            if let snapshot = stt.timingSnapshot {
                Text(String(describing: snapshot.phase))
            }
            if isIssue {
                Image(systemName: "exclamationmark.circle.fill")
            }
            if model.capturingScreen || model.placementCapturing {
                Image(systemName: "eye.fill")
            }
            Circle().stroke(Color.accentColor.opacity(0.45))
            Image(systemName: "pause.circle.fill")
            Image(systemName: "hourglass")
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityValue(CompanionAccessibility.value(status: status, detail: detail, capturingScreen: model.capturingScreen || model.placementCapturing, screenUsed: model.screenContextUsed))
    }

    private var isIssue: Bool { preparation.state.isIssue || { if case .blocked = model.phase { return true }; return false }() }
    private var detail: String? {
        if let issue = preparation.state.detail { return issue }
        if case .blocked(let issue) = model.phase { return issue }
        return model.voiceDeliveryNotice
    }
    private var status: String {
        if preparation.state == .checking { return "Checking bundled files, \(Int(preparation.progress * 100)) percent" }
        if !preparation.ready { return preparation.state.caption }
        if case .blocked = model.phase { return (model.issue?.title ?? CompanionIssue.unknown.title) + " · right-click" }
        if model.phase == .idle, let outcome = model.captureOutcome { return outcome }
        if stt.transcribing { return "Transcribing locally…" }
        if stt.recording, let snapshot = stt.timingSnapshot {
            switch snapshot.phase {
            case .invitation: return "Time to begin speaking: \(CompanionStatusText.seconds(snapshot.remainingSeconds)) seconds"
            case .trailingSilence: return "Waiting for uninterrupted silence: \(CompanionStatusText.seconds(snapshot.remainingSeconds)) seconds"
            case .speaking, .waitingForSpeech: return "Listening"
            }
        }
        if stt.captureState == .requestingPermission { return "Waiting for microphone permission" }
        if model.capturingScreen { return "Reading screen locally…" }
        if model.phase == .listening && !stt.recording { return "Preparing microphone…" }
        if model.phase == .listening && model.automaticReply { return "Listening for your reply" }
        if model.voiceDeliveryNotice != nil { return model.phase == .thinking ? "Generating text. Voice unavailable." : "Text-only reply. Voice unavailable." }
        return model.phase.caption
    }
    private var shortStatus: String {
        if preparation.state == .checking { return "Checking \(Int(preparation.progress * 100))%" }
        if !preparation.ready { return preparation.state == .paused ? "Paused" : "Check files" }
        if case .blocked = model.phase { return CompanionStatusText.issue(model.issue) }
        if model.phase == .idle, let outcome = model.captureOutcome { return outcome }
        if model.phase == .idle, let stage = model.taskStage { return stage }
        if stt.transcribing { return "Transcribing" }
        if stt.recording, let snapshot = stt.timingSnapshot {
            switch snapshot.phase {
            case .invitation: return "Reply \(CompanionStatusText.seconds(snapshot.remainingSeconds))s"
            case .trailingSilence: return "Wait \(CompanionStatusText.seconds(snapshot.remainingSeconds))s"
            case .speaking, .waitingForSpeech: return "Listening"
            }
        }
        if stt.captureState == .requestingPermission { return "Allow mic" }
        if model.capturingScreen { return "Reading screen" }
        switch model.phase {
        case .idle: return model.voiceDeliveryNotice != nil ? "Text only" : model.followupPending ? "Reply soon" : "Ready"
        case .listening: return stt.recording ? "Listening" : "Starting mic"
        case .thinking: return model.voiceDeliveryNotice != nil ? "Thinking · text" : "Thinking"
        case .speaking: return "Speaking"
        case .blocked: return "Try again"
        }
    }

    @ViewBuilder private var taskHaloView: some View {
        switch model.taskHalo {
        case .hidden:
            EmptyView()
        case .indeterminate:
            Circle()
                .trim(from: 0.1, to: 0.45)
                .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 116, height: 116)
        case .determinate(let fraction):
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(1, max(0.04, fraction)))
                    .stroke(Color.accentColor.opacity(0.85), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 116, height: 116)
        case .verifiedComplete:
            Circle()
                .stroke(Color.green.opacity(0.88), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 116, height: 116)
        }
    }

    private func openOptions() { model.dismissFirstUseHint(); model.showOptions?() }
    private func stop() { model.stopCurrentTurn(); preparation.pause() }
}

enum CompanionStatusText {
    static func seconds(_ remaining: Double?) -> String {
        guard let remaining, remaining.isFinite else { return "—" }
        return String(Int(ceil(min(60, max(0, remaining)))))
    }
    static func issue(_ issue: CompanionIssue?) -> String {
        switch issue {
        case .screenPermission: return "Allow screen"
        case .screenCapture: return "Screen failed"
        case .vision: return "Vision offline"
        case .speech: return "Check mic"
        case .voice: return "Check voice"
        case .files: return "Check files"
        case .engine: return "Engine offline"
        case .unknown, .none: return "Try again"
        }
    }
}
