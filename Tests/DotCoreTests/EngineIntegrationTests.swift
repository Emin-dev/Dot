#if !SWIFT_PACKAGE
import XCTest
import Foundation

private final class SplashFixtureProtocol: URLProtocol {
    static var ready = true
    static var server = "Splash"
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let payload = """
        {"schema_version":6,"ready":\(Self.ready),"instance":{"id":"0123456789abcdef01234567","pid":1234,"model":"owner/model","host":"127.0.0.1","port":8000}}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Server": Self.server])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EngineIntegrationTests: XCTestCase {
    @MainActor private func makeEngine(endpoint: String = "http://127.0.0.1:8000", model: String = "owner/model") -> EngineManager {
        SplashFixtureProtocol.ready = true; SplashFixtureProtocol.server = "Splash"; SplashFixtureProtocol.requests = []
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
    @MainActor func testRemoteConfigurationMakesNoRequest() async {
        let engine = makeEngine(endpoint: "http://example.com:8000"); defer { engine.shutdown() }
        do { _ = try await engine.verifyConnection(); XCTFail("Remote endpoint accepted") }
        catch { XCTAssertEqual(error as? EngineError, .configuration) }
        XCTAssertTrue(SplashFixtureProtocol.requests.isEmpty)
    }
}
#endif
