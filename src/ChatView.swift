import SwiftUI
import AppKit
import OSLog
import AVFoundation
import CoreGraphics

@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var phase: PetPhase = .idle { didSet { if phase.isActive { placementInvalidated?() } } }
    @Published private(set) var issue: CompanionIssue?
    private var answer = ""
    @Published var pinned = UserDefaults.standard.bool(forKey: "petPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "petPinned"); placementInvalidated?() }
    }
    @Published var hovered = false { didSet { if hovered { placementInvalidated?() } } }
    @Published var interactionPaused = false { didSet { if interactionPaused { placementInvalidated?(); cancelForInteraction() } } }
    var placementInvalidated: (() -> Void)?
    @Published var placementCapturing = false
    var showOptions: (() -> Void)?
    let voiceTiming = VoiceTimingSettings()
    let skinPreferences = SkinPreferences()
    private let followup = VoiceFollowup()
    private var voiceRoute: VoiceAudioRoute?
    @Published private(set) var automaticReply = false
    var visible = true { didSet { if !visible { cancelTurn() } } }
    var followupPending: Bool { followup.pending }
    let stt = STTManager()
    let tts = TTSManager()
    let engine = EngineManager()
    let screen = ScreenContext()
    @Published var screenEnabled = ScreenPrivacyPreference.enabled() { didSet { ScreenPrivacyPreference.setEnabled(screenEnabled); screen.enabled = screenEnabled; placementInvalidated?(); cancelTurn() } }
    @Published private(set) var screenContextUsed = false
    @Published private(set) var capturingScreen = false
    private var gate = TurnGate()
    private var work: Task<Void, Never>?
    private let warmup = TurnWarmup()
    private var generating = false
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
        let reason: PipelineDiagnostic.Reason
        if let value = error as? ScreenContext.ScreenFailure {
            switch value {
            case .permission: reason = .permission
            case .unsupported: reason = .unsupported
            case .unavailable: reason = .unavailable
            }
        } else if let value = error as? EngineError {
            switch value {
            case .configuration, .unavailable: reason = .unavailable
            case .identity: reason = .identity
            case .response: reason = .invalidResponse
            case .empty: reason = .emptyResponse
            }
        } else if error is ResponseLimit { reason = .resourceLimit }
        else if error is URLError { reason = .transport }
        else { reason = stage == .capture ? .captureFailed : stage == .voice ? .voiceFailed : .unknown }
        guard let diagnostic = PipelineDiagnostic.failure(stage: stage, reason: reason,
            cancelled: Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled) else { return }
        Self.runtimeLog.error("\(diagnostic.logLine, privacy: .public)")
    }

    init() {
        followup.environment = { [weak self] in
            guard let self else { return .init(ready: false, microphoneAuthorized: false, screenAuthorized: false, interacting: true) }
            return .init(ready: OfflinePreparation.shared.ready && self.visible && !self.tts.speaking && !self.stt.recording && !self.stt.transcribing
                    && self.voiceRoute != nil && self.voiceRoute == VoiceAudioRoute.current(),
                microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                screenAuthorized: !self.screenEnabled || CGPreflightScreenCaptureAccess(),
                interacting: self.interactionPaused)
        }
        followup.onInvite = { [weak self] previous, continuation in
            guard let self, self.gate.accepts(previous), self.visible, !self.interactionPaused else { return }
            self.beginListening(continuation: continuation)
        }
        stt.onNoSpeech = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn()
        }
        stt.onCaptureCancelled = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn()
        }
        stt.onSpeechEnded = { [weak self] id, evidence in
            guard let self, self.gate.accepts(id) else { return }
            self.speechEndedAt = evidence.speechEndedAt
            self.silenceSatisfiedAt = evidence.silenceSatisfiedAt
            let milliseconds = Int(evidence.selectedSilenceSeconds * 1000)
            Self.timingLog.notice("DOT_TIMING selected_silence=\(milliseconds)ms")
        }
        screen.enabled = screenEnabled
        OfflinePreparation.shared.start(nativeRecognizerAvailable: WhisperRecognizer.available)
        stt.onFinal = { [weak self] id, text in
            guard let self, self.gate.accepts(id) else { return }
            self.submit(text, id: id)
        }
        stt.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn(); self.block(message, issue: .speech)
        }
        stt.onRecording = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.timing("capture_started")
            do { try self.tts.start(id: id) }
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
            let diagnostic = PipelineDiagnostic(stage: .voice, outcome: .failed, reason: .voiceFailed)
            Self.runtimeLog.error("\(diagnostic.logLine, privacy: .public)")
            self.cancelTurn(); self.block(message, issue: .voice)
        }
        tts.onStarted = { [weak self] id in
            guard let self, self.gate.accepts(id), !self.firstAudio else { return }
            self.firstAudio = true; self.timing("playback_started")
            // Player scheduling is not an acoustic measurement. Keep these metrics labelled.
            let now = ProcessInfo.processInfo.systemUptime
            if let ended = self.speechEndedAt, let satisfied = self.silenceSatisfiedAt {
                let total = Int((now - ended) * 1000), processing = Int((now - satisfied) * 1000)
                Self.timingLog.notice("DOT_TIMING speech_end_to_playback_scheduled=\(total)ms post_silence_to_playback_scheduled=\(processing)ms")
            }
        }
        tts.onFinalPlayback = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.timing("final_playback_complete")
            self.followup.playbackFinished(turn: id)
        }
        tts.onDrained = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.phase = self.generating ? .thinking : .idle
        }
    }

    /// Manual clicks interrupt; automatic capture requires the same-turn final-question gate.
    func clicked() {
        guard OfflinePreparation.shared.ready else { return }
        beginListening(continuation: nil)
    }
    private func beginListening(continuation: UUID?) {
        let invitation = continuation != nil
        let id = cancelTurn(preserveFollowup: invitation)
        voiceRoute = VoiceAudioRoute.current()
        followup.begin(turn: id, continuation: continuation)
        automaticReply = invitation
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        speechEndedAt = nil; silenceSatisfiedAt = nil; answer = ""
        phase = .listening
        work = Task { [weak self] in
            guard let self, !Task.isCancelled, self.gate.accepts(id) else { return }
            do { try self.screen.prepare(turn: id, requestPermission: !invitation) }
            catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: .capture)
                self.cancelTurn(); self.block(error.localizedDescription, issue: .screenPermission); return
            }
            guard !Task.isCancelled, self.gate.accepts(id) else { return }
            await self.stt.start(id: id, settings: self.voiceTiming, invitation: invitation)
        }
    }

    private func submit(_ text: String, id: UUID) {
        guard gate.accepts(id) else { return }
        timing("final_transcript")
        phase = .thinking; generating = true
        answer = ""; chunker = SentenceBuffer()
        history.append(ChatMessage(role: "user", content: text))
        if history.count > 12 { history.removeFirst(history.count - 12) }
        let snapshot = history
        work = Task { [weak self] in
            guard let self else { return }
            var stage = PipelineDiagnostic.Stage.readiness
            do {
                try await self.warmup.wait(turn: id)
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                let question = try await self.engine.chat(history: snapshot, onDelta: { [weak self] content in
                    guard let self, self.gate.accepts(id) else { return }
                    if !self.firstAnswer { self.firstAnswer = true; self.timing("first_answer") }
                    self.answer += content
                    for sentence in self.chunker.feed(content) { self.tts.enqueue(sentence, id: id) }
                    if self.tts.speaking { self.phase = .speaking }
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
                    let image = try await self.screen.capture(turn: id, modelHasVision: hasVision)
                    guard self.gate.accepts(id), !Task.isCancelled else { throw CancellationError() }
                    if image != nil {
                        let diagnostic = PipelineDiagnostic(stage: .capture, outcome: .ready)
                        Self.runtimeLog.notice("\(diagnostic.logLine, privacy: .public)")
                    }
                    stage = .response
                    self.screenContextUsed = image != nil; return image
                })
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                if let tail = self.chunker.flush() { self.tts.enqueue(tail, id: id) }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.followup.generationFinished(turn: id, hasQuestion: question != nil)
                if let question {
                    self.answer += (self.answer.isEmpty ? "" : " ") + question.text
                    self.tts.enqueue(question.text, id: id)
                }
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.history.append(ChatMessage(role: "assistant", content: self.answer))
                self.generating = false; self.timing("generation_complete")
                self.tts.markGenerationComplete(id: id)
                self.phase = self.tts.speaking ? .speaking : .idle
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: stage)
                self.generating = false; self.tts.stop(); self.followup.cancel()
                let issue: CompanionIssue
                if let failure = error as? ScreenContext.ScreenFailure {
                    switch failure {
                    case .permission: issue = .screenPermission
                    case .unavailable: issue = .screenCapture
                    case .unsupported: issue = .vision
                    }
                } else { issue = stage == .capture ? .screenCapture : .engine }
                self.block(error.localizedDescription, issue: issue)
            }
            if self.gate.accepts(id) { self.work = nil }
        }
    }

    private func block(_ message: String, issue: CompanionIssue) {
        self.issue = issue; phase = .blocked(message)
    }

    @discardableResult
    func cancelTurn(preserveFollowup: Bool = false) -> UUID {
        if !preserveFollowup { followup.cancel() }
        automaticReply = false; voiceRoute = nil
        let id = gate.advance()
        work?.cancel(); work = nil; warmup.cancel()
        stt.cancel(); tts.stop(); screen.cancel(); screenContextUsed = false; capturingScreen = false; generating = false
        chunker = SentenceBuffer(); issue = nil; phase = .idle
        return id
    }
    /// Menus and dragging revoke capture without erasing a diagnostic the user is inspecting.
    func cancelForInteraction() {
        let savedIssue = issue, savedPhase = phase
        cancelTurn()
        if case .blocked = savedPhase { issue = savedIssue; phase = savedPhase }
    }
    func reset() { cancelTurn(); history = []; answer = "" }
    func shutdown() { cancelTurn(); stt.shutdown(); tts.shutdown(); engine.shutdown(); OfflinePreparation.shared.shutdown() }
}

struct PetView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var stt: STTManager
    @ObservedObject var tts: TTSManager
    @ObservedObject var skins: SkinPreferences
    @ObservedObject private var preparation = OfflinePreparation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: model.clicked) {
            PetCharacter(phase: model.phase, level: stt.level, still: reduceMotion || model.hovered || model.pinned,
                         skin: skins.selected, playbackLevel: tts.playbackLevel, motionDetail: skins.motionDetail)
                .frame(width: PetLayout.petSize.width, height: PetLayout.petSize.height)
                .overlay {
                    if preparation.state == .checking {
                        ZStack {
                            Circle().stroke(Color.accentColor.opacity(0.45), lineWidth: 2)
                            Circle().trim(from: 0, to: CGFloat(preparation.progress))
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                            .frame(width: 116, height: 116).rotationEffect(.degrees(-90))
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isIssue {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
                            .foregroundStyle(.orange).accessibilityHidden(true)
                    } else if preparation.state == .paused {
                        Image(systemName: "pause.circle.fill").font(.system(size: 12))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    } else if preparation.state == .checking {
                        Image(systemName: "hourglass").font(.system(size: 12))
                            .foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.capturingScreen || model.placementCapturing || model.screenContextUsed {
                        Image(systemName: (model.capturingScreen || model.placementCapturing) ? "eye.fill" : "eye")
                            .font(.system(size: 12)).accessibilityLabel(model.placementCapturing ? "Checking a clear place locally" : model.capturingScreen ? "Reading screen locally" : "Screen used for this reply")
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Ellipse())
        .onHover { model.hovered = $0 }
        .accessibilityLabel("Dot companion")
        .accessibilityValue(CompanionAccessibility.value(status: status, detail: detail, capturingScreen: model.capturingScreen || model.placementCapturing, screenUsed: model.screenContextUsed))
        .accessibilityHint("Click to talk or interrupt. Drag to move. Right-click or Shift F10 for options. Escape stops the current action.")
        .accessibilityAction(named: Text("Options")) { model.showOptions?() }
        .padding(PetLayout.edgePadding)
        .frame(width: PetLayout.panelSize.width, height: PetLayout.panelSize.height)
        .onExitCommand {
            model.cancelTurn()
            preparation.pause()
        }
    }
    private var isIssue: Bool { preparation.state.isIssue || { if case .blocked = model.phase { return true }; return false }() }
    private var detail: String? {
        if let issue = preparation.state.detail { return issue }
        if case .blocked(let issue) = model.phase { return issue }
        return nil
    }
    private var status: String {
        if preparation.state == .checking { return "Checking bundled files, \(Int(preparation.progress * 100)) percent" }
        if !preparation.ready { return preparation.state.caption }
        if case .blocked = model.phase { return (model.issue?.title ?? CompanionIssue.unknown.title) + " · right-click" }
        if stt.transcribing { return "Transcribing locally…" }
        if model.capturingScreen { return "Reading screen locally…" }
        if model.phase == .listening && !stt.recording { return "Preparing microphone…" }
        if model.phase == .listening && model.automaticReply { return "Listening for your reply" }
        return model.phase.caption
    }
}
