import Foundation
import CoreFoundation
#if canImport(AppKit)
import AppKit
#endif

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

/// Ephemeral pixels with the original monotonic acquisition bound preserved through
/// encoding and request assembly. Never put this value in conversation history.
struct CapturedScreenImage: Sendable {
    let turn: UUID
    let acquiredAt: Double
    private let encodedDataURL: String
    static let maximumAge: Double = 5

    fileprivate init(turn: UUID, acquiredAt: Double, dataURL: String) {
        self.turn = turn; self.acquiredAt = acquiredAt; encodedDataURL = dataURL
    }
    func dataURL(now: Double) throws -> String {
        try validateFreshness(now: now)
        return encodedDataURL
    }
    func validateFreshness(now: Double) throws {
        try Self.validateTime(acquiredAt: acquiredAt, now: now)
    }
    fileprivate static func validateTime(acquiredAt: Double, now: Double) throws {
        guard acquiredAt.isFinite, acquiredAt >= 0, now.isFinite,
              now >= acquiredAt, now - acquiredAt <= maximumAge else { throw ScreenContextGate.Failure.stale }
    }
}

/// Pure contract for one ephemeral screenshot bound to one voice turn.
/// CaptureKit integration is separate; this type never captures, writes or uploads pixels.
struct ScreenContextGate {
    enum Failure: LocalizedError, Equatable {
        case disabled, permissionDenied, unavailable, unsupportedModel, stale, invalidImage
        var errorDescription: String? {
            switch self {
            case .disabled: return "Screen context is off. Continue without screen or enable it in Options."
            case .permissionDenied: return "Allow Dot in System Settings → Privacy & Security → Screen Recording, or continue without screen."
            case .stale: return "The screen image became too old before it could be used. Retry for a fresh image or continue without screen."
            case .unsupportedModel: return "The local model could not accept screen context. Continue without screen."
            case .unavailable, .invalidImage: return "The screen image could not be read. Retry or continue without screen."
            }
        }
    }
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
    func validateCapture(turn: UUID) throws {
        guard self.turn == turn else { throw Failure.stale }
        if let state, state != .unavailable { throw state }
    }
    mutating func capturedJPEG(_ data: Data, width: Int, height: Int, turn: UUID, acquiredAt: Double, now: Double) throws {
        try validateCapture(turn: turn)
        guard state == .unavailable else { throw state ?? Failure.stale }
        do { try CapturedScreenImage.validateTime(acquiredAt: acquiredAt, now: now) }
        catch { cancel(); throw error }
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= Self.maximumPixels, data.count <= Self.maximumBytes, data.count >= 4,
              data.starts(with: [0xff, 0xd8, 0xff]), data.suffix(2).elementsEqual([0xff, 0xd9]) else { throw Failure.invalidImage }
        image = data; capturedAt = acquiredAt; state = nil
    }
    mutating func consume(turn: UUID, now: Double) throws -> CapturedScreenImage {
        guard self.turn == turn else { throw Failure.stale }
        if let state { throw state }
        defer { cancel() }
        guard let image, let capturedAt else { throw Failure.unavailable }
        try CapturedScreenImage.validateTime(acquiredAt: capturedAt, now: now)
        // Consume once; callers must not retain this in subsequent conversation history.
        let url = "data:image/jpeg;base64," + image.base64EncodedString()
        return CapturedScreenImage(turn: turn, acquiredAt: capturedAt, dataURL: url)
    }
    mutating func cancel(turn: UUID) { if self.turn == turn { cancel() } }
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

enum CompanionMenuAction: Equatable, CaseIterable {
    case talk, stop, pause, retry, pin, screen, clear, copyDetails, quit
    func title(busy: Bool, pinned: Bool, issue: CompanionIssue?) -> String {
        switch self {
        case .talk: return busy ? "Interrupt and listen" : (issue?.retryTitle ?? "Talk")
        case .stop: return "Stop"
        case .pause: return "Pause file check"
        case .retry: return "Retry file check"
        case .pin: return pinned ? "Roam" : "Pin here"
        case .screen: return "Screen context"
        case .clear: return "Clear conversation"
        case .copyDetails: return "Copy details"
        case .quit: return "Quit Dot"
        }
    }
    static func available(readiness: CompanionReadiness, busy: Bool, hasDetails: Bool = false) -> [Self] {
        var actions: [Self] = []
        if readiness.canTalk { actions.append(.talk) }
        if busy { actions.append(.stop) }
        if readiness.canPause { actions.append(.pause) }
        if readiness.canRetry { actions.append(.retry) }
        return actions + [.pin, .screen, .clear] + (hasDetails ? [.copyDetails] : []) + [.quit]
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

/// Public diagnostics accept only finite identifiers, never error descriptions or payloads.
struct PipelineDiagnostic: Equatable {
    enum Stage: String { case microphone, voice, readiness, capture, response }
    enum Outcome: String { case started, ready, timeout, failed }
    enum Reason: String {
        case permission, unsupported, unavailable, identity, httpRejected = "http_rejected"
        case invalidResponse = "invalid_response", emptyResponse = "empty_response"
        case resourceLimit = "resource_limit", transport, captureFailed = "capture_failed", voiceFailed = "voice_failed", unknown
    }
    let stage: Stage
    let outcome: Outcome
    let reason: Reason?
    init(stage: Stage, outcome: Outcome, reason: Reason? = nil) {
        self.stage = stage; self.outcome = outcome; self.reason = reason
    }
    static func failure(stage: Stage, reason: Reason, cancelled: Bool) -> Self? {
        cancelled ? nil : Self(stage: stage, outcome: .failed, reason: reason)
    }
    var logLine: String {
        "pipeline=\(stage.rawValue) outcome=\(outcome.rawValue)\(reason.map { " reason=\($0.rawValue)" } ?? "")"
    }
}

/// Permission may be requested once at the explicit click, never after expensive warmup.
struct ScreenPermissionTurn {
    private var authorizedTurn: UUID?
    mutating func prepare(turn: UUID, enabled: Bool, preflight: () -> Bool, request: () -> Bool) -> Bool {
        authorizedTurn = nil
        guard enabled else { return true }
        guard ScreenPermissionAccess.allowed(preflight: preflight, request: request) else { return false }
        authorizedTurn = turn; return true
    }
    func mayCapture(turn: UUID, preflight: () -> Bool) -> Bool {
        authorizedTurn == turn && preflight()
    }
    mutating func cancel() { authorizedTurn = nil }
}

/// Short fixed labels keep the existing context menu bounded. Detail remains available
/// to accessibility and an explicit Copy details action, never a scrolling error window.
enum CompanionIssue: CaseIterable, Equatable {
    case files, speech, voice, screenPermission, screenCapture, vision, engine, unknown
    var title: String {
        switch self {
        case .files: return "App files need repair"
        case .speech: return "Speech unavailable"
        case .voice: return "Voice unavailable"
        case .screenPermission: return "Screen access needed"
        case .screenCapture: return "Screen capture failed"
        case .vision: return "Vision unavailable"
        case .engine: return "Local answer unavailable"
        case .unknown: return "Couldn't finish this turn"
        }
    }
    var retryTitle: String {
        switch self {
        case .files: return "Retry file check"
        case .speech: return "Try microphone again"
        case .voice: return "Retry voice"
        case .screenPermission: return "Retry screen access"
        case .screenCapture, .vision: return "Retry with screen"
        case .engine, .unknown: return "Try again"
        }
    }
    static func copiedDiagnostic(readiness: CompanionReadiness, issue: Self?) -> String {
        let preparation: String
        switch readiness {
        case .checking: preparation = "checking"
        case .paused: preparation = "paused"
        case .unavailable: preparation = "unavailable"
        case .ready: preparation = "ready"
        }
        return "Dot diagnostic summary\nPreparation: \(preparation)\nIssue: \(issue?.title ?? (readiness.isIssue ? Self.files.title : "None"))"
    }
    static func menuHeader(readiness: CompanionReadiness, issue: Self?, progress: Double) -> String? {
        switch readiness {
        case .checking:
            let value = progress.isFinite ? min(1, max(0, progress)) : 0
            return "Checking files, \(Int(value * 100))%"
        case .paused: return "File check paused"
        case .unavailable: return Self.files.title
        case .ready: return issue?.title
        }
    }
}

/// Same-turn followup policy; the controller supplies successful final audible playback.
/// A question ID must come from a validated explicit question contract, never punctuation.
struct QuestionReplyGate {
    static let maximumAutomaticReplies = 3
    static let playbackSettleSeconds = 0.4
    // Bounds stale playback-to-capture handoff, not the configurable invitation to speak.
    static let invitationLifetimeSeconds = 8.0
    private var turn: UUID?
    private var question: UUID?
    private var playbackEndedAt: Double?
    private var repliesUsed = 0
    private var responseFinalized = false
    private var explicitConversation = false
    private var issuedContinuation: UUID?
    private var issuedAt: Double?

    mutating func begin(turn: UUID, explicitClick: Bool, continuation: UUID? = nil, now: Double = 0) {
        guard now.isFinite else { cancel(); return }
        if explicitClick { explicitConversation = true; repliesUsed = 0 }
        else {
            guard explicitConversation, let issuedContinuation, continuation == issuedContinuation,
                  let issuedAt, now >= issuedAt, now - issuedAt <= 1 else { cancel(); return }
        }
        issuedContinuation = nil; issuedAt = nil
        self.turn = turn; question = nil; playbackEndedAt = nil; responseFinalized = false
    }
    mutating func responseFinished(turn: UUID, question: UUID?, succeeded: Bool) {
        guard explicitConversation, self.turn == turn, !responseFinalized else { return }
        responseFinalized = true
        guard succeeded, let question else { cancel(); return }
        self.question = question
        // Earlier/intermediate TTS drain can never satisfy a final question's playback.
        playbackEndedAt = nil
    }
    mutating func questionPlayed(turn: UUID, question: UUID, now: Double) {
        guard self.turn == turn, self.question == question, playbackEndedAt == nil, now.isFinite else { return }
        playbackEndedAt = now
    }
    mutating func consume(turn: UUID, now: Double, ready: Bool, microphoneAuthorized: Bool,
                          screenAuthorized: Bool, interacting: Bool) -> UUID? {
        guard self.turn == turn else { return nil }
        guard ready, microphoneAuthorized, screenAuthorized, !interacting, now.isFinite,
              repliesUsed < Self.maximumAutomaticReplies else { cancel(); return nil }
        guard let question, let played = playbackEndedAt else { return nil }
        guard now >= played, now - played <= Self.invitationLifetimeSeconds else { cancel(); return nil }
        guard now - played >= Self.playbackSettleSeconds else { return nil }
        repliesUsed += 1; issuedContinuation = question; issuedAt = now
        self.turn = nil; self.question = nil; playbackEndedAt = nil
        return question
    }
    mutating func cancel() {
        turn = nil; question = nil; playbackEndedAt = nil
        explicitConversation = false; issuedContinuation = nil; issuedAt = nil
    }
}

/// Strict parser for the pinned Splash streamed tool-call contract. It grants no microphone authority.
/// The controller still needs same-turn success plus the final question's actual playback completion.
struct QuestionIntentStream {
    struct Question: Equatable, Sendable { let text: String }
    enum ToolAction: Equatable, Sendable {
        case typeText(String)
        case pressKey(String)
    }
    enum Failure: Error { case invalid }
    // The one-field tool argument object uses strict JSON punctuation before Foundation decoding.
    // This prevents duplicate keys/trailing commas from being normalized into a valid dictionary.
    private static let questionObjectPattern = #"\A[ \t\r\n]*\{[ \t\r\n]*"question"[ \t\r\n]*:[ \t\r\n]*"(?:[^"\\\x00-\x1F]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"[ \t\r\n]*\}[ \t\r\n]*\z"#
    private static let textObjectPattern = #"\A[ \t\r\n]*\{[ \t\r\n]*"text"[ \t\r\n]*:[ \t\r\n]*"(?:[^"\\\x00-\x1F]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"[ \t\r\n]*\}[ \t\r\n]*\z"#
    private static let keyObjectPattern = #"\A[ \t\r\n]*\{[ \t\r\n]*"key"[ \t\r\n]*:[ \t\r\n]*"(?:[^"\\\x00-\x1F]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"[ \t\r\n]*\}[ \t\r\n]*\z"#
    private static let allowedToolNames: Set<String> = ["ask_user", "type_text", "press_key"]
    private var callID: String?
    private var functionName: String?
    private var arguments = ""
    private var terminal: String?
    private var sawCall = false
    private var done = false
    private var invalid = false

    mutating func feed(_ line: String) throws {
        guard !invalid else { throw Failure.invalid }
        do { try append(line) } catch { invalid = true; throw Failure.invalid }
    }
    private mutating func append(_ line: String) throws {
        guard line.utf8.count <= 262_144 else { throw Failure.invalid }
        guard line.hasPrefix("data:") else { return }
        let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !done else { throw Failure.invalid }
        if value == "[DONE]" { done = true; return }
        guard let data = value.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let choices = object["choices"] as? [[String: Any]], choices.count <= 1 else { throw Failure.invalid }
        // A terminal usage-only chunk may contain no choices.
        guard let choice = choices.first else { return }
        if let index = choice["index"] { guard Self.zero(index) else { throw Failure.invalid } }
        let delta: [String: Any]
        if let value = choice["delta"] {
            guard let object = value as? [String: Any] else { throw Failure.invalid }
            delta = object
        } else { delta = [:] }
        guard delta["function_call"] == nil else { throw Failure.invalid }
        if let role = delta["role"] { guard role as? String == "assistant" else { throw Failure.invalid } }
        for field in ["content", "reasoning_content"] {
            if let value = delta[field], !(value is NSNull) {
                guard let text = value as? String else { throw Failure.invalid }
                // Once a call starts, no later spoken content can follow the final question.
                if sawCall && !text.isEmpty { throw Failure.invalid }
            }
        }
        if let callsValue = delta["tool_calls"] {
            guard terminal == nil, let calls = callsValue as? [[String: Any]], calls.count == 1,
                  let call = calls.first, let index = call["index"], Self.zero(index) else { throw Failure.invalid }
            sawCall = true
            if let value = call["id"] {
                guard let id = value as? String, id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
                      callID == nil || callID == id else { throw Failure.invalid }
                callID = id
            }
            if let type = call["type"] { guard type as? String == "function" else { throw Failure.invalid } }
            guard let function = call["function"] as? [String: Any] else { throw Failure.invalid }
            if let name = function["name"] {
                guard let nameStr = name as? String, Self.allowedToolNames.contains(nameStr),
                      functionName == nil || functionName == nameStr else { throw Failure.invalid }
                functionName = nameStr
            }
            if let fragment = function["arguments"] {
                guard let fragment = fragment as? String, arguments.utf8.count + fragment.utf8.count <= 2048 else { throw Failure.invalid }
                arguments += fragment
            }
        } else if terminal != nil && !delta.isEmpty { throw Failure.invalid }
        if let reason = choice["finish_reason"], !(reason is NSNull) {
            guard terminal == nil, let reason = reason as? String else { throw Failure.invalid }
            terminal = reason
        }
    }
    func completed() throws -> Question? {
        guard !invalid, done else { throw Failure.invalid }
        guard sawCall else {
            guard terminal == "stop" else { throw Failure.invalid }
            return nil
        }
        guard terminal == "tool_calls", callID != nil, let functionName else { throw Failure.invalid }
        if functionName == "type_text" || functionName == "press_key" {
            _ = try completedToolAction()
            return nil
        }
        guard functionName == "ask_user",
              arguments.range(of: Self.questionObjectPattern, options: .regularExpression) != nil,
              let data = arguments.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["question"], let text = object["question"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 400, text.utf8.count <= 1600,
              text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw Failure.invalid }
        return Question(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func completedToolAction() throws -> ToolAction? {
        guard !invalid, done, sawCall else { return nil }
        guard terminal == "tool_calls", callID != nil, let functionName else { throw Failure.invalid }
        switch functionName {
        case "type_text":
            guard arguments.range(of: Self.textObjectPattern, options: .regularExpression) != nil,
                  let data = arguments.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["text"],
                  let text = object["text"] as? String,
                  !text.isEmpty,
                  text.count <= 1500,
                  text.utf8.count <= 2048 else { throw Failure.invalid }
            return .typeText(text)
        case "press_key":
            guard arguments.range(of: Self.keyObjectPattern, options: .regularExpression) != nil,
                  let data = arguments.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["key"],
                  let key = object["key"] as? String else { throw Failure.invalid }
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty, trimmedKey.count <= 100 else { throw Failure.invalid }
            return .pressKey(trimmedKey)
        default:
            return nil
        }
    }
    private static func zero(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 0
    }
}


/// Synthesis/drain events are not audible completion. Only successful player callbacks retire
/// an enqueued request; the producer must seal after its last sentence and validated question.
struct FinalPlaybackBarrier {
    private var turn: UUID?
    private var outstanding: Set<UUID> = []
    private var enqueued: Set<UUID> = []
    private var sealed = false
    private var emitted = false

    mutating func begin(turn: UUID) { cancel(); self.turn = turn }
    mutating func enqueue(turn: UUID, request: UUID) -> Bool {
        guard self.turn == turn, !sealed, !emitted, !enqueued.contains(request) else { return false }
        enqueued.insert(request); outstanding.insert(request); return true
    }
    mutating func generationComplete(turn: UUID) -> UUID? {
        guard self.turn == turn else { return nil }
        sealed = true; return completion()
    }
    mutating func playbackFinished(turn: UUID, request: UUID, successfully: Bool) -> UUID? {
        guard self.turn == turn, outstanding.contains(request) else { return nil }
        guard successfully else { cancel(); return nil }
        outstanding.remove(request); return completion()
    }
    private mutating func completion() -> UUID? {
        guard let turn, sealed, !enqueued.isEmpty, outstanding.isEmpty, !emitted else { return nil }
        emitted = true; return turn
    }
    mutating func cancel() {
        turn = nil; outstanding.removeAll(); enqueued.removeAll(); sealed = false; emitted = false
    }
}

/// Hardware requirements verification and production launch gate.
/// Target Minimum Specification: Apple Silicon M4 Pro, M5, or newer, 48 GB Unified Memory, macOS 27.
public struct HardwareCompatibility: Sendable {
    public struct SystemInfo: Equatable, Sendable {
        public let chip: String
        public let ramGB: Int
        public let osMajor: Int
        public let osMinor: Int
        public let osPatch: Int
        public let isAppleSilicon: Bool

        public init(chip: String, ramGB: Int, osMajor: Int, osMinor: Int = 0, osPatch: Int = 0, isAppleSilicon: Bool = true) {
            self.chip = chip
            self.ramGB = ramGB
            self.osMajor = osMajor
            self.osMinor = osMinor
            self.osPatch = osPatch
            self.isAppleSilicon = isAppleSilicon
        }

        public var osString: String {
            "\(osMajor).\(osMinor).\(osPatch)"
        }

        public var meetsChipSpec: Bool {
            guard isAppleSilicon else { return false }
            if let match = chip.range(of: #"M(\d+)"#, options: .regularExpression) {
                let numStr = chip[match].dropFirst()
                if let gen = Int(numStr) {
                    if gen >= 5 { return true }
                    if gen == 4 {
                        let upper = chip.uppercased()
                        return upper.contains("PRO") || upper.contains("MAX") || upper.contains("ULTRA")
                    }
                }
            }
            return false
        }

        public var meetsRAMSpec: Bool {
            ramGB >= 48
        }

        public var meetsOSSpec: Bool {
            osMajor >= 27
        }

        public var meetsAllSpecs: Bool {
            meetsChipSpec && meetsRAMSpec && meetsOSSpec
        }

        public var technicalImpossibilityReason: String? {
            if !isAppleSilicon {
                return "Intel processors are not supported. Dot requires Apple Silicon architecture."
            }
            if ramGB < 24 {
                return "This Mac has \(ramGB) GB of Unified Memory. Dot runs a 27B model (Qwen 3.8 27B 4-bit) requiring a minimum of 24 GB Unified Memory to load."
            }
            if osMajor < 15 {
                return "macOS \(osMajor) is unsupported. Dot requires macOS 15 or newer (macOS 27 recommended)."
            }
            return nil
        }

        public var belowSpecReasons: [String] {
            var reasons: [String] = []
            if !meetsChipSpec {
                reasons.append("Processor (\(chip)) is below recommended M4 Pro, M5 or newer.")
            }
            if !meetsRAMSpec {
                reasons.append("Unified Memory (\(ramGB) GB) is below recommended 48 GB.")
            }
            if !meetsOSSpec {
                reasons.append("Operating System (macOS \(osString)) is below recommended macOS 27.")
            }
            return reasons
        }
    }

    public enum Status: Equatable, Sendable {
        case compatible(SystemInfo)
        case belowMinimum(SystemInfo, reasons: [String])
        case technicallyImpossible(SystemInfo, reason: String)
    }

    public static func queryCurrent() -> SystemInfo {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let chipName = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines)

        let mem = ProcessInfo.processInfo.physicalMemory
        let ramGB = Int(round(Double(mem) / (1024.0 * 1024.0 * 1024.0)))
        let os = ProcessInfo.processInfo.operatingSystemVersion

        #if arch(arm64)
        let defaultChip = "Apple Silicon"
        let isArm = true
        #else
        let defaultChip = "Intel"
        let isArm = false
        #endif

        return SystemInfo(
            chip: chipName.isEmpty ? defaultChip : chipName,
            ramGB: ramGB,
            osMajor: os.majorVersion,
            osMinor: os.minorVersion,
            osPatch: os.patchVersion,
            isAppleSilicon: isArm
        )
    }

    public static func evaluate(info: SystemInfo = queryCurrent()) -> Status {
        if let impossible = info.technicalImpossibilityReason {
            return .technicallyImpossible(info, reason: impossible)
        }
        let reasons = info.belowSpecReasons
        if !reasons.isEmpty {
            return .belowMinimum(info, reasons: reasons)
        }
        return .compatible(info)
    }

    public static func statusSummary(info: SystemInfo = queryCurrent()) -> String {
        switch evaluate(info: info) {
        case .compatible(let current):
            return "Hardware fully compatible! Your Mac (\(current.chip), \(current.ramGB) GB Unified Memory, macOS \(current.osString)) meets all target minimum specifications (Apple Silicon M4 Pro or M5+, 48 GB RAM, macOS 27+)."
        case .belowMinimum(let current, let reasons):
            let details = reasons.joined(separator: " ")
            return "Hardware below target minimum specification: \(current.chip), \(current.ramGB) GB Unified Memory, macOS \(current.osString). \(details) Target minimum is Apple Silicon M4 Pro or M5+, 48 GB Unified Memory, and macOS 27."
        case .technicallyImpossible(let current, let reason):
            return "Hardware incompatible: \(current.chip), \(current.ramGB) GB RAM, macOS \(current.osString). Reason: \(reason)"
        }
    }

    #if canImport(AppKit)
    @MainActor
    public static func verifyOnLaunch() -> Bool {
        let status = evaluate()
        switch status {
        case .compatible:
            return true

        case .belowMinimum(let info, let reasons):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Hardware Below Target Specification"
            let items = reasons.map { "• " + $0 }.joined(separator: "\n")
            alert.informativeText = "Running Dot on this hardware is not recommended. You may experience slow responses or heavy memory pressure.\n\n" +
                "Target Minimum Specification:\n" +
                "• Apple Silicon M4 Pro, M5, or newer\n" +
                "• 48 GB Unified Memory\n" +
                "• macOS 27 or newer\n\n" +
                "Detected on this Mac:\n" +
                "• Processor: \(info.chip)\n" +
                "• Memory: \(info.ramGB) GB Unified Memory\n" +
                "• Operating System: macOS \(info.osString)\n\n" +
                "Items below specification:\n" +
                items + "\n\n" +
                "Would you like to stop or run anyway?"
            let stopButton = alert.addButton(withTitle: "Stop")
            stopButton.keyEquivalent = "\r"
            alert.addButton(withTitle: "Run Anyway")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSApplication.shared.terminate(nil)
                return false
            }
            return true

        case .technicallyImpossible(let info, let reason):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Hardware Incompatible with Dot"
            alert.informativeText = "Dot cannot run on this machine.\n\n" +
                "Detected:\n" +
                "• Processor: \(info.chip)\n" +
                "• Memory: \(info.ramGB) GB Unified Memory\n" +
                "• Operating System: macOS \(info.osString)\n\n" +
                "Reason:\n\(reason)\n\n" +
                "Target Minimum Specification:\n" +
                "• Apple Silicon M4 Pro, M5, or newer\n" +
                "• 48 GB Unified Memory\n" +
                "• macOS 27 or newer"
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return false
        }
    }

    @MainActor
    public static func showStatusAlert() {
        let status = evaluate()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch status {
        case .compatible(let info):
            alert.alertStyle = .informational
            alert.messageText = "Hardware Fully Compatible"
            alert.informativeText = "Your Mac meets or exceeds all target minimum specifications for Dot.\n\n" +
                "• Processor: \(info.chip) (M4 Pro, M5 or newer)\n" +
                "• Memory: \(info.ramGB) GB Unified Memory (48 GB minimum)\n" +
                "• Operating System: macOS \(info.osString) (macOS 27+)\n\n" +
                "Dot runs the local Qwen 3.8 27B 4-bit model at optimal performance."
            alert.addButton(withTitle: "OK")

        case .belowMinimum(let info, let reasons):
            alert.alertStyle = .warning
            alert.messageText = "Hardware Below Target Specification"
            let items = reasons.map { "• " + $0 }.joined(separator: "\n")
            alert.informativeText = "Target Minimum: Apple Silicon M4 Pro/M5+, 48 GB Unified Memory, macOS 27+\n\n" +
                "Detected on this Mac:\n" +
                "• Processor: \(info.chip)\n" +
                "• Memory: \(info.ramGB) GB Unified Memory\n" +
                "• Operating System: macOS \(info.osString)\n\n" +
                "Notes:\n\(items)\n\n" +
                "(Running under user override)"
            alert.addButton(withTitle: "OK")

        case .technicallyImpossible(let info, let reason):
            alert.alertStyle = .critical
            alert.messageText = "Hardware Incompatible"
            alert.informativeText = "Reason: \(reason)\n\n" +
                "Detected:\n" +
                "• Processor: \(info.chip)\n" +
                "• Memory: \(info.ramGB) GB\n" +
                "• macOS: \(info.osString)"
            alert.addButton(withTitle: "OK")
        }
        alert.runModal()
    }
    #endif
}

// MARK: - Active Desktop Context

/// Captures active user desktop context (frontmost app, window title, and highlighted selection).
public struct ActiveDesktopContext: Equatable {
    public let appName: String?
    public let windowTitle: String?
    public let selectedText: String?

    public init(appName: String?, windowTitle: String?, selectedText: String?) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.selectedText = selectedText
    }

    public var promptContextSnippet: String? {
        var parts: [String] = []
        if let app = appName, !app.isEmpty {
            if let win = windowTitle, !win.isEmpty {
                parts.append("Active App: \(app) (\"\(win)\")")
            } else {
                parts.append("Active App: \(app)")
            }
        }
        if let sel = selectedText, !sel.isEmpty {
            let truncated = sel.count > 1500 ? String(sel.prefix(1500)) + "…" : sel
            parts.append("User highlighted selection: \"\(truncated)\"")
        }
        guard !parts.isEmpty else { return nil }
        return "[" + parts.joined(separator: " | ") + "]"
    }

    #if canImport(AppKit)
    @MainActor
    public static func current() -> ActiveDesktopContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let isOwnApp = frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let appName = !isOwnApp ? frontApp?.localizedName : nil
        var windowTitle: String? = nil
        var selectedText: String? = nil

        if let frontApp = frontApp, !isOwnApp {
            let pid = frontApp.processIdentifier
            #if canImport(CoreGraphics)
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let frontWindows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            for w in frontWindows {
                if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                    windowTitle = name
                    break
                }
            }
            #endif

            #if canImport(ApplicationServices)
            let appRef = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused = focused {
                var selected: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
                   let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedText = String(text.prefix(2000))
                }
            }
            #endif
        }
        return ActiveDesktopContext(appName: appName, windowTitle: windowTitle, selectedText: selectedText)
    }
    #endif
}

// MARK: - Smart Timers & Reminders

public struct ScheduledTimer: Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let durationSeconds: Double
    public let fireDate: Date
    public var remainingSeconds: Double { max(0, fireDate.timeIntervalSinceNow) }

    public init(id: UUID = UUID(), label: String, durationSeconds: Double, fireDate: Date) {
        self.id = id
        self.label = label
        self.durationSeconds = durationSeconds
        self.fireDate = fireDate
    }
}

public enum TimerCommand: Equatable {
    case create(seconds: Double, label: String)
    case cancel(label: String?)
    case list
    case none
}

public enum SmartTimerParser {
    public static func parse(_ text: String) -> TimerCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "cancel timer" || lower == "stop timer" || lower == "clear timer" || lower == "cancel timers" {
            return .cancel(label: nil)
        }
        if lower == "timers" || lower == "show timers" || lower == "list timers" || lower == "check timer" || lower == "my timers" {
            return .list
        }

        let pattern = #"(?:set\s+(?:a\s+)?timer\s+(?:for\s+)?|timer\s+(?:for\s+)?|remind\s+me\s+in\s+)(\d+(?:\.\d+)?)\s*(seconds?|sec|s|minutes?|min|m|hours?|hr|h)\b(?:\s+(?:to|for)\s+(.+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return .none }
        let nsString = lower as NSString
        guard let match = regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: nsString.length)) else {
            return .none
        }

        let numberStr = nsString.substring(with: match.range(at: 1))
        let unitStr = nsString.substring(with: match.range(at: 2)).lowercased()
        guard let value = Double(numberStr), value > 0 else { return .none }

        let seconds: Double
        if unitStr.hasPrefix("s") {
            seconds = value
        } else if unitStr.hasPrefix("m") {
            seconds = value * 60.0
        } else if unitStr.hasPrefix("h") {
            seconds = value * 3600.0
        } else {
            return .none
        }

        var label = "Timer"
        if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound {
            let userLabel = nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !userLabel.isEmpty {
                label = userLabel
            }
        }
        return .create(seconds: seconds, label: label)
    }
}

public final class SmartTimerScheduler: @unchecked Sendable {
    public static let shared = SmartTimerScheduler()
    private let lock = NSLock()
    private var timers: [UUID: (timer: ScheduledTimer, task: Task<Void, Never>)] = [:]

    private init() {}

    public func schedule(seconds: Double, label: String, onFire: @escaping @Sendable (ScheduledTimer) -> Void = { _ in }) -> ScheduledTimer {
        let fireDate = Date().addingTimeInterval(seconds)
        let scheduled = ScheduledTimer(label: label, durationSeconds: seconds, fireDate: fireDate)
        let id = scheduled.id

        let task = Task {
            let ms = UInt64(max(0.1, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ms)
            guard !Task.isCancelled else { return }
            self.remove(id)
            onFire(scheduled)
        }

        lock.lock()
        timers[id] = (scheduled, task)
        lock.unlock()
        return scheduled
    }

    public func cancelAll() -> Int {
        lock.lock()
        let count = timers.count
        for (_, entry) in timers {
            entry.task.cancel()
        }
        timers.removeAll()
        lock.unlock()
        return count
    }

    public func activeTimers() -> [ScheduledTimer] {
        lock.lock()
        defer { lock.unlock() }
        return timers.values.map { $0.timer }.sorted { $0.fireDate < $1.fireDate }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        timers.removeValue(forKey: id)
        lock.unlock()
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes) minute\(minutes > 1 ? "s" : "")"
        } else {
            return "\(secs) second\(secs != 1 ? "s" : "")"
        }
    }
}

// MARK: - Native Screen OCR

#if canImport(Vision)
import Vision

public struct ScreenOCRLine: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(text: String, confidence: Float = 1.0, boundingBox: CGRect = .zero) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public enum NativeScreenOCR {
    public static func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) async -> [ScreenOCRLine] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                var lines: [ScreenOCRLine] = []
                for obs in observations {
                    if let candidate = obs.topCandidates(1).first {
                        lines.append(ScreenOCRLine(
                            text: candidate.string,
                            confidence: candidate.confidence,
                            boundingBox: obs.boundingBox
                        ))
                    }
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
#endif

// MARK: - Clipboard Intelligence

public enum ClipboardCommand: Equatable {
    case read
    case clear
    case copy(text: String)
    case summarize
    case explain
    case translate(language: String)
    case none
}

public enum ClipboardIntelligence {
    public static func parseCommand(_ text: String) -> ClipboardCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "clipboard" || lower == "read clipboard" || lower == "what is on my clipboard" || lower == "show clipboard" || lower == "check clipboard" {
            return .read
        }
        if lower == "clear clipboard" || lower == "empty clipboard" {
            return .clear
        }
        if lower.hasPrefix("copy to clipboard ") {
            let content = String(text.dropFirst("copy to clipboard ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .copy(text: content)
        }
        if lower == "summarize clipboard" || lower == "summarize my clipboard" {
            return .summarize
        }
        if lower == "explain clipboard" || lower == "explain my clipboard" || lower == "explain code on clipboard" {
            return .explain
        }
        if lower.hasPrefix("translate clipboard to ") {
            let lang = String(lower.dropFirst("translate clipboard to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .translate(language: lang)
        }
        return .none
    }

    public static func read() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func write(_ text: String) -> Bool {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
        #else
        return false
        #endif
    }

    public static func clear() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        #endif
    }
}

// MARK: - System Control Suite

public enum SystemControlCommand: Equatable {
    case toggleDarkMode
    case setDarkMode(enabled: Bool)
    case muteVolume
    case unmuteVolume
    case lockScreen
    case findFile(name: String)
    case none
}

public enum SystemControlSuite {
    public static func parseCommand(_ text: String) -> SystemControlCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "toggle dark mode" || lower == "switch dark mode" {
            return .toggleDarkMode
        }
        if lower == "dark mode on" || lower == "enable dark mode" || lower == "turn on dark mode" {
            return .setDarkMode(enabled: true)
        }
        if lower == "dark mode off" || lower == "disable dark mode" || lower == "turn off dark mode" || lower == "light mode" {
            return .setDarkMode(enabled: false)
        }
        if lower == "mute" || lower == "mute volume" || lower == "mute audio" || lower == "silence audio" {
            return .muteVolume
        }
        if lower == "unmute" || lower == "unmute volume" || lower == "unmute audio" {
            return .unmuteVolume
        }
        if lower == "lock screen" || lower == "lock mac" || lower == "lock my mac" {
            return .lockScreen
        }
        if lower.hasPrefix("find file ") || lower.hasPrefix("locate file ") || lower.hasPrefix("search file ") {
            let prefix = lower.hasPrefix("find file ") ? "find file " : (lower.hasPrefix("locate file ") ? "locate file " : "search file ")
            let name = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return .findFile(name: name)
            }
        }
        return .none
    }

    #if canImport(AppKit)
    @MainActor
    public static func execute(_ command: SystemControlCommand) -> String? {
        switch command {
        case .toggleDarkMode:
            let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error == nil ? "Toggled Dark Mode." : "Could not toggle Dark Mode."

        case .setDarkMode(let enabled):
            let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled)"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error == nil ? (enabled ? "Dark Mode enabled." : "Light Mode enabled.") : "Could not change appearance."

        case .muteVolume:
            let script = "set volume output muted true"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error == nil ? "Audio muted." : "Could not mute audio."

        case .unmuteVolume:
            let script = "set volume output muted false"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error == nil ? "Audio unmuted." : "Could not unmute audio."

        case .lockScreen:
            let script = "tell application \"System Events\" to sleep"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error == nil ? "Putting display to sleep." : "Could not lock screen."

        case .findFile(let name):
            let results = findFilesSpotlight(named: name, limit: 5)
            if results.isEmpty {
                return "No files found matching \"\(name)\"."
            } else {
                let items = results.map { "• " + $0 }.joined(separator: "\n")
                return "Found \(results.count) matching file\(results.count > 1 ? "s" : ""):\n\(items)"
            }

        case .none:
            return nil
        }
    }

    public static func findFilesSpotlight(named: String, limit: Int = 5) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", named]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            let lines = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            return Array(lines.prefix(limit))
        } catch {
            return []
        }
    }
    #endif
}

// MARK: - In-Place App Typing & Key-Press Actions

#if canImport(ApplicationServices)
import ApplicationServices
#endif

public enum InPlaceTypingCommand: Equatable, Sendable {
    case type(text: String)
    case pressKey(key: String)
    case typeAndSubmit(text: String)
    case none
}

public enum InPlaceAppTyping {
    public struct KeySpec: Equatable, Sendable {
        public let keyCode: UInt16
        public let flags: UInt64
        public let displayName: String

        public init(keyCode: UInt16, flags: UInt64 = 0, displayName: String) {
            self.keyCode = keyCode
            self.flags = flags
            self.displayName = displayName
        }
    }

    public static let accessibilityPermissionPromptMessage =
        "I need Accessibility permission to type or press keys into other apps. Please grant Dot access in System Settings > Privacy & Security > Accessibility."

    private static let lock = NSLock()
    private static var lastExternalAppPID: pid_t?
    private static var lastExternalAppName: String?

    public static func noteExternalApplication(pid: pid_t, name: String?) {
        lock.lock()
        lastExternalAppPID = pid
        if let name, !name.isEmpty {
            lastExternalAppName = name
        }
        lock.unlock()
    }

    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        #if canImport(ApplicationServices)
        if AXIsProcessTrusted() {
            return true
        }
        if promptIfNeeded {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            #if canImport(AppKit)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            #endif
        }
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    public static func prepareFocusedTargetApp() -> String? {
        let ownBundleID = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != ownBundleID {
            noteExternalApplication(pid: front.processIdentifier, name: front.localizedName)
            return front.localizedName
        }

        // Dot's own panel is currently frontmost; restore focus to the previous external app.
        lock.lock()
        let savedPID = lastExternalAppPID
        let savedName = lastExternalAppName
        lock.unlock()

        if let savedPID,
           let app = NSRunningApplication(processIdentifier: savedPID),
           !app.isTerminated,
           app.bundleIdentifier != ownBundleID {
            app.activate()
            usleep(75_000)
            return app.localizedName ?? savedName
        }

        #if canImport(CoreGraphics)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            noteExternalApplication(pid: pid, name: app.localizedName)
            app.activate()
            usleep(75_000)
            return app.localizedName
        }
        #endif

        return savedName
    }
    #endif

    public static func parseKeySpec(_ raw: String) -> KeySpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split modifier combinations like "Cmd+C", "Command + Shift + Z", "Ctrl-C", "Shift+Enter"
        let normalized = trimmed
            .replacingOccurrences(of: " + ", with: "+")
            .replacingOccurrences(of: "+", with: " ")
        let rawTokens = normalized.split(whereSeparator: \.isWhitespace).map { String($0) }
        let tokens: [String]
        if rawTokens.count == 1 && trimmed.contains("-") && trimmed.count > 1 {
            tokens = trimmed.split(separator: "-").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            tokens = rawTokens
        }
        guard !tokens.isEmpty else { return nil }

        let cmdMask: UInt64 = 0x100000     // CGEventFlags.maskCommand
        let shiftMask: UInt64 = 0x020000   // CGEventFlags.maskShift
        let altMask: UInt64 = 0x080000     // CGEventFlags.maskAlternate
        let ctrlMask: UInt64 = 0x040000    // CGEventFlags.maskControl

        var flags: UInt64 = 0
        var modNames: [String] = []
        var baseToken: String?

        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            let isLast = (index == tokens.count - 1)
            if !isLast {
                switch lower {
                case "cmd", "command", "⌘", "meta", "super":
                    if (flags & cmdMask) == 0 { flags |= cmdMask; modNames.append("Cmd") }
                    continue
                case "shift", "⇧":
                    if (flags & shiftMask) == 0 { flags |= shiftMask; modNames.append("Shift") }
                    continue
                case "opt", "option", "alt", "⌥":
                    if (flags & altMask) == 0 { flags |= altMask; modNames.append("Option") }
                    continue
                case "ctrl", "control", "⌃":
                    if (flags & ctrlMask) == 0 { flags |= ctrlMask; modNames.append("Ctrl") }
                    continue
                default:
                    break
                }
            }
            if baseToken == nil {
                baseToken = token
            } else {
                baseToken = (baseToken ?? "") + "_" + token
            }
        }

        guard let keyStr = baseToken?.lowercased() else { return nil }

        let specialKeys: [String: (code: UInt16, label: String)] = [
            "enter": (36, "Enter"),
            "return": (36, "Enter"),
            "ret": (36, "Enter"),
            "⏎": (36, "Enter"),
            "↩": (36, "Enter"),
            "kp_enter": (76, "Enter"),
            "numpad_enter": (76, "Enter"),
            "tab": (48, "Tab"),
            "⇥": (48, "Tab"),
            "space": (49, "Space"),
            "spacebar": (49, "Space"),
            "space_bar": (49, "Space"),
            "␣": (49, "Space"),
            "backspace": (51, "Backspace"),
            "delete": (51, "Backspace"),
            "del": (51, "Backspace"),
            "bksp": (51, "Backspace"),
            "⌫": (51, "Backspace"),
            "forwarddelete": (117, "Forward Delete"),
            "forward_delete": (117, "Forward Delete"),
            "fwddel": (117, "Forward Delete"),
            "⌦": (117, "Forward Delete"),
            "escape": (53, "Escape"),
            "esc": (53, "Escape"),
            "⎋": (53, "Escape"),
            "up": (126, "Up Arrow"),
            "uparrow": (126, "Up Arrow"),
            "up_arrow": (126, "Up Arrow"),
            "arrowup": (126, "Up Arrow"),
            "arrow_up": (126, "Up Arrow"),
            "↑": (126, "Up Arrow"),
            "down": (125, "Down Arrow"),
            "downarrow": (125, "Down Arrow"),
            "down_arrow": (125, "Down Arrow"),
            "arrowdown": (125, "Down Arrow"),
            "arrow_down": (125, "Down Arrow"),
            "↓": (125, "Down Arrow"),
            "left": (123, "Left Arrow"),
            "leftarrow": (123, "Left Arrow"),
            "left_arrow": (123, "Left Arrow"),
            "arrowleft": (123, "Left Arrow"),
            "arrow_left": (123, "Left Arrow"),
            "←": (123, "Left Arrow"),
            "right": (124, "Right Arrow"),
            "rightarrow": (124, "Right Arrow"),
            "right_arrow": (124, "Right Arrow"),
            "arrowright": (124, "Right Arrow"),
            "arrow_right": (124, "Right Arrow"),
            "→": (124, "Right Arrow"),
            "home": (115, "Home"),
            "end": (119, "End"),
            "pageup": (116, "Page Up"),
            "page_up": (116, "Page Up"),
            "pgup": (116, "Page Up"),
            "pagedown": (121, "Page Down"),
            "page_down": (121, "Page Down"),
            "pgdn": (121, "Page Down"),
            "f1": (122, "F1"),
            "f2": (120, "F2"),
            "f3": (99, "F3"),
            "f4": (118, "F4"),
            "f5": (96, "F5"),
            "f6": (97, "F6"),
            "f7": (98, "F7"),
            "f8": (100, "F8"),
            "f9": (101, "F9"),
            "f10": (109, "F10"),
            "f11": (103, "F11"),
            "f12": (111, "F12")
        ]

        if let special = specialKeys[keyStr] {
            let label = modNames.isEmpty ? special.label : (modNames + [special.label]).joined(separator: "+")
            return KeySpec(keyCode: special.code, flags: flags, displayName: label)
        }

        let characterKeyCodes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "`": 50
        ]

        if let code = characterKeyCodes[keyStr] {
            let keyLabel = keyStr.uppercased()
            let label = modNames.isEmpty ? keyLabel : (modNames + [keyLabel]).joined(separator: "+")
            return KeySpec(keyCode: code, flags: flags, displayName: label)
        }

        return nil
    }

    public static func parseCommand(_ text: String) -> InPlaceTypingCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return .none }

        var working = trimmed
        let politePrefixes = [
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "please ", "hey dot, ", "hey dot ", "dot, ", "dot ", "just "
        ]
        for prefix in politePrefixes {
            if working.lowercased().hasPrefix(prefix) {
                working = String(working.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lower = working.lowercased()

        // 1. Check for "press <key>" / "hit <key>" / "send <key>"
        let keyVerbs = ["press ", "hit ", "tap ", "send key "]
        for verb in keyVerbs {
            if lower.hasPrefix(verb) {
                var candidate = String(working.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'"))
                if candidate.lowercased().hasPrefix("the ") {
                    candidate = String(candidate.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                for suffix in [" in that input", " into that input", " in the focused app", " into the focused app", " key"] {
                    if candidate.lowercased().hasSuffix(suffix) {
                        candidate = String(candidate.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let spec = parseKeySpec(candidate) {
                    return .pressKey(key: spec.displayName)
                }
            }
        }

        // 2. Explicit prefixes: "type this: ...", "type into app: ...", "dictate: ...", "write into app: ..."
        let explicitPrefixes = ["type this: ", "type this ", "type into app: ", "type into app ", "dictate: ", "write into app: "]
        for prefix in explicitPrefixes {
            if lower.hasPrefix(prefix) {
                let content = String(working.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    return .type(text: content)
                }
            }
        }

        // 3. Natural "type 'hello' in that input" / "type \"Continue\" and press enter" / "type Continue"
        if lower.hasPrefix("type ") && !lower.hasPrefix("type of ") && !lower.hasPrefix("type in ") {
            var remainder = String(working.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            var shouldPressEnter = false
            let enterSuffixes = [" and press enter", " and hit enter", " then press enter", " then hit enter", " and submit"]
            for suffix in enterSuffixes {
                if remainder.lowercased().hasSuffix(suffix) {
                    shouldPressEnter = true
                    remainder = String(remainder.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            let locationSuffixes = [
                " in that input", " into that input", " in the input", " into the input",
                " in that field", " into that field", " in the field", " into the field",
                " in the focused app", " into the focused app", " in focused app", " into focused app",
                " in that box", " into that box", " here", " there"
            ]
            for suffix in locationSuffixes {
                if remainder.lowercased().hasSuffix(suffix) {
                    remainder = String(remainder.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            // Strip matching outer single or double quotes if present
            if (remainder.hasPrefix("'") && remainder.hasSuffix("'") && remainder.count >= 2) ||
               (remainder.hasPrefix("\"") && remainder.hasSuffix("\"") && remainder.count >= 2) ||
               (remainder.hasPrefix("“") && remainder.hasSuffix("”") && remainder.count >= 2) {
                remainder = String(remainder.dropFirst().dropLast())
            }

            if !remainder.isEmpty {
                return shouldPressEnter ? .typeAndSubmit(text: remainder) : .type(text: remainder)
            }
        }

        return .none
    }

    #if canImport(CoreGraphics)
    @discardableResult
    public static func type(text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        // Type character by character so every Unicode grapheme (ASCII, accented, Cyrillic, CJK, emoji)
        // is delivered intact via keyboardSetUnicodeString.
        for character in text {
            var utf16Units = Array(String(character).utf16)
            guard !utf16Units.isEmpty else { continue }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            down.post(tap: .cghidEventTap)
            up.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            up.post(tap: .cghidEventTap)
            usleep(1_500)
        }
        return true
    }

    @discardableResult
    public static func sendKey(_ keyCombo: String) -> Bool {
        guard let spec = parseKeySpec(keyCombo) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(spec.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(spec.keyCode), keyDown: false) else {
            return false
        }
        down.flags = CGEventFlags(rawValue: spec.flags)
        up.flags = CGEventFlags(rawValue: spec.flags)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
    #else
    public static func type(text: String) -> Bool { false }
    public static func sendKey(_ keyCombo: String) -> Bool { false }
    #endif

    @MainActor
    public static func performTypeText(_ text: String, checkPermission: Bool = true) -> (succeeded: Bool, confirmation: String) {
        guard !text.isEmpty else {
            return (false, "No text provided to type.")
        }
        if checkPermission && !isAccessibilityTrusted(promptIfNeeded: true) {
            return (false, accessibilityPermissionPromptMessage)
        }
        #if canImport(AppKit)
        let appName = prepareFocusedTargetApp()
        #else
        let appName: String? = nil
        #endif
        let ok = type(text: text)
        guard ok else {
            return (false, "Could not type text into the focused app.")
        }
        if let appName, !appName.isEmpty {
            return (true, "Typed '\(text)' into \(appName) (the focused app).")
        }
        return (true, "Typed '\(text)' into the focused app.")
    }

    @MainActor
    public static func performPressKey(_ keyCombo: String, checkPermission: Bool = true) -> (succeeded: Bool, confirmation: String) {
        guard let spec = parseKeySpec(keyCombo) else {
            return (false, "Unsupported key '\(keyCombo)'.")
        }
        if checkPermission && !isAccessibilityTrusted(promptIfNeeded: true) {
            return (false, accessibilityPermissionPromptMessage)
        }
        #if canImport(AppKit)
        let appName = prepareFocusedTargetApp()
        #else
        let appName: String? = nil
        #endif
        let ok = sendKey(keyCombo)
        guard ok else {
            return (false, "Could not press \(spec.displayName) in the focused app.")
        }
        if let appName, !appName.isEmpty {
            return (true, "Pressed \(spec.displayName) in \(appName) (the focused app).")
        }
        return (true, "Pressed \(spec.displayName) in the focused app.")
    }
}

// MARK: - 10-Minute Idle Self-Reflection & Antigravity Auto-Suggestion Loop

public final class IdleSelfReflectionEngine: @unchecked Sendable {
    public static let shared = IdleSelfReflectionEngine()
    public static let idleThresholdSeconds: Double = 600.0 // 10 minutes

    private let lock = NSLock()
    private var lastUserActivityAt: Double = ProcessInfo.processInfo.systemUptime
    private var lastReflectionAt: Double = ProcessInfo.processInfo.systemUptime
    private var emittedSuggestions: [String] = []

    public init() {}

    public func recordUserActivity(now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastUserActivityAt = now
        lock.unlock()
    }

    public func shouldTriggerReflection(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.isFinite,
              now - lastUserActivityAt >= Self.idleThresholdSeconds,
              now - lastReflectionAt >= Self.idleThresholdSeconds else {
            return false
        }
        return true
    }

    public func markReflected(now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastReflectionAt = now
        lock.unlock()
    }

    public func analyzeConversationLog(logContent: String) -> String {
        let lines = logContent.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let recentLines = Array(lines.suffix(120))

        // 1. Check for recorded self-improvement failures or errors
        let failureLines = recentLines.filter { $0.contains("[DOT (SELF-IMPROVEMENT)]") || $0.contains("[DOT (ERROR)]") }
        if let latestFailure = failureLines.last {
            let cleaned = latestFailure.replacingOccurrences(of: #"^\[[^\]]+\]\s*\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
            let suggestion = "Dot 10-min self-reflection: I noticed an issue in my recent conversation log (\(cleaned.prefix(180))). Please help improve my handling for this case."
            if recordSuggestionIfNew(suggestion) {
                return suggestion
            }
        }

        // 2. Check for user corrections or repeated commands
        let userLines = recentLines.filter { $0.contains("[USER]") }
        if let lastUser = userLines.last {
            let cleanedUser = lastUser.replacingOccurrences(of: #"^\[[^\]]+\]\s*\[USER\]\s*"#, with: "", options: .regularExpression)
            let candidate = "Dot 10-min self-reflection: Based on our recent conversation about \"\(cleanedUser.prefix(100))\", we could add a dedicated fast-path action, richer visual feedback, and expanded unit tests for this workflow."
            if recordSuggestionIfNew(candidate) {
                return candidate
            }
        }

        // 3. Fallback rotating architectural improvement suggestions
        let fallbacks = [
            "Dot 10-min self-reflection: Let's review my recent conversation logs and add more natural-language aliases for app control, window snapping, and keyboard shortcuts.",
            "Dot 10-min self-reflection: We can improve my proactive screen context awareness by combining OCR text highlights with contextual quick-actions for the active app.",
            "Dot 10-min self-reflection: Let's benchmark my end-to-end voice turn latency and add automated regression checks for multi-turn follow-up questions."
        ]
        lock.lock()
        let index = emittedSuggestions.count % fallbacks.count
        let chosen = fallbacks[index]
        emittedSuggestions.append(chosen)
        lock.unlock()
        return chosen
    }

    private func recordSuggestionIfNew(_ suggestion: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if emittedSuggestions.contains(suggestion) {
            return false
        }
        emittedSuggestions.append(suggestion)
        if emittedSuggestions.count > 32 {
            emittedSuggestions.removeFirst()
        }
        return true
    }

    @MainActor
    public func performReflectionAndWriteToAntigravity(logURL: URL? = nil) -> String {
        markReflected()
        let url = logURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent("dot_chat_log.txt")
        let content = (url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let suggestion = analyzeConversationLog(logContent: content)

        // Always copy to clipboard so it is immediately available
        ClipboardIntelligence.write(suggestion)

        #if canImport(AppKit)
        // If Accessibility is trusted, focus Antigravity (or active editor) and type the suggestion into the input
        if InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: false) {
            let running = NSWorkspace.shared.runningApplications
            if let antigravityApp = running.first(where: {
                let name = ($0.localizedName ?? "").lowercased()
                let bundle = ($0.bundleIdentifier ?? "").lowercased()
                return name.contains("antigravity") || bundle.contains("antigravity")
            }) {
                antigravityApp.activate()
                usleep(100_000)
                _ = InPlaceAppTyping.type(text: suggestion)
                return "Typed self-improvement suggestion into Antigravity: \"\(suggestion)\""
            } else {
                _ = InPlaceAppTyping.performTypeText(suggestion, checkPermission: false)
                return "Typed self-improvement suggestion into the focused app: \"\(suggestion)\""
            }
        }
        #endif
        return "Prepared self-improvement suggestion (copied to clipboard): \"\(suggestion)\""
    }
}

// MARK: - Self-Codebase Indexing & Live Source Reader

public enum SelfCodebaseReader {
    public static let defaultRootPath = "/Users/mac/.gemini/antigravity/scratch/Dot"

    public static func listSwiftFiles(rootPath: String = defaultRootPath) -> [String] {
        let srcPath = (rootPath as NSString).appendingPathComponent("src")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: srcPath) else { return [] }
        return items.filter { $0.hasSuffix(".swift") }.sorted()
    }

    public static func searchCodebase(query: String, rootPath: String = defaultRootPath, maxMatches: Int = 5) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let srcPath = (rootPath as NSString).appendingPathComponent("src")
        let files = listSwiftFiles(rootPath: rootPath)
        var results: [String] = []

        for file in files {
            let fullPath = (srcPath as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                if line.localizedCaseInsensitiveContains(trimmed) {
                    let snippet = line.trimmingCharacters(in: .whitespaces)
                    results.append("\(file):\(idx + 1): \(snippet.prefix(120))")
                    if results.count >= maxMatches {
                        return results
                    }
                }
            }
        }
        return results
    }
}

// MARK: - Native Window Layout & Snapping

public enum WindowSnapLayout: String, Equatable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case center
}

public enum WindowLayoutManager {
    public static func parseCommand(_ text: String) -> WindowSnapLayout? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "snap window left" || lower == "snap left" || lower == "window left half" || lower == "tile window left" {
            return .leftHalf
        }
        if lower == "snap window right" || lower == "snap right" || lower == "window right half" || lower == "tile window right" {
            return .rightHalf
        }
        if lower == "snap window top" || lower == "window top half" {
            return .topHalf
        }
        if lower == "snap window bottom" || lower == "window bottom half" {
            return .bottomHalf
        }
        if lower == "maximize window" || lower == "fullscreen window" || lower == "expand window" {
            return .maximize
        }
        if lower == "center window" || lower == "center active window" {
            return .center
        }
        return nil
    }

    public static func targetFrame(for layout: WindowSnapLayout, in visibleFrame: CGRect) -> CGRect {
        switch layout {
        case .leftHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: floor(visibleFrame.width / 2), height: visibleFrame.height)
        case .rightHalf:
            let half = floor(visibleFrame.width / 2)
            return CGRect(x: visibleFrame.minX + half, y: visibleFrame.minY, width: visibleFrame.width - half, height: visibleFrame.height)
        case .topHalf:
            let half = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: half)
        case .bottomHalf:
            let half = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY + half, width: visibleFrame.width, height: visibleFrame.height - half)
        case .maximize:
            return visibleFrame
        case .center:
            let w = floor(visibleFrame.width * 0.75)
            let h = floor(visibleFrame.height * 0.75)
            return CGRect(x: visibleFrame.minX + floor((visibleFrame.width - w) / 2),
                          y: visibleFrame.minY + floor((visibleFrame.height - h) / 2),
                          width: w, height: h)
        }
    }

    #if canImport(AppKit) && canImport(ApplicationServices)
    @MainActor
    public static func applyLayout(_ layout: WindowSnapLayout) -> String {
        guard InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: true) else {
            return InPlaceAppTyping.accessibilityPermissionPromptMessage
        }
        guard let screen = NSScreen.main else {
            return "Could not determine main display bounds."
        }
        let appName = InPlaceAppTyping.prepareFocusedTargetApp() ?? "the focused app"
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return "No active application window found."
        }
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let windowObj = focusedWindow else {
            return "Could not access focused window of \(appName)."
        }
        let axWindow = windowObj as! AXUIElement
        // Convert AppKit visibleFrame (bottom-left origin) to CG/AX screen coordinates (top-left origin)
        let fullHeight = screen.frame.height
        let vf = screen.visibleFrame
        let axVisible = CGRect(
            x: vf.minX,
            y: fullHeight - vf.maxY,
            width: vf.width,
            height: vf.height
        )
        let rect = targetFrame(for: layout, in: axVisible)
        var pos = CGPoint(x: rect.origin.x, y: rect.origin.y)
        var size = CGSize(width: rect.size.width, height: rect.size.height)
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            _ = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        }
        return "Snapped \(appName) window to \(layout.rawValue)."
    }
    #endif
}

// MARK: - iOS Simulator & Developer Workflow Control

public enum SimulatorCommand: Equatable, Sendable {
    case listBooted
    case openSimulatorApp
    case screenshot
    case none
}

public enum SimulatorControlSuite {
    public static func parseCommand(_ text: String) -> SimulatorCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "list simulators" || lower == "booted simulators" || lower == "check simulator" || lower == "simulator status" {
            return .listBooted
        }
        if lower == "open simulator" || lower == "launch simulator" || lower == "start simulator" {
            return .openSimulatorApp
        }
        if lower == "simulator screenshot" || lower == "take simulator screenshot" {
            return .screenshot
        }
        return .none
    }

    #if canImport(AppKit)
    @MainActor
    public static func execute(_ command: SimulatorCommand) -> String? {
        switch command {
        case .listBooted:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "devices", "booted"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                let booted = output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.contains("(Booted)") }
                if booted.isEmpty {
                    return "No iOS Simulators are currently booted."
                }
                return "Booted Simulators: " + booted.joined(separator: ", ")
            } catch {
                return "Could not query iOS Simulators."
            }
        case .openSimulatorApp:
            let url = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return "Opened iOS Simulator."
            }
            return "Xcode Simulator.app was not found in /Applications/Xcode.app."
        case .screenshot:
            guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
                return "Could not resolve Desktop directory."
            }
            let outURL = desktop.appendingPathComponent("simulator_screenshot_\(Int(Date().timeIntervalSince1970)).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "io", "booted", "screenshot", outURL.path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return "Saved iOS Simulator screenshot to Desktop (\(outURL.lastPathComponent))."
                }
                return "No booted iOS Simulator found to capture screenshot."
            } catch {
                return "Failed to capture iOS Simulator screenshot."
            }
        case .none:
            return nil
        }
    }
    #endif
}

// MARK: - Real-Time Neural Diagnostics & Metrics Inspector

public enum NeuralMetricsInspector {
    public static func isMetricsQuery(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "neural metrics" || lower == "engine metrics" || lower == "memory usage" ||
               lower == "diagnostics" || lower == "performance stats" || lower == "dot diagnostics"
    }

    public static func currentReport(engineReady: Bool, activeTimersCount: Int) -> String {
        let hw = HardwareCompatibility.queryCurrent()
        var residentMB = 0
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            residentMB = Int(info.resident_size / (1024 * 1024))
        }
        let axTrusted = InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: false)
        return "Neural Diagnostics: Model Qwen 3.8 27B 4-bit (Splash) \(engineReady ? "Ready" : "Warming") | Voice Kokoro bf_isabella | App RAM: \(residentMB) MB on \(hw.chip) (\(hw.ramGB) GB Unified) | Accessibility: \(axTrusted ? "Granted" : "Not Granted") | Active Timers: \(activeTimersCount)."
    }
}

// MARK: - Meeting & Focus Mode Awareness

public enum MeetingFocusAwareness {
    public static let knownMeetingAppSignatures: [String] = [
        "zoom.us",
        "us.zoom.xos",
        "microsoft teams",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "webex",
        "cisco webex meetings",
        "google meet",
        "facetime",
        "com.apple.facetime",
        "slack",
        "discord",
        "obs",
        "com.obsproject.obs-studio"
    ]

    public static func isMeetingApp(bundleIdentifier: String?, appName: String?) -> Bool {
        let idLower = (bundleIdentifier ?? "").lowercased()
        let nameLower = (appName ?? "").lowercased()
        for sig in knownMeetingAppSignatures {
            if idLower.contains(sig) || nameLower.contains(sig) {
                return true
            }
        }
        return false
    }

    #if canImport(AppKit)
    public static func activeMeetingApp() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        if isMeetingApp(bundleIdentifier: front?.bundleIdentifier, appName: front?.localizedName) {
            return front?.localizedName ?? "Meeting"
        }
        for app in NSWorkspace.shared.runningApplications {
            if app.isActive && isMeetingApp(bundleIdentifier: app.bundleIdentifier, appName: app.localizedName) {
                return app.localizedName ?? "Meeting"
            }
        }
        return nil
    }

    public static func isMeetingActive() -> Bool {
        activeMeetingApp() != nil
    }
    #else
    public static func activeMeetingApp() -> String? { nil }
    public static func isMeetingActive() -> Bool { false }
    #endif
}

// MARK: - On-Screen Visual Guidance & Laser Pointer Overlay

public enum LaserPointerCommand: Equatable {
    case pointToCenter
    case pointAt(x: CGFloat, y: CGFloat)
    case highlightActiveWindow
    case none
}

public enum LaserPointerParser {
    public static func parse(_ text: String) -> LaserPointerCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "point" || lower == "laser pointer" || lower == "show pointer" || lower == "where are you looking" || lower == "point here" {
            return .pointToCenter
        }
        if lower == "highlight window" || lower == "highlight active window" || lower == "outline window" {
            return .highlightActiveWindow
        }
        return .none
    }
}

#if canImport(AppKit)
@MainActor
public final class ScreenGuideLaserOverlay {
    public static let shared = ScreenGuideLaserOverlay()
    private var window: NSPanel?

    private init() {}

    public func showPointer(at point: CGPoint, duration: TimeInterval = 2.5) {
        dismiss()
        let size: CGFloat = 80
        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let ringView = LaserRingView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = ringView
        panel.orderFrontRegardless()
        self.window = panel

        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self?.window === panel {
                self?.dismiss()
            }
        }
    }

    public func highlightRect(_ rect: CGRect, duration: TimeInterval = 3.0) {
        dismiss()
        let inset = rect.insetBy(dx: -8, dy: -8)
        let panel = NSPanel(
            contentRect: inset,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let rectView = LaserBoxView(frame: NSRect(origin: .zero, size: inset.size))
        panel.contentView = rectView
        panel.orderFrontRegardless()
        self.window = panel

        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self?.window === panel {
                self?.dismiss()
            }
        }
    }

    public func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class LaserRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2 - 6

        ctx.saveGState()
        // Outer glowing pulse
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(6.0)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Core bright ring
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(2.5)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Center dot
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.addArc(center: center, radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

private final class LaserBoxView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8)

        NSGraphicsContext.current?.saveGraphicsState()
        NSColor.systemOrange.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 5.0
        path.stroke()

        NSColor.systemOrange.setStroke()
        path.lineWidth = 2.0
        path.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
#endif

// MARK: - Autonomous Mac Agent & Workspace Observer

public struct AutonomousWorkspaceSnapshot: Equatable, Sendable {
    public let activeApp: String
    public let windowTitle: String?
    public let selectedText: String?
    public let recentDownloadFile: String?
    public let clipboardSignal: String?
    public let autonomousActionNote: String?

    public init(
        activeApp: String,
        windowTitle: String?,
        selectedText: String?,
        recentDownloadFile: String?,
        clipboardSignal: String?,
        autonomousActionNote: String?
    ) {
        self.activeApp = activeApp
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.recentDownloadFile = recentDownloadFile
        self.clipboardSignal = clipboardSignal
        self.autonomousActionNote = autonomousActionNote
    }

    public var promptSummary: String {
        var lines: [String] = []
        if let title = windowTitle, !title.isEmpty {
            lines.append("Active Application: \(activeApp) — Window: \"\(title)\"")
        } else {
            lines.append("Active Application: \(activeApp)")
        }
        if let selected = selectedText, !selected.isEmpty {
            let clean = selected.count > 400 ? String(selected.prefix(400)) + "…" : selected
            lines.append("Highlighted Selection: \"\(clean)\"")
        }
        if let download = recentDownloadFile {
            lines.append("Recent File in Downloads: \(download)")
        }
        if let clip = clipboardSignal {
            lines.append("Clipboard Signal: \(clip)")
        }
        if let note = autonomousActionNote {
            lines.append("Autonomous Background Action Completed: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}

public final class AutonomousMacAgent {
    public static let shared = AutonomousMacAgent()
    private var lastObservedApp: String = ""
    private var lastObservedWindow: String = ""
    private var lastIndexedDownload: String = ""

    private init() {}

    #if canImport(AppKit)
    @MainActor
    public func observeAndMaintainWorkspace() -> AutonomousWorkspaceSnapshot {
        let desktop = ActiveDesktopContext.current()
        let appName = desktop.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS Desktop"
        let winTitle = desktop.windowTitle

        // 1. Check most recent file in ~/Downloads modified within the last 15 minutes
        var recentDownload: String? = nil
        if let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           let items = try? FileManager.default.contentsOfDirectory(
               at: downloadsURL,
               includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            let cutoff = Date().addingTimeInterval(-900)
            var newest: (name: String, date: Date)? = nil
            for url in items where url.lastPathComponent != "dot_chat_log.txt" {
                if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                   vals.isRegularFile == true,
                   let modDate = vals.contentModificationDate,
                   modDate >= cutoff {
                    if newest == nil || modDate > newest!.date {
                        newest = (url.lastPathComponent, modDate)
                    }
                }
            }
            recentDownload = newest?.name
        }

        // 2. Inspect highlighted selection or window title for errors, stack traces, or URLs
        var clipboardSignal: String? = nil
        let candidateText = (desktop.selectedText ?? winTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidateText.isEmpty {
            let lower = candidateText.lowercased()
            if lower.contains("error:") || lower.contains("fatal error") || lower.contains("exception") || lower.contains("traceback") || lower.contains("failed") {
                let snippet = String(candidateText.prefix(220)).replacingOccurrences(of: "\n", with: " ")
                clipboardSignal = "Error/Diagnostic detected: \"\(snippet)\""
            } else if candidateText.hasPrefix("https://") || candidateText.hasPrefix("http://") {
                clipboardSignal = "Active URL detected: \(String(candidateText.prefix(160)))"
            }
        }

        // 3. Autonomous background action: maintain live workspace brief in Application Support/Dot/Documents
        var actionNote: String? = nil
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let docDir = support?.appendingPathComponent("Dot/Documents", isDirectory: true) {
            try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            let briefURL = docDir.appendingPathComponent("autonomous_workspace_brief.md")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            var entry = "- [\(timestamp)] App: **\(appName)**"
            if let winTitle, !winTitle.isEmpty {
                entry += " (`\(winTitle)`)"
            }
            if let recentDownload, recentDownload != lastIndexedDownload {
                lastIndexedDownload = recentDownload
                entry += " | Noted recent download: `\(recentDownload)`"
                actionNote = "Logged new download '\(recentDownload)' and updated workspace brief"
            } else if appName != lastObservedApp || (winTitle ?? "") != lastObservedWindow {
                actionNote = "Updated autonomous workspace brief for \(appName)"
            }
            lastObservedApp = appName
            lastObservedWindow = winTitle ?? ""
            entry += "\n"
            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: briefURL.path),
                   let handle = try? FileHandle(forWritingTo: briefURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    let header = "# Dot Autonomous Workspace Brief\n\n"
                    try? (header + entry).write(to: briefURL, atomically: true, encoding: .utf8)
                }
            }
        }

        return AutonomousWorkspaceSnapshot(
            activeApp: appName,
            windowTitle: winTitle,
            selectedText: desktop.selectedText,
            recentDownloadFile: recentDownload,
            clipboardSignal: clipboardSignal,
            autonomousActionNote: actionNote
        )
    }
    #endif
}

