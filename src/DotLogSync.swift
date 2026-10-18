import Foundation

/// Publishes this Dot's logs and health snapshot to its own folder on GitHub
/// (dots/<DOT_ID>/ in the Dot repo), so every Dot's activity, failures and
/// "calls for help" are visible to the owner, other Dots and the maintainer —
/// without bundling any credential and without depending on a git installation.
///
/// The token is read from `~/Library/Application Support/Dot/github.token`
/// (permissions 0600, created by the owner). When it is absent the sync stays
/// silent except for one log line, so a stock install never fails because of it.
final class DotLogSync: @unchecked Sendable {
    static let shared = DotLogSync()

    private let apiBase = URL(string: "https://api.github.com/repos/Emin-dev/Dot/contents/")!
    private let repo = "Emin-dev/Dot"
    private let queue = DispatchQueue(label: "app.dot.log-sync", qos: .utility)
    private var running = false
    private var lastPushAt: Double = 0
    private var lastLogHash: Int?
    private var lastHealthHash: Int?
    private var pushedOnce = false

    private var dotID: String {
        let name = Host.current().localizedName ?? "dot"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 8))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        // One clean slug: letters, digits and hyphens only, so the folder name is
        // always a valid, stable path on GitHub (commas and spaces in hw.model
        // otherwise leak into the id).
        let slug: (String) -> String = { value in
            let folded = value.lowercased()
            var result = ""
            var lastDash = true
            for scalar in folded.unicodeScalars {
                let v = scalar.value
                if (48...57).contains(v) || (97...122).contains(v) || scalar == "-" {
                    result.unicodeScalars.append(scalar); lastDash = (scalar == "-")
                } else if !lastDash {
                    result.unicodeScalars.append("-"); lastDash = true
                }
            }
            return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let cleaned = slug(name)
        let modelName = slug(String(cString: model))
        return "\(cleaned)-\(modelName)"
    }

    private var supportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dot", isDirectory: true)
    }

    private var token: String? {
        guard let url = supportDirectory?.appendingPathComponent("github.token"),
              let value = try? String(contentsOf: url, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Called once at launch and then by the periodic loop; requests are throttled
    /// so a burst of health transitions cannot hammer the API.
    func requestSync(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPushAt >= 25 else { return }
        queue.async { [weak self] in self?.syncNow(reason: reason) }
    }

    func start() {
        queue.async { [weak self] in
            while let self {
                self.syncNow(reason: "periodic")
                Thread.sleep(forTimeInterval: 300)
            }
        }
    }

    private func syncNow(reason: String) {
        guard !running else { return }
        guard let token else {
            if !pushedOnce {
                DiagnosticChatLogger.record(role: "system",
                    text: "[SYNC] no github.token in Application Support/Dot — publishing skipped")
                pushedOnce = true
            }
            return
        }
        running = true
        defer { running = false }
        lastPushAt = ProcessInfo.processInfo.systemUptime

        guard let support = supportDirectory else { return }
        let logs = support.appendingPathComponent("Logs", isDirectory: true)
        let logFile = logs.appendingPathComponent("dot_chat_log.txt")
        let healthFile = support.appendingPathComponent("dot-health.json")

        var uploaded = 0
        if let data = try? Data(contentsOf: logFile) {
            let hash = data.hashValue
            if hash != lastLogHash, upload(data: data, path: "dots/\(dotID)/logs/dot_chat_log.txt", token: token, message: "\(dotID): \(reason)") {
                lastLogHash = hash; uploaded += 1
            }
        }
        if let data = try? Data(contentsOf: healthFile) {
            let hash = data.hashValue
            if hash != lastHealthHash, upload(data: data, path: "dots/\(dotID)/dot-health.json", token: token, message: "\(dotID): \(reason)") {
                lastHealthHash = hash; uploaded += 1
            }
        }
        if uploaded > 0 {
            DiagnosticChatLogger.record(role: "system", text: "[SYNC] pushed \(uploaded) file(s) to \(repo) dots/\(dotID) (\(reason))")
            pushedOnce = true
        }
    }

    /// PUT one file through the Contents API: fetch the current blob sha (404 means
    /// new), then create-or-update with base64 content. Bounded and honest.
    private func upload(data: Data, path: String, token: String, message: String) -> Bool {
        let url = apiBase.appendingPathComponent(path)
        var sha: String?
        var getRequest = URLRequest(url: url)
        getRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        getRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        getRequest.timeoutInterval = 15
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        URLSession.shared.dataTask(with: getRequest) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 200, let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sha = object["sha"] as? String
            }
        }.resume()
        semaphore.wait()

        var putRequest = URLRequest(url: url)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        putRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        putRequest.timeoutInterval = 20
        var body: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        if let sha { body["sha"] = sha }
        putRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: putRequest) { _, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            success = (200...201).contains(http.statusCode)
        }.resume()
        semaphore.wait()
        return success
    }
}
