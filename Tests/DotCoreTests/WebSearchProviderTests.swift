import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

// MARK: - Bundled Rust runtime (Contents/MacOS/dot-search)

/// A one-request loopback HTTP/1.1 fixture. It records the raw bytes the client put
/// on the wire, including how much of the request arrived in the first read, because
/// the shipped runtime parses each request with a single read.
private final class LoopbackSearchFixture: @unchecked Sendable {
    struct Answer {
        var status = 200
        var contentType = "application/json"
        var payload = Data()
        var declaredLength: Int?
    }
    private let listener: Int32
    private let lock = NSLock()
    private var answer = Answer()
    private var request = Data()
    private var firstRead = Data()
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { close(descriptor); throw CocoaError(.fileNoSuchFile) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func configure(_ changes: (inout Answer) -> Void) { lock.lock(); changes(&answer); lock.unlock() }
    var observedRequest: Data { lock.lock(); defer { lock.unlock() }; return request }
    var observedFirstRead: Data { lock.lock(); defer { lock.unlock() }; return firstRead }

    /// Serves exactly one request on a background queue, then closes the connection.
    /// Waiting for a client is bounded so a case that never connects cannot pin a
    /// dispatch thread for the rest of the suite; the listener itself stays open
    /// because one fixture can legitimately serve two searches in sequence.
    func serveOne() {
        DispatchQueue.global().async { [self] in
            var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while pending.revents == 0 {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return }
                let milliseconds = Int32(clamping: remaining.components.seconds * 1_000
                                         + remaining.components.attoseconds / 1_000_000_000_000_000)
                let ready = poll(&pending, 1, max(1, milliseconds))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { return }
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var first = true
            while bytes.count < 65_536 {
                if let head = FixtureFraming.headerEnd(bytes), let declared = FixtureFraming.declaredLength(bytes),
                   bytes.count - head >= declared { break }
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer[0..<count])
                if first { lock.lock(); firstRead = bytes; lock.unlock(); first = false }
            }
            lock.lock(); request = bytes; let current = answer; lock.unlock()
            let payload = current.payload
            let head = "HTTP/1.1 \(current.status) Status\r\n"
                + "Content-Type: \(current.contentType)\r\n"
                + "Content-Length: \(current.declaredLength ?? payload.count)\r\n"
                + "Connection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(payload)
            _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        }
    }
}

private enum FixtureFraming {
    static func headerEnd(_ bytes: Data) -> Int? {
        let data = [UInt8](bytes)
        guard data.count >= 4 else { return nil }
        for index in 0...(data.count - 4)
        where data[index] == 13 && data[index + 1] == 10 && data[index + 2] == 13 && data[index + 3] == 10 {
            return index + 4
        }
        return nil
    }
    static func declaredLength(_ bytes: Data) -> Int? {
        guard let head = headerEnd(bytes) else { return nil }
        let text = String(decoding: [UInt8](bytes)[0..<(head - 4)], as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            guard line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                continue
            }
            return Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
    static func body(_ request: Data) -> String {
        guard let head = headerEnd(request) else { return "" }
        return String(decoding: [UInt8](request)[head...], as: UTF8.self)
    }
    static func header(_ request: Data, _ name: String) -> String? {
        guard let head = headerEnd(request) else { return nil }
        let text = String(decoding: [UInt8](request)[0..<(head - 4)], as: UTF8.self)
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            guard line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() else {
                continue
            }
            return line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// A stand-in for the bundled Rust runtime: it speaks only the documented control
/// protocol, reports the PID it was given, and exits on stdin EOF exactly as the
/// real runtime does. Real DuckDuckGo/Wikipedia retrieval belongs to the runtime's
/// own tests; these cases bound what this side does with its receipt.
private enum LocalDotSearchProviderFixture {
    static let capability = String(repeating: "a", count: 64)

    /// `body` is inserted after the PID is recorded and one command line is read.
    static func make(port: Int, body: String) throws -> (executable: URL, pidFile: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-search-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("dot-search")
        let pidFile = root.appendingPathComponent("pid")
        let script = """
        #!/bin/sh
        printf '%s' "$$" > "\(pidFile.path)"
        read -r command
        # Built-in parameter expansion only: readiness must not depend on spawning
        # two extra processes, which under the full gate's load delayed the ready
        # line past the honest ten-second startup bound.
        generation=${command##*'"generation":"'}
        generation=${generation%%'"'*}
        \(body)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, pidFile)
    }

    /// The ready line shape the Rust runtime emits, including both PIDs it reports.
    static func readyLine(port: Int) -> String {
        """
        printf '{"protocol":1,"event":"ready","generation":"%s","endpoint":"http://127.0.0.1:\(port)/search",\
        "capability":"\(capability)","helper_pid":%s,"server_pid":%s}\\n' "$generation" "$$" "$(( $$ + 1 ))"
        cat >/dev/null
        """
    }

    static func spawnedPID(_ pidFile: URL, seconds: Double = 5) async -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    static func waitUntilGone(_ pid: Int32) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }
}

final class LocalDotSearchProviderTests: XCTestCase {
    private func response(_ body: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: body) }

    private func item(_ url: String, _ title: String, _ content: String, published: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["url": url, "title": title, "content": content]
        if let published { value["published_date"] = published }
        return value
    }

    /// A runtime fixture wired to a loopback server on the port its ready line claims.
    private func makeRuntime() throws -> (fixture: (executable: URL, pidFile: URL), server: LoopbackSearchFixture) {
        let server = try LoopbackSearchFixture()
        let fixture = try LocalDotSearchProviderFixture.make(port: server.port,
                                                            body: LocalDotSearchProviderFixture.readyLine(port: server.port))
        return (fixture, server)
    }

    func testMissingBundledRuntimeFailsHonestlyWithoutAnotherSearchPath() async {
        let provider = LocalDotSearchProvider(executableURL: URL(fileURLWithPath: "/nonexistent/dot-search"),
                                              cache: SearchResultCache(inMemory: true))
        do { _ = try await provider.search(query: "anything", limit: 3); XCTFail("Missing runtime searched anyway") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .runtimeMissing) }
    }

    func testHandshakeDispatchesCapabilityAndNormalizesBoundedResults() async throws {
        let payload = response(["results": [
            item("https://example.org/one#first", "  First  ", "Discovery snippet", published: "2023-11-14"),
            item("https://example.org/one#second", "Duplicate", "duplicate"),
            item("http://example.org/insecure", "Insecure", "not https"),
            item("https://example.org/untitled", "   ", "no title"),
            item("https://example.org/three", "Third", String(repeating: "é", count: 5_000)),
            item("https://example.org/four", "Fourth", "not requested"),
        ], "unresponsive_engines": []])
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.fixture.executable.deletingLastPathComponent()) }
        runtime.server.configure { $0.payload = payload }
        runtime.server.serveOne()
        let provider = LocalDotSearchProvider(executableURL: runtime.fixture.executable,
                                              cache: SearchResultCache(inMemory: true))
        let response = try await provider.searchResponse(query: "café & rust", limit: 3)
        let request = runtime.server.observedRequest
        let body = FixtureFraming.body(request)
        XCTAssertEqual(FixtureFraming.header(request, "X-Dot-Search-Capability"), LocalDotSearchProviderFixture.capability)
        XCTAssertEqual(FixtureFraming.header(request, "Content-Length"), String(body.utf8.count))
        XCTAssertEqual(body, "q=caf%C3%A9+%26+rust")
        XCTAssertNil(FixtureFraming.header(request, "X-Ambient"))
        // The runtime parses each request with one read: head and body must arrive together.
        XCTAssertEqual(FixtureFraming.body(runtime.server.observedFirstRead), body,
                       "request head and body were written separately")
        XCTAssertEqual(response.results.map(\.url.absoluteString),
                       ["https://example.org/one", "https://example.org/three", "https://example.org/four"])
        XCTAssertEqual(response.results[0].title, "First")
        XCTAssertEqual(response.results[0].snippet, "Discovery snippet")
        XCTAssertEqual(response.results[0].publicationDateHint, ISO8601DateFormatter().date(from: "2023-11-14T00:00:00Z"))
        XCTAssertLessThanOrEqual(response.results[1].snippet.utf8.count, 8_192)
        XCTAssertEqual(response.coverage, .complete)
        XCTAssertTrue(response.unavailableEngineIDs.isEmpty)
    }

    func testEverySearchEndsItsOwnRuntimeProcess() async throws {
        let payload = response(["results": [item("https://example.org/one", "One", "snippet")],
                                "unresponsive_engines": []])
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.fixture.executable.deletingLastPathComponent()) }
        runtime.server.configure { $0.payload = payload }
        runtime.server.serveOne()
        let provider = LocalDotSearchProvider(executableURL: runtime.fixture.executable,
                                              cache: SearchResultCache(inMemory: true))
        _ = try await provider.search(query: "first", limit: 1)
        let observedFirst = await LocalDotSearchProviderFixture.spawnedPID(runtime.fixture.pidFile)
        let first = try XCTUnwrap(observedFirst)
        let firstGone = await LocalDotSearchProviderFixture.waitUntilGone(first)
        XCTAssertTrue(firstGone, "runtime survived its search")
        // A second search launches a fresh runtime rather than reusing a stale one.
        try? FileManager.default.removeItem(at: runtime.fixture.pidFile)
        runtime.server.configure { $0.payload = payload }
        runtime.server.serveOne()
        _ = try await provider.search(query: "second", limit: 1)
        let observedSecond = await LocalDotSearchProviderFixture.spawnedPID(runtime.fixture.pidFile)
        let second = try XCTUnwrap(observedSecond)
        XCTAssertNotEqual(first, second)
        let secondGone = await LocalDotSearchProviderFixture.waitUntilGone(second)
        XCTAssertTrue(secondGone)
    }

    func testCancellationTerminatesTheOwnedRuntime() async throws {
        // `exec` keeps the fixture's stdout pipe owned by the process we signal, so a
        // surviving grandchild cannot delay the cancellation receipt.
        let fixture = try LocalDotSearchProviderFixture.make(port: 1, body: "exec sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
        let provider = LocalDotSearchProvider(executableURL: fixture.executable,
                                           cache: SearchResultCache(inMemory: true))
        let task = Task { try await provider.search(query: "cancelled", limit: 1) }
        let observed = await LocalDotSearchProviderFixture.spawnedPID(fixture.pidFile)
        let pid = try XCTUnwrap(observed)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled search succeeded") }
        catch is CancellationError {}
        catch { XCTFail("Wrong cancellation error: \(error)") }
        let gone = await LocalDotSearchProviderFixture.waitUntilGone(pid)
        XCTAssertTrue(gone, "cancelled runtime survived")
    }

    func testMalformedOrOversizedReadyLinesNeverBecomeAReceipt() async throws {
        let junk = "printf '%s' \"$(head -c 5000 /dev/zero | tr '\\0' 'x')\""
        let uppercase = "printf '{\"protocol\":1,\"event\":\"ready\",\"generation\":\"%s\",\"endpoint\":"
            + "\"http://127.0.0.1:1/search\",\"capability\":"
            + "\"\(String(repeating: "A", count: 64))\",\"helper_pid\":%s,\"server_pid\":%s}\\n' \"$generation\" \"$$\" \"$(( $$ + 1 ))\""
        let cases: [(body: String, expected: SearchRuntimeFailure)] = [
            ("printf '{\"protocol\":1,\"event\":\"ready\"}\\n'", .invalidControl),
            (junk, .startupFailed),
            (uppercase, .invalidControl),
        ]
        for entry in cases {
            let fixture = try LocalDotSearchProviderFixture.make(port: 1, body: entry.body)
            defer { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
            let provider = LocalDotSearchProvider(executableURL: fixture.executable,
                                           cache: SearchResultCache(inMemory: true))
            do { _ = try await provider.search(query: "anything", limit: 1); XCTFail("Invalid ready line accepted: \(entry.body)") }
            catch { XCTAssertEqual(error as? SearchRuntimeFailure, entry.expected, entry.body) }
            let observed = await LocalDotSearchProviderFixture.spawnedPID(fixture.pidFile)
            let pid = try XCTUnwrap(observed)
            let gone = await LocalDotSearchProviderFixture.waitUntilGone(pid)
            XCTAssertTrue(gone)
        }
    }

    /// S17: a runtime that stops before its ready line (no OS random source) fails the
    /// search at once instead of waiting out the startup bound.
    func testRuntimeThatExitsBeforeReadyFailsPromptly() async throws {
        let fixture = try LocalDotSearchProviderFixture.make(
            port: 1, body: "printf 'no secure random source for the search capability\\n' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
        let provider = LocalDotSearchProvider(executableURL: fixture.executable, cache: SearchResultCache(inMemory: true))
        let start = ContinuousClock.now
        do { _ = try await provider.search(query: "anything", limit: 1); XCTFail("A runtime without a capability searched") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .startupFailed) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    /// F4: a ready line that arrives slowly but inside the honest ten-second startup
    /// bound is a normal readiness, never a timeout.
    func testSlowReadyLineWithinTheStartupBoundSucceeds() async throws {
        let payload = response(["results": [item("https://example.org/slow", "Slow", "snippet")],
                                "unresponsive_engines": []])
        let server = try LoopbackSearchFixture()
        server.configure { $0.payload = payload }
        let fixture = try LocalDotSearchProviderFixture.make(port: server.port,
            body: "sleep 2\n" + LocalDotSearchProviderFixture.readyLine(port: server.port))
        defer { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
        server.serveOne()
        let provider = LocalDotSearchProvider(executableURL: fixture.executable,
                                              cache: SearchResultCache(inMemory: true))
        let result = try await provider.searchResponse(query: "slow", limit: 1)
        XCTAssertEqual(result.results.map(\.url.absoluteString), ["https://example.org/slow"])
    }

    /// F4: one past the ten-second startup bound is a distinct, honest failure. The
    /// bound itself stays at ten seconds; this case never weakens it.
    func testReadyLinePastTheStartupBoundThrowsStartupTimeout() async throws {
        let server = try LoopbackSearchFixture()
        let fixture = try LocalDotSearchProviderFixture.make(port: server.port,
            body: "sleep 12\n" + LocalDotSearchProviderFixture.readyLine(port: server.port))
        defer { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
        server.serveOne()
        let provider = LocalDotSearchProvider(executableURL: fixture.executable,
                                              cache: SearchResultCache(inMemory: true))
        do { _ = try await provider.searchResponse(query: "late", limit: 1); XCTFail("Late ready line accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .startupTimeout) }
    }

    func testRuntimeAnswersAreBoundedAndCapabilityRejectionSurfaces() async throws {
        let valid = response(["results": [item("https://example.org/one", "One", "snippet")],
                              "unresponsive_engines": []])
        /// One runtime per answer keeps every case on a fresh process and port.
        func runtime(payload: Data = Data(), status: Int = 200, contentType: String = "application/json",
                     declaredLength: Int? = nil, validPayload: Data) throws -> LocalDotSearchProvider {
            let server = try LoopbackSearchFixture()
            server.configure {
                $0.status = status
                $0.contentType = contentType
                $0.declaredLength = declaredLength
                $0.payload = payload.isEmpty ? validPayload : payload
            }
            let fixture = try LocalDotSearchProviderFixture.make(port: server.port,
                                                                body: LocalDotSearchProviderFixture.readyLine(port: server.port))
            addTeardownBlock { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
            server.serveOne()
            return LocalDotSearchProvider(executableURL: fixture.executable,
                                           cache: SearchResultCache(inMemory: true))
        }
        // A rejected capability is its own failure, never an empty result set.
        let forbidden = try runtime(payload: Data(), status: 403, validPayload: valid)
        do { _ = try await forbidden.search(query: "forbidden", limit: 1); XCTFail("Forbidden answer accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .forbidden) }
        // A declared response larger than the cap is refused before it is read.
        let oversized = try runtime(declaredLength: LocalDotSearchProvider.maximumResponseBytes + 1, validPayload: valid)
        do { _ = try await oversized.search(query: "declared-large", limit: 1); XCTFail("Oversized answer accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .responseTooLarge) }
        // A non-JSON answer from the port never becomes search evidence.
        let html = try runtime(payload: Data("<html>not the runtime</html>".utf8), contentType: "text/html", validPayload: valid)
        do { _ = try await html.search(query: "challenge", limit: 1); XCTFail("HTML answer accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .challenge) }
        let binary = try runtime(payload: Data([0, 1, 2]), contentType: "application/octet-stream", validPayload: valid)
        do { _ = try await binary.search(query: "binary", limit: 1); XCTFail("Binary answer accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .malformedResponse) }
        // Malformed JSON and unusable results fail instead of reporting no findings.
        let broken = try runtime(payload: Data("{".utf8), validPayload: valid)
        do { _ = try await broken.search(query: "malformed", limit: 1); XCTFail("Malformed answer accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .malformedResponse) }
        let unusable = try runtime(payload: response(["results": [item("http://example.org/plain", "Title", "snippet")],
                                                     "unresponsive_engines": []]), validPayload: valid)
        do { _ = try await unusable.search(query: "unusable", limit: 1); XCTFail("Unusable results accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .invalidResults) }
        // Every reviewed engine reported unavailable is a provider failure, not success.
        let down = try runtime(payload: response(["results": [],
                                                  "unresponsive_engines": [["duckduckgo", "timeout"], ["wikipedia", "timeout"],
                                                                          ["google-news", "timeout"], ["arxiv", "timeout"]]]),
                               validPayload: valid)
        do { _ = try await down.search(query: "engines-down", limit: 1); XCTFail("Engine outage accepted") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .unavailable) }
        // One reviewed engine down keeps the partial coverage visible.
        let partial = try runtime(payload: response(["results": [item("https://example.org/wiki", "Wiki", "snippet")],
                                                    "unresponsive_engines": [["duckduckgo", "timeout"]]]),
                                  validPayload: valid)
        let response = try await partial.searchResponse(query: "partial", limit: 1)
        XCTAssertEqual(response.coverage, .partial)
        XCTAssertEqual(response.unavailableEngineIDs, ["duckduckgo"])
    }

    func testQueryLimitsPrecedeAnyRuntimeLaunch() async throws {
        let fixture = try LocalDotSearchProviderFixture.make(port: 1, body: LocalDotSearchProviderFixture.readyLine(port: 1))
        defer { try? FileManager.default.removeItem(at: fixture.executable.deletingLastPathComponent()) }
        let provider = LocalDotSearchProvider(executableURL: fixture.executable,
                                           cache: SearchResultCache(inMemory: true))
        for (query, limit) in [("   ", 1), (String(repeating: "a", count: 2_049), 1), ("ok\u{0}bad", 1), ("fine", 0), ("fine", 9)] {
            do { _ = try await provider.search(query: query, limit: limit); XCTFail("Invalid input accepted") }
            catch { XCTAssertEqual(error as? SearchRuntimeFailure, .invalidQuery) }
        }
        let launched = await LocalDotSearchProviderFixture.spawnedPID(fixture.pidFile, seconds: 1)
        XCTAssertNil(launched, "runtime launched for invalid input")
    }
}

final class SearchResultCacheTests: XCTestCase {
    private func response(_ name: String) -> WebSearchResponse {
        WebSearchResponse(results: [WebSearchResult(url: URL(string: "https://example.com/\(name)")!,
            title: name, snippet: "snippet", publicationDateHint: nil)],
            coverage: .complete, unavailableEngineIDs: [])
    }

    func testCacheRoundTripsExpiresAndPersistsOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cache = SearchResultCache(fileURL: file, ttl: 60, maximumEntries: 4)
        await cache.store(query: "Swift", limit: 3, response: response("a"), now: now)
        let fresh = await cache.lookup(query: "swift", limit: 3, now: now.addingTimeInterval(30))
        XCTAssertEqual(fresh, response("a"))
        let expired = await cache.lookup(query: "swift", limit: 3, now: now.addingTimeInterval(61))
        XCTAssertNil(expired)

        let reopened = SearchResultCache(fileURL: file, ttl: 3_600, maximumEntries: 4)
        let persisted = await reopened.lookup(query: "SWIFT", limit: 3, now: now.addingTimeInterval(30))
        XCTAssertEqual(persisted, response("a"))
    }

    func testLimitIsPartOfTheKeyAndTheOldestEntryIsEvicted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cache = SearchResultCache(fileURL: directory.appendingPathComponent("cache.json"),
                                      ttl: 3_600, maximumEntries: 2)
        await cache.store(query: "q", limit: 2, response: response("q"), now: now)
        let otherLimit = await cache.lookup(query: "q", limit: 3, now: now)
        XCTAssertNil(otherLimit)
        await cache.store(query: "a", limit: 1, response: response("a"), now: now.addingTimeInterval(1))
        await cache.store(query: "b", limit: 1, response: response("b"), now: now.addingTimeInterval(2))
        let evicted = await cache.lookup(query: "q", limit: 2, now: now.addingTimeInterval(3))
        XCTAssertNil(evicted)
        let first = await cache.lookup(query: "a", limit: 1, now: now.addingTimeInterval(3))
        let second = await cache.lookup(query: "b", limit: 1, now: now.addingTimeInterval(3))
        XCTAssertEqual(first, response("a"))
        XCTAssertEqual(second, response("b"))
    }
}
