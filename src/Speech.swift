import AppKit
import AVFoundation
import Combine

/// Bounded PCM storage. The real-time tap only downmixes/copies a small buffer.
final class CapturedPCM: @unchecked Sendable {
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
    func poll(at now: Double) -> (level: Double, decision: VoiceCaptureDecision, evidence: VoiceCaptureTimingEvidence?, snapshot: VoiceCaptureTimingSnapshot?, endReason: VoiceCaptureEndReason?) {
        lock.lock(); defer { lock.unlock() }
        if active, deadline?.evaluate(at: now) != .listening { active = false }
        return (loudness, deadline?.decision ?? .cancelled, deadline?.timingEvidence,
                deadline?.snapshot(at: now), deadline?.endReason)
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
    @Published private(set) var captureState = VoiceCaptureState.idle
    @Published private(set) var timingSnapshot: VoiceCaptureTimingSnapshot?
    var onFinal: ((UUID, String) -> Void)?
    var onRecording: ((UUID) -> Void)?
    var onError: ((UUID, String) -> Void)?
    var onNoSpeech: ((UUID) -> Void)?
    var onCaptureCancelled: ((UUID) -> Void)?
    var onCaptureEnded: ((UUID, VoiceCaptureEndReason) -> Void)?
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
        cancel(); capture = id; captureState = .preparing
        let silenceSeconds = settings.silenceSeconds
        let invitationSeconds = invitation ? settings.invitationSeconds : nil
        if invitation, microphonePermission != .authorized { endCapture(id, reason: .permissionLost); return }
        do {
            let payload = try await OfflinePayload.shared.validate()
            guard continueStarting(id) else { return }
            modelURL = payload.appendingPathComponent("STT/ggml-base.en.bin")
            guard WhisperRecognizer.available else { throw RecognitionFailure.unavailable }
        } catch {
            guard continueStarting(id) else { return }
            if error is CancellationError { endCapture(id, reason: .intentionalCancellation) }
            else { fail(id, error.localizedDescription) }
            return
        }
        guard continueStarting(id) else { return }
        let mic: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = true
        case .notDetermined:
            guard VoiceCaptureAccessPolicy.shouldRequestPermission(invitation: invitation, permission: .undetermined) else {
                endCapture(id, reason: .permissionLost); return
            }
            captureState = .requestingPermission
            mic = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: mic = false
        }
        guard continueStarting(id) else { return }
        captureState = .preparing
        guard mic, microphonePermission == .authorized else {
            endCapture(id, reason: .permissionLost)
            return
        }
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard (8000...96000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { endCapture(id, reason: .invalidAudio); return }
        let pcm = CapturedPCM(rate: format.sampleRate); self.pcm = pcm
        transcript = ""; captureFormat = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in pcm.append(buffer, at: time) }
        tapInstalled = true
        do {
            engine.prepare(); try engine.start()
            guard continueStarting(id) else { return }
            guard microphonePermission == .authorized else { endCapture(id, reason: .permissionLost); return }
            let now = ProcessInfo.processInfo.systemUptime
            pcm.begin(at: now, silence: silenceSeconds, invitation: invitationSeconds)
            timingSnapshot = pcm.poll(at: now).snapshot
            recording = true; captureState = .capturing
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
        guard microphonePermission == .authorized else { endCapture(id, reason: .permissionLost); return }
        if !routeMatches {
            handleAudioRouteChange(id)
            guard routeMatches && engine.isRunning else { endCapture(id, reason: .routeChanged); return }
        }
        guard engine.isRunning else { endCapture(id, reason: .missingAudio); return }
        let observation = pcm.poll(at: ProcessInfo.processInfo.systemUptime)
        level = min(1, observation.level * 8)
        timingSnapshot = observation.snapshot
        switch observation.decision {
        case .listening: break
        case .silenceSatisfied:
            if let evidence = observation.evidence { onSpeechEnded?(id, evidence) }
            finishCapture(id)
        case .noSpeech, .maximumDuration, .audioUnavailable, .cancelled:
            endCapture(id, reason: observation.endReason ?? .invalidAudio)
        }
    }
    func forceFinishCapture() {
        if let id = capture, recording {
            finishCapture(id)
        }
    }
    private func finishCapture(_ id: UUID) {
        guard capture == id, let pcm, let modelURL else { return }
        stopAudio(); let samples = pcm.take(); self.pcm = nil
        let token = RecognitionCancellation(); cancellation = token; transcribing = true; captureState = .transcribing
        inference = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.recognizer.transcribe(samples, sampleRate: pcm.rate, model: modelURL, cancellation: token)
                guard !Task.isCancelled, !token.isCancelled, self.capture == id else { return }
                guard self.microphonePermission == .authorized else { self.endCapture(id, reason: .permissionLost); return }
                self.transcript = text; self.resetCapture(); self.onFinal?(id, text)
            } catch {
                guard !Task.isCancelled, !token.isCancelled, self.capture == id else { return }
                if case RecognitionFailure.empty = error { self.endCapture(id, reason: .noRecognizedWords) }
                else if error is CancellationError { self.endCapture(id, reason: .intentionalCancellation) }
                else { self.fail(id, error.localizedDescription) }
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
    private func handleAudioRouteChange(_ id: UUID) {
        guard capture == id, recording, let pcm else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard (8000...96000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            endCapture(id, reason: .routeChanged)
            return
        }
        captureFormat = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            pcm.append(buffer, at: time)
        }
        tapInstalled = true
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            endCapture(id, reason: .routeChanged)
        }
    }
    private func observeCaptureLifecycle(_ id: UUID) {
        func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: VoiceCaptureEndReason, object: Any? = nil) {
            let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.endCapture(id, reason: reason) }
            }
            observers.append((center, token))
        }
        let routeToken = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleAudioRouteChange(id) }
        }
        observers.append((NotificationCenter.default, routeToken))
        observe(.default, AVCaptureDevice.wasDisconnectedNotification, reason: .routeChanged)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, reason: .systemSleep)
    }
    private func continueStarting(_ id: UUID) -> Bool {
        guard capture == id else { return false }
        guard !Task.isCancelled else { endCapture(id, reason: .intentionalCancellation); return false }
        return true
    }
    private func endCapture(_ id: UUID, reason: VoiceCaptureEndReason) {
        guard capture == id else { return }
        resetCapture()
        if let onCaptureEnded { onCaptureEnded(id, reason) }
        else if reason == .noSpeech { onNoSpeech?(id) }
        else if let message = reason.recoveryMessage { onError?(id, message) }
        else { onCaptureCancelled?(id) }
    }
    private func fail(_ id: UUID, _ message: String) { guard capture == id else { return }; resetCapture(); onError?(id, message) }
    private func stopAudio() {
        timer?.invalidate(); timer = nil; recording = false; timingSnapshot = nil
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        level = 0
    }
    func cancel(reason: VoiceCaptureEndReason = .intentionalCancellation) {
        if let capture { endCapture(capture, reason: reason) }
        else { resetCapture() }
    }
    private func resetCapture() {
        capture = nil; cancellation?.cancel(); cancellation = nil
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        inference?.cancel(); inference = nil; stopAudio(); pcm?.cancel(); pcm = nil; transcribing = false; captureFormat = nil
        captureState = .idle
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
