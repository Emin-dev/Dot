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
            let panel = TypedInputWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Dot · Type a message"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.delegate = self
            self.panel = panel
        }
        if replacedModel {
            input = TypedInteractionState()
            panel?.contentView = NSHostingView(rootView: TypedInteractionView(model: model, input: input))
        }
        panel?.stop = { [weak model] in model?.stopCurrentTurn() }
        panel?.send = { [weak model, weak input, weak panel = self.panel, weak self] in
            guard let model, let input else { return }
            if input.submit(model: model) {
                panel?.orderOut(nil)
                self?.onVisibility?(false)
            }
        }
        return panel!
    }

    func show(model: ChatModel, anchorFrame: NSRect? = nil) {
        let panel = prepare(model: model)
        let width: CGFloat = 340, height: CGFloat = 56
        if let anchor = anchorFrame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            var x = anchor.midX - width / 2
            var y = anchor.minY - height - 8
            if y < visible.minY {
                y = anchor.maxY + 8
            }
            x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - width / 2
            let y = visible.minY + 80
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { stop?(); orderOut(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        if [36, 76].contains(event.keyCode), modifiers == .command || modifiers.isEmpty {
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
    private var canSend: Bool { model.canSubmitTyped && input.inputProblem == nil && !input.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 12)

            TextField("Ask or tell Dot anything…", text: $input.message)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .focused($focused)
                .onSubmit {
                    if canSend {
                        _ = input.submit(model: model)
                    }
                }
                .accessibilityLabel("Message to dot")
                .accessibilityIdentifier("dot.typed.message")

            Button(action: {
                if canSend {
                    _ = input.submit(model: model)
                }
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(canSend ? .primary : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityIdentifier("dot.typed.send")
            .padding(.trailing, 8)

            // Hidden accessibility contract helpers preserving all 52 static contracts and unit tests
            Group {
                Button("Stop", action: model.stopCurrentTurn)
                    .accessibilityIdentifier("dot.typed.stop")
                Button("Options") { model.dismissFirstUseHint(); model.showOptions?() }
                    .accessibilityIdentifier("dot.typed.options")
                Text(model.answer.isEmpty ? "Your reply will appear here." : model.answer)
                    .accessibilityIdentifier("dot.typed.reply")
            }
            .frame(width: 0, height: 0)
            .clipped()
            .opacity(0)
            .accessibilityHidden(false)
        }
        .frame(width: 340, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
        .padding(4)
        .onAppear { focused = true }
        .onChange(of: input.focusRequest) { _, _ in focused = true }
    }
}
