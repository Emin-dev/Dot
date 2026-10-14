import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class SearchEgressBrokerTests: XCTestCase {
    private let generation = UUID(uuidString: "2A123456-1234-4567-8123-123456789ABC")!
    private var fixtureAuthorization: String {
        "Basic " + Data(("dot:" + String(repeating: "a", count: 64)).utf8).base64EncodedString()
    }
    private func frame(authorization: String? = nil, extra: String = "") -> Data {
        Data(("CONNECT html.duckduckgo.com:443 HTTP/1.1\r\n"
            + "Host: html.duckduckgo.com:443\r\n"
            + "Proxy-Authorization: \(authorization ?? fixtureAuthorization)\r\n"
            + extra + "\r\n").utf8)
    }
    private func parsed(_ data: Data, generation: UUID? = nil) throws -> SearchCONNECTRequest {
        var parser = SearchCONNECTParser(generation: generation ?? self.generation)
        let request = try parser.append(data)
        return try XCTUnwrap(request)
    }
    private func expect(_ failure: SearchEgressFailure, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? SearchEgressFailure, failure, file: file, line: line)
        }
    }
    private func budget(now: TimeInterval = 100, deadline: TimeInterval = 200) throws -> SearchEgressBudget {
        try SearchEgressBudget(generation: generation, absoluteDeadline: deadline, now: now)
    }
    private func admit(_ value: inout SearchEgressBudget, now: TimeInterval = 100) throws -> SearchCONNECTAdmission {
        let request = try parsed(frame(authorization: value.proxyAuthorization), generation: value.generation)
        return try value.admit(request, now: now)
    }
    private func write(_ value: inout SearchEgressBudget, admission: SearchCONNECTAdmission,
                       direction: SearchEgressDirection, bytes: Int, now: TimeInterval = 100) throws {
        let permit = try value.reserveWrite(admission, direction: direction, requestedBytes: bytes, now: now)
        XCTAssertEqual(permit.byteCount, bytes)
        try value.settleWrite(permit, successfulBytes: bytes, now: now)
    }

    func testEverySplitPositionOfValidHeader() throws {
        let data = frame(extra: "Proxy-Connection: Keep-Alive\r\nUser-Agent: curl/fixture 1\r\n")
        for split in 0...data.count {
            var parser = SearchCONNECTParser(generation: generation)
            let first = try parser.append(Data(data.prefix(split)))
            if split < data.count {
                XCTAssertNil(first, "split \(split)")
                XCTAssertNotNil(try parser.append(Data(data.dropFirst(split))), "split \(split)")
            } else { XCTAssertNotNil(first) }
            XCTAssertEqual(parser.bufferedByteCount, 0)
            expect(.parserFinished) { _ = try parser.append(Data()) }
            expect(.parserFinished) { _ = try parser.append(data) }
            expect(.parserFinished) { try parser.finish() }
        }
    }

    func testByteAtATimeAndAllOptionalHeaderCombinations() throws {
        for extra in ["", "Proxy-Connection: Keep-Alive\r\n", "User-Agent: curl/8.0.0 (fixture)\r\n",
                      "Proxy-Connection: Keep-Alive\r\nUser-Agent: curl/8.0.0 (fixture)\r\n"] {
            let data = frame(extra: extra)
            var parser = SearchCONNECTParser(generation: generation)
            for (index, byte) in data.enumerated() {
                let result = try parser.append(Data([byte]))
                if index == data.count - 1 { XCTAssertNotNil(result) } else { XCTAssertNil(result) }
                XCTAssertLessThanOrEqual(parser.bufferedByteCount, SearchCONNECTParser.maximumHeaderBytes)
            }
        }
    }

    func testHeaderNamesAreCaseInsensitiveAndMayBeReordered() throws {
        let text = "CONNECT html.duckduckgo.com:443 HTTP/1.1\r\n"
            + "pRoXy-AuThOrIzAtIoN: \(fixtureAuthorization)\r\n"
            + "uSeR-aGeNt: !~ fixture\r\npRoXy-CoNnEcTiOn: Keep-Alive\r\nhOsT: html.duckduckgo.com:443\r\n\r\n"
        XCTAssertNotNil(try parsed(Data(text.utf8)))
    }

    func testExactHeaderLimitAcceptedAtEverySplitAndOneOverRejected() throws {
        let fixed = frame(extra: "User-Agent: x\r\n").count - 1
        let data = frame(extra: "User-Agent: " + String(repeating: "x", count: 8192 - fixed) + "\r\n")
        XCTAssertEqual(data.count, SearchCONNECTParser.maximumHeaderBytes)
        // Includes the CR/LF and limit boundaries as well as all value splits.
        for split in 0..<data.count {
            var parser = SearchCONNECTParser(generation: generation)
            XCTAssertNil(try parser.append(Data(data.prefix(split))))
            XCTAssertNotNil(try parser.append(Data(data.dropFirst(split))))
        }
        XCTAssertNotNil(try parsed(data))
        let oversized = frame(extra: "User-Agent: " + String(repeating: "x", count: 8193 - fixed) + "\r\n")
        for split in [0, 1, 4096, 8191, 8192, 8193] {
            var parser = SearchCONNECTParser(generation: generation)
            expect(.headerTooLarge) {
                _ = try parser.append(Data(oversized.prefix(split)))
                _ = try parser.append(Data(oversized.dropFirst(split)))
            }
            XCTAssertEqual(parser.bufferedByteCount, 0)
            expect(.headerTooLarge) { _ = try parser.append(frame()) }
        }
    }

    func testMissingTerminatorEOFIsStickyAndClearsBuffer() throws {
        for suffix in 1...4 {
            var parser = SearchCONNECTParser(generation: generation)
            XCTAssertNil(try parser.append(Data(frame().dropLast(suffix))))
            expect(.incompleteHeader) { try parser.finish() }
            XCTAssertEqual(parser.bufferedByteCount, 0)
            expect(.incompleteHeader) { _ = try parser.append(Data([13, 10, 13, 10])) }
        }
        var empty = SearchCONNECTParser(generation: generation)
        expect(.incompleteHeader) { try empty.finish() }
    }

    func testUnterminatedLimitAndHugeFragmentNeverGrowBuffer() throws {
        var parser = SearchCONNECTParser(generation: generation)
        XCTAssertNil(try parser.append(Data(repeating: 65, count: 8191)))
        expect(.headerTooLarge) { _ = try parser.append(Data([65])) }
        XCTAssertEqual(parser.bufferedByteCount, 0)
        var huge = SearchCONNECTParser(generation: generation)
        expect(.headerTooLarge) { _ = try huge.append(Data(repeating: 65, count: 1_000_000)) }
        XCTAssertEqual(huge.bufferedByteCount, 0)
    }

    func testAppendedAndPipelinedBytesRejectedAcrossTerminatorSplits() throws {
        for extra in [Data([0]), Data("x".utf8), frame()] {
            let data = frame() + extra
            for split in (frame().count - 4)..<frame().count {
                var parser = SearchCONNECTParser(generation: generation)
                XCTAssertNil(try parser.append(Data(data.prefix(split))))
                expect(.trailingBytes) { _ = try parser.append(Data(data.dropFirst(split))) }
                expect(.trailingBytes) { _ = try parser.append(frame()) }
                XCTAssertEqual(parser.bufferedByteCount, 0)
            }
        }
        var parser = SearchCONNECTParser(generation: generation)
        XCTAssertNotNil(try parser.append(frame()))
        expect(.parserFinished) { _ = try parser.append(Data([1])) }
    }

    func testDuplicateMixedCaseHeadersAlwaysRejected() {
        for line in ["hOsT: html.duckduckgo.com:443", "pRoXy-AuThOrIzAtIoN: \(fixtureAuthorization)",
                     "User-Agent: first\r\nuSeR-aGeNt: second",
                     "Proxy-Connection: Keep-Alive\r\npRoXy-CoNnEcTiOn: Keep-Alive"] {
            expect(.invalidHeader) { _ = try parsed(frame(extra: line + "\r\n")) }
        }
    }

    func testAuthorityAndRequestLineAliasesRejected() {
        let canonical = String(decoding: frame(), as: UTF8.self)
        let aliases = ["HTML.duckduckgo.com:443", "html.duckduckgo.com.:443", "html.duckduckgo.com:0443",
                       "html.duckduckgo.com", "https://html.duckduckgo.com:443", "html.duckduckgo.com:443/",
                       "html.duckduckgo.com:443?x", "user@html.duckduckgo.com:443", "127.0.0.1:443",
                       "[::1]:443", "html%2educkduckgo.com:443", "html.duckduckgo.com:80"]
        for alias in aliases {
            let target = canonical.replacingOccurrences(of: "CONNECT html.duckduckgo.com:443", with: "CONNECT \(alias)")
            expect(.invalidHeader) { _ = try parsed(Data(target.utf8)) }
            let host = canonical.replacingOccurrences(of: "Host: html.duckduckgo.com:443", with: "Host: \(alias)")
            expect(.invalidHeader) { _ = try parsed(Data(host.utf8)) }
        }
        for line in ["connect html.duckduckgo.com:443 HTTP/1.1", "GET html.duckduckgo.com:443 HTTP/1.1",
                     "CONNECT  html.duckduckgo.com:443 HTTP/1.1", "CONNECT html.duckduckgo.com:443  HTTP/1.1",
                     "CONNECT html.duckduckgo.com:443 HTTP/1.0", "CONNECT html.duckduckgo.com:443 HTTP/2",
                     " CONNECT html.duckduckgo.com:443 HTTP/1.1", "CONNECT html.duckduckgo.com:443 HTTP/1.1 "] {
            let data = canonical.replacingOccurrences(of: "CONNECT html.duckduckgo.com:443 HTTP/1.1", with: line)
            expect(.invalidHeader) { _ = try parsed(Data(data.utf8)) }
        }
    }

    func testControlsFoldingNonASCIIAndBareNewlinesRejected() {
        for byte in (0...31).map(UInt8.init) + [UInt8(127), 128, 255] {
            if byte == 13 || byte == 10 { continue }
            var data = frame(extra: "User-Agent: ab\r\n")
            let index = data.count - 5
            data[index] = byte
            expect(.invalidHeader) { _ = try parsed(data) }
        }
        for extra in [" User-Agent: x\r\n", "\tUser-Agent: x\r\n", "User-Agent: x\r\n folded\r\n",
                      "User-Agent: x\nHost: x\r\n", "User-Agent: x\rHost: x\r\n", "User-Agent: é\r\n"] {
            expect(.invalidHeader) { _ = try parsed(frame(extra: extra)) }
        }
        let canonical = String(decoding: frame(), as: UTF8.self)
        expect(.invalidHeader) { _ = try parsed(Data(canonical.replacingOccurrences(of: "\r\n", with: "\n").utf8)) }
        var parser = SearchCONNECTParser(generation: generation)
        XCTAssertNil(try parser.append(Data("CONNECT\r".utf8)))
        expect(.invalidHeader) { _ = try parser.append(Data("X".utf8)) }
        expect(.invalidHeader) { _ = try parser.append(frame()) }
    }

    func testAmbiguousSpacingBodiesUnknownAndOptionalHeaderValuesRejected() {
        let canonical = String(decoding: frame(), as: UTF8.self)
        for host in ["Host:html.duckduckgo.com:443", "Host : html.duckduckgo.com:443",
                     "Host:  html.duckduckgo.com:443", "Host: html.duckduckgo.com:443 ",
                     "Host:\thtml.duckduckgo.com:443", ": html.duckduckgo.com:443"] {
            let data = canonical.replacingOccurrences(of: "Host: html.duckduckgo.com:443", with: host)
            expect(.invalidHeader) { _ = try parsed(Data(data.utf8)) }
        }
        for extra in ["Content-Length: 0\r\n", "Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n",
                      "Connection: Keep-Alive\r\n", "X-Foo: value\r\n", "Proxy-Connection: close\r\n",
                      "Proxy-Connection: keep-alive\r\n", "User-Agent: \r\n", "User-Agent:  x\r\n",
                      "User-Agent: x \r\n", "User-Agent : x\r\n"] {
            expect(.invalidHeader) { _ = try parsed(frame(extra: extra)) }
        }
        for missing in ["Host: html.duckduckgo.com:443\r\n", "Proxy-Authorization: \(fixtureAuthorization)\r\n"] {
            expect(.invalidHeader) { _ = try parsed(Data(canonical.replacingOccurrences(of: missing, with: "").utf8)) }
        }
    }

    func testBasicCapabilityRequiresCanonicalEncodingAndLowercaseHex() {
        for credential in ["dot:" + String(repeating: "A", count: 64), "dot:" + String(repeating: "g", count: 64),
                           "dot:" + String(repeating: "a", count: 63), "dot:" + String(repeating: "a", count: 65),
                           "Dot:" + String(repeating: "a", count: 64), "other:" + String(repeating: "a", count: 64)] {
            let auth = "Basic " + Data(credential.utf8).base64EncodedString()
            expect(.unauthorized) { _ = try parsed(frame(authorization: auth)) }
        }
        for auth in [fixtureAuthorization.lowercased(), "Bearer " + String(fixtureAuthorization.dropFirst(6)),
                     String(fixtureAuthorization.dropLast()), fixtureAuthorization + "=", "Basic !!!!",
                     fixtureAuthorization.replacingOccurrences(of: "Basic ", with: "Basic  ")] {
            expect(.unauthorized) { _ = try parsed(frame(authorization: auth)) }
        }
        // Same decoded bytes with nonzero unused base64 pad bits is an alias.
        var alias = Array(fixtureAuthorization.utf8)
        alias[alias.count - 2] += 1
        expect(.unauthorized) { _ = try parsed(frame(authorization: String(decoding: alias, as: UTF8.self))) }
    }

    func testSearchMustBeAdmittedExactlyOnce() throws {
        var value = try budget()
        expect(.searchNotAdmitted) { _ = try admit(&value) }
        XCTAssertEqual(value.authenticatedAdmissions, 0)
        try value.beginSearch(now: 100)
        expect(.searchAlreadyAdmitted) { try value.beginSearch(now: 101) }
        _ = try admit(&value, now: 101)
        XCTAssertTrue(value.searchAdmitted)
        XCTAssertEqual(value.absoluteDeadline, 200)
    }

    func testFailedAuthenticationConsumesNoAdmissionsOrBytes() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let wrong = try parsed(frame())
        for _ in 0..<100 { expect(.unauthorized) { _ = try value.admit(wrong, now: 100) } }
        XCTAssertEqual(value.authenticatedAdmissions, 0)
        XCTAssertEqual(value.upstreamBytes, 0)
        XCTAssertEqual(value.downstreamBytes, 0)
        XCTAssertNil(value.terminalFailure)
        _ = try admit(&value)
        XCTAssertEqual(value.authenticatedAdmissions, 1)
    }

    func testWrongCapabilityAtEveryHexPositionRejected() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let decoded = try XCTUnwrap(Data(base64Encoded: String(value.proxyAuthorization.dropFirst(6))))
        for index in 4..<decoded.count {
            var wrong = decoded
            wrong[index] = wrong[index] == 97 ? 98 : 97
            let request = try parsed(frame(authorization: "Basic " + wrong.base64EncodedString()))
            expect(.unauthorized) { _ = try value.admit(request, now: 100) }
        }
        XCTAssertEqual(value.authenticatedAdmissions, 0)
    }

    func testFailedConnectAndReconnectConsumeBothAdmissionsWithoutRefund() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let first = try admit(&value)
        try value.endAdmission(first) // Failed upstream connect still consumed it.
        expect(.invalidAdmission) { try value.endAdmission(first) }
        let second = try admit(&value)
        XCTAssertEqual(value.authenticatedAdmissions, 2)
        try value.endAdmission(second)
        expect(.admissionLimitExceeded) { _ = try admit(&value) }
        XCTAssertEqual(value.terminalFailure, .admissionLimitExceeded)
        expect(.admissionLimitExceeded) { try value.beginSearch(now: 100) }
        value.invalidate()
        expect(.admissionLimitExceeded) { _ = try admit(&value) }
        XCTAssertEqual(value.authenticatedAdmissions, 2)
        XCTAssertEqual(value.upstreamBytes, 0)
    }

    func testFailedAuthenticationAfterTwoAdmissionsDoesNotEndActiveRelay() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        _ = try admit(&value)
        let second = try admit(&value)
        expect(.unauthorized) { _ = try value.admit(parsed(frame()), now: 100) }
        XCTAssertNil(value.terminalFailure)
        try write(&value, admission: second, direction: .upstream, bytes: 1)
    }

    func testPartialSuccessfulAndFailedWritesAccountExactly() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let admission = try admit(&value)
        let first = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 100, now: 100)
        try value.settleWrite(first, successfulBytes: 13, now: 100)
        XCTAssertEqual(value.upstreamBytes, 13)
        XCTAssertEqual(value.pendingWriteCount, 0)
        let second = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 87, now: 100)
        try value.settleWrite(second, successfulBytes: 0, now: 100)
        XCTAssertEqual(value.upstreamBytes, 13)
        try write(&value, admission: admission, direction: .downstream, bytes: 31)
        XCTAssertEqual(value.downstreamBytes, 31)
        expect(.invalidWrite) { try value.settleWrite(first, successfulBytes: 13, now: 100) }
        XCTAssertEqual(value.upstreamBytes, 13)
    }

    func testSharedReconnectBudgetIncludesPartialWritesBeforeRetirement() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let first = try admit(&value)
        try write(&value, admission: first, direction: .upstream, bytes: 32768)
        let pending = try value.reserveWrite(first, direction: .upstream, requestedBytes: 32768, now: 100)
        try value.endAdmission(first)
        let second = try admit(&value)
        expect(.writePending) { _ = try value.reserveWrite(second, direction: .upstream, requestedBytes: 1, now: 100) }
        try value.settleWrite(pending, successfulBytes: 32760, now: 100)
        let last = try value.reserveWrite(second, direction: .upstream, requestedBytes: 32768, now: 100)
        XCTAssertEqual(last.byteCount, 8)
        try value.settleWrite(last, successfulBytes: 8, now: 100)
        XCTAssertEqual(value.upstreamBytes, 65536)
        XCTAssertEqual(value.terminalFailure, .byteLimitExceeded)
        expect(.byteLimitExceeded) { _ = try value.reserveWrite(second, direction: .downstream, requestedBytes: 1, now: 100) }
    }

    func testReservationBoundsPreventConcurrentOverspendAndStayFinite() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let first = try admit(&value)
        let second = try admit(&value)
        let a = try value.reserveWrite(first, direction: .upstream, requestedBytes: 32768, now: 100)
        let b = try value.reserveWrite(second, direction: .upstream, requestedBytes: 32768, now: 100)
        let c = try value.reserveWrite(first, direction: .downstream, requestedBytes: 32768, now: 100)
        let d = try value.reserveWrite(second, direction: .downstream, requestedBytes: 32768, now: 100)
        XCTAssertEqual(value.pendingWriteCount, 4)
        for _ in 0..<100 {
            expect(.writePending) { _ = try value.reserveWrite(first, direction: .upstream, requestedBytes: 1, now: 100) }
        }
        XCTAssertEqual(value.pendingWriteCount, 4)
        try value.settleWrite(a, successfulBytes: 100, now: 100)
        let e = try value.reserveWrite(first, direction: .upstream, requestedBytes: 32768, now: 100)
        XCTAssertEqual(e.byteCount, 32668)
        try value.settleWrite(b, successfulBytes: 32768, now: 100)
        try value.settleWrite(c, successfulBytes: 17, now: 100)
        try value.settleWrite(d, successfulBytes: 19, now: 100)
        try value.settleWrite(e, successfulBytes: 32668, now: 100)
        XCTAssertEqual(value.upstreamBytes, 65536)
        XCTAssertEqual(value.downstreamBytes, 36)
        XCTAssertEqual(value.pendingWriteCount, 0)
        XCTAssertEqual(value.terminalFailure, .byteLimitExceeded)
    }

    func testExactDownstreamCapIsSharedAcrossBothAdmissionsAndSticky() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let first = try admit(&value)
        for _ in 0..<128 { try write(&value, admission: first, direction: .downstream, bytes: 32768) }
        try value.endAdmission(first)
        let second = try admit(&value)
        for _ in 0..<127 { try write(&value, admission: second, direction: .downstream, bytes: 32768) }
        try write(&value, admission: second, direction: .downstream, bytes: 32767)
        XCTAssertNil(value.terminalFailure)
        let last = try value.reserveWrite(second, direction: .downstream, requestedBytes: 32768, now: 100)
        XCTAssertEqual(last.byteCount, 1)
        try value.settleWrite(last, successfulBytes: 1, now: 100)
        XCTAssertEqual(value.downstreamBytes, 8 * 1024 * 1024)
        XCTAssertEqual(value.upstreamBytes, 0)
        expect(.byteLimitExceeded) { _ = try value.reserveWrite(second, direction: .downstream, requestedBytes: 1, now: 100) }
        expect(.byteLimitExceeded) { _ = try admit(&value) }
        value.invalidate()
        XCTAssertEqual(value.terminalFailure, .byteLimitExceeded)
    }

    func testChunkBoundsRejectZeroNegativeAndOverflowWithoutChangingCounters() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let admission = try admit(&value)
        for count in [Int.min, -1, 0, 32769, Int.max] {
            for direction in [SearchEgressDirection.upstream, .downstream] {
                expect(.invalidWrite) { _ = try value.reserveWrite(admission, direction: direction, requestedBytes: count, now: 100) }
            }
        }
        XCTAssertEqual(value.pendingWriteCount, 0)
        XCTAssertEqual(value.upstreamBytes, 0)
        XCTAssertEqual(value.downstreamBytes, 0)
        try write(&value, admission: admission, direction: .upstream, bytes: 32768)
    }

    func testInvalidCompletionCountsFailClosedWithoutOverflow() throws {
        for count in [Int.min, -1, 11, Int.max] {
            var value = try budget()
            try value.beginSearch(now: 100)
            let admission = try admit(&value)
            let permit = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 10, now: 100)
            expect(.invalidWrite) { try value.settleWrite(permit, successfulBytes: count, now: 100) }
            XCTAssertEqual(value.upstreamBytes, 0)
            XCTAssertEqual(value.pendingWriteCount, 0)
            XCTAssertEqual(value.terminalFailure, .invalidWrite)
            expect(.invalidWrite) { _ = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 1, now: 100) }
        }
    }

    func testRetiredAdmissionsCannotWriteAndHaveNoRefund() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let admission = try admit(&value)
        try value.endAdmission(admission)
        expect(.invalidAdmission) { _ = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 1, now: 100) }
        XCTAssertEqual(value.authenticatedAdmissions, 1)
        XCTAssertNil(value.terminalFailure)
    }

    func testDeadlineAndClockInputsMustBeFiniteAndOrdered() {
        for time in [TimeInterval.nan, .infinity, -.infinity] {
            expect(.invalidTime) { _ = try budget(now: time) }
            expect(.invalidTime) { _ = try budget(deadline: time) }
        }
        expect(.invalidTime) { _ = try budget(now: -1) }
        for deadline in [TimeInterval(-1), 0, 99, 100] {
            expect(.deadlineExceeded) { _ = try budget(deadline: deadline) }
        }
    }

    func testExpiredDeadlineStickyEvenIfLaterTimeMovesBackwards() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let admission = try admit(&value, now: 199)
        XCTAssertEqual(value.absoluteDeadline, 200)
        expect(.deadlineExceeded) { try value.checkActive(now: 200) }
        expect(.deadlineExceeded) { try value.checkActive(now: 100) }
        expect(.deadlineExceeded) { _ = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 1, now: 199) }
        expect(.deadlineExceeded) { _ = try admit(&value, now: 199) }
        value.invalidate()
        XCTAssertEqual(value.terminalFailure, .deadlineExceeded)
    }

    func testInvalidObservedTimeIsSticky() throws {
        for time in [TimeInterval.nan, .infinity, -.infinity, 99] {
            var value = try budget()
            try value.beginSearch(now: 100)
            expect(.invalidTime) { try value.checkActive(now: time) }
            expect(.invalidTime) { try value.checkActive(now: 101) }
            XCTAssertEqual(value.absoluteDeadline, 200)
        }
    }

    func testInvalidationBeforeSearchAndDuringRelayIsSticky() throws {
        var unused = try budget()
        unused.invalidate()
        expect(.invalidated) { try unused.beginSearch(now: 100) }
        var value = try budget()
        try value.beginSearch(now: 100)
        let admission = try admit(&value)
        value.invalidate(); value.invalidate()
        expect(.invalidated) { _ = try admit(&value) }
        expect(.invalidated) { _ = try value.reserveWrite(admission, direction: .downstream, requestedBytes: 1, now: 100) }
        expect(.invalidated) { try value.checkActive(now: 300) }
        try value.endAdmission(admission)
        XCTAssertEqual(value.authenticatedAdmissions, 1)
    }

    func testInFlightSuccessfulBytesStillAccountAfterCancellationOrExpiry() throws {
        for cancel in [true, false] {
            var value = try budget()
            try value.beginSearch(now: 100)
            let admission = try admit(&value)
            let permit = try value.reserveWrite(admission, direction: .upstream, requestedBytes: 100, now: 100)
            if cancel { value.invalidate() }
            expect(cancel ? .invalidated : .deadlineExceeded) {
                try value.settleWrite(permit, successfulBytes: 17, now: cancel ? 100 : 200)
            }
            XCTAssertEqual(value.upstreamBytes, 17)
            XCTAssertEqual(value.pendingWriteCount, 0)
            expect(.invalidWrite) { try value.settleWrite(permit, successfulBytes: 17, now: 200) }
            XCTAssertEqual(value.upstreamBytes, 17)
        }
    }

    func testPendingOppositeDirectionCanSettleAfterByteExhaustion() throws {
        var value = try budget()
        try value.beginSearch(now: 100)
        let admission = try admit(&value)
        try write(&value, admission: admission, direction: .upstream, bytes: 32768)
        let down = try value.reserveWrite(admission, direction: .downstream, requestedBytes: 10, now: 100)
        try write(&value, admission: admission, direction: .upstream, bytes: 32768)
        expect(.byteLimitExceeded) { try value.settleWrite(down, successfulBytes: 10, now: 100) }
        XCTAssertEqual(value.upstreamBytes, 65536)
        XCTAssertEqual(value.downstreamBytes, 10)
        XCTAssertEqual(value.pendingWriteCount, 0)
    }

    func testDelayedOldGenerationCapabilityAndHandlesCannotSpendFreshBudget() throws {
        var old = try budget()
        try old.beginSearch(now: 100)
        let oldRequest = try parsed(frame(authorization: old.proxyAuthorization))
        let oldAdmission = try old.admit(oldRequest, now: 100)
        let oldPermit = try old.reserveWrite(oldAdmission, direction: .upstream, requestedBytes: 10, now: 100)
        old.invalidate()
        let newGeneration = UUID()
        var fresh = try SearchEgressBudget(generation: newGeneration, absoluteDeadline: 400, now: 200)
        try fresh.beginSearch(now: 200)
        expect(.wrongGeneration) { _ = try fresh.admit(oldRequest, now: 200) }
        // Even re-parsing delayed wire bytes under the new generation cannot
        // authenticate: its capability was minted afresh and never reset.
        let delayed = try parsed(frame(authorization: old.proxyAuthorization), generation: newGeneration)
        expect(.unauthorized) { _ = try fresh.admit(delayed, now: 200) }
        expect(.invalidated) { _ = try old.admit(oldRequest, now: 100) }
        expect(.invalidAdmission) { _ = try fresh.reserveWrite(oldAdmission, direction: .upstream, requestedBytes: 1, now: 200) }
        expect(.invalidWrite) { try fresh.settleWrite(oldPermit, successfulBytes: 10, now: 200) }
        XCTAssertEqual(fresh.authenticatedAdmissions, 0)
        XCTAssertEqual(fresh.upstreamBytes, 0)
        XCTAssertEqual(fresh.pendingWriteCount, 0)
        XCTAssertEqual(fresh.absoluteDeadline, 400)
        _ = try admit(&fresh, now: 200)
        expect(.invalidated) { try old.settleWrite(oldPermit, successfulBytes: 7, now: 200) }
        XCTAssertEqual(old.upstreamBytes, 7)
        XCTAssertEqual(fresh.upstreamBytes, 0)
    }

    func testFreshCapabilityEvenIfCallerAccidentallyReusesGenerationIdentifier() throws {
        let old = try budget()
        var fresh = try budget()
        try fresh.beginSearch(now: 100)
        let delayed = try parsed(frame(authorization: old.proxyAuthorization))
        expect(.unauthorized) { _ = try fresh.admit(delayed, now: 100) }
        XCTAssertEqual(fresh.authenticatedAdmissions, 0)
    }

    func testDescriptionsAndErrorsNeverContainCapability() throws {
        let value = try budget()
        let request = try parsed(frame(authorization: value.proxyAuthorization))
        var parser = value.makeParser()
        XCTAssertNil(try parser.append(Data(frame(authorization: value.proxyAuthorization).dropLast())))
        let credential = try XCTUnwrap(Data(base64Encoded: String(value.proxyAuthorization.dropFirst(6))))
        let secret = String(decoding: credential.dropFirst(4), as: UTF8.self)
        let errors: [SearchEgressFailure] = [.capabilityUnavailable, .invalidHeader, .headerTooLarge,
            .incompleteHeader, .trailingBytes, .parserFinished, .unauthorized, .wrongGeneration, .invalidTime,
            .deadlineExceeded, .invalidated, .searchNotAdmitted, .searchAlreadyAdmitted, .admissionLimitExceeded,
            .byteLimitExceeded, .invalidAdmission, .invalidWrite, .writePending]
        var diagnostics = [String(describing: value), String(reflecting: value), String(describing: request),
                           String(reflecting: request), String(describing: parser), String(reflecting: parser)]
        for error in errors { diagnostics += [String(describing: error), String(reflecting: error), error.localizedDescription] }
        for text in diagnostics {
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains(value.proxyAuthorization))
            XCTAssertFalse(text.contains(String(value.proxyAuthorization.dropFirst(6))))
        }
    }
}

#if DEBUG
import Darwin

/// Native Darwin tests of the actual broker and dispatch sources. No internet,
/// resolver process, provider, installed app, or production configuration seam.
final class SearchEgressSocketOwnerTests: XCTestCase {
    private enum FixtureError: Error { case socket, timeout, eof }
    private static let connected = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    /// Lock covers each nonblocking syscall and the one close. A test task never
    /// retains a numeric fd across suspension and then uses it after reuse.
    private final class FD: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32
        init(_ value: Int32) { self.value = value }
        func use<T>(_ body: (Int32) throws -> T) throws -> T {
            lock.lock(); defer { lock.unlock() }
            guard value >= 0 else { throw FixtureError.eof }
            return try body(value)
        }
        func close() {
            lock.lock(); defer { lock.unlock() }
            if value >= 0 { Darwin.close(value); value = -1 }
        }
        deinit { close() }
    }
    private actor Latch {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            opened = true; let current = waiters; waiters.removeAll()
            for waiter in current { waiter.resume() }
        }
        var released: Bool { opened }
    }
    private func address(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        return address
    }
    private func socket() throws -> FD {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.socket }
        let result = FD(fd)
        do {
            try result.use { fd in
                var one: Int32 = 1
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                      fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw FixtureError.socket
                }
            }
            return result
        } catch { result.close(); throw error }
    }
    private func listener(listening: Bool = true) throws -> (FD, UInt16) {
        let listener = try socket()
        let port = try listener.use { fd -> UInt16 in
            var local = address(0)
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, !listening || Darwin.listen(fd, 8) == 0 else { throw FixtureError.socket }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &size) }
            }
            guard result == 0 else { throw FixtureError.socket }
            return UInt16(bigEndian: local.sin_port)
        }
        return (listener, port)
    }
    private func connect(_ port: UInt16, receiveBufferBytes: Int32? = nil) async throws -> FD {
        let client = try socket()
        try client.use { fd in
            // Request a small receive window before the handshake. This changes
            // only a fixture-owned socket; actual kernel sizes are checked below.
            if var bytes = receiveBufferBytes {
                guard bytes > 0, bytes <= 32_768,
                      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw FixtureError.socket
                }
            }
            var target = address(port)
            let result = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 || errno == EINPROGRESS else { throw FixtureError.socket }
        }
        try await eventually {
            try client.use { fd in
                var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard Darwin.poll(&item, 1, 0) > 0 else { return false }
                var error: Int32 = 0, count = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &count) == 0, error == 0 else { throw FixtureError.socket }
                return true
            }
        }
        if var bytes = receiveBufferBytes {
            try client.use { fd in
                // Darwin can grow even a user-sized receive buffer by 16 MSS
                // units twice. Bound that growth on this fixture peer, then
                // restore the small requested buffer after handshake rounding.
                var maximumSegmentBytes: Int32 = 512
                guard setsockopt(fd, IPPROTO_TCP, TCP_MAXSEG, &maximumSegmentBytes, socklen_t(MemoryLayout<Int32>.size)) == 0,
                      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw FixtureError.socket
                }
            }
        }
        return client
    }
    private func accept(_ listener: FD) async throws -> FD {
        var accepted: Int32 = -1
        try await eventually {
            accepted = try listener.use { Darwin.accept($0, nil, nil) }
            return accepted >= 0
        }
        let result = FD(accepted)
        try result.use { fd in
            var one: Int32 = 1
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw FixtureError.socket
            }
        }
        return result
    }
    private func eventually(timeout: TimeInterval = 4, _ condition: () async throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while try await condition() == false {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func send(_ data: Data, to socket: FD, timeout: TimeInterval = 5) async throws {
        var offset = 0
        try await eventually(timeout: timeout) {
            guard offset < data.count else { return true }
            let count = try socket.use { fd in
                data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return false }
            guard count > 0 else { throw FixtureError.socket }
            offset += count
            return offset == data.count
        }
    }
    private func read(_ socket: FD, count: Int? = nil, timeout: TimeInterval = 5) async throws -> Data {
        var result = Data()
        try await eventually(timeout: timeout) {
            if let count, result.count == count { return true }
            var bytes = [UInt8](repeating: 0, count: min(32_768, count.map { $0 - result.count } ?? 32_768))
            let received = try socket.use { fd in bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) } }
            if received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return false }
            // A reset is also a terminal close for hostile/oversized input tests.
            if received < 0 && errno == ECONNRESET { if count != nil { throw FixtureError.eof }; return true }
            guard received >= 0 else { throw FixtureError.socket }
            if received == 0 { if count != nil { throw FixtureError.eof }; return true }
            result.append(contentsOf: bytes.prefix(received)); return false
        }
        return result
    }
    private func frame(_ authorization: String, authority: String = "html.duckduckgo.com:443") -> Data {
        Data(("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Authorization: \(authorization)\r\n\r\n").utf8)
    }
    private func broker(port: UInt16, resolve: @escaping @Sendable () async throws -> [String] = { ["8.8.8.8"] },
                        expectedPeerPort: UInt16? = nil, maximumWriteBytes: Int? = nil,
                        socketSendBufferBytes: Int32? = nil,
                        holdConnect: Bool = false, holdCloses: Bool = false,
                        invalidateBeforeConnect: Bool = false, invalidateBeforeRelayWrite: Bool = false) throws -> SearchEgressBroker {
        let owner = try SearchEgressBroker(generation: UUID(), testing: .init(resolve: resolve, loopbackPort: port,
            expectedPeerPort: expectedPeerPort, maximumWriteBytes: maximumWriteBytes,
            socketSendBufferBytes: socketSendBufferBytes,
            holdConnectCompletion: holdConnect, holdCloseReceipts: holdCloses,
            invalidateBeforeConnect: invalidateBeforeConnect, invalidateBeforeRelayWrite: invalidateBeforeRelayWrite))
        addTeardownBlock {
            await owner.testReleaseCloseReceipts()
            await owner.testReleaseConnectCompletion()
            await owner.drain()
        }
        return owner
    }
    private func tunnel(_ endpoint: SearchEgressEndpoint, server: FD,
                        receiveBufferBytes: Int32? = nil) async throws -> (FD, FD) {
        let client = try await connect(endpoint.port, receiveBufferBytes: receiveBufferBytes)
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let origin = try await accept(server)
        let reply = try await read(client, count: Self.connected.count)
        XCTAssertEqual(reply, Self.connected)
        return (client, origin)
    }

    func testListenerIsContinuouslyHeldAcrossResolutionAndArming() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let gate = Latch()
        let broker = try broker(port: port, resolve: { await gate.wait(); return ["8.8.8.8"] })
        addTeardownBlock { await gate.release() }
        let preparation = Task { try await broker.prepare() }
        try await eventually { await broker.testSnapshot().listenerDescriptor != nil }
        let before = await broker.testSnapshot()
        await gate.release()
        let endpoint = try await preparation.value
        let prepared = await broker.testSnapshot()
        XCTAssertEqual(before.listenerDescriptor, prepared.listenerDescriptor)
        XCTAssertNil(prepared.requestDeadline)
        let competitor = try socket(); defer { competitor.close() }
        let result = try competitor.use { fd -> Int32 in
            var target = address(endpoint.port)
            return withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        XCTAssertEqual(result, -1); XCTAssertEqual(errno, EADDRINUSE)
        let armTime = ProcessInfo.processInfo.systemUptime
        try await broker.beginSearch()
        let armed = await broker.testSnapshot()
        XCTAssertEqual(armed.listenerDescriptor, before.listenerDescriptor)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(armed.requestDeadline), armTime + 30)
        XCTAssertLessThan(try XCTUnwrap(armed.requestDeadline), armTime + 31)
        XCTAssertEqual(armed.resolverCalls, 1)
        do { try await broker.beginSearch(); XCTFail("Duplicate arm accepted") } catch {
            XCTAssertEqual(error as? SearchEgressFailure, .searchAlreadyAdmitted)
        }
        await broker.drain()
    }

    func testValidCapabilityCannotConnectBeforeArming() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let response = try await read(client)
        XCTAssertTrue(response.isEmpty)
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 0); XCTAssertEqual(snapshot.connectAttempts, 0)
        XCTAssertNil(snapshot.requestDeadline)
        try await broker.beginSearch()
        await broker.drain()
    }

    func testUnsafeMixedPrivateIPv6AndTooManyPinsFailBeforeEndpoint() async throws {
        for pins in [["127.0.0.1"], ["10.0.0.1"], ["8.8.8.8", "192.168.0.1"],
                     ["2606:4700:4700::1111"], ["8.8.8.8", "2606:4700:4700::1111"],
                     (1...17).map { "8.8.8.\($0)" }, []] {
            let broker = try broker(port: 1, resolve: { pins })
            do { _ = try await broker.prepare(); XCTFail("Unsafe result accepted") } catch {}
            await broker.drain()
            let snapshot = await broker.testSnapshot()
            XCTAssertTrue(snapshot.drained); XCTAssertEqual(snapshot.sockets, 0)
            XCTAssertEqual(snapshot.resolverCalls, 1); XCTAssertEqual(snapshot.connectAttempts, 0)
        }
    }

    func testDeduplicatedPinsResolveOnceAcrossBothAdmissions() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, resolve: { Array(repeating: "8.8.8.8", count: 32) })
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let (first, firstOrigin) = try await tunnel(endpoint, server: server)
        let (second, secondOrigin) = try await tunnel(endpoint, server: server)
        defer { first.close(); firstOrigin.close(); second.close(); secondOrigin.close() }
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.resolverCalls, 1); XCTAssertEqual(snapshot.connectAttempts, 2)
        XCTAssertEqual(snapshot.admissions, 2)
        await broker.drain()
    }

    func testHostileAuthorityWrongCapabilityAndOversizeAllocateNoUpstream() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let wrong = "Basic " + Data(("dot:" + String(repeating: "0", count: 64)).utf8).base64EncodedString()
        let attacks = [frame(endpoint.proxyAuthorization, authority: "127.0.0.1:443"),
                       frame(endpoint.proxyAuthorization, authority: "html.duckduckgo.com.:443"),
                       frame(wrong),
                       Data(repeating: 65, count: 8193)]
        for attack in attacks {
            let client = try await connect(endpoint.port)
            try? await send(attack, to: client)
            let response = try await read(client)
            XCTAssertTrue(response.isEmpty); client.close()
        }
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.connectAttempts, 0); XCTAssertEqual(snapshot.admissions, 0)
        XCTAssertEqual(snapshot.upstreamBytes, 0); XCTAssertEqual(snapshot.downstreamBytes, 0)
        await broker.drain()
    }

    func testOldGenerationCapabilityFailsAtFreshActualListener() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let old = try broker(port: port)
        let oldEndpoint = try await old.prepare(); try await old.beginSearch(); await old.drain()
        let fresh = try broker(port: port)
        let endpoint = try await fresh.prepare(); try await fresh.beginSearch()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(oldEndpoint.proxyAuthorization), to: client)
        let response = try await read(client)
        XCTAssertTrue(response.isEmpty)
        let snapshot = await fresh.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 0); XCTAssertEqual(snapshot.connectAttempts, 0)
        await fresh.drain()
    }

    func testFourUnauthenticatedSlotsExpireAndFifthCannotAllocateOne() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        var clients: [FD] = []
        for _ in 0..<4 { clients.append(try await connect(endpoint.port)) }
        defer { for client in clients { client.close() } }
        try await eventually { await broker.testSnapshot().headers == 4 }
        let fifth = try await connect(endpoint.port); defer { fifth.close() }
        let response = try await read(fifth, timeout: 1)
        XCTAssertTrue(response.isEmpty)
        try await eventually(timeout: 3) { await broker.testSnapshot().headers == 0 }
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 0); XCTAssertEqual(snapshot.connectAttempts, 0)
        await broker.drain()
    }

    func testConnectedPeerMismatchCannotSend200() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let expected: UInt16 = port == 65_535 ? 1 : port + 1
        let broker = try broker(port: port, expectedPeerPort: expected)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let origin = try await accept(server); defer { origin.close() }
        let response = try await read(client)
        XCTAssertTrue(response.isEmpty)
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 1); XCTAssertEqual(snapshot.upstreamBytes, 0)
        await broker.drain()
    }

    func testFailedConnectsSpendBothAdmissionsAndThirdInvalidatesGeneration() async throws {
        let (server, port) = try listener(listening: false); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        for attempt in 1...2 {
            let client = try await connect(endpoint.port); defer { client.close() }
            try await send(frame(endpoint.proxyAuthorization), to: client)
            // A bound, non-listening Darwin target can use the full connect
            // deadline. The fixture must allow its timer and close receipts to
            // finish rather than race them with an identical five-second wait.
            let response: Data
            do { response = try await read(client, timeout: SearchEgressBroker.connectSeconds + 2) }
            catch {
                let failed = await broker.testSnapshot()
                XCTFail("Failed-connect close missing: attempt=\(attempt), admissions=\(failed.admissions), connects=\(failed.connectAttempts), phases=\(failed.tunnelPhases), sockets=\(failed.sockets), closes=\(failed.actualCloses), pending=\(failed.pendingWrites), drained=\(failed.drained)")
                throw error
            }
            XCTAssertTrue(response.isEmpty)
            try await eventually { await broker.testSnapshot().actualCloses == attempt * 2 }
            let failed = await broker.testSnapshot()
            XCTAssertEqual(failed.admissions, attempt); XCTAssertEqual(failed.connectAttempts, attempt)
            XCTAssertEqual(failed.sockets, 1); XCTAssertEqual(failed.pendingWrites, 0)
            XCTAssertEqual(failed.upstreamBytes, 0); XCTAssertEqual(failed.downstreamBytes, 0)
            XCTAssertFalse(failed.drained)
        }
        let third = try await connect(endpoint.port); defer { third.close() }
        try await send(frame(endpoint.proxyAuthorization), to: third)
        let response = try await read(third)
        XCTAssertTrue(response.isEmpty)
        // Observe the third admission terminating the generation BEFORE drain(),
        // which would itself invalidate it and conceal a missing terminal path.
        try await eventually { await broker.testSnapshot().drained }
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 2); XCTAssertEqual(snapshot.connectAttempts, 2)
        XCTAssertEqual(snapshot.upstreamBytes, 0); XCTAssertEqual(snapshot.downstreamBytes, 0)
        XCTAssertEqual(snapshot.pendingWrites, 0); XCTAssertEqual(snapshot.sockets, 0)
        XCTAssertEqual(snapshot.actualCloses, 6); XCTAssertTrue(snapshot.drained)
        await broker.drain()
        let drained = await broker.testSnapshot()
        XCTAssertEqual(drained.actualCloses, 6)
    }

    func testRealHalfClosesFlushBothDirectionsWithoutCredentialForwarding() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, maximumWriteBytes: 7)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let (client, origin) = try await tunnel(endpoint, server: server)
        defer { client.close(); origin.close() }
        let upload = Data((0..<101).map { UInt8($0) }), download = Data(repeating: 240, count: 113)
        try await send(upload, to: client)
        _ = try client.use { Darwin.shutdown($0, SHUT_WR) }
        let originData = try await read(origin)
        XCTAssertEqual(originData, upload) // CONNECT/auth never reaches the origin.
        try await send(download, to: origin)
        _ = try origin.use { Darwin.shutdown($0, SHUT_WR) }
        let clientData = try await read(client)
        XCTAssertEqual(clientData, download)
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.upstreamBytes, upload.count); XCTAssertEqual(snapshot.downstreamBytes, download.count)
        XCTAssertEqual(snapshot.pendingWrites, 0)
        await broker.drain()
    }

    func testSharedPartialWriteBudgetAcrossTwoActualTunnels() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, maximumWriteBytes: 31)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        for size in [333, 777] {
            let (client, origin) = try await tunnel(endpoint, server: server)
            let payload = Data(repeating: UInt8(size % 255), count: size)
            try await send(payload, to: client)
            let received = try await read(origin, count: size)
            XCTAssertEqual(received, payload)
            try await send(payload, to: origin)
            let returned = try await read(client, count: size)
            XCTAssertEqual(returned, payload)
            client.close(); origin.close()
        }
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.upstreamBytes, 1110); XCTAssertEqual(snapshot.downstreamBytes, 1110)
        XCTAssertEqual(snapshot.pendingWrites, 0); XCTAssertEqual(snapshot.admissions, 2)
        await broker.drain()
    }

    func testShortOSWritesSettleExactPermitsUnderRealBackpressure() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, socketSendBufferBytes: 8192)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let (client, origin) = try await tunnel(endpoint, server: server, receiveBufferBytes: 4096)
        defer { client.close(); origin.close() }
        func peerOption(_ level: Int32, _ option: Int32) throws -> Int32 {
            try client.use { fd in
                var value: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, level, option, &value, &size) == 0 else { throw FixtureError.socket }
                return value
            }
        }
        let receiveBufferBytes = try peerOption(SOL_SOCKET, SO_RCVBUF)
        let maximumSegmentBytes = try peerOption(IPPROTO_TCP, TCP_MAXSEG)
        XCTAssertEqual(maximumSegmentBytes, 512)
        let initial = await broker.testSnapshot()
        let sendBufferBytes = try XCTUnwrap(initial.clientSendBufferBytes.first)
        XCTAssertEqual(initial.clientSendBufferBytes.count, 1)
        XCTAssertGreaterThan(receiveBufferBytes, 0); XCTAssertGreaterThan(sendBufferBytes, 0)
        // Downstream has enough room under its existing 8 MiB cap to exhaust
        // both TCP buffers. A 65,535-byte upload could fit the old receive window.
        let payload = Data((0..<524_287).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8) ^ ($0 >> 16)) })
        XCTAssertLessThan(payload.count, SearchEgressBudget.maximumDownstreamBytes)
        XCTAssertLessThan(Int(receiveBufferBytes) + Int(sendBufferBytes), payload.count)
        let writer = Task { try await self.send(payload, to: origin, timeout: 15) }
        defer { writer.cancel() }
        // Keep the real receiving peer unread until a real Darwin.send result
        // proves a short write. No maximumWriteBytes seam or simulated receipt.
        do { try await eventually { await broker.testSnapshot().partialWrites > 0 } }
        catch {
            let stalled = await broker.testSnapshot()
            let currentReceiveBuffer = try? peerOption(SOL_SOCKET, SO_RCVBUF)
            XCTFail("No short OS write before reading: SO_SNDBUF=\(sendBufferBytes), currentSNDBUF=\(stalled.clientSendBufferBytes), SO_RCVBUF=\(receiveBufferBytes), currentRCVBUF=\(currentReceiveBuffer ?? -1), TCP_MAXSEG=\(maximumSegmentBytes), payload=\(payload.count), downstream=\(stalled.downstreamBytes), partial=\(stalled.partialWrites), wouldBlock=\(stalled.wouldBlockWrites), pending=\(stalled.pendingWrites), phases=\(stalled.tunnelPhases), sockets=\(stalled.sockets), closes=\(stalled.actualCloses), drained=\(stalled.drained)")
            throw error
        }
        let pressured = await broker.testSnapshot()
        XCTAssertGreaterThan(pressured.downstreamBytes, 0)
        XCTAssertLessThan(pressured.downstreamBytes, payload.count)
        XCTAssertEqual(pressured.pendingWrites, 0)
        let received: Data
        do {
            received = try await read(client, count: payload.count, timeout: 15)
            try await writer.value
        } catch {
            let failed = await broker.testSnapshot()
            let currentReceiveBuffer = try? peerOption(SOL_SOCKET, SO_RCVBUF)
            XCTFail("Backpressured transfer failed: SO_SNDBUF=\(failed.clientSendBufferBytes), SO_RCVBUF=\(currentReceiveBuffer ?? -1), TCP_MAXSEG=\(maximumSegmentBytes), downstream=\(failed.downstreamBytes), partial=\(failed.partialWrites), wouldBlock=\(failed.wouldBlockWrites), pending=\(failed.pendingWrites), phases=\(failed.tunnelPhases), sockets=\(failed.sockets), closes=\(failed.actualCloses), drained=\(failed.drained)")
            throw error
        }
        XCTAssertEqual(received, payload)
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.upstreamBytes, 0); XCTAssertEqual(snapshot.downstreamBytes, payload.count)
        XCTAssertEqual(snapshot.pendingWrites, 0)
        XCTAssertGreaterThan(snapshot.partialWrites, 0, "SO_SNDBUF=\(sendBufferBytes), SO_RCVBUF=\(receiveBufferBytes), downstream=\(snapshot.downstreamBytes), wouldBlock=\(snapshot.wouldBlockWrites)")
        await broker.drain()
        let drained = await broker.testSnapshot()
        XCTAssertEqual(drained.downstreamBytes, payload.count); XCTAssertEqual(drained.pendingWrites, 0)
        XCTAssertEqual(drained.actualCloses, 3); XCTAssertEqual(drained.sockets, 0); XCTAssertTrue(drained.drained)
        print("Search short-write receipt: SO_SNDBUF=\(sendBufferBytes), SO_RCVBUF=\(receiveBufferBytes), TCP_MAXSEG=\(maximumSegmentBytes), payload=\(payload.count), downstream=\(drained.downstreamBytes), partial=\(drained.partialWrites), wouldBlock=\(drained.wouldBlockWrites), pending=\(drained.pendingWrites), closes=\(drained.actualCloses)")
    }

    func testEarlyPayloadWhileConnectingNeverReceives200() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, holdConnect: true)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let origin = try await accept(server); defer { origin.close() }
        try await send(Data([1]), to: client)
        let response = try await read(client)
        XCTAssertTrue(response.isEmpty)
        await broker.testReleaseConnectCompletion()
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.upstreamBytes, 0); XCTAssertEqual(snapshot.downstreamBytes, 0)
        await broker.drain()
    }

    func testActualUpstreamCapStopsAtExactly64KiB() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let (client, origin) = try await tunnel(endpoint, server: server)
        defer { client.close(); origin.close() }
        let writer = Task { try? await self.send(Data(repeating: 65, count: 65_537), to: client) }
        let received = try await read(origin)
        await writer.value
        XCTAssertEqual(received.count, 65_536)
        await broker.drain()
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.upstreamBytes, 65_536); XCTAssertEqual(snapshot.pendingWrites, 0)
        XCTAssertTrue(snapshot.drained)
    }

    func testActualDownstreamCapStopsAtExactly8MiB() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let (client, origin) = try await tunnel(endpoint, server: server)
        defer { client.close(); origin.close() }
        let writer = Task { try? await self.send(Data(repeating: 66, count: 8 * 1024 * 1024 + 1), to: origin, timeout: 20) }
        let received = try await read(client, timeout: 20)
        await writer.value
        XCTAssertEqual(received.count, 8 * 1024 * 1024)
        await broker.drain()
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.downstreamBytes, 8 * 1024 * 1024); XCTAssertEqual(snapshot.pendingWrites, 0)
    }

    func testCancelBeforePreparationCreatesNoResources() async throws {
        let broker = try broker(port: 1)
        broker.invalidate()
        do { _ = try await broker.prepare(); XCTFail("Prepared invalid generation") } catch {}
        await broker.drain()
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.resolverCalls, 0); XCTAssertEqual(snapshot.actualCloses, 0)
        XCTAssertTrue(snapshot.drained)
    }

    func testCancelledPreparationWaitsForCancellationResistantResolverReturn() async throws {
        let gate = Latch(), drained = Latch(), returned = Latch()
        let broker = try broker(port: 1, resolve: { await gate.wait(); return ["8.8.8.8"] })
        addTeardownBlock { await gate.release() }
        let preparation = Task { do { _ = try await broker.prepare() } catch {}; await returned.release() }
        try await eventually { await broker.testSnapshot().resolverCalls == 1 }
        preparation.cancel()
        let drain = Task { await broker.drain(); await drained.release() }
        drain.cancel() // A cancelled drain consumer still waits for the real receipt.
        try await eventually { await broker.testSnapshot().sockets == 0 }
        let before = await broker.testSnapshot()
        let prematureDrain = await drained.released, prematurePrepare = await returned.released
        XCTAssertFalse(before.drained); XCTAssertFalse(prematureDrain); XCTAssertFalse(prematurePrepare)
        await gate.release()
        await preparation.value; await drain.value
        let after = await broker.testSnapshot()
        XCTAssertTrue(after.drained); XCTAssertEqual(after.sockets, 0)
    }

    func testInvalidationAfterAuthenticationBeforeConnectStartsNoUpstream() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, invalidateBeforeConnect: true)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let response = try await read(client)
        XCTAssertTrue(response.isEmpty)
        await broker.drain()
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 1) // Authentication already happened.
        XCTAssertEqual(snapshot.connectAttempts, 0)
        XCTAssertEqual(snapshot.actualCloses, 3) // Includes never-resumed upstream sources.
        XCTAssertEqual(snapshot.sockets, 0); XCTAssertTrue(snapshot.drained)
        // Check the actual origin listener, not only an instrumentation counter.
        let (accepted, savedErrno) = try server.use { fd -> (Int32, Int32) in
            let accepted = Darwin.accept(fd, nil, nil)
            return (accepted, errno)
        }
        if accepted >= 0 { Darwin.close(accepted) }
        XCTAssertEqual(accepted, -1)
        XCTAssertTrue(savedErrno == EAGAIN || savedErrno == EWOULDBLOCK)
    }

    func testInvalidationAfterReservationBeforeSendSettlesZeroActualBytes() async throws {
        for uploading in [true, false] {
            let (server, port) = try listener(); defer { server.close() }
            let broker = try broker(port: port, invalidateBeforeRelayWrite: true)
            let endpoint = try await broker.prepare(); try await broker.beginSearch()
            let (client, origin) = try await tunnel(endpoint, server: server)
            defer { client.close(); origin.close() }
            try await send(Data([71]), to: uploading ? client : origin)
            let received = try await read(uploading ? origin : client)
            XCTAssertTrue(received.isEmpty) // The real peer received no relay bytes.
            await broker.drain()
            let snapshot = await broker.testSnapshot()
            XCTAssertEqual(snapshot.connectAttempts, 1)
            XCTAssertEqual(snapshot.upstreamBytes, 0); XCTAssertEqual(snapshot.downstreamBytes, 0)
            XCTAssertEqual(snapshot.pendingWrites, 0)
            XCTAssertEqual(snapshot.actualCloses, 3); XCTAssertTrue(snapshot.drained)
        }
    }

    func testCancelDuringConnectDoesNotAcceptLateWritableCallback() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, holdConnect: true)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let origin = try await accept(server); defer { origin.close() }
        try await eventually { await broker.testSnapshot().connectAttempts == 1 }
        broker.invalidate(); await broker.drain()
        await broker.testReleaseConnectCompletion()
        let response = try await read(client)
        XCTAssertTrue(response.isEmpty)
        let snapshot = await broker.testSnapshot()
        XCTAssertTrue(snapshot.drained); XCTAssertEqual(snapshot.upstreamBytes, 0)
        XCTAssertEqual(snapshot.sockets, 0)
    }

    func testConnectTimeoutRetiresSourcesWithoutRefundingAdmission() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, holdConnect: true)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let client = try await connect(endpoint.port); defer { client.close() }
        try await send(frame(endpoint.proxyAuthorization), to: client)
        let origin = try await accept(server); defer { origin.close() }
        let response = try await read(client, timeout: 7)
        XCTAssertTrue(response.isEmpty)
        let snapshot = await broker.testSnapshot()
        XCTAssertEqual(snapshot.admissions, 1); XCTAssertEqual(snapshot.upstreamBytes, 0)
        await broker.testReleaseConnectCompletion(); await broker.drain()
    }

    func testCancelDuringBackpressuredPumpSettlesActualWrites() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port, maximumWriteBytes: 127)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let (client, origin) = try await tunnel(endpoint, server: server)
        defer { client.close(); origin.close() }
        let writer = Task { try? await self.send(Data(repeating: 90, count: 1_048_576), to: origin) }
        try await eventually { await broker.testSnapshot().downstreamBytes > 0 }
        broker.invalidate(); broker.invalidate()
        await broker.drain(); await writer.value
        let snapshot = await broker.testSnapshot()
        XCTAssertTrue(snapshot.drained); XCTAssertEqual(snapshot.pendingWrites, 0)
        XCTAssertGreaterThan(snapshot.downstreamBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.downstreamBytes, 8 * 1024 * 1024)
        XCTAssertEqual(snapshot.sockets, 0)
    }

    func testRepeatedStopAndCancelledDrainWaitForDelayedActualCloseReceipts() async throws {
        let drained = Latch()
        let broker = try broker(port: 1, holdCloses: true)
        _ = try await broker.prepare()
        broker.invalidate(); broker.invalidate()
        let drain = Task { await broker.drain(); await drained.release() }
        drain.cancel()
        try await eventually { await broker.testSnapshot().deferredCloseReceipts == 1 }
        let before = await broker.testSnapshot(), premature = await drained.released
        XCTAssertEqual(before.actualCloses, 1); XCTAssertFalse(before.drained); XCTAssertFalse(premature)
        await broker.testReleaseCloseReceipts(); await drain.value
        await broker.drain(); broker.invalidate()
        let after = await broker.testSnapshot()
        XCTAssertTrue(after.drained); XCTAssertEqual(after.actualCloses, 1)
    }

    func testDelayedCloseReceiptCannotCloseReusedDescriptor() async throws {
        let broker = try broker(port: 1, holdCloses: true)
        _ = try await broker.prepare()
        let before = await broker.testSnapshot()
        let old = try XCTUnwrap(before.listenerDescriptor)
        broker.invalidate()
        try await eventually { await broker.testSnapshot().deferredCloseReceipts == 1 }
        // Reuse only by the OS allocator; never dup2 over an unrelated live fd.
        var replacements: [FD] = []
        var replacement: FD?
        for _ in 0..<16 {
            let candidate = try socket(); replacements.append(candidate)
            if try candidate.use({ $0 == old }) { replacement = candidate; break }
        }
        defer { for candidate in replacements { candidate.close() } }
        guard let replacement else {
            await broker.testReleaseCloseReceipts(); await broker.drain()
            throw XCTSkip("OS did not reuse the closed descriptor in this run")
        }
        await broker.testReleaseCloseReceipts(); await broker.drain()
        let descriptorFlags = try replacement.use { fcntl($0, F_GETFD) }
        XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
        let after = await broker.testSnapshot()
        XCTAssertEqual(after.actualCloses, 1); XCTAssertTrue(after.drained)
    }

    func testPreparationExpiresBeforeArmAndLateHelperReadinessCannotRearm() async throws {
        let broker = try broker(port: 1)
        _ = try await broker.prepare()
        // Real production timer and real 35-second startup bound, not a fake clock.
        try await eventually(timeout: 38) { await broker.testSnapshot().drained }
        do { try await broker.beginSearch(); XCTFail("Late readiness armed expired owner") } catch {}
        let snapshot = await broker.testSnapshot()
        XCTAssertNil(snapshot.requestDeadline); XCTAssertEqual(snapshot.connectAttempts, 0)
        XCTAssertTrue(snapshot.drained)
        await broker.drain()
    }

    func testRequestDeadlineExpiresIdleRelayAndNeverRenews() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let broker = try broker(port: port)
        let endpoint = try await broker.prepare(); try await broker.beginSearch()
        let before = await broker.testSnapshot()
        let (client, origin) = try await tunnel(endpoint, server: server)
        defer { client.close(); origin.close() }
        let response = try await read(client, timeout: 33)
        XCTAssertTrue(response.isEmpty)
        await broker.drain()
        let after = await broker.testSnapshot()
        XCTAssertEqual(after.requestDeadline, before.requestDeadline); XCTAssertTrue(after.drained)
        do { try await broker.beginSearch(); XCTFail("Expired request rearmed") } catch {}
    }

    func testEndpointDescriptionsDoNotExposePrivateCapability() async throws {
        let broker = try broker(port: 1)
        let endpoint = try await broker.prepare()
        for description in [String(describing: endpoint), String(reflecting: endpoint)] {
            XCTAssertFalse(description.contains(endpoint.proxyAuthorization))
            XCTAssertFalse(description.contains(String(endpoint.proxyAuthorization.dropFirst(6))))
        }
        await broker.drain()
    }
}
#endif

// Review supplement only. Append to the exact frozen SearchEgressBrokerTests.swift
// in an isolated native verification overlay; no frozen author files are changed.
// UNRUN: requires macOS/Darwin and Swift/XCTest.
#if DEBUG
extension SearchEgressSocketOwnerTests {
    private actor LifecycleCompletionCount {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private final class WeakLifecycleOwner {
        weak var value: SearchEgressBroker?
        init(_ owner: SearchEgressBroker) { value = owner }
    }

    func testLifecycleConcurrentArmHasExactlyOneWinnerAndOneDeadline() async throws {
        let owner = try broker(port: 1)
        _ = try await owner.prepare()
        let started = ProcessInfo.processInfo.systemUptime
        let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    do { try await owner.beginSearch(); return 0 }
                    catch { return (error as? SearchEgressFailure) == .searchAlreadyAdmitted ? 1 : 2 }
                }
            }
            var values: [Int] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(results.filter { $0 == 1 }.count, 63)
        XCTAssertFalse(results.contains(2))
        let armed = await owner.testSnapshot()
        let deadline = try XCTUnwrap(armed.requestDeadline)
        XCTAssertGreaterThanOrEqual(deadline, started + SearchEgressBroker.searchSeconds)
        XCTAssertLessThan(deadline, started + SearchEgressBroker.searchSeconds + 2)
        await owner.drain()
        let finished = await owner.testSnapshot()
        XCTAssertEqual(finished.requestDeadline, deadline)
        XCTAssertTrue(finished.drained)
    }

    func testLifecycleConcurrentCancelledDrainsWaitForAllFiveCloseReceipts() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let owner = try broker(port: port, holdCloses: true)
        let endpoint = try await owner.prepare(); try await owner.beginSearch()
        let (first, firstOrigin) = try await tunnel(endpoint, server: server)
        let (second, secondOrigin) = try await tunnel(endpoint, server: server)
        defer { first.close(); firstOrigin.close(); second.close(); secondOrigin.close() }
        let initial = await owner.testSnapshot()
        XCTAssertEqual(initial.sockets, 5)
        let completions = LifecycleCompletionCount()
        let consumers = (0..<64).map { index -> Task<Void, Never> in
            let task = Task { await owner.drain(); await completions.increment() }
            if index.isMultiple(of: 2) { task.cancel() }
            return task
        }
        owner.invalidate(); owner.invalidate()
        try await eventually { await owner.testSnapshot().deferredCloseReceipts == 5 }
        let held = await owner.testSnapshot()
        let completedBeforeRelease = await completions.value
        XCTAssertEqual(held.actualCloses, 5)
        XCTAssertEqual(held.sockets, 5)
        XCTAssertFalse(held.drained)
        XCTAssertEqual(completedBeforeRelease, 0)
        await owner.testReleaseCloseReceipts()
        for consumer in consumers { await consumer.value }
        let done = await owner.testSnapshot()
        let completedAfterRelease = await completions.value
        XCTAssertEqual(completedAfterRelease, 64)
        XCTAssertEqual(done.actualCloses, 5)
        XCTAssertEqual(done.sockets, 0)
        XCTAssertEqual(done.pendingWrites, 0)
        XCTAssertTrue(done.drained)
        let firstReply = try await read(first), secondReply = try await read(second)
        XCTAssertTrue(firstReply.isEmpty); XCTAssertTrue(secondReply.isEmpty)
    }

    private func lifecycleMakeDrainedOwner(port: UInt16, server: FD) async throws -> WeakLifecycleOwner {
        // Deliberately bypass broker(), whose XCTest teardown block retains owner.
        let owner = try SearchEgressBroker(generation: UUID(), testing: .init(resolve: { ["8.8.8.8"] }, loopbackPort: port))
        let reference = WeakLifecycleOwner(owner)
        do {
            let endpoint = try await owner.prepare(); try await owner.beginSearch()
            let (client, origin) = try await tunnel(endpoint, server: server)
            defer { client.close(); origin.close() }
            try await send(Data([31, 32, 33]), to: client)
            let received = try await read(origin, count: 3)
            XCTAssertEqual(received, Data([31, 32, 33]))
            await owner.drain()
            let done = await owner.testSnapshot()
            XCTAssertTrue(done.drained); XCTAssertEqual(done.actualCloses, 3)
            return reference
        } catch {
            await owner.drain()
            throw error
        }
    }

    func testLifecycleOwnerReleasesAfterRealTunnelDrain() async throws {
        let (server, port) = try listener(); defer { server.close() }
        let reference = try await lifecycleMakeDrainedOwner(port: port, server: server)
        try await eventually { reference.value == nil }
    }

    private func lifecycleMakeCancelledPreparation(gate: Latch, returned: Latch) async throws
        -> (WeakLifecycleOwner, Task<Void, Never>) {
        let owner = try SearchEgressBroker(generation: UUID(), testing: .init(
            resolve: { await gate.wait(); return ["8.8.8.8"] }, loopbackPort: 1))
        let reference = WeakLifecycleOwner(owner)
        let preparation = Task {
            do { _ = try await owner.prepare(); XCTFail("Cancelled preparation returned an endpoint") }
            catch {}
            await returned.release()
        }
        do {
            try await eventually { await owner.testSnapshot().resolverCalls == 1 }
            preparation.cancel()
            try await eventually { await owner.testSnapshot().sockets == 0 }
            return (reference, preparation)
        } catch {
            await gate.release()
            preparation.cancel()
            await preparation.value
            await owner.drain()
            throw error
        }
    }

    func testLifecycleOwnerSurvivesLateResolverAndReleasesAfterActualReturn() async throws {
        let gate = Latch(), returned = Latch()
        addTeardownBlock { await gate.release() }
        let (reference, preparation) = try await lifecycleMakeCancelledPreparation(gate: gate, returned: returned)
        XCTAssertNotNil(reference.value)
        let premature = await returned.released
        XCTAssertFalse(premature)
        await gate.release()
        await preparation.value
        let didReturn = await returned.released
        XCTAssertTrue(didReturn)
        try await eventually { reference.value == nil }
    }
}
#endif
