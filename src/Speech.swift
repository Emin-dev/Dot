import AppKit
import AVFoundation
import Combine

/// Bounded PCM storage. The real-time tap only downmixes/copies a small buffer.
private final class CapturedPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var active = true
    private let maximum: Int
    private(set) var rate: Double
    private var loudness = 0.0
    private var speechAt: Double?
    private var overflow = false
    init(rate: Double) { self.rate = rate; maximum = Int(rate * 61); samples.reserveCapacity(maximum) }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.format.sampleRate == rate,
              buffer.format.channelCount > 0, buffer.frameLength <= 8192 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        guard samples.count + count <= maximum else { overflow = true; return }
        var sum: Float = 0
        for index in 0..<count {
            var sample: Float = 0
            for channel in 0..<channelCount { sample += channels[channel][index] / Float(channelCount) }
            if !sample.isFinite { overflow = true; return }
            samples.append(sample); sum += sample * sample
        }
        loudness = count > 0 ? Double(sqrt(sum / Float(count))) : 0
        if loudness > 0.015 { speechAt = ProcessInfo.processInfo.systemUptime }
    }
    func status() -> (Double, Double?, Bool) { lock.lock(); defer { lock.unlock() }; return (loudness, speechAt, overflow) }
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; active = false; let result = samples; samples = []; return result }
    func cancel() { lock.lock(); active = false; samples = []; lock.unlock() }
}

@MainActor
final class STTManager: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcribing = false
    @Published private(set) var transcript = ""
    @Published private(set) var level = 0.0
    var onFinal: ((UUID, String) -> Void)?
    var onRecording: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    private let engine = AVAudioEngine()
    private let recognizer = WhisperRecognizer()
    private var pcm: CapturedPCM?
    private var cancellation: RecognitionCancellation?
    private var inference: Task<Void, Never>?
    private var capture: UUID?
    private var timer: Timer?
    private var tapInstalled = false
    private var began = 0.0
    private var modelURL: URL?

    func start(id: UUID) async {
        guard !Task.isCancelled else { return }
        cancel(); capture = id
        do {
            let payload = try await OfflinePayload.shared.validate()
            guard !Task.isCancelled, capture == id else { return }
            modelURL = payload.appendingPathComponent("STT/ggml-base.en.bin")
            guard WhisperRecognizer.available else { throw RecognitionFailure.unavailable }
        } catch { fail(id, error.localizedDescription); return }
        guard !Task.isCancelled, capture == id else { return }
        let mic: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = true
        case .notDetermined:
            mic = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: mic = false
        }
        guard !Task.isCancelled, capture == id else { return }
        guard mic else { fail(id, "Microphone access is off. Enable Dot in System Settings → Privacy & Security → Microphone."); return }
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard (8000...96000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { fail(id, RecognitionFailure.format.localizedDescription); return }
        let pcm = CapturedPCM(rate: format.sampleRate); self.pcm = pcm
        transcript = ""; began = ProcessInfo.processInfo.systemUptime
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in pcm.append(buffer) }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start(); recording = true
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick(id) }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            onRecording?(id)
        } catch { fail(id, "The microphone couldn't start. Click me to try again.") }
    }
    private func tick(_ id: UUID) {
        guard capture == id, recording, let pcm else { return }
        let (rms, lastSpeech, overflow) = pcm.status(), now = ProcessInfo.processInfo.systemUptime
        level = min(1, rms * 8)
        if overflow { fail(id, "The recording reached its safe limit. Click me to start again.") }
        else if let lastSpeech, now - lastSpeech >= 3 { finishCapture(id) }
        else if now - began >= 60 { fail(id, "Listening ended after one minute. Click me when you're ready.") }
    }
    private func finishCapture(_ id: UUID) {
        guard capture == id, let pcm, let modelURL else { return }
        stopAudio(); let samples = pcm.take(); self.pcm = nil
        let token = RecognitionCancellation(); cancellation = token; transcribing = true
        inference = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.recognizer.transcribe(samples, sampleRate: pcm.rate, model: modelURL, cancellation: token)
                guard !Task.isCancelled, !token.isCancelled, self.capture == id else { return }
                self.transcript = text; self.cancel(); self.onFinal?(id, text)
            } catch {
                guard !Task.isCancelled, !token.isCancelled, self.capture == id else { return }
                self.fail(id, error.localizedDescription)
            }
        }
    }
    private func fail(_ id: UUID, _ message: String) { guard capture == id else { return }; cancel(); onError?(id, message) }
    private func stopAudio() {
        timer?.invalidate(); timer = nil; recording = false
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        level = 0
    }
    func cancel() {
        capture = nil; cancellation?.cancel(); cancellation = nil
        inference?.cancel(); inference = nil; stopAudio(); pcm?.cancel(); pcm = nil; transcribing = false
    }
    func shutdown() { cancel(); recognizer.shutdown() }
}

/// Manual audio-device diagnostic used by tests/main.swift.
/// The product voice coordinator neither constructs nor falls back to this voice.
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
