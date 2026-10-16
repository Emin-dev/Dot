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

#if !SWIFT_PACKAGE
final class VoiceLaunchConfigurationTests: XCTestCase {
    private func privateDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("dot-voice-alias-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    func testVarAliasUsesSamePOSIXPathEverywhere() throws {
        let directory = try privateDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = try VoiceLaunchConfiguration.canonicalPrivatePath(directory)
        XCTAssertEqual(path, "/private" + directory.path)
    }
    func testMissingNonPrivateAndSymlinkDirectoriesFailClosed() throws {
        let directory = try privateDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try VoiceLaunchConfiguration.canonicalPrivatePath(directory.appendingPathComponent("missing")))
        let link = directory.appendingPathExtension("link"); defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try VoiceLaunchConfiguration.canonicalPrivatePath(link))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try VoiceLaunchConfiguration.canonicalPrivatePath(directory))
    }
    func testSetupCleanupLeavesReplacementAndNonemptyDirectoryUntouched() throws {
        let directory = try privateDirectory()
        let identity = try VoiceLaunchConfiguration.privateIdentity(directory)
        let original = directory.appendingPathExtension("original")
        try FileManager.default.moveItem(at: directory, to: original)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: original) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        VoiceLaunchConfiguration.removeEmptyIfUnchanged(directory, identity: identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let file = original.appendingPathComponent("keep"); try Data("keep".utf8).write(to: file)
        VoiceLaunchConfiguration.removeEmptyIfUnchanged(original, identity: identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        VoiceLaunchConfiguration.removeEmptyIfUnchanged(original, identity: identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }
}
#endif
