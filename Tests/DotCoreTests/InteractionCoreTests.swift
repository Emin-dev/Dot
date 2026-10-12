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
    func testNegativeMonitorBoundsClampWholeWindow() {
        let bounds = RoamingCore.originBounds(window: CGSize(width: 320, height: 420), visible: visible)!
        let point = RoamingCore.clamp(CGPoint(x: 9000, y: -9000), to: bounds)
        XCTAssertEqual(point.x, -336); XCTAssertEqual(point.y, 46)
    }
    func testTinyDisplayCannotStartTrip() {
        XCTAssertNil(RoamingCore.originBounds(window: CGSize(width: 320, height: 420), visible: CGRect(x: 0, y: 0, width: 200, height: 300)))
    }
    func testSegmentDistanceRejectsCrossingCursor() {
        XCTAssertEqual(RoamingCore.distanceToSegment(CGPoint(x: 50, y: 0), .zero, CGPoint(x: 100, y: 0)), 0)
        XCTAssertEqual(RoamingCore.distanceToSegment(CGPoint(x: 50, y: 150), .zero, CGPoint(x: 100, y: 0)), 150)
    }
    func testSeededWanderStaysVisibleAndVisitsVariedPositions() {
        var planner = RoamingCore(seed: 42, now: 0)
        var frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        var visited: Set<String> = []
        for tick in 0..<24000 {
            frame.origin = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: Double(tick) / 60)
            XCTAssertTrue(visible.contains(frame))
            visited.insert("\(Int(frame.minX / 100)):\(Int(frame.minY / 100))")
        }
        XCTAssertGreaterThan(visited.count, 8)
    }
    func testPauseNeverMovesAndReleaseWaits() {
        var planner = RoamingCore(seed: 1, now: 0)
        let frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        for tick in 0..<100 {
            XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: true, now: Double(tick)), frame.origin)
            XCTAssertFalse(planner.isTravelling)
        }
        XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 100), frame.origin)
        XCTAssertFalse(planner.isTravelling)
    }
    func testApproachingPointerStopsWithoutFleeing() {
        var planner = RoamingCore(seed: 2, now: 0)
        let frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        let near = CGPoint(x: frame.midX, y: frame.minY + 85)
        for tick in 0..<200 { XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: near, paused: false, now: Double(tick)), frame.origin) }
    }
    func testLongWakeIntervalDoesNotTeleport() {
        var planner = RoamingCore(seed: 42, now: 0)
        var frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        for tick in 0..<10000 {
            frame.origin = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: Double(tick) / 60)
            if planner.isTravelling {
                let old = frame.origin
                let next = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 100000)
                XCTAssertLessThan(hypot(next.x - old.x, next.y - old.y), 20); return
            }
        }
        XCTFail("seed never travelled")
    }
    func testCancellationInvalidatesTrajectory() {
        var planner = RoamingCore(seed: 42, now: 0)
        let frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        _ = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 9)
        planner.cancel(now: 10)
        XCTAssertFalse(planner.isTravelling)
        XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: 10.1), frame.origin)
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

extension RoamingTests {
    func testPauseInterruptsAnActiveTripAtCurrentPosition() {
        var planner = RoamingCore(seed: 42, now: 0)
        var frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        for tick in 0..<10000 {
            let now = Double(tick) / 60
            frame.origin = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: now)
            if planner.isTravelling {
                let origin = frame.origin
                XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: true, now: now + 0.1), origin)
                XCTAssertFalse(planner.isTravelling)
                XCTAssertEqual(planner.step(frame: frame, visible: visible, cursor: cursor, paused: true, now: now + 30), origin)
                return
            }
        }
        XCTFail("seed never travelled")
    }
    func testDisplayRemovalCancelsAndClampsToRemainingScreen() {
        var planner = RoamingCore(seed: 42, now: 0)
        var frame = CGRect(x: -800, y: 100, width: 320, height: 420)
        for tick in 0..<10000 {
            let now = Double(tick) / 60
            frame.origin = planner.step(frame: frame, visible: visible, cursor: cursor, paused: false, now: now)
            if planner.isTravelling {
                let replacement = CGRect(x: 0, y: 0, width: 1200, height: 900)
                planner.cancel(now: now)
                frame.origin = planner.step(frame: frame, visible: replacement, cursor: cursor, paused: false, now: now + 0.1)
                XCTAssertTrue(replacement.contains(frame)); XCTAssertFalse(planner.isTravelling); return
            }
        }
        XCTFail("seed never travelled")
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
