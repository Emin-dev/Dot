import Foundation
import Combine

/// Direct Splash HTTP only. No launcher, downloader, shell, generic proxy, or fallback engine.
/// These are consistency checks of the local server's reported identity, not attestation.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum EngineError: LocalizedError, Equatable {
    case configuration, unavailable, identity, response, empty
    var errorDescription: String? {
        switch self {
        case .configuration: return "Splash needs its local address and exact loaded model. Open Connection from my menu."
        case .unavailable: return "Splash isn't ready. Start your local Splash server, then click me again."
        case .identity: return "This server hasn't verified the expected Splash model. Check Connection."
        case .response: return "Splash stopped answering. Click me to try again."
        case .empty: return "Splash sent no answer. Click me to try again."
        }
    }
}

@MainActor
final class EngineManager: ObservableObject {
    private let delegate = NoRedirects()
    private let configuredEndpoint: String?
    private let configuredModel: String?
    private let protocolClasses: [AnyClass]?
    init(endpoint: String? = nil, model: String? = nil, protocolClasses: [AnyClass]? = nil) {
        configuredEndpoint = endpoint; configuredModel = model; self.protocolClasses = protocolClasses
    }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.connectionProxyDictionary = [:]
        configuration.protocolClasses = protocolClasses
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    var endpoint: String {
        get { configuredEndpoint ?? UserDefaults.standard.string(forKey: "splashURL") ?? ProcessInfo.processInfo.environment["DOT_SPLASH_URL"] ?? "http://127.0.0.1:8000" }
        set { UserDefaults.standard.set(newValue, forKey: "splashURL") }
    }
    var expectedModel: String {
        get { configuredModel ?? UserDefaults.standard.string(forKey: "splashModel") ?? ProcessInfo.processInfo.environment["DOT_SPLASH_MODEL"] ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "splashModel") }
    }

    func verifyConnection() async throws -> (URL, String) {
        guard let base = LocalEndpoint.validate(endpoint), !expectedModel.isEmpty else { throw EngineError.configuration }
        let model = expectedModel
        var request = URLRequest(url: base.appendingPathComponent("status"))
        request.timeoutInterval = 4
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { try Task.checkCancellation(); throw EngineError.unavailable }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let identity = try? JSONDecoder().decode(SplashIdentity.self, from: data),
              identity.matches(model: model, port: base.port ?? 0, server: http.value(forHTTPHeaderField: "Server")) else {
            throw EngineError.identity
        }
        return (base, model)
    }

    func chat(history: [ChatMessage], onDelta: @escaping @MainActor (String) -> Void,
              onReasoning: @escaping @MainActor () -> Void = {}) async throws {
        let (base, model) = try await verifyConnection()
        try Task.checkCancellation()
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let messages: [[String: String]] = [["role": "system", "content": "You are Dot, a warm concise English-speaking companion. Give short natural spoken answers. Do not use markdown, emoji, or lengthy preambles."]] + history.suffix(12).map { ["role": $0.role, "content": String($0.content.prefix(6000))] }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, "stream": true, "max_completion_tokens": 1536, "reasoning_effort": "low",
            "temperature": 0.7, "top_p": 0.8,
            "chat_template_kwargs": ["enable_thinking": true, "reasoning_effort": "low"]
        ])
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Server") == "Splash" else { throw EngineError.response }
        var hasContent = false
        var sawDone = false
        var sawReasoning = false
        let updates = StreamDelivery(onDelta: onDelta)
        defer { updates.cancel() }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let delta = StreamDelta.parse(line) else { continue }
            if delta.done {
                updates.finish()
                sawDone = true; break
            }
            if !delta.reasoning.isEmpty && !sawReasoning { sawReasoning = true; onReasoning() }
            if !delta.content.isEmpty {
                hasContent = true
                updates.feed(delta.content)
            }
        }
        try Task.checkCancellation()
        guard sawDone else { throw EngineError.response }
        if !hasContent { throw EngineError.empty }
    }

    func shutdown() {
        session.invalidateAndCancel()
        // Borrowed Splash stays running. Dot creates no inference processes.
    }
}

/// Keeps a trailing streamed sentence responsive even when the server pauses.
@MainActor
final class StreamDelivery {
    private var buffer = StreamUpdateBuffer()
    private var deadline: Task<Void, Never>?
    private var closed = false
    private let onDelta: @MainActor (String) -> Void
    init(onDelta: @escaping @MainActor (String) -> Void) { self.onDelta = onDelta }
    func feed(_ content: String) {
        guard !closed else { return }
        if let batch = buffer.feed(content, now: ProcessInfo.processInfo.systemUptime) {
            deadline?.cancel(); deadline = nil; onDelta(batch)
        } else if deadline == nil {
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.deadline = nil
                if let tail = self.buffer.flush() { self.onDelta(tail) }
            }
        }
    }
    func finish() {
        guard !closed else { return }
        deadline?.cancel(); deadline = nil; closed = true
        if let tail = buffer.flush() { onDelta(tail) }
    }
    func cancel() {
        deadline?.cancel(); deadline = nil; closed = true; buffer = StreamUpdateBuffer()
    }
}
