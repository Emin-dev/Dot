import Foundation
import Combine
import OSLog

struct BundledModelIndex: Decodable {
    struct Asset: Decodable { let path: String; let bytes: Int64; let sha256: String }
    let schema_version: Int
    let total_bytes: Int64
    let files: [Asset]
}

/// Reads the signed application's own payload. When the public (model-less) app has
/// no bundled models, the exact manifest files are downloaded to Application Support
/// and verified against the signed hashes; no external folder or substitute is used.
@MainActor
final class OfflinePreparation: ObservableObject {
    static let shared = OfflinePreparation()
    private static let log = Logger(subsystem: "app.dot", category: "timing")
    @Published private(set) var state: CompanionReadiness = .checking
    @Published private(set) var progress = 0.0
    /// Visible cold-start detail ("Downloading model") so a 20 GB first launch is
    /// not misreported as a file check.
    @Published private(set) var detail: String?
    var ready: Bool { state == .ready }
    private(set) var root: URL?
    private let resources: URL?
    private let runtimeCheck: @Sendable () async throws -> URL
    private var work: Task<Void, Never>?
    private var resumeRequested = false
    private var generation = UUID()
    private var recognizerAvailable = false

    init(resources: URL? = Bundle.main.resourceURL,
         runtimeCheck: @escaping @Sendable () async throws -> URL = { try await OfflinePayload.shared.validate() }) {
        self.resources = resources; self.runtimeCheck = runtimeCheck
    }
    func start(nativeRecognizerAvailable: Bool? = nil) {
        if let nativeRecognizerAvailable { recognizerAvailable = nativeRecognizerAvailable }
        guard recognizerAvailable else {
            state = .unavailable("This app is missing its bundled speech recognizer. A complete build is required."); return
        }
        guard work == nil, !ready else { return }
        state = .checking; progress = 0; detail = nil
        let token = UUID(); generation = token
        let began = ProcessInfo.processInfo.systemUptime
        Self.log.notice("DOT_PREPARATION stage=payload event=started")
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                let milliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                let outcome = self.ready ? "ready" : Task.isCancelled ? "cancelled" : "failed"
                Self.log.notice("DOT_PREPARATION stage=payload event=ended outcome=\(outcome, privacy: .public) elapsed=\(milliseconds)ms")
                self.work = nil
                if self.resumeRequested { self.resumeRequested = false; self.start() }
            }
            do {
                let folder = try await PayloadVerification.run(runtime: self.runtimeCheck, models: {
                    try await self.verifyModels(token: token)
                })
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.root = folder; self.progress = 1; self.detail = nil; self.state = .ready
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.detail = nil
                self.state = .unavailable((error as? PreparationFailure ?? .integrity).localizedDescription)
            }
        }
    }
    private func verifyModels(token: UUID) async throws -> URL {
        try Task.checkCancellation()
        guard let resources = resources else { throw PreparationFailure.models }
        let manifest = resources.appendingPathComponent("bundled-models.json")
        let values = try manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (1...1_000_000).contains(values.fileSize ?? 0) else { throw PreparationFailure.integrity }
        let plan = try JSONDecoder().decode(BundledModelIndex.self, from: Data(contentsOf: manifest))
        guard plan.schema_version == 1, (1...100).contains(plan.files.count),
              plan.files.allSatisfy({ (1...25_000_000_000).contains($0.bytes) && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              plan.total_bytes == plan.files.reduce(0, { $0 + $1.bytes }), plan.total_bytes <= 25_000_000_000,
              Set(plan.files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == plan.files.count else { throw PreparationFailure.integrity }
        let bundled = resources.appendingPathComponent("OfflineModels", isDirectory: true)
        let bundledValues = try? bundled.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let useBundled = bundledValues?.isDirectory == true && bundledValues?.isSymbolicLink != true
        let folder: URL
        if useBundled {
            guard bundled.resolvingSymlinksInPath().deletingLastPathComponent().path == resources.resolvingSymlinksInPath().path else {
                throw PreparationFailure.models
            }
            folder = bundled
        } else {
            // A public app ships without the 19.9 GB model. Fetch the exact manifest
            // files from Hugging Face into Application Support; every file is verified
            // against the signed manifest before it is used.
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw PreparationFailure.models
            }
            folder = support.appendingPathComponent("Dot", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
            detail = "Downloading model"
            do {
                try await ModelProvisioner.shared.ensureModels(at: folder, plan: plan) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.progress = 0.05 + 0.90 * fraction
                    }
                }
            } catch {
                detail = nil
                throw error
            }
            detail = nil
        }
        let closure = Task.detached(priority: .utility) { try Self.verifyClosure(folder, names: Set(plan.files.map(\.path))) }
        try await withTaskCancellationHandler(operation: { try await closure.value }, onCancel: { closure.cancel() })
        var completed: Int64 = 0
        // A downloaded model has already been verified file-by-file; the final pass
        // still re-hashes it, but its progress must continue from 90%, not jump back.
        let progressBase = useBundled ? 0.0 : 0.90
        let progressSpan = useBundled ? 0.95 : 0.05
        for asset in plan.files {
            try Task.checkCancellation()
            let path = try OfflinePayload.safePath(asset.path, root: folder)
            do {
                try await OfflinePayload.verifyHash(path, bytes: asset.bytes, expected: asset.sha256)
            } catch {
                if !useBundled {
                    // A downloaded file with a correct size but a bad hash is
                    // discarded so the menu's Retry can fetch it again.
                    try? FileManager.default.removeItem(at: path)
                    throw PreparationFailure.download("A downloaded model file failed verification. Retry the download.")
                }
                throw error
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            completed += asset.bytes
            progress = progressBase + progressSpan * Double(completed) / Double(plan.total_bytes)
        }
        try Task.checkCancellation()
        return folder
    }
    nonisolated private static func verifyClosure(_ folder: URL, names: Set<String>) throws {
        // macOS may enumerate /var paths as /private/var. Use one canonical root
        // for both traversal and relative names; reject links before resolving entries.
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonical.path + "/"
        guard let items = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw PreparationFailure.integrity }
        var actual = Set<String>(), nodes = 0
        for case let item as URL in items {
            try Task.checkCancellation(); nodes += 1
            guard nodes <= 1000 else { throw PreparationFailure.integrity }
            let properties = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw PreparationFailure.integrity }
            if properties.isDirectory != true {
                let path = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(prefix) else { throw PreparationFailure.integrity }
                actual.insert(String(path.dropFirst(prefix.count)))
                guard actual.count <= 100 else { throw PreparationFailure.integrity }
            }
        }
        guard actual == names else { throw PreparationFailure.integrity }
    }
    func pause() {
        resumeRequested = false
        guard state == .checking else { return }
         generation = UUID(); state = .paused; work?.cancel()
    }
    func retry() {
        guard !ready else { return }
        if work != nil { resumeRequested = true }
        else { start() }
    }
    func shutdown() { resumeRequested = false; generation = UUID(); work?.cancel() }
}

enum PreparationFailure: LocalizedError {
    case runtime, models, integrity
    case download(String)
    var errorDescription: String? {
        switch self {
        case .runtime: return "The bundled voice runtime is missing or damaged. A complete build is required."
        case .models: return "The local model is missing and could not be prepared."
        case .integrity: return "Bundled files could not be verified. This app needs a repaired complete build."
        case .download(let reason): return "Downloading the local model failed: \(reason). Check your connection and free disk space, then retry from the menu."
        }
    }
}

/// Downloads the exact signed-manifest model files from their public Hugging Face
/// repositories. Byte identity is preserved by verifying each file's SHA-256 against
/// `bundled-models.json`; no substitute model is ever accepted.
actor ModelProvisioner {
    static let shared = ModelProvisioner()
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 86_400
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    static func remoteURL(for path: String) throws -> URL {
        let prefix: String
        let base: String
        if path.hasPrefix("llm-target/") {
            prefix = "llm-target/"; base = "https://huggingface.co/mlx-community/Qwen3.8-27B-4bit/resolve/main/"
        } else if path.hasPrefix("llm-draft/") {
            prefix = "llm-draft/"; base = "https://huggingface.co/incoai/Qwen3.8-27B-DFlash2/resolve/main/"
        } else {
            throw PreparationFailure.download("Unknown model path '\(path)'.")
        }
        let rest = String(path.dropFirst(prefix.count))
        guard let encoded = rest.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + encoded) else {
            throw PreparationFailure.download("Invalid model path '\(path)'.")
        }
        return url
    }

    func ensureModels(at folder: URL, plan: BundledModelIndex,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var completed: Int64 = 0
        for asset in plan.files {
            try Task.checkCancellation()
            let destination = try OfflinePayload.safePath(asset.path, root: folder)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) == asset.bytes {
                completed += asset.bytes
                progress(Double(completed) / Double(plan.total_bytes))
                continue
            }
            try? FileManager.default.removeItem(at: destination)
            let remote = try Self.remoteURL(for: asset.path)
            let base = completed
            let reporter = ModelDownloadProgress { written, _ in
                progress(Double(base + min(written, asset.bytes)) / Double(plan.total_bytes))
            }
            let (temporary, response) = try await session.download(from: remote, delegate: reporter)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PreparationFailure.download("The model server returned an unexpected response.")
            }
            let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) == asset.bytes else {
                throw PreparationFailure.download("'\(asset.path)' was incomplete.")
            }
            try await OfflinePayload.verifyHash(temporary, bytes: asset.bytes, expected: asset.sha256)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: destination)
            completed += asset.bytes
            progress(Double(completed) / Double(plan.total_bytes))
        }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    init(_ onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    // The async `download(from:delegate:)` owns the temporary file; observing the
    // finish is required by the protocol but no move happens here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

/// Exactly two full verification streams. Any failure cancels and drains the sibling.
/// This never trusts a metadata cache or starts an inference process.
enum PayloadVerification {
    private enum Part: Sendable { case runtime, models(URL) }
    private static let log = Logger(subsystem: "app.dot", category: "timing")
    static func run(runtime: @escaping @Sendable () async throws -> URL,
                    models: @escaping @Sendable () async throws -> URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Part.self) { group in
            group.addTask {
                let began = ProcessInfo.processInfo.systemUptime
                log.notice("DOT_PREPARATION stage=runtime event=started")
                var verified = false
                defer {
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                    let outcome = verified ? "ready" : Task.isCancelled ? "cancelled" : "failed"
                    log.notice("DOT_PREPARATION stage=runtime event=ended outcome=\(outcome, privacy: .public) elapsed=\(milliseconds)ms")
                }
                do { _ = try await runtime() }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); throw PreparationFailure.runtime }
                try Task.checkCancellation()
                verified = true
                return .runtime
            }
            group.addTask {
                let began = ProcessInfo.processInfo.systemUptime
                log.notice("DOT_PREPARATION stage=models event=started")
                var verified = false
                defer {
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                    let outcome = verified ? "ready" : Task.isCancelled ? "cancelled" : "failed"
                    log.notice("DOT_PREPARATION stage=models event=ended outcome=\(outcome, privacy: .public) elapsed=\(milliseconds)ms")
                }
                let root = try await models()
                try Task.checkCancellation()
                verified = true
                return .models(root)
            }
            var root: URL?
            while let part = try await group.next() {
                if case .models(let value) = part { root = value }
            }
            try Task.checkCancellation()
            guard let root else { throw PreparationFailure.models }
            return root
        }
    }
}
