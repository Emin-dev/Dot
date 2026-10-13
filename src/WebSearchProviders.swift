import Foundation

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
