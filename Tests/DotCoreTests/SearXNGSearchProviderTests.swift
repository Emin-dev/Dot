import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

private actor SearXNGFixtureLease {
    private var current = true
    private(set) var cancellations = 0
    func isCurrent() -> Bool { current }
    func invalidate() { current = false }
    func cancelled() { cancellations += 1 }
}

/// Explicit test transport; no localhost listener or real engine is contacted.
private final class SearXNGFixture: URLProtocol {
    struct Captured {
        let request: URLRequest
        let body: String
        let form: [String: String]
    }
    private static let lock = NSLock()
    private static var records: [String: [Captured]] = [:]
    private var pending: DispatchWorkItem?
    static func requests(_ query: String) -> [Captured] {
        lock.lock(); defer { lock.unlock() }; return records[query] ?? []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
        }
        let body = String(data: bytes, encoding: .utf8) ?? ""
        var form: [String: String] = [:]
        for field in body.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
                let key = String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                form[key] = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
        }
        let query = form["q"] ?? ""
        Self.lock.lock(); Self.records[query, default: []].append(Captured(request: request, body: body, form: form)); Self.lock.unlock()
        if query == "timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if query == "network-secret" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "secret-query-and-capability", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SECRET RESPONSE BODY"])); return
        }
        if query == "transport-cancelled" { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        var status = 200
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        var envelope: [String: Any] = ["results": [Self.item()], "unresponsive_engines": [],
            "answers": [["answer": "UNTRUSTED ANSWER"]], "infoboxes": [["content": "UNTRUSTED INFOBOX"]],
            "corrections": ["DO NOT USE"], "query": "DO NOT RETAIN THIS QUERY"]
        switch query {
        case "empty": envelope["results"] = []
        case "many": envelope["results"] = (0..<40).map { Self.item("https://example.org/\($0)") }
        case "too-many": envelope["results"] = (0..<513).map { Self.item("https://example.org/\($0)") }
        case "optional": envelope["results"] = [["url": "https://example.org/optional", "title": "Optional fields"]]
        case "updated-only": envelope["results"] = [["url": "https://example.org/updated", "title": "Updated", "publishedDate": NSNull(), "last_updated": "2026-01-01", "pubdate": "2026-01-01"]]
        case "normalize":
            envelope["results"] = [
                Self.item("http://127.0.0.1/private"), Self.item("https://example.org/one#first", title: String(repeating: "👨‍👩‍👧‍👦", count: 200), content: String(repeating: "界e\u{301}", count: 3_000)),
                Self.item("https://example.org:443/one#second"), ["title": "non-web answer"],
                Self.item("https://example.org/two"), Self.item("file:///private/doc")
            ]
        case "heterogeneous":
            envelope["results"] = [42, NSNull(), ["url": "https://example.org/image", "title": "Image", "template": "images.html"],
                ["url": "https://example.org/wrong", "title": "Wrong", "content": 4], Self.item()]
        case "filtered": envelope["results"] = [Self.item("http://127.0.0.1/private"), ["title": "missing URL"]]
        case "partial", "partial-empty":
            envelope["unresponsive_engines"] = [["brave", "Délai dépassé SECRET ERROR"]]
            if query == "partial-empty" { envelope["results"] = [] }
        case "all-failed": envelope["results"] = []; envelope["unresponsive_engines"] = [["duckduckgo", "錯誤"], ["brave", "тайм-аут"]]
        case "unknown-engine": envelope["unresponsive_engines"] = [["unreviewed SECRET ID", "translated prose"]]
        case "warning-shape": envelope["unresponsive_engines"] = [["duckduckgo": "timeout"]]
        case "warning-type": envelope["unresponsive_engines"] = [["brave", 42]]
        case "missing-warnings": envelope.removeValue(forKey: "unresponsive_engines")
        case "missing-results": envelope.removeValue(forKey: "results")
        case "results-type": envelope["results"] = "wrong"
        case "error-envelope": envelope["error"] = "SECRET BODY"
        case "403": status = 403
        case "302": status = 302; headers["Location"] = "http://127.0.0.1:42981/other"
        case "500": status = 500
        case "html": headers["Content-Type"] = "text/html"
        case "bad-mime": headers["Content-Type"] = "text/plain"
        case "retry-seconds": status = 429; headers["Retry-After"] = "3600"
        case "retry-date":
            status = 503
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            headers["Retry-After"] = formatter.string(from: Date().addingTimeInterval(7_200))
        case "retry-malformed": status = 429; headers["Retry-After"] = "later SECRET"
        case "retry-huge": status = 429; headers["Retry-After"] = String(repeating: "9", count: 100)
        case "retry-zero": status = 429; headers["Retry-After"] = "0"
        default: break
        }
        var data = try! JSONSerialization.data(withJSONObject: envelope)
        if query == "bad-json" { data = Data("{".utf8) }
        if query == "array-json" { data = Data("[]".utf8) }
        if query == "html" { data = Data("<html>captcha SECRET</html>".utf8) }
        if query == "stream-large" { data = Data(repeating: 0x20, count: 1_048_577) }
        headers["Content-Length"] = query == "declared-large" ? "1048577" : (query == "stream-large" ? "1" : String(data.count))
        let responseURL = query == "wrong-origin" ? URL(string: "http://127.0.0.1:42982/search")! : request.url!
        let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for offset in stride(from: 0, to: data.count, by: 16_384) {
                self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(data.count, offset + 16_384)))
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        if query.hasPrefix("delay-") { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: work) }
        else { work.perform() }
    }
    static func item(_ url: String = "https://example.org/article", title: String = "Source title", content: String = "Discovery hint") -> [String: Any] {
        ["url": url, "title": title, "content": content, "publishedDate": "2023-11-14T22:13:20Z", "engine": "duckduckgo",
         "engines": ["duckduckgo", "SECRET UNKNOWN ENGINE"], "raw_content": "DO NOT USE AS EVIDENCE"]
    }
    override func stopLoading() { pending?.cancel(); pending = nil }
}

private final class SearXNGChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

final class SearXNGSearchProviderTests: XCTestCase {
    private let capability = String(repeating: "fixture-only-", count: 4)
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [SearXNGFixture.self]
        config.httpAdditionalHeaders = ["Authorization": "ambient-secret", "Cookie": "ambient-secret", "X-Ambient": "ambient-secret"]
        config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "untrusted.example", "HTTPPort": 9999]
        return config
    }
    private func endpoint() throws -> SearXNGOwnedEndpoint { try SearXNGOwnedEndpoint(port: 42981, capability: capability, generation: UUID()) }
    private func provider(gate: SearXNGRequestGate = SearXNGRequestGate(minimumInterval: .zero),
                          lease: SearXNGFixtureLease = SearXNGFixtureLease(),
                          engineIDs: [String] = ["duckduckgo", "brave"]) throws -> SearXNGSearchProvider {
        try SearXNGSearchProvider(endpoint: endpoint(), gate: gate,
            isCurrentGeneration: { _ in await lease.isCurrent() }, onCancellation: { _ in await lease.cancelled() },
            engineIDs: engineIDs, configuration: configuration())
    }
    private func waitForRequest(_ query: String, after count: Int = 0) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while SearXNGFixture.requests(query).count <= count && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThan(SearXNGFixture.requests(query).count, count)
    }

    func testExactPOSTFormEncodingAndNoCredentialsOrRetention() async throws {
        let provider = try provider(engineIDs: ["duckduckgo"])
        let query = "C++ & café=界 %\r\n🙂"
        let result = try await provider.searchResponse(query: query, limit: 3)
        let sent = try XCTUnwrap(SearXNGFixture.requests(query).last)
        XCTAssertEqual(sent.request.url?.absoluteString, "http://127.0.0.1:42981/search")
        XCTAssertNil(sent.request.url?.query); XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Dot-Search-Capability"), capability)
        for key in ["Authorization", "Cookie", "X-Ambient", "Proxy-Authorization"] { XCTAssertNil(sent.request.value(forHTTPHeaderField: key)) }
        XCTAssertEqual(sent.form, ["q": query, "format": "json", "categories": "general", "pageno": "1", "language": "auto", "safesearch": "1", "engines": "duckduckgo"])
        XCTAssertTrue(sent.body.contains("C%2B%2B+%26+caf%C3%A9%3D%E7%95%8C+%25%0D%0A%F0%9F%99%82"))
        XCTAssertFalse(provider.permitsResultPersistence)
        XCTAssertEqual(result.coverage, .complete); XCTAssertEqual(result.unavailableEngineIDs, [])
        XCTAssertEqual(result.results.first?.snippet, "Discovery hint")
        XCTAssertEqual(result.results.first?.publicationDateHint, Date(timeIntervalSince1970: 1_700_000_000))
    }
    func testFailureMetadataPausesBrokenRuntimeWithoutExposingDiagnostics() {
        for failure in [SearXNGSearchError.invalidConfiguration, .unavailable, .forbidden, .challenge,
                        .malformedResponse, .invalidResults, .responseTooLarge, .cooldown(until: nil)] {
            XCTAssertTrue(failure.retryRequiresReview); XCTAssertNil(failure.retryDate)
        }
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertFalse(SearXNGSearchError.cooldown(until: date).retryRequiresReview)
        XCTAssertEqual(SearXNGSearchError.cooldown(until: date).retryDate, date)
        XCTAssertFalse(SearXNGSearchError.busy.retryRequiresReview)
    }
    func testEndpointConstructionOnlyAcceptsExplicitValidPortAndBoundedCapability() throws {
        for port in [-1, 0, 65536, Int.max] { XCTAssertThrowsError(try SearXNGOwnedEndpoint(port: port, capability: capability, generation: UUID())) }
        for token in ["", "short", String(repeating: "x", count: 257), String(repeating: "x", count: 32) + "\n", String(repeating: "x", count: 32) + ":"] {
            XCTAssertThrowsError(try SearXNGOwnedEndpoint(port: 42981, capability: token, generation: UUID()))
        }
        let endpoint = try endpoint()
        XCTAssertEqual(endpoint.url.host, "127.0.0.1"); XCTAssertNil(endpoint.url.user); XCTAssertNil(endpoint.url.password)
        XCTAssertNil(endpoint.url.query); XCTAssertNil(endpoint.url.fragment)
        XCTAssertFalse(String(reflecting: endpoint).contains(capability))
        for ids in [[], ["braveapi"], ["google"], ["duckduckgo", "duckduckgo"], ["duckduckgo,brave"]] {
            XCTAssertThrowsError(try provider(engineIDs: ids))
        }
    }
    func testInvalidQueriesAndUnownedGenerationDispatchNothing() async throws {
        let lease = SearXNGFixtureLease(), provider = try provider(lease: lease)
        for (query, limit) in [(" ", 1), ("contains\u{0}nul", 1), (String(repeating: "界", count: 683), 1), (String(repeating: "a", count: 500), 1), (String(repeating: "e\u{301}", count: 250), 1), ("bad-limit", 0), ("bad-limit", 9), ("!brave query", 1), ("query !!external", 1)] {
            do { _ = try await provider.search(query: query, limit: limit); XCTFail("Invalid query accepted") }
            catch { XCTAssertEqual(error as? SearXNGSearchError, .invalidQuery) }
            XCTAssertTrue(SearXNGFixture.requests(query).isEmpty)
        }
        await lease.invalidate()
        do { _ = try await provider.search(query: "unowned", limit: 1); XCTFail("Unowned generation dispatched") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .unavailable) }
        XCTAssertTrue(SearXNGFixture.requests("unowned").isEmpty)
    }
    func testNormalizationAcceptsMoreThanTwentyAndMissingOptionalFields() async throws {
        let provider = try provider()
        let many = try await provider.search(query: "many", limit: 8)
        XCTAssertEqual(many.count, 8); XCTAssertEqual(many.last?.url.path, "/7")
        let optional = try await provider.search(query: "optional", limit: 1)
        XCTAssertEqual(optional.first?.snippet, ""); XCTAssertNil(optional.first?.publicationDateHint)
        let updated = try await provider.search(query: "updated-only", limit: 1)
        XCTAssertNil(updated.first?.publicationDateHint)
        let mixed = try await provider.search(query: "heterogeneous", limit: 8)
        XCTAssertEqual(mixed.count, 1)
    }
    func testCanonicalDeduplicationPublicLexicalFilterAndGraphemeBounds() async throws {
        let results = try await provider().search(query: "normalize", limit: 8)
        XCTAssertEqual(results.map(\.url.absoluteString), ["https://example.org/one", "https://example.org/two"])
        XCTAssertLessThanOrEqual(results[0].title.utf8.count, 2_048)
        XCTAssertTrue(String(repeating: "👨‍👩‍👧‍👦", count: 200).hasPrefix(results[0].title))
        XCTAssertLessThanOrEqual(results[0].snippet.utf8.count, 8_192)
        XCTAssertTrue(String(repeating: "界e\u{301}", count: 3_000).hasPrefix(results[0].snippet))
        XCTAssertFalse(results[0].snippet.contains("DO NOT USE"))
    }
    func testEmptyPartialAndAllFailedHaveDifferentOutcomesAndWarningsAreRedacted() async throws {
        let provider = try provider()
        let empty = try await provider.searchResponse(query: "empty", limit: 1)
        XCTAssertTrue(empty.results.isEmpty); XCTAssertEqual(empty.coverage, .complete)
        for query in ["partial", "partial-empty"] {
            let result = try await provider.searchResponse(query: query, limit: 1)
            XCTAssertEqual(result.coverage, .partial); XCTAssertEqual(result.unavailableEngineIDs, ["brave"])
            XCTAssertEqual(result.results.isEmpty, query == "partial-empty")
        }
        let unknown = try await provider.searchResponse(query: "unknown-engine", limit: 1)
        XCTAssertEqual(unknown.coverage, .partial); XCTAssertEqual(unknown.unavailableEngineIDs, [])
        do { _ = try await provider.search(query: "all-failed", limit: 1); XCTFail("All engine failures reported zero hits") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .unavailable) }
    }
    func testMalformedFilteredAndForbiddenAreNotZeroHitSuccessAndNeverRetry() async throws {
        let cases: [(String, SearXNGSearchError)] = [
            ("warning-shape", .malformedResponse), ("warning-type", .malformedResponse), ("missing-warnings", .malformedResponse),
            ("missing-results", .malformedResponse), ("results-type", .malformedResponse), ("error-envelope", .malformedResponse),
            ("bad-json", .malformedResponse), ("array-json", .malformedResponse), ("too-many", .malformedResponse),
            ("filtered", .invalidResults), ("403", .forbidden), ("html", .challenge), ("bad-mime", .malformedResponse),
            ("wrong-origin", .malformedResponse), ("302", .httpStatus(302)), ("500", .httpStatus(500)),
            ("declared-large", .responseTooLarge), ("stream-large", .responseTooLarge), ("timeout", .timeout), ("network-secret", .networkFailure)
        ]
        for (query, expected) in cases {
            let count = SearXNGFixture.requests(query).count
            do { _ = try await provider().search(query: query, limit: 1); XCTFail("Invalid response accepted") }
            catch {
                XCTAssertEqual(error as? SearXNGSearchError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET")); XCTAssertFalse(error.localizedDescription.contains(capability))
            }
            XCTAssertEqual(SearXNGFixture.requests(query).count, count + 1)
        }
    }
    func testCooldownHonorsFullSecondsAndHTTPDateAcrossProviderInstancesAndSixQueries() async throws {
        for (query, minimum) in [("retry-seconds", 3_599.0), ("retry-date", 7_198.0), ("retry-malformed", 29.0)] {
            let gate = SearXNGRequestGate(minimumInterval: .zero, maximumWait: .zero)
            let first = try provider(gate: gate), second = try provider(gate: gate)
            let start = Date(), count = SearXNGFixture.requests(query).count
            var date: Date?
            do { _ = try await first.search(query: query, limit: 1); XCTFail("Cooldown ignored") }
            catch SearXNGSearchError.cooldown(let until) { date = until }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(date).timeIntervalSince(start), minimum)
            for index in 0..<6 {
                let next = "blocked-\(query)-\(index)"
                do { _ = try await second.search(query: next, limit: 1); XCTFail("Shared cooldown bypassed") }
                catch { XCTAssertEqual(error as? SearXNGSearchError, .cooldown(until: date)) }
                XCTAssertTrue(SearXNGFixture.requests(next).isEmpty)
            }
            XCTAssertEqual(SearXNGFixture.requests(query).count, count + 1)
        }
    }
    func testUnrepresentableCooldownFailsClosedAndZeroAllowsOnlyExplicitNewRequest() async throws {
        let blocked = try provider(gate: SearXNGRequestGate(minimumInterval: .zero, maximumWait: .zero))
        for query in ["retry-huge", "blocked-huge"] {
            do { _ = try await blocked.search(query: query, limit: 1); XCTFail("Unrepresentable delay shortened") }
            catch { XCTAssertEqual(error as? SearXNGSearchError, .cooldown(until: nil)) }
        }
        XCTAssertTrue(SearXNGFixture.requests("blocked-huge").isEmpty)
        let retry = try provider(gate: SearXNGRequestGate(minimumInterval: .zero, maximumWait: .zero))
        let count = SearXNGFixture.requests("retry-zero").count
        do { _ = try await retry.search(query: "retry-zero", limit: 1); XCTFail("Zero delay auto-retried") }
        catch SearXNGSearchError.cooldown { }
        XCTAssertEqual(SearXNGFixture.requests("retry-zero").count, count + 1)
        let result = try await retry.search(query: "explicit-after-zero", limit: 1)
        XCTAssertEqual(result.count, 1)
    }
    func testBusyCancellationBeforeAndDuringPacingDispatchNothing() async throws {
        let lease = SearXNGFixtureLease(), gate = SearXNGRequestGate(minimumInterval: .seconds(1))
        let provider = try provider(gate: gate, lease: lease)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await provider.search(query: "cancel-before", limit: 1) }
        do { _ = try await cancelled.value; XCTFail("Pre-cancel succeeded") } catch is CancellationError { }
        XCTAssertTrue(SearXNGFixture.requests("cancel-before").isEmpty)
        _ = try await provider.search(query: "pacing-start", limit: 1)
        let pacing = Task { try await provider.search(query: "cancel-pacing", limit: 1) }
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await provider.search(query: "busy-pacing", limit: 1); XCTFail("Pacing did not hold single-flight") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        pacing.cancel()
        do { _ = try await pacing.value; XCTFail("Cancelled pacing succeeded") } catch is CancellationError { }
        XCTAssertTrue(SearXNGFixture.requests("cancel-pacing").isEmpty)
        XCTAssertTrue(SearXNGFixture.requests("busy-pacing").isEmpty)
        let cancellations = await lease.cancellations; XCTAssertEqual(cancellations, 0)
        _ = try await provider.search(query: "explicit-after-pacing", limit: 1)
    }
    func testInFlightCancellationDropsResultsStopsOwnedLaunchAndReleasesSingleFlight() async throws {
        let lease = SearXNGFixtureLease(), provider = try provider(lease: lease)
        let count = SearXNGFixture.requests("delay-cancel").count
        let task = Task { try await provider.search(query: "delay-cancel", limit: 1) }
        await waitForRequest("delay-cancel", after: count)
        do { _ = try await provider.search(query: "busy-network", limit: 1); XCTFail("Overlapping request started") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled result delivered") } catch is CancellationError { }
        let cancellations = await lease.cancellations; XCTAssertEqual(cancellations, 1)
        _ = try await provider.search(query: "explicit-after-cancel", limit: 1)
        XCTAssertTrue(SearXNGFixture.requests("busy-network").isEmpty)
    }
    func testGenerationRecheckedAfterPacingAndBeforeReturningLateResult() async throws {
        let lease = SearXNGFixtureLease(), provider = try provider(lease: lease)
        let count = SearXNGFixture.requests("delay-stale").count
        let task = Task { try await provider.search(query: "delay-stale", limit: 1) }
        await waitForRequest("delay-stale", after: count); await lease.invalidate()
        do { _ = try await task.value; XCTFail("Stale launch result delivered") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .unavailable) }
        let secondLease = SearXNGFixtureLease()
        let second = try self.provider(gate: SearXNGRequestGate(minimumInterval: .milliseconds(100)), lease: secondLease)
        _ = try await second.search(query: "generation-pacing-start", limit: 1)
        let pacing = Task { try await second.search(query: "generation-pacing-stale", limit: 1) }
        try await Task.sleep(for: .milliseconds(20)); await secondLease.invalidate()
        do { _ = try await pacing.value; XCTFail("Stale lease dispatched after pacing") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .unavailable) }
        XCTAssertTrue(SearXNGFixture.requests("generation-pacing-stale").isEmpty)
    }
    func testIsolatedConfigurationDropsAmbientStateAndDisablesProxyMechanisms() {
        let config = SearXNGSearchNetworkPolicy.isolated(configuration())
        XCTAssertNil(config.identifier); XCTAssertNil(config.urlCache); XCTAssertNil(config.httpAdditionalHeaders)
        XCTAssertNil(config.httpCookieStorage); XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.urlCredentialStorage); XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(config.timeoutIntervalForRequest, 15); XCTAssertEqual(config.timeoutIntervalForResource, 30)
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 1); XCTAssertFalse(config.waitsForConnectivity)
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            XCTAssertEqual(config.connectionProxyDictionary?[key] as? Int, 0)
        }
        XCTAssertNil(config.connectionProxyDictionary?["HTTPProxy"])
    }
    func testRedirectsAndEveryAuthenticationChallengeAreDenied() throws {
        let policy = SearXNGSearchNetworkPolicy(), session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try endpoint().url, task = session.dataTask(with: origin)
        for destination in ["http://127.0.0.1:42981/next", "http://127.0.0.1:42982/search", "https://example.org/steal"] {
            let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination])!
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: destination)!)) { XCTAssertNil($0) }
        }
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodServerTrust] {
            let space = URLProtectionSpace(host: "127.0.0.1", port: 42981, protocol: "http", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space,
                proposedCredential: URLCredential(user: "ambient", password: "secret", persistence: .none),
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: SearXNGChallengeSender())
            policy.urlSession(session, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential)
            }
            policy.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, .cancelAuthenticationChallenge); XCTAssertNil(credential)
            }
        }
    }
}

private actor SearXNGAdmissionFixture {
    private(set) var calls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        calls += 1
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
    }
}

extension SearXNGSearchProviderTests {
    func testAdmissionHookHoldsExistingGateBeforeAnyHTTPDispatch() async throws {
        let hook = SearXNGAdmissionFixture()
        let lease = SearchGenerationLease()
        let provider = try SearXNGSearchProvider(endpoint: endpoint(), gate: SearXNGRequestGate(minimumInterval: .zero),
            isCurrentGeneration: { _ in true }, onCancellation: { _ in }, cancellationLease: lease,
            beforeDispatch: { await hook.enter() }, configuration: configuration())
        let query = "admission-before-dispatch", before = SearXNGFixture.requests("admission-before-dispatch").count
        let first = Task { try await provider.searchResponse(query: query, limit: 1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await hook.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        let calls = await hook.calls; XCTAssertEqual(calls, 1)
        XCTAssertEqual(SearXNGFixture.requests(query).count, before)
        do { _ = try await provider.searchResponse(query: "admission-concurrent", limit: 1); XCTFail("Hook lost gate reservation") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        await hook.release()
        _ = try await first.value
        XCTAssertEqual(SearXNGFixture.requests(query).count, before + 1)
        let finalCalls = await hook.calls; XCTAssertEqual(finalCalls, 1)
    }

    func testLeaseRevocationDuringAdmissionHookDispatchesNothing() async throws {
        let hook = SearXNGAdmissionFixture(), lease = SearchGenerationLease()
        let provider = try SearXNGSearchProvider(endpoint: endpoint(), gate: SearXNGRequestGate(minimumInterval: .zero),
            isCurrentGeneration: { _ in true }, onCancellation: { _ in }, cancellationLease: lease,
            beforeDispatch: { await hook.enter() }, configuration: configuration())
        let query = "admission-revoked", before = SearXNGFixture.requests("admission-revoked").count
        let search = Task { try await provider.searchResponse(query: query, limit: 1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await hook.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        lease.invalidate()
        await hook.release()
        do { _ = try await search.value; XCTFail("Revoked admission dispatched") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .unavailable) }
        XCTAssertEqual(SearXNGFixture.requests(query).count, before)
    }

    func testFailedAdmissionHookAndCooldownDoNotDispatchOrRearm() async throws {
        let hook = SearXNGAdmissionFixture()
        await hook.release()
        let gate = SearXNGRequestGate(minimumInterval: .zero, maximumWait: .zero)
        let provider = try SearXNGSearchProvider(endpoint: endpoint(), gate: gate,
            isCurrentGeneration: { _ in true }, onCancellation: { _ in },
            beforeDispatch: { await hook.enter(); throw SearXNGSearchError.unavailable }, configuration: configuration())
        let query = "admission-failed", before = SearXNGFixture.requests("admission-failed").count
        do { _ = try await provider.search(query: query, limit: 1); XCTFail("Failed admission dispatched") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .unavailable) }
        let calls = await hook.calls; XCTAssertEqual(calls, 1)
        _ = await gate.imposeCooldown(retryAfter: "9999999999999999999999999999")
        do { _ = try await provider.search(query: query, limit: 1); XCTFail("Cooldown invoked hook") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .cooldown(until: nil)) }
        let finalCalls = await hook.calls; XCTAssertEqual(finalCalls, 1)
        XCTAssertEqual(SearXNGFixture.requests(query).count, before)
    }

    func testGenerationLeaseCancelsInFlightSessionWithoutCallerCancellation() async throws {
        let lease = SearchGenerationLease()
        let provider = try SearXNGSearchProvider(endpoint: endpoint(), gate: SearXNGRequestGate(minimumInterval: .zero),
            isCurrentGeneration: { _ in lease.isValid }, onCancellation: { _ in }, cancellationLease: lease,
            configuration: configuration())
        let query = "delay-lease-revocation", before = SearXNGFixture.requests("delay-lease-revocation").count
        let search = Task { try await provider.search(query: query, limit: 1) }
        await waitForRequest(query, after: before)
        lease.invalidate()
        do { _ = try await search.value; XCTFail("Revoked lease returned a response") }
        catch { XCTAssertTrue(error is CancellationError || error as? SearXNGSearchError == .unavailable) }
        XCTAssertFalse(search.isCancelled)
    }
}
