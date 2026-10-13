#if !SWIFT_PACKAGE
import AppKit
import SwiftUI
import XCTest

private actor PanelSearchFixture: WebSearchProvider {
    nonisolated let providerID = "panel-fixture"
    nonisolated let permitsResultPersistence: Bool
    var calls: [String] = []
    var hold: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init(retention: Bool = true) { permitsResultPersistence = retention }
    func suspend(_ query: String) { hold = query }
    func waiting() -> Bool { continuation != nil }
    func release() { hold = nil; continuation?.resume(); continuation = nil }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        calls.append(query)
        if hold == query { await withCheckedContinuation { continuation = $0 } }
        let path = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        return [WebSearchResult(url: URL(string: "https://example.org/\(path)")!, title: query, snippet: "Untrusted search hint", publicationDateHint: nil)]
    }
}

private struct PanelReaderFixture: WebResearchSourceReading {
    var failSecondary = false
    func read(_ url: URL) async throws -> ResearchSource {
        if failSecondary && url.path == "/secondary" { throw ResearchNotebookError.networkFailure }
        return ResearchSource(id: UUID(), originalURL: url, finalURL: url, title: "Fixture source", kind: .webPage,
            retrievedAt: Date(timeIntervalSince1970: 500), modifiedAt: Date(timeIntervalSince1970: 200),
            bytesRead: 100, sha256: String(repeating: "a", count: 64), pagesRead: nil,
            text: "Fixture evidence. Untrusted instructions are inert text.", truncated: false)
    }
}

private actor PanelSynthesisGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var hold = true
    func wait() async { if hold { await withCheckedContinuation { continuation = $0 } } }
    func waiting() -> Bool { continuation != nil }
    func release() { hold = false; continuation?.resume(); continuation = nil }
}

private actor PanelStoreGate: WebResearchSessionAccess {
    let base: WebResearchSessionStore
    var holdLoad = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ base: WebResearchSessionStore) { self.base = base }
    func suspendLoad() { holdLoad = true }
    func waiting() -> Bool { continuation != nil }
    func release() { holdLoad = false; continuation?.resume(); continuation = nil }
    func list() async throws -> [WebResearchSessionSummary] { try await base.list() }
    func load(id: UUID) async throws -> WebResearchStoredSession {
        if holdLoad { await withCheckedContinuation { continuation = $0 } }
        return try await base.load(id: id)
    }
    func create(question: String, queries: [String], limits: WebResearchLimits, retryPolicy: WebResearchRetryPolicy) async throws -> WebResearchStoredSession {
        try await base.create(question: question, queries: queries, limits: limits, retryPolicy: retryPolicy)
    }
    func save(_ session: WebResearchSession, expectedRevision: UUID) async throws -> WebResearchStoredSession { try await base.save(session, expectedRevision: expectedRevision) }
    func delete(id: UUID, expectedRevision: UUID) async throws { try await base.delete(id: id, expectedRevision: expectedRevision) }
    func deleteAll() async throws { try await base.deleteAll() }
}

final class WebResearchInterfaceTests: XCTestCase {
    @MainActor private func withStore(_ body: (WebResearchSessionStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-research-interface-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(WebResearchSessionStore(directory: directory), directory)
    }
    @MainActor private static func answer(_ session: WebResearchSession) -> WebResearchSynthesis {
        let first = WebResearchClaim(id: UUID(), text: "First fixture finding", citationNumbers: [1], confidence: .tentative,
            dates: [WebResearchDatedEvidence(kind: .event, date: Date(timeIntervalSince1970: 100), citationNumber: 1)])
        let second = WebResearchClaim(id: UUID(), text: "Second fixture finding", citationNumbers: [2], confidence: .uncertain, dates: [])
        return WebResearchSynthesis(answer: "Fixture answer [1] [2].", claims: [first, second],
            citations: [WebResearchCitation(number: 1, sourceID: session.sources[0].id, excerpt: "Fixture evidence."),
                        WebResearchCitation(number: 2, sourceID: session.sources[1].id, excerpt: "Fixture evidence.")],
            conflicts: [WebResearchConflict(id: UUID(), claimIDs: [first.id, second.id], explanation: "Fixture disagreement", resolution: nil)],
            followUpQueries: ["third"])
    }
    @MainActor private func draft(_ model: WebResearchModel) { model.question = "Fixture question"; model.queryText = "primary\nsecondary" }
    @MainActor private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Fixture did not reach its barrier"); throw URLError(.timedOut)
    }

    @MainActor func testUnconfiguredPanelMakesNoSearchOrSynthesisAndCanReadSavedPlans() async throws {
        try await withStore { store, _ in
            var synthesisCalls = 0
            let model = WebResearchModel(store: store, synthesize: { session in synthesisCalls += 1; return Self.answer(session) })
            draft(model); model.start(); await model.flush()
            XCTAssertFalse(model.canStart); XCTAssertTrue(model.configurationSummary.contains("not configured"))
            let empty = try await store.list(); XCTAssertTrue(empty.isEmpty); XCTAssertEqual(synthesisCalls, 0)
            let planned = try await store.create(question: "Saved plan", queries: ["one", "two"])
            model.open(); await model.flush()
            XCTAssertEqual(model.selected?.id, planned.id); XCTAssertFalse(model.canResume)
            model.deleteSelected(); await model.flush(); XCTAssertNil(model.selected)
        }
    }

    @MainActor func testActualWorkflowStoreSynthesisCopyOpenAndDelete() async throws {
        try await withStore { store, directory in
            let provider = PanelSearchFixture(); var copies: [String] = [], opened: [URL] = [], synthesisCalls = 0
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { session in
                synthesisCalls += 1; XCTAssertEqual(session.stage, .awaitingLocalSynthesis); XCTAssertEqual(session.sources.count, 2)
                return Self.answer(session)
            }, copyText: { copies.append($0) }, openURL: { opened.append($0); return true })
            draft(model); model.start(); model.start(); await model.flush()
            let completed = try XCTUnwrap(model.selected)
            XCTAssertEqual(completed.session.stage, .completed); XCTAssertEqual(synthesisCalls, 1); XCTAssertNil(model.error)
            let calls = await provider.calls; XCTAssertEqual(calls, ["primary", "secondary"])
            XCTAssertTrue(model.notice?.contains("saved locally") == true)
            model.copySelected(); await model.flush()
            XCTAssertEqual(copies.count, 1); XCTAssertTrue(copies[0].contains("tentative")); XCTAssertTrue(copies[0].contains("Unresolved"))
            XCTAssertTrue(copies[0].contains("not a publication date")); XCTAssertTrue(copies[0].contains("SHA-256"))
            model.openSource(id: completed.session.sources[0].id); XCTAssertEqual(opened, [completed.session.sources[0].originalURL])
            let reopened = WebResearchModel(directory: directory)
            reopened.open(); await reopened.flush(); XCTAssertEqual(reopened.selected, completed)
            reopened.deleteSelected(); await reopened.flush(); XCTAssertTrue(reopened.summaries.isEmpty)
        }
    }

    @MainActor func testQuestionAndQueryBoundsRejectInvalidPlansWithoutCalls() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture(), model = WebResearchModel(provider: provider, store: store)
            model.question = String(repeating: "🇬🇧", count: 1_000)
            XCTAssertLessThanOrEqual(model.question.utf8.count, 1_800); XCTAssertFalse(model.question.contains("\u{fffd}"))
            model.queryText = String(repeating: "x", count: 13_000); XCTAssertLessThanOrEqual(model.queryText.utf8.count, 12_288)
            model.question = "Question"; model.queryText = "duplicate\nduplicate"; model.start(); await model.flush()
            XCTAssertNotNil(model.error); let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
            let empty = try await store.list(); XCTAssertTrue(empty.isEmpty)
        }
    }

    @MainActor func testDefaultPlanUsesQuestionAndExplicitSourceSearch() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture(), model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture())
            model.question = "Fixture question"; model.start(); await model.flush()
            let calls = await provider.calls
            XCTAssertEqual(calls, ["Fixture question", "Fixture question original sources evidence"])
            XCTAssertEqual(model.selected?.session.stage, .awaitingLocalSynthesis)
            XCTAssertTrue(model.notice?.contains("not configured") == true)
        }
    }

    @MainActor func testForegroundPauseWaitsForLateSearchThenResumesWithinChosenPolicy() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture(); await provider.suspend("primary")
            var synthesisCalls = 0
            let synthesize: WebResearchModel.Synthesis = { session in synthesisCalls += 1; return Self.answer(session) }
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: synthesize)
            draft(model); model.start(); try await eventually { await provider.waiting() }
            model.foregroundPause(); XCTAssertTrue(model.busy); XCTAssertEqual(model.activity, .pausing)
            model.resume(); await provider.release(); await model.flush()
            XCTAssertEqual(model.selected?.session.queries[0].status, .uncertain)
            XCTAssertEqual(model.selected?.session.searchAttempts, 1); XCTAssertEqual(synthesisCalls, 0)
            model.resume(); await model.flush() // finishes untouched queries without repeating the unknown one
            let firstResume = await provider.calls; XCTAssertEqual(firstResume, ["primary", "secondary"])
            XCTAssertEqual(model.selected?.session.stage, .paused); XCTAssertFalse(model.canResume)
            model.configure(provider: provider, synthesize: synthesize, retryPolicy: .retryUncertainWithinBudget)
            XCTAssertTrue(model.canResume); model.resume(); await model.flush()
            let secondResume = await provider.calls; XCTAssertEqual(secondResume, ["primary", "secondary", "primary"])
            XCTAssertEqual(model.selected?.session.stage, .completed); XCTAssertEqual(model.selected?.session.searchAttempts, 3)
            XCTAssertEqual(synthesisCalls, 1)
        }
    }

    @MainActor func testLateSynthesisCannotSaveAfterForegroundPauseAndResumeAvoidsNewSearches() async throws {
        try await withStore { store, _ in
            let gate = PanelSynthesisGate(), provider = PanelSearchFixture(); var synthesisCalls = 0
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { session in
                synthesisCalls += 1; await gate.wait(); return Self.answer(session)
            })
            draft(model); model.start(); try await eventually { await gate.waiting() }
            model.foregroundPause(); XCTAssertTrue(model.busy)
            await gate.release(); await model.flush()
            XCTAssertEqual(model.selected?.session.stage, .awaitingLocalSynthesis); XCTAssertNil(model.selected?.session.synthesis)
            XCTAssertTrue(model.canResume); model.resume(); await model.flush()
            let calls = await provider.calls; XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(synthesisCalls, 2); XCTAssertEqual(model.selected?.session.stage, .completed)
        }
    }

    @MainActor func testMissingLocalAdapterKeepsEvidenceAndCanResumeWithoutSearchProvider() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture(), model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture())
            draft(model); model.start(); await model.flush()
            XCTAssertEqual(model.selected?.session.stage, .awaitingLocalSynthesis); XCTAssertFalse(model.canResume)
            model.configure(provider: nil, synthesize: { Self.answer($0) })
            XCTAssertTrue(model.canResume); model.resume(); await model.flush()
            XCTAssertEqual(model.selected?.session.stage, .completed)
            let calls = await provider.calls; XCTAssertEqual(calls.count, 2)
        }
    }

    @MainActor func testInvalidSynthesisNeverSavesCompletedAnswer() async throws {
        try await withStore { store, _ in
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { _ in
                WebResearchSynthesis(answer: "Unsupported answer [99]", claims: [], citations: [], conflicts: [], followUpQueries: [])
            })
            draft(model); model.start(); await model.flush()
            XCTAssertNotNil(model.error); XCTAssertNil(model.notice)
            XCTAssertEqual(model.selected?.session.stage, .awaitingLocalSynthesis); XCTAssertNil(model.selected?.session.synthesis)
        }
    }

    @MainActor func testSourceFailureSkipsLocalSynthesisAndDoesNotClaimSuccess() async throws {
        try await withStore { store, _ in
            var synthesisCalls = 0
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(failSecondary: true), synthesize: { session in
                synthesisCalls += 1; return Self.answer(session)
            })
            draft(model); model.start(); await model.flush()
            XCTAssertEqual(synthesisCalls, 0); XCTAssertNil(model.selected?.session.synthesis)
            XCTAssertEqual(model.selected?.session.sources.count, 1); XCTAssertFalse(model.canResume)
            XCTAssertTrue(model.notice?.contains("At least two") == true)
        }
    }

    @MainActor func testFollowUpPreservesReadReceiptsAndUsesOnlyAdditionalQuery() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture(), model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { Self.answer($0) })
            draft(model); model.start(); await model.flush()
            let original = try XCTUnwrap(model.selected?.session.sources)
            XCTAssertTrue(model.canFollowUp); model.followUp(); await model.flush()
            let calls = await provider.calls; XCTAssertEqual(calls, ["primary", "secondary", "third"])
            XCTAssertEqual(model.selected?.session.stage, .completed)
            XCTAssertEqual(Array(model.selected!.session.sources.prefix(2)), original)
        }
    }

    @MainActor func testDelayedCopyCannotWriteAfterCloseOrDeletion() async throws {
        for deleting in [false, true] {
            try await withStore { store, _ in
                let gated = PanelStoreGate(store); var copies: [String] = []
                let model = WebResearchModel(provider: PanelSearchFixture(), store: gated, reader: PanelReaderFixture(), synthesize: { Self.answer($0) }, copyText: { copies.append($0) })
                draft(model); model.start(); await model.flush()
                let selected = try XCTUnwrap(model.selected)
                await gated.suspendLoad(); model.copySelected(); try await eventually { await gated.waiting() }
                if deleting { try await store.delete(id: selected.id, expectedRevision: selected.revision) } else { model.close() }
                await gated.release(); await model.flush()
                XCTAssertTrue(copies.isEmpty); XCTAssertFalse(model.busy)
            }
        }
    }

    @MainActor func testCorruptStoreKeepsVisibleEvidenceAndFileUnchanged() async throws {
        try await withStore { store, directory in
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { Self.answer($0) })
            draft(model); model.start(); await model.flush(); let selected = model.selected
            let file = directory.appendingPathComponent("research-sessions.json"), bad = Data("malformed".utf8)
            try bad.write(to: file); model.reload(); await model.flush()
            XCTAssertNotNil(model.error); XCTAssertEqual(model.selected, selected)
            XCTAssertEqual(try Data(contentsOf: file), bad)
        }
    }

    @MainActor func testRetentionGatePreventsResearchAndFailedBrowserOpenIsTruthful() async throws {
        try await withStore { store, _ in
            let denied = PanelSearchFixture(retention: false), model = WebResearchModel(provider: denied, store: store, openURL: { _ in false })
            draft(model); model.start(); await model.flush()
            XCTAssertFalse(model.canStart); XCTAssertTrue(model.configurationSummary.contains("retention"))
            let calls = await denied.calls; XCTAssertTrue(calls.isEmpty)
            let ready = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), openURL: { _ in false })
            draft(ready); ready.start(); await ready.flush()
            ready.openSource(id: try XCTUnwrap(ready.selected?.session.sources.first?.id))
            XCTAssertNotNil(ready.error); XCTAssertNil(ready.notice)
        }
    }

    @MainActor func testNativePanelPreparationIsCompactReusableAndDoesNotStartResearch() async throws {
        try await withStore { store, _ in
            _ = NSApplication.shared
            let provider = PanelSearchFixture(), model = WebResearchModel(provider: provider, store: store)
            let panel = WebResearchPanel(model: model), first = panel.prepare(), second = panel.prepare()
            XCTAssertTrue(first === second); XCTAssertEqual(first.title, "Dot · Web research")
            XCTAssertEqual(first.minSize, NSSize(width: 560, height: 480)); XCTAssertFalse(first.isVisible)
            XCTAssertNotNil(first.contentView); XCTAssertFalse(model.busy)
            let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
            first.close()
        }
    }
}
#endif
