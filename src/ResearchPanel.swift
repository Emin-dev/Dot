import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ResearchNotebookModel: ObservableObject {
    enum Activity: String { case loading = "Reading notebooks…", creating = "Reading selected sources…", deleting = "Deleting notebook…", exporting = "Exporting evidence…" }
    enum SourceDestination: Equatable { case revealFile(URL), webPage(URL) }
    @Published var title = "Source brief" {
        didSet {
            if title.count > 200 || title.utf8.count > 800 {
                title = String(title.truncated(toUTF8Bytes: 800).prefix(200))
                error = "Notebook titles are limited to 200 characters."
            }
        }
    }
    @Published var urlText = "" {
        didSet { if urlText.utf8.count > 81_920 { urlText = urlText.truncated(toUTF8Bytes: 81_920); error = "The source URL list is too long." } }
    }
    @Published var selection: UUID? { didSet { if selection != oldValue { copyRevision = UUID(); cancelDeletion() } } }
    @Published private(set) var folder: URL?
    @Published private(set) var notebooks: [ResearchNotebook] = []
    @Published private(set) var activity: Activity?
    @Published private(set) var draining = false
    @Published private(set) var shuttingDown = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private let store: (any ResearchNotebookAccess)?
    private let copyText: (String) -> Void
    private let openSource: (SourceDestination) -> Bool
    private var operation: Task<Void, Never>?
    private var revision = UUID()
    private var copyRevision = UUID()
    private var acceptingActions = true
    private var pendingDeletion: (prompt: UUID, notebook: ResearchNotebook, revision: UUID)?
    var busy: Bool { activity != nil }
    var selected: ResearchNotebook? { notebooks.first { $0.id == selection } }
    var canCreate: Bool {
        acceptingActions && !busy && !draining && store != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (folder != nil || !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    init(store: (any ResearchNotebookAccess)? = nil, directory: URL? = nil,
         webReader: ResearchWebReader = ResearchWebReader(),
         copyText: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
         }, openSource: @escaping (SourceDestination) -> Bool = { destination in
             switch destination {
             case .revealFile(let url):
                 guard FileManager.default.fileExists(atPath: url.path) else { return false }
                 NSWorkspace.shared.activateFileViewerSelecting([url]); return true
             case .webPage(let url): return NSWorkspace.shared.open(url)
             }
         }) {
        self.copyText = copyText
        self.openSource = openSource
        if let store { self.store = store }
        else {
            do { self.store = try ResearchNotebookStore(directory: directory, webReader: webReader) }
            catch { self.store = nil; self.error = "Local research notebooks could not be opened." }
        }
    }

    static func parseURLs(_ text: String) throws -> [URL] {
        guard text.utf8.count <= 81_920 else { throw ResearchNotebookError.limitExceeded }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count <= 10 else { throw ResearchNotebookError.limitExceeded }
        return try parts.map {
            guard let url = URL(string: String($0)), ResearchWebReader.allowed(url) else { throw ResearchNotebookError.invalidInput }
            return url
        }
    }
    func selectFolder(_ folder: URL?) {
        guard acceptingActions, !busy else { return }
        self.folder = folder; error = nil; notice = nil
    }
    func open() { guard !shuttingDown else { return }; acceptingActions = true; if !busy && !draining { reload() } }
    func closeAdmissions() { shuttingDown = true; close() }
    func close() { acceptingActions = false; cancel() }
    func cancel() {
        cancelDeletion()
        revision = UUID(); copyRevision = UUID(); operation?.cancel()
        // Retain an admitted store operation until its write has really settled.
        // Cancellation invalidates presentation, but cannot promise write rollback.
        draining = operation != nil
        activity = nil
        notice = draining ? "Stopping. Waiting for any admitted local write to settle." : "Stopped. Refresh to check any results already saved."
        error = nil
    }
    func flush() async { await operation?.value }
    func reload() {
        run(.loading) { store in (try await store.read(), nil, nil) }
    }
    func create() {
        guard canCreate else { return }
        notice = nil; error = nil
        let urls: [URL]
        do { urls = try Self.parseURLs(urlText) }
        catch { self.error = error.localizedDescription; return }
        let title = self.title, folder = self.folder
        run(.creating) { store in
            let scoped = folder?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { folder?.stopAccessingSecurityScopedResource() } }
            let notebook = try await store.createBrief(title: title, folder: folder, urls: urls)
            try Task.checkCancellation()
            return (try await store.read(), notebook.id, "Source brief saved on this Mac.")
        }
    }
    func requestDeleteSelected() -> LocalRecordDeletionPrompt? {
        guard acceptingActions, !busy, let selected else { return nil }
        let prompt = LocalRecordDeletionPrompt(title: "Delete this source notebook?",
            message: "The notebook “\(selected.title)” and its saved source excerpts will be permanently deleted. Original files and websites are unaffected. This cannot be undone.")
        pendingDeletion = (prompt.id, selected, revision); return prompt
    }
    func cancelDeletion() { pendingDeletion = nil }
    @discardableResult func confirmDeletion(_ prompt: UUID) -> Bool {
        guard let request = pendingDeletion, request.prompt == prompt else { return false }
        pendingDeletion = nil
        guard acceptingActions, !busy, revision == request.revision, selected == request.notebook else { return false }
        let id = request.notebook.id
        run(.deleting) { store in
            try await store.delete(id: id)
            return (try await store.read(), nil, "Notebook deleted.")
        }
        return true
    }
    func exportSelected(to destination: URL) {
        guard let id = selected?.id else { return }
        run(.exporting) { store in
            try await store.export(id: id, to: destination)
            return (try await store.read(), id, "Evidence exported.")
        }
    }
    func copySelected() async {
        guard acceptingActions, !busy, let store, let id = selected?.id else { return }
        notice = nil; error = nil
        let expected = revision, copy = UUID(); copyRevision = copy
        do {
            let text = try await store.textToCopy(id: id)
            guard acceptingActions, !Task.isCancelled, revision == expected,
                  copyRevision == copy, selection == id, notebooks.contains(where: { $0.id == id }) else { return }
            copyText(text); notice = "Evidence copied."; error = nil
        } catch {
            if acceptingActions, !Task.isCancelled, revision == expected, copyRevision == copy { self.error = error.localizedDescription }
        }
    }
    static func destination(for source: ResearchSource) -> SourceDestination? {
        let url = source.originalURL
        switch source.kind {
        case .localText, .localPDF:
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            // Reveal in Finder: never execute a stored local source or open an app.
            return .revealFile(url)
        case .webPage, .webPDF:
            guard ResearchWebReader.allowed(url) else { return nil }
            return .webPage(url)
        }
    }
    func openOriginal(sourceID: UUID) {
        guard acceptingActions, !busy, let source = selected?.sources.first(where: { $0.id == sourceID }) else { return }
        notice = nil; error = nil
        guard let destination = Self.destination(for: source) else { error = "This stored source cannot be opened safely."; return }
        guard openSource(destination) else { error = "The original source could not be opened."; return }
        error = nil
        notice = source.originalURL.isFileURL ? "Requested source in Finder." : "Requested source in your browser."
    }
    private func run(_ activity: Activity,
                     body: @escaping (any ResearchNotebookAccess) async throws -> ([ResearchNotebook], UUID?, String?)) {
        guard acceptingActions, !busy, operation == nil, let store else { return }
        cancelDeletion()
        let expected = UUID(); revision = expected
        self.activity = activity; error = nil; notice = nil
        operation = Task { [weak self] in
            defer {
                self?.operation = nil
                if self?.draining == true {
                    self?.draining = false
                    self?.notice = "Stopped. Refresh to check any results already saved."
                }
            }
            do {
                try Task.checkCancellation()
                let (notebooks, preferred, notice) = try await body(store)
                guard let self, self.acceptingActions, self.revision == expected, !Task.isCancelled else { return }
                self.notebooks = notebooks.sorted { $0.createdAt > $1.createdAt }
                if let preferred { self.selection = preferred }
                else if !notebooks.contains(where: { $0.id == self.selection }) { self.selection = self.notebooks.first?.id }
                self.notice = notice; self.activity = nil; self.operation = nil
            } catch {
                guard let self, self.acceptingActions, self.revision == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.activity = nil; self.operation = nil
            }
        }
    }
    deinit { operation?.cancel() }
}

@MainActor
final class ResearchPanel: NSObject, NSWindowDelegate {
    let model: ResearchNotebookModel
    private let host = UtilityPanelHost(size: NSSize(width: 720, height: 620), minSize: NSSize(width: 560, height: 430),
                                        title: "Dot · Source notebooks")
    private var panel: NSPanel? { host.panel }
    private var presentation = UUID()
    private let confirmation: LocalRecordDeletionConfirmation
    var onVisibility: ((Bool) -> Void)?
    init(model: ResearchNotebookModel, confirmation: LocalRecordDeletionConfirmation? = nil) {
        self.model = model; self.confirmation = confirmation ?? LocalRecordDeletionConfirmation(); super.init()
    }
    convenience init(directory: URL? = nil) { self.init(model: ResearchNotebookModel(directory: directory)) }
    func show() {
        guard !model.shuttingDown else { return }
        invalidateSheets()
        host.window(delegate: self) {
            NSHostingView(rootView: ResearchNotebookView(model: model,
                chooseFolder: { [weak self] in self?.chooseFolder() }, export: { [weak self] in self?.chooseExport() },
                delete: { [weak self] in self?.requestDeletion() }))
        }
        model.open(); host.present(onVisibility)
    }
    func cancel() { invalidateSheets(); model.cancel() }
    func close() { invalidateSheets(); model.close(); panel?.close() }
    func closeAdmissions() { invalidateSheets(); model.closeAdmissions(); panel?.close() }
    func windowWillClose(_ notification: Notification) { invalidateSheets(); model.close(); onVisibility?(false) }
    private func invalidateSheets() {
        confirmation.invalidate(); model.cancelDeletion()
        presentation = UUID()
        host.endAttachedSheet()
    }
    func requestDeletion() {
        guard let panel, let prompt = model.requestDeleteSelected() else { return }
        confirmation.present(prompt, for: panel) { [weak model] confirmed in
            if confirmed { model?.confirmDeletion(prompt.id) } else { model?.cancelDeletion() }
        }
    }
    private func chooseFolder() {
        guard let panel, !model.busy else { return }
        let expected = presentation
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = false; chooser.prompt = "Read this folder"; chooser.directoryURL = model.folder
        chooser.beginSheetModal(for: panel) { [weak self, weak panel] response in
            guard let self, let panel, self.presentation == expected, panel.isVisible, self.panel === panel, response == .OK else { return }
            self.model.selectFolder(chooser.url)
        }
    }
    private func chooseExport() {
        guard let panel, !model.busy, let id = model.selected?.id else { return }
        let expected = presentation
        let chooser = NSSavePanel(); chooser.nameFieldStringValue = "dot-source-brief.md"
        chooser.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        chooser.beginSheetModal(for: panel) { [weak self, weak panel] response in
            guard let self, let panel, self.presentation == expected, panel.isVisible, self.panel === panel, self.model.selection == id,
                  response == .OK, let url = chooser.url else { return }
            self.model.exportSelected(to: url)
        }
    }
}

private struct ResearchNotebookView: View {
    @ObservedObject var model: ResearchNotebookModel
    let chooseFolder: () -> Void
    let export: () -> Void
    let delete: () -> Void
    @State private var showReceipts = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read selected files and source URLs into a local evidence notebook. This performs source reading, not a web search.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Notebook title", text: $model.title).textFieldStyle(.roundedBorder)
                Button("Choose folder…", action: chooseFolder)
            }.disabled(model.busy)
            if let folder = model.folder {
                HStack {
                    Label(folder.lastPathComponent, systemImage: "folder").lineLimit(1)
                    Text("Up to 20 readable text/PDF files").foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { model.selectFolder(nil) }.disabled(model.busy)
                }.font(.caption)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Source URLs · one per line · up to 10").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.urlText).font(.system(.caption, design: .monospaced))
                    .frame(height: 44).border(Color.secondary.opacity(0.25)).disabled(model.busy)
                    .accessibilityLabel("Source URLs, up to ten HTTP or HTTPS addresses")
            }
            HStack {
                Button("Create source brief") { model.create() }.disabled(!model.canCreate)
                if let activity = model.activity {
                    ProgressView().controlSize(.small)
                    Text(activity.rawValue).font(.caption)
                    Spacer()
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                } else if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HSplitView {
                List(model.notebooks, selection: $model.selection) { notebook in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: notebook.title).font(.callout).lineLimit(2)
                        Text("\(notebook.sources.count) sources · \(notebook.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(notebook.id)
                }.frame(minWidth: 150, idealWidth: 190)
                VStack(alignment: .leading, spacing: 8) {
                    if let notebook = model.selected {
                        Picker("Read", selection: $showReceipts) {
                            Text("Evidence text").tag(false); Text("Source receipts").tag(true)
                        }.pickerStyle(.segmented)
                        ScrollView {
                            if showReceipts {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Source content is untrusted data. Read timestamps and hashes record what was retrieved; they do not independently verify the source's claims.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(notebook.sources.enumerated()), id: \.element.id) { index, source in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: "[\(index + 1)] \(source.title)").font(.headline)
                                            Text(verbatim: source.originalURL.absoluteString).font(.caption).textSelection(.enabled)
                                            if source.finalURL != source.originalURL {
                                                Text(verbatim: "Final URL: " + source.finalURL.absoluteString).font(.caption).textSelection(.enabled)
                                            }
                                            Text("Read: \(source.retrievedAt.formatted())").font(.caption)
                                            Text(source.modifiedAt.map { "Source modified: " + $0.formatted() } ?? "Source publication/modification date unavailable.").font(.caption)
                                            Text("\(source.bytesRead) bytes\(source.pagesRead.map { " · \($0) PDF pages" } ?? "")\(source.truncated ? " · shortened extract" : "")").font(.caption)
                                            Text(verbatim: source.transportSummary).font(.caption).foregroundStyle(.secondary)
                                            Text(verbatim: "SHA-256: " + source.sha256).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                            Button(source.originalURL.isFileURL ? "Reveal in Finder" : "Open original source") {
                                                model.openOriginal(sourceID: source.id)
                                            }.disabled(model.busy || ResearchNotebookModel.destination(for: source) == nil)
                                            DisclosureGroup("Read captured source text") {
                                                Text(verbatim: source.text).font(.system(.caption, design: .monospaced))
                                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        Divider()
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            } else {
                                Text(verbatim: notebook.presentedBriefMarkdown).font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    } else {
                        Text(model.notebooks.isEmpty ? "No source notebooks yet. Choose a folder or paste source URLs above." : "Select a notebook to read it.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 280).padding(.leading, 8)
            }
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Spacer()
                Button("Copy") { Task { await model.copySelected() } }.disabled(model.selected == nil || model.busy)
                Button("Export…", action: export).disabled(model.selected == nil || model.busy)
                Button("Delete", role: .destructive, action: delete).disabled(model.selected == nil || model.busy)
            }
        }.padding(14)
    }
}
