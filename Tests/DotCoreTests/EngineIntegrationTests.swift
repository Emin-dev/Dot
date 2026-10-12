#if !SWIFT_PACKAGE
import XCTest
import Foundation

private final class SplashFixtureProtocol: URLProtocol {
    static var ready = true
    static var server = "Splash"
    static var requests: [URLRequest] = []
    static var declaredLength: Int?
    static var oversizedBody = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
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
    @MainActor private func makeEngine(endpoint: String = "http://127.0.0.1:8000", model: String = "owner/model") -> EngineManager {
        SplashFixtureProtocol.ready = true; SplashFixtureProtocol.server = "Splash"; SplashFixtureProtocol.requests = []; SplashFixtureProtocol.declaredLength = nil; SplashFixtureProtocol.oversizedBody = false
        return EngineManager(endpoint: endpoint, model: model, protocolClasses: [SplashFixtureProtocol.self])
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

/// Exercises the actual URLSession authentication delegate against the production relay.
/// The fixture is model-free and cannot read user prompts, screenshots or credentials.
final class NativeTLSIntegrationTests: XCTestCase {
    private struct Ready: Decodable { let port: Int; let pin: String }
    @MainActor private func runFixture(correctPin: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process(), control = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
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
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: NoRedirects(certificateSHA256: correctPin ? ready.pin : String(repeating: "0", count: 64)), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(ready.port)/fixture")!)
        request.setValue("Bearer model-free-test", forHTTPHeaderField: "Authorization")
        if correctPin {
            // Connection: close requires a fresh pinned TLS connection for each request.
            for _ in 0..<2 {
                let (body, response) = try await session.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(body, Data("OK".utf8))
            }
        } else {
            do { _ = try await session.data(for: request); XCTFail("wrong certificate accepted") }
            catch { XCTAssertTrue(error is URLError) }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("received"), encoding: .utf8), "0")
        }
        try control.fileHandleForWriting.close()
        for _ in 0..<500 where process.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(process.isRunning, "TLS fixture did not stop after parent EOF")
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0) }
    }
    @MainActor func testActualDelegatePinsEveryReconnect() async throws { try await runFixture(correctPin: true) }
    @MainActor func testWrongCertificateReceivesNoAuthorizationBytes() async throws { try await runFixture(correctPin: false) }
}

#endif
