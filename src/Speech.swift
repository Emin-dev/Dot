import Foundation
import AppKit
import AVFoundation
import Speech

// MARK: - Speech-to-text (Apple on-device)

final class STTManager: NSObject, ObservableObject {
    static let shared = STTManager()

    @Published var recording = false
    @Published var transcript = ""
    @Published var permissionDenied = false
    /// Human-readable voice error (shown in the UI; modal alerts are avoided —
    /// they would hang the app/CI when no audio device or permission exists).
    @Published var errorText: String?
    /// Live microphone level 0..1 (drives the orb while listening).
    @Published var level: Double = 0
    /// Set to true when a voice capture should auto-send its final transcript.
    var autoSendOnFinal = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func ensurePermissions(_ ok: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { ok(false); return }
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async {
                        if status == .authorized { ok(true) }
                        else { self.permissionDenied = true; ok(false) }
                    }
                }
            }
        }
    }

    func start() {
        guard !recording else { return }
        ensurePermissions { [weak self] granted in
            guard let self, granted else { return }
            self.begin()
        }
    }

    // internal (not private) so the headless STT harness can drive it directly.
    func begin() {
        guard !recording else { return }
        transcript = ""
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec, rec.isAvailable else { return }
        recognizer = rec

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // private: stays on this Mac
        }
        request.taskHint = .dictation
        self.request = request

        let input = audioEngine.inputNode
        // CRASH FIX: the tap MUST use the input node's OWN output format
        // (48 kHz on most Macs). Installing a custom 16 kHz tap format throws
        // an unrecoverable ObjC exception → SIGABRT. The recognizer resamples
        // internally, so no manual conversion is needed.
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0 else {
            errorText = "No microphone available"
            return
        }
        var tapCount = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: nodeFormat) { [weak self] buffer, _ in
            request.append(buffer)
            // Level metering (throttled) — feeds the orb.
            tapCount += 1
            guard let self, tapCount % 3 == 0,
                  let ch = buffer.floatChannelData?.pointee else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(1, n)))
            let scaled = min(1.0, Double(rms) * 7.0)
            DispatchQueue.main.async { self.level = max(0.06, scaled) }
        }

        task = rec.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true {
                    self.stop(fireFinal: false)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            errorText = nil
            recording = true
        } catch {
            // Mic permission denied / device busy — recover cleanly, no crash.
            errorText = error.localizedDescription
            cleanup()
        }
    }

    func stop(fireFinal: Bool = true) {
        guard recording else { return }
        recording = false
        cleanup()
    }

    private func cleanup() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        recognizer = nil
        level = 0
    }
}

// MARK: - Text-to-speech (native, premium voice, sentence-streaming)

final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSManager()

    @Published var speaking = false
    /// Fires on the main queue when the whole queue has finished playing.
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var isBusy = false
    /// Resolved per utterance — the voice list can be empty at first access
    /// (it loads lazily), so never cache a bad result.
    private func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let en = voices.filter { $0.language.lowercased().hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            if v.quality == .premium { s += 8 }
            if v.quality == .enhanced { s += 5 }
            if v.quality == .default { s += 1 }
            if v.name.lowercased().contains("samantha") { s += 4 }
            if v.name.lowercased().contains("allison") { s += 3 }
            return s
        }
        return en.max(by: { score($0) < score($1) }) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Feed a (possibly partial) sentence; playback starts as soon as the first
    /// sentence is complete — audio never waits for the whole reply.
    func speakSegment(_ segment: String) {
        let t = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 2 else { return }
        queue.append(t)
        if !speaking { speaking = true }
        pump()
    }

    func stop() {
        queue.removeAll()
        synthesizer.stopSpeaking(at: .word)
        speaking = false
    }

    private func pump() {
        guard !isBusy, !queue.isEmpty else { return }
        isBusy = true
        let text = queue.removeFirst()
        let u = AVSpeechUtterance(string: text)
        u.voice = pickVoice()
        u.rate = 0.47                     // slightly brisk, still natural
        u.pitchMultiplier = 1.0
        u.preUtteranceDelay = 0.02
        synthesizer.speak(u)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isBusy = false
            if !self.queue.isEmpty { self.pump() }
            else {
                self.speaking = false
                self.onFinished?()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.isBusy = false
            if self?.queue.isEmpty == true {
                self?.speaking = false
                self?.onFinished?()
            }
        }
    }
}

/// Splits streamed tokens into speakable chunks on sentence boundaries.
final class SentenceChunker {
    private var pending = ""
    func feed(_ token: String) -> [String] {
        pending += token
        var out: [String] = []
        while let range = Self.sentenceEnd(in: pending) {
            let chunk = String(pending[..<range.lowerBound])
            pending = String(pending[range.upperBound...])
            let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            if pending.count > 600 {            // safety: don't buffer forever
                if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(pending); pending = ""
                }
                break
            }
        }
        return out
    }
    func flush() -> String? {
        let t = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return t.isEmpty ? nil : t
    }
    private static func sentenceEnd(in s: String) -> Range<String.Index>? {
        var i = s.startIndex
        var inQuote = false
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { inQuote.toggle() }
            if !inQuote, ".!?…".contains(c) {
                // require a space or newline after, or end of string
                let nextIdx = s.index(after: i)
                if nextIdx == s.endIndex {
                    return i..<nextIdx
                }
                let next = s[nextIdx]
                if next == " " || next == "\n" || next == "\t" {
                    return s.startIndex..<nextIdx
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
