import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class ConversationHistoryTests: XCTestCase {
    private func assistant(_ store: ConversationHistoryStore) async throws -> ConversationHistoryRecord {
        let records = try await store.read()
        return try XCTUnwrap(records.first { $0.role == .assistant })
    }

    func testLegacyReadIsUnchangedAndFirstMutationPreservesExactBackup() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            let old = [fixture("Old user"), fixture("Old generated response", role: "assistant")]
            let original = try write(directory, records: old)
            let before = try await store.read()
            XCTAssertEqual(before.map(\.text), ["Old user", "Old generated response"])
            XCTAssertEqual(before[1].generation, .unknown); XCTAssertEqual(before[1].playback, .unknown)
            XCTAssertEqual(try Data(contentsOf: file(directory)), original)
            let backup = directory.appendingPathComponent("conversations.schema1.backup.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            _ = try await store.append(role: .user, text: "New user", turnID: UUID())
            XCTAssertEqual(try Data(contentsOf: backup), original)
            let after = try await store.read()
            XCTAssertEqual(Array(after.prefix(2)), before)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file(directory))) as? [String: Any])
            XCTAssertEqual(document["schemaVersion"] as? Int, 2)
        }
    }

    func testExplicitDeletionRetiresMigrationBackupSoDeletedTextIsNotRetainedThere() async throws {
        for clear in [false, true] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory)
                _ = try write(directory, records: [fixture("Remove this", role: "assistant")])
                _ = try await store.append(role: .user, text: "Keep this", turnID: UUID())
                let old = try await assistant(store)
                if clear { try await store.clear() } else { _ = try await store.delete(id: old.id) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations.schema1.backup.json").path))
                let text = String(decoding: try Data(contentsOf: file(directory)), as: UTF8.self)
                XCTAssertFalse(text.contains("Remove this"))
            }
        }
    }

    func testConflictingLegacyBackupCannotBeOverwrittenDuringConversion() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            let original = try write(directory, records: [fixture()])
            let backup = directory.appendingPathComponent("conversations.schema1.backup.json")
            let previous = Data("Preserve prior backup".utf8); try previous.write(to: backup)
            await expect(.unavailable) { _ = try await store.append(role: .user, text: "New", turnID: UUID()) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), original)
            XCTAssertEqual(try Data(contentsOf: backup), previous)
        }
    }

    func testGenerationAndPlaybackAreSeparateUntilFinalEvidence() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            let pending = try await assistant(store)
            XCTAssertEqual(pending.generation, .inProgress); XCTAssertEqual(pending.playback, .notStarted)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Generated answer", event: .generated)
            let generated = try await assistant(store)
            XCTAssertEqual(generated.generation, .complete); XCTAssertEqual(generated.playback, .notStarted)
            XCTAssertNil(generated.playbackCompletedAt)
            let premature = try await store.recordAssistant(id: id, turnID: turn, event: .playbackCompleted)
            XCTAssertFalse(premature)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .playbackStarted)
            let playing = try await assistant(store)
            XCTAssertEqual(playing.playback, .inProgress); XCTAssertNil(playing.playbackCompletedAt)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .playbackCompleted)
            let complete = try await assistant(store)
            XCTAssertEqual(complete.playback, .completed); XCTAssertNotNil(complete.playbackCompletedAt)
            XCTAssertTrue(complete.statusSummary.contains("Playback completed"))
            XCTAssertTrue(complete.deliveryExplanation.contains("does not establish that the user heard"))
            let reopened = try await ConversationHistoryStore(directory: directory).read()
            XCTAssertEqual(reopened, [complete])
        }
    }

    func testPlaybackMayStartBeforeGenerationCompletesButCannotFinishTheRecordEarly() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .playbackStarted)
            let premature = try await store.recordAssistant(id: id, turnID: turn, event: .playbackCompleted)
            XCTAssertFalse(premature)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Whole answer", event: .generated)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .playbackCompleted)
            let complete = try await assistant(store)
            XCTAssertEqual(complete.text, "Whole answer"); XCTAssertEqual(complete.playback, .completed)
        }
    }

    func testInterruptionKeepsPartialGeneratedTextAndLateCallbacksCannotUpgradeIt() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .playbackStarted)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Partial generated words", event: .interrupted)
            let interrupted = try await assistant(store)
            XCTAssertEqual(interrupted.generation, .interrupted); XCTAssertEqual(interrupted.playback, .interrupted)
            XCTAssertEqual(interrupted.text, "Partial generated words"); XCTAssertNil(interrupted.playbackCompletedAt)
            for event in [ConversationHistoryEvent.generated, .playbackStarted, .playbackCompleted, .interrupted, .failed(.voice)] {
                let changed = try await store.recordAssistant(id: id, turnID: turn, text: "Late replacement", event: event)
                XCTAssertFalse(changed)
            }
            let after = try await assistant(store)
            XCTAssertEqual(after, interrupted)
            let copy = try await store.textToCopy(id: id)
            XCTAssertTrue(copy.contains("Generation interrupted")); XCTAssertTrue(copy.contains("Generated text:\nPartial generated words"))
        }
    }

    func testVoiceFailureKeepsCompleteGeneratedAnswerAndCannotBecomeGenericInterruption() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Complete generated answer", event: .generated)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .failed(.voice))
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Shorter partial", event: .interrupted)
            let failed = try await assistant(store)
            XCTAssertEqual(failed.generation, .complete); XCTAssertEqual(failed.playback, .failed)
            XCTAssertEqual(failed.failureStage, .voice); XCTAssertEqual(failed.text, "Complete generated answer")
        }
    }

    func testTypedVoiceFailureKeepsGenerationOpenThenSavesCompleteText() async throws {
        for started in [false, true] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
                try await store.beginAssistant(id: id, turnID: turn)
                if started { _ = try await store.recordAssistant(id: id, turnID: turn, event: .playbackStarted) }
                _ = try await store.recordAssistant(id: id, turnID: turn, text: started ? "Partial" : nil,
                                                    event: .voiceFailedContinuing)
                let pending = try await assistant(store)
                XCTAssertEqual(pending.generation, .inProgress); XCTAssertEqual(pending.playback, .failed)
                XCTAssertEqual(pending.failureStage, .voice); XCTAssertNil(pending.endedAt)
                XCTAssertEqual(pending.playbackStartedAt != nil, started)
                XCTAssertFalse(pending.isTerminal)
                for event in [ConversationHistoryEvent.voiceFailedContinuing, .playbackStarted, .playbackCompleted] {
                    let changed = try await store.recordAssistant(id: id, turnID: turn, text: "Stale partial", event: event)
                    XCTAssertFalse(changed)
                }
                let unchanged = try await assistant(store)
                XCTAssertEqual(unchanged, pending)
                let finishedAt = Date(timeIntervalSince1970: 1_800_000_100)
                _ = try await store.recordAssistant(id: id, turnID: turn, text: "Full generated answer after voice failure",
                                                    event: .generated, date: finishedAt)
                let complete = try await assistant(store)
                XCTAssertEqual(complete.generation, .complete); XCTAssertEqual(complete.playback, .failed)
                XCTAssertEqual(complete.failureStage, .voice); XCTAssertEqual(complete.generationCompletedAt, finishedAt)
                XCTAssertEqual(complete.endedAt, finishedAt); XCTAssertNil(complete.playbackCompletedAt)
                XCTAssertEqual(complete.text, "Full generated answer after voice failure"); XCTAssertTrue(complete.isTerminal)
                for event in [ConversationHistoryEvent.generated, .voiceFailedContinuing, .playbackCompleted, .interrupted] {
                    let changed = try await store.recordAssistant(id: id, turnID: turn, text: "Late replacement", event: event)
                    XCTAssertFalse(changed)
                }
                let reopened = try await ConversationHistoryStore(directory: directory).read()
                XCTAssertEqual(reopened, [complete])
                let copy = try await store.textToCopy(id: id)
                XCTAssertTrue(copy.contains("Generated response · Voice failed"))
                XCTAssertFalse(copy.contains("Playback completed"))
            }
        }
    }

    func testTypedVoiceFailureAfterGenerationIsImmediatelyTerminal() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Complete response", event: .generated)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Older partial", event: .voiceFailedContinuing)
            let failed = try await assistant(store)
            XCTAssertEqual(failed.text, "Complete response"); XCTAssertEqual(failed.generation, .complete)
            XCTAssertEqual(failed.playback, .failed); XCTAssertEqual(failed.failureStage, .voice)
            XCTAssertNotNil(failed.endedAt); XCTAssertTrue(failed.isTerminal)
            let late = try await store.recordAssistant(id: id, turnID: turn, event: .playbackCompleted)
            XCTAssertFalse(late)
        }
    }

    func testTypedFallbackInterruptionAndGenerationFailureKeepVoiceFailure() async throws {
        for event in [ConversationHistoryEvent.interrupted, .failed(.generation)] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
                try await store.beginAssistant(id: id, turnID: turn)
                _ = try await store.recordAssistant(id: id, turnID: turn, text: "Early text", event: .voiceFailedContinuing)
                _ = try await store.recordAssistant(id: id, turnID: turn, text: "Latest partial text", event: event)
                let failed = try await assistant(store)
                XCTAssertEqual(failed.generation, event == .interrupted ? .interrupted : .failed)
                XCTAssertEqual(failed.failureStage, event == .interrupted ? .voice : .generation)
                XCTAssertEqual(failed.playback, .failed); XCTAssertEqual(failed.text, "Latest partial text")
                XCTAssertNotNil(failed.endedAt); XCTAssertNil(failed.generationCompletedAt)
                XCTAssertTrue(failed.isTerminal)
                let late = try await store.recordAssistant(id: id, turnID: turn, text: "Late full text", event: .generated)
                XCTAssertFalse(late)
            }
        }
    }

    func testTypedVoiceFailureRestartMarksGenerationIncompleteButPreservesDeliveryFailure() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "Partial before crash", event: .voiceFailedContinuing)
            let bytes = try Data(contentsOf: file(directory))
            let reopened = try ConversationHistoryStore(directory: directory)
            let record = try await assistant(reopened)
            XCTAssertEqual(record.generation, .incomplete); XCTAssertEqual(record.playback, .failed)
            XCTAssertEqual(record.failureStage, .voice); XCTAssertEqual(record.text, "Partial before crash")
            XCTAssertNil(record.endedAt); XCTAssertNil(record.generationCompletedAt)
            XCTAssertTrue(record.isTerminal); XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
            let late = try await reopened.recordAssistant(id: id, turnID: turn, text: "Cannot resume old generation", event: .generated)
            XCTAssertFalse(late)
            _ = try await reopened.append(role: .user, text: "Next conversation", turnID: UUID())
            let reread = try await ConversationHistoryStore(directory: directory).read()
            XCTAssertEqual(reread.first, record)
        }
    }

    func testDeleteOrClearContinuingVoiceFailurePreventsLateTextResurrection() async throws {
        for clear in [false, true] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
                try await store.beginAssistant(id: id, turnID: turn)
                _ = try await store.recordAssistant(id: id, turnID: turn, text: "Delete this partial", event: .voiceFailedContinuing)
                if clear { try await store.clear() } else { _ = try await store.delete(id: id) }
                let changed = try await store.recordAssistant(id: id, turnID: turn, text: "Late generated answer", event: .generated)
                XCTAssertFalse(changed)
                let records = try await store.read()
                XCTAssertTrue(records.isEmpty)
            }
        }
    }

    func testGenerationFailureBeforeAnyTextRemainsVisibleAndDoesNotInventSpeech() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, event: .failed(.generation))
            let failed = try await assistant(store)
            XCTAssertEqual(failed.generation, .failed); XCTAssertEqual(failed.failureStage, .generation)
            XCTAssertTrue(failed.text.isEmpty); XCTAssertNil(failed.playbackStartedAt); XCTAssertNil(failed.playbackCompletedAt)
        }
    }

    func testReopenOfUnfinishedRecordReportsIncompleteAndUnknownWithoutInventedCompletion() async throws {
        for generated in [false, true] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
                try await store.beginAssistant(id: id, turnID: turn)
                _ = try await store.recordAssistant(id: id, turnID: turn, text: "Partial text", event: .playbackStarted)
                if generated { _ = try await store.recordAssistant(id: id, turnID: turn, text: "Final generated text", event: .generated) }
                let bytes = try Data(contentsOf: file(directory))
                let reopened = try ConversationHistoryStore(directory: directory)
                let record = try await assistant(reopened)
                XCTAssertEqual(record.generation, generated ? .complete : .incomplete)
                XCTAssertEqual(record.playback, .unknown); XCTAssertNil(record.playbackCompletedAt)
                XCTAssertEqual(try Data(contentsOf: file(directory)), bytes, "Reading recovery must not rewrite the original")
                let stale = try await reopened.recordAssistant(id: id, turnID: turn, event: .playbackCompleted)
                XCTAssertFalse(stale)
            }
        }
    }

    func testUnknownTurnDeletedRecordAndDuplicateBeginCannotCreateOrReplaceHistory() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), id = UUID(), turn = UUID()
            let absent = try await store.recordAssistant(id: id, turnID: turn, text: "Late", event: .generated)
            XCTAssertFalse(absent)
            try await store.beginAssistant(id: id, turnID: turn)
            try await store.beginAssistant(id: UUID(), turnID: turn)
            let wrong = try await store.recordAssistant(id: id, turnID: UUID(), event: .playbackStarted)
            XCTAssertFalse(wrong)
            let records = try await store.read(); XCTAssertEqual(records.count, 1)
            _ = try await store.delete(id: id)
            let stale = try await store.recordAssistant(id: id, turnID: turn, text: "Resurrected", event: .generated)
            XCTAssertFalse(stale)
            let deleted = try await store.read(); XCTAssertTrue(deleted.isEmpty)
        }
    }

    func testOversizedPartialTextIsBoundedAtUTF8BoundaryAndClearlyLabelled() async throws {
        try await withDirectory { directory in
            let limits = ConversationHistoryStore.Limits(maxRecords: 2, maxTextBytes: 5, maxTotalTextBytes: 10, maxFileBytes: 4_096)
            let store = try ConversationHistoryStore(directory: directory, limits: limits), id = UUID(), turn = UUID()
            try await store.beginAssistant(id: id, turnID: turn)
            _ = try await store.recordAssistant(id: id, turnID: turn, text: "🐈🐈long", event: .interrupted)
            let record = try await assistant(store)
            XCTAssertEqual(record.text, "🐈"); XCTAssertTrue(record.textTruncated)
            XCTAssertTrue(record.deliveryExplanation.contains("shortened"))
        }
    }
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-history-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
    private func file(_ directory: URL) -> URL { directory.appendingPathComponent("conversations.json") }
    private func fixture(_ text: String = "Saved text", id: UUID = UUID(), role: String = "user") -> [String: Any] {
        ["id": id.uuidString, "date": 1_700_000_000_000.0, "role": role, "text": text, "turnID": UUID().uuidString]
    }
    private func write(_ directory: URL, version: Int = 1, records: [[String: Any]]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "records": records], options: [.sortedKeys])
        try data.write(to: file(directory)); return data
    }
    private func expect(_ expected: ConversationHistoryError, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ConversationHistoryError, expected, file: file, line: line) }
    }

    func testMissingFileMigratesToVersionedStoreOnlyOnFirstAppend() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            let empty = try await store.read()
            XCTAssertTrue(empty.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file(directory).path))
            let entry = try await store.append(role: .user, text: "Hello", turnID: UUID())
            let restored = try await ConversationHistoryStore(directory: directory).read()
            XCTAssertEqual(restored, [entry])
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file(directory))) as? [String: Any])
            XCTAssertEqual(document["schemaVersion"] as? Int, 2)
        }
    }
    func testReopeningPreservesIDsRolesTurnsDatesAndExactText() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory), turn = UUID()
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let user = try await store.append(role: .user, text: "Hello\nSecond line 🐈", turnID: turn, date: date)
            let response = try await store.append(role: .assistant, text: "  Answer with spacing.  ", turnID: turn, date: date.addingTimeInterval(5))
            let reopened = try ConversationHistoryStore(directory: directory)
            let records = try await reopened.read()
            XCTAssertEqual(records, [user, response])
            let copied = try await reopened.textToCopy(id: response.id)
            XCTAssertTrue(copied.hasSuffix(response.text))
            XCTAssertTrue(copied.contains("Delivery unknown"))
            XCTAssertTrue(copied.contains("Generated text:"))
            let all = try await reopened.textToCopy()
            XCTAssertTrue(all.contains("You\nHello\nSecond line 🐈"))
            XCTAssertTrue(all.contains("Generated text:\n  Answer with spacing.  "))
            XCTAssertTrue(all.contains("2023-11-14T22:13:20Z"))
        }
    }
    func testDeleteAndClearPersistWithoutChangingOtherEntries() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            let first = try await store.append(role: .user, text: "First", turnID: UUID())
            let second = try await store.append(role: .assistant, text: "Second", turnID: UUID())
            let removed = try await store.delete(id: first.id)
            XCTAssertTrue(removed)
            let missing = try await store.delete(id: UUID())
            XCTAssertFalse(missing)
            let retained = try await ConversationHistoryStore(directory: directory).read()
            XCTAssertEqual(retained, [second])
            await expect(.notFound) { _ = try await store.textToCopy(id: first.id) }
            try await store.clear()
            let cleared = try await ConversationHistoryStore(directory: directory).read()
            XCTAssertTrue(cleared.isEmpty)
        }
    }
    func testHistoryDirectoryAndFileHavePrivatePermissions() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            try await store.append(role: .user, text: "Private", turnID: UUID())
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: file(directory).path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let content = String(decoding: try Data(contentsOf: file(directory)), as: UTF8.self)
            XCTAssertFalse(content.contains("audio"))
            XCTAssertFalse(content.contains("screenshot"))
        }
    }
    func testTruncatedFileBlocksOrdinaryWritesAndIsPreservedUntilExplicitClear() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            let broken = Data(#"{"schemaVersion":1,"records":["#.utf8)
            try broken.write(to: file(directory))
            await expect(.corrupt) { _ = try await store.read() }
            await expect(.corrupt) { _ = try await store.append(role: .user, text: "New", turnID: UUID()) }
            await expect(.corrupt) { _ = try await store.delete(id: UUID()) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), broken)
            try await store.clear()
            let cleared = try await store.read()
            XCTAssertTrue(cleared.isEmpty)
        }
    }
    func testFutureAndUnknownSchemasArePreservedWithoutInventedMigration() async throws {
        for version in [0, 3, 999] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory)
                let original = try write(directory, version: version, records: [fixture()])
                await expect(.unsupportedVersion(version)) { _ = try await store.read() }
                await expect(.unsupportedVersion(version)) { _ = try await store.append(role: .assistant, text: "New", turnID: UUID()) }
                XCTAssertEqual(try Data(contentsOf: file(directory)), original)
            }
        }
    }
    func testMalformedRoleEmptyTextAndDuplicateIDsAreRejectedWithoutDeletingData() async throws {
        let id = UUID()
        for records in [[fixture(role: "system")], [fixture(" \n")], [fixture(id: id), fixture(id: id)]] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory)
                let original = try write(directory, records: records)
                await expect(.corrupt) { _ = try await store.read() }
                XCTAssertEqual(try Data(contentsOf: file(directory)), original)
            }
        }
    }
    func testPerRecordUTF8LimitRejectsOversizeInputWithoutCreatingFile() async throws {
        try await withDirectory { directory in
            let limits = ConversationHistoryStore.Limits(maxRecords: 2, maxTextBytes: 4, maxTotalTextBytes: 8, maxFileBytes: 4_096)
            let store = try ConversationHistoryStore(directory: directory, limits: limits)
            await expect(.invalidText) { _ = try await store.append(role: .user, text: "🐈a", turnID: UUID()) }
            await expect(.invalidText) { _ = try await store.append(role: .user, text: "  \n", turnID: UUID()) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file(directory).path))
            try await store.append(role: .user, text: "🐈", turnID: UUID())
            let records = try await store.read()
            XCTAssertEqual(records.count, 1)
        }
    }
    func testRecordAndTotalTextBudgetsNeverSilentlyRemoveSavedHistory() async throws {
        for limits in [ConversationHistoryStore.Limits(maxRecords: 1, maxTextBytes: 8, maxTotalTextBytes: 32, maxFileBytes: 4_096),
                       ConversationHistoryStore.Limits(maxRecords: 5, maxTextBytes: 8, maxTotalTextBytes: 6, maxFileBytes: 4_096)] {
            try await withDirectory { directory in
                let store = try ConversationHistoryStore(directory: directory, limits: limits)
                let first = try await store.append(role: .user, text: "First", turnID: UUID())
                let before = try Data(contentsOf: file(directory))
                await expect(.capacityExceeded) { _ = try await store.append(role: .assistant, text: "Next", turnID: UUID()) }
                XCTAssertEqual(try Data(contentsOf: file(directory)), before)
                let retained = try await store.read()
                XCTAssertEqual(retained, [first])
            }
        }
    }
    func testOversizedFileAndArrayAreRejectedBeforeUnboundedRecordDecoding() async throws {
        try await withDirectory { directory in
            let limits = ConversationHistoryStore.Limits(maxRecords: 2, maxTextBytes: 100, maxTotalTextBytes: 200, maxFileBytes: 1_024)
            let store = try ConversationHistoryStore(directory: directory, limits: limits)
            let tooLarge = Data(repeating: 0x20, count: 1_025)
            try tooLarge.write(to: file(directory))
            await expect(.capacityExceeded) { _ = try await store.read() }
            XCTAssertEqual(try Data(contentsOf: file(directory)), tooLarge)
            let oversizedArray = try write(directory, records: [fixture(), fixture(), fixture()])
            await expect(.capacityExceeded) { _ = try await store.read() }
            XCTAssertEqual(try Data(contentsOf: file(directory)), oversizedArray)
        }
    }
    func testEncodedFileBudgetPreservesExistingFileWhenEscapingGrowsText() async throws {
        try await withDirectory { directory in
            let limits = ConversationHistoryStore.Limits(maxRecords: 4, maxTextBytes: 200, maxTotalTextBytes: 400, maxFileBytes: 400)
            let store = try ConversationHistoryStore(directory: directory, limits: limits)
            try await store.append(role: .user, text: "First", turnID: UUID())
            let before = try Data(contentsOf: file(directory))
            await expect(.capacityExceeded) {
                _ = try await store.append(role: .assistant, text: String(repeating: "\u{0001}", count: 100), turnID: UUID())
            }
            XCTAssertEqual(try Data(contentsOf: file(directory)), before)
        }
    }
    func testFileSymlinkIsNeverFollowedOrOverwrittenEvenByClear() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            let target = directory.appendingPathComponent("unrelated.txt")
            let original = Data("Leave this alone".utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: file(directory), withDestinationURL: target)
            await expect(.unsafeStorage) { _ = try await store.read() }
            await expect(.unsafeStorage) { try await store.clear() }
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file(directory).path), target.path)
        }
    }
    func testDanglingFileSymlinkAndDirectorySymlinkAreRejected() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            try FileManager.default.createSymbolicLink(at: file(directory), withDestinationURL: directory.appendingPathComponent("missing"))
            await expect(.unsafeStorage) { try await store.clear() }
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            XCTAssertThrowsError(try ConversationHistoryStore(directory: alias)) {
                XCTAssertEqual($0 as? ConversationHistoryError, .unsafeStorage)
            }
        }
    }
    func testConcurrentAppendsOnTheStoreDoNotLoseRecords() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask { try await store.append(role: .user, text: "Entry \(index)", turnID: UUID()); return () }
                }
                try await group.waitForAll()
            }
            let records = try await ConversationHistoryStore(directory: directory).read()
            XCTAssertEqual(records.count, 20)
            XCTAssertEqual(Set(records.map(\.text)), Set((0..<20).map { "Entry \($0)" }))
        }
    }
    func testExternalCorruptionAfterReadIsNotOverwrittenByCachedState() async throws {
        try await withDirectory { directory in
            let store = try ConversationHistoryStore(directory: directory)
            try await store.append(role: .user, text: "First", turnID: UUID())
            _ = try await store.read()
            let replacement = Data("external malformed content".utf8)
            try replacement.write(to: file(directory))
            await expect(.corrupt) { _ = try await store.append(role: .user, text: "Second", turnID: UUID()) }
            XCTAssertEqual(try Data(contentsOf: file(directory)), replacement)
        }
    }
}
