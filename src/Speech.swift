import AppKit
import AVFoundation
import Combine

/// Bounded PCM storage. The real-time tap only downmixes/copies a small buffer.
private final class CapturedPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var active = false
    private let maximum: Int
    private(set) var rate: Double
    private var loudness = 0.0
    private var deadline: VoiceCaptureDeadline?
    private var continuity = VoiceAudioContinuity()
    init(rate: Double) { self.rate = rate; maximum = Int(rate * VoiceCaptureDeadline.maximumDuration); samples.reserveCapacity(maximum) }
    func begin(at now: Double, silence: Double, invitation: Double?) {
        lock.lock(); defer { lock.unlock() }
        deadline = VoiceCaptureDeadline(startedAt: now, silenceSeconds: silence, invitationSeconds: invitation)
        active = true
    }
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        guard let channels = buffer.floatChannelData, buffer.format.sampleRate == rate,
              buffer.format.channelCount > 0, buffer.frameLength <= 8192 else {
            deadline?.rejectAudio(); active = false; return
        }
        let frames = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        let callbackAt = ProcessInfo.processInfo.systemUptime
        let duration = Double(frames) / rate
        // AVAudioTime's host clock shares the system-uptime monotonic timebase.
        // Fall back conservatively to callback time when the device has no host time.
        let bufferStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : callbackAt - duration
        let bufferEnd = time.isHostTimeValid ? bufferStart + duration : callbackAt
        guard bufferStart.isFinite, bufferEnd <= callbackAt, let startedAt = deadline?.startedAt else {
            deadline?.rejectAudio(); active = false; return
        }
        let window = VoiceCaptureFrameWindow(frames: frames, stored: samples.count, rate: rate,
                                             bufferStartedAt: bufferStart, captureStartedAt: startedAt)
        let count = window.count
        guard count > 0 else {
            if window.reachesLimit { deadline?.reachCaptureLimit(); active = false }
            return
        }
        let processedStart = bufferStart + Double(window.offset) / rate
        let processedEnd = min(bufferEnd, processedStart + Double(count) / rate)
        guard continuity.accept(from: processedStart, through: processedEnd) else {
            deadline?.rejectAudio(); active = false; return
        }
        var sum: Float = 0
        var firstLoud: Int?, lastLoud: Int?
        for index in window.offset..<(window.offset + count) {
            var sample: Float = 0
            for channel in 0..<channelCount { sample += channels[channel][index] / Float(channelCount) }
            if !sample.isFinite { deadline?.rejectAudio(); active = false; return }
            samples.append(sample); sum += sample * sample
            if abs(sample) > 0.015 {
                if firstLoud == nil { firstLoud = index }; lastLoud = index
            }
        }
        loudness = count > 0 ? Double(sqrt(sum / Float(count))) : 0
        let hasSpeech = loudness > 0.015
        deadline?.observeAudio(firstSpeech: hasSpeech ? firstLoud.map { bufferStart + Double($0) / rate } : nil,
                               lastSpeech: hasSpeech ? lastLoud.map { min(processedEnd, bufferStart + Double($0 + 1) / rate) } : nil,
                               through: processedEnd)
        if let evidence = deadline?.timingEvidence {
            // Do not pass speech from a later utterance in this boundary buffer to
            // transcription when the main actor was delayed past the silence.
            let trailingFrames = min(count, max(0, Int(ceil((processedEnd - evidence.silenceSatisfiedAt) * rate))))
            if trailingFrames > 0 { samples.removeLast(trailingFrames) }
            active = false
        }
        if window.reachesLimit {
            // A silence completed inside the allowed prefix takes priority. An
            // unfinished utterance remains a terminal error, never transcription.
            deadline?.reachCaptureLimit(); active = false
        }
    }
    /// Evaluation and terminal close share the tap lock: no callback can append
    /// newly resumed speech between the main timer's decision and capture closure.
    func poll(at now: Double) -> (Double, VoiceCaptureDecision, VoiceCaptureTimingEvidence?) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return (loudness, deadline?.decision ?? .cancelled, deadline?.timingEvidence) }
        let result = deadline?.evaluate(at: now) ?? .cancelled
        if result != .listening { active = false }
        return (loudness, result, deadline?.timingEvidence)
    }
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; active = false; let result = samples; samples = []; return result }
    func cancel() { lock.lock(); active = false; deadline?.cancel(); samples = []; lock.unlock() }
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
    var onNoSpeech: ((UUID) -> Void)?
    var onCaptureCancelled: ((UUID) -> Void)?
    var onSpeechEnded: ((UUID, VoiceCaptureTimingEvidence) -> Void)?
    private let engine = AVAudioEngine()
    private let recognizer = WhisperRecognizer()
    private var pcm: CapturedPCM?
    private var cancellation: RecognitionCancellation?
    private var inference: Task<Void, Never>?
    private var capture: UUID?
    private var timer: Timer?
    private var tapInstalled = false
    private var modelURL: URL?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var captureFormat: AVAudioFormat?

    func start(id: UUID) async {
        guard !Task.isCancelled else { return }
        await start(id: id, settings: VoiceTimingSettings(), invitation: false)
    }
    func start(id: UUID, settings: VoiceTimingSettings, invitation: Bool) async {
        guard !Task.isCancelled else { return }
        cancel(); capture = id
        let silenceSeconds = settings.silenceSeconds
        let invitationSeconds = invitation ? settings.invitationSeconds : nil
        if invitation, microphonePermission != .authorized { cancelCapture(id); return }
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
            guard VoiceCaptureAccessPolicy.shouldRequestPermission(invitation: invitation, permission: .undetermined) else {
                cancelCapture(id); return
            }
            mic = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: mic = false
        }
        guard !Task.isCancelled, capture == id else { return }
        guard mic, microphonePermission == .authorized else {
            if invitation { cancelCapture(id) }
            else { fail(id, "Microphone access is off. Enable Dot in System Settings → Privacy & Security → Microphone.") }
            return
        }
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard (8000...96000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { fail(id, RecognitionFailure.format.localizedDescription); return }
        let pcm = CapturedPCM(rate: format.sampleRate); self.pcm = pcm
        transcript = ""; captureFormat = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in pcm.append(buffer, at: time) }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start()
            guard !Task.isCancelled, capture == id else { cancel(); return }
            guard microphonePermission == .authorized else { cancelCapture(id); return }
            pcm.begin(at: ProcessInfo.processInfo.systemUptime, silence: silenceSeconds, invitation: invitationSeconds)
            recording = true
            observeCaptureLifecycle(id)
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick(id) }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            onRecording?(id)
        } catch { fail(id, "The microphone couldn't start. Click me to try again.") }
    }
    private func tick(_ id: UUID) {
        guard capture == id, recording, let pcm else { return }
        guard VoiceCaptureAccessPolicy.mayCapture(permission: microphonePermission, routeAvailable: routeMatches && engine.isRunning) else {
            cancelCapture(id); return
        }
        let (rms, decision, evidence) = pcm.poll(at: ProcessInfo.processInfo.systemUptime)
        level = min(1, rms * 8)
        switch decision {
        case .listening: break
        case .silenceSatisfied:
            if let evidence { onSpeechEnded?(id, evidence) }
            finishCapture(id)
        case .noSpeech: cancel(); onNoSpeech?(id)
        case .maximumDuration: fail(id, "Listening ended after one minute. Click me when you're ready.")
        case .audioUnavailable, .cancelled: cancelCapture(id)
        }
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
                guard self.microphonePermission == .authorized, self.routeMatches else { self.cancelCapture(id); return }
                self.transcript = text; self.cancel(); self.onFinal?(id, text)
            } catch {
                guard !Task.isCancelled, !token.isCancelled, self.capture == id else { return }
                self.fail(id, error.localizedDescription)
            }
        }
    }
    private var microphonePermission: VoiceMicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }
    private var routeMatches: Bool {
        guard let captureFormat else { return false }
        let current = engine.inputNode.outputFormat(forBus: 0)
        return current.sampleRate == captureFormat.sampleRate && current.channelCount == captureFormat.channelCount
            && current.commonFormat == captureFormat.commonFormat && current.isInterleaved == captureFormat.isInterleaved
    }
    private func observeCaptureLifecycle(_ id: UUID) {
        func observe(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancelCapture(id) }
            }
            observers.append((center, token))
        }
        observe(.default, .AVAudioEngineConfigurationChange, object: engine)
        observe(.default, AVCaptureDevice.wasDisconnectedNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification)
    }
    private func cancelCapture(_ id: UUID) {
        guard capture == id else { return }
        cancel(); onCaptureCancelled?(id)
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
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        inference?.cancel(); inference = nil; stopAudio(); pcm?.cancel(); pcm = nil; transcribing = false; captureFormat = nil
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
