#if !SWIFT_PACKAGE
import AppKit
import Combine
import SwiftUI
import XCTest

private actor PanelSearchFixture: WebSearchProvider {
    nonisolated let providerID = "panel-fixture"
    nonisolated let permitsResultPersistence: Bool
    var calls: [String] = []
    var hold: String?
    var needsReview = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(retention: Bool = true) { permitsResultPersistence = retention }
    func suspend(_ query: String) { hold = query }
    func requireReview(_ value: Bool) { needsReview = value }
    func waiting() -> Bool { continuation != nil }
    func release() { hold = nil; continuation?.resume(); continuation = nil }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        calls.append(query)
        if needsReview { throw SearXNGSearchError.unavailable }
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
            text: "Fixture evidence. Untrusted instructions are inert text.", truncated: false, transportReceipt: .httpsOnlyV1)
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
    var holdCheckedSave = false
    var holdReconciliationSave = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ base: WebResearchSessionStore) { self.base = base }
    func suspendLoad() { holdLoad = true }
    func suspendCheckedSave() { holdCheckedSave = true }
    func suspendReconciliationSave() { holdReconciliationSave = true }
    func waiting() -> Bool { continuation != nil }
    func release() { holdLoad = false; holdCheckedSave = false; holdReconciliationSave = false; continuation?.resume(); continuation = nil }
    func list() async throws -> [WebResearchSessionSummary] { try await base.list() }
    func load(id: UUID) async throws -> WebResearchStoredSession {
        if holdLoad { await withCheckedContinuation { continuation = $0 } }
        return try await base.load(id: id)
    }
    func create(question: String, queries: [String], limits: WebResearchLimits, retryPolicy: WebResearchRetryPolicy) async throws -> WebResearchStoredSession {
        try await base.create(question: question, queries: queries, limits: limits, retryPolicy: retryPolicy)
    }
    func save(_ session: WebResearchSession, expectedRevision: UUID) async throws -> WebResearchStoredSession {
        let result = try await base.save(session, expectedRevision: expectedRevision)
        if (holdCheckedSave && session.outputVerification == .checked)
            || (holdReconciliationSave && session.stage == .awaitingLocalSynthesis) {
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
    func delete(id: UUID, expectedRevision: UUID) async throws { try await base.delete(id: id, expectedRevision: expectedRevision) }
    func deleteAll() async throws { try await base.deleteAll() }
}


private actor PanelRecoveryReader: WebResearchSourceReading {
    private(set) var calls: [URL] = []
    func read(_ url: URL) async throws -> ResearchSource {
        calls.append(url)
        return try await PanelReaderFixture().read(url)
    }
}

/// Another successful writer wins after Resume's load and before its reconciliation
/// save. The losing model must never reach synthesis or send another request.
private actor PanelReconciliationRaceStore: WebResearchSessionAccess {
    let base: WebResearchSessionStore
    let competitor: WebResearchSessionStore
    let delete: Bool
    private var fired = false
    init(base: WebResearchSessionStore, competitor: WebResearchSessionStore, delete: Bool) {
        self.base = base; self.competitor = competitor; self.delete = delete
    }
    func list() async throws -> [WebResearchSessionSummary] { try await base.list() }
    func load(id: UUID) async throws -> WebResearchStoredSession { try await base.load(id: id) }
    func create(question: String, queries: [String], limits: WebResearchLimits, retryPolicy: WebResearchRetryPolicy) async throws -> WebResearchStoredSession {
        try await base.create(question: question, queries: queries, limits: limits, retryPolicy: retryPolicy)
    }
    func save(_ session: WebResearchSession, expectedRevision: UUID) async throws -> WebResearchStoredSession {
        if !fired && session.stage == .awaitingLocalSynthesis {
            fired = true
            if delete { try await competitor.delete(id: session.id, expectedRevision: expectedRevision) }
            else { _ = try await competitor.save(session, expectedRevision: expectedRevision) }
        }
        return try await base.save(session, expectedRevision: expectedRevision)
    }
    func delete(id: UUID, expectedRevision: UUID) async throws { try await base.delete(id: id, expectedRevision: expectedRevision) }
    func deleteAll() async throws { try await base.deleteAll() }
}

private actor ProgressReadbackStore: WebResearchSessionAccess {
    enum Fault { case firstReadRevision, secondReadRevision, thirdReadRevision, fourthReadRevision, checkedSaveFailure, deletionBeforeRefresh }
    let base: WebResearchSessionStore
    let fault: Fault
    private var completed: WebResearchStoredSession?
    private var completedLoads = 0
    init(_ base: WebResearchSessionStore, fault: Fault) { self.base = base; self.fault = fault }
    func list() async throws -> [WebResearchSessionSummary] {
        if fault == .deletionBeforeRefresh, completedLoads > 0, let completed {
            try await base.delete(id: completed.id, expectedRevision: completed.revision)
            self.completed = nil
        }
        return try await base.list()
    }
    func load(id: UUID) async throws -> WebResearchStoredSession {
        let result = try await base.load(id: id)
        if result.session.stage == .completed {
            completedLoads += 1
            if (fault == .firstReadRevision && completedLoads == 1) || (fault == .secondReadRevision && completedLoads == 2)
                || (fault == .thirdReadRevision && completedLoads == 3) || (fault == .fourthReadRevision && completedLoads == 4) {
                return WebResearchStoredSession(revision: UUID(), session: result.session, recoveredAt: result.recoveredAt)
            }
        }
        return result
    }
    func create(question: String, queries: [String], limits: WebResearchLimits, retryPolicy: WebResearchRetryPolicy) async throws -> WebResearchStoredSession {
        try await base.create(question: question, queries: queries, limits: limits, retryPolicy: retryPolicy)
    }
    func save(_ session: WebResearchSession, expectedRevision: UUID) async throws -> WebResearchStoredSession {
        if fault == .checkedSaveFailure && session.outputVerification == .checked { throw WebResearchStoreError.unavailable }
        let result = try await base.save(session, expectedRevision: expectedRevision)
        if session.stage == .completed { completed = result }
        return result
    }
    func delete(id: UUID, expectedRevision: UUID) async throws { try await base.delete(id: id, expectedRevision: expectedRevision) }
    func deleteAll() async throws { try await base.deleteAll() }
}

final class WebResearchInterfaceTests: XCTestCase {
    @MainActor func testHistoricalAnswerCopyReportLabelsUnverifiedTransportWithoutLosingReceipts() async throws {
        let draft = try WebResearchSession(question: "History", queries: ["primary", "secondary"])
        let ready = try await WebResearchWorkflow(provider: PanelSearchFixture(), reader: PanelReaderFixture()).run(draft) { _ in }
        var archive = try ready.completing(with: Self.answer(ready))
        for index in archive.reads.indices { archive.reads[index].source?.transportReceipt = nil }
        let restored = try WebResearchSession.decodeCheckpoint(archive.encodedCheckpoint())
        let report = WebResearchModel.report(restored)
        XCTAssertTrue(report.contains("Unverified web transport"))
        XCTAssertTrue(report.contains(try XCTUnwrap(restored.synthesis).answer))
        for source in restored.sources {
            XCTAssertTrue(report.contains(source.sha256)); XCTAssertTrue(report.contains(source.text))
        }
    }

    @MainActor func testHistoricalHTTPOriginalExplainsRefusalWithoutOpeningOrChangingSavedEvidence() async throws {
        try await withStore { store, directory in
            let initial = try await store.create(question: "Historical original", queries: ["primary", "secondary"])
            let ready = try await WebResearchWorkflow(provider: PanelSearchFixture(), reader: PanelReaderFixture()).run(initial.session) { _ in }
            var historical = try ready.completing(with: Self.answer(ready))
            let original = try XCTUnwrap(historical.reads.first?.source)
            let http = URL(string: "http://example.org/primary")!
            let archived = ResearchSource(id: original.id, originalURL: http, finalURL: http, title: original.title,
                kind: original.kind, retrievedAt: original.retrievedAt, modifiedAt: original.modifiedAt,
                bytesRead: original.bytesRead, sha256: original.sha256, pagesRead: original.pagesRead,
                text: original.text, truncated: original.truncated)
            historical.reads[0] = WebResearchRead(id: historical.reads[0].id, url: http,
                status: .completed, source: archived, failure: nil)
            let result = historical.queries[0].results[0]
            historical.queries[0].results[0] = WebSearchResult(url: http, title: result.title,
                snippet: result.snippet, publicationDateHint: result.publicationDateHint)
            XCTAssertEqual(try WebResearchSession.decodeCheckpoint(historical.encodedCheckpoint()), historical)
            XCTAssertEqual(historical.schemaVersion, 1); XCTAssertNil(archived.transportReceipt)
            XCTAssertFalse(archived.eligibleForSynthesis)
            let saved = WebResearchStoredSession(revision: UUID(), session: historical, recoveredAt: nil)
            struct Archive: Encodable { let schemaVersion = 1; let sessions: [WebResearchStoredSession] }
            let file = directory.appendingPathComponent("research-sessions.json")
            let bytes = try JSONEncoder().encode(Archive(sessions: [saved]))
            try bytes.write(to: file)
            let reader = PanelRecoveryReader()
            var opened: [URL] = [], copies: [String] = []
            let model = WebResearchModel(store: store, reader: reader,
                copyText: { copies.append($0) }, openURL: { opened.append($0); return true })
            model.open(); await model.flush()
            model.select(saved.id); await model.flush()
            XCTAssertFalse(model.configured); XCTAssertFalse(model.busy)
            XCTAssertNil(model.error); XCTAssertEqual(model.selected, saved)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            model.copySelected(); await model.flush()
            XCTAssertEqual(copies.count, 1)
            XCTAssertEqual(model.notice, "Research and source receipts copied.")
            model.question = String(repeating: "x", count: 1_801)
            XCTAssertEqual(model.error, "Please keep the research question within 1,800 UTF-8 bytes.")
            let selected = try XCTUnwrap(model.selected), source = try XCTUnwrap(model.selected?.session.sources.first)
            let attempts = selected.session.searchAttempts, readCount = selected.session.reads.count
            let readsBefore = await reader.calls
            XCTAssertTrue(readsBefore.isEmpty); XCTAssertEqual(source.originalURL, http); XCTAssertEqual(source.finalURL, http)
            XCTAssertNil(source.transportReceipt); XCTAssertEqual(source.text, original.text)
            for _ in 0..<2 {
                model.openSource(id: source.id); await model.flush()
                XCTAssertTrue(opened.isEmpty)
                XCTAssertEqual(model.error, "This stored source cannot be opened safely. Use an HTTPS source in a new research pass.")
                XCTAssertNil(model.notice)
                XCTAssertEqual(model.selected, selected); XCTAssertEqual(model.selected?.revision, saved.revision)
                XCTAssertEqual(model.selected?.session.sources.first, source)
                XCTAssertEqual(model.selected?.session.sources.first?.text, source.text)
                XCTAssertNil(model.selected?.session.sources.first?.transportReceipt)
                XCTAssertEqual(model.selected?.session.searchAttempts, attempts)
                XCTAssertEqual(model.selected?.session.reads.count, readCount)
                XCTAssertEqual(model.selected?.session.limits, selected.session.limits)
                XCTAssertEqual(model.selected?.session.hasAdditionalSourceCapacity, selected.session.hasAdditionalSourceCapacity)
                let readsAfter = await reader.calls
                XCTAssertEqual(readsAfter, readsBefore)
                let reloaded = try await store.load(id: saved.id)
                XCTAssertEqual(reloaded, saved); XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
            let secure = try XCTUnwrap(selected.session.sources.last)
            XCTAssertTrue(secure.eligibleForSynthesis); XCTAssertEqual(secure.originalURL.scheme, "https")
            model.openSource(id: secure.id)
            XCTAssertEqual(opened, [secure.originalURL]); XCTAssertNil(model.error)
            XCTAssertEqual(model.notice, "Requested the original source in your browser.")
            XCTAssertEqual(model.selected, selected); XCTAssertEqual(try Data(contentsOf: file), bytes)
            let readsAfterSecureOpen = await reader.calls
            XCTAssertEqual(readsAfterSecureOpen, readsBefore)
        }
    }

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
    @MainActor private func confirmDelete(_ model: WebResearchModel) {
        guard let prompt = model.requestDeleteSelected() else { return XCTFail("Missing delete confirmation") }
        XCTAssertTrue(model.confirmDeletion(prompt.id))
    }

    @MainActor func testResearchControllerRequiresConfirmationAndRejectsLateClosedSheet() async throws {
        try await withStore { store, _ in
            _ = NSApplication.shared
            _ = try await store.create(question: "Keep this research", queries: ["first", "second"],
                limits: WebResearchLimits(), retryPolicy: .preserveUncertain)
            let model = WebResearchModel(store: store)
            var replies: [LocalRecordDeletionConfirmation.Reply] = []
            let panel = WebResearchPanel(model: model, confirmation: LocalRecordDeletionConfirmation(present: { _, _, reply in replies.append(reply) }))
            panel.show(); await model.flush()
            defer { panel.close() }
            panel.requestDeletion(); XCTAssertEqual(replies.count, 1)
            replies[0](false); await model.flush(); XCTAssertEqual(model.summaries.count, 1)
            panel.requestDeletion(); XCTAssertEqual(replies.count, 2)
            panel.close(); panel.show(); await model.flush()
            replies[1](true); await model.flush(); XCTAssertEqual(model.summaries.count, 1)
            panel.requestDeletion(); XCTAssertEqual(replies.count, 3)
            replies[2](true); await model.flush(); XCTAssertTrue(model.summaries.isEmpty)
        }
    }

    @MainActor func testResearchConfirmationIsSingleUseAndCannotDeleteAChangedRevision() async throws {
        try await withStore { store, _ in
            let saved = try await store.create(question: "First question", queries: ["first", "second"],
                limits: WebResearchLimits(), retryPolicy: .preserveUncertain)
            let model = WebResearchModel(store: store)
            model.open(); await model.flush()
            let cancelled = try XCTUnwrap(model.requestDeleteSelected())
            XCTAssertEqual(model.selected?.id, saved.id)
            model.cancelDeletion(); XCTAssertFalse(model.confirmDeletion(cancelled.id))
            let stale = try XCTUnwrap(model.requestDeleteSelected())
            _ = try await store.save(saved.session, expectedRevision: saved.revision)
            XCTAssertTrue(model.confirmDeletion(stale.id))
            await model.flush()
            XCTAssertNotNil(model.error)
            let preserved = try await store.load(id: saved.id)
            XCTAssertEqual(preserved.id, saved.id)
            model.reload(); await model.flush()
            let closing = try XCTUnwrap(model.requestDeleteSelected())
            model.close(); model.open(); await model.flush()
            XCTAssertFalse(model.confirmDeletion(closing.id))
            let deselected = try XCTUnwrap(model.requestDeleteSelected())
            model.select(nil); XCTAssertFalse(model.confirmDeletion(deselected.id))
            model.select(saved.id); await model.flush()
            let accepted = try XCTUnwrap(model.requestDeleteSelected())
            XCTAssertTrue(model.confirmDeletion(accepted.id)); XCTAssertFalse(model.confirmDeletion(accepted.id))
            await model.flush(); XCTAssertTrue(model.summaries.isEmpty)
        }
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
            XCTAssertFalse(model.canStart); XCTAssertFalse(model.configured)
            XCTAssertTrue(model.configurationSummary.contains("Search is not ready"))
            XCTAssertTrue(model.configurationSummary.contains("Saved research remains available"))
            let empty = try await store.list(); XCTAssertTrue(empty.isEmpty); XCTAssertEqual(synthesisCalls, 0)
            let planned = try await store.create(question: "Saved plan", queries: ["one", "two"])
            model.open(); await model.flush()
            XCTAssertEqual(model.selected?.id, planned.id); XCTAssertFalse(model.canResume)
            confirmDelete(model); await model.flush(); XCTAssertNil(model.selected)
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
            confirmDelete(reopened); await reopened.flush(); XCTAssertTrue(reopened.summaries.isEmpty)
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

    @MainActor func testServiceReviewNeedsExplicitRetryAndPreservesAttemptBudget() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture(); await provider.requireReview(true)
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { Self.answer($0) })
            draft(model); model.start(); await model.flush()
            XCTAssertFalse(model.canResume); XCTAssertTrue(model.canRetryReviewedService)
            XCTAssertEqual(model.selected?.session.searchAttempts, 1)
            await provider.requireReview(false)
            model.resume(); await model.flush()
            let before = await provider.calls; XCTAssertEqual(before, ["primary"])
            model.retryReviewedService(); await model.flush()
            let after = await provider.calls; XCTAssertEqual(after, ["primary", "primary", "secondary"])
            XCTAssertEqual(model.selected?.session.searchAttempts, 3)
            XCTAssertEqual(model.selected?.session.stage, .completed)
            XCTAssertFalse(model.canRetryReviewedService)
        }
    }

    @MainActor func testShutdownCannotReopenWebResearchDuringOrAfterDrain() async throws {
        try await withStore { store, _ in
            _ = NSApplication.shared
            let provider = PanelSearchFixture(); await provider.suspend("primary")
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture())
            let panel = WebResearchPanel(model: model)
            var presentations = 0; panel.onVisibility = { if $0 { presentations += 1 } }
            draft(model); model.start(); try await eventually { await provider.waiting() }
            panel.closeAdmissions(); panel.show(); model.open(); model.start(); model.resume()
            XCTAssertTrue(model.shuttingDown); XCTAssertFalse(model.canStart); XCTAssertFalse(model.canResume)
            var drained = false
            let flush = Task { await model.flush(); drained = true }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(drained)
            await provider.release(); await flush.value
            panel.show(); model.open(); model.start(); model.resume(); await model.flush()
            XCTAssertEqual(presentations, 0)
            let calls = await provider.calls; XCTAssertEqual(calls, ["primary"])
            let saved = try await store.list(); XCTAssertEqual(saved.count, 1)
            XCTAssertFalse(model.canStart); XCTAssertFalse(model.canResume)
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

    @MainActor func testFollowUpAtSourceCapKeepsAnswerRevisionAndMakesNoNewCalls() async throws {
        try await withStore { store, _ in
            var limits = WebResearchLimits(); limits.maxSources = 2
            let provider = PanelSearchFixture()
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(),
                synthesize: { Self.answer($0) }, limits: limits)
            draft(model); model.start(); await model.flush()
            let original = try XCTUnwrap(model.selected)
            XCTAssertEqual(original.session.stage, .completed)
            XCTAssertFalse(model.canFollowUp)
            model.followUp(); await model.flush()
            XCTAssertEqual(model.selected, original)
            let saved = try await store.load(id: original.id); XCTAssertEqual(saved, original)
            let calls = await provider.calls; XCTAssertEqual(calls, ["primary", "secondary"])
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
    @MainActor func testTransientResearchCompletesWithoutDiskWritesClipboardOrRestartRestoration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-transient-canary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var copied: [String] = []
        let provider = PanelSearchFixture(retention: false)
        let model = WebResearchModel(provider: provider, directory: directory, retention: .transient,
            reader: PanelReaderFixture(), synthesize: { Self.answer($0) }, copyText: { copied.append($0) })
        XCTAssertTrue(model.transient); XCTAssertTrue(model.configured)
        XCTAssertTrue(model.configurationSummary.contains("no restart recovery"))
        draft(model); model.start(); await model.flush()
        XCTAssertEqual(model.selected?.session.stage, .completed)
        XCTAssertEqual(model.selected?.session.storageMode, .transient)
        XCTAssertFalse(model.canCopy)
        model.copySelected(); await model.flush(); XCTAssertTrue(copied.isEmpty)
        model.close(); await model.flush(); model.open(); await model.flush()
        XCTAssertEqual(model.selected?.session.stage, .completed, "Memory-only pause can resume within this app lifetime")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let restarted = WebResearchModel(directory: directory, retention: .transient)
        restarted.open(); await restarted.flush(); XCTAssertTrue(restarted.summaries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }


    @MainActor func testProgressFollowsProducerReceiptsThroughReadBack() async throws {
        try await withStore { store, _ in
            var now = 0.0
            var progress = ResearchTaskProgress()
            var changes: [ResearchTaskProgress.Change] = []
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { session in
                now = 121; progress.tick(now: now)
                XCTAssertEqual(progress.progress.state, .running)
                XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
                return Self.answer(session)
            })
            model.onTaskProgress = { event in changes.append(event.change); progress.receive(event, now: now) }
            draft(model); model.start(); await model.flush()
            XCTAssertEqual(model.selected?.session.stage, .completed)
            XCTAssertEqual(progress.progress.halo, .verifiedComplete)
            guard case .completed(let result) = progress.progress.state else { return XCTFail("Missing checked result") }
            XCTAssertEqual(result.evidenceID, model.selected?.revision.uuidString)
            XCTAssertTrue(result.summary.contains("conclusions still require judgment"))
            XCTAssertEqual(changes.filter { if case .started = $0 { return true }; return false }.count, 1)
            XCTAssertEqual(changes.filter { if case .verified = $0 { return true }; return false }.count, 1)
            XCTAssertTrue(changes.contains { if case .verifying = $0 { return true }; return false })
            confirmDelete(model); await model.flush()
            XCTAssertEqual(progress.progress.state, .idle, "Deleting this result clears its completed status")
        }
    }
    @MainActor func testProgressDoesNotCompleteBeforeStoreReadBackReturns() async throws {
        try await withStore { store, _ in
            let gated = PanelStoreGate(store)
            var now = 0.0
            var progress = ResearchTaskProgress()
            let model = WebResearchModel(provider: PanelSearchFixture(), store: gated, reader: PanelReaderFixture(), synthesize: { session in
                now = 121; progress.tick(now: now); await gated.suspendLoad()
                return Self.answer(session)
            })
            model.onTaskProgress = { progress.receive($0, now: now) }
            draft(model); model.start(); try await eventually { await gated.waiting() }
            XCTAssertEqual(progress.progress.snapshot?.phase, .finalVerification)
            XCTAssertEqual(progress.progress.state, .running)
            XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
            await gated.release(); await model.flush()
            XCTAssertEqual(progress.progress.halo, .verifiedComplete)
        }
    }
    @MainActor func testPauseOrStopDuringReadBackResumesOnlyExactVerification() async throws {
        for stop in [false, true] {
            try await withStore { store, _ in
                let gated = PanelStoreGate(store), provider = PanelSearchFixture()
                var now = 0.0, syntheses = 0
                var progress = ResearchTaskProgress()
                var starts: [ResearchTaskProgress.Event] = []
                let model = WebResearchModel(provider: provider, store: gated, reader: PanelReaderFixture(), synthesize: { session in
                    syntheses += 1; now = 121; progress.tick(now: now); await gated.suspendLoad()
                    return Self.answer(session)
                })
                model.onTaskProgress = { event in
                    if case .started = event.change { starts.append(event) }
                    progress.receive(event, now: now)
                }
                draft(model); model.start(); try await eventually { await gated.waiting() }
                if stop { model.cancel() } else { model.foregroundPause() }
                await gated.release(); await model.flush()
                XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
                if stop { XCTAssertEqual(progress.progress.state, .cancelled) }
                else if case .paused = progress.progress.state {} else { XCTFail("Expected paused verification") }
                XCTAssertFalse(model.busy); XCTAssertTrue(model.canResume)
                let expected = try XCTUnwrap(model.selected)
                XCTAssertEqual(expected.session.stage, .completed)
                let callsBefore = await provider.calls

                // An explicit resume performs only the deferred read-back. Old
                // operation callbacks cannot replace this verification attempt.
                await gated.suspendLoad(); model.resume()
                try await eventually { await gated.waiting() }
                XCTAssertEqual(syntheses, 1)
                XCTAssertEqual(progress.progress.state, .running)
                XCTAssertEqual(progress.progress.snapshot?.phase, .finalVerification)
                XCTAssertEqual(starts.count, 2)
                XCTAssertGreaterThan(starts[1].generation, starts[0].generation)
                XCTAssertNotEqual(starts[1].operation, starts[0].operation)
                progress.receive(.init(operation: starts[0].operation, generation: starts[0].generation,
                    sequence: UInt64.max, change: .failed), now: now)
                XCTAssertEqual(progress.progress.state, .running)
                XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
                await gated.release(); await model.flush()
                let callsAfter = await provider.calls
                XCTAssertEqual(callsAfter, callsBefore); XCTAssertEqual(syntheses, 1)
                XCTAssertEqual(model.selected?.session.synthesis, expected.session.synthesis, "Retry cannot replace the answer")
                XCTAssertEqual(model.selected?.session.outputVerification, .checked)
                XCTAssertEqual(progress.progress.halo, .verifiedComplete)
                XCTAssertFalse(model.canResume); XCTAssertFalse(model.busy)
                XCTAssertNil(model.error)
            }
        }
    }
    @MainActor func testResumedVerificationRejectsAChangedSavedRevision() async throws {
        try await withStore { store, _ in
            let gated = PanelStoreGate(store)
            var now = 0.0, syntheses = 0
            var progress = ResearchTaskProgress()
            let model = WebResearchModel(provider: PanelSearchFixture(), store: gated, reader: PanelReaderFixture(), synthesize: { session in
                syntheses += 1; now = 121; progress.tick(now: now); await gated.suspendLoad()
                return Self.answer(session)
            })
            model.onTaskProgress = { progress.receive($0, now: now) }
            draft(model); model.start(); try await eventually { await gated.waiting() }
            model.foregroundPause(); await gated.release(); await model.flush()
            let expected = try XCTUnwrap(model.selected)
            XCTAssertTrue(model.canResume)
            _ = try await store.save(expected.session, expectedRevision: expected.revision)
            model.resume(); await model.flush()
            XCTAssertEqual(syntheses, 1); XCTAssertNotNil(model.error)
            XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
            guard case .failed = progress.progress.state else { return XCTFail("Changed result must fail closed") }
        }
    }
    @MainActor func testLoadingCompletedAnswerDoesNotOfferVerificationResumeWithoutReceipt() async throws {
        try await withStore { store, _ in
            let writer = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { Self.answer($0) })
            draft(writer); writer.start(); await writer.flush()
            XCTAssertEqual(writer.selected?.session.stage, .completed)
            XCTAssertFalse(writer.canResume)
            let browser = WebResearchModel(store: store)
            var progressEvents = 0
            browser.onTaskProgress = { _ in progressEvents += 1 }
            browser.open(); await browser.flush()
            XCTAssertEqual(browser.selected?.session.stage, .completed)
            XCTAssertFalse(browser.canResume)
            browser.resume(); await browser.flush()
            XCTAssertEqual(progressEvents, 0)
        }
    }
    @MainActor func testInvalidCitationFailsProgressInsteadOfShowingSuccess() async throws {
        try await withStore { store, _ in
            var now = 0.0
            var progress = ResearchTaskProgress()
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { session in
                now = 121; progress.tick(now: now)
                let answer = Self.answer(session)
                return WebResearchSynthesis(answer: answer.answer, claims: answer.claims,
                    citations: [.init(number: 1, sourceID: session.sources[0].id, excerpt: "Fabricated quotation")],
                    conflicts: answer.conflicts, followUpQueries: [])
            })
            model.onTaskProgress = { progress.receive($0, now: now) }
            draft(model); model.start(); await model.flush()
            guard case .failed = progress.progress.state else { return XCTFail("Expected failed verification") }
            XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
            XCTAssertNotNil(model.error)
        }
    }
    @MainActor func testInsufficientSourcesBlockWithActionableReason() async throws {
        try await withStore { store, _ in
            var progress = ResearchTaskProgress()
            let now = 0.0
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(failSecondary: true), synthesize: { Self.answer($0) })
            model.onTaskProgress = { progress.receive($0, now: now) }
            draft(model); model.start(); await model.flush()
            guard case .blocked(let reason) = progress.progress.state else { return XCTFail("Expected evidence blocker") }
            XCTAssertTrue(reason.nextAction.contains("revise the search plan"))
            XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
        }
    }

    @MainActor func testMismatchedOrDeletedFinalReadBackNeverShowsCompleteHalo() async throws {
        for fault in [ProgressReadbackStore.Fault.firstReadRevision, .secondReadRevision, .thirdReadRevision, .fourthReadRevision, .checkedSaveFailure, .deletionBeforeRefresh] {
            try await withStore { base, _ in
                let store = ProgressReadbackStore(base, fault: fault)
                var now = 0.0
                var progress = ResearchTaskProgress()
                var verified = 0
                let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { session in
                    now = 121; progress.tick(now: now); return Self.answer(session)
                })
                model.onTaskProgress = { event in
                    if case .verified = event.change { verified += 1 }
                    progress.receive(event, now: now)
                }
                draft(model); model.start(); await model.flush()
                XCTAssertEqual(verified, 0); XCTAssertNotNil(model.error)
                XCTAssertNotEqual(progress.progress.halo, .verifiedComplete)
                guard case .failed = progress.progress.state else { return XCTFail("Read-back must fail closed") }
            }
        }
    }
    @MainActor private func interruptedTerminalRetrieval(_ store: WebResearchSessionStore,
                                                        unqueued: Bool = false, atSourceCap: Bool = false) async throws -> WebResearchStoredSession {
        var limits = WebResearchLimits()
        if atSourceCap { limits.maxSources = 2 }
        let initial = try await store.create(question: "Reconciliation fixture", queries: ["primary", "secondary"], limits: limits)
        var retrieved = try await WebResearchWorkflow(provider: PanelSearchFixture(), reader: PanelReaderFixture()).run(initial.session) { _ in }
        retrieved.stage = .retrieving
        if unqueued { retrieved.reads = [] }
        if atSourceCap {
            retrieved.queries[0].results.append(WebSearchResult(url: URL(string: "https://example.org/over-cap")!,
                title: "Over cap", snippet: "Untrusted hint", publicationDateHint: nil))
        }
        return try await store.save(retrieved, expectedRevision: initial.revision)
    }

    @MainActor func testExplicitResumeReconcilesTerminalRetrievalBeforeProviderFreeLocalSynthesis() async throws {
        for atSourceCap in [false, true] {
            try await withStore { owner, directory in
                let active = try await interruptedTerminalRetrieval(owner, atSourceCap: atSourceCap)
                let reader = PanelRecoveryReader(), file = directory.appendingPathComponent("research-sessions.json")
                let before = try Data(contentsOf: file)
                var syntheses = 0
                let model = WebResearchModel(directory: directory, reader: reader, synthesize: { session in
                    syntheses += 1
                    let committed = try await owner.load(id: active.id)
                    XCTAssertNotEqual(committed.revision, active.revision)
                    XCTAssertEqual(committed.session, session)
                    XCTAssertEqual(session.stage, .awaitingLocalSynthesis)
                    XCTAssertNotNil(committed.recoveredAt)
                    return Self.answer(session)
                })
                model.open(); await model.flush()
                XCTAssertEqual(model.selected?.revision, active.revision)
                XCTAssertEqual(model.selected?.session.stage, .paused)
                XCTAssertEqual(try Data(contentsOf: file), before)
                XCTAssertTrue(model.canResume); XCTAssertEqual(syntheses, 0)
                let beforeReads = await reader.calls; XCTAssertTrue(beforeReads.isEmpty)
                model.resume(); await model.flush()
                XCTAssertNil(model.error); XCTAssertEqual(syntheses, 1)
                XCTAssertEqual(model.selected?.session.outputVerification, .checked)
                XCTAssertEqual(model.selected?.session.searchAttempts, active.session.searchAttempts)
                XCTAssertEqual(model.selected?.session.sources, active.session.sources)
                let reads = await reader.calls; XCTAssertTrue(reads.isEmpty)
            }
        }
    }

    @MainActor func testExplicitResumeWithTerminalQueriesStillReadsUnqueuedResults() async throws {
        try await withStore { owner, directory in
            let active = try await interruptedTerminalRetrieval(owner, unqueued: true)
            let provider = PanelSearchFixture(), reader = PanelRecoveryReader()
            var syntheses = 0
            let model = WebResearchModel(provider: provider, directory: directory, reader: reader, synthesize: { session in
                syntheses += 1; return Self.answer(session)
            })
            model.open(); await model.flush()
            XCTAssertEqual(model.selected?.revision, active.revision)
            XCTAssertEqual(model.selected?.session.stage, .paused); XCTAssertTrue(model.canResume)
            model.resume(); await model.flush()
            XCTAssertNil(model.error); XCTAssertEqual(syntheses, 1)
            XCTAssertEqual(model.selected?.session.outputVerification, .checked)
            let calls = await provider.calls, reads = await reader.calls
            XCTAssertTrue(calls.isEmpty, "Completed queries must not be replayed")
            XCTAssertEqual(reads.map(\.path), ["/primary", "/secondary"])
        }
    }

    @MainActor func testStopRetainsEvidenceAndReadsUnqueuedResultBeforeSynthesisUnlessAtSourceCap() async throws {
        for atSourceCap in [false, true] {
            try await withStore { owner, directory in
                var limits = WebResearchLimits()
                if atSourceCap { limits.maxSources = 2 }
                let initial = try await owner.create(question: "Retained evidence with unread result",
                    queries: ["primary", "secondary"], limits: limits)
                var retrieved = try await WebResearchWorkflow(provider: PanelSearchFixture(), reader: PanelReaderFixture())
                    .run(initial.session) { _ in }
                retrieved.stage = .retrieving
                // Add the discovered result before the first completed-query save. Later
                // writes must preserve the existing immutable query-result receipts.
                retrieved.queries[0].results.append(WebSearchResult(url: URL(string: "https://example.org/third")!,
                    title: "Third source", snippet: "Untrusted hint", publicationDateHint: nil))
                let active = try await owner.save(retrieved, expectedRevision: initial.revision)
                let retainedSources = active.session.sources, attempts = active.session.searchAttempts
                XCTAssertEqual(retainedSources.count, 2); XCTAssertEqual(active.session.unreadResultCount, 1)
                let provider = PanelSearchFixture(), reader = PanelRecoveryReader()
                var syntheses = 0, armed = false, stopped = false
                let model = WebResearchModel(provider: atSourceCap ? nil : provider, directory: directory,
                    reader: reader, synthesize: { session in
                        syntheses += 1
                        XCTAssertEqual(Array(session.sources.prefix(2)), retainedSources)
                        XCTAssertEqual(session.searchAttempts, attempts)
                        return Self.answer(session)
                    })
                model.open(); await model.flush()
                XCTAssertEqual(model.selected?.session.stage, .paused); XCTAssertTrue(model.canResume)
                // The synchronous publication is an exact barrier: ownership is already
                // bound, but research() has not admitted a source request or synthesis.
                let observation = model.$selected.sink { selected in
                    if armed, !stopped, selected?.id == active.id {
                        stopped = true; model.cancel()
                    }
                }
                defer { observation.cancel() }
                armed = true
                model.resume(); await model.flush()
                XCTAssertTrue(stopped); XCTAssertFalse(model.busy); XCTAssertNil(model.error)
                XCTAssertEqual(syntheses, 0)
                XCTAssertEqual(model.selected?.session.stage, atSourceCap ? .awaitingLocalSynthesis : .paused)
                XCTAssertEqual(model.selected?.session.sources, retainedSources)
                XCTAssertEqual(model.selected?.session.unreadResultCount, 1)
                XCTAssertEqual(model.selected?.session.searchAttempts, attempts)
                XCTAssertEqual(model.selected?.session.queries, active.session.queries)
                let callsBefore = await provider.calls, readsBefore = await reader.calls
                XCTAssertTrue(callsBefore.isEmpty); XCTAssertTrue(readsBefore.isEmpty)
                observation.cancel()
                XCTAssertTrue(model.canResume)
                model.resume(); await model.flush()
                XCTAssertNil(model.error); XCTAssertEqual(syntheses, 1)
                XCTAssertEqual(model.selected?.session.outputVerification, .checked)
                XCTAssertEqual(model.selected?.session.searchAttempts, attempts)
                XCTAssertEqual(model.selected?.session.queries, active.session.queries)
                XCTAssertEqual(Array(try XCTUnwrap(model.selected).session.sources.prefix(2)), retainedSources)
                XCTAssertEqual(model.selected?.session.sources.count, atSourceCap ? 2 : 3)
                XCTAssertEqual(model.selected?.session.unreadResultCount, atSourceCap ? 1 : 0)
                let callsAfter = await provider.calls, readsAfter = await reader.calls
                XCTAssertTrue(callsAfter.isEmpty, "Completed queries must never be replayed or recharge the search budget")
                XCTAssertEqual(readsAfter.map(\.path), atSourceCap ? [] : ["/third"])
            }
        }
    }

    @MainActor func testExplicitResumeRejectsChangedSelectedRevisionBeforeAnyNewWork() async throws {
        for terminal in [false, true] {
            try await withStore { owner, directory in
                let active: WebResearchStoredSession
                if terminal { active = try await interruptedTerminalRetrieval(owner) }
                else { active = try await owner.create(question: "Original plan", queries: ["primary", "secondary"]) }
                let provider = PanelSearchFixture(), reader = PanelRecoveryReader()
                var syntheses = 0, events = 0
                let model = WebResearchModel(provider: provider, directory: directory, reader: reader, synthesize: { session in
                    syntheses += 1; return Self.answer(session)
                })
                model.onTaskProgress = { _ in events += 1 }
                model.open(); await model.flush(); XCTAssertTrue(model.canResume)
                let selected = try XCTUnwrap(model.selected)
                let winner = try await owner.save(active.session, expectedRevision: active.revision)
                let file = directory.appendingPathComponent("research-sessions.json"), before = try Data(contentsOf: file)
                model.resume(); await model.flush()
                XCTAssertEqual(model.error, WebResearchStoreError.conflict.localizedDescription)
                XCTAssertEqual(model.selected, selected)
                XCTAssertEqual(events, 0, "A stale Resume must not bind a newer operation")
                XCTAssertEqual(syntheses, 0)
                let calls = await provider.calls, reads = await reader.calls
                XCTAssertTrue(calls.isEmpty); XCTAssertTrue(reads.isEmpty)
                XCTAssertEqual(try Data(contentsOf: file), before)
                let latest = try await owner.load(id: winner.id); XCTAssertEqual(latest, winner)
            }
        }
    }

    @MainActor func testLostReconciliationCASCannotStartSynthesisOrRestoreDeletedTarget() async throws {
        for delete in [false, true] {
            try await withStore { owner, directory in
                let active = try await interruptedTerminalRetrieval(owner)
                let store = PanelReconciliationRaceStore(base: try WebResearchSessionStore(directory: directory), competitor: owner, delete: delete)
                let reader = PanelRecoveryReader()
                var syntheses = 0
                let model = WebResearchModel(store: store, reader: reader, synthesize: { session in
                    syntheses += 1; return Self.answer(session)
                })
                model.open(); await model.flush(); XCTAssertTrue(model.canResume)
                model.resume(); await model.flush()
                XCTAssertEqual(model.error, (delete ? WebResearchStoreError.notFound : .conflict).localizedDescription)
                XCTAssertEqual(syntheses, 0)
                let reads = await reader.calls; XCTAssertTrue(reads.isEmpty)
                let list = try await owner.list()
                if delete { XCTAssertTrue(list.isEmpty) }
                else {
                    let winner = try await owner.load(id: active.id)
                    XCTAssertNotEqual(winner.revision, active.revision)
                    XCTAssertEqual(winner.session.stage, .awaitingLocalSynthesis)
                    XCTAssertNil(winner.session.synthesis)
                }
            }
        }
    }

    @MainActor func testStopDrainsAdmittedReconciliationBeforeLaterLocalResume() async throws {
        try await withStore { owner, directory in
            let active = try await interruptedTerminalRetrieval(owner)
            let gate = PanelStoreGate(try WebResearchSessionStore(directory: directory))
            let reader = PanelRecoveryReader()
            var syntheses = 0
            let model = WebResearchModel(store: gate, reader: reader, synthesize: { session in
                syntheses += 1; return Self.answer(session)
            })
            model.open(); await model.flush()
            await gate.suspendReconciliationSave()
            model.resume(); try await eventually { await gate.waiting() }
            model.cancel(); await gate.release(); await model.flush()
            XCTAssertEqual(syntheses, 0)
            XCTAssertEqual(model.selected?.session.stage, .awaitingLocalSynthesis)
            XCTAssertNotEqual(model.selected?.revision, active.revision)
            XCTAssertNil(model.error)
            model.resume(); await model.flush()
            XCTAssertEqual(syntheses, 1); XCTAssertNil(model.error)
            XCTAssertEqual(model.selected?.session.outputVerification, .checked)
            let reads = await reader.calls; XCTAssertTrue(reads.isEmpty)
        }
    }

    @MainActor func testUncertainOnlyPreservePolicyStillNeedsNoAutomaticOrExplicitReplay() async throws {
        try await withStore { owner, directory in
            let initial = try await owner.create(question: "Unknown outcomes", queries: ["primary", "secondary"])
            var interrupted = initial.session; interrupted.stage = .retrieving; interrupted.providerID = "panel-fixture"
            for index in interrupted.queries.indices { interrupted.queries[index].status = .inFlight; interrupted.queries[index].attempts = 1 }
            let active = try await owner.save(interrupted, expectedRevision: initial.revision)
            let provider = PanelSearchFixture(), reader = PanelRecoveryReader()
            let model = WebResearchModel(provider: provider, directory: directory, reader: reader)
            let file = directory.appendingPathComponent("research-sessions.json"), before = try Data(contentsOf: file)
            model.open(); await model.flush()
            XCTAssertEqual(model.selected?.revision, active.revision)
            XCTAssertFalse(model.canResume)
            model.resume(); await model.flush()
            let calls = await provider.calls, reads = await reader.calls
            XCTAssertTrue(calls.isEmpty); XCTAssertTrue(reads.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    @MainActor func testRestartOffersOnlyExplicitLocalVerificationOfPendingAnswer() async throws {
        try await withStore { store, directory in
            let gated = PanelStoreGate(store), provider = PanelSearchFixture()
            var syntheses = 0
            let writer = WebResearchModel(provider: provider, store: gated, reader: PanelReaderFixture(), synthesize: { session in
                syntheses += 1; await gated.suspendLoad(); return Self.answer(session)
            })
            draft(writer); writer.start(); try await eventually { await gated.waiting() }
            writer.cancel(); await gated.release(); await writer.flush()
            let pending = try XCTUnwrap(writer.selected)
            XCTAssertEqual(pending.session.outputVerification, .pending)
            let before = await provider.calls
            let restarted = WebResearchModel(store: try WebResearchSessionStore(directory: directory))
            var verified = 0, events = 0
            restarted.onTaskProgress = { event in
                events += 1
                if case .verified = event.change { verified += 1 }
            }
            restarted.open(); await restarted.flush()
            XCTAssertEqual(events, 0, "Opening cannot replay any work")
            XCTAssertTrue(restarted.canResume, "Final local checks need neither provider nor synthesis")
            XCTAssertEqual(restarted.selected, pending)
            restarted.resume(); await restarted.flush()
            XCTAssertEqual(verified, 1); XCTAssertNil(restarted.error)
            XCTAssertEqual(restarted.selected?.session.outputVerification, .checked)
            XCTAssertEqual(restarted.selected?.session.synthesis, pending.session.synthesis)
            XCTAssertFalse(restarted.canResume)
            let after = await provider.calls
            XCTAssertEqual(before, after); XCTAssertEqual(syntheses, 1)
            let reopened = WebResearchModel(store: try WebResearchSessionStore(directory: directory))
            reopened.open(); await reopened.flush()
            XCTAssertFalse(reopened.canResume)
            XCTAssertEqual(reopened.selected?.session.outputVerification, .checked)
        }
    }

    @MainActor func testRestoredPendingReceiptRejectsDeletedOrChangedRevision() async throws {
        for deleted in [false, true] {
            try await withStore { store, directory in
                let gated = PanelStoreGate(store)
                let writer = WebResearchModel(provider: PanelSearchFixture(), store: gated, reader: PanelReaderFixture(), synthesize: { session in
                    await gated.suspendLoad(); return Self.answer(session)
                })
                draft(writer); writer.start(); try await eventually { await gated.waiting() }
                writer.cancel(); await gated.release(); await writer.flush()
                let restartStore = try WebResearchSessionStore(directory: directory)
                let reader = WebResearchModel(store: restartStore)
                reader.open(); await reader.flush()
                let pending = try XCTUnwrap(reader.selected)
                if deleted { try await restartStore.delete(id: pending.id, expectedRevision: pending.revision) }
                else { _ = try await restartStore.save(pending.session, expectedRevision: pending.revision) }
                var verified = 0
                reader.onTaskProgress = { if case .verified = $0.change { verified += 1 } }
                reader.resume(); await reader.flush()
                XCTAssertEqual(verified, 0); XCTAssertNotNil(reader.error)
            }
        }
    }

    @MainActor func testStopDrainsAdmittedCheckedReceiptWriteWithoutReplayingAnswer() async throws {
        try await withStore { store, _ in
            let gate = PanelStoreGate(store)
            await gate.suspendCheckedSave()
            var syntheses = 0, verified = 0
            let model = WebResearchModel(provider: PanelSearchFixture(), store: gate, reader: PanelReaderFixture(), synthesize: { session in
                syntheses += 1; return Self.answer(session)
            })
            model.onTaskProgress = { if case .verified = $0.change { verified += 1 } }
            draft(model); model.start(); try await eventually { await gate.waiting() }
            model.cancel()
            XCTAssertTrue(model.busy, "Stop must drain a previously admitted metadata write")
            await gate.release(); await model.flush()
            XCTAssertEqual(verified, 0); XCTAssertTrue(model.canResume)
            XCTAssertEqual(model.selected?.session.outputVerification, .checked)
            let committed = model.selected
            model.resume(); await model.flush()
            XCTAssertEqual(verified, 1); XCTAssertEqual(syntheses, 1)
            XCTAssertEqual(model.selected, committed, "The checked receipt needs only read-back")
            XCTAssertFalse(model.canResume)
        }
    }

    @MainActor func testPendingAndLegacyValidAnswersCannotEmitVerifiedSuccess() async throws {
        try await withStore { store, _ in
            let writer = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { Self.answer($0) })
            draft(writer); writer.start(); await writer.flush()
            let checked = try XCTUnwrap(writer.selected)
            XCTAssertEqual(checked.session.outputVerification, .checked)
            let states: [WebResearchOutputVerification?] = [.pending, nil, .checked]
            for state in states {
                var session = checked.session; session.outputVerification = state
                XCTAssertNoThrow(try session.encodedCheckpoint(), "Use a valid answer to isolate receipt admission")
                let stored = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
                let operation = UUID()
                var progress = ResearchTaskProgress()
                XCTAssertTrue(progress.receive(.init(operation: operation, generation: 1, sequence: 1,
                    change: .started(session, resuming: true)), now: 0))
                XCTAssertTrue(progress.receive(.init(operation: operation, generation: 1, sequence: 2,
                    change: .verifying(session)), now: 121))
                let accepted = progress.receive(.init(operation: operation, generation: 1, sequence: 3,
                    change: .verified(expected: stored, reloaded: stored)), now: 122)
                XCTAssertEqual(accepted, state == .checked)
                if state != .checked { XCTAssertNotEqual(progress.progress.halo, .verifiedComplete) }
            }
        }
    }

    @MainActor func testSynchronousCheckedSelectionObserverStopsBeforeVerifiedEvent() async throws {
        try await withStore { store, _ in
            var syntheses = 0, verified = 0, stopped = false
            let model = WebResearchModel(provider: PanelSearchFixture(), store: store, reader: PanelReaderFixture(), synthesize: { session in
                syntheses += 1; return Self.answer(session)
            })
            model.onTaskProgress = { if case .verified = $0.change { verified += 1 } }
            let observation = model.$selected.sink { selected in
                if selected?.session.outputVerification == .checked, !stopped {
                    stopped = true; model.cancel()
                }
            }
            defer { observation.cancel() }
            draft(model); model.start(); await model.flush()
            XCTAssertTrue(stopped); XCTAssertEqual(verified, 0)
            XCTAssertTrue(model.canResume); XCTAssertFalse(model.busy)
            model.resume(); await model.flush()
            XCTAssertEqual(verified, 1); XCTAssertEqual(syntheses, 1)
            XCTAssertFalse(model.canResume)
        }
    }

    @MainActor func testVerifiedCallbackStopOrCloseCannotPublishLateSuccessOrLoseReadbackRetry() async throws {
        for close in [false, true] {
            try await withStore { store, _ in
                let provider = PanelSearchFixture()
                var syntheses = 0, verified = 0, interrupted = false
                var lateSuccessNotices: [String] = []
                let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { session in
                    syntheses += 1; return Self.answer(session)
                })
                let observation = model.$notice.sink { notice in
                    if interrupted, let notice, notice.contains("Citation excerpts match sources") {
                        lateSuccessNotices.append(notice)
                    }
                }
                defer { observation.cancel() }
                model.onTaskProgress = { event in
                    if case .verified = event.change {
                        verified += 1
                        if !interrupted {
                            interrupted = true
                            if close { model.close() } else { model.cancel() }
                        }
                    }
                }
                draft(model); model.start(); await model.flush()
                XCTAssertTrue(interrupted); XCTAssertEqual(verified, 1)
                XCTAssertTrue(lateSuccessNotices.isEmpty, "No success notice may publish after the callback interrupts admission")
                XCTAssertFalse(model.busy)
                let checked = try XCTUnwrap(model.selected)
                XCTAssertEqual(checked.session.outputVerification, .checked, "Completed local checks remain durable")
                if close {
                    XCTAssertFalse(model.canResume)
                    model.open(); await model.flush()
                }
                XCTAssertTrue(model.canResume, "Keep the exact receipt until uninterrupted completion publication")
                let callsBefore = await provider.calls
                observation.cancel()
                model.resume(); await model.flush()
                XCTAssertEqual(verified, 2); XCTAssertEqual(syntheses, 1)
                XCTAssertEqual(model.selected, checked, "Retry only reads back the same checked receipt")
                let callsAfter = await provider.calls
                XCTAssertEqual(callsAfter, callsBefore)
                XCTAssertFalse(model.canResume); XCTAssertNil(model.error)
            }
        }
    }

    @MainActor func testAdmissionActivityObserverStopOrCloseDrainsOwnedTaskBeforeAnyWork() async throws {
        for close in [false, true] {
            try await withStore { store, _ in
                let provider = PanelSearchFixture()
                var interrupted = false, syntheses = 0
                let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { session in
                    syntheses += 1; return Self.answer(session)
                })
                let observation = model.$activity.sink { activity in
                    if activity == .retrieving, !interrupted {
                        interrupted = true
                        XCTAssertTrue(model.busy, "Ownership must precede the first published activity")
                        if close { model.close() } else { model.cancel() }
                    }
                }
                defer { observation.cancel() }
                draft(model); model.start()
                XCTAssertTrue(interrupted); XCTAssertTrue(model.busy)
                XCTAssertEqual(model.activity, .pausing, "Outer willSet must not overwrite the nested pause")
                await model.flush()
                XCTAssertFalse(model.busy); XCTAssertNil(model.activity); XCTAssertNil(model.selected)
                let calls = await provider.calls, saved = try await store.list()
                XCTAssertTrue(calls.isEmpty); XCTAssertTrue(saved.isEmpty); XCTAssertEqual(syntheses, 0)
                if close { model.open(); await model.flush() }
                model.start(); await model.flush()
                XCTAssertEqual(syntheses, 1, "Admission is restored only after the old task drained")
                XCTAssertEqual(model.selected?.session.outputVerification, .checked)
            }
        }
    }

    @MainActor func testAdmissionActivityObserverCannotReplaceOperationBeforeHandleInstallation() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture()
            var attempted = false, syntheses = 0
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { session in
                syntheses += 1; return Self.answer(session)
            })
            let observation = model.$activity.sink { activity in
                if activity == .retrieving, !attempted {
                    attempted = true
                    XCTAssertTrue(model.busy); XCTAssertFalse(model.canStart)
                    model.start()
                }
            }
            defer { observation.cancel() }
            draft(model); model.start(); await model.flush()
            XCTAssertTrue(attempted); XCTAssertFalse(model.busy)
            let saved = try await store.list(), calls = await provider.calls
            XCTAssertEqual(saved.count, 1); XCTAssertEqual(calls.count, 2); XCTAssertEqual(syntheses, 1)
            XCTAssertEqual(model.selected?.session.outputVerification, .checked)
        }
    }

    @MainActor func testIdleActivityObserverCannotAdmitWorkDuringOldHandleCleanup() async throws {
        try await withStore { store, _ in
            let provider = PanelSearchFixture()
            var armed = false, attempted = false, syntheses = 0
            let model = WebResearchModel(provider: provider, store: store, reader: PanelReaderFixture(), synthesize: { session in
                syntheses += 1; return Self.answer(session)
            })
            let observation = model.$activity.sink { activity in
                if activity != nil { armed = true }
                if activity == nil, armed, !attempted {
                    attempted = true
                    XCTAssertTrue(model.busy, "Idle publication reserves admission until old cleanup finishes")
                    XCTAssertFalse(model.canStart)
                    model.start()
                }
            }
            defer { observation.cancel() }
            draft(model); model.start(); await model.flush()
            XCTAssertTrue(attempted); XCTAssertFalse(model.busy); XCTAssertNil(model.activity)
            let first = try await store.list()
            XCTAssertEqual(first.count, 1); XCTAssertEqual(syntheses, 1)
            XCTAssertTrue(model.canStart)
            model.start(); await model.flush()
            let second = try await store.list(), calls = await provider.calls
            XCTAssertEqual(second.count, 2); XCTAssertEqual(calls.count, 4); XCTAssertEqual(syntheses, 2)
            XCTAssertFalse(model.busy); XCTAssertNil(model.activity)
        }
    }

}
#endif
