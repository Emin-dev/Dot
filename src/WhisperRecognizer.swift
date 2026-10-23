#if DOT_COMPLETE_BUNDLE && !canImport(whisper)
#error("The complete Dot installer must compile against its pinned whisper framework")
#endif
import Foundation
import AVFoundation
import Speech
#if canImport(whisper)
import whisper
#endif

final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum RecognitionFailure: LocalizedError {
    case unavailable, modelNotReady, format, tooLong, failed, empty
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This installation is missing its bundled English voice recognizer. Please install the complete Dot build."
        case .modelNotReady: return "Apple's English speech model is not on this Mac yet. I asked macOS to download it; stay online and click me again in a few minutes."
        case .format: return "I couldn't read that microphone format. Try another microphone."
        case .tooLong: return "That recording was too long to transcribe locally. Click me and try again with a shorter turn."
        case .failed: return "Local transcription stopped. Click me to try again."
        case .empty: return "I didn't catch any words. Click me and try again."
        }
    }
}

/// R25: which recognizer a voice turn uses. On macOS 26 and later it is Apple's on-device
/// SpeechAnalyzer; whisper.cpp stays only as the fallback until its payload is removed.
enum NativeRecognizer {
    static var available: Bool {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable { return true }
        return WhisperRecognizer.available
    }
    static var usesAppleSpeech: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }
}

/// R25: speech-to-text with Apple SpeechAnalyzer and SpeechTranscriber, entirely on this Mac.
/// The system downloads the English model once (at first launch, with the main model) and
/// keeps it for every app; after that transcription needs no network. R3: English only.
@available(macOS 26.0, *)
enum AppleSpeechRecognizer {
    static let language = Locale(identifier: "en-US")

    private static func transcriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language) else {
            throw RecognitionFailure.unavailable
        }
        // Final results only: the turn is transcribed once, after the silence rule ends it.
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    /// True when the English model is installed, so a turn can be transcribed offline now.
    static func isReady() async -> Bool {
        guard let module = try? await transcriber() else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Installs the English speech model when it is missing. Nil means ready. The download can
    /// return before it is done (the system retries after a network error), so the status is
    /// checked afterwards.
    static func prepareAssets() async -> String? {
        do {
            let module = try await transcriber()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let status = await AssetInventory.status(forModules: [module])
            if status == .installed { return nil }
            if status == .downloading { return "Apple's English speech model is still downloading." }
            if status == .unsupported { return "Apple's English speech model is not supported on this Mac." }
            return "Apple's English speech model is not downloaded yet; Dot asks again at the next voice turn."
        } catch {
            return "The English speech model could not be installed yet: \(error.localizedDescription)"
        }
    }

    static func transcribe(_ samples: [Float], sampleRate: Double, cancellation: RecognitionCancellation) async throws -> String {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let module = try await transcriber()
        // Fail fast: installing is prepareAssets' job at launch, never a wait inside a turn.
        guard await AssetInventory.status(forModules: [module]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw RecognitionFailure.modelNotReady
        }
        let buffer = try WhisperRecognizer.buffer(samples, sampleRate: sampleRate, format: format)
        guard !cancellation.isCancelled else { throw CancellationError() }
        let (input, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        builder.yield(AnalyzerInput(buffer: buffer))
        builder.finish()
        let analyzer = SpeechAnalyzer(modules: [module])
        // Results are read while the analyzer consumes the input.
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in module.results where result.isFinal {
                text += (text.isEmpty ? "" : " ") + String(result.text.characters)
            }
            return text
        }
        do {
            if let last = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw RecognitionFailure.failed
        }
        let raw: String
        do { raw = try await collector.value } catch { throw RecognitionFailure.failed }
        guard !cancellation.isCancelled else { throw CancellationError() }
        let words = SpokenTranscript.words(raw)
        guard !words.isEmpty else { throw RecognitionFailure.empty }
        return words
    }
}

/// One serial owner for the native context. Cancellation never waits on this queue.
final class WhisperRecognizer: @unchecked Sendable {
    static var available: Bool {
        #if canImport(whisper)
        return true
        #else
        return false
        #endif
    }
    private let queue = DispatchQueue(label: "app.dot.whisper", qos: .userInitiated)
    #if canImport(whisper)
    private var context: OpaquePointer?
    #endif
    func transcribe(_ samples: [Float], sampleRate: Double, model: URL, cancellation: RecognitionCancellation) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    let pcm = try Self.convert(samples, sampleRate: sampleRate)
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    #if canImport(whisper)
                    if self.context == nil {
                        var parameters = whisper_context_default_params()
                        // Preserve GPU memory for Splash; this small English recognizer uses CPU/Accelerate.
                        parameters.use_gpu = false
                        self.context = model.path.withCString { whisper_init_from_file_with_params($0, parameters) }
                    }
                    guard let context = self.context else { throw RecognitionFailure.unavailable }
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    parameters.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2)))
                    parameters.translate = false; parameters.detect_language = false
                    parameters.no_context = true; parameters.no_timestamps = true
                    parameters.print_realtime = false; parameters.print_progress = false
                    parameters.print_timestamps = false; parameters.print_special = false
                    parameters.token_timestamps = false; parameters.vad = false
                    let token = Unmanaged.passRetained(cancellation).toOpaque()
                    defer { Unmanaged<RecognitionCancellation>.fromOpaque(token).release() }
                    parameters.abort_callback_user_data = token
                    parameters.abort_callback = { pointer in
                        guard let pointer else { return true }
                        return Unmanaged<RecognitionCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
                    }
                    parameters.encoder_begin_callback_user_data = token
                    parameters.encoder_begin_callback = { _, _, pointer in
                        guard let pointer else { return false }
                        return !Unmanaged<RecognitionCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
                    }
                    let code = "en".withCString { language in
                        parameters.language = language
                        return pcm.withUnsafeBufferPointer { whisper_full(context, parameters, $0.baseAddress, Int32($0.count)) }
                    }
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    guard code == 0 else { throw RecognitionFailure.failed }
                    var result = ""
                    for index in 0..<whisper_full_n_segments(context) {
                        if let text = whisper_full_get_segment_text(context, index) { result += String(cString: text) }
                    }
                    result = SpokenTranscript.words(result)
                    guard !result.isEmpty else { throw RecognitionFailure.empty }
                    continuation.resume(returning: result)
                    #else
                    _ = pcm; _ = model
                    throw RecognitionFailure.unavailable
                    #endif
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func shutdown() {
        queue.async {
            #if canImport(whisper)
            if let context = self.context { whisper_free(context); self.context = nil }
            #endif
        }
    }
    private static func convert(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw RecognitionFailure.format
        }
        let output = try buffer(samples, sampleRate: sampleRate, format: outputFormat)
        guard let data = output.floatChannelData?.pointee else { throw RecognitionFailure.format }
        guard output.frameLength <= 16000 * 301 else { throw RecognitionFailure.tooLong }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    /// The captured mono samples converted to the format a recognizer asks for.
    static func buffer(_ samples: [Float], sampleRate: Double, format outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard sampleRate.isFinite, (8000...96000).contains(sampleRate), !samples.isEmpty,
              samples.allSatisfy(\.isFinite),
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = input.floatChannelData?.pointee else { throw RecognitionFailure.format }
        // R1: turns may listen for five minutes, so the recognizer must accept the
        // same window; exceeding it is reported honestly as a recording that was too
        // long, not as an unreadable microphone format.
        guard samples.count <= Int(sampleRate * 301) else { throw RecognitionFailure.tooLong }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let source = $0.baseAddress { destination.update(from: source, count: samples.count) } }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * outputFormat.sampleRate / sampleRate) + 4096)) else { throw RecognitionFailure.format }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, flag in
            if supplied { flag.pointee = .endOfStream; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        guard error == nil, status != .error, output.frameLength > 0 else { throw RecognitionFailure.format }
        return output
    }
}
