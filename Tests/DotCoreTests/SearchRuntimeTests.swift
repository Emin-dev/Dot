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
