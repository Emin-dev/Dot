import SwiftUI
import AppKit

@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var phase: PetPhase = .idle
    @Published private(set) var answer = ""
    @Published var pinned = UserDefaults.standard.bool(forKey: "petPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "petPinned") }
    }
    @Published var hovered = false
    @Published var bubbleHovered = false
    @Published var interactionPaused = false
    let stt = STTManager()
    let tts = TTSManager()
    let engine = EngineManager()
    private var gate = TurnGate()
    private var work: Task<Void, Never>?
    private var generating = false
    private var history: [ChatMessage] = []
    private var chunker = SentenceBuffer()
    private var clickedAt = 0.0
    private var firstReasoning = false
    private var firstAnswer = false
    private var firstAudio = false
    private func timing(_ stage: String) {
        // Durations only. Never log speech, prompts, replies or model paths.
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - clickedAt) * 1000)
        print("DOT_TIMING \(stage)=\(milliseconds)ms")
    }

    init() {
        stt.onFinal = { [weak self] id, text in
            guard let self, self.gate.accepts(id) else { return }
            self.submit(text, id: id)
        }
        stt.onError = { [weak self] id, message in
            guard let self, self.gate.accepts(id) else { return }
            self.phase = .blocked(message)
        }
        tts.onStarted = { [weak self] id in
            guard let self, self.gate.accepts(id), !self.firstAudio else { return }
            self.firstAudio = true; self.timing("first_audio")
        }
        tts.onDrained = { [weak self] id in
            guard let self, self.gate.accepts(id) else { return }
            self.phase = self.generating ? .thinking : .idle
        }
    }

    /// The only route into microphone capture is an explicit pet click.
    func clicked() {
        let id = cancelTurn()
        clickedAt = ProcessInfo.processInfo.systemUptime
        firstReasoning = false; firstAnswer = false; firstAudio = false
        answer = ""
        phase = .listening
        work = Task { [weak self] in
            guard let self, !Task.isCancelled, self.gate.accepts(id) else { return }
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
        tts.start(id: id)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.chat(history: snapshot, onDelta: { [weak self] content in
                    guard let self, self.gate.accepts(id) else { return }
                    if !self.firstAnswer { self.firstAnswer = true; self.timing("first_answer") }
                    self.answer += content
                    for sentence in self.chunker.feed(content) { self.tts.enqueue(sentence, id: id) }
                    if self.tts.speaking { self.phase = .speaking }
                }, onReasoning: { [weak self] in
                    guard let self, self.gate.accepts(id), !self.firstReasoning else { return }
                    self.firstReasoning = true; self.timing("first_reasoning")
                })
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                if let tail = self.chunker.flush() { self.tts.enqueue(tail, id: id) }
                self.history.append(ChatMessage(role: "assistant", content: self.answer))
                self.generating = false; self.timing("generation_complete")
                self.phase = self.tts.speaking ? .speaking : .idle
            } catch {
                guard self.gate.accepts(id), !Task.isCancelled else { return }
                self.generating = false; self.tts.stop()
                // Keep this capture visible for retry; never claim a connection succeeded.
                self.answer = text
                self.phase = .blocked(error.localizedDescription)
            }
            if self.gate.accepts(id) { self.work = nil }
        }
    }

    @discardableResult
    func cancelTurn() -> UUID {
        let id = gate.advance()
        work?.cancel(); work = nil
        stt.cancel(); tts.stop(); generating = false
        chunker = SentenceBuffer(); phase = .idle
        return id
    }
    func reset() { cancelTurn(); history = []; answer = "" }
    func configure(url: String, model: String) {
        cancelTurn(); engine.endpoint = url; engine.expectedModel = model
        phase = .idle
    }
    func shutdown() { cancelTurn(); engine.shutdown() }
}

struct PetView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var stt: STTManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var connectionShown = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if model.phase.isActive || !model.answer.isEmpty || isBlocked || model.hovered {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Circle().fill(isBlocked ? Color.orange : Color.green).frame(width: 5, height: 5)
                        Text(status).font(.system(size: 11, weight: .semibold, design: .rounded))
                        Spacer()
                        if model.pinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
                    }
                    if !stt.transcript.isEmpty && model.phase == .listening {
                        Text(stt.transcript).lineLimit(5)
                    } else if !model.answer.isEmpty {
                        Text(model.answer).lineLimit(7).textSelection(.enabled)
                    }
                    if model.phase == .listening {
                        Text("Take your time. I'll wait 3 seconds after you finish.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color.primary)
                .padding(14)
                .frame(maxWidth: 280, alignment: .leading)
                .background {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        RoundedRectangle(cornerRadius: 20).fill(.regularMaterial)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                .padding(.horizontal, 15)
                .onHover { model.bubbleHovered = $0 }
            }
            Button(action: model.clicked) {
                PetCharacter(phase: model.phase, level: stt.level, still: reduceMotion || model.hovered || model.pinned)
                    .frame(width: 140, height: 148)
            }
            .buttonStyle(.plain)
            .contentShape(Ellipse())
            .onHover { model.hovered = $0 }
            .help("Click to talk or interrupt. Right-click for Pin and Connection.")
            .accessibilityLabel("Dot companion")
            .accessibilityValue(status)
            .accessibilityHint("Click to start a new voice capture. Interrupts any current answer.")
            .contextMenu {
                Button(model.pinned ? "Unpin" : "Pin in place") { model.pinned.toggle() }
                Button("Connection…") { connectionShown = true }
                Button("Clear conversation") { model.reset() }
                if model.phase.isActive { Button("Stop") { model.cancelTurn() } }
                Divider()
                Text("Voice: built-in English · on device")
                Button("Quit Dot") { NSApp.terminate(nil) }
            }
            .popover(isPresented: $connectionShown, arrowEdge: .top) { ConnectionView(model: model) }
            .onChange(of: connectionShown) { _, shown in model.interactionPaused = shown }
            Text(model.hovered ? "interim voice: built-in English" : "dot")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .frame(width: 320, height: 420)
    }

    private var isBlocked: Bool { if case .blocked = model.phase { return true }; return false }
    private var status: String {
        if model.phase == .listening && !stt.recording { return "Preparing your microphone…" }
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

private struct ConnectionView: View {
    @ObservedObject var model: ChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var loadedModel = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A little local connection").font(.headline)
            Text("Dot connects directly to an already-running Splash server. Nothing is downloaded or started here.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("http://127.0.0.1:8000", text: $url)
            TextField("Exact loaded upstream model ID", text: $loadedModel)
            Text("The model must exactly match Splash /status → instance.model. A generic Bionic/LM Studio proxy isn't verified as Splash.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { model.configure(url: url, model: loadedModel); dismiss() }
                    .disabled(LocalEndpoint.validate(url) == nil || loadedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 340)
        .onAppear { url = model.engine.endpoint; loadedModel = model.engine.expectedModel }
    }
}
