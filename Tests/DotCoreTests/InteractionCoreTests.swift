#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class InteractionCoreTests: XCTestCase {
    func testSilenceNeverFinishesBeforeSpeech() {
        XCTAssertFalse(SilenceGate().shouldFinish(at: 100_000))
    }
    func testThreeFullSecondsAreRequired() {
        var gate = SilenceGate(); gate.heardSpeech(at: 10)
        XCTAssertFalse(gate.shouldFinish(at: 12.999))
        XCTAssertTrue(gate.shouldFinish(at: 13))
    }
    func testResumedSpeechResetsDeadline() {
        var gate = SilenceGate(); gate.heardSpeech(at: 10); gate.heardSpeech(at: 12.5)
        XCTAssertFalse(gate.shouldFinish(at: 13))
        XCTAssertTrue(gate.shouldFinish(at: 15.5))
    }
    func testNewTurnRejectsStaleEvents() {
        var gate = TurnGate(); let old = gate.current; let current = gate.advance()
        XCTAssertFalse(gate.accepts(old)); XCTAssertTrue(gate.accepts(current))
    }
    func testLoopbackEndpoints() {
        XCTAssertNotNil(LocalEndpoint.validate("http://127.0.0.1:8000"))
        XCTAssertNotNil(LocalEndpoint.validate("http://localhost:8000/"))
        XCTAssertNotNil(LocalEndpoint.validate("http://[::1]:8000"))
    }
    func testRemoteAndCredentialEndpointsRejected() {
        for url in ["https://example.com:8000", "http://192.168.1.4:8000", "http://127.0.0.1.example.com:8000", "http://user:password@localhost:8000", "http://localhost:8000/?token=x", "file:///tmp/server", "http://localhost", "http://localhost:8000/v1"] {
            XCTAssertNil(LocalEndpoint.validate(url), url)
        }
    }
    private func identity(ready: Bool = true, model: String = "owner/model", schema: Int = 6) throws -> SplashIdentity {
        let data = Data("""
        {"schema_version":\(schema),"ready":\(ready),"instance":{"id":"0123456789abcdef01234567","pid":1234,"model":"\(model)","host":"127.0.0.1","port":8000}}
        """.utf8)
        return try JSONDecoder().decode(SplashIdentity.self, from: data)
    }
    func testExactReadySplashIdentityAccepted() throws {
        XCTAssertTrue(try identity().matches(model: "owner/model", port: 8000, server: "Splash"))
    }
    func testGenericOpenAIEndpointRejected() throws {
        XCTAssertFalse(try identity().matches(model: "owner/model", port: 8000, server: "LM Studio"))
        XCTAssertFalse(try identity().matches(model: "owner/model", port: 8000, server: nil))
    }
    func testAliasOrDifferentModelRejected() throws {
        XCTAssertFalse(try identity().matches(model: "model", port: 8000, server: "Splash"))
        XCTAssertFalse(try identity().matches(model: "other/model", port: 8000, server: "Splash"))
    }
    func testWrongPortUnreadyOrUnsupportedSchemaRejected() throws {
        XCTAssertFalse(try identity().matches(model: "owner/model", port: 8642, server: "Splash"))
        XCTAssertFalse(try identity(ready: false).matches(model: "owner/model", port: 8000, server: "Splash"))
        XCTAssertFalse(try identity(schema: 7).matches(model: "owner/model", port: 8000, server: "Splash"))
    }
    func testMissingInstanceRejected() throws {
        let identity = try JSONDecoder().decode(SplashIdentity.self, from: Data(#"{"schema_version":6,"ready":false}"#.utf8))
        XCTAssertFalse(identity.matches(model: "owner/model", port: 8000, server: "Splash"))
    }
    func testSentencesAndPunctuationArePreserved() {
        var buffer = SentenceBuffer()
        XCTAssertEqual(buffer.feed("Hello. Next"), ["Hello."])
        XCTAssertEqual(buffer.flush(), "Next")
    }
    func testSplitTokensAndFinalFragment() {
        var buffer = SentenceBuffer()
        XCTAssertTrue(buffer.feed("Hello").isEmpty)
        XCTAssertTrue(buffer.feed(".").isEmpty)
        XCTAssertEqual(buffer.feed(" Next! "), ["Hello.", "Next!"])
        XCTAssertNil(buffer.flush())
    }
    func testDecimalIsNotSplit() {
        var buffer = SentenceBuffer()
        XCTAssertTrue(buffer.feed("3.").isEmpty)
        XCTAssertEqual(buffer.feed("14 is pi. "), ["3.14 is pi."])
    }
    func testLongUnpunctuatedTextIsBounded() {
        var buffer = SentenceBuffer()
        let text = String(repeating: "word ", count: 70)
        let chunks = buffer.feed(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, 280)
        XCTAssertNotNil(buffer.flush())
    }
    func testSSEEmptyUsageKeepaliveAndDone() {
        XCTAssertNil(StreamDelta.parse(": keepalive"))
        XCTAssertNil(StreamDelta.parse(#"data: {"choices":[],"usage":{"completion_tokens":1}}"#))
        XCTAssertEqual(StreamDelta.parse("data: [DONE]")?.done, true)
    }
    func testSSEOnlyContentIsSpoken() {
        let reasoning = StreamDelta.parse(#"data: {"choices":[{"delta":{"reasoning_content":"private thought"}}]}"#)
        XCTAssertEqual(reasoning?.content, "")
        let content = StreamDelta.parse(#"data: {"choices":[{"delta":{"content":"Hello"}}]}"#)
        XCTAssertEqual(content?.content, "Hello")
    }
}

final class VoiceEventTests: XCTestCase {
    private func event(_ fields: [String: Any]) -> VoiceEvent? {
        VoiceEvent.parse(try! JSONSerialization.data(withJSONObject: fields))
    }
    private var audio: [String: Any] {
        ["protocol": 1, "event": "audio", "id": UUID().uuidString, "turn": UUID().uuidString,
         "file": "audio-" + UUID().uuidString.lowercased() + ".wav", "sample_rate": 24000, "samples": 24000]
    }
    func testVoiceHandshakeExactIdentity() {
        XCTAssertNotNil(event(["protocol": 1, "event": "hello", "engine": "kokoro", "voice": "bf_isabella", "sample_rate": 24000, "offline": true]))
    }
    func testVoiceHandshakeRejectsOtherEngine() {
        XCTAssertNil(event(["protocol": 1, "event": "hello", "engine": "remote", "voice": "bf_isabella", "sample_rate": 24000, "offline": true]))
    }
    func testVoiceAudioRequiresValidRequestAndTurn() {
        XCTAssertNotNil(event(audio))
        var invalid = audio; invalid["turn"] = "stale"; XCTAssertNil(event(invalid))
    }
    func testVoiceRejectsTraversal() {
        var invalid = audio; invalid["file"] = "../../private.wav"; XCTAssertNil(event(invalid))
    }
    func testVoiceRejectsOversizedAudio() {
        var invalid = audio; invalid["samples"] = 1_440_001; XCTAssertNil(event(invalid))
    }
    func testVoiceRejectsWrongVersion() {
        var invalid = audio; invalid["protocol"] = 2; XCTAssertNil(event(invalid))
    }
    func testVoiceRejectsUnknownEvent() {
        XCTAssertNil(event(["protocol": 1, "event": "execute"]))
    }
    func testVoiceRejectsOversizedFrame() {
        XCTAssertNil(VoiceEvent.parse(Data(repeating: 32, count: 8193)))
    }
}

final class RoamingTests: XCTestCase {
    private let visible = CGRect(x: -1440, y: 30, width: 1440, height: 900)
    private let cursor = CGPoint(x: 5000, y: 5000)
    private let frame = CGRect(x: -800, y: 100, width: 148, height: 156)
    private let obstacle = CGRect(x: -820, y: 100, width: 40, height: 156)
    private func map(_ regions: [CGRect]? = nil, at: Double = 9) -> PlacementSnapshot {
        PlacementSnapshot(displayID: 7, displayFrame: visible, visibleFrame: visible, capturedAt: at, protected: regions ?? [obstacle])
    }
    func testNegativeMonitorBoundsClampWholeWindowForManualDrag() {
        let bounds = RoamingCore.originBounds(window: CGSize(width: 320, height: 420), visible: visible)!
        XCTAssertEqual(RoamingCore.clamp(CGPoint(x: 9000, y: -9000), to: bounds), CGPoint(x: -336, y: 46))
    }
    func testTinyOrNonfiniteDisplayCannotStartTrip() {
        XCTAssertNil(RoamingCore.originBounds(window: CGSize(width: 320, height: 420), visible: CGRect(x: 0, y: 0, width: 200, height: 300)))
        XCTAssertFalse(PlacementSnapshot.validRect(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300)))
    }
    func testSegmentDistanceRejectsCrossingCursor() {
        XCTAssertEqual(RoamingCore.distanceToSegment(CGPoint(x: 50, y: 0), .zero, CGPoint(x: 100, y: 0)), 0)
        XCTAssertEqual(RoamingCore.distanceToSegment(CGPoint(x: 50, y: 150), .zero, CGPoint(x: 100, y: 0)), 150)
    }
    func testNoAnalysisNeverMovesEvenOutsideCurrentDisplay() {
        var planner = RoamingCore(seed: 42, now: 0)
        let elsewhere = CGRect(x: 5000, y: 5000, width: 148, height: 156)
        for time in [9.0, 100.0, 10000.0] {
            XCTAssertEqual(planner.step(frame: elsewhere, visible: visible, cursor: cursor, paused: false, now: time), elsewhere.origin)
            XCTAssertFalse(planner.isTravelling)
        }
    }
    func testClearCurrentPositionStaysRatherThanRandomlyWandering() {
        var planner = RoamingCore(seed: 42, now: 0)
        XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 9, displayID: 7, snapshot: map([])), frame.origin)
        XCTAssertFalse(planner.isTravelling)
    }
    func testShortEscapeReducesExistingOverlapWithoutCrossingContent() {
        var planner = RoamingCore(seed: 42, now: 0), moving = frame
        let snapshot = map(); var priorArea = frame.intersection(obstacle).width * frame.intersection(obstacle).height
        for tick in 0...40 {
            let now = 9 + Double(tick) / 60
            moving.origin = planner.step(frame: moving, visible: visible, cursor: cursor, paused: false, now: now, displayID: 7, snapshot: snapshot)
            let overlap = moving.intersection(obstacle), area = overlap.isNull ? 0 : overlap.width * overlap.height
            XCTAssertLessThanOrEqual(area, priorArea); priorArea = area
            XCTAssertTrue(visible.contains(moving))
        }
        XCTAssertEqual(moving.origin, CGPoint(x: -779, y: 100)); XCTAssertEqual(priorArea, 0)
    }
    func testWholeWindowAndSweptPathRejectNewContent() {
        let target = CGPoint(x: -779, y: 100)
        XCTAssertTrue(RoamingCore.safePath(from: frame, to: target, regions: [obstacle]))
        XCTAssertFalse(RoamingCore.safePath(from: frame, to: target, regions: [obstacle, CGRect(x: -640, y: 200, width: 1, height: 1)]))
        let start = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertFalse(RoamingCore.safePath(from: start, to: CGPoint(x: 40, y: 0), regions: [CGRect(x: 20, y: 1, width: 2, height: 2)]))
        XCTAssertFalse(RoamingCore.safePath(from: start, to: CGPoint(x: 40, y: 40), regions: []))
    }
    func testNoClearAreaHasNoFallback() {
        var planner = RoamingCore(seed: 1, now: 0)
        XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 9, displayID: 7, snapshot: map([visible])), frame.origin)
        XCTAssertFalse(planner.isTravelling)
    }
    func testPausePointerStaleAndWrongDisplayStopAtPresentedPosition() {
        for reason in 0..<5 {
            var planner = RoamingCore(seed: 42, now: 0), moving = frame
            let snapshot = map()
            _ = planner.step(frame: moving, visible: visible, cursor: cursor, paused: false, now: 9, displayID: 7, snapshot: snapshot)
            XCTAssertTrue(planner.isTravelling)
            moving.origin = planner.step(frame: moving, visible: visible, cursor: cursor, paused: false, now: 9.1, displayID: 7, snapshot: snapshot)
            let next = planner.step(frame: moving, visible: visible, cursor: reason == 1 ? CGPoint(x: moving.midX, y: moving.midY) : cursor,
                paused: reason == 0, now: reason == 2 ? 20 : 9.2, displayID: reason == 3 ? 8 : 7, snapshot: reason == 4 ? nil : snapshot)
            XCTAssertEqual(next, moving.origin); XCTAssertFalse(planner.isTravelling)
        }
    }
    func testChangedDisplayGeometryDoesNotUnsafelyClamp() {
        var planner = RoamingCore(seed: 42, now: 0)
        _ = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 9, displayID: 7, snapshot: map())
        XCTAssertEqual(planner.step(frame: frame, visible: CGRect(x: 0, y: 0, width: 1200, height: 900), cursor: cursor, paused: false, now: 9.1, displayID: 7, snapshot: map()), frame.origin)
        XCTAssertFalse(planner.isTravelling)
    }
    func testLongWakeIntervalRejectsExpiredMapInsteadOfTeleporting() {
        var planner = RoamingCore(seed: 42, now: 0)
        _ = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 9, displayID: 7, snapshot: map())
        XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 10000, displayID: 7, snapshot: map()), frame.origin)
    }
    func testGeometryTransformsAcrossAboveAndLeftMonitors() {
        let screen = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        XCTAssertEqual(PlacementSnapshot.quartzRect(CGRect(x: -1440, y: -900, width: 1440, height: 900), primaryTop: 900), screen)
        let normalized = CGRect(x: 0.25, y: 0.75, width: 0.25, height: 0.25)
        let expected = CGRect(x: -1080, y: 1575, width: 360, height: 225)
        XCTAssertEqual(PlacementSnapshot.visionRect(normalized, display: screen), expected)
        XCTAssertEqual(PlacementSnapshot.rasterRect(CGRect(x: 500, y: 0, width: 500, height: 250), width: 2000, height: 1000, display: screen), expected)
    }
    func testMalformedOversizedFutureMapsReject() {
        XCTAssertFalse(map(at: 10).valid(displayID: 7, visible: visible, now: 9))
        XCTAssertFalse(map(Array(repeating: obstacle, count: 8193)).valid(displayID: 7, visible: visible, now: 9))
        XCTAssertNil(PlacementSnapshot.visionRect(CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5), display: visible))
    }
}

final class PlacementScanTests: XCTestCase {
    func testOneFlightAndTenSecondCadence() throws {
        var gate = PlacementScanGate()
        let token = try XCTUnwrap(gate.begin(now: 1, eligible: true))
        XCTAssertNil(gate.begin(now: 20, eligible: true))
        gate.finish(token: token, result: nil)
        XCTAssertNil(gate.begin(now: 10, eligible: true)); XCTAssertNotNil(gate.begin(now: 11, eligible: true))
    }
    func testOptOutOrInteractionDropsLateResultWithoutOverlappingCapture() throws {
        var gate = PlacementScanGate()
        let token = try XCTUnwrap(gate.begin(now: 1, eligible: true)); gate.invalidate()
        XCTAssertNil(gate.begin(now: 20, eligible: true))
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        gate.finish(token: token, result: PlacementSnapshot(displayID: 1, displayFrame: frame, visibleFrame: frame, capturedAt: 1, protected: []))
        XCTAssertNil(gate.snapshot); XCTAssertNil(gate.active)
    }
    func testDeniedPausedAndNonfiniteStartNeverCapture() {
        var gate = PlacementScanGate()
        XCTAssertNil(gate.begin(now: 1, eligible: false)); XCTAssertNil(gate.begin(now: .nan, eligible: true))
    }
}

final class ScreenContextTests: XCTestCase {
    private let jpeg = Data([0xff, 0xd8, 0xff, 0x00, 0xff, 0xd9])
    private func active(_ id: UUID) -> ScreenContextGate {
        var gate = ScreenContextGate(); gate.begin(turn: id, enabled: true, permissionGranted: true, modelHasVision: true); return gate
    }
    func testFreshFrameIsLocalDataURLAndConsumedOnce() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 1920, height: 1080, turn: id, now: 5)
        XCTAssertEqual(try gate.consumeDataURL(turn: id, now: 6), "data:image/jpeg;base64," + jpeg.base64EncodedString())
        XCTAssertThrowsError(try gate.consumeDataURL(turn: id, now: 6))
    }
    func testCaptureFailureNeverUsesMissingImage() {
        let id = UUID(); var gate = active(id)
        XCTAssertThrowsError(try gate.consumeDataURL(turn: id, now: 1)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .unavailable) }
    }
    func testPermissionDenialCannotClaimCapture() {
        let id = UUID(); var gate = ScreenContextGate()
        gate.begin(turn: id, enabled: true, permissionGranted: false, modelHasVision: true)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, now: 1)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .permissionDenied) }
    }
    func testTextOnlyModelCannotUseImage() {
        let id = UUID(); var gate = ScreenContextGate()
        gate.begin(turn: id, enabled: true, permissionGranted: true, modelHasVision: false)
        XCTAssertThrowsError(try gate.consumeDataURL(turn: id, now: 1)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .unsupportedModel) }
    }
    func testNewTurnRejectsOldScreenshot() throws {
        let old = UUID(); var gate = active(old)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: old, now: 1)
        gate.begin(turn: UUID(), enabled: true, permissionGranted: true, modelHasVision: true)
        XCTAssertThrowsError(try gate.consumeDataURL(turn: old, now: 2)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale) }
    }
    func testExpiredFrameIsRejected() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, now: 1)
        XCTAssertThrowsError(try gate.consumeDataURL(turn: id, now: 7)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale) }
    }
    func testImageDimensionsAndBytesAreBounded() {
        let id = UUID(); var gate = active(id)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 4096, height: 4096, turn: id, now: 1))
        XCTAssertThrowsError(try gate.capturedJPEG(Data(repeating: 0, count: 2_000_001), width: 10, height: 10, turn: id, now: 1))
    }
    func testPauseClearsCapturedPixels() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, now: 1)
        gate.begin(turn: id, enabled: false, permissionGranted: true, modelHasVision: true)
        XCTAssertThrowsError(try gate.consumeDataURL(turn: id, now: 2)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .disabled) }
    }
}

extension ScreenContextTests {
    func testStaleCaptureCallbackHasAccurateFailure() {
        let old = UUID(), current = UUID(); var gate = active(current)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: old, now: 1)) {
            XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale)
        }
    }
}

final class StreamUpdateTests: XCTestCase {
    func testFirstAnswerTokenIsImmediate() {
        var buffer = StreamUpdateBuffer(); XCTAssertEqual(buffer.feed("Hello", now: 0), "Hello")
    }
    func testFastTokensCoalesceInOrder() {
        var buffer = StreamUpdateBuffer(); _ = buffer.feed("a", now: 0)
        XCTAssertNil(buffer.feed("b", now: 0.01)); XCTAssertNil(buffer.feed("c", now: 0.02))
        XCTAssertEqual(buffer.feed("d", now: 0.05), "bcd")
    }
    func testFinalFlushPreservesTrailingTextOnce() {
        var buffer = StreamUpdateBuffer(); _ = buffer.feed("a", now: 0); _ = buffer.feed("b", now: 0.01)
        XCTAssertEqual(buffer.flush(), "b"); XCTAssertNil(buffer.flush())
    }
    func testPendingByteLimitFlushesBeforeInterval() {
        var buffer = StreamUpdateBuffer(); _ = buffer.feed("a", now: 0)
        XCTAssertEqual(buffer.feed(String(repeating: "x", count: 1024), now: 0.001)?.count, 1024)
    }
}

final class ProvisioningContractTests: XCTestCase {
    func testPartialDownloadCreditsExistingBytes() {
        XCTAssertEqual(DownloadBudget.requiredFree(total: 19_930_313_310, reusableBytes: 4_000_000_000), 20_930_313_310)
    }
    func testSpaceBudgetNeverCreditsMoreThanPayload() {
        XCTAssertEqual(DownloadBudget.requiredFree(total: 20, reusableBytes: 100), 5_000_000_000)
        XCTAssertEqual(DownloadBudget.requiredFree(total: 20, reusableBytes: -1), 5_000_000_020)
    }
    func testScreenPrivacyChoiceSurvivesNewReader() {
        let name = "DotPrivacyTest." + UUID().uuidString
        let first = UserDefaults(suiteName: name)!
        defer { first.removePersistentDomain(forName: name) }
        ScreenPrivacyPreference.setEnabled(false, in: first)
        XCTAssertFalse(ScreenPrivacyPreference.enabled(in: UserDefaults(suiteName: name)!))
    }
    func testFirstLaunchScreenPolicyIsExplicit() {
        let name = "DotPrivacyTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ScreenPrivacyPreference.enabled(in: defaults))
    }
}

final class CompanionPolicyTests: XCTestCase {
    func testIncompleteAppNeverOffersTalkOrDownload() {
        let actions = CompanionMenuAction.available(readiness: .unavailable("Missing runtime"), busy: false)
        XCTAssertEqual(actions, [.retry, .pin, .screen, .clear, .quit])
    }
    func testCheckingCanPauseWithoutHidingPrivacyAndQuit() {
        XCTAssertEqual(CompanionMenuAction.available(readiness: .checking, busy: false), [.pause, .pin, .screen, .clear, .quit])
    }
    func testActiveTurnAlwaysHasStopAndInterrupt() {
        XCTAssertEqual(CompanionMenuAction.available(readiness: .ready, busy: true), [.talk, .stop, .pin, .screen, .clear, .quit])
    }
    func testPauseNeverLooksReadyAndOffersRetry() {
        XCTAssertFalse(CompanionReadiness.paused.canTalk)
        XCTAssertTrue(CompanionReadiness.paused.canRetry)
        XCTAssertFalse(CompanionReadiness.paused.canPause)
    }
    func testMissingRuntimeErrorRemainsVisibleInCaptionAndDetail() {
        let state = CompanionReadiness.unavailable("Missing runtime")
        XCTAssertTrue(state.isIssue); XCTAssertEqual(state.detail, "Missing runtime")
        XCTAssertTrue(state.caption.contains("Incomplete app"))
    }
}

final class CompanionAccessibilityTests: XCTestCase {
    func testPrimaryElementAnnouncesScreenUse() {
        XCTAssertTrue(CompanionAccessibility.value(status: "Speaking", detail: nil, capturingScreen: false, screenUsed: true).contains("Screen used locally"))
    }
    func testNoScreenClaimWhenCaptureWasNotUsed() {
        XCTAssertEqual(CompanionAccessibility.value(status: "Thinking", detail: nil, capturingScreen: false, screenUsed: false), "Thinking")
    }
}

final class SpeechChunkBoundTests: XCTestCase {
    private func assertChunks(_ input: String, incremental: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        var buffer = SentenceBuffer(), chunks: [String] = []
        if incremental { for char in input { chunks += buffer.feed(String(char)) } }
        else { chunks = buffer.feed(input) }
        if let tail = buffer.flush() { chunks.append(tail) }
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 280 }, file: file, line: line)
        let compact: (String) -> String = { String($0.filter { !$0.isWhitespace }) }
        XCTAssertEqual(compact(chunks.joined()), compact(input), file: file, line: line)
    }
    func testLargeSingleDeltaWithoutPunctuation() { assertChunks(String(repeating: "word ", count: 400)) }
    func testLargePunctuatedSentenceIsBounded() { assertChunks(String(repeating: "word ", count: 400) + ". ") }
    func testLongUnbrokenTokenIsBounded() { assertChunks(String(repeating: "x", count: 1700)) }
    func testIncrementalLongSentencePreservesContent() { assertChunks(String(repeating: "word ", count: 400) + ". ", incremental: true) }
}

final class ResponseBoundsTests: XCTestCase {
    func testOversizedUnterminatedLineRejected() {
        var parser = BoundedSSELines()
        XCTAssertThrowsError(try (0...BoundedSSELines.maximumLineBytes).forEach { _ in _ = try parser.feed(65) })
    }
    func testCRLFAndSplitUTF8Preserved() throws {
        var parser = BoundedSSELines(), output: [String] = []
        for byte in "data: héllo\r\n".utf8 { if let line = try parser.feed(byte) { output.append(line) } }
        XCTAssertEqual(output, ["data: héllo"])
    }
    func testRepeatedContentCannotExceedReplyBudget() throws {
        var budget = ResponseTextBudget()
        for _ in 0..<64 { try budget.accept(String(repeating: "x", count: 1000)) }
        XCTAssertThrowsError(try budget.accept("x"))
    }
    func testStreamOfShortLinesStillHasTotalLimit() {
        var parser = BoundedSSELines()
        XCTAssertThrowsError(try (0...BoundedSSELines.maximumStreamBytes).forEach { _ in _ = try parser.feed(10) })
    }
}

final class ResponseBoundaryTests: XCTestCase {
    func testInvalidUTF8RejectedAtLineBoundary() throws {
        var parser = BoundedSSELines()
        _ = try parser.feed(0xff)
        XCTAssertThrowsError(try parser.feed(10))
    }
    func testExactLineLimitAcceptedThenNextLineStartsEmpty() throws {
        var parser = BoundedSSELines()
        for _ in 0..<BoundedSSELines.maximumLineBytes { _ = try parser.feed(65) }
        XCTAssertEqual(try parser.feed(10)?.utf8.count, BoundedSSELines.maximumLineBytes)
        XCTAssertEqual(try parser.feed(10), "")
    }
    func testTextBudgetCountsUTF8BytesInsteadOfCharacters() throws {
        var budget = ResponseTextBudget()
        try budget.accept(String(repeating: "é", count: 32_000))
        XCTAssertThrowsError(try budget.accept("a"))
    }
}

final class CompanionDragTests: XCTestCase {
    func testDragCooldownSurvivesPausedToUnpausedTransition() {
        for seed in 1...20 {
            var roam = RoamingCore(seed: UInt64(seed), now: 0)
            let frame = CGRect(x: 200, y: 200, width: 148, height: 156)
            let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let cursor = CGPoint(x: 5000, y: 5000)
            _ = roam.step(frame: frame, visible: visible, cursor: cursor, paused: true, now: 0)
            roam.cancel(now: 1, longRest: true)
            for tick in 2...30 {
                XCTAssertEqual(roam.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: Double(tick), displayID: 1,
                    snapshot: PlacementSnapshot(displayID: 1, displayFrame: visible, visibleFrame: visible, capturedAt: Double(tick), protected: [CGRect(x: 180, y: 200, width: 40, height: 156)])), frame.origin)
                XCTAssertFalse(roam.isTravelling)
            }
        }
    }
    func testPanelFootprintHasOnlySmallCharacterPadding() {
        XCTAssertEqual(PetLayout.panelSize.width, PetLayout.petSize.width + 8)
        XCTAssertEqual(PetLayout.panelSize.height, PetLayout.petSize.height + 8)
        XCTAssertEqual(PetLayout.petBottom, 4)
    }
    func testClickWaitsForReleaseAndRequiresInside() {
        var gesture = CompanionDragState(); gesture.begin(point: .zero, origin: .zero)
        XCTAssertNil(gesture.update(point: CGPoint(x: 3, y: 4)))
        XCTAssertTrue(gesture.release(point: CGPoint(x: 3, y: 4), inside: true))
        XCTAssertFalse(gesture.release(point: .zero, inside: true))
        gesture.begin(point: .zero, origin: .zero)
        XCTAssertFalse(gesture.release(point: .zero, inside: false))
    }
    func testExactThresholdLatchesDragAndSuppressesReturnClick() {
        var gesture = CompanionDragState(); gesture.begin(point: .zero, origin: CGPoint(x: -200, y: 40))
        XCTAssertEqual(gesture.update(point: CGPoint(x: 6, y: 0)), CGPoint(x: -194, y: 40))
        XCTAssertTrue(gesture.dragging)
        XCTAssertEqual(gesture.update(point: .zero), CGPoint(x: -200, y: 40))
        XCTAssertFalse(gesture.release(point: .zero, inside: true))
    }
    func testReleaseDisplacementWithoutDraggedEventDoesNotClick() {
        var gesture = CompanionDragState(); gesture.begin(point: .zero, origin: .zero)
        XCTAssertFalse(gesture.release(point: CGPoint(x: 0, y: 6), inside: true))
    }
    func testCancellationAndReplacementNeverResurrectOldClick() {
        var gesture = CompanionDragState(); gesture.begin(point: .zero, origin: .zero); gesture.cancel()
        XCTAssertFalse(gesture.release(point: .zero, inside: true)); XCTAssertNil(gesture.update(point: .zero))
        gesture.begin(point: CGPoint(x: 10, y: 10), origin: .zero)
        XCTAssertTrue(gesture.release(point: CGPoint(x: 10, y: 10), inside: true))
    }
}

final class RuntimeDiagnosticTests: XCTestCase {
    func testFixedFailureCodeBecomesActionableText() throws {
        let diagnostic = try XCTUnwrap(RuntimeDiagnostic.parse(Data(#"{"protocol":1,"event":"failed","stage":"launcher","reason":"module_missing","exit_status":7}"#.utf8)))
        XCTAssertEqual(diagnostic.exitStatus, 7)
        XCTAssertTrue(diagnostic.localizedDescription.contains("bundled dependency"))
        XCTAssertEqual(diagnostic.logLine, "stage=launcher reason=module_missing exit=7")
    }
    func testUnknownTextCannotReachErrorOrLog() throws {
        for field in ["reason", "stage"] {
            var object: [String: Any] = ["protocol": 1, "event": "failed", "stage": "launcher", "reason": "process_exited"]
            object[field] = "/private/SECRET"
            XCTAssertNil(RuntimeDiagnostic.parse(try JSONSerialization.data(withJSONObject: object)))
        }
    }
    func testMalformedAndUnboundedDiagnosticsRejected() {
        for status in ["256", "-256", "true", #""private""#] {
            let json = #"{"protocol":1,"event":"failed","stage":"launcher","reason":"process_exited","exit_status":VALUE}"#.replacingOccurrences(of: "VALUE", with: status)
            XCTAssertNil(RuntimeDiagnostic.parse(Data(json.utf8)))
        }
        XCTAssertNil(RuntimeDiagnostic.parse(Data(repeating: 32, count: 8193)))
        XCTAssertNil(RuntimeDiagnostic.parse(Data(#"{"protocol":2,"event":"failed","stage":"launcher","reason":"process_exited"}"#.utf8)))
    }
    func testNegativeSignalAndMissingExitRemainBounded() throws {
        let data = Data(#"{"protocol":1,"event":"failed","stage":"launcher","reason":"process_exited","exit_status":-9,"stderr":"SECRET"}"#.utf8)
        let value = try XCTUnwrap(RuntimeDiagnostic.parse(data))
        XCTAssertFalse(value.logLine.contains("SECRET"))
        XCTAssertTrue(value.localizedDescription.contains("exit -9"))
    }
}

final class RuntimeExitStateTests: XCTestCase {
    func testExitBeforeFinalProtocolCannotPublishGenericFailure() throws {
        var state = RuntimeExitState()
        state.exited(status: 2)
        XCTAssertNil(state.resolved)
        // Fast child: both lines can be in the same pipe read after the exit callback.
        let lines = "{\"protocol\":1,\"event\":\"started\"}\n{\"protocol\":1,\"event\":\"failed\",\"stage\":\"launcher\",\"reason\":\"module_missing\",\"exit_status\":7}\n"
        for line in lines.split(separator: "\n") {
            if let event = RuntimeDiagnostic.parse(Data(line.utf8)) { state.received(event) }
        }
        state.finishedOutput()
        XCTAssertEqual(try XCTUnwrap(state.resolved).reason, .moduleMissing)
        XCTAssertEqual(state.resolved?.exitStatus, 7)
    }
    func testUnclassifiedExitRequiresEOFInEitherOrder() {
        var exitFirst = RuntimeExitState(); exitFirst.exited(status: 2)
        XCTAssertNil(exitFirst.resolved); exitFirst.finishedOutput()
        XCTAssertEqual(exitFirst.resolved?.reason, .processExited)
        var eofFirst = RuntimeExitState(); eofFirst.finishedOutput()
        XCTAssertNil(eofFirst.resolved); eofFirst.exited(status: 2)
        XCTAssertEqual(eofFirst.resolved, exitFirst.resolved)
    }
    func testTimedOutDrainOnlyExposesNumericFallback() {
        var state = RuntimeExitState(); state.exited(status: -9)
        XCTAssertNil(state.resolved)
        XCTAssertEqual(state.fallback.logLine, "stage=supervisor reason=process_exited exit=-9")
    }
}

final class ScreenPermissionAccessTests: XCTestCase {
    func testAlreadyGrantedDoesNotPrompt() {
        var requests = 0
        XCTAssertTrue(ScreenPermissionAccess.allowed(preflight: { true }, request: { requests += 1; return true }))
        XCTAssertEqual(requests, 0)
    }
    func testSuccessfulFirstGrantContinuesSameTurn() {
        var checks = [false, true], requests = 0
        XCTAssertTrue(ScreenPermissionAccess.allowed(preflight: { checks.removeFirst() }, request: { requests += 1; return true }))
        XCTAssertTrue(checks.isEmpty); XCTAssertEqual(requests, 1)
    }
    func testRefusalCannotCaptureOrReprompt() {
        var checks = 0, requests = 0
        XCTAssertFalse(ScreenPermissionAccess.allowed(preflight: { checks += 1; return false }, request: { requests += 1; return false }))
        XCTAssertEqual(checks, 1); XCTAssertEqual(requests, 1)
    }
    func testGrantWithoutEffectiveAccessStillFailsHonestly() {
        var checks = 0, requests = 0
        XCTAssertFalse(ScreenPermissionAccess.allowed(preflight: { checks += 1; return false }, request: { requests += 1; return true }))
        XCTAssertEqual(checks, 2); XCTAssertEqual(requests, 1)
    }
}

final class PipelineDiagnosticTests: XCTestCase {
    func testReadinessAndCaptureSuccessUseFixedIdentifiers() {
        XCTAssertEqual(PipelineDiagnostic(stage: .readiness, outcome: .ready).logLine, "pipeline=readiness outcome=ready")
        XCTAssertEqual(PipelineDiagnostic(stage: .capture, outcome: .started).logLine, "pipeline=capture outcome=started")
        XCTAssertEqual(PipelineDiagnostic(stage: .capture, outcome: .ready).logLine, "pipeline=capture outcome=ready")
    }
    func testTimeoutAndHTTPFailureAreDistinguishable() {
        XCTAssertEqual(PipelineDiagnostic(stage: .readiness, outcome: .timeout).logLine, "pipeline=readiness outcome=timeout")
        XCTAssertEqual(PipelineDiagnostic.failure(stage: .response, reason: .httpRejected, cancelled: false)?.logLine,
                       "pipeline=response outcome=failed reason=http_rejected")
    }
    func testCancellationNeverProducesFailureRecord() {
        XCTAssertNil(PipelineDiagnostic.failure(stage: .capture, reason: .captureFailed, cancelled: true))
        XCTAssertNil(PipelineDiagnostic.failure(stage: .readiness, reason: .transport, cancelled: true))
    }
    func testGenericFailureDoesNotAcceptAnErrorDescription() {
        XCTAssertEqual(PipelineDiagnostic.failure(stage: .capture, reason: .captureFailed, cancelled: false)?.logLine,
                       "pipeline=capture outcome=failed reason=capture_failed")
    }
}

final class ScreenPermissionTurnTests: XCTestCase {
    func testDeniedEarlyPermissionDoesNotAuthorizeLaterCapture() {
        var permission = ScreenPermissionTurn(); let turn = UUID(); var requests = 0
        XCTAssertFalse(permission.prepare(turn: turn, enabled: true, preflight: { false }, request: { requests += 1; return false }))
        XCTAssertFalse(permission.mayCapture(turn: turn, preflight: { true })); XCTAssertEqual(requests, 1)
    }
    func testFirstGrantIsRequestedOnceThenOnlyRechecked() {
        var permission = ScreenPermissionTurn(); let turn = UUID(); var checks = [false, true], requests = 0
        XCTAssertTrue(permission.prepare(turn: turn, enabled: true, preflight: { checks.removeFirst() }, request: { requests += 1; return true }))
        XCTAssertTrue(permission.mayCapture(turn: turn, preflight: { true }))
        XCTAssertFalse(permission.mayCapture(turn: turn, preflight: { false }))
        XCTAssertEqual(requests, 1)
    }
    func testCancellationAndAnotherTurnCannotReusePermission() {
        var permission = ScreenPermissionTurn(); let turn = UUID()
        XCTAssertTrue(permission.prepare(turn: turn, enabled: true, preflight: { true }, request: { XCTFail("unexpected prompt"); return false }))
        XCTAssertFalse(permission.mayCapture(turn: UUID(), preflight: { true }))
        permission.cancel(); XCTAssertFalse(permission.mayCapture(turn: turn, preflight: { true }))
    }
    func testDisabledScreenNeverChecksOrRequestsPermission() {
        var permission = ScreenPermissionTurn(); let turn = UUID()
        XCTAssertTrue(permission.prepare(turn: turn, enabled: false, preflight: { XCTFail("unexpected check"); return false }, request: { XCTFail("unexpected prompt"); return false }))
        XCTAssertFalse(permission.mayCapture(turn: turn, preflight: { XCTFail("unexpected check"); return true }))
    }
}
