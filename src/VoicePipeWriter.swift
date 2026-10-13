import Foundation
import Darwin

/// Serial, bounded and nonblocking even if the child stops reading its pipe.
/// This queue never runs model work and never blocks the main actor's Stop/Quit.
final class VoicePipeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.dot.voice.stdin")
    private let handle: FileHandle
    private var source: DispatchSourceWrite?
    private var bytes = Data()
    private var closed = false
    private var active = false
    private let failure: @Sendable () -> Void
    init(handle: FileHandle, failure: @escaping @Sendable () -> Void) throws {
        self.handle = handle; self.failure = failure
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in self?.flush() }
        source.setCancelHandler { try? handle.close() }
    }
    func append(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            guard data.count <= 8192, bytes.count + data.count <= 196_608 else { fail(); return }
            bytes.append(data)
            if !active { active = true; source?.resume() }
            flush()
        }
    }
    private func flush() {
        while !closed && !bytes.isEmpty {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(handle.fileDescriptor, raw.baseAddress!, raw.count)
            }
            if count > 0 { bytes.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { fail(); return }
        }
        if active && !closed { active = false; source?.suspend() }
    }
    private func fail() { closeOnQueue(); failure() }
    private func closeOnQueue() {
        guard !closed else { return }
        closed = true; bytes.removeAll()
        if !active { active = true; source?.resume() }
        source?.cancel(); source = nil
    }
    func close(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in closeOnQueue(); completion() }
    }
}
