import SwiftUI
import AppKit

final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isGenerating = false
    /// Qwen3.8 thinking toggle (low effort vs off) — the speed/quality lever.
    @Published var thinking: Bool = true
    /// Speak replies out loud.
    @Published var autoSpeak: Bool = false

    let engine = EngineManager.shared
    private var chunker = SentenceChunker()

    @MainActor
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard case .ready = engine.phase else { return }

        let history = messages
        input = ""
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        var assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistant)
        let aidx = messages.count - 1
        isGenerating = true
        chunker.flush()

        let think = thinking
        engine.chat(history: history, userText: text, thinking: think) { [weak self] rDelta, cDelta in
            guard let self, self.messages.indices.contains(aidx) else { return }
            if let r = rDelta { self.messages[aidx].thinking += r }
            if let c = cDelta { self.messages[aidx].content += c }
            if self.autoSpeak, let c = cDelta {
                for seg in self.chunker.feed(c) {
                    TTSManager.shared.speakSegment(seg)
                }
            }
        } onDone: { [weak self] ok in
            guard let self else { return }
            if self.messages.indices.contains(aidx) {
                self.messages[aidx].isStreaming = false
                if !ok && self.messages[aidx].content.isEmpty {
                    self.messages[aidx].content = "⚠️ The engine didn't answer — check the status above and try again."
                }
                if self.autoSpeak, let last = self.chunker.flush() {
                    TTSManager.shared.speakSegment(last)
                }
            }
            self.isGenerating = false
        }
    }

    func stop() {
        engine.cancelChat()
        TTSManager.shared.stop()
        if let last = messages.last, last.isStreaming {
            messages[messages.count - 1].isStreaming = false
        }
        isGenerating = false
    }

    func newChat() {
        stop()
        messages = []
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @ObservedObject private var stt = STTManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if model.messages.isEmpty { hero } else { transcript }
            Divider().opacity(0.3)
            inputBar
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 640, idealHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.engine.bootstrap() }
        .onReceive(stt.$transcript) { t in
            if stt.recording { model.input = t }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            statusDot
            Text(statusTitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            if model.messages.isEmpty == false {
                Button {
                    model.newChat()
                } label: {
                    Label("New chat", systemImage: "square.on.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Start a new conversation")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 9, height: 9)
    }

    private var dotColor: Color {
        switch model.engine.phase {
        case .ready: .green
        case .checking, .starting: .orange
        case .downloading: .orange
        case .failed: .red
        case .idle: .gray
        }
    }

    private var statusTitle: String {
        if let f = model.engine.engineFetch {
            return String(format: "Fetching llama.cpp engine… %.0f%%", f * 100)
        }
        switch model.engine.phase {
        case .idle: return "Dot"
        case .checking: return "Waking up…"
        case .downloading(let f):
            let gb = 16.8 * f
            return String(format: "Downloading Qwen3.8-27B — %.1f / 16.8 GB (%.0f%%)", gb, f * 100)
        case .starting: return "Loading model… first load takes a moment"
        case .ready:
            let src = model.engine.isExternal() ? "Splash" : "llama.cpp"
            return "Qwen3.8-27B · \(src) · local"
        case .failed(let msg): return msg
        }
    }

    // MARK: hero (empty state)

    private var hero: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("Icon")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(spacing: 6) {
                Text("Qwen3.8-27B, entirely on your Mac.")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Private · offline · nothing leaves this machine")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if case .failed(let msg) = model.engine.phase {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button("Retry") { model.engine.retry() }
                    .buttonStyle(.borderedProminent)
            }
            if model.engine.engineFetch == nil, case .downloading = model.engine.phase {
                ProgressView()
                    .controlSize(.large)
            }
            if model.engine.engineFetch != nil {
                ProgressView("Preparing the engine…")
            } else if case .starting = model.engine.phase {
                ProgressView("Warming up the engine…")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.messages) { msg in
                        bubble(msg)
                            .id(msg.id)
                    }
                    if !model.engine.lastLog.isEmpty {
                        Text(model.engine.lastLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.messages.last?.content) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(msg.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.28))
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !msg.thinking.isEmpty {
                    DisclosureGroup {
                        Text(msg.thinking)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label("Thinking", systemImage: "brain")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                if !msg.content.isEmpty || msg.isStreaming {
                    Text(msg.content + (msg.isStreaming ? " ▍" : ""))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .onSubmit { model.send() }

            Button {
                if stt.recording { stt.stop() } else {
                    stt.transcript = ""
                    stt.start()
                }
            } label: {
                Image(systemName: stt.recording ? "mic.fill" : "mic")
                    .foregroundStyle(stt.recording ? .red : Color.secondary)
                    .symbolEffect(.pulse, isActive: stt.recording)
            }
            .buttonStyle(.borderless)
            .help(stt.recording ? "Stop listening" : "Talk instead of typing")

            Button {
                model.thinking.toggle()
            } label: {
                Image(systemName: model.thinking ? "brain.fill" : "brain")
                    .foregroundStyle(model.thinking ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.thinking ? "Thinking: low effort (fast + thorough). Click to turn off for chores." : "Thinking off (fastest). Click to enable low effort.")

            Button {
                model.autoSpeak.toggle()
                if !model.autoSpeak { TTSManager.shared.stop() }
            } label: {
                Image(systemName: model.autoSpeak ? "speaker.wave.2.fill" : "speaker.slash")
                    .foregroundStyle(model.autoSpeak ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.autoSpeak ? "Speak replies: on" : "Speak replies: off")

            if model.isGenerating {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty
                          || !(model.engine.phase == .ready))
                .help("Send")
            }
        }
        .padding(10)
    }
}
