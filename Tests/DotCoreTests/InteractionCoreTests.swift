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
