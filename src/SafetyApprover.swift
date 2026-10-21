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
    private var strikes: [String: Int] = [:]
    /// The action that reached three refusals; "force it" can only unlock this
    /// exact action, and only once.
    private var lastRefused: String?
    private var forceKey: String?
    private var forceExpiresAt: TimeInterval = 0

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
        guard let key = lastRefused, (strikes[key] ?? 0) >= 3 else { return false }
        forceKey = key
        forceExpiresAt = ProcessInfo.processInfo.systemUptime + 120
        return true
    }

    /// One free pass for the exact refused action, consumed by its next evaluation.
    /// Consuming it also clears that action's strikes, so a later refusal needs
    /// three fresh refusals before "force it" can arm again.
    private func consumeForce(for action: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard forceKey == action,
              ProcessInfo.processInfo.systemUptime <= forceExpiresAt else { return false }
        forceKey = nil
        forceExpiresAt = 0
        strikes[action] = 0
        if lastRefused == action { lastRefused = nil }
        return true
    }

    private func clearStrikes(for action: String) {
        lock.lock(); defer { lock.unlock() }
        strikes[action] = 0
        if lastRefused == action { lastRefused = nil }
    }

    func registerStrike(key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = (strikes[key] ?? 0) + 1
        strikes[key] = count
        if count >= 3 { lastRefused = key }
        return count
    }

    /// Runs the local model and returns its verdict. Bounded by a hard timeout;
    /// any failure is `.unavailable` and therefore a denial upstream.
    func evaluate(conversation: String, action: String) async -> SafetyVerdict {
        if consumeForce(for: action) { return .allowed }
        guard let binary = binaryURL else { return .unavailable(reason: "approver binary missing") }
        guard let model = await modelURL() else { return .unavailable(reason: "approver model missing") }
        let request: [String: String] = ["conversation": conversation, "action": action]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            return .unavailable(reason: "request encoding failed")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--model", model.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = object["verdict"] as? String else {
            return .unavailable(reason: "approver gave no verdict")
        }
        let reason = (object["reason"] as? String) ?? ""
        if verdict == "yes" {
            clearStrikes(for: action)
            return .allowed
        }
        return .denied(reason: reason)
    }
}
