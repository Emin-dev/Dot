import Foundation

/// A manager-issued launch receipt, not proof of ownership by itself. The manager
/// must continuously own the inherited listener and verify the launch generation.
/// Never construct this from port discovery, user URL text, or a public instance.
struct SearXNGOwnedEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let port: Int
    let generation: UUID
    let url: URL
    let capability: String

    init(port: Int, capability: String, generation: UUID) throws {
        guard (1...65_535).contains(port), (32...256).contains(capability.utf8.count),
              capability.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let url = URL(string: "http://127.0.0.1:\(port)/search") else {
            throw SearXNGSearchError.invalidConfiguration
        }
        self.port = port; self.capability = capability; self.generation = generation; self.url = url
    }
    var description: String { "Owned search launch (capability redacted)" }
    var debugDescription: String { description }
}

enum SearXNGSearchError: Error, Equatable, LocalizedError, WebSearchTemporarilyUnavailable {
    case invalidConfiguration, invalidQuery, unavailable, busy, forbidden, challenge
    case malformedResponse, invalidResults, responseTooLarge, timeout, networkFailure
    case httpStatus(Int)
    /// nil is a fail-closed, unrepresentable server delay; do not dispatch again.
    case cooldown(until: Date?)

    var retryDate: Date? {
        if case .cooldown(let until) = self { return until }; return nil
    }
    var retryRequiresReview: Bool {
        switch self {
        case .cooldown(let until): return until == nil
        case .invalidConfiguration, .unavailable, .forbidden, .challenge,
             .malformedResponse, .invalidResults, .responseTooLarge: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Search needs a valid owned helper launch."
        case .invalidQuery: return "Provide a nonempty search query within the supported limits."
        case .unavailable: return "The owned search runtime or all selected engines are unavailable."
        case .busy: return "This search runtime already has a request in progress."
        case .forbidden: return "Search was forbidden. Check the owned runtime's JSON configuration and access."
        case .challenge: return "Search returned a web page instead of JSON. Check the owned runtime."
        case .malformedResponse: return "Search returned an unsupported response."
        case .invalidResults: return "Search returned no usable web results from a nonempty response."
        case .responseTooLarge: return "The search response exceeded its bounded size."
        case .timeout: return "The search request timed out."
        case .networkFailure: return "The search request could not finish."
        case .httpStatus(let status): return "The search runtime returned HTTP \(status)."
        case .cooldown: return "Search is paused for the runtime's retry delay."
        }
    }
}

/// One manager-owned gate must be shared by every provider for this runtime,
/// including replacement launches. Neither queries nor provider recreation may
/// reset its cooldown. All deadlines controlling dispatch use a monotonic clock.
actor SearXNGRequestGate {
    private let clock = ContinuousClock()
    private let minimumInterval: Duration
    private let maximumWait: Duration
    private var nextStart = ContinuousClock.now
    private var blockedUntil: ContinuousClock.Instant?
    private var retryDate: Date?
    private var indefinitelyBlocked = false
    private var busy = false

    init(minimumInterval: Duration = .milliseconds(500), maximumWait: Duration = .seconds(2)) {
        self.minimumInterval = max(.zero, minimumInterval)
        self.maximumWait = max(.zero, maximumWait)
    }

    func perform(_ operation: @Sendable () async throws -> WebSearchResponse) async throws -> WebSearchResponse {
        try Task.checkCancellation()
        guard !busy else { throw SearXNGSearchError.busy }
        busy = true; defer { busy = false }
        guard !indefinitelyBlocked else { throw SearXNGSearchError.cooldown(until: nil) }
        let now = clock.now
        if let blockedUntil, blockedUntil > now, now.duration(to: blockedUntil) > maximumWait {
            throw SearXNGSearchError.cooldown(until: retryDate)
        }
        let deadline = max(nextStart, blockedUntil ?? nextStart)
        if deadline > now { try await clock.sleep(until: deadline) }
        try Task.checkCancellation()
        nextStart = clock.now.advanced(by: minimumInterval)
        return try await operation()
    }

    /// Only response headers reach this method; no query, body or capability.
    func imposeCooldown(retryAfter: String?, now: Date = Date()) -> Date? {
        let delay: TimeInterval
        if let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            if value.utf8.allSatisfy({ (48...57).contains($0) }) {
                // Values beyond a safely representable monotonic interval block
                // indefinitely rather than being shortened to a local retry cap.
                guard value.utf8.count <= 16, let seconds = Double(value), seconds.isFinite,
                      seconds <= 3_155_760_000 else {
                    indefinitelyBlocked = true; retryDate = nil; return nil
                }
                delay = seconds
            } else if value.utf8.count <= 128, let date = Self.httpDate(value) {
                delay = max(0, date.timeIntervalSince(now))
            } else { delay = 30 }
        } else { delay = 30 }
        guard delay <= 3_155_760_000 else { indefinitelyBlocked = true; retryDate = nil; return nil }
        let deadline = clock.now.advanced(by: .seconds(delay))
        if blockedUntil == nil || deadline > blockedUntil! {
            blockedUntil = deadline; retryDate = now.addingTimeInterval(delay)
        }
        return retryDate
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// Retrieval only, with no API key, paid-provider budget or retention assertion.
/// The production manager supplies the endpoint, current-generation check and
/// cancellation hook. A configured URL/port does not make a helper ready.
final class SearXNGSearchProvider: WebSearchProvider, Sendable {
    let providerID = "searxng-owned-keyless"
    let permitsResultPersistence = false
    private let client: SearXNGSearchClient

    init(endpoint: SearXNGOwnedEndpoint, gate: SearXNGRequestGate,
         isCurrentGeneration: @escaping @Sendable (UUID) async -> Bool,
         onCancellation: @escaping @Sendable (UUID) async -> Void,
         engineIDs: [String] = ["duckduckgo"], language: String = "auto", safeSearch: Int = 1,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        client = try SearXNGSearchClient(endpoint: endpoint, gate: gate,
            isCurrentGeneration: isCurrentGeneration, onCancellation: onCancellation,
            engineIDs: engineIDs, language: language, safeSearch: safeSearch, configuration: configuration)
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        try await searchResponse(query: query, limit: limit).results
    }
    func searchResponse(query: String, limit: Int) async throws -> WebSearchResponse {
        try await client.search(query: query, limit: limit)
    }
}

private actor SearXNGSearchClient {
    static let maximumResponseBytes = 1_048_576
    private let endpoint: SearXNGOwnedEndpoint
    private let gate: SearXNGRequestGate
    private let isCurrentGeneration: @Sendable (UUID) async -> Bool
    private let onCancellation: @Sendable (UUID) async -> Void
    private let engineIDs: [String]
    private let language: String
    private let safeSearch: Int
    private let configuration: URLSessionConfiguration

    init(endpoint: SearXNGOwnedEndpoint, gate: SearXNGRequestGate,
         isCurrentGeneration: @escaping @Sendable (UUID) async -> Bool,
         onCancellation: @escaping @Sendable (UUID) async -> Void,
         engineIDs: [String], language: String, safeSearch: Int,
         configuration: URLSessionConfiguration) throws {
        // The helper must independently keep_only this exact reviewed selection.
        let reviewed = Set(["duckduckgo", "brave", "wikipedia"])
        guard !engineIDs.isEmpty, engineIDs.count <= reviewed.count,
              Set(engineIDs).count == engineIDs.count, Set(engineIDs).isSubset(of: reviewed),
              (0...2).contains(safeSearch), (1...20).contains(language.utf8.count),
              language.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw SearXNGSearchError.invalidConfiguration
        }
        self.endpoint = endpoint; self.gate = gate
        self.isCurrentGeneration = isCurrentGeneration; self.onCancellation = onCancellation
        self.engineIDs = engineIDs; self.language = language; self.safeSearch = safeSearch
        // Fresh ephemeral config; the sole supported injection is explicit
        // URLProtocol fixture classes. Ambient caches/proxies/headers never copy.
        self.configuration = SearXNGSearchNetworkPolicy.isolated(configuration)
    }

    func search(query: String, limit: Int) async throws -> WebSearchResponse {
        try Task.checkCancellation()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 2_048, (1...8).contains(limit),
              (!engineIDs.contains("duckduckgo") || query.unicodeScalars.count < 500),
              !query.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.hasPrefix("!") }) else {
            throw SearXNGSearchError.invalidQuery
        }
        let current = await isCurrentGeneration(endpoint.generation)
        try Task.checkCancellation()
        guard current else { throw SearXNGSearchError.unavailable }
        return try await gate.perform { try await self.request(query: query, limit: limit) }
    }

    private func request(query: String, limit: Int) async throws -> WebSearchResponse {
        try Task.checkCancellation()
        let current = await isCurrentGeneration(endpoint.generation)
        try Task.checkCancellation()
        guard current else { throw SearXNGSearchError.unavailable }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(endpoint.capability, forHTTPHeaderField: "X-Dot-Search-Capability")
        request.httpBody = Self.form([
            ("q", query), ("format", "json"), ("categories", "general"), ("pageno", "1"),
            ("language", language), ("safesearch", String(safeSearch)), ("engines", engineIDs.joined(separator: ","))
        ])
        let policy = SearXNGSearchNetworkPolicy()
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = rawResponse as? HTTPURLResponse, response.url == endpoint.url else {
                throw SearXNGSearchError.malformedResponse
            }
            if [429, 503].contains(response.statusCode) {
                let until = await gate.imposeCooldown(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                throw SearXNGSearchError.cooldown(until: until)
            }
            if response.statusCode == 403 { throw SearXNGSearchError.forbidden }
            guard (200...299).contains(response.statusCode) else { throw SearXNGSearchError.httpStatus(response.statusCode) }
            guard response.mimeType?.lowercased() == "application/json" else {
                throw response.mimeType?.lowercased() == "text/html" ? SearXNGSearchError.challenge : .malformedResponse
            }
            guard response.expectedContentLength <= Self.maximumResponseBytes else { throw SearXNGSearchError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
                guard data.count < Self.maximumResponseBytes else { throw SearXNGSearchError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard await isCurrentGeneration(endpoint.generation) else { throw SearXNGSearchError.unavailable }
            let result = try Self.normalize(data, limit: limit, selectedEngines: engineIDs)
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                session.invalidateAndCancel()
                // Cancelling the HTTP task cannot prove upstream work stopped.
                // The manager tears down only this still-owned launch generation.
                await onCancellation(endpoint.generation)
                throw CancellationError()
            }
            if let safe = error as? SearXNGSearchError { throw safe }
            if (error as? URLError)?.code == .timedOut { throw SearXNGSearchError.timeout }
            // Never propagate URLSession errors, bodies, queries or capabilities.
            throw SearXNGSearchError.networkFailure
        }
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

    private static func normalize(_ data: Data, limit: Int, selectedEngines: [String]) throws -> WebSearchResponse {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw SearXNGSearchError.malformedResponse }
        guard let envelope = object as? [String: Any], envelope["error"] == nil, envelope["errors"] == nil,
              let items = envelope["results"] as? [Any], items.count <= 512,
              let warnings = envelope["unresponsive_engines"] as? [Any], warnings.count <= 64 else {
            throw SearXNGSearchError.malformedResponse
        }
        let allowed = Set(selectedEngines)
        var unavailable = Set<String>()
        var partial = false
        for entry in warnings {
            // Reasons are translated, untrusted prose. Validate their shape,
            // discard their contents, and retain only reviewed selected IDs.
            guard let pair = entry as? [Any], pair.count == 2, let engine = pair[0] as? String,
                  engine.utf8.count <= 100, let reason = pair[1] as? String, reason.utf8.count <= 8_192 else {
                throw SearXNGSearchError.malformedResponse
            }
            partial = true
            if allowed.contains(engine) { unavailable.insert(engine) }
        }
        if unavailable == allowed { throw SearXNGSearchError.unavailable }
        var seen = Set<String>(), results: [WebSearchResult] = []
        for value in items {
            try Task.checkCancellation()
            guard let item = value as? [String: Any],
                  item["template"] == nil || item["template"] as? String == "default.html",
                  let address = item["url"] as? String, let titleValue = item["title"] as? String,
                  let url = URL(string: address), ResearchWebReader.allowed(url),
                  item["content"] == nil || item["content"] is NSNull || item["content"] is String,
                  item["publishedDate"] == nil || item["publishedDate"] is NSNull || item["publishedDate"] is String else { continue }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil; parts?.host = parts?.host?.lowercased(); parts?.scheme = parts?.scheme?.lowercased()
            if (parts?.scheme == "https" && parts?.port == 443) || (parts?.scheme == "http" && parts?.port == 80) { parts?.port = nil }
            guard let canonical = parts?.url else { continue }
            let title = prefixUTF8(titleValue.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 2_048)
            guard !title.isEmpty, seen.insert(canonical.absoluteString).inserted else { continue }
            results.append(WebSearchResult(url: canonical, title: title,
                snippet: prefixUTF8(item["content"] as? String ?? "", maximumBytes: 8_192),
                publicationDateHint: (item["publishedDate"] as? String).flatMap(dateHint)))
            if results.count == limit { break }
        }
        guard items.isEmpty || !results.isEmpty else { throw SearXNGSearchError.invalidResults }
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
}

/// This loopback transport never performs any credential challenge or redirect,
/// including same-origin redirects. It has no access/debug/query logger.
final class SearXNGSearchNetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func isolated(_ original: URLSessionConfiguration) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = original.protocolClasses
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil; config.httpAdditionalHeaders = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // nil/empty proxyConfigurations inherits system settings. A nonnil legacy
        // dictionary explicitly disables each mechanism for this fixed loopback.
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0, "ExceptionsList": ["127.0.0.1"]]
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 1; config.waitsForConnectivity = false
        return config
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
