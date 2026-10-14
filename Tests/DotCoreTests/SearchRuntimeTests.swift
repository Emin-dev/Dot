import Foundation
import XCTest
import CryptoKit
#if os(macOS)
import Darwin
#endif
#if SWIFT_PACKAGE
@testable import DotCore
#endif

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
    func testCancellationLeaseRevokesAndRunsCallbacksExactlyOnce() {
        let lease = SearchGenerationLease()
        let counter = LockedCounter()
        let removed = lease.register { counter.increment(100) }
        lease.unregister(removed)
        _ = lease.register { counter.increment(1) }
        XCTAssertTrue(lease.isValid)
        lease.invalidate(); lease.invalidate()
        XCTAssertFalse(lease.isValid)
        _ = lease.register { counter.increment(10) }
        XCTAssertEqual(counter.value, 11)
    }
    func testCancellationFromBackgroundIsSynchronous() async {
        let lease = SearchGenerationLease()
        let counter = LockedCounter()
        _ = lease.register { counter.increment(1) }
        await Task.detached { lease.invalidate(); XCTAssertFalse(lease.isValid); XCTAssertEqual(counter.value, 1) }.value
    }
    func testInvalidatedLeaseRevokesLateRegistrationSynchronously() {
        let lease = SearchGenerationLease()
        let counter = LockedCounter()
        lease.invalidate()
        _ = lease.register { counter.increment(1) }
        XCTAssertEqual(counter.value, 1)
        XCTAssertFalse(lease.isValid)
    }
    func testCancellationCallbackCanInspectAndUnregisterLease() {
        let lease = SearchGenerationLease()
        let counter = LockedCounter()
        let removed = lease.register { counter.increment(100) }
        lease.unregister(removed)
        _ = lease.register {
            XCTAssertFalse(lease.isValid)
            lease.unregister(removed)
            counter.increment(1)
        }
        lease.invalidate()
        XCTAssertEqual(counter.value, 1)
    }
    func testRelativePathsRejectTraversalControlsAndAliases() {
        for path in ["", "/python/bin/python3", "../escape", "python//bin", "python/./bin", "python/../other", "python\\bin", "evidence/x\tother"] {
            XCTAssertFalse(SearchPayloadAudit.validRelativePath(path), path)
        }
        XCTAssertTrue(SearchPayloadAudit.validRelativePath("python/bin/python3"))
    }
    func testPayloadDigestUsesExactSortedArtifactEntries() {
        let files = [SearchPayloadFile(path: "b", size: 2, sha256: String(repeating: "b", count: 64)),
                     SearchPayloadFile(path: "evidence/receipt", size: 9, sha256: String(repeating: "c", count: 64)),
                     SearchPayloadFile(path: "a", size: 1, sha256: String(repeating: "a", count: 64))]
        let text = "a\t1\t\(String(repeating: "a", count: 64))\nb\t2\t\(String(repeating: "b", count: 64))\n"
        let expected = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(SearchPayloadAudit.payloadDigest(files), expected)
    }
    func testAbsentRuntimeDoesNotFallBackToSystemPython() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
    }
    func testUnsignedBooleanGateDoesNotMintLaunchConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("{\"protocol\":1,\"native_boundary_verified\":true,\"source_license_verified\":true,\"transient_cache_verified\":true,\"searxng_waitress_compatibility_verified\":true,\"files\":[]}".utf8)
        try data.write(to: root.appendingPathComponent("search-runtime-manifest.json"))
        XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
    }
    func testSyntheticArtifactAuditRejectsChangedMissingAndUnlistedFiles() throws {
        try withSyntheticPayload { root in
            _ = try SearchPayloadAudit.verify(root)
            let helper = root.appendingPathComponent("dot_search.py")
            let original = try Data(contentsOf: helper)
            try Data("changed fixture".utf8).write(to: helper)
            XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
            try original.write(to: helper)
            let extra = root.appendingPathComponent("unexpected.py")
            try Data("extra".utf8).write(to: extra)
            XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
            try FileManager.default.removeItem(at: extra)
            try FileManager.default.removeItem(at: helper)
            XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
        }
    }
    func testSyntheticArtifactAuditRejectsSymlinkAndHardlink() throws {
        try withSyntheticPayload { root in
            let helper = root.appendingPathComponent("dot_search.py")
            try FileManager.default.removeItem(at: helper)
            try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: root.appendingPathComponent("search.sb"))
            XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
        }
        try withSyntheticPayload { root in
            try FileManager.default.linkItem(at: root.appendingPathComponent("dot_search.py"), to: root.appendingPathComponent("alias"))
            XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
        }
    }
    func testReceiptParsingRequiresExactManifestBytes() throws {
        try withSyntheticPayload { root in
            let manifest = try SearchPayloadAudit.verify(root)
            let receipt = root.appendingPathComponent(manifest.acceptance_receipt)
            let original = try Data(contentsOf: receipt)
            var data = original
            // Same size and identical valid JSON semantically. This isolates the
            // receipt hash check instead of relying only on its size check.
            XCTAssertEqual(data.last, 32)
            data[data.count - 1] = 10
            XCTAssertEqual(data.count, original.count)
            let decoded = try JSONDecoder().decode(SearchPayloadAudit.Receipt.self, from: data)
            XCTAssertEqual(decoded.schema, 1)
            XCTAssertTrue(decoded.gates.values.allSatisfy { $0.result == "passed" })
            try data.write(to: receipt)
            XCTAssertThrowsError(try SearchPayloadAudit.verifyReceipt(manifest, root: root)) {
                XCTAssertEqual($0 as? SearchRuntimeFailure, .unacceptedPayload)
            }
            data = original; data.append(32)
            try data.write(to: receipt)
            XCTAssertThrowsError(try SearchPayloadAudit.verifyReceipt(manifest, root: root)) {
                XCTAssertEqual($0 as? SearchRuntimeFailure, .unacceptedPayload)
            }
        }
    }
    func testBoundedNativeReaderRejectsAliasesAndWrongSizes() throws {
        try withSyntheticPayload { root in
            let helper = root.appendingPathComponent("dot_search.py")
            let data = try Data(contentsOf: helper)
            XCTAssertEqual(try SearchPayloadAudit.boundedFile(helper, limit: data.count), data)
            XCTAssertThrowsError(try SearchPayloadAudit.boundedFile(helper, limit: 0))
            XCTAssertThrowsError(try SearchPayloadAudit.boundedFile(helper, limit: data.count - 1))
            XCTAssertThrowsError(try SearchPayloadAudit.hashFile(helper, expectedSize: Int64(data.count + 1)))
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: helper)
            XCTAssertThrowsError(try SearchPayloadAudit.hashFile(alias, expectedSize: Int64(data.count)))
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.linkItem(at: helper, to: alias)
            XCTAssertThrowsError(try SearchPayloadAudit.hashFile(helper, expectedSize: Int64(data.count)))
        }
    }
    #if os(macOS)
    func testNativeReaderHashesEmptyAndAccumulatesMultipleChunks() throws {
        try withSyntheticPayload { root in
            let helper = root.appendingPathComponent("dot_search.py")
            try Data().write(to: helper)
            let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try SearchPayloadAudit.hashFile(helper, expectedSize: 0), emptyHash)
            XCTAssertThrowsError(try SearchPayloadAudit.boundedFile(helper, limit: 1))
            let data = Data(repeating: 0x5a, count: 2 * 1_048_576 + 17)
            try data.write(to: helper)
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try SearchPayloadAudit.hashFile(helper, expectedSize: Int64(data.count)), expected)
            XCTAssertEqual(try SearchPayloadAudit.boundedFile(helper, limit: data.count), data)
            XCTAssertThrowsError(try SearchPayloadAudit.hashFile(helper, expectedSize: -1))
            XCTAssertThrowsError(try SearchPayloadAudit.hashFile(helper, expectedSize: 2_000_000_001))
            XCTAssertThrowsError(try SearchPayloadAudit.boundedFile(helper, limit: Int.max))
        }
    }
    func testNativeReaderRejectsFIFOAndUnsafeModes() throws {
        try withSyntheticPayload { root in
            let helper = root.appendingPathComponent("dot_search.py")
            let size = Int64(try Data(contentsOf: helper).count)
            for mode in [0o622, 0o4600, 0o2600] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: helper.path)
                XCTAssertThrowsError(try SearchPayloadAudit.hashFile(helper, expectedSize: size))
            }
            try FileManager.default.removeItem(at: helper)
            XCTAssertEqual(mkfifo(helper.path, 0o600), 0)
            XCTAssertThrowsError(try SearchPayloadAudit.boundedFile(helper, limit: 1024))
            XCTAssertThrowsError(try SearchPayloadAudit.hashFile(helper, expectedSize: 0))
        }
    }
    func testRootedNativeReaderAllowsAliasOutsidePayloadAndRejectsOneInside() throws {
        try withSyntheticPayload { root in
            let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: alias) }
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
            _ = try SearchPayloadAudit.verify(alias.appendingPathComponent(root.lastPathComponent))
        }
        try withSyntheticPayload { root in
            let python = root.appendingPathComponent("python")
            let saved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: saved) }
            try FileManager.default.moveItem(at: python, to: saved)
            try FileManager.default.createSymbolicLink(at: python, withDestinationURL: saved)
            XCTAssertThrowsError(try SearchPayloadAudit.verify(root))
        }
    }
    func testRootedNativeReaderRejectsParentReplacementDuringRead() throws {
        for useSymlink in [true, false] {
            try withSyntheticPayload { root in
                let reader = try SearchPayloadAudit.Reader(root: root)
                defer { reader.close() }
                let python = root.appendingPathComponent("python")
                let saved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: saved) }
                let count = Int64(try Data(contentsOf: python.appendingPathComponent("bin/python3")).count)
                var mutated = false
                XCTAssertThrowsError(try reader.readFile("python/bin/python3", maximumSize: count) { _ in
                    guard !mutated else { return }; mutated = true
                    try FileManager.default.moveItem(at: python, to: saved)
                    if useSymlink {
                        try FileManager.default.createSymbolicLink(at: python, withDestinationURL: saved)
                    } else {
                        try FileManager.default.createDirectory(at: python, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])
                    }
                })
                XCTAssertTrue(mutated)
            }
        }
    }
    func testRootedNativeReaderRejectsRootReplacementDuringRead() throws {
        try withSyntheticPayload { root in
            let reader = try SearchPayloadAudit.Reader(root: root)
            defer { reader.close() }
            let saved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: saved) }
            let count = Int64(try Data(contentsOf: root.appendingPathComponent("dot_search.py")).count)
            var mutated = false
            XCTAssertThrowsError(try reader.readFile("dot_search.py", maximumSize: count) { _ in
                guard !mutated else { return }; mutated = true
                try FileManager.default.moveItem(at: root, to: saved)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            })
            XCTAssertTrue(mutated)
        }
    }
    func testRootedNativeReaderRejectsLeafReplacementAndGrowthDuringRead() throws {
        for grow in [true, false] {
            try withSyntheticPayload { root in
                let reader = try SearchPayloadAudit.Reader(root: root)
                defer { reader.close() }
                let helper = root.appendingPathComponent("dot_search.py")
                let original = try Data(contentsOf: helper)
                let saved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: saved) }
                var consumed = 0, mutated = false
                XCTAssertThrowsError(try reader.readFile("dot_search.py", maximumSize: Int64(original.count)) { chunk in
                    consumed += chunk.count
                    guard !mutated else { return }; mutated = true
                    if grow {
                        let writer = try FileHandle(forWritingTo: helper)
                        defer { try? writer.close() }
                        _ = try writer.seekToEnd()
                        try writer.write(contentsOf: Data(repeating: 0x21, count: 4096))
                    } else {
                        try FileManager.default.moveItem(at: helper, to: saved)
                        try original.write(to: helper)
                    }
                })
                XCTAssertTrue(mutated)
                XCTAssertEqual(consumed, original.count)
            }
        }
    }
    func testRootedNativeReaderRetainsFileIdentityAcrossReads() throws {
        try withSyntheticPayload { root in
            let reader = try SearchPayloadAudit.Reader(root: root)
            defer { reader.close() }
            let original = try reader.data("dot_search.py", limit: 1024)
            let helper = root.appendingPathComponent("dot_search.py")
            try original.write(to: helper)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: helper.path)
            XCTAssertThrowsError(try reader.data("dot_search.py", limit: 1024))
        }
    }
    func testRootedNativeReaderRejectsTruncationAndSameSizeRewriteDuringRead() throws {
        for truncate in [true, false] {
            try withSyntheticPayload { root in
                let helper = root.appendingPathComponent("dot_search.py")
                let original = Data(repeating: 0x41, count: 2 * 1_048_576 + 17)
                try original.write(to: helper)
                let reader = try SearchPayloadAudit.Reader(root: root)
                defer { reader.close() }
                var mutated = false
                XCTAssertThrowsError(try reader.readFile("dot_search.py", maximumSize: Int64(original.count)) { _ in
                    guard !mutated else { return }; mutated = true
                    let writer = try FileHandle(forWritingTo: helper)
                    defer { try? writer.close() }
                    if truncate {
                        try writer.truncate(atOffset: 0)
                    } else {
                        try writer.write(contentsOf: Data(repeating: 0x42, count: original.count))
                        // Ensure deterministic metadata mismatch even on a coarse clock.
                        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                                              ofItemAtPath: helper.path)
                    }
                })
                XCTAssertTrue(mutated)
            }
        }
    }
    func testRootedNativeReaderRejectsReadsAfterIdempotentClose() throws {
        try withSyntheticPayload { root in
            let reader = try SearchPayloadAudit.Reader(root: root)
            reader.close(); reader.close()
            XCTAssertThrowsError(try reader.data("dot_search.py", limit: 1024))
            XCTAssertThrowsError(try reader.checkTree())
        }
    }
    func testNativeReaderStopsBeforeNextChunkAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 2 * 1_048_576 + 17)
        try bytes.write(to: root.appendingPathComponent("fixture"))
        let result = await Task.detached { () -> (cancelled: Bool, consumed: Int) in
            var consumed = 0
            do {
                let reader = try SearchPayloadAudit.Reader(root: root)
                defer { reader.close() }
                try reader.readFile("fixture", maximumSize: Int64(bytes.count)) { chunk in
                    consumed += chunk.count
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return (false, consumed)
            } catch { return (error is CancellationError, consumed) }
        }.value
        XCTAssertTrue(result.cancelled)
        XCTAssertGreaterThan(result.consumed, 0)
        XCTAssertLessThanOrEqual(result.consumed, 1_048_576)
    }
    func testNativeReaderChecksCancellationBeforeInspectingPath() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try SearchPayloadAudit.boundedFile(missing, limit: 1024); return false }
            catch { guard error is CancellationError else { return false } }
            do { _ = try SearchPayloadAudit.hashFile(missing, expectedSize: 0); return false }
            catch { return error is CancellationError }
        }.value
        XCTAssertTrue(cancelled)
    }
    #endif
    private func withSyntheticPayload(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [SearchPayloadFile] = []
        func write(_ name: String, data: Data) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url)
            files.append(.init(path: name, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        for name in SearchPayloadAudit.requiredFiles.sorted() { try write(name, data: Data(("synthetic " + name).utf8)) }
        try write("evidence/technical.json", data: Data("synthetic audit fixture; not production acceptance".utf8))
        let report = files.last!
        let gates = Dictionary(uniqueKeysWithValues: SearchPayloadAudit.gates.map {
            ($0, ["result": "passed", "report": report.path, "sha256": report.sha256])
        })
        let receipt: [String: Any] = ["schema": 1, "platform": "macOS-arm64", "payload_digest": SearchPayloadAudit.payloadDigest(files), "gates": gates]
        var receiptData = try JSONSerialization.data(withJSONObject: receipt)
        receiptData.append(32) // Allow a same-size, semantically identical mutation test.
        try write("evidence/search-acceptance.json", data: receiptData)
        let manifest: [String: Any] = ["protocol": 1, "searxng_revision": "22c64b8d394b680c7ea96be25f36dad14126420a",
            "waitress_version": "3.0.2", "ddg_transient_patch_sha256": "e4683ebd1207d9011016123ba09f8dc72af19638f164304ef94d5349cb09489f",
            "native_bootstrap": "bin/dot-search-bootstrap", "acceptance_receipt": "evidence/search-acceptance.json",
            "files": files.map { ["path": $0.path, "size": $0.size, "sha256": $0.sha256] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("search-runtime-manifest.json"))
        // This exercises only the pure artifact audit; it cannot construct a
        // ValidatedSearchPayload or bypass the real running-app signature check.
        try body(root)
    }

}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment(_ amount: Int) { lock.lock(); count += amount; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

#if DEBUG && os(macOS)
/// Actual Swift manager/broker/Process/pipe lifecycle, with an explicitly
/// unaccepted shell helper and URLProtocol gateway. No SearXNG/TLS/payload
/// acceptance is claimed by these fixtures; native execution is required.
@MainActor
final class SearchGenerationLifecycleTests: XCTestCase {
    private func wait(_ predicate: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied, "Fixture observation timed out", file: file, line: line)
    }
    private func assertPending(_ latch: RuntimeReceiptLatch, file: StaticString = #filePath, line: UInt = #line) async {
        let released = await latch.hasReleased()
        XCTAssertFalse(released, file: file, line: line)
    }
    private func rejected(_ operation: () async throws -> WebSearchResponse) async {
        do { _ = try await operation(); XCTFail("Unexpected successful search") } catch { }
    }

    func testPrecancelledCallDoesNotReserveOrCreateGeneration() async throws {
        let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-precancel", limit: 1) }
        search.cancel()
        do { _ = try await search.value; XCTFail("Precancelled search succeeded") } catch is CancellationError { }
        XCTAssertTrue(fixture.records.isEmpty); XCTAssertEqual(manager.state, .stopped)
    }

    func testOperationReservedBeforeFactorySuspensionAndLateOwnerDrainsWithoutLaunch() async throws {
        let factoryReceipt = RuntimeReceiptLatch()
        let fixture = try RuntimeLifecycleFixture(factoryReceipt: factoryReceipt); defer { fixture.remove() }
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-held-factory", limit: 1) }
        await wait { fixture.records.count == 1 }
        do { _ = try await manager.searchResponse(query: "fixture-concurrent-factory", limit: 1); XCTFail("Concurrent factory consumed operation") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        let stopped = manager.invalidate(reason: .userStop)
        let stoppedReturned = RuntimeReceiptLatch()
        Task { await stopped.value; await stoppedReturned.release() }
        await Task.yield(); await assertPending(stoppedReturned)
        await factoryReceipt.release()
        await rejected { try await search.value }; await stopped.value
        XCTAssertEqual(fixture.records.count, 1)
        let record = try XCTUnwrap(fixture.records.first)
        XCTAssertFalse(record.owner.isRunning)
        let snapshot = await record.broker.testSnapshot(); XCTAssertTrue(snapshot.drained)
        XCTAssertFalse(fixture.exists("started")); XCTAssertFalse(record.lease.isValid)
    }

    func testCancelDuringResolverWaitRequiresLateResolverReceiptAndNeverLaunches() async throws {
        let resolution = RuntimeReceiptLatch()
        let fixture = try RuntimeLifecycleFixture(resolverReceipt: resolution); defer { fixture.remove() }
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-held-resolver", limit: 1) }
        await wait { guard let first = fixture.records.first else { return false }; return await first.broker.testSnapshot().resolverCalls == 1 }
        let record = try XCTUnwrap(fixture.records.first)
        search.cancel()
        await wait { !record.lease.isValid }
        XCTAssertFalse(fixture.exists("started"))
        do { _ = try await manager.searchResponse(query: "fixture-during-resolver-drain", limit: 1); XCTFail("Replaced unresolved generation") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        let snapshot = await record.broker.testSnapshot(); XCTAssertFalse(snapshot.drained)
        await resolution.release()
        do { _ = try await search.value; XCTFail("Cancelled resolver launched") } catch is CancellationError { }
        let drained = await record.broker.testSnapshot(); XCTAssertTrue(drained.drained)
        XCTAssertFalse(fixture.exists("started")); XCTAssertFalse(record.owner.isRunning)
    }

    func testSuccessRetainsReservationUntilRealSocketAndHelperExitReceipts() async throws {
        let fixture = try RuntimeLifecycleFixture(holdCloseReceipts: true); defer { fixture.remove() }
        try fixture.touch("hold-exit")
        let manager = fixture.manager()
        let completed = RuntimeReceiptLatch()
        let search = Task { @MainActor in
            let response = try await manager.searchResponse(query: "fixture-success-held", limit: 1)
            await completed.release(); return response
        }
        await wait { fixture.exists("stdin-closed") }
        let record = try XCTUnwrap(fixture.records.first)
        await wait { await record.broker.testSnapshot().deferredCloseReceipts > 0 }
        XCTAssertFalse(record.lease.isValid); XCTAssertTrue(record.owner.isRunning)
        await assertPending(completed)
        do { _ = try await manager.searchResponse(query: "fixture-replacement-held", limit: 1); XCTFail("Replacement preceded receipts") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        await record.broker.testReleaseCloseReceipts()
        await assertPending(completed)
        try fixture.touch("release-exit")
        let result = try await search.value
        XCTAssertEqual(result.results.count, 1); XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(record.owner.isRunning)
        let drained = await record.broker.testSnapshot(); XCTAssertTrue(drained.drained); XCTAssertEqual(drained.sockets, 0)
        XCTAssertTrue(fixture.exists("valid-private-start"))
        _ = try await manager.searchResponse(query: "fixture-fresh-generation", limit: 1)
        XCTAssertEqual(fixture.records.count, 2)
        XCTAssertNotEqual(fixture.records[0].lease.generation, fixture.records[1].lease.generation)
    }

    func testStopDuringSuccessfulDrainSuppressesOtherwiseValidResult() async throws {
        let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
        try fixture.touch("hold-exit")
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-stop-settlement", limit: 1) }
        await wait { fixture.exists("stdin-closed") }
        let stop = manager.invalidate(reason: .userStop)
        let quit = manager.invalidate(reason: .quit)
        try fixture.touch("release-exit")
        do { _ = try await search.value; XCTFail("Stop before settlement published result") }
        catch { XCTAssertEqual(error as? SearchRuntimeFailure, .stopped) }
        await stop.value; await quit.value
        XCTAssertEqual(manager.state, .stopped)
        XCTAssertFalse(try XCTUnwrap(fixture.records.first).owner.isRunning)
    }

    func testCallerCancellationCannotCancelIndependentCleanup() async throws {
        let fixture = try RuntimeLifecycleFixture(holdCloseReceipts: true); defer { fixture.remove() }
        try fixture.touch("hold-exit")
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-cancel-settlement", limit: 1) }
        await wait { fixture.exists("stdin-closed") }
        let record = try XCTUnwrap(fixture.records.first)
        search.cancel()
        let cleanup = manager.invalidate(reason: .sleep)
        let observerDone = RuntimeReceiptLatch()
        let observer = Task { await cleanup.value; await observerDone.release() }
        observer.cancel()
        await wait { await record.broker.testSnapshot().deferredCloseReceipts > 0 }
        await assertPending(observerDone)
        try fixture.touch("release-exit")
        await wait { !record.owner.isRunning }
        await assertPending(observerDone)
        await record.broker.testReleaseCloseReceipts()
        await observer.value
        do { _ = try await search.value; XCTFail("Cancelled caller received result") } catch is CancellationError { }
        let drained = await record.broker.testSnapshot(); XCTAssertTrue(drained.drained)
    }

    func testEveryResponseAndValidationFailureSettlesItsGeneration() async throws {
        let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
        let manager = fixture.manager()
        for query in ["fixture-empty", "fixture-forbidden", "fixture-malformed", "fixture-timeout", "fixture-network", "fixture-oversize", " "] {
            let before = fixture.records.count
            if query == "fixture-empty" {
                let response = try await manager.searchResponse(query: query, limit: 1); XCTAssertTrue(response.results.isEmpty)
            } else { await rejected { try await manager.searchResponse(query: query, limit: 1) } }
            XCTAssertEqual(fixture.records.count, before + 1)
            let record = try XCTUnwrap(fixture.records.last)
            XCTAssertFalse(record.lease.isValid); XCTAssertFalse(record.owner.isRunning)
            let snapshot = await record.broker.testSnapshot(); XCTAssertTrue(snapshot.drained); XCTAssertEqual(snapshot.sockets, 0)
            XCTAssertEqual(snapshot.requestDeadline == nil, query == " ")
        }
    }

    func testCooldownAndIndefiniteCooldownPersistAcrossRealGenerationReplacement() async throws {
        for query in ["fixture-cooldown", "fixture-indefinite"] {
            let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
            let manager = fixture.manager()
            var cooldown: SearXNGSearchError?
            do { _ = try await manager.searchResponse(query: query, limit: 1); XCTFail("Cooldown ignored") }
            catch { cooldown = error as? SearXNGSearchError }
            for _ in 0..<2 {
                do { _ = try await manager.searchResponse(query: "fixture-after-cooldown", limit: 1); XCTFail("Replacement reset cooldown") }
                catch { XCTAssertEqual(error as? SearXNGSearchError, cooldown) }
                let record = try XCTUnwrap(fixture.records.last)
                let snapshot = await record.broker.testSnapshot()
                XCTAssertTrue(snapshot.drained); XCTAssertNil(snapshot.requestDeadline)
                XCTAssertFalse(record.owner.isRunning)
            }
            XCTAssertEqual(fixture.records.count, 3)
            XCTAssertNotEqual(fixture.records[0].lease.generation, fixture.records[1].lease.generation)
        }
    }

    func testFailedProcessRunStillWaitsForActualBrokerCloseReceipts() async throws {
        let fixture = try RuntimeLifecycleFixture(holdCloseReceipts: true, missingExecutable: true); defer { fixture.remove() }
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-failed-run", limit: 1) }
        await wait { guard let first = fixture.records.first else { return false }; return await first.broker.testSnapshot().deferredCloseReceipts > 0 }
        let record = try XCTUnwrap(fixture.records.first)
        XCTAssertFalse(record.owner.isRunning)
        do { _ = try await manager.searchResponse(query: "fixture-after-failed-run-held", limit: 1); XCTFail("Run failure skipped broker drain") }
        catch { XCTAssertEqual(error as? SearXNGSearchError, .busy) }
        await record.broker.testReleaseCloseReceipts()
        await rejected { try await search.value }
        let snapshot = await record.broker.testSnapshot(); XCTAssertTrue(snapshot.drained)
        XCTAssertEqual(manager.state, .unavailable)
    }

    func testBootstrapClosesStdinBeforeStartWriteDoesNotRaiseSIGPIPE() async throws {
        let fixture = try RuntimeLifecycleFixture(closeStdinBeforeStart: true); defer { fixture.remove() }
        try fixture.touch("close-stdin-before-start")
        let manager = fixture.manager()
        await rejected { try await manager.searchResponse(query: "fixture-closed-stdin", limit: 1) }
        XCTAssertTrue(fixture.exists("closed-before-start"))
        let record = try XCTUnwrap(fixture.records.first)
        XCTAssertFalse(record.owner.isRunning); XCTAssertFalse(record.lease.isValid)
        let snapshot = await record.broker.testSnapshot()
        XCTAssertTrue(snapshot.drained); XCTAssertNil(snapshot.requestDeadline)
    }

    func testReadinessFailureAndSharedPreparationDeadlineDoNotArmRequest() async throws {
        for mode in ["malformed-ready", "crash-before-ready", "expired-preparation"] {
            let fixture = try RuntimeLifecycleFixture(expiredPreparation: mode == "expired-preparation"); defer { fixture.remove() }
            if mode != "expired-preparation" { try fixture.touch(mode) }
            let manager = fixture.manager()
            await rejected { try await manager.searchResponse(query: "fixture-readiness-failed", limit: 1) }
            let record = try XCTUnwrap(fixture.records.first)
            let snapshot = await record.broker.testSnapshot()
            XCTAssertTrue(snapshot.drained); XCTAssertNil(snapshot.requestDeadline)
            XCTAssertFalse(record.owner.isRunning)
        }
    }

    func testStopBeforeReadinessClosesControlAndLateReadinessCannotDispatch() async throws {
        let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
        try fixture.touch("hold-ready")
        let manager = fixture.manager()
        let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-late-ready", limit: 1) }
        await wait { fixture.exists("started") }
        let record = try XCTUnwrap(fixture.records.first)
        let completion = manager.invalidate(reason: .interruption)
        XCTAssertFalse(record.lease.isValid)
        try fixture.touch("release-ready")
        await completion.value; await rejected { try await search.value }
        let snapshot = await record.broker.testSnapshot(); XCTAssertTrue(snapshot.drained); XCTAssertNil(snapshot.requestDeadline)
        XCTAssertFalse(record.owner.isRunning)
    }

    func testInFlightCancellationAndHelperCrashDrainWithoutStartupCycle() async throws {
        for crash in [false, true] {
            let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
            if crash { try fixture.touch("hold-before-crash") }
            let manager = fixture.manager()
            let search = Task { @MainActor in try await manager.searchResponse(query: "fixture-http-held", limit: 1) }
            await wait { guard let first = fixture.records.first else { return false }; return await first.broker.testSnapshot().requestDeadline != nil }
            let record = try XCTUnwrap(fixture.records.first)
            if crash { try fixture.touch("release-crash") } else { search.cancel() }
            await rejected { try await search.value }
            let snapshot = await record.broker.testSnapshot()
            XCTAssertFalse(record.lease.isValid); XCTAssertFalse(record.owner.isRunning)
            XCTAssertTrue(snapshot.drained); XCTAssertEqual(snapshot.sockets, 0)
        }
    }

    func testFreshBrokerDeadlineForEachPacedGeneration() async throws {
        let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
        let manager = fixture.manager(gate: SearXNGRequestGate(minimumInterval: .seconds(1), maximumWait: .seconds(2)))
        _ = try await manager.searchResponse(query: "fixture-before-pacing", limit: 1)
        let first = try XCTUnwrap(fixture.records.first)
        let firstSnapshot = await first.broker.testSnapshot()
        let firstDeadline = try XCTUnwrap(firstSnapshot.requestDeadline)
        let earliestArm = ProcessInfo.processInfo.systemUptime
        _ = try await manager.searchResponse(query: "fixture-after-pacing", limit: 1)
        let second = fixture.records[1]
        let settled = await second.broker.testSnapshot()
        let nextDeadline = try XCTUnwrap(settled.requestDeadline)
        XCTAssertGreaterThan(nextDeadline, firstDeadline)
        XCTAssertGreaterThanOrEqual(nextDeadline, earliestArm + SearchEgressBroker.searchSeconds)
        XCTAssertLessThanOrEqual(nextDeadline, ProcessInfo.processInfo.systemUptime + SearchEgressBroker.searchSeconds)
        XCTAssertTrue(settled.drained)
    }

    func testStaleFailureCallbackCannotInvalidateReplacement() async throws {
        let fixture = try RuntimeLifecycleFixture(); defer { fixture.remove() }
        let manager = fixture.manager()
        _ = try await manager.searchResponse(query: "fixture-first-callback", limit: 1)
        let old = try XCTUnwrap(fixture.records.first)
        try fixture.touch("hold-ready")
        let next = Task { @MainActor in try await manager.searchResponse(query: "fixture-next-callback", limit: 1) }
        await wait { fixture.records.count == 2 }
        let replacement = fixture.records[1]
        old.onFailure(); old.lease.invalidate(); old.owner.requestStop()
        await Task.yield()
        XCTAssertTrue(replacement.lease.isValid)
        try fixture.touch("release-ready")
        let result = try await next.value; XCTAssertEqual(result.results.count, 1)
    }
}

private actor RuntimeReceiptLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hasReleased() -> Bool { released }
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class RuntimeLifecycleFixture: @unchecked Sendable {
    struct Record: Sendable {
        let lease: SearchGenerationLease
        let broker: SearchEgressBroker
        let owner: SearchOwnedProcess
        let onFailure: @Sendable () -> Void
    }
    let root: URL
    private let lock = NSLock()
    private var stored: [Record] = []
    private var calls = 0
    private let factoryReceipt: RuntimeReceiptLatch?
    private let resolverReceipt: RuntimeReceiptLatch?
    private let holdCloseReceipts: Bool
    private let missingExecutable: Bool
    private let expiredPreparation: Bool
    private let closeStdinBeforeStart: Bool
    var records: [Record] { lock.lock(); defer { lock.unlock() }; return stored }
    var factoryCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func noteCall() { lock.lock(); calls += 1; lock.unlock() }
    private func note(_ record: Record) { lock.lock(); stored.append(record); lock.unlock() }
    init(factoryReceipt: RuntimeReceiptLatch? = nil, resolverReceipt: RuntimeReceiptLatch? = nil,
         holdCloseReceipts: Bool = false, missingExecutable: Bool = false, expiredPreparation: Bool = false,
         closeStdinBeforeStart: Bool = false) throws {
        self.factoryReceipt = factoryReceipt; self.resolverReceipt = resolverReceipt
        self.holdCloseReceipts = holdCloseReceipts; self.missingExecutable = missingExecutable
        self.expiredPreparation = expiredPreparation; self.closeStdinBeforeStart = closeStdinBeforeStart
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dot-lifecycle-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = #"""
        #!/bin/sh
        # Unaccepted lifecycle fixture: no engine, TLS origin or payload audit.
        [ "$#" = 6 ] && [ "$1" = --payload ] && [ "$3" = --state-root ] && [ "$5" = --egress-port ] || exit 10
        root="$2"; argv_port="$6"
        if [ -e "$root/close-stdin-before-start" ]; then
          exec 0<&-
          : > "$root/closed-before-start"
          /bin/sleep 0.2
          exit 16
        fi
        IFS= read -r frame || exit 11
        generation=${frame#*\"generation\":\"}; generation=${generation%%\"*}
        port=${frame#*\"egress_port\":}; port=${port%%,*}
        auth=${frame#*\"proxy_authorization\":\"}; auth=${auth%%\"*}
        [ "${#generation}" = 36 ] && [ "$port" = "$argv_port" ] && [ "${#auth}" = 98 ] || exit 12
        case "$auth" in 'Basic '*) ;; *) exit 13;; esac
        : > "$root/valid-private-start"
        : > "$root/started"
        while [ -e "$root/hold-ready" ] && [ ! -e "$root/release-ready" ]; do /bin/sleep 0.01; done
        [ ! -e "$root/crash-before-ready" ] || exit 14
        if [ -e "$root/malformed-ready" ]; then printf '{}\n'; else
          printf '{"protocol":1,"event":"ready","generation":"%s","endpoint":"http://127.0.0.1:30123/search","capability":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","helper_pid":%s,"server_pid":%s}\n' "$generation" "$$" "$(( $$ + 1 ))"
        fi
        if [ -e "$root/hold-before-crash" ]; then
          while [ ! -e "$root/release-crash" ]; do /bin/sleep 0.01; done
          exit 15
        fi
        /bin/cat >/dev/null
        : > "$root/stdin-closed"
        while [ -e "$root/hold-exit" ] && [ ! -e "$root/release-exit" ]; do /bin/sleep 0.01; done
        printf '{"protocol":1,"event":"stopped","generation":"%s"}\n' "$generation"
        """#
        let executable = root.appendingPathComponent("helper")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func touch(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @MainActor func manager(gate: SearXNGRequestGate = SearXNGRequestGate(minimumInterval: .zero, maximumWait: .zero)) -> SearchRuntimeManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeGatewayFixture.self]
        return SearchRuntimeManager(testing: .init(makeProcess: { [self] lease, onFailure in
            noteCall()
            let broker = try SearchEgressBroker(generation: lease.generation,
                testing: .init(resolve: { [resolverReceipt] in
                    if let resolverReceipt { await resolverReceipt.wait() }
                    return ["93.184.216.34"]
                }, loopbackPort: 1, holdCloseReceipts: holdCloseReceipts && records.isEmpty))
            let beforeControlWrite: (@Sendable () throws -> Void)?
            if closeStdinBeforeStart {
                beforeControlWrite = { [self] in
                    let deadline = ProcessInfo.processInfo.systemUptime + 5
                    while !exists("closed-before-start"), ProcessInfo.processInfo.systemUptime < deadline { usleep(1_000) }
                    guard exists("closed-before-start") else { throw SearchRuntimeFailure.startupFailed }
                }
            } else {
                beforeControlWrite = nil
            }
            let owner = SearchOwnedProcess(testingBootstrap: root.appendingPathComponent(missingExecutable ? "missing" : "helper"),
                fixtureRoot: root, lease: lease, broker: broker,
                preparationDeadline: expiredPreparation ? ContinuousClock.now : nil,
                beforeControlWrite: beforeControlWrite, onFailure: onFailure)
            note(.init(lease: lease, broker: broker, owner: owner, onFailure: onFailure))
            if let factoryReceipt { await factoryReceipt.wait() }
            return owner
        }, configuration: configuration), gate: gate)
    }
}

private final class RuntimeGatewayFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; body.append(bytes, count: count)
            }
        }
        let query = String(decoding: body, as: UTF8.self).split(separator: "&").first(where: { $0.hasPrefix("q=") })
            .map { String($0.dropFirst(2)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" } ?? ""
        if query == "fixture-http-held" { return }
        if query == "fixture-timeout" { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if query == "fixture-network" { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Dot-Search-Capability"), String(repeating: "a", count: 64))
        XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
        var status = 200, headers = ["Content-Type": "application/json"]
        var data = Data("{\"results\":[{\"url\":\"https://example.org/fixture\",\"title\":\"Lifecycle fixture\"}],\"unresponsive_engines\":[]}".utf8)
        switch query {
        case "fixture-empty": data = Data("{\"results\":[],\"unresponsive_engines\":[]}".utf8)
        case "fixture-forbidden": status = 403
        case "fixture-malformed": data = Data("{".utf8)
        case "fixture-oversize": headers["Content-Length"] = "1048577"
        case "fixture-cooldown": status = 429; headers["Retry-After"] = "3600"
        case "fixture-indefinite": status = 503; headers["Retry-After"] = String(repeating: "9", count: 100)
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif

#if DEBUG && os(macOS)
/// The real owner prepares a real broker listener, but never launches a helper,
/// arms a request, transmits a capability or constructs an accepted payload.
final class SearchPreparedEndpointTests: XCTestCase {
    private func withOwner(holdCloseReceipts: Bool = false,
                           _ body: (SearchOwnedProcess, SearchGenerationLease, SearchEgressBroker) async throws -> Void) async throws {
        let lease = SearchGenerationLease()
        let broker = try SearchEgressBroker(generation: lease.generation,
            testing: .init(resolve: { ["8.8.8.8"] }, loopbackPort: 1, holdCloseReceipts: holdCloseReceipts))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dot-endpoint-unused-" + UUID().uuidString)
        let owner = SearchOwnedProcess(testingBootstrap: root.appendingPathComponent("unused"),
            fixtureRoot: root, lease: lease, broker: broker, onFailure: {})
        do { try await body(owner, lease, broker) }
        catch {
            await broker.testReleaseCloseReceipts()
            await owner.cleanup().value
            throw error
        }
        await broker.testReleaseCloseReceipts()
        await owner.cleanup().value
    }

    func testPreparedEndpointReadsDoNotPrepareOrArmAndRetainExactValue() async throws {
        try await withOwner { owner, lease, broker in
            let before = await broker.testSnapshot()
            XCTAssertEqual(before.resolverCalls, 0)
            XCTAssertEqual(before.sockets, 0)
            for _ in 0..<8 { XCTAssertTrue(owner.testPreparedEndpoint() == nil) }
            let unprepared = await broker.testSnapshot()
            XCTAssertEqual(unprepared.resolverCalls, before.resolverCalls)
            XCTAssertEqual(unprepared.sockets, before.sockets)
            XCTAssertNil(unprepared.listenerDescriptor)
            XCTAssertNil(unprepared.requestDeadline)
            XCTAssertEqual(unprepared.admissions, 0)
            XCTAssertEqual(unprepared.connectAttempts, 0)

            try await owner.prepare()
            guard let first = owner.testPreparedEndpoint() else { XCTFail("Prepared endpoint missing"); return }
            let prepared = await broker.testSnapshot()
            let descriptor = try XCTUnwrap(prepared.listenerDescriptor)
            var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            }
            XCTAssertEqual(result, 0)
            XCTAssertEqual(address.sin_family, sa_family_t(AF_INET))
            XCTAssertEqual(first.port, UInt16(bigEndian: address.sin_port))
            XCTAssertGreaterThan(first.port, 0)
            XCTAssertFalse(first.proxyAuthorization.isEmpty)
            for _ in 0..<8 {
                let observed = owner.testPreparedEndpoint()
                let sameEndpoint = observed?.port == first.port && observed?.proxyAuthorization == first.proxyAuthorization
                XCTAssertTrue(sameEndpoint, "Prepared endpoint changed during observation")
            }
            let observed = await broker.testSnapshot()
            XCTAssertTrue(lease.isValid)
            XCTAssertFalse(owner.isRunning)
            XCTAssertEqual(observed.listenerDescriptor, prepared.listenerDescriptor)
            XCTAssertEqual(observed.resolverCalls, 1)
            XCTAssertEqual(observed.sockets, prepared.sockets)
            XCTAssertEqual(observed.admissions, 0)
            XCTAssertEqual(observed.connectAttempts, 0)
            XCTAssertEqual(observed.upstreamBytes, 0)
            XCTAssertEqual(observed.downstreamBytes, 0)
            XCTAssertNil(observed.requestDeadline)
            XCTAssertFalse(observed.drained)
        }
    }

    func testPreparedEndpointDisappearsOnRevocationBeforeHeldDrainAndAfterCleanup() async throws {
        try await withOwner(holdCloseReceipts: true) { owner, lease, broker in
            try await owner.prepare()
            XCTAssertTrue(owner.testPreparedEndpoint() != nil)
            lease.invalidate()
            XCTAssertTrue(owner.testPreparedEndpoint() == nil)
            let cleanup = owner.cleanup()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var snapshot = await broker.testSnapshot()
            while snapshot.deferredCloseReceipts == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
                snapshot = await broker.testSnapshot()
            }
            XCTAssertGreaterThan(snapshot.actualCloses, 0)
            XCTAssertGreaterThan(snapshot.deferredCloseReceipts, 0)
            XCTAssertFalse(snapshot.drained)
            XCTAssertTrue(owner.testPreparedEndpoint() == nil)
            await broker.testReleaseCloseReceipts()
            await cleanup.value
            let drained = await broker.testSnapshot()
            XCTAssertTrue(drained.drained)
            XCTAssertEqual(drained.sockets, 0)
            XCTAssertEqual(drained.deferredCloseReceipts, 0)
            XCTAssertFalse(lease.isValid)
            XCTAssertTrue(owner.testPreparedEndpoint() == nil)
        }
    }

    func testPreparedEndpointRemainsBoundToItsOwnerGeneration() async throws {
        try await withOwner { firstOwner, firstLease, firstBroker in
            try await firstOwner.prepare()
            guard let first = firstOwner.testPreparedEndpoint() else { XCTFail("First prepared endpoint missing"); return }
            firstLease.invalidate()
            await firstOwner.cleanup().value
            let firstDrained = await firstBroker.testSnapshot()
            XCTAssertTrue(firstDrained.drained)
            XCTAssertTrue(firstOwner.testPreparedEndpoint() == nil)
            try await self.withOwner { currentOwner, currentLease, currentBroker in
                try await currentOwner.prepare()
                guard let current = currentOwner.testPreparedEndpoint() else { XCTFail("Current prepared endpoint missing"); return }
                let distinctGenerations = firstLease.generation != currentLease.generation
                let distinctCapabilities = first.proxyAuthorization != current.proxyAuthorization
                XCTAssertTrue(distinctGenerations)
                XCTAssertTrue(distinctCapabilities, "Replacement reused the preceding capability")
                firstOwner.requestStop()
                XCTAssertTrue(firstOwner.testPreparedEndpoint() == nil)
                let observed = currentOwner.testPreparedEndpoint()
                let sameCurrentEndpoint = observed?.port == current.port && observed?.proxyAuthorization == current.proxyAuthorization
                XCTAssertTrue(sameCurrentEndpoint, "Observation returned another generation's endpoint")
                XCTAssertTrue(currentLease.isValid)
                let snapshot = await currentBroker.testSnapshot()
                XCTAssertEqual(snapshot.resolverCalls, 1)
                XCTAssertEqual(snapshot.admissions, 0)
                XCTAssertEqual(snapshot.connectAttempts, 0)
                XCTAssertNil(snapshot.requestDeadline)
                XCTAssertFalse(snapshot.drained)
            }
        }
    }
}
#endif
