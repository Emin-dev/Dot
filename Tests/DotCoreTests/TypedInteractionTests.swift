#if !SWIFT_PACKAGE
import AppKit
import XCTest

private final class TypedFixtureTransport: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [Int: TypedFixtureTransport] = [:]
    private static var nextPort = 21_000
    private let lock = NSLock()
    private var paths: [String] = []
    let port: Int
    let question: Bool
    let heldPrefix: String?
    private var active: TypedFixtureProtocol?
    init(question: Bool, heldPrefix: String? = nil) {
        self.question = question; self.heldPrefix = heldPrefix
        Self.registryLock.lock(); defer { Self.registryLock.unlock() }
        Self.nextPort += 1; port = Self.nextPort; Self.registry[port] = self
    }
    static func fixture(_ port: Int) -> TypedFixtureTransport? {
        registryLock.lock(); defer { registryLock.unlock() }; return registry[port]
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
    func body(_ path: String, handler: TypedFixtureProtocol) -> (String, Bool) {
        lock.lock(); defer { lock.unlock() }; paths.append(path)
        if path == "/v1/chat/completions" {
            if let heldPrefix { active = handler; return (heldPrefix, true) }
            if question {
                return (#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_typed","type":"function","function":{"name":"ask_user","arguments":"{\"question\":\"Shall I continue?\"}"}}]}}]}"# + "\n\n"
                    + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n", false)
            }
            return ("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"A local reply.\"}}]}\n\n"
                + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", false)
        }
        return (#"{"schema_version":6,"ready":true,"instance":{"id":"0123456789abcdef01234567","pid":1234,"model":"fixture/model","host":"127.0.0.1","port":\#(port)}}"#, false)
    }
    func finish(_ tail: String) {
        lock.lock(); let current = active; active = nil; lock.unlock()
        current?.finish(tail)
    }
    func remove() { Self.registryLock.lock(); Self.registry.removeValue(forKey: port); Self.registryLock.unlock() }
}
private final class TypedFixtureProtocol: URLProtocol {
    private let callbacks = NSRecursiveLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        callbacks.lock(); defer { callbacks.unlock() }
        guard !stopped, let url = request.url, let fixture = TypedFixtureTransport.fixture(url.port ?? 0) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Server": "Splash", "Content-Type": url.path == "/status" ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let (body, hold) = fixture.body(url.path, handler: self)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if !hold { client?.urlProtocolDidFinishLoading(self) }
    }
    func finish(_ tail: String) {
        callbacks.lock(); defer { callbacks.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didLoad: Data(tail.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { callbacks.lock(); stopped = true; callbacks.unlock() }
}

@MainActor
private final class TypedFixture {
    let transport: TypedFixtureTransport
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-typed-" + UUID().uuidString)
    let suite = "app.dot.tests.typed." + UUID().uuidString
    let defaults: UserDefaults
    let history: ConversationHistoryModel
    var model: ChatModel!
    var ready = true
    var voiceFailure = false
    var captureAttempts = 0
    var captureIDs: [UUID] = []
    var started: [UUID] = []
    var enqueued: [String] = []
    var completed: [UUID] = []
    var speaking = false
    init(question: Bool = false, heldPrefix: String? = nil) throws {
        transport = TypedFixtureTransport(question: question, heldPrefix: heldPrefix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "screenContextEnabled")
        history = ConversationHistoryModel(directory: directory.appendingPathComponent("History"), copyText: { _ in
            XCTFail("Typed replay must not use the system clipboard")
        })
        let runtime = ChatRuntime(isReady: { [weak self] in self?.ready == true }, startPreparation: {},
            microphoneAuthorized: { false }, currentRoute: { nil }, screenAuthorized: { false },
            startVoice: { [weak self] id in
                guard let self else { return }
                if self.voiceFailure { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Voice is unavailable. Retry the message."]) }
                self.started.append(id)
            }, enqueueVoice: { [weak self] text, _ in self?.speaking = true; self?.enqueued.append(text) },
            completeVoice: { [weak self] in self?.completed.append($0) },
            stopVoice: { [weak self] in self?.speaking = false }, ttsSpeaking: { [weak self] in self?.speaking == true },
            startCapture: { [weak self] id, _, _ in self?.captureAttempts += 1; self?.captureIDs.append(id) }, stopCapture: {},
            recording: { false }, transcribing: { false })
        model = ChatModel(engine: EngineManager(endpoint: "http://127.0.0.1:\(transport.port)", model: "fixture/model", protocolClasses: [TypedFixtureProtocol.self]),
            textHistory: history, defaults: defaults, followup: VoiceFollowup(automaticScheduling: false),
            proactive: ProactiveBehavior(defaults: defaults, automaticScheduling: false, observeWorkspace: false),
            runtime: runtime, videoPlayback: { false })
    }
    func close() async {
        model?.cancelTurn(); model?.stopProactivity(); await history.flush()
        transport.remove(); model = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class TypedInteractionTests: XCTestCase {
    private func frame(_ delta: [String: Any] = [:], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self) + "\n\n"
    }
    @MainActor private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition())
        if !condition() { throw NSError(domain: "TypedReplayTimeout", code: 1) }
    }
    @MainActor private func key(_ code: UInt16, command: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: code == 53 ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r", isARepeat: false, keyCode: code))
    }

    @MainActor func testEditorAndCoordinatorRejectTheSameOversizedAndControlInputWithoutSideEffects() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        let input = TypedInteractionState()
        for text in ["", " \n\t", String(repeating: "a", count: 6_001), String(repeating: "👨‍👩‍👧‍👦", count: 1_000), "hello\u{0}world", "hello\u{7f}world"] {
            input.message = text
            XCTAssertNotNil(input.inputProblem)
            XCTAssertFalse(input.submit(model: f.model)); XCTAssertNotNil(input.submissionFeedback)
            XCTAssertFalse(f.model.submitTyped(text))
        }
        XCTAssertTrue(f.started.isEmpty); XCTAssertEqual(f.captureAttempts, 0); XCTAssertEqual(f.transport.requestCount, 0)
        await f.history.flush(); XCTAssertTrue(f.history.records.isEmpty)
        XCTAssertNil(TypedMessageValidation.problem(String(repeating: "a", count: 6_000)))
        XCTAssertNil(TypedMessageValidation.problem("Line one\nLine two\twith tab"))
    }

    @MainActor func testNotReadyPreservesDraftAndShowsReasonUntilExplicitRetry() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }; f.ready = false
        let input = TypedInteractionState(); input.message = "Keep my message"
        XCTAssertFalse(input.submit(model: f.model)); XCTAssertEqual(input.message, "Keep my message")
        XCTAssertTrue(try XCTUnwrap(input.submissionFeedback).contains("not ready"))
        XCTAssertEqual(f.transport.requestCount, 0); XCTAssertTrue(f.started.isEmpty)
        f.ready = true
        XCTAssertTrue(input.submit(model: f.model)); XCTAssertNil(input.submissionFeedback)
        try await eventually { f.completed.count == 1 }
        XCTAssertEqual(input.message, "Keep my message"); XCTAssertEqual(f.captureAttempts, 0)
    }

    func testPreparationMessagesExplainCheckingPausedMissingAndReadyStates() {
        XCTAssertTrue(TypedInteractionStatus.unavailable(canSubmit: false, preparation: .checking)!.contains("Checking"))
        XCTAssertTrue(TypedInteractionStatus.unavailable(canSubmit: false, preparation: .paused)!.contains("Options"))
        XCTAssertEqual(TypedInteractionStatus.unavailable(canSubmit: false, preparation: .unavailable("Missing bundled files")), "Missing bundled files")
        XCTAssertNotNil(TypedInteractionStatus.unavailable(canSubmit: false, preparation: .ready))
        XCTAssertNil(TypedInteractionStatus.unavailable(canSubmit: true, preparation: .checking))
    }

    @MainActor func testSynchronousVoiceFailureContinuesTypedTextAndDisablesQuestionAudio() async throws {
        let f = try TypedFixture(question: true); addTeardownBlock { await f.close() }; f.voiceFailure = true
        let input = TypedInteractionState(); input.message = "Please help"
        XCTAssertTrue(input.submit(model: f.model)); XCTAssertNil(input.submissionFeedback)
        XCTAssertEqual(input.message, "Please help"); XCTAssertEqual(f.model.issue, .voice)
        XCTAssertNotNil(f.model.voiceDeliveryNotice)
        let failed = try XCTUnwrap(f.model.displayedAnswerTurn)
        try await eventually { f.model.phase == .idle && f.model.answer == "Shall I continue?" }
        XCTAssertTrue(f.started.isEmpty); XCTAssertTrue(f.enqueued.isEmpty); XCTAssertTrue(f.completed.isEmpty)
        XCTAssertFalse(f.model.followupPending); XCTAssertEqual(f.captureAttempts, 0)
        await f.history.flush()
        let record = try XCTUnwrap(TypedInteractionStatus.delivery(turn: failed, records: f.history.records))
        XCTAssertEqual(record.generation, .complete); XCTAssertEqual(record.playback, .failed)
        XCTAssertEqual(record.text, "Shall I continue?")
        f.voiceFailure = false
        XCTAssertTrue(input.submit(model: f.model)); try await eventually { f.completed.count == 1 }
        XCTAssertNil(input.submissionFeedback); XCTAssertNil(f.model.issue); XCTAssertNil(f.model.voiceDeliveryNotice)
        f.model.tts.onError?(failed, "Old voice error")
        XCTAssertNil(f.model.voiceDeliveryNotice)
    }

    @MainActor func testCommandReturnUsesRealCoordinatorAndEscapeStopsWithVisibleOutcome() async throws {
        _ = NSApplication.shared
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        let controller = TypedInteractionPanel(), panel = controller.prepare(model: f.model)
        XCTAssertFalse(panel.isVisible)
        controller.input.message = "  A keyboard message  "
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(36, command: true)))
        try await eventually { f.completed.count == 1 }
        XCTAssertEqual(f.model.answer, "A local reply."); XCTAssertEqual(f.captureAttempts, 0)
        let turn = try XCTUnwrap(f.model.displayedAnswerTurn)
        panel.keyDown(with: try key(53))
        XCTAssertEqual(f.model.captureOutcome, "Stopped"); XCTAssertEqual(f.model.displayedAnswerTurn, turn)
        await f.history.flush()
        let record = try XCTUnwrap(TypedInteractionStatus.delivery(turn: turn, records: f.history.records))
        XCTAssertEqual(record.playback, .interrupted)
        XCTAssertTrue(f.history.records.contains { $0.role == .user && $0.text == "A keyboard message" })
    }

    @MainActor func testPanelRebindsCallbacksAndDraftWithoutActivatingOrRetainingOldModel() async throws {
        _ = NSApplication.shared
        let first = try TypedFixture(), second = try TypedFixture()
        addTeardownBlock { await first.close(); await second.close() }
        let controller = TypedInteractionPanel()
        let panel = controller.prepare(model: first.model)
        XCTAssertEqual(controller.input.focusRequest, 0, "Preparing a hidden panel must not move native editor focus")
        controller.input.message = "First draft"
        XCTAssertTrue(controller.prepare(model: first.model) === panel)
        XCTAssertEqual(controller.input.message, "First draft")
        XCTAssertTrue(controller.prepare(model: second.model) === panel)
        XCTAssertEqual(controller.input.message, "")
        XCTAssertEqual(controller.input.focusRequest, 0)
        panel.cancelOperation(nil)
        XCTAssertNil(first.model.captureOutcome); XCTAssertEqual(second.model.captureOutcome, "Stopped")
        controller.input.message = "Second draft"
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(76, command: true)))
        try await eventually { second.completed.count == 1 }
        XCTAssertTrue(first.started.isEmpty); XCTAssertEqual(second.captureAttempts, 0); XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testDisplayedDeliveryRequiresFinalPlaybackAndMatchesOnlyDisplayedTurn() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("First response")); try await eventually { f.completed.count == 1 }
        let first = try XCTUnwrap(f.model.displayedAnswerTurn)
        await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: first, records: f.history.records)?.playback, .notStarted)
        f.model.tts.onStarted?(first); await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: first, records: f.history.records)?.playback, .inProgress)
        f.speaking = false; f.model.tts.onDrained?(first); await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: first, records: f.history.records)?.playback, .inProgress)
        f.model.tts.onFinalPlayback?(first); await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: first, records: f.history.records)?.playback, .completed)
        XCTAssertTrue(f.model.submitTyped("Second response")); try await eventually { f.completed.count == 2 }
        let second = try XCTUnwrap(f.model.displayedAnswerTurn); XCTAssertNotEqual(first, second)
        await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: second, records: f.history.records)?.playback, .notStarted)
        f.model.tts.onFinalPlayback?(first); await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: second, records: f.history.records)?.playback, .notStarted)
        XCTAssertNil(TypedInteractionStatus.delivery(turn: nil, records: f.history.records))
        XCTAssertNil(TypedInteractionStatus.delivery(turn: UUID(), records: f.history.records))
        f.model.reset(); XCTAssertNil(f.model.displayedAnswerTurn); XCTAssertEqual(f.model.answer, "")
    }

    @MainActor func testWithoutScreenRetryUsesTypedTextAndNeverFallsBackToMicrophone() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        f.model.screenEnabled = true
        let input = TypedInteractionState()
        XCTAssertFalse(input.submit(model: f.model, withoutScreen: true))
        XCTAssertTrue(f.model.screenEnabled, "Invalid draft must not change the screen preference")
        input.message = "Continue with only this typed text"
        XCTAssertTrue(input.submit(model: f.model, withoutScreen: true))
        try await eventually { f.completed.count == 1 }
        XCTAssertFalse(f.model.screenEnabled); XCTAssertFalse(ScreenPrivacyPreference.enabled(in: f.defaults))
        XCTAssertEqual(f.captureAttempts, 0)
    }

    @MainActor func testRejectedKeyboardSubmissionIsVisibleAndDoesNotClearDraft() async throws {
        _ = NSApplication.shared
        let f = try TypedFixture(); addTeardownBlock { await f.close() }; f.ready = false
        let controller = TypedInteractionPanel(), panel = controller.prepare(model: f.model)
        controller.input.message = "Wait for readiness"
        XCTAssertTrue(panel.performKeyEquivalent(with: try key(36, command: true)))
        XCTAssertNotNil(controller.input.submissionFeedback)
        XCTAssertEqual(controller.input.message, "Wait for readiness"); XCTAssertEqual(f.transport.requestCount, 0)
        XCTAssertGreaterThanOrEqual(panel.minSize.width, 420); XCTAssertGreaterThanOrEqual(panel.minSize.height, 400)
    }

    @MainActor func testControlDownKeepsTheStopTargetStableUntilItsActionRuns() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Keep speaking until Stop runs"))
        try await eventually { f.completed.count == 1 }
        XCTAssertEqual(f.model.phase, .speaking)
        let turn = f.model.displayedAnswerTurn, text = f.model.answer
        f.model.setControlInteraction(true)
        XCTAssertEqual(f.model.phase, .speaking)
        XCTAssertEqual(f.model.displayedAnswerTurn, turn); XCTAssertEqual(f.model.answer, text)
        f.model.stopCurrentTurn()
        f.model.setControlInteraction(false)
        XCTAssertEqual(f.model.phase, .idle); XCTAssertEqual(f.model.captureOutcome, "Stopped")
        XCTAssertEqual(f.captureAttempts, 0)
    }

    @MainActor func testControlDownRevokesQuestionIntentAndReleaseDoesNotRearmIt() async throws {
        let f = try TypedFixture(question: true); addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Ask me a question"))
        try await eventually { f.completed.count == 1 }
        let turn = try XCTUnwrap(f.model.displayedAnswerTurn)
        XCTAssertTrue(f.model.followupPending)
        f.model.setControlInteraction(true)
        XCTAssertFalse(f.model.followupPending); XCTAssertEqual(f.model.phase, .speaking)
        f.model.setControlInteraction(false)
        f.model.tts.onStarted?(turn); f.speaking = false
        f.model.tts.onDrained?(turn); f.model.tts.onFinalPlayback?(turn)
        XCTAssertFalse(f.model.followupPending); XCTAssertEqual(f.captureAttempts, 0)
        await f.history.flush()
        XCTAssertEqual(TypedInteractionStatus.delivery(turn: turn, records: f.history.records)?.playback, .completed)
    }

    @MainActor func testVoiceFailureDuringHeldGenerationKeepsLaterTextAndCannotRearmAudio() async throws {
        let f = try TypedFixture(heldPrefix: frame(["content": "First sentence. "]))
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Give a longer answer"))
        try await eventually { f.model.answer == "First sentence. " && f.enqueued.count == 1 }
        let turn = try XCTUnwrap(f.model.displayedAnswerTurn)
        f.model.tts.onStarted?(turn)
        f.model.tts.onError?(turn, "Audio device failed")
        XCTAssertEqual(f.model.phase, .thinking); XCTAssertNotNil(f.model.voiceDeliveryNotice)
        await f.history.flush()
        let partial = try XCTUnwrap(TypedInteractionStatus.delivery(turn: turn, records: f.history.records))
        XCTAssertEqual(partial.generation, .inProgress); XCTAssertEqual(partial.playback, .failed)
        XCTAssertNil(partial.endedAt)
        f.model.tts.onStarted?(turn); f.model.tts.onDrained?(turn); f.model.tts.onFinalPlayback?(turn)
        XCTAssertEqual(f.model.phase, .thinking)
        let tool = ["tool_calls": [["index": 0, "id": "call_followup", "type": "function",
                     "function": ["name": "ask_user", "arguments": "{\"question\":\"Continue?\"}"]]]]
        f.transport.finish(try frame(["content": "Second sentence."]) + frame(tool)
            + frame(finish: "tool_calls") + "data: [DONE]\n\n")
        try await eventually { f.model.phase == .idle && f.model.answer.contains("Continue?") }
        XCTAssertEqual(f.model.answer, "First sentence. Second sentence. Continue?")
        XCTAssertEqual(f.enqueued, ["First sentence."]); XCTAssertTrue(f.completed.isEmpty)
        XCTAssertFalse(f.model.followupPending); XCTAssertEqual(f.captureAttempts, 0)
        await f.history.flush()
        let final = try XCTUnwrap(TypedInteractionStatus.delivery(turn: turn, records: f.history.records))
        XCTAssertEqual(final.generation, .complete); XCTAssertEqual(final.playback, .failed)
        XCTAssertEqual(final.text, f.model.answer); XCTAssertNotNil(final.endedAt)
    }

    @MainActor func testTypedPlaybackFailurePreservesCompleteTextAndRejectsLateCompletion() async throws {
        let f = try TypedFixture(question: true); addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Ask a question")); try await eventually { f.completed.count == 1 }
        let turn = try XCTUnwrap(f.model.displayedAnswerTurn)
        XCTAssertTrue(f.model.followupPending)
        f.model.tts.onStarted?(turn); f.model.tts.onError?(turn, "Playback failed")
        XCTAssertEqual(f.model.answer, "Shall I continue?"); XCTAssertEqual(f.model.phase, .idle)
        XCTAssertNotNil(f.model.voiceDeliveryNotice); XCTAssertFalse(f.model.followupPending)
        f.model.tts.onFinalPlayback?(turn); f.model.tts.onStarted?(turn); f.model.tts.onDrained?(turn)
        await f.history.flush()
        let record = try XCTUnwrap(TypedInteractionStatus.delivery(turn: turn, records: f.history.records))
        XCTAssertEqual(record.generation, .complete); XCTAssertEqual(record.playback, .failed)
        XCTAssertNil(record.playbackCompletedAt); XCTAssertEqual(f.captureAttempts, 0)
    }

    @MainActor func testStopDuringTextFallbackKeepsVoiceFailureAndStopsFurtherText() async throws {
        let f = try TypedFixture(heldPrefix: frame(["content": "First sentence. "]))
        addTeardownBlock { await f.close() }
        XCTAssertTrue(f.model.submitTyped("Long answer"))
        try await eventually { !f.model.answer.isEmpty }
        let turn = try XCTUnwrap(f.model.displayedAnswerTurn)
        f.model.tts.onError?(turn, "Playback failed"); f.model.stopCurrentTurn()
        f.transport.finish(try frame(["content": "Must not appear."]) + frame(finish: "stop") + "data: [DONE]\n\n")
        await f.history.flush()
        let record = try XCTUnwrap(TypedInteractionStatus.delivery(turn: turn, records: f.history.records))
        XCTAssertEqual(record.generation, .interrupted); XCTAssertEqual(record.playback, .failed)
        XCTAssertEqual(record.text, "First sentence. "); XCTAssertEqual(f.model.answer, "First sentence. ")
        XCTAssertEqual(f.model.captureOutcome, "Stopped"); XCTAssertFalse(f.model.followupPending)
    }

    @MainActor func testSpokenTurnVoiceSetupFailureStillCancelsBeforeReasoning() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }; f.voiceFailure = true
        f.model.clicked(); try await eventually { f.captureIDs.count == 1 }
        f.model.stt.onRecording?(try XCTUnwrap(f.captureIDs.first))
        guard case .blocked = f.model.phase else { return XCTFail("Spoken turn must still fail closed") }
        XCTAssertEqual(f.model.issue, .voice); XCTAssertNil(f.model.voiceDeliveryNotice)
        XCTAssertEqual(f.transport.requestCount, 0); XCTAssertFalse(f.model.followupPending)
        await f.history.flush(); XCTAssertTrue(f.history.records.isEmpty)
    }

    @MainActor func testForegroundHookRunsBeforeAcceptedTypedAndListeningWorkOnly() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        var callbacks = 0
        f.model.onForegroundInteraction = {
            callbacks += 1
            if callbacks == 1 { XCTAssertTrue(f.started.isEmpty); XCTAssertEqual(f.transport.requestCount, 0) }
            if callbacks == 2 { XCTAssertEqual(f.captureAttempts, 0) }
        }
        XCTAssertFalse(f.model.submitTyped("")); XCTAssertEqual(callbacks, 0)
        f.ready = false; XCTAssertFalse(f.model.submitTyped("Not ready")); f.model.clicked()
        XCTAssertEqual(callbacks, 0)
        f.ready = true; XCTAssertTrue(f.model.submitTyped("Ready")); XCTAssertEqual(callbacks, 1)
        try await eventually { f.completed.count == 1 }
        f.model.clicked(); XCTAssertEqual(callbacks, 2)
        try await eventually { f.captureAttempts == 1 }
    }

    @MainActor func testPasteOfferNeverReplacesAPendingApproval() {
        let destructive = ActionApprovalRequest(title: "Delete File", detail: "delete", target: "/tmp/x",
                                                isDestructive: true, command: "rm -rf /tmp/x")
        XCTAssertEqual(ChatModel.pendingPasteOffer(existing: destructive, suggestion: "try this"), destructive)
        let offer = ChatModel.pendingPasteOffer(existing: nil, suggestion: "try this")
        XCTAssertEqual(offer?.title, "Paste Suggestion")
        XCTAssertFalse(offer?.isDestructive ?? true)
        XCTAssertNil(ChatModel.pendingPasteOffer(existing: nil, suggestion: "  "))
    }

    @MainActor func testMemoryStorageStripsRememberCueAnywhere() {
        XCTAssertEqual(ChatModel.factToRemember(from: "can you remember that I like tea"), "I like tea")
        XCTAssertEqual(ChatModel.factToRemember(from: "Please remember: my name is Bob"), "my name is Bob")
        XCTAssertEqual(ChatModel.factToRemember(from: "I prefer oat milk"), "I prefer oat milk")
        XCTAssertNil(ChatModel.factToRemember(from: "what is the weather"))
        XCTAssertNil(ChatModel.factToRemember(from: String(repeating: "a", count: 241) + " I like tea"))
    }

    @MainActor func testPageReadRequestIsExactAndDoesNotStealOrdinaryTurns() {
        XCTAssertTrue(ChatModel.isPageReadRequest("summarize this page"))
        XCTAssertTrue(ChatModel.isPageReadRequest(" read this document "))
        XCTAssertFalse(ChatModel.isPageReadRequest("read this page later and tell me"))
        XCTAssertFalse(ChatModel.isPageReadRequest("what is on the screen"))
    }

    @MainActor func testSpotlightFallbackStripsSpokenFileFiller() {
        XCTAssertEqual(ChatModel.spotlightNameQuery(from: "my notes file"), "notes")
        XCTAssertEqual(ChatModel.spotlightNameQuery(from: "report.txt"), "report.txt")
        XCTAssertEqual(ChatModel.spotlightNameQuery(from: "/Users/me/Documents/budget.csv"), "budget.csv")
    }

    @MainActor func testSystemWakeClearsTheSleepBlockAndSaysItIsBack() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        f.model.cancelForEnvironment(reason: .systemSleep)
        guard case .blocked = f.model.phase else { return XCTFail("Sleep must block the turn") }
        f.model.handleSystemWake()
        XCTAssertNil(f.model.issue)
        XCTAssertTrue(f.enqueued.contains("I'm back."))
        guard case .speaking = f.model.phase else { return XCTFail("The greeting must start playback") }
    }

    @MainActor func testFinalSpokenQuestionArmsTheFollowupWithoutAToolCall() {
        XCTAssertTrue(ChatModel.shouldArmFollowup(explicitQuestion: false,
            answer: "Would you like me to open it?", voiceFailed: false, videoSilent: false))
        XCTAssertTrue(ChatModel.shouldArmFollowup(explicitQuestion: true,
            answer: "Done.", voiceFailed: false, videoSilent: false))
        XCTAssertFalse(ChatModel.shouldArmFollowup(explicitQuestion: false,
            answer: "It is 3pm.", voiceFailed: false, videoSilent: false))
        XCTAssertFalse(ChatModel.shouldArmFollowup(explicitQuestion: false,
            answer: "What?", voiceFailed: false, videoSilent: false))
        XCTAssertFalse(ChatModel.shouldArmFollowup(explicitQuestion: false,
            answer: "A quoted question: why?", voiceFailed: false, videoSilent: false))
        XCTAssertTrue(ChatModel.shouldArmFollowup(explicitQuestion: false,
            answer: "Here is the plan. Do you want me to proceed?", voiceFailed: false, videoSilent: false))
        XCTAssertFalse(ChatModel.shouldArmFollowup(explicitQuestion: true,
            answer: "Done.", voiceFailed: true, videoSilent: false))
        XCTAssertFalse(ChatModel.shouldArmFollowup(explicitQuestion: true,
            answer: "Done.", voiceFailed: false, videoSilent: true))
    }

    @MainActor func testFiveMinuteCapAnswersAndSaysTheLimitWasReached() async throws {
        let f = try TypedFixture(); addTeardownBlock { await f.close() }
        f.model.clicked()
        try await eventually { f.captureIDs.count == 1 }
        let id = try XCTUnwrap(f.captureIDs.first)
        f.model.stt.onRecording?(id)
        let now = ProcessInfo.processInfo.systemUptime
        let evidence = VoiceCaptureTimingEvidence(captureStartedAt: now - 10, firstSpeechAt: now - 9,
            speechEndedAt: now - 5, silenceSatisfiedAt: now, selectedSilenceSeconds: 3,
            invitationSeconds: nil, outcome: .maximumDuration)
        f.model.stt.onSpeechEnded?(id, evidence)
        f.model.stt.onFinal?(id, "What is two plus two?")
        try await eventually { f.completed.count == 1 }
        XCTAssertTrue(f.model.answer.contains("five-minute limit"))
        XCTAssertTrue(f.enqueued.contains { $0.contains("five-minute limit") })
    }
}
#endif
