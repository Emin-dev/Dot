#if !SWIFT_PACKAGE
import XCTest
import AppKit

final class CompanionInterfaceTests: XCTestCase {
    @MainActor private func pointerPanel() -> CompanionPanel {
        _ = NSApplication.shared
        let panel = CompanionPanel(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.primaryHitTest = { $0.x >= 0 && $0.x <= 100 && $0.y >= 0 && $0.y <= 100 }
        panel.constrainDrag = { [weak panel] _, _ in panel?.frame.origin ?? .zero }
        return panel
    }
    @MainActor private func sendPointer(_ type: NSEvent.EventType, _ point: NSPoint, to panel: CompanionPanel, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.sendEvent(event)
    }
    @MainActor func testMouseTalkOnlyOccursOnceOnUndraggedRelease() {
        let panel = pointerPanel(); defer { panel.close() }; var talks = 0
        panel.primaryAction = { talks += 1 }
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel); XCTAssertEqual(talks, 0)
        sendPointer(.leftMouseUp, NSPoint(x: 22, y: 22), to: panel); XCTAssertEqual(talks, 1)
        sendPointer(.leftMouseUp, NSPoint(x: 22, y: 22), to: panel); XCTAssertEqual(talks, 1)
    }
    @MainActor func testDraggingThenReturningNeverStartsTalk() {
        let panel = pointerPanel(); defer { panel.close() }; var talks = 0; var interactions: [Bool] = []
        panel.primaryAction = { talks += 1 }; panel.pointerInteraction = { interactions.append($0) }
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel)
        sendPointer(.leftMouseDragged, NSPoint(x: 26, y: 20), to: panel)
        sendPointer(.leftMouseDragged, NSPoint(x: 20, y: 20), to: panel)
        sendPointer(.leftMouseUp, NSPoint(x: 20, y: 20), to: panel)
        XCTAssertEqual(talks, 0); XCTAssertEqual(interactions, [true, false])
    }
    @MainActor func testCanceledOrControlClickGestureNeverStartsTalkOnRelease() {
        let panel = pointerPanel(); defer { panel.close() }; var talks = 0; var options = 0
        panel.primaryAction = { talks += 1 }; panel.optionsAction = { options += 1 }
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel); panel.cancelOperation(nil)
        sendPointer(.leftMouseUp, NSPoint(x: 20, y: 20), to: panel)
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel, modifiers: [.control])
        sendPointer(.leftMouseUp, NSPoint(x: 20, y: 20), to: panel)
        XCTAssertEqual(talks, 0); XCTAssertEqual(options, 1)
    }
    @MainActor func testOutsideHitRegionAndLostKeyNeverStartTalk() {
        let panel = pointerPanel(); defer { panel.close() }; var talks = 0
        panel.primaryAction = { talks += 1 }
        sendPointer(.leftMouseDown, NSPoint(x: -5, y: -5), to: panel)
        sendPointer(.leftMouseUp, NSPoint(x: 20, y: 20), to: panel)
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel); panel.resignKey()
        sendPointer(.leftMouseUp, NSPoint(x: 20, y: 20), to: panel); XCTAssertEqual(talks, 0)
    }
    @MainActor func testKeyboardOptionsCancelsPressedPointerBeforeLaterRelease() {
        let panel = pointerPanel(); defer { panel.close() }; var talks = 0; var options = 0
        panel.primaryAction = { talks += 1 }; panel.optionsAction = { options += 1 }
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109)!
        panel.sendEvent(key)
        sendPointer(.leftMouseUp, NSPoint(x: 20, y: 20), to: panel)
        XCTAssertEqual(talks, 0); XCTAssertEqual(options, 1)
    }
    @MainActor func testDragUsesGlobalDeltaAfterPanelOriginChanges() {
        let panel = pointerPanel(); defer { panel.close() }; panel.constrainDrag = nil
        let initial = panel.frame.origin
        sendPointer(.leftMouseDown, NSPoint(x: 20, y: 20), to: panel)
        sendPointer(.leftMouseDragged, NSPoint(x: 30, y: 20), to: panel)
        XCTAssertEqual(panel.frame.origin.x, initial.x + 10, accuracy: 0.01)
        sendPointer(.leftMouseDragged, NSPoint(x: 35, y: 20), to: panel)
        XCTAssertEqual(panel.frame.origin.x, initial.x + 25, accuracy: 0.01)
        sendPointer(.leftMouseUp, NSPoint(x: 35, y: 20), to: panel)
    }
    @MainActor func testRepeatedRecallReusesOnlyCompanionPanel() {
        _ = NSApplication.shared
        let surface = CompanionSurface()
        let first = surface.present(content: NSView(), size: NSSize(width: 180, height: 224))
        defer { first.close() }
        surface.recall()
        let second = surface.present(content: NSView(), size: NSSize(width: 180, height: 224))
        XCTAssertTrue(first === second)
        XCTAssertEqual(NSApp.windows.filter { $0.identifier?.rawValue == "dot.companion" }.count, 1)
        XCTAssertFalse(first.canBecomeMain)
        XCTAssertFalse(first.styleMask.contains(.titled))
    }
    @MainActor func testEscapeCallsCancellationWithoutClosingOrCreatingPanel() {
        _ = NSApplication.shared
        let panel = CompanionPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var stops = 0
        panel.stopAction = { stops += 1 }
        panel.cancelOperation(nil); panel.cancelOperation(nil)
        XCTAssertEqual(stops, 2)
    }
    @MainActor func testRightClickOpensOptionsWithoutTriggeringTalk() {
        _ = NSApplication.shared
        let panel = CompanionPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var options = 0
        panel.optionsAction = { options += 1 }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.sendEvent(event)
        XCTAssertEqual(options, 1)
    }
    @MainActor func testControlClickOpensOptionsWithoutForwardingToContent() {
        _ = NSApplication.shared
        let panel = CompanionPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; defer { panel.close() }
        var options = 0; panel.optionsAction = { options += 1 }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.sendEvent(event); XCTAssertEqual(options, 1)
    }
    @MainActor func testPauseRetryPauseCancelsQueuedRestart() async throws {
        let preparation = OfflinePreparation(resources: nil, runtimeCheck: {
            try? await Task.sleep(nanoseconds: 20_000_000); return URL(fileURLWithPath: "/")
        })
        preparation.start(nativeRecognizerAvailable: true); preparation.pause(); preparation.retry(); preparation.pause()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(preparation.state, .paused); XCTAssertFalse(preparation.ready)
    }
    func testRuntimeValidationRejectsAlreadyCancelledOwner() async {
        let payload = OfflinePayload(root: URL(fileURLWithPath: "/no-runtime-fixture"))
        let task = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await payload.validate()
        }
        do { _ = try await task.value; XCTFail("cancelled runtime audit ran") }
        catch is CancellationError {} catch { XCTFail("cancellation was not propagated") }
    }
    func testRealRuntimeAuditChecksCancellationBeforeFileIO() async {
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try OfflinePayload.audit(URL(fileURLWithPath: "/no-runtime-fixture"))
        }
        do { try await task.value; XCTFail("cancelled worker performed audit") }
        catch is CancellationError {} catch { XCTFail("audit missed cancellation") }
    }
    @MainActor func testMissingRecognizerFailsBeforeRuntimeInspection() {
        let preparation = OfflinePreparation(resources: nil, runtimeCheck: { XCTFail("runtime invoked"); return URL(fileURLWithPath: "/") })
        preparation.start(nativeRecognizerAvailable: false)
        XCTAssertTrue(preparation.state.isIssue); XCTAssertFalse(preparation.ready)
        XCTAssertTrue(preparation.state.detail?.contains("speech recognizer") == true)
    }
    @MainActor func testMissingRuntimeStaysVisibleAndNeverReady() async throws {
        let preparation = OfflinePreparation(resources: nil, runtimeCheck: { throw PreparationFailure.runtime })
        preparation.start(nativeRecognizerAvailable: true)
        try await waitUntil { preparation.state != .checking }
        XCTAssertEqual(preparation.state, .unavailable(PreparationFailure.runtime.localizedDescription))
        XCTAssertNil(preparation.root)
    }
    @MainActor func testCancellationSuppressesDelayedRuntimeSuccess() async throws {
        let preparation = OfflinePreparation(resources: nil, runtimeCheck: {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return URL(fileURLWithPath: "/")
        })
        preparation.start(nativeRecognizerAvailable: true); preparation.pause()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(preparation.state, .paused); XCTAssertFalse(preparation.ready)
    }
    @MainActor func testVerifiedBundledModelsBecomeReadyWithoutCreatingFiles() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: { folder })
        preparation.start(nativeRecognizerAvailable: true)
        try await waitUntil { preparation.state != .checking }
        XCTAssertEqual(preparation.state, .ready); XCTAssertEqual(preparation.progress, 1)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted(), before)
    }
    @MainActor func testResourceAncestorAliasDoesNotCorruptRelativeModelNames() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let alias = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: alias) }
        let preparation = OfflinePreparation(resources: alias, runtimeCheck: { folder })
        preparation.start(nativeRecognizerAvailable: true)
        try await waitUntil { preparation.state != .checking }
        XCTAssertEqual(preparation.state, .ready)
    }
    @MainActor func testCorruptBundledFileFailsWithoutRepairOrDownload() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("OfflineModels/model")
        try Data("wrong".utf8).write(to: model)
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: { folder })
        preparation.start(nativeRecognizerAvailable: true)
        try await waitUntil { preparation.state != .checking }
        XCTAssertTrue(preparation.state.isIssue); XCTAssertFalse(preparation.ready)
        XCTAssertEqual(try Data(contentsOf: model), Data("wrong".utf8))
    }
    @MainActor func testUnmanifestedModelFileRejectsReadiness() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("extra".utf8).write(to: folder.appendingPathComponent("OfflineModels/unexpected"))
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: { folder })
        preparation.start(nativeRecognizerAvailable: true)
        try await waitUntil { preparation.state != .checking }
        XCTAssertTrue(preparation.state.isIssue); XCTAssertFalse(preparation.ready)
    }
    @MainActor func testExternalModelFolderIsNeverAdopted() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("OfflineModels")
        let external = folder.appendingPathComponent("external")
        try FileManager.default.moveItem(at: model, to: external)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: external)
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: { folder })
        preparation.start(nativeRecognizerAvailable: true)
        try await waitUntil { preparation.state != .checking }
        XCTAssertTrue(preparation.state.isIssue); XCTAssertFalse(preparation.ready)
    }
    @MainActor func testPauseThenImmediateRetryCannotCommitOldFailure() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: {
            try? await Task.sleep(nanoseconds: 20_000_000); return folder
        })
        preparation.start(nativeRecognizerAvailable: true); preparation.pause(); preparation.retry()
        try await waitUntil { preparation.ready }
        XCTAssertEqual(preparation.state, .ready)
    }
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("readiness did not settle")
    }
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("OfflineModels"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("OfflineModels/model"))
        let data = Data(#"{"schema_version":1,"total_bytes":5,"files":[{"path":"model","bytes":5,"sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}]}"#.utf8)
        try data.write(to: folder.appendingPathComponent("bundled-models.json"))
        return folder
    }
}
#endif
