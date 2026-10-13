#if !SWIFT_PACKAGE
import Foundation
import XCTest
import AVFoundation

/// A port-keyed URLProtocol registry keeps concurrent test fixtures isolated. All
/// requests terminate here: no listener, socket, installed model or app is started.
private final class CoordinatorTransport: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [Int: CoordinatorTransport] = [:]
    private static var nextPort = 18_000
    let port: Int
    private let lock = NSLock()
    private var stream: String
    private var hold: Bool
    private var active: CoordinatorURLProtocol?
    private var paths: [String] = []
    private var heldStopped = false

    init(stream: String, hold: Bool = false) {
        Self.registryLock.lock()
        Self.nextPort += 1; port = Self.nextPort
        self.stream = stream; self.hold = hold
        Self.registry[port] = self
        Self.registryLock.unlock()
    }
    static func fixture(port: Int) -> CoordinatorTransport? {
        registryLock.lock(); defer { registryLock.unlock() }; return registry[port]
    }
    var requestPaths: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    var heldRequestStopped: Bool { lock.lock(); defer { lock.unlock() }; return heldStopped }
    func stopped(_ handler: CoordinatorURLProtocol) {
        lock.lock(); defer { lock.unlock() }
        if active === handler { heldStopped = true }
    }
    func response(for request: URLRequest, protocol handler: CoordinatorURLProtocol) -> (String, Bool) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path; paths.append(path)
        if path == "/v1/chat/completions" {
            if hold { active = handler; heldStopped = false }
            return (stream, hold)
        }
        return (#"{"schema_version":6,"ready":true,"instance":{"id":"0123456789abcdef01234567","pid":1234,"model":"fixture/model","host":"127.0.0.1","port":\#(port)}}"#, false)
    }
    func replace(stream: String, hold: Bool = false) {
        lock.lock(); self.stream = stream; self.hold = hold; lock.unlock()
    }
    func finish(with tail: String) {
        lock.lock(); let current = active; active = nil; lock.unlock()
        current?.complete(tail)
    }
    func remove() {
        finish(with: "")
        Self.registryLock.lock(); Self.registry.removeValue(forKey: port); Self.registryLock.unlock()
    }
}

private final class CoordinatorURLProtocol: URLProtocol {
    private let callbacks = NSRecursiveLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        callbacks.lock(); defer { callbacks.unlock() }
        guard !stopped, let url = request.url, let fixture = CoordinatorTransport.fixture(port: url.port ?? 0) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let (body, hold) = fixture.response(for: request, protocol: self)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Server": "Splash", "Content-Type": url.path == "/status" ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if !hold { client?.urlProtocolDidFinishLoading(self) }
    }
    func complete(_ tail: String) {
        callbacks.lock(); defer { callbacks.unlock() }
        guard !stopped else { return }
        if !tail.isEmpty { client?.urlProtocol(self, didLoad: Data(tail.utf8)) }
        client?.urlProtocolDidFinishLoading(self); stopped = true
    }
    override func stopLoading() {
        callbacks.lock(); stopped = true
        CoordinatorTransport.fixture(port: request.url?.port ?? 0)?.stopped(self)
        callbacks.unlock()
    }
}

private enum CoordinatorStream {
    static func frame(_ delta: [String: Any] = [:], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self) + "\n\n"
    }
    static func question(_ text: String = "Which colour would you like?") throws -> String {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["question": text]), as: UTF8.self)
        return try frame(["tool_calls": [["index": 0, "id": "call_fixture_0", "type": "function",
            "function": ["name": "ask_user", "arguments": arguments]]]])
    }
    static func completeQuestion() throws -> String {
        try frame(["content": "I can help. "]) + question() + frame(finish: "tool_calls") + "data: [DONE]\n\n"
    }
    static func ordinary(_ text: String = "A quoted question: why?") throws -> String {
        try frame(["content": text]) + frame(finish: "stop") + "data: [DONE]\n\n"
    }
}

@MainActor
private final class CoordinatorFixture {
    enum VoiceEvent: Equatable { case start(UUID), enqueue(UUID, String), complete(UUID), stop }
    struct CaptureAttempt {
        let id: UUID
        let invitation: Bool
        let silence: Double
        let invitationSeconds: Double
    }
    final class Clock { var now = 100.0 }
    let clock = Clock()
    let transport: CoordinatorTransport
    let directory: URL
    let suite = "app.dot.tests.coordinator." + UUID().uuidString
    let defaults: UserDefaults
    let history: ConversationHistoryModel
    let followup: VoiceFollowup
    private(set) var model: ChatModel!
    var ready = true
    var microphoneAuthorized = true
    var route: VoiceAudioRoute? = .init(input: 1, output: 2, inputRate: 48_000, outputRate: 48_000)
    var speaking = false
    var recording = false
    var voiceEvents: [VoiceEvent] = []
    var captures: [CaptureAttempt] = []
    var captureFailure: VoiceCaptureEndReason?
    var intermediateDrainOnEnqueue = false
    var onComplete: ((UUID) -> Void)?
    var preparationRequests = 0

    init(stream: String, hold: Bool = false) throws {
        transport = CoordinatorTransport(stream: stream, hold: hold)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-coordinator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "screenContextEnabled")
        history = ConversationHistoryModel(directory: directory.appendingPathComponent("History"), copyText: { _ in
            XCTFail("Coordinator replay must not touch the clipboard")
        })
        let clock = self.clock
        followup = VoiceFollowup(clock: { clock.now }, automaticScheduling: false)
        let runtime = ChatRuntime(
            isReady: { [weak self] in self?.ready ?? false },
            startPreparation: { [weak self] in self?.preparationRequests += 1 },
            microphoneAuthorized: { [weak self] in self?.microphoneAuthorized ?? false },
            currentRoute: { [weak self] in self?.route }, screenAuthorized: { false },
            startVoice: { [weak self] in self?.voiceEvents.append(.start($0)) },
            enqueueVoice: { [weak self] text, id in
                guard let self else { return }
                self.voiceEvents.append(.enqueue(id, text)); self.speaking = true
                if self.intermediateDrainOnEnqueue {
                    self.speaking = false; self.model.tts.onDrained?(id)
                }
            },
            completeVoice: { [weak self] id in
                guard let self else { return }
                self.voiceEvents.append(.complete(id)); self.onComplete?(id)
            },
            stopVoice: { [weak self] in self?.speaking = false; self?.voiceEvents.append(.stop) },
            ttsSpeaking: { [weak self] in self?.speaking ?? false },
            startCapture: { [weak self] id, settings, invitation in
                guard let self else { return }
                self.captures.append(.init(id: id, invitation: invitation, silence: settings.silenceSeconds,
                                           invitationSeconds: settings.invitationSeconds))
                if let reason = self.captureFailure { self.model.stt.onCaptureEnded?(id, reason) }
                else { self.recording = true }
            },
            stopCapture: { [weak self] in self?.recording = false },
            recording: { [weak self] in self?.recording ?? false }, transcribing: { false })
        model = ChatModel(engine: EngineManager(endpoint: "http://127.0.0.1:\(transport.port)", model: "fixture/model",
                                               protocolClasses: [CoordinatorURLProtocol.self]),
                          textHistory: history, defaults: defaults, followup: followup,
                          proactive: ProactiveBehavior(defaults: defaults, clock: { clock.now },
                                                       automaticScheduling: false, observeWorkspace: false), runtime: runtime)
    }
    var completedTurns: [UUID] { voiceEvents.compactMap { if case .complete(let id) = $0 { return id }; return nil } }
    func enqueued(for id: UUID) -> [String] {
        voiceEvents.compactMap { if case .enqueue(let turn, let text) = $0, turn == id { return text }; return nil }
    }
    func finishPlayback(_ id: UUID) {
        model.tts.onStarted?(id)
        speaking = false
        model.tts.onDrained?(id)
        model.tts.onFinalPlayback?(id)
    }
    func advanceSettle() { clock.now += QuestionReplyGate.playbackSettleSeconds + 0.001; followup.poll() }
    func close() async {
        model.cancelTurn(); model.stopProactivity()
        await history.flush()
        transport.remove(); model = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Real ChatModel methods, real EngineManager SSE/parser, real follow-up policy and
/// real durable history. Only native side effects and the transport peer are fixtures.
final class VoiceCoordinatorTests: XCTestCase {
    @MainActor private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                                      _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
        if !condition() { throw NSError(domain: "CoordinatorReplayTimeout", code: 1) }
    }
    @MainActor private func assistant(_ fixture: CoordinatorFixture, turn: UUID) async throws -> ConversationHistoryRecord {
        await fixture.history.flush()
        return try XCTUnwrap(fixture.history.records.first { $0.turnID == turn && $0.role == .assistant })
    }

    @MainActor func testRealGeneratedQuestionEnqueuesFinalTextBeforeCompletionThenInvitesOnce() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.voiceTiming.setSilenceSeconds(8))
        XCTAssertTrue(f.model.voiceTiming.setInvitationSeconds(20))
        XCTAssertTrue(f.model.submitTyped("Help choose a colour"))
        try await eventually("Generation must complete") { f.completedTurns.count == 1 }
        let turn = try XCTUnwrap(f.completedTurns.first)
        XCTAssertEqual(f.enqueued(for: turn), ["I can help.", "Which colour would you like?"])
        XCTAssertEqual(f.voiceEvents.last, .complete(turn))
        XCTAssertEqual(f.model.answer.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                       "I can help. Which colour would you like?")
        XCTAssertTrue(f.model.followupPending)
        XCTAssertTrue(f.captures.isEmpty)
        let generated = try await assistant(f, turn: turn)
        XCTAssertEqual(generated.generation, .complete)
        XCTAssertEqual(generated.playback, .notStarted)
        f.speaking = false
        f.model.tts.onDrained?(turn); f.model.tts.onDrained?(turn)
        f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty, "Queue drains cannot stand in for final successful playback")
        f.finishPlayback(turn)
        f.followup.poll()
        XCTAssertTrue(f.captures.isEmpty, "Final playback still requires the existing echo-settle interval")
        f.advanceSettle()
        try await eventually("Question should hand off to capture") { f.captures.count == 1 }
        let capture = try XCTUnwrap(f.captures.first)
        XCTAssertTrue(capture.invitation)
        XCTAssertEqual(capture.silence, 8); XCTAssertEqual(capture.invitationSeconds, 20)
        XCTAssertNotEqual(capture.id, turn)
        XCTAssertTrue(f.model.automaticReply)
        XCTAssertEqual(f.model.phase, .listening)
        f.model.tts.onFinalPlayback?(turn); f.advanceSettle()
        XCTAssertEqual(f.captures.count, 1)
        let delivered = try await assistant(f, turn: turn)
        XCTAssertEqual(delivered.playback, .completed)
        XCTAssertNotNil(delivered.playbackCompletedAt)
    }

    @MainActor func testOrdinaryQuestionPunctuationFinishesWithoutOpeningMicrophone() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.ordinary())
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Read the quotation"))
        try await eventually("Ordinary response should finish") { f.completedTurns.count == 1 }
        let turn = f.completedTurns[0]
        f.finishPlayback(turn); f.advanceSettle()
        XCTAssertFalse(f.model.followupPending)
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertEqual(f.model.phase, .idle)
        let delivered = try await assistant(f, turn: turn)
        XCTAssertEqual(delivered.playback, .completed)
    }

    @MainActor func testGenerationFailureKeepsPartialTextAndCannotInviteFromLateAudio() async throws {
        let stream = try CoordinatorStream.frame(["content": "A partial useful answer. "])
            + CoordinatorStream.question() + CoordinatorStream.frame(finish: "tool_calls") // missing DONE
        let f = try CoordinatorFixture(stream: stream)
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Incomplete stream"))
        try await eventually("Truncated generation should surface recovery") { f.model.issue == .engine }
        let turn = try XCTUnwrap(f.voiceEvents.compactMap { if case .start(let id) = $0 { return id }; return nil }.first)
        XCTAssertTrue(f.completedTurns.isEmpty)
        XCTAssertFalse(f.enqueued(for: turn).contains("Which colour would you like?"))
        f.finishPlayback(turn); f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertEqual(f.model.issue, .engine)
        let record = try await assistant(f, turn: turn)
        XCTAssertEqual(record.generation, .failed)
        XCTAssertEqual(record.failureStage, .generation)
        XCTAssertEqual(record.text, "A partial useful answer. ")
        XCTAssertNotEqual(record.playback, .completed)
    }

    @MainActor func testIntermediatePlaybackAndDrainsDuringGenerationCannotOpenInvitation() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.frame(["content": "An early sentence. "]), hold: true)
        addTeardownBlock { await f.close() }
        f.intermediateDrainOnEnqueue = true
        XCTAssertTrue(f.model.submitTyped("Stream slowly"))
        try await eventually("First sentence should stream") { f.voiceEvents.contains { if case .enqueue = $0 { return true }; return false } }
        let turn = try XCTUnwrap(f.voiceEvents.compactMap { if case .start(let id) = $0 { return id }; return nil }.first)
        XCTAssertEqual(f.model.phase, .thinking)
        f.model.tts.onStarted?(turn); f.model.tts.onFinalPlayback?(turn)
        f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertFalse(f.model.followupPending)
        f.transport.finish(with: try CoordinatorStream.question() + CoordinatorStream.frame(finish: "tool_calls") + "data: [DONE]\n\n")
        try await eventually("Final question generation should complete") { f.completedTurns.count == 1 }
        f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty, "Earlier audio cannot satisfy the final question's playback barrier")
        f.finishPlayback(turn); f.advanceSettle()
        try await eventually("Final audio should now open one invitation") { f.captures.count == 1 }
    }

    @MainActor func testStopAndReplacementRejectPriorGenerationAudioAndCaptureCallbacks() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("First turn"))
        try await eventually("First turn should generate") { f.completedTurns.count == 1 }
        let old = f.completedTurns[0]
        f.model.stopCurrentTurn()
        XCTAssertEqual(f.model.captureOutcome, "Stopped")
        XCTAssertNil(f.model.issue)
        f.finishPlayback(old); f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertEqual(f.model.captureOutcome, "Stopped", "A stale playback callback cannot clear the Stop feedback")
        f.transport.replace(stream: try CoordinatorStream.ordinary("Replacement answer."))
        XCTAssertTrue(f.model.submitTyped("Replacement turn"))
        XCTAssertNil(f.model.captureOutcome, "New foreground work clears the prior completion feedback")
        try await eventually("Replacement should generate") { f.completedTurns.count == 2 }
        let current = f.completedTurns[1]
        f.model.stt.onCaptureEnded?(old, .missingAudio)
        f.model.stt.onCaptureEnded?(old, .noSpeech)
        f.model.stt.onFinal?(old, "Stale transcript must not become a new request")
        f.model.tts.onError?(old, "Stale playback failure")
        f.finishPlayback(old); f.advanceSettle()
        XCTAssertNil(f.model.issue)
        XCTAssertNil(f.model.captureOutcome, "An old no-speech callback cannot label the replacement turn")
        XCTAssertEqual(f.model.answer, "Replacement answer.")
        XCTAssertEqual(f.transport.requestPaths.filter { $0 == "/v1/chat/completions" }.count, 2)
        XCTAssertTrue(f.captures.isEmpty)
        let interrupted = try await assistant(f, turn: old)
        XCTAssertEqual(interrupted.playback, .interrupted)
        f.finishPlayback(current)
        let replacement = try await assistant(f, turn: current)
        XCTAssertEqual(replacement.playback, .completed)
    }

    @MainActor func testVoiceFailurePreservesGeneratedButUndeliveredHistoryAndRevokesInvitation() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Speak the question"))
        try await eventually("Question should generate") { f.completedTurns.count == 1 }
        let turn = f.completedTurns[0]
        f.model.tts.onStarted?(turn)
        f.model.tts.onError?(turn, "Fixture audio failed")
        f.finishPlayback(turn); f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertEqual(f.model.issue, .voice)
        let record = try await assistant(f, turn: turn)
        XCTAssertEqual(record.generation, .complete)
        XCTAssertEqual(record.playback, .failed)
        XCTAssertEqual(record.failureStage, .voice)
        XCTAssertNil(record.playbackCompletedAt)
    }

    @MainActor func testMissingMicNeverBlocksTypedAnswerButRevokesAutomaticInvitation() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        f.microphoneAuthorized = false
        XCTAssertTrue(f.model.submitTyped("Typed input needs no microphone"))
        try await eventually("Typed answer should generate with microphone off") { f.completedTurns.count == 1 }
        let turn = f.completedTurns[0]
        f.finishPlayback(turn); f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertFalse(f.model.followupPending)
        XCTAssertNil(f.model.issue)
        f.microphoneAuthorized = true; f.followup.poll()
        XCTAssertTrue(f.captures.isEmpty, "Restoring permission cannot resurrect a stale invitation")
    }

    @MainActor func testCapturePermissionLossSurfacesRecoveryThenTypedRetryWorksWithoutMic() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        f.captureFailure = .permissionLost
        XCTAssertTrue(f.model.submitTyped("Ask me"))
        try await eventually("Question should generate") { f.completedTurns.count == 1 }
        f.finishPlayback(f.completedTurns[0]); f.advanceSettle()
        try await eventually("Mic failure should be visible") { f.model.issue == .speech }
        XCTAssertEqual(f.model.phase, .blocked(VoiceCaptureEndReason.permissionLost.recoveryMessage!))
        XCTAssertFalse(f.model.automaticReply)
        XCTAssertFalse(f.recording)
        XCTAssertEqual(f.captures.count, 1)
        f.captureFailure = nil; f.microphoneAuthorized = false
        f.transport.replace(stream: try CoordinatorStream.ordinary("Typed recovery works."))
        XCTAssertTrue(f.model.submitTyped("Continue by keyboard"))
        try await eventually("Typed recovery should complete") { f.completedTurns.count == 2 }
        XCTAssertNil(f.model.issue)
        XCTAssertEqual(f.model.answer, "Typed recovery works.")
        XCTAssertEqual(f.captures.count, 1)
    }

    @MainActor func testNoSpeechIsQuietAndRouteChangeDuringSettleDoesNotReopenLater() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("First invitation"))
        try await eventually("Question should generate") { f.completedTurns.count == 1 }
        f.finishPlayback(f.completedTurns[0]); f.advanceSettle()
        try await eventually("Invitation should open") { f.captures.count == 1 }
        f.model.stt.onCaptureEnded?(f.captures[0].id, .noSpeech)
        XCTAssertNil(f.model.issue)
        XCTAssertEqual(f.model.phase, .idle)
        XCTAssertEqual(f.model.captureOutcome, "No reply")
        XCTAssertFalse(f.recording)
        XCTAssertTrue(f.model.submitTyped("Second invitation"))
        XCTAssertNil(f.model.captureOutcome)
        try await eventually("Second question should generate") { f.completedTurns.count == 2 }
        f.finishPlayback(f.completedTurns[1])
        let prior = f.route; f.route = nil; f.advanceSettle()
        XCTAssertFalse(f.model.followupPending)
        f.route = prior; f.followup.poll()
        XCTAssertEqual(f.captures.count, 1)
    }

    @MainActor func testFinalCallbackSynchronousWithGenerationCommitKeepsDeliveryOrdering() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        f.onComplete = { [weak f] id in f?.finishPlayback(id) }
        XCTAssertTrue(f.model.submitTyped("Fast final audio"))
        try await eventually("Completion callback should be delivered") { f.completedTurns.count == 1 }
        let turn = f.completedTurns[0]
        let record = try await assistant(f, turn: turn)
        XCTAssertEqual(record.generation, .complete)
        XCTAssertEqual(record.playback, .completed)
        XCTAssertTrue(f.model.followupPending)
        XCTAssertTrue(f.captures.isEmpty)
        f.advanceSettle()
        try await eventually("Committed question should produce one invitation") { f.captures.count == 1 }
    }

    @MainActor func testRealPCMReplyBeginsNearExpiryAndCannotReasonUntilResetSilenceCompletes() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.voiceTiming.setSilenceSeconds(2))
        XCTAssertTrue(f.model.voiceTiming.setInvitationSeconds(3))
        XCTAssertTrue(f.model.submitTyped("Ask me for the next step"))
        try await eventually("Initial question should generate") { f.completedTurns.count == 1 }
        f.finishPlayback(f.completedTurns[0]); f.advanceSettle()
        try await eventually("Reply capture should begin") { f.captures.count == 1 }
        let attempt = f.captures[0]
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: attempt.silence, invitation: attempt.invitationSeconds)
        f.model.stt.onRecording?(attempt.id)
        func append(start: Double, frames: UInt32 = 800, speechFrom: Int? = nil) {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let samples = buffer.floatChannelData!.pointee
            for index in 0..<Int(frames) { samples[index] = speechFrom.map { index >= $0 ? 0.1 : 0 } ?? 0 }
            pcm.append(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
        }
        for index in 0..<29 { append(start: 100 + Double(index) / 10) }
        XCTAssertEqual(pcm.poll(at: 103.05).decision, .listening, "In-flight boundary audio must be considered")
        append(start: 102.9, frames: 1_600, speechFrom: 720) // speech starts at 102.99, before the invitation ends
        XCTAssertEqual(pcm.poll(at: 103.1).snapshot?.phase, .speaking)
        append(start: 103.1, speechFrom: 0)
        for index in 0..<19 { append(start: 103.2 + Double(index) / 10) }
        XCTAssertEqual(pcm.poll(at: 105.19).decision, .listening)
        XCTAssertEqual(f.transport.requestPaths.filter { $0 == "/v1/chat/completions" }.count, 1)
        append(start: 105.1, frames: 1_600, speechFrom: 720) // resumed speech resets the prior 105.2 deadline
        let reset = pcm.poll(at: 105.3)
        XCTAssertEqual(reset.decision, .listening)
        XCTAssertEqual(reset.snapshot!.deadlineAt!, 107.3, accuracy: 0.00001)
        for index in 0..<19 { append(start: 105.3 + Double(index) / 10) }
        XCTAssertEqual(pcm.poll(at: 107.29).decision, .listening)
        XCTAssertEqual(f.transport.requestPaths.filter { $0 == "/v1/chat/completions" }.count, 1,
                       "Foreground capture cannot begin LLM reasoning on an unfinished reply")
        append(start: 107.2, frames: 1_600)
        let ended = pcm.poll(at: 107.4)
        XCTAssertEqual(ended.decision, .silenceSatisfied)
        let evidence = try XCTUnwrap(ended.evidence)
        XCTAssertEqual(evidence.selectedSilenceSeconds, 2)
        XCTAssertGreaterThan(evidence.silenceSatisfiedAt, 103, "The invitation is not the utterance limit")
        f.recording = false
        f.model.stt.onSpeechEnded?(attempt.id, evidence)
        // The recognizer's text is a fixture; microphone PCM and coordinator
        // deadline/turn ordering above are production code, not acoustic acceptance.
        f.transport.replace(stream: try CoordinatorStream.ordinary("Reply accepted after silence."))
        f.model.stt.onFinal?(attempt.id, "Continue the plan")
        try await eventually("Only the completed utterance should start the next response") { f.completedTurns.count == 2 }
        XCTAssertEqual(f.transport.requestPaths.filter { $0 == "/v1/chat/completions" }.count, 2)
        XCTAssertEqual(f.model.answer, "Reply accepted after silence.")
    }

    @MainActor func testTranscriptWithoutCompletedSilenceEvidenceCannotReachEngine() async throws {
        for futureEvidence in [false, true] {
            let f = try CoordinatorFixture(stream: CoordinatorStream.ordinary())
            addTeardownBlock { await f.close() }
            f.model.clicked()
            try await eventually("Explicit click should start fixture capture") { f.captures.count == 1 }
            let id = f.captures[0].id
            f.model.stt.onRecording?(id)
            if futureEvidence {
                let now = ProcessInfo.processInfo.systemUptime
                f.model.stt.onSpeechEnded?(id, .init(captureStartedAt: now - 1, firstSpeechAt: now - 0.5,
                    speechEndedAt: now, silenceSatisfiedAt: now + 3, selectedSilenceSeconds: 3, invitationSeconds: nil))
            }
            f.model.stt.onFinal?(id, "This transcript must not bypass silence")
            XCTAssertEqual(f.model.issue, .speech)
            XCTAssertEqual(f.model.phase, .blocked("Listening timing could not be verified. Please try again."))
            XCTAssertFalse(f.recording)
            XCTAssertFalse(f.transport.requestPaths.contains("/v1/chat/completions"))
            XCTAssertTrue(f.completedTurns.isEmpty)
            await f.history.flush()
            XCTAssertTrue(f.history.records.isEmpty)
        }
    }

    @MainActor func testStopDuringLiveGenerationCancelsTransportAndKeepsPartialHistoryUndelivered() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.frame(["content": "Keep this partial finding. "]), hold: true)
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Start a slow response"))
        try await eventually("The incomplete stream must reach the real coordinator") { f.model.answer.contains("partial finding") }
        let turn = try XCTUnwrap(f.voiceEvents.compactMap { if case .start(let id) = $0 { return id }; return nil }.first)
        f.model.stopCurrentTurn()
        try await eventually("Stop must cancel the actual URLSession request") { f.transport.heldRequestStopped }
        let eventCount = f.voiceEvents.count
        f.transport.finish(with: try CoordinatorStream.question() + CoordinatorStream.frame(finish: "tool_calls") + "data: [DONE]\n\n")
        f.finishPlayback(turn); f.advanceSettle()
        XCTAssertEqual(f.voiceEvents.count, eventCount)
        XCTAssertTrue(f.completedTurns.isEmpty)
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertEqual(f.model.captureOutcome, "Stopped")
        XCTAssertEqual(f.model.phase, .idle)
        XCTAssertNil(f.model.issue)
        let record = try await assistant(f, turn: turn)
        XCTAssertEqual(record.text, "Keep this partial finding. ")
        XCTAssertEqual(record.generation, .interrupted)
        XCTAssertEqual(record.playback, .interrupted)
        XCTAssertNil(record.playbackCompletedAt)
    }

    @MainActor func testPermissionRevocationDuringTypedGenerationKeepsAnswerAndCancelsFollowup() async throws {
        let f = try CoordinatorFixture(stream: CoordinatorStream.frame(["content": "Typed work continues. "]), hold: true)
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Use my typed request"))
        try await eventually("Typed stream should start") { f.model.answer.contains("Typed work") }
        f.microphoneAuthorized = false
        f.model.cancelForEnvironment(reason: .permissionLost)
        XCTAssertNil(f.model.issue)
        XCTAssertFalse(f.transport.heldRequestStopped, "A typed request has no microphone dependency")
        f.transport.finish(with: try CoordinatorStream.question() + CoordinatorStream.frame(finish: "tool_calls") + "data: [DONE]\n\n")
        try await eventually("Typed generation should finish after permission revocation") { f.completedTurns.count == 1 }
        let turn = f.completedTurns[0]
        f.finishPlayback(turn); f.advanceSettle()
        XCTAssertTrue(f.captures.isEmpty)
        XCTAssertFalse(f.model.followupPending)
        XCTAssertNil(f.model.issue)
        XCTAssertNil(f.model.captureOutcome)
        let record = try await assistant(f, turn: turn)
        XCTAssertEqual(record.generation, .complete)
        XCTAssertEqual(record.playback, .completed)
        f.microphoneAuthorized = true; f.followup.poll()
        XCTAssertTrue(f.captures.isEmpty)
    }

    @MainActor func testRouteChangeAndSleepDuringOutputInterruptDeliveryAndRejectLateCompletion() async throws {
        for reason in [VoiceCaptureEndReason.routeChanged, .systemSleep] {
            let f = try CoordinatorFixture(stream: CoordinatorStream.completeQuestion())
            addTeardownBlock { await f.close() }
            XCTAssertTrue(f.model.submitTyped("Speak a question before environment changes"))
            try await eventually("Question should generate") { f.completedTurns.count == 1 }
            let turn = f.completedTurns[0]
            f.model.tts.onStarted?(turn)
            f.model.cancelForEnvironment(reason: reason)
            XCTAssertEqual(f.model.issue, .voice)
            XCTAssertEqual(f.model.phase, .blocked(reason.recoveryMessage!))
            XCTAssertFalse(f.speaking)
            XCTAssertNil(f.model.captureOutcome, "A device problem must not be shown as a quiet No reply/Stop")
            f.finishPlayback(turn); f.advanceSettle()
            XCTAssertTrue(f.captures.isEmpty)
            XCTAssertFalse(f.model.followupPending)
            let record = try await assistant(f, turn: turn)
            XCTAssertEqual(record.generation, .complete)
            XCTAssertEqual(record.playback, .interrupted)
            XCTAssertNil(record.playbackCompletedAt)
        }
    }
}
#endif
