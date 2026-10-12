import Foundation

@MainActor
final class BundledSplash {
    static let shared = BundledSplash()
    static let model = "mlx-community/Qwen3.8-27B-4bit"
    private var process: Process?
    private var control: FileHandle?
    private var output: FileHandle?
    private var state: URL?
    private var token = UUID()
    private var bytes = Data()
    private(set) var port: Int?
    private(set) var serverPID: Int?
    private(set) var apiKey: String?
    func connection() async throws -> (URL, Int) {
        let payload = try await OfflinePayload.shared.validate()
        try Task.checkCancellation()
        guard ModelDownload.shared.ready, let models = ModelDownload.shared.root else { throw OfflineFailure.download }
        if process == nil {
            guard let resources = Bundle.main.resourceURL else { throw OfflineFailure.incomplete }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dot-splash-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let child = Process(), input = Pipe(), stdout = Pipe(), generation = UUID()
            token = generation; bytes = Data(); port = nil; serverPID = nil; apiKey = nil
            child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            // Only loopback connections are allowed inside the owned runtime sandbox.
            child.arguments = ["-f", resources.appendingPathComponent("Runtime/splash.sb").path,
                               payload.appendingPathComponent("Splash/python/bin/python3").path, "-I", "-B",
                               resources.appendingPathComponent("Runtime/dot_runtime.py").path,
                               "--payload", payload.path, "--models", models.path, "--state", directory.path,
                               "--manifest", resources.appendingPathComponent("model-downloads.json").path]
            child.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path, "PYTHONDONTWRITEBYTECODE": "1"]
            child.standardInput = input; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] _ in
                try? FileManager.default.removeItem(at: directory)
                Task { @MainActor in
                    guard let self, self.token == generation else { return }
                    self.process = nil; self.port = nil; self.serverPID = nil; self.apiKey = nil
                    self.output?.readabilityHandler = nil; self.output = nil; self.control = nil
                }
            }
            do { try child.run() } catch { try? FileManager.default.removeItem(at: directory); throw OfflineFailure.runtime }
            process = child; state = directory; control = input.fileHandleForWriting; output = stdout.fileHandleForReading
            output?.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor in
                    guard let self, self.token == generation else { return }
                    self.receive(data)
                }
            }
        }
        let expected = token
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard token == expected, process?.isRunning == true else { throw OfflineFailure.runtime }
            if let port, let serverPID, let url = URL(string: "http://127.0.0.1:\(port)") { return (url, serverPID) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw OfflineFailure.runtime
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty, bytes.count + data.count <= 8192 else { return }
        bytes.append(data)
        guard let end = bytes.firstIndex(of: 10) else { return }
        let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["protocol"] as? Int == 1, object["event"] as? String == "started",
              let port = object["port"] as? Int, (1...65535).contains(port), let pid = object["pid"] as? Int, pid > 0,
              let key = object["api_key"] as? String, key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return }
        self.port = port; serverPID = pid; apiKey = key
    }
    func owns(pid: Int) -> Bool { serverPID == pid && process?.isRunning == true }
    func shutdown() {
        token = UUID(); output?.readabilityHandler = nil; try? output?.close(); output = nil
        // EOF tells the supervisor to stop its own process group. No synchronous waits on UI.
        try? control?.close(); control = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; port = nil; serverPID = nil; apiKey = nil; state = nil
    }
}
