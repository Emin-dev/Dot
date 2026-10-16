import CryptoKit
import Foundation

enum SourceReferenceError: LocalizedError, Equatable {
    case missingProvenance, invalidProvenance, unpublishedSource, invalidPath, unexpectedResponse
    case httpStatus(Int), tooLarge, invalidText, busy

    var errorDescription: String? {
        switch self {
        case .missingProvenance: return "This build has no bundled source revision."
        case .invalidProvenance: return "This build's source revision is invalid."
        case .unpublishedSource: return "This development build contains unpublished source changes, so its exact source is not available at a GitHub revision."
        case .invalidPath: return "Choose a relative source file in Emin-dev/Dot."
        case .unexpectedResponse: return "The source server returned an unexpected response."
        case .httpStatus(let status): return "Source retrieval failed (HTTP \(status))."
        case .tooLarge: return "This source file exceeds the 256 KiB text limit."
        case .invalidText: return "This source file is not UTF-8 text."
        case .busy: return "Source retrieval is already busy. Try again shortly."
        }
    }
}

struct SourceProvenance: Equatable, Sendable {
    let commit: String

    init(commit: String) throws {
        guard commit.utf8.count == 40,
              commit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw SourceReferenceError.invalidProvenance }
        self.commit = commit.lowercased()
    }

    init(data: Data) throws {
        struct Record: Decodable { let commit: String; let source_dirty: Bool? }
        guard data.count <= 16_384,
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { throw SourceReferenceError.invalidProvenance }
        guard record.source_dirty != true else { throw SourceReferenceError.unpublishedSource }
        try self.init(commit: record.commit)
    }

    static func load(bundle: Bundle = .main) throws -> SourceProvenance {
        guard let url = bundle.url(forResource: "build-provenance", withExtension: "json")
        else { throw SourceReferenceError.missingProvenance }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try SourceProvenance(data: handle.read(upToCount: 16_385) ?? Data())
    }

    func sourceURL(path: String) throws -> URL {
        try url(base: "https://raw.githubusercontent.com/Emin-dev/Dot/", path: path)
    }

    func citationURL(path: String) throws -> URL {
        try url(base: "https://github.com/Emin-dev/Dot/blob/", path: path)
    }

    private func url(base: String, path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 512,
              path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }),
              let url = URL(string: base + commit + "/" + path)
        else { throw SourceReferenceError.invalidPath }
        return url
    }
}

/// Untrusted public source text with an immutable citation and a local integrity receipt.
/// The hash records the received bytes; it is not an independent authenticity claim.
struct SourceReference: Equatable, Sendable {
    let commit: String
    let path: String
    let text: String
    let citationURL: URL
    let contentSHA256: String
    let fetchedAt: Date

    var citation: String { "[\(path) @ \(commit.prefix(12))](\(citationURL.absoluteString))" }
}

/// Reads only the fixed public repository at the bundled commit. No execution,
/// credentials, cookies, persistent cache or fallback to a moving branch.
actor SourceReferenceStore {
    static let maximumFileBytes = 256 * 1_024
    static let maximumCacheBytes = 1_024 * 1_024
    static let maximumCacheEntries = 8

    let provenance: SourceProvenance
    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date
    private var cache: [String: SourceReference] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private var activeReads = 0

    init(provenance: SourceProvenance, configuration: URLSessionConfiguration = .ephemeral,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provenance = provenance
        let safe = configuration.copy() as! URLSessionConfiguration
        safe.urlCredentialStorage = nil
        safe.httpCookieStorage = nil
        safe.httpShouldSetCookies = false
        safe.urlCache = nil
        safe.requestCachePolicy = .reloadIgnoringLocalCacheData
        safe.httpAdditionalHeaders = nil
        safe.timeoutIntervalForRequest = 15
        safe.timeoutIntervalForResource = 30
        safe.waitsForConnectivity = false
        self.configuration = safe
        self.now = now
    }

    func read(path: String) async throws -> SourceReference {
        try Task.checkCancellation()
        let url = try provenance.sourceURL(path: path)
        if let cached = cache[path] { return cached }
        guard activeReads < 2 else { throw SourceReferenceError.busy }
        activeReads += 1
        defer { activeReads -= 1 }

        let session = URLSession(configuration: configuration, delegate: SourceReferenceSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url
        else { throw SourceReferenceError.unexpectedResponse }
        guard response.statusCode == 200 else { throw SourceReferenceError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= Int64(Self.maximumFileBytes)
        else { throw SourceReferenceError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumFileBytes else { throw SourceReferenceError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0")
        else { throw SourceReferenceError.invalidText }
        let reference = SourceReference(commit: provenance.commit, path: path, text: text,
                                        citationURL: try provenance.citationURL(path: path),
                                        contentSHA256: data.sha256Hex,
                                        fetchedAt: now())
        cacheReference(reference, bytes: data.count)
        return reference
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }

    private func cacheReference(_ reference: SourceReference, bytes: Int) {
        if let existing = cache.removeValue(forKey: reference.path) {
            cacheBytes -= existing.text.utf8.count
            cacheOrder.removeAll { $0 == reference.path }
        }
        while !cacheOrder.isEmpty && (cacheOrder.count >= Self.maximumCacheEntries || cacheBytes + bytes > Self.maximumCacheBytes) {
            let oldest = cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.text.utf8.count }
        }
        cache[reference.path] = reference
        cacheOrder.append(reference.path)
        cacheBytes += bytes
    }
}

final class SourceReferenceSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TLS retains normal system verification. HTTP/proxy authentication never uses credentials.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
