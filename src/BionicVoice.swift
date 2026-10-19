import Foundation
import AVFoundation
import Combine
import OSLog

@MainActor
final class TTSManager: ObservableObject {
    @Published private(set) var playbackLevel: Double = 0
    private var generation: UUID?
    var onDrained: ((UUID) -> Void)?
    var onFinalPlayback: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    /// Non-fatal delivery notice (for example a chunk dropped under backpressure).
    /// Unlike `onError`, it never ends the turn's voice session.
    var onDeliveryNotice: ((UUID, String) -> Void)?
    private let bionic = BionicVoice()
    private var root: String { Bundle.main.resourceURL?.appendingPathComponent("Offline/Voice").path ?? "" }
    var speaking: Bool { bionic.speaking }
    init() {
        bionic.onStarted = { [weak self] id in
            guard let self, self.generation == id else { return }; self.onStarted?(id)
        }
        bionic.onDrained = { [weak self] id in
            guard let self, self.generation == id else { return }; self.onDrained?(id)
        }
        bionic.onFinalPlayback = { [weak self] id in
            guard let self, self.generation == id else { return }; self.onFinalPlayback?(id)
        }
        bionic.onPlaybackLevel = { [weak self] id, level in
            guard let self, self.generation == id else { return }
            let bounded = level.isFinite ? min(1, max(0, level)) : 0
            if self.playbackLevel != bounded { self.playbackLevel = bounded }
        }
        bionic.onError = { [weak self] id, message in
            guard let self, self.generation == id else { return }
            self.playbackLevel = 0; self.onError?(id, message)
        }
        bionic.onDeliveryNotice = { [weak self] id, message in
            guard let self, self.generation == id else { return }
            self.onDeliveryNotice?(id, message)
        }
    }
    func start(id: UUID) throws {
        generation = id; playbackLevel = 0
        do { try bionic.start(id: id, root: root) }
        catch { generation = nil; playbackLevel = 0; throw error }
    }
    func enqueue(_ text: String, id: UUID) {
        bionic.enqueue(text, id: id)
    }
    func markGenerationComplete(id: UUID) { bionic.markGenerationComplete(id: id) }
    func stop() { generation = nil; playbackLevel = 0; bionic.stop() }
    func shutdown() { generation = nil; playbackLevel = 0; bionic.shutdown() }
}

/// Only launches the bundled native engine (`Contents/MacOS/dot-voice`) against
/// its app-bundled model root. No interpreter, script or sandbox-profile
/// fallback: a build without that binary reports the failure instead of
/// substituting a different voice.
/// No socket adoption, shell interpolation, model download or external-service fallback.
@MainActor
final class BionicVoice: NSObject, AVAudioPlayerDelegate {
    var onPlaybackLevel: ((UUID, Double) -> Void)?
    private static let log = Logger(subsystem: "app.dot", category: "runtime")
    var onDrained: ((UUID) -> Void)?
    var onFinalPlayback: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    /// Non-fatal delivery notice (a chunk dropped under backpressure). It never
    /// ends the voice session the way `onError` does.
    var onDeliveryNotice: ((UUID, String) -> Void)?
    private(set) var speaking = false
    private var process: Process?
    private var input: VoicePipeWriter?
    private var output: FileHandle?
    private var directory: URL?
    private var session = UUID()
    private var generation: UUID?
    private var ready = false
    private var pending: Set<UUID> = []
    private var unsent: [(UUID, String)] = []
    /// Chunks waiting for the synthesis queue to drain (backpressure). They are
    /// retried by the tick and dropped with a notice after a bounded wait.
    private var deferred: [(turn: UUID, text: String)] = []
    private var deferredDeadline = 0.0
    /// `markGenerationComplete` arrived while chunks were deferred; the final
    /// barrier seals only after those chunks are enqueued (or dropped).
    private var pendingSeal = false
    /// How long a saturated queue may delay new chunks before they are dropped.
    static let queueWaitSeconds = 10.0
    /// Per-request bound for the Rust synth engine; longer text is split at
    /// sentence boundaries instead of being rejected.
    static let maximumRequestLength = 1000
    private var audio: [(UUID, Data)] = []
    private var loads: [UUID: Task<Void, Never>] = [:]
    private var audioOrder: [UUID] = []
    private var loaded: [UUID: Data] = [:]
    private var player: AVAudioPlayer?
    private var playerRequest: UUID?
    private var playerDeadline = 0.0
    private var finalPlayback = FinalPlaybackBarrier()
    private var timer: Timer?
    private var deadline = 0.0
    private var buffer = Data()
    private let clock = { ProcessInfo.processInfo.systemUptime }

    func start(id: UUID, root: String) throws {
        stop(); generation = id; finalPlayback.begin(turn: id)
        guard process == nil else { return }
        guard root.hasPrefix("/") else { throw VoiceFailure.setup }
        let base = URL(fileURLWithPath: root, isDirectory: true)

        let nativeVoice = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("dot-voice")
        guard let native = nativeVoice, FileManager.default.isExecutableFile(atPath: native.path) else { throw VoiceFailure.setup }

        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("dot-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard (try? VoiceLaunchConfiguration.privateIdentity(requested)) != nil else { throw VoiceFailure.setup }

        let child = Process(), stdin = Pipe(), stdout = Pipe()
        let dir = requested
        child.executableURL = native
        // R4: the owner's voice choice travels with the launch; the engine loads only
        // that one voice's embedding, so RAM never holds the whole voice set.
        let voice = UserDefaults.standard.string(forKey: "dot.voice") ?? "bf_emma"
        child.arguments = ["--root", base.path, "--output", requested.path, "--voice", voice]
        child.environment = ["PATH": "/usr/bin:/bin"]
        child.currentDirectoryURL = requested
        child.standardInput = stdin; child.standardOutput = stdout
        // Library diagnostics may contain paths. They never go into application logs.
        child.standardError = FileHandle.nullDevice
        let token = UUID(); session = token
        child.terminationHandler = { [weak self] finished in
            let status = (finished.terminationReason == .uncaughtSignal ? -1 : 1) * Int(finished.terminationStatus)
            Task { @MainActor in
                try? FileManager.default.removeItem(at: dir)
                guard let self, self.session == token else { return }
                let diagnostic = RuntimeDiagnostic(stage: .voice, reason: .processExited, exitStatus: status)
                Self.log.error("\(diagnostic.logLine, privacy: .public)")
                self.fail(diagnostic.localizedDescription)
            }
        }
        let writer: VoicePipeWriter
        do {
            writer = try VoicePipeWriter(handle: stdin.fileHandleForWriting) { [weak self] in
                Task { @MainActor in
                    guard let self, self.session == token else { return }
                    self.fail("Bionic voice connection closed.")
                }
            }
            do { try child.run() }
            catch { writer.close(); throw error }
        } catch { try? FileManager.default.removeItem(at: dir); throw VoiceFailure.setup }
        process = child; input = writer; output = stdout.fileHandleForReading
        directory = dir; ready = false; buffer = Data(); deadline = clock() + 60
        output?.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in
                guard let self, self.session == token else { return }
                self.receive(bytes)
            }
        }
        ensureTimer()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let tick = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }

    func enqueue(_ text: String, id: UUID) {
        guard generation == id else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        ensureTimer()
        for chunk in Self.synthesisChunks(value, limit: Self.maximumRequestLength) {
            enqueueChunk(chunk, id: id)
        }
    }
    /// Split text at sentence boundaries so no synthesis request exceeds `limit`.
    /// A sentence longer than the limit is cut at a word boundary; a single word
    /// longer than the limit is cut at the limit. Short text passes through.
    static func synthesisChunks(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.count <= limit {
                let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { chunks.append(tail) }
                break
            }
            let prefix = rest.prefix(limit)
            let cut: String.Index
            if let sentence = prefix.range(of: #"[.!?…](?:["”']?\s+)"#, options: [.regularExpression, .backwards]) {
                cut = sentence.upperBound
            } else if let whitespace = prefix.lastIndex(where: { $0.isWhitespace }) {
                cut = rest.index(after: whitespace)
            } else {
                cut = rest.index(rest.startIndex, offsetBy: limit)
            }
            let chunk = String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            rest = rest[cut...]
        }
        return chunks
    }
    private var queueHasRoom: Bool {
        audio.count + audioOrder.count + (player == nil ? 0 : 1) < 24 && loads.count < 24
    }
    private func enqueueChunk(_ value: String, id: UUID) {
        guard generation == id else { return }
        guard queueHasRoom else {
            // Backpressure: the synthesis queue is busy. Wait a bounded time for
            // it to drain; if it stays saturated, drop the chunk with a notice
            // instead of failing the whole voice session mid-answer.
            if deferred.isEmpty { deferredDeadline = clock() + Self.queueWaitSeconds }
            deferred.append((id, value))
            ensureTimer()
            return
        }
        let request = UUID()
        guard finalPlayback.enqueue(turn: id, request: request) else {
            // The barrier is sealed. `markGenerationComplete` only seals after any
            // deferred chunks are enqueued, so a sentence here really is after the
            // final response: a protocol violation, not backpressure.
            fail("Bionic voice received a sentence after its final response."); return
        }
        pending.insert(request); audioOrder.append(request); speaking = true
        if pending.count == 1 { deadline = clock() + 60 }
        if ready { send(request: request, text: value, turn: id) }
        else { unsent.append((request, value)) }
    }
    func markGenerationComplete(id: UUID) {
        guard generation == id else { return }
        if deferred.isEmpty { completeGeneration(id) }
        else { pendingSeal = true }
    }
    private func completeGeneration(_ id: UUID) {
        guard generation == id else { return }
        if let completed = finalPlayback.generationComplete(turn: id) { onFinalPlayback?(completed) }
    }
    private static let queueBusyNotice = "The voice queue stayed busy, so part of the reply was not spoken. The full text is still shown."
    /// The `unavailable` event is a terminal exit of the Rust engine. Its `code`
    /// says why: report that honestly instead of one generic missing-files claim.
    private static func eventCode(in data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["code"] as? String
    }
    private static func unavailableMessage(code: String?) -> String {
        switch code {
        case "missing_root_argument", "missing_output_argument":
            return "The bundled voice engine was launched without its model paths. A repaired complete app is required."
        case "local_voice_setup_failed":
            return "The bundled voice engine could not load its local voice model. A repaired complete app is required."
        case "invalid_protocol_request", "unsupported_protocol":
            return "The bundled voice engine rejected the speech protocol. A repaired complete app is required."
        default:
            return "The bundled voice files are missing or incompatible. A repaired complete app is required."
        }
    }
    private func send(request: UUID, text: String, turn: UUID) {
        write(["protocol": 1, "type": "speak", "id": request.uuidString, "turn": turn.uuidString, "text": text])
    }
    private func write(_ value: [String: Any]) {
        guard let input, var bytes = try? JSONSerialization.data(withJSONObject: value) else { return }
        bytes.append(10)
        input.append(bytes)
    }
    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { output?.readabilityHandler = nil; return }
        guard bytes.count <= 65_536 else { fail("Bionic voice response exceeded its safe limit."); return }
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let event = VoiceEvent.parse(line) else { fail("Unsupported Bionic voice protocol."); return }
            if event.kind == "hello" {
                guard !ready else { fail("Unexpected Bionic voice handshake."); return }
                ready = true
                let waiting = unsent; unsent.removeAll()
                if let id = generation { for (request, text) in waiting { send(request: request, text: text, turn: id) } }
            } else if event.kind == "unavailable" {
                fail(Self.unavailableMessage(code: Self.eventCode(in: line)))
                return
            } else if event.kind == "audio", let filename = event.filename, let dir = directory {
                let url = dir.appendingPathComponent(filename)
                guard ready, event.turn == generation, let request = event.request, pending.remove(request) != nil else {
                    try? FileManager.default.removeItem(at: url); continue
                }
                let token = session, turn = generation
                loads[request] = Task { [weak self] in
                    defer { self?.loads.removeValue(forKey: request) }
                    do {
                        let data = try await VoiceAudioReader.read(url)
                        guard let self, !Task.isCancelled, self.session == token, self.generation == turn else { return }
                        self.loaded[request] = data
                        // Independent disk reads may finish out of order. Playback may not.
                        while let first = self.audioOrder.first, let next = self.loaded.removeValue(forKey: first) {
                            self.audioOrder.removeFirst(); self.audio.append((first, next))
                        }
                        self.deadline = self.clock() + 60; self.playNext()
                    } catch {
                        guard let self, !Task.isCancelled, self.session == token, self.generation == turn else { return }
                        self.fail("The bundled voice returned invalid audio.")
                    }
                }
            } else if event.kind == "error", event.turn == generation {
                fail("The bundled voice could not speak this sentence. Try again; if it persists, this app needs repair."); return
            }
        }
        if buffer.count > 8192 { fail("Bionic voice response exceeded its safe limit.") }
    }
    private func tick() {
        if !deferred.isEmpty {
            if queueHasRoom {
                let waiting = deferred; deferred.removeAll()
                for (turn, text) in waiting where generation == turn { enqueueChunk(text, id: turn) }
                if deferred.isEmpty, pendingSeal, let id = generation { pendingSeal = false; completeGeneration(id) }
            } else if clock() > deferredDeadline {
                let dropped = deferred.count
                deferred.removeAll()
                Self.log.warning("Dropped \(dropped) deferred voice chunk(s): the synthesis queue stayed busy.")
                if let id = generation { onDeliveryNotice?(id, Self.queueBusyNotice) }
                if pendingSeal, let id = generation { pendingSeal = false; completeGeneration(id) }
            }
        }
        if (!ready || !pending.isEmpty || !audioOrder.isEmpty) && clock() > deadline { fail("Bionic voice timed out."); return }
        // isPlaying becoming false also describes interruptions and errors. Only the
        // delegate's successful completion can satisfy the final audible barrier.
        if player != nil && clock() > playerDeadline { fail("Bionic audio playback did not finish."); return }
        if let id = generation {
            var level = 0.0
            if let player, player.isPlaying {
                player.updateMeters()
                let power = player.averagePower(forChannel: 0)
                if power.isFinite && power > -50 {
                    // Linear RMS amplitude with bounded visual gain. This is an audio
                    // envelope for mouth aperture, not phoneme or viseme alignment.
                    level = min(1, pow(10, Double(min(0, power)) / 20) * 3)
                }
            }
            onPlaybackLevel?(id, level)
        }
        if ready && pending.isEmpty && audioOrder.isEmpty && audio.isEmpty && player == nil && deferred.isEmpty {
            timer?.invalidate(); timer = nil
        }
    }
    private func playNext() {
        guard player == nil, let id = generation else { return }
        if audio.isEmpty {
            if pending.isEmpty && audioOrder.isEmpty && speaking {
                speaking = false
                SystemAudioDucker.shared.restoreIfDucked()
                onDrained?(id)
            }
            return
        }
        do {
            let (request, data) = audio.removeFirst()
            let next = try AVAudioPlayer(data: data)
            guard next.numberOfChannels == 1, next.format.sampleRate == 24000,
                  next.duration > 0, next.duration <= 60 else { throw VoiceFailure.audio }
            next.isMeteringEnabled = true
            next.delegate = self; player = next; playerRequest = request
            playerDeadline = clock() + next.duration + 2
            guard next.play() else { throw VoiceFailure.audio }
            SystemAudioDucker.shared.duckIfPlaying()
            onStarted?(id)
        } catch { fail("Bionic audio playback failed.") }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let player else { return }
            self?.playbackFinished(player, successfully: flag)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.fail("Bionic audio playback failed.")
        }
    }
    private func playbackFinished(_ player: AVAudioPlayer, successfully: Bool) {
        guard self.player === player, let request = playerRequest, let id = generation else { return }
        guard successfully else { fail("Bionic audio playback failed."); return }
        player.delegate = nil; self.player = nil; playerRequest = nil
        onPlaybackLevel?(id, 0)
        let completed = finalPlayback.playbackFinished(turn: id, request: request, successfully: true)
        playNext()
        if let completed, generation == completed { onFinalPlayback?(completed) }
    }
    func stop() {
        SystemAudioDucker.shared.restoreIfDucked()
        if let id = generation { onPlaybackLevel?(id, 0) }
        finalPlayback.cancel()
        generation = nil; pending.removeAll(); unsent.removeAll(); audio.removeAll()
        deferred.removeAll(); pendingSeal = false
        for task in loads.values { task.cancel() }
        loads.removeAll()
        audioOrder.removeAll(); loaded.removeAll()
        player?.delegate = nil; player?.stop(); player = nil; playerRequest = nil; speaking = false
        if ready { write(["protocol": 1, "type": "cancel"]) }
    }
    private func fail(_ message: String) {
        SystemAudioDucker.shared.restoreIfDucked()
        let id = generation
        shutdown()
        if let id { onError?(id, message) }
    }
    func shutdown() {
        // Invalidate before closing handles or receiving delayed callbacks.
        if let id = generation { onPlaybackLevel?(id, 0) }
        session = UUID(); generation = nil; ready = false; finalPlayback.cancel()
        timer?.invalidate(); timer = nil
        pending.removeAll(); unsent.removeAll(); audio.removeAll(); buffer = Data()
        deferred.removeAll(); pendingSeal = false
        for task in loads.values { task.cancel() }
        loads.removeAll()
        audioOrder.removeAll(); loaded.removeAll()
        player?.delegate = nil; player?.stop(); player = nil; playerRequest = nil; speaking = false
        output?.readabilityHandler = nil; try? output?.close(); output = nil
        // Do not wait for a pipe write or a stuck inference kernel to acknowledge shutdown.
        input?.close(); input = nil
        if let owned = process {
            // This Process object is ours; no PID searches or borrowed-daemon kills.
            if owned.isRunning { owned.terminate() }
        }
        process = nil
        // Unlink private output immediately; app termination need not await a queued callback.
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}

private enum VoiceFailure: LocalizedError {
    case setup, audio
    var errorDescription: String? {
        switch self {
        case .setup: return "My bundled voice files are missing. Please install the complete Dot installer."
        case .audio: return "Bionic returned invalid audio."
        }
    }
}
