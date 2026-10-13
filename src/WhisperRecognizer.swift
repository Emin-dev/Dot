#if DOT_COMPLETE_BUNDLE && !canImport(whisper)
#error("The complete Dot installer must compile against its pinned whisper framework")
#endif
import Foundation
import AVFoundation
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
    case unavailable, format, failed, empty
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This installation is missing its bundled English voice recognizer. Please install the complete Dot build."
        case .format: return "I couldn't read that microphone format. Try another microphone."
        case .failed: return "Local transcription stopped. Click me to try again."
        case .empty: return "I didn't catch any words. Click me and try again."
        }
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
                    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard sampleRate.isFinite, (8000...96000).contains(sampleRate), !samples.isEmpty,
              samples.count <= Int(sampleRate * 61), samples.allSatisfy(\.isFinite),
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = input.floatChannelData?.pointee else { throw RecognitionFailure.format }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let source = $0.baseAddress { destination.update(from: source, count: samples.count) } }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16000 / sampleRate) + 4096)) else { throw RecognitionFailure.format }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, flag in
            if supplied { flag.pointee = .endOfStream; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        guard error == nil, status != .error, let data = output.floatChannelData?.pointee,
              output.frameLength > 0, output.frameLength <= 16000 * 61 else { throw RecognitionFailure.format }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
