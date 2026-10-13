import SwiftUI
import AppKit

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
    func delete(id: UUID) {
        guard !closing else { return }
        assistantIDs = assistantIDs.filter { $0.value != id }
        onDelete?()
        enqueue { store in try await store.delete(id: id) }
    }
    func clear() {
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
    func closeAdmissions() { closing = true; revision = UUID(); assistantIDs.removeAll() }
    func flush() async {
        await writes?.value
        if closing { busy = false }
    }
    private func enqueue(_ operation: @escaping @MainActor (ConversationHistoryStore) async throws -> Void) {
        guard let store, !closing else { return }
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
    private var panel: NSPanel?
    var onVisibility: ((Bool) -> Void)?
    func show(model: ConversationHistoryModel) {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "Dot · Local text history"
            window.minSize = NSSize(width: 400, height: 340)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: ConversationHistoryView(model: model))
            window.center(); panel = window
        }
        model.reload(); onVisibility?(true)
        panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: false)
    }
    func windowWillClose(_ notification: Notification) { onVisibility?(false) }
}

private struct ConversationHistoryView: View {
    @ObservedObject var model: ConversationHistoryModel
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
                Button("Delete") { if let selection { model.delete(id: selection); self.selection = nil } }
                    .disabled(selected == nil || model.busy)
                Button("Delete all", role: .destructive) { model.clear(); selection = nil }
                    .disabled(model.busy || (model.records.isEmpty && model.error == nil))
            }
        }.padding(14).disabled(model.closing)
    }
}
