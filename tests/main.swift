// Manual audio-device smoke test. Not CI and not proof of heard audio.
import AppKit
import Speech

@main
struct TTSSmoke {
    @MainActor static func main() async {
        guard ProcessInfo.processInfo.environment["DOT_ALLOW_AUDIO_TEST"] == "1" else {
            print("SKIP: explicit DOT_ALLOW_AUDIO_TEST=1 required for audio playback"); exit(77)
        }
        let tts = TTSManager(); let id = UUID(); let start = Date()
        tts.start(id: id)
        tts.enqueue("Hello. This is Dot's built-in English voice test.", id: id)
        tts.enqueue("Please confirm that both sentences are audible.", id: id)
        while tts.speaking && Date().timeIntervalSince(start) < 30 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !tts.speaking, Date().timeIntervalSince(start) > 1 else {
            tts.stop(); print("FAIL: playback timed out or ended suspiciously early"); exit(1)
        }
        print("TTS callback smoke passed; human audibility confirmation still required")
    }
}
