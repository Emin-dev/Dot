import SwiftUI
import AppKit

/// A single explicit confirmation for a specific local-record mutation. The model
/// separately validates its single-use token; dismissing a sheet grants no authority.
struct LocalRecordDeletionPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class LocalRecordDeletionConfirmation {
    typealias Reply = @MainActor (Bool) -> Void
    typealias Present = @MainActor (LocalRecordDeletionPrompt, NSWindow, @escaping Reply) -> Void
    private let presentOverride: Present?
    private var generation = UUID()
    private weak var window: NSWindow?
    private var alert: NSAlert?
    init(present: Present? = nil) { presentOverride = present }
    func present(_ prompt: LocalRecordDeletionPrompt, for window: NSWindow, reply: @escaping Reply) {
        invalidate()
        guard window.isVisible, window.attachedSheet == nil else { reply(false); return }
        let expected = generation
        let receive: Reply = { [weak self, weak window] confirmed in
            guard let self, let window, self.generation == expected, window.isVisible else { return }
            self.generation = UUID(); self.alert = nil; self.window = nil
            reply(confirmed)
        }
        if let presentOverride { presentOverride(prompt, window, receive); return }
        let alert = NSAlert()
        alert.alertStyle = .warning; alert.messageText = prompt.title; alert.informativeText = prompt.message
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true; delete.keyEquivalent = ""
        self.alert = alert; self.window = window
        alert.beginSheetModal(for: window) { response in receive(response == .alertSecondButtonReturn) }
    }
    func invalidate() {
        generation = UUID()
        if let alert, let window, window.attachedSheet === alert.window {
            window.endSheet(alert.window, returnCode: .cancel)
        }
        alert = nil; window = nil
    }
}

/// Durable text is separate from the short, in-memory prompt context.
@MainActor
final class ConversationHistoryModel: ObservableObject {
    @Published private(set) var records: [ConversationHistoryRecord] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var closing = false
    var onDelete: (() -> Void)?
    private let store: ConversationHistoryStore?
    private let copyText: (String) -> Void
    private var writes: Task<Void, Never>?
    private var revision = UUID()
    private var assistantIDs: [UUID: UUID] = [:]
    private enum DeletionTarget { case record(UUID), all }
    private var pendingDeletion: (prompt: UUID, target: DeletionTarget, revision: UUID)?

    init(directory: URL? = nil, copyText: @escaping (String) -> Void = { text in
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }) {
        self.copyText = copyText
        do { store = try ConversationHistoryStore(directory: directory) }
        catch { store = nil; self.error = "Local history could not be opened. Your conversation can continue." }
        reload()
    }
    func append(role: ConversationHistoryRole, text: String, turn: UUID) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let date = Date()
        enqueue { store in _ = try await store.append(role: role, text: text, turnID: turn, date: date) }
    }
    func beginAssistant(turn: UUID) {
        guard store != nil, !closing, assistantIDs[turn] == nil else { return }
        let id = UUID(), date = Date()
        assistantIDs[turn] = id
        enqueue { store in try await store.beginAssistant(id: id, turnID: turn, date: date) }
    }
    func recordAssistant(turn: UUID, text: String? = nil, event: ConversationHistoryEvent) {
        guard !closing, let id = assistantIDs[turn] else { return }
        let date = Date()
        enqueue { store in
            _ = try await store.recordAssistant(id: id, turnID: turn, text: text, event: event, date: date)
        }
    }
    func reload() { enqueue { _ in } }
    func requestDelete(id: UUID) -> LocalRecordDeletionPrompt? {
        guard !closing, store != nil, let record = records.first(where: { $0.id == id }) else { return nil }
        let prompt = LocalRecordDeletionPrompt(title: "Delete this history entry?",
            message: "The saved \(record.role == .user ? "user" : "assistant") text from \(record.date.formatted(date: .abbreviated, time: .shortened)) will be permanently deleted. This cannot be undone.")
        pendingDeletion = (prompt.id, .record(id), revision); return prompt
    }
    func requestClear() -> LocalRecordDeletionPrompt? {
        guard !closing, store != nil else { return nil }
        let prompt = LocalRecordDeletionPrompt(title: "Delete all local text history?",
            message: "All saved conversation text and any unreadable history file will be permanently deleted. This cannot be undone.")
        pendingDeletion = (prompt.id, .all, revision); return prompt
    }
    func cancelDeletion() { pendingDeletion = nil }
    @discardableResult func confirmDeletion(_ prompt: UUID) -> Bool {
        guard let request = pendingDeletion, request.prompt == prompt else { return false }
        pendingDeletion = nil
        guard !closing, revision == request.revision else { return false }
        switch request.target {
        case .record(let id): delete(id: id)
        case .all: clear()
        }
        return true
    }
    private func delete(id: UUID) {
        guard !closing else { return }
        assistantIDs = assistantIDs.filter { $0.value != id }
        onDelete?()
        enqueue { store in try await store.delete(id: id) }
    }
    private func clear() {
        guard !closing else { return }
        assistantIDs.removeAll()
        onDelete?()
        enqueue { store in try await store.clear() }
    }
    func copy(id: UUID) async {
        let previous = writes, expected = revision
        await previous?.value
        guard let store else { return }
        do {
            let text = try await store.textToCopy(id: id)
            guard revision == expected, !closing else { return }
            copyText(text)
        }
        catch {
            if revision == expected { self.error = "This history entry could not be copied. Refresh and try again." }
        }
    }
    func closeAdmissions() { cancelDeletion(); closing = true; revision = UUID(); assistantIDs.removeAll() }
    func flush() async {
        await writes?.value
        if closing { busy = false }
    }
    private func enqueue(_ operation: @escaping @MainActor (ConversationHistoryStore) async throws -> Void) {
        guard let store, !closing else { return }
        cancelDeletion()
        let previous = writes; busy = true
        let expected = UUID(); revision = expected
        writes = Task { [weak self] in
            await previous?.value
            do {
                try await operation(store)
                let records = try await store.read()
                guard let self else { return }
                let terminalIDs = Set(records.filter(\.isTerminal).map(\.id))
                self.assistantIDs = self.assistantIDs.filter { !terminalIDs.contains($0.value) }
                self.records = records.sorted { $0.date > $1.date }; self.error = nil
            } catch {
                self?.error = "Local history could not be read or saved. Existing files were kept. Delete entries if storage is full; Delete all resets an unreadable history."
            }
            if self?.revision == expected { self?.busy = false }
        }
    }
}

/// An explicit Read action opens this reusable native utility surface.
@MainActor
final class ConversationHistoryPanel: NSObject, NSWindowDelegate {
    private let host = UtilityPanelHost(size: NSSize(width: 540, height: 500), minSize: NSSize(width: 400, height: 340),
                                        title: "Dot · Local text history")
    private var panel: NSPanel? { host.panel }
    private weak var model: ConversationHistoryModel?
    private let confirmation: LocalRecordDeletionConfirmation
    init(confirmation: LocalRecordDeletionConfirmation? = nil) {
        self.confirmation = confirmation ?? LocalRecordDeletionConfirmation(); super.init()
    }
    var onVisibility: ((Bool) -> Void)?
    func show(model: ConversationHistoryModel) {
        invalidateDeletion()
        let changedModel = self.model !== model
        self.model = model
        host.window(delegate: self) {
            NSHostingView(rootView: ConversationHistoryView(model: model,
                delete: { [weak self] id in self?.requestDeletion(id: id) },
                clear: { [weak self] in self?.requestDeletion(id: nil) }))
        }
        if changedModel, let panel {
            panel.contentView = NSHostingView(rootView: ConversationHistoryView(model: model,
                delete: { [weak self] id in self?.requestDeletion(id: id) },
                clear: { [weak self] in self?.requestDeletion(id: nil) }))
        }
        model.reload(); host.present(onVisibility)
    }
    func windowWillClose(_ notification: Notification) { invalidateDeletion(); onVisibility?(false) }
    private func invalidateDeletion() { confirmation.invalidate(); model?.cancelDeletion() }
    func requestDeletion(id: UUID?) {
        guard let model, let panel, !model.busy, !model.closing else { return }
        let prompt = id.flatMap { model.requestDelete(id: $0) } ?? (id == nil ? model.requestClear() : nil)
        guard let prompt else { return }
        confirmation.present(prompt, for: panel) { [weak model] confirmed in
            if confirmed { model?.confirmDeletion(prompt.id) } else { model?.cancelDeletion() }
        }
    }
}

private struct ConversationHistoryView: View {
    @ObservedObject var model: ConversationHistoryModel
    let delete: (UUID) -> Void
    let clear: () -> Void
    @State private var selection: UUID?
    private var selected: ConversationHistoryRecord? { model.records.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved on this Mac. Microphone audio and screenshots are not stored.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.largeTitle)
                    Text(model.busy ? "Reading local history…" : "No saved conversations yet")
                }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
            } else {
                HSplitView {
                    List(model.records, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.role == .user ? "You" : "Dot").fontWeight(.medium)
                                Spacer()
                                Text(record.date, style: .time).foregroundStyle(.secondary)
                            }.font(.caption)
                            if record.role == .assistant {
                                Text(record.statusSummary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(record.text).lineLimit(2).font(.callout)
                        }.padding(.vertical, 4).tag(record.id)
                    }.frame(minWidth: 160, idealWidth: 210)
                    ScrollView {
                        if let selected {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(selected.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(selected.statusSummary).font(.callout).fontWeight(.medium)
                                Text(selected.deliveryExplanation).font(.caption).foregroundStyle(.secondary)
                                if selected.role == .assistant { Text("Generated text").font(.caption).fontWeight(.medium) }
                                Text(selected.text.isEmpty ? "No generated text saved." : selected.text)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12)
                        } else {
                            Text("Select an entry to read it.").foregroundStyle(.secondary).padding()
                        }
                    }.frame(minWidth: 180)
                }
            }
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Spacer()
                Button("Copy") { if let selection { Task { await model.copy(id: selection) } } }.disabled(selected == nil)
                Button("Delete", role: .destructive) { if let selection { delete(selection) } }
                    .disabled(selected == nil || model.busy)
                Button("Delete all", role: .destructive, action: clear)
                    .disabled(model.busy || (model.records.isEmpty && model.error == nil))
            }
        }.padding(14).disabled(model.closing)
    }
}
