// Headless STT crash-verification: drives STTManager.begin() directly —
// the exact call that SIGABRT'd in 1.0 (installTap format mismatch).
import AppKit
import Speech

let stt = STTManager.shared
print("STT: calling begin() — old code crashed here (installTap NSException)")
stt.begin()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let start = Date()
let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
    let el = Date().timeIntervalSince(start)
    if el > 5 {
        t.invalidate()
        stt.stop()
        print("STT_OK survived=5s recording=\(stt.recording) — no crash")
        exit(0)
    }
    if el > 30 {
        t.invalidate()
        print("STT_TIMEOUT")
        exit(1)
    }
}
app.run()
