import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum NativeActionChoice: String, CaseIterable, Identifiable {
    case launch = "Open app", browse = "Open URL", read = "Read text", create = "Create text"
    case edit = "Edit text", move = "Move text", folder = "Create folder"
    var id: String { rawValue }
    var needsFolder: Bool { self != .launch && self != .browse }
    var needsText: Bool { self == .create || self == .edit }
}

@MainActor
final class NativeActionPanelModel: ObservableObject {
    @Published var choice = NativeActionChoice.launch
    @Published var bundleID = ""
    @Published var webURL = ""
    @Published var path = "" { didSet { if path != oldValue { readVersion = nil } } }
    @Published var destination = ""
    @Published var text = ""
    @Published var selection: UUID?
    @Published private(set) var documentRoot: URL?
    @Published private(set) var receipts: [NativeActionReceipt] = []
    @Published private(set) var busy = false {
        didSet {
            if !busy { let waiting = flushWaiters; flushWaiters = []; waiting.forEach { $0.resume() } }
        }
    }
    @Published private(set) var cancelling = false
    @Published private(set) var shuttingDown = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastResult: NativeActionResult?
    private let workspace: any NativeWorkspaceAccess
    private let applicationStorage: URL?
    private var applicationExecutor: NativeActionExecutor?
    private var documentExecutor: NativeActionExecutor?
    private var applicationReceipts: [NativeActionReceipt] = []
    private var documentReceipts: [NativeActionReceipt] = []
    private var readVersion: (path: String, sha256: String)?
    private var scopedFolder: URL?
    private var work: Task<NativeActionResult, Never>?
    private var acceptingActions = true
    private var requestID: UUID?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []

    init(applicationStorage: URL? = nil, workspace: any NativeWorkspaceAccess = SystemNativeWorkspaceAccess()) {
        self.workspace = workspace
        self.applicationStorage = applicationStorage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Dot/Actions", isDirectory: true)
    }
    deinit { scopedFolder?.stopAccessingSecurityScopedResource() }

    var selected: NativeActionReceipt? { receipts.first { $0.id == selection } }
    var canUseReadVersion: Bool { readVersion?.path == path && documentRoot != nil }
    var canRun: Bool {
        guard acceptingActions, !busy, !choice.needsFolder || documentRoot != nil else { return false }
        switch choice {
        case .launch: return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .browse: return (try? NativeActionExecutor.webURL(webURL)) != nil
        case .read, .folder: return !path.isEmpty
        case .create: return !path.isEmpty && text.utf8.count <= NativeActionExecutor.maximumTextBytes
        case .edit: return canUseReadVersion && text.utf8.count <= NativeActionExecutor.maximumTextBytes
        case .move: return canUseReadVersion && !destination.isEmpty && path != destination
        }
    }
    var canUndoSelected: Bool {
        guard acceptingActions, !busy, let selected, selected.status == .succeeded, selected.undo != nil else { return false }
        return !receipts.contains { $0.status == .succeeded && $0.undoes == selected.id }
    }

    /// Folder selection is an explicit native UI action. No background scan or
    /// permission request occurs, and a failed selection retains the prior scope.
    @discardableResult func selectFolder(_ url: URL) async -> Bool {
        guard acceptingActions, !busy else { error = NativeActionError.busy.localizedDescription; return false }
        guard url.isFileURL else { error = NativeActionError.unsafePath.localizedDescription; return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if canonical == documentRoot { error = nil; return true }
        busy = true; defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let executor = try NativeActionExecutor(documentRoot: url, workspace: workspace)
            let previous = scopedFolder
            documentExecutor = executor; documentRoot = canonical
            scopedFolder = scoped ? url : nil
            previous?.stopAccessingSecurityScopedResource()
            documentReceipts = await executor.receipts()
            readVersion = nil; selection = nil; lastResult = nil; error = nil
            notice = "Document actions use the selected folder. Receipts and up to 20 recovery versions stay in its private .dot-actions folder."
            refreshVisibleReceipts(); return true
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            self.error = (error as? NativeActionError)?.localizedDescription ?? "The document folder could not be opened."
            return false
        }
    }

    /// Typed requests are the only executor entry point. File/web contents are
    /// displayed as data; they never select an action or supply tool authority.
    @discardableResult func execute(_ action: NativeAction, id: UUID = UUID()) async -> NativeActionResult? {
        guard acceptingActions, !busy else { error = NativeActionError.busy.localizedDescription; return nil }
        guard !Task.isCancelled else { notice = "Stopped before starting an action."; return nil }
        let executor: NativeActionExecutor
        do { executor = try self.executor(for: action) }
        catch { self.error = error.localizedDescription; return nil }
        busy = true; cancelling = false; error = nil; notice = nil; requestID = id
        let operation = Task { await executor.execute(.init(id: id, action: action)) }
        work = operation
        let result = await withTaskCancellationHandler(operation: { await operation.value }, onCancel: { operation.cancel() })
        // Keep the actual result even if Stop/Close arrived after a verified file
        // operation. Cancellation is not proof that an OS action was recalled.
        if requestID == id {
            let records = await executor.receipts()
            if executor === documentExecutor { documentReceipts = records } else { applicationReceipts = records }
            refreshVisibleReceipts()
            lastResult = result; selection = result.receipt.id
            if !result.historySaved { error = "The result could not be saved to local action history. Its outcome is shown below." }
            else if result.receipt.status == .failed { error = result.receipt.detail }
            else { notice = result.receipt.detail }
            updateReadVersion(action: action, result: result)
            busy = false; cancelling = false; requestID = nil; work = nil
        }
        return result
    }

    @discardableResult func runSelected() async -> NativeActionResult? {
        guard canRun else { error = "Complete the action fields. Read the current document before editing or moving it."; return nil }
        let action: NativeAction
        switch choice {
        case .launch: action = .launchApplication(bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .browse: action = .openWebURL(webURL)
        case .read: action = .readText(path: path)
        case .create: action = .createText(path: path, text: text)
        case .edit:
            guard let version = readVersion, version.path == path else { return nil }
            action = .editText(path: path, expectedSHA256: version.sha256, text: text)
        case .move:
            guard let version = readVersion, version.path == path else { return nil }
            action = .moveDocument(from: path, to: destination, expectedSHA256: version.sha256)
        case .folder: action = .createFolder(path: path)
        }
        return await execute(action)
    }
    @discardableResult func readCurrent() async -> NativeActionResult? { await execute(.readText(path: path)) }
    @discardableResult func undoSelected() async -> NativeActionResult? {
        guard canUndoSelected, let selection else { return nil }
        return await execute(.undo(receiptID: selection))
    }
    func open() { if !shuttingDown { acceptingActions = true } }
    func close() { acceptingActions = false; stop() }
    /// Unlike closing a window, application shutdown cannot reopen action admissions.
    func closeAdmissions() { shuttingDown = true; close() }
    func stop() {
        guard let work else { return }
        cancelling = true; notice = "Stopping. A request already sent to macOS may still complete."
        work.cancel()
    }
    func flush() async {
        if busy { await withCheckedContinuation { flushWaiters.append($0) } }
    }
    func reloadReceipts() async {
        guard acceptingActions, !busy else { return }
        busy = true; defer { busy = false }
        if applicationExecutor == nil, let applicationStorage,
           FileManager.default.fileExists(atPath: applicationStorage.path) {
            do { applicationExecutor = try NativeActionExecutor(documentRoot: applicationStorage, workspace: workspace) }
            catch { self.error = "Local application receipts could not be opened. Existing files were preserved." }
        }
        if let applicationExecutor { applicationReceipts = await applicationExecutor.receipts() }
        if let documentExecutor { documentReceipts = await documentExecutor.receipts() }
        refreshVisibleReceipts()
    }

    private func executor(for action: NativeAction) throws -> NativeActionExecutor {
        switch action {
        case .launchApplication, .openWebURL, .sendShortcut, .moveMouse, .click, .clickElement:
            if let applicationExecutor { return applicationExecutor }
            guard let applicationStorage else { throw NativeActionError.storageUnavailable }
            try FileManager.default.createDirectory(at: applicationStorage, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let executor = try NativeActionExecutor(documentRoot: applicationStorage, workspace: workspace)
            applicationExecutor = executor; return executor
        case .undo(let id):
            guard documentReceipts.contains(where: { $0.id == id }), let documentExecutor else { throw NativeActionError.nothingToUndo }
            return documentExecutor
        default:
            guard let documentExecutor else { throw NativeActionError.unsafePath }
            return documentExecutor
        }
    }
    private func updateReadVersion(action: NativeAction, result: NativeActionResult) {
        guard result.receipt.status == .succeeded else {
            switch action { case .editText, .moveDocument, .undo: readVersion = nil; default: break }
            return
        }
        switch action {
        case .readText(let path):
            if let text = result.text, let hash = result.sha256 {
                self.path = path; self.text = text; readVersion = (path, hash)
            }
        case .createText(let path, _), .editText(let path, _, _):
            if self.path == path, let hash = result.sha256 { readVersion = (path, hash) }
        case .moveDocument, .undo: readVersion = nil
        default: break
        }
    }
    private func refreshVisibleReceipts() {
        receipts = (applicationReceipts + documentReceipts).sorted { $0.startedAt > $1.startedAt }
    }
}

extension NativeActionReceipt {
    var statusTitle: String {
        switch status {
        case .started: return "Awaiting verification"
        case .succeeded: return "Verified"
        case .handedOff: return "Handed to browser"
        case .failed: return "Not verified"
        case .cancelled: return "Cancelled"
        }
    }
}

@MainActor
final class NativeActionPanel: NSObject, NSWindowDelegate {
    enum PickerKind { case folder, application }
    typealias PickerReply = @MainActor (URL?) -> Void
    typealias Picker = @MainActor (PickerKind, NSPanel, @escaping PickerReply) -> Void
    let model: NativeActionPanelModel
    var onVisibility: ((Bool) -> Void)?
    private var panel: NSPanel?
    private var presentation = UUID()
    private let pickerOverride: Picker?
    init(model: NativeActionPanelModel? = nil, picker: Picker? = nil) {
        self.model = model ?? NativeActionPanelModel(); pickerOverride = picker; super.init()
    }
    func show() {
        guard !model.shuttingDown else { return }
        invalidateSheets()
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            window.title = "Dot · Native actions"; window.minSize = NSSize(width: 520, height: 500)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: NativeActionView(model: model, chooseFolder: { [weak self] in self?.chooseFolder() },
                                                                         chooseApplication: { [weak self] in self?.chooseApplication() }))
            window.center(); panel = window
        }
        model.open(); onVisibility?(true); panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: false)
        Task { await model.reloadReceipts() }
    }
    func stop() { invalidateSheets(); model.stop() }
    func closeAdmissions() { invalidateSheets(); model.closeAdmissions(); panel?.close() }
    func windowWillClose(_ notification: Notification) { invalidateSheets(); model.close(); onVisibility?(false) }
    private func invalidateSheets() {
        presentation = UUID()
        if let panel, let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel) }
    }
    func chooseFolder() {
        guard !model.shuttingDown, !model.busy, let panel, panel.isVisible, panel.attachedSheet == nil else { return }
        presentation = UUID()
        let expected = presentation
        let receive: PickerReply = { [weak self, weak panel] url in
            guard let url else { return }
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.presentation == expected, self.panel === panel,
                      panel.isVisible, !self.model.shuttingDown, !self.model.busy else { return }
                _ = await self.model.selectFolder(url)
            }
        }
        if let pickerOverride { pickerOverride(.folder, panel, receive); return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.prompt = "Use folder"
        picker.message = "Choose the folder for document actions and their local recovery receipts."
        picker.beginSheetModal(for: panel) { response in receive(response == .OK ? picker.url : nil) }
    }
    func chooseApplication() {
        guard !model.shuttingDown, !model.busy, let panel, panel.isVisible, panel.attachedSheet == nil else { return }
        presentation = UUID()
        let expected = presentation
        let receive: PickerReply = { [weak self, weak panel] url in
            guard let url, let identifier = Bundle(url: url)?.bundleIdentifier else { return }
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.presentation == expected, self.panel === panel,
                      panel.isVisible, !self.model.shuttingDown, !self.model.busy else { return }
                self.model.bundleID = identifier
            }
        }
        if let pickerOverride { pickerOverride(.application, panel, receive); return }
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false; picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); picker.prompt = "Choose app"
        picker.beginSheetModal(for: panel) { response in receive(response == .OK ? picker.url : nil) }
    }
}

private struct NativeActionView: View {
    @ObservedObject var model: NativeActionPanelModel
    let chooseFolder: () -> Void
    let chooseApplication: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Action", selection: $model.choice) {
                    ForEach(NativeActionChoice.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 240)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.cancelling ? "Stopping…" : "Stop") { model.stop() }.disabled(!model.busy || model.cancelling)
            }
            Group {
                if model.choice == .launch {
                    HStack { TextField("Application bundle ID", text: $model.bundleID); Button("Choose app…", action: chooseApplication) }
                    Text("Opens an installed app and verifies that it is running.").font(.caption).foregroundStyle(.secondary)
                } else if model.choice == .browse {
                    TextField("https://example.com", text: $model.webURL)
                    Text("Opens HTTP or HTTPS in your default browser. The receipt cannot verify that the page loaded.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(model.documentRoot?.path ?? "Choose a document folder").font(.caption).lineLimit(2).textSelection(.enabled)
                        Spacer(); Button("Choose folder…", action: chooseFolder)
                    }
                    TextField("Relative path, such as Notes/idea.txt", text: $model.path)
                    if model.choice == .move { TextField("New relative path", text: $model.destination) }
                    if model.choice == .edit || model.choice == .move {
                        HStack {
                            Text(model.canUseReadVersion ? "Current content hash available" : "Read this path before changing it").font(.caption).foregroundStyle(.secondary)
                            Spacer(); Button("Read current") { Task { await model.readCurrent() } }.disabled(model.documentRoot == nil || model.path.isEmpty)
                        }
                    }
                    if model.choice == .read {
                        ScrollView {
                            Text(model.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }.frame(minHeight: 100, maxHeight: 180).border(.quaternary).accessibilityLabel("Document text")
                    } else if model.choice.needsText {
                        TextEditor(text: $model.text).font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100, maxHeight: 180).border(.quaternary)
                            .accessibilityLabel("Document content")
                    }
                    Text("UTF-8 text up to 1 MB. Existing destinations are never replaced by Create or Move. Document text cannot issue actions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy)
            HStack {
                Button(model.choice.rawValue) { Task { await model.runSelected() } }.keyboardShortcut(.return).disabled(!model.canRun)
                Spacer()
                Button("Refresh receipts") { Task { await model.reloadReceipts() } }.disabled(model.busy)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            else if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HSplitView {
                List(model.receipts, selection: $model.selection) { receipt in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(receipt.operation + " · " + receipt.statusTitle).font(.caption).fontWeight(.medium)
                        Text(receipt.target).font(.caption).lineLimit(1)
                        Text(receipt.startedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }.tag(receipt.id)
                }.frame(minWidth: 160, idealWidth: 210)
                ScrollView {
                    if let receipt = model.selected {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(receipt.statusTitle).font(.headline)
                            Text(receipt.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(receipt.detail).font(.callout)
                            if let hash = receipt.sha256 { Text("SHA-256: " + hash).font(.caption2.monospaced()) }
                            if receipt.cancellationRequested { Text("Cancellation was requested; the recorded outcome above remains authoritative.").font(.caption) }
                            Button("Undo file action") { Task { await model.undoSelected() } }.disabled(!model.canUndoSelected)
                            Text(receipt.undo == nil ? "This action has no supported Undo." : "Undo checks the current file identity and content. Changed files are preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } else { Text("Select a dated receipt to inspect its outcome.").foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 230)
            }.frame(minHeight: 160)
        }.padding(14)
    }
}
