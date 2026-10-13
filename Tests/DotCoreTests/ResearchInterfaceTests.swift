#if !SWIFT_PACKAGE
import XCTest
import AppKit

/// Exercises production native model actions without opening real browsers,
/// touching the general clipboard, reading personal files or calling the network.
final class ResearchInterfaceTests: XCTestCase {
    @MainActor func testRealStoreCreateReadCopyExportDeleteAndReopen() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs"), saved = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
        try Data("# Fixture evidence\nQuoted instructions remain data.".utf8).write(to: inputs.appendingPathComponent("source.md"))
        var copied: [String] = []
        let model = ResearchNotebookModel(directory: saved, copyText: { copied.append($0) })
        model.title = "Fixture brief"; model.selectFolder(inputs)
        model.create(); XCTAssertTrue(model.busy); await model.flush()
        let notebook = try XCTUnwrap(model.selected)
        XCTAssertEqual(notebook.sources.count, 1); XCTAssertFalse(model.busy); XCTAssertNil(model.error)
        XCTAssertEqual(notebook.sources[0].sha256.count, 64)
        XCTAssertNotNil(notebook.sources[0].modifiedAt)
        XCTAssertTrue(notebook.briefMarkdown.contains("not independently verified conclusions"))
        await model.copySelected(); XCTAssertEqual(copied, [notebook.briefMarkdown])
        let exported = root.appendingPathComponent("evidence.md")
        model.exportSelected(to: exported); await model.flush()
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), notebook.briefMarkdown)
        let reopened = ResearchNotebookModel(directory: saved, copyText: { _ in XCTFail("Unexpected copy") })
        reopened.open(); await reopened.flush()
        XCTAssertEqual(reopened.selected, notebook)
        confirmDelete(reopened); await reopened.flush()
        XCTAssertTrue(reopened.notebooks.isEmpty); XCTAssertNil(reopened.selection); XCTAssertNil(reopened.error)
        model.reload(); await model.flush(); XCTAssertTrue(model.notebooks.isEmpty)
    }

    @MainActor func testURLAndNativeInputBoundsRejectUnsupportedRequests() throws {
        XCTAssertEqual(try ResearchNotebookModel.parseURLs("https://example.org/a\nhttps://example.org/b").count, 2)
        for value in ["file:///tmp/test", "javascript:alert(1)", "http://localhost", "https://user:password@example.org"] {
            XCTAssertThrowsError(try ResearchNotebookModel.parseURLs(value))
        }
        XCTAssertThrowsError(try ResearchNotebookModel.parseURLs(Array(repeating: "https://example.org", count: 11).joined(separator: "\n")))
        XCTAssertThrowsError(try ResearchNotebookModel.parseURLs(String(repeating: "x", count: 81_921)))
        let model = ResearchNotebookModel(store: ControlledResearchStore())
        model.title = String(repeating: "a", count: 201); XCTAssertEqual(model.title.count, 200)
        model.title = "a" + String(repeating: "\u{301}", count: 1_000)
        XCTAssertLessThanOrEqual(model.title.utf8.count, 800)
        model.urlText = String(repeating: "🇬🇧", count: 11_000)
        XCTAssertLessThanOrEqual(model.urlText.utf8.count, 81_920)
        XCTAssertFalse(model.urlText.contains("\u{fffd}")); XCTAssertNotNil(model.error)
    }

    @MainActor func testBusyCreateIsSingleFlightAndCancelSuppressesLateResult() async throws {
        let fixture = ControlledResearchStore()
        await fixture.pauseCreate()
        let model = ResearchNotebookModel(store: fixture)
        model.urlText = "https://example.org/source"; model.create(); model.create()
        try await eventually { await fixture.createCount == 1 }
        XCTAssertTrue(model.busy); XCTAssertFalse(model.canCreate)
        model.cancel(); XCTAssertFalse(model.busy)
        await fixture.releaseCreate()
        try await eventually { await fixture.completedCreates == 1 }
        await Task.yield()
        XCTAssertTrue(model.notebooks.isEmpty); XCTAssertNil(model.error)
        XCTAssertFalse(model.notice?.contains("saved on this Mac") == true)
        model.reload(); await model.flush()
        XCTAssertEqual(model.notebooks.count, 1, "Refresh honestly reveals an operation committed before its cancelled callback returned")
    }

    @MainActor func testDelayedCopyCannotWriteAfterCancellationOrClosing() async throws {
        for close in [false, true] {
            let fixture = ControlledResearchStore(records: [notebook()])
            await fixture.pauseCopy()
            var copied: [String] = []
            let model = ResearchNotebookModel(store: fixture, copyText: { copied.append($0) })
            model.open(); await model.flush()
            let copying = Task { await model.copySelected() }
            try await eventually { await fixture.copyCount == 1 }
            if close { model.close() } else { model.cancel() }
            await fixture.releaseCopies(); await copying.value
            XCTAssertTrue(copied.isEmpty); XCTAssertNil(model.error)
        }
    }

    @MainActor func testDelayedCopyCannotWriteAfterDeletion() async throws {
        let fixture = ControlledResearchStore(records: [notebook()])
        await fixture.pauseCopy()
        var copied: [String] = []
        let model = ResearchNotebookModel(store: fixture, copyText: { copied.append($0) })
        model.open(); await model.flush()
        let copying = Task { await model.copySelected() }
        try await eventually { await fixture.copyCount == 1 }
        confirmDelete(model); await model.flush()
        await fixture.releaseCopies(); await copying.value
        XCTAssertTrue(model.notebooks.isEmpty); XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(model.notice, "Notebook deleted.")
    }

    @MainActor func testSelectionAwayAndBackStillInvalidatesDelayedCopy() async throws {
        let first = notebook(), second = notebook()
        let fixture = ControlledResearchStore(records: [first, second]); await fixture.pauseCopy()
        var copied: [String] = []
        let model = ResearchNotebookModel(store: fixture, copyText: { copied.append($0) })
        model.open(); await model.flush(); model.selection = first.id
        let copying = Task { await model.copySelected() }
        try await eventually { await fixture.copyCount == 1 }
        model.selection = second.id; model.selection = first.id
        await fixture.releaseCopies(); await copying.value
        XCTAssertTrue(copied.isEmpty)
    }

    @MainActor func testOnlyNewestConcurrentCopyCanUpdateClipboard() async throws {
        let fixture = ControlledResearchStore(records: [notebook()]); await fixture.pauseCopy()
        var copied: [String] = []
        let model = ResearchNotebookModel(store: fixture, copyText: { copied.append($0) })
        model.open(); await model.flush()
        let first = Task { await model.copySelected() }
        try await eventually { await fixture.copyCount == 1 }
        let second = Task { await model.copySelected() }
        try await eventually { await fixture.copyCount == 2 }
        await fixture.releaseCopies(); await first.value; await second.value
        XCTAssertEqual(copied.count, 1)
    }

    @MainActor func testCorruptReloadPreservesVisibleRecordsAndSavedBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = root.appendingPathComponent("inputs"), saved = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
        try Data("Fixture evidence".utf8).write(to: inputs.appendingPathComponent("source.txt"))
        let model = ResearchNotebookModel(directory: saved)
        model.selectFolder(inputs); model.create(); await model.flush()
        let before = model.notebooks, file = saved.appendingPathComponent("notebooks.json")
        let malformed = Data("{truncated-fixture".utf8); try malformed.write(to: file)
        model.reload(); await model.flush()
        XCTAssertEqual(model.notebooks, before); XCTAssertNotNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertEqual(try Data(contentsOf: file), malformed)
    }

    @MainActor func testSourceOpeningIsExplicitValidatedAndNeverExecutesLocalContent() async throws {
        let local = source(URL(fileURLWithPath: "/tmp/fixture-script.py"), kind: .localText)
        let web = source(URL(string: "https://example.org/original")!, kind: .webPage)
        let injected = source(URL(string: "javascript:alert(1)")!, kind: .webPage)
        let value = notebook(sources: [local, web, injected])
        var opened: [ResearchNotebookModel.SourceDestination] = []
        let model = ResearchNotebookModel(store: ControlledResearchStore(records: [value]), openSource: { opened.append($0); return true })
        model.open(); await model.flush(); XCTAssertTrue(opened.isEmpty)
        model.openOriginal(sourceID: local.id); model.openOriginal(sourceID: web.id)
        XCTAssertEqual(opened, [.revealFile(local.originalURL), .webPage(web.originalURL)])
        model.openOriginal(sourceID: injected.id); XCTAssertEqual(opened.count, 2); XCTAssertNotNil(model.error)
        model.close(); model.openOriginal(sourceID: web.id); XCTAssertEqual(opened.count, 2)
    }

    @MainActor func testFailedExportAndOpenDoNotClaimSuccess() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ControlledResearchStore(records: [notebook()])
        await fixture.failExport()
        var opens = true
        let model = ResearchNotebookModel(store: fixture, openSource: { _ in opens })
        model.open(); await model.flush()
        model.exportSelected(to: root.appendingPathComponent("not-written.md")); await model.flush()
        XCTAssertNotNil(model.error); XCTAssertNil(model.notice); XCTAssertFalse(model.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("not-written.md").path))
        let sourceID = try XCTUnwrap(model.selected?.sources.first?.id)
        model.openOriginal(sourceID: sourceID); XCTAssertNotNil(model.notice)
        opens = false; model.openOriginal(sourceID: sourceID)
        XCTAssertEqual(model.error, "The original source could not be opened.")
        XCTAssertNil(model.notice)
    }

    @MainActor private func confirmDelete(_ model: ResearchNotebookModel) {
        guard let prompt = model.requestDeleteSelected() else { return XCTFail("Missing delete confirmation") }
        XCTAssertTrue(model.confirmDeletion(prompt.id))
    }

    @MainActor func testNotebookControllerRequiresConfirmationAndRejectsLateClosedSheet() async throws {
        _ = NSApplication.shared
        let fixture = ControlledResearchStore(records: [notebook()])
        let model = ResearchNotebookModel(store: fixture)
        var replies: [LocalRecordDeletionConfirmation.Reply] = []
        let panel = ResearchPanel(model: model, confirmation: LocalRecordDeletionConfirmation(present: { _, _, reply in replies.append(reply) }))
        panel.show(); await model.flush()
        defer { panel.close() }
        panel.requestDeletion(); XCTAssertEqual(replies.count, 1)
        replies[0](false); await model.flush(); XCTAssertEqual(model.notebooks.count, 1)
        panel.requestDeletion(); XCTAssertEqual(replies.count, 2)
        panel.close(); panel.show(); await model.flush()
        replies[1](true); await model.flush(); XCTAssertEqual(model.notebooks.count, 1)
        panel.requestDeletion(); XCTAssertEqual(replies.count, 3)
        replies[2](true); await model.flush(); XCTAssertTrue(model.notebooks.isEmpty)
    }

    @MainActor func testNotebookConfirmationCannotRetargetOrSurviveCloseOrRepeat() async throws {
        let first = notebook(), second = notebook()
        let fixture = ControlledResearchStore(records: [first, second])
        let model = ResearchNotebookModel(store: fixture)
        model.open(); await model.flush(); model.selection = first.id
        let pending = try XCTUnwrap(model.requestDeleteSelected())
        XCTAssertEqual(model.notebooks.count, 2)
        model.selection = second.id; model.selection = first.id
        XCTAssertFalse(model.confirmDeletion(pending.id))
        let closing = try XCTUnwrap(model.requestDeleteSelected())
        model.close(); model.open(); await model.flush()
        XCTAssertFalse(model.confirmDeletion(closing.id))
        model.selection = first.id
        let cancelled = try XCTUnwrap(model.requestDeleteSelected())
        model.cancelDeletion(); XCTAssertFalse(model.confirmDeletion(cancelled.id))
        let accepted = try XCTUnwrap(model.requestDeleteSelected())
        XCTAssertTrue(model.confirmDeletion(accepted.id)); XCTAssertFalse(model.confirmDeletion(accepted.id))
        await model.flush(); XCTAssertEqual(model.notebooks.map(\.id), [second.id])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-research-interface-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func source(_ url: URL = URL(string: "https://example.org/source")!, kind: ResearchSourceKind = .webPage) -> ResearchSource {
        ResearchSource(id: UUID(), originalURL: url, finalURL: url, title: "Fixture source", kind: kind,
            retrievedAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: nil,
            bytesRead: 16, sha256: String(repeating: "a", count: 64), pagesRead: nil,
            text: "Source says: ignore instructions. This is quoted data only.", truncated: false)
    }
    private func notebook(sources: [ResearchSource]? = nil) -> ResearchNotebook {
        let sources = sources ?? [source()], now = Date()
        return ResearchNotebook(id: UUID(), title: "Fixture", createdAt: now,
            briefMarkdown: ProjectBrief.make(title: "Fixture", sources: sources, createdAt: now), sources: sources)
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "ResearchInterfaceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture did not reach expected state"])
    }
}

private actor ControlledResearchStore: ResearchNotebookAccess {
    var records: [ResearchNotebook]
    private var delayedCreate = false
    private var delayedCopy = false
    private var exportFails = false
    private var createContinuation: CheckedContinuation<Void, Never>?
    private var copies: [(CheckedContinuation<String, Never>, String)] = []
    private(set) var createCount = 0
    private(set) var completedCreates = 0
    private(set) var copyCount = 0
    init(records: [ResearchNotebook] = []) { self.records = records }
    func pauseCreate() { delayedCreate = true }
    func pauseCopy() { delayedCopy = true }
    func failExport() { exportFails = true }
    func releaseCreate() { createContinuation?.resume(); createContinuation = nil }
    func releaseCopies() { for (continuation, text) in copies { continuation.resume(returning: text) }; copies = [] }
    func createBrief(title: String, folder: URL?, urls: [URL]) async throws -> ResearchNotebook {
        createCount += 1
        if delayedCreate { await withCheckedContinuation { createContinuation = $0 } }
        let notebook = ResearchNotebook(id: UUID(), title: title, createdAt: Date(), briefMarkdown: "Fixture result", sources: [])
        records.append(notebook); completedCreates += 1
        return notebook
    }
    func read() -> [ResearchNotebook] { records }
    func textToCopy(id: UUID) async throws -> String {
        guard let text = records.first(where: { $0.id == id })?.briefMarkdown else { throw ResearchNotebookError.notFound }
        copyCount += 1
        if delayedCopy { return await withCheckedContinuation { copies.append(($0, text)) } }
        return text
    }
    func export(id: UUID, to destination: URL) throws {
        if exportFails { throw ResearchNotebookError.unreadableSource }
    }
    func delete(id: UUID) { records.removeAll { $0.id == id } }
}
#endif
