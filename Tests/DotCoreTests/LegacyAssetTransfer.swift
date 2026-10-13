#if !SWIFT_PACKAGE
// Retained regression harness for removed network provisioning; never linked into Dot.app.
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


#endif
