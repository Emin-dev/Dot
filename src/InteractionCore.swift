import Foundation
import CoreFoundation
import CryptoKit
#if canImport(CoreAudio)
import CoreAudio
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Shared helpers

/// One ordered phrase table standing in for hand-written `if lower == "…"` chains. The first rule
/// that matches wins, so overlapping synonyms keep exactly the precedence they had inline.
struct PhraseMatcher<Command> {
    /// Either exact phrase synonyms, or a prefix rule that receives the remainder of the original
    /// and of the lowercased text and declines by returning nil.
    enum Rule {
        case phrases([String], Command)
        case prefix(String, (String, String) -> Command?)
    }
    private let rules: [Rule]
    init(_ rules: Rule...) { self.rules = rules }
    func match(_ text: String) -> Command? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules {
            switch rule {
            case .phrases(let phrases, let command) where phrases.contains(lower):
                return command
            case .prefix(let prefix, let build) where lower.hasPrefix(prefix):
                if let command = build(String(text.dropFirst(prefix.count)), String(lower.dropFirst(prefix.count))) { return command }
            default:
                continue
            }
        }
        return nil
    }
}

/// Strips each conversational filler at most once, in order, exactly as the inlined loops did.
/// Every call site keeps its own list: the fillers genuinely differ between intents.
func stripConversationalPrefixes(_ text: String, prefixes: [String]) -> String {
    var working = text
    for prefix in prefixes where working.lowercased().hasPrefix(prefix) {
        working = String(working.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return working
}

/// The sentence punctuation the conversational parsers ignore.
func trimConversationalPunctuation(_ text: String) -> String {
    text.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,:;\"'"))
}

/// The one read-to-EOF subprocess shape: launch, drain the pipe, then wait for exit. The order
/// matters: waiting for exit before draining deadlocks as soon as the child writes more than the
/// pipe buffer (about 64 KiB on macOS), because the child blocks on write and never exits.
/// Callers keep their own decoding, trimming, limits and error text so no reply string changes.
/// Audit S16: a child that runs too long (`sleep 1e9`) is stopped after `timeout`, and one that
/// prints without end (`yes`) is stopped at `outputLimit` bytes, so neither can hang a worker or
/// fill memory.
enum SubprocessRunner {
    /// Collects output on a background reader, so a grandchild that keeps the pipe open
    /// (`sleep 1e9; true`) can never hold the caller past the timeout.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private(set) var reachedLimit = false
        let finished = DispatchSemaphore(value: 0)
        func append(_ chunk: Data, limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            storage.append(chunk.prefix(max(0, limit - storage.count)))
            reachedLimit = storage.count >= limit
            return reachedLimit
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    static func run(executable: String, arguments: [String], mergeStandardError: Bool = false,
                    currentDirectory: URL? = nil, timeout: TimeInterval = 30,
                    outputLimit: Int = 1_048_576) throws -> (data: Data, status: Int32, stopped: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        if mergeStandardError { process.standardError = pipe }
        try process.run()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let collector = OutputCollector()
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            // Reading ends when every writer closes the pipe, or at the output limit.
            while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
                if collector.append(chunk, limit: outputLimit) { break }
            }
            collector.finished.signal()
        }
        let ended = collector.finished.wait(timeout: .now() + max(0, timeout)) == .success
        if ended && !collector.reachedLimit {
            while process.isRunning && Date() < deadline { usleep(20_000) }
        }
        var stopped = false
        if process.isRunning {
            stopped = true
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        return (collector.data, process.terminationStatus, stopped || collector.reachedLimit)
    }
}


/// The one folder the owner explicitly chose for document and shell work. The
/// App Sandbox already confines Dot to its container plus user-selected folders;
/// this scope additionally makes the shell start in that chosen folder and gives
/// the safety approver a concrete target. It never widens the sandbox.
final class UserFolderScope: @unchecked Sendable {
    static let shared = UserFolderScope()

    /// The owner's real home folder. Inside the App Sandbox NSHomeDirectory() is
    /// the container (~/Library/Containers/<id>/Data), so "~" would point there.
    static func userHome(sandboxHome: String = NSHomeDirectory()) -> String {
        sandboxHome.components(separatedBy: "/Library/Containers/").first ?? sandboxHome
    }
    static func expandingUserHome(_ path: String, sandboxHome: String = NSHomeDirectory()) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return userHome(sandboxHome: sandboxHome) + String(path.dropFirst())
    }
    /// The owner's real Desktop, Documents or Downloads folder. R21 grants read
    /// access to exactly these; FileManager's .desktopDirectory and friends name
    /// the container's copies inside the App Sandbox.
    static func userFolder(_ name: String, sandboxHome: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: userHome(sandboxHome: sandboxHome), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
    static var watchedFolders: [URL] { ["Desktop", "Documents", "Downloads"].map { userFolder($0) } }
    private let lock = NSLock()
    private var folder: URL?

    var current: URL? {
        lock.lock(); defer { lock.unlock() }
        return folder
    }

    func set(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        folder = url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

extension Sequence where Element == UInt8 {
    /// Lowercase two-digit-per-byte hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    /// Lowercase 64-character SHA-256 hex digest.
    var sha256Hex: String { SHA256.hash(data: self).hexString }
}

extension String {
    /// The longest prefix that is at most `bytes` UTF-8 bytes and ends on a scalar boundary.
    func truncated(toUTF8Bytes bytes: Int) -> String {
        let prefix = Array(utf8.prefix(bytes))
        var end = prefix.count
        while end > 0 {
            if let value = String(bytes: prefix[..<end], encoding: .utf8) { return value }
            end -= 1
        }
        return ""
    }
}

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

/// The `ask_user` question is spoken after the answer only when the answer has not
/// already asked it. The model often ends its content with its own question and
/// then calls the tool with a reworded one, which made Dot ask twice in a row.
enum SpokenQuestion {
    static func endsWithQuestion(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closers = "\"'”’)]}"
        while let last = trimmed.last, closers.contains(last) {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmed.hasSuffix("?") else { return false }
        var sentence = String(trimmed.dropLast())
        let boundaries: Set<Character> = [".", "!", "?", "\n"]
        if let last = sentence.lastIndex(where: { boundaries.contains($0) }) {
            sentence = String(sentence[sentence.index(after: last)...])
        }
        // A quoted/explanatory construction ("A quoted question: why?") is not Dot
        // asking the owner; only a direct final question is an invitation.
        guard !sentence.contains(":"), !sentence.contains("\""),
              !sentence.contains("“"), !sentence.contains("”") else { return false }
        return sentence.split(whereSeparator: \.isWhitespace).count >= 2
    }
    static func needsAppending(_ question: String, after content: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: "?!.,:; ").union(.whitespacesAndNewlines)
        let cleanQ = question.lowercased().trimmingCharacters(in: punctuation)
        let cleanC = content.lowercased().trimmingCharacters(in: punctuation)
        guard !cleanQ.isEmpty else { return false }
        if cleanC.isEmpty { return true }
        return !cleanC.contains(cleanQ) && !endsWithQuestion(content)
    }
}

/// Whisper writes non-speech as annotations ("[BLANK_AUDIO]", "[MUSIC PLAYING]",
/// "(coughs)", "♪"). They are not words the owner said and must never become a turn.
enum SpokenTranscript {
    static func words(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\[[^\]]{0,60}\]"#, with: " ", options: .regularExpression)
        // Only short parentheticals are annotations; longer ones can be real speech.
        text = text.replacingOccurrences(of: #"\((?:\s*[A-Za-z'-]+){1,4}\s*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[♪♫*]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) ? trimmed : ""
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

/// R4: the four British Kokoro voices the owner can pick. Emma is the default;
/// Isabella is the one the signed runtime manifest always ships.
enum DotVoice {
    static let defaultsKey = "dot.voice"
    static let defaultVoice = "bf_emma"
    static let alwaysBundled = "bf_isabella"
    static let british = ["bf_emma", "bf_isabella", "bf_alice", "bf_lily"]
    static func selected(in defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: defaultsKey) ?? defaultVoice
        return british.contains(stored) ? stored : defaultVoice
    }
    /// The voice to launch: the owner's choice when its embedding is on disk,
    /// otherwise the always-bundled Isabella, so a missing file never mutes Dot.
    static func launchVoice(selected: String, root: URL,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        // Same layout rule as dot-voice: <root>/model when present, else <root>.
        let model = root.appendingPathComponent("model", isDirectory: true)
        let voices = (exists(model.path) ? model : root).appendingPathComponent("voices", isDirectory: true)
        return exists(voices.appendingPathComponent(selected + ".pt").path) ? selected : alwaysBundled
    }
    /// The British voices whose embedding this install actually carries; the
    /// release payload may ship only Isabella, so a picker must never promise more.
    static func installed(root: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        british.filter { launchVoice(selected: $0, root: root, exists: exists) == $0 }
    }
    /// "bf_isabella" -> "isabella".
    static func spokenName(_ voice: String) -> String {
        voice.hasPrefix("bf_") ? String(voice.dropFirst(3)) : voice
    }
}

/// Strict framing for Dot's bundled Bionic helper, not an installed daemon API.
struct VoiceEvent {
    let kind: String
    let request: UUID?
    let turn: UUID?
    let filename: String?
    /// The Bionic helper's reason code for `cancelled`/`unavailable`/`error` events;
    /// preserved so the caller can report the honest per-code message.
    let code: Int?
    init(kind: String, request: UUID?, turn: UUID?, filename: String?, code: Int? = nil) {
        self.kind = kind; self.request = request; self.turn = turn
        self.filename = filename; self.code = code
    }
    static func parse(_ data: Data) -> VoiceEvent? {
        guard data.count <= 8192,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = value["protocol"] as? Int, version == 1,
              let kind = value["event"] as? String else { return nil }
        if kind == "hello" {
            // dot-voice announces the voice it loaded; any of the four British
            // voices is valid. Requiring Isabella here rejected the Emma default.
            guard value["engine"] as? String == "kokoro", let voice = value["voice"] as? String,
                  DotVoice.british.contains(voice),
                  value["sample_rate"] as? Int == 24000, value["offline"] as? Bool == true else { return nil }
            return VoiceEvent(kind: kind, request: nil, turn: nil, filename: nil)
        }
        if kind == "cancelled" || kind == "unavailable" {
            return VoiceEvent(kind: kind, request: nil, turn: nil, filename: nil,
                              code: value["code"] as? Int)
        }
        guard kind == "audio" || kind == "error",
              let id = value["id"] as? String, let request = UUID(uuidString: id),
              let generation = value["turn"] as? String, let turn = UUID(uuidString: generation) else { return nil }
        if kind == "error" {
            return VoiceEvent(kind: kind, request: request, turn: turn, filename: nil,
                              code: value["code"] as? Int)
        }
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
    /// Documented freshness window (docs/BUILD_CHECKLIST.md: "Extended freshness window to 15s to
    /// eliminate false-stale drops during reasoning/warmup"). One named constant, honored by every
    /// freshness check above and asserted by `ScreenContextTests`.
    static let maximumAge: Double = 15

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
    /// A model already on disk at its exact sizes downloads nothing, so an offline
    /// relaunch must not demand free space or report "Downloading".
    static func needsDownload(total: Int64, reusableBytes: Int64) -> Bool {
        reusableBytes < total
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
        case notImplemented = "not-implemented"
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
        case .notImplemented: detail = "the supervisor reported a not-implemented path"
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
        // The blocked message carries the remediation instruction ("enable X in Y");
        // the short menu title alone never tells the owner what to do about it.
        let issueText: String
        if case .unavailable(let message) = readiness, !message.isEmpty {
            issueText = message
        } else {
            issueText = issue?.title ?? (readiness.isIssue ? Self.files.title : "None")
        }
        return "Dot diagnostic summary\nPreparation: \(preparation)\nIssue: \(issueText)"
    }
    /// R11: the menu-bar title is the always-visible cold-start surface. Kept short
    /// so it never crowds the menu bar, and nil when nothing is starting.
    static func statusTitle(preparing: Bool, progress: Double, engineStage: String?) -> String? {
        if let engineStage {
            return engineStage.localizedCaseInsensitiveContains("loading") ? "Loading model…" : "Starting Dot…"
        }
        guard preparing else { return nil }
        let value = progress.isFinite ? min(1, max(0, progress)) : 0
        return "Preparing \(Int(value * 100))%"
    }

    static func menuHeader(readiness: CompanionReadiness, issue: Self?, progress: Double,
                           engineStage: String? = nil, detail: String? = nil) -> String? {
        switch readiness {
        case .checking:
            let value = progress.isFinite ? min(1, max(0, progress)) : 0
            return "\(detail ?? "Checking files"), \(Int(value * 100))%"
        case .paused: return "File check paused"
        case .unavailable: return Self.files.title
        case .ready: return engineStage ?? issue?.title
        }
    }
}

/// Same-turn followup policy; the controller supplies successful final audible playback.
/// The preferred path is a validated explicit `ask_user` contract. A final spoken
/// question is the bounded fallback the controller supplies when the local model
/// omits that call; punctuation alone never opens the microphone, and the invitation
/// still waits for final playback, a transient-ready environment and the 8 s lifetime.
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
    /// The question provisionally reserved by `reserve` but not yet armed by `commit`.
    private var reservedQuestion: UUID?

    /// One provisional reply slot: `reserve` spends it, `commit` arms it, and
    /// `release` gives it back when the caller rejects the invitation.
    struct Reservation: Equatable {
        let turn: UUID
        let question: UUID
        let at: Double
    }

    mutating func begin(turn: UUID, explicitClick: Bool, continuation: UUID? = nil, now: Double = 0) {
        guard now.isFinite else { cancel(); return }
        if explicitClick { explicitConversation = true; repliesUsed = 0 }
        else {
            guard explicitConversation, let issuedContinuation, continuation == issuedContinuation,
                  let issuedAt, now >= issuedAt, now - issuedAt <= 1 else { cancel(); return }
        }
        issuedContinuation = nil; issuedAt = nil
        self.turn = turn; question = nil; playbackEndedAt = nil; responseFinalized = false
        reservedQuestion = nil
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
    /// Two-phase consumption: `reserve` spends the reply slot provisionally, and the
    /// caller must either `commit` (the invitation is actually armed) or `release`
    /// (the invitation was rejected) it. A rejected invitation therefore never burns
    /// `repliesUsed`, and the automatic-reply chain is not shortened by refusals.
    mutating func reserve(turn: UUID, now: Double, ready: Bool, microphoneAuthorized: Bool,
                          screenAuthorized: Bool, interacting: Bool) -> Reservation? {
        guard self.turn == turn else { return nil }
        // Permission loss and an exhausted chain are final. Readiness and a brief
        // interaction are transient after playback (audio route/teardown); the caller
        // retries them inside the invitation lifetime instead of dropping the reply.
        guard microphoneAuthorized, screenAuthorized, now.isFinite,
              repliesUsed < Self.maximumAutomaticReplies else { cancel(); return nil }
        guard ready, !interacting else { return nil }
        guard let question, let played = playbackEndedAt, reservedQuestion == nil else { return nil }
        guard now >= played, now - played <= Self.invitationLifetimeSeconds else { cancel(); return nil }
        guard now - played >= Self.playbackSettleSeconds else { return nil }
        repliesUsed += 1
        reservedQuestion = question
        return Reservation(turn: turn, question: question, at: now)
    }

    mutating func commit(_ reservation: Reservation) -> UUID? {
        guard self.turn == reservation.turn, self.question == reservation.question,
              reservedQuestion == reservation.question else {
            release(reservation)
            return nil
        }
        issuedContinuation = reservation.question
        issuedAt = reservation.at
        reservedQuestion = nil
        self.turn = nil; self.question = nil; playbackEndedAt = nil
        return reservation.question
    }

    mutating func release(_ reservation: Reservation) {
        guard self.turn == reservation.turn, self.question == reservation.question,
              reservedQuestion == reservation.question else { return }
        if repliesUsed > 0 { repliesUsed -= 1 }
        reservedQuestion = nil
    }

    mutating func consume(turn: UUID, now: Double, ready: Bool, microphoneAuthorized: Bool,
                          screenAuthorized: Bool, interacting: Bool) -> UUID? {
        guard let reservation = reserve(turn: turn, now: now, ready: ready,
                                        microphoneAuthorized: microphoneAuthorized,
                                        screenAuthorized: screenAuthorized,
                                        interacting: interacting) else { return nil }
        return commit(reservation)
    }
    mutating func cancel() {
        turn = nil; question = nil; playbackEndedAt = nil
        explicitConversation = false; issuedContinuation = nil; issuedAt = nil
        reservedQuestion = nil
    }
}

/// Bounds for model-supplied integers. The advertised tool schemas are advisory only: a local
/// model can emit any number, so every numeric argument is clamped at the parse boundary and
/// again at the engine entry point before it can drive a loop or an `Int32` conversion.
enum ToolNumericBounds {
    static let clicks = 1...3
    static let scrollAmount = 1...50

    /// Clamps a JSON number without ever converting an out-of-range `Double` to `Int`.
    static func clamped(_ value: NSNumber?, to range: ClosedRange<Int>, default fallback: Int) -> Int {
        guard let value, CFGetTypeID(value) != CFBooleanGetTypeID() else { return fallback }
        let raw = value.doubleValue
        guard raw.isFinite else { return fallback }
        let rounded = raw.rounded()
        if rounded <= Double(range.lowerBound) { return range.lowerBound }
        if rounded >= Double(range.upperBound) { return range.upperBound }
        return Int(rounded)
    }
    static func clampedClicks(_ value: NSNumber?) -> Int { clamped(value, to: clicks, default: 1) }
    static func clampedScrollAmount(_ value: NSNumber?) -> Int { clamped(value, to: scrollAmount, default: 6) }

    static func clampedClicks(_ value: Int) -> Int { min(max(value, clicks.lowerBound), clicks.upperBound) }
    static func clampedScrollAmount(_ value: Int) -> Int { min(max(value, scrollAmount.lowerBound), scrollAmount.upperBound) }

    /// Pure arithmetic for `CGEvent` scroll deltas: the magnitude is clamped before the `Int32`
    /// conversion, which would otherwise trap for values above `Int32.max`.
    static func scrollDelta(amount: Int, inverted: Bool) -> Int32 {
        let magnitude = clampedScrollAmount(amount)
        return Int32(clamping: inverted ? -magnitude : magnitude)
    }
}

/// Strict parser for the pinned Splash streamed tool-call contract. It grants no microphone authority.
/// The controller still needs same-turn success plus the final question's actual playback completion.
struct QuestionIntentStream {
    struct Question: Equatable, Sendable { let text: String }
    enum ToolAction: Equatable, Sendable {
        case typeText(String)
        case pressKey(String)
        case sendShortcut(modifiers: [String], key: String)
        case moveMouse(x: Double, y: Double)
        case clickPoint(x: Double, y: Double, button: String, clicks: Int)
        case clickElement(description: String)
        case pointOnScreen(x: Double, y: Double, label: String?)
        case scrollScreen(direction: String, amount: Int)
        case snapWindow(layout: String)
        case executeCommand(command: String, explanation: String?)
        case deleteFile(path: String, explanation: String?)
        case contextualWorkflow(app: String, action: String)
        case calendarSchedule(action: String, title: String?, startTime: String?, durationMinutes: Int?)
    }
    enum Failure: Error { case invalid }
    // The one-field tool argument object uses strict JSON punctuation before Foundation decoding.
    // This prevents duplicate keys/trailing commas from being normalized into a valid dictionary.
    private static let questionObjectPattern = #"\A[ \t\r\n]*\{[ \t\r\n]*"question"[ \t\r\n]*:[ \t\r\n]*"(?:[^"\\\x00-\x1F]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"[ \t\r\n]*\}[ \t\r\n]*\z"#
    private static let allowedToolNames: Set<String> = [
        "ask_user", "type_text", "press_key", "send_shortcut", "click_element", "move_mouse", "click_point", "point_on_screen", "scroll_screen", "snap_window", "execute_command", "delete_file", "contextual_workflow", "calendar_schedule"
    ]
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
        if functionName != "ask_user" {
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
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalid
        }
        switch functionName {
        case "type_text":
            guard let text = object["text"] as? String, !text.isEmpty, text.count <= 1500 else { throw Failure.invalid }
            return .typeText(text)
        case "press_key":
            guard let key = object["key"] as? String else { throw Failure.invalid }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 100 else { throw Failure.invalid }
            return .pressKey(trimmed)
        case "send_shortcut":
            let raw = (object["shortcut"] as? String) ?? (object["key"] as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 100 else { throw Failure.invalid }
            let mods = (object["modifiers"] as? [String]) ?? []
            return .sendShortcut(modifiers: mods, key: trimmed)
        case "click_element":
            guard let desc = object["description"] as? String else { throw Failure.invalid }
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 250 else { throw Failure.invalid }
            return .clickElement(description: trimmed)
        case "move_mouse":
            guard let x = (object["x"] as? NSNumber)?.doubleValue,
                  let y = (object["y"] as? NSNumber)?.doubleValue else { throw Failure.invalid }
            return .moveMouse(x: x, y: y)
        case "click_point":
            guard let x = (object["x"] as? NSNumber)?.doubleValue,
                  let y = (object["y"] as? NSNumber)?.doubleValue else { throw Failure.invalid }
            let button = (object["button"] as? String) ?? "left"
            // Schema advertises 1...3; the model is not trusted to respect it.
            let clicks = ToolNumericBounds.clampedClicks(object["clicks"] as? NSNumber)
            return .clickPoint(x: x, y: y, button: button, clicks: clicks)
        case "point_on_screen":
            guard let x = (object["x"] as? NSNumber)?.doubleValue,
                  let y = (object["y"] as? NSNumber)?.doubleValue else { throw Failure.invalid }
            let label = object["label"] as? String
            return .pointOnScreen(x: x, y: y, label: label)
        case "scroll_screen":
            let dir = (object["direction"] as? String) ?? "down"
            // Schema advertises 1...50; the model is not trusted to respect it.
            let amt = ToolNumericBounds.clampedScrollAmount(object["amount"] as? NSNumber)
            return .scrollScreen(direction: dir, amount: amt)
        case "snap_window":
            guard let layout = object["layout"] as? String, !layout.isEmpty else { throw Failure.invalid }
            return .snapWindow(layout: layout)
        case "execute_command":
            guard let cmd = object["command"] as? String else { throw Failure.invalid }
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 1000 else { throw Failure.invalid }
            let exp = object["explanation"] as? String
            return .executeCommand(command: trimmed, explanation: exp)
        case "delete_file":
            guard let path = object["path"] as? String else { throw Failure.invalid }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 1000 else { throw Failure.invalid }
            let exp = object["explanation"] as? String
            return .deleteFile(path: trimmed, explanation: exp)
        case "contextual_workflow":
            guard let app = object["app"] as? String, let action = object["action"] as? String else { throw Failure.invalid }
            let trimmedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedApp.isEmpty, !trimmedAction.isEmpty else { throw Failure.invalid }
            return .contextualWorkflow(app: trimmedApp, action: trimmedAction)
        case "calendar_schedule":
            guard let action = object["action"] as? String else { throw Failure.invalid }
            let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAction.isEmpty else { throw Failure.invalid }
            let title = object["title"] as? String
            let start = object["start_time_iso"] as? String
            let duration = (object["duration_minutes"] as? NSNumber)?.intValue
            return .calendarSchedule(action: trimmedAction, title: title, startTime: start, durationMinutes: duration)
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
/// The owner's minimum is Apple Silicon M5 Pro class, 48 GB Unified Memory and macOS 27+.
/// The exact Qwen3.8 27B Q4 Splash model has no smaller fallback, so a machine below that
/// minimum is refused at launch with one clear message.
public struct HardwareCompatibility: Sendable {
    /// Minimum Unified Memory required to launch Dot.
    public static let minimumRAMGB = 48
    /// Kept for display; the minimum and the recommendation are the same.
    public static let recommendedRAMGB = 48
    /// Minimum OS required to launch Dot.
    public static let minimumOSMajor = 27
    public static let minimumOSMinor = 0
    public static let recommendedOSMajor = 27

    /// Pure, testable description of a launch alert. AppKit presentation only applies this plan,
    /// so button order and the Return-key button are covered by portable tests.
    public struct LaunchAlertPlan: Equatable, Sendable {
        public let title: String
        public let informativeText: String
        public let buttons: [String]
        public let defaultButtonIndex: Int
        public let isCritical: Bool

        public init(title: String, informativeText: String, buttons: [String], defaultButtonIndex: Int, isCritical: Bool) {
            self.title = title
            self.informativeText = informativeText
            self.buttons = buttons
            self.defaultButtonIndex = defaultButtonIndex
            self.isCritical = isCritical
        }

        public var defaultButtonTitle: String {
            buttons.indices.contains(defaultButtonIndex) ? buttons[defaultButtonIndex] : ""
        }
    }

    /// Launch outcome. Any machine below the minimum is refused; there is no override.
    public enum LaunchGate: Equatable, Sendable {
        case proceed
        case refuseImpossible(LaunchAlertPlan)
    }

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
                    if gen >= 6 { return true }
                    if gen == 5 {
                        let upper = chip.uppercased()
                        return upper.contains("PRO") || upper.contains("MAX") || upper.contains("ULTRA")
                    }
                }
            }
            return false
        }

        /// Minimum specification: 48 GB Unified Memory.
        public var meetsRAMSpec: Bool {
            ramGB >= HardwareCompatibility.minimumRAMGB
        }

        /// Minimum specification: macOS 27.0 or later.
        public var meetsOSSpec: Bool {
            osMajor > HardwareCompatibility.minimumOSMajor
                || (osMajor == HardwareCompatibility.minimumOSMajor && osMinor >= HardwareCompatibility.minimumOSMinor)
        }

        public var meetsAllSpecs: Bool {
            meetsChipSpec && meetsRAMSpec && meetsOSSpec
        }

        /// Only Intel is treated as a different architecture failure; every other unmet
        /// requirement is reported by `belowSpecReasons` and still refused at launch.
        public var technicalImpossibilityReason: String? {
            if !isAppleSilicon {
                return "Intel processors are not supported. Dot requires Apple Silicon (M5 Pro class or newer)."
            }
            return nil
        }

        /// Human-readable gaps from the minimum; empty on a compatible Mac.
        public var advisoryNotes: [String] {
            var notes: [String] = []
            if !meetsChipSpec {
                notes.append("Processor (\(chip)) is below the required Apple M5 Pro class or newer.")
            }
            if ramGB < HardwareCompatibility.recommendedRAMGB {
                notes.append("Unified Memory (\(ramGB) GB) is below the required \(HardwareCompatibility.recommendedRAMGB) GB.")
            }
            if osMajor < HardwareCompatibility.recommendedOSMajor {
                notes.append("Operating System (macOS \(osString)) is below the required macOS \(HardwareCompatibility.recommendedOSMajor).")
            }
            return notes
        }

        /// Reasons the minimum specification is not met.
        public var belowSpecReasons: [String] {
            var reasons: [String] = []
            if !meetsChipSpec {
                reasons.append("Processor (\(chip)) is below the required Apple M5 Pro class or newer.")
            }
            if !meetsRAMSpec {
                reasons.append("Unified Memory (\(ramGB) GB) is below the required \(HardwareCompatibility.minimumRAMGB) GB minimum.")
            }
            if !meetsOSSpec {
                reasons.append("Operating System (macOS \(osString)) is below the required macOS \(HardwareCompatibility.minimumOSMajor).\(HardwareCompatibility.minimumOSMinor)+.")
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
            return "Hardware meets Dot's minimum specification: \(current.chip), \(current.ramGB) GB Unified Memory, macOS \(current.osString). Minimum is Apple M5 Pro class, \(minimumRAMGB) GB Unified Memory and macOS \(minimumOSMajor).\(minimumOSMinor)+."
        case .belowMinimum(let current, let reasons):
            let details = reasons.joined(separator: " ")
            return "Hardware below Dot's minimum specification: \(current.chip), \(current.ramGB) GB Unified Memory, macOS \(current.osString). \(details) Minimum is Apple M5 Pro class, \(minimumRAMGB) GB Unified Memory and macOS \(minimumOSMajor).\(minimumOSMinor)+."
        case .technicallyImpossible(let current, let reason):
            return "Hardware incompatible: \(current.chip), \(current.ramGB) GB RAM, macOS \(current.osString). Reason: \(reason)"
        }
    }

    /// Pure launch-gate decision. Every unmet minimum refuses to launch; there is no override.
    public static func launchGate(info: SystemInfo = queryCurrent()) -> LaunchGate {
        switch evaluate(info: info) {
        case .compatible:
            return .proceed
        case .belowMinimum(let detected, let reasons):
            return .refuseImpossible(minimumPlan(info: detected, reasons: reasons))
        case .technicallyImpossible(let detected, let reason):
            return .refuseImpossible(impossiblePlan(info: detected, reason: reason))
        }
    }

    /// Clear, blocking message for a Mac below the minimum configuration.
    public static func minimumPlan(info: SystemInfo, reasons: [String]) -> LaunchAlertPlan {
        let items = reasons.map { "• " + $0 }.joined(separator: "\n")
        let text = "Dot needs Apple Silicon M5 Pro class or newer, \(minimumRAMGB) GB Unified Memory and macOS \(minimumOSMajor).\(minimumOSMinor) or newer. The exact Qwen3.8 27B Q4 model runs locally and has no smaller fallback, so Dot cannot start on this Mac.\n\n" +
            "Detected on this Mac:\n" +
            "• Processor: \(info.chip)\n" +
            "• Memory: \(info.ramGB) GB Unified Memory\n" +
            "• Operating System: macOS \(info.osString)\n\n" +
            "Not met:\n" +
            items
        return LaunchAlertPlan(title: "Hardware Does Not Meet Dot's Minimum",
                               informativeText: text,
                               buttons: ["Quit"],
                               defaultButtonIndex: 0,
                               isCritical: true)
    }

    public static func impossiblePlan(info: SystemInfo, reason: String) -> LaunchAlertPlan {
        LaunchAlertPlan(title: "Hardware Incompatible with Dot",
                        informativeText: "Dot cannot run on this machine.\n\n" +
                            "Detected:\n" +
                            "• Processor: \(info.chip)\n" +
                            "• Memory: \(info.ramGB) GB Unified Memory\n" +
                            "• Operating System: macOS \(info.osString)\n\n" +
                            "Reason:\n\(reason)\n\n" +
                            "Required:\n" +
                            "• Apple Silicon M5 Pro class or newer\n" +
                            "• \(minimumRAMGB) GB Unified Memory or more\n" +
                            "• macOS \(minimumOSMajor).\(minimumOSMinor) or newer",
                        buttons: ["Quit"],
                        defaultButtonIndex: 0,
                        isCritical: true)
    }

    #if canImport(AppKit)
    /// The single place a plan becomes AppKit: button order and the Return-key button come from the
    /// plan, so the plan itself is what portable tests assert.
    @MainActor
    public static func makeAlert(from plan: LaunchAlertPlan) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = plan.isCritical ? .critical : .warning
        alert.messageText = plan.title
        alert.informativeText = plan.informativeText
        for (index, title) in plan.buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            button.keyEquivalent = index == plan.defaultButtonIndex ? "\r" : ""
        }
        return alert
    }

    @MainActor
    public static func verifyOnLaunch(beforeAlert: () -> Void = {}) -> Bool {
        switch launchGate() {
        case .proceed:
            return true
        case .refuseImpossible(let plan):
            // Record the refusal before the blocking alert: this is the only
            // durable evidence on a below-minimum Mac, and it must not claim the
            // app started. `beforeAlert` starts the log upload (R19), which runs
            // off the main thread while the owner reads the alert.
            DiagnosticChatLogger.record(role: "dot (error)",
                text: "Launch refused. \(plan.title): \(plan.informativeText)")
            beforeAlert()
            NSApp.activate(ignoringOtherApps: true)
            makeAlert(from: plan).runModal()
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
            alert.messageText = "Hardware Compatible"
            alert.informativeText = "Your Mac meets Dot's minimum specification.\n\n" +
                "• Processor: \(info.chip) (Apple M5 Pro class or newer required)\n" +
                "• Memory: \(info.ramGB) GB Unified Memory (\(minimumRAMGB) GB minimum)\n" +
                "• Operating System: macOS \(info.osString) (macOS \(minimumOSMajor).\(minimumOSMinor)+ required)\n\n" +
                "Dot runs the exact local Qwen3.8 27B Q4 model on Splash with no smaller fallback."

        case .belowMinimum(let info, let reasons):
            alert.alertStyle = .critical
            alert.messageText = "Hardware Does Not Meet Dot's Minimum"
            let items = reasons.map { "• " + $0 }.joined(separator: "\n")
            alert.informativeText = "Target Minimum: Apple Silicon M5 Pro class or newer, \(minimumRAMGB) GB Unified Memory, macOS \(minimumOSMajor).\(minimumOSMinor)+\n\n" +
                "Detected on this Mac:\n" +
                "• Processor: \(info.chip)\n" +
                "• Memory: \(info.ramGB) GB Unified Memory\n" +
                "• Operating System: macOS \(info.osString)\n\n" +
                "Not met:\n\(items)"

        case .technicallyImpossible(let info, let reason):
            alert.alertStyle = .critical
            alert.messageText = "Hardware Incompatible"
            alert.informativeText = "Reason: \(reason)\n\n" +
                "Detected:\n" +
                "• Processor: \(info.chip)\n" +
                "• Memory: \(info.ramGB) GB\n" +
                "• macOS: \(info.osString)"
        }
        alert.addButton(withTitle: "OK")
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

        // Labelled cancels: "cancel the tea timer" cancels only timers labelled "tea".
        // The remainder must really name a timer ("clear clipboard" is not one).
        let cancelPrefixes = ["cancel the ", "cancel ", "stop the ", "stop ", "clear the ", "clear "]
        for prefix in cancelPrefixes where lower.hasPrefix(prefix) {
            let remainder = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder == "timer" || remainder == "timers" { return .cancel(label: nil) }
            guard let suffix = [" timer", " timers"].first(where: { remainder.hasSuffix($0) }) else { return .none }
            let label = String(remainder.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? .cancel(label: nil) : .cancel(label: label)
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
    private var timers: [UUID: (timer: ScheduledTimer, task: Task<Void, Never>,
                                 onFire: @Sendable (ScheduledTimer) -> Void)] = [:]

    private init() {}

    public func schedule(seconds: Double, label: String, onFire: @escaping @Sendable (ScheduledTimer) -> Void = { _ in }) -> ScheduledTimer {
        let fireDate = Date().addingTimeInterval(seconds)
        let scheduled = ScheduledTimer(label: label, durationSeconds: seconds, fireDate: fireDate)
        let id = scheduled.id
        let task = Self.firingTask(id: id, timer: scheduled, seconds: seconds, onFire: onFire)

        lock.lock()
        timers[id] = (scheduled, task, onFire)
        lock.unlock()
        return scheduled
    }

    /// `Task.sleep` is a monotonic suspension; a Mac that sleeps through a timer
    /// deadline would otherwise fire late by the sleep duration. On wake, fire each
    /// missed timer exactly once (the spoken note is the owner's answer), and
    /// reschedule future timers against their wall-clock fire date. Returns the
    /// timers that were actually missed and fired at wake.
    @discardableResult
    public func handleWake(now: Date = Date()) -> [ScheduledTimer] {
        lock.lock()
        let entries = timers
        lock.unlock()
        var missed: [ScheduledTimer] = []
        for (id, entry) in entries {
            entry.task.cancel()
            let remaining = entry.timer.fireDate.timeIntervalSince(now)
            if remaining <= 0 {
                // Fire only when this wake removed the entry itself; the firing task
                // that lost the race must stay silent, so a timer never double-fires.
                if removeAndFireIfPresent(id, timer: entry.timer, onFire: entry.onFire) {
                    missed.append(entry.timer)
                }
            } else {
                let task = Self.firingTask(id: id, timer: entry.timer, seconds: remaining, onFire: entry.onFire)
                lock.lock()
                if timers[id] != nil { timers[id] = (entry.timer, task, entry.onFire) }
                lock.unlock()
            }
        }
        for timer in missed {
            DiagnosticChatLogger.record(role: "system", text: "Timer missed during sleep: \(timer.label) — firing once at wake.")
        }
        return missed
    }

    private static func firingTask(id: UUID, timer: ScheduledTimer, seconds: Double,
                                   onFire: @escaping @Sendable (ScheduledTimer) -> Void) -> Task<Void, Never> {
        Task {
            let ms = UInt64(max(0.1, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ms)
            guard !Task.isCancelled else { return }
            _ = SmartTimerScheduler.shared.removeAndFireIfPresent(id, timer: timer, onFire: onFire)
        }
    }

    /// Remove-and-fire as one decision: the callback runs only when this caller
    /// actually removed the entry, so the wake path and the firing task can race
    /// without ever firing the same timer twice, and a cancelled timer never fires.
    /// The callback runs outside the lock because it may re-enter the scheduler
    /// and NSLock is not recursive.
    private func removeAndFireIfPresent(_ id: UUID, timer: ScheduledTimer,
                                        onFire: @Sendable (ScheduledTimer) -> Void) -> Bool {
        lock.lock()
        let present = timers.removeValue(forKey: id) != nil
        lock.unlock()
        if present { onFire(timer) }
        return present
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

    /// Cancels only the timers whose label matches, case-insensitively; returns how
    /// many were removed. An empty label cancels nothing (call `cancelAll` for that).
    public func cancel(matching label: String) -> Int {
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let matched = timers.filter { $0.value.timer.label.lowercased() == lower }
        for id in matched.keys {
            timers[id]?.task.cancel()
            timers.removeValue(forKey: id)
        }
        return matched.count
    }

    public func activeTimers() -> [ScheduledTimer] {
        lock.lock()
        defer { lock.unlock() }
        return timers.values.map { $0.timer }.sorted { $0.fireDate < $1.fireDate }
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

// MARK: - Battery alerts (R14)

/// Owner-set, off-by-default battery notices. Pure state so the transitions can be
/// tested without IOKit: low is announced once per discharge below the threshold
/// (with hysteresis), charging once per plug-in transition.
public struct BatteryAlertPolicy: Equatable {
    public enum Alert: Equatable {
        case low(Int)
        case charging(Int)
    }
    private var lowAlerted = false
    private var wasCharging: Bool?

    public init() {}

    public mutating func evaluate(percent: Int, charging: Bool, enabled: Bool,
                                  lowThreshold: Int, chargingAlerts: Bool) -> Alert? {
        guard enabled, (0...100).contains(percent) else { return nil }
        if charging || percent > min(95, lowThreshold + 5) { lowAlerted = false }
        var alert: Alert?
        if chargingAlerts, charging, wasCharging == false {
            alert = .charging(percent)
        } else if !charging, percent <= lowThreshold, !lowAlerted {
            lowAlerted = true
            alert = .low(percent)
        }
        wasCharging = charging
        return alert
    }
}

/// Persisted owner choices. Alerts are off by default; the threshold defaults to 20%
/// and charging notices default on once alerts are enabled.
public struct BatteryAlertSettings {
    public static let thresholds = [10, 15, 20, 30]
    private let defaults: UserDefaults
    private static let enabledKey = "dot.batteryAlertsEnabled"
    private static let thresholdKey = "dot.batteryLowThreshold"
    private static let chargingKey = "dot.batteryChargingAlerts"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    public var lowThreshold: Int {
        get {
            let stored = defaults.integer(forKey: Self.thresholdKey)
            return stored == 0 ? 20 : max(5, min(50, stored))
        }
        nonmutating set {
            let bounded = max(5, min(50, newValue))
            defaults.set(bounded, forKey: Self.thresholdKey)
        }
    }
    public var chargingAlerts: Bool {
        get {
            defaults.object(forKey: Self.chargingKey) == nil
                ? true : defaults.bool(forKey: Self.chargingKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.chargingKey) }
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
    /// Typed failure: a failed recognition is not an empty screen, so callers can
    /// say "I could not read the screen text right now" instead of presenting the
    /// failure as a successful blank read.
    public enum RecognitionFailure: Error, Equatable { case recognitionFailed }

    public static func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel = .accurate) async throws -> [ScreenOCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: RecognitionFailure.recognitionFailed)
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
                continuation.resume(throwing: RecognitionFailure.recognitionFailed)
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
    private static let matcher = PhraseMatcher<ClipboardCommand>(
        .phrases(["clipboard", "read clipboard", "what is on my clipboard", "show clipboard", "check clipboard"], .read),
        .phrases(["clear clipboard", "empty clipboard"], .clear),
        .prefix("copy to clipboard ") { text, _ in
            .copy(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        },
        .phrases(["summarize clipboard", "summarize my clipboard"], .summarize),
        .phrases(["explain clipboard", "explain my clipboard", "explain code on clipboard"], .explain),
        .prefix("translate clipboard to ") { _, lower in
            .translate(language: lower.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    )
    public static func parseCommand(_ text: String) -> ClipboardCommand {
        matcher.match(text) ?? .none
    }

    /// Password managers mark copied secrets with these nspasteboard.org types.
    static let concealedTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    public static var holdsConcealedItem: Bool {
        #if canImport(AppKit)
        let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
        return types.contains { concealedTypes.contains($0) }
        #else
        return false
        #endif
    }

    public static func read() -> String? {
        #if canImport(AppKit)
        guard !holdsConcealedItem else { return nil }
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
    private static let fileName: (String, String) -> SystemControlCommand? = { text, _ in
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : .findFile(name: name)
    }
    private static let matcher = PhraseMatcher<SystemControlCommand>(
        .phrases(["toggle dark mode", "switch dark mode"], .toggleDarkMode),
        .phrases(["dark mode on", "enable dark mode", "turn on dark mode"], .setDarkMode(enabled: true)),
        .phrases(["dark mode off", "disable dark mode", "turn off dark mode", "light mode"], .setDarkMode(enabled: false)),
        .phrases(["mute", "mute volume", "mute audio", "silence audio"], .muteVolume),
        .phrases(["unmute", "unmute volume", "unmute audio"], .unmuteVolume),
        .phrases(["lock screen", "lock mac", "lock my mac"], .lockScreen),
        .prefix("find file ", fileName),
        .prefix("locate file ", fileName),
        .prefix("search file ", fileName)
    )
    public static func parseCommand(_ text: String) -> SystemControlCommand {
        matcher.match(text) ?? .none
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
            // Control-Command-Q locks the screen; System Events "sleep" slept the whole Mac.
            let script = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            return error == nil ? "Locking the screen." : "Could not lock screen."

        case .findFile(let name):
            do {
                let results = try findFilesSpotlight(named: name, limit: 5)
                if results.isEmpty {
                    return "No files found matching \"\(name)\"."
                } else {
                    let items = results.map { "• " + $0 }.joined(separator: "\n")
                    return "Found \(results.count) matching file\(results.count > 1 ? "s" : ""):\n\(items)"
                }
            } catch {
                return "Spotlight search failed (is indexing enabled?)"
            }

        case .none:
            return nil
        }
    }

    /// A Spotlight failure is not an empty result set: mdfind errors are surfaced so
    /// the caller never reports "no files found" when the index simply could not answer.
    enum SpotlightSearchError: LocalizedError, Equatable {
        case failed
        var errorDescription: String? { "Spotlight search failed (is indexing enabled?)" }
    }

    /// Search file *contents* (Spotlight indexes text, and the query is not limited to
    /// names). Read-only, bounded, and it throws rather than guessing.
    public static func searchFileContents(_ query: String, limit: Int = 5) throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }
        let result = try SubprocessRunner.run(executable: "/usr/bin/mdfind", arguments: [trimmed])
        guard result.status == 0 else { throw SpotlightSearchError.failed }
        let lines = String(decoding: result.data, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("/System/") && !$0.hasPrefix("/private/var/") }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    public static func findFilesSpotlight(named: String, limit: Int = 5) throws -> [String] {
        let result = try SubprocessRunner.run(executable: "/usr/bin/mdfind", arguments: ["-name", named])
        guard result.status == 0 else { throw SpotlightSearchError.failed }
        let output = String(decoding: result.data, as: UTF8.self)
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        return Array(lines.prefix(limit))
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
    case clickElement(description: String)
    case clickPoint(x: Double, y: Double, button: NativeMouseButton, clicks: Int)
    case moveMouse(description: String)
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
    /// The app the owner used before Dot's own panel took focus, if it still runs.
    public static func lastExternalApplication() -> NSRunningApplication? {
        lock.lock()
        let pid = lastExternalAppPID
        lock.unlock()
        guard let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

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

        let working = stripConversationalPrefixes(trimmed, prefixes: [
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "please ", "hey dot, ", "hey dot ", "dot, ", "dot ", "just "
        ])

        let lower = working.lowercased()

        // 0. App, browser, and navigation shortcuts
        if lower == "refresh this page" || lower == "refresh the page" || lower == "refresh page" ||
           lower == "reload this page" || lower == "reload the page" || lower == "reload page" ||
           lower == "refresh website" || lower == "refresh this website" {
            return .pressKey(key: "Cmd+R")
        }
        if lower == "new tab" || lower == "open new tab" || lower == "open a new tab" {
            return .pressKey(key: "Cmd+T")
        }
        if lower == "close tab" || lower == "close this tab" || lower == "close the tab" {
            return .pressKey(key: "Cmd+W")
        }
        if lower == "reopen tab" || lower == "reopen closed tab" || lower == "reopen the closed tab" {
            return .pressKey(key: "Cmd+Shift+T")
        }
        if lower == "select all" || lower == "select all text" {
            return .pressKey(key: "Cmd+A")
        }
        if lower == "copy" || lower == "copy that" || lower == "copy this" {
            return .pressKey(key: "Cmd+C")
        }
        if lower == "paste" || lower == "paste that" || lower == "paste here" {
            return .pressKey(key: "Cmd+V")
        }
        if lower == "go back" || lower == "navigate back" {
            return .pressKey(key: "Cmd+[")
        }
        if lower == "go forward" || lower == "navigate forward" {
            return .pressKey(key: "Cmd+]")
        }
        if lower == "fullscreen" || lower == "full screen" || lower == "toggle fullscreen" || lower == "exit fullscreen" {
            return .pressKey(key: "Ctrl+Cmd+F")
        }

        // 0.5. Mouse movement and clicks
        if lower.hasPrefix("move mouse ") || lower.hasPrefix("move cursor ") || lower.hasPrefix("move the mouse ") {
            let desc = working.components(separatedBy: " ").dropFirst(2).joined(separator: " ")
            return .moveMouse(description: desc)
        }
        if lower.hasPrefix("double click ") || lower.hasPrefix("double-click ") || lower.hasPrefix("double click on ") {
            let desc = working.components(separatedBy: " ").dropFirst(2).joined(separator: " ")
            return .clickElement(description: desc)
        }
        if lower.hasPrefix("right click ") || lower.hasPrefix("right-click ") || lower.hasPrefix("right click on ") {
            let desc = working.components(separatedBy: " ").dropFirst(2).joined(separator: " ")
            return .clickElement(description: desc)
        }
        if lower.hasPrefix("click ") || lower.hasPrefix("click on ") || lower.hasPrefix("click the ") || lower.hasPrefix("click that ") {
            var desc = working.components(separatedBy: " ").dropFirst(1).joined(separator: " ")
            if desc.lowercased().hasPrefix("on ") { desc = String(desc.dropFirst(3)) }
            if desc.lowercased().hasPrefix("the ") { desc = String(desc.dropFirst(4)) }
            if desc.lowercased().hasPrefix("that ") { desc = String(desc.dropFirst(5)) }
            desc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                return .clickElement(description: desc)
            }
        }

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
    /// Hard cap on one typing call: posting more than this many characters on the
    /// caller's actor would freeze the UI, so the tail is dropped instead. This is
    /// the schema's own `type_text` maximum, so tool calls never truncate.
    public static let maximumTypingCharacters = 1500

    @discardableResult
    public static func type(text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        // Type character by character so every Unicode grapheme (ASCII, accented, Cyrillic, CJK, emoji)
        // is delivered intact via keyboardSetUnicodeString. No per-character sleep: events are
        // posted into the HID queue in order, and the character cap bounds the total duration
        // so a max-length tool call cannot freeze the UI for seconds.
        for character in text.prefix(Self.maximumTypingCharacters) {
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
        // Never echo the text: it can be a password, and the reply is spoken and logged.
        let typed = text.count == 1 ? "1 character" : "\(text.count) characters"
        if let appName, !appName.isEmpty {
            return (true, "Typed \(typed) into \(appName) (the focused app).")
        }
        return (true, "Typed \(typed) into the focused app.")
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
    private var lastReflectedSessionStart: String?
    private var lastReflectedUserLineCount = 0

    /// The suggestion produced by the most recent reflection, so the coordinator can
    /// offer to paste it without parsing it back out of the spoken report.
    public private(set) var lastSuggestion: String?
    public static let noNewMaterialMessage = "No new conversation to reflect on yet."

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

    static func currentSessionLines(_ content: String) -> [String] {
        let all = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let start = all.lastIndex { $0.contains("[SYSTEM] App session started") }
        return start.map { Array(all[$0...]) } ?? all
    }

    public func analyzeConversationLog(logContent: String) -> String {
        // The app writes a session marker on every launch. Analyse only the current
        // session: an older or fixture-written tail is not evidence about today.
        let recentLines = Array(Self.currentSessionLines(logContent).suffix(120))

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
    /// `copyToClipboard` is only for the owner's explicit "self reflect" command;
    /// the idle ticker never touches the clipboard (R20, owner answer 2026-10-22).
    public func performReflectionAndWriteToAntigravity(logURL: URL? = nil, copyToClipboard: Bool = true) -> String {
        markReflected()
        lock.lock(); lastSuggestion = nil; lock.unlock()
        let url = logURL ?? DiagnosticChatLogger.logFileURL
        let content = (url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let lines = Self.currentSessionLines(content)
        let sessionStart = lines.last { $0.contains("[SYSTEM] App session started") }
        // Only the owner's lines count as material: Dot's own '[DOT'-marked
        // reflection and reply lines must never feed the loop back into itself.
        let userLineCount = lines.filter { $0.contains("[USER]") }.count
        lock.lock()
        let newSession = sessionStart != lastReflectedSessionStart
        let previousUserCount = newSession ? 0 : lastReflectedUserLineCount
        lock.unlock()
        // A new [USER] line since the last reflection is required before any
        // suggestion, including the rotating fallbacks. Analysing an empty or
        // self-written log was how the every-10-minutes junk loop was produced.
        guard userLineCount > 0, userLineCount > previousUserCount else { return Self.noNewMaterialMessage }
        let suggestion = analyzeConversationLog(logContent: content)
        lock.lock()
        lastSuggestion = suggestion
        lastReflectedSessionStart = sessionStart
        lastReflectedUserLineCount = userLineCount
        lock.unlock()

        // Write to the reflections log next to the chat log (Application Support/
        // Dot/Logs, one shared path constant), rotating by size like the chat log.
        // The result is reported, never assumed.
        var wroteFile = false
        if let reflectionURL = DiagnosticChatLogger.reflectionsFileURL(for: url) {
            let directory = reflectionURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            DiagnosticChatLogger.rotateIfOversized(reflectionURL,
                                                   rotatedName: DiagnosticChatLogger.rotatedReflectionsFileName)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "[\(timestamp)] \(suggestion)\n"
            if FileManager.default.fileExists(atPath: reflectionURL.path) {
                if let handle = try? FileHandle(forWritingTo: reflectionURL) {
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data(entry.utf8))
                        try handle.close()
                        wroteFile = true
                    } catch { try? handle.close() }
                }
            } else {
                wroteFile = (try? entry.write(to: reflectionURL, atomically: true, encoding: .utf8)) != nil
            }
        }

        // The owner asked for this: never type into another application unprompted.
        // The suggestion is written to its own file above and copied to the clipboard
        // so it can be pasted deliberately, and Dot states what actually happened.
        guard copyToClipboard else { return Self.shortNote(wroteFile: wroteFile) }
        let copied = ClipboardIntelligence.write(suggestion)
        return Self.reflectionReport(suggestion: suggestion, readLog: true, wroteFile: wroteFile, copied: copied)
    }

    /// R20: what the idle reflection says aloud: one short sentence. The full
    /// suggestion goes to the reflections file and the uploaded log instead.
    static func shortNote(wroteFile: Bool) -> String {
        wroteFile ? "I noted an idea to improve myself." : "I had an idea to improve myself, but couldn't save it."
    }

    static func reflectionReport(suggestion: String, readLog: Bool, wroteFile: Bool, copied: Bool) -> String {
        var parts: [String] = []
        parts.append(wroteFile ? "Wrote the suggestion to my reflections file."
                               : "Could not write my reflections file.")
        parts.append(copied ? "Copied it to the clipboard." : "Could not copy it to the clipboard.")
        if !readLog { parts.append("I could not read my conversation log, so this is a general suggestion.") }
        parts.append("Suggestion: \"\(suggestion)\"")
        return parts.joined(separator: " ")
    }
}

// MARK: - Self-Codebase Indexing & Live Source Reader

public enum SelfCodebaseReader {
    /// Where Dot reads its own source. Resolved when it is asked rather than pinned
    /// to one machine: an explicit override wins, then the source root recorded by
    /// the installer in `build-provenance.json`, then the long-standing checkout if
    /// it is really there, and otherwise nothing - so a machine without the source
    /// says so instead of searching a path that cannot exist.
    public static var defaultRootPath: String {
        resolvedRoot()
    }

    /// Injectable form for tests; every candidate must really contain `src`.
    public static func resolvedRoot(bundleResourceURL: URL? = Bundle.main.resourceURL,
                                    environment: [String: String] = ProcessInfo.processInfo.environment,
                                    historicalRoot: String = "/Users/mac/.gemini/antigravity/scratch/Dot") -> String {
        func hasSource(_ root: String) -> Bool {
            !root.isEmpty && FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("src"))
        }
        if let override = environment["DOT_SOURCE_ROOT"], hasSource(override) {
            return override
        }
        if let resource = bundleResourceURL?.appendingPathComponent("build-provenance.json"),
           let data = try? Data(contentsOf: resource),
           let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = record["source_root"] as? String, hasSource(root) {
            return root
        }
        return hasSource(historicalRoot) ? historicalRoot : ""
    }

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
    private static let matcher = PhraseMatcher<WindowSnapLayout>(
        .phrases(["snap window left", "snap left", "window left half", "tile window left"], .leftHalf),
        .phrases(["snap window right", "snap right", "window right half", "tile window right"], .rightHalf),
        .phrases(["snap window top", "window top half"], .topHalf),
        .phrases(["snap window bottom", "window bottom half"], .bottomHalf),
        .phrases(["maximize window", "fullscreen window", "expand window"], .maximize),
        .phrases(["center window", "center active window"], .center)
    )
    public static func parseCommand(_ text: String) -> WindowSnapLayout? {
        matcher.match(text)
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

    @MainActor
    public static func executeWorkspaceAction(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "show desktop" || lower == "desktop" {
            _ = InPlaceAppTyping.sendKey("Cmd+F3")
            return "Showing your desktop."
        }
        if lower == "hide others" || lower == "hide other apps" || lower == "hide background apps" || lower == "minimize background apps" || lower == "clean workspace" {
            _ = InPlaceAppTyping.sendKey("Cmd+Option+H")
            return "Hidden other background applications."
        }
        return nil
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
    private static let matcher = PhraseMatcher<SimulatorCommand>(
        .phrases(["list simulators", "booted simulators", "check simulator", "simulator status"], .listBooted),
        .phrases(["open simulator", "launch simulator", "start simulator"], .openSimulatorApp),
        .phrases(["simulator screenshot", "take simulator screenshot"], .screenshot)
    )
    public static func parseCommand(_ text: String) -> SimulatorCommand {
        matcher.match(text) ?? .none
    }

    #if canImport(AppKit)
    @MainActor
    public static func execute(_ command: SimulatorCommand) -> String? {
        switch command {
        case .listBooted:
            do {
                let data = try SubprocessRunner.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "booted"]).data
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
            // Under the App Sandbox the Desktop is read-only (R21); the screenshot goes
            // to Dot's own Documents folder and is revealed in Finder.
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return "Could not resolve Dot's Documents folder."
            }
            let folder = support.appendingPathComponent("Dot/Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let outURL = folder.appendingPathComponent("simulator_screenshot_\(Int(Date().timeIntervalSince1970)).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "io", "booted", "screenshot", outURL.path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                    return "Saved the iOS Simulator screenshot to Dot's Documents folder (\(outURL.lastPathComponent)) and showed it in Finder."
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
        let ramSnap = SystemRAMInspector.currentRAM()
        let memoryFactsCount = PersistentMemoryBrain.shared.readProfileBullets().count + PersistentMemoryBrain.shared.readVolatileBullets().count
        let axTrusted = InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: false)
        let isMuted = SystemAudioState.isOutputMuted()
        return "Neural Diagnostics: Model Qwen 3.8 27B 4-bit (Splash) \(engineReady ? "Ready" : "Warming") | Voice Kokoro bf_isabella | App RAM: \(residentMB) MB | Host Memory: \(ramSnap.usagePercent)% used (\(String(format: "%.1f", ramSnap.freeGB)) GB free of \(String(format: "%.1f", ramSnap.totalGB)) GB) on \(hw.chip) | Audio: \(isMuted ? "Muted" : "Active") | Memories: \(memoryFactsCount) facts stored | Accessibility: \(axTrusted ? "Granted" : "Not Granted") | Active Timers: \(activeTimersCount)."
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

// MARK: - Adaptive screen watching (R8)

/// Pure cadence for adaptive screen watching. One idle snapshot every three minutes;
/// a change or real mouse movement starts a 10–50 s watch that is extended while the
/// screen keeps changing and stops after a settled period. Battery/low-power and the
/// visible screen switch gate every capture.
public struct ScreenWatchState: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, idleSnapshot, startWatch, captureFrame, stop }
    public static let idleInterval = 180.0
    public static let frameInterval = 2.0
    public static let minimumWatch = 10.0
    public static let maximumWatch = 50.0
    public static let settleInterval = 4.0
    public static let triggerCooldown = 60.0

    private var watching = false
    private var startedAt = 0.0
    private var lastChangeAt = 0.0
    private var lastFrameAt = 0.0
    private var lastIdleAt = -Self.idleInterval
    private var lastTriggerAt = -Self.triggerCooldown

    public init() {}

    public var isWatching: Bool { watching }

    public mutating func tick(now: Double, enabled: Bool, idle: Bool, changed: Bool,
                              inputActive: Bool, batteryOK: Bool) -> Action {
        guard now.isFinite else { return .none }
        if !enabled || !idle {
            if watching { watching = false; return .stop }
            return .none
        }
        if watching {
            if changed { lastChangeAt = now }
            if now - startedAt >= Self.maximumWatch { watching = false; return .stop }
            if now - startedAt >= Self.minimumWatch, now - lastChangeAt >= Self.settleInterval {
                watching = false
                return .stop
            }
            if now - lastFrameAt >= Self.frameInterval {
                lastFrameAt = now
                return .captureFrame
            }
            return .none
        }
        if batteryOK, (changed || inputActive), now - lastTriggerAt >= Self.triggerCooldown {
            watching = true
            startedAt = now; lastChangeAt = now; lastFrameAt = now; lastTriggerAt = now
            return .startWatch
        }
        if now - lastIdleAt >= Self.idleInterval {
            lastIdleAt = now
            return .idleSnapshot
        }
        return .none
    }
}

// MARK: - Microphone mode

/// macOS exposes the Control Center microphone filters only as read-only state plus
/// a system selector; there is no public setter. Dot reports the active mode, offers
/// the selector in its menu, and nudges once so the owner can choose Wide Spectrum.
public enum MicrophoneMode {
    public static var current: AVCaptureDevice.MicrophoneMode {
        if #available(macOS 12.0, *) { return AVCaptureDevice.activeMicrophoneMode }
        return .standard
    }

    public static var displayName: String {
        switch current {
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        default: return "Standard"
        }
    }

    public static var isWideSpectrum: Bool { current == .wideSpectrum }

    public static func displayName(for mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        default: return "Standard"
        }
    }

    public static func openSystemSelector() {
        if #available(macOS 12.0, *) {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        }
    }
}

// MARK: - Video playback silence

/// Dot stays quiet while the owner is watching a video. Detection is deliberately
/// conservative about *not* speaking: a known video app, a browser with a video-shaped
/// window title, or audio playing in a browser/video app all count. Muted videos in a
/// background window are undetectable with public APIs and are not guessed.
public enum VideoPlaybackDetector {
    public static let videoAppSignatures = [
        "com.apple.quicktimeplayerx", "com.apple.quicktimeplayer", "com.apple.tv", "com.apple.dvdplayer",
        "org.videolan.vlc", "com.colliderli.iina", "io.mpv", "com.plexapp.plex", "tv.kodi.kodi",
        "com.elmediaplayer", "com.movistplayer", "com.5kplayer", "com.infuseapp.infuse"
    ]
    /// Apps that are not dedicated players but do play videos; only their audio
    /// makes them count, so browsing photos does not silence Dot.
    public static let mediaAppSignatures = ["com.apple.photos"]
    public static let browserSignatures = [
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "company.thebrowser.browser",
        "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi",
        "com.kagi.kagimini", "com.orionbrowser.orion"
    ]
    public static let videoTitleHints = [
        "youtube", "netflix", "prime video", "disney+", "hulu", "vimeo", "twitch", "hbo max",
        "max.com", "paramount+", "peacock", "plex", "apple tv", "video", "watch", "lecture",
        "course", "webinar"
    ]

    public static func isVideoContext(appName: String?, bundleID: String?, windowTitle: String?,
                                      audioPlaying: Bool) -> Bool {
        let id = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()
        let title = (windowTitle ?? "").lowercased()
        let videoApp = videoAppSignatures.contains { id.contains($0) || name.contains($0) }
        let browser = browserSignatures.contains { id.contains($0) || name.contains($0) }
        let mediaApp = mediaAppSignatures.contains { id.contains($0) || name.contains($0) }
        let shapedTitle = videoTitleHints.contains { title.contains($0) }
        if videoApp { return true }
        if mediaApp && audioPlaying { return true }
        if browser && shapedTitle { return true }
        if audioPlaying && (browser || videoApp) { return true }
        return false
    }

    #if canImport(AppKit)
    private struct ForeignContext {
        let name: String?
        let bundleID: String?
        let title: String?
        let at: Double
    }
    @MainActor private static var recentForeign: [ForeignContext] = []
    @MainActor private static var lastRecorded: (String?, Double) = (nil, -1)

    /// Called on app activation changes, before Dot itself takes focus, so a video app
    /// remains identifiable while the owner has clicked Dot.
    @MainActor public static func recordFrontmostApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastRecorded.0, last == front.bundleIdentifier, now - lastRecorded.1 < 5 { return }
        let context = ActiveDesktopContext.current()
        lastRecorded = (front.bundleIdentifier, now)
        recentForeign.append(ForeignContext(name: context.appName, bundleID: front.bundleIdentifier,
                                            title: context.windowTitle, at: now))
        recentForeign.removeAll { $0.at < now - 600 }
        if recentForeign.count > 6 { recentForeign.removeFirst(recentForeign.count - 6) }
    }

    @MainActor public static func isWatchingVideo() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let isSelf = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        if !isSelf { recordFrontmostApp() }
        let audio = isAudioPlaying()
        if !isSelf {
            let context = ActiveDesktopContext.current()
            if isVideoContext(appName: context.appName, bundleID: front?.bundleIdentifier,
                              windowTitle: context.windowTitle, audioPlaying: audio) { return true }
        } else if audio {
            let cutoff = ProcessInfo.processInfo.systemUptime - 600
            for entry in recentForeign where entry.at >= cutoff {
                if isVideoContext(appName: entry.name, bundleID: entry.bundleID,
                                  windowTitle: entry.title, audioPlaying: true) { return true }
            }
        }
        return false
    }
    #endif

    /// Public CoreAudio: whether any client is using the default output device. Dot
    /// checks this before its own audio starts, so its voice cannot suppress itself.
    public static func isAudioPlaying() -> Bool {
        #if canImport(CoreAudio)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return false }
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr else { return false }
        return running != 0
        #else
        return false
        #endif
    }
}

// MARK: - On-Screen Visual Guidance & Laser Pointer Overlay

public enum LaserPointerCommand: Equatable {
    case pointToCenter
    case pointAt(x: CGFloat, y: CGFloat)
    case highlightActiveWindow
    case none
}

public enum LaserPointerParser {
    private static let matcher = PhraseMatcher<LaserPointerCommand>(
        .phrases(["point", "laser pointer", "show pointer", "where are you looking", "point here"], .pointToCenter),
        .phrases(["highlight window", "highlight active window", "outline window"], .highlightActiveWindow)
    )
    public static func parse(_ text: String) -> LaserPointerCommand {
        matcher.match(text) ?? .none
    }
}

/// Explicit mapping between the two global display coordinate spaces macOS mixes:
/// CoreGraphics/Vision report top-left origins with y increasing downward (`CGEvent`,
/// `CGWarpMouseCursorPosition`, `VNRecognizedTextObservation`), while AppKit reports bottom-left
/// origins with y increasing upward (`NSScreen.frame`, `NSPanel` frames, `NSEvent.mouseLocation`).
/// Panels are positioned in AppKit space even when the rect came from Vision or CG, so every
/// crossing goes through this type instead of assuming the two spaces are the same.
struct ScreenCoordinateSpace: Equatable, Sendable {
    /// AppKit frame of the primary display, whose bottom-left corner is the AppKit origin.
    let primaryFrame: CGRect
    /// AppKit frame of the display that owns the converted coordinates.
    let screenFrame: CGRect

    init(primaryFrame: CGRect, screenFrame: CGRect) {
        self.primaryFrame = primaryFrame
        self.screenFrame = screenFrame
    }

    /// The target display's bounds in CG/Vision global top-left coordinates.
    var screenBoundsInTopLeft: CGRect {
        CGRect(x: screenFrame.minX,
               y: primaryFrame.maxY - screenFrame.maxY,
               width: screenFrame.width,
               height: screenFrame.height)
    }

    /// Flipping about the primary display's horizontal mid-line maps one global space to the other.
    /// x is shared: both spaces grow rightward from the primary display's left edge.
    func appKitPoint(fromTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryFrame.maxY - point.y)
    }
    func topLeftPoint(fromAppKit point: CGPoint) -> CGPoint {
        appKitPoint(fromTopLeft: point)
    }

    func appKitRect(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    func topLeftRect(fromAppKit rect: CGRect) -> CGRect {
        appKitRect(fromTopLeft: rect)
    }

    /// Vision/OCR boxes are normalized to the captured image with a bottom-left origin; scaling
    /// them by the owning display's size yields pixels local to that display with a top-left origin.
    func screenLocalRect(fromVisionNormalized rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * screenFrame.width,
               y: (1 - rect.maxY) * screenFrame.height,
               width: rect.width * screenFrame.width,
               height: rect.height * screenFrame.height)
    }
    func screenLocalPoint(fromVisionNormalized point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * screenFrame.width, y: (1 - point.y) * screenFrame.height)
    }

    /// A rect in the target display's local top-left pixels to that display's AppKit global frame.
    func appKitRect(fromScreenTopLeftLocal rect: CGRect) -> CGRect {
        let origin = screenBoundsInTopLeft.origin
        return appKitRect(fromTopLeft: rect.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// A Vision/OCR box straight to AppKit global coordinates, for panel placement.
    func appKitRect(fromVisionNormalized rect: CGRect) -> CGRect {
        appKitRect(fromScreenTopLeftLocal: screenLocalRect(fromVisionNormalized: rect))
    }
}

#if canImport(AppKit)
extension ScreenCoordinateSpace {
    /// AppKit frame of the primary (menu bar) display; its origin is (0, 0).
    @MainActor
    static func primaryFrame() -> CGRect {
        let screens = NSScreen.screens
        return (screens.first(where: { $0.frame.origin == .zero }) ?? screens.first)?.frame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    @MainActor
    static func current() -> ScreenCoordinateSpace {
        ScreenCoordinateSpace(primaryFrame: primaryFrame(), screenFrame: NSScreen.main?.frame ?? primaryFrame())
    }

    @MainActor
    static func current(for screen: NSScreen?) -> ScreenCoordinateSpace {
        ScreenCoordinateSpace(primaryFrame: primaryFrame(), screenFrame: screen?.frame ?? NSScreen.main?.frame ?? primaryFrame())
    }

    /// Space of the display that contains `point` in CG/Vision global top-left coordinates.
    @MainActor
    static func current(containing point: CGPoint) -> ScreenCoordinateSpace {
        let primary = primaryFrame()
        for screen in NSScreen.screens {
            let candidate = ScreenCoordinateSpace(primaryFrame: primary, screenFrame: screen.frame)
            if candidate.screenBoundsInTopLeft.contains(point) { return candidate }
        }
        return current()
    }

    @MainActor
    static func current(containing rect: CGRect) -> ScreenCoordinateSpace {
        current(containing: CGPoint(x: rect.midX, y: rect.midY))
    }
}
#endif

#if canImport(AppKit)
@MainActor
public final class ScreenGuideLaserOverlay {
    public static let shared = ScreenGuideLaserOverlay()
    private var window: NSPanel?

    private init() {}

    /// `point` is in CG/Vision global top-left coordinates (`CGEvent`/`CGWarpMouseCursorPosition`
    /// space); the panel frame is converted to AppKit bottom-left space for the owning display.
    public func showPointer(at point: CGPoint, duration: TimeInterval = 2.5) {
        dismiss()
        let size: CGFloat = 80
        let center = ScreenCoordinateSpace.current(containing: point).appKitPoint(fromTopLeft: point)
        let frame = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
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
        // Callers pass CG/Vision top-left global coordinates; panels need AppKit bottom-left space.
        let appKit = ScreenCoordinateSpace.current(containing: rect).appKitRect(fromTopLeft: rect)
        let inset = appKit.insetBy(dx: -8, dy: -8)
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

/// R7: a bounded view of recently changed files across the owner's usual folders.
/// Only names, folders, times and a work-in-progress hint leave the scan; contents
/// are never read here.
public struct FileInsight: Equatable, Sendable {
    public let name: String
    public let folder: String
    public let modifiedAt: Date
    public let isWorkInProgress: Bool
    public init(name: String, folder: String, modifiedAt: Date, isWorkInProgress: Bool) {
        self.name = name; self.folder = folder; self.modifiedAt = modifiedAt
        self.isWorkInProgress = isWorkInProgress
    }
}

public enum FileInsightScanner {
    public static func recentFiles(in roots: [URL], now: Date = Date(),
                                   lookback: TimeInterval = 86_400, limit: Int = 6,
                                   maximumEntriesPerRoot: Int = 600) -> [FileInsight] {
        var found: [FileInsight] = []
        let cutoff = now.addingTimeInterval(-max(0, lookback))
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isHiddenKey]
        for root in roots {
            var examined = 0
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                examined += 1
                if examined > maximumEntriesPerRoot { break }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isHidden != true,
                      let modified = values.contentModificationDate,
                      modified >= cutoff else { continue }
                let name = url.lastPathComponent
                if name.hasPrefix(".") || name == "dot_chat_log.txt" { continue }
                let lower = name.lowercased()
                let wip = ["draft", "todo", "wip", "untitled"].contains { lower.contains($0) }
                found.append(FileInsight(name: name, folder: root.lastPathComponent,
                                         modifiedAt: modified, isWorkInProgress: wip))
            }
        }
        return Array(found.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(max(0, limit)))
    }

    public static func summary(_ files: [FileInsight], now: Date = Date()) -> String? {
        guard !files.isEmpty else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let parts = files.prefix(5).map { file -> String in
            let age = formatter.localizedString(for: file.modifiedAt, relativeTo: now)
            let wip = file.isWorkInProgress ? ", work in progress" : ""
            return "\(file.name) (\(file.folder), \(age)\(wip))"
        }
        return parts.joined(separator: "; ")
    }
}

public struct AutonomousWorkspaceSnapshot: Equatable, Sendable {
    public let activeApp: String
    public let windowTitle: String?
    public let selectedText: String?
    public let recentDownloadFile: String?
    public let clipboardSignal: String?
    public let autonomousActionNote: String?
    public let recentFiles: [FileInsight]

    public init(
        activeApp: String,
        windowTitle: String?,
        selectedText: String?,
        recentDownloadFile: String?,
        clipboardSignal: String?,
        autonomousActionNote: String?,
        recentFiles: [FileInsight] = []
    ) {
        self.activeApp = activeApp
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.recentDownloadFile = recentDownloadFile
        self.clipboardSignal = clipboardSignal
        self.autonomousActionNote = autonomousActionNote
        self.recentFiles = recentFiles
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
        if let files = FileInsightScanner.summary(recentFiles) {
            lines.append("Recently Changed Files: \(files)")
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
        let downloadsURL = UserFolderScope.userFolder("Downloads")
        if let items = try? FileManager.default.contentsOfDirectory(
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

        let recentFiles = FileInsightScanner.recentFiles(in: UserFolderScope.watchedFolders)
        return AutonomousWorkspaceSnapshot(
            activeApp: appName,
            windowTitle: winTitle,
            selectedText: desktop.selectedText,
            recentDownloadFile: recentDownload,
            clipboardSignal: clipboardSignal,
            autonomousActionNote: actionNote,
            recentFiles: recentFiles
        )
    }

    @MainActor
    public func generateProactiveTip(for desktop: ActiveDesktopContext) -> String? {
        let app = (desktop.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "").lowercased()
        let win = (desktop.windowTitle ?? "").lowercased()
        let ocr = (desktop.selectedText ?? "").lowercased()

        if app.contains("xcode") {
            if win.contains("error") || ocr.contains("error:") || ocr.contains("build failed") {
                return "I noticed an Xcode build issue. Would you like me to inspect recent changes or run tests?"
            }
            return "Working in Xcode? You can tell me to 'build', 'run', or 'clean' anytime."
        } else if app.contains("terminal") || app.contains("iterm") || app.contains("ghostty") {
            if ocr.contains("error:") || ocr.contains("failed") {
                return "I noticed an error in Terminal. Would you like me to check git status or inspect the log?"
            }
            return "Working in Terminal? You can tell me 'git status' or 'git diff' to check repository status."
        } else if app.contains("safari") || app.contains("chrome") {
            return "Browsing the web? You can tell me to toggle Reader Mode or copy this page link."
        } else if app.contains("figma") {
            return "Designing in Figma? You can tell me to 'zoom to fit' or 'toggle UI'."
        } else if !lastIndexedDownload.isEmpty {
            let download = lastIndexedDownload
            return "I noticed a recent download '\(download)'. Would you like me to open it or move it to a project folder?"
        }
        return "I'm monitoring your workspace and ready to help. You can ask me to run shortcuts, click elements, or automate tasks."
    }
    #endif
}

// MARK: - Hierarchical Persistent Memory Brain & Expanded Context Window

public enum MemoryDirectCommand: Equatable, Sendable {
    case listMemories
    case forget(topic: String)
    case rememberExplicit(fact: String)
    case none
}

public final class PersistentMemoryBrain: @unchecked Sendable {
    public static let shared = PersistentMemoryBrain()

    private let lock = NSLock()
    private let memoryDirectory: URL
    private let profileURL: URL
    private let volatileURL: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.memoryDirectory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.memoryDirectory = support
                .appendingPathComponent("Dot", isDirectory: true)
                .appendingPathComponent("Memory", isDirectory: true)
        }
        self.profileURL = self.memoryDirectory.appendingPathComponent("PROFILE.md")
        self.volatileURL = self.memoryDirectory.appendingPathComponent("VOLATILE.md")
        try? FileManager.default.createDirectory(at: self.memoryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public static func parseCommand(_ text: String) -> MemoryDirectCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
        if lower == "what do you remember" || lower == "what do you remember about me" ||
           lower == "show memories" || lower == "list memories" || lower == "my memories" ||
           lower == "memory status" || lower == "show your memory" || lower == "what is in your memory" {
            return .listMemories
        }
        let forgetPrefixes = ["forget that ", "forget about ", "delete memory ", "remove from memory "]
        for prefix in forgetPrefixes {
            if lower.hasPrefix(prefix) {
                let topic = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !topic.isEmpty {
                    return .forget(topic: topic)
                }
            }
        }
        let explicitRememberPrefixes = ["remember strictly: ", "remember always: ", "save to memory: "]
        for prefix in explicitRememberPrefixes {
            if lower.hasPrefix(prefix) {
                let fact = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !fact.isEmpty {
                    return .rememberExplicit(fact: fact)
                }
            }
        }
        return .none
    }

    public func readProfileBullets(limit: Int = 30) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return readBullets(from: profileURL, limit: limit)
    }

    public func readVolatileBullets(limit: Int = 20) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return readBullets(from: volatileURL, limit: limit)
    }


    private func readBullets(from url: URL, limit: Int) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") }
        return Array(lines.suffix(limit))
    }

    public func readProfile() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
    }

    public func readVolatile() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: volatileURL, encoding: .utf8)) ?? ""
    }

    public func writeProfile(_ content: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? content.write(to: profileURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
    }

    public func writeVolatile(_ content: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? content.write(to: volatileURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: volatileURL.path)
    }


    /// Convenience turn context assembler querying FTS and active desktop state.
    func assembleTurnContext(
        query: String,
        ftsStore: LocalFTSStore?,
        activeDesktop: ActiveDesktopContext?,
        memory: MemoryTierStore? = nil
    ) async -> String? {
        var queryMems: [String] = []
        var pastTurns: [String] = []
        var docEvidence: [String] = []
        var pinnedMems: [String] = []

        if let memory {
            // Tiered recall: core records are identity, preferences and corrected
            // facts, so they lead; the rest follow by tier through the same store, so
            // promotion and supersession are respected instead of being invisible.
            // Newest first: the store lists records oldest first, so recent
            // corrections/preferences would otherwise be the ones dropped by limit 15.
            // Oldest-first stays reserved for the eviction/ageing paths.
            if let core = try? await memory.records(tier: .core, limit: 200, includeSuperseded: false) {
                pinnedMems = core.sorted { $0.updatedAt > $1.updatedAt }.prefix(15).map(\.text)
            }
            if let recalled = try? await memory.recall(query: query, limit: 10, now: Date()) {
                queryMems = recalled.map(\.text)
            }
        }
        if let fts = ftsStore {
            if pinnedMems.isEmpty, let pinned = try? await fts.listPinnedMemories(limit: 15) {
                pinnedMems = pinned.map { $0.fact }
            }
            if queryMems.isEmpty, let searched = try? await fts.searchMemories(query: query, limit: 10) {
                queryMems = searched.map { $0.fact }
            }
            if let past = try? await fts.searchConversations(query: query, limit: 5) {
                pastTurns = past.map { "\($0.role.rawValue): \($0.text)" }
            }
            if let evidence = try? await fts.searchEvidence(query: query, limit: 3) {
                docEvidence = evidence.map { "\($0.title): \($0.snippet)" }
            }
        }

        switch WholeContextExtractor.shared.extractActiveDocumentOrWebpageText() {
        case .text(let source, let content):
            docEvidence.append("\(source): \(content)")
        case .permissionDenied:
            DiagnosticChatLogger.record(role: "system", text: "Context extraction skipped: permission denied for the active document or webpage.")
        case .noText:
            DiagnosticChatLogger.record(role: "system", text: "Context extraction skipped: the active document or webpage had no readable text.")
        }

        var desktopSnippet = activeDesktop?.promptContextSnippet
        if let pastScreens = PreviousScreenMemory.shared.formatPromptSnippet() {
            if let existing = desktopSnippet {
                desktopSnippet = existing + " | " + pastScreens
            } else {
                desktopSnippet = "[" + pastScreens + "]"
            }
        }

        return assembleTurnContext(
            pinnedMemories: pinnedMems,
            queryMemories: queryMems,
            recalledConversations: pastTurns,
            documentEvidence: docEvidence,
            desktopContextSnippet: desktopSnippet,
            includeMarkdownFiles: true
        )
    }

    /// Assembles a unified, deduplicated memory context block combining always-pinned facts,
    /// query-relevant memories, recalled past conversations, document evidence, and desktop context.
    public func assembleTurnContext(
        pinnedMemories: [String],
        queryMemories: [String],
        recalledConversations: [String],
        documentEvidence: [String],
        desktopContextSnippet: String?,
        includeMarkdownFiles: Bool = true
    ) -> String? {
        var sections: [String] = []
        var seenFacts = Set<String>()
        var coreItems: [String] = []

        func appendCore(_ raw: String) {
            let cleaned = raw.replacingOccurrences(of: #"^-\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            let norm = cleaned.lowercased()
            guard seenFacts.insert(norm).inserted else { return }
            coreItems.append(cleaned)
        }

        for fact in pinnedMemories { appendCore(fact) }
        if includeMarkdownFiles {
            for bullet in readProfileBullets(limit: 20) { appendCore(bullet) }
            for bullet in readVolatileBullets(limit: 12) { appendCore(bullet) }
        }
        for fact in queryMemories { appendCore(fact) }

        if !coreItems.isEmpty {
            sections.append("Persistent Memories: " + coreItems.prefix(28).joined(separator: " ; "))
        }
        if !recalledConversations.isEmpty {
            sections.append("Recalled Past Turns: " + recalledConversations.prefix(6).joined(separator: " ; "))
        }
        if !documentEvidence.isEmpty {
            sections.append("Document Evidence: " + documentEvidence.prefix(5).joined(separator: " ; "))
        }
        if let desktop = desktopContextSnippet, !desktop.isEmpty {
            sections.append(desktop)
        }
        guard !sections.isEmpty else { return nil }
        return "\n[Context: " + sections.joined(separator: " | ") + "]"
    }
}

public enum ExpandedContextWindow {
    /// Maximum conversation messages retained in live memory (increased from 12 to 64).
    public static let maxHistoryMessages: Int = 64
    /// Maximum characters per message sent to the local LLM (increased from 6,000 to 24,000).
    public static let maxCharsPerMessage: Int = 24_000
    /// Maximum total character budget across the multi-turn conversation history (~30,000 tokens).
    public static let maxTotalHistoryChars: Int = 120_000
    /// Maximum completion tokens per turn (increased from 1,536 to 4,096).
    public static let maxCompletionTokens: Int = 4_096

    /// Selects the most recent messages up to `maxMessages`, truncating individual messages to
    /// `maxCharsPerMessage` and fitting within `maxTotalChars` while always keeping the newest message.
    public static func buildMessages(
        from history: [(role: String, content: String)],
        maxMessages: Int = maxHistoryMessages,
        maxCharsPerMessage: Int = maxCharsPerMessage,
        maxTotalChars: Int = maxTotalHistoryChars
    ) -> [[String: Any]] {
        let candidateSlice = history.suffix(max(1, maxMessages))
        var selectedReversed: [[String: Any]] = []
        var totalChars = 0

        for item in candidateSlice.reversed() {
            let truncated = String(item.content.prefix(max(1, maxCharsPerMessage)))
            let len = truncated.count
            if !selectedReversed.isEmpty && (totalChars + len > maxTotalChars) {
                break
            }
            selectedReversed.append(["role": item.role, "content": truncated])
            totalChars += len
        }

        return selectedReversed.reversed()
    }
}

// MARK: - Mouse Control Engine (Move, Click & Vision OCR Match)

#if canImport(CoreGraphics) && canImport(AppKit)
@MainActor
public enum MouseControlEngine {
    public static func moveMouse(to point: CGPoint) -> Bool {
        guard InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: true) else {
            return false
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }

        CGWarpMouseCursorPosition(point)
        let source = CGEventSource(stateID: .hidSystemState)
        let moveEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
        return true
    }

    public static func moveMouseRelative(description: String) -> (succeeded: Bool, confirmation: String) {
        guard let screen = NSScreen.main else {
            return (false, "No active screen found.")
        }
        let frame = screen.frame
        let space = ScreenCoordinateSpace.current(for: screen)
        let lower = description.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Offsets are computed in AppKit screen space, then converted once to the CG top-left space
        // that `moveMouse` and the overlay consume.
        let appKitPoint: CGPoint
        let label: String

        if lower.contains("center") || lower.contains("middle") {
            appKitPoint = CGPoint(x: frame.midX, y: frame.midY)
            label = "center of the screen"
        } else if lower.contains("top left") {
            appKitPoint = CGPoint(x: frame.minX + 100, y: frame.maxY - 100)
            label = "top-left of the screen"
        } else if lower.contains("top right") {
            appKitPoint = CGPoint(x: frame.maxX - 100, y: frame.maxY - 100)
            label = "top-right of the screen"
        } else if lower.contains("bottom left") {
            appKitPoint = CGPoint(x: frame.minX + 100, y: frame.minY + 100)
            label = "bottom-left of the screen"
        } else if lower.contains("bottom right") {
            appKitPoint = CGPoint(x: frame.maxX - 100, y: frame.minY + 100)
            label = "bottom-right of the screen"
        } else if lower.contains("top") {
            appKitPoint = CGPoint(x: frame.midX, y: frame.maxY - 100)
            label = "top edge of the screen"
        } else if lower.contains("bottom") {
            appKitPoint = CGPoint(x: frame.midX, y: frame.minY + 100)
            label = "bottom edge of the screen"
        } else if lower.contains("left") {
            appKitPoint = CGPoint(x: frame.minX + 100, y: frame.midY)
            label = "left edge of the screen"
        } else if lower.contains("right") {
            appKitPoint = CGPoint(x: frame.maxX - 100, y: frame.midY)
            label = "right edge of the screen"
        } else {
            appKitPoint = CGPoint(x: frame.midX, y: frame.midY)
            label = "center of the screen"
        }

        let targetPoint = space.topLeftPoint(fromAppKit: appKitPoint)
        let ok = moveMouse(to: targetPoint)
        if ok {
            ScreenGuideLaserOverlay.shared.showPointer(at: targetPoint, duration: 1.5)
            return (true, "Moved mouse to \(label) (\(Int(targetPoint.x)), \(Int(targetPoint.y))).")
        } else {
            return (false, "Could not move mouse. Check Accessibility permissions.")
        }
    }

    public static func click(at point: CGPoint, button: NativeMouseButton = .left, clicks: Int = 1) -> Bool {
        guard InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: true) else {
            return false
        }
        // Each click sleeps on the main actor; bound the loop again here so no caller can freeze the UI.
        let clicks = ToolNumericBounds.clampedClicks(clicks)
        let source = CGEventSource(stateID: .hidSystemState)
        CGWarpMouseCursorPosition(point)
        usleep(15_000)

        let downType: CGEventType
        let upType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
            cgButton = .left
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
            cgButton = .right
        case .middle:
            downType = .otherMouseDown
            upType = .otherMouseUp
            cgButton = .center
        }

        for clickIndex in 1...clicks {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
                return false
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))

            down.post(tap: .cghidEventTap)
            usleep(25_000)
            up.post(tap: .cghidEventTap)
            usleep(25_000)
        }

        ScreenGuideLaserOverlay.shared.showPointer(at: point, duration: 1.5)
        return true
    }

    public static func clickElement(description: String) async -> (succeeded: Bool, confirmation: String) {
        guard InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: true) else {
            return (false, InPlaceAppTyping.accessibilityPermissionPromptMessage)
        }
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDesc.isEmpty else {
            return (false, "No element description provided.")
        }

        do {
            let screenContext = ScreenContext()
            let capture = try await screenContext.extractVisibleScreenTextAndScreen()
            let target = clickMatchTarget(trimmedDesc)

            var bestMatch: ScreenOCRLine?
            var bestScore = 0
            for line in capture.lines {
                guard let score = clickMatchScore(line: line, target: target) else { continue }
                if score > bestScore { bestScore = score; bestMatch = line }
            }

            if let matched = bestMatch {
                // Normalized Vision boxes belong to the display that was actually
                // captured, never an unrelated NSScreen.main.
                let screen = capture.screen ?? NSScreen.main ?? NSScreen.screens.first
                let space = ScreenCoordinateSpace.current(for: screen)
                let localCenter = space.screenLocalPoint(
                    fromVisionNormalized: CGPoint(x: matched.boundingBox.midX, y: matched.boundingBox.midY)
                )
                let origin = space.screenBoundsInTopLeft.origin
                let clickPoint = CGPoint(x: origin.x + localCenter.x, y: origin.y + localCenter.y)

                // A click into an inactive window only activates it. Bring the window
                // under the point forward first, then dispatch the click.
                activateWindow(at: clickPoint)
                let ok = click(at: clickPoint, button: .left, clicks: 1)
                if ok {
                    return (true, "Clicked \"\(matched.text)\" at (\(Int(clickPoint.x)), \(Int(clickPoint.y))).")
                } else {
                    return (false, "Found \"\(matched.text)\" but failed to dispatch mouse click.")
                }
            }
        } catch {
            // Screen OCR unavailable; continue to accessibility fallback
        }

        if let axMatch = findElementViaAX(description: trimmedDesc) {
            activateWindow(at: axMatch.center)
            let ok = click(at: axMatch.center, button: .left, clicks: 1)
            if ok {
                return (true, "Clicked element \"\(axMatch.title)\" at (\(Int(axMatch.center.x)), \(Int(axMatch.center.y))).")
            }
        }

        return (false, "Could not find \"\(trimmedDesc)\" on screen. Please make sure it is visible.")
    }

    private static func clickMatchTarget(_ description: String) -> String {
        var target = description.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("click ") { target = String(target.dropFirst(6)) }
        if target.hasSuffix(" button") { target = String(target.dropLast(7)) }
        if target.hasSuffix(" link") { target = String(target.dropLast(5)) }
        return target.isEmpty ? description.lowercased() : target
    }

    /// Prefer an exact, short element label over a paragraph that merely contains the
    /// words. Returns nil for lines too long to be a single control.
    static func clickMatchScore(line: ScreenOCRLine, target: String) -> Int? {
        let text = line.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 240, !target.isEmpty else { return nil }
        let confidence = Int((max(0, min(1, line.confidence)) * 40).rounded())
        if text == target { return 10_000 + confidence }
        let targetTokens = target.split(whereSeparator: \.isWhitespace).map(String.init)
        let textTokens = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        if !targetTokens.isEmpty, targetTokens.allSatisfy({ textTokens.contains($0) }) {
            return 6_000 - min(1_500, text.count) + confidence
        }
        if text.hasPrefix(target) || text.hasSuffix(target) {
            return 5_000 - min(1_500, text.count) + confidence
        }
        if text.contains(target) {
            return 4_000 - min(1_500, text.count) + confidence
        }
        let common = targetTokens.filter { textTokens.contains($0) }.count
        guard common > 0 else { return nil }
        if targetTokens.count > 1, common < max(2, targetTokens.count / 2) { return nil }
        return 1_000 + common * 150 - min(500, text.count / 4)
    }

    /// The window under the point (front-to-back order) is activated so the click is
    /// delivered to a control, not merely used to raise its window.
    static func activateWindow(at point: CGPoint) {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha > 0,
                  let values = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
                  rect.contains(point) else { continue }
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.activate(options: [.activateAllWindows])
                usleep(140_000)
            }
            return
        }
    }

    private struct AXElementMatch {
        let title: String
        let center: CGPoint
    }

    private static func findElementViaAX(description: String) -> AXElementMatch? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowElement = windowRef as! AXUIElement? else {
            return nil
        }
        return searchAXChildren(element: windowElement, target: description.lowercased(), depth: 0)
    }

    private static func searchAXChildren(element: AXUIElement, target: String, depth: Int) -> AXElementMatch? {
        guard depth < 6 else { return nil }
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, !title.isEmpty {
            if title.lowercased().contains(target) {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
                   AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let posVal = posRef, let sizeVal = sizeRef {
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    if AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
                       AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) {
                        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                        return AXElementMatch(title: title, center: center)
                    }
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(20) {
                if let match = searchAXChildren(element: child, target: target, depth: depth + 1) {
                    return match
                }
            }
        }
        return nil
    }
}
#endif

// MARK: - System RAM Inspector & Parallel Agent Coordinator

public struct RAMMetrics: Equatable, Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let usedBytes: UInt64
    public let usageRatio: Double

    public var freeGB: Double { Double(freeBytes) / 1_073_741_824.0 }
    public var usagePercent: Double { usageRatio * 100 }
    public var totalGB: Double { Double(totalBytes) / 1_073_741_824.0 }
    public var isHighPressure: Bool { usageRatio >= 0.90 }
    public var canDeployParallelAgents: Bool { usageRatio < 0.75 && freeGB >= 4.0 }
}

public enum SystemRAMInspector {
    public static func currentRAM() -> RAMMetrics {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return RAMMetrics(totalBytes: totalBytes, freeBytes: totalBytes / 4, usedBytes: totalBytes * 3 / 4, usageRatio: 0.75)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let freePages = UInt64(vmStats.free_count) + UInt64(vmStats.inactive_count)
        let freeBytes = freePages * pageSize
        let usedBytes = totalBytes > freeBytes ? (totalBytes - freeBytes) : 0
        let ratio = totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) : 0.5
        return RAMMetrics(totalBytes: totalBytes, freeBytes: freeBytes, usedBytes: usedBytes, usageRatio: ratio)
    }

    public static func formattedReport() -> String {
        let ram = currentRAM()
        let freeStr = String(format: "%.1f", ram.freeGB)
        let totalStr = String(format: "%.1f", ram.totalGB)
        if ram.canDeployParallelAgents {
            return "RAM status: \(ram.usagePercent)% used (\(freeStr) GB free of \(totalStr) GB). Memory is healthy — parallel agent tasks can run safely under the 90% threshold."
        } else if ram.isHighPressure {
            return "RAM status: \(ram.usagePercent)% used (\(freeStr) GB free of \(totalStr) GB). High memory pressure (>90%) — parallel tasks paused and context will be archived."
        } else {
            return "RAM status: \(ram.usagePercent)% used (\(freeStr) GB free of \(totalStr) GB)."
        }
    }
}

public final class ParallelAgentCoordinator: @unchecked Sendable {
    public static let shared = ParallelAgentCoordinator()
    private let lock = NSLock()
    private var activeAgentTasks: [UUID: String] = [:]




    public func activeAgentsSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        if activeAgentTasks.isEmpty {
            return "No background parallel agents currently active."
        }
        let labels = activeAgentTasks.values.joined(separator: ", ")
        return "\(activeAgentTasks.count) parallel agent(s) active: \(labels)."
    }
}

// MARK: - Dot Soul Manager (Archive, Clean, Export & Import)

public final class DotSoulManager: @unchecked Sendable {
    public static let shared = DotSoulManager()
    private let lock = NSLock()
    /// The Soul directory keeps a bounded archive: at most this many files, or this
    /// many bytes total, oldest first — unbounded growth was the old failure mode.
    public static let maximumArchives = 20
    public static let maximumArchiveBytes = 10_000_000
    private var lastArchivedStateDigest: String?

    public var soulDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Dot/Soul")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Throws when the state cannot be archived; returns false when `onTransitionOnly`
    /// skipped writing because the state is unchanged since the last archive.
    @discardableResult
    public func archiveCurrentState(reason: String = "routine", onTransitionOnly: Bool = false) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let archiveFile = soulDirectory.appendingPathComponent("soul_archive_\(timestamp).json")

        let brain = PersistentMemoryBrain.shared
        let profile = brain.readProfile()
        let volatile = brain.readVolatile()

        let chatLogContent = (DiagnosticChatLogger.logFileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        let chatSnippet = String(chatLogContent.suffix(50_000))

        // The digest covers the archived *state*, not the archivedAt timestamp, so a
        // repeated archive of the same state can honestly be skipped on transition only.
        let stateDigest = Data((profile + "\u{0}" + volatile + "\u{0}" + chatSnippet + "\u{0}" + reason).utf8).sha256Hex
        if onTransitionOnly, stateDigest == lastArchivedStateDigest { return false }

        let payload: [String: Any] = [
            "archivedAt": formatter.string(from: now),
            "reason": reason,
            "profileMarkdown": profile,
            "volatileMarkdown": volatile,
            "chatLogSnippet": chatSnippet
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: archiveFile)
        lastArchivedStateDigest = stateDigest
        pruneArchives(directory: archiveFile.deletingLastPathComponent())
        return true
    }

    /// Keep the newest archives within the count and byte budgets; remove oldest first.
    private func pruneArchives(directory: URL) {
        func size(_ url: URL) -> Int {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
            return values.fileSize ?? 0
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var archives = contents
            .filter { $0.lastPathComponent.hasPrefix("soul_archive_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var totalBytes = archives.reduce(0) { $0 + size($1) }
        while archives.count > Self.maximumArchives || totalBytes > Self.maximumArchiveBytes,
              let oldest = archives.first {
            totalBytes -= size(oldest)
            try? FileManager.default.removeItem(at: oldest)
            archives.removeFirst()
        }
    }

    public func exportSoul() -> (url: URL?, message: String) {
        _ = try? archiveCurrentState(reason: "user_export")
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "Dot_Soul_\(fmt.string(from: now)).dotsoul"

        // A sandboxed Dot writes only inside its own container. Exports live in
        // Application Support/Dot/Exports and can be moved out through Finder.
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return (nil, "Could not locate Dot's application storage.")
        }
        let exports = support.appendingPathComponent("Dot/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let exportURL = exports.appendingPathComponent(filename)

        let brain = PersistentMemoryBrain.shared
        let profile = brain.readProfile()
        let volatile = brain.readVolatile()
        let chatLogContent = (DiagnosticChatLogger.logFileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""

        let soulExport: [String: Any] = [
            "version": 1,
            "exportDate": ISO8601DateFormatter().string(from: now),
            "profile": profile,
            "volatile": volatile,
            "chatLog": String(chatLogContent.suffix(100_000))
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: soulExport, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: exportURL)
            NSWorkspace.shared.activateFileViewerSelecting([exportURL])
            return (exportURL, "Dot's soul exported successfully to \(exportURL.path). It holds your profile and standing rules, active project notes and the latest conversation log; the five-tier memory database is not included. You can transfer this file to any Mac and import it.")
        } catch {
            return (nil, "Failed to export Dot's soul: \(error.localizedDescription)")
        }
    }

    public func importLatestSoulFromDownloads() -> (success: Bool, message: String) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return (false, "Could not locate Dot's application storage.")
        }
        let downloads = support.appendingPathComponent("Dot/Exports", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey]),
              let latest = files.filter({ $0.pathExtension == "dotsoul" || $0.lastPathComponent.hasPrefix("Dot_Soul_") || $0.lastPathComponent.hasPrefix("DotSoul") })
                .sorted(by: {
                    let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    return d1 > d2
                }).first else {
            return (false, "No .dotsoul backup file found in Application Support/Dot/Exports.")
        }
        return importSoul(from: latest)
    }

    public func importSoul(from url: URL) -> (success: Bool, message: String) {
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (false, "Invalid .dotsoul archive format.")
            }
            if let profile = obj["profile"] as? String, !profile.isEmpty {
                PersistentMemoryBrain.shared.writeProfile(profile)
            }
            if let volatile = obj["volatile"] as? String, !volatile.isEmpty {
                PersistentMemoryBrain.shared.writeVolatile(volatile)
            }
            return (true, "Successfully imported Dot's soul from \(url.lastPathComponent)! Profile preferences, learned rules, and session memory are restored.")
        } catch {
            return (false, "Failed to import soul: \(error.localizedDescription)")
        }
    }

    public func cleanContextIfMemoryPressure(force: Bool = false) -> Bool {
        let ram = SystemRAMInspector.currentRAM()
        guard ram.usageRatio >= 0.88 || force else { return false }
        do {
            _ = try archiveCurrentState(reason: "ram_pressure_cleanup", onTransitionOnly: true)
            return true
        } catch {
            // The archive write failed; claiming the cleanup ran would be a lie.
            DiagnosticChatLogger.record(role: "system", text: "Memory-pressure soul archive failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Native Screen Scroll Engine (CoreGraphics Event Synthesis)

public enum ScrollDirection: String, Codable, Sendable {
    case up, down, left, right, top, bottom, pageUp, pageDown
}

public enum ScrollCommand: Equatable {
    case scroll(direction: ScrollDirection, amount: Int)
    case none
}

public enum ScrollControlEngine {
    public static func parseCommand(_ text: String) -> ScrollCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let clean = trimConversationalPunctuation(trimmed)

        let s = stripConversationalPrefixes(clean, prefixes: [
            "can you please ", "could you please ", "please ", "can you ", "could you ", "dot "
        ])

        if s == "scroll down" || s == "scroll down a bit" || s == "scroll down a little" || s == "scroll" || s == "прокрути вниз" {
            return .scroll(direction: .down, amount: 6)
        }
        if s == "scroll up" || s == "scroll up a bit" || s == "scroll up a little" || s == "прокрути вверх" {
            return .scroll(direction: .up, amount: 6)
        }
        if s == "scroll down more" || s == "scroll down a lot" || s == "scroll down fast" {
            return .scroll(direction: .down, amount: 16)
        }
        if s == "scroll up more" || s == "scroll up a lot" || s == "scroll up fast" {
            return .scroll(direction: .up, amount: 16)
        }
        if s == "scroll to top" || s == "scroll to the top" || s == "scroll all the way up" || s == "go to top" || s == "в самый верх" {
            return .scroll(direction: .top, amount: 0)
        }
        if s == "scroll to bottom" || s == "scroll to the bottom" || s == "scroll all the way down" || s == "go to bottom" || s == "в самый низ" {
            return .scroll(direction: .bottom, amount: 0)
        }
        if s == "page down" || s == "next page" {
            return .scroll(direction: .pageDown, amount: 0)
        }
        if s == "page up" || s == "previous page" {
            return .scroll(direction: .pageUp, amount: 0)
        }
        if s == "scroll left" {
            return .scroll(direction: .left, amount: 6)
        }
        if s == "scroll right" {
            return .scroll(direction: .right, amount: 6)
        }
        return .none
    }

    @discardableResult
    @MainActor
    public static func scroll(direction: ScrollDirection, amount: Int = 6) -> Bool {
        guard InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: true) else { return false }
        // Bounded again at the engine entry point: `Int32(-max(1, amount))` traps above Int32.max.
        switch direction {
        case .down:
            let delta = ToolNumericBounds.scrollDelta(amount: amount, inverted: true)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        case .up:
            let delta = ToolNumericBounds.scrollDelta(amount: amount, inverted: false)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        case .left:
            let delta = ToolNumericBounds.scrollDelta(amount: amount, inverted: false)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        case .right:
            let delta = ToolNumericBounds.scrollDelta(amount: amount, inverted: true)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0) else { return false }
            event.post(tap: .cghidEventTap)
            return true
        case .top:
            return InPlaceAppTyping.performPressKey("Cmd+Up", checkPermission: false).succeeded
        case .bottom:
            return InPlaceAppTyping.performPressKey("Cmd+Down", checkPermission: false).succeeded
        case .pageDown:
            return InPlaceAppTyping.performPressKey("PageDown", checkPermission: false).succeeded
        case .pageUp:
            return InPlaceAppTyping.performPressKey("PageUp", checkPermission: false).succeeded
        }
    }
}

// MARK: - Whole-Document & Active Webpage Reader (DOM Text Extraction)

/// Typed outcome of reading the active document/webpage: a permission problem and
/// "no readable text" are distinct, so a caller never presents either as a
/// successful empty read.
public enum ActiveTextExtraction: Equatable, Sendable {
    case text(source: String, content: String)
    case permissionDenied
    case noText
}

public final class WholeContextExtractor: @unchecked Sendable {
    public static let shared = WholeContextExtractor()

    public func extractActiveDocumentOrWebpageText() -> ActiveTextExtraction {
        // A typed "read this page" brings Dot's own panel to the front first; read
        // the app the owner was using before, not Dot.
        var frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier,
           let previous = InPlaceAppTyping.lastExternalApplication() {
            frontApp = previous
        }
        let appName = (frontApp?.localizedName ?? "").lowercased()

        if appName.contains("safari") {
            let script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    set curTab to current tab of front window
                    set pageURL to URL of curTab
                    set pageTitle to name of curTab
                    set pageText to text of curTab
                    return pageTitle & "|||" & pageURL & "|||" & pageText
                end if
            end tell
            """
            let result = runAppleScript(script)
            if result.permissionDenied { return .permissionDenied }
            if let output = result.output, !output.isEmpty {
                let parts = output.components(separatedBy: "|||")
                if parts.count >= 3 {
                    let title = parts[0]
                    let url = parts[1]
                    let body = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let truncated = String(body.prefix(6000))
                    if !truncated.isEmpty {
                        return .text(source: "Safari Webpage [\(title)] (\(url))", content: truncated)
                    }
                }
            }
        }

        if appName.contains("chrome") {
            let script = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    set curTab to active tab of front window
                    set pageURL to URL of curTab
                    set pageTitle to title of curTab
                    set pageText to execute curTab javascript "document.body.innerText"
                    return pageTitle & "|||" & pageURL & "|||" & pageText
                end if
            end tell
            """
            let result = runAppleScript(script)
            if result.permissionDenied { return .permissionDenied }
            if let output = result.output, !output.isEmpty {
                let parts = output.components(separatedBy: "|||")
                if parts.count >= 3 {
                    let title = parts[0]
                    let url = parts[1]
                    let body = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let truncated = String(body.prefix(6000))
                    if !truncated.isEmpty {
                        return .text(source: "Chrome Webpage [\(title)] (\(url))", content: truncated)
                    }
                }
            }
        }

        if appName.contains("textedit") {
            let script = """
            tell application "TextEdit"
                if (count of documents) > 0 then
                    set docName to name of front document
                    set docText to text of front document
                    return docName & "|||" & docText
                end if
            end tell
            """
            let result = runAppleScript(script)
            if result.permissionDenied { return .permissionDenied }
            if let output = result.output, !output.isEmpty {
                let parts = output.components(separatedBy: "|||")
                if parts.count >= 2 {
                    let docName = parts[0]
                    let docText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let truncated = String(docText.prefix(6000))
                    if !truncated.isEmpty {
                        return .text(source: "TextEdit Document [\(docName)]", content: truncated)
                    }
                }
            }
        }

        // 3. Inspect active document URL via Accessibility (kAXDocumentAttribute).
        // An untrusted Accessibility session is a permission problem, not an empty read.
        guard InPlaceAppTyping.isAccessibilityTrusted(promptIfNeeded: false) else { return .permissionDenied }
        if let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let win = winRef as! AXUIElement? {
                var docRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &docRef) == .success,
                   let docURLStr = docRef as? String,
                   let docURL = URL(string: docURLStr), docURL.isFileURL {
                    let ext = docURL.pathExtension.lowercased()
                    let readableExts: Set<String> = [
                        "txt", "md", "swift", "py", "js", "ts", "json", "csv", "html", "sh", "yml", "yaml", "xml", "rs", "c", "h", "cpp"
                    ]
                    if readableExts.contains(ext), let text = try? String(contentsOf: docURL, encoding: .utf8), !text.isEmpty {
                        let truncated = String(text.prefix(6000))
                        return .text(source: "Active File [\(docURL.lastPathComponent)]", content: truncated)
                    }
                }
            }
        }

        return .noText
    }

    /// Returns the AppleScript output plus whether Automation permission was refused
    /// (error -1743 = errAEEventNotPermitted), so the refusal surfaces honestly
    /// instead of looking like an empty document.
    private func runAppleScript(_ source: String) -> (output: String?, permissionDenied: Bool) {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: source) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil {
                return (output.stringValue, false)
            }
            if let number = error?[NSAppleScript.errorNumber] as? Int, number == -1743 {
                return (nil, true)
            }
            // Chrome refuses page JavaScript until View > Developer > Allow JavaScript
            // from Apple Events is on: a permission to grant, not "no text".
            if let message = error?[NSAppleScript.errorMessage] as? String,
               message.localizedCaseInsensitiveContains("javascript") {
                return (nil, true)
            }
        }
        return (nil, false)
    }
}

// MARK: - Previous-Screen Memory Buffer ("Just-Left Page" Memory)

public struct PastScreenContext: Sendable {
    public let timestamp: Date
    public let appName: String
    public let windowTitle: String
    public let ocrTextSummary: String
}

public final class PreviousScreenMemory: @unchecked Sendable {
    public static let shared = PreviousScreenMemory()
    private let lock = NSLock()
    private var buffer: [PastScreenContext] = []

    public func recordScreen(appName: String, windowTitle: String, ocrText: String) {
        lock.lock()
        defer { lock.unlock() }
        let summary = String(ocrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
        guard !summary.isEmpty else { return }
        if let last = buffer.last, last.appName == appName && last.windowTitle == windowTitle && last.ocrTextSummary == summary {
            return
        }
        buffer.append(PastScreenContext(
            timestamp: Date(),
            appName: appName,
            windowTitle: windowTitle,
            ocrTextSummary: summary
        ))
        if buffer.count > 6 {
            buffer.removeFirst()
        }
    }

    public func recallRecentScreens() -> [PastScreenContext] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func formatPromptSnippet() -> String? {
        let screens = recallRecentScreens()
        guard screens.count > 1 else { return nil }
        let past = screens.dropLast().suffix(2)
        guard !past.isEmpty else { return nil }
        var parts: [String] = []
        for p in past {
            parts.append("\(p.appName) (\"\(p.windowTitle)\"): \(p.ocrTextSummary.prefix(350))")
        }
        return "Previously Viewed Screens: " + parts.joined(separator: " ; ")
    }
}

// MARK: - System Audio State & Volume Control

public enum SystemAudioState {
    public static func isOutputMuted() -> Bool {
        var error: NSDictionary?
        if let script = NSAppleScript(source: "output muted of (get volume settings)") {
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return result.booleanValue
            }
        }
        return false
    }

    public static func setMuted(_ muted: Bool) -> Bool {
        let scriptSource = muted ? "set volume with output muted" : "set volume without output muted"
        var error: NSDictionary?
        if let script = NSAppleScript(source: scriptSource) {
            script.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    public static func currentVolume() -> Int {
        var error: NSDictionary?
        if let script = NSAppleScript(source: "output volume of (get volume settings)") {
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return Int(result.int32Value)
            }
        }
        return 50
    }

    public static func setVolume(_ percent: Int) -> Bool {
        let bounded = max(0, min(100, percent))
        var error: NSDictionary?
        if let script = NSAppleScript(source: "set volume output volume \(bounded)") {
            script.executeAndReturnError(&error)
            return error == nil
        }
        return false
    }

    public static func adjustVolume(by delta: Int) -> Int {
        let current = currentVolume()
        let newVol = max(0, min(100, current + delta))
        _ = setVolume(newVol)
        return newVol
    }
}

// MARK: - Background Media & Audio Ducking

public final class SystemAudioDucker: @unchecked Sendable {
    public static let shared = SystemAudioDucker()
    private var pausedMusic = false
    private var pausedSpotify = false
    private let lock = NSLock()

    private init() {}

    public func duckIfPlaying() {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(AppKit)
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { $0.bundleIdentifier == "com.apple.Music" }), Self.pauseIfPlaying("Music") {
            pausedMusic = true
        }
        if apps.contains(where: { $0.bundleIdentifier == "com.spotify.client" }), Self.pauseIfPlaying("Spotify") {
            pausedSpotify = true
        }
        #endif
    }

    #if canImport(AppKit)
    /// Pauses `app` only while it plays and reports whether it did. A paused
    /// player is left alone, so the restore never starts music the owner stopped.
    private static func pauseIfPlaying(_ app: String) -> Bool {
        let source = "tell application \"\(app)\"\nif player state is playing then\npause\nreturn true\nend if\nreturn false\nend tell"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }
    #endif

    public func restoreIfDucked() {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(AppKit)
        if pausedMusic {
            var error: NSDictionary?
            if let script = NSAppleScript(source: "tell application \"Music\" to play") {
                script.executeAndReturnError(&error)
            }
            pausedMusic = false
        }
        if pausedSpotify {
            var error: NSDictionary?
            if let script = NSAppleScript(source: "tell application \"Spotify\" to play") {
                script.executeAndReturnError(&error)
            }
            pausedSpotify = false
        }
        #endif
    }
}

// MARK: - User Spatial Scribble / Circle-to-Ask Gesture

public final class ScreenScribbleTracker: @unchecked Sendable {
    public static let shared = ScreenScribbleTracker()
    private var flagsMonitor: Any?
    private var mouseMonitor: Any?
    private var isTracking = false
    private var points: [CGPoint] = []
    private var onCircleCompleted: (@MainActor (CGRect) -> Void)?

    public func startMonitoring(onCircleCompleted: @escaping @MainActor (CGRect) -> Void) {
        self.onCircleCompleted = onCircleCompleted
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isCtrlOpt = event.modifierFlags.contains([.control, .option])
            if isCtrlOpt && !(self?.isTracking ?? false) {
                self?.isTracking = true
                self?.points = [NSEvent.mouseLocation]
            } else if !isCtrlOpt && (self?.isTracking ?? false) {
                self?.finishTracking()
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self, self.isTracking else { return }
            self.points.append(NSEvent.mouseLocation)
            if self.points.count > 1, let minX = self.points.map(\.x).min(),
               let maxX = self.points.map(\.x).max(),
               let minY = self.points.map(\.y).min(),
               let maxY = self.points.map(\.y).max(),
               (maxX - minX) > 30, (maxY - minY) > 30 {
                let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                Task { @MainActor in
                    // `NSEvent.mouseLocation` is AppKit bottom-left; the overlay takes CG top-left.
                    let space = ScreenCoordinateSpace.current()
                    ScreenGuideLaserOverlay.shared.highlightRect(space.topLeftRect(fromAppKit: rect), duration: 0.6)
                }
            }
        }
    }

    public func stopMonitoring() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        flagsMonitor = nil
        mouseMonitor = nil
        isTracking = false
        points.removeAll()
    }

    private func finishTracking() {
        isTracking = false
        guard points.count >= 4,
              let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else {
            points.removeAll()
            return
        }
        let width = maxX - minX
        let height = maxY - minY
        points.removeAll()
        guard width >= 40 && height >= 40 else { return }
        let box = CGRect(x: minX, y: minY, width: width, height: height)
        Task { @MainActor [weak self] in
            // `box` stays in AppKit coordinates: it is hit-tested against `NSEvent.mouseLocation`
            // and handed to callers that only read its size.
            let space = ScreenCoordinateSpace.current()
            ScreenGuideLaserOverlay.shared.highlightRect(space.topLeftRect(fromAppKit: box), duration: 3.0)
            self?.onCircleCompleted?(box)
        }
    }
}

// MARK: - Diagnostic Chat Logger

public enum DiagnosticChatLogger {
    private static let lock = NSLock()
    static let fileName = "dot_chat_log.txt"
    private static let rotatedFileName = "dot_chat_log.1.txt"
    private static let rotationBytes = 2_000_000
    /// One shared path constant: the reflections log always lives next to the chat
    /// log (Application Support/Dot/Logs; a temp directory under tests), never in
    /// Downloads, and rotates by size the same way.
    static let reflectionsFileName = "dot_self_reflections.txt"
    static let rotatedReflectionsFileName = "dot_self_reflections.1.txt"
    /// Never write fixture conversations into the owner's real log: the
    /// self-reflection reads that file, so a test suite would otherwise feed it
    /// synthetic turns. The test bundle gets a temporary file instead.
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    static func resolvedLogURL(testProcess: Bool, persistent: URL?, temporary: URL) -> URL? {
        (testProcess ? temporary : persistent)?.appendingPathComponent(fileName)
    }
    private static let logURL: URL? = {
        let persistent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dot", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        return resolvedLogURL(testProcess: isRunningTests, persistent: persistent,
                              temporary: FileManager.default.temporaryDirectory)
    }()
    /// The one path the reflection reads. Not Downloads: a notarised/sandboxed
    /// build loses write access there and observability dies silently.
    static var logFileURL: URL? { logURL }
    /// The reflections log beside the given chat log (defaulting to the shared
    /// Application Support/Dot/Logs path), so both observability files live under
    /// one directory and one constant.
    static func reflectionsFileURL(for logURL: URL? = nil) -> URL? {
        (logURL ?? self.logURL)?.deletingLastPathComponent().appendingPathComponent(reflectionsFileName)
    }
    /// Shared size rotation: once `url` exceeds `maxBytes`, move it to `rotatedName`.
    /// Used by the chat log and the reflections log alike.
    static func rotateIfOversized(_ url: URL, rotatedName: String, maxBytes: Int = rotationBytes) {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > maxBytes else { return }
        let rotated = url.deletingLastPathComponent().appendingPathComponent(rotatedName)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Create the private log directory, migrate the old Downloads log once, and
    /// rotate by size. Called under the writer lock.
    private static func prepare(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if !isRunningTests, !FileManager.default.fileExists(atPath: url.path),
           let old = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
               .appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: old.path) {
            // Preserve the owner's existing history; if the move fails, start fresh.
            try? FileManager.default.moveItem(at: old, to: url)
        }
        rotateIfOversized(url, rotatedName: rotatedFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public static func record(role: String, text: String) {
        guard let url = logURL else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(role.uppercased())] \(LogRedaction.capped(LogRedaction.masked(trimmed)))\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        prepare(url)

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            let header = "# Dot Conversation Diagnostic Log\n# Created: \(timestamp)\n# Records user prompts, assistant actions and turn errors for local debugging. Rotates at \(rotationBytes) bytes.\n\n"
            var combined = header.data(using: .utf8) ?? Data()
            combined.append(data)
            try? combined.write(to: url, options: .atomic)
        }
    }

    public static func recordFailure(task: String, reason: String, missingCapability: String, proposedFix: String) {
        let msg = "TASK: \"\(task)\" | REASON: \(reason) | MISSING: \(missingCapability) | PROPOSED_FIX: \(proposedFix)"
        record(role: "dot (self-improvement)", text: msg)
    }

    /// S3: command output, files, pages and calendar listings are not conversation, so
    /// the public log keeps their first line (at most 200 characters) and their size.
    public static func loggableToolOutput(_ output: String) -> String {
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let shown = first.count > 200 ? String(first.prefix(200)) + "…" : first
        guard shown != output else { return output }
        return "\(shown) [\(output.count) characters in all, the rest not logged]"
    }

    /// The text of a dropped file is not the owner's words: only its name and size are logged.
    public static func loggableDroppedFileText(_ text: String) -> String? {
        guard text.hasPrefix("I dropped the ") else { return nil }
        // The earliest marker ends the header, so file text that repeats a marker stays out.
        let markers = ["'. Here are its contents:\n\n", "'. Here is the text extracted from it:\n\n"]
        guard let range = markers.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        var body = text[range.upperBound...]
        for request in ["\n\nPlease briefly inspect and summarize this file.", "\n\nPlease briefly summarize this PDF."]
        where body.hasSuffix(request) { body = body.dropLast(request.count) }
        return "\(text[..<range.lowerBound])'. [\(body.count) characters of its text, not logged]"
    }

    public static func recordTool(name: String, target: String, outcome: String, succeeded: Bool) {
        let status = succeeded ? "SUCCESS" : "FAILED"
        let msg = "TOOL: \(name) | TARGET: \"\(target)\" | OUTCOME: \(outcome) | STATUS: \(status)"
        record(role: "tool", text: msg)
    }

    public static func recordScreen(app: String, ocrLineCount: Int, durationMs: Double) {
        let msg = "ACTIVE_APP: \"\(app)\" | OCR_LINES: \(ocrLineCount) | LATENCY: \(String(format: "%.1f", durationMs))ms"
        record(role: "screen", text: msg)
    }


    public static func recordEvent(category: String, message: String) {
        record(role: category.lowercased(), text: message)
    }
}

// MARK: - Action Approval Request (Milestone 2)

public struct CalendarDraft: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable { case create, edit }
    public let action: Action
    public let eventID: String?
    public let title: String
    public let startDate: Date
    public let durationMinutes: Int
    public init(action: Action, eventID: String? = nil, title: String, startDate: Date, durationMinutes: Int) {
        self.action = action; self.eventID = eventID; self.title = title
        self.startDate = startDate; self.durationMinutes = durationMinutes
    }
}

public struct AppActionDraft: Equatable, Sendable {
    public let app: String
    public let action: String
    public init(app: String, action: String) { self.app = app; self.action = action }
}

/// R15: owner-managed app names whose contextual actions skip the card. Empty by
/// default, so every app action is confirmed until the owner trusts an app.
public struct TrustedAppStore {
    public static let defaultsKey = "dot.trustedAppNames"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var names: Set<String> { Set(defaults.stringArray(forKey: Self.defaultsKey) ?? []) }
    public func isTrusted(_ app: String) -> Bool {
        names.contains(Self.normalized(app))
    }
    public func trust(_ app: String) {
        let name = Self.normalized(app)
        guard !name.isEmpty else { return }
        var updated = names; updated.insert(name)
        defaults.set(updated.sorted(), forKey: Self.defaultsKey)
    }
    public func untrust(_ app: String) {
        var updated = names; updated.remove(Self.normalized(app))
        defaults.set(updated.sorted(), forKey: Self.defaultsKey)
    }
    public func removeAll() { defaults.removeObject(forKey: Self.defaultsKey) }
    private static func normalized(_ app: String) -> String {
        app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// R7: file operations are automatic. Only a simple command made entirely of file
/// utilities (optionally chained with ;, &&, || or a pipe) qualifies; shells,
/// wrappers, substitutions, `/dev` and `/System` targets, and every other
/// executable still keep the per-command card.
public enum FileOperationPolicy {
    private static let utilities: Set<String> = [
        "rm", "rmdir", "mv", "cp", "touch", "mkdir", "ln", "unlink", "trash",
        "echo", "printf", "cat", "tee", "truncate"
    ]
    private static let wrappers: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "sudo", "doas",
        "env", "xargs", "osascript", "python", "python3", "perl", "ruby", "node"
    ]

    public static func isAutomaticFileOperation(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else { return false }
        // `=(…)` is zsh process substitution and `*(e:…:)` a glob qualifier: both run code.
        guard !trimmed.contains("`"), !trimmed.contains("$("), !trimmed.contains("<("), !trimmed.contains(">("),
              !trimmed.contains("=("), !trimmed.contains("(e:"), !trimmed.contains("(+"),
              !trimmed.contains("${") else { return false }
        let segments = commandSegments(trimmed)
        guard !segments.isEmpty else { return false }
        for raw in segments {
            let tokens = tokenize(raw)
            guard let executable = tokens.first, let name = systemCommandName(executable) else { return false }
            guard !wrappers.contains(name) else { return false }
            if tokens.contains(where: { $0 == "/dev" || $0.hasPrefix("/dev/") || $0.hasPrefix("/System/") }) {
                return false
            }
            if name == "find" {
                // Deletion is a file operation; -exec/-ok re-introduce arbitrary commands.
                guard raw.contains("-delete"), !raw.contains("-exec"), !raw.contains("-ok") else { return false }
                continue
            }
            guard utilities.contains(name) else { return false }
        }
        return true
    }

    /// Every command in a line: `&&`, `||`, `;`, `|`, a single `&` (background) and a newline
    /// each start a new one, so `echo x & sudo reboot` is two commands. A backslash line
    /// continuation joins its lines first.
    static func commandSegments(_ command: String) -> [String] {
        command.replacingOccurrences(of: "\\\n", with: " ")
            // `2>&1` and `&>` are redirects, not a background `&`.
            .replacingOccurrences(of: ">&", with: ">")
            .replacingOccurrences(of: "&>", with: ">")
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .replacingOccurrences(of: "|", with: "\n")
            .replacingOccurrences(of: "&", with: "\n")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Commands that only read and run with no approver. Every other command that does not
    /// need the card goes to the safety approver first, so no shell command runs unchecked.
    /// Tools that can write through a flag (`sort -o`, `uniq in out`, `rg --pre`, `find`)
    /// are left out on purpose.
    private static let readOnlyExecutables: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "pwd", "date", "cal",
        "which", "file", "stat", "du", "df", "uname", "sw_vers", "whoami", "uptime", "ps",
        "mdfind", "mdls", "cut", "tr", "diff", "cmp", "shasum", "md5", "basename", "dirname",
        "realpath", "echo", "printf"
    ]
    /// `diff`, `show` and `blame` are left out: a repository's config can run an external diff
    /// or text filter for them.
    private static let readOnlyGitSubcommands: Set<String> = ["status", "log", "rev-parse", "describe", "ls-files"]

    /// The command name of a bare word (`ls`) or of a path in a system folder (`/bin/ls`).
    /// `./cat` or `~/Downloads/ls` could be anything, so they get no name and no shortcut.
    static func systemCommandName(_ token: String) -> String? {
        guard token.contains("/") else { return token }
        let folder = (token as NSString).deletingLastPathComponent
        guard ["/bin", "/usr/bin", "/sbin", "/usr/sbin"].contains(folder) else { return nil }
        return (token as NSString).lastPathComponent
    }

    public static func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else { return false }
        guard !trimmed.contains("`"), !trimmed.contains("$("), !trimmed.contains("<("),
              !trimmed.contains(">"), !trimmed.contains("("), !trimmed.contains(")"),
              !trimmed.contains("${") else { return false }
        let segments = commandSegments(trimmed)
        guard !segments.isEmpty else { return false }
        for raw in segments {
            let tokens = tokenize(raw)
            guard let executable = tokens.first, let name = systemCommandName(executable) else { return false }
            if name == "git" {
                // The subcommand must come right after `git` (or `git --no-pager`): the values
                // of `-C`, `-c` or `--git-dir` must never be read as one.
                var rest = tokens.dropFirst()
                if rest.first == "--no-pager" { rest = rest.dropFirst() }
                // `-p`, `--patch` and `-u` run a repository's diff filters, like `git diff`.
                guard let subcommand = rest.first, readOnlyGitSubcommands.contains(subcommand),
                      !tokens.contains(where: { $0 == "-p" || $0 == "-u" || $0.hasPrefix("--patch") }),
                      !tokens.contains(where: { $0.hasPrefix("--output") || $0 == "--ext-diff" }) else { return false }
                continue
            }
            guard readOnlyExecutables.contains(name) else { return false }
        }
        return true
    }

    /// Minimal quote-aware splitter; enough to identify the executable and reject
    /// path targets without pretending to be a shell parser.
    static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in segment {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

public struct ActionApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let target: String
    public let isDestructive: Bool
    public let command: String
    /// A calendar action is confirmed on the card and executed by the approval
    /// branch, never by the shell-command branches below it.
    public let calendarDraft: CalendarDraft?
    /// R15: a contextual app action awaiting confirmation for an untrusted app.
    public let appAction: AppActionDraft?

    public init(id: UUID = UUID(), title: String, detail: String, target: String, isDestructive: Bool, command: String,
                calendarDraft: CalendarDraft? = nil, appAction: AppActionDraft? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.target = target
        self.isDestructive = isDestructive
        self.command = command
        self.calendarDraft = calendarDraft
        self.appAction = appAction
    }

    /// The longest command an approval card shows; it is shown in full, so a longer one is
    /// refused instead of being offered with a hidden tail.
    public static let maximumShownCommand = 56

    /// Executables whose invocation can destroy data or take over the machine. Matching is by
    /// token basename, so `/bin/rm`, `env rm`, `rm` after any separator and quoted forms all match.
    private static let destructiveExecutables: Set<String> = [
        "rm", "rmdir", "srm", "dd", "mkfs", "fdisk", "diskutil", "kill", "killall", "pkill",
        "sudo", "chmod", "chown", "mv", "trash", "shutdown"
    ]
    /// Shells and executors that re-introduce a hidden command in a later token.
    /// Interpreters belong here too: `python3 -c '…shutil.rmtree…'` and
    /// `osascript -e '…delete…'` are not file utilities and must keep the card.
    private static let wrapperExecutables: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "xargs",
        "env", "doas", "osascript", "python", "python3", "perl", "ruby", "node", "php"
    ]
    /// Tools that can send data off the Mac, read secrets, start other apps or change system
    /// settings. They always keep the card, like the destructive ones.
    private static let approvalExecutables: Set<String> = [
        "nc", "ncat", "netcat", "ssh", "scp", "sftp", "ftp", "telnet", "security", "open",
        "launchctl", "screencapture", "tccutil", "crontab", "networksetup", "systemsetup", "scutil"
    ]
    /// Flags that delete, or execute a command per file, inside another command.
    private static let wrapperFlags: Set<String> = ["-exec", "-execdir", "-delete", "-ok", "-okdir"]
    /// Programs that rewrite or unpack files as their normal job (R16: every file
    /// mutation Dot chooses is checked). `sed` and `curl` count only with an
    /// in-place or output flag, so reading with them stays free.
    private static let fileWritingExecutables: Set<String> = [
        "rsync", "ditto", "unzip", "tar", "sqlite3", "wget", "patch", "shred"
    ]
    /// Characters that start a new command in POSIX shell syntax. The backtick and `$`
    /// open command substitutions, so `` `rm -rf ~/Documents` `` and `$(sudo reboot)`
    /// tokenize to their inner destructive commands instead of hiding them inside one token.
    private static let commandSeparators: Set<Character> = [";", "&", "|", "(", ")", "\"", "'", "`", "$"]

    /// Evaluates whether a shell command or action is potentially destructive and requires approval.
    /// Tokenizing (not substring matching) is what stops `/bin/rm -rf ~/Documents`, `sh -c "rm …"`,
    /// `find . -delete`, `echo x > ~/.zshrc` and `curl https://x/i.sh | zsh` from executing silently.
    public static func isPotentiallyDestructive(_ command: String) -> Bool {
        let tokens = shellTokens(in: command)
        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            if wrapperFlags.contains(lower) { return true }
            let name = basename(lower)
            if destructiveExecutables.contains(name) || fileWritingExecutables.contains(name) { return true }
            if isCommandPosition(tokens, index: index), approvalExecutables.contains(name) { return true }
            let later = tokens[(index + 1)...].map { $0.lowercased() }
            if name == "defaults", later.contains(where: { ["write", "delete", "import", "export", "rename"].contains($0) }) { return true }
            // Only curl's own options count: `curl -s url | grep -c x` must not need the card.
            if name == "curl", curlArguments(tokens[(index + 1)...]).contains(where: curlOptionSendsOrWrites) { return true }
            if name == "sed", later.contains(where: { $0.hasPrefix("-i") || $0.hasPrefix("--in-place") }) { return true }
            // A shell or executor only counts as a wrapper in command position (start of the
            // command or right after a separator such as `|`), so `echo zsh` stays harmless.
            if isCommandPosition(tokens, index: index), wrapperExecutables.contains(name) { return true }
        }
        if hasDestructiveGitInvocation(tokens) { return true }
        // A redirect rewrites a file even when no listed executable is involved.
        return hasUnquotedRedirect(command)
    }

    /// Reading with curl stays free; sending data off the Mac or writing a file does not.
    /// curl accepts any unambiguous start of a long option (`--jso`), so a word counts when it
    /// starts one of these or one of these starts it. Short flags are case-sensitive: `-F` and
    /// `-T` upload, `-f` only fails quietly.
    private static let curlSendingOrWritingOptions = [
        "--data", "--form", "--upload-file", "--json", "--dump-header", "--cookie-jar", "--trace",
        "--stderr", "--libcurl", "--etag-save", "--hsts", "--alt-svc", "--output", "--remote-name",
        "--create-dirs"
    ]
    /// The words of one curl command: the tokens after `curl` up to the next `;`, `&` or `|`
    /// outside quotes. A quoted URL such as "https://x/?a=1&b=2" does not end the command.
    private static func curlArguments(_ tokens: ArraySlice<String>) -> [String] {
        var words: [String] = []
        var quote: String?
        for token in tokens {
            if token == "\"" || token == "'" {
                if quote == nil { quote = token } else if quote == token { quote = nil }
                continue
            }
            if quote == nil, token.count <= 2, token.allSatisfy({ ";&|".contains($0) }) { break }
            words.append(token)
        }
        return words
    }

    private static func curlOptionSendsOrWrites(_ word: String) -> Bool {
        if word.hasPrefix("--") {
            let option = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            // A full read-only name is itself, not the start of a longer option.
            guard option.count > 3, option != "--cookie" else { return false }
            return curlSendingOrWritingOptions.contains { $0.hasPrefix(option) || option.hasPrefix($0) }
        }
        return word.hasPrefix("-") && word.count > 1 && word.dropFirst().contains(where: { "dFTDcoO".contains($0) })
    }

    /// Splits on whitespace and shell metacharacters, keeping the metacharacters as their own
    /// tokens so command position stays observable.
    private static func shellTokens(in command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var escaped = false
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for character in command {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character.isWhitespace || commandSeparators.contains(character) {
                flush()
                if commandSeparators.contains(character) { tokens.append(String(character)) }
                continue
            }
            current.append(character)
        }
        flush()
        return tokens
    }

    /// `/bin/rm` and `/usr/bin/sudo` must be judged by their executable name, not their path.
    private static func basename(_ token: String) -> String {
        let parts = token.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? token
    }

    /// Launchers that run the next non-option word, plus leading assignments.
    private static let launcherExecutables: Set<String> = [
        "env", "sudo", "doas", "nohup", "command", "builtin", "exec", "time",
        "nice", "setsid", "xcrun", "arch", "!"
    ]

    private static func isCommandPosition(_ tokens: [String], index: Int) -> Bool {
        guard index > 0 else { return true }
        // Walk back to the start of this command segment, then skip leading
        // `NAME=value` assignments. This makes `FOO=1 python3 -c …` and
        // `nohup env python3 -c …` count as executors without treating
        // `echo env python3` as a command.
        var start = index
        while start > 0 {
            let previous = tokens[start - 1]
            if previous.count == 1, commandSeparators.contains(Character(previous)) { break }
            start -= 1
        }
        var cursor = start
        while cursor < index, isAssignment(tokens[cursor]) { cursor += 1 }
        guard cursor < index else { return true }
        let first = basename(tokens[cursor].lowercased())
        guard launcherExecutables.contains(first) else { return cursor == index }
        cursor += 1
        var skipNext = false
        while cursor < index {
            let token = tokens[cursor].lowercased()
            if skipNext { skipNext = false; cursor += 1; continue }
            if token.hasPrefix("-") {
                // `env -u NAME`, `env -C DIR`, `env -S STRING` take an argument.
                if first == "env", ["-u", "--unset", "-c", "--chdir", "-s", "--split-string"].contains(token) {
                    skipNext = true
                }
                cursor += 1; continue
            }
            if isAssignment(token) { cursor += 1; continue }
            // `nice -n 5`, `time -p`, `xcrun --sdk macosx` take non-option words
            // before the command; skip those for their known launchers.
            if ["nice", "time", "xcrun", "arch"].contains(first) { cursor += 1; continue }
            break
        }
        return cursor == index
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// `git reset`, `git clean`, `git checkout -f` and `git push --force` discard committed or
    /// uncommitted work even though `git` itself is harmless. Options that take an argument
    /// (`-C`, `--git-dir`, `--work-tree`, `-c`) never name the subcommand, so their argument is
    /// skipped and every remaining word is scanned: `git -C /tmp/repo reset --hard` must match.
    private static func hasDestructiveGitInvocation(_ tokens: [String]) -> Bool {
        let words = tokens.map { $0.lowercased() }
        guard let gitIndex = words.firstIndex(where: { basename($0) == "git" }) else { return false }
        let rest = Array(words[(gitIndex + 1)...])
        let optionArguments: Set<String> = ["-c", "-C", "--git-dir", "--work-tree"]
        var skipNext = false
        var commandWords: [String] = []
        for word in rest {
            if skipNext { skipNext = false; continue }
            if optionArguments.contains(word) { skipNext = true; continue }
            commandWords.append(word)
        }
        let flags = Set(commandWords.filter { $0.hasPrefix("-") })
        for word in commandWords where !word.hasPrefix("-") {
            switch basename(word) {
            case "reset", "clean":
                return true
            case "restore", "rm":
                return true
            case "checkout":
                // "git checkout -- file" throws away that file's changes.
                if flags.contains("-f") || flags.contains("--force") || flags.contains("--") { return true }
            case "push":
                if flags.contains("-f") || flags.contains("--force")
                    || flags.contains("--force-with-lease") || flags.contains("--force-if-includes") { return true }
            default:
                continue
            }
        }
        return false
    }

    /// True for a `>`/`>>` write outside quotes. File-descriptor duplication (`2>&1`, `>&-`) is
    /// not a write and stays allowed.
    private static func hasUnquotedRedirect(_ command: String) -> Bool {
        let characters = Array(command)
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped { escaped = false; index += 1; continue }
            if character == "\\" { escaped = true; index += 1; continue }
            if character == "'" && !doubleQuoted { singleQuoted.toggle(); index += 1; continue }
            if character == "\"" && !singleQuoted { doubleQuoted.toggle(); index += 1; continue }
            if character == ">", !singleQuoted, !doubleQuoted {
                if index + 2 < characters.count, characters[index + 1] == "&" {
                    let after = characters[index + 2]
                    if after.isNumber || after == "-" { index += 1; continue }
                }
                return true
            }
            index += 1
        }
        return false
    }
}

// MARK: - Contextual App Workflows (Milestone 3)

public enum ContextualWorkflowApp: String, CaseIterable, Sendable {
    case xcode
    case terminal
    case safari
    case figma
    case unknown

    public static func identify(bundleID: String?, appName: String?) -> ContextualWorkflowApp {
        let id = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()

        if id.contains("apple.dt.xcode") || name.contains("xcode") {
            return .xcode
        } else if id.contains("terminal") || id.contains("iterm") || id.contains("ghostty") || id.contains("warp") || name.contains("terminal") || name.contains("iterm") || name.contains("ghostty") {
            return .terminal
        } else if id.contains("safari") || id.contains("chrome") || id.contains("browser") || name.contains("safari") || name.contains("chrome") || name.contains("arc") {
            return .safari
        } else if id.contains("figma") || name.contains("figma") {
            return .figma
        }
        return .unknown
    }
}

public struct ContextualWorkflowHelper {
    @MainActor
    public static func performAction(app: ContextualWorkflowApp, action: String) async -> (succeeded: Bool, message: String) {
        let act = action.lowercased().replacingOccurrences(of: " ", with: "_")
        switch app {
        case .xcode:
            switch act {
            case "build", "build_project", "compile":
                let res = InPlaceAppTyping.performPressKey("Cmd+B")
                return (res.succeeded, res.succeeded ? "Building Xcode project (Cmd+B)." : "Could not trigger build.")
            case "run", "run_project":
                let res = InPlaceAppTyping.performPressKey("Cmd+R")
                return (res.succeeded, res.succeeded ? "Running Xcode project (Cmd+R)." : "Could not trigger run.")
            case "clean", "clean_build", "clean_project":
                let res = InPlaceAppTyping.performPressKey("Cmd+Shift+K")
                return (res.succeeded, res.succeeded ? "Cleaning build folder (Cmd+Shift+K)." : "Could not trigger clean.")
            case "stop", "stop_running":
                let res = InPlaceAppTyping.performPressKey("Cmd+.")
                return (res.succeeded, res.succeeded ? "Stopped Xcode task (Cmd+.)." : "Could not trigger stop.")
            case "previews", "canvas", "toggle_previews":
                let res = InPlaceAppTyping.performPressKey("Cmd+Option+Enter")
                return (res.succeeded, res.succeeded ? "Toggled Xcode canvas previews (Cmd+Option+Enter)." : "Could not toggle canvas.")
            case "find", "find_in_project":
                let res = InPlaceAppTyping.performPressKey("Cmd+Shift+F")
                return (res.succeeded, res.succeeded ? "Opened Find in Project (Cmd+Shift+F)." : "Could not open search.")
            default:
                return (false, "Unknown Xcode action '\(action)'.")
            }

        case .terminal:
            switch act {
            case "git_status", "status":
                let res = InPlaceAppTyping.performTypeText("git status\n")
                return (res.succeeded, res.succeeded ? "Checked git status." : "Could not type git status.")
            case "git_diff", "diff":
                let res = InPlaceAppTyping.performTypeText("git diff\n")
                return (res.succeeded, res.succeeded ? "Checked git diff." : "Could not type git diff.")
            case "cancel", "cancel_process", "stop":
                let res = InPlaceAppTyping.performTypeText("\u{03}")
                return (res.succeeded, res.succeeded ? "Sent Ctrl+C to cancel current process." : "Could not send cancel signal.")
            case "clear":
                let res = InPlaceAppTyping.performPressKey("Cmd+K")
                return (res.succeeded, res.succeeded ? "Cleared terminal screen." : "Could not clear terminal.")
            default:
                return (false, "Unknown terminal action '\(action)'.")
            }

        case .safari:
            switch act {
            case "reader", "reader_mode":
                let res = InPlaceAppTyping.performPressKey("Cmd+Shift+R")
                return (res.succeeded, res.succeeded ? "Toggled Safari reader mode (Cmd+Shift+R)." : "Could not toggle reader mode.")
            case "reload", "refresh":
                let res = InPlaceAppTyping.performPressKey("Cmd+R")
                return (res.succeeded, res.succeeded ? "Reloaded webpage (Cmd+R)." : "Could not reload page.")
            case "new_tab":
                let res = InPlaceAppTyping.performPressKey("Cmd+T")
                return (res.succeeded, res.succeeded ? "Opened new browser tab (Cmd+T)." : "Could not open tab.")
            case "close_tab":
                let res = InPlaceAppTyping.performPressKey("Cmd+W")
                return (res.succeeded, res.succeeded ? "Closed browser tab (Cmd+W)." : "Could not close tab.")
            case "copy_url":
                let select = InPlaceAppTyping.performPressKey("Cmd+L")
                try? await Task.sleep(nanoseconds: 100_000_000)
                let copy = InPlaceAppTyping.performPressKey("Cmd+C")
                return (select.succeeded && copy.succeeded, "Copied browser URL to clipboard.")
            default:
                return (false, "Unknown browser action '\(action)'.")
            }

        case .figma:
            switch act {
            case "zoom_fit", "fit":
                let res = InPlaceAppTyping.performPressKey("Shift+1")
                return (res.succeeded, res.succeeded ? "Zoomed to fit in Figma (Shift+1)." : "Could not zoom to fit.")
            case "zoom_selection", "selection":
                let res = InPlaceAppTyping.performPressKey("Shift+2")
                return (res.succeeded, res.succeeded ? "Zoomed to selection in Figma (Shift+2)." : "Could not zoom to selection.")
            case "toggle_ui":
                let res = InPlaceAppTyping.performPressKey("Cmd+\\")
                return (res.succeeded, res.succeeded ? "Toggled Figma UI visibility (Cmd+\\)." : "Could not toggle UI.")
            case "group":
                let res = InPlaceAppTyping.performPressKey("Cmd+G")
                return (res.succeeded, res.succeeded ? "Grouped selection in Figma (Cmd+G)." : "Could not group selection.")
            case "export":
                let res = InPlaceAppTyping.performPressKey("Cmd+Shift+E")
                return (res.succeeded, res.succeeded ? "Opened Figma export panel (Cmd+Shift+E)." : "Could not open export panel.")
            default:
                return (false, "Unknown Figma action '\(action)'.")
            }

        case .unknown:
            return (false, "No contextual workflow available for this application.")
        }
    }
}

// MARK: - Proactive Idle & Stuck Detection (Milestone 4)

public struct StuckErrorEvent: Equatable, Sendable {
    public let appName: String
    public let errorSnippet: String
    public let guidance: String

    public init(appName: String, errorSnippet: String, guidance: String) {
        self.appName = appName
        self.errorSnippet = errorSnippet
        self.guidance = guidance
    }
}

@MainActor
public final class StuckTaskDetector {
    public static let shared = StuckTaskDetector()

    private struct ErrorRecord {
        let signature: String
        let firstSeenUptime: Double
        var lastSeenUptime: Double
        let appName: String
        var alerted: Bool
    }

    private var activeRecord: ErrorRecord?
    private let stuckThresholdSeconds: Double = 180.0 // >3 minutes
    private var lastGuidanceUptime: Double = -600.0
    private let cooldownSeconds: Double = 600.0 // 10 minutes between proactive alerts

    public func evaluate(appName: String?, windowTitle: String?, ocrText: String?, now: Double) -> StuckErrorEvent? {
        let combined = [windowTitle ?? "", ocrText ?? ""].joined(separator: "\n")
        guard isErrorState(combined) else {
            if let active = activeRecord, (now - active.lastSeenUptime) > 30.0 {
                activeRecord = nil
            }
            return nil
        }

        let signature = extractSignature(combined)
        let resolvedApp = appName ?? "Active App"

        if var existing = activeRecord, existing.signature == signature {
            existing.lastSeenUptime = now
            let elapsed = now - existing.firstSeenUptime
            if elapsed >= stuckThresholdSeconds && !existing.alerted && (now - lastGuidanceUptime >= cooldownSeconds) {
                existing.alerted = true
                activeRecord = existing
                lastGuidanceUptime = now
                let guidance = formatGuidance(for: signature, app: resolvedApp)
                // Screen text and window titles stay out of the log (owner rule).
                DiagnosticChatLogger.recordEvent(category: "stuck_detection", message: "Stuck on an error in \(resolvedApp) for \(Int(elapsed))s")
                return StuckErrorEvent(appName: resolvedApp, errorSnippet: signature, guidance: guidance)
            }
            activeRecord = existing
        } else {
            activeRecord = ErrorRecord(signature: signature, firstSeenUptime: now, lastSeenUptime: now, appName: resolvedApp, alerted: false)
        }
        return nil
    }

    private func isErrorState(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("build failed") ||
               lower.contains("fatal error:") ||
               lower.contains("traceback (most recent call last):") ||
               lower.contains("syntaxerror:") ||
               lower.contains("compile error") ||
               lower.contains("failed with exit code") ||
               lower.contains("failed (failures=") ||
               lower.contains("assertion failed") ||
               (lower.contains("error:") && (lower.contains(".swift:") || lower.contains(".rs:") || lower.contains(".py:")))
    }

    private func extractSignature(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("error:") || lower.contains("build failed") || lower.contains("traceback") || lower.contains("fatal") {
                return String(line.prefix(120))
            }
        }
        return String(text.prefix(80))
    }

    private func formatGuidance(for signature: String, app: String) -> String {
        let lowerApp = app.lowercased()
        if lowerApp.contains("xcode") {
            return "I noticed you've been working on this Xcode build error for a few minutes: \"\(signature)\". Would you like me to inspect the code or suggest a fix?"
        } else if lowerApp.contains("terminal") || lowerApp.contains("iterm") || lowerApp.contains("ghostty") {
            return "I noticed this command failed with an error: \"\(signature)\". Would you like me to check the stack trace or review recent changes?"
        } else {
            return "I noticed this persistent error: \"\(signature)\". Would you like me to help troubleshoot it?"
        }
    }

    public func reset() {
        activeRecord = nil
        lastGuidanceUptime = -cooldownSeconds
    }
}

// MARK: - Calendar & Meeting Preparation (EventKit)

public struct CalendarMeetingItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let notes: String?
    public let url: URL?
    public let attendees: [String]
    public let meetingLink: String?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        attendees: [String] = [],
        meetingLink: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.meetingLink = meetingLink ?? Self.detectMeetingLink(location: location, notes: notes, url: url)
    }

    public static func detectMeetingLink(location: String?, notes: String?, url: URL?) -> String? {
        if let u = url?.absoluteString, isVideoMeetingURL(u) { return u }
        if let loc = location, let link = extractFirstVideoURL(from: loc) { return link }
        if let n = notes, let link = extractFirstVideoURL(from: n) { return link }
        return nil
    }

    public static func isVideoMeetingURL(_ str: String) -> Bool {
        let lower = str.lowercased()
        return lower.contains("zoom.us/j/") || lower.contains("meet.google.com/") ||
               lower.contains("teams.microsoft.com/") || lower.contains("webex.com/") ||
               lower.contains("chime.aws/")
    }

    public static func extractFirstVideoURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) ?? []
        for match in matches {
            if let matchURL = match.url?.absoluteString, isVideoMeetingURL(matchURL) {
                return matchURL
            }
        }
        return nil
    }
}

public enum CalendarCommand: Equatable, Sendable {
    case todaySchedule
    case nextMeetingBrief
    case schedule(title: String, date: Date, durationMinutes: Int)
    case none
}

@MainActor
public final class CalendarMeetingAssistant {
    public static let shared = CalendarMeetingAssistant()

    #if canImport(EventKit)
    private let eventStore = EKEventStore()
    #endif

    public func hasAccess() -> Bool {
        accessState() == .granted
    }

    /// The honest distinction the Settings pane cannot fix: `.restricted` is a
    /// Screen Time or administrator policy, so the refusal must not point at a pane
    /// the owner cannot change.
    public enum CalendarAccess: Equatable, Sendable {
        case granted, denied, restricted, notDetermined
    }

    public func accessState() -> CalendarAccess {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .restricted: return .restricted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        default:
            if #available(macOS 14.0, *) {
                return (status == .fullAccess || status == .writeOnly) ? .granted : .denied
            }
            // The launch gate requires macOS 27, so this branch is unreachable; the
            // legacy case stays honest rather than referencing the deprecated member.
            return .denied
        }
        #else
        return .denied
        #endif
    }

    /// Refusal text for calendar reads and writes. A restriction names Screen Time /
    /// the administrator instead of a Settings pane that cannot override it.
    public func accessRefusalMessage(purpose: String) -> String {
        if accessState() == .restricted {
            return "Calendar access is restricted on this Mac by Screen Time or an administrator policy, so Dot cannot \(purpose). The administrator must allow Calendar access for Dot; System Settings cannot override this restriction."
        }
        return "Calendar access is not granted. You can allow access in System Settings > Privacy & Security > Calendars so I can \(purpose)."
    }

    public func requestAccess() async -> Bool {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return true }
            if status == .denied || status == .restricted { return false }
            do {
                return try await eventStore.requestFullAccessToEvents()
            } catch {
                return false
            }
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return false
        #endif
    }

    public func fetchEvents(from start: Date, to end: Date) -> [CalendarMeetingItem] {
        #if canImport(EventKit)
        guard hasAccess() else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)
        return ekEvents.map { ek in
            let attendees = ek.attendees?.compactMap { $0.name ?? $0.url.absoluteString } ?? []
            return CalendarMeetingItem(
                id: ek.eventIdentifier ?? UUID().uuidString,
                title: ek.title ?? "Untitled Meeting",
                startDate: ek.startDate,
                endDate: ek.endDate,
                isAllDay: ek.isAllDay,
                location: ek.location,
                notes: ek.notes,
                url: ek.url,
                attendees: attendees
            )
        }.sorted { $0.startDate < $1.startDate }
        #else
        return []
        #endif
    }

    public func fetchTodaySchedule(calendar: Calendar = .current, now: Date = Date()) -> [CalendarMeetingItem] {
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        return fetchEvents(from: startOfDay, to: endOfDay)
    }

    public func fetchNextMeeting(now: Date = Date()) -> CalendarMeetingItem? {
        let calendar = Calendar.current
        guard let oneDayLater = calendar.date(byAdding: .hour, value: 24, to: now) else { return nil }
        let upcoming = fetchEvents(from: now, to: oneDayLater).filter { $0.endDate > now && !$0.isAllDay }
        return upcoming.first
    }

    public func formatTodaySchedule(now: Date = Date()) -> String {
        guard hasAccess() else {
            return accessRefusalMessage(purpose: "read your meetings")
        }
        let items = fetchTodaySchedule(now: now)
        guard !items.isEmpty else {
            return "You have no meetings scheduled for today."
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        var result = "You have \(items.count) meeting\(items.count == 1 ? "" : "s") today:\n"
        for (idx, item) in items.enumerated() {
            let timeStr = item.isAllDay ? "All Day" : formatter.string(from: item.startDate)
            let platform = item.meetingLink != nil ? " · [Video Link]" : ""
            result += "\(idx + 1). \(item.title) at \(timeStr)\(platform)\n"
        }
        return result.trimmingCharacters(in: .newlines)
    }

    public func prepareNextMeetingBrief(now: Date = Date()) -> String {
        guard hasAccess() else {
            return accessRefusalMessage(purpose: "view meeting briefs")
        }
        guard let next = fetchNextMeeting(now: now) else {
            return "You have no upcoming meetings in the next 24 hours."
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let durationMin = max(1, Int(next.endDate.timeIntervalSince(next.startDate) / 60))
        var brief = "Next Meeting Brief:\n• \(next.title)\n• Time: \(formatter.string(from: next.startDate)) (\(durationMin) min)"
        if let link = next.meetingLink {
            brief += "\n• Video Link: \(link)"
        } else if let loc = next.location, !loc.isEmpty {
            brief += "\n• Location: \(loc)"
        }
        if !next.attendees.isEmpty {
            brief += "\n• Attendees: \(next.attendees.prefix(4).joined(separator: ", "))"
        }
        if let notes = next.notes, !notes.isEmpty {
            let snippet = notes.prefix(120).replacingOccurrences(of: "\n", with: " ")
            brief += "\n• Agenda/Notes: \"\(snippet)...\""
        }
        return brief
    }

    public func createEvent(title: String, startDate: Date, durationMinutes: Int, notes: String? = nil) -> (success: Bool, message: String) {
        #if canImport(EventKit)
        guard hasAccess() else {
            return (false, accessRefusalMessage(purpose: "create events"))
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(Double(durationMinutes * 60))
        event.notes = notes
        event.calendar = eventStore.defaultCalendarForNewEvents
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            return (true, "Scheduled '\(title)' for \(fmt.string(from: startDate)) (\(durationMinutes) min).")
        } catch {
            return (false, "Could not save event: \(error.localizedDescription)")
        }
        #else
        return (false, "EventKit is not available on this platform.")
        #endif
    }

    public func updateEvent(id: String, title: String? = nil, startDate: Date? = nil,
                            durationMinutes: Int? = nil) -> (success: Bool, message: String) {
        #if canImport(EventKit)
        guard hasAccess() else {
            return (false, accessRefusalMessage(purpose: "edit events"))
        }
        guard let event = eventStore.event(withIdentifier: id) else {
            return (false, "I could not find that event; it may have been deleted.")
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { event.title = title }
        if let startDate {
            let minutes = durationMinutes ?? max(1, Int(event.endDate.timeIntervalSince(event.startDate) / 60))
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(Double(minutes * 60))
        }
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
            return (true, "Updated '\(event.title ?? "event")' to \(fmt.string(from: event.startDate)).")
        } catch {
            return (false, "Could not save the event change: \(error.localizedDescription)")
        }
        #else
        return (false, "EventKit is not available on this platform.")
        #endif
    }

    public nonisolated static func parseCommand(_ text: String) -> CalendarCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("what meetings do i have today") ||
           lower == "meetings today" ||
           lower == "calendar today" ||
           lower == "schedule today" ||
           lower == "my meetings" ||
           lower == "today's meetings" ||
           lower == "upcoming meetings" ||
           lower == "what's on my schedule" ||
           lower == "check my calendar" {
            return .todaySchedule
        }
        if lower.contains("next meeting brief") ||
           lower.contains("prepare for my next meeting") ||
           lower.contains("brief for my next meeting") ||
           lower == "next meeting" ||
           lower == "what is my next meeting" {
            return .nextMeetingBrief
        }
        return .none
    }
}


// MARK: - Conversation key points (R5)

/// Turns a conversation into a prompt for the local model and parses its bullet
/// key points. Pure so the prompt/parse contract is testable without inference;
/// the full transcript stays in the FTS conversation archive, never in a tier.
public enum MemoryKeyPointExtractor {
    public static let systemPrompt = """
    You extract durable memory from a conversation with Dot's owner. Reply with 5 to 10 short key \
    points, one per line, each starting with "- ". Keep names, preferences, decisions, dates, \
    projects, constraints and corrections. Do not quote whole sentences from the conversation, do \
    not include chit-chat, and do not add any commentary. If nothing is worth remembering, reply \
    exactly: NONE.
    """

    public struct Line: Equatable, Sendable {
        public let role: String
        public let text: String
        public init(role: String, text: String) { self.role = role; self.text = text }
    }

    public static func prompt(for lines: [Line], limit: Int = 16) -> [Line]? {
        let usable = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ($0.role == "user" || $0.role == "assistant")
        }.suffix(max(2, limit))
        guard usable.contains(where: { $0.role == "user" }), usable.count >= 2 else { return nil }
        let transcript = usable.map { line -> String in
            let speaker = line.role == "user" ? "User" : "Dot"
            return "\(speaker): \(String(line.text.prefix(500)))"
        }.joined(separator: "\n")
        return [Line(role: "system", text: systemPrompt), Line(role: "user", text: transcript)]
    }

    public static func parse(_ response: String) -> [String] {
        var seen = Set<String>()
        var points: [String] = []
        for raw in response.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.uppercased() == "NONE" { continue }
            if let range = line.range(of: #"^(?:[-*•–]|\d{1,2}[\.\)])\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
            } else { continue }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•–"))
            guard line.count >= 4, line.count <= 240 else { continue }
            let key = line.lowercased()
            guard seen.insert(key).inserted else { continue }
            points.append(line)
            if points.count == 10 { break }
        }
        return points
    }
}

// MARK: - Model part download plan (pure, tested by SwiftPM)

/// Plan for the primary model delivery route: pinned split parts hosted on the
/// `Emin-dev/Dot` GitHub release. `Resources/model-parts.json` stays `pending`
/// until the owner splits and uploads the verified payload. When ready, every
/// part is verified by SHA-256 and the joined file is verified against
/// `bundled-models.json`; Hugging Face is only a fallback with the same hash.
public struct ModelPartPlan: Decodable, Equatable, Sendable {
    public struct Part: Decodable, Equatable, Sendable {
        public let asset: String
        public let file: String
        public let offset: Int64
        public let bytes: Int64
        public let sha256: String

        public init(asset: String, file: String, offset: Int64, bytes: Int64, sha256: String) {
            self.asset = asset
            self.file = file
            self.offset = offset
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public let schema_version: Int
    public let status: String
    public let release_tag: String?
    public let base_url: String?
    public let parts: [Part]

    /// GitHub rejects release assets at 2 GB, so every part must stay below it.
    public static let maximumPartBytes: Int64 = 2_000_000_000

    public static func decode(_ data: Data) -> ModelPartPlan? {
        guard let plan = try? JSONDecoder().decode(ModelPartPlan.self, from: data),
              plan.schema_version == 1, plan.parts.count <= 512 else { return nil }
        return plan
    }

    public var isReady: Bool {
        status == "ready" && !parts.isEmpty && baseURL != nil && releaseTag != nil
    }

    public var releaseTag: String? { release_tag }
    public var baseURL: URL? {
        guard let base_url, let tag = release_tag, !tag.isEmpty,
              let url = URL(string: base_url),
              url.scheme == "https", url.host == "github.com", url.query == nil,
              url.absoluteString.hasPrefix("https://github.com/Emin-dev/Dot/releases/download/\(tag)/") else { return nil }
        return url
    }

    public func parts(for file: String) -> [Part] {
        parts.filter { $0.file == file }.sorted { $0.offset < $1.offset }
    }

    /// A part plan is usable only when every covered file is contiguous from
    /// zero and the part sizes add up to the signed manifest size. Files with no
    /// parts fall back to the per-file Hugging Face route.
    public func validate(files: [(path: String, bytes: Int64)]) -> Bool {
        guard isReady else { return false }
        let expected = Dictionary(files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let covered = Set(parts.map(\.file))
        var assets = Set<String>()
        for file in covered {
            guard let total = expected[file] else { return false }
            let ordered = parts(for: file)
            var next: Int64 = 0
            for part in ordered {
                guard part.offset == next, part.bytes > 0, part.bytes <= Self.maximumPartBytes,
                      part.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      part.asset != ".", !part.asset.contains("/"), !part.asset.contains(".."),
                      part.asset.range(of: "^[A-Za-z0-9._-]{1,200}$", options: .regularExpression) != nil,
                      !part.file.hasPrefix("/"), !part.file.contains(".."),
                      assets.insert(part.asset).inserted else { return false }
                next += part.bytes
            }
            guard next == total else { return false }
        }
        return !covered.isEmpty
    }
}

// MARK: - GitHub log channel policy (pure, tested by SwiftPM)

import Foundation

/// Pure policy for the per-Dot GitHub log channel. Kept separate from the
/// AppKit/URLSession uploader so it is covered by the portable SwiftPM suite.
public enum LogSyncPolicy {
    /// Dedicated data branch. The shipped token can append logs but cannot change
    /// `main`; branch protection on `main` requires a pull request.
    public static let branch = "dot-logs"
    public static let repository = "Emin-dev/Dot"
    /// One folder per app launch under `dot/<install-id>/<launch-timestamp>/`.
    public static let root = "dot"
    public static let maximumRetries = 8
    public static let maximumQueueEntries = 64
    public static let maximumFileBytes = 4_000_000
    public static let baseBackoffSeconds: Double = 30
    public static let maximumBackoffSeconds: Double = 3_600

    /// Accept only a lowercase alphanumeric stable id (8–32 characters).
    public static func normalizedInstallID(_ raw: String) -> String? {
        let filtered = raw.lowercased().filter { character in
            ("a"..."z").contains(character) || ("0"..."9").contains(character)
        }
        guard filtered.count >= 8 else { return nil }
        return String(filtered.prefix(32))
    }

    /// A new anonymous id from a UUID, with no hardware or account information.
    public static func newInstallID() -> String {
        String(UUID().uuidString.lowercased().filter {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }.prefix(16))
    }

    /// UTC folder timestamp, e.g. `2026-10-20T17-24-00Z`.
    public static func launchStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }

    public static func folder(installID: String, launch: Date) -> String {
        "\(root)/\(installID)/\(launchStamp(for: launch))"
    }

    public static func remotePath(folder: String, file: String) -> String {
        folder.hasSuffix("/") ? folder + file : folder + "/" + file
    }

    public static func backoff(attempt: Int) -> Double {
        guard attempt > 0 else { return baseBackoffSeconds }
        let exponent = min(Double(attempt - 1), 16)
        return min(maximumBackoffSeconds, baseBackoffSeconds * pow(2, exponent))
    }

    public static func shouldRetry(attempt: Int) -> Bool {
        attempt < maximumRetries
    }
}

/// One queued upload. `nextAttempt` is a Unix timestamp so the queue survives
/// restarts and can stay offline indefinitely.
public struct LogUploadEntry: Codable, Equatable, Sendable {
    public var localPath: String
    public var remotePath: String
    public var attempts: Int
    public var nextAttempt: Double

    public init(localPath: String, remotePath: String, attempts: Int = 0, nextAttempt: Double = 0) {
        self.localPath = localPath
        self.remotePath = remotePath
        self.attempts = attempts
        self.nextAttempt = nextAttempt
    }
}

/// Persistent offline queue with backoff and a hard bound.
public struct LogUploadQueue: Codable, Equatable, Sendable {
    public private(set) var entries: [LogUploadEntry]

    public init(entries: [LogUploadEntry] = []) {
        self.entries = entries
    }

    /// Re-queueing the same remote path replaces the snapshot but keeps the
    /// existing retry budget and backoff, so a log that keeps changing while
    /// offline cannot defeat exponential backoff. New content after the retry
    /// budget was exhausted gets a fresh budget, so a recovered network can
    /// upload again without restarting Dot.
    public mutating func enqueue(localPath: String, remotePath: String, now: Double) {
        if let index = entries.firstIndex(where: { $0.remotePath == remotePath }) {
            entries[index].localPath = localPath
            if entries[index].attempts >= LogSyncPolicy.maximumRetries {
                entries[index].attempts = 0
                entries[index].nextAttempt = now
            }
        } else {
            entries.append(LogUploadEntry(localPath: localPath, remotePath: remotePath, nextAttempt: now))
            let overflow = entries.count - LogSyncPolicy.maximumQueueEntries
            if overflow > 0 { entries.removeFirst(overflow) }
        }
    }

    /// Old builds parked exhausted entries for a year. Any next attempt beyond
    /// the 1 h backoff cap is implausible, so an upgrade makes it due now
    /// instead of leaving a stable snapshot stranded.
    public mutating func normalize(now: Double) {
        let ceiling = now + LogSyncPolicy.maximumBackoffSeconds
        for index in entries.indices where entries[index].nextAttempt > ceiling {
            entries[index].nextAttempt = now
        }
    }

    public func due(now: Double) -> [LogUploadEntry] {
        entries.filter { $0.nextAttempt <= now }
    }

    public mutating func remove(remotePath: String) {
        entries.removeAll { $0.remotePath == remotePath }
    }

    /// Returns the new attempt count, or nil once the retry budget is spent.
    /// An exhausted entry is still retried at the maximum backoff, so a stable
    /// log is uploaded when the network returns instead of being parked for a
    /// year; new content resets the budget in `enqueue`.
    @discardableResult
    public mutating func failed(remotePath: String, now: Double) -> Int? {
        guard let index = entries.firstIndex(where: { $0.remotePath == remotePath }) else { return nil }
        let attempts = min(entries[index].attempts + 1, LogSyncPolicy.maximumRetries)
        entries[index].attempts = attempts
        entries[index].nextAttempt = now + LogSyncPolicy.backoff(attempt: attempts)
        return LogSyncPolicy.shouldRetry(attempt: attempts) ? attempts : nil
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(_ data: Data) -> LogUploadQueue? {
        try? JSONDecoder().decode(LogUploadQueue.self, from: data)
    }
}

/// Last-line defence: secrets must never reach the log file or an upload.
public enum LogRedaction {
    /// Mask bytes again immediately before upload, so a log line written by an
    /// older build that predates a redaction rule can never be published raw.
    public static func masked(_ data: Data) -> Data {
        // The log contract is text. A non-UTF-8 file is not a text log, so
        // uploading nothing is safer than publishing opaque bytes.
        guard let text = String(data: data, encoding: .utf8) else { return Data() }
        let masked = masked(text)
        return masked == text ? data : Data(masked.utf8)
    }

    /// Longest logged text per line. A larger command output is cut, so a single
    /// line can never push a log file past the 4 MB upload limit.
    public static let lineCharacterLimit = 20_000
    public static func capped(_ text: String, limit: Int = lineCharacterLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " … [\(text.count - limit) more characters not logged]"
    }

    public static func masked(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----.*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#, "[REDACTED_PRIVATE_KEY]"),
            (#"(?i)(authorization\s*[:=]\s*bearer\s+)\S+"#, "$1[REDACTED]"),
            (#"(?i)(authorization\s*[:=]\s*basic\s+)\S+"#, "$1[REDACTED]"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}\b"#, "Bearer [REDACTED]"),
            (#"(?i)\"([^\"]*(?:token|secret|password|passwd|api[_-]?key|access_key|private_key)[^\"]*)\"\s*:\s*\"[^\"]*\""#, "\"$1\":\"[REDACTED]\""),
            (#"(?i)\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*\s*[:=]\s*\S+"#, "[REDACTED_ENV]"),
            (#"\beyJ[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]*){2,4}(?![A-Za-z0-9_.-])"#, "[REDACTED_JWT]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, "[REDACTED_TOKEN]"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, "[REDACTED_TOKEN]"),
            (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED_TOKEN]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED_AWS_KEY]"),
            (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "[REDACTED_TOKEN]"),
            (#"(?i)\b(password|passwd|passphrase|secret)\s*[:=]\s*[^\r\n]+"#, "$1=[REDACTED]"),
            (#"(?i)\b(password|passwd|passphrase|secret)\s+(?:is|was)\s+[^\r\n]+"#, "$1=[REDACTED]"),
            (#"(?i)\b(token|api(?:[\s_-]?key))\s*[:=]\s*\S+"#, "$1=[REDACTED]"),
            (#"(?i)\b(token|api(?:[\s_-]?key))\s+(?:is|was)\s+\S+"#, "$1=[REDACTED]"),
            // Credentials inside commands and URLs (the shell tool logs both).
            (#"(?i)\b([a-z][a-z0-9+.-]*://[^\s/:@]+):[^\s/@]+@"#, "$1:[REDACTED]@"),
            (#"(?i)(\s(?:-u|--user)\s+[^\s:]+):\S+"#, "$1:[REDACTED]"),
            (#"(?i)\b(mysql[a-z]*\b[^\r\n]*?\s)-p\S+"#, "$1-p[REDACTED]"),
            (#"\bhf_[A-Za-z0-9]{20,}\b"#, "[REDACTED_TOKEN]"),
            (#"\bglpat-[A-Za-z0-9_-]{20,}"#, "[REDACTED_TOKEN]"),
            (#"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\b"#, "[REDACTED_TOKEN]"),
            (#"\bAIza[0-9A-Za-z_-]{35}"#, "[REDACTED_TOKEN]"),
            // Personal details: the logs branch is public, so e-mail addresses,
            // the account name in home paths and card-length numbers never upload.
            (#"\b(?!git@)[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "[EMAIL]"),
            (#"(/Users/)(?!Shared\b)[^/\s"'`]+"#, "$1[USER]"),
            (#"\b(?:\d[ -]?){12,18}\d\b"#, "[NUMBER]"),
        ]
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(of: pattern, with: replacement,
                                                 options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}

/// Pure policy for the owner's "force it" safety override. Kept in DotCore so
/// the expiry, exact-action match, three-refusal gate and one-shot reset are
/// executable tests; `SafetyApprover` supplies the clock and the lock.
public struct ForceOverridePolicy: Equatable, Sendable {
    public private(set) var strikes: [String: Int]
    public private(set) var lastRefused: String?
    public private(set) var forceKey: String?
    public private(set) var forceExpiresAt: TimeInterval

    public init() {
        strikes = [:]
        lastRefused = nil
        forceKey = nil
        forceExpiresAt = 0
    }

    /// The override can only be armed for the exact action that was refused at
    /// least `minimumStrikes` times.
    @discardableResult
    public mutating func registerStrike(_ action: String, minimumStrikes: Int = 3) -> Int {
        let count = (strikes[action] ?? 0) + 1
        strikes[action] = count
        if count >= minimumStrikes { lastRefused = action }
        return count
    }

    public mutating func arm(now: TimeInterval, lifetime: TimeInterval = 120) -> Bool {
        // An already-armed override cannot be extended. An expired, unconsumed
        // override is discarded with its strikes, so arming again needs three
        // fresh refusals rather than inheriting an old pass.
        if let key = forceKey {
            guard now > forceExpiresAt else { return false }
            forceKey = nil
            forceExpiresAt = 0
            strikes[key] = 0
            if lastRefused == key { lastRefused = nil }
        }
        guard let key = lastRefused, (strikes[key] ?? 0) >= 3 else { return false }
        forceKey = key
        forceExpiresAt = now + lifetime
        return true
    }

    /// One free pass for the exact refused action before `expiresAt`; consuming
    /// it clears that action's strikes so a later refusal needs three fresh ones.
    public mutating func consume(_ action: String, now: TimeInterval) -> Bool {
        guard forceKey == action, now <= forceExpiresAt else { return false }
        forceKey = nil
        forceExpiresAt = 0
        strikes[action] = 0
        if lastRefused == action { lastRefused = nil }
        return true
    }

    public mutating func clear(_ action: String) {
        strikes[action] = 0
        if lastRefused == action { lastRefused = nil }
    }
}
