import Foundation
import Darwin

/// Reads only a bounded regular WAV off the main actor; never follows a link.
enum VoiceAudioReader {
    static let maximumBytes = 2_881_024
    enum Failure: Error { case invalidAudio }
    static func read(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { () throws -> Data in
            defer { try? FileManager.default.removeItem(at: url) }
            try Task.checkCancellation()
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw Failure.invalidAudio }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  (44...maximumBytes).contains(Int(info.st_size)) else { throw Failure.invalidAudio }
            let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
            try Task.checkCancellation()
            guard data.count == Int(info.st_size), data.count <= maximumBytes,
                  data.prefix(4) == Data("RIFF".utf8), data.dropFirst(8).prefix(4) == Data("WAVE".utf8) else { throw Failure.invalidAudio }
            return data
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

/// Seatbelt matches the kernel path, not Foundation's preferred /var URL spelling.
/// This configuration is shared by the production launch and its native sandbox test.
struct VoiceLaunchConfiguration {
    let directory: URL
    let arguments: [String]
    let environment: [String: String]
    enum Failure: Error { case privateDirectory }
    init(python: URL, helper: URL, profile: URL, root: URL, output: URL) throws {
        let path = try Self.canonicalPrivatePath(output)
        directory = URL(fileURLWithPath: path, isDirectory: true)
        arguments = ["-D", "DOT_OUTPUT=" + path, "-f", profile.path,
                     python.path, "-I", "-B", "-u", helper.path, "--root", root.path, "--output", path]
        environment = ["PATH": "/usr/bin:/bin", "HOME": path, "TMPDIR": path,
                       "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                       "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1"]
    }
    struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }
    static func privateIdentity(_ directory: URL) throws -> DirectoryIdentity {
        var info = stat()
        guard directory.isFileURL, lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw Failure.privateDirectory
        }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }
    static func removeEmptyIfUnchanged(_ directory: URL, identity: DirectoryIdentity) {
        guard (try? privateIdentity(directory)) == identity else { return }
        // Setup has not launched anything yet. Never recursively remove a rejected path.
        _ = rmdir(directory.path)
    }
    static func canonicalPrivatePath(_ directory: URL) throws -> String {
        var before = stat()
        guard directory.isFileURL, lstat(directory.path, &before) == 0,
              before.st_mode & S_IFMT == S_IFDIR, before.st_uid == getuid(), before.st_mode & 0o077 == 0,
              let resolved = realpath(directory.path, nil) else { throw Failure.privateDirectory }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var after = stat()
        guard path.hasPrefix("/"), lstat(path, &after) == 0,
              after.st_mode & S_IFMT == S_IFDIR, after.st_uid == getuid(), after.st_mode & 0o077 == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw Failure.privateDirectory }
        return path
    }
}
