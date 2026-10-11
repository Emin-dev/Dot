// Headless TTS verification: speaks two sentences, waits for completion.
import AppKit
import Speech

let tts = TTSManager.shared
tts.speakSegment("Hello! This is a test of the voice.")
tts.speakSegment("If you hear this, text to speech is working.")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let start = Date()
let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
    if !tts.speaking {
        t.invalidate()
        let secs = Date().timeIntervalSince(start)
        // A 2-sentence utterance taking <1s means it silently failed.
        if secs < 1.0 {
            print("TTS_SUSPECT finished suspiciously fast (\(String(format: "%.1f", secs))s) — voice may be missing")
            exit(2)
        }
        print("TTS_OK finished=\(String(format: "%.1f", secs))s")
        exit(0)
    }
    if Date().timeIntervalSince(start) > 90 {
        t.invalidate()
        print("TTS_TIMEOUT after 90s")
        exit(1)
    }
}
app.run()
