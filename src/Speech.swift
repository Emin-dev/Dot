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

    private func begin() {
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

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
            try audioEngine.start()
            recording = true
        } catch {
            AppKit.NSApp?.presentError(error)
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
    }
}

// MARK: - Text-to-speech (native, premium voice, sentence-streaming)

final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSManager()

    @Published var speaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var isBusy = false
    /// Best available English voice — prefer enhanced/premium for natural quality.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let en = voices.filter { $0.language.lowercased().hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            if v.quality == .premium { s += 8 }
            if v.quality == .enhanced { s += 5 }
            if v.quality == .default { s += 1 }
            if v.gender == .male { s += 2 }        // distinct from typical chat assistants
            if v.name.lowercased().contains("samantha") { s += 4 }
            return s
        }
        return en.max(by: { score($0) < score($1) }) ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

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
        u.voice = voice
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
            else { self.speaking = false }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.isBusy = false
            if self?.queue.isEmpty == true { self?.speaking = false }
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
