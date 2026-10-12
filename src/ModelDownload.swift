import Foundation
import Combine

struct ModelDownloadPlan: Decodable {
    struct Asset: Decodable { let path: String; let url: URL; let bytes: Int64; let sha256: String }
    let schema_version: Int
    let total_bytes: Int64
    let files: [Asset]
}

/// One HTTPS request and bounded file sink. Delegates run on a serial utility queue.
final class AssetTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let asset: ModelDownloadPlan.Asset
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let protocolClasses: [AnyClass]?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var lastProgress = 0.0
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()
    private var cancelled = false
    init(asset: ModelDownloadPlan.Asset, destination: URL, protocolClasses: [AnyClass]? = nil, progress: @escaping @Sendable (Int64) -> Void) {
        self.asset = asset; self.destination = destination; self.progress = progress; self.protocolClasses = protocolClasses
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if cancelled { continuation.resume(throwing: OfflineFailure.paused); return }
            self.continuation = continuation
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw OfflineFailure.download }
                }
                guard !(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else { throw OfflineFailure.corrupt }
                let handle = try FileHandle(forWritingTo: destination)
                received = Int64(try handle.seekToEnd()); requestedOffset = received
                guard received <= asset.bytes else { try? handle.close(); throw OfflineFailure.corrupt }
                file = handle
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = protocolClasses
                configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 7200
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
                session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: asset.url); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                task = session?.dataTask(with: request); task?.resume()
            } catch { self.continuation = nil; continuation.resume(throwing: error) }
        }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
        completionHandler(request.url?.scheme == "https" && allowed ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            if response.statusCode == 200 {
                try file?.truncate(atOffset: 0); try file?.seek(toOffset: 0); received = 0
            } else if response.statusCode == 206 {
                guard response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(requestedOffset)-") == true else { throw OfflineFailure.download }
            } else { throw OfflineFailure.download }
            guard response.expectedContentLength <= asset.bytes - received else { throw OfflineFailure.corrupt }
            completionHandler(.allow)
        } catch { completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard Int64(data.count) <= asset.bytes - received else { throw OfflineFailure.corrupt }
            try file?.write(contentsOf: data); received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress > 0.2 { lastProgress = now; progress(received) }
        } catch { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close(); file = nil
        lock.lock(); let completion = continuation; continuation = nil; let paused = cancelled; self.task = nil; lock.unlock()
        defer { session.finishTasksAndInvalidate(); self.session = nil }
        if paused { completion?.resume(throwing: OfflineFailure.paused); return }
        if error != nil { completion?.resume(throwing: OfflineFailure.download); return }
        do { try OfflinePayload.hash(destination, bytes: asset.bytes, expected: asset.sha256); progress(asset.bytes); completion?.resume(returning: destination) }
        catch { completion?.resume(throwing: error) }
    }
}

@MainActor
final class ModelDownload: ObservableObject {
    static let shared = ModelDownload()
    @Published private(set) var progress = 0.0
    @Published private(set) var message = "Checking local files…"
    @Published private(set) var ready = false
    @Published private(set) var paused = false
    private var work: Task<Void, Never>?
    private var transfer: AssetTransfer?
    private var generation = UUID()
    private var resumeRequested = false
    private var nativeRecognizerAvailable = false
    private(set) var root: URL?
    func start(nativeRecognizerAvailable: Bool? = nil) {
        if let nativeRecognizerAvailable { self.nativeRecognizerAvailable = nativeRecognizerAvailable }
        guard self.nativeRecognizerAvailable else { message = OfflineFailure.incomplete.localizedDescription; paused = true; return }
        guard work == nil, !ready else { return }; paused = false
        let token = UUID(); generation = token
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.work = nil; self.transfer = nil
                if self.resumeRequested { self.resumeRequested = false; self.start() }
            }
            do {
                _ = try await OfflinePayload.shared.validate()
                guard !Task.isCancelled else { return }
                guard let url = Bundle.main.url(forResource: "model-downloads", withExtension: "json") else { throw OfflineFailure.incomplete }
                let plan = try JSONDecoder().decode(ModelDownloadPlan.self, from: Data(contentsOf: url))
                guard plan.schema_version == 1, (1...100).contains(plan.files.count),
                      plan.files.allSatisfy({ (1...25_000_000_000).contains($0.bytes) && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && $0.url.scheme == "https" && $0.url.host == "huggingface.co" }),
                      plan.total_bytes == plan.files.reduce(0, { $0 + $1.bytes }), plan.total_bytes <= 25_000_000_000,
                      Set(plan.files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == plan.files.count else { throw OfflineFailure.corrupt }
                let bundled = Bundle.main.resourceURL!.appendingPathComponent("OfflineModels", isDirectory: true)
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dot/Models", isDirectory: true)
                let folder = FileManager.default.fileExists(atPath: bundled.path) ? bundled : support
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                root = folder
                var completed: Int64 = 0
                for asset in plan.files {
                    try Task.checkCancellation()
                    let final = try OfflinePayload.safePath(asset.path, root: folder)
                    if FileManager.default.fileExists(atPath: final.path) {
                        message = "Checking downloaded model…"
                        do { try await OfflinePayload.verifyHash(final, bytes: asset.bytes, expected: asset.sha256) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            guard folder != bundled else { throw OfflineFailure.corrupt }
                            try FileManager.default.removeItem(at: final)
                        }
                    }
                    try Task.checkCancellation()
                    if !FileManager.default.fileExists(atPath: final.path) {
                        guard folder != bundled else { throw OfflineFailure.corrupt }
                        let before = completed
                        message = "Downloading my local model…"
                        let partialURL = final.appendingPathExtension("partial")
                        if (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == asset.bytes {
                            do {
                                try await OfflinePayload.verifyHash(partialURL, bytes: asset.bytes, expected: asset.sha256)
                                try Task.checkCancellation(); try FileManager.default.moveItem(at: partialURL, to: final)
                                completed += asset.bytes; progress = Double(completed) / Double(plan.total_bytes); continue
                            } catch is CancellationError { throw CancellationError() }
                            catch { try FileManager.default.removeItem(at: partialURL) }
                        }
                        if let size = try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) > asset.bytes {
                            try FileManager.default.removeItem(at: partialURL)
                        }
                        // Credit bounded on-disk partials and later existing files. Hash checks still gate each final file.
                        let stored = try plan.files.reduce(Int64(0)) { sum, item in
                            let path = try OfflinePayload.safePath(item.path, root: folder)
                            let finalBytes = Int64((try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            let partialBytes = Int64((try? path.appendingPathExtension("partial").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            return sum + min(item.bytes, max(finalBytes, partialBytes))
                        }
                        let free = (try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                        guard free >= DownloadBudget.requiredFree(total: plan.total_bytes, reusableBytes: stored) else { throw OfflineFailure.space }
                        let download = AssetTransfer(asset: asset, destination: partialURL) { [weak self] bytes in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.progress = Double(before + bytes) / Double(plan.total_bytes)
                            }
                        }
                        transfer = download
                        let partial = try await download.start(); try Task.checkCancellation()
                        try FileManager.default.moveItem(at: partial, to: final); transfer = nil
                    }
                    completed += asset.bytes; progress = Double(completed) / Double(plan.total_bytes)
                }
                try Task.checkCancellation()
                ready = true; message = "Ready for offline conversation"; progress = 1
            } catch {
                if !Task.isCancelled { self.message = error.localizedDescription; self.paused = true }
            }
        }
    }
    func pause() { resumeRequested = false; generation = UUID(); paused = true; message = "Download paused"; transfer?.cancel(); work?.cancel() }
    func resume() {
        if work != nil { resumeRequested = true; paused = false; message = "Resuming download…" }
        else { start() }
    }
    func shutdown() { pause() }
}
