import XCTest
import Darwin
#if SWIFT_PACKAGE
@testable import DotCore
#endif

/// Explicit test-only URLProtocol adapter. Never compiled into the application,
/// and refuses a URL that the injected protocol classes do not claim.
struct ResearchURLSessionFixtureTransport: ResearchHTTPTransport, @unchecked Sendable {
    let configuration: URLSessionConfiguration
    func fetch(_ url: URL) async throws -> ResearchHTTPResult {
        var request = URLRequest(url: url)
        request.setValue("text/html, text/plain, application/pdf", forHTTPHeaderField: "Accept")
        guard (configuration.protocolClasses ?? []).contains(where: { ($0 as? URLProtocol.Type)?.canInit(with: request) == true }) else {
            throw ResearchNotebookError.networkFailure
        }
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil; config.connectionProxyDictionary = [:]
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let policy = ResearchFixtureNetworkPolicy(), session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        guard let response = response as? HTTPURLResponse, response.url == url,
              (200...299).contains(response.statusCode), response.expectedContentLength <= ResearchExtraction.maxBytes else {
            throw ResearchNotebookError.networkFailure
        }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
            guard data.count < ResearchExtraction.maxBytes else { throw ResearchNotebookError.limitExceeded }
            data.append(byte)
        }
        try Task.checkCancellation()
        return ResearchHTTPResult(data: data, response: response)
    }
}
private final class ResearchFixtureNetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private actor ResearchTransportTrace {
    var resolutions: [String] = []
    var pins: [String] = []
    func resolve(_ host: String) { resolutions.append(host) }
    func pin(_ value: String) { pins.append(value) }
    func snapshot() -> ([String], [String]) { (resolutions, pins) }
}

final class ResearchHTTPTransportTests: XCTestCase {
    private static func response(_ url: URL, code: Int = 200, location: String? = nil) -> ResearchHTTPResult {
        var headers = ["Content-Type": "text/plain"]
        if let location { headers["Location"] = location }
        return ResearchHTTPResult(data: Data("original evidence".utf8), response: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
    func testAllSpecialIPv4AndTransitionIPv6AreRejected() {
        let denied = ["0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "100.127.255.255", "127.0.0.1", "127.255.255.255",
                      "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.0.0.9", "192.0.2.1", "192.31.196.1", "192.52.193.1",
                      "192.88.99.1", "192.168.1.1", "192.175.48.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.1",
                      "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255", "::", "::1", "::127.0.0.1", "::ffff:127.0.0.1",
                      "::ffff:8.8.8.8", "::ffff:0:127.0.0.1", "64:ff9b::7f00:1", "64:ff9b:1::1", "100::1", "2001::7f00:1",
                      "2001:20::1", "2001:db8::1", "2002:7f00:1::1", "3ffe::1", "3fff::1", "2620:4f:8000::1", "fc00::1", "fd00::1",
                      "fe80::1", "fe80::1%en0", "ff02::1", "2606:4700::5efe:7f00:1", "2606:4700::200:5efe:7f00:1", "garbage", "127.1", "0x7f000001"]
        for address in denied { XCTAssertFalse(ResearchPublicAddress.allowed(address), address) }
        for address in ["1.1.1.1", "8.8.8.8", "93.184.216.34", "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1",
                        "2606:4700:4700::1111", "2001:4860:4860::8888", "2a00:1450:4001:800::200e"] {
            XCTAssertTrue(ResearchPublicAddress.allowed(address), address)
        }
    }
    func testDNSParsingRejectsMixedFamiliesMalformedEmptyAndOversizedAnswers() throws {
        let fixture = "name: example.org\nipv6_address: 2606:4700:4700::1111\n\nname: example.org\nalias: www.example.org \nip_address: 1.1.1.1\n\n"
        XCTAssertEqual(try ResearchSystemHTTP.parseDNS(Data(fixture.utf8)), ["2606:4700:4700::1111", "1.1.1.1"])
        for text in [fixture + "ip_address: 127.0.0.1\n", fixture + "ipv6_address: ::ffff:10.0.0.1\n", "", "name: nothing.example\n",
                     "address: 1.1.1.1\n", "ip_address: 1.1.1.1 injected\n", String(repeating: "ip_address: 1.1.1.1\n", count: 65), String(repeating: "a", count: 16_385)] {
            XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(text.utf8)))
        }
    }
    func testMixedDNSNeverDispatchesConnection() async {
        for addresses in [["1.1.1.1", "10.0.0.1"], ["2606:4700:4700::1111", "::1"], [], ["127.0.0.1"]] {
            let trace = ResearchTransportTrace()
            let transport = ResearchPinnedHTTPTransport(resolve: { _, _ in addresses }, exchange: { url, pin, _ in
                await trace.pin(pin); return Self.response(url)
            })
            do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Unsafe answer") } catch {}
            let (_, pins) = await trace.snapshot(); XCTAssertTrue(pins.isEmpty)
        }
    }
    func testPrivateDNSSinkReceivesZeroConnectionsOrRequestBytes() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        guard listener >= 0 else { return }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(listener, 4), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let flags = fcntl(listener, F_GETFL)
        XCTAssertEqual(fcntl(listener, F_SETFL, flags | O_NONBLOCK), 0)
        let url = URL(string: "http://private.example:\(UInt16(bigEndian: address.sin_port))/secret")!
        for answer in [["127.0.0.1"], ["1.1.1.1", "127.0.0.1"], ["2606:4700:4700::1111", "::ffff:127.0.0.1"]] {
            let transport = ResearchPinnedHTTPTransport(resolve: { _, _ in answer }, exchange: { _, _, _ in
                XCTFail("Unsafe DNS reached exchange"); throw ResearchNotebookError.networkFailure
            })
            do { _ = try await transport.fetch(url); XCTFail("Expected rejection before curl") } catch {}
        }
        let accepted = accept(listener, nil, nil)
        if accepted >= 0 { close(accepted); XCTFail("Private server received a connection") }
        else { XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK) }
    }
    func testRebindingCannotChangeApprovedPinAndEveryNewFetchResolvesAgain() async throws {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
            await trace.resolve(host)
            let (queries, _) = await trace.snapshot()
            return queries.count == 1 ? ["1.1.1.1"] : ["127.0.0.1"]
        }, exchange: { url, pin, _ in await trace.pin(pin); return Self.response(url) })
        _ = try await transport.fetch(URL(string: "https://EXAMPLE.org./a#fragment")!)
        do { _ = try await transport.fetch(URL(string: "https://example.org/a")!); XCTFail("Expected fresh unsafe DNS failure") } catch {}
        let (queries, pins) = await trace.snapshot()
        XCTAssertEqual(queries, ["example.org", "example.org"]); XCTAssertEqual(pins, ["1.1.1.1"])
    }
    func testRedirectIsReresolvedAndPrivateRedirectNeverConnects() async {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
            await trace.resolve(host); return host == "example.org" ? ["1.1.1.1"] : ["192.168.1.1"]
        }, exchange: { url, pin, _ in
            await trace.pin(pin); return Self.response(url, code: 302, location: "https://private.example/secret")
        })
        do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Expected blocked redirect") } catch {}
        let (queries, pins) = await trace.snapshot()
        XCTAssertEqual(queries, ["example.org", "private.example"]); XCTAssertEqual(pins, ["1.1.1.1"])
    }
    func testSameHostRedirectRebindingAlsoStopsBeforeSecondConnect() async {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
            await trace.resolve(host); let (queries, _) = await trace.snapshot()
            return queries.count == 1 ? ["1.1.1.1"] : ["127.0.0.1"]
        }, exchange: { url, pin, _ in await trace.pin(pin); return Self.response(url, code: 302, location: "/next") })
        do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Expected blocked rebind") } catch {}
        let (queries, pins) = await trace.snapshot(); XCTAssertEqual(queries.count, 2); XCTAssertEqual(pins.count, 1)
    }
    func testRedirectLimitAndHTTPSDowngrade() async {
        for location in ["/again", "http://example.org/unsafe", "file:///etc/passwd", "https://user:pass@example.org"] {
            let trace = ResearchTransportTrace()
            let transport = ResearchPinnedHTTPTransport(resolve: { _, _ in ["1.1.1.1"] }, exchange: { url, pin, _ in
                await trace.pin(pin); return Self.response(url, code: 302, location: location)
            })
            do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Expected redirect failure") } catch {}
            let (_, pins) = await trace.snapshot(); XCTAssertEqual(pins.count, location == "/again" ? 4 : 1)
        }
    }
    func testCancellationDuringResolverPreventsDispatch() async {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000); return ["1.1.1.1"]
        }, exchange: { url, pin, _ in await trace.pin(pin); return Self.response(url) })
        let task = Task { try await transport.fetch(URL(string: "https://example.org")!) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let (_, pins) = await trace.snapshot(); XCTAssertTrue(pins.isEmpty)
    }
    func testDefaultReaderFailsClosedWithoutAuditedRuntime() async {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in await trace.resolve(host); return ["1.1.1.1"] })
        do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Expected missing runtime failure") } catch {}
        let (queries, pins) = await trace.snapshot(); XCTAssertTrue(queries.isEmpty); XCTAssertTrue(pins.isEmpty)
    }
    func testMetadataIsBoundedAndDoesNotAdmitCookiesOrAuth() throws {
        let url = URL(string: "https://example.org")!
        let raw = Data(#"{"status":200,"headers":{"content-type":"text/html; charset=iso-8859-1","last-modified":"Tue, 14 Nov 2023 22:13:20 GMT"}}"#.utf8)
        let parsed = try ResearchSystemHTTP.parseMetadata(raw, url: url)
        XCTAssertEqual(parsed.statusCode, 200); XCTAssertEqual(parsed.textEncodingName, "iso-8859-1")
        for bad in [#"{"status":101,"headers":{}}"#, #"{"status":200,"headers":{"set-cookie":"secret=1"}}"#, "{}", String(repeating: "a", count: 65_537)] {
            XCTAssertThrowsError(try ResearchSystemHTTP.parseMetadata(Data(bad.utf8), url: url))
        }
        XCTAssertEqual(Set(ResearchBoundedProcess.environment.keys), ["PATH", "HOME", "LC_ALL", "PYTHONDONTWRITEBYTECODE"])
    }
    func testOwnedProcessDeadlineCancellationAndOutputLimit() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await ResearchBoundedProcess.run(executable: "/bin/sleep", arguments: ["5"], deadline: start + 0.1, stdoutLimit: 16, stderrLimit: 16)
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let task = Task { try await ResearchBoundedProcess.run(executable: "/bin/sleep", arguments: ["5"], deadline: ProcessInfo.processInfo.systemUptime + 10, stdoutLimit: 16, stderrLimit: 16) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await ResearchBoundedProcess.run(executable: "/usr/bin/yes", arguments: [], deadline: ProcessInfo.processInfo.systemUptime + 2, stdoutLimit: 100, stderrLimit: 16)
            XCTFail("Expected streamed overflow")
        } catch { XCTAssertEqual(error as? ResearchNotebookError, .limitExceeded) }
        let empty = try await ResearchBoundedProcess.run(executable: "/usr/bin/true", arguments: [], deadline: ProcessInfo.processInfo.systemUptime + 2, stdoutLimit: 16, stderrLimit: 16)
        XCTAssertEqual(empty.status, 0); XCTAssertTrue(empty.stdout.isEmpty); XCTAssertTrue(empty.stderr.isEmpty)
    }
}
