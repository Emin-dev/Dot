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
        // Primary route: pinned split parts on the Emin-dev/Dot release. The
        // bundled plan is `pending` until the owner uploads the parts, so the
        // Hugging Face fallback stays active meanwhile. Both routes verify the
        // same signed manifest hash; a part plan that disagrees is ignored.
        let partsManifest = resources.appendingPathComponent("model-parts.json")
        let decodedParts = (try? Data(contentsOf: partsManifest)).flatMap(ModelPartPlan.decode)
        let parts = decodedParts?.validate(files: plan.files.map { ($0.path, $0.bytes) }) == true ? decodedParts : nil
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
            // Refuse before downloading when the volume cannot hold the model plus
            // the 5 GB working margin; files already present at the exact size are
            // reusable and need no new space.
            var reusable: Int64 = 0
            for asset in plan.files {
                guard let path = try? OfflinePayload.safePath(asset.path, root: folder),
                      let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(size) == asset.bytes else { continue }
                reusable += asset.bytes
            }
            let staging = parts?.parts.map(\.bytes).max() ?? 0
            let requiredFree = DownloadBudget.requiredFree(total: plan.total_bytes, reusableBytes: reusable) + staging
            var volume = folder
            while !FileManager.default.fileExists(atPath: volume.path) { volume = volume.deletingLastPathComponent() }
            if let free = (try? FileManager.default.attributesOfFileSystem(forPath: volume.path))?[.systemFreeSize] as? Int64,
               free < requiredFree {
                throw PreparationFailure.download("Not enough free disk space: the model needs \(ByteCountFormatter.string(fromByteCount: requiredFree, countStyle: .file)), but only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is available.")
            }
            detail = parts == nil ? "Downloading model" : "Downloading model parts"
            do {
                try await ModelProvisioner.shared.ensureModels(at: folder, plan: plan, parts: parts) { [weak self] fraction in
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
        // Re-verify every launch. A file with the right size but a bad hash is
        // removed and fetched once more automatically; only a second failure is
        // reported, so a crash during a previous download repairs itself.
        var repaired = false
        while true {
            let closure = Task.detached(priority: .utility) { try Self.verifyClosure(folder, names: Set(plan.files.map(\.path))) }
            try await withTaskCancellationHandler(operation: { try await closure.value }, onCancel: { closure.cancel() })
            var failed: [BundledModelIndex.Asset] = []
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if useBundled { throw error }
                    failed.append(asset)
                    try? FileManager.default.removeItem(at: path)
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                completed += asset.bytes
                progress = progressBase + progressSpan * Double(completed) / Double(plan.total_bytes)
            }
            guard !failed.isEmpty else { break }
            guard !repaired else {
                throw PreparationFailure.download("A downloaded model file still failed verification after an automatic repair. Retry the download.")
            }
            repaired = true
            detail = "Repairing model"
            do {
                try await ModelProvisioner.shared.ensureModels(at: folder, plan: plan, parts: parts) { [weak self] fraction in
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
        if work != nil {
            // Stop an in-flight transfer now (the part downloader forwards task
            // cancellation to URLSession) and start a fresh attempt when it exits.
            resumeRequested = true
            generation = UUID()
            work?.cancel()
        } else {
            start()
        }
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

    /// Pinned revisions from `packaging/initial-download-plan.json`. The
    /// Hugging Face route is a fallback, never a floating "latest" substitute:
    /// every file must still match the SHA-256 in the signed manifest.
    static let targetRevision = "10c35caafbb80f7dc6a7a432cdd11af10a6d4818"
    static let draftRevision = "015e795645c74b1a0eeef3b570031fb62e769bc5"
    static let auxRevision = "d0976223747697cb51e056d85c532013931fe52e"

    static func remoteURL(for path: String) throws -> URL {
        let prefix: String
        let base: String
        if path.hasPrefix("llm-target/") {
            prefix = "llm-target/"
            base = "https://huggingface.co/mlx-community/Qwen3.8-27B-4bit/resolve/\(targetRevision)/"
        } else if path.hasPrefix("llm-draft/") {
            prefix = "llm-draft/"
            base = "https://huggingface.co/incoai/Qwen3.8-27B-DFlash2/resolve/\(draftRevision)/"
        } else if path.hasPrefix("aux/") {
            prefix = "aux/"
            base = "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/\(auxRevision)/"
        } else {
            throw PreparationFailure.download("Unknown model path '\(path)'.")
        }
        let rest = String(path.dropFirst(prefix.count))
        guard !rest.isEmpty, !rest.contains(".."), !rest.hasPrefix("/"),
              let encoded = rest.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + encoded) else {
            throw PreparationFailure.download("Invalid model path '\(path)'.")
        }
        return url
    }

    func ensureModels(at folder: URL, plan: BundledModelIndex, parts: ModelPartPlan? = nil,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var completed: Int64 = 0
        let total = Double(plan.total_bytes)
        for asset in plan.files {
            try Task.checkCancellation()
            let destination = try OfflinePayload.safePath(asset.path, root: folder)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) == asset.bytes {
                completed += asset.bytes
                progress(Double(completed) / total)
                continue
            }
            try? FileManager.default.removeItem(at: destination)
            let base = completed
            let report: @Sendable (Int64) -> Void = { written in
                progress(Double(base + min(written, asset.bytes)) / total)
            }
            let grouped = parts?.parts(for: asset.path) ?? []
            if !grouped.isEmpty {
                do {
                    try await downloadParts(grouped, for: asset, into: destination,
                                            folder: folder, plan: parts!, report: report)
                    completed += asset.bytes
                    progress(Double(completed) / total)
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Primary route failed after its own retries: fall through to
                    // the pinned Hugging Face file. The same signed hash is the
                    // only thing either route is allowed to satisfy.
                }
            }
            try await downloadWholeFile(asset, to: destination, report: report)
            completed += asset.bytes
            progress(Double(completed) / total)
        }
        if parts != nil {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(".parts", isDirectory: true))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(".staging", isDirectory: true))
        }
    }

    private func downloadWholeFile(_ asset: BundledModelIndex.Asset, to destination: URL,
                                   report: @escaping @Sendable (Int64) -> Void) async throws {
        let remote = try Self.remoteURL(for: asset.path)
        let reporter = ModelDownloadProgress { written, _ in report(written) }
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(from: remote, delegate: reporter)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw PreparationFailure.download("The download of '\(asset.path)' was interrupted (\(error.code)).")
        }
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
    }

    /// Download the pinned parts, verify each one, then join and verify the
    /// whole file against the signed manifest. Partial part files survive
    /// interruptions and resume with an HTTP Range request.
    private func downloadParts(_ grouped: [ModelPartPlan.Part], for asset: BundledModelIndex.Asset,
                               into destination: URL, folder: URL, plan: ModelPartPlan,
                               report: @escaping @Sendable (Int64) -> Void) async throws {
        guard let base = plan.baseURL else {
            throw PreparationFailure.download("The model part plan has no usable release URL.")
        }
        let partsDirectory = folder.appendingPathComponent(".parts", isDirectory: true)
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var partURLs: [URL] = []
        for part in grouped {
            try Task.checkCancellation()
            guard let url = URL(string: part.asset, relativeTo: base)?.absoluteURL else {
                throw PreparationFailure.download("Invalid model part name '\(part.asset)'.")
            }
            let local = partsDirectory.appendingPathComponent(part.asset)
            let offset = part.offset
            let reporter: @Sendable (Int64) -> Void = { written in
                report(offset + min(written, part.bytes))
            }
            try await downloadResumable(url, to: local, expected: part.bytes,
                                        expectedHash: part.sha256, report: reporter)
            partURLs.append(local)
        }
        let stagingDirectory = folder.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let staging = stagingDirectory.appendingPathComponent(destination.lastPathComponent + ".join")
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw PreparationFailure.download("Could not create the model staging file.")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = try FileHandle(forWritingTo: staging)
        do {
            for (index, part) in grouped.enumerated() {
                try Task.checkCancellation()
                let input = try FileHandle(forReadingFrom: partURLs[index])
                defer { try? input.close() }
                var copied: Int64 = 0
                while let data = try input.read(upToCount: 8 * 1_024 * 1_024), !data.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: data)
                    copied += Int64(data.count)
                }
                guard copied == part.bytes else {
                    throw PreparationFailure.download("Joined model part '\(part.asset)' has the wrong size.")
                }
            }
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try output.close()
        try await OfflinePayload.verifyHash(staging, bytes: asset.bytes, expected: asset.sha256)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        for url in partURLs { try? FileManager.default.removeItem(at: url) }
    }

    /// Resume a single part. GitHub release assets support Range; a server that
    /// ignores the range restarts the part instead of corrupting it.
    private func downloadResumable(_ url: URL, to destination: URL, expected: Int64,
                                   expectedHash: String,
                                   report: @escaping @Sendable (Int64) -> Void) async throws {
        let partial = destination.appendingPathExtension("partial")
        var hashesTried = 0
        while true {
            var attempt = 0
            while true {
                attempt += 1
                do {
                    try await transfer(url, to: partial, expected: expected, report: report)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let http as PartHTTPFailure {
                    if http.status == 408 || http.status == 429 || http.status >= 500 {
                        if attempt >= 5 { throw PreparationFailure.download("A model part download failed after \(attempt) attempts.") }
                        let seconds = min(30, 1 << (attempt - 1))
                        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                    } else {
                        throw PreparationFailure.download("The model part server returned HTTP \(http.status).")
                    }
                } catch {
                    if attempt >= 5 {
                        throw PreparationFailure.download("A model part download failed after \(attempt) attempts.")
                    }
                    let seconds = min(30, 1 << (attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
            }
            let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) == expected else {
                try? FileManager.default.removeItem(at: partial)
                throw PreparationFailure.download("A model part was incomplete.")
            }
            do {
                try await OfflinePayload.verifyHash(partial, bytes: expected, expected: expectedHash)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: partial)
                hashesTried += 1
                guard hashesTried < 2 else {
                    throw PreparationFailure.download("A model part failed SHA-256 verification twice.")
                }
            }
        }
    }

    private func transfer(_ url: URL, to destination: URL, expected: Int64,
                          report: @escaping @Sendable (Int64) -> Void) async throws {
        let resumeURL = destination.appendingPathExtension("resumedata")
        let resumeData = try? Data(contentsOf: resumeURL)
        var existing = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if resumeData == nil {
            if existing == expected { report(expected); return }
            if existing > expected { try? FileManager.default.removeItem(at: destination); existing = 0 }
        }
        var request = URLRequest(url: url)
        if resumeData == nil, existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let progressOffset = resumeData == nil ? existing : 0
        let (temporary, response) = try await downloadPartFile(request, resumeData: resumeData,
                                                               progressOffset: progressOffset,
                                                               resumeURL: resumeURL, report: report)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response, (http.statusCode == 200 || http.statusCode == 206) else {
            throw PartHTTPFailure(status: response?.statusCode ?? 0)
        }
        let append = resumeData == nil && existing > 0 && http.statusCode == 206
        if append {
            let handle = try FileHandle(forWritingTo: destination)
            let input = try FileHandle(forReadingFrom: temporary)
            do {
                _ = try handle.seekToEnd()
                while let data = try input.read(upToCount: 8 * 1_024 * 1_024), !data.isEmpty {
                    try handle.write(contentsOf: data)
                }
                try handle.close(); try input.close()
            } catch {
                try? handle.close(); try? input.close()
                throw error
            }
        } else {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try? FileManager.default.removeItem(at: resumeURL)
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size == expected else {
            try? FileManager.default.removeItem(at: destination)
            throw PreparationFailure.download("A model part was incomplete.")
        }
        report(expected)
    }

    private func downloadPartFile(_ request: URLRequest, resumeData: Data?, progressOffset: Int64,
                                  resumeURL: URL,
                                  report: @escaping @Sendable (Int64) -> Void) async throws -> (URL, HTTPURLResponse?) {
        let cancellation = PartDownloadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let receiver = PartDownloadReceiver(resumeURL: resumeURL, progressOffset: progressOffset, report: report)
                let partSession = URLSession(configuration: session.configuration, delegate: receiver,
                                             delegateQueue: nil)
                receiver.session = partSession
                receiver.completion = { result in
                    partSession.finishTasksAndInvalidate()
                    continuation.resume(with: result)
                }
                let task = resumeData.map { partSession.downloadTask(withResumeData: $0) }
                    ?? partSession.downloadTask(with: request)
                receiver.task = task
                cancellation.attach(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// Connects Swift task cancellation to the URLSession task. `pause`, `retry` and
/// `shutdown` cancel the preparation task; without this the transfer would keep
/// waiting on the network (up to the 24 h resource timeout) and the actor would
/// never leave `ensureModels`.
private final class PartDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Persists a downloaded part and any URLSession resume data, so a dropped
/// connection continues from the bytes already received instead of restarting.
private final class PartDownloadReceiver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let resumeURL: URL
    private let progressOffset: Int64
    private let report: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var location: URL?
    private var response: HTTPURLResponse?
    private var completed = false
    var session: URLSession?
    var task: URLSessionDownloadTask?
    var completion: ((Result<(URL, HTTPURLResponse?), Error>) -> Void)?

    init(resumeURL: URL, progressOffset: Int64, report: @escaping @Sendable (Int64) -> Void) {
        self.resumeURL = resumeURL
        self.progressOffset = progressOffset
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        report(progressOffset + totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let held = location.appendingPathExtension("dot-part-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: held)
            lock.lock(); self.location = held; lock.unlock()
        } catch {
            lock.lock(); self.location = nil; lock.unlock()
        }
        lock.lock(); response = downloadTask.response as? HTTPURLResponse; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let location = self.location
        let response = self.response
        lock.unlock()
        if let error {
            let ns = error as NSError
            if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: resumeURL)
            }
            if let location { try? FileManager.default.removeItem(at: location) }
            completion?(.failure(error))
            return
        }
        guard let location else {
            completion?(.failure(URLError(.badServerResponse)))
            return
        }
        completion?(.success((location, response)))
    }
}

private struct PartHTTPFailure: Error { let status: Int }

private final class ModelPartProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let offset: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void
    init(offset: Int64, _ onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.offset = offset
        self.onProgress = onProgress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(offset + totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
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
