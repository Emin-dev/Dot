import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

private actor SearchFixtureBudget: WebSearchBudgetAuthorizing {
    private(set) var charges: [WebSearchCharge] = []
    private var remaining: Int
    private let fail: Bool
    init(remaining: Int = 10, fail: Bool = false) { self.remaining = remaining; self.fail = fail }
    func reserve(_ charge: WebSearchCharge) throws {
        guard !fail, remaining > 0 else { throw CocoaError(.fileWriteNoPermission) }
        remaining -= 1; charges.append(charge)
    }
}

private final class RawSearchFixture: URLProtocol {
    private static let lock = NSLock()
    private static var delayCount = 0
    static var delayedRequests: Int { lock.lock(); defer { lock.unlock() }; return delayCount }
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
        }
        let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let query = payload["query"] as? String ?? ""
        let tavily = request.url?.host == "api.tavily.com"
        guard request.httpMethod == "POST", request.url?.scheme == "https", request.url?.path == "/search",
              ["api.tavily.com", "api.perplexity.ai"].contains(request.url?.host),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-token",
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "X-Ambient") == nil,
              payload["api_key"] == nil, payload["model"] == nil else { fail(); return }
        if tavily {
            guard payload["search_depth"] as? String == "basic", payload["topic"] as? String == "general",
                  payload["auto_parameters"] as? Bool == false, payload["include_answer"] as? Bool == false,
                  payload["include_raw_content"] as? Bool == false, payload["include_usage"] as? Bool == true,
                  payload["include_images"] as? Bool == false else { fail(); return }
        } else {
            guard payload["search_type"] as? String == "web", payload["max_tokens"] as? Int == 8_000,
                  payload["max_tokens_per_page"] as? Int == 1_000 else { fail(); return }
        }
        if query == "cancelled" { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        if query == "network" { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let status = Int(query) ?? 200
        var body: [String: Any] = ["results": [item(tavily: tavily)], "usage": ["credits": query == "cost-mismatch" ? 2 : 1],
                                   "answer": "DO NOT USE THIS PROVIDER ANSWER", "choices": [["text": "NOT LOCAL QWEN"]]]
        if query == "missing-usage" { body.removeValue(forKey: "usage") }
        if query == "malformed" { body["results"] = "not an array" }
        if query == "missing-fields" { body["results"] = [["url": "https://example.org"]] }
        if query == "empty" { body["results"] = [] }
        if query == "many" { body["results"] = Array(repeating: item(tavily: tavily), count: 21) }
        if query == "normalize" {
            body["results"] = [item(tavily: tavily, url: "http://127.0.0.1/private"),
                               item(tavily: tavily, url: "https://example.org/one#first", title: String(repeating: "🙂", count: 1_000), snippet: String(repeating: "é", count: 5_000)),
                               item(tavily: tavily, url: "https://example.org/one#second"),
                               item(tavily: tavily, url: "https://example.org/two")]
        }
        if query == "updated-only" {
            var result = item(tavily: tavily); result.removeValue(forKey: tavily ? "published_date" : "date"); result["last_updated"] = "2025-01-01"
            body["results"] = [result]
        }
        let data = query == "large" ? Data(repeating: 0x61, count: 1_048_577) : (query == "bad-json" ? Data("{".utf8) : try! JSONSerialization.data(withJSONObject: body))
        let response = HTTPURLResponse(url: query == "wrong-origin" ? URL(string: "https://example.org/search")! : request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": query == "mime" ? "text/html" : "application/json", "Content-Length": query == "declared-large" ? "1048577" : (query == "large" ? "1" : String(data.count))])!
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        if query == "delay" {
            Self.lock.lock(); Self.delayCount += 1; Self.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: work)
        } else { work.perform() }
    }
    private func item(tavily: Bool, url: String = "https://example.org/article", title: String = "Source title", snippet: String = "Discovery snippet only") -> [String: Any] {
        ["url": url, "title": title, tavily ? "content" : "snippet": snippet,
         tavily ? "published_date" : "date": tavily ? "Tue, 14 Nov 2023 22:13:20 GMT" : "2023-11-14",
         "raw_content": "DO NOT TURN RAW CONTENT INTO READ EVIDENCE"]
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
    override func stopLoading() { pending?.cancel(); pending = nil }
}

private final class SearchChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

final class WebSearchProviderTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RawSearchFixture.self]
        config.httpAdditionalHeaders = ["Authorization": "ambient-unwanted", "Cookie": "ambient=unwanted", "X-Ambient": "unwanted"]
        return config
    }
    private func provider(_ tavily: Bool, budget: SearchFixtureBudget = SearchFixtureBudget(), retention: WebSearchResultRetention = .notConfirmed) throws -> any WebSearchProvider {
        if tavily { return try TavilyBasicSearchProvider(apiKey: "fixture-only-token", budget: budget, retention: retention, freeOnlyAccountConfirmed: true, configuration: configuration()) }
        return try PerplexityRawSearchProvider(apiKey: "fixture-only-token", budget: budget, retention: retention, configuration: configuration())
    }
    func testTavilyBasicRequestDisablesAnswerRawContentAndAutomaticUpgrade() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(true, budget: budget)
        XCTAssertEqual(provider.providerID, "tavily-basic")
        let result = try await provider.search(query: "official information", limit: 5)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].snippet, "Discovery snippet only")
        XCTAssertEqual(result[0].publicationDateHint, Date(timeIntervalSince1970: 1_700_000_000))
        let charges = await budget.charges; XCTAssertEqual(charges, [.tavilyBasicCredits(1)])
    }
    func testPerplexityUsesRawSearchWebEndpointAndExplicitMoneyReservation() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(false, budget: budget)
        XCTAssertEqual(provider.providerID, "perplexity-search-web")
        let result = try await provider.search(query: "official information", limit: 5)
        XCTAssertEqual(result[0].snippet, "Discovery snippet only")
        XCTAssertEqual(result[0].publicationDateHint, Date(timeIntervalSince1970: 1_699_920_000))
        let charges = await budget.charges; XCTAssertEqual(charges, [.perplexityMicroUSD(5_000)])
    }
    func testConstructionNeedsExplicitCredentialAndTavilyFreeOnlyAccount() throws {
        for key in ["", "bad\nkey", "bad key", String(repeating: "x", count: 4_097)] {
            XCTAssertThrowsError(try PerplexityRawSearchProvider(apiKey: key, budget: SearchFixtureBudget(), retention: .notConfirmed))
        }
        XCTAssertThrowsError(try TavilyBasicSearchProvider(apiKey: "fixture-only-token", budget: SearchFixtureBudget(), retention: .notConfirmed, freeOnlyAccountConfirmed: false)) {
            XCTAssertEqual($0 as? WebSearchProviderError, .freeOnlyAccountNotConfirmed)
        }
    }
    func testRetentionIsAnExplicitSelectedPlanFlagForBothAdapters() throws {
        for tavily in [true, false] {
            XCTAssertFalse(try provider(tavily).permitsResultPersistence)
            XCTAssertTrue(try provider(tavily, retention: .permittedBySelectedPlan).permitsResultPersistence)
        }
    }
    func testInvalidQueriesConsumeNoQuota() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(true, budget: budget)
        for (query, limit) in [(" ", 5), (String(repeating: "x", count: 2_049), 5), ("query", 0), ("query", 9)] {
            do { _ = try await provider.search(query: query, limit: limit); XCTFail("Invalid input accepted") }
            catch { XCTAssertEqual(error as? WebSearchProviderError, .invalidQuery) }
        }
        let charges = await budget.charges; XCTAssertTrue(charges.isEmpty)
    }
    func testFailedDurableReservationPreventsDispatchAndSanitizesError() async throws {
        let budget = SearchFixtureBudget(fail: true), provider = try provider(false, budget: budget)
        do { _ = try await provider.search(query: "network", limit: 1); XCTFail("Budget failure allowed request") }
        catch { XCTAssertEqual(error as? WebSearchProviderError, .budgetUnavailable) }
        let charges = await budget.charges; XCTAssertTrue(charges.isEmpty)
    }
    func testSharedCallerQuotaBoundsDifferentAdapterInstances() async throws {
        let budget = SearchFixtureBudget(remaining: 1)
        let first = try provider(true, budget: budget), second = try provider(false, budget: budget)
        _ = try await first.search(query: "query", limit: 1)
        do { _ = try await second.search(query: "query", limit: 1); XCTFail("Exhausted shared quota ignored") }
        catch { XCTAssertEqual(error as? WebSearchProviderError, .budgetUnavailable) }
        let charges = await budget.charges; XCTAssertEqual(charges, [.tavilyBasicCredits(1)])
    }
    func testStatusFailuresAreSanitizedNeverRetriedAndKeepReservations() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(false, budget: budget)
        for code in [301, 401, 403, 429, 500] {
            do { _ = try await provider.search(query: String(code), limit: 1); XCTFail("Failure accepted") }
            catch { XCTAssertEqual(error as? WebSearchProviderError, .httpStatus(code)) }
        }
        let charges = await budget.charges; XCTAssertEqual(charges.count, 5)
    }
    func testMalformedOversizedWrongOriginAndWrongMIMEFailClosed() async throws {
        for tavily in [true, false] {
            let provider = try provider(tavily, budget: SearchFixtureBudget(remaining: 20))
            for query in ["malformed", "missing-fields", "bad-json", "many", "wrong-origin", "mime", "declared-large", "large"] {
                do { _ = try await provider.search(query: query, limit: 2); XCTFail("Accepted \(query)") }
                catch { XCTAssertEqual(error as? WebSearchProviderError, ["declared-large", "large"].contains(query) ? .responseTooLarge : .invalidResponse) }
            }
        }
    }
    func testUnexpectedTavilyUsageStopsFurtherCallsWithoutMoreReservations() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(true, budget: budget)
        for query in ["cost-mismatch", "query"] {
            do { _ = try await provider.search(query: query, limit: 1); XCTFail("Unexpected usage ignored") }
            catch { XCTAssertEqual(error as? WebSearchProviderError, .unexpectedUsage) }
        }
        let charges = await budget.charges; XCTAssertEqual(charges.count, 1)
        do { _ = try await self.provider(true).search(query: "missing-usage", limit: 1); XCTFail("Missing usage accepted") }
        catch { XCTAssertEqual(error as? WebSearchProviderError, .invalidResponse) }
    }
    func testNormalizeDeduplicatesFiltersPrivateURLsAndBoundsUTF8WithoutCreatingEvidence() async throws {
        for tavily in [true, false] {
            let results = try await provider(tavily).search(query: "normalize", limit: 2)
            XCTAssertEqual(results.map(\.url.absoluteString), ["https://example.org/one", "https://example.org/two"])
            XCTAssertEqual(results[0].title.utf8.count, 2_048); XCTAssertEqual(results[0].snippet.utf8.count, 8_192)
            XCTAssertEqual(results[1].snippet, "Discovery snippet only")
        }
    }
    func testEmptyResultsAreACompletedChargedRequestAndUpdatedDateIsNotPublication() async throws {
        for tavily in [true, false] {
            let budget = SearchFixtureBudget(), provider = try provider(tavily, budget: budget)
            let empty = try await provider.search(query: "empty", limit: 2); XCTAssertTrue(empty.isEmpty)
            let result = try await provider.search(query: "updated-only", limit: 2); XCTAssertNil(result[0].publicationDateHint)
            let charges = await budget.charges; XCTAssertEqual(charges.count, 2)
        }
    }
    func testCancellationBeforeReservationAndTransportCancellationPreserveSemantics() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(false, budget: budget)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await provider.search(query: "query", limit: 1) }
        do { _ = try await task.value; XCTFail("Cancelled request succeeded") } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let before = await budget.charges; XCTAssertTrue(before.isEmpty)
        do { _ = try await provider.search(query: "cancelled", limit: 1); XCTFail("Cancelled transport succeeded") } catch is CancellationError {} catch { XCTFail("Wrong transport cancellation") }
        let after = await budget.charges; XCTAssertEqual(after.count, 1)
    }
    func testSingleFlightPreventsOverlappingProviderRequests() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(false, budget: budget)
        let task = Task { try await provider.search(query: "delay", limit: 1) }
        while await budget.charges.isEmpty { await Task.yield() }
        do { _ = try await provider.search(query: "query", limit: 1); XCTFail("Overlapping request allowed") }
        catch { XCTAssertEqual(error as? WebSearchProviderError, .busy) }
        _ = try await task.value
        let charges = await budget.charges; XCTAssertEqual(charges.count, 1)
    }
    func testCancelInFlightRetainsReservationAndAllowsANewExplicitRequest() async throws {
        let budget = SearchFixtureBudget(), provider = try provider(false, budget: budget)
        let initial = RawSearchFixture.delayedRequests
        let task = Task { try await provider.search(query: "delay", limit: 1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while RawSearchFixture.delayedRequests == initial && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThan(RawSearchFixture.delayedRequests, initial)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled in-flight request succeeded") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation error") }
        let before = await budget.charges; XCTAssertEqual(before.count, 1)
        _ = try await provider.search(query: "query", limit: 1)
        let after = await budget.charges; XCTAssertEqual(after.count, 2)
    }
    func testAuthenticationChallengesUseSystemTLSAndRejectOtherCredentials() {
        let policy = RawSearchNetworkPolicy(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "api.tavily.com", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let proposed = URLCredential(user: "ambient", password: "must-not-use", persistence: .none)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: proposed, previousFailureCount: 0, failureResponse: nil, error: nil, sender: SearchChallengeSender())
            policy.urlSession(session, didReceive: challenge) { disposition, credential in
                XCTAssertNil(credential)
                XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge)
            }
        }
    }
    func testRedirectDelegateRejectsEvenSameOriginWithoutForwardingCredentials() {
        let policy = RawSearchNetworkPolicy(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://api.tavily.com/search")!, task = session.dataTask(with: URL(string: "https://api.tavily.com/search")!)
        for destination in ["https://api.tavily.com/next", "https://example.org/steal", "http://api.tavily.com/search"] {
            let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination])!
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: destination)!)) { XCTAssertNil($0) }
        }
    }
}
