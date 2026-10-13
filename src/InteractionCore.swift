import Foundation
import CoreFoundation

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
    struct Question: Equatable { let text: String }
    enum Failure: Error { case invalid }
    // The one-field tool argument object uses strict JSON punctuation before Foundation decoding.
    // This prevents duplicate keys/trailing commas from being normalized into a valid dictionary.
    private static let questionObjectPattern = #"\A[ \t\r\n]*\{[ \t\r\n]*"question"[ \t\r\n]*:[ \t\r\n]*"(?:[^"\\\x00-\x1F]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"[ \t\r\n]*\}[ \t\r\n]*\z"#
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
                guard name as? String == "ask_user", functionName == nil || functionName == "ask_user" else { throw Failure.invalid }
                functionName = "ask_user"
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
        guard terminal == "tool_calls", callID != nil, functionName == "ask_user",
              arguments.range(of: Self.questionObjectPattern, options: .regularExpression) != nil,
              let data = arguments.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["question"], let text = object["question"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 400, text.utf8.count <= 1600,
              text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw Failure.invalid }
        return Question(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
