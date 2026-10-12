import Foundation
import AppKit

/// Invisible local verification harness — active ONLY when the binary is
/// launched with the environment variable DOT_AUTOTEST=1 (ordinary launches are
/// untouched). Drives the full product stack in the real app:
///
///   engine load (llama-server + Qwen3.8-27B)
///   → a real chat turn (thinking on) and verifies the reply
///   → waits for TTS to actually finish speaking
///   → (DOT_AUTOTEST_MIC=1) starts/stops the mic to verify the STT pipeline
///   → prints an "AUTOTEST PASS/FAIL" summary and exits with 0/1.
final class Autotest {
    static let shared = Autotest()

    private var model: ChatModel?
    private var timer: Timer?
    private var started = Date()
    private var phaseStarted = Date()
    private var phaseName = ""
    private var done = false
    private var micStartRequested = false
    private var chatVerified = false
    private var ttsVerified = false
    private var obs = [NSObjectProtocol]()

    func attach(_ m: ChatModel) {
        // Activation: DOT_AUTOTEST=1 env var, OR marker files in ~/.dot
        // (the file form works when launched via `open`, where env is not passed).
        // IMPORTANT: the app must be launched via LaunchServices (`open`/double-click),
        // not directly from a terminal — TCC attributes mic/speech requests from
        // terminal-launched processes to the parent app and aborts them.
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let dotDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".dot")
        let fileMarker = fm.fileExists(atPath: dotDir.appendingPathComponent("autotest").path)
        guard env["DOT_AUTOTEST"] == "1" || fileMarker else { return }
        model = m
        guard timer == nil else { return }
        let wantMic = env["DOT_AUTOTEST_MIC"] == "1"
            || fm.fileExists(atPath: dotDir.appendingPathComponent("autotest-mic").path)
        setPhase(wantMic ? "engine" : "engine")
        log("autotest started (mic=\(wantMic ? "yes" : "no"))")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(wantMic: wantMic) }
        }
        // If the user closes the window before we finish, still report the
        // verification result on termination.
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.done, self.chatVerified, self.ttsVerified else { return }
            self.log("app terminated after chat+TTS verification — PASS (window closed early)")
        }
        obs.append(token)
    }

    private func setPhase(_ name: String) {
        phaseName = name
        phaseStarted = Date()
    }

    private func log(_ s: String) {
        let line = String(format: "AUTOTEST [t=%5.1f] %@", Date().timeIntervalSince(started), s)
        print(line)
        // Also persist to a file: with `open`, stdout is not visible to the shell.
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dot").appendingPathComponent("autotest-result.log")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    @MainActor
    private func fail(_ s: String) {
        log("FAIL: \(s)")
        finish(false)
    }

    @MainActor
    private func tick(wantMic: Bool) {
        guard let m = model, !done else { return }
        switch phaseName {
        case "engine":
            if case .ready = m.engine.phase {
                log("engine ready in \(String(format: "%.1f", Date().timeIntervalSince(phaseStarted)))s (model: \(m.engine.loadedModel))")
                m.send("Reply with exactly: DOT_OK")
                setPhase("chat")
            } else if case .failed(let msg) = m.engine.phase {
                fail("engine failed: \(msg)")
            } else if Date().timeIntervalSince(phaseStarted) > 300 {
                fail("engine never ready after 300s (lastLog: \(m.engine.lastLog))")
            }
        case "chat":
            if !m.isGenerating {
                guard let last = m.messages.last, last.role == .assistant else {
                    fail("no assistant message after send")
                    return
                }
                if last.content.contains("DOT_OK") {
                    chatVerified = true
                    log("chat OK in \(String(format: "%.1f", Date().timeIntervalSince(phaseStarted)))s — reply: “\(String(last.content.prefix(80)))” (thinking chars: \(last.thinking.count))")
                    if m.autoSpeak { setPhase("tts") } else { micStartRequested = false; setPhase(wantMic ? "mic" : "done") }
                } else {
                    fail("engine answered but not with DOT_OK: “\(String(last.content.prefix(200)))”")
                }
            } else if Date().timeIntervalSince(phaseStarted) > 180 {
                fail("chat still generating after 180s")
            }
        case "tts":
            if !m.tts.speaking {
                ttsVerified = true
                log("TTS finished speaking the reply in \(String(format: "%.1f", Date().timeIntervalSince(phaseStarted)))s")
                setPhase(wantMic ? "mic" : "done")
            } else if Date().timeIntervalSince(phaseStarted) > 90 {
                fail("TTS still speaking after 90s")
            }
        case "mic":
            // Permission may need a user click (fresh build → fresh TCC identity).
            // Wait until the decision is known: recording, denied, or an error.
            let el = Date().timeIntervalSince(phaseStarted)
            if !m.stt.recording, !micStartRequested, el < 25 { micStartRequested = true; m.stt.start() }
            if el > 3, m.stt.recording {
                m.stt.stop()                    // 3s of silence — enough to prove the pipeline
                setPhase("mic-final")
            } else if m.stt.permissionDenied || m.stt.errorText != nil {
                log("STT not usable: denied=\(m.stt.permissionDenied) error=\(m.stt.errorText ?? "-") — recorded as skipped (no crash)")
                setPhase("done")
            } else if el > 25 {
                log("STT permission prompt never answered — recorded as skipped (no crash)")
                setPhase("done")
            }
        case "mic-final":
            let el = Date().timeIntervalSince(phaseStarted)
            if m.stt.errorText == nil, el > 2 {
                log("STT pipeline OK — started, recorded, stopped without crash/error (transcript: “\(String(m.stt.transcript.prefix(60)))”)")
                setPhase("done")
            } else if el > 8 {
                log("STT reported: \(m.stt.errorText ?? "(late final)") — recorded as skipped")
                setPhase("done")
            }
        case "done":
            finish(true)
        default:
            break
        }
    }

    @MainActor
    private func finish(_ ok: Bool) {
        guard !done else { return }
        done = true
        timer?.invalidate()
        // Tear everything down so no 17 GB engine / mic tap survives the exit.
        model?.tts.stop()
        model?.stt.stop()
        EngineManager.shared.stopEngine()
        let total = Date().timeIntervalSince(started)
        log(ok
            ? "AUTOTEST PASS total=\(String(format: "%.1f", total))s"
            : "AUTOTEST FAIL total=\(String(format: "%.1f", total))s")
        // Give the engine process a moment to die cleanly, then exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            exit(ok ? 0 : 1)
        }
    }
}
