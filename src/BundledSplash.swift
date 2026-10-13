import Foundation
import OSLog
import Darwin

@MainActor
final class BundledSplash {
    static let shared = BundledSplash()
    static let model = "mlx-community/Qwen3.8-27B-4bit"
    private static let log = Logger(subsystem: "app.dot", category: "runtime")
    private var exitState = RuntimeExitState()
    private(set) var diagnostic: RuntimeDiagnostic?
    func failure() async -> Error {
        let expected = token
        // A process-exit notification may beat the final stdout callback. Yield to
        // the bounded protocol reader until EOF, without blocking the main actor.
        for _ in 0..<50 {
            guard token == expected, !Task.isCancelled else { return CancellationError() }
            if let value = exitState.resolved { return value }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard token == expected, !Task.isCancelled else { return CancellationError() }
        return exitState.fallback
    }
    private func publishResolvedFailure() {
        guard diagnostic == nil, let value = exitState.resolved else { return }
        diagnostic = value; Self.log.error("\(value.logLine, privacy: .public)")
    }
    private var process: Process?
    private var control: FileHandle?
    private var output: FileHandle?
    private var protocolReader: RuntimeProtocolReader?
    private var state: URL?
    private var token = UUID()
    private var bytes = Data()
    private(set) var port: Int?
    private(set) var backendPort: Int?
    private(set) var certificateSHA256: String?
    private(set) var serverPID: Int?
    private(set) var apiKey: String?
    struct Connection { let url: URL; let pid: Int; let backendPort: Int; let certificateSHA256: String }
    func connection() async throws -> Connection {
        let payload = try await OfflinePayload.shared.validate()
        try Task.checkCancellation()
        guard OfflinePreparation.shared.ready, let models = OfflinePreparation.shared.root else { throw OfflineFailure.incomplete }
        if process == nil {
            // A quick retry may precede the old pipe's EOF callback.
            protocolReader?.close(); protocolReader = nil
            output?.readabilityHandler = nil; try? output?.close(); output = nil
            guard let resources = Bundle.main.resourceURL else { throw OfflineFailure.incomplete }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-splash-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let child = Process(), input = Pipe(), stdout = Pipe(), generation = UUID()
            token = generation; diagnostic = nil; exitState = RuntimeExitState(); bytes = Data(); port = nil; backendPort = nil; certificateSHA256 = nil; serverPID = nil; apiKey = nil
            child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            // Only loopback connections are allowed inside the owned runtime sandbox.
            child.arguments = ["-f", resources.appendingPathComponent("Runtime/splash.sb").path,
                               payload.appendingPathComponent("Splash/python/bin/python3").path, "-I", "-B",
                               resources.appendingPathComponent("Runtime/dot_runtime.py").path,
                               "--payload", payload.path, "--models", models.path, "--state", directory.path,
                               "--manifest", resources.appendingPathComponent("bundled-models.json").path]
            child.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path, "PYTHONDONTWRITEBYTECODE": "1"]
            child.standardInput = input; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] finished in
                let status = (finished.terminationReason == .uncaughtSignal ? -1 : 1) * Int(finished.terminationStatus)
                try? FileManager.default.removeItem(at: directory)
                Task { @MainActor in
                    guard let self, self.token == generation else { return }
                    self.exitState.exited(status: status); self.publishResolvedFailure()
                    self.process = nil; self.port = nil; self.backendPort = nil; self.certificateSHA256 = nil; self.serverPID = nil; self.apiKey = nil
                    // Keep the stdout reader until EOF; the failure event may still be queued.
                    self.control = nil
                }
            }
            do { try child.run() } catch { try? FileManager.default.removeItem(at: directory); throw OfflineFailure.runtime }
            Self.log.notice("stage=splash_supervisor_started")
            process = child; state = directory; control = input.fileHandleForWriting; output = stdout.fileHandleForReading
            do {
                let reader = try RuntimeProtocolReader(handle: stdout.fileHandleForReading)
                protocolReader = reader
                output?.readabilityHandler = { [weak self] _ in
                    reader.read { [weak self] data in
                        guard let self, self.token == generation else { return }
                        self.receive(data)
                    }
                }
            } catch {
                shutdown(); throw OfflineFailure.runtime
            }
        }
        let expected = token
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard token == expected else { throw CancellationError() }
            guard process?.isRunning == true else { throw await failure() }
            if let port, let serverPID, let backendPort, let certificateSHA256, let url = URL(string: "https://127.0.0.1:\(port)") {
                return Connection(url: url, pid: serverPID, backendPort: backendPort, certificateSHA256: certificateSHA256)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let error = await failure()
        guard token == expected, !Task.isCancelled else { throw CancellationError() }
        Self.log.error("stage=splash_startup outcome=timeout")
        // A startup-event timeout must not leave an unreachable owned model alive.
        shutdown()
        throw error
    }
    private func receive(_ data: Data) {
        if data.isEmpty {
            exitState.finishedOutput(); publishResolvedFailure()
            protocolReader?.close(); protocolReader = nil
            output?.readabilityHandler = nil; try? output?.close(); output = nil
            return
        }
        guard bytes.count + data.count <= 8192 else { return }
        bytes.append(data)
        while let end = bytes.firstIndex(of: 10) {
            let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
            if let diagnostic = RuntimeDiagnostic.parse(line) {
                exitState.received(diagnostic); publishResolvedFailure()
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["protocol"] as? Int == 1, object["event"] as? String == "started",
                  let port = object["port"] as? Int, (1...65535).contains(port), let pid = object["pid"] as? Int, pid > 0,
                  let backend = object["backend_port"] as? Int, (1...65535).contains(backend), backend != port,
                  let certificate = object["tls_certificate_sha256"] as? String, certificate.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let key = object["api_key"] as? String, key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return }
            self.port = port; backendPort = backend; certificateSHA256 = certificate; serverPID = pid; apiKey = key
        }
    }
    func owns(pid: Int) -> Bool { serverPID == pid && process?.isRunning == true }
    func shutdown() {
        token = UUID(); protocolReader?.close(); protocolReader = nil
        output?.readabilityHandler = nil; try? output?.close(); output = nil
        // EOF tells the supervisor to stop its own process group. No synchronous waits on UI.
        try? control?.close(); control = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; port = nil; backendPort = nil; certificateSHA256 = nil; serverPID = nil; apiKey = nil; state = nil
    }
}

/// A pipe read must deliver available bytes while its long-lived writer stays open.
/// Own a duplicate descriptor so shutdown cannot close/reuse it during a read.
final class RuntimeProtocolReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var descriptor: Int32
    private var finished = false
    init(handle: FileHandle) throws {
        self.handle = handle
        let fd = Darwin.dup(handle.fileDescriptor)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        descriptor = fd
        let descriptorFlags = fcntl(fd, F_GETFD)
        let statusFlags = fcntl(fd, F_GETFL)
        guard descriptorFlags >= 0, statusFlags >= 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            let error = errno; Darwin.close(fd); descriptor = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
    }
    func read(deliver: @escaping @MainActor @Sendable (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        let data: Data
        if count > 0 { data = Data(buffer.prefix(count)) }
        else { finishLocked(); data = Data() }
        // Submission is under the same lock as read/EOF; main-queue FIFO preserves order.
        DispatchQueue.main.async { deliver(data) }
    }
    private func finishLocked() {
        guard !finished else { return }
        finished = true; handle.readabilityHandler = nil
        let fd = descriptor; descriptor = -1
        if fd >= 0 { Darwin.close(fd) }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        finishLocked()
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
