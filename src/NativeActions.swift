import Foundation
import AppKit
import CryptoKit
import Darwin

/// These are typed operations supplied by the app's user-goal planner. There is deliberately
/// no natural-language, webpage, document-command, AppleScript, or shell evaluator here.
enum NativeAction: Codable, Equatable, Sendable {
    case launchApplication(bundleID: String)
    case openWebURL(String)
    case readText(path: String)
    case createText(path: String, text: String)
    case editText(path: String, expectedSHA256: String, text: String)
    case moveDocument(from: String, to: String, expectedSHA256: String)
    case createFolder(path: String)
    case undo(receiptID: UUID)
}

struct NativeActionRequest: Sendable {
    let id: UUID
    let action: NativeAction
    init(id: UUID = UUID(), action: NativeAction) { self.id = id; self.action = action }
}

enum NativeActionStatus: String, Codable, Sendable { case started, succeeded, handedOff, failed, cancelled }
enum NativeActionVerification: String, Codable, Sendable {
    case none, runningApplication, browserHandoff, textRead, contentHash, fileMoved, directoryCreated, undoVerified
}

struct NativeActionReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    let operation: String
    let target: String
    var status: NativeActionStatus
    var verification: NativeActionVerification
    var detail: String
    var sha256: String?
    var undo: NativeActionUndo?
    var undoes: UUID?
    var cancellationRequested: Bool
}

struct NativeActionUndo: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case createdText, editedText, movedText, createdFolder }
    let kind: Kind
    let path: String
    let originalPath: String?
    let expectedSHA256: String?
    let originalSHA256: String?
    let backupName: String?
    let device: UInt64
    let inode: UInt64
}

struct NativeActionResult: Sendable {
    let receipt: NativeActionReceipt
    let text: String?
    /// A completed operation can still have a receipt-persistence failure. Report that separately.
    let historySaved: Bool
    var sha256: String? { receipt.sha256 }
}

struct NativeApplicationObservation: Sendable {
    let bundleID: String?
    let processID: Int32
    let isRunning: Bool
}

protocol NativeWorkspaceAccess: Sendable {
    func launchApplication(bundleID: String) async throws -> NativeApplicationObservation
    func openWebURL(_ url: URL) async throws -> NativeApplicationObservation
}

/// NSWorkspace supplies a launch/open completion, then the actual returned app is inspected.
/// Browser handoff cannot verify the remote page loaded or that a website completed a task.
struct SystemNativeWorkspaceAccess: NativeWorkspaceAccess {
    @MainActor func launchApplication(bundleID: String) async throws -> NativeApplicationObservation {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw NativeActionError.applicationUnavailable
        }
        return try await open { configuration, completion in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: completion)
        }
    }
    @MainActor func openWebURL(_ url: URL) async throws -> NativeApplicationObservation {
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw NativeActionError.applicationUnavailable
        }
        return try await open { configuration, completion in
            NSWorkspace.shared.open([url], withApplicationAt: application,
                                    configuration: configuration, completionHandler: completion)
        }
    }
    @MainActor private func open(_ dispatch: (NSWorkspace.OpenConfiguration,
        @escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void) async throws -> NativeApplicationObservation {
        try Task.checkCancellation()
        let reply = NativeWorkspaceReply()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                reply.continuation = continuation
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.promptsUserIfNeeded = false
                configuration.addsToRecentItems = false
                reply.timeout = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    reply.finish(.failure(NativeActionError.unverifiedHandoff))
                }
                dispatch(configuration) { application, error in
                    Task { @MainActor in
                        if error != nil { reply.finish(.failure(NativeActionError.workspaceRejected)); return }
                        guard let application else { reply.finish(.failure(NativeActionError.unverifiedHandoff)); return }
                        reply.finish(.success(NativeApplicationObservation(bundleID: application.bundleIdentifier,
                            processID: application.processIdentifier, isRunning: !application.isTerminated)))
                    }
                }
            }
        }, onCancel: {
            // Launch Services cannot recall a request already dispatched. Cancel waiting,
            // report that uncertainty, and ignore its later completion without retrying.
            Task { @MainActor in reply.finish(.failure(NativeActionError.cancelledHandoff)) }
        })
    }
}

@MainActor
private final class NativeWorkspaceReply {
    var continuation: CheckedContinuation<NativeApplicationObservation, Error>?
    var timeout: Task<Void, Never>?
    func finish(_ result: Result<NativeApplicationObservation, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

enum NativeActionError: Error, LocalizedError, Equatable {
    case invalidRequest, unsafePath, missingItem, alreadyExists, unsupportedText, limitReached
    case conflict, recoveryRequired(String), storageUnavailable, applicationUnavailable, workspaceRejected
    case unverifiedHandoff, cancelledHandoff, nothingToUndo, busy
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The action needs valid typed arguments."
        case .unsafePath: return "The path is not a safe relative path inside the selected document folder."
        case .missingItem: return "The requested item is missing."
        case .alreadyExists: return "The destination already exists; it was not replaced."
        case .unsupportedText: return "This action supports bounded UTF-8 text documents only."
        case .limitReached: return "The local action or recovery storage limit was reached; no new action was started."
        case .conflict: return "The document changed. Read its current version before editing or undoing it."
        case .recoveryRequired(let name): return "The document changed during the action. Preserved recovery data: .dot-actions/\(name). Review the files before continuing."
        case .storageUnavailable: return "The selected folder or private action history could not be accessed."
        case .applicationUnavailable: return "The requested installed application or default browser is unavailable."
        case .workspaceRejected: return "macOS did not complete the application request. No extra permission prompt was opened."
        case .unverifiedHandoff: return "macOS did not confirm the request in time. It may still complete; it was not retried."
        case .cancelledHandoff: return "Cancelled waiting for macOS. Its dispatched request may still complete; it was not retried."
        case .nothingToUndo: return "That action has no available undo, or has already been undone."
        case .busy: return "Another native action is still completing."
        }
    }
}

/// One capability-rooted owner, private dated receipts, and bounded recoverable file mutations.
/// Native descriptor-relative operations refuse symlinks; atomic exclusive rename never clobbers
/// a destination. Edits atomically swap a staged version with the old inode, preserving the old
/// bytes even when an uncoordinated external writer races the expected-content check.
actor NativeActionExecutor {
    static let maximumTextBytes = 1_048_576
    static let maximumReceipts = 500
    static let maximumRecoveryFiles = 20
    private static let maximumLedgerBytes = 2_097_152
    private let root: Int32
    private let state: Int32
    private let lock: Int32
    private let workspace: any NativeWorkspaceAccess
    private var history: [NativeActionReceipt]
    private var active = false
    private var historySaved = true

    init(documentRoot: URL, workspace: any NativeWorkspaceAccess = SystemNativeWorkspaceAccess()) throws {
        guard documentRoot.isFileURL else { throw NativeActionError.unsafePath }
        let canonical = documentRoot.standardizedFileURL.resolvingSymlinksInPath()
        let root = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw NativeActionError.storageUnavailable }
        var state: Int32 = -1, lock: Int32 = -1
        do {
            if mkdirat(root, ".dot-actions", 0o700) != 0 && errno != EEXIST { throw NativeActionError.storageUnavailable }
            state = openat(root, ".dot-actions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var info = stat()
            guard state >= 0, fstat(state, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw NativeActionError.storageUnavailable
            }
            lock = openat(state, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0, fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw NativeActionError.storageUnavailable
            }
            let previous = try Self.loadLedger(state: state)
            let history = previous.map { receipt -> NativeActionReceipt in
                guard receipt.status == .started else { return receipt }
                var interrupted = receipt
                interrupted.status = .failed; interrupted.finishedAt = Date()
                interrupted.detail = "The previous session ended before verification. The effect is unknown; inspect the target before a new request. This request will not run again automatically."
                return interrupted
            }
            if history != previous { try Self.writeLedger(history, state: state) }
            self.root = root; self.state = state; self.lock = lock; self.workspace = workspace; self.history = history
        } catch { if lock >= 0 { close(lock) }; if state >= 0 { close(state) }; close(root); throw error }
    }
    deinit { close(lock); close(state); close(root) }

    func receipts() -> [NativeActionReceipt] { history }

    func execute(_ request: NativeActionRequest) async -> NativeActionResult {
        // A repeated ID is a receipt lookup, never a second side effect after uncertain delivery.
        if let previous = history.first(where: { $0.id == request.id }) {
            return NativeActionResult(receipt: previous, text: nil, historySaved: historySaved)
        }
        var receipt = NativeActionReceipt(id: request.id, startedAt: Date(), finishedAt: nil,
            operation: Self.name(request.action), target: Self.target(request.action), status: .started,
            verification: .none, detail: "Started", sha256: nil, undo: nil, undoes: nil, cancellationRequested: false)
        var text: String?
        do {
            try Task.checkCancellation()
            guard !active else { throw NativeActionError.busy }
            guard history.count < Self.maximumReceipts else { throw NativeActionError.limitReached }
            history.append(receipt)
            do { try saveLedger() } catch { history.removeLast(); throw error }
            active = true
            defer { active = false }
            let output = try await perform(request.action, id: request.id)
            receipt.status = output.verification == .browserHandoff ? .handedOff : .succeeded
            receipt.verification = output.verification; receipt.detail = output.detail
            receipt.sha256 = output.sha256; receipt.undo = output.undo; receipt.undoes = output.undoes
            receipt.cancellationRequested = Task.isCancelled
            if Task.isCancelled { receipt.detail += " Cancellation arrived after this verified outcome." }
            text = output.text
        } catch NativeActionError.cancelledHandoff {
            receipt.status = .cancelled; receipt.detail = NativeActionError.cancelledHandoff.localizedDescription
            receipt.cancellationRequested = true
        } catch is CancellationError {
            receipt.status = .cancelled; receipt.detail = "Cancelled before the next side effect."; receipt.cancellationRequested = true
        } catch {
            receipt.status = .failed
            receipt.detail = (error as? NativeActionError)?.localizedDescription ?? "The native action could not be completed."
            receipt.cancellationRequested = Task.isCancelled
        }
        receipt.finishedAt = Date()
        if let index = history.firstIndex(where: { $0.id == request.id }) { history[index] = receipt }
        else if history.count < Self.maximumReceipts { history.append(receipt) }
        else { return NativeActionResult(receipt: receipt, text: text, historySaved: false) }
        do { try saveLedger(); return NativeActionResult(receipt: receipt, text: text, historySaved: true) }
        catch { return NativeActionResult(receipt: receipt, text: text, historySaved: false) }
    }

    private struct Output {
        let verification: NativeActionVerification
        let detail: String
        var text: String? = nil
        var sha256: String? = nil
        var undo: NativeActionUndo? = nil
        var undoes: UUID? = nil
    }
    private func perform(_ action: NativeAction, id: UUID) async throws -> Output {
        switch action {
        case .launchApplication(let bundleID):
            guard bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$", options: .regularExpression) != nil else {
                throw NativeActionError.invalidRequest
            }
            try Task.checkCancellation()
            let observation = try await workspace.launchApplication(bundleID: bundleID)
            guard observation.isRunning, observation.processID > 0, observation.bundleID == bundleID else {
                throw NativeActionError.unverifiedHandoff
            }
            return Output(verification: .runningApplication, detail: "Verified the requested application is running.")
        case .openWebURL(let value):
            let url = try Self.webURL(value)
            try Task.checkCancellation()
            let observation = try await workspace.openWebURL(url)
            guard observation.isRunning, observation.processID > 0, observation.bundleID?.isEmpty == false else {
                throw NativeActionError.unverifiedHandoff
            }
            return Output(verification: .browserHandoff, detail: "The default browser accepted the URL. Page loading and website actions are unverified.")
        case .readText(let path):
            let parent = try parent(of: path); defer { close(parent.fd) }
            // Only stable read snapshots retry, once. Mutations and app launches never retry blindly.
            let snapshot: Snapshot
            do { snapshot = try Self.read(parent.fd, parent.name) }
            catch NativeActionError.conflict { snapshot = try Self.read(parent.fd, parent.name) }
            return Output(verification: .textRead, detail: "Read and hashed the UTF-8 document.",
                          text: snapshot.text, sha256: snapshot.hash)
        case .createText(let path, let text):
            let bytes = try Self.textBytes(text), parent = try parent(of: path); defer { close(parent.fd) }
            let staging = try stage(bytes, id: id)
            defer { if !staging.retained { unlinkat(state, staging.name, 0) } }
            try Task.checkCancellation()
            try Self.rename(state, staging.name, parent.fd, parent.name, flags: UInt32(RENAME_EXCL))
            let created = try Self.read(parent.fd, parent.name, cancellable: false)
            guard created.hash == Self.hash(bytes), created.sameFile(as: staging.info) else { throw NativeActionError.conflict }
            return Output(verification: .contentHash, detail: "Created and reread the document; its content hash matches.", sha256: created.hash,
                undo: NativeActionUndo(kind: .createdText, path: path, originalPath: nil, expectedSHA256: created.hash,
                    originalSHA256: nil, backupName: nil, device: created.device, inode: created.inode))
        case .editText(let path, let expected, let text):
            try Self.validHash(expected)
            let bytes = try Self.textBytes(text), parent = try parent(of: path); defer { close(parent.fd) }
            let before = try Self.read(parent.fd, parent.name)
            guard before.hash == expected else { throw NativeActionError.conflict }
            let staging = try stage(bytes, id: id)
            defer { if !staging.retained { unlinkat(state, staging.name, 0) } }
            try Task.checkCancellation()
            let current = try Self.read(parent.fd, parent.name)
            guard current.hash == expected, current.sameFile(as: before.info) else { throw NativeActionError.conflict }
            try Self.rename(state, staging.name, parent.fd, parent.name, flags: UInt32(RENAME_SWAP)); staging.retained = true
            let after: Snapshot
            do {
                let saved = try Self.read(state, staging.name, cancellable: false)
                after = try Self.read(parent.fd, parent.name, cancellable: false)
                guard saved.hash == expected, saved.sameFile(as: before.info), after.hash == Self.hash(bytes), after.sameFile(as: staging.info) else {
                    throw NativeActionError.conflict
                }
            } catch { throw NativeActionError.recoveryRequired(staging.name) }
            return Output(verification: .contentHash, detail: "Verified the new content hash and preserved the previous version for undo.", sha256: after.hash,
                undo: NativeActionUndo(kind: .editedText, path: path, originalPath: nil, expectedSHA256: after.hash,
                    originalSHA256: before.hash, backupName: staging.name, device: after.device, inode: after.inode))
        case .moveDocument(let from, let to, let expected):
            try Self.validHash(expected)
            guard from != to else { throw NativeActionError.invalidRequest }
            let source = try parent(of: from); defer { close(source.fd) }
            let destination = try parent(of: to); defer { close(destination.fd) }
            let before = try Self.read(source.fd, source.name)
            guard before.hash == expected else { throw NativeActionError.conflict }
            try Task.checkCancellation()
            try Self.rename(source.fd, source.name, destination.fd, destination.name, flags: UInt32(RENAME_EXCL))
            let after = try Self.read(destination.fd, destination.name, cancellable: false)
            guard after.hash == expected, after.sameFile(as: before.info) else { throw NativeActionError.conflict }
            return Output(verification: .fileMoved, detail: "Moved the same document inode without replacing a destination; verified its hash.", sha256: after.hash,
                undo: NativeActionUndo(kind: .movedText, path: to, originalPath: from, expectedSHA256: after.hash,
                    originalSHA256: nil, backupName: nil, device: after.device, inode: after.inode))
        case .createFolder(let path):
            let parent = try parent(of: path); defer { close(parent.fd) }
            try Task.checkCancellation()
            guard mkdirat(parent.fd, parent.name, 0o700) == 0 else { throw Self.fileError() }
            let directory = openat(parent.fd, parent.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw NativeActionError.conflict }; defer { close(directory) }
            var info = stat(); guard fstat(directory, &info) == 0 else { throw NativeActionError.storageUnavailable }
            return Output(verification: .directoryCreated, detail: "Created and reopened the directory.",
                undo: NativeActionUndo(kind: .createdFolder, path: path, originalPath: nil, expectedSHA256: nil,
                    originalSHA256: nil, backupName: nil, device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
        case .undo(let receiptID): return try undo(receiptID: receiptID, actionID: id)
        }
    }

    private func undo(receiptID: UUID, actionID: UUID) throws -> Output {
        guard let original = history.first(where: { $0.id == receiptID && $0.status == .succeeded }), let undo = original.undo,
              !history.contains(where: { $0.undoes == receiptID && $0.status == .succeeded }) else { throw NativeActionError.nothingToUndo }
        let parent = try parent(of: undo.path); defer { close(parent.fd) }
        if undo.kind == .createdFolder {
            let directory = openat(parent.fd, parent.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw NativeActionError.conflict }; defer { close(directory) }
            var info = stat()
            guard fstat(directory, &info) == 0, UInt64(info.st_dev) == undo.device, UInt64(info.st_ino) == undo.inode else { throw NativeActionError.conflict }
            try Task.checkCancellation()
            // Native rmdir is atomic and refuses nonempty folders; never recursively remove data.
            guard unlinkat(parent.fd, parent.name, AT_REMOVEDIR) == 0 else { throw NativeActionError.conflict }
            return Output(verification: .undoVerified, detail: "Removed only the unchanged empty directory.", undoes: receiptID)
        }
        guard let expected = undo.expectedSHA256 else { throw NativeActionError.nothingToUndo }; try Self.validHash(expected)
        let current = try Self.read(parent.fd, parent.name)
        guard current.hash == expected, current.device == undo.device, current.inode == undo.inode else { throw NativeActionError.conflict }
        try Task.checkCancellation()
        switch undo.kind {
        case .editedText:
            guard let name = undo.backupName, Self.validBackupName(name), let originalHash = undo.originalSHA256 else { throw NativeActionError.nothingToUndo }
            try Self.validHash(originalHash)
            let backup = try Self.read(state, name)
            guard backup.hash == originalHash else { throw NativeActionError.conflict }
            try Self.rename(state, name, parent.fd, parent.name, flags: UInt32(RENAME_SWAP))
            let restored = try Self.read(parent.fd, parent.name, cancellable: false)
            let preserved = try Self.read(state, name, cancellable: false)
            guard restored.hash == originalHash, restored.sameFile(as: backup.info), preserved.hash == expected,
                  preserved.sameFile(as: current.info) else { throw NativeActionError.recoveryRequired(name) }
            return Output(verification: .undoVerified, detail: "Restored the previous content and retained the replaced version in recovery storage.",
                          sha256: restored.hash, undoes: receiptID)
        case .createdText:
            try recoveryCapacity()
            let name = actionID.uuidString + ".backup"
            try Self.rename(parent.fd, parent.name, state, name, flags: UInt32(RENAME_EXCL))
            let preserved = try Self.read(state, name, cancellable: false)
            guard preserved.hash == expected, preserved.sameFile(as: current.info) else { throw NativeActionError.recoveryRequired(name) }
            return Output(verification: .undoVerified, detail: "Removed the unchanged created document from its original location and preserved it in recovery storage.", undoes: receiptID)
        case .movedText:
            guard let path = undo.originalPath else { throw NativeActionError.nothingToUndo }
            let destination = try self.parent(of: path); defer { close(destination.fd) }
            try Self.rename(parent.fd, parent.name, destination.fd, destination.name, flags: UInt32(RENAME_EXCL))
            let restored = try Self.read(destination.fd, destination.name, cancellable: false)
            guard restored.hash == expected, restored.sameFile(as: current.info) else { throw NativeActionError.conflict }
            return Output(verification: .undoVerified, detail: "Returned the unchanged document to its original location without replacing another file.",
                          sha256: restored.hash, undoes: receiptID)
        case .createdFolder: throw NativeActionError.nothingToUndo
        }
    }

    private struct Parent { let fd: Int32; let name: String }
    private func parent(of path: String) throws -> Parent {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 1024, parts.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.caseInsensitiveCompare(".dot-actions") != .orderedSame && $0.utf8.count <= 255 }),
              path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && $0 != "\\" }) else { throw NativeActionError.unsafePath }
        var parent = dup(root)
        guard parent >= 0 else { throw NativeActionError.storageUnavailable }
        do {
            for part in parts.dropLast() {
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.fileError() }
                close(parent); parent = next
            }
            return Parent(fd: parent, name: parts.last!)
        } catch { close(parent); throw error }
    }
    private struct Snapshot {
        let data: Data
        let text: String
        let hash: String
        let info: stat
        var device: UInt64 { UInt64(info.st_dev) }
        var inode: UInt64 { UInt64(info.st_ino) }
        func sameFile(as other: stat) -> Bool { info.st_dev == other.st_dev && info.st_ino == other.st_ino }
    }
    private static func read(_ parent: Int32, _ name: String, cancellable: Bool = true) throws -> Snapshot {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw fileError() }; defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumTextBytes else { throw NativeActionError.unsupportedText }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if cancellable { try Task.checkCancellation() }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; throw NativeActionError.storageUnavailable }
            if count == 0 { break }
            guard data.count + count <= maximumTextBytes else { throw NativeActionError.unsupportedText }
            data.append(contentsOf: chunk.prefix(count))
        }
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw NativeActionError.conflict }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { throw NativeActionError.unsupportedText }
        return Snapshot(data: data, text: text, hash: hash(data), info: after)
    }
    private final class Staging {
        let name: String, info: stat
        var retained = false
        init(name: String, info: stat) { self.name = name; self.info = info }
    }
    private func stage(_ bytes: Data, id: UUID) throws -> Staging {
        try recoveryCapacity()
        let name = id.uuidString + ".backup"
        try Self.writeExclusive(bytes, parent: state, name: name)
        do {
            let file = try Self.read(state, name)
            return Staging(name: name, info: file.info)
        } catch { unlinkat(state, name, 0); throw error }
    }
    private func recoveryCapacity() throws {
        // A fresh file description is required: dup would share the readdir offset.
        let fd = openat(state, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0, let stream = fdopendir(fd) else { if fd >= 0 { close(fd) }; throw NativeActionError.storageUnavailable }
        defer { closedir(stream) }
        var count = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name.hasSuffix(".backup") { count += 1 }
            guard count < Self.maximumRecoveryFiles else { throw NativeActionError.limitReached }
        }
    }
    private static func textBytes(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= maximumTextBytes, !bytes.contains(0) else { throw NativeActionError.unsupportedText }
        return bytes
    }
    static func sha256(of text: String) -> String { hash(Data(text.utf8)) }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func validHash(_ hash: String) throws {
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw NativeActionError.invalidRequest }
    }
    private static func validBackupName(_ name: String) -> Bool {
        name.hasSuffix(".backup") && UUID(uuidString: String(name.dropLast(7))) != nil && name.count == 43
    }
    static func webURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8192, text.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }),
              let components = URLComponents(string: text), ["http", "https"].contains(components.scheme?.lowercased()),
              components.user == nil, components.password == nil, components.host?.isEmpty == false,
              let url = components.url else { throw NativeActionError.invalidRequest }
        return url
    }
    private static func rename(_ from: Int32, _ name: String, _ to: Int32, _ destination: String, flags: UInt32) throws {
        guard renameatx_np(from, name, to, destination, flags) == 0 else { throw fileError() }
    }
    private static func fileError() -> NativeActionError {
        switch errno { case EEXIST, ENOTEMPTY: return .alreadyExists; case ENOENT: return .missingItem
        case ELOOP, ENOTDIR: return .unsafePath; default: return .storageUnavailable }
    }
    private static func writeExclusive(_ data: Data, parent: Int32, name: String) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fileError() }; defer { close(fd) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw NativeActionError.storageUnavailable }
                    guard count > 0 else { throw NativeActionError.storageUnavailable }; offset += count
                }
            }
            guard fsync(fd) == 0 else { throw NativeActionError.storageUnavailable }
        } catch { unlinkat(parent, name, 0); throw error }
    }
    private static func loadLedger(state: Int32) throws -> [NativeActionReceipt] {
        let fd = openat(state, "receipts.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return [] }; throw NativeActionError.storageUnavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_size <= maximumLedgerBytes else { throw NativeActionError.storageUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            let bytes = try handle.read(upToCount: maximumLedgerBytes + 1) ?? Data()
            guard bytes.count <= maximumLedgerBytes else { throw NativeActionError.storageUnavailable }
            let records = try JSONDecoder().decode([NativeActionReceipt].self, from: bytes)
            guard records.count <= maximumReceipts, Set(records.map(\.id)).count == records.count else { throw NativeActionError.storageUnavailable }
            return records
        } catch { throw NativeActionError.storageUnavailable }
    }
    private func saveLedger() throws {
        do { try Self.writeLedger(history, state: state); historySaved = true }
        catch { historySaved = false; throw error }
    }
    private static func writeLedger(_ history: [NativeActionReceipt], state: Int32) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(history)
        guard bytes.count <= maximumLedgerBytes else { throw NativeActionError.limitReached }
        let name = UUID().uuidString + ".ledger"
        try writeExclusive(bytes, parent: state, name: name)
        defer { unlinkat(state, name, 0) }
        try rename(state, name, state, "receipts.json", flags: 0)
        guard fsync(state) == 0 else { throw NativeActionError.storageUnavailable }
    }
    private static func name(_ action: NativeAction) -> String {
        switch action { case .launchApplication: return "launchApplication"; case .openWebURL: return "openWebURL"
        case .readText: return "readText"; case .createText: return "createText"; case .editText: return "editText"
        case .moveDocument: return "moveDocument"; case .createFolder: return "createFolder"; case .undo: return "undo" }
    }
    private static func target(_ action: NativeAction) -> String {
        let value: String
        switch action {
        case .launchApplication(let id): value = id
        case .openWebURL(let text): value = (try? webURL(text).host) ?? "Invalid web URL"
        case .readText(let path), .createText(let path, _), .editText(let path, _, _), .createFolder(let path): value = path
        case .moveDocument(let from, let to, _): value = from + " → " + to
        case .undo(let id): value = id.uuidString
        }
        return String(value.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.prefix(1024))
    }
}
