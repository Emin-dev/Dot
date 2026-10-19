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

    /// Set when the owner says "force it": the next approval skips the model gate
    /// once, then the flag resets — the manual override after three refusals.
    var forceNext = false

    private let lock = NSLock()
    private var strikes: [String: Int] = [:]

    private var modelURL: URL? {
        guard let base = Bundle.main.resourceURL?
            .appendingPathComponent("OfflineModels/aux/gemma-3-4b-it-Q4_K_M.gguf") else { return nil }
        return FileManager.default.fileExists(atPath: base.path) ? base : nil
    }

    private var binaryURL: URL? {
        guard let bin = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("dot-safety") else { return nil }
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// The owner's manual override: one free pass, consumed by the next evaluation.
    func consumeForce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = forceNext
        forceNext = false
        return value
    }

    func registerStrike(key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = (strikes[key] ?? 0) + 1
        strikes[key] = count
        return count
    }

    /// Runs the local model and returns its verdict. Bounded by a hard timeout;
    /// any failure is `.unavailable` and therefore a denial upstream.
    func evaluate(conversation: String, action: String) async -> SafetyVerdict {
        if consumeForce() { return .allowed }
        guard let binary = binaryURL else { return .unavailable(reason: "approver binary missing") }
        guard let model = modelURL else { return .unavailable(reason: "approver model missing") }
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
        return verdict == "yes" ? .allowed : .denied(reason: reason)
    }
}
