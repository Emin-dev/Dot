import Darwin
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

private struct StoredWorkflowSearch: WebSearchProvider {
    let providerID = "stored-fixture"
    let permitsResultPersistence = true
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        [WebSearchResult(url: URL(string: "https://example.org/\(query)")!, title: query, snippet: "Fixture hint", publicationDateHint: nil)]
    }
}

/// An explicit continuation barrier fixes the observer between the persisted in-flight
/// checkpoint and its result. No elapsed-time ordering or real service is involved.
private actor StoredRecoverySearch: WebSearchProvider {
    nonisolated let providerID = "fixture"
    nonisolated let permitsResultPersistence = true
    private(set) var calls: [String] = []
    private var holdFirst: Bool
    private var request: CheckedContinuation<Void, Never>?
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        calls.append(query)
        if holdFirst {
            await withCheckedContinuation { request = $0 }
        }
        return [WebSearchResult(url: URL(string: "https://example.org/\(query)")!, title: query,
            snippet: "Fixture hint", publicationDateHint: nil)]
    }
    func waiting() -> Bool { request != nil }
    func release() { holdFirst = false; request?.resume(); request = nil }
}

private actor StoredWorkflowReader: WebResearchSourceReading {
    var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func setHold() { hold = true }
    func waiting() -> Bool { continuation != nil }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func read(_ url: URL) async throws -> ResearchSource {
        if hold { await withCheckedContinuation { continuation = $0 } }
        return ResearchSource(id: UUID(), originalURL: url, finalURL: url, title: "Fixture", kind: .webPage,
            retrievedAt: Date(), modifiedAt: nil, bytesRead: 50, sha256: String(repeating: "a", count: 64),
            pagesRead: nil, text: "Actual fixture evidence", truncated: false, transportReceipt: .httpsOnlyV1)
    }
}

private actor StoredWorkflowCheckpoints {
    let store: WebResearchSessionStore
    var revision: UUID
    private(set) var values: [WebResearchStoredSession] = []
    init(store: WebResearchSessionStore, revision: UUID) { self.store = store; self.revision = revision }
    func save(_ session: WebResearchSession) async throws {
        let stored = try await store.save(session, expectedRevision: revision)
        revision = stored.revision; values.append(stored)
    }
}

final class WebResearchStoreTests: XCTestCase {
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dot-research-store-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
    private func file(_ directory: URL) -> URL { directory.appendingPathComponent("research-sessions.json") }
    private func raw(_ directory: URL, id: UUID) throws -> WebResearchStoredSession {
        struct Archive: Decodable { let sessions: [WebResearchStoredSession] }
        return try XCTUnwrap(JSONDecoder().decode(Archive.self, from: Data(contentsOf: file(directory)))
            .sessions.first { $0.id == id })
    }
    private func create(_ store: WebResearchSessionStore, question: String = "Public fixture question") async throws -> WebResearchStoredSession {
        try await store.create(question: question, queries: ["primary", "secondary"])
    }
    private func expect(_ expected: WebResearchStoreError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? WebResearchStoreError, expected) }
    }
    private func waitForRequest(_ predicate: () async -> Bool) async throws {
        // This timeout only bounds failure. The held request establishes ordering.
        for _ in 0..<2_000 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Workflow did not reach its held request"); throw URLError(.timedOut)
    }
    private func inFlight(_ session: WebResearchSession) -> WebResearchSession {
        var copy = session; copy.stage = .retrieving; copy.providerID = "fixture"
        copy.queries[0].status = .inFlight; copy.queries[0].attempts = 1
        return copy
    }
    private func ready(_ session: WebResearchSession) -> WebResearchSession {
        var copy = session; copy.stage = .awaitingLocalSynthesis; copy.providerID = "fixture"
        for index in copy.queries.indices {
            let url = URL(string: "https://example.org/source\(index)")!
            copy.queries[index].status = .completed; copy.queries[index].attempts = 1
            copy.queries[index].completedAt = Date(timeIntervalSince1970: 100)
            copy.queries[index].results = [WebSearchResult(url: url, title: "Source", snippet: "Untrusted search hint", publicationDateHint: nil)]
            let source = ResearchSource(id: UUID(), originalURL: url, finalURL: url, title: "Source", kind: .webPage,
                retrievedAt: Date(timeIntervalSince1970: 200), modifiedAt: nil, bytesRead: 100,
                sha256: String(repeating: "a", count: 64), pagesRead: nil, text: "Fixture evidence.", truncated: false, transportReceipt: .httpsOnlyV1)
            copy.reads.append(WebResearchRead(id: UUID(), url: url, status: .completed, source: source, failure: nil))
        }
        return copy
    }

    func testCreateListLoadReopenAndPrivatePermissions() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory)
            let stored = try await create(store), list = try await store.list()
            XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0].id, stored.id)
            XCTAssertEqual(list[0].stage, .planned); XCTAssertEqual(list[0].sourcesRead, 0)
            let reopened = try await WebResearchSessionStore(directory: directory).load(id: stored.id)
            XCTAssertEqual(reopened, stored)
            for (url, mode) in [(directory, 0o700), (file(directory), 0o600), (directory.appendingPathComponent("research-sessions.lock"), 0o600)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
            }
            let data = try Data(contentsOf: file(directory)), json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["schemaVersion"] as? Int, 1)
            XCTAssertEqual(Set(json.keys), ["schemaVersion", "sessions"])
        }
    }

    func testSavingUsesNewRevisionAndRejectsStaleWriteWithoutFileChange() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let latest = try await store.save(inFlight(initial.session), expectedRevision: initial.revision)
            XCTAssertNotEqual(latest.revision, initial.revision)
            let before = try Data(contentsOf: file(directory))
            await expect(.conflict) { _ = try await store.save(initial.session, expectedRevision: initial.revision) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            let current = try await store.load(id: latest.id)
            XCTAssertEqual(current, latest) // The current owner must not recover its own live request.
        }
    }

    func testForeignReadProjectsUnknownOutcomeWithoutChangingBytesOrOwnerRevision() async throws {
        try await withDirectory { directory in
            let original = try WebResearchSessionStore(directory: directory), initial = try await create(original)
            let active = try await original.save(inFlight(initial.session), expectedRevision: initial.revision)
            let observer = try WebResearchSessionStore(directory: directory, now: { Date(timeIntervalSince1970: 700) })
            let before = try Data(contentsOf: file(directory))
            let inode = try FileManager.default.attributesOfItem(atPath: file(directory).path)[.systemFileNumber] as? NSNumber
            let projected = try await observer.load(id: active.id)
            XCTAssertEqual(projected.session.stage, .paused)
            XCTAssertEqual(projected.session.queries[0].status, .uncertain)
            XCTAssertEqual(projected.session.queries[0].failure, .interruptedOutcomeUnknown)
            XCTAssertEqual(projected.session.searchAttempts, 1)
            XCTAssertEqual(projected.session.retryPolicy, .preserveUncertain)
            XCTAssertEqual(projected.revision, active.revision)
            XCTAssertEqual(projected.session.updatedAt, active.session.updatedAt)
            XCTAssertNil(projected.recoveredAt, "Observation is not a durable reconciliation or proof of process death")
            for _ in 0..<3 {
                let list = try await observer.list(), again = try await observer.load(id: active.id)
                XCTAssertEqual(again, projected)
                XCTAssertEqual(list[0].revision, active.revision); XCTAssertEqual(list[0].stage, .paused)
                XCTAssertEqual(list[0].updatedAt, active.session.updatedAt); XCTAssertNil(list[0].recoveredAt)
                XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            }
            let independent = try await WebResearchSessionStore(directory: directory, now: { Date(timeIntervalSince1970: 900) }).load(id: active.id)
            XCTAssertEqual(independent, projected, "Projection identity must not depend on observation time")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file(directory).path)[.systemFileNumber] as? NSNumber, inode)
            XCTAssertEqual(try raw(directory, id: active.id), active)
            let owned = try await original.load(id: active.id); XCTAssertEqual(owned, active)
            let saved = try await original.save(active.session, expectedRevision: active.revision)
            XCTAssertNotEqual(saved.revision, active.revision); XCTAssertNil(saved.recoveredAt)
        }
    }

    func testForeignMutationsPreserveRawUnrelatedActiveRecord() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
            let active = try await owner.save(inFlight(initial.session), expectedRevision: initial.revision)
            let foreign = try WebResearchSessionStore(directory: directory)
            _ = try await foreign.list(); _ = try await foreign.load(id: active.id)
            let unrelated = try await create(foreign, question: "Independent work")
            XCTAssertEqual(try raw(directory, id: active.id), active)
            let changed = try await foreign.save(unrelated.session, expectedRevision: unrelated.revision)
            XCTAssertEqual(try raw(directory, id: active.id), active)
            try await foreign.delete(id: changed.id, expectedRevision: changed.revision)
            XCTAssertEqual(try raw(directory, id: active.id), active)
            let saved = try await owner.save(active.session, expectedRevision: active.revision)
            XCTAssertNotEqual(saved.revision, active.revision)
        }
    }

    func testFailedForeignMutationsDoNotCommitRecoveryAsASideEffect() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
            let active = try await owner.save(inFlight(initial.session), expectedRevision: initial.revision)
            var limits = WebResearchSessionStore.Limits(); limits.maxSessions = 1
            let foreign = try WebResearchSessionStore(directory: directory, limits: limits)
            let before = try Data(contentsOf: file(directory))
            await expect(.capacity) { _ = try await create(foreign) }
            await expect(.conflict) { _ = try await foreign.save(active.session, expectedRevision: initial.revision) }
            await expect(.conflict) { try await foreign.delete(id: active.id, expectedRevision: initial.revision) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            XCTAssertEqual(try raw(directory, id: active.id), active)
        }
    }

    func testExplicitRecoverySaveCommitsOnlyTargetAndFencesOldRevision() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory)
            let first = try await create(owner), second = try await create(owner)
            let active = try await owner.save(inFlight(first.session), expectedRevision: first.revision)
            let unrelated = try await owner.save(inFlight(second.session), expectedRevision: second.revision)
            let foreign = try WebResearchSessionStore(directory: directory, now: { Date(timeIntervalSince1970: 700) })
            let projected = try await foreign.load(id: active.id)
            let reconciled = try await foreign.save(projected.session, expectedRevision: projected.revision)
            XCTAssertNotEqual(reconciled.revision, active.revision)
            XCTAssertEqual(reconciled.session, projected.session)
            XCTAssertEqual(reconciled.recoveredAt, Date(timeIntervalSince1970: 700))
            XCTAssertEqual(try raw(directory, id: active.id), reconciled)
            XCTAssertEqual(try raw(directory, id: unrelated.id), unrelated)
            let reopened = try await WebResearchSessionStore(directory: directory).load(id: active.id)
            XCTAssertEqual(reopened, reconciled)
            let before = try Data(contentsOf: file(directory))
            await expect(.conflict) { _ = try await owner.save(active.session, expectedRevision: active.revision) }
            await expect(.conflict) { try await owner.delete(id: active.id, expectedRevision: active.revision) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), before)
        }
    }

    func testStaleRecoveryCannotReplaceCommitOrResurrectDeletedRecordOrDispatchSearch() async throws {
        for mutation in ["save", "delete", "deleteAll"] {
            try await withDirectory { directory in
                let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
                let active = try await owner.save(inFlight(initial.session), expectedRevision: initial.revision)
                let foreign = try WebResearchSessionStore(directory: directory)
                let projected = try await foreign.load(id: active.id)
                if mutation == "save" { _ = try await owner.save(active.session, expectedRevision: active.revision) }
                else if mutation == "delete" { try await owner.delete(id: active.id, expectedRevision: active.revision) }
                else { try await owner.deleteAll() }
                let before = try Data(contentsOf: file(directory))
                let expected: WebResearchStoreError = mutation == "save" ? .conflict : .notFound
                await expect(expected) { _ = try await foreign.save(projected.session, expectedRevision: projected.revision) }
                await expect(expected) { try await foreign.delete(id: projected.id, expectedRevision: projected.revision) }
                let provider = StoredRecoverySearch(), sink = StoredWorkflowCheckpoints(store: foreign, revision: projected.revision)
                do {
                    _ = try await WebResearchWorkflow(provider: provider, reader: StoredWorkflowReader()).run(projected.session) { try await sink.save($0) }
                    XCTFail("The first Resume checkpoint must reject a stale/deleted revision")
                } catch { XCTAssertEqual(error as? WebResearchError, .checkpointFailed) }
                let calls = await provider.calls, checkpoints = await sink.values
                XCTAssertTrue(calls.isEmpty); XCTAssertTrue(checkpoints.isEmpty)
                XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            }
        }
    }

    func testRestartKeepsCompletedQueriesAndEvidenceButResetsUnfinishedRead() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            var partial = ready(initial.session); partial.stage = .retrieving
            partial.reads[1].status = .inFlight; partial.reads[1].source = nil
            let active = try await store.save(partial, expectedRevision: initial.revision)
            let before = try Data(contentsOf: file(directory))
            let recovered = try await WebResearchSessionStore(directory: directory).load(id: active.id)
            XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            XCTAssertEqual(recovered.revision, active.revision)
            XCTAssertEqual(recovered.session.queries, active.session.queries)
            XCTAssertEqual(recovered.session.reads[0], active.session.reads[0])
            XCTAssertEqual(recovered.session.reads[1].status, .pending)
            XCTAssertNil(recovered.session.reads[1].source)
            XCTAssertEqual(recovered.session.sources.count, 1)
            XCTAssertNil(recovered.session.synthesis)
        }
    }

    func testAwaitingSynthesisAndValidatedCompletionSurviveRestartTruthfully() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let fetched = try await store.save(ready(initial.session), expectedRevision: initial.revision)
            let reopened = try await WebResearchSessionStore(directory: directory).load(id: fetched.id)
            XCTAssertEqual(reopened, fetched); XCTAssertNil(reopened.session.synthesis)
            let claim = WebResearchClaim(id: UUID(), text: "Fixture conclusion", citationNumbers: [1], confidence: .tentative, dates: [])
            let synthesis = WebResearchSynthesis(answer: "Fixture conclusion [1].", claims: [claim],
                citations: [WebResearchCitation(number: 1, sourceID: fetched.session.sources[0].id, excerpt: "Fixture evidence.")], conflicts: [], followUpQueries: [])
            let finished = try await store.save(fetched.session.completing(with: synthesis), expectedRevision: fetched.revision)
            let final = try await WebResearchSessionStore(directory: directory).load(id: finished.id)
            XCTAssertEqual(final.session.stage, .completed); XCTAssertEqual(final.session.synthesis, synthesis)
        }
    }

    func testUnvalidatedCompletedStateAndBudgetRollbackRejected() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            var fake = initial.session; fake.stage = .completed
            await expect(.invalidInput) { _ = try await store.save(fake, expectedRevision: initial.revision) }
            let active = try await store.save(inFlight(initial.session), expectedRevision: initial.revision)
            await expect(.invalidInput) { _ = try await store.save(initial.session, expectedRevision: active.revision) }
            let current = try await store.load(id: active.id); XCTAssertEqual(current, active)
        }
    }

    func testCompletedQueriesAndReadReceiptsCannotBeRemovedOrRewrittenOnSave() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let fetched = try await store.save(ready(initial.session), expectedRevision: initial.revision)
            var changed = fetched.session; changed.reads.removeFirst()
            await expect(.invalidInput) { _ = try await store.save(changed, expectedRevision: fetched.revision) }
            changed = fetched.session; changed.queries[0].results = []
            await expect(.invalidInput) { _ = try await store.save(changed, expectedRevision: fetched.revision) }
            let followUp = try fetched.session.addingQueries(["new query"])
            let saved = try await store.save(followUp, expectedRevision: fetched.revision)
            XCTAssertEqual(saved.session.sources, fetched.session.sources)
        }
    }

    func testDeleteRemovesTextAndLateWriteCannotResurrectAcrossRestart() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store, question: "Remove this exact private fixture")
            try await store.delete(id: initial.id, expectedRevision: initial.revision)
            await expect(.notFound) { _ = try await store.save(initial.session, expectedRevision: initial.revision) }
            let restarted = try WebResearchSessionStore(directory: directory)
            await expect(.notFound) { _ = try await restarted.save(initial.session, expectedRevision: initial.revision) }
            let contents = String(decoding: try Data(contentsOf: file(directory)), as: UTF8.self)
            XCTAssertFalse(contents.contains("Remove this exact private fixture"))
            let new = try await create(restarted); XCTAssertNotEqual(new.id, initial.id)
        }
    }

    func testStaleDeleteFailsAndDeleteAllInvalidatesEveryPendingSave() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), first = try await create(store), second = try await create(store)
            let changed = try await store.save(inFlight(first.session), expectedRevision: first.revision)
            await expect(.conflict) { try await store.delete(id: first.id, expectedRevision: first.revision) }
            try await store.deleteAll()
            for old in [changed, second] { await expect(.notFound) { _ = try await store.save(old.session, expectedRevision: old.revision) } }
            let list = try await store.list(); XCTAssertTrue(list.isEmpty)
        }
    }

    func testCorruptAndFutureDocumentsPreservedByEveryOrdinaryMutation() async throws {
        for (text, error) in [("broken", WebResearchStoreError.corrupt), ("{\"schemaVersion\":99}", .unsupportedVersion(99)), ("{\"schemaVersion\":1,\"sessions\":[{}]}", .corrupt)] {
            try await withDirectory { directory in
                let original = Data(text.utf8); try original.write(to: file(directory))
                let store = try WebResearchSessionStore(directory: directory)
                await expect(error) { _ = try await store.list() }
                await expect(error) { _ = try await create(store) }
                await expect(error) { try await store.deleteAll() }
                XCTAssertEqual(try Data(contentsOf: file(directory)), original)
            }
        }
    }

    func testSessionAndWholeFileCapacityPreservePreviousDocument() async throws {
        try await withDirectory { directory in
            var limits = WebResearchSessionStore.Limits(); limits.maxSessions = 1
            let store = try WebResearchSessionStore(directory: directory, limits: limits)
            _ = try await create(store)
            let data = try Data(contentsOf: file(directory))
            await expect(.capacity) { _ = try await create(store) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), data)
        }
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory)
            _ = try await create(store, question: String(repeating: "x", count: 2_000))
            let data = try Data(contentsOf: file(directory))
            var small = WebResearchSessionStore.Limits(); small.maxFileBytes = 1_024
            let bounded = try WebResearchSessionStore(directory: directory, limits: small)
            await expect(.capacity) { _ = try await bounded.list() }
            XCTAssertEqual(try Data(contentsOf: file(directory)), data)
            small.maxFileBytes = 16_777_216; small.maxSessionBytes = 1_024
            let perSession = try WebResearchSessionStore(directory: directory, limits: small)
            await expect(.capacity) { _ = try await perSession.list() }
        }
    }

    func testCancellationBeforeAdmissionCreatesNoSessionOrFile() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.create(question: "cancelled", queries: ["one", "two"])
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file(directory).path))
        }
    }

    func testAtomicReplaceLeavesCompleteDocumentAndNoTemporaryFiles() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let before = try FileManager.default.attributesOfItem(atPath: file(directory).path)[.systemFileNumber] as? NSNumber
            _ = try await store.save(inFlight(initial.session), expectedRevision: initial.revision)
            let after = try FileManager.default.attributesOfItem(atPath: file(directory).path)[.systemFileNumber] as? NSNumber
            XCTAssertNotEqual(before, after)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: file(directory))))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
        }
    }

    func testAbandonedOwnTemporaryRemovedButUnknownFilesPreserved() async throws {
        try await withDirectory { directory in
            let orphan = directory.appendingPathComponent(".research-sessions-\(UUID().uuidString).tmp")
            let unknown = directory.appendingPathComponent("notes.txt")
            try Data("abandoned private text".utf8).write(to: orphan)
            try Data("keep this".utf8).write(to: unknown)
            let store = try WebResearchSessionStore(directory: directory)
            _ = try await store.list()
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
            XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep this")
        }
    }

    func testSymbolicAndHardLinksCannotRedirectResearchStorage() async throws {
        try await withDirectory { root in
            let target = root.appendingPathComponent("target.json"), directory = root.appendingPathComponent("store")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = Data("untouched target".utf8); try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: file(directory), withDestinationURL: target)
            let store = try WebResearchSessionStore(directory: directory)
            await expect(.unsafeStorage) { _ = try await create(store) }
            XCTAssertEqual(try Data(contentsOf: target), original)
            try FileManager.default.removeItem(at: file(directory))
            try FileManager.default.linkItem(at: target, to: file(directory))
            await expect(.unsafeStorage) { _ = try await store.list() }
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testDirectoryAndLockSymlinksRejected() async throws {
        try await withDirectory { root in
            let actual = root.appendingPathComponent("actual"), alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
            let aliased = try WebResearchSessionStore(directory: alias)
            await expect(.unsafeStorage) { _ = try await aliased.list() }
            let target = root.appendingPathComponent("lock-target")
            try Data("private target".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: actual.appendingPathComponent("research-sessions.lock"), withDestinationURL: target)
            let store = try WebResearchSessionStore(directory: actual)
            await expect(.unsafeStorage) { _ = try await store.list() }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "private target")
        }
    }

    func testHeldWriterLockReportsBusyWithoutWaitingOrOverwriting() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let lock = open(directory.appendingPathComponent("research-sessions.lock").path, O_RDWR)
            XCTAssertGreaterThanOrEqual(lock, 0)
            defer { flock(lock, LOCK_UN); close(lock) }
            XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
            await expect(.busy) { _ = try await store.save(initial.session, expectedRevision: initial.revision) }
        }
    }

    func testConcurrentSavesWithSameRevisionHaveExactlyOneWinner() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let candidate = inFlight(initial.session)
            let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do { _ = try await store.save(candidate, expectedRevision: initial.revision); return true }
                        catch { return false }
                    }
                }
                var outcomes: [Bool] = []; for await result in group { outcomes.append(result) }; return outcomes
            }
            XCTAssertEqual(results.filter { $0 }.count, 1)
            let list = try await store.list(); XCTAssertEqual(list.count, 1)
        }
    }

    func testForeignReadDuringSuspendedSearchCannotInvalidateLiveWorkflowCheckpoint() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
            let provider = StoredRecoverySearch(holdFirst: true)
            let sink = StoredWorkflowCheckpoints(store: owner, revision: initial.revision)
            let workflow = WebResearchWorkflow(provider: provider, reader: StoredWorkflowReader())
            let task = Task { try await workflow.run(initial.session) { try await sink.save($0) } }
            do {
                try await waitForRequest { await provider.waiting() }
                let active = try await owner.load(id: initial.id), before = try Data(contentsOf: file(directory))
                XCTAssertEqual(active.session.queries[0].status, .inFlight)
                let foreign = try WebResearchSessionStore(directory: directory)
                _ = try await foreign.list()
                let projected = try await foreign.load(id: initial.id)
                XCTAssertEqual(projected.revision, active.revision)
                XCTAssertEqual(projected.session.queries[0].status, .uncertain)
                XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            } catch { await provider.release(); _ = try? await task.value; throw error }
            await provider.release()
            let result = try await task.value, saved = try await owner.load(id: initial.id)
            XCTAssertEqual(result.stage, .awaitingLocalSynthesis); XCTAssertEqual(saved.session, result)
            let calls = await provider.calls; XCTAssertEqual(calls, ["primary", "secondary"])
        }
    }

    func testForeignReadDuringSuspendedSourceCannotInvalidateLiveWorkflowCheckpoint() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
            let reader = StoredWorkflowReader(); await reader.setHold()
            let sink = StoredWorkflowCheckpoints(store: owner, revision: initial.revision)
            let workflow = WebResearchWorkflow(provider: StoredWorkflowSearch(), reader: reader)
            let task = Task { try await workflow.run(initial.session) { try await sink.save($0) } }
            do {
                try await waitForRequest { await reader.waiting() }
                let active = try await owner.load(id: initial.id), before = try Data(contentsOf: file(directory))
                XCTAssertEqual(active.session.reads[0].status, .inFlight)
                let foreign = try WebResearchSessionStore(directory: directory)
                _ = try await foreign.list()
                let projected = try await foreign.load(id: initial.id)
                XCTAssertEqual(projected.revision, active.revision)
                XCTAssertEqual(projected.session.reads[0].status, .pending)
                XCTAssertEqual(projected.session.queries, active.session.queries)
                XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            } catch { await reader.release(); _ = try? await task.value; throw error }
            await reader.release()
            let result = try await task.value, saved = try await owner.load(id: initial.id)
            XCTAssertEqual(result.stage, .awaitingLocalSynthesis); XCTAssertEqual(saved.session, result)
            XCTAssertEqual(result.sources.count, 2)
        }
    }

    func testExplicitResumeReconcilesBeforeRequestsAndPreservesUncertainAttemptCaps() async throws {
        let scenarios: [(WebResearchRetryPolicy, Int, Int, Int, [String])] = [
            (.preserveUncertain, 1, 0, 3, ["secondary"]),
            (.retryUncertainWithinBudget, 1, 0, 3, ["primary", "secondary"]),
            (.retryUncertainWithinBudget, 2, 0, 3, ["secondary"]),
            (.retryUncertainWithinBudget, 1, 1, 2, [])
        ]
        for (policy, firstAttempts, secondAttempts, cap, expectedCalls) in scenarios {
            try await withDirectory { directory in
                var limits = WebResearchLimits(); limits.maxSearchAttempts = cap
                let owner = try WebResearchSessionStore(directory: directory)
                let initial = try await owner.create(question: "Resume fixture", queries: ["primary", "secondary"], limits: limits, retryPolicy: policy)
                var pending = inFlight(initial.session); pending.queries[0].attempts = firstAttempts
                if secondAttempts > 0 { pending.queries[1].status = .inFlight; pending.queries[1].attempts = secondAttempts }
                let active = try await owner.save(pending, expectedRevision: initial.revision)
                let foreign = try WebResearchSessionStore(directory: directory, now: { Date(timeIntervalSince1970: 700) })
                let provider = StoredRecoverySearch(), before = try Data(contentsOf: file(directory))
                _ = try await foreign.list()
                let projected = try await foreign.load(id: active.id)
                XCTAssertEqual(try Data(contentsOf: file(directory)), before)
                let callsBeforeResume = await provider.calls; XCTAssertTrue(callsBeforeResume.isEmpty)
                let sink = StoredWorkflowCheckpoints(store: foreign, revision: projected.revision)
                let result = try await WebResearchWorkflow(provider: provider, reader: StoredWorkflowReader()).run(projected.session) { try await sink.save($0) }
                let calls = await provider.calls, checkpoints = await sink.values
                XCTAssertEqual(calls, expectedCalls)
                let first = try XCTUnwrap(checkpoints.first)
                XCTAssertNotEqual(first.revision, active.revision)
                XCTAssertEqual(first.recoveredAt, Date(timeIntervalSince1970: 700))
                XCTAssertEqual(first.session.searchAttempts, active.session.searchAttempts, "Reconciliation does not refund or spend an attempt")
                XCTAssertEqual(first.session.limits, limits); XCTAssertEqual(first.session.retryPolicy, policy)
                XCTAssertEqual(result.searchAttempts, firstAttempts + secondAttempts + expectedCalls.count)
                XCTAssertLessThanOrEqual(result.searchAttempts, cap)
                XCTAssertTrue(result.queries.allSatisfy { $0.attempts <= 2 })
                if !expectedCalls.contains("primary") {
                    XCTAssertEqual(result.queries[0].status, .uncertain)
                    XCTAssertEqual(result.queries[0].failure, .interruptedOutcomeUnknown)
                }
                let beforeStaleWrite = try Data(contentsOf: file(directory))
                await expect(.conflict) { _ = try await owner.save(active.session, expectedRevision: active.revision) }
                XCTAssertEqual(try Data(contentsOf: file(directory)), beforeStaleWrite)
            }
        }
    }

    func testRecoveryProjectionRetainsRetryGatesUntilExplicitAction() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
            var pending = inFlight(initial.session)
            pending.retryNotBefore = Date(timeIntervalSince1970: 2_000)
            pending.retryRequiresReview = true
            pending.retryPolicy = .retryUncertainWithinBudget
            let active = try await owner.save(pending, expectedRevision: initial.revision)
            let foreign = try WebResearchSessionStore(directory: directory)
            let projected = try await foreign.load(id: active.id)
            XCTAssertEqual(projected.session.retryNotBefore, active.session.retryNotBefore)
            XCTAssertEqual(projected.session.retryRequiresReview, true)
            XCTAssertEqual(projected.session.retryPolicy, active.session.retryPolicy)
            let before = try Data(contentsOf: file(directory)), provider = StoredRecoverySearch()
            let sink = StoredWorkflowCheckpoints(store: foreign, revision: projected.revision)
            let result = try await WebResearchWorkflow(provider: provider, reader: StoredWorkflowReader()).run(projected.session) { try await sink.save($0) }
            XCTAssertEqual(result, projected.session)
            let calls = await provider.calls, checkpoints = await sink.values
            XCTAssertTrue(calls.isEmpty); XCTAssertTrue(checkpoints.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file(directory)), before)
        }
    }

    func testForeignObservationPreservesExactPendingAndCheckedOutputReceipts() async throws {
        try await withDirectory { directory in
            let owner = try WebResearchSessionStore(directory: directory), initial = try await create(owner)
            let pending = try await owner.save(completed(initial.session), expectedRevision: initial.revision)
            let foreign = try WebResearchSessionStore(directory: directory)
            let before = try Data(contentsOf: file(directory))
            _ = try await foreign.list()
            let loadedPending = try await foreign.load(id: pending.id)
            XCTAssertEqual(loadedPending, pending); XCTAssertEqual(try Data(contentsOf: file(directory)), before)
            var session = pending.session; session.outputVerification = .checked
            let checked = try await owner.save(session, expectedRevision: pending.revision)
            let after = try Data(contentsOf: file(directory))
            _ = try await foreign.list()
            let loadedChecked = try await foreign.load(id: checked.id)
            XCTAssertEqual(loadedChecked, checked); XCTAssertEqual(try Data(contentsOf: file(directory)), after)
            await expect(.conflict) { _ = try await foreign.save(pending.session, expectedRevision: pending.revision) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), after)
        }
    }

    func testWorkflowCheckpointsUseOneSharedStoreThroughActualRetrievalBarrier() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let sink = StoredWorkflowCheckpoints(store: store, revision: initial.revision)
            let workflow = WebResearchWorkflow(provider: StoredWorkflowSearch(), reader: StoredWorkflowReader())
            let result = try await workflow.run(initial.session) { try await sink.save($0) }
            XCTAssertEqual(result.stage, .awaitingLocalSynthesis); XCTAssertEqual(result.sources.count, 2)
            let saved = try await store.load(id: result.id)
            XCTAssertEqual(saved.session, result)
            let reopened = try await WebResearchSessionStore(directory: directory).load(id: result.id)
            XCTAssertEqual(reopened, saved)
        }
    }

    func testDeletionDuringSourceRequestRejectsLateWorkflowCheckpoint() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let sink = StoredWorkflowCheckpoints(store: store, revision: initial.revision)
            let reader = StoredWorkflowReader(); await reader.setHold()
            let workflow = WebResearchWorkflow(provider: StoredWorkflowSearch(), reader: reader)
            let task = Task { try await workflow.run(initial.session) { try await sink.save($0) } }
            var waiting = false
            for _ in 0..<2_000 {
                if await reader.waiting() { waiting = true; break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(waiting)
            let active = try await store.load(id: initial.id)
            try await store.delete(id: active.id, expectedRevision: active.revision)
            await reader.release()
            do { _ = try await task.value; XCTFail("Expected deleted checkpoint rejection") }
            catch { XCTAssertEqual(error as? WebResearchError, .checkpointFailed) }
            let list = try await store.list(); XCTAssertTrue(list.isEmpty)
        }
    }
    func testTransientStoreHasNoDiskDestinationOrRestartRecoveryAndUsesCAS() async throws {
        let memory = TransientWebResearchStore()
        let initial = try await memory.create(question: "Temporary question", queries: ["first", "second"])
        XCTAssertEqual(memory.retention, .transient)
        XCTAssertEqual(initial.session.storageMode, .transient)
        let active = try await memory.save(inFlight(initial.session), expectedRevision: initial.revision)
        XCTAssertNotEqual(initial.revision, active.revision)
        await expect(.conflict) { _ = try await memory.save(initial.session, expectedRevision: initial.revision) }
        let loaded = try await memory.load(id: active.id); XCTAssertEqual(loaded, active)
        let restarted = TransientWebResearchStore(), empty = try await restarted.list()
        XCTAssertTrue(empty.isEmpty)
        try await memory.delete(id: active.id, expectedRevision: active.revision)
        await expect(.notFound) { _ = try await memory.save(active.session, expectedRevision: active.revision) }
    }

    func testTransientSessionCannotTouchDurableStoreAndPersistentSessionCannotEnterMemoryStore() async throws {
        try await withDirectory { directory in
            let target = directory.appendingPathComponent("must-not-be-created")
            let disk = try WebResearchSessionStore(directory: target), memory = TransientWebResearchStore()
            let temporary = try await memory.create(question: "Never write this", queries: ["first", "second"])
            await expect(.invalidInput) { _ = try await disk.save(temporary.session, expectedRevision: temporary.revision) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            let saved = try WebResearchSession(question: "Saved mode", queries: ["first", "second"])
            await expect(.invalidInput) { _ = try await memory.save(saved, expectedRevision: UUID()) }
            let remaining = try await memory.list(); XCTAssertEqual(remaining.count, 1)
        }
    }

    func testLegacySessionWithoutRetentionFieldRemainsReadableAsSavedMode() throws {
        let session = try WebResearchSession(question: "Legacy saved session", queries: ["first", "second"])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.encodedCheckpoint()) as? [String: Any])
        json.removeValue(forKey: "retention")
        let decoded = try WebResearchSession.decodeCheckpoint(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.storageMode, .permittedPersistence)
        XCTAssertEqual(decoded.question, session.question)
        XCTAssertNil(decoded.retention)
    }

    func testPartialCoverageCannotBeRewrittenAfterCompletedQueryIsSaved() async throws {
        let memory = TransientWebResearchStore()
        let initial = try await memory.create(question: "Coverage", queries: ["first", "second"])
        var partial = ready(initial.session)
        partial.queries[0].coverage = .partial; partial.queries[0].unavailableEngineIDs = ["duckduckgo"]
        let saved = try await memory.save(partial, expectedRevision: initial.revision)
        var changed = partial; changed.queries[0].coverage = .complete; changed.queries[0].unavailableEngineIDs = []
        await expect(.invalidInput) { _ = try await memory.save(changed, expectedRevision: saved.revision) }
        let actual = try await memory.load(id: saved.id); XCTAssertEqual(actual, saved)
    }

    private func completed(_ session: WebResearchSession) throws -> WebResearchSession {
        let fetched = ready(session)
        let claim = WebResearchClaim(id: UUID(), text: "Fixture conclusion", citationNumbers: [1], confidence: .tentative, dates: [])
        return try fetched.completing(with: WebResearchSynthesis(answer: "Fixture conclusion [1].", claims: [claim],
            citations: [WebResearchCitation(number: 1, sourceID: fetched.sources[0].id, excerpt: "Fixture evidence.")],
            conflicts: [], followUpQueries: []))
    }

    func testPendingOutputReceiptSurvivesRestartWithoutRecoveryMutation() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            let pending = try await store.save(completed(initial.session), expectedRevision: initial.revision)
            XCTAssertEqual(pending.session.outputVerification, .pending)
            let data = try Data(contentsOf: file(directory))
            let restored = try await WebResearchSessionStore(directory: directory).load(id: pending.id)
            XCTAssertEqual(restored, pending)
            XCTAssertEqual(try Data(contentsOf: file(directory)), data)
        }
    }

    func testCheckedReceiptCannotBeMintedWithNewAnswerOrReboundToChangedContent() async throws {
        let store = TransientWebResearchStore()
        let initial = try await store.create(question: "Fixture", queries: ["first", "second"])
        var draft = try completed(initial.session); draft.outputVerification = .checked
        await expect(.invalidInput) { _ = try await store.save(draft, expectedRevision: initial.revision) }
        draft.outputVerification = .pending
        let pending = try await store.save(draft, expectedRevision: initial.revision)
        var checked = pending.session; checked.outputVerification = .checked
        let saved = try await store.save(checked, expectedRevision: pending.revision)
        var changed = checked; changed.updatedAt = changed.updatedAt.addingTimeInterval(1)
        await expect(.invalidInput) { _ = try await store.save(changed, expectedRevision: saved.revision) }
        changed = checked
        let old = try XCTUnwrap(changed.reads[0].source)
        changed.reads[0].source = ResearchSource(id: old.id, originalURL: old.originalURL, finalURL: old.finalURL,
            title: old.title, kind: old.kind, retrievedAt: old.retrievedAt, modifiedAt: old.modifiedAt,
            bytesRead: old.bytesRead, sha256: old.sha256, pagesRead: old.pagesRead,
            text: old.text + " Changed evidence.", truncated: old.truncated, transportReceipt: .httpsOnlyV1)
        await expect(.invalidInput) { _ = try await store.save(changed, expectedRevision: saved.revision) }
        changed = checked; changed.outputVerification = .pending
        await expect(.invalidInput) { _ = try await store.save(changed, expectedRevision: saved.revision) }
        let actual = try await store.load(id: saved.id); XCTAssertEqual(actual, saved)
    }

    func testFollowUpClearsCheckedReceiptAndCannotInheritIt() async throws {
        let store = TransientWebResearchStore()
        let initial = try await store.create(question: "Fixture", queries: ["first", "second"])
        let pending = try await store.save(completed(initial.session), expectedRevision: initial.revision)
        var checked = pending.session; checked.outputVerification = .checked
        let saved = try await store.save(checked, expectedRevision: pending.revision)
        var followUp = try saved.session.addingQueries(["third"])
        XCTAssertNil(followUp.outputVerification)
        followUp.outputVerification = .checked
        XCTAssertThrowsError(try followUp.encodedCheckpoint())
        await expect(.invalidInput) { _ = try await store.save(followUp, expectedRevision: saved.revision) }
        followUp.outputVerification = nil
        let next = try await store.save(followUp, expectedRevision: saved.revision)
        XCTAssertNil(next.session.outputVerification); XCTAssertNil(next.session.synthesis)
    }

    func testLegacyOutputReceiptIsUnknownAndUnknownEnumIsRejected() throws {
        let session = try completed(WebResearchSession(question: "Legacy", queries: ["first", "second"]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: session.encodedCheckpoint()) as? [String: Any])
        json.removeValue(forKey: "outputVerification")
        let legacy = try WebResearchSession.decodeCheckpoint(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.outputVerification); XCTAssertEqual(legacy.synthesis, session.synthesis)
        json["outputVerification"] = "future-verification"
        XCTAssertThrowsError(try WebResearchSession.decodeCheckpoint(JSONSerialization.data(withJSONObject: json)))
    }

    func testUnknownOutputStatePreservesDiskDocumentOnLoadAndDelete() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            _ = try await store.save(completed(initial.session), expectedRevision: initial.revision)
            let data = try Data(contentsOf: file(directory))
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let future = Data(text.replacingOccurrences(of: "\"outputVerification\":\"pending\"",
                with: "\"outputVerification\":\"future\"").utf8)
            XCTAssertNotEqual(data, future)
            try future.write(to: file(directory))
            let reopened = try WebResearchSessionStore(directory: directory)
            await expect(.corrupt) { _ = try await reopened.list() }
            await expect(.corrupt) { try await reopened.deleteAll() }
            XCTAssertEqual(try Data(contentsOf: file(directory)), future)
        }
    }

}
