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
