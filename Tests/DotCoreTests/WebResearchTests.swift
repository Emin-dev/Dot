import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

private actor ResearchSearchFixture: WebSearchProvider {
    nonisolated let providerID: String
    nonisolated let permitsResultPersistence: Bool
    var calls: [String] = []
    var fail: Set<String> = []
    var custom: [String: [WebSearchResult]] = [:]
    var hold: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init(id: String = "fixture", retention: Bool = true) { providerID = id; permitsResultPersistence = retention }
    func configure(fail: Set<String> = [], hold: String? = nil, custom: [String: [WebSearchResult]] = [:]) {
        self.fail = fail; self.hold = hold; self.custom = custom
    }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        calls.append(query)
        if hold == query { await withCheckedContinuation { continuation = $0 } }
        if fail.contains(query) { throw URLError(.notConnectedToInternet) }
        return custom[query] ?? [WebSearchResult(url: URL(string: "https://example.org/\(query)")!, title: query,
                                               snippet: "Search snippet is not source evidence.", publicationDateHint: Date(timeIntervalSince1970: 123))]
    }
    func waiting() -> Bool { continuation != nil }
    func release() { hold = nil; continuation?.resume(); continuation = nil }
}

private actor ResearchReadFixture: WebResearchSourceReading {
    var calls: [URL] = []
    var fail: Set<String> = []
    var hold: String?
    var text: String?
    var byteCount = 200
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(fail: Set<String> = [], hold: String? = nil, text: String? = nil, byteCount: Int = 200) {
        self.fail = fail; self.hold = hold; self.text = text; self.byteCount = byteCount
    }
    func read(_ url: URL) async throws -> ResearchSource {
        calls.append(url)
        if hold == url.path { await withCheckedContinuation { continuation = $0 } }
        if fail.contains(url.path) { throw ResearchNotebookError.networkFailure }
        return ResearchSource(id: UUID(), originalURL: url, finalURL: url, title: url.lastPathComponent, kind: .webPage,
                              retrievedAt: Date(timeIntervalSince1970: 456), modifiedAt: Date(timeIntervalSince1970: 100),
                              bytesRead: byteCount, sha256: String(repeating: "a", count: 64), pagesRead: nil,
                              text: text ?? "Evidence for \(url.path). Publication 2026-10-01.", truncated: false)
    }
    func waiting() -> Bool { continuation != nil }
    func release() { hold = nil; continuation?.resume(); continuation = nil }
}

private actor ResearchCheckpoints {
    var values: [WebResearchSession] = []
    func save(_ session: WebResearchSession) throws {
        // Exercise the exact serialized checkpoint contract, not an in-memory-only approximation.
        values.append(try WebResearchSession.decodeCheckpoint(session.encodedCheckpoint()))
    }
}

private final class WorkflowPageFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html", "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html><script>ignored()</script><body>Evidence for the public fixture page.</body></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WebResearchTests: XCTestCase {
    private func session(limits: WebResearchLimits = WebResearchLimits(),
                         policy: WebResearchRetryPolicy = .preserveUncertain) throws -> WebResearchSession {
        try WebResearchSession(question: "Public fixture question", queries: ["primary", "secondary"], limits: limits, retryPolicy: policy)
    }
    private func ready(reader: ResearchReadFixture = ResearchReadFixture()) async throws -> WebResearchSession {
        try await WebResearchWorkflow(provider: ResearchSearchFixture(), reader: reader).run(session()) { _ in }
    }
    private func result(_ session: WebResearchSession) -> WebResearchSynthesis {
        let first = session.sources[0], second = session.sources[1]
        let claim1 = WebResearchClaim(id: UUID(), text: "First finding", citationNumbers: [1], confidence: .tentative,
                                     dates: [WebResearchDatedEvidence(kind: .publication, date: Date(timeIntervalSince1970: 1), citationNumber: 1)])
        let claim2 = WebResearchClaim(id: UUID(), text: "Second finding", citationNumbers: [2], confidence: .uncertain, dates: [])
        return WebResearchSynthesis(answer: "The sources differ [1] [2].", claims: [claim1, claim2],
                                    citations: [WebResearchCitation(number: 1, sourceID: first.id, excerpt: "Evidence for"),
                                                WebResearchCitation(number: 2, sourceID: second.id, excerpt: "Evidence for")],
                                    conflicts: [WebResearchConflict(id: UUID(), claimIDs: [claim1.id, claim2.id], explanation: "Unresolved fixture conflict", resolution: nil)],
                                    followUpQueries: ["third"])
    }
    private func waitFor(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Fixture did not reach its barrier"); throw URLError(.timedOut)
    }

    func testSessionRejectsDuplicateUnboundedAndSingleQueryPlans() throws {
        XCTAssertThrowsError(try WebResearchSession(question: "q", queries: ["a", "A"]))
        XCTAssertThrowsError(try WebResearchSession(question: "q", queries: ["a"]))
        XCTAssertThrowsError(try WebResearchSession(question: "", queries: ["a", "b"]))
        var limits = WebResearchLimits(); limits.maxSources = 100
        XCTAssertThrowsError(try session(limits: limits))
        XCTAssertThrowsError(try WebResearchSession.decodeCheckpoint(Data("broken".utf8)))
    }

    func testSearchAndActualReadsCheckpointBeforeCallsAndReachSynthesisBarrier() async throws {
        let search = ResearchSearchFixture(), reader = ResearchReadFixture(), checkpoints = ResearchCheckpoints()
        let workflow = WebResearchWorkflow(provider: search, reader: reader)
        let finished = try await workflow.run(session()) { try await checkpoints.save($0) }
        XCTAssertEqual(finished.stage, .awaitingLocalSynthesis)
        XCTAssertNil(finished.synthesis)
        XCTAssertEqual(finished.searchAttempts, 2)
        XCTAssertEqual(finished.sources.count, 2)
        XCTAssertEqual(finished.sources[0].retrievedAt, Date(timeIntervalSince1970: 456))
        XCTAssertEqual(finished.sources[0].modifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(finished.queries[0].results[0].publicationDateHint, Date(timeIntervalSince1970: 123))
        let saved = await checkpoints.values
        XCTAssertTrue(saved.contains { $0.queries[0].status == .inFlight && $0.sources.isEmpty })
        XCTAssertTrue(saved.contains { $0.reads.first?.status == .inFlight && $0.sources.isEmpty })
        XCTAssertEqual(try WebResearchSession.decodeCheckpoint(finished.encodedCheckpoint()), finished)
    }

    func testCitationCompletionKeepsConflictsAndDatesSeparateFromReadDates() async throws {
        let fetched = try await ready()
        let completed = try fetched.completing(with: result(fetched))
        XCTAssertEqual(completed.stage, .completed)
        XCTAssertNil(completed.synthesis?.conflicts.first?.resolution)
        XCTAssertEqual(completed.synthesis?.claims.first?.dates.first?.date, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(completed.sources.first?.retrievedAt, Date(timeIntervalSince1970: 456))
        XCTAssertEqual(try WebResearchSession.decodeCheckpoint(completed.encodedCheckpoint()), completed)
    }

    func testSearchSnippetUnknownSourcesAndInventedMarkersCannotBecomeCitations() async throws {
        let fetched = try await ready(), valid = result(fetched)
        for citation in [WebResearchCitation(number: 1, sourceID: fetched.sources[0].id, excerpt: "Search snippet is not source evidence."),
                         WebResearchCitation(number: 1, sourceID: UUID(), excerpt: "Evidence for")] {
            let bad = WebResearchSynthesis(answer: valid.answer, claims: valid.claims, citations: [citation, valid.citations[1]], conflicts: [], followUpQueries: [])
            XCTAssertThrowsError(try fetched.completing(with: bad))
        }
        let wrongMarker = WebResearchSynthesis(answer: "Finding [99]", claims: valid.claims, citations: valid.citations, conflicts: [], followUpQueries: [])
        XCTAssertThrowsError(try fetched.completing(with: wrongMarker))
        let oversizedMarker = WebResearchSynthesis(answer: "[1] [2] [999999999999999999999999999999999999]", claims: valid.claims, citations: valid.citations, conflicts: [], followUpQueries: [])
        XCTAssertThrowsError(try fetched.completing(with: oversizedMarker))
        let wrongDate = WebResearchClaim(id: UUID(), text: "claim", citationNumbers: [1, 2], confidence: .uncertain,
                                        dates: [WebResearchDatedEvidence(kind: .event, date: Date(), citationNumber: 99)])
        XCTAssertThrowsError(try fetched.completing(with: WebResearchSynthesis(answer: valid.answer, claims: [wrongDate], citations: valid.citations, conflicts: [], followUpQueries: [])))
    }

    func testForegroundPauseDropsLateSearchAndPreservesUncertainSpendWithoutRepeating() async throws {
        let search = ResearchSearchFixture(), workflow = WebResearchWorkflow(provider: search, reader: ResearchReadFixture())
        await search.configure(hold: "primary")
        let initial = try session()
        let task = Task { try await workflow.run(initial) { _ in } }
        try await waitFor { await search.waiting() }
        await workflow.pause(); await search.release()
        let paused = try await task.value
        XCTAssertEqual(paused.stage, .paused)
        XCTAssertEqual(paused.queries[0].status, .uncertain)
        XCTAssertEqual(paused.queries[0].failure, .interruptedOutcomeUnknown)
        XCTAssertTrue(paused.queries[0].results.isEmpty)
        let resumed = try await workflow.run(paused) { _ in }
        let calls = await search.calls
        XCTAssertEqual(calls, ["primary", "secondary"])
        XCTAssertEqual(resumed.stage, .paused)
        XCTAssertEqual(resumed.searchAttempts, 2)
    }

    func testConfiguredRetryUsesPersistedAttemptCapAndNeverRepeatsCompletedQuery() async throws {
        let search = ResearchSearchFixture(), workflow = WebResearchWorkflow(provider: search, reader: ResearchReadFixture())
        var checkpoint = try session(policy: .retryUncertainWithinBudget)
        checkpoint.queries[0].status = .inFlight; checkpoint.queries[0].attempts = 1
        let resumed = try await workflow.run(checkpoint) { _ in }
        XCTAssertEqual(resumed.stage, .awaitingLocalSynthesis)
        XCTAssertEqual(resumed.searchAttempts, 3)
        _ = try await workflow.run(resumed) { _ in }
        let calls = await search.calls
        XCTAssertEqual(calls, ["primary", "secondary"])
    }

    func testBudgetCannotBeResetByInterruptedCheckpointResume() async throws {
        var limits = WebResearchLimits(); limits.maxSearchAttempts = 2
        var checkpoint = try session(limits: limits, policy: .retryUncertainWithinBudget)
        checkpoint.queries[0].status = .inFlight; checkpoint.queries[0].attempts = 2
        let search = ResearchSearchFixture()
        let resumed = try await WebResearchWorkflow(provider: search, reader: ResearchReadFixture()).run(checkpoint) { _ in }
        let calls = await search.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(resumed.stage, .paused)
        XCTAssertEqual(resumed.queries[1].failure, .budget)
    }

    func testPausedSourceResumesWithoutRepeatingSearchOrKeepingLateSourceReceipt() async throws {
        let search = ResearchSearchFixture(), reader = ResearchReadFixture()
        await reader.configure(hold: "/primary")
        let workflow = WebResearchWorkflow(provider: search, reader: reader), initial = try session()
        let task = Task { try await workflow.run(initial) { _ in } }
        try await waitFor { await reader.waiting() }
        await workflow.pause(); await reader.release()
        let paused = try await task.value
        XCTAssertTrue(paused.sources.isEmpty)
        let resumed = try await workflow.run(paused) { _ in }
        let searches = await search.calls, reads = await reader.calls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(reads.map(\.path), ["/primary", "/primary", "/secondary"])
        XCTAssertEqual(resumed.sources.count, 2)
    }

    func testCallerTaskCancellationCannotAcceptLateSource() async throws {
        let reader = ResearchReadFixture(); await reader.configure(hold: "/primary")
        let workflow = WebResearchWorkflow(provider: ResearchSearchFixture(), reader: reader), initial = try session()
        let task = Task { try await workflow.run(initial) { _ in } }
        try await waitFor { await reader.waiting() }
        task.cancel(); await reader.release()
        let paused = try await task.value
        XCTAssertEqual(paused.stage, .paused); XCTAssertTrue(paused.sources.isEmpty)
    }

    func testCheckpointFailurePreventsExternalRequests() async throws {
        let search = ResearchSearchFixture(), workflow = WebResearchWorkflow(provider: search, reader: ResearchReadFixture())
        do { _ = try await workflow.run(session()) { _ in throw CocoaError(.fileWriteNoPermission) }; XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? WebResearchError, .checkpointFailed) }
        let calls = await search.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testProviderFailureContinuesOtherQueriesWithoutAutomaticFailureRetry() async throws {
        let search = ResearchSearchFixture(); await search.configure(fail: ["primary"])
        let workflow = WebResearchWorkflow(provider: search, reader: ResearchReadFixture())
        let failed = try await workflow.run(session()) { _ in }
        XCTAssertEqual(failed.queries[0].failure, .provider)
        XCTAssertEqual(failed.sources.count, 1)
        _ = try await workflow.run(failed) { _ in }
        let calls = await search.calls; XCTAssertEqual(calls.count, 2)
        let dummy = WebResearchSynthesis(answer: "answer", claims: [], citations: [], conflicts: [], followUpQueries: [])
        XCTAssertThrowsError(try failed.completing(with: dummy))
    }

    func testSourceFailureDoesNotClaimSourceWasRead() async throws {
        let reader = ResearchReadFixture(); await reader.configure(fail: ["/secondary"])
        let fetched = try await ready(reader: reader)
        XCTAssertEqual(fetched.reads[1].status, .failed)
        XCTAssertNil(fetched.reads[1].source)
        XCTAssertEqual(fetched.sources.count, 1)
    }

    func testResultsAreDeduplicatedAndRoundRobinReadBudgetIsHonest() async throws {
        let search = ResearchSearchFixture(), reader = ResearchReadFixture()
        func hit(_ path: String) -> WebSearchResult { WebSearchResult(url: URL(string: "https://example.org/\(path)")!, title: path, snippet: "", publicationDateHint: nil) }
        await search.configure(custom: ["primary": [hit("shared#one"), hit("shared#two"), hit("extra1")], "secondary": [hit("shared"), hit("extra2")]])
        var limits = WebResearchLimits(); limits.maxSources = 2
        let fetched = try await WebResearchWorkflow(provider: search, reader: reader).run(session(limits: limits)) { _ in }
        XCTAssertEqual(fetched.sources.count, 2)
        XCTAssertEqual(fetched.unreadResultCount, 1)
        XCTAssertEqual(fetched.queries[0].results.count, 2)
        let calls = await reader.calls; XCTAssertEqual(calls.map(\.path), ["/shared", "/extra1"])
    }

    func testUnboundedOrPrivateResultsRejectedBeforeSourceReader() async throws {
        let search = ResearchSearchFixture(), reader = ResearchReadFixture()
        let privateHit = WebSearchResult(url: URL(string: "http://127.0.0.1/secrets")!, title: "bad", snippet: "", publicationDateHint: nil)
        await search.configure(custom: ["primary": [privateHit]])
        let fetched = try await WebResearchWorkflow(provider: search, reader: reader).run(session()) { _ in }
        XCTAssertEqual(fetched.queries[0].failure, .provider)
        let calls = await reader.calls; XCTAssertEqual(calls.map(\.path), ["/secondary"])
    }

    func testBoundedEvidenceEnvelopeLabelsUntrustedSourcesAndExcludesSearchSnippets() async throws {
        let fetched = try await ready(), text = try fetched.evidenceJSON()
        XCTAssertTrue(text.contains("Untrusted source data"))
        XCTAssertFalse(text.contains("Search snippet is not source evidence"))
        XCTAssertTrue(text.contains("modifiedAt"))
        XCTAssertThrowsError(try fetched.evidenceJSON(maxBytes: 10))
        let reader = ResearchReadFixture(); await reader.configure(text: String(repeating: "x", count: 10_000))
        let long = try await ready(reader: reader)
        XCTAssertThrowsError(try long.evidenceJSON(maxBytes: 4_096))
        XCTAssertTrue(try long.evidenceJSON().contains("extractShortened"))
    }

    func testFollowUpQueriesPreserveReceiptsAndClearPriorSynthesis() async throws {
        let search = ResearchSearchFixture(), workflow = WebResearchWorkflow(provider: search, reader: ResearchReadFixture())
        let first = try await workflow.run(session()) { _ in }
        let completed = try first.completing(with: result(first))
        let followUp = try completed.addingQueries(["third"])
        XCTAssertNil(followUp.synthesis); XCTAssertEqual(followUp.stage, .planned)
        let final = try await workflow.run(followUp) { _ in }
        let calls = await search.calls; XCTAssertEqual(calls, ["primary", "secondary", "third"])
        XCTAssertEqual(final.sources.count, 3)
        XCTAssertEqual(final.sources[0], first.sources[0])
        XCTAssertThrowsError(try final.addingQueries(["primary"]))
    }

    func testUnconfirmedResultRetentionStopsBeforeAnySavedHitsOrRequests() async throws {
        let search = ResearchSearchFixture(retention: false), checkpoints = ResearchCheckpoints()
        do { _ = try await WebResearchWorkflow(provider: search).run(session()) { try await checkpoints.save($0) }; XCTFail("Expected storage rights gate") }
        catch { XCTAssertEqual(error as? WebResearchError, .resultRetentionUnavailable) }
        let calls = await search.calls, saved = await checkpoints.values
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(saved.isEmpty)
    }

    func testConcurrentRunRejectedAndProviderCannotChangeMidSession() async throws {
        let search = ResearchSearchFixture(); await search.configure(hold: "primary")
        let workflow = WebResearchWorkflow(provider: search, reader: ResearchReadFixture()), initial = try session()
        let task = Task { try await workflow.run(initial) { _ in } }
        try await waitFor { await search.waiting() }
        do { _ = try await workflow.run(initial) { _ in }; XCTFail("Expected single owner") }
        catch { XCTAssertEqual(error as? WebResearchError, .busy) }
        await workflow.pause(); await search.release()
        let paused = try await task.value
        do { _ = try await WebResearchWorkflow(provider: ResearchSearchFixture(id: "other")).run(paused) { _ in }; XCTFail("Expected provider mismatch") }
        catch { XCTAssertEqual(error as? WebResearchError, .invalidSession) }
    }

    func testExistingNativeReaderIntegrationProducesHashedPageEvidence() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WorkflowPageFixture.self]
        let workflow = WebResearchWorkflow(provider: ResearchSearchFixture(), reader: ResearchWebReader(configuration: configuration))
        let fetched = try await workflow.run(session()) { _ in }
        XCTAssertEqual(fetched.sources.count, 2)
        XCTAssertTrue(fetched.sources.allSatisfy { $0.text.contains("Evidence for") && !$0.text.contains("ignored()") })
        XCTAssertEqual(fetched.sources[0].sha256.count, 64)
        XCTAssertEqual(fetched.sources[0].modifiedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(try fetched.evidenceJSON().contains("2023-11-14T22:13:20Z"))
        XCTAssertEqual(try fetched.completing(with: result(fetched)).stage, .completed)
    }

    func testCorruptReceiptCannotResumeOrIssueNewRequests() async throws {
        let fetched = try await ready()
        var corrupt = fetched
        corrupt.reads[0].status = .pending // a pending read cannot already contain source evidence
        XCTAssertThrowsError(try corrupt.encodedCheckpoint())
        let data = try JSONEncoder().encode(corrupt)
        XCTAssertThrowsError(try WebResearchSession.decodeCheckpoint(data))
        let search = ResearchSearchFixture()
        do { _ = try await WebResearchWorkflow(provider: search).run(corrupt) { _ in }; XCTFail("Expected invalid receipt") }
        catch { XCTAssertEqual(error as? WebResearchError, .invalidSession) }
        let calls = await search.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testCombinedSourceTextBudgetDoesNotStoreOversizedReceipt() async throws {
        var limits = WebResearchLimits(); limits.maxSourceTextBytes = 1_024
        let reader = ResearchReadFixture(); await reader.configure(text: String(repeating: "x", count: 700))
        let fetched = try await WebResearchWorkflow(provider: ResearchSearchFixture(), reader: reader).run(session(limits: limits)) { _ in }
        XCTAssertEqual(fetched.sources.count, 1)
        XCTAssertEqual(fetched.reads[1].failure, .budget)
        XCTAssertNil(fetched.reads[1].source)
        XCTAssertNoThrow(try fetched.encodedCheckpoint())
    }

    func testMalformedReaderByteCountCannotOverflowAggregateBudget() async throws {
        let reader = ResearchReadFixture(); await reader.configure(byteCount: Int.max)
        let fetched = try await ready(reader: reader)
        XCTAssertTrue(fetched.sources.isEmpty)
        XCTAssertTrue(fetched.reads.allSatisfy { $0.status == .failed && $0.failure == .source })
    }
}
