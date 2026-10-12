#if !SWIFT_PACKAGE
import XCTest
import Foundation
final class VoiceAudioReaderTests: XCTestCase {
    private func file(_ data: Data) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: path); return path
    }
    private var wav: Data { Data("RIFF0000WAVE".utf8) + Data(repeating: 0, count: 32) }
    func testBoundedRegularAudioReadRemovesTemporaryFile() async throws {
        let path = try file(wav)
        let data = try await VoiceAudioReader.read(path)
        XCTAssertEqual(data, wav); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testOversizedAudioRejectedWithoutUnboundedRead() async throws {
        let path = try file(Data(repeating: 0, count: VoiceAudioReader.maximumBytes + 1))
        do { _ = try await VoiceAudioReader.read(path); XCTFail("oversized audio accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testSymlinkRejectedWithoutDeletingTarget() async throws {
        let path = try file(wav); defer { try? FileManager.default.removeItem(at: path) }
        let link = path.appendingPathExtension("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        do { _ = try await VoiceAudioReader.read(link); XCTFail("symlink accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testCancelledReadNeverSucceeds() async throws {
        let path = try file(wav); defer { try? FileManager.default.removeItem(at: path) }
        let task = Task { () throws -> Data in
            withUnsafeCurrentTask { $0?.cancel() }; return try await VoiceAudioReader.read(path)
        }
        do { _ = try await task.value; XCTFail("canceled read succeeded") } catch is CancellationError {} catch { XCTFail("wrong error") }
    }
}
#endif
