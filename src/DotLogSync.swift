import Foundation
import Security

/// Publishes this Dot's text logs to the dedicated `dot-logs` branch of
/// `Emin-dev/Dot` under `dot/<install-id>/<launch-timestamp>/`.
///
/// - No images, audio, microphone data or screenshots are uploaded.
/// - The conversation log is text only; secrets are masked by `LogRedaction`.
/// - The credential is read from Keychain service `dot-github-token` (stored by
///   the owner with `scripts/store_github_token.sh`) and falls back to the
///   owner-created `Application Support/Dot/github.token` file.
/// - Uploads survive restarts and offline periods through a bounded queue with
///   exponential backoff. Nothing is written to `main`; CI and code stay safe.
final class DotLogSync: @unchecked Sendable {
    static let shared = DotLogSync()
    static let keychainService = "dot-github-token"

    private let repository = LogSyncPolicy.repository
    private let branch = LogSyncPolicy.branch
    private let workQueue = DispatchQueue(label: "app.dot.log-sync", qos: .utility)
    private let fileManager = FileManager.default
    private let launchDate = Date()
    private let stateLock = NSLock()
    private var started = false
    private var running = false
    private var lastRequestAt: Double = 0
    private var lastNotice: String?
    private var pushedOnce = false
    private var branchReady = false
    private var branchNextAttempt: Double = 0
    private var metadataQueued = false
    private var prunedOnce = false
    private var lastKeychainStatus: OSStatus?
    private lazy var installID = loadOrCreateInstallID()
    private lazy var launchFolder = LogSyncPolicy.folder(installID: installID, launch: launchDate)
    private lazy var launchStamp = LogSyncPolicy.launchStamp(for: launchDate)

    private var supportDirectory: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dot", isDirectory: true)
    }
    private var logsDirectory: URL? {
        supportDirectory?.appendingPathComponent("Logs", isDirectory: true)
    }
    private var queueDirectory: URL? {
        logsDirectory?.appendingPathComponent("UploadQueue", isDirectory: true)
    }
    private var queueFile: URL? {
        logsDirectory?.appendingPathComponent("upload-queue.json")
    }
    /// Uploader diagnostics stay local and are never fed back into an uploaded
    /// file, which would otherwise reset the retry budget forever.
    private var syncLogURL: URL? {
        logsDirectory?.appendingPathComponent("dot-sync.log")
    }

    /// Called once at launch. The loop stays offline-safe: a failed attempt only
    /// advances the persisted backoff.
    func start() {
        guard !DiagnosticChatLogger.isRunningTests
                || ProcessInfo.processInfo.environment["DOT_LOG_SYNC_TESTS"] == "1" else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started else { return }
        started = true
        workQueue.async { [weak self] in
            guard let self else { return }
            self.createPrivateDirectory()
            self.recordStartup()
            self.syncNow()
            self.schedulePeriodicSync()
        }
    }

    /// Reschedule instead of sleeping on the serial queue: a long `Thread.sleep`
    /// here would block every `requestSync` for the process lifetime.
    private func schedulePeriodicSync() {
        workQueue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.started else { return }
            self.syncNow()
            self.schedulePeriodicSync()
        }
    }

    /// Called by health transitions. Throttled on the serial upload queue so a
    /// burst cannot hammer the API and `lastRequestAt` stays race-free.
    func requestSync(reason: String) {
        guard !DiagnosticChatLogger.isRunningTests
                || ProcessInfo.processInfo.environment["DOT_LOG_SYNC_TESTS"] == "1" else { return }
        workQueue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastRequestAt >= 20 else { return }
            self.lastRequestAt = now
            self.syncNow()
        }
    }

    private func recordStartup() {
        let configured = token() != nil
        DiagnosticChatLogger.record(
            role: "system",
            text: "[SYNC] log uploader started; token \(configured ? "configured" : "absent (see docs/QUESTIONS_FOR_EMIN.md)")")
        syncLog("[SYNC] launch folder \(launchFolder), branch \(branch), token \(configured ? "present" : "absent")")
    }

    // MARK: - Sync

    private func syncNow() {
        guard !running else { return }
        running = true
        defer { running = false }

        guard let token = token() else {
            notice("no-log-token",
                   "[SYNC] log upload is waiting for the owner's GitHub token in Keychain service \(Self.keychainService)")
            return
        }
        guard supportDirectory != nil, logsDirectory != nil else { return }
        createPrivateDirectory()
        pruneSnapshotsIfNeeded()

        writeMetadataIfNeeded()
        enqueueCurrentFiles()
        flush(token: token)
    }

    private func createPrivateDirectory() {
        guard let logs = logsDirectory, let queue = queueDirectory else { return }
        try? fileManager.createDirectory(at: logs, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try? fileManager.createDirectory(at: queue, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
    }

    private func writeMetadataIfNeeded() {
        guard !metadataQueued, let queue = queueDirectory else { return }
        metadataQueued = true
        let hardware = HardwareCompatibility.queryCurrent()
        let metadata: [String: Any] = [
            "schema_version": 1,
            "install_id": installID,
            "launch_timestamp_utc": launchStamp,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "chip": hardware.chip,
            "memory_gb": hardware.ramGB,
            "log_format": "text: [ISO-8601] [ROLE] message",
            "privacy": "text only; no images, audio, screenshots, keys, tokens or passwords",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: metadata,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let snapshot = queue.appendingPathComponent("\(launchStamp)-meta.json")
        try? data.write(to: snapshot, options: .atomic)
        enqueue(local: snapshot, remote: LogSyncPolicy.remotePath(folder: launchFolder, file: "meta.json"),
                now: Date().timeIntervalSince1970)
    }

    private func enqueueCurrentFiles() {
        guard let logs = logsDirectory, let queue = queueDirectory else { return }
        var sources: [(String, URL)] = [
            ("dot_chat_log.txt", logs.appendingPathComponent("dot_chat_log.txt")),
            ("dot_chat_log.1.txt", logs.appendingPathComponent("dot_chat_log.1.txt")),
        ]
        if let support = supportDirectory {
            sources.append(("dot-health.json", support.appendingPathComponent("dot-health.json")))
        }
        for (name, source) in sources {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: source.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= LogSyncPolicy.maximumFileBytes else { continue }
            let snapshot = queue.appendingPathComponent("\(launchStamp)-\(name)")
            let sourceModified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            let snapshotAttributes = try? fileManager.attributesOfItem(atPath: snapshot.path)
            let snapshotModified = (snapshotAttributes?[.modificationDate] as? Date) ?? .distantPast
            let snapshotSize = (snapshotAttributes?[.size] as? NSNumber)?.intValue ?? -1
            // Copy and enqueue only when the source actually changed. Keeping the
            // snapshot after a successful upload prevents an upload loop. The copy
            // is staged first so a failed copy never destroys the last snapshot.
            guard snapshotSize != size || sourceModified > snapshotModified else { continue }
            let staged = snapshot.appendingPathExtension("tmp")
            try? fileManager.removeItem(at: staged)
            do {
                try fileManager.copyItem(at: source, to: staged)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
                try? fileManager.removeItem(at: snapshot)
                try fileManager.moveItem(at: staged, to: snapshot)
            } catch {
                try? fileManager.removeItem(at: staged)
                syncLog("[SYNC] could not stage \(name) for upload; the previous snapshot is kept")
                continue
            }
            enqueue(local: snapshot, remote: LogSyncPolicy.remotePath(folder: launchFolder, file: name),
                    now: Date().timeIntervalSince1970)
        }
    }

    private func enqueue(local: URL, remote: String, now: Double) {
        var state = readQueue()
        if !state.entries.contains(where: { $0.remotePath == remote }),
           state.entries.count >= LogSyncPolicy.maximumQueueEntries,
           let oldest = state.entries.first {
            try? fileManager.removeItem(atPath: oldest.localPath)
        }
        state.enqueue(localPath: local.path, remotePath: remote, now: now)
        writeQueue(state)
    }

    private func flush(token: String) {
        guard ensureBranch(token: token) else {
            notice("no-branch", "[SYNC] could not reach the \(branch) logs branch; uploads stay queued")
            return
        }
        var state = readQueue()
        let now = Date().timeIntervalSince1970
        var changed = false
        for entry in state.due(now: now) {
            let file = URL(fileURLWithPath: entry.localPath)
            guard fileManager.fileExists(atPath: file.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > 0, size <= LogSyncPolicy.maximumFileBytes,
                  let data = try? Data(contentsOf: file) else {
                state.remove(remotePath: entry.remotePath)
                changed = true
                continue
            }
            if upload(data: data, remotePath: entry.remotePath, token: token) {
                state.remove(remotePath: entry.remotePath)
                changed = true
                if !pushedOnce {
                    pushedOnce = true
                    notice("first-upload",
                           "[SYNC] text logs are uploading to \(repository)@\(branch)/\(launchFolder)")
                }
            } else {
                let attempts = state.failed(remotePath: entry.remotePath, now: now)
                if attempts == nil {
                    notice("retry-exhausted", "[SYNC] a log upload exhausted its retry budget; the snapshot is kept locally")
                } else if let attempts,
                          attempts == 1 || attempts == LogSyncPolicy.maximumRetries - 1 {
                    notice("retry-\(attempts)",
                           "[SYNC] log upload will retry (attempt \(attempts) of \(LogSyncPolicy.maximumRetries))")
                }
                changed = true
            }
        }
        if changed { writeQueue(state) }
    }

    // MARK: - HTTP

    private func ensureBranch(token: String) -> Bool {
        if branchReady { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= branchNextAttempt else { return false }
        branchNextAttempt = now + 300
        if let url = URL(string: "https://api.github.com/repos/\(repository)/branches/\(branch)"),
           authorizedGET(url, token: token).status == 200 {
            branchReady = true
            return true
        }
        guard let mainURL = URL(string: "https://api.github.com/repos/\(repository)/git/ref/heads/main"),
              let response = authorizedGET(mainURL, token: token).json as? [String: Any],
              let object = response["object"] as? [String: Any],
              let sha = object["sha"] as? String,
              let refURL = URL(string: "https://api.github.com/repos/\(repository)/git/refs") else {
            return false
        }
        var request = URLRequest(url: refURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let body: [String: Any] = ["ref": "refs/heads/\(branch)", "sha": sha]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (status, _) = perform(request)
        branchReady = (200...201).contains(status)
        return branchReady
    }

    private func upload(data: Data, remotePath: String, token: String) -> Bool {
        guard let getURL = contentsURL(path: remotePath, ref: branch) else { return false }
        let existing = authorizedGET(getURL, token: token)
        var sha: String?
        if existing.status == 200,
           let object = existing.json as? [String: Any] {
            sha = object["sha"] as? String
        } else if existing.status != 404 {
            return false
        }
        guard let putURL = contentsURL(path: remotePath, ref: nil) else { return false }
        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
        var body: [String: Any] = [
            "message": "logs: \(installID) \(launchStamp)",
            "content": data.base64EncodedString(),
            "branch": branch,
        ]
        if let sha { body["sha"] = sha }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (status, _) = perform(request)
        if status == 404 || status == 409 || status == 422 {
            // The logs branch may have been deleted or renamed while Dot runs.
            // Re-check it on the next attempt instead of failing until restart.
            branchReady = false
            branchNextAttempt = 0
        }
        return (200...201).contains(status)
    }

    private func contentsURL(path: String, ref: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/contents/\(path)"
        if let ref { components.queryItems = [URLQueryItem(name: "ref", value: ref)] }
        return components.url
    }

    private func authorizedGET(_ url: URL, token: String) -> (status: Int, json: Any?) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (status, data) = perform(request)
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return (status, json)
    }

    /// Bounded synchronous call on the upload queue; the request body never
    /// contains the token in a log line.
    private func perform(_ request: URLRequest) -> (status: Int, data: Data?) {
        let semaphore = DispatchSemaphore(value: 0)
        var status = 0
        var body: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            body = data
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (status, body)
    }

    // MARK: - Token, identity and queue

    private func token() -> String? {
        let keychain = keychainToken()
        if let value = keychain.value, !value.isEmpty { return value }
        if keychain.status != errSecItemNotFound, keychain.status != errSecSuccess,
           keychain.status != lastKeychainStatus {
            lastKeychainStatus = keychain.status
            syncLog("[SYNC] Keychain read failed with status \(keychain.status); falling back to the config file")
        }
        guard let url = supportDirectory?.appendingPathComponent("github.token"),
              let value = try? String(contentsOf: url, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func keychainToken() -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return (nil, status) }
        return (value, status)
    }

    private func loadOrCreateInstallID() -> String {
        guard let support = supportDirectory else { return LogSyncPolicy.newInstallID() }
        let url = support.appendingPathComponent("install-id")
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let existing = LogSyncPolicy.normalizedInstallID(raw) {
            return existing
        }
        let generated = LogSyncPolicy.newInstallID()
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        try? Data("\(generated)\n".utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return generated
    }

    private func readQueue() -> LogUploadQueue {
        guard let url = queueFile, let data = try? Data(contentsOf: url),
              let state = LogUploadQueue.decoded(data) else { return LogUploadQueue() }
        return state
    }

    private func writeQueue(_ state: LogUploadQueue) {
        guard let url = queueFile, let data = try? state.encoded() else { return }
        try? data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Uploader diagnostics are local only. Writing them into `dot_chat_log.txt`
    /// would change the uploaded file and reset its retry budget forever.
    private func notice(_ key: String, _ message: String) {
        guard key != lastNotice else { return }
        lastNotice = key
        syncLog(message)
    }

    private func syncLog(_ message: String) {
        guard let url = syncLogURL else { return }
        DiagnosticChatLogger.rotateIfOversized(url, rotatedName: "dot-sync.1.log", maxBytes: 1_000_000)
        let line = "[\(Date().ISO8601Format())] \(LogRedaction.masked(message))\n"
        if !fileManager.fileExists(atPath: url.path) {
            try? Data(line.utf8).write(to: url, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Bound unqueued snapshots to roughly 32 MB, never deleting a queued upload.
    /// The absolute bound is 32 MB plus the 64-entry queue; older launches are
    /// pruned first and the current launch is rewritten on demand.
    private func pruneSnapshotsIfNeeded() {
        guard !prunedOnce, let queue = queueDirectory else { return }
        prunedOnce = true
        let queued = Set(readQueue().entries.map { URL(fileURLWithPath: $0.localPath).lastPathComponent })
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? fileManager.contentsOfDirectory(at: queue, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles])) ?? []
        let sorted = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var total = 0
        for (file, size, _) in sorted {
            total += size
            if total > 32_000_000, !queued.contains(file.lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
