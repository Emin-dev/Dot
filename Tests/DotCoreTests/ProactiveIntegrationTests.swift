import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class ProactiveIntegrationTests: XCTestCase {
    private func frame(_ delta: [String: Any] = [:], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
    }

    func testOnlyRecentRealUserEvidenceCanProduceDistinctNativeContextKey() throws {
        var evidence = ProactiveConversationEvidence()
        let changed = ProactiveContextChange(reason: .foregroundApplicationChanged, applicationIdentifier: "app.editor")
        XCTAssertNil(evidence.key(change: changed, now: 100, ownIdentifier: "app.dot"))
        let user = UUID(); evidence.recordUser(turn: user, now: 100)
        let key = try XCTUnwrap(evidence.key(change: changed, now: 110, ownIdentifier: "app.dot"))
        XCTAssertEqual(evidence.key(change: changed, now: 120, ownIdentifier: "app.dot"), key)
        XCTAssertNil(evidence.key(change: .init(reason: .foregroundApplicationChanged, applicationIdentifier: "app.dot"), now: 110, ownIdentifier: "app.dot"))
        XCTAssertNil(evidence.key(change: changed, now: 99, ownIdentifier: "app.dot"))
        XCTAssertNil(evidence.key(change: changed, now: 100 + ProactiveConversationEvidence.maximumAge + 0.001, ownIdentifier: "app.dot"))
        evidence.recordUser(turn: UUID(), now: 200)
        XCTAssertNotEqual(evidence.key(change: changed, now: 201, ownIdentifier: "app.dot"), key)
        evidence.clear()
        XCTAssertNil(evidence.key(change: changed, now: 202, ownIdentifier: "app.dot"))
    }

    func testValidatedNoOpportunityIsSilentAcrossArbitraryTokenSplits() throws {
        for split in 0...ProactiveReplyBuffer.noOpportunity.count {
            var reply = ProactiveReplyBuffer()
            reply.append(" \n" + String(ProactiveReplyBuffer.noOpportunity.prefix(split)))
            reply.append(String(ProactiveReplyBuffer.noOpportunity.dropFirst(split)) + "\n")
            XCTAssertEqual(try reply.completed(question: nil), .silent)
        }
    }

    func testAmbiguousNoOpportunityOrOversizedOutputNeverBecomesSpeech() {
        for text in ["", "DOT_NO_USEFUL_OPPORTUNITY but try this", "dot_no_useful_opportunity", "\u{0000}unsafe"] {
            var reply = ProactiveReplyBuffer(); reply.append(text)
            XCTAssertThrowsError(try reply.completed(question: nil))
        }
        var sentinelWithQuestion = ProactiveReplyBuffer()
        sentinelWithQuestion.append(ProactiveReplyBuffer.noOpportunity)
        XCTAssertThrowsError(try sentinelWithQuestion.completed(question: "What next?"))
        var overlong = ProactiveReplyBuffer(); overlong.append(String(repeating: "x", count: 2_401))
        overlong.append("Actually short.")
        XCTAssertThrowsError(try overlong.completed(question: nil), "Overflow cannot recover as a misleading truncated suggestion")
    }

    @MainActor func testCompleteQuestionAndFinalAudioAreBothNeededBeforeProactiveInvitation() throws {
        var stream = QuestionIntentStream(), reply = ProactiveReplyBuffer()
        let lead = "The draft still has an empty title."
        try stream.feed(frame(["content": lead])); reply.append(lead)
        try stream.feed(frame(["tool_calls": [["index": 0, "id": "call_dot_0", "type": "function", "function": ["name": "ask_user", "arguments": #"{"question":"Would a short title help?"}"#]]]]))
        XCTAssertThrowsError(try stream.completed(), "Incomplete generation cannot authorize speech or a mic")
        try stream.feed(frame(finish: "tool_calls")); try stream.feed("data: [DONE]")
        let question = try XCTUnwrap(stream.completed())
        XCTAssertEqual(try reply.completed(question: question.text), .speak(content: lead, question: question.text))
        var now = 100.0, invitations = 0
        let followup = VoiceFollowup(clock: { now }, automaticScheduling: false)
        followup.environment = { .init(ready: true, microphoneAuthorized: true, screenAuthorized: true, interacting: false) }
        followup.onInvite = { _, _ in invitations += 1 }
        let turn = UUID(), firstAudio = UUID(), finalAudio = UUID()
        var barrier = FinalPlaybackBarrier(); barrier.begin(turn: turn)
        followup.begin(turn: turn)
        XCTAssertTrue(barrier.enqueue(turn: turn, request: firstAudio))
        XCTAssertTrue(barrier.enqueue(turn: turn, request: finalAudio))
        followup.generationFinished(turn: turn, hasQuestion: true)
        XCTAssertNil(barrier.generationComplete(turn: turn))
        XCTAssertNil(barrier.playbackFinished(turn: turn, request: firstAudio, successfully: true))
        followup.poll(); XCTAssertEqual(invitations, 0)
        let completed = try XCTUnwrap(barrier.playbackFinished(turn: turn, request: finalAudio, successfully: true))
        followup.playbackFinished(turn: completed)
        now += QuestionReplyGate.playbackSettleSeconds + 0.001
        followup.poll(); XCTAssertEqual(invitations, 1)
        followup.poll(); XCTAssertEqual(invitations, 1)
    }

    @MainActor func testForegroundCancellationRevokesBothOpportunityAndQuestionInvitation() throws {
        let domain = "DotProactiveFlow." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var now = 0.0
        let coordinator = ProactiveBehavior(defaults: defaults, clock: { now }, automaticScheduling: false, observeWorkspace: false)
        let followup = VoiceFollowup(clock: { now }, automaticScheduling: false)
        var invitations = 0, opportunities = 0, cancellations = 0
        var currentOpportunity: UUID?
        followup.environment = { .init(ready: true, microphoneAuthorized: true, screenAuthorized: true, interacting: false) }
        followup.onInvite = { _, _ in invitations += 1 }
        coordinator.onOpportunity = { opportunity in
            opportunities += 1; currentOpportunity = opportunity.id
            let turn = UUID(); followup.begin(turn: turn)
            followup.generationFinished(turn: turn, hasQuestion: true)
            followup.playbackFinished(turn: turn)
        }
        coordinator.onCancel = { opportunity in
            guard opportunity == currentOpportunity else { return }
            cancellations += 1; followup.cancel(); currentOpportunity = nil
        }
        coordinator.setFrequency(.high) // This case exercises the 60-second cadence.
        coordinator.start(); defer { coordinator.stop() }
        coordinator.updateContext(.init(ready: true, visible: true))
        coordinator.offerContext(key: "changed-work", reason: .foregroundApplicationChanged)
        now = 60; coordinator.poll()
        XCTAssertEqual(opportunities, 1)
        let active = try XCTUnwrap(coordinator.activeOpportunity)
        coordinator.updateContext(.init(ready: true, visible: true, foregroundBusy: true))
        XCTAssertEqual(cancellations, 1)
        now += 1; followup.poll()
        XCTAssertEqual(invitations, 0)
        XCTAssertNil(coordinator.activeOpportunity)
        coordinator.complete(id: active.id)
        now = 1_000; coordinator.poll()
        XCTAssertEqual(opportunities, 1)
    }
}

#if !SWIFT_PACKAGE
import AppKit

private final class ProactiveEngineFixture: URLProtocol {
    static var responseText = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = """
        {"schema_version":6,"ready":true,"instance":{"id":"0123456789abcdef01234567","pid":1234,"model":"owner/model","host":"127.0.0.1","port":8000}}
        """
        let content = request.url?.path == "/status" ? status : Self.responseText
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Server": "Splash"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProactiveEngineIntegrationTests: XCTestCase {
    private func body(_ content: String, terminal: Bool) throws -> String {
        let delta: [String: Any] = ["choices": [["index": 0, "delta": ["content": content]]]]
        var output = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: delta), as: UTF8.self) + "\n\n"
        if terminal { output += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n" }
        return output
    }
    @MainActor func testProductionEngineSuccessfulNoOpportunityProducesNoSpeechOrQuestion() async throws {
        let engine = EngineManager(endpoint: "http://127.0.0.1:8000", model: "owner/model", protocolClasses: [ProactiveEngineFixture.self])
        defer { engine.shutdown() }
        ProactiveEngineFixture.responseText = try body(ProactiveReplyBuffer.noOpportunity, terminal: true)
        var buffer = ProactiveReplyBuffer()
        let question = try await engine.chat(history: [ChatMessage(role: "user", content: ProactiveReplyBuffer.prompt)], onDelta: { buffer.append($0) })
        XCTAssertNil(question)
        XCTAssertEqual(try buffer.completed(question: question?.text), .silent)
    }
    @MainActor func testProductionEngineTruncationCannotReleaseBufferedSuggestion() async throws {
        let engine = EngineManager(endpoint: "http://127.0.0.1:8000", model: "owner/model", protocolClasses: [ProactiveEngineFixture.self])
        defer { engine.shutdown() }
        ProactiveEngineFixture.responseText = try body("A useful suggestion?", terminal: false)
        var buffer = ProactiveReplyBuffer(), released: ProactiveReplyBuffer.Result?
        do {
            let question = try await engine.chat(history: [ChatMessage(role: "user", content: ProactiveReplyBuffer.prompt)], onDelta: { buffer.append($0) })
            released = try buffer.completed(question: question?.text)
            XCTFail("Incomplete stream accepted")
        } catch { XCTAssertEqual(error as? EngineError, .response) }
        XCTAssertNil(released, "No streamed background content reaches speech before complete generation")
    }
}

final class CompanionStatusIntegrationTests: XCTestCase {
    func testCountdownUsesConservativeCeilingAndRejectsInvalidValues() {
        XCTAssertEqual(CompanionStatusText.seconds(5.999), "6")
        XCTAssertEqual(CompanionStatusText.seconds(0.01), "1")
        XCTAssertEqual(CompanionStatusText.seconds(0), "0")
        XCTAssertEqual(CompanionStatusText.seconds(-10), "0")
        XCTAssertEqual(CompanionStatusText.seconds(.infinity), "—")
        XCTAssertEqual(CompanionStatusText.seconds(.nan), "—")
        XCTAssertEqual(CompanionStatusText.seconds(nil), "—")
    }
    @MainActor func testRecoveryLabelsFitBesideTheVisibleMicIndicator() {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        for issue in CompanionIssue.allCases {
            let label = CompanionStatusText.issue(issue)
            XCTAssertFalse(label.contains("\n"))
            XCTAssertLessThan((label as NSString).size(withAttributes: [.font: font]).width, 79)
        }
        XCTAssertEqual(PetStatusLayout.controlHeight, 0)
        XCTAssertGreaterThanOrEqual(PetLayout.petBottom, PetStatusLayout.controlHeight)
        XCTAssertEqual(PetLayout.panelSize.height, PetLayout.petSize.height + PetStatusLayout.controlHeight + PetLayout.edgePadding * 2)
    }
}
#endif
