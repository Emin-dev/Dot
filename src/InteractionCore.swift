import Foundation

/// Pure, deterministic rules shared by the app and its XCTest target.
struct TurnGate {
    private(set) var current = UUID()
    mutating func advance() -> UUID { current = UUID(); return current }
    func accepts(_ id: UUID) -> Bool { id == current }
}

struct SilenceGate {
    static let grace: TimeInterval = 3
    private(set) var lastSpeech: TimeInterval?
    mutating func heardSpeech(at time: TimeInterval) { lastSpeech = time }
    func shouldFinish(at time: TimeInterval) -> Bool {
        guard let lastSpeech else { return false }
        return time - lastSpeech >= Self.grace
    }
}

enum LocalEndpoint {
    static func validate(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "http",
              let host = parts.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let port = parts.port, (1...65535).contains(port) else { return nil }
        return parts.url
    }
}

struct SplashIdentity: Decodable {
    struct Instance: Decodable {
        let id: String
        let pid: Int
        let model: String
        let host: String
        let port: Int
    }
    let schema_version: Int
    let ready: Bool
    let instance: Instance?
    let vision: Bool?
    let input_modalities: [String]?
    func matches(model: String, port: Int, server: String?) -> Bool {
        guard server == "Splash", schema_version == 6, ready, let instance,
              instance.pid > 0, instance.id.range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil,
              ["127.0.0.1", "localhost", "::1"].contains(instance.host),
              instance.port == port, instance.model == model, !model.isEmpty else { return false }
        return true
    }
}

struct SentenceBuffer {
    private var pending = ""
    mutating func feed(_ delta: String) -> [String] {
        pending += delta
        var output: [String] = []
        // Keep every chunk bounded, including a whole sentence arriving in one SSE delta.
        while !pending.isEmpty {
            let sentence = pending.range(of: #"[.!?…](?:[\"”']?\s+)"#, options: .regularExpression)
            let end: String.Index
            if let sentence, pending.distance(from: pending.startIndex, to: sentence.upperBound) <= 280 {
                end = sentence.upperBound
            } else if pending.count >= 280 {
                let prefix = pending.prefix(280)
                if let whitespace = prefix.lastIndex(where: { $0.isWhitespace }), whitespace != pending.startIndex {
                    end = pending.index(after: whitespace)
                } else { end = pending.index(pending.startIndex, offsetBy: 280) }
            } else { break }
            let chunk = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<end)
            if !chunk.isEmpty { output.append(chunk) }
        }
        return output
    }
    mutating func flush() -> String? {
        let value = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return value.isEmpty ? nil : value
    }
}

struct StreamDelta {
    let content: String
    let reasoning: String
    let done: Bool
    static func parse(_ line: String) -> StreamDelta? {
        guard line.hasPrefix("data:") else { return nil }
        let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if value == "[DONE]" { return StreamDelta(content: "", reasoning: "", done: true) }
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return StreamDelta(content: delta["content"] as? String ?? "",
                           reasoning: delta["reasoning_content"] as? String ?? "", done: false)
    }
}

/// Strict framing for Dot's bundled Bionic helper, not an installed daemon API.
struct VoiceEvent {
    let kind: String
    let request: UUID?
    let turn: UUID?
    let filename: String?
    static func parse(_ data: Data) -> VoiceEvent? {
        guard data.count <= 8192,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = value["protocol"] as? Int, version == 1,
              let kind = value["event"] as? String else { return nil }
        if kind == "hello" {
            guard value["engine"] as? String == "kokoro", value["voice"] as? String == "bf_isabella",
                  value["sample_rate"] as? Int == 24000, value["offline"] as? Bool == true else { return nil }
            return VoiceEvent(kind: kind, request: nil, turn: nil, filename: nil)
        }
        if kind == "cancelled" || kind == "unavailable" {
            return VoiceEvent(kind: kind, request: nil, turn: nil, filename: nil)
        }
        guard kind == "audio" || kind == "error",
              let id = value["id"] as? String, let request = UUID(uuidString: id),
              let generation = value["turn"] as? String, let turn = UUID(uuidString: generation) else { return nil }
        if kind == "error" { return VoiceEvent(kind: kind, request: request, turn: turn, filename: nil) }
        guard let filename = value["file"] as? String, filename.hasPrefix("audio-"), filename.hasSuffix(".wav"),
              UUID(uuidString: String(filename.dropFirst(6).dropLast(4))) != nil,
              filename.count == 46, value["sample_rate"] as? Int == 24000,
              let samples = value["samples"] as? Int, (1...1_440_000).contains(samples) else { return nil }
        return VoiceEvent(kind: kind, request: request, turn: turn, filename: filename)
    }
}

/// Pure contract for one ephemeral screenshot bound to one explicit voice turn.
/// CaptureKit integration is separate; this type never captures, writes or uploads pixels.
struct ScreenContextGate {
    enum Failure: Error, Equatable { case disabled, permissionDenied, unavailable, unsupportedModel, stale, invalidImage }
    private var turn: UUID?
    private var image: Data?
    private var capturedAt: Double?
    private var state: Failure? = .unavailable
    static let maximumBytes = 2_000_000
    static let maximumPixels = 2_097_152
    mutating func begin(turn: UUID, enabled: Bool, permissionGranted: Bool, modelHasVision: Bool) {
        self.turn = turn; image = nil; capturedAt = nil
        state = !enabled ? .disabled : !permissionGranted ? .permissionDenied : !modelHasVision ? .unsupportedModel : .unavailable
    }
    mutating func capturedJPEG(_ data: Data, width: Int, height: Int, turn: UUID, now: Double) throws {
        guard self.turn == turn else { throw Failure.stale }
        guard state == .unavailable else { throw state ?? Failure.stale }
        guard now.isFinite, width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= Self.maximumPixels, data.count <= Self.maximumBytes, data.count >= 4,
              data.starts(with: [0xff, 0xd8, 0xff]), data.suffix(2).elementsEqual([0xff, 0xd9]) else { throw Failure.invalidImage }
        image = data; capturedAt = now; state = nil
    }
    mutating func consumeDataURL(turn: UUID, now: Double) throws -> String {
        guard self.turn == turn else { throw Failure.stale }
        if let state { throw state }
        guard let image, let capturedAt, now.isFinite, now >= capturedAt, now - capturedAt <= 5 else {
            cancel(); throw Failure.stale
        }
        // Consume once; callers must not retain this in subsequent conversation history.
        let url = "data:image/jpeg;base64," + image.base64EncodedString()
        cancel(); return url
    }
    mutating func cancel() { turn = nil; image = nil; capturedAt = nil; state = .unavailable }
}

/// Coalesces fast token streams without delaying the first visible answer token.
struct StreamUpdateBuffer {
    private var pending = ""
    private var lastEmission: Double?
    mutating func feed(_ content: String, now: Double) -> String? {
        pending += content
        guard lastEmission == nil || now - lastEmission! >= 0.04 || pending.utf8.count >= 1024 else { return nil }
        lastEmission = now; return flush()
    }
    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let value = pending; pending = ""; return value
    }
}

struct DownloadBudget {
    static func requiredFree(total: Int64, reusableBytes: Int64) -> Int64 {
        max(0, total - min(total, max(0, reusableBytes))) + 5_000_000_000
    }
}
enum ScreenPrivacyPreference {
    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "screenContextEnabled") as? Bool ?? true
    }
    static func setEnabled(_ value: Bool, in defaults: UserDefaults = .standard) { defaults.set(value, forKey: "screenContextEnabled") }
}

/// Visible readiness never implies that missing runtime files can be downloaded or selected.
enum CompanionReadiness: Equatable {
    case checking, paused, ready, unavailable(String)
    var canTalk: Bool { self == .ready }
    var canPause: Bool { self == .checking }
    var canRetry: Bool { switch self { case .paused, .unavailable: return true; default: return false } }
    var isIssue: Bool { if case .unavailable = self { return true }; return false }
    var caption: String {
        switch self {
        case .checking: return "Checking bundled files…"
        case .paused: return "Check paused · right-click"
        case .ready: return "Click to talk"
        case .unavailable: return "Incomplete app · right-click"
        }
    }
    var detail: String? { if case .unavailable(let message) = self { return message }; return nil }
}

enum CompanionMenuAction: Equatable {
    case talk, stop, pause, retry, pin, screen, clear, quit
    static func available(readiness: CompanionReadiness, busy: Bool) -> [Self] {
        var actions: [Self] = []
        if readiness.canTalk { actions.append(.talk) }
        if busy { actions.append(.stop) }
        if readiness.canPause { actions.append(.pause) }
        if readiness.canRetry { actions.append(.retry) }
        return actions + [.pin, .screen, .clear, .quit]
    }
}

enum CompanionAccessibility {
    static func value(status: String, detail: String?, capturingScreen: Bool, screenUsed: Bool) -> String {
        let base = detail ?? status
        if capturingScreen { return base + ". Reading screen locally." }
        if screenUsed { return base + ". Screen used locally for this reply." }
        return base
    }
}

/// Client-side resource bounds do not trust server completion-token settings.
enum ResponseLimit: Error { case exceeded, invalidUTF8 }
struct BoundedSSELines {
    static let maximumLineBytes = 262_144
    static let maximumStreamBytes = 4_000_000
    private var line = Data()
    private var total = 0
    mutating func feed(_ byte: UInt8) throws -> String? {
        total += 1
        guard total <= Self.maximumStreamBytes else { throw ResponseLimit.exceeded }
        if byte == 10 {
            defer { line.removeAll(keepingCapacity: true) }
            if line.last == 13 { line.removeLast() }
            guard let value = String(data: line, encoding: .utf8) else { throw ResponseLimit.invalidUTF8 }
            return value
        }
        guard line.count < Self.maximumLineBytes else { throw ResponseLimit.exceeded }
        line.append(byte); return nil
    }
}
struct ResponseTextBudget {
    private var bytes = 0
    mutating func accept(_ text: String) throws {
        let count = text.utf8.count
        guard count <= 64_000 - bytes else { throw ResponseLimit.exceeded }
        bytes += count
    }
}

/// Only fixed identifiers and bounded numeric exit codes cross the diagnostic boundary.
/// Library stderr, paths, prompts and credentials never become display/log text.
struct RuntimeDiagnostic: LocalizedError, Equatable {
    enum Stage: String, Decodable { case snapshot, tls, launcher, supervisor, voice }
    enum Reason: String, Decodable {
        case moduleMissing = "module_missing", permissionDenied = "permission_denied"
        case outOfMemory = "out_of_memory", fileMissing = "file_missing"
        case argumentRejected = "argument_rejected", deviceUnsupported = "device_unsupported"
        case processExited = "process_exited", startupFailed = "startup_failed"
    }
    let stage: Stage
    let reason: Reason
    let exitStatus: Int?
    static func parse(_ data: Data) -> Self? {
        struct Event: Decodable {
            let `protocol`: Int
            let event: String
            let stage: Stage
            let reason: Reason
            let exit_status: Int?
        }
        guard data.count <= 8192, let event = try? JSONDecoder().decode(Event.self, from: data),
              event.protocol == 1, event.event == "failed",
              event.exit_status.map({ (-255...255).contains($0) }) ?? true else { return nil }
        return Self(stage: event.stage, reason: event.reason, exitStatus: event.exit_status)
    }
    var logLine: String {
        "stage=\(stage.rawValue) reason=\(reason.rawValue) exit=\(exitStatus.map(String.init) ?? "unknown")"
    }
    var errorDescription: String? {
        let detail: String
        switch reason {
        case .moduleMissing: detail = "a bundled dependency could not load"
        case .permissionDenied: detail = "a required local operation was denied"
        case .outOfMemory: detail = "memory allocation failed"
        case .fileMissing: detail = "a required bundled file could not be opened"
        case .argumentRejected: detail = "the bundled launcher rejected an option"
        case .deviceUnsupported: detail = "the runtime rejected this device"
        case .processExited: detail = "the owned process stopped"
        case .startupFailed: detail = "initialization failed"
        }
        return "\(stage == .voice ? "Voice" : "Splash") \(stage.rawValue): \(detail)\(exitStatus.map { " (exit \($0))" } ?? ""). Click to retry."
    }
}

/// Exit notifications are not proof that the final protocol callback has run.
struct RuntimeExitState {
    private var diagnostic: RuntimeDiagnostic?
    private var status: Int?
    private var eof = false
    mutating func received(_ value: RuntimeDiagnostic) { diagnostic = value }
    mutating func exited(status: Int) { self.status = status }
    mutating func finishedOutput() { eof = true }
    var resolved: RuntimeDiagnostic? {
        if let diagnostic { return diagnostic }
        return eof && status != nil ? fallback : nil
    }
    var fallback: RuntimeDiagnostic {
        RuntimeDiagnostic(stage: .supervisor, reason: status == nil ? .startupFailed : .processExited, exitStatus: status)
    }
}

/// One explicit-turn OS request at most. A successful first grant may proceed
/// only when the fresh preflight confirms access; refusal never becomes a capture.
enum ScreenPermissionAccess {
    static func allowed(preflight: () -> Bool, request: () -> Bool) -> Bool {
        if preflight() { return true }
        guard request() else { return false }
        return preflight()
    }
}
