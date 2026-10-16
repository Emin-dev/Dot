import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

/// The ready line is the whole trust boundary between this app and the bundled
/// `dot-search` runtime: exactly one ASCII JSON object, no aliases, no adopted
/// ports, no capability other than the 64-character lowercase hex that runtime
/// generates. These cases are the decoder contract; process and transport behavior
/// lives with the provider's own tests.
final class SearchRuntimeTests: XCTestCase {
    private let generation = UUID(uuidString: "2A123456-1234-4567-8123-123456789ABC")!
    private var capability: String { String(repeating: "a", count: 64) }
    private func event(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["protocol": 1, "event": "ready", "generation": generation.uuidString,
            "endpoint": "http://127.0.0.1:30123/search", "capability": capability, "helper_pid": 700, "server_pid": 701]
        changes.forEach { object[$0.key] = $0.value }
        // Control protocol intentionally forbids escaped URL spelling.
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])
    }
    func testExactReadyReceipt() throws {
        let value = try SearchControlEvent.decode(event(), generation: generation, ownedPID: 700)
        XCTAssertEqual(value, .ready(.init(generation: generation, port: 30123, capability: capability, helperPID: 700, serverPID: 701)))
    }
    /// The shipped Rust runtime serializes `ReadyEvent` in declaration order; this is
    /// that exact line, including the `helper_pid`/`server_pid` pair it reports.
    func testShippedRuntimeReadyLineDecodes() throws {
        let line = Data(("{\"protocol\":1,\"event\":\"ready\",\"generation\":\"\(generation.uuidString)\","
            + "\"endpoint\":\"http://127.0.0.1:51234/search\",\"capability\":\"\(capability)\","
            + "\"helper_pid\":700,\"server_pid\":701}").utf8)
        XCTAssertEqual(try SearchControlEvent.decode(line, generation: generation, ownedPID: 700),
                       .ready(.init(generation: generation, port: 51234, capability: capability,
                                    helperPID: 700, serverPID: 701)))
    }
    func testWrongProcessOrGenerationRejected() throws {
        XCTAssertThrowsError(try SearchControlEvent.decode(event(), generation: generation, ownedPID: 702))
        XCTAssertThrowsError(try SearchControlEvent.decode(event(), generation: UUID(), ownedPID: 700))
        for pid in [0, -1, 700, Int(Int32.max) + 1] {
            XCTAssertThrowsError(try SearchControlEvent.decode(event(["server_pid": pid]), generation: generation, ownedPID: 700))
        }
    }
    func testNoPortAdoptionOrEndpointAliases() throws {
        for url in ["http://localhost:30123/search", "http://127.0.0.1:030123/search", "http://127.0.0.1:0/search",
                    "http://127.0.0.1:65536/search", "https://127.0.0.1:30123/search", "http://[::1]:30123/search",
                    "http://127.0.0.1:30123/search?x=1", "http://127.0.0.1:30123/search#x",
                    "http://user@127.0.0.1:30123/search", "http://127.0.0.1:30123//search",
                    "http://127.0.0.1:30123/%73earch", "http://127.0.0.1:30123/search/"] {
            XCTAssertThrowsError(try SearchControlEvent.decode(event(["endpoint": url]), generation: generation, ownedPID: 700), url)
        }
    }
    func testCapabilityIsExactLowercaseHex() throws {
        for value in [String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                      String(repeating: "a", count: 63), String(repeating: "a", count: 65), "token"] {
            XCTAssertThrowsError(try SearchControlEvent.decode(event(["capability": value]), generation: generation, ownedPID: 700))
        }
    }
    func testDuplicateKeysBooleansFloatsAndAdditionalFieldsRejected() throws {
        var text = String(decoding: try event(), as: UTF8.self)
        text = "{\"protocol\":1," + text.dropFirst()
        XCTAssertThrowsError(try SearchControlEvent.decode(Data(text.utf8), generation: generation, ownedPID: 700))
        for value in [true, 1.5, "1", NSNull()] as [Any] {
            XCTAssertThrowsError(try SearchControlEvent.decode(event(["protocol": value]), generation: generation, ownedPID: 700))
        }
        XCTAssertThrowsError(try SearchControlEvent.decode(event(["arbitrary": "ignored?"]), generation: generation, ownedPID: 700))
        XCTAssertThrowsError(try SearchControlEvent.decode(Data(repeating: 32, count: 2048), generation: generation, ownedPID: 700))
    }
    func testFixedFailureAndStoppedOnly() throws {
        let stopped = Data("{\"protocol\":1,\"event\":\"stopped\",\"generation\":\"\(generation.uuidString)\"}".utf8)
        XCTAssertEqual(try SearchControlEvent.decode(stopped, generation: generation, ownedPID: 700), .stopped(generation))
        let failure = Data("{\"protocol\":1,\"event\":\"failed\",\"reason\":\"native_boundary_failed\"}".utf8)
        XCTAssertEqual(try SearchControlEvent.decode(failure, generation: generation, ownedPID: 700), .failed)
        let arbitrary = Data("{\"protocol\":1,\"event\":\"failed\",\"reason\":\"secret query exception\"}".utf8)
        XCTAssertThrowsError(try SearchControlEvent.decode(arbitrary, generation: generation, ownedPID: 700))
    }
}
