// Manual hardware regression. Explicitly opt in and grant microphone/speech
// access to the launching test host. A skipped capture never counts as PASS.
import AppKit
import Speech

@main
struct STTSmoke {
    @MainActor static func main() async {
        guard ProcessInfo.processInfo.environment["DOT_ALLOW_MIC_TEST"] == "1" else {
            print("SKIP: explicit DOT_ALLOW_MIC_TEST=1 required for microphone capture"); exit(77)
        }
        let stt = STTManager(); let id = UUID()
        var failure: String?
        stt.onError = { _, message in failure = message }
        await stt.start(id: id)
        guard stt.recording else {
            print("FAIL: microphone capture did not start: \(failure ?? "unknown")"); exit(1)
        }
        try? await Task.sleep(for: .seconds(2))
        stt.cancel()
        guard !stt.recording, failure == nil else {
            print("FAIL: local capture reported an error"); exit(1)
        }
        print("STT capture/start/cancel smoke passed; transcription accuracy and silence timing require separate tests")
    }
}
