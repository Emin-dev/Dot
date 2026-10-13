import SwiftUI
import AppKit

/// This owns only the editor draft and local submission feedback. Conversation,
/// generation and delivery state continue to belong to ChatModel/history.
@MainActor
final class TypedInteractionState: ObservableObject {
    @Published var message = "" { didSet { submissionFeedback = nil } }
    @Published private(set) var submissionFeedback: String?
    @Published private(set) var focusRequest: UInt64 = 0
    var inputProblem: String? { TypedMessageValidation.problem(message) }
    func requestFocus() { focusRequest &+= 1 }

    @discardableResult
    func submit(model: ChatModel, withoutScreen: Bool = false) -> Bool {
        if let inputProblem { submissionFeedback = inputProblem; return false }
        guard model.canSubmitTyped else {
            submissionFeedback = "Dot is not ready to send. Check the status below or open Options."
            return false
        }
        if withoutScreen { model.screenEnabled = false }
        guard model.submitTyped(message) else {
            if case .blocked(let reason) = model.phase { submissionFeedback = reason }
            else { submissionFeedback = "The message could not start. Check the status below and try again." }
            return false
        }
        submissionFeedback = nil
        return true
    }
}

/// Presentation never infers heard speech from generated text or a quiet player.
enum TypedInteractionStatus {
    static func unavailable(canSubmit: Bool, preparation: CompanionReadiness) -> String? {
        guard !canSubmit else { return nil }
        switch preparation {
        case .checking: return "Checking bundled files. You can write a message while dot gets ready."
        case .paused: return "The file check is paused. Resume it in Options before sending."
        case .unavailable(let message): return message
        case .ready: return "Dot is not ready to send. Open Options to check its status."
        }
    }

    static func delivery(turn: UUID?, records: [ConversationHistoryRecord]) -> ConversationHistoryRecord? {
        guard let turn else { return nil }
        return records.first { $0.turnID == turn && $0.role == .assistant }
    }
}

@MainActor
final class TypedInteractionPanel: NSObject, NSWindowDelegate {
    var onVisibility: ((Bool) -> Void)?
    private var panel: TypedInputWindow?
    private weak var model: ChatModel?
    private(set) var input = TypedInteractionState()

    /// Constructing/rebinding does not activate an app, show a window, capture
    /// audio or start a model. The same draft survives reopening for one model.
    func prepare(model: ChatModel) -> NSPanel {
        let replacedModel = self.model !== model
        self.model = model
        if panel == nil {
            let panel = TypedInputWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Dot · Type a message"
            panel.minSize = NSSize(width: 420, height: 400)
            panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.center(); self.panel = panel
        }
        if replacedModel {
            input = TypedInteractionState()
            panel?.contentView = NSHostingView(rootView: TypedInteractionView(model: model, input: input))
        }
        panel?.stop = { [weak model] in model?.stopCurrentTurn() }
        panel?.send = { [weak model, weak input] in
            guard let model, let input else { return }
            input.submit(model: model)
        }
        return panel!
    }

    func show(model: ChatModel) {
        let panel = prepare(model: model)
        onVisibility?(true); panel.makeKeyAndOrderFront(nil)
        input.requestFocus()
        NSApp.activate(ignoringOtherApps: false)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopCurrentTurn(); onVisibility?(false)
    }
}

private final class TypedInputWindow: NSPanel {
    var stop: (() -> Void)?
    var send: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { stop?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { stop?() } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if [36, 76].contains(event.keyCode), modifiers == .command {
            send?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct TypedInteractionView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var input: TypedInteractionState
    @ObservedObject private var preparation = OfflinePreparation.shared
    @ObservedObject private var history: ConversationHistoryModel
    @FocusState private var focused: Bool

    init(model: ChatModel, input: TypedInteractionState) {
        self.model = model; self.input = input; history = model.textHistory
    }
    private var unavailable: String? {
        TypedInteractionStatus.unavailable(canSubmit: model.canSubmitTyped, preparation: preparation.state)
    }
    private var record: ConversationHistoryRecord? {
        TypedInteractionStatus.delivery(turn: model.displayedAnswerTurn, records: history.records)
    }
    private var canSend: Bool { model.canSubmitTyped && input.inputProblem == nil }
    private var screenIssue: Bool {
        model.issue == .screenPermission || model.issue == .screenCapture || model.issue == .vision
    }
    private var currentStatus: String {
        if let outcome = model.captureOutcome { return outcome }
        if model.capturingScreen { return "Reading screen context" }
        if model.voiceDeliveryNotice != nil {
            if model.phase == .thinking { return "Generating text only" }
            if model.phase == .idle { return "Text-only reply" }
        }
        switch model.phase {
        case .idle: return model.canSubmitTyped ? "Ready to send" : "Not ready"
        case .listening: return "Listening"
        case .thinking: return "Preparing or generating a reply"
        case .speaking: return "Generating or playing reply audio"
        case .blocked: return model.issue?.title ?? "Could not finish this turn"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Type to dot without opening the microphone.").font(.headline)
            TextField("Your message", text: $input.message, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("Message to dot").accessibilityIdentifier("dot.typed.message")
            HStack {
                Text("⌘ Return sends · Escape stops").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Stop", action: model.stopCurrentTurn)
                    .disabled(!model.phase.isActive && !model.followupPending)
                    .accessibilityIdentifier("dot.typed.stop")
                Button("Send") { input.submit(model: model) }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
                    .accessibilityIdentifier("dot.typed.send")
            }
            if let warning = input.submissionFeedback ?? (input.message.isEmpty ? nil : input.inputProblem) {
                Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(currentStatus).font(.callout).fontWeight(.medium)
                    Spacer()
                    Button("Options") { model.dismissFirstUseHint(); model.showOptions?() }
                        .accessibilityIdentifier("dot.typed.options")
                }
                if let unavailable {
                    Text(unavailable).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = model.voiceDeliveryNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if case .blocked(let reason) = model.phase {
                    Text(reason).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Retry message") { input.submit(model: model) }.disabled(!canSend)
                        if screenIssue {
                            Button("Continue without screen") { input.submit(model: model, withoutScreen: true) }
                                .disabled(!canSend).help("Turns off screen context and retries the message shown above.")
                        }
                    }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.answer.isEmpty ? "Your reply will appear here." : model.answer)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("dot.typed.reply")
                    if let record {
                        Text(record.statusSummary).font(.caption).fontWeight(.medium)
                        Text(record.deliveryExplanation).font(.caption).foregroundStyle(.secondary)
                    } else if !model.answer.isEmpty {
                        Text("Generated text · Delivery not yet recorded")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = history.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(16)
            .onAppear { focused = input.focusRequest > 0 }
            .onChange(of: input.focusRequest) { _, _ in focused = true }
    }
}
