import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class SourceReferenceTests: XCTestCase {
    private let commit = "6aa5b89a8fa6ede0dca2c65a03a80221b566b0bc"

    override func setUp() {
        super.setUp()
        SourceFixtureProtocol.reset()
    }

    private func store() throws -> SourceReferenceStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceFixtureProtocol.self]
        // The store must remove ambient headers, credentials, cookies and HTTP cache.
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-must-be-removed", "Cookie": "fixture-must-be-removed"]
        return SourceReferenceStore(provenance: try SourceProvenance(commit: commit), configuration: configuration,
                                    now: { Date(timeIntervalSince1970: 123_456) })
    }

    func testExactCommitValidationAndProvenanceFields() throws {
        let data = Data("{\"commit\":\"\(commit.uppercased())\",\"signing\":\"ad-hoc\"}".utf8)
        XCTAssertEqual(try SourceProvenance(data: data).commit, commit)
        for bad in ["main", "HEAD", String(commit.prefix(7)), String(repeating: "x", count: 40), commit + "\n", ""] {
            XCTAssertThrowsError(try SourceProvenance(commit: bad)) {
                XCTAssertEqual($0 as? SourceReferenceError, .invalidProvenance)
            }
        }
        for bad in [Data("{}".utf8), Data("{\"commit\":3}".utf8), Data(repeating: 32, count: 16_385)] {
            XCTAssertThrowsError(try SourceProvenance(data: bad))
        }
    }

    func testDirtyDevelopmentBuildCannotClaimAnImmutableSourceRevision() throws {
        let dirty = Data("{\"commit\":\"\(commit)\",\"source_dirty\":true}".utf8)
        XCTAssertThrowsError(try SourceProvenance(data: dirty)) {
            XCTAssertEqual($0 as? SourceReferenceError, .unpublishedSource)
        }
        let clean = Data("{\"commit\":\"\(commit)\",\"source_dirty\":false}".utf8)
        XCTAssertEqual(try SourceProvenance(data: clean).commit, commit)
        XCTAssertThrowsError(try SourceProvenance(data: Data("{\"commit\":\"\(commit)\",\"source_dirty\":\"false\"}".utf8)))
    }

    func testBundledProvenanceLoadsBoundedExactRevisionWithoutFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>app.dot.source.fixture</string></dict></plist>".utf8)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let record = resources.appendingPathComponent("build-provenance.json")
        try Data("{\"commit\":\"\(commit)\"}".utf8).write(to: record)
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(try SourceProvenance.load(bundle: bundle).commit, commit)
        try Data(repeating: 32, count: 20_000).write(to: record)
        XCTAssertThrowsError(try SourceProvenance.load(bundle: bundle)) {
            XCTAssertEqual($0 as? SourceReferenceError, .invalidProvenance)
        }
    }

    func testMissingBundledProvenanceDoesNotGuessARevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>app.dot.source.missing</string></dict></plist>".utf8)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try SourceProvenance.load(bundle: XCTUnwrap(Bundle(url: root)))) {
            XCTAssertEqual($0 as? SourceReferenceError, .missingProvenance)
        }
    }

    func testURLsArePinnedToPublicRepositoryAndRejectTraversal() throws {
        let provenance = try SourceProvenance(commit: commit)
        XCTAssertEqual(try provenance.sourceURL(path: "src/App.swift").absoluteString,
                       "https://raw.githubusercontent.com/Emin-dev/Dot/\(commit)/src/App.swift")
        XCTAssertEqual(try provenance.citationURL(path: "docs/BUILD_CHECKLIST.md").absoluteString,
                       "https://github.com/Emin-dev/Dot/blob/\(commit)/docs/BUILD_CHECKLIST.md")
        XCTAssertNoThrow(try provenance.sourceURL(path: ".github/workflows/ci.yml"))
        for path in ["", "/src/App.swift", "../secret", "src/../App.swift", "src/./App.swift", "src//App.swift", "src/",
                     "src\\App.swift", "%2e%2e/file", "src/App.swift?token=x", "src/App.swift#x", "https://example.com/file",
                     "//example.com/file", ".git/config", "src/\nfile", "å.swift", String(repeating: "a", count: 513)] {
            XCTAssertThrowsError(try provenance.sourceURL(path: path), path)
            XCTAssertThrowsError(try provenance.citationURL(path: path), path)
        }
    }

    func testReadReturnsImmutableCitationHashAndDateAndUsesNoAmbientHeaders() async throws {
        SourceFixtureProtocol.set(.init(body: Data("hello".utf8)), path: "README.md")
        let reader = try store()
        let receipt = try await reader.read(path: "README.md")
        XCTAssertEqual(receipt.text, "hello")
        XCTAssertEqual(receipt.commit, commit)
        XCTAssertEqual(receipt.path, "README.md")
        XCTAssertEqual(receipt.contentSHA256, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(receipt.fetchedAt, Date(timeIntervalSince1970: 123_456))
        XCTAssertTrue(receipt.citation.contains("/blob/\(commit)/README.md"))
        let request = try XCTUnwrap(SourceFixtureProtocol.requests.last)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testImmutableMemoryCacheAvoidsNetworkAndCanBeCleared() async throws {
        SourceFixtureProtocol.set(.init(body: Data("first".utf8)), path: "README.md")
        let reader = try store()
        let first = try await reader.read(path: "README.md")
        SourceFixtureProtocol.set(.init(body: Data("second".utf8)), path: "README.md")
        let cached = try await reader.read(path: "README.md")
        XCTAssertEqual(cached, first)
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 1)
        await reader.clearCache()
        let fresh = try await reader.read(path: "README.md")
        XCTAssertEqual(fresh.text, "second")
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 2)
    }

    func testCacheEvictsByEntryCount() async throws {
        let reader = try store()
        for index in 0...SourceReferenceStore.maximumCacheEntries {
            let path = "file\(index).swift"
            SourceFixtureProtocol.set(.init(body: Data("x".utf8)), path: path)
            _ = try await reader.read(path: path)
        }
        _ = try await reader.read(path: "file0.swift")
        XCTAssertEqual(SourceFixtureProtocol.requests.count, SourceReferenceStore.maximumCacheEntries + 2)
    }

    func testCacheEvictsByByteBudget() async throws {
        let reader = try store()
        for index in 0..<5 {
            let path = "large\(index).swift"
            SourceFixtureProtocol.set(.init(body: Data(repeating: 65, count: SourceReferenceStore.maximumFileBytes)), path: path)
            _ = try await reader.read(path: path)
        }
        _ = try await reader.read(path: "large0.swift")
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 6)
    }

    func testHTTPFailuresDoNotCacheAndNeverFallbackToMain() async throws {
        SourceFixtureProtocol.set(.init(status: 404), path: "missing.swift")
        let reader = try store()
        for _ in 0..<2 {
            do { _ = try await reader.read(path: "missing.swift"); XCTFail("Expected 404") }
            catch { XCTAssertEqual(error as? SourceReferenceError, .httpStatus(404)) }
        }
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 2)
        XCTAssertTrue(SourceFixtureProtocol.requests.allSatisfy { $0.url?.path.contains(commit) == true })
    }

    func testDeclaredAndStreamedOversizeAreBothRejected() async throws {
        let reader = try store()
        SourceFixtureProtocol.set(.init(headers: ["Content-Length": "262145"]), path: "declared.swift")
        SourceFixtureProtocol.set(.init(body: Data(repeating: 65, count: SourceReferenceStore.maximumFileBytes + 1)), path: "streamed.swift")
        for path in ["declared.swift", "streamed.swift"] {
            do { _ = try await reader.read(path: path); XCTFail("Expected size limit") }
            catch { XCTAssertEqual(error as? SourceReferenceError, .tooLarge) }
        }
    }

    func testBinaryAndMalformedUTF8AreRejected() async throws {
        let reader = try store()
        for (path, data) in [("binary.swift", Data([65, 0, 66])), ("invalid.swift", Data([0xff, 0xfe]))] {
            SourceFixtureProtocol.set(.init(body: data), path: path)
            do { _ = try await reader.read(path: path); XCTFail("Expected text rejection") }
            catch { XCTAssertEqual(error as? SourceReferenceError, .invalidText) }
        }
    }

    func testInvalidPathDoesNotReachNetwork() async throws {
        let reader = try store()
        do { _ = try await reader.read(path: "../outside"); XCTFail("Expected invalid path") }
        catch { XCTAssertEqual(error as? SourceReferenceError, .invalidPath) }
        XCTAssertTrue(SourceFixtureProtocol.requests.isEmpty)
    }

    func testDifferentResponseURLIsRejected() async throws {
        SourceFixtureProtocol.set(.init(responseURL: URL(string: "https://example.com/file")!), path: "README.md")
        let reader = try store()
        do { _ = try await reader.read(path: "README.md"); XCTFail("Expected URL mismatch") }
        catch { XCTAssertEqual(error as? SourceReferenceError, .unexpectedResponse) }
    }

    func testRedirectIsNotFollowed() async throws {
        SourceFixtureProtocol.set(.init(status: 302, headers: ["Location": "https://example.com/private"],
                                       redirect: URL(string: "https://example.com/private")!), path: "README.md")
        let reader = try store()
        do { _ = try await reader.read(path: "README.md"); XCTFail("Expected redirect rejection") }
        catch {
            // Foundation's synthetic URLProtocol redirect can fail with URLError.unknown
            // after the delegate declines it; neither outcome may start another request.
            XCTAssertTrue(error as? SourceReferenceError == .httpStatus(302) || (error as? URLError)?.code == .unknown, "\(error)")
        }
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 1)
    }

    func testRedirectDelegateRefusesEvenAnotherPathInTheSameRepository() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try SourceProvenance(commit: commit).sourceURL(path: "README.md")
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        var called = false
        SourceReferenceSessionDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                    newRequest: URLRequest(url: url)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }

    func testConcurrentSourceReadsHaveABoundedAdmissionLimit() async throws {
        let started = expectation(description: "Two admitted reads started")
        started.expectedFulfillmentCount = 2
        for path in ["first.swift", "second.swift"] {
            SourceFixtureProtocol.set(.init(body: Data("x".utf8), delay: 0.2, onStart: { started.fulfill() }), path: path)
        }
        let reader = try store()
        let first = Task { try await reader.read(path: "first.swift") }
        let second = Task { try await reader.read(path: "second.swift") }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await reader.read(path: "third.swift"); XCTFail("Expected admission limit") }
        catch { XCTAssertEqual(error as? SourceReferenceError, .busy) }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 2)
    }

    func testCancellationDuringNetworkDoesNotPopulateCache() async throws {
        let started = expectation(description: "Read started")
        SourceFixtureProtocol.set(.init(body: Data("old".utf8), delay: 0.2, onStart: { started.fulfill() }), path: "README.md")
        let reader = try store()
        let task = Task { try await reader.read(path: "README.md") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancelled read") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        SourceFixtureProtocol.set(.init(body: Data("new".utf8)), path: "README.md")
        let retry = try await reader.read(path: "README.md")
        XCTAssertEqual(retry.text, "new")
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 2)
    }

    @MainActor
    func testCancellationPreventsNetworkOrCacheReturn() async throws {
        SourceFixtureProtocol.set(.init(body: Data("cached".utf8)), path: "README.md")
        let reader = try store()
        _ = try await reader.read(path: "README.md")
        let task = Task { try await reader.read(path: "README.md") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(SourceFixtureProtocol.requests.count, 1)
    }
}

private final class SourceFixtureProtocol: URLProtocol {
    struct Fixture {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var responseURL: URL?
        var redirect: URL?
        var delay: TimeInterval = 0
        var onStart: (() -> Void)?
    }

    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var recorded: [URLRequest] = []
    private let deliveryLock = NSLock()
    private var stopped = false
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeAll(); recorded.removeAll()
    }

    static func set(_ fixture: Fixture, path: String) {
        lock.lock(); defer { lock.unlock() }
        fixtures[path] = fixture
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let path = request.url?.path.split(separator: "/").dropFirst(3).joined(separator: "/") ?? ""
        let fixture = Self.fixtures[path] ?? Fixture(status: 404)
        Self.lock.unlock()
        fixture.onStart?()
        if fixture.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay) { [weak self] in
                self?.deliver(fixture)
            }
        } else { deliver(fixture) }
    }

    private func deliver(_ fixture: Fixture) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped else { return }
        let response = HTTPURLResponse(url: fixture.responseURL ?? request.url!, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        if let redirect = fixture.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
        } else {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fixture.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        stopped = true
    }
}
