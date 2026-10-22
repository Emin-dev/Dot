import Foundation

/// R7/R16: the small local approver. Every file and shell action goes through the
/// bundled Gemma-3-4B verdict before execution. This process never executes the
/// action itself, and any harness failure is a denial — a missing approver must
/// never mean automatic approval.
enum SafetyVerdict: Equatable {
    case allowed
    case denied(reason: String)
    case unavailable(reason: String)
}

final class SafetyApprover: @unchecked Sendable {
    static let shared = SafetyApprover()

    private let lock = NSLock()
    /// The pure policy is tested in DotCore; the clock and lock live here.
    private var policy = ForceOverridePolicy()

    private static let auxiliaryModelPath = "aux/gemma-3-4b-it-Q4_K_M.gguf"

    /// A complete build bundles the approver model; the default model-less app
    /// downloads and verifies the same signed aux file into Application Support.
    /// Both routes lead to the identical hash-checked file.
    private func modelURL() async -> URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("OfflineModels", isDirectory: true)
            .appendingPathComponent(Self.auxiliaryModelPath),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return await MainActor.run {
            guard let root = OfflinePreparation.shared.root else { return nil }
            let downloaded = root.appendingPathComponent(Self.auxiliaryModelPath)
            return FileManager.default.fileExists(atPath: downloaded.path) ? downloaded : nil
        }
    }

    private var binaryURL: URL? {
        guard let bin = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("dot-safety") else { return nil }
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// Arm the owner's manual override only after the safety model refused the
    /// same action three times. Returns false when there is nothing to force.
    func armForce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return policy.arm(now: ProcessInfo.processInfo.systemUptime)
    }

    /// One free pass for the exact refused action, consumed by its next evaluation.
    /// Consuming it also clears that action's strikes, so a later refusal needs
    /// three fresh refusals before "force it" can arm again.
    private func consumeForce(for action: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return policy.consume(action, now: ProcessInfo.processInfo.systemUptime)
    }

    private func clearStrikes(for action: String) {
        lock.lock(); defer { lock.unlock() }
        policy.clear(action)
    }

    static let conversationCharacters = 3_000
    static let actionCharacters = 1_000
    /// The newest `limit` characters, cut at a line start when one is close by.
    static func recent(_ conversation: String, limit: Int = conversationCharacters) -> String {
        guard conversation.count > limit else { return conversation }
        let tail = conversation.suffix(limit)
        if let newline = tail.firstIndex(of: "\n"), tail.distance(from: tail.startIndex, to: newline) < 200 {
            return String(tail[tail.index(after: newline)...])
        }
        return String(tail)
    }

    func registerStrike(key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return policy.registerStrike(key)
    }

    /// Runs the local model and returns its verdict. Bounded by a hard timeout;
    /// any failure is `.unavailable` and therefore a denial upstream.
    func evaluate(conversation: String, action: String) async -> SafetyVerdict {
        if consumeForce(for: action) { return .allowed }
        guard let binary = binaryURL else { return .unavailable(reason: "approver binary missing") }
        guard let model = await modelURL() else { return .unavailable(reason: "approver model missing") }
        // The approver runs a 2,048-token context: send the newest part of the
        // conversation and a bounded action so every request fits.
        let request: [String: String] = ["conversation": Self.recent(conversation),
                                         "action": String(action.prefix(Self.actionCharacters))]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            return .unavailable(reason: "request encoding failed")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--model", model.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // llama.cpp logs its model load to stderr; an unread pipe filled up and
        // stalled the approver until the watchdog killed it.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            stdin.fileHandleForWriting.write(body)
            try stdin.fileHandleForWriting.close()
        } catch {
            return .unavailable(reason: "could not start approver")
        }
        // A hard 20-second watchdog; the blocking read below ends when the process
        // exits or is terminated. This runs on the generic executor, never on the
        // main actor, so a slow model load cannot freeze the pet.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        watchdog.cancel()
        process.waitUntilExit()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable(reason: "approver gave no verdict")
        }
        // A harness failure is not the model saying no: no execution and no strike.
        if let error = object["error"] as? String { return .unavailable(reason: error) }
        guard process.terminationStatus == 0, let verdict = object["verdict"] as? String else {
            return .unavailable(reason: (object["reason"] as? String) ?? "approver gave no verdict")
        }
        let reason = (object["reason"] as? String) ?? ""
        if verdict == "yes" {
            clearStrikes(for: action)
            return .allowed
        }
        return .denied(reason: reason)
    }
}
