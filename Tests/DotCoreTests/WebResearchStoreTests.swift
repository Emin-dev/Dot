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
            pagesRead: nil, text: "Actual fixture evidence", truncated: false)
    }
}

private actor StoredWorkflowCheckpoints {
    let store: WebResearchSessionStore
    var revision: UUID
    init(store: WebResearchSessionStore, revision: UUID) { self.store = store; self.revision = revision }
    func save(_ session: WebResearchSession) async throws {
        revision = try await store.save(session, expectedRevision: revision).revision
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
    private func create(_ store: WebResearchSessionStore, question: String = "Public fixture question") async throws -> WebResearchStoredSession {
        try await store.create(question: question, queries: ["primary", "secondary"])
    }
    private func expect(_ expected: WebResearchStoreError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? WebResearchStoreError, expected) }
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
                sha256: String(repeating: "a", count: 64), pagesRead: nil, text: "Fixture evidence.", truncated: false)
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

    func testRestartPersistsUncertainOutcomeAndInvalidatesOldOwnerRevision() async throws {
        try await withDirectory { directory in
            let original = try WebResearchSessionStore(directory: directory), initial = try await create(original)
            let active = try await original.save(inFlight(initial.session), expectedRevision: initial.revision)
            let restarted = try WebResearchSessionStore(directory: directory, now: { Date(timeIntervalSince1970: 700) })
            let recovered = try await restarted.load(id: active.id)
            XCTAssertEqual(recovered.session.stage, .paused)
            XCTAssertEqual(recovered.session.queries[0].status, .uncertain)
            XCTAssertEqual(recovered.session.queries[0].failure, .interruptedOutcomeUnknown)
            XCTAssertEqual(recovered.session.searchAttempts, 1)
            XCTAssertEqual(recovered.session.retryPolicy, .preserveUncertain)
            XCTAssertEqual(recovered.recoveredAt, Date(timeIntervalSince1970: 700))
            XCTAssertNotEqual(recovered.revision, active.revision)
            let normalized = try Data(contentsOf: file(directory))
            let again = try await restarted.load(id: active.id)
            XCTAssertEqual(again, recovered); XCTAssertEqual(try Data(contentsOf: file(directory)), normalized)
            await expect(.conflict) { _ = try await original.save(active.session, expectedRevision: active.revision) }
        }
    }

    func testRestartKeepsCompletedQueriesAndEvidenceButResetsUnfinishedRead() async throws {
        try await withDirectory { directory in
            let store = try WebResearchSessionStore(directory: directory), initial = try await create(store)
            var partial = ready(initial.session); partial.stage = .retrieving
            partial.reads[1].status = .inFlight; partial.reads[1].source = nil
            let active = try await store.save(partial, expectedRevision: initial.revision)
            let recovered = try await WebResearchSessionStore(directory: directory).load(id: active.id)
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

}
