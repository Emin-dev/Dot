import SwiftUI
import AppKit
import OSLog

@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var phase: PetPhase = .idle { didSet { if phase.isActive { placementInvalidated?() } } }
    private var answer = ""
    @Published var pinned = UserDefaults.standard.bool(forKey: "petPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "petPinned"); placementInvalidated?() }
    }
    @Published var hovered = false { didSet { if hovered { placementInvalidated?() } } }
    @Published var interactionPaused = false { didSet { if interactionPaused { placementInvalidated?() } } }
    var placementInvalidated: (() -> Void)?
    @Published var placementCapturing = false
    var showOptions: (() -> Void)?
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
        screen.enabled = screenEnabled
        OfflinePreparation.shared.start(nativeRecognizerAvailable: WhisperRecognizer.available)
        stt.onFinal = { [weak self] id, text in
            guard let self, self.gate.accepts(id) else { return }
            self.submit(text, id: id)
        }
        stt.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            self.cancelTurn(); self.phase = .blocked(message)
        }
        stt.onRecording = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.timing("capture_started")
            do { try self.tts.start(id: id) }
            catch {
                self.logFailure(error, stage: .voice)
                self.cancelTurn(); self.phase = .blocked(error.localizedDescription); return
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
            self.cancelTurn(); self.phase = .blocked(message)
        }
        tts.onStarted = { [weak self] id in
            guard let self, self.gate.accepts(id), !self.firstAudio else { return }
            self.firstAudio = true; self.timing("playback_started")
        }
        tts.onDrained = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.phase = self.generating ? .thinking : .idle
        }
    }

    /// The only route into microphone capture is an explicit pet click.
    func clicked() {
        guard OfflinePreparation.shared.ready else { return }
        let id = cancelTurn()
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        answer = ""
        phase = .listening
        work = Task { [weak self] in
            guard let self, !Task.isCancelled, self.gate.accepts(id) else { return }
            do { try self.screen.prepare(turn: id) }
            catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: .capture)
                self.phase = .blocked(error.localizedDescription); return
            }
            guard !Task.isCancelled, self.gate.accepts(id) else { return }
            await self.stt.start(id: id)
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
                try await self.engine.chat(history: snapshot, onDelta: { [weak self] content in
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
                self.history.append(ChatMessage(role: "assistant", content: self.answer))
                self.generating = false; self.timing("generation_complete")
                self.phase = self.tts.speaking ? .speaking : .idle
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.logFailure(error, stage: stage)
                self.generating = false; self.tts.stop()
                self.phase = .blocked(error.localizedDescription)
            }
            if self.gate.accepts(id) { self.work = nil }
        }
    }

    @discardableResult
    func cancelTurn() -> UUID {
        let id = gate.advance()
        work?.cancel(); work = nil; warmup.cancel()
        stt.cancel(); tts.stop(); screen.cancel(); screenContextUsed = false; capturingScreen = false; generating = false
        chunker = SentenceBuffer(); phase = .idle
        return id
    }
    func reset() { cancelTurn(); history = []; answer = "" }
    func shutdown() { cancelTurn(); stt.shutdown(); tts.shutdown(); engine.shutdown(); OfflinePreparation.shared.shutdown() }
}

struct PetView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var stt: STTManager
    @ObservedObject private var preparation = OfflinePreparation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: model.clicked) {
            PetCharacter(phase: model.phase, level: stt.level, still: reduceMotion || model.hovered || model.pinned)
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
            if model.phase.isActive { model.cancelTurn() }
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
        if case .blocked = model.phase { return "Voice unavailable · right-click" }
        if stt.transcribing { return "Transcribing locally…" }
        if model.capturingScreen { return "Reading screen locally…" }
        if model.phase == .listening && !stt.recording { return "Preparing microphone…" }
        return model.phase.caption
    }
}

struct PetCharacter: View {
    let phase: PetPhase
    let level: Double
    let still: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still || phase == .listening)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let bob = still || phase.isActive ? 0.0 : sin(time * 1.4) * 3
            ZStack {
                Ellipse().fill(.black.opacity(0.10)).frame(width: 75, height: 10).blur(radius: 4).offset(y: 62)
                ZStack {
                    if reduceTransparency {
                        Circle().fill(Color(red: 0.84, green: 0.91, blue: 0.93)).frame(width: 108, height: 108)
                    } else {
                        Circle().fill(.regularMaterial).frame(width: 108, height: 108)
                            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.60), Color(red: 0.55, green: 0.74, blue: 0.80).opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    }
                    Circle().strokeBorder(.white.opacity(0.58), lineWidth: 1.5).frame(width: 106, height: 106)
                    Circle().trim(from: 0.08, to: 0.43).stroke(.white.opacity(0.65), lineWidth: 2).rotationEffect(.degrees(90)).frame(width: 94, height: 94)
                    Ellipse().fill(.white.opacity(0.75)).frame(width: 25, height: 11).rotationEffect(.degrees(-35)).blur(radius: 2).offset(x: -26, y: -33)
                    HStack(spacing: 22) { eye(time: time); eye(time: time) }.offset(y: -4)
                    if phase == .speaking {
                        Ellipse().fill(Color(red: 0.22, green: 0.36, blue: 0.41))
                            .frame(width: 8, height: still ? 6 : 4 + 4 * abs(sin(time * 7))).offset(y: 12)
                    } else {
                        Smile().stroke(Color(red: 0.22, green: 0.36, blue: 0.41), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 9, height: 5).offset(y: 12)
                    }
                    if phase == .listening {
                        Circle().stroke(Color(red: 0.56, green: 0.68, blue: 0.87).opacity(0.55), lineWidth: 1.5)
                            .frame(width: 121 + min(level, 0.4) * 12, height: 121 + min(level, 0.4) * 12)
                    }
                    if phase == .thinking {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { index in
                                Circle().fill(Color(red: 0.25, green: 0.43, blue: 0.45)).frame(width: 3, height: 3)
                                    .opacity(still ? 1 : 0.35 + 0.65 * abs(sin(time * 2 + Double(index))))
                            }
                        }.offset(y: 34)
                    }
                }.offset(y: bob)
            }
        }
    }
    private func eye(time: TimeInterval) -> some View {
        let closed = !still && time.truncatingRemainder(dividingBy: 5) < 0.16
        return Capsule().fill(Color(red: 0.22, green: 0.36, blue: 0.41)).frame(width: 6, height: closed ? 2 : 11)
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: 0), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
