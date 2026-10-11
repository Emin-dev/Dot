import SwiftUI
import AppKit
import Combine

enum VoiceState { case idle, listening, thinking, speaking }

final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var showText: Bool = false
    @Published var isGenerating = false
    @Published var autoSpeak: Bool = true        // voice-first: replies are spoken
    @Published var voiceState: VoiceState = .idle

    let engine = EngineManager.shared
    let tts = TTSManager.shared
    let stt = STTManager.shared
    private var chunker = SentenceChunker()
    private var cancellables = Set<AnyCancellable>()

    init() {
        tts.onFinished = { [weak self] in
            guard let self, self.voiceState == .speaking else { return }
            self.voiceState = .idle
        }
        stt.$recording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rec in
                guard let self else { return }
                if rec {
                    self.voiceState = .listening
                } else {
                    MainActor.assumeIsolated {
                        if self.stt.autoSendOnFinal, !self.stt.transcript.isEmpty {
                            self.stt.autoSendOnFinal = false
                            self.send(self.stt.transcript)
                        } else if self.voiceState == .listening {
                            self.voiceState = self.isGenerating ? .thinking : .idle
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: send (text or voice)

    @MainActor
    func send(_ voiceText: String? = nil) {
        let text = (voiceText ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard case .ready = engine.phase else { return }

        input = ""
        let history = messages          // snapshot BEFORE the new user message (engine appends it)
        messages.append(ChatMessage(role: .user, content: text))
        var assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistant)
        let aidx = messages.count - 1
        isGenerating = true
        voiceState = .thinking
        chunker.flush()

        engine.chat(history: history, userText: text, thinking: true) { [weak self] rDelta, cDelta in
            guard let self, self.messages.indices.contains(aidx) else { return }
            if let r = rDelta { self.messages[aidx].thinking += r }
            if let c = cDelta { self.messages[aidx].content += c }
            if self.autoSpeak, let c = cDelta {
                for seg in self.chunker.feed(c) { self.tts.speakSegment(seg) }
                if self.tts.speaking { self.voiceState = .speaking }
            }
        } onDone: { [weak self] ok in
            guard let self else { return }
            if self.messages.indices.contains(aidx) {
                self.messages[aidx].isStreaming = false
                if !ok && self.messages[aidx].content.isEmpty {
                    self.messages[aidx].content = "⚠️ The engine didn't answer — try again."
                }
                if self.autoSpeak, let last = self.chunker.flush() { self.tts.speakSegment(last) }
            }
            self.isGenerating = false
            if self.tts.speaking { self.voiceState = .speaking }
            else { self.voiceState = .idle }
        }
    }

    func stop() {
        engine.cancelChat()
        tts.stop()
        if let last = messages.last, last.isStreaming {
            messages[messages.count - 1].isStreaming = false
        }
        isGenerating = false
        voiceState = .idle
    }

    func newChat() {
        stop()
        messages = []
        input = ""
    }

    // MARK: mic (with barge-in over TTS)

    func micTapped() {
        if stt.recording {
            stt.autoSendOnFinal = true
            stt.stop()
            return
        }
        if tts.speaking { tts.stop() }        // barge-in
        if isGenerating { stop() }
        stt.transcript = ""
        stt.autoSendOnFinal = true
        stt.start()
    }
}

// MARK: - Orb (Dottie-style reactive avatar)

struct OrbView: View {
    let state: VoiceState
    var micLevel: Double = 0

    @State private var phase: Double = 0
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var core: Color {
        switch state {
        case .idle: return Color(red: 0.95, green: 0.45, blue: 0.25).opacity(0.55)
        case .listening: return Color(red: 0.98, green: 0.55, blue: 0.28)
        case .thinking: return Color(red: 0.95, green: 0.45, blue: 0.25)
        case .speaking: return Color(red: 1.0, green: 0.62, blue: 0.35)
        }
    }

    private var scale: Double {
        switch state {
        case .listening: return 1.0 + min(0.28, micLevel) * 0.9
        case .speaking: return 1.0 + 0.07 * abs(sin(phase * 5.5))
        case .thinking: return 1.0 + 0.03 * abs(sin(phase * 3.0))
        case .idle: return 1.0 + 0.02 * sin(phase * 1.1)
        }
    }

    var body: some View {
        ZStack {
            // glow
            Circle()
                .fill(RadialGradient(colors: [core.opacity(state == .idle ? 0.25 : 0.5), .clear],
                                      center: .center, startRadius: 20, endRadius: 120))
                .frame(width: 240, height: 240)
                .scaleEffect(scale)
            // thinking arc
            if state == .thinking {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(core, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 168, height: 168)
                    .rotationEffect(.degrees(phase * 260))
            }
            // speaking rings
            if state == .speaking {
                Circle()
                    .stroke(core.opacity(0.5), lineWidth: 2)
                    .frame(width: 190, height: 190)
                    .scaleEffect(1.0 + 0.12 * abs(sin(phase * 5.5)))
                Circle()
                    .stroke(core.opacity(0.25), lineWidth: 2)
                    .frame(width: 214, height: 214)
                    .scaleEffect(1.0 + 0.16 * abs(sin(phase * 5.5 + 1)))
            }
            // core
            Circle()
                .fill(RadialGradient(colors: [core, core.opacity(0.25)],
                                      center: UnitPoint(x: 0.35, y: 0.3),
                                      startRadius: 4, endRadius: 90))
                .frame(width: 150, height: 150)
                .scaleEffect(scale)
                .overlay(
                    Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                        .frame(width: 150, height: 150)
                        .scaleEffect(scale)
                )
        }
        .frame(width: 240, height: 240)
        .onReceive(ticker) { _ in
            phase += 0.05
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var model = ChatModel()

    private let accent = Color(red: 0.98, green: 0.55, blue: 0.28)
    private let bg = Color(red: 0.06, green: 0.07, blue: 0.09)
    private let surface = Color.white.opacity(0.06)

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.messages.isEmpty { hero } else { transcript }
            OrbView(state: model.voiceState, micLevel: model.stt.level)
                .padding(.vertical, 8)
            bottomBar
            if model.showText { inputBar }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 640, idealHeight: 820)
        .background(bg)
        .task { model.engine.bootstrap() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(statusTitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.autoSpeak.toggle()
                if !model.autoSpeak { model.tts.stop() }
            } label: {
                Image(systemName: model.autoSpeak ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(model.autoSpeak ? accent : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.autoSpeak ? "Voice replies: on" : "Voice replies: off")
            if !model.messages.isEmpty {
                Button { model.newChat() } label: {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("New chat")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var dotColor: Color {
        switch model.engine.phase {
        case .ready: return .green
        case .checking, .starting: return .orange
        case .downloading: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusTitle: String {
        if let f = model.engine.engineFetch {
            return String(format: "Fetching engine… %.0f%%", f * 100)
        }
        switch model.engine.phase {
        case .idle: return "Dot"
        case .checking: return "Waking up…"
        case .downloading(let f):
            return String(format: "Downloading Qwen3.8-27B — %.1f/16.8 GB (%.0f%%)", 16.8 * f, f * 100)
        case .starting: return "Loading model…"
        case .ready:
            return "Qwen3.8-27B · \(model.engine.isExternal() ? "Splash" : "llama.cpp") · local"
        case .failed(let m): return m
        }
    }

    // MARK: hero

    private var hero: some View {
        VStack(spacing: 14) {
            Spacer()
            if case .failed(let msg) = model.engine.phase {
                Text(msg).font(.system(size: 12)).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
                Button("Retry") { model.engine.retry() }.buttonStyle(.borderedProminent)
                    .tint(accent)
            }
            if model.engine.engineFetch == nil {
                if case .downloading = model.engine.phase {
                    ProgressView().controlSize(.large)
                }
            }
            if model.engine.engineFetch != nil {
                ProgressView("Preparing the engine…")
            } else if case .starting = model.engine.phase {
                ProgressView("Warming up the engine…")
            }
            Text("Tap the mic — or type")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .frame(maxHeight: 300)
            .onChange(of: model.messages.count) { _ in scrollBottom(proxy) }
            .onChange(of: model.messages.last?.content) { _ in scrollBottom(proxy) }
            .onAppear { scrollBottom(proxy) }
        }
    }

    private func scrollBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(msg.content)
                    .textSelection(.enabled)
                    .font(.system(size: 14))
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(accent.opacity(0.25)))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !msg.thinking.isEmpty {
                    DisclosureGroup {
                        Text(msg.thinking).font(.system(size: 11)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    } label: {
                        Label("Thinking", systemImage: "brain")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(surface))
                }
                if !msg.content.isEmpty || msg.isStreaming {
                    Text(msg.content + (msg.isStreaming ? " ▍" : ""))
                        .textSelection(.enabled)
                        .font(.system(size: 14))
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(surface))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: bottom bar (voice-first)

    private var bottomBar: some View {
        HStack(spacing: 26) {
            Button { model.showText.toggle() } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 15))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(model.showText ? accent.opacity(0.3) : surface))
                    .foregroundStyle(model.showText ? accent : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Type instead of talking")

            Button(action: model.micTapped) {
                Image(systemName: model.stt.recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24))
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(
                        model.stt.recording
                            ? Color.red
                            : (model.engine.phase == .ready ? accent : surface)))
                    .foregroundStyle(model.stt.recording ? .white :
                        (model.engine.phase == .ready ? Color.black.opacity(0.8) : Color.secondary))
                    .scaleEffect(model.stt.recording ? 1.0 + model.stt.level * 0.15 : 1.0)
                    .symbolEffect(.pulse, isActive: model.stt.recording)
            }
            .buttonStyle(.borderless)
            .help(model.stt.recording ? "Stop & send" : "Talk")

            if model.isGenerating {
                Button { model.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(surface))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Color.clear.frame(width: 44, height: 44)   // balance
            }
        }
        .padding(.bottom, 18)
    }

    // MARK: text input (hidden until asked)

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 14))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
                .onSubmit { model.send() }
            Button {
                if model.isGenerating { model.stop() } else { model.send() }
            } label: {
                Image(systemName: model.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(model.isGenerating ? Color.red : accent)
                    .opacity(model.isGenerating || !model.input.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : 0.4)
            }
            .buttonStyle(.borderless)
            .disabled(!model.isGenerating && model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            .disabled(model.engine.phase != .ready && !model.isGenerating)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}
