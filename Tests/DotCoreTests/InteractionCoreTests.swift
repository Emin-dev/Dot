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
    func testPetWandersAfterQuietMinute() {
        var planner = RoamingCore(seed: 42, now: 0)
        XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 9, displayID: 7, snapshot: map([], at: 9)), frame.origin)
        XCTAssertFalse(planner.isTravelling)
        for t in stride(from: 10.0, to: 45.0, by: 1.0) {
            _ = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: t, displayID: 7, snapshot: map([], at: t))
        }
        _ = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 45.0, displayID: 7, snapshot: map([], at: 45.0))
        XCTAssertTrue(planner.isTravelling)
    }
    func testPetWandersSmoothlyAcrossSnapshotRefreshesAndObstacles() {
        var planner = RoamingCore(seed: 42, now: 0)
        var currentFrame = frame
        let nonOverlappingObstacle = CGRect(x: 100, y: 100, width: 200, height: 200)
        var moved = false
        for t in stride(from: 0.0, through: 50.0, by: 0.5) {
            let snap = map([nonOverlappingObstacle], at: t)
            let nextOrigin = planner.step(frame: currentFrame, visible: visible, cursor: cursor, paused: false, now: t, displayID: 7, snapshot: snap)
            if nextOrigin != currentFrame.origin {
                moved = true
                currentFrame.origin = nextOrigin
            }
        }
        XCTAssertTrue(moved)
        XCTAssertNotEqual(currentFrame.origin, frame.origin)
    }
    func testFindRandomEmptySpaceAlwaysFindsSpotEvenWithMaximizedWindowRegions() {
        let bounds = RoamingCore.originBounds(window: frame.size, visible: visible)!
        var seen: Set<String> = []
        for _ in 0..<12 {
            let target = RoamingCore.findRandomEmptySpace(
                frame: frame,
                bounds: bounds,
                cursor: cursor,
                regions: [visible],
                minDistance: 120
            )
            XCTAssertNotNil(target)
            if let target {
                XCTAssertNotEqual(target, frame.origin)
                XCTAssertTrue(bounds.contains(target))
                seen.insert("\(Int(target.x)),\(Int(target.y))")
            }
        }
        XCTAssertGreaterThan(seen.count, 1)
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
        try gate.capturedJPEG(jpeg, width: 1920, height: 1080, turn: id, acquiredAt: 5, now: 5.5)
        let image = try gate.consume(turn: id, now: 6)
        XCTAssertEqual(try image.dataURL(now: 6), "data:image/jpeg;base64," + jpeg.base64EncodedString())
        XCTAssertEqual(image.acquiredAt, 5); XCTAssertEqual(image.turn, id)
        XCTAssertThrowsError(try gate.consume(turn: id, now: 6))
    }
    func testCaptureFailureNeverUsesMissingImage() {
        let id = UUID(); var gate = active(id)
        XCTAssertThrowsError(try gate.consume(turn: id, now: 1)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .unavailable) }
    }
    func testPermissionDenialCannotClaimCapture() {
        let id = UUID(); var gate = ScreenContextGate()
        gate.begin(turn: id, enabled: true, permissionGranted: false, modelHasVision: true)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 1, now: 1)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .permissionDenied) }
    }
    func testTextOnlyModelCannotUseImage() {
        let id = UUID(); var gate = ScreenContextGate()
        gate.begin(turn: id, enabled: true, permissionGranted: true, modelHasVision: false)
        XCTAssertThrowsError(try gate.consume(turn: id, now: 1)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .unsupportedModel) }
    }
    func testNewTurnRejectsOldScreenshot() throws {
        let old = UUID(); var gate = active(old)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: old, acquiredAt: 1, now: 1)
        gate.begin(turn: UUID(), enabled: true, permissionGranted: true, modelHasVision: true)
        XCTAssertThrowsError(try gate.consume(turn: old, now: 2)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale) }
    }
    func testExpiredFrameIsRejected() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 1, now: 1)
        XCTAssertThrowsError(try gate.consume(turn: id, now: 7)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale) }
    }
    func testImageDimensionsAndBytesAreBounded() {
        let id = UUID(); var gate = active(id)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 4096, height: 4096, turn: id, acquiredAt: 1, now: 1))
        XCTAssertThrowsError(try gate.capturedJPEG(Data(repeating: 0, count: 2_000_001), width: 10, height: 10, turn: id, acquiredAt: 1, now: 1))
    }
    func testPauseClearsCapturedPixels() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 1, now: 1)
        gate.begin(turn: id, enabled: false, permissionGranted: true, modelHasVision: true)
        XCTAssertThrowsError(try gate.consume(turn: id, now: 2)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .disabled) }
    }
}

extension ScreenContextTests {
    func testStaleCaptureCallbackHasAccurateFailure() {
        let old = UUID(), current = UUID(); var gate = active(current)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: old, acquiredAt: 1, now: 1)) {
            XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale)
        }
    }
    func testSlowEncodingCannotMakeOldAcquisitionFresh() {
        let id = UUID(); var gate = active(id)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 10, now: 15.001)) {
            XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale)
        }
        XCTAssertThrowsError(try gate.consume(turn: id, now: 15.001))
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 15, now: 15.1),
                             "Expired capture cannot be revived without a new capture lifecycle")
    }
    func testEncodingAndSubmissionShareOneFreshnessBudget() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 10, now: 14)
        let image = try gate.consume(turn: id, now: 14.5)
        XCTAssertNoThrow(try image.validateFreshness(now: 15))
        XCTAssertThrowsError(try image.validateFreshness(now: 15.001)) { XCTAssertEqual($0 as? ScreenContextGate.Failure, .stale) }
        XCTAssertThrowsError(try image.dataURL(now: 15.001))
    }
    func testInvalidAndReversedMonotonicTimesRejectPixels() {
        for (acquiredAt, now) in [(Double.nan, 1.0), (Double.infinity, 1.0), (-1.0, 1.0),
                                  (2.0, 1.0), (1.0, Double.nan), (1.0, Double.infinity)] {
            let id = UUID(); var gate = active(id)
            XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: acquiredAt, now: now))
            XCTAssertThrowsError(try gate.consume(turn: id, now: 1))
        }
    }
    func testTypedImageRejectsInvalidSubmissionTimes() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 10, now: 10)
        let image = try gate.consume(turn: id, now: 10)
        for now in [Double.nan, Double.infinity, 9.999] { XCTAssertThrowsError(try image.dataURL(now: now)) }
    }
    func testCancelledEncodingCallbackCannotRestorePixels() {
        let id = UUID(); var gate = active(id)
        gate.cancel()
        XCTAssertThrowsError(try gate.validateCapture(turn: id))
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 1, now: 2))
        XCTAssertThrowsError(try gate.consume(turn: id, now: 2))
    }
    func testOldCallbackAndCleanupDoNotEraseNewTurnsImage() throws {
        let old = UUID(), current = UUID(); var gate = active(old)
        gate.begin(turn: current, enabled: true, permissionGranted: true, modelHasVision: true)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: current, acquiredAt: 3, now: 3)
        XCTAssertThrowsError(try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: old, acquiredAt: 1, now: 3))
        gate.cancel(turn: old)
        let image = try gate.consume(turn: current, now: 4)
        XCTAssertEqual(image.turn, current); XCTAssertEqual(image.acquiredAt, 3)
    }
    func testExpiredConsumeClearsPixelsEvenIfClockThenMovesBack() throws {
        let id = UUID(); var gate = active(id)
        try gate.capturedJPEG(jpeg, width: 10, height: 10, turn: id, acquiredAt: 1, now: 1)
        XCTAssertThrowsError(try gate.consume(turn: id, now: 7))
        XCTAssertThrowsError(try gate.consume(turn: id, now: 2))
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
        XCTAssertEqual(PetLayout.panelSize.height, PetLayout.petSize.height + 8 + PetStatusLayout.controlHeight)
        XCTAssertEqual(PetLayout.petBottom, 4 + PetStatusLayout.controlHeight)
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

final class PlacementDiagnosticTests: XCTestCase {
    func testFixedFailureRecordsStageAndCodeWithoutFreeText() {
        let diagnostic = PlacementDiagnostic(stage: .capture, outcome: .failed, reason: .framework, elapsed: 0.05, errorCode: -3801)
        XCTAssertEqual(diagnostic.logLine, "DOT_PLACEMENT stage=capture outcome=failed reason=framework elapsed=50ms capture=0ms analysis=0ms regions=0 code=-3801 image=0x0 alpha=none unknown_tiles=0 added_windows=0")
    }
    func testExpiryAndInterruptionAreRejectionsNotFrameworkFailures() {
        for reason in [PlacementDiagnostic.Reason.expired, .inputChanged, .windowsChanged] {
            XCTAssertTrue(PlacementDiagnostic(stage: .validation, outcome: .rejected, reason: reason).logLine.contains("outcome=rejected"))
        }
    }
    func testMeasurementsAreFiniteAndBounded() {
        let diagnostic = PlacementDiagnostic(stage: .analysis, outcome: .cancelled, reason: .cancelled,
            elapsed: .infinity, capture: -1, analysis: 100000, regions: Int.max, errorCode: Int.min,
            imageWidth: Int.max, imageHeight: -1, observedAlpha: 256, unknownTiles: Int.max, addedWindows: Int.max)
        XCTAssertEqual(diagnostic.elapsedMilliseconds, 0); XCTAssertEqual(diagnostic.captureMilliseconds, 0)
        XCTAssertEqual(diagnostic.analysisMilliseconds, 60000); XCTAssertEqual(diagnostic.regions, 8192)
        XCTAssertEqual(diagnostic.unknownTiles, 8192); XCTAssertEqual(diagnostic.addedWindows, 512)
        XCTAssertNil(diagnostic.errorCode)
        XCTAssertEqual(diagnostic.imageWidth, 65536); XCTAssertEqual(diagnostic.imageHeight, 0); XCTAssertNil(diagnostic.observedAlpha)
    }
}

final class PlacementGeometryComparisonTests: XCTestCase {
    private let a = CGRect(x: -100, y: 20, width: 90, height: 60)
    private let b = CGRect(x: 300, y: -50, width: 40, height: 75)
    func testOrderOnlyChangeRetainsDuplicateMultiplicity() {
        XCTAssertTrue(PlacementSnapshot.sameGeometry([a, b, a], [a, a, b]))
        XCTAssertTrue(PlacementSnapshot.sameGeometry([], []))
        XCTAssertFalse(PlacementSnapshot.sameGeometry([a, b, a], [a, b, b]))
    }
    func testMoveResizeAddAndRemoveAreChanges() {
        XCTAssertFalse(PlacementSnapshot.sameGeometry([a, b], [a.offsetBy(dx: 1, dy: 0), b]))
        XCTAssertFalse(PlacementSnapshot.sameGeometry([a, b], [a.insetBy(dx: 0, dy: 1), b]))
        XCTAssertFalse(PlacementSnapshot.sameGeometry([a], [a, b]))
        XCTAssertFalse(PlacementSnapshot.sameGeometry([a, b], [a]))
    }
    func testAddedWindowsRetainEveryPriorProtectedRectangle() {
        XCTAssertTrue(PlacementSnapshot.preservesGeometry([a], in: [b, a]))
        XCTAssertTrue(PlacementSnapshot.preservesGeometry([a, a], in: [a, b, a]))
        XCTAssertTrue(PlacementSnapshot.preservesGeometry([], in: [a]))
    }
    func testAdditionsNeverHideRemovalMoveResizeOrDuplicateLoss() {
        XCTAssertFalse(PlacementSnapshot.preservesGeometry([a, b], in: [a, a]))
        XCTAssertFalse(PlacementSnapshot.preservesGeometry([a, a], in: [a, b]))
        XCTAssertFalse(PlacementSnapshot.preservesGeometry([a], in: [a.offsetBy(dx: 1, dy: 0), b]))
        XCTAssertFalse(PlacementSnapshot.preservesGeometry([a], in: [a.insetBy(dx: 1, dy: 0), b]))
        XCTAssertFalse(PlacementSnapshot.preservesGeometry([a, b], in: [a]))
        XCTAssertFalse(PlacementSnapshot.preservesGeometry([a], in: [.null, a]))
    }
    func testMalformedOrUnboundedGeometryCannotCompareEqual() {
        XCTAssertFalse(PlacementSnapshot.sameGeometry([.null], [.null]))
        XCTAssertFalse(PlacementSnapshot.sameGeometry([.zero], [.zero]))
        XCTAssertFalse(PlacementSnapshot.sameGeometry([CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)],
                                                     [CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1)]))
        let tooMany = Array(repeating: a, count: PlacementSnapshot.maximumRegions + 1)
        XCTAssertFalse(PlacementSnapshot.sameGeometry(tooMany, tooMany))
    }
}

final class CompactIssueTests: XCTestCase {
    func testEveryIssueUsesShortSingleLineTitlesAndRetryActions() {
        for issue in CompanionIssue.allCases {
            for value in [issue.title, issue.retryTitle] {
                XCTAssertLessThanOrEqual(value.count, 28)
                XCTAssertFalse(value.contains("\n")); XCTAssertFalse(value.isEmpty)
            }
        }
    }
    func testArbitrarilyLongFailureDoesNotBecomeMenuHeader() {
        let long = String(repeating: "private detail ", count: 10000)
        XCTAssertEqual(CompanionIssue.menuHeader(readiness: .unavailable(long), issue: nil, progress: 0), "App files need repair")
        XCTAssertEqual(CompanionIssue.menuHeader(readiness: .ready, issue: .screenPermission, progress: 1), "Screen access needed")
    }
    func testCheckingProgressIsFiniteAndClamped() {
        XCTAssertEqual(CompanionIssue.menuHeader(readiness: .checking, issue: nil, progress: .nan), "Checking files, 0%")
        XCTAssertEqual(CompanionIssue.menuHeader(readiness: .checking, issue: nil, progress: 10), "Checking files, 100%")
        XCTAssertEqual(CompanionIssue.menuHeader(readiness: .checking, issue: nil, progress: -1), "Checking files, 0%")
    }
    func testDetailsActionOnlyAppearsWhenNeededAndQuitStaysLast() {
        for state in [CompanionReadiness.checking, .paused, .ready, .unavailable("detail")] {
            for busy in [false, true] {
                let normal = CompanionMenuAction.available(readiness: state, busy: busy)
                XCTAssertFalse(normal.contains(.copyDetails))
                let detail = CompanionMenuAction.available(readiness: state, busy: busy, hasDetails: true)
                XCTAssertEqual(detail.filter { $0 == .copyDetails }.count, 1)
                XCTAssertEqual(detail.last, .quit); XCTAssertLessThanOrEqual(detail.count, 8)
            }
        }
    }
}

final class QuestionReplyGateTests: XCTestCase {
    private func consume(_ gate: inout QuestionReplyGate, _ turn: UUID, at time: Double = 1) -> UUID? {
        gate.consume(turn: turn, now: time, ready: true, microphoneAuthorized: true, screenAuthorized: true, interacting: false)
    }
    func testCompleteQuestionAndItsActualPlaybackAreBothRequired() {
        var gate = QuestionReplyGate(); let turn = UUID(), question = UUID()
        gate.begin(turn: turn, explicitClick: true)
        gate.questionPlayed(turn: turn, question: question, now: 0)
        XCTAssertNil(consume(&gate, turn))
        gate.responseFinished(turn: turn, question: question, succeeded: true)
        XCTAssertNil(consume(&gate, turn))
        gate.questionPlayed(turn: turn, question: question, now: 0)
        XCTAssertEqual(consume(&gate, turn), question); XCTAssertNil(consume(&gate, turn))
    }
    func testOrdinaryOrQuotedQuestionTextHasNoExplicitIntent() {
        // Text is deliberately not an input to this policy: '?', quotes and rhetoric
        // cannot synthesize a question ID. The structured parser must prove intent.
        for _ in ["Why?", "The quote says 'What is this?'", "Who wouldn't enjoy that?"] {
            var gate = QuestionReplyGate(); let turn = UUID()
            gate.begin(turn: turn, explicitClick: true)
            gate.responseFinished(turn: turn, question: nil, succeeded: true)
            gate.questionPlayed(turn: turn, question: UUID(), now: 0)
            XCTAssertNil(consume(&gate, turn))
        }
    }
    func testFailedTruncatedOrUnplayedResponseNeverArms() {
        var gate = QuestionReplyGate(); let turn = UUID(), question = UUID()
        gate.begin(turn: turn, explicitClick: true)
        gate.responseFinished(turn: turn, question: question, succeeded: false)
        gate.questionPlayed(turn: turn, question: question, now: 0)
        XCTAssertNil(consume(&gate, turn))
    }
    func testStopAndReplacementRejectStalePlayback() {
        var gate = QuestionReplyGate(); let first = UUID(), next = UUID(), question = UUID()
        gate.begin(turn: first, explicitClick: true)
        gate.responseFinished(turn: first, question: question, succeeded: true)
        gate.cancel(); gate.questionPlayed(turn: first, question: question, now: 0)
        XCTAssertNil(consume(&gate, first))
        gate.begin(turn: next, explicitClick: true)
        gate.responseFinished(turn: first, question: question, succeeded: true)
        gate.questionPlayed(turn: first, question: question, now: 0)
        XCTAssertNil(consume(&gate, next))
    }
    func testInterruptionOrMissingPermissionCancelsRatherThanDefersListening() {
        for missing in 0..<4 {
            var gate = QuestionReplyGate(); let turn = UUID(), question = UUID()
            gate.begin(turn: turn, explicitClick: true)
            gate.responseFinished(turn: turn, question: question, succeeded: true)
            gate.questionPlayed(turn: turn, question: question, now: 0)
            XCTAssertNil(gate.consume(turn: turn, now: 1, ready: missing != 0, microphoneAuthorized: missing != 1,
                screenAuthorized: missing != 2, interacting: missing == 3))
            XCTAssertNil(consume(&gate, turn))
        }
    }
    func testSettleDelayAndExpiryCannotBeExtendedByRepeatedDrain() {
        var gate = QuestionReplyGate(); let turn = UUID(), question = UUID()
        gate.begin(turn: turn, explicitClick: true)
        gate.responseFinished(turn: turn, question: question, succeeded: true)
        gate.questionPlayed(turn: turn, question: question, now: 0)
        XCTAssertNil(consume(&gate, turn, at: 0.2))
        gate.responseFinished(turn: turn, question: question, succeeded: true)
        gate.questionPlayed(turn: turn, question: question, now: 7)
        XCTAssertNil(consume(&gate, turn, at: 9)); XCTAssertNil(consume(&gate, turn, at: 10))
    }
    func testAutomaticChainIsBoundedAndExplicitClickResetsBudget() {
        var gate = QuestionReplyGate()
        var continuation: UUID?
        for index in 0...QuestionReplyGate.maximumAutomaticReplies {
            let turn = UUID(), question = UUID()
            gate.begin(turn: turn, explicitClick: index == 0, continuation: continuation, now: Double(index))
            gate.responseFinished(turn: turn, question: question, succeeded: true)
            gate.questionPlayed(turn: turn, question: question, now: Double(index))
            continuation = consume(&gate, turn, at: Double(index) + 1)
            XCTAssertEqual(continuation, index < QuestionReplyGate.maximumAutomaticReplies ? question : nil)
        }
        let turn = UUID(), question = UUID(); gate.begin(turn: turn, explicitClick: true)
        gate.responseFinished(turn: turn, question: question, succeeded: true)
        gate.questionPlayed(turn: turn, question: question, now: 0)
        XCTAssertEqual(consume(&gate, turn), question)
    }
}


extension QuestionReplyGateTests {
    func testIdleOrStoppedConversationCannotBeginAutomatically() {
        for stopped in [false, true] {
            var gate = QuestionReplyGate(); let first = UUID(), next = UUID(), question = UUID()
            if stopped {
                gate.begin(turn: first, explicitClick: true)
                gate.responseFinished(turn: first, question: question, succeeded: true)
                gate.questionPlayed(turn: first, question: question, now: 0)
                XCTAssertEqual(consume(&gate, first), question)
                gate.cancel()
            }
            gate.begin(turn: next, explicitClick: false, continuation: question, now: 1)
            gate.responseFinished(turn: next, question: question, succeeded: true)
            gate.questionPlayed(turn: next, question: question, now: 1)
            XCTAssertNil(consume(&gate, next, at: 2))
        }
    }
    func testContinuationIsExactSingleUseAndExpires() {
        for failure in 0..<3 {
            var gate = QuestionReplyGate(); let first = UUID(), next = UUID(), question = UUID()
            gate.begin(turn: first, explicitClick: true)
            gate.responseFinished(turn: first, question: question, succeeded: true)
            gate.questionPlayed(turn: first, question: question, now: 0)
            XCTAssertEqual(consume(&gate, first), question)
            gate.begin(turn: next, explicitClick: false, continuation: failure == 0 ? UUID() : question, now: failure == 1 ? 3 : 1)
            if failure == 2 { gate.begin(turn: next, explicitClick: false, continuation: question, now: 1) }
            gate.responseFinished(turn: next, question: question, succeeded: true)
            gate.questionPlayed(turn: next, question: question, now: 3)
            XCTAssertNil(consume(&gate, next, at: 4))
        }
    }
    func testCopiedDiagnosticCannotContainRawErrorPayload() {
        let summary = CompanionIssue.copiedDiagnostic(readiness: .unavailable("/private/secret user transcript token=ABC"), issue: .voice)
        XCTAssertEqual(summary, "Dot diagnostic summary\nPreparation: unavailable\nIssue: Voice unavailable")
        XCTAssertFalse(summary.contains("secret")); XCTAssertFalse(summary.contains("ABC"))
    }
}

final class QuestionIntentStreamTests: XCTestCase {
    private func frame(_ delta: [String: Any] = [:], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
    }
    private func call(_ arguments: String, name: String = "ask_user", index: Any = 0) throws -> String {
        try frame(["tool_calls": [["index": index, "id": "call_question", "type": "function", "function": ["name": name, "arguments": arguments]]]])
    }
    func testFragmentedQuestionNeedsTerminalAndDone() throws {
        var stream = QuestionIntentStream()
        try stream.feed(call("{\"question\":\"Which "))
        try stream.feed(frame(["tool_calls": [["index": 0, "function": ["arguments": "colour do you prefer?\"}"]]]]))
        XCTAssertThrowsError(try stream.completed())
        try stream.feed(frame(finish: "tool_calls")); XCTAssertThrowsError(try stream.completed())
        try stream.feed("data: [DONE]")
        XCTAssertEqual(try stream.completed()?.text, "Which colour do you prefer?")
    }
    func testPlainAndQuotedQuestionsNeverProduceIntent() throws {
        for text in ["Why?", "The quotation is: What is this?", "Who wouldn't like that?"] {
            var stream = QuestionIntentStream()
            try stream.feed(frame(["content": text])); try stream.feed(frame(finish: "stop")); try stream.feed("data: [DONE]")
            XCTAssertNil(try stream.completed())
        }
    }
    func testWrongFinishOrTruncationCannotArm() throws {
        for reason in ["stop", "length", "content_filter"] {
            var stream = QuestionIntentStream(); try stream.feed(call("{\"question\":\"Your preference?\"}"))
            try stream.feed(frame(finish: reason)); try stream.feed("data: [DONE]")
            XCTAssertThrowsError(try stream.completed())
        }
    }
    func testUnknownMultipleAndBooleanIndexedCallsReject() throws {
        var unknown = QuestionIntentStream(); XCTAssertThrowsError(try unknown.feed(call("{}", name: "execute")))
        var index = QuestionIntentStream(); XCTAssertThrowsError(try index.feed(call("{}", index: true)))
        var multiple = QuestionIntentStream()
        XCTAssertThrowsError(try multiple.feed(frame(["tool_calls": [["index": 0], ["index": 1]]])))
    }
    func testArgumentsAreExactAndBounded() throws {
        for arguments in ["{}", "{\"question\":\"\"}", "{\"question\":\"Yes?\",\"command\":\"run\"}",
                          "{\"question\":\"" + String(repeating: "a", count: 401) + "\"}"] {
            var stream = QuestionIntentStream(); try stream.feed(call(arguments))
            try stream.feed(frame(finish: "tool_calls")); try stream.feed("data: [DONE]")
            XCTAssertThrowsError(try stream.completed())
        }
        var oversized = QuestionIntentStream(); XCTAssertThrowsError(try oversized.feed(call(String(repeating: "x", count: 2049))))
    }
    func testDuplicateKeysAndTrailingCommasCannotProduceQuestionIntent() throws {
        for arguments in [#"{"question":"First?","question":"Second?"}"#, #"{"question":"Yes?",}"#] {
            var stream = QuestionIntentStream(); try stream.feed(call(arguments))
            try stream.feed(frame(finish: "tool_calls")); try stream.feed("data: [DONE]")
            XCTAssertThrowsError(try stream.completed())
        }
    }
    func testStrictArgumentsStillAllowJSONEscapedQuestionText() throws {
        var stream = QuestionIntentStream()
        try stream.feed(call(#" { "question" : "Would you choose \"blue\"?" } "#))
        try stream.feed(frame(finish: "tool_calls")); try stream.feed("data: [DONE]")
        XCTAssertEqual(try stream.completed()?.text, "Would you choose \"blue\"?")
    }
    func testNonObjectDeltaInvalidatesPreviouslyValidQuestion() throws {
        for delta in ["malformed", NSNull(), 1, ["array"]] as [Any] {
            var stream = QuestionIntentStream()
            try stream.feed(call("{\"question\":\"Your preference?\"}"))
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": delta, "finish_reason": "tool_calls"]]])
            XCTAssertThrowsError(try stream.feed("data: " + String(decoding: data, as: UTF8.self)))
            XCTAssertThrowsError(try stream.feed("data: [DONE]"))
            XCTAssertThrowsError(try stream.completed())
        }
    }
    func testMalformedOrPostCompletionFramesStayRejected() throws {
        var invalid = QuestionIntentStream(); XCTAssertThrowsError(try invalid.feed("data: {"))
        XCTAssertThrowsError(try invalid.feed("data: [DONE]")); XCTAssertThrowsError(try invalid.completed())
        var complete = QuestionIntentStream(); try complete.feed("data: [DONE]")
        XCTAssertThrowsError(try complete.feed(call("{}"))); XCTAssertThrowsError(try complete.completed())
    }
}


extension QuestionIntentStreamTests {
    func testOrdinaryAnswersNeedSuccessfulStopTerminal() throws {
        for reason in [nil, "length", "content_filter", "tool_calls"] as [String?] {
            var stream = QuestionIntentStream()
            try stream.feed(frame(["content": "Answer"], finish: reason)); try stream.feed("data: [DONE]")
            XCTAssertThrowsError(try stream.completed())
        }
    }
    func testErrorEnvelopeAndTextAfterCallInvalidateIntent() throws {
        var failure = QuestionIntentStream()
        XCTAssertThrowsError(try failure.feed(#"data: {"error":{"message":"failed"}}"#))
        var stream = QuestionIntentStream(); try stream.feed(call(#"{"question":"Which?"}"#))
        XCTAssertThrowsError(try stream.feed(frame(["content": "A later answer."])))
        XCTAssertThrowsError(try stream.completed())
    }
    func testUsageChunkAfterSuccessfulTerminalIsAllowed() throws {
        var stream = QuestionIntentStream(); try stream.feed(call(#"{"question":"Which?"}"#))
        try stream.feed(frame(finish: "tool_calls"))
        try stream.feed(#"data: {"choices":[],"usage":{"completion_tokens":12}}"#)
        try stream.feed("data: [DONE]"); XCTAssertEqual(try stream.completed()?.text, "Which?")
    }
}

final class FinalPlaybackBarrierTests: XCTestCase {
    func testIntermediateDrainAndGenerationAloneCannotComplete() {
        var barrier = FinalPlaybackBarrier(); let turn = UUID(), answer = UUID(), question = UUID()
        barrier.begin(turn: turn)
        XCTAssertTrue(barrier.enqueue(turn: turn, request: answer))
        XCTAssertNil(barrier.playbackFinished(turn: turn, request: answer, successfully: true))
        XCTAssertTrue(barrier.enqueue(turn: turn, request: question))
        XCTAssertNil(barrier.generationComplete(turn: turn))
        XCTAssertEqual(barrier.playbackFinished(turn: turn, request: question, successfully: true), turn)
        XCTAssertNil(barrier.playbackFinished(turn: turn, request: question, successfully: true))
        XCTAssertNil(barrier.generationComplete(turn: turn))
    }
    func testAllSuccessfulRequestsAndFinalSealAreRequiredInEitherOrdering() {
        for sealFirst in [false, true] {
            var barrier = FinalPlaybackBarrier(); let turn = UUID(), first = UUID(), last = UUID()
            barrier.begin(turn: turn)
            XCTAssertTrue(barrier.enqueue(turn: turn, request: first)); XCTAssertTrue(barrier.enqueue(turn: turn, request: last))
            if sealFirst { XCTAssertNil(barrier.generationComplete(turn: turn)) }
            XCTAssertNil(barrier.playbackFinished(turn: turn, request: last, successfully: true))
            let result = barrier.playbackFinished(turn: turn, request: first, successfully: true)
            XCTAssertEqual(result, sealFirst ? turn : nil)
            XCTAssertEqual(barrier.generationComplete(turn: turn), sealFirst ? nil : turn)
        }
    }
    func testFailedAudioStopReplacementAndUnknownCallbacksCannotComplete() {
        for failure in 0..<3 {
            var barrier = FinalPlaybackBarrier(); let turn = UUID(), request = UUID()
            barrier.begin(turn: turn); XCTAssertTrue(barrier.enqueue(turn: turn, request: request))
            XCTAssertNil(barrier.generationComplete(turn: turn))
            XCTAssertNil(barrier.playbackFinished(turn: turn, request: UUID(), successfully: true))
            if failure == 0 { XCTAssertNil(barrier.playbackFinished(turn: turn, request: request, successfully: false)) }
            if failure == 1 { barrier.cancel() }
            if failure == 2 { barrier.begin(turn: UUID()) }
            XCTAssertNil(barrier.playbackFinished(turn: turn, request: request, successfully: true))
            XCTAssertNil(barrier.generationComplete(turn: turn))
        }
    }
    func testNoAudioDuplicateRequestOrLateSentenceCannotGrantCompletion() {
        var barrier = FinalPlaybackBarrier(); let turn = UUID(), request = UUID()
        barrier.begin(turn: turn); XCTAssertNil(barrier.generationComplete(turn: turn))
        XCTAssertFalse(barrier.enqueue(turn: turn, request: request))
        barrier.begin(turn: turn); XCTAssertTrue(barrier.enqueue(turn: turn, request: request))
        XCTAssertFalse(barrier.enqueue(turn: turn, request: request))
        XCTAssertNil(barrier.generationComplete(turn: turn))
        XCTAssertFalse(barrier.enqueue(turn: turn, request: UUID()))
        XCTAssertNil(barrier.playbackFinished(turn: UUID(), request: request, successfully: true))
        XCTAssertEqual(barrier.playbackFinished(turn: turn, request: request, successfully: true), turn)
    }
}

final class HardwareCompatibilityTests: XCTestCase {
    func testHardwareCompatibilityMeetsSpecification() {
        let m5Pro = HardwareCompatibility.SystemInfo(chip: "Apple M5 Pro", ramGB: 48, osMajor: 27, osMinor: 0, osPatch: 1, isAppleSilicon: true)
        XCTAssertTrue(m5Pro.meetsChipSpec)
        XCTAssertTrue(m5Pro.meetsRAMSpec)
        XCTAssertTrue(m5Pro.meetsOSSpec)
        XCTAssertTrue(m5Pro.meetsAllSpecs)
        XCTAssertNil(m5Pro.technicalImpossibilityReason)
        XCTAssertEqual(HardwareCompatibility.evaluate(info: m5Pro), .compatible(m5Pro))

        let m4Max = HardwareCompatibility.SystemInfo(chip: "Apple M4 Max", ramGB: 64, osMajor: 27, osMinor: 1, osPatch: 0, isAppleSilicon: true)
        XCTAssertTrue(m4Max.meetsAllSpecs)
        XCTAssertEqual(HardwareCompatibility.evaluate(info: m4Max), .compatible(m4Max))

        let m4Pro = HardwareCompatibility.SystemInfo(chip: "Apple M4 Pro", ramGB: 48, osMajor: 27, osMinor: 0, osPatch: 0, isAppleSilicon: true)
        XCTAssertTrue(m4Pro.meetsAllSpecs)
        XCTAssertEqual(HardwareCompatibility.evaluate(info: m4Pro), .compatible(m4Pro))
    }

    func testHardwareCompatibilityBelowSpecification() {
        // Base M4 (not Pro/Max/Ultra)
        let m4Base = HardwareCompatibility.SystemInfo(chip: "Apple M4", ramGB: 48, osMajor: 27, osMinor: 0, osPatch: 0, isAppleSilicon: true)
        XCTAssertFalse(m4Base.meetsChipSpec)
        XCTAssertTrue(m4Base.meetsRAMSpec)
        XCTAssertNil(m4Base.technicalImpossibilityReason)
        if case .belowMinimum(_, let reasons) = HardwareCompatibility.evaluate(info: m4Base) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("below recommended M4 Pro") }))
        } else {
            XCTFail("Expected belowMinimum for base M4")
        }

        // M4 Pro with 32 GB RAM (< 48 GB)
        let m4Pro32 = HardwareCompatibility.SystemInfo(chip: "Apple M4 Pro", ramGB: 32, osMajor: 27, osMinor: 0, osPatch: 0, isAppleSilicon: true)
        XCTAssertTrue(m4Pro32.meetsChipSpec)
        XCTAssertFalse(m4Pro32.meetsRAMSpec)
        XCTAssertNil(m4Pro32.technicalImpossibilityReason)
        if case .belowMinimum(_, let reasons) = HardwareCompatibility.evaluate(info: m4Pro32) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("Unified Memory") }))
        } else {
            XCTFail("Expected belowMinimum for 32 GB RAM")
        }

        // M5 Pro with macOS 26 (< 27)
        let m5ProOlderOS = HardwareCompatibility.SystemInfo(chip: "Apple M5 Pro", ramGB: 48, osMajor: 26, osMinor: 0, osPatch: 0, isAppleSilicon: true)
        XCTAssertFalse(m5ProOlderOS.meetsOSSpec)
        XCTAssertNil(m5ProOlderOS.technicalImpossibilityReason)
        if case .belowMinimum(_, let reasons) = HardwareCompatibility.evaluate(info: m5ProOlderOS) {
            XCTAssertTrue(reasons.contains(where: { $0.contains("macOS 27") }))
        } else {
            XCTFail("Expected belowMinimum for older OS")
        }

        // Older M3 Max
        let m3Max = HardwareCompatibility.SystemInfo(chip: "Apple M3 Max", ramGB: 64, osMajor: 27, osMinor: 0, osPatch: 0, isAppleSilicon: true)
        XCTAssertFalse(m3Max.meetsChipSpec)
        if case .belowMinimum = HardwareCompatibility.evaluate(info: m3Max) {
            // Success
        } else {
            XCTFail("Expected belowMinimum for M3 Max")
        }
    }

    func testHardwareCompatibilityTechnicallyImpossible() {
        // Intel Mac
        let intel = HardwareCompatibility.SystemInfo(chip: "Intel Core i9", ramGB: 64, osMajor: 27, osMinor: 0, osPatch: 0, isAppleSilicon: false)
        XCTAssertNotNil(intel.technicalImpossibilityReason)
        if case .technicallyImpossible(_, let reason) = HardwareCompatibility.evaluate(info: intel) {
            XCTAssertTrue(reason.contains("Intel"))
        } else {
            XCTFail("Expected technicallyImpossible for Intel Mac")
        }

        // Apple Silicon with < 24 GB RAM (8 GB or 16 GB)
        let m1LowRAM = HardwareCompatibility.SystemInfo(chip: "Apple M1", ramGB: 16, osMajor: 27, osMinor: 0, osPatch: 0, isAppleSilicon: true)
        XCTAssertNotNil(m1LowRAM.technicalImpossibilityReason)
        if case .technicallyImpossible(_, let reason) = HardwareCompatibility.evaluate(info: m1LowRAM) {
            XCTAssertTrue(reason.contains("24 GB"))
        } else {
            XCTFail("Expected technicallyImpossible for 16 GB RAM")
        }

        // macOS < 15
        let oldOS = HardwareCompatibility.SystemInfo(chip: "Apple M4 Pro", ramGB: 48, osMajor: 14, osMinor: 5, osPatch: 0, isAppleSilicon: true)
        XCTAssertNotNil(oldOS.technicalImpossibilityReason)
        if case .technicallyImpossible(_, let reason) = HardwareCompatibility.evaluate(info: oldOS) {
            XCTAssertTrue(reason.contains("macOS 15"))
        } else {
            XCTFail("Expected technicallyImpossible for macOS < 15")
        }
    }

    func testHardwareCompatibilityStatusSummary() {
        let current = HardwareCompatibility.queryCurrent()
        let summary = HardwareCompatibility.statusSummary(info: current)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains(current.chip))
    }
}

final class ActiveDesktopContextTests: XCTestCase {
    func testPromptContextSnippetFormatting() {
        let empty = ActiveDesktopContext(appName: nil, windowTitle: nil, selectedText: nil)
        XCTAssertNil(empty.promptContextSnippet)

        let appOnly = ActiveDesktopContext(appName: "Safari", windowTitle: nil, selectedText: nil)
        XCTAssertEqual(appOnly.promptContextSnippet, "[Active App: Safari]")

        let appAndWin = ActiveDesktopContext(appName: "Xcode", windowTitle: "ScreenContext.swift", selectedText: nil)
        XCTAssertEqual(appAndWin.promptContextSnippet, "[Active App: Xcode (\"ScreenContext.swift\")]")

        let full = ActiveDesktopContext(appName: "Notes", windowTitle: "Ideas", selectedText: "Meeting at 3 PM")
        XCTAssertEqual(full.promptContextSnippet, "[Active App: Notes (\"Ideas\") | User highlighted selection: \"Meeting at 3 PM\"]")

        let longText = String(repeating: "A", count: 2000)
        let truncated = ActiveDesktopContext(appName: "Xcode", windowTitle: nil, selectedText: longText)
        XCTAssertTrue(truncated.promptContextSnippet!.contains("…\""))
        XCTAssertTrue(truncated.promptContextSnippet!.count < 1600)
    }
}

final class SmartTimerTests: XCTestCase {
    func testSmartTimerParser() {
        XCTAssertEqual(SmartTimerParser.parse("set a timer for 10 minutes"), .create(seconds: 600, label: "Timer"))
        XCTAssertEqual(SmartTimerParser.parse("timer 5 min"), .create(seconds: 300, label: "Timer"))
        XCTAssertEqual(SmartTimerParser.parse("remind me in 30 seconds to stretch"), .create(seconds: 30, label: "stretch"))
        XCTAssertEqual(SmartTimerParser.parse("timer for 1.5 hours to finish report"), .create(seconds: 5400, label: "finish report"))
        XCTAssertEqual(SmartTimerParser.parse("cancel timer"), .cancel(label: nil))
        XCTAssertEqual(SmartTimerParser.parse("stop timer"), .cancel(label: nil))
        XCTAssertEqual(SmartTimerParser.parse("show timers"), .list)
        XCTAssertEqual(SmartTimerParser.parse("list timers"), .list)
        XCTAssertEqual(SmartTimerParser.parse("what is the capital of France"), .none)
    }

    func testSmartTimerScheduler() async {
        final class FiredBox: @unchecked Sendable { var fired = false }
        let box = FiredBox()
        let scheduler = SmartTimerScheduler.shared
        _ = scheduler.cancelAll()
        XCTAssertEqual(scheduler.activeTimers().count, 0)

        let timer = scheduler.schedule(seconds: 0.1, label: "Quick Test") { _ in
            box.fired = true
        }
        XCTAssertEqual(timer.label, "Quick Test")
        XCTAssertEqual(scheduler.activeTimers().count, 1)

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(box.fired)
        XCTAssertEqual(scheduler.activeTimers().count, 0)

        _ = scheduler.schedule(seconds: 100, label: "Long Timer")
        XCTAssertEqual(scheduler.activeTimers().count, 1)
        let cancelled = scheduler.cancelAll()
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(scheduler.activeTimers().count, 0)
    }

    func testDurationFormatting() {
        XCTAssertEqual(SmartTimerScheduler.formatDuration(30), "30 seconds")
        XCTAssertEqual(SmartTimerScheduler.formatDuration(60), "1 minute")
        XCTAssertEqual(SmartTimerScheduler.formatDuration(300), "5 minutes")
        XCTAssertEqual(SmartTimerScheduler.formatDuration(3665), "1h 1m")
    }
}

final class InPlaceAppTypingTests: XCTestCase {
    func testParseCommand() {
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type this: Hello World"), .type(text: "Hello World"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type this draft response"), .type(text: "draft response"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type into app: func main()"), .type(text: "func main()"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("dictate: Dear team,"), .type(text: "Dear team,"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("write into app: notes"), .type(text: "notes"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type 'hello' in that input"), .type(text: "hello"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type \"Continue\" into the focused app"), .type(text: "Continue"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type 'Привет мир 🚀' in that input"), .type(text: "Привет мир 🚀"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type 'Continue' and press enter"), .typeAndSubmit(text: "Continue"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Enter"), .pressKey(key: "Enter"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Tab"), .pressKey(key: "Tab"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Escape"), .pressKey(key: "Escape"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Backspace"), .pressKey(key: "Backspace"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Cmd+C"), .pressKey(key: "Cmd+C"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Cmd+V"), .pressKey(key: "Cmd+V"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("press Cmd+A"), .pressKey(key: "Cmd+A"))
        XCTAssertEqual(InPlaceAppTyping.parseCommand("hello world"), .none)
        XCTAssertEqual(InPlaceAppTyping.parseCommand("type of file"), .none)
    }

    func testParseKeySpecSpecialAndModifierKeys() {
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Enter"), InPlaceAppTyping.KeySpec(keyCode: 36, flags: 0, displayName: "Enter"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Return"), InPlaceAppTyping.KeySpec(keyCode: 36, flags: 0, displayName: "Enter"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Tab"), InPlaceAppTyping.KeySpec(keyCode: 48, flags: 0, displayName: "Tab"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Escape"), InPlaceAppTyping.KeySpec(keyCode: 53, flags: 0, displayName: "Escape"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Backspace"), InPlaceAppTyping.KeySpec(keyCode: 51, flags: 0, displayName: "Backspace"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Delete"), InPlaceAppTyping.KeySpec(keyCode: 51, flags: 0, displayName: "Backspace"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("ForwardDelete"), InPlaceAppTyping.KeySpec(keyCode: 117, flags: 0, displayName: "Forward Delete"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Space"), InPlaceAppTyping.KeySpec(keyCode: 49, flags: 0, displayName: "Space"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Up"), InPlaceAppTyping.KeySpec(keyCode: 126, flags: 0, displayName: "Up Arrow"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Down"), InPlaceAppTyping.KeySpec(keyCode: 125, flags: 0, displayName: "Down Arrow"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Left"), InPlaceAppTyping.KeySpec(keyCode: 123, flags: 0, displayName: "Left Arrow"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Right"), InPlaceAppTyping.KeySpec(keyCode: 124, flags: 0, displayName: "Right Arrow"))

        // Modifier combinations
        let cmdMask: UInt64 = 0x100000
        let shiftMask: UInt64 = 0x020000
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Cmd+C"), InPlaceAppTyping.KeySpec(keyCode: 8, flags: cmdMask, displayName: "Cmd+C"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Cmd+V"), InPlaceAppTyping.KeySpec(keyCode: 9, flags: cmdMask, displayName: "Cmd+V"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Cmd+A"), InPlaceAppTyping.KeySpec(keyCode: 0, flags: cmdMask, displayName: "Cmd+A"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Command+Shift+Z"), InPlaceAppTyping.KeySpec(keyCode: 6, flags: cmdMask | shiftMask, displayName: "Cmd+Shift+Z"))
        XCTAssertEqual(InPlaceAppTyping.parseKeySpec("Shift+Enter"), InPlaceAppTyping.KeySpec(keyCode: 36, flags: shiftMask, displayName: "Shift+Enter"))
    }

    func testQuestionIntentStreamParsesTypeTextAndPressKeyTools() throws {
        func toolFrame(name: String, arguments: String) throws -> String {
            let obj: [String: Any] = [
                "choices": [[
                    "index": 0,
                    "delta": [
                        "tool_calls": [[
                            "index": 0,
                            "id": "call_123",
                            "type": "function",
                            "function": ["name": name, "arguments": arguments]
                        ]]
                    ]
                ]]
            ]
            return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let finishFrame = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#

        var typeStream = QuestionIntentStream()
        try typeStream.feed(toolFrame(name: "type_text", arguments: #"{"text":"Continue — Привет 🚀"}"#))
        try typeStream.feed(finishFrame)
        try typeStream.feed("data: [DONE]")
        XCTAssertNil(try typeStream.completed())
        XCTAssertEqual(try typeStream.completedToolAction(), .typeText("Continue — Привет 🚀"))

        var keyStream = QuestionIntentStream()
        try keyStream.feed(toolFrame(name: "press_key", arguments: #"{"key":"Cmd+V"}"#))
        try keyStream.feed(finishFrame)
        try keyStream.feed("data: [DONE]")
        XCTAssertNil(try keyStream.completed())
        XCTAssertEqual(try keyStream.completedToolAction(), .pressKey("Cmd+V"))

        var cmdStream = QuestionIntentStream()
        try cmdStream.feed(toolFrame(name: "execute_command", arguments: #"{"command":"git status","explanation":"Check working tree"}"#))
        try cmdStream.feed(finishFrame)
        try cmdStream.feed("data: [DONE]")
        XCTAssertNil(try cmdStream.completed())
        XCTAssertEqual(try cmdStream.completedToolAction(), .executeCommand(command: "git status", explanation: "Check working tree"))

        var delStream = QuestionIntentStream()
        try delStream.feed(toolFrame(name: "delete_file", arguments: #"{"path":"/tmp/test.txt"}"#))
        try delStream.feed(finishFrame)
        try delStream.feed("data: [DONE]")
        XCTAssertNil(try delStream.completed())
        XCTAssertEqual(try delStream.completedToolAction(), .deleteFile(path: "/tmp/test.txt", explanation: nil))

        var workflowStream = QuestionIntentStream()
        try workflowStream.feed(toolFrame(name: "contextual_workflow", arguments: #"{"app":"xcode","action":"build"}"#))
        try workflowStream.feed(finishFrame)
        try workflowStream.feed("data: [DONE]")
        XCTAssertNil(try workflowStream.completed())
        XCTAssertEqual(try workflowStream.completedToolAction(), .contextualWorkflow(app: "xcode", action: "build"))

        var calStream = QuestionIntentStream()
        try calStream.feed(toolFrame(name: "calendar_schedule", arguments: #"{"action":"today_schedule"}"#))
        try calStream.feed(finishFrame)
        try calStream.feed("data: [DONE]")
        XCTAssertNil(try calStream.completed())
        XCTAssertEqual(try calStream.completedToolAction(), .calendarSchedule(action: "today_schedule", title: nil, startTime: nil, durationMinutes: nil))
    }

    func testActionApprovalRequestDestructiveGuard() {
        XCTAssertTrue(ActionApprovalRequest.isPotentiallyDestructive("rm -rf /tmp/test"))
        XCTAssertTrue(ActionApprovalRequest.isPotentiallyDestructive("sudo make install"))
        XCTAssertTrue(ActionApprovalRequest.isPotentiallyDestructive("git reset --hard HEAD~1"))
        XCTAssertTrue(ActionApprovalRequest.isPotentiallyDestructive("killall Dot"))
        XCTAssertFalse(ActionApprovalRequest.isPotentiallyDestructive("git status"))
        XCTAssertFalse(ActionApprovalRequest.isPotentiallyDestructive("ls -la"))
        XCTAssertFalse(ActionApprovalRequest.isPotentiallyDestructive("cargo test"))
    }

    func testContextualWorkflowAppIdentification() {
        XCTAssertEqual(ContextualWorkflowApp.identify(bundleID: "com.apple.dt.Xcode", appName: "Xcode"), .xcode)
        XCTAssertEqual(ContextualWorkflowApp.identify(bundleID: "com.apple.Terminal", appName: "Terminal"), .terminal)
        XCTAssertEqual(ContextualWorkflowApp.identify(bundleID: "com.apple.Safari", appName: "Safari"), .safari)
        XCTAssertEqual(ContextualWorkflowApp.identify(bundleID: "com.figma.Desktop", appName: "Figma"), .figma)
        XCTAssertEqual(ContextualWorkflowApp.identify(bundleID: "com.random.app", appName: "Notes"), .unknown)
    }

    @MainActor
    func testStuckTaskDetectorEvaluation() {
        let detector = StuckTaskDetector()
        detector.reset()

        // Initially seeing an error should record observation but not alert immediately (< 180s)
        let event1 = detector.evaluate(appName: "Xcode", windowTitle: "Build failed with 2 errors", ocrText: "error: cannot find type in scope", now: 100)
        XCTAssertNil(event1)

        // After 60 seconds, still not threshold
        let event2 = detector.evaluate(appName: "Xcode", windowTitle: "Build failed with 2 errors", ocrText: "error: cannot find type in scope", now: 160)
        XCTAssertNil(event2)

        // After 181 seconds, threshold exceeded: triggers alert!
        let event3 = detector.evaluate(appName: "Xcode", windowTitle: "Build failed with 2 errors", ocrText: "error: cannot find type in scope", now: 285)
        XCTAssertNotNil(event3)
        XCTAssertEqual(event3?.appName, "Xcode")
        XCTAssertTrue(event3?.guidance.contains("Xcode build error") ?? false)
    }
}

final class IdleSelfReflectionAndAutonomyTests: XCTestCase {
    func testIdleSelfReflectionCadenceAndLogAnalysis() {
        let engine = IdleSelfReflectionEngine()
        engine.recordUserActivity(now: 100)
        engine.markReflected(now: 100)
        XCTAssertFalse(engine.shouldTriggerReflection(now: 500))
        XCTAssertTrue(engine.shouldTriggerReflection(now: 701))

        let sampleLog = """
        [2026-10-16T00:00:00Z] [USER] type 'Continue' in that input
        [2026-10-16T00:00:02Z] [DOT (SELF-IMPROVEMENT)] TASK: "snap window" | REASON: Window not snapped | MISSING: WindowLayoutManager | PROPOSED_FIX: Add AX window snapping
        """
        let suggestion = engine.analyzeConversationLog(logContent: sampleLog)
        XCTAssertTrue(suggestion.contains("Dot 10-min self-reflection"))
        XCTAssertTrue(suggestion.contains("WindowLayoutManager"))
    }

    func testWindowLayoutAndDeveloperSuites() {
        XCTAssertEqual(WindowLayoutManager.parseCommand("snap window left"), .leftHalf)
        XCTAssertEqual(WindowLayoutManager.parseCommand("snap window right"), .rightHalf)
        XCTAssertEqual(WindowLayoutManager.parseCommand("maximize window"), .maximize)
        XCTAssertEqual(WindowLayoutManager.parseCommand("center window"), .center)

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(WindowLayoutManager.targetFrame(for: .leftHalf, in: screen), CGRect(x: 0, y: 0, width: 720, height: 900))
        XCTAssertEqual(WindowLayoutManager.targetFrame(for: .rightHalf, in: screen), CGRect(x: 720, y: 0, width: 720, height: 900))

        XCTAssertEqual(SimulatorControlSuite.parseCommand("list simulators"), .listBooted)
        XCTAssertEqual(SimulatorControlSuite.parseCommand("open simulator"), .openSimulatorApp)
        XCTAssertEqual(SimulatorControlSuite.parseCommand("simulator screenshot"), .screenshot)
        XCTAssertTrue(NeuralMetricsInspector.isMetricsQuery("neural metrics"))
        XCTAssertTrue(NeuralMetricsInspector.isMetricsQuery("diagnostics"))
    }
}

final class MeetingFocusAwarenessTests: XCTestCase {
    func testMeetingAppSignatures() {
        XCTAssertTrue(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "us.zoom.xos", appName: "zoom.us"))
        XCTAssertTrue(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.microsoft.teams2", appName: "Microsoft Teams"))
        XCTAssertTrue(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.apple.FaceTime", appName: "FaceTime"))
        XCTAssertTrue(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.google.Chrome", appName: "Google Meet - Sync"))
        XCTAssertTrue(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack"))
        XCTAssertFalse(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
        XCTAssertFalse(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        XCTAssertFalse(MeetingFocusAwareness.isMeetingApp(bundleIdentifier: "com.apple.finder", appName: "Finder"))
    }
}

final class LaserPointerParserTests: XCTestCase {
    func testLaserCommands() {
        XCTAssertEqual(LaserPointerParser.parse("point"), .pointToCenter)
        XCTAssertEqual(LaserPointerParser.parse("laser pointer"), .pointToCenter)
        XCTAssertEqual(LaserPointerParser.parse("show pointer"), .pointToCenter)
        XCTAssertEqual(LaserPointerParser.parse("where are you looking"), .pointToCenter)
        XCTAssertEqual(LaserPointerParser.parse("highlight window"), .highlightActiveWindow)
        XCTAssertEqual(LaserPointerParser.parse("outline window"), .highlightActiveWindow)
        XCTAssertEqual(LaserPointerParser.parse("what is this"), .none)
    }
}

final class ClipboardIntelligenceTests: XCTestCase {
    func testClipboardCommands() {
        XCTAssertEqual(ClipboardIntelligence.parseCommand("read clipboard"), .read)
        XCTAssertEqual(ClipboardIntelligence.parseCommand("what is on my clipboard"), .read)
        XCTAssertEqual(ClipboardIntelligence.parseCommand("clear clipboard"), .clear)
        XCTAssertEqual(ClipboardIntelligence.parseCommand("empty clipboard"), .clear)
        XCTAssertEqual(ClipboardIntelligence.parseCommand("copy to clipboard Swift rocks"), .copy(text: "Swift rocks"))
        XCTAssertEqual(ClipboardIntelligence.parseCommand("summarize clipboard"), .summarize)
        XCTAssertEqual(ClipboardIntelligence.parseCommand("explain clipboard"), .explain)
        XCTAssertEqual(ClipboardIntelligence.parseCommand("translate clipboard to French"), .translate(language: "french"))
        XCTAssertEqual(ClipboardIntelligence.parseCommand("unrelated query"), .none)
    }
}

final class SystemControlSuiteTests: XCTestCase {
    func testSystemControlCommands() {
        XCTAssertEqual(SystemControlSuite.parseCommand("toggle dark mode"), .toggleDarkMode)
        XCTAssertEqual(SystemControlSuite.parseCommand("dark mode on"), .setDarkMode(enabled: true))
        XCTAssertEqual(SystemControlSuite.parseCommand("turn off dark mode"), .setDarkMode(enabled: false))
        XCTAssertEqual(SystemControlSuite.parseCommand("light mode"), .setDarkMode(enabled: false))
        XCTAssertEqual(SystemControlSuite.parseCommand("mute volume"), .muteVolume)
        XCTAssertEqual(SystemControlSuite.parseCommand("silence audio"), .muteVolume)
        XCTAssertEqual(SystemControlSuite.parseCommand("unmute volume"), .unmuteVolume)
        XCTAssertEqual(SystemControlSuite.parseCommand("lock screen"), .lockScreen)
        XCTAssertEqual(SystemControlSuite.parseCommand("lock my mac"), .lockScreen)
        XCTAssertEqual(SystemControlSuite.parseCommand("find file notes.txt"), .findFile(name: "notes.txt"))
        XCTAssertEqual(SystemControlSuite.parseCommand("locate file main.swift"), .findFile(name: "main.swift"))
        XCTAssertEqual(SystemControlSuite.parseCommand("what time is it"), .none)
    }
}

final class CalendarMeetingAssistantTests: XCTestCase {
    func testCalendarCommandParsing() {
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("what meetings do I have today"), .todaySchedule)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("calendar today"), .todaySchedule)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("upcoming meetings"), .todaySchedule)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("my meetings"), .todaySchedule)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("prepare for my next meeting"), .nextMeetingBrief)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("next meeting brief"), .nextMeetingBrief)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("what is my next meeting"), .nextMeetingBrief)
        XCTAssertEqual(CalendarMeetingAssistant.parseCommand("play some music"), .none)
    }

    func testMeetingItemVideoLinkDetection() {
        let zoomItem = CalendarMeetingItem(
            id: "1",
            title: "Sprint Planning",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            location: "https://zoom.us/j/123456789"
        )
        XCTAssertEqual(zoomItem.meetingLink, "https://zoom.us/j/123456789")

        let meetItem = CalendarMeetingItem(
            id: "2",
            title: "Design Sync",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            notes: "Please join via https://meet.google.com/abc-defg-hij on time"
        )
        XCTAssertEqual(meetItem.meetingLink, "https://meet.google.com/abc-defg-hij")

        let inPersonItem = CalendarMeetingItem(
            id: "3",
            title: "Lunch with Team",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            location: "Cafeteria Building 4"
        )
        XCTAssertNil(inPersonItem.meetingLink)
    }
}


