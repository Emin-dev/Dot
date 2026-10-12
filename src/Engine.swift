import Foundation
import AppKit
import Darwin

/// Owns the local inference backend:
///  1. External OpenAI-compatible endpoint (DOT_LLM_URL / UserDefaults llmUrl) — e.g. Bionic + Splash.
///  2. Otherwise: supervised llama-server (Metal) found in LM Studio's bundled backends / Homebrew / PATH.
///
/// Qwen3.8-27B tuned for speed + quality (per the Qwen3.8 field guide):
///  - reasoning_effort "low" (template default is xhigh — minutes burned on trivial asks)
///  - sampling: thinking on  1.0 / 0.95 · thinking off 0.7 / 0.80
///  - stable, short system prompt → KV prefix reuse keeps prefill near-free
///  - streaming SSE so first token lands instantly
final class EngineManager: NSObject, ObservableObject {
    static let shared = EngineManager()

    @Published var phase: EnginePhase = .idle
    @Published var source: EngineSource?
    @Published var lastLog: String = ""
    @Published var loadedModel: String = ""
    /// 0..1 while the llama-server binary itself is being fetched (first run on machines
    /// without LM Studio / Homebrew llama.cpp). nil when not fetching.
    @Published var engineFetch: Double?

    // MARK: - Endpoints

    var baseURL: URL? {
        if let s = UserDefaults.standard.string(forKey: "llmUrl"), !s.isEmpty,
           let u = URL(string: s), u.host == "127.0.0.1" || u.host == "localhost" {
            return u
        }
        if let s = ProcessInfo.processInfo.environment["DOT_LLM_URL"], !s.isEmpty,
           let u = URL(string: s), u.host == "127.0.0.1" || u.host == "localhost" {
            return u
        }
        return nil
    }

    let port: UInt16 = 8642
    var localURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    // MARK: - Model

    private var modelsDir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dot").appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var modelFile: URL { modelsDir.appendingPathComponent(modelFileRelPath) }
    private let modelFileRelPath = "Qwen3.8-27B-Uncensored-Q4_K_M.gguf"
    private let modelDownloadURL = URL(string:
        "https://huggingface.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF/resolve/main/Qwen3.8-27B-Uncensored-Q4_K_M.gguf?download=true")!
    private let expectedModelBytes: Int64 = 16_810_714_528   // Q4_K_M

    // MARK: - Engine process

    private var proc: Process?
    private var stderrPipe: Pipe?
    private var stderrBuf = ""
    private var healthTimer: Timer?
    private var activeDownloader: ModelDownloader?
    private var chatTask: Task<Void, Never>?
    private var adopted = false   // a server we did not start (but we own the port contract with)

    private var engineDir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dot").appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // llama-server candidates, most specific first:
    // ours (auto-downloaded) → LM Studio bundled backends → Homebrew → PATH.
    private func findLlamaServer() -> URL? {
        let ours = engineDir.appendingPathComponent("llama-server")
        if FileManager.default.isExecutableFile(atPath: ours.path) { return ours }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let extBase = home.appendingPathComponent(".lmstudio/extensions/backends")
        var localCandidates: [URL] = []
        if let items = try? FileManager.default.contentsOfDirectory(
            at: extBase, includingPropertiesForKeys: nil) {
            let lmc = items
                .filter { $0.lastPathComponent.hasPrefix("llama.cpp-mac-arm64") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            localCandidates = lmc.map { $0.appendingPathComponent("llama-server") }
        }
        let others = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            "/usr/bin/llama-server",
        ].compactMap(URL.init(string:))
        for url in localCandidates + others {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let inPath = PATHFind("llama-server") { return inPath }
        return nil
    }

    private func PATHFind(_ name: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let u = URL(string: String(dir))?.appendingPathComponent(name)
            if let u, FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    // MARK: - Bootstrap

    func bootstrap() {
        if case .ready = phase { return }
        if case .idle = phase {} else if case .checking = phase { return }
        if case .downloading = phase { return }
        phase = .checking
        lastLog = ""

        if let ext = baseURL {
            probeExternal(ext)
            return
        }
        if findLlamaServer() == nil {
            fetchEngineBinary { [weak self] ok in
                guard let self else { return }
                self.engineFetch = nil
                if !ok {
                    self.fail("Couldn't fetch the llama.cpp engine (needs internet). Check connection and retry.")
                    return
                }
                self.afterEngineReady()
            }
            return
        }
        afterEngineReady()
    }

    private func afterEngineReady() {
        if FileManager.default.fileSize(atPath: modelFile.path) == expectedModelBytes {
            adoptExistingOrStart()
        } else {
            startDownload()
        }
    }

    /// A healthy llama-server already on our port (left over from a previous
    /// launch) is adopted instead of failing to bind — instant "ready".
    private func adoptExistingOrStart() {
        var req = URLRequest(url: localURL.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                if (200...299).contains(status) {
                    var mreq = URLRequest(url: self.localURL.appendingPathComponent("v1/models"))
                    mreq.timeoutInterval = 1.5
                    URLSession.shared.dataTask(with: mreq) { d, _, _ in
                        DispatchQueue.main.async {
                            var id = "qwen3.8-27b"
                            if let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                               let arr = obj["data"] as? [[String: Any]],
                               let first = arr.first?["id"] as? String { id = first }
                            // Only adopt Qwen — a foreign server means the port is taken.
                            if id.lowercased().contains("qwen") {
                                self.loadedModel = id
                                self.source = .llamaServer
                                self.adopted = true
                                self.phase = .ready
                                self.lastLog = "Reusing the engine already running on port \(self.port)"
                                return
                            }
                            self.startEngine()
                        }
                    }.resume()
                    return
                }
                self.startEngine()
            }
        }.resume()
    }

    // Pinned engine build. llama.cpp ships every *binary* release as a prerelease
    // (b11564) with .tar.gz assets, and "releases/latest" points at v0.6.0 which
    // contains NO binaries — so a "latest" lookup silently finds nothing. b11564 is
    // verified to accept every flag the app uses (--jinja, --flash-attn on,
    // --reasoning-format deepseek, --cache-reuse, --no-webui, --alias, …).
    static let engineBuild = "b11564"

    /// Self-contained fallback: pulls the official llama.cpp release binary into
    /// ~/.dot/bin so the app works on ANY Apple Silicon Mac with zero prerequisites.
    private func fetchEngineBinary(_ done: @escaping (Bool) -> Void) {
        lastLog = "Fetching llama.cpp engine…"
        let suffix = Self.machineArch() == "arm64" ? "macos-arm64" : "macos-x64"
        let tag = Self.engineBuild
        let name = "llama-\(tag)-bin-\(suffix).tar.gz"
        // Direct release-asset URL (302 → GitHub release CDN): no API call, no rate limits.
        guard let url = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/\(name)") else {
            DispatchQueue.main.async { done(false) }
            return
        }
        let expected: Int64 = suffix == "macos-arm64" ? 12_105_541 : 11_597_000
        let archive = engineDir.appendingPathComponent("llama-server.tar.gz")
        let downloader = ModelDownloader(
            url: url,
            destination: archive,
            expectedSize: expected,
            existingBytes: FileManager.default.fileSize(atPath: archive.path)
        )
        downloader.onProgress = { [weak self] f in self?.engineFetch = f }
        downloader.onFinished = { [weak self] ok in
            guard let self else { return }
            if ok { self.extractEngine(done: done) } else { done(false) }
        }
        activeDownloader = downloader
        downloader.start()
    }

    private func extractEngine(done: @escaping (Bool) -> Void) {
        let archive = engineDir.appendingPathComponent("llama-server.tar.gz")
        let staging = engineDir.appendingPathComponent(".staging-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { done(false); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["xzf", archive.path, "-C", staging.path]
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                // The tarball unpacks into a single top-level dir (llama-b11564/);
                // flatten it so ~/.dot/bin/llama-server is the stable discovery path.
                if proc.terminationStatus == 0,
                   let top = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil),
                   let inner = top.first {
                    for item in (try? FileManager.default.contentsOfDirectory(at: inner, includingPropertiesForKeys: nil)) ?? [] {
                        let dest = self.engineDir.appendingPathComponent(item.lastPathComponent)
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.moveItem(at: item, to: dest)
                    }
                }
                try? FileManager.default.removeItem(at: staging)
                let bin = self.engineDir.appendingPathComponent("llama-server")
                if proc.terminationStatus == 0,
                   FileManager.default.isExecutableFile(atPath: bin.path) {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
                    try? FileManager.default.removeItem(at: archive)
                    self.lastLog = "Engine ready (llama.cpp \(Self.engineBuild))"
                    done(true)
                } else {
                    done(false)  // keep archive: ModelDownloader resumes next attempt
                }
            }
        }
        do { try p.run() } catch { done(false) }
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machines = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        return machines
    }

    private func probeExternal(_ base: URL) {
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if (200...299).contains(status), let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = obj["data"] as? [[String: Any]],
                   let id = arr.first?["id"] as? String {
                    self.source = .external(base.absoluteString)
                    self.loadedModel = id
                    self.phase = .ready
                    self.lastLog = "Using external engine (\(base.absoluteString))"
                } else {
                    self.fail("Engine at \(base.absoluteString) is not answering /v1/models — start it (e.g. Bionic with Splash) or unset DOT_LLM_URL.")
                }
            }
        }.resume()
    }

    private func fail(_ msg: String) {
        phase = .failed(msg)
        lastLog = msg
    }

    // MARK: - Model download (resumable)

    private func startDownload() {
        phase = .downloading(0)
        lastLog = "Downloading Qwen3.8-27B (16.8 GB, Q4_K_M)…"
        let existing = FileManager.default.fileSize(atPath: modelFile.path)
        if existing >= expectedModelBytes { startEngine(); return }

        let downloader = ModelDownloader(
            url: modelDownloadURL,
            destination: modelFile,
            expectedSize: expectedModelBytes,
            existingBytes: existing
        )
        downloader.onProgress = { [weak self] frac in
            self?.phase = .downloading(frac)
        }
        downloader.onFinished = { [weak self] ok in
            guard let self else { return }
            self.activeDownloader = nil
            if ok {
                self.startEngine()
            } else {
                self.phase = .failed("Model download failed — check connection, re-open the app to resume where it left off.")
            }
        }
        activeDownloader = downloader
        downloader.start()
    }

    // MARK: - llama-server supervision

    private func startEngine() {
        phase = .starting
        lastLog = "Starting llama-server (Metal)…"
        guard let bin = findLlamaServer() else {
            fail("llama-server binary disappeared."); return
        }
        stopProcess()

        let p = Process()
        p.executableURL = bin
        // Optimized for a 27B dense model on Apple silicon:
        //  -jinja: native Qwen3.8 template (correct thinking control)
        //  full offload + 32K ctx + q8_0 KV + flash attention + KV prefix reuse
        //  --cache-reuse: warm prefix across requests (stable system prompt)
        //  --reasoning-format: splits  thinking into reasoning_content
        p.arguments = [
            "-m", modelFile.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--alias", "qwen3.8-27b",
            "--jinja",
            "--n-gpu-layers", "999",
            "--ctx-size", "32768",
            "--cache-type-k", "q8_0",
            "--cache-type-v", "q8_0",
            "--cache-reuse", "4096",
            "--flash-attn", "on",
            "--reasoning-format", "deepseek",
            "--no-webui",
        ]
        p.currentDirectoryURL = modelsDir

        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        stderrPipe = pipe
        stderrBuf = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            let s = String(data: d, encoding: .utf8) ?? ""
            self?.ingestStderr(s)
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.proc === proc else { return }
                self.proc = nil
                self.healthTimer?.invalidate()
                if case .ready = self.phase {
                    self.fail("Engine process exited unexpectedly — press Retry.")
                }
            }
        }
        do {
            try p.run()
        } catch {
            fail("Could not start engine: \(error.localizedDescription)")
            return
        }
        proc = p
        source = .llamaServer

        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { return }
            if let p = self.proc, p.isRunning {
                self.pollHealth(deadline: Date().addingTimeInterval(240))
            } else {
                t.invalidate()
                if case .starting = self.phase {
                    self.fail("Engine exited before becoming ready. \(self.lastLog)")
                }
            }
        }
    }

    private var lastStderrPublish = Date.distantPast
    private func ingestStderr(_ s: String) {
        stderrBuf += s
        // Surface the most useful recent line (throttled: load is chatty and
        // this publishes UI state).
        let lines = stderrBuf.split(separator: "\n").map(String.init)
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty,
           Date().timeIntervalSince(lastStderrPublish) > 0.12 {
            lastStderrPublish = Date()
            let compact = last
                .replacingOccurrences(of: "llama_server_context: ", with: "")
                .replacingOccurrences(of: "load_all_data: ", with: "")
            DispatchQueue.main.async { self.lastLog = String(compact.prefix(140)) }
        }
        if stderrBuf.count > 16_384 { stderrBuf = String(stderrBuf.suffix(8_192)) }
    }

    private func pollHealth(deadline: Date) {
        var req = URLRequest(url: localURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                self.healthTimer?.invalidate()
                // discover model id
                var mreq = URLRequest(url: self.localURL.appendingPathComponent("v1/models"))
                mreq.timeoutInterval = 2
                URLSession.shared.dataTask(with: mreq) { d, _, _ in
                    var id = "qwen3.8-27b"
                    if let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let arr = obj["data"] as? [[String: Any]],
                       let first = arr.first?["id"] as? String { id = first }
                    DispatchQueue.main.async {
                        self.loadedModel = id
                        self.phase = .ready
                        self.lastLog = "Qwen3.8-27B ready · Metal · 32K ctx · KV q8_0 · prefix reuse"
                    }
                }.resume()
            } else if Date() < deadline {
                // keep polling
            } else {
                self.healthTimer?.invalidate()
                self.fail("Engine not healthy after load. \(self.lastLog)")
            }
        }.resume()
    }

    func stopEngine() {
        stopProcess()
        // An adopted (pre-existing) server must also die, or it orphans 17 GB of RAM.
        // Our port is app-private, so the pattern is precise.
        if adopted || (proc != nil) == false {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", "llama-server.*--port \(port)"]
            do { try p.run() } catch {}
        }
        adopted = false
    }

    private func stopProcess() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = proc, p.isRunning {
            p.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { p.terminate() }
            }
        }
        proc = nil
    }

    func retry() {
        if case .failed = phase { bootstrap() }
    }

    // MARK: - Chat (OpenAI-compatible, SSE)

    /// System prompt is short + constant so llama-server's --cache-reuse KV window
    /// keeps the prefix warm (Splash-style prefix caching semantics on llama.cpp).
    static let systemPrompt =
        "You are Dot, a private assistant running fully on the user's Mac (Qwen3.8-27B, local, nothing leaves this machine). " +
        "Be direct and concise. One task at a time, no preamble. Use markdown only when it helps."

    private static let maxHistoryChars = 18_000   // keeps decode fast (32K ctx budget)

    private func buildBody(history: [ChatMessage], userText: String, thinking: Bool) -> Data {
        var msgs: [[String: Any]] = [["role": "system", "content": Self.systemPrompt]]

        // Trim from the back: keep the most recent messages that fit the budget.
        var budget = Self.maxHistoryChars
        var tail: [ChatMessage] = []
        for m in history.reversed() where m.role != .system {
            let cost = m.content.count + m.thinking.count
            if budget - cost < 0 && !tail.isEmpty { break }
            budget -= max(cost, 0)
            tail.append(m)
        }
        for m in tail.reversed() {
            msgs.append(["role": m.role.rawValue, "content": m.content])
        }
        msgs.append(["role": "user", "content": userText])

        var body: [String: Any] = [
            "model": loadedModel.isEmpty ? "qwen3.8-27b" : loadedModel,
            "messages": msgs,
            "stream": true,
            "max_tokens": 4096,
            // Field-guide sampling: thinking 1.0/0.95 · instruct 0.7/0.80
            "temperature": thinking ? 1.0 : 0.7,
            "top_p": thinking ? 0.95 : 0.80,
        ]
        // Qwen3.8 template: enable_thinking on/off + reasoning_effort low|medium|xhigh
        // (xhigh is the template default — pin "low" for speed, or disable entirely).
        var kwargs: [String: Any] = ["enable_thinking": thinking]
        if thinking { kwargs["reasoning_effort"] = "low" }
        body["chat_template_kwargs"] = kwargs

        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Streams one turn. onDelta(reasoning, content) on the main queue.
    /// Uses URLSession.bytes — true token streaming, first token lands fast.
    @discardableResult
    func chat(history: [ChatMessage], userText: String, thinking: Bool,
              onDelta: @escaping (_ thinking: String?, _ content: String?) -> Void,
              onDone: @escaping (Bool) -> Void) -> Task<Void, Never>? {
        let isExternal = source?.isExternal ?? false
        let url = isExternal ? (baseURL ?? localURL) : localURL
        var req = URLRequest(url: url.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = buildBody(history: history, userText: userText, thinking: thinking)

        final class StreamBox { var breakLoop = false }
        let box = StreamBox()
        let task = Task { [weak self] in
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200...299).contains(status) {
                    onDone(false)
                    return
                }
                var gotAnything = false
                for try await line in bytes.lines {
                    // This SDK's AsyncBytes has no cancel() — bail out of the loop
                    // the moment the Task is cancelled (per-token latency < 100 ms).
                    if box.breakLoop || Task.isCancelled { box.breakLoop = true; break }
                    let s = line.trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix("data:") else { continue }
                    let payload = s.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let d = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let choices = obj["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any] else { continue }
                    // UI state is mutated in these callbacks — hop to main.
                    if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                        gotAnything = true
                        let rr = r
                        DispatchQueue.main.async { onDelta(rr, nil) }
                    }
                    if let c = delta["content"] as? String, !c.isEmpty {
                        gotAnything = true
                        let cc = c
                        DispatchQueue.main.async { onDelta(nil, cc) }
                    }
                }
                if gotAnything { onDone(true) } else { onDone(false) }
            } catch is CancellationError {
                box.breakLoop = true
                onDone(true)            // user hit stop — treat as completed
            } catch let e as URLError where e.code == .cancelled {
                box.breakLoop = true
                onDone(true)
            } catch {
                onDone(false)
            }
            self?.chatTask = nil
        }
        chatTask = task
        return task
    }

    func cancelChat() {
        chatTask?.cancel()
        chatTask = nil
    }
}

extension EngineManager {
    func isExternal() -> Bool {
        if case .external = source { return true }
        return false
    }
}

extension EngineSource {
    var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

extension FileManager {
    func fileSize(atPath path: String) -> Int64 {
        (try? attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }
}

// MARK: - Resumable model downloader (streams straight to disk; Range-resume on relaunch)

final class ModelDownloader: NSObject {
    var onProgress: ((Double) -> Void)?
    var onFinished: ((Bool) -> Void)?

    private let url: URL
    private let destination: URL
    private let expectedSize: Int64
    private let chunkSize: Int64 = 64 * 1024 * 1024
    private var written: Int64
    private var task: Task<Void, Never>?

    init(url: URL, destination: URL, expectedSize: Int64, existingBytes: Int64) {
        self.url = url
        self.destination = destination
        self.expectedSize = expectedSize
        self.written = existingBytes
    }

    /// Sequential Range chunks → direct FileHandle writes (bounded RAM, resumable).
    func start() {
        guard written < expectedSize else {
            finish(ok: true); return
        }
        // FileHandle(forWritingTo:) requires the file to exist.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.createFile(atPath: destination.path, contents: Data())
        }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        let fm = FileManager.default
        do {
            var offset = written
            var fh = try FileHandle(forWritingTo: destination)
            defer { fh.closeFile() }

            while offset < expectedSize {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, expectedSize) - 1
                var req = URLRequest(url: url)
                req.timeoutInterval = 300
                req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    throw URLError(.badServerResponse)
                }
                if status == 200, offset > 0 {
                    // Server ignored Range — full file returned; rewrite from zero.
                    try fm.removeItem(at: destination)
                    fh.closeFile()
                    fh = try FileHandle(forWritingTo: destination)
                    offset = 0
                }
                fh.seek(toFileOffset: UInt64(offset))
                fh.write(data)
                offset += Int64(data.count)
                written = offset
                let frac = min(1.0, Double(written) / Double(expectedSize))
                DispatchQueue.main.async { self.onProgress?(frac) }
            }
            finish(ok: true)
        } catch {
            finish(ok: false)
        }
    }

    func cancel() {
        task?.cancel()
        finish(ok: false)
    }

    private func finish(ok: Bool) {
        task = nil
        let complete = FileManager.default.fileSize(atPath: destination.path) >= expectedSize
        DispatchQueue.main.async { self.onFinished?(ok && complete) }
    }
}
