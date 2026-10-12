import AppKit
import AVFoundation
import Speech
import Combine

/// The audio tap never reaches into actor-isolated state. Its destination can
/// rotate after a recognizer final result without replacing the microphone tap.
private final class AudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func replace(with value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = value
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; request?.append(buffer)
    }
}

@MainActor
final class STTManager: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcript = ""
    @Published private(set) var level = 0.0
    var onFinal: ((UUID, String) -> Void)?
    var onError: ((UUID, String) -> Void)?
    private let engine = AVAudioEngine()
    private let relay = AudioRelay()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var capture: UUID?
    private var segment = UUID()
    private var prefix = ""
    private var partial = ""
    private var silence = SilenceGate()
    private var timer: Timer?
    private var finalWait: Task<Void, Never>?
    private var tapInstalled = false
    private var began = 0.0

    func start(id: UUID) async {
        guard !Task.isCancelled else { return }
        cancel()
        capture = id
        let mic = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, capture == id else { return }
        guard mic else { fail(id, "Microphone access is off. Enable Dot in System Settings → Privacy & Security → Microphone."); return }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, capture == id else { return }
        guard authorization == .authorized else { fail(id, "Speech recognition access is off in System Settings."); return }
        guard let speech = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              speech.isAvailable, speech.supportsOnDeviceRecognition else {
            fail(id, "On-device English speech isn't available. I won't send your audio to a server."); return
        }
        recognizer = speech
        prefix = ""; partial = ""; transcript = ""; silence = SilenceGate()
        began = ProcessInfo.processInfo.systemUptime
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail(id, "No microphone is available."); return }
        startSegment(id)
        let relay = self.relay
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            relay.append(buffer)
            guard let samples = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = Double(sqrt(sum / Float(count)))
            Task { @MainActor [weak self] in
                guard let self, self.capture == id, self.recording else { return }
                self.level = min(1, rms * 8)
                if rms > 0.015 { self.silence.heardSpeech(at: ProcessInfo.processInfo.systemUptime) }
            }
        }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start(); recording = true
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick(id) }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { fail(id, "The microphone couldn't start. Try again after closing other recording apps.") }
    }

    private func startSegment(_ id: UUID) {
        guard capture == id, let recognizer else { return }
        let segmentID = UUID(); segment = segmentID
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.requiresOnDeviceRecognition = true
        next.shouldReportPartialResults = true
        next.taskHint = .dictation
        request = next; relay.replace(with: next)
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.capture == id, self.segment == segmentID else { return }
                if let result {
                    let value = result.bestTranscription.formattedString
                    if value != self.partial, !value.isEmpty, self.recording {
                        self.silence.heardSpeech(at: ProcessInfo.processInfo.systemUptime)
                    }
                    self.partial = value
                    self.transcript = [self.prefix, value].filter { !$0.isEmpty }.joined(separator: " ")
                    if result.isFinal {
                        if self.recording {
                            // Some recognizers end segments early. Continue this same,
                            // explicitly clicked capture until OUR silence window ends.
                            self.prefix = self.transcript; self.partial = ""
                            self.startSegment(id)
                        } else { self.deliver(id) }
                        return
                    }
                }
                if error != nil {
                    if !self.recording { self.deliver(id) }
                    else { self.fail(id, "Local speech recognition stopped. Click me to try again.") }
                }
            }
        }
    }

    private func tick(_ id: UUID) {
        guard capture == id, recording else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if silence.shouldFinish(at: now) {
            finishCapture(id)
        } else if now - began > 60 {
            fail(id, "Listening ended after one minute. Click me when you're ready.")
        }
    }

    private func finishCapture(_ id: UUID) {
        stopAudio()
        request?.endAudio()
        // Keep recognition alive briefly for its final result, without recording.
        finalWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.deliver(id)
        }
    }

    private func deliver(_ id: UUID) {
        guard capture == id else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        if text.isEmpty { onError?(id, "I didn't catch that. Click me and try again.") }
        else { onFinal?(id, text) }
    }
    private func fail(_ id: UUID, _ message: String) {
        guard capture == id else { return }
        cancel(); onError?(id, message)
    }
    private func stopAudio() {
        timer?.invalidate(); timer = nil
        recording = false
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        relay.replace(with: nil); level = 0
    }
    func cancel() {
        capture = nil; segment = UUID()
        finalWait?.cancel(); finalWait = nil
        stopAudio(); request?.endAudio(); task?.cancel()
        request = nil; task = nil; recognizer = nil
    }
}

/// Explicit native offline fallback while the versioned Bionic/Kokoro bridge
/// is not yet available. No guessed daemon or unverified Python installation.
@MainActor
final class NativeTTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    var onDrained: ((UUID) -> Void)?
    var onStarted: ((UUID) -> Void)?
    private var synthesizer = AVSpeechSynthesizer()
    private var generation: UUID?
    private var pending: Set<ObjectIdentifier> = []
    override init() { super.init(); synthesizer.delegate = self }
    func start(id: UUID) { stop(); generation = id }
    func enqueue(_ text: String, id: UUID) {
        guard generation == id else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        pending.insert(ObjectIdentifier(utterance)); speaking = true
        synthesizer.speak(utterance)
    }
    func stop() {
        generation = nil; pending.removeAll(); speaking = false
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        // A fresh synthesizer prevents old cancellation callbacks from claiming
        // a new utterance or holding its queue hostage.
        synthesizer = AVSpeechSynthesizer(); synthesizer.delegate = self
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.synthesizer === synthesizer,
                  self.pending.contains(ObjectIdentifier(utterance)), let id = self.generation else { return }
            self.onStarted?(id)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.synthesizer === synthesizer,
                  self.pending.remove(ObjectIdentifier(utterance)) != nil else { return }
            if self.pending.isEmpty {
                self.speaking = false
                if let id = self.generation { self.onDrained?(id) }
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.synthesizer === synthesizer else { return }
            self.pending.remove(ObjectIdentifier(utterance))
            if self.pending.isEmpty { self.speaking = false }
        }
    }
}
