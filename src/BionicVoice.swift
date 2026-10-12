import Foundation
import AVFoundation

/// Explicit choice: unavailable Bionic never falls back to a different voice.
enum VoiceMode: String, CaseIterable, Identifiable {
    case bionic, builtIn
    var id: String { rawValue }
    var label: String { self == .bionic ? "Bionic / Kokoro · bf_isabella" : "Built-in English (interim)" }
}

@MainActor
final class TTSManager {
    var onDrained: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    private let native = NativeTTSManager()
    private let bionic = BionicVoice()
    private var activeMode: VoiceMode = .bionic
    var mode: VoiceMode {
        get { VoiceMode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "") ?? .bionic }
        set { stop(); UserDefaults.standard.set(newValue.rawValue, forKey: "voiceMode") }
    }
    var root: String {
        get { UserDefaults.standard.string(forKey: "bionicRoot") ?? "" }
        set { shutdown(); UserDefaults.standard.set(newValue, forKey: "bionicRoot") }
    }
    var speaking: Bool { activeMode == .bionic ? bionic.speaking : native.speaking }
    init() {
        native.onStarted = { [weak self] in self?.onStarted?($0) }
        native.onDrained = { [weak self] in self?.onDrained?($0) }
        bionic.onStarted = { [weak self] in self?.onStarted?($0) }
        bionic.onDrained = { [weak self] in self?.onDrained?($0) }
        bionic.onError = { [weak self] in self?.onError?($0, $1) }
    }
    func start(id: UUID) throws {
        stop(); activeMode = mode
        if activeMode == .bionic { try bionic.start(id: id, root: root) }
        else { native.start(id: id) }
    }
    func enqueue(_ text: String, id: UUID) {
        if activeMode == .bionic { bionic.enqueue(text, id: id) }
        else { native.enqueue(text, id: id) }
    }
    func stop() { native.stop(); bionic.stop() }
    func shutdown() { native.stop(); bionic.shutdown() }
}

/// Only launches the bundled helper using an explicitly chosen existing environment.
/// No socket adoption, shell interpolation, model download or external-service fallback.
@MainActor
final class BionicVoice {
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
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var deadline = 0.0
    private var buffer = Data()
    private let clock = { ProcessInfo.processInfo.systemUptime }

    func start(id: UUID, root: String) throws {
        stop(); generation = id
        guard process == nil else { return }
        guard root.hasPrefix("/"),
              let helper = Bundle.main.url(forResource: "bionic_helper", withExtension: "py", subdirectory: "Voice") else {
            throw VoiceFailure.setup
        }
        let base = URL(fileURLWithPath: root, isDirectory: true)
        let python = base.appendingPathComponent("env/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              ["model/config.json", "model/kokoro-v1_0.pth", "model/voices/bf_isabella.pt"].allSatisfy({
                  FileManager.default.isReadableFile(atPath: base.appendingPathComponent($0).path)
              }) else { throw VoiceFailure.setup }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dot-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", "(version 1)(allow default)(deny network*)", python.path, "-I", "-u", helper.path, "--root", base.path, "--output", dir.path]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": dir.path,
                             "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"]
        child.standardInput = stdin; child.standardOutput = stdout
        // Library diagnostics may contain paths. They never go into application logs.
        child.standardError = FileHandle.nullDevice
        let token = UUID(); session = token
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? FileManager.default.removeItem(at: dir)
                guard let self, self.session == token else { return }
                self.fail("Bionic voice stopped. Check the selected local environment.")
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
        let tick = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }

    func enqueue(_ text: String, id: UUID) {
        guard generation == id else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value.count <= 1000, pending.count + audio.count < 24 else {
            fail("Bionic voice queue reached its safe limit. Click to start again."); return
        }
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
                fail("Bionic needs its existing Python packages, English language data and Kokoro assets. Nothing was downloaded."); return
            } else if event.kind == "audio", let filename = event.filename, let dir = directory {
                let url = dir.appendingPathComponent(filename)
                defer { try? FileManager.default.removeItem(at: url) }
                guard ready, event.turn == generation, let request = event.request, pending.remove(request) != nil else { continue }
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = attributes[.size] as? NSNumber, (44...2_881_024).contains(size.intValue) else { throw VoiceFailure.audio }
                    let bytes = try Data(contentsOf: url)
                    guard bytes.count <= 2_881_024 else { throw VoiceFailure.audio }
                    audio.append(bytes); deadline = clock() + 60; playNext()
                } catch { fail("Bionic returned invalid local audio."); return }
            } else if event.kind == "error", event.turn == generation {
                fail("Bionic could not synthesize this sentence. Check the local voice setup."); return
            }
        }
        if buffer.count > 8192 { fail("Bionic voice response exceeded its safe limit.") }
    }
    private func tick() {
        if (!ready || !pending.isEmpty) && clock() > deadline { fail("Bionic voice timed out."); return }
        if let player, !player.isPlaying { self.player = nil; playNext() }
    }
    private func playNext() {
        guard player == nil, let id = generation else { return }
        if audio.isEmpty {
            if pending.isEmpty && speaking { speaking = false; onDrained?(id) }
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
        case .setup: return "Choose an existing Bionic voice-engine folder in Connection. Its Python environment and Kokoro assets must already be installed."
        case .audio: return "Bionic returned invalid audio."
        }
    }
}
