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

/// Only the delivery queue is held. Foundation launches/reaps a real child;
/// tests never call its termination handler or synthesize a receipt.
@MainActor private final class ResearchProcessSettlementFixture {
    let process = Process()
    let receiptQueue = OperationQueue()
    let input = Pipe()
    private(set) var returned = false

    init(_ script: String) {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        receiptQueue.maxConcurrentOperationCount = 1
        receiptQueue.isSuspended = true
    }

    func start(seconds: TimeInterval = 5, stdoutLimit: Int = 16, stderrLimit: Int = 16,
               beforeLaunch: (@Sendable () -> Void)? = nil) -> Task<ResearchBoundedProcess.Output, Error> {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        return Task { @MainActor in
            defer { returned = true }
            return try await ResearchBoundedProcess.run(testProcess: process, terminationReceiptQueue: receiptQueue,
                deadline: deadline, stdoutLimit: stdoutLimit, stderrLimit: stderrLimit, standardInput: input.fileHandleForReading,
                beforeLaunch: beforeLaunch)
        }
    }

    var pipes: [Pipe] { [process.standardOutput, process.standardError].compactMap { $0 as? Pipe } }

    func release() {
        receiptQueue.isSuspended = false
        try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
    }
}

@MainActor private final class ResearchProcessLifetimeProbe {
    weak var child: Process?
    weak var output: Pipe?
    weak var errors: Pipe?
}

final class ResearchHTTPTransportTests: XCTestCase {
    private static func response(_ url: URL, code: Int = 200, location: String? = nil) -> ResearchHTTPResult {
        var headers = ["Content-Type": "text/plain"]
        if let location { headers["Location"] = location }
        return ResearchHTTPResult(data: Data("original evidence".utf8), response: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
    func testInitialHTTPNeverResolvesOrConnectsAndCustomHTTPSPortsRemainAllowed() async throws {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
            await trace.resolve(host); return ["1.1.1.1"]
        }, exchange: { url, pin, _ in
            await trace.pin(pin); XCTAssertEqual(url.port, 8443); return Self.response(url)
        })
        for address in ["http://example.org/source", "HTTP://example.org/source", "http://example.org:8443/source"] {
            do { _ = try await transport.fetch(URL(string: address)!); XCTFail("HTTP must fail before DNS") }
            catch { XCTAssertEqual(error as? ResearchNotebookError, .invalidInput) }
        }
        let (queries, pins) = await trace.snapshot()
        XCTAssertTrue(queries.isEmpty); XCTAssertTrue(pins.isEmpty)
        _ = try await transport.fetch(URL(string: "https://example.org:8443/source")!)
        let (secureQueries, securePins) = await trace.snapshot()
        XCTAssertEqual(secureQueries, ["example.org"]); XCTAssertEqual(securePins, ["1.1.1.1"])
    }

    func testDowngradeRedirectStopsBeforeSecondDNSOrConnection() async {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
            await trace.resolve(host); return ["1.1.1.1"]
        }, exchange: { url, pin, _ in
            await trace.pin(pin); return Self.response(url, code: 302, location: "http://other.example/replaced")
        })
        do { _ = try await transport.fetch(URL(string: "https://example.org/source")!); XCTFail("HTTP redirect accepted") }
        catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        let (queries, pins) = await trace.snapshot()
        XCTAssertEqual(queries, ["example.org"]); XCTAssertEqual(pins, ["1.1.1.1"])
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
        for address in ["1.1.1.1", "8.8.8.8", "93.184.216.34", "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1"] {
            XCTAssertTrue(ResearchPublicAddress.allowed(address), address)
        }
    }
    func testDNSParsingUsesOnlyVettedIPv4AndRejectsMalformedEmptyOversizedAnswers() throws {
        let fixture = "name: example.org\nipv6_address: 2606:4700:4700::1111\n\nname: example.org\nalias: www.example.org \nip_address: 1.1.1.1\n\n"
        XCTAssertEqual(try ResearchSystemHTTP.parseDNS(Data(fixture.utf8)), ["1.1.1.1"])
        for text in [fixture + "ip_address: 127.0.0.1\n", "ipv6_address: 2001:4860:1234:5678::a00:1\n", fixture + "ipv6_address: malformed\n", "", "name: nothing.example\n",
                     "address: 1.1.1.1\n", "ip_address: 1.1.1.1 injected\n", String(repeating: "ip_address: 1.1.1.1\n", count: 65), fixture + String(repeating: "ipv6_address: ::1\n", count: 65), String(repeating: "a", count: 16_385)] {
            XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(text.utf8)))
        }
    }
    func testGlobalIPv6AndNetworkSpecificNAT64AreNeverAdmitted() throws {
        for address in ["2606:4700:4700::1111", "2001:4860:4860::8888",
                        "2001:4860:1234:5678::7f00:1", "2001:4860:1234:5678::a00:1",
                        "2001:4860:1234:5678::a9fe:a9fe", "2001:4860:1234:5678::c0a8:101"] {
            XCTAssertFalse(ResearchPublicAddress.allowed(address))
            XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data("ipv6_address: \(address)\n".utf8)))
            XCTAssertEqual(try ResearchSystemHTTP.parseDNS(Data("ipv6_address: \(address)\nip_address: 1.1.1.1\n".utf8)), ["1.1.1.1"])
        }
    }
    func testDNSCountsDiscardedAAAAAndRejectsUnsafeARegardlessOfOrder() throws {
        let safe = "ip_address: 1.1.1.1\n"
        let discarded = "ipv6_address: ::ffff:10.0.0.1\n"
        XCTAssertEqual(try ResearchSystemHTTP.parseDNS(Data((String(repeating: discarded, count: 63) + safe).utf8)), ["1.1.1.1"])
        XCTAssertEqual(try ResearchSystemHTTP.parseDNS(Data(String(repeating: safe, count: 64).utf8)).count, 64)
        for text in [String(repeating: discarded, count: 64) + safe,
                     safe + "ipv6_address: fe80::1%en0\n", safe + "ipv6_address: 1.1.1.1\n",
                     safe + "ip_address: 2606:4700:4700::1111\n"] {
            XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(text.utf8)))
        }
        for address in ["10.0.0.1", "127.0.0.1", "169.254.169.254", "192.168.1.1", "192.0.2.1", "240.0.0.1"] {
            let unsafe = "ip_address: \(address)\n"
            for text in [safe + discarded + unsafe, unsafe + discarded + safe] {
                XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(text.utf8)))
            }
        }
        for address in ["::1", "::ffff:127.0.0.1", "::ffff:0:127.0.0.1", "64:ff9b::7f00:1", "fc00::1", "fe80::1"] {
            let aaaa = "ipv6_address: \(address)\n"
            XCTAssertEqual(try ResearchSystemHTTP.parseDNS(Data((aaaa + safe).utf8)), ["1.1.1.1"])
            XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(aaaa.utf8)))
        }
    }
    func testDNSRejectsNULSuffixedAAAAWithPublicAInEitherOrder() throws {
        let safe = "ip_address: 1.1.1.1\n"
        for address in ["::1", "2606:4700:4700::1111", "2001:4860:1234:5678::a00:1"] {
            for suffix in ["", "garbage"] {
                let malformed = "ipv6_address: \(address)\u{0}\(suffix)\n"
                for text in [malformed + safe, safe + malformed] {
                    XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(text.utf8)))
                }
            }
        }
    }
    func testDNSRejectsNULSuffixedIPv4PinsWithPublicAInEitherOrder() throws {
        let safe = "ip_address: 93.184.216.34\n"
        for address in ["1.1.1.1", "8.8.8.8"] {
            for suffix in ["", "garbage"] {
                let malformed = "\(address)\u{0}\(suffix)"
                XCTAssertFalse(ResearchPublicAddress.allowed(malformed))
                let invalidA = "ip_address: \(malformed)\n"
                for text in [invalidA, invalidA + safe, safe + invalidA] {
                    XCTAssertThrowsError(try ResearchSystemHTTP.parseDNS(Data(text.utf8)))
                }
            }
        }
    }
    func testCustomResolverCannotMixIPv6WithPublicIPv4() async {
        for address in ["2606:4700:4700::1111", "::ffff:127.0.0.1", "::ffff:0:127.0.0.1",
                        "64:ff9b::7f00:1", "2001:4860:1234:5678::a00:1", "192.0.2.1", "240.0.0.1"] {
            for addresses in [[address], ["1.1.1.1", address], [address, "1.1.1.1"]] {
                let trace = ResearchTransportTrace()
                let transport = ResearchPinnedHTTPTransport(resolve: { _, _ in addresses }, exchange: { url, pin, _ in
                    await trace.pin(pin); return Self.response(url)
                })
                do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Unsafe custom resolver pin") }
                catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
                let (_, pins) = await trace.snapshot(); XCTAssertTrue(pins.isEmpty)
            }
        }
    }
    func testFirstPublicIPv4IsTheOnlyAttemptEvenWhenExchangeFails() async {
        let trace = ResearchTransportTrace()
        let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
            await trace.resolve(host); return ["8.8.8.8", "1.1.1.1"]
        }, exchange: { _, pin, _ in
            await trace.pin(pin); throw ResearchNotebookError.networkFailure
        })
        do { _ = try await transport.fetch(URL(string: "https://example.org")!); XCTFail("Expected exchange failure") }
        catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        let (queries, pins) = await trace.snapshot()
        XCTAssertEqual(queries, ["example.org"]); XCTAssertEqual(pins, ["8.8.8.8"])
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
        let url = URL(string: "https://private.example:\(UInt16(bigEndian: address.sin_port))/secret")!
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
    func testRedirectRepinsToNewPublicIPv4ForSameAndDifferentHosts() async throws {
        for location in ["/next", "https://other.example/next"] {
            let trace = ResearchTransportTrace()
            let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
                await trace.resolve(host); let (queries, _) = await trace.snapshot()
                return queries.count == 1 ? ["1.1.1.1"] : ["8.8.8.8"]
            }, exchange: { url, pin, _ in
                await trace.pin(pin)
                return Self.response(url, code: url.path == "/next" ? 200 : 302, location: url.path == "/next" ? nil : location)
            })
            let result = try await transport.fetch(URL(string: "https://example.org/start")!)
            XCTAssertEqual(result.response.url?.path, "/next")
            let (queries, pins) = await trace.snapshot()
            XCTAssertEqual(queries, ["example.org", location.hasPrefix("/") ? "example.org" : "other.example"])
            XCTAssertEqual(pins, ["1.1.1.1", "8.8.8.8"])
        }
    }
    func testRedirectRebindingToIPv6OrMixedUnsafeAStopsBeforeSecondExchange() async {
        for location in ["/next", "https://other.example/next"] {
            for rebound in [["2001:4860:1234:5678::a00:1"], ["1.1.1.1", "::ffff:127.0.0.1"],
                            ["1.1.1.1", "192.0.2.1"], ["1.1.1.1", "10.0.0.1"]] {
                let trace = ResearchTransportTrace()
                let transport = ResearchPinnedHTTPTransport(resolve: { host, _ in
                    await trace.resolve(host); let (queries, _) = await trace.snapshot()
                    return queries.count == 1 ? ["1.1.1.1"] : rebound
                }, exchange: { url, pin, _ in
                    await trace.pin(pin); return Self.response(url, code: 302, location: location)
                })
                do { _ = try await transport.fetch(URL(string: "https://example.org/start")!); XCTFail("Unsafe redirect rebind") }
                catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
                let (queries, pins) = await trace.snapshot()
                XCTAssertEqual(queries, ["example.org", location.hasPrefix("/") ? "example.org" : "other.example"])
                XCTAssertEqual(pins, ["1.1.1.1"])
            }
        }
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
    /// The shipped reader is the native `dot-fetch` executable. There is no
    /// interpreter selection left: exactly one executable regular file is admissible,
    /// and both literals handed to Seatbelt are kernel-resolved paths.
    func testNativeRuntimeAdmitsOnlyOneExecutableReaderThroughKernelPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = directory.appendingPathComponent("dot-fetch"), profile = directory.appendingPathComponent("source_fetch.sb")
        try Data("fixture native reader".utf8).write(to: reader)
        try Data("(version 1)".utf8).write(to: profile)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        let alias = directory.appendingPathComponent("reader-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let runtime = try ResearchFetchRuntime(signedHelper: alias.appendingPathComponent("dot-fetch"),
            signedProfile: alias.appendingPathComponent("source_fetch.sb"))
        let expectedReader = try Self.kernelPath(reader), expectedProfile = try Self.kernelPath(profile)
        XCTAssertEqual(runtime.helper, expectedReader); XCTAssertEqual(runtime.profile, expectedProfile)
        XCTAssertNotEqual(runtime.helper, alias.appendingPathComponent("dot-fetch").path)
        let arguments = try runtime.arguments(url: URL(string: "https://example.org/")!, address: "1.1.1.1", remaining: 2)
        XCTAssertEqual(arguments, ["-f", expectedProfile, "-D", "DOT_SOURCE_HELPER=" + expectedReader,
            expectedReader, "https://example.org/", "1.1.1.1", "2.000"])
        // A non-executable, directory, missing or remote helper is never a reader.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reader.path)
        XCTAssertThrowsError(try ResearchFetchRuntime(signedHelper: alias.appendingPathComponent("dot-fetch"),
            signedProfile: alias.appendingPathComponent("source_fetch.sb")))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        for invalid in [directory, directory.appendingPathComponent("missing-reader"), URL(string: "https://example.org/dot-fetch")!] {
            XCTAssertThrowsError(try ResearchFetchRuntime(signedHelper: invalid, signedProfile: profile))
        }
        XCTAssertThrowsError(try ResearchFetchRuntime(signedHelper: reader, signedProfile: directory))
    }

    private static func kernelPath(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
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

    @MainActor private func eventuallyProcess(_ condition: () -> Bool,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Process fixture did not reach its observed state", file: file, line: line)
                throw ResearchNotebookError.networkFailure
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor private func assertProcessPipesClosed(_ fixture: ResearchProcessSettlementFixture,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.pipes.count, 2, file: file, line: line)
        for pipe in fixture.pipes {
            XCTAssertThrowsError(try pipe.fileHandleForReading.read(upToCount: 1), file: file, line: line)
        }
        XCTAssertNil(fixture.process.terminationHandler, file: file, line: line)
        // The supplied input belongs to the caller, not child cleanup.
        XCTAssertGreaterThanOrEqual(fcntl(fixture.input.fileHandleForReading.fileDescriptor, F_GETFD), 0, file: file, line: line)
    }

    @MainActor func testOwnedProcessEOFDoesNotSubstituteForExitOrTerminationReceipt() async throws {
        let fixture = ResearchProcessSettlementFixture("exec 1>&- 2>&-; read -r line")
        let task = fixture.start()
        defer { task.cancel(); fixture.release() }
        try await eventuallyProcess { fixture.process.isRunning }
        let descriptors = fixture.pipes.map { $0.fileHandleForReading.fileDescriptor }
        XCTAssertEqual(descriptors.count, 2)
        try await eventuallyProcess {
            descriptors.allSatisfy { descriptor in
                var byte: UInt8 = 0
                return Darwin.read(descriptor, &byte, 1) == 0
            }
        }
        // Both output streams are genuinely at EOF, but this exact child is alive.
        XCTAssertTrue(fixture.process.isRunning); XCTAssertFalse(fixture.returned)
        XCTAssertEqual(fixture.receiptQueue.operationCount, 0)
        try fixture.input.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
        try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
        XCTAssertFalse(fixture.process.isRunning)
        XCTAssertEqual(fixture.process.terminationReason, .exit)
        XCTAssertEqual(fixture.process.terminationStatus, 0)
        // Even actual exit plus EOF cannot bypass the held authentic receipt.
        for _ in 0..<4 { await Task.yield() }
        XCTAssertFalse(fixture.returned)
        for descriptor in descriptors { XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0) }
        fixture.receiptQueue.isSuspended = false
        let result = try await task.value
        XCTAssertEqual(result.status, 0); XCTAssertTrue(result.stdout.isEmpty); XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertTrue(fixture.returned); assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessRepeatedCancellationWaitsForRealTerminationAndPipeClosure() async throws {
        let fixture = ResearchProcessSettlementFixture("trap '' TERM; read -r line")
        let task = fixture.start()
        defer { task.cancel(); fixture.release() }
        try await eventuallyProcess { fixture.process.isRunning }
        let descriptors = fixture.pipes.map { $0.fileHandleForReading.fileDescriptor }
        task.cancel()
        try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
        XCTAssertFalse(fixture.process.isRunning)
        XCTAssertEqual(fixture.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(fixture.process.terminationStatus, SIGKILL)
        // Cleanup already killed the held child; repeated cancellation must not
        // cancel cleanup or turn that kill request into a settlement receipt.
        for _ in 0..<8 {
            task.cancel(); try await Task.sleep(nanoseconds: 5_000_000)
            XCTAssertFalse(fixture.returned)
        }
        for descriptor in descriptors { XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0) }
        fixture.receiptQueue.isSuspended = false
        do { _ = try await task.value; XCTFail("Expected cancellation after settlement") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.returned); assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessDeadlineCannotReplaceTerminationReceiptDuringCancellation() async throws {
        let fixture = ResearchProcessSettlementFixture("read -r line")
        let task = fixture.start(seconds: 1)
        defer { task.cancel(); fixture.release() }
        try await eventuallyProcess { fixture.process.isRunning }
        let descriptors = fixture.pipes.map { $0.fileHandleForReading.fileDescriptor }
        try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
        XCTAssertFalse(fixture.process.isRunning)
        XCTAssertEqual(fixture.process.terminationStatus, SIGKILL)
        for _ in 0..<8 {
            task.cancel(); try await Task.sleep(nanoseconds: 5_000_000)
            XCTAssertFalse(fixture.returned)
        }
        for descriptor in descriptors { XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0) }
        fixture.receiptQueue.isSuspended = false
        do { _ = try await task.value; XCTFail("Expected original deadline failure") }
        catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessBothOutputLimitsAwaitRealTerminationDespiteRepeatedCancellation() async throws {
        for destination in ["", " >&2"] {
            let fixture = ResearchProcessSettlementFixture("read -r line; while :; do printf '12345678'" + destination + "; done")
            let task = fixture.start(stdoutLimit: 7, stderrLimit: 7)
            defer { task.cancel(); fixture.release() }
            try await eventuallyProcess { fixture.process.isRunning }
            let descriptors = fixture.pipes.map { $0.fileHandleForReading.fileDescriptor }
            try fixture.input.fileHandleForWriting.write(contentsOf: Data("start\n".utf8))
            try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
            XCTAssertFalse(fixture.process.isRunning)
            XCTAssertEqual(fixture.process.terminationReason, .uncaughtSignal)
            XCTAssertEqual(fixture.process.terminationStatus, SIGKILL)
            for _ in 0..<4 {
                task.cancel(); try await Task.sleep(nanoseconds: 5_000_000)
                XCTAssertFalse(fixture.returned)
            }
            for descriptor in descriptors { XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0) }
            fixture.receiptQueue.isSuspended = false
            do { _ = try await task.value; XCTFail("Expected streamed overflow after settlement") }
            catch { XCTAssertEqual(error as? ResearchNotebookError, .limitExceeded) }
            assertProcessPipesClosed(fixture)
        }
    }

    @MainActor func testOwnedProcessExactLimitSuccessAndNonzeroStatusWaitForReceipt() async throws {
        for status in [0, 7] {
            let fixture = ResearchProcessSettlementFixture("printf 'source'; printf 'meta' >&2; exit \(status)")
            let task = fixture.start(stdoutLimit: 6, stderrLimit: 4)
            defer { task.cancel(); fixture.release() }
            try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
            XCTAssertFalse(fixture.process.isRunning)
            XCTAssertEqual(fixture.process.terminationStatus, Int32(status))
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertFalse(fixture.returned)
            fixture.receiptQueue.isSuspended = false
            let result = try await task.value
            XCTAssertEqual(result.status, Int32(status))
            XCTAssertEqual(result.stdout, Data("source".utf8)); XCTAssertEqual(result.stderr, Data("meta".utf8))
            assertProcessPipesClosed(fixture)
        }
    }

    @MainActor func testOwnedProcessSuccessfulExitPastDeadlineStillAwaitsReceiptThenFails() async throws {
        let fixture = ResearchProcessSettlementFixture("exit 0")
        let task = fixture.start(seconds: 0.5)
        defer { task.cancel(); fixture.release() }
        try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
        XCTAssertFalse(fixture.process.isRunning); XCTAssertEqual(fixture.process.terminationStatus, 0)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(fixture.returned, "The elapsed deadline must not release a held receipt")
        fixture.receiptQueue.isSuspended = false
        do { _ = try await task.value; XCTFail("Expected expired deadline after settlement") }
        catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessCancellationWhileSuccessfulReceiptIsHeldCannotReturnSuccess() async throws {
        let fixture = ResearchProcessSettlementFixture("exit 0")
        let task = fixture.start()
        defer { task.cancel(); fixture.release() }
        try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
        XCTAssertFalse(fixture.process.isRunning); XCTAssertEqual(fixture.process.terminationStatus, 0)
        for _ in 0..<8 {
            task.cancel(); try await Task.sleep(nanoseconds: 5_000_000)
            XCTAssertFalse(fixture.returned)
        }
        fixture.receiptQueue.isSuspended = false
        do { _ = try await task.value; XCTFail("Cancelled caller received success") }
        catch { XCTAssertTrue(error is CancellationError) }
        assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessCancellationAfterInitialCheckStillSettlesAdmittedChild() async throws {
        let fixture = ResearchProcessSettlementFixture("read -r line")
        let task = fixture.start(beforeLaunch: { withUnsafeCurrentTask { $0?.cancel() } })
        defer { task.cancel(); fixture.release() }
        try await eventuallyProcess { fixture.receiptQueue.operationCount == 1 }
        XCTAssertTrue(task.isCancelled)
        XCTAssertGreaterThan(fixture.process.processIdentifier, 0)
        XCTAssertFalse(fixture.process.isRunning)
        XCTAssertEqual(fixture.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(fixture.process.terminationStatus, SIGKILL)
        for _ in 0..<4 { task.cancel(); await Task.yield(); XCTAssertFalse(fixture.returned) }
        fixture.receiptQueue.isSuspended = false
        do { _ = try await task.value; XCTFail("Expected cancellation after admitted-child settlement") }
        catch { XCTAssertTrue(error is CancellationError) }
        assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessLaunchFailureClosesPipesWithoutInventingReceipt() async throws {
        let fixture = ResearchProcessSettlementFixture("exit 0")
        fixture.process.executableURL = URL(fileURLWithPath: "/nonexistent-dot-process-fixture/child")
        let task = fixture.start()
        defer { task.cancel(); fixture.release() }
        do { _ = try await task.value; XCTFail("Expected launch failure") } catch {}
        XCTAssertFalse(fixture.process.isRunning); XCTAssertEqual(fixture.receiptQueue.operationCount, 0)
        XCTAssertTrue(fixture.returned); assertProcessPipesClosed(fixture)
    }

    @MainActor func testOwnedProcessSettledTasksReleaseChildAndPipesIncludingLaunchFailure() async throws {
        for failsToLaunch in [false, true] {
            let probe = ResearchProcessLifetimeProbe()
            let completedTask: Task<ResearchBoundedProcess.Output, Error>
            do {
                let fixture = ResearchProcessSettlementFixture("printf 'ok'")
                if failsToLaunch {
                    fixture.process.executableURL = URL(fileURLWithPath: "/nonexistent-dot-process-fixture/child")
                }
                // Allow immediate callback delivery, including callback-before-
                // waiter scheduling. The receipt stores an already-arrived status.
                fixture.receiptQueue.isSuspended = false
                let task = fixture.start()
                defer { task.cancel(); fixture.release() }
                let result = await task.result
                if failsToLaunch {
                    if case .success = result { XCTFail("Expected launch failure") }
                } else {
                    let value = try result.get()
                    XCTAssertEqual(value.status, 0); XCTAssertEqual(value.stdout, Data("ok".utf8))
                }
                assertProcessPipesClosed(fixture)
                probe.child = fixture.process; probe.output = fixture.pipes.first; probe.errors = fixture.pipes.last
                XCTAssertNotNil(probe.child); XCTAssertNotNil(probe.output); XCTAssertNotNil(probe.errors)
                completedTask = task
            }
            // Retaining the finished consumer must not retain cleanup, its child
            // or either pipe through a callback/task ownership cycle.
            try await eventuallyProcess { probe.child == nil && probe.output == nil && probe.errors == nil }
            withExtendedLifetime(completedTask) {}
        }
    }

    func testNumericConnectRejectsPrivatePinsInvalidPortsAndExpiredDeadlines() async {
        for (address, port, deadline) in [("127.0.0.1", 80, ProcessInfo.processInfo.systemUptime + 1),
                                         ("::1", 80, ProcessInfo.processInfo.systemUptime + 1),
                                         ("1.1.1.1", 0, ProcessInfo.processInfo.systemUptime + 1),
                                         ("1.1.1.1", 65_536, ProcessInfo.processInfo.systemUptime + 1),
                                         ("1.1.1.1", 80, 0), ("1.1.1.1", 80, .infinity)] {
            do {
                let socket = try await ResearchPinnedSocket.connect(address: address, port: port, deadline: deadline)
                try? socket.close(); XCTFail("Invalid endpoint/deadline accepted")
            } catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        }
    }

    func testConnectWaitHonorsDeadlineAndCancellationWithoutBlocking() async throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { XCTFail("socketpair failed"); return }
        defer { sockets.forEach { Darwin.close($0) } }
        let descriptor = sockets[0], flags = fcntl(sockets[0], F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), 0)
        // Fill a local socket so its POLLOUT stays pending without public traffic.
        let buffer = [UInt8](repeating: 0, count: 16_384)
        var blocked = false
        for _ in 0..<1_024 {
            let count = buffer.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 {
                XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK); blocked = true; break
            }
        }
        guard blocked else { XCTFail("Fixture did not fill"); return }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try await ResearchPinnedSocket.waitUntilConnected(descriptor, deadline: start + 0.05)
            XCTFail("Expected connect deadline")
        } catch { XCTAssertEqual(error as? ResearchNotebookError, .networkFailure) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let task = Task { try await ResearchPinnedSocket.waitUntilConnected(descriptor, deadline: ProcessInfo.processInfo.systemUptime + 10) }
        try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
        do { try await task.value; XCTFail("Expected connect cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

#if !SWIFT_PACKAGE
    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The shipped native reader is the second `[[bin]]` of `crates/dot-research`.
    /// `scripts/verify_macos.sh` builds it before the XCTest lane; a direct Xcode run
    /// without it skips instead of substituting another reader.
    private static func nativeReader() throws -> URL {
        let reader = repository.appendingPathComponent("target/release/dot-fetch")
        guard FileManager.default.isExecutableFile(atPath: reader.path) else {
            throw XCTSkip("Build the native source reader first: cargo build --release --manifest-path Cargo.toml --bin dot-fetch")
        }
        return reader
    }

    /// Assemble the runtime over the staged native reader and the shipped profile.
    @MainActor private func sourceRuntime(helper: URL) async throws -> ResearchFetchRuntime {
        try ResearchFetchRuntime(signedHelper: helper,
            signedProfile: Self.repository.appendingPathComponent("Resources/Research/source_fetch.sb"))
    }

    @MainActor private func inheritedTCPFixture() async throws -> (FileHandle, FileHandle, Int) {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ResearchNotebookError.networkFailure }
        defer { Darwin.close(listener) }
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw ResearchNotebookError.networkFailure }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else { throw ResearchNotebookError.networkFailure }
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { throw ResearchNotebookError.networkFailure }
        let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
        do {
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else { throw ResearchNotebookError.networkFailure }
            let started = withUnsafePointer(to: &endpoint) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard started == 0 || errno == EINPROGRESS else { throw ResearchNotebookError.networkFailure }
            try await ResearchPinnedSocket.waitUntilConnected(client, deadline: ProcessInfo.processInfo.systemUptime + 1)
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else { throw ResearchNotebookError.networkFailure }
            return (handle, FileHandle(fileDescriptor: accepted, closeOnDealloc: true), Int(UInt16(bigEndian: endpoint.sin_port)))
        } catch { try? handle.close(); throw error }
    }

    @MainActor private func assertPeerBytes(_ peer: FileHandle, expected: Data) throws {
        let descriptor = peer.fileDescriptor, flags = fcntl(peer.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ResearchNotebookError.networkFailure }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&event, 1, 1_000), 1, "Child socket must close promptly after its owner closes")
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        XCTAssertGreaterThanOrEqual(count, 0)
        XCTAssertEqual(Data(buffer.prefix(max(0, count))), expected)
    }

    @MainActor func testAssembledNativeReaderRunsOnlyThePinnedExecutableUnderExactSandbox() async throws {
        let reader = try Self.nativeReader()
        let runtime = try await sourceRuntime(helper: reader)
        XCTAssertEqual(runtime.helper, try Self.kernelPath(reader), "The exact sandbox literal must retain /private when required")
        // The reader adopts the inherited descriptor and has no dialing call site at
        // all, so (deny network*) is not the only reason it cannot reach another peer.
        let source = try String(contentsOf: Self.repository.appendingPathComponent("crates/dot-research/src/fetch.rs"), encoding: .utf8)
        XCTAssertFalse(source.contains("TcpStream::connect"))
        XCTAssertFalse(source.contains("to_socket_addrs"))
        // The exact profile admits one executable: the pinned reader. Any substituted
        // child is refused by Seatbelt before it runs, so no reader can be swapped in.
        let substituted = try await ResearchBoundedProcess.run(executable: "/usr/bin/sandbox-exec",
            arguments: ["-f", runtime.profile, "-D", "DOT_SOURCE_HELPER=" + runtime.helper, "/usr/bin/true"],
            deadline: ProcessInfo.processInfo.systemUptime + 3, stdoutLimit: 128, stderrLimit: 4_096)
        XCTAssertNotEqual(substituted.status, 0); XCTAssertTrue(substituted.stdout.isEmpty)
        // Under the profile the reader inherits exactly this connected socket and
        // refuses a peer that is not the pin before any request byte leaves it.
        let (inherited, peer, port) = try await inheritedTCPFixture()
        defer { try? inherited.close(); try? peer.close() }
        let arguments = try runtime.arguments(url: URL(string: "https://fixture.invalid:\(port)/")!, address: "1.1.1.1", remaining: 2)
        XCTAssertFalse(arguments.contains { $0.contains("DOT_SOURCE_ENDPOINT") })
        let result = try await ResearchBoundedProcess.run(executable: "/usr/bin/sandbox-exec", arguments: arguments,
            deadline: ProcessInfo.processInfo.systemUptime + 3, stdoutLimit: 128, stderrLimit: 4_096, standardInput: inherited)
        XCTAssertEqual(result.status, 1, String(decoding: result.stderr, as: UTF8.self))
        XCTAssertTrue(result.stdout.isEmpty); XCTAssertTrue(result.stderr.isEmpty)
        try inherited.close()
        try assertPeerBytes(peer, expected: Data())
    }

    @MainActor func testAssembledProductionReaderRejectsInheritedPeerBeforeHTTPBytes() async throws {
        let runtime = try await sourceRuntime(helper: try Self.nativeReader())
        let (inherited, peer, port) = try await inheritedTCPFixture()
        defer { try? inherited.close(); try? peer.close() }
        let arguments = try runtime.arguments(url: URL(string: "https://fixture.invalid:\(port)/secret")!, address: "1.1.1.1", remaining: 2)
        let result = try await ResearchBoundedProcess.run(executable: "/usr/bin/sandbox-exec", arguments: arguments,
            deadline: ProcessInfo.processInfo.systemUptime + 3, stdoutLimit: 128, stderrLimit: 4_096, standardInput: inherited)
        XCTAssertEqual(result.status, 1); XCTAssertTrue(result.stdout.isEmpty); XCTAssertTrue(result.stderr.isEmpty)
        try inherited.close()
        try assertPeerBytes(peer, expected: Data())
    }
#endif
}
