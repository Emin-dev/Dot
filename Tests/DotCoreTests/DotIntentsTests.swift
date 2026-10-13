import AppIntents
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class DotIntentsTests: XCTestCase {
    @MainActor
    func testUnconfiguredRouterFailsWithoutStartingAnything() async {
        let router = DotIntentRouter()
        for action in DotIntentAction.allCases {
            XCTAssertThrowsError(try router.perform(action)) {
                XCTAssertEqual($0 as? DotIntentError, .unavailable)
            }
        }
    }

    @MainActor
    func testRegistrationAndClearingDoNotInvokeHandlers() async throws {
        let router = DotIntentRouter()
        var calls: [DotIntentAction] = []
        router.configure(talk: { calls.append(.talk) }, stop: { calls.append(.stop) }, show: { calls.append(.show) })
        XCTAssertTrue(calls.isEmpty)
        try router.perform(.show)
        XCTAssertEqual(calls, [.show])
        router.clear()
        for action in DotIntentAction.allCases { XCTAssertThrowsError(try router.perform(action)) }
        XCTAssertEqual(calls, [.show])
    }

    @MainActor
    func testReplacementDropsOldOwnersAndRoutesOneAction() async throws {
        let router = DotIntentRouter()
        var oldCalls = 0
        var calls: [DotIntentAction] = []
        router.configure(talk: { oldCalls += 1 }, stop: { oldCalls += 1 }, show: { oldCalls += 1 })
        router.configure(talk: { calls.append(.talk) }, stop: { calls.append(.stop) }, show: { calls.append(.show) })
        for action in DotIntentAction.allCases { try router.perform(action) }
        XCTAssertEqual(calls, [.talk, .stop, .show])
        XCTAssertEqual(oldCalls, 0)
    }

    @MainActor
    func testHandlerFailurePropagatesWithoutFallbackCapture() async {
        enum PermissionError: Error { case denied }
        let router = DotIntentRouter()
        var otherCalls = 0
        router.configure(talk: { throw PermissionError.denied }, stop: { otherCalls += 1 }, show: { otherCalls += 1 })
        XCTAssertThrowsError(try router.perform(.talk)) { XCTAssertTrue($0 is PermissionError) }
        XCTAssertEqual(otherCalls, 0)
    }

    @MainActor
    func testNativeIntentsUseExistingRouterAndForegroundPolicy() async throws {
        var calls: [DotIntentAction] = []
        let router = DotIntentRouter.shared
        router.configure(talk: { calls.append(.talk) }, stop: { calls.append(.stop) }, show: { calls.append(.show) })
        defer { router.clear() }
        _ = try await TalkToDotIntent().perform()
        _ = try await StopDotIntent().perform()
        _ = try await ShowDotIntent().perform()
        XCTAssertEqual(calls, [.talk, .stop, .show])
        XCTAssertTrue(TalkToDotIntent.openAppWhenRun)
        XCTAssertTrue(StopDotIntent.openAppWhenRun)
        XCTAssertTrue(ShowDotIntent.openAppWhenRun)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(TalkToDotIntent.supportedModes, .foreground)
            XCTAssertEqual(StopDotIntent.supportedModes, .foreground)
            XCTAssertEqual(ShowDotIntent.supportedModes, .foreground)
        }
        XCTAssertEqual(DotAppShortcuts.appShortcuts.count, 3)
    }

    @MainActor
    func testCancelledIntentsCannotReachTheAppOwner() async {
        var calls = 0
        DotIntentRouter.shared.configure(talk: { calls += 1 }, stop: { calls += 1 }, show: { calls += 1 })
        defer { DotIntentRouter.shared.clear() }
        let operations: [@MainActor () async throws -> Void] = [
            { _ = try await TalkToDotIntent().perform() },
            { _ = try await StopDotIntent().perform() },
            { _ = try await ShowDotIntent().perform() }
        ]
        for operation in operations {
            let task = Task { @MainActor in try await operation() }
            task.cancel()
            do {
                try await task.value
                XCTFail("Cancelled intent must not execute")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testNativeIntentUnavailableErrorSurvivesTheFrameworkEntryPoint() async {
        DotIntentRouter.shared.clear()
        do {
            _ = try await TalkToDotIntent().perform()
            XCTFail("An intent must not report success before the app owner is ready")
        } catch {
            XCTAssertEqual(error as? DotIntentError, .unavailable)
            XCTAssertEqual(error.localizedDescription, DotIntentError.unavailable.errorDescription)
        }
    }

    @MainActor
    func testNativeIntentReportsTheOwnerFailureWithoutTryingAnotherAction() async {
        enum OwnerFailure: Error { case microphoneUnavailable }
        var calls: [DotIntentAction] = []
        DotIntentRouter.shared.configure(talk: {
            calls.append(.talk)
            throw OwnerFailure.microphoneUnavailable
        }, stop: { calls.append(.stop) }, show: { calls.append(.show) })
        defer { DotIntentRouter.shared.clear() }
        do {
            _ = try await TalkToDotIntent().perform()
            XCTFail("The actual intent must preserve the capture error")
        } catch { XCTAssertTrue(error is OwnerFailure) }
        XCTAssertEqual(calls, [.talk])
    }
}
