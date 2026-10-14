#if !SWIFT_PACKAGE
import XCTest
import Foundation

private final class SplashFixtureProtocol: URLProtocol {
    static var ready = true
    static var server = "Splash"
    static var requests: [URLRequest] = []
    static var declaredLength: Int?
    static var oversizedBody = false
    static var chatBody = ""
    static var chatRequestBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if request.url?.path == "/v1/chat/completions" {
            Self.chatRequestBody = request.httpBody
            if Self.chatRequestBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
                Self.chatRequestBody = body
            }
            let body = Data(Self.chatBody.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Server": Self.server, "Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self); return
        }
        let payload = """
        {"schema_version":6,"ready":\(Self.ready),"instance":{"id":"0123456789abcdef01234567","pid":1234,"model":"owner/model","host":"127.0.0.1","port":8000}}
        """
        let body = Self.oversizedBody ? Data((String(payload.dropLast()) + ",\"padding\":\"" + String(repeating: "x", count: 1_000_001) + "\"}").utf8) : Data(payload.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Server": Self.server, "Content-Length": Self.declaredLength.map(String.init) ?? (Self.oversizedBody ? "" : String(body.count))])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EngineIntegrationTests: XCTestCase {
    @MainActor private func makeEngine(endpoint: String = "http://127.0.0.1:8000", model: String = "owner/model",
                                      clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) -> EngineManager {
        SplashFixtureProtocol.ready = true; SplashFixtureProtocol.server = "Splash"; SplashFixtureProtocol.requests = []; SplashFixtureProtocol.declaredLength = nil; SplashFixtureProtocol.oversizedBody = false
        SplashFixtureProtocol.chatBody = ""; SplashFixtureProtocol.chatRequestBody = nil
        return EngineManager(endpoint: endpoint, model: model, protocolClasses: [SplashFixtureProtocol.self], clock: clock)
    }
    @MainActor func testRealTransportValidatesStatusBeforeUse() async throws {
        let engine = makeEngine(); defer { engine.shutdown() }
        let (url, model) = try await engine.verifyConnection()
        XCTAssertEqual(url.port, 8000); XCTAssertEqual(model, "owner/model")
        XCTAssertEqual(SplashFixtureProtocol.requests.first?.url?.path, "/status")
    }
    @MainActor func testWrongRuntimeNeverAccepted() async {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.server = "LM Studio"
        do { _ = try await engine.verifyConnection(); XCTFail("Generic proxy accepted") }
        catch { XCTAssertEqual(error as? EngineError, .identity) }
    }
    @MainActor func testUnreadyServerNeverAccepted() async {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.ready = false
        do { _ = try await engine.verifyConnection(); XCTFail("Unready engine accepted") }
        catch { XCTAssertEqual(error as? EngineError, .identity) }
    }
    @MainActor func testWrongExactModelNeverAccepted() async {
        let engine = makeEngine(model: "different/model"); defer { engine.shutdown() }
        do { _ = try await engine.verifyConnection(); XCTFail("Wrong model accepted") }
        catch { XCTAssertEqual(error as? EngineError, .identity) }
    }
    @MainActor func testOversizedDeclaredStatusRejected() async {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.declaredLength = 1_000_001
        do { _ = try await engine.verifyConnection(); XCTFail("oversized declared status accepted") } catch { XCTAssertEqual(error as? EngineError, .response) }
    }
    @MainActor func testOversizedStatusBodyRejected() async {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.oversizedBody = true
        do { _ = try await engine.verifyConnection(); XCTFail("oversized status body accepted") } catch { XCTAssertEqual(error as? EngineError, .response) }
    }
    @MainActor func testRemoteConfigurationMakesNoRequest() async {
        let engine = makeEngine(endpoint: "http://example.com:8000"); defer { engine.shutdown() }
        do { _ = try await engine.verifyConnection(); XCTFail("Remote endpoint accepted") }
        catch { XCTAssertEqual(error as? EngineError, .configuration) }
        XCTAssertTrue(SplashFixtureProtocol.requests.isEmpty)
    }
    private func frame(_ delta: [String: Any] = [:], finish: String? = nil) throws -> String {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self) + "\n\n"
    }
    private func questionCall(_ arguments: String, name: String = "ask_user") throws -> String {
        try frame(["tool_calls": [["index": 0, "id": "call_turn_0", "type": "function", "function": ["name": name, "arguments": arguments]]]])
    }
    private func screenFixture(acquiredAt: Double) throws -> CapturedScreenImage {
        let turn = UUID(); var gate = ScreenContextGate()
        gate.begin(turn: turn, enabled: true, permissionGranted: true, modelHasVision: true)
        try gate.capturedJPEG(Data([0xff, 0xd8, 0xff, 0xd9]), width: 1, height: 1,
                              turn: turn, acquiredAt: acquiredAt, now: acquiredAt)
        return try gate.consume(turn: turn, now: acquiredAt)
    }
    @MainActor func testFreshAcquiredImageAppearsOnlyInCurrentRequest() async throws {
        let engine = makeEngine(clock: { 101 }); defer { engine.shutdown() }
        SplashFixtureProtocol.chatBody = try frame(["content": "Fixture answer."]) + frame(finish: "stop") + "data: [DONE]\n\n"
        let image = try screenFixture(acquiredAt: 100)
        let history = [ChatMessage(role: "user", content: "Describe this fixture.")]
        _ = try await engine.chat(history: history, onDelta: { _ in }, screenImage: { _ in image })
        let first = try XCTUnwrap(SplashFixtureProtocol.chatRequestBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(blocks.first { $0["type"] as? String == "image_url" })
        let imageURL = try XCTUnwrap((imageBlock["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(imageURL.hasPrefix("data:image/jpeg;base64,"))
        _ = try await engine.chat(history: history, onDelta: { _ in })
        let second = try XCTUnwrap(SplashFixtureProtocol.chatRequestBody)
        let nextObject = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        let nextMessages = try XCTUnwrap(nextObject["messages"] as? [[String: Any]])
        XCTAssertEqual(nextMessages.last?["content"] as? String, "Describe this fixture.")
    }
    @MainActor func testExpiredImagePreventsChatSubmissionAfterEncoding() async throws {
        let engine = makeEngine(clock: { 106 }); defer { engine.shutdown() }
        let image = try screenFixture(acquiredAt: 100)
        do {
            _ = try await engine.chat(history: [ChatMessage(role: "user", content: "Fixture")],
                                      onDelta: { _ in }, screenImage: { _ in image })
            XCTFail("An expired acquisition reached transport")
        } catch { XCTAssertEqual(error as? ScreenContextGate.Failure, .stale) }
        XCTAssertFalse(SplashFixtureProtocol.requests.contains { $0.url?.path == "/v1/chat/completions" })
    }
    @MainActor func testImageExpiringDuringRequestAssemblyNeverReachesTransport() async throws {
        var sample = 0
        let clockValues = [100.0, 104.9, 105.01]
        let engine = makeEngine(clock: { defer { sample += 1 }; return clockValues[min(sample, 2)] })
        defer { engine.shutdown() }
        let image = try screenFixture(acquiredAt: 100)
        do {
            _ = try await engine.chat(history: [ChatMessage(role: "user", content: "Fixture")],
                                      onDelta: { _ in }, screenImage: { _ in image })
            XCTFail("Assembly consumed the freshness budget")
        } catch { XCTAssertEqual(error as? ScreenContextGate.Failure, .stale) }
        XCTAssertEqual(sample, 3)
        XCTAssertFalse(SplashFixtureProtocol.requests.contains { $0.url?.path == "/v1/chat/completions" })
    }
    @MainActor func testProductionChatRequestAndFragmentedFinalQuestionContract() async throws {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.chatBody = try frame(["content": "I can help. "])
            + questionCall(#"{"question":"Which "#)
            + frame(["tool_calls": [["index": 0, "function": ["arguments": #"colour?"}"#]]]])
            + frame(finish: "tool_calls") + "data: [DONE]\n\n"
        var spoken = ""
        let question = try await engine.chat(history: [ChatMessage(role: "user", content: "Help me choose")], onDelta: { spoken += $0 })
        XCTAssertEqual(question?.text, "Which colour?")
        XCTAssertEqual(spoken, "I can help. ", "Tool arguments are never sent to streaming speech")
        XCTAssertEqual(SplashFixtureProtocol.requests.map { $0.url?.path }, ["/status", "/v1/chat/completions"])
        let body = try XCTUnwrap(SplashFixtureProtocol.chatRequestBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "owner/model")
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(object["stream"] as? Bool, true)
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1); XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "ask_user"); XCTAssertEqual(function["strict"] as? Bool, true)
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(parameters["required"] as? [String], ["question"])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(properties.keys), ["question"])
        XCTAssertEqual(properties["question"]?["maxLength"] as? Int, 400)
    }
    @MainActor func testOrdinaryPunctuationDoesNotProduceQuestionIntent() async throws {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.chatBody = try frame(["content": "The quotation says: Why?"])
            + frame(finish: "stop") + "data: [DONE]\n\n"
        var spoken = ""
        let question = try await engine.chat(history: [], onDelta: { spoken += $0 })
        XCTAssertNil(question); XCTAssertEqual(spoken, "The quotation says: Why?")
    }
    @MainActor func testToolOnlyQuestionIsNotAnEmptyAnswer() async throws {
        let engine = makeEngine(); defer { engine.shutdown() }
        SplashFixtureProtocol.chatBody = try questionCall(#"{"question":"Which colour?"}"#)
            + frame(finish: "tool_calls") + "data: [DONE]\n\n"
        let question = try await engine.chat(history: [], onDelta: { _ in XCTFail("Tool JSON entered speech") })
        XCTAssertEqual(question?.text, "Which colour?")
    }
    @MainActor func testMalformedFailedTruncatedAndNonFinalQuestionStreamsReject() async throws {
        let call = try questionCall(#"{"question":"Which colour?"}"#)
        let streams = try [
            call + frame(finish: "tool_calls"), // missing DONE
            call + "data: [DONE]\n\n", // missing terminal
            call + frame(finish: "length") + "data: [DONE]\n\n",
            call + "data: {\"error\":{\"message\":\"fixture failure\"}}\n\ndata: [DONE]\n\n",
            call + frame(["content": "Actually, more comes after."]) + frame(finish: "tool_calls") + "data: [DONE]\n\n",
            questionCall("{}", name: "execute") + frame(finish: "tool_calls") + "data: [DONE]\n\n",
            questionCall(#"{"question":"Yes?",}"#) + frame(finish: "tool_calls") + "data: [DONE]\n\n",
            frame(["content": "Incomplete answer"]) + frame(finish: "length") + "data: [DONE]\n\n",
            frame(["content": "No terminal"]) + "data: [DONE]\n\n"
        ]
        for stream in streams {
            let engine = makeEngine(); defer { engine.shutdown() }
            SplashFixtureProtocol.chatBody = stream
            do { try await engine.chat(history: [], onDelta: { _ in }); XCTFail("Invalid stream accepted") }
            catch { XCTAssertEqual(error as? EngineError, .response) }
        }
    }

}

final class StreamDeliveryTests: XCTestCase {
    @MainActor func testServerPauseStillFlushesCompleteSentence() async throws {
        var chunks: [String] = []
        let delivery = StreamDelivery { chunks.append($0) }; defer { delivery.cancel() }
        delivery.feed("Hello"); delivery.feed(" there. ")
        XCTAssertEqual(chunks, ["Hello"])
        for _ in 0..<100 where chunks.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(chunks, ["Hello", " there. "])
    }
    @MainActor func testCancellationSuppressesDeferredTail() async throws {
        var chunks: [String] = []
        let delivery = StreamDelivery { chunks.append($0) }
        delivery.feed("first"); delivery.feed(" stale"); delivery.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        delivery.feed(" later"); delivery.finish()
        XCTAssertEqual(chunks, ["first"])
    }
    @MainActor func testFinishFlushesExactlyOnce() async throws {
        var chunks: [String] = []
        let delivery = StreamDelivery { chunks.append($0) }
        delivery.feed("first"); delivery.feed(" tail"); delivery.finish(); delivery.finish()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(chunks, ["first", " tail"])
    }
}
final class RuntimePinTests: XCTestCase {
    private let expected = "03d66dd08835c1ca3f128cceacd1f31ac94163096b20f445ae84285bc0832d72"
    func testChangedCertificateAndWrongHostFailClosed() {
        XCTAssertFalse(RuntimeCertificatePin.matches(Data("other".utf8), expected: expected, host: "127.0.0.1"))
        XCTAssertFalse(RuntimeCertificatePin.matches(Data("certificate".utf8), expected: expected, host: "example.com"))
        XCTAssertFalse(RuntimeCertificatePin.matches(Data(), expected: expected, host: "127.0.0.1"))
    }
    func testExactPerSessionPinIsRequired() {
        XCTAssertTrue(RuntimeCertificatePin.matches(Data("certificate".utf8), expected: expected, host: "127.0.0.1"))
        XCTAssertFalse(RuntimeCertificatePin.matches(Data("certificate".utf8), expected: String(repeating: "0", count: 64), host: "127.0.0.1"))
    }
}

private actor ObservedChallenges {
    struct Check: Sendable { let serverTrust: Bool; let accepted: Bool }
    private(set) var values: [Check] = []
    func record(serverTrust: Bool, accepted: Bool) { values.append(Check(serverTrust: serverTrust, accepted: accepted)) }
}
private final class ObservedPinDelegate: NSObject, URLSessionTaskDelegate {
    let production: NoRedirects
    let observations: ObservedChallenges
    init(pin: String, observations: ObservedChallenges) {
        production = NoRedirects(certificateSHA256: pin); self.observations = observations
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        production.urlSession(session, task: task, didReceive: challenge) { [observations] disposition, credential in
            let isTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            Task { await observations.record(serverTrust: isTrust, accepted: disposition == .useCredential) }
            completionHandler(disposition, credential)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        production.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}

/// Exercises the actual URLSession authentication delegate against the production relay.
/// The fixture is model-free and cannot read user prompts, screenshots or credentials.
final class NativeTLSIntegrationTests: XCTestCase {
    private struct Ready: Decodable { let port: Int; let pin: String }
    @MainActor private func runFixture(correctPin: Bool, inference: Bool = false) async throws {
        let python = try XCTUnwrap(ProcessInfo.processInfo.environment["DOT_TEST_PYTHON"], "Run scripts/verify_macos.sh to select the supported test interpreter")
        guard python.hasPrefix("/"), !python.contains("$(") else { throw CocoaError(.executableNotLoadable) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process(), control = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-B", root.appendingPathComponent("Fixtures/tls_endpoint.py").path, directory.path]
        process.standardInput = control
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        defer {
            try? control.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
        try process.run()
        let readyPath = directory.appendingPathComponent("ready.json")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: readyPath.path) && process.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(contentsOf: readyPath))
        let config = inference ? EngineManager.directConfiguration() : URLSessionConfiguration.ephemeral
        if !inference { config.connectionProxyDictionary = [:] }
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        let observations = ObservedChallenges()
        let pin = correctPin ? ready.pin : String(repeating: "0", count: 64)
        let delegate = ObservedPinDelegate(pin: pin, observations: observations)
        // Inference owns its real session, data task and session/data delegate.
        // No wrapper or fallback session can supply the pin on its behalf.
        let session = inference ? nil : URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session?.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(ready.port)/fixture")!)
        request.setValue("Bearer model-free-test", forHTTPHeaderField: "Authorization")
        var inferenceSnapshots: [InferenceTransfer.Snapshot] = []
        func settle(_ transfer: InferenceTransfer) async {
            transfer.cancel()
            await transfer.waitForCompletion()
            let state = await transfer.snapshot()
            inferenceSnapshots.append(state)
            XCTAssertTrue(state.started)
            XCTAssertTrue(state.completed, "The exact resumed data task must acknowledge completion")
            XCTAssertTrue(state.invalidated, "The owned session must acknowledge invalidation")
            XCTAssertTrue(state.settled)
            XCTAssertFalse(state.retainedTask)
            XCTAssertFalse(state.retainedSession)
            XCTAssertGreaterThan(state.pinChallenges, 0, "TLS failed before the production pinning delegate ran")
            XCTAssertEqual(state.acceptedPins, correctPin ? state.pinChallenges : 0)
        }
        func fetch() async throws -> (Data, URLResponse) {
            if let session { return try await session.data(for: request) }
            let transfer = InferenceTransfer(request: request, configuration: config, certificateSHA256: pin)
            let initial = await transfer.snapshot()
            XCTAssertFalse(initial.started)
            XCTAssertTrue(initial.retainedTask, "The suspended task must be retained before start")
            XCTAssertTrue(initial.retainedSession)
            do {
                let (chunks, response) = try await transfer.start()
                var body = Data()
                for try await chunk in chunks { body.append(chunk) }
                await settle(transfer)
                return (body, response)
            } catch {
                await settle(transfer)
                throw error
            }
        }
        if correctPin {
            // Connection: close requires a fresh pinned TLS connection for each request.
            for _ in 0..<2 {
                do {
                    let (body, response) = try await fetch()
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    XCTAssertEqual(body, Data("OK".utf8))
                } catch {
                    let environment = (try? String(contentsOf: directory.appendingPathComponent("tls-debug.json"), encoding: .utf8)) ?? "missing TLS diagnostics"
                    let failures = (try? String(contentsOf: directory.appendingPathComponent("tls-errors.txt"), encoding: .utf8)) ?? "no server SSL error"
                    XCTFail(environment + "\n" + failures)
                    throw error
                }
            }
        } else {
            do { _ = try await fetch(); XCTFail("wrong certificate accepted") }
            catch { XCTAssertTrue(error is URLError) }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8), "0")
        }
        if inference {
            XCTAssertEqual(inferenceSnapshots.count, correctPin ? 2 : 1)
        } else {
            for _ in 0..<100 {
                if !(await observations.values).isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let checks = await observations.values
            XCTAssertFalse(checks.isEmpty, "TLS failed before the production certificate-pinning delegate ran")
            XCTAssertTrue(checks.allSatisfy { $0.serverTrust && $0.accepted == correctPin })
        }
        try control.fileHandleForWriting.close()
        for _ in 0..<500 where process.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(process.isRunning, "TLS fixture did not stop after parent EOF")
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0) }
    }
    @MainActor func testActualDelegatePinsEveryReconnect() async throws { try await runFixture(correctPin: true) }
    @MainActor func testWrongCertificateReceivesNoAuthorizationBytes() async throws { try await runFixture(correctPin: false) }
    @MainActor func testExplicitInferenceTransferPinsEveryReconnectAndSettles() async throws { try await runFixture(correctPin: true, inference: true) }
    @MainActor func testExplicitInferenceWrongPinReceivesNoAuthorizationBytesAndSettles() async throws { try await runFixture(correctPin: false, inference: true) }
}

/// Intercepts every request, including a wrongly followed destination, so this
/// redirect test cannot contact either a local listener or an external host.
private final class InferenceRedirectFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var destination = URL(string: "http://127.0.0.1:8000/redirect-target")!
    private static var recorded: [URLRequest] = []
    private static var redirects = 0

    static func reset(destination: URL) {
        lock.lock(); defer { lock.unlock() }
        self.destination = destination; recorded = []; redirects = 0
    }
    static func snapshot() -> (requests: [URLRequest], redirects: Int) {
        lock.lock(); defer { lock.unlock() }
        return (recorded, redirects)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let destination = Self.destination
        let redirect = request.url?.path == "/redirect-source"
        if redirect { Self.redirects += 1 }
        Self.lock.unlock()
        if redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            // Preserve the synthetic bearer in the proposed request. Denial must
            // prevent even this deliberately credential-bearing redirect.
            var proposed = request; proposed.url = destination
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "2"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("OK".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class EngineProxyPolicyTests: XCTestCase {
    func testExplicitInferenceTransferDeniesRedirectsWithoutForwardingAuthorizationAndSettles() async throws {
        let source = URL(string: "http://127.0.0.1:8000/redirect-source")!
        let destinations = [URL(string: "http://127.0.0.1:8000/redirect-target")!,
                            URL(string: "http://redirect-target.invalid/redirect-target")!]
        for destination in destinations {
            InferenceRedirectFixtureProtocol.reset(destination: destination)
            let configuration = EngineManager.directConfiguration()
            configuration.protocolClasses = [InferenceRedirectFixtureProtocol.self]
            configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 5
            var request = URLRequest(url: source)
            request.setValue("Bearer model-free-redirect-test", forHTTPHeaderField: "Authorization")
            let transfer = InferenceTransfer(request: request, configuration: configuration, certificateSHA256: nil)
            do {
                let (chunks, response) = try await transfer.start()
                var body = Data()
                for try await chunk in chunks { body.append(chunk) }
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
                XCTAssertEqual(response.url, source)
                XCTAssertTrue(body.isEmpty)
            } catch {
                // The synthetic protocol finishes without delivering didReceive
                // when its redirect is denied. The adapter rejects that absent
                // response; Foundation may alternatively report .unknown.
                XCTAssertTrue((error as? EngineError) == .response || (error as? URLError)?.code == .unknown,
                              "Unexpected redirect error: \(error)")
            }
            transfer.cancel()
            await transfer.waitForCompletion()
            let state = await transfer.snapshot()
            XCTAssertTrue(state.started)
            XCTAssertTrue(state.completed)
            XCTAssertTrue(state.invalidated)
            XCTAssertTrue(state.settled)
            XCTAssertFalse(state.retainedTask)
            XCTAssertFalse(state.retainedSession)
            let observed = InferenceRedirectFixtureProtocol.snapshot()
            XCTAssertEqual(observed.redirects, 1, "The fixture must actually propose a redirect")
            XCTAssertEqual(observed.requests.map(\.url), [source])
            XCTAssertEqual(observed.requests.first?.value(forHTTPHeaderField: "Authorization"),
                           "Bearer model-free-redirect-test")
            XCTAssertFalse(observed.requests.contains { $0.url == destination },
                           "No redirected request or Authorization bytes may reach the destination")
        }
    }

    func testReadinessAndChatConfigurationExplicitlyDisablesEveryProxyMechanism() throws {
        let configuration = EngineManager.directConfiguration()
        let policy = try XCTUnwrap(configuration.connectionProxyDictionary)
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            XCTAssertEqual((policy[key] as? NSNumber)?.intValue, 0, key)
        }
        XCTAssertEqual(policy["ExceptionsList"] as? [String], ["127.0.0.1"])
    }
}
#endif
