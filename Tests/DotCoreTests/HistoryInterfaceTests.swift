#if !SWIFT_PACKAGE
import XCTest
import AppKit
import Combine

/// Native model/panel tests use isolated text-only files. They never touch real history,
/// the general clipboard, a microphone, or a model runtime.
final class HistoryInterfaceTests: XCTestCase {
    @MainActor func testLifecycleUpdatesOneRowAndKeepsGenerationSeparateUntilFinalPlayback() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.beginAssistant(turn: turn)
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, text: "Complete generated reply", event: .generated)
        await model.flush()
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.records[0].generation, .complete)
        XCTAssertEqual(model.records[0].playback, .notStarted)
        model.recordAssistant(turn: turn, event: .playbackStarted)
        await model.flush()
        XCTAssertEqual(model.records[0].playback, .inProgress)
        model.recordAssistant(turn: turn, event: .playbackCompleted)
        model.recordAssistant(turn: turn, event: .playbackCompleted)
        model.recordAssistant(turn: turn, text: "Late shorter text", event: .interrupted)
        await model.flush()
        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(model.records[0].playback, .completed)
        XCTAssertEqual(model.records[0].text, "Complete generated reply")
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
    }

    @MainActor func testFailureFollowedByGenericCancelRetainsFailureAndPartialText() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, event: .playbackStarted)
        model.recordAssistant(turn: turn, text: "Part of a reply", event: .failed(.voice))
        model.recordAssistant(turn: turn, text: "Later callback", event: .interrupted)
        model.recordAssistant(turn: turn, text: "Must not complete", event: .generated)
        await model.flush()
        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(record.failureStage, .voice); XCTAssertEqual(record.playback, .failed)
        XCTAssertEqual(record.generation, .interrupted); XCTAssertEqual(record.text, "Part of a reply")
        XCTAssertNil(record.playbackCompletedAt)
    }

    @MainActor func testTypedFallbackRemainsActiveUntilFinalTextThenRejectsCallbacksWithoutEnqueueing() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, event: .voiceFailedContinuing)
        await model.flush()
        let pending = try XCTUnwrap(model.records.first)
        XCTAssertEqual(pending.generation, .inProgress); XCTAssertEqual(pending.playback, .failed)
        XCTAssertFalse(pending.isTerminal)
        model.recordAssistant(turn: turn, text: "Complete typed answer despite unavailable voice", event: .generated)
        await model.flush()
        let complete = try XCTUnwrap(model.records.first)
        XCTAssertEqual(complete.generation, .complete); XCTAssertEqual(complete.playback, .failed)
        XCTAssertEqual(complete.text, "Complete typed answer despite unavailable voice")
        XCTAssertNotNil(complete.endedAt); XCTAssertNil(model.error)
        model.recordAssistant(turn: turn, text: "Late callback", event: .interrupted)
        XCTAssertFalse(model.busy, "A terminal fallback turn must release its active mapping")
        let saved = try await ConversationHistoryStore(directory: directory).read()
        XCTAssertEqual(saved, [complete])
    }

    @MainActor func testQueuedTypedVoiceFailureAfterGenerationReleasesItsTurnMapping() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, text: "Complete text", event: .generated)
        model.recordAssistant(turn: turn, event: .voiceFailedContinuing)
        await model.flush()
        let complete = try XCTUnwrap(model.records.first)
        XCTAssertEqual(complete.generation, .complete); XCTAssertEqual(complete.playback, .failed)
        XCTAssertNotNil(complete.endedAt); XCTAssertTrue(complete.isTerminal)
        model.recordAssistant(turn: turn, event: .playbackCompleted)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.records, [complete])
    }

    @MainActor func testTypedFallbackShutdownRetainsLatestPartialAndVoiceFailure() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, text: "Partial at voice failure", event: .voiceFailedContinuing)
        model.recordAssistant(turn: turn, text: "Longer partial at shutdown", event: .interrupted)
        model.closeAdmissions()
        model.recordAssistant(turn: turn, text: "Late complete text", event: .generated)
        await model.flush()
        let records = try await ConversationHistoryStore(directory: directory).read()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.generation, .interrupted); XCTAssertEqual(record.playback, .failed)
        XCTAssertEqual(record.failureStage, .voice); XCTAssertEqual(record.text, "Longer partial at shutdown")
        XCTAssertNil(record.playbackCompletedAt); XCTAssertNotNil(record.endedAt)
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
    }

    @MainActor func testDeleteAndClearRevokePendingCallbacksWithoutResurrection() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), first = UUID(), second = UUID()
        model.beginAssistant(turn: first)
        model.recordAssistant(turn: first, text: "Delete me", event: .generated)
        await model.flush()
        let id = try XCTUnwrap(model.records.first?.id)
        confirmDelete(model, id: id)
        model.recordAssistant(turn: first, event: .playbackStarted)
        model.recordAssistant(turn: first, event: .playbackCompleted)
        model.beginAssistant(turn: second)
        model.recordAssistant(turn: second, event: .playbackStarted)
        confirmClear(model)
        model.recordAssistant(turn: second, text: "Late data", event: .generated)
        model.recordAssistant(turn: second, event: .playbackCompleted)
        await model.flush()
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.error)
    }

    @MainActor func testShutdownFlushPreservesAdmittedPartialInterruptionAndRejectsLaterCompletion() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, event: .playbackStarted)
        model.recordAssistant(turn: turn, text: "Partial before shutdown", event: .interrupted)
        model.closeAdmissions()
        model.recordAssistant(turn: turn, event: .playbackCompleted)
        await model.flush()
        XCTAssertTrue(model.closing); XCTAssertFalse(model.busy)
        let records = try await ConversationHistoryStore(directory: directory).read()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, "Partial before shutdown")
        XCTAssertEqual(records[0].generation, .interrupted); XCTAssertEqual(records[0].playback, .interrupted)
    }

    @MainActor func testCopyIncludesDeliveryStatusAndCannotCopyAfterClosing() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var copied: [String] = []
        let model = ConversationHistoryModel(directory: directory, copyText: { copied.append($0) }), turn = UUID()
        model.beginAssistant(turn: turn)
        model.recordAssistant(turn: turn, text: "Partial words", event: .interrupted)
        await model.flush()
        let record = try XCTUnwrap(model.records.first)
        await model.copy(id: record.id)
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(copied[0].contains("Generation interrupted"))
        XCTAssertTrue(copied[0].contains("Generated text:\nPartial words"))
        model.closeAdmissions()
        await model.copy(id: record.id)
        XCTAssertEqual(copied.count, 1)
    }
    @MainActor private func confirmDelete(_ model: ConversationHistoryModel, id: UUID) {
        guard let prompt = model.requestDelete(id: id) else { return XCTFail("Missing delete confirmation") }
        XCTAssertTrue(model.confirmDeletion(prompt.id))
    }
    @MainActor private func confirmClear(_ model: ConversationHistoryModel) {
        guard let prompt = model.requestClear() else { return XCTFail("Missing clear confirmation") }
        XCTAssertTrue(model.confirmDeletion(prompt.id))
    }

    @MainActor func testDeletionRequiresSingleUseConfirmationAndNewWritesRevokeIt() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory)
        model.append(role: .user, text: "First", turn: UUID()); await model.flush()
        let original = model.records, id = try XCTUnwrap(original.first?.id)
        let cancelled = try XCTUnwrap(model.requestDelete(id: id))
        XCTAssertEqual(model.records, original)
        model.cancelDeletion(); XCTAssertFalse(model.confirmDeletion(cancelled.id))
        let stale = try XCTUnwrap(model.requestClear())
        model.append(role: .user, text: "Newer", turn: UUID()); await model.flush()
        XCTAssertFalse(model.confirmDeletion(stale.id)); XCTAssertEqual(model.records.count, 2)
        let accepted = try XCTUnwrap(model.requestDelete(id: id))
        XCTAssertTrue(model.confirmDeletion(accepted.id)); XCTAssertFalse(model.confirmDeletion(accepted.id))
        await model.flush(); XCTAssertEqual(model.records.map(\.text), ["Newer"])
        let closing = try XCTUnwrap(model.requestClear())
        model.closeAdmissions(); XCTAssertFalse(model.confirmDeletion(closing.id))
        await model.flush(); XCTAssertEqual(model.records.count, 1)
    }

    @MainActor func testPanelDeletionCancelAndLateResponseAfterReopenPreserveRecords() async throws {
        _ = NSApplication.shared
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory)
        model.append(role: .user, text: "Keep until confirmed", turn: UUID()); await model.flush()
        var replies: [LocalRecordDeletionConfirmation.Reply] = []
        let confirmer = LocalRecordDeletionConfirmation(present: { _, _, reply in replies.append(reply) })
        let panel = ConversationHistoryPanel(confirmation: confirmer)
        panel.show(model: model); await model.flush()
        let window = try XCTUnwrap(NSApp.windows.first { ($0.delegate as AnyObject?) === panel })
        defer { window.close() }
        let id = try XCTUnwrap(model.records.first?.id)
        panel.requestDeletion(id: id); XCTAssertEqual(replies.count, 1)
        replies[0](false); await model.flush(); XCTAssertEqual(model.records.count, 1)
        panel.requestDeletion(id: id); XCTAssertEqual(replies.count, 2)
        window.close(); panel.show(model: model); await model.flush()
        replies[1](true); await model.flush(); XCTAssertEqual(model.records.count, 1)
        panel.requestDeletion(id: id); XCTAssertEqual(replies.count, 3)
        replies[2](true); replies[2](true); await model.flush(); XCTAssertTrue(model.records.isEmpty)
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-history-interface-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    @MainActor func testQueuedAppendAndReloadKeepEveryRecordAndStayBusyUntilLastWrite() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory)
        await model.flush()
        XCTAssertNil(model.error); XCTAssertFalse(model.busy)
        var becameIdle = 0
        let observation = model.$busy.dropFirst().sink { busy in if !busy { becameIdle += 1 } }
        defer { observation.cancel() }
        let turn = UUID()
        for index in 0..<24 {
            model.append(role: index.isMultiple(of: 2) ? .user : .assistant,
                         text: "Fixture message \(index)", turn: turn)
            if index.isMultiple(of: 3) { model.reload() }
        }
        XCTAssertTrue(model.busy)
        await model.flush()
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
        XCTAssertEqual(becameIdle, 1, "An earlier queued operation must not enable controls while newer work is pending")
        XCTAssertEqual(model.records.count, 24)
        XCTAssertEqual(Set(model.records.map(\.turnID)), [turn])
        XCTAssertEqual(model.records.map(\.date), model.records.map(\.date).sorted(by: >))
        let reopened = try ConversationHistoryStore(directory: directory)
        let records = try await reopened.read()
        XCTAssertEqual(records.map(\.text), (0..<24).map { "Fixture message \($0)" })
        XCTAssertEqual(records.map(\.role), (0..<24).map { $0.isMultiple(of: 2) ? .user : .assistant })
    }

    @MainActor func testDeleteAndClearAreSerializedWithLaterAppends() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        var deletionNotifications = 0
        model.onDelete = { deletionNotifications += 1 }
        model.append(role: .user, text: "Remove this", turn: turn)
        await model.flush()
        let removed = try XCTUnwrap(model.records.first?.id)
        model.append(role: .assistant, text: "Keep this", turn: turn)
        confirmDelete(model, id: removed)
        model.reload()
        await model.flush()
        XCTAssertEqual(model.records.map(\.text), ["Keep this"])
        XCTAssertEqual(deletionNotifications, 1); XCTAssertNil(model.error)

        model.append(role: .user, text: "Before clear", turn: turn)
        confirmClear(model)
        model.append(role: .assistant, text: "After clear", turn: turn)
        await model.flush()
        XCTAssertEqual(model.records.map(\.text), ["After clear"])
        XCTAssertEqual(deletionNotifications, 2); XCTAssertFalse(model.busy)
        let reopened = try ConversationHistoryStore(directory: directory)
        let records = try await reopened.read()
        XCTAssertEqual(records.map(\.text), ["After clear"])
    }

    @MainActor func testFlushPersistsAlreadyQueuedWorkBeforeShutdownAndReopen() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var original: ConversationHistoryModel? = ConversationHistoryModel(directory: directory)
        let releasedModel = { [weak original] in original }
        let turn = UUID()
        for index in 0..<16 { original?.append(role: .user, text: "Before shutdown \(index)", turn: turn) }
        await original?.flush()
        original = nil
        XCTAssertNil(releasedModel(), "Completed write tasks must not keep the model alive")
        let reopened = ConversationHistoryModel(directory: directory)
        await reopened.flush()
        XCTAssertNil(reopened.error); XCTAssertFalse(reopened.busy)
        XCTAssertEqual(Set(reopened.records.map(\.text)), Set((0..<16).map { "Before shutdown \($0)" }))
        XCTAssertEqual(Set(reopened.records.map(\.turnID)), [turn])
    }

    @MainActor func testCorruptFileAndFailedSaveRetainVisibleRecordsUntilExplicitClear() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.append(role: .user, text: "Previously readable", turn: turn)
        await model.flush()
        let before = model.records
        let file = directory.appendingPathComponent("conversations.json")
        let corrupt = Data("deliberately invalid test history".utf8)
        try corrupt.write(to: file, options: .atomic)
        model.reload(); await model.flush()
        XCTAssertNotNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.records, before)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        model.append(role: .assistant, text: "Must not overwrite corruption", turn: turn)
        await model.flush()
        XCTAssertNotNil(model.error); XCTAssertEqual(model.records, before)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)

        confirmClear(model); await model.flush()
        XCTAssertNil(model.error); XCTAssertTrue(model.records.isEmpty); XCTAssertFalse(model.busy)
        model.append(role: .user, text: "Recovered", turn: turn)
        await model.flush()
        XCTAssertNil(model.error); XCTAssertEqual(model.records.map(\.text), ["Recovered"])
        let reopened = try ConversationHistoryStore(directory: directory)
        let records = try await reopened.read()
        XCTAssertEqual(records.map(\.text), ["Recovered"])
    }

    @MainActor func testRejectedOversizedAppendRetainsExistingTextAndNextValidWriteRecovers() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory), turn = UUID()
        model.append(role: .user, text: "Keep me", turn: turn)
        await model.flush()
        let before = model.records
        model.append(role: .assistant, text: String(repeating: "x", count: 65_537), turn: turn)
        await model.flush()
        XCTAssertNotNil(model.error); XCTAssertEqual(model.records, before); XCTAssertFalse(model.busy)
        model.append(role: .assistant, text: "Valid retry", turn: turn)
        await model.flush()
        XCTAssertNil(model.error); XCTAssertEqual(Set(model.records.map(\.text)), ["Keep me", "Valid retry"])
    }

    @MainActor func testBlankAppendIsIgnoredAndUnopenableDirectoryPreservesFixture() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory)
        await model.flush()
        model.append(role: .user, text: " \n\t ", turn: UUID())
        XCTAssertFalse(model.busy); XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.error)

        let nonDirectory = directory.appendingPathComponent("ordinary-file")
        let sentinel = Data("unrelated fixture".utf8)
        try sentinel.write(to: nonDirectory)
        let unavailable = ConversationHistoryModel(directory: nonDirectory)
        unavailable.append(role: .user, text: "Not written", turn: UUID())
        await unavailable.flush()
        XCTAssertNotNil(unavailable.error); XCTAssertFalse(unavailable.busy); XCTAssertTrue(unavailable.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: nonDirectory), sentinel)
    }

    @MainActor func testExplicitCopyWaitsForQueuedWritesAndMissingEntryCannotChangeClipboard() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var copied: [String] = []
        let model = ConversationHistoryModel(directory: directory, copyText: { copied.append($0) })
        let turn = UUID(), original = "Exact local text.\nSecond line with Unicode: café."
        model.append(role: .assistant, text: original, turn: turn)
        await model.flush()
        let selected = try XCTUnwrap(model.records.first?.id)
        for index in 0..<8 { model.append(role: .user, text: "Later \(index)", turn: turn) }
        await model.copy(id: selected)
        XCTAssertEqual(copied.count, 1); XCTAssertTrue(copied[0].hasSuffix(original)); XCTAssertTrue(copied[0].contains("Delivery unknown")); XCTAssertNil(model.error)
        XCTAssertEqual(model.records.count, 9); XCTAssertFalse(model.busy)
        let before = model.records
        await model.copy(id: UUID())
        XCTAssertEqual(copied.count, 1); XCTAssertTrue(copied[0].hasSuffix(original)); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.records, before)
        model.reload(); await model.flush()
        XCTAssertNil(model.error)
        confirmDelete(model, id: selected)
        await model.copy(id: selected)
        XCTAssertEqual(copied.count, 1, "A copy ordered after deletion must not return stale cached text")
        XCTAssertNotNil(model.error); XCTAssertFalse(model.records.contains { $0.id == selected })
    }

    @MainActor func testClosingDrainsAdmittedWritesAndRejectsLaterEditsAndCopy() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var copied: [String] = []
        var deletions = 0
        let model = ConversationHistoryModel(directory: directory, copyText: { copied.append($0) })
        model.onDelete = { deletions += 1 }
        model.append(role: .user, text: "Admitted before closing", turn: UUID())
        await model.flush()
        let original = try XCTUnwrap(model.records.first?.id)
        model.append(role: .assistant, text: "Also admitted", turn: UUID())
        model.closeAdmissions()
        model.append(role: .user, text: "Rejected after closing", turn: UUID())
        XCTAssertNil(model.requestDelete(id: original)); XCTAssertNil(model.requestClear()); model.reload()
        await model.copy(id: original)
        await model.flush()
        XCTAssertTrue(model.closing); XCTAssertFalse(model.busy)
        XCTAssertTrue(copied.isEmpty); XCTAssertEqual(deletions, 0)
        let reopened = try ConversationHistoryStore(directory: directory)
        let saved = try await reopened.read()
        XCTAssertEqual(saved.map(\.text), ["Admitted before closing", "Also admitted"])
    }

    @MainActor func testHistoryPanelReusesItsWindowAndReportsOpenCloseVisibility() async throws {
        _ = NSApplication.shared
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConversationHistoryModel(directory: directory)
        await model.flush()
        let controller = ConversationHistoryPanel()
        var visibility: [Bool] = []
        controller.onVisibility = { visibility.append($0) }
        controller.show(model: model)
        let window = try XCTUnwrap(NSApp.windows.first { ($0.delegate as AnyObject?) === controller })
        defer { window.close() }
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.styleMask.contains(.closable)); XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        controller.show(model: model)
        XCTAssertEqual(NSApp.windows.filter { ($0.delegate as AnyObject?) === controller }.count, 1)
        window.close(); XCTAssertFalse(window.isVisible)
        XCTAssertEqual(visibility, [true, true, false])
        controller.show(model: model)
        let reopened = try XCTUnwrap(NSApp.windows.first { ($0.delegate as AnyObject?) === controller })
        XCTAssertTrue(reopened === window); XCTAssertTrue(reopened.isVisible)
        window.close(); XCTAssertEqual(visibility, [true, true, false, true, false])
        await model.flush()
    }
}
#endif
