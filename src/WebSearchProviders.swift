import Foundation
#if os(macOS)
import Darwin
#endif

enum WebSearchResultRetention: Sendable {
    case notConfirmed
    /// The caller has checked the selected account/plan's applicable retention terms.
    /// API access alone, or another provider's terms, cannot establish this flag.
    case permittedBySelectedPlan
}

enum WebSearchCharge: Equatable, Sendable {
    case tavilyBasicCredits(Int)
    case perplexityMicroUSD(Int)
}

protocol WebSearchBudgetAuthorizing: Sendable {
    /// Atomically reserve and durably commit BEFORE returning. The caller owns the
    /// account/window quota, including other sessions and restart recovery. Throw
    /// when exhausted/unavailable. Never refund uncertain, cancelled or failed
    /// attempts automatically; adapters do not retry or maintain a second ledger.
    func reserve(_ charge: WebSearchCharge) async throws
}

enum WebSearchProviderError: Error, Equatable, LocalizedError {
    case invalidConfiguration, freeOnlyAccountNotConfirmed, invalidQuery, budgetUnavailable, busy
    case httpStatus(Int), responseTooLarge, invalidResponse, unexpectedUsage, networkFailure
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Search needs an explicitly configured credential and plan."
        case .freeOnlyAccountNotConfirmed: return "Tavily needs a confirmed free-only account with available free credits and paid overage disabled."
        case .invalidQuery: return "Provide a nonempty search query within the supported limits."
        case .budgetUnavailable: return "Search could not reserve its configured local budget. No request was started."
        case .busy: return "This search provider already has a request in progress."
        case .httpStatus(let status): return "The search provider returned HTTP \(status)."
        case .responseTooLarge: return "The search response exceeded its bounded size."
        case .invalidResponse: return "The search provider returned an unsupported response."
        case .unexpectedUsage: return "Search stopped because the provider reported unexpected credit usage. Check the account before continuing."
        case .networkFailure: return "The search request could not finish. Its reserved budget was retained."
        }
    }
}

/// Retrieval-only API, verified against:
/// https://docs.tavily.com/documentation/api-reference/endpoint/search
/// https://docs.tavily.com/documentation/api-credits
/// Basic is one credit. No automatic depth, answer generation, or raw-content call.
final class TavilyBasicSearchProvider: WebSearchProvider, Sendable {
    let providerID = "tavily-basic"
    let permitsResultPersistence: Bool
    private let client: RawWebSearchClient
    init(apiKey: String, budget: any WebSearchBudgetAuthorizing, retention: WebSearchResultRetention,
         freeOnlyAccountConfirmed: Bool, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard freeOnlyAccountConfirmed else { throw WebSearchProviderError.freeOnlyAccountNotConfirmed }
        // This is caller-supplied setup evidence, not a remote account check. Local
        // credit allowance cannot itself disable PAYG or detect other account use.
        permitsResultPersistence = retention == .permittedBySelectedPlan
        client = try RawWebSearchClient(provider: .tavily, apiKey: apiKey, budget: budget, configuration: configuration)
    }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        try await client.search(query: query, limit: limit)
    }
}

/// Raw POST /search only, never Sonar, Agent API, chat completions or a provider LLM.
/// https://docs.perplexity.ai/api-reference/search-post
/// https://docs.perplexity.ai/docs/getting-started/pricing
/// Standard web Search was $5/1,000 requests when checked 2026-10-13. Setup must
/// verify current pricing before enabling usage; no paid allowance is implicit.
final class PerplexityRawSearchProvider: WebSearchProvider, Sendable {
    let providerID = "perplexity-search-web"
    let permitsResultPersistence: Bool
    private let client: RawWebSearchClient
    init(apiKey: String, budget: any WebSearchBudgetAuthorizing, retention: WebSearchResultRetention,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        permitsResultPersistence = retention == .permittedBySelectedPlan
        client = try RawWebSearchClient(provider: .perplexity, apiKey: apiKey, budget: budget, configuration: configuration)
    }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        try await client.search(query: query, limit: limit)
    }
}

private enum RawSearchAPI: Sendable {
    case tavily, perplexity
    var endpoint: URL {
        URL(string: self == .tavily ? "https://api.tavily.com/search" : "https://api.perplexity.ai/search")!
    }
    var charge: WebSearchCharge { self == .tavily ? .tavilyBasicCredits(1) : .perplexityMicroUSD(5_000) }
}

private actor RawWebSearchClient {
    private let provider: RawSearchAPI
    private let apiKey: String
    private let budget: any WebSearchBudgetAuthorizing
    private let configuration: URLSessionConfiguration
    private var busy = false
    private var usageMismatch = false
    static let maxResponseBytes = 1_048_576

    init(provider: RawSearchAPI, apiKey: String, budget: any WebSearchBudgetAuthorizing,
         configuration: URLSessionConfiguration) throws {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 4_096,
              apiKey.utf8.allSatisfy({ (33...126).contains($0) }) else { throw WebSearchProviderError.invalidConfiguration }
        self.provider = provider; self.apiKey = apiKey; self.budget = budget
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2_048, (1...8).contains(limit) else { throw WebSearchProviderError.invalidQuery }
        guard !usageMismatch else { throw WebSearchProviderError.unexpectedUsage }
        guard !busy else { throw WebSearchProviderError.busy }
        busy = true; defer { busy = false }
        var payload: [String: Any] = ["query": query, "max_results": limit]
        if provider == .tavily {
            payload.merge(["search_depth": "basic", "topic": "general", "auto_parameters": false,
                           "include_answer": false, "include_raw_content": false, "include_images": false,
                           "include_image_descriptions": false, "include_favicon": false,
                           "include_usage": true, "include_published_date": true, "chunks_per_source": 3]) { _, new in new }
        } else {
            payload.merge(["search_type": "web", "max_tokens": 8_000, "max_tokens_per_page": 1_000]) { _, new in new }
        }
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        do { try await budget.reserve(provider.charge) }
        catch is CancellationError { throw CancellationError() }
        catch { throw WebSearchProviderError.budgetUnavailable }
        try Task.checkCancellation()
        let config = Self.isolated(configuration)
        let policy = RawSearchNetworkPolicy()
        let session = URLSession(configuration: config, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url == provider.endpoint else {
                throw WebSearchProviderError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else { throw WebSearchProviderError.httpStatus(response.statusCode) }
            guard response.mimeType?.lowercased() == "application/json" else { throw WebSearchProviderError.invalidResponse }
            guard response.expectedContentLength <= Self.maxResponseBytes else { throw WebSearchProviderError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
                guard data.count < Self.maxResponseBytes else { throw WebSearchProviderError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            let result: [WebSearchResult]
            if provider == .tavily {
                let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
                guard decoded.usage.credits == 1 else { usageMismatch = true; throw WebSearchProviderError.unexpectedUsage }
                result = try Self.normalize(decoded.results.map { ($0.url, $0.title, $0.content, $0.published_date) }, limit: limit)
            } else {
                let decoded = try JSONDecoder().decode(PerplexityResponse.self, from: data)
                result = try Self.normalize(decoded.results.map { ($0.url, $0.title, $0.snippet, $0.date) }, limit: limit)
            }
            try Task.checkCancellation()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as WebSearchProviderError { throw error }
        catch is DecodingError { throw WebSearchProviderError.invalidResponse }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Never surface response bodies, URLSession diagnostics, queries or keys.
            throw WebSearchProviderError.networkFailure
        }
    }

    private static func isolated(_ original: URLSessionConfiguration) -> URLSessionConfiguration {
        let config = original.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    private static func normalize(_ items: [(String, String, String, String?)], limit: Int) throws -> [WebSearchResult] {
        guard items.count <= 20 else { throw WebSearchProviderError.invalidResponse }
        var seen = Set<String>(), results: [WebSearchResult] = []
        for (address, title, snippet, date) in items {
            try Task.checkCancellation()
            guard let url = URL(string: address), ResearchWebReader.allowed(url) else { continue }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.fragment = nil
            guard let canonical = parts?.url, seen.insert(canonical.absoluteString).inserted else { continue }
            let title = prefixUTF8(title.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 2_048)
            guard !title.isEmpty else { throw WebSearchProviderError.invalidResponse }
            // Snippets are provider discovery hints, not page-read receipts or
            // verified evidence. Original pages must pass ResearchWebReader.
            results.append(WebSearchResult(url: canonical, title: title, snippet: prefixUTF8(snippet, bytes: 8_192),
                                           publicationDateHint: date.flatMap(dateHint)))
            if results.count == limit { break }
        }
        return results
    }
    private static func prefixUTF8(_ value: String, bytes: Int) -> String {
        var result = "", used = 0
        for character in value { let count = String(character).utf8.count; if used + count > bytes { break }; result.append(character); used += count }
        return result
    }
    private static func dateHint(_ value: String) -> Date? {
        guard value.utf8.count <= 128 else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        for format in ["yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// Fixed HTTPS destinations and normal system TLS validation. No cross-origin or
/// same-origin redirects; no HTTP/proxy/client-certificate credential challenges.
final class RawSearchNetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
}

private struct TavilyResponse: Decodable {
    struct Usage: Decodable { let credits: Int }
    struct Result: Decodable { let url: String; let title: String; let content: String; let published_date: String? }
    let results: [Result]
    let usage: Usage
}
private struct PerplexityResponse: Decodable {
    struct Result: Decodable { let url: String; let title: String; let snippet: String; let date: String? }
    let results: [Result]
}

/// Free, keyless local web search through the bundled native `dot-search` runtime.
///
/// This provider never reads the open web itself. It launches the Rust runtime that
/// ships beside the app executable (`Contents/MacOS/dot-search`, the same convention
/// `BionicVoice` uses for `dot-voice`), writes exactly one bounded start command to
/// the child's stdin, and speaks only that runtime's loopback protocol: the `ready`
/// line carries the ephemeral port and the 64-hex-character capability that every
/// `POST /search` must present in `X-Dot-Search-Capability`. DuckDuckGo HTML results
/// with a Wikipedia fallback are produced inside the runtime; this side bounds,
/// validates and normalizes what comes back, and no child outlives its search.
/// A bounded on-disk cache for keyless search results. A fresh hit is returned
/// without launching the runtime; stale/corrupt entries are ignored. Best-effort
/// persistence: a cache failure never fails a search.
actor SearchResultCache {
    struct Entry: Codable {
        let results: [WebSearchResult]
        let coverage: WebSearchCoverage
        let unavailableEngineIDs: [String]
        let storedAt: Date
    }
    static let shared = SearchResultCache()
    private let fileURL: URL?
    private let ttl: TimeInterval
    private let maximumEntries: Int
    private var entries: [String: Entry] = [:]
    private var loaded = false

    init(fileURL: URL? = nil, ttl: TimeInterval = 6 * 3600, maximumEntries: Int = 50,
         inMemory: Bool = false) {
        self.ttl = ttl
        self.maximumEntries = max(1, maximumEntries)
        if inMemory { self.fileURL = nil }
        else if let fileURL { self.fileURL = fileURL }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            self.fileURL = support?.appendingPathComponent("Dot", isDirectory: true)
                .appendingPathComponent("SearchCache.json")
        }
    }

    func lookup(query: String, limit: Int, now: Date = Date()) -> WebSearchResponse? {
        loadIfNeeded()
        guard let entry = entries[key(query: query, limit: limit)] else { return nil }
        // Only a complete response serves the full TTL; a partial entry is revalidated
        // against the live runtime so a recovered engine is never misreported, and
        // unavailable engine IDs are never reused across cache hits.
        guard entry.coverage == .complete, now.timeIntervalSince(entry.storedAt) <= ttl else { return nil }
        return WebSearchResponse(results: entry.results, coverage: entry.coverage,
                                 unavailableEngineIDs: [])
    }

    func store(query: String, limit: Int, response: WebSearchResponse, now: Date = Date()) {
        // Partial responses carry unavailable engines; never persist them for reuse.
        guard response.coverage == .complete else { return }
        loadIfNeeded()
        entries[key(query: query, limit: limit)] = Entry(results: response.results,
            coverage: response.coverage, unavailableEngineIDs: response.unavailableEngineIDs, storedAt: now)
        while entries.count > maximumEntries,
              let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        save()
    }

    private func key(query: String, limit: Int) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + String(limit)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(entries) else { return }
        guard (try? data.write(to: fileURL, options: [.atomic])) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

final class LocalDotSearchProvider: WebSearchProvider, Sendable {
    static let maximumQueryBytes = 2_048
    static let maximumResponseBytes = 1_048_576
    /// The engines the shipped runtime is reviewed to query with keyless access.
    /// The shipped runtime queries google-news on every search, so it stays in the
    /// reviewed set even when only some searches surface news results.
    static let reviewedEngineIDs: Set<String> = ["duckduckgo", "wikipedia", "google-news", "arxiv"]
    let providerID = "local-dot-search"
    let permitsResultPersistence = true
    let isKeyless = true
    private let runner: LocalDotSearchRunner
    private let cache: SearchResultCache

    /// `configuration` is retained so existing call sites keep compiling unchanged.
    /// The loopback transport is now a direct socket to the bundled runtime, which
    /// inherits no URLSession cache, cookie, credential or proxy state at all, so no
    /// `URLSessionConfiguration` applies to this path any more. `executableURL` is the
    /// launch seam used by tests and canaries.
    init(configuration: URLSessionConfiguration = .ephemeral, executableURL: URL? = nil,
         cache: SearchResultCache = .shared) {
        _ = configuration
        runner = LocalDotSearchRunner(executable: executableURL)
        self.cache = cache
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        try await searchResponse(query: query, limit: limit).results
    }

    func searchResponse(query: String, limit: Int) async throws -> WebSearchResponse {
        try Task.checkCancellation()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumQueryBytes,
              !trimmed.contains("\u{0}"), (1...8).contains(limit) else { throw SearchRuntimeFailure.invalidQuery }
        let now = Date()
        if let cached = await cache.lookup(query: trimmed, limit: limit, now: now) {
            return cached
        }
        let response = try await runner.search(query: trimmed, limit: limit)
        if permitsResultPersistence {
            await cache.store(query: trimmed, limit: limit, response: response, now: Date())
        }
        return response
    }

    /// The app and its runtime are one bundle: the binary is a sibling of the app
    /// executable. A missing runtime is an honest setup failure and never a reason
    /// to search some other way.
    static func bundledExecutable() throws -> URL {
        guard let sibling = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("dot-search"),
              FileManager.default.isExecutableFile(atPath: sibling.path) else {
            throw SearchRuntimeFailure.runtimeMissing
        }
        return sibling
    }
}

/// Every search owns its own runtime process and its own ephemeral loopback port, so
/// concurrent research queries cannot share, disturb or inherit each other's
/// capability.
private actor LocalDotSearchRunner {
    private let executable: URL?

    init(executable: URL?) { self.executable = executable }

    func search(query: String, limit: Int) async throws -> WebSearchResponse {
        try Task.checkCancellation()
        let executableURL: URL
        if let executable { executableURL = executable }
        else { executableURL = try LocalDotSearchProvider.bundledExecutable() }
        let child = DotSearchChildProcess(executable: executableURL)
        return try await withTaskCancellationHandler(operation: {
            do {
                let receipt = try await child.start()
                let response = try await DotSearchLoopbackClient.perform(receipt: receipt, query: query,
                                                                         limit: limit, isRevoked: { child.isRevoked })
                await child.stop()
                return response
            } catch {
                await child.stop()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let safe = error as? SearchRuntimeFailure { throw safe }
                throw SearchRuntimeFailure.startupFailed
            }
        }, onCancel: {
            // Synchronous and lock-protected: revocation never waits for this actor.
            child.terminate()
        })
    }
}

/// One launch of the bundled runtime for one bounded search. The child inherits only
/// the two pipes it needs and a minimal environment, receives exactly one start
/// command, and is closed with stdin EOF when its search settles; a child that does
/// not exit in time is terminated and then killed, so no runtime is left behind.
private final class DotSearchChildProcess: @unchecked Sendable {
    static let readyLineBytes = 4_096
    static let startupSeconds: TimeInterval = 10
    static let exitGraceSeconds: TimeInterval = 2
    private static let readerQueue = DispatchQueue(label: "app.dot.search-runtime", qos: .userInitiated)

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let executable: URL
    private let generation = UUID()
    private let lock = NSLock()
    private var terminated = false

    init(executable: URL) {
        self.executable = executable
        process.executableURL = executable
        process.arguments = []
        // A minimal environment keeps ambient proxy variables and credentials out of
        // the runtime; only this app's own bundle ever starts it this way.
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    /// Launch, hand over the one start command, and accept only that runtime's own
    /// `ready` receipt for this process and this generation.
    func start() async throws -> SearchReadyReceipt {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SearchRuntimeFailure.runtimeMissing
        }
        #if os(macOS)
        // A runtime that closes stdin first must surface EPIPE instead of killing
        // this process with SIGPIPE during the single bounded command write.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw SearchRuntimeFailure.startupFailed
        }
        #endif
        do { try process.run() } catch { throw SearchRuntimeFailure.startupFailed }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let ownedPID = process.processIdentifier
        let expected = generation
        // The runtime's protocol accepts exactly this one ASCII JSON command line;
        // `generation` is echoed back and nothing else is sent.
        let command = "{\"protocol\":1,\"command\":\"start\",\"generation\":\"\(generation.uuidString)\"}\n"
        return try await withCheckedThrowingContinuation { continuation in
            Self.readerQueue.async { [self] in
                do {
                    writeCommand(Data(command.utf8))
                    let line = try Self.readLine(descriptor: descriptor, limit: Self.readyLineBytes,
                                                 seconds: Self.startupSeconds, isRevoked: { self.isRevoked })
                    guard case .ready(let receipt) = try SearchControlEvent.decode(line, generation: expected,
                                                                                  ownedPID: ownedPID) else {
                        throw SearchRuntimeFailure.startupFailed
                    }
                    continuation.resume(returning: receipt)
                } catch {
                    if let safe = error as? SearchRuntimeFailure { continuation.resume(throwing: safe) }
                    else { continuation.resume(throwing: SearchRuntimeFailure.startupFailed) }
                }
            }
        }
    }

    /// Bounded, deadlined read of one control line. The runtime's stdout is the only
    /// input, but a broken or replaced binary must not be able to grow the buffer,
    /// block its search forever, or starve the cooperative pool. A revoked search
    /// stops within one poll interval instead of waiting out the whole deadline.
    private static func readLine(descriptor: Int32, limit: Int, seconds: TimeInterval,
                                 isRevoked: () -> Bool) throws -> Data {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            guard !isRevoked() else { throw SearchRuntimeFailure.stopped }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw SearchRuntimeFailure.startupTimeout }
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(clamping: remaining.components.seconds * 1_000
                                     + remaining.components.attoseconds / 1_000_000_000_000_000)
            let ready = poll(&state, 1, max(1, min(milliseconds, 500)))
            if ready < 0 { if errno == EINTR { continue }; throw SearchRuntimeFailure.startupFailed }
            if ready == 0 { continue }
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw SearchRuntimeFailure.startupFailed }
            // EOF before a complete line means this launch can never become ready.
            guard count > 0 else { throw SearchRuntimeFailure.startupFailed }
            for byte in chunk.prefix(count) {
                if byte == 10 { return line }
                guard line.count < limit else { throw SearchRuntimeFailure.startupFailed }
                line.append(byte)
            }
        }
    }

    /// Lock-protected revocation flag, read by the bounded readers and by the single
    /// command write so all of them stop promptly without locking in async context.
    var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return terminated }

    /// The one command write, serialized with the close in `stop()` so no descriptor
    /// is ever closed under an in-flight write.
    private func writeCommand(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !terminated else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Stdin EOF is the runtime's own stop signal. Synchronous so no lock is taken in
    /// an asynchronous context, and serialized with `writeCommand`.
    private func closeInput() {
        lock.lock(); defer { lock.unlock() }
        terminated = true
        try? input.fileHandleForWriting.close()
    }

    /// Revocation path for a cancelled search. It only signals the process it owns:
    /// the pending bounded write, read or loopback request then settles on its own.
    func terminate() {
        lock.lock()
        let pid = process.isRunning ? process.processIdentifier : -1
        terminated = true
        lock.unlock()
        if pid > 0 { kill(pid, SIGTERM) }
    }

    /// Normal settlement: stdin EOF is the runtime's own stop signal, then a bounded
    /// wait, then SIGTERM, then SIGKILL. Called once per search after `start()`
    /// settles, so it never races the single command write.
    func stop() async {
        closeInput()
        for _ in 0..<10 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(Self.exitGraceSeconds * 100))
        }
        let pid = process.isRunning ? process.processIdentifier : -1
        if pid > 0 { kill(pid, SIGTERM) }
        for _ in 0..<10 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning, pid > 0 { kill(pid, SIGKILL) }
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }
}

/// The only client of the runtime's loopback endpoint. It speaks minimal HTTP/1.1 on
/// a direct socket so that the request head and its form body are written in ONE
/// call: the shipped runtime parses each request with a single read, and a client
/// that writes the two separately leaves it with no query at all (HTTP 400). Nothing
/// here follows a redirect, consults a proxy, or inherits a URLSession cache, cookie
/// or header, and both the request and the response are bounded.
private enum DotSearchLoopbackClient {
    static let connectSeconds: TimeInterval = 5
    static let responseSeconds: TimeInterval = 15
    private static let queue = DispatchQueue(label: "app.dot.search-loopback", qos: .userInitiated)

    /// Runs the blocking socket exchange off the cooperative pool. Revocation is
    /// polled, and a terminated runtime also closes the socket, so cancellation
    /// settles within one poll interval.
    static func perform(receipt: SearchReadyReceipt, query: String, limit: Int,
                        isRevoked: @escaping @Sendable () -> Bool) async throws -> WebSearchResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try blocking(receipt: receipt, query: query, limit: limit,
                                                                isRevoked: isRevoked))
                } catch {
                    if let safe = error as? SearchRuntimeFailure { continuation.resume(throwing: safe) }
                    else { continuation.resume(throwing: SearchRuntimeFailure.networkFailure) }
                }
            }
        }
    }

    private static func blocking(receipt: SearchReadyReceipt, query: String, limit: Int,
                                 isRevoked: () -> Bool) throws -> WebSearchResponse {
        let body = form([("q", query)])
        let head = "POST /search HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(receipt.port)\r\n"
            + "Content-Type: application/x-www-form-urlencoded; charset=utf-8\r\n"
            + "Accept: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "X-Dot-Search-Capability: \(receipt.capability)\r\n"
            + "Connection: close\r\n\r\n"
        var request = Data(head.utf8)
        request.append(body)
        let descriptor = try connect(port: receipt.port, isRevoked: isRevoked)
        defer { close(descriptor) }
        try write(request, to: descriptor, isRevoked: isRevoked)
        return try decode(try read(from: descriptor, isRevoked: isRevoked), limit: limit)
    }

    private static func connect(port: Int, isRevoked: () -> Bool) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SearchRuntimeFailure.networkFailure }
        #if os(macOS)
        var on: Int32 = 1
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0,
              setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(descriptor); throw SearchRuntimeFailure.networkFailure
        }
        #endif
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            close(descriptor); throw SearchRuntimeFailure.networkFailure
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS,
                  try wait(descriptor, events: Int16(POLLOUT), seconds: connectSeconds, isRevoked: isRevoked) else {
                close(descriptor); throw SearchRuntimeFailure.networkFailure
            }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                close(descriptor); throw SearchRuntimeFailure.networkFailure
            }
        }
        return descriptor
    }

    private static func write(_ data: Data, to descriptor: Int32, isRevoked: () -> Bool) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                // One call carries the whole request: the runtime reads the head and
                // body together, and a split write would leave it without a query.
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard try wait(descriptor, events: Int16(POLLOUT), seconds: responseSeconds,
                                   isRevoked: isRevoked) else { throw SearchRuntimeFailure.timeout }
                    continue
                }
                throw SearchRuntimeFailure.networkFailure
            }
        }
    }

    private static func read(from descriptor: Int32, isRevoked: () -> Bool) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = ContinuousClock.now.advanced(by: .seconds(responseSeconds))
        while true {
            guard !isRevoked() else { throw SearchRuntimeFailure.stopped }
            if let framing = try framing(bytes), bytes.count - framing.head >= framing.contentLength { return bytes }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw SearchRuntimeFailure.timeout }
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(clamping: remaining.components.seconds * 1_000
                                     + remaining.components.attoseconds / 1_000_000_000_000_000)
            let ready = poll(&state, 1, max(1, min(milliseconds, 250)))
            if ready < 0 { if errno == EINTR { continue }; throw SearchRuntimeFailure.networkFailure }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw SearchRuntimeFailure.networkFailure }
            guard count > 0 else {
                // EOF is only a complete response when it carries a full declared body.
                if let framing = try framing(bytes), bytes.count - framing.head >= framing.contentLength { return bytes }
                throw SearchRuntimeFailure.malformedResponse
            }
            guard bytes.count + count <= LocalDotSearchProvider.maximumResponseBytes + 16_384 else {
                throw SearchRuntimeFailure.responseTooLarge
            }
            bytes.append(contentsOf: buffer[0..<count])
        }
    }

    /// The response's own framing: where the head ends and how long its declared body
    /// is. The runtime always sends `Content-Length` and closes; a chunked or
    /// length-less response is refused rather than guessed at.
    private static func framing(_ bytes: [UInt8]) throws -> (head: Int, contentLength: Int)? {
        guard let head = headerEnd(bytes) else {
            guard bytes.count <= 16_384 else { throw SearchRuntimeFailure.malformedResponse }
            return nil
        }
        let lines = String(decoding: bytes[0..<(head - 4)], as: UTF8.self).components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            guard line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                continue
            }
            guard let value = Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)), value >= 0 else {
                throw SearchRuntimeFailure.malformedResponse
            }
            guard value <= LocalDotSearchProvider.maximumResponseBytes else {
                throw SearchRuntimeFailure.responseTooLarge
            }
            return (head, value)
        }
        throw SearchRuntimeFailure.malformedResponse
    }

    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index + 4
        }
        return nil
    }

    private static func decode(_ bytes: [UInt8], limit: Int) throws -> WebSearchResponse {
        guard let framing = try framing(bytes), bytes.count >= framing.head + framing.contentLength else {
            throw SearchRuntimeFailure.malformedResponse
        }
        let lines = String(decoding: bytes[0..<(framing.head - 4)], as: UTF8.self).components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
            throw SearchRuntimeFailure.malformedResponse
        }
        if code == 403 { throw SearchRuntimeFailure.forbidden }
        guard (200...299).contains(code) else { throw SearchRuntimeFailure.httpStatus(code) }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard fields[name] == nil else { throw SearchRuntimeFailure.malformedResponse }
            fields[name] = value
        }
        let mime = fields["content-type"]?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard mime == "application/json" else {
            throw mime == "text/html" ? SearchRuntimeFailure.challenge : .malformedResponse
        }
        let body = Data(bytes[framing.head..<(framing.head + framing.contentLength)])
        return try normalize(body, limit: limit)
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        func encode(_ value: String) -> String {
            var result = ""
            for byte in value.utf8 {
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || [UInt8(45), 46, 95, 126].contains(byte) { result.append(Character(UnicodeScalar(byte))) }
                else if byte == 32 { result.append("+") }
                else { result += String(format: "%%%02X", byte) }
            }
            return result
        }
        return Data(fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }

    /// The runtime reports its results and any engine warnings; nothing else in the
    /// envelope is trusted. Provider snippets stay discovery hints: original pages
    /// must still pass `ResearchWebReader`.
    private static func normalize(_ data: Data, limit: Int) throws -> WebSearchResponse {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw SearchRuntimeFailure.malformedResponse }
        guard let envelope = object as? [String: Any], envelope["error"] == nil, envelope["errors"] == nil,
              let items = envelope["results"] as? [Any], items.count <= 512,
              let warnings = envelope["unresponsive_engines"] as? [Any], warnings.count <= 64 else {
            throw SearchRuntimeFailure.malformedResponse
        }
        let allowed = LocalDotSearchProvider.reviewedEngineIDs
        var unavailable = Set<String>()
        var partial = false
        for entry in warnings {
            // Reasons are translated, untrusted prose. Validate their shape, discard
            // their contents, and retain only reviewed engine IDs.
            guard let pair = entry as? [Any], pair.count == 2, let engine = pair[0] as? String,
                  engine.utf8.count <= 100, let reason = pair[1] as? String, reason.utf8.count <= 8_192 else {
                throw SearchRuntimeFailure.malformedResponse
            }
            partial = true
            if allowed.contains(engine) { unavailable.insert(engine) }
        }
        if !unavailable.isEmpty, unavailable == allowed { throw SearchRuntimeFailure.unavailable }
        var seen = Set<String>(), results: [WebSearchResult] = []
        for value in items {
            try Task.checkCancellation()
            guard let item = value as? [String: Any],
                  let address = item["url"] as? String, let titleValue = item["title"] as? String,
                  let url = URL(string: address), ResearchWebReader.allowed(url),
                  item["content"] == nil || item["content"] is NSNull || item["content"] is String else { continue }
            let published = item["published_date"] ?? item["publishedDate"]
            guard published == nil || published is NSNull || published is String,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            let host = parts.host?.lowercased(), scheme = parts.scheme?.lowercased()
            parts.fragment = nil; parts.host = host; parts.scheme = scheme
            if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
            guard let canonical = parts.url else { continue }
            let title = prefixUTF8(titleValue.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 2_048)
            guard !title.isEmpty, seen.insert(canonical.absoluteString).inserted else { continue }
            results.append(WebSearchResult(url: canonical, title: title,
                snippet: prefixUTF8(item["content"] as? String ?? "", maximumBytes: 8_192),
                publicationDateHint: (published as? String).flatMap(dateHint)))
            if results.count == limit { break }
        }
        guard items.isEmpty || !results.isEmpty else { throw SearchRuntimeFailure.invalidResults }
        return WebSearchResponse(results: results, coverage: partial ? .partial : .complete,
                                 unavailableEngineIDs: unavailable.sorted())
    }

    private static func prefixUTF8(_ value: String, maximumBytes: Int) -> String {
        var result = "", used = 0
        for character in value {
            let count = String(character).utf8.count
            if used + count > maximumBytes { break }
            result.append(character); used += count
        }
        return result
    }

    private static func dateHint(_ value: String) -> Date? {
        guard value.utf8.count <= 128 else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// One poll slice, bounded so revocation and deadlines are both observed promptly.
    private static func wait(_ descriptor: Int32, events: Int16, seconds: TimeInterval,
                             isRevoked: () -> Bool) throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            guard !isRevoked() else { throw SearchRuntimeFailure.stopped }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            var state = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(clamping: remaining.components.seconds * 1_000
                                     + remaining.components.attoseconds / 1_000_000_000_000_000)
            let ready = poll(&state, 1, max(1, min(milliseconds, 250)))
            if ready < 0 { if errno == EINTR { continue }; throw SearchRuntimeFailure.networkFailure }
            guard ready > 0 else { continue }
            let revents = state.revents
            if revents & events != 0 || revents & Int16(POLLERR) != 0 || revents & Int16(POLLHUP) != 0 { return true }
        }
    }
}

