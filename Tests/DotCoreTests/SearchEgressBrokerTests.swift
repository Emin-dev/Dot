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
        return try XCTUnwrap(parser.append(data))
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
