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
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: { throw PreparationFailure.runtime })
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
    @MainActor func testModelsVerifyWhileRuntimeWaitsButCannotPublishReadiness() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = VerificationBarrier()
        let preparation = OfflinePreparation(resources: folder, runtimeCheck: { try await runtime.value() })
        preparation.start(nativeRecognizerAvailable: true)
        defer { preparation.shutdown() }
        try await waitUntil { preparation.progress > 0 }
        XCTAssertFalse(preparation.ready); XCTAssertNil(preparation.root); XCTAssertLessThan(preparation.progress, 1)
        for _ in 0..<200 { if await runtime.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let runtimeStarted = await runtime.started; XCTAssertTrue(runtimeStarted)
        guard runtimeStarted else { throw NSError(domain: "DotTests", code: 1) }
        await runtime.succeed(folder)
        try await waitUntil { preparation.ready }
        XCTAssertEqual(preparation.root?.lastPathComponent, "OfflineModels")
    }
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("readiness did not settle")
        throw NSError(domain: "DotTests", code: 1)
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

#if !SWIFT_PACKAGE
private actor VerificationBarrier {
    private var continuation: CheckedContinuation<URL, Error>?
    private(set) var started = false
    private(set) var ended = false
    func value() async throws -> URL {
        started = true; defer { ended = true }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation = $0 }
            try Task.checkCancellation(); return result
        }, onCancel: { Task { await self.fail(CancellationError()) } })
    }
    func succeed(_ result: URL = URL(fileURLWithPath: "/verified")) {
        let saved = continuation; continuation = nil; saved?.resume(returning: result)
    }
    func fail(_ error: Error) {
        let saved = continuation; continuation = nil; saved?.resume(throwing: error)
    }
}
private actor VerificationCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}
final class PayloadVerificationConcurrencyTests: XCTestCase {
    private func waitForStart(_ barriers: [VerificationBarrier]) async throws {
        for _ in 0..<200 {
            var all = true
            for barrier in barriers { if !(await barrier.started) { all = false } }
            if all { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("verification branches did not start")
        throw NSError(domain: "DotTests", code: 1)
    }
    func testBothBranchesStartTogetherAndBothMustFinish() async throws {
        let runtime = VerificationBarrier(), models = VerificationBarrier(), completion = VerificationCompletion()
        let task = Task {
            let root = try await PayloadVerification.run(runtime: { try await runtime.value() }, models: { try await models.value() })
            await completion.finish(); return root
        }
        defer { task.cancel() }
        try await waitForStart([runtime, models])
        await runtime.succeed()
        let completeBeforeModels = await completion.finished; XCTAssertFalse(completeBeforeModels)
        await models.succeed(URL(fileURLWithPath: "/models"))
        let result = try await task.value; XCTAssertEqual(result.path, "/models")
    }
    func testEitherFailureCancelsAndDrainsTheOtherBranch() async throws {
        for runtimeFails in [true, false] {
            let runtime = VerificationBarrier(), models = VerificationBarrier()
            let task = Task { try await PayloadVerification.run(runtime: { try await runtime.value() }, models: { try await models.value() }) }
            defer { task.cancel() }
            try await waitForStart([runtime, models])
            if runtimeFails { await runtime.fail(PreparationFailure.runtime) }
            else { await models.fail(PreparationFailure.integrity) }
            do { _ = try await task.value; XCTFail("verification failure was ignored") }
            catch PreparationFailure.runtime { XCTAssertTrue(runtimeFails) }
            catch PreparationFailure.integrity { XCTAssertFalse(runtimeFails) }
            catch { XCTFail("original verification failure was replaced") }
            let runtimeEnded = await runtime.ended, modelEnded = await models.ended
            XCTAssertTrue(runtimeEnded); XCTAssertTrue(modelEnded)
        }
    }
    func testOwnerCancellationDrainsBothBranches() async throws {
        let runtime = VerificationBarrier(), models = VerificationBarrier()
        let task = Task { try await PayloadVerification.run(runtime: { try await runtime.value() }, models: { try await models.value() }) }
        defer { task.cancel() }
        try await waitForStart([runtime, models]); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled verification succeeded") }
        catch is CancellationError {} catch { XCTFail("cancellation was replaced") }
        let runtimeEnded = await runtime.ended, modelEnded = await models.ended
        XCTAssertTrue(runtimeEnded); XCTAssertTrue(modelEnded)
    }
}
final class TurnWarmupTests: XCTestCase {
    @MainActor func testCancelledQueuedWarmupNeverStartsOperation() async throws {
        let warmup = TurnWarmup(), turn = UUID(); var calls = 0
        defer { warmup.cancel() }
        warmup.start(turn: turn) { calls += 1 }; warmup.cancel()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        do { try await warmup.wait(turn: turn); XCTFail("cancelled turn was adopted") } catch is CancellationError {} catch { XCTFail("unexpected error") }
    }
    @MainActor func testTranscriptSharesOneWarmAttempt() async throws {
        let warmup = TurnWarmup(), turn = UUID(), barrier = VerificationBarrier(); var calls = 0
        defer { warmup.cancel() }
        warmup.start(turn: turn) { calls += 1; _ = try await barrier.value() }
        for _ in 0..<200 { if await barrier.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await barrier.started; XCTAssertTrue(started)
        guard started else { throw NSError(domain: "DotTests", code: 1) }
        let waiter = Task { try await warmup.wait(turn: turn) }
        await barrier.succeed(); try await waiter.value
        try await warmup.wait(turn: turn)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testReplacementRejectsOldCompletionAndKeepsNewWarmup() async throws {
        let warmup = TurnWarmup(), first = UUID(), second = UUID(), barrier = VerificationBarrier()
        defer { warmup.cancel() }
        warmup.start(turn: first) { _ = try await barrier.value() }
        for _ in 0..<200 { if await barrier.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await barrier.started; XCTAssertTrue(started)
        guard started else { throw NSError(domain: "DotTests", code: 1) }
        var waiterEntered = false
        let oldWait = Task { waiterEntered = true; try await warmup.wait(turn: first) }
        for _ in 0..<200 { if waiterEntered { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(waiterEntered)
        guard waiterEntered else { throw NSError(domain: "DotTests", code: 1) }
        warmup.start(turn: second) {}
        do { try await oldWait.value; XCTFail("old warmup was reused") } catch is CancellationError {} catch { XCTFail("unexpected error") }
        try await warmup.wait(turn: second)
        for _ in 0..<200 { if await barrier.ended { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let ended = await barrier.ended; XCTAssertTrue(ended)
    }
}
#endif
