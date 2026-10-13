import Foundation
import AVFoundation
import OSLog

@MainActor
final class TTSManager {
    var onDrained: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    private let bionic = BionicVoice()
    private var root: String { Bundle.main.resourceURL?.appendingPathComponent("Offline/Voice").path ?? "" }
    var speaking: Bool { bionic.speaking }
    init() {
        bionic.onStarted = { [weak self] in self?.onStarted?($0) }
        bionic.onDrained = { [weak self] in self?.onDrained?($0) }
        bionic.onError = { [weak self] in self?.onError?($0, $1) }
    }
    func start(id: UUID) throws {
        try bionic.start(id: id, root: root)
    }
    func enqueue(_ text: String, id: UUID) {
        bionic.enqueue(text, id: id)
    }
    func stop() { bionic.stop() }
    func shutdown() { bionic.shutdown() }
}

/// Only launches the bundled helper using only its app-bundled runtime.
/// No socket adoption, shell interpolation, model download or external-service fallback.
@MainActor
final class BionicVoice {
    private static let log = Logger(subsystem: "app.dot", category: "runtime")
    var onDrained: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
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
    private var audio: [Data] = []
    private var loads: [UUID: Task<Void, Never>] = [:]
    private var audioOrder: [UUID] = []
    private var loaded: [UUID: Data] = [:]
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var deadline = 0.0
    private var buffer = Data()
    private let clock = { ProcessInfo.processInfo.systemUptime }

    func start(id: UUID, root: String) throws {
        stop(); generation = id
        guard process == nil else { return }
        guard root.hasPrefix("/"),
              let helper = Bundle.main.url(forResource: "bionic_helper", withExtension: "py", subdirectory: "Voice"),
              let profile = Bundle.main.url(forResource: "voice", withExtension: "sb", subdirectory: "Voice") else {
            throw VoiceFailure.setup
        }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        let python = base.appendingPathComponent("python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              ["model/config.json", "model/kokoro-v1_0.pth", "model/voices/bf_isabella.pt"].allSatisfy({
                  FileManager.default.isReadableFile(atPath: base.appendingPathComponent($0).path)
              }) else { throw VoiceFailure.setup }
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("dot-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let identity = try? VoiceLaunchConfiguration.privateIdentity(requested) else { throw VoiceFailure.setup }
        let launch: VoiceLaunchConfiguration
        do {
            launch = try VoiceLaunchConfiguration(python: python, helper: helper, profile: profile, root: base, output: requested)
            guard try VoiceLaunchConfiguration.privateIdentity(launch.directory) == identity else { throw VoiceFailure.setup }
        } catch {
            VoiceLaunchConfiguration.removeEmptyIfUnchanged(requested, identity: identity)
            throw VoiceFailure.setup
        }
        let dir = launch.directory
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = launch.arguments
        child.environment = launch.environment
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
        guard value.count <= 1000, pending.count + audio.count + audioOrder.count < 24, loads.count < 24 else {
            fail("Bionic voice queue reached its safe limit. Click to start again."); return
        }
        ensureTimer()
        let request = UUID(); pending.insert(request); speaking = true
        if pending.count == 1 { deadline = clock() + 60 }
        if ready { send(request: request, text: value, turn: id) }
        else { unsent.append((request, value)) }
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
                fail("The bundled voice files are missing or incompatible. A repaired complete app is required."); return
            } else if event.kind == "audio", let filename = event.filename, let dir = directory {
                let url = dir.appendingPathComponent(filename)
                guard ready, event.turn == generation, let request = event.request, pending.remove(request) != nil else {
                    try? FileManager.default.removeItem(at: url); continue
                }
                let token = session, turn = generation
                audioOrder.append(request)
                loads[request] = Task { [weak self] in
                    defer { self?.loads.removeValue(forKey: request) }
                    do {
                        let data = try await VoiceAudioReader.read(url)
                        guard let self, !Task.isCancelled, self.session == token, self.generation == turn else { return }
                        self.loaded[request] = data
                        // Independent disk reads may finish out of order. Playback may not.
                        while let first = self.audioOrder.first, let next = self.loaded.removeValue(forKey: first) {
                            self.audioOrder.removeFirst(); self.audio.append(next)
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
        if (!ready || !pending.isEmpty || !audioOrder.isEmpty) && clock() > deadline { fail("Bionic voice timed out."); return }
        if let player, !player.isPlaying { self.player = nil; playNext() }
        if ready && pending.isEmpty && audioOrder.isEmpty && audio.isEmpty && player == nil {
            timer?.invalidate(); timer = nil
        }
    }
    private func playNext() {
        guard player == nil, let id = generation else { return }
        if audio.isEmpty {
            if pending.isEmpty && audioOrder.isEmpty && speaking { speaking = false; onDrained?(id) }
            return
        }
        do {
            let next = try AVAudioPlayer(data: audio.removeFirst())
            guard next.numberOfChannels == 1, next.format.sampleRate == 24000,
                  next.duration > 0, next.duration <= 60, next.play() else { throw VoiceFailure.audio }
            player = next; onStarted?(id)
        } catch { fail("Bionic audio playback failed.") }
    }
    func stop() {
        generation = nil; pending.removeAll(); unsent.removeAll(); audio.removeAll()
        for task in loads.values { task.cancel() }
        audioOrder.removeAll(); loaded.removeAll()
        player?.stop(); player = nil; speaking = false
        if ready { write(["protocol": 1, "type": "cancel"]) }
    }
    private func fail(_ message: String) {
        let id = generation
        shutdown()
        if let id { onError?(id, message) }
    }
    func shutdown() {
        // Invalidate before closing handles or receiving delayed callbacks.
        session = UUID(); generation = nil; ready = false
        timer?.invalidate(); timer = nil
        pending.removeAll(); unsent.removeAll(); audio.removeAll(); buffer = Data()
        for task in loads.values { task.cancel() }
        audioOrder.removeAll(); loaded.removeAll()
        player?.stop(); player = nil; speaking = false
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
