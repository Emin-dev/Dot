#if !SWIFT_PACKAGE
import XCTest
import Foundation
import CryptoKit

private final class AssetFixture: URLProtocol {
    static var status = 200
    static var payload = Data("hello".utf8)
    static var range: String?
    static var lastRange: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRange = request.value(forHTTPHeaderField: "Range")
        var headers = ["Content-Length": String(Self.payload.count)]
        if let range = Self.range { headers["Content-Range"] = range }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OfflineIntegrationTests: XCTestCase {
    private var folder: URL!
    private let checksum = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        AssetFixture.status = 200; AssetFixture.payload = Data("hello".utf8); AssetFixture.range = nil; AssetFixture.lastRange = nil
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func transfer() -> AssetTransfer {
        let asset = ModelDownloadPlan.Asset(path: "model", url: URL(string: "https://huggingface.co/fixture")!, bytes: 5, sha256: checksum)
        return AssetTransfer(asset: asset, destination: folder.appendingPathComponent("model.partial"), protocolClasses: [AssetFixture.self]) { _ in }
    }
    func testFreshDownloadChecksBytesAndHash() async throws {
        let url = try await transfer().start()
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8)); XCTAssertNil(AssetFixture.lastRange)
    }
    func testPartialDownloadUsesRangeAndVerifiesWholeFile() async throws {
        try Data("he".utf8).write(to: folder.appendingPathComponent("model.partial"))
        AssetFixture.status = 206; AssetFixture.range = "bytes 2-4/5"; AssetFixture.payload = Data("llo".utf8)
        let url = try await transfer().start()
        XCTAssertEqual(AssetFixture.lastRange, "bytes=2-"); XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }
    func testServerIgnoringRangeRestartsWithoutAppendingDuplicateBytes() async throws {
        try Data("he".utf8).write(to: folder.appendingPathComponent("model.partial"))
        let url = try await transfer().start(); XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }
    func testIncorrectHashNeverSucceeds() async {
        AssetFixture.payload = Data("HELLO".utf8)
        do { _ = try await transfer().start(); XCTFail("corruption accepted") } catch {}
    }
    func testOverlongResponseNeverSucceeds() async {
        AssetFixture.payload = Data("hello unexpected".utf8)
        do { _ = try await transfer().start(); XCTFail("overflow accepted") } catch {}
        XCTAssertLessThanOrEqual((try? Data(contentsOf: folder.appendingPathComponent("model.partial")).count) ?? 0, 5)
    }
    func testCancelledBeforeStartNeverOpensConnection() async {
        let task = transfer(); task.cancel()
        do { _ = try await task.start(); XCTFail("cancelled transfer started") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.partial").path))
    }
    func testWrongRangeNeverAccepted() async throws {
        try Data("he".utf8).write(to: folder.appendingPathComponent("model.partial"))
        AssetFixture.status = 206; AssetFixture.range = "bytes 1-4/5"; AssetFixture.payload = Data("ello".utf8)
        do { _ = try await transfer().start(); XCTFail("wrong range accepted") } catch {}
    }
    func testUnsafeRelativePathsAndExternalSymlinksRejected() throws {
        for name in ["../outside", "/absolute", "a//b", "a/./b", "a\\b"] {
            XCTAssertThrowsError(try OfflinePayload.safePath(name, root: folder))
        }
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try OfflinePayload.safePath("link/file", root: folder))
    }
    func testHashRejectsSymlinkEvenWhenContentsMatch() throws {
        let file = folder.appendingPathComponent("actual"); try Data("hello".utf8).write(to: file)
        let link = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try OfflinePayload.hash(link, bytes: 5, expected: checksum))
    }
    func testCancelledHashDoesNotReportSuccess() async throws {
        let file = folder.appendingPathComponent("small"); try Data("hello".utf8).write(to: file)
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try await OfflinePayload.verifyHash(file, bytes: 5, expected: checksum)
        }
        task.cancel()
        do { try await task.value; XCTFail("cancelled hash succeeded") } catch is CancellationError {} catch { XCTFail("unexpected error") }
    }
    func testHashRejectsSizeMismatch() throws {
        let url = folder.appendingPathComponent("small"); try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try OfflinePayload.hash(url, bytes: 4, expected: checksum))
        XCTAssertNoThrow(try OfflinePayload.hash(url, bytes: 5, expected: checksum))
    }
}
#endif
