import Darwin
import Foundation

struct WebResearchStoredSession: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { session.id }
    let revision: UUID
    let session: WebResearchSession
    let recoveredAt: Date?
}

struct WebResearchSessionSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let revision: UUID
    let question: String
    let stage: WebResearchStage
    let createdAt: Date
    let updatedAt: Date
    let recoveredAt: Date?
    let sourcesRead: Int
    let searchAttempts: Int
}

enum WebResearchStoreError: Error, Equatable, LocalizedError {
    case invalidInput, capacity, corrupt, unsupportedVersion(Int), unsafeStorage, unavailable, busy, conflict, notFound
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "The research session is invalid or changes its original identity."
        case .capacity: return "Saved research reached its local storage limit. Delete a session to make room."
        case .corrupt: return "Saved research could not be read. The existing file has been preserved."
        case .unsupportedVersion: return "Saved research uses an unsupported format. The existing file has been preserved."
        case .unsafeStorage: return "Research storage must use a private, locally owned regular file and folder."
        case .unavailable: return "Research could not be read or saved. Reload to check the latest saved state."
        case .busy: return "Another research storage operation is active."
        case .conflict: return "This research session changed. Reload it before saving again."
        case .notFound: return "That research session has been deleted or is no longer available."
        }
    }
}

protocol WebResearchSessionAccess: Sendable {
    var retention: WebResearchRetention { get }
    func list() async throws -> [WebResearchSessionSummary]
    func load(id: UUID) async throws -> WebResearchStoredSession
    func create(question: String, queries: [String], limits: WebResearchLimits,
                retryPolicy: WebResearchRetryPolicy) async throws -> WebResearchStoredSession
    func save(_ session: WebResearchSession, expectedRevision: UUID) async throws -> WebResearchStoredSession
    func delete(id: UUID, expectedRevision: UUID) async throws
    func deleteAll() async throws
}

extension WebResearchSessionAccess { var retention: WebResearchRetention { .permittedPersistence } }

/// Inject one shared owner into the research UI/task coordinator. This actor performs no network,
/// inference, source interpretation or clipboard work. Only bounded session text/receipts enter it.
actor WebResearchSessionStore: WebResearchSessionAccess {
    struct Limits: Sendable {
        var maxSessions = 20
        var maxSessionBytes = 8_388_608
        var maxFileBytes = 16_777_216
    }

    private struct Document: Codable { let schemaVersion: Int; var sessions: [WebResearchStoredSession] }
    private struct Version: Decodable { let schemaVersion: Int }
    private static let fileName = "research-sessions.json"
    private static let lockName = "research-sessions.lock"
    private let directory: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    /// Local write provenance only: an unowned revision may belong to another live store.
    /// This set is not an execution lease or evidence that another process has stopped.
    private var ownedRevisions: Set<UUID> = []

    init(directory: URL? = nil, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard (1...50).contains(limits.maxSessions), (1_024...8_388_608).contains(limits.maxSessionBytes),
              (1_024...33_554_432).contains(limits.maxFileBytes) else { throw WebResearchStoreError.capacity }
        guard let chosen = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dot/ResearchSessions", isDirectory: true), chosen.isFileURL,
              !chosen.path.contains("\0") else { throw WebResearchStoreError.unsafeStorage }
        self.directory = chosen.standardizedFileURL; self.limits = limits; self.now = now
    }

    func list() throws -> [WebResearchSessionSummary] {
        try transaction { folder in
            let projected = try read(folder).sessions.map(recoveryProjection)
            let sortedSessions = projected.sorted {
                if $0.session.updatedAt == $1.session.updatedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.session.updatedAt > $1.session.updatedAt
            }
            return sortedSessions.map { stored in
                let session = stored.session
                return WebResearchSessionSummary(
                    id: stored.id,
                    revision: stored.revision,
                    question: session.question,
                    stage: session.stage,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    recoveredAt: stored.recoveredAt,
                    sourcesRead: session.sources.count,
                    searchAttempts: session.searchAttempts
                )
            }
        }
    }

    func load(id: UUID) throws -> WebResearchStoredSession {
        try transaction { folder in
            guard let stored = try read(folder).sessions.first(where: { $0.id == id }) else { throw WebResearchStoreError.notFound }
            return recoveryProjection(stored)
        }
    }

    /// IDs are minted here. An old callback cannot recreate a deleted session by passing its ID.
    func create(question: String, queries: [String], limits researchLimits: WebResearchLimits = WebResearchLimits(),
                retryPolicy: WebResearchRetryPolicy = .preserveUncertain) throws -> WebResearchStoredSession {
        try transaction { folder in
            var document = try read(folder)
            let session: WebResearchSession
            do { session = try WebResearchSession(question: question, queries: queries, limits: researchLimits, retryPolicy: retryPolicy, now: now()) }
            catch { throw WebResearchStoreError.invalidInput }
            let stored = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
            document.sessions.append(stored)
            try persist(document, folder: folder)
            rememberOwned(document, adding: stored.revision)
            return stored
        }
    }

    /// Compare-and-swap on an existing record only; never an upsert. Callers must keep the returned
    /// revision after every serialized checkpoint. A deleted or explicitly replaced revision is rejected.
    /// Passive recovery projections retain their raw CAS revision until a caller commits a change.
    func save(_ session: WebResearchSession, expectedRevision: UUID) throws -> WebResearchStoredSession {
        guard session.storageMode == .permittedPersistence else { throw WebResearchStoreError.invalidInput }
        return try transaction { folder in
            var document = try read(folder)
            guard let index = document.sessions.firstIndex(where: { $0.id == session.id }) else { throw WebResearchStoreError.notFound }
            let previous = document.sessions[index]
            guard previous.revision == expectedRevision else { throw WebResearchStoreError.conflict }
            guard validResearchReplacement(previous: previous.session, next: session) else { throw WebResearchStoreError.invalidInput }
            try validateSession(session)
            // Only an explicit target write records reconciliation; it cannot prove the prior
            // process died or prevent an already-issued request from finishing elsewhere.
            let recoveredAt = needsReconciliation(previous) ? now() : previous.recoveredAt
            let stored = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: recoveredAt)
            document.sessions[index] = stored
            try persist(document, folder: folder)
            rememberOwned(document, adding: stored.revision)
            return stored
        }
    }

    func delete(id: UUID, expectedRevision: UUID) throws {
        try transaction { folder in
            var document = try read(folder)
            guard let index = document.sessions.firstIndex(where: { $0.id == id }) else { throw WebResearchStoreError.notFound }
            guard document.sessions[index].revision == expectedRevision else { throw WebResearchStoreError.conflict }
            document.sessions.remove(at: index)
            try persist(document, folder: folder)
            rememberOwned(document)
        }
    }

    /// Explicitly deletes currently saved valid sessions. Corrupt/unknown files remain preserved,
    /// rather than being silently replaced by an ordinary delete operation.
    func deleteAll() throws {
        try transaction { folder in
            _ = try read(folder)
            try persist(Document(schemaVersion: 1, sessions: []), folder: folder)
            ownedRevisions.removeAll()
        }
    }

    /// An unowned active checkpoint has an unknown outcome, not a proven dead owner.
    /// Project a conservative paused view without changing durable bytes, timestamps or CAS.
    /// Every mutation reloads raw records so unrelated writes cannot persist this projection.
    private func recoveryProjection(_ stored: WebResearchStoredSession) -> WebResearchStoredSession {
        guard needsReconciliation(stored) else { return stored }
        var session = stored.session
        for query in session.queries.indices where session.queries[query].status == .inFlight {
            session.queries[query].status = .uncertain
            session.queries[query].failure = .interruptedOutcomeUnknown
        }
        for source in session.reads.indices where session.reads[source].status == .inFlight {
            session.reads[source].status = .pending
        }
        session.stage = .paused
        return WebResearchStoredSession(revision: stored.revision, session: session, recoveredAt: stored.recoveredAt)
    }

    private func needsReconciliation(_ stored: WebResearchStoredSession) -> Bool {
        !ownedRevisions.contains(stored.revision) && (stored.session.stage == .retrieving
            || stored.session.queries.contains { $0.status == .inFlight }
            || stored.session.reads.contains { $0.status == .inFlight })
    }

    private func rememberOwned(_ document: Document, adding: UUID? = nil) {
        ownedRevisions.formIntersection(Set(document.sessions.map(\.revision)))
        if let adding { ownedRevisions.insert(adding) }
    }

    private func validateSession(_ session: WebResearchSession) throws {
        guard session.storageMode == .permittedPersistence else { throw WebResearchStoreError.invalidInput }
        do {
            let data = try session.encodedCheckpoint()
            guard data.count <= limits.maxSessionBytes else { throw WebResearchStoreError.capacity }
        } catch let error as WebResearchStoreError { throw error }
        catch { throw WebResearchStoreError.invalidInput }
    }

    private func validate(_ document: Document) throws {
        guard document.schemaVersion == 1 else { throw WebResearchStoreError.unsupportedVersion(document.schemaVersion) }
        guard document.sessions.count <= limits.maxSessions else { throw WebResearchStoreError.capacity }
        guard Set(document.sessions.map(\.id)).count == document.sessions.count,
              Set(document.sessions.map(\.revision)).count == document.sessions.count else { throw WebResearchStoreError.corrupt }
        for stored in document.sessions {
            try Task.checkCancellation()
            guard stored.recoveredAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw WebResearchStoreError.corrupt }
            try validateSession(stored.session)
        }
    }

    private func read(_ folder: Int32) throws -> Document {
        let descriptor = openat(folder, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return Document(schemaVersion: 1, sessions: []) }
            throw WebResearchStoreError.unsafeStorage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try Self.checkRegular(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size <= limits.maxFileBytes else { throw WebResearchStoreError.capacity }
        let data = try handle.read(upToCount: limits.maxFileBytes + 1) ?? Data()
        guard data.count <= limits.maxFileBytes else { throw WebResearchStoreError.capacity }
        do {
            let decoder = JSONDecoder()
            let version = try decoder.decode(Version.self, from: data)
            guard version.schemaVersion == 1 else { throw WebResearchStoreError.unsupportedVersion(version.schemaVersion) }
            let document = try decoder.decode(Document.self, from: data)
            try validate(document)
            return document
        } catch is CancellationError { throw CancellationError() }
        catch WebResearchStoreError.invalidInput { throw WebResearchStoreError.corrupt }
        catch let error as WebResearchStoreError { throw error }
        catch { throw WebResearchStoreError.corrupt }
    }

    private func persist(_ document: Document, folder: Int32) throws {
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= limits.maxFileBytes else { throw WebResearchStoreError.capacity }
        let temporary = ".research-sessions-\(UUID().uuidString).tmp"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WebResearchStoreError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(folder, temporary, 0) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try Task.checkCancellation()
        guard renameat(folder, temporary, folder, Self.fileName) == 0 else { throw WebResearchStoreError.unavailable }
        // Rename is the commit point. A late cancellation cannot undo it; sync the directory entry.
        guard fsync(folder) == 0 else { throw WebResearchStoreError.unavailable }
    }

    private func transaction<T>(_ operation: (Int32) throws -> T) throws -> T {
        try Task.checkCancellation()
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard folder >= 0 else { throw WebResearchStoreError.unsafeStorage }
            defer { close(folder) }
            var info = stat()
            guard fstat(folder, &info) == 0, info.st_uid == geteuid(), fchmod(folder, 0o700) == 0 else { throw WebResearchStoreError.unsafeStorage }
            let lock = openat(folder, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lock >= 0 else { throw WebResearchStoreError.unsafeStorage }
            defer { close(lock) }
            try Self.checkRegular(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WebResearchStoreError.busy }
            defer { flock(lock, LOCK_UN) }
            try removeAbandonedTemporaries(folder)
            try Task.checkCancellation()
            return try operation(folder)
        } catch is CancellationError { throw CancellationError() }
        catch let error as WebResearchStoreError { throw error }
        catch { throw WebResearchStoreError.unavailable }
    }

    /// Remove only this writer's regular, private orphan files while holding its cross-owner lock.
    /// They can contain deleted text after an interrupted pre-rename write; unknown files are untouched.
    private func removeAbandonedTemporaries(_ folder: Int32) throws {
        let duplicate = dup(folder)
        guard duplicate >= 0 else { throw WebResearchStoreError.unavailable }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw WebResearchStoreError.unavailable }
        defer { closedir(stream) }
        var visited = 0
        while let entry = readdir(stream) {
            try Task.checkCancellation(); visited += 1
            guard visited <= 1_000 else { throw WebResearchStoreError.capacity }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            let prefix = ".research-sessions-", suffix = ".tmp"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { continue }
            let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw WebResearchStoreError.unsafeStorage }
            defer { close(descriptor) }
            try Self.checkRegular(descriptor)
            guard unlinkat(folder, name, 0) == 0 else { throw WebResearchStoreError.unavailable }
        }
    }

    private static func checkRegular(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, fchmod(descriptor, 0o600) == 0 else { throw WebResearchStoreError.unsafeStorage }
    }
}

/// Volatile research has no directory, file, cache, or export destination. Dropping this
/// owner (including app exit) drops its contents; it cannot provide restart recovery.
actor TransientWebResearchStore: WebResearchSessionAccess {
    nonisolated let retention = WebResearchRetention.transient
    private var sessions: [UUID: WebResearchStoredSession] = [:]
    private let maximumSessions = 20
    private let maximumBytes = 16_777_216
    private let now: @Sendable () -> Date
    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func list() throws -> [WebResearchSessionSummary] {
        try Task.checkCancellation()
        return sessions.values.sorted {
            $0.session.updatedAt == $1.session.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.session.updatedAt > $1.session.updatedAt
        }.map { stored in
            let session = stored.session
            return WebResearchSessionSummary(id: stored.id, revision: stored.revision, question: session.question,
                stage: session.stage, createdAt: session.createdAt, updatedAt: session.updatedAt,
                recoveredAt: nil, sourcesRead: session.sources.count, searchAttempts: session.searchAttempts)
        }
    }
    func load(id: UUID) throws -> WebResearchStoredSession {
        try Task.checkCancellation()
        guard let session = sessions[id] else { throw WebResearchStoreError.notFound }
        return session
    }
    func create(question: String, queries: [String], limits: WebResearchLimits = WebResearchLimits(),
                retryPolicy: WebResearchRetryPolicy = .preserveUncertain) throws -> WebResearchStoredSession {
        try Task.checkCancellation()
        let session = try WebResearchSession(question: question, queries: queries, limits: limits,
            retryPolicy: retryPolicy, now: now(), retention: .transient)
        let stored = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
        var next = sessions; next[stored.id] = stored
        try validateCapacity(next); sessions = next
        return stored
    }
    func save(_ session: WebResearchSession, expectedRevision: UUID) throws -> WebResearchStoredSession {
        try Task.checkCancellation()
        guard session.storageMode == .transient else { throw WebResearchStoreError.invalidInput }
        guard let previous = sessions[session.id] else { throw WebResearchStoreError.notFound }
        guard previous.revision == expectedRevision else { throw WebResearchStoreError.conflict }
        guard validResearchReplacement(previous: previous.session, next: session) else { throw WebResearchStoreError.invalidInput }
        let stored = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
        var next = sessions; next[stored.id] = stored
        try validateCapacity(next); sessions = next
        return stored
    }
    func delete(id: UUID, expectedRevision: UUID) throws {
        try Task.checkCancellation()
        guard let previous = sessions[id] else { throw WebResearchStoreError.notFound }
        guard previous.revision == expectedRevision else { throw WebResearchStoreError.conflict }
        sessions.removeValue(forKey: id)
    }
    func deleteAll() throws { try Task.checkCancellation(); sessions.removeAll() }
    private func validateCapacity(_ proposed: [UUID: WebResearchStoredSession]) throws {
        guard proposed.count <= maximumSessions else { throw WebResearchStoreError.capacity }
        var bytes = 0
        for stored in proposed.values {
            try Task.checkCancellation()
            guard stored.session.storageMode == .transient else { throw WebResearchStoreError.invalidInput }
            do { bytes += try stored.session.encodedCheckpoint().count }
            catch { throw WebResearchStoreError.invalidInput }
            guard bytes <= maximumBytes else { throw WebResearchStoreError.capacity }
        }
    }
}

private func validResearchReplacement(previous: WebResearchSession, next: WebResearchSession) -> Bool {
    // A checked receipt is meaningful only for the exact immutable completed
    // payload read back by the controller. Follow-up work explicitly clears it.
    if previous.stage == .completed && next.stage == .completed {
        var payload = next
        payload.outputVerification = previous.outputVerification
        guard payload == previous else { return false }
        if next.outputVerification != previous.outputVerification {
            guard previous.outputVerification == .pending, next.outputVerification == .checked else { return false }
        }
    } else if next.stage == .completed {
        guard next.outputVerification == .pending else { return false }
    } else {
        guard next.outputVerification == nil else { return false }
    }
    guard previous.question == next.question, previous.createdAt == next.createdAt,
                  previous.limits == next.limits, previous.storageMode == next.storageMode,
                  previous.providerID == nil || previous.providerID == next.providerID,
                  next.searchAttempts >= previous.searchAttempts,
                  previous.queries.allSatisfy({ old in
                      guard let next = next.queries.first(where: { $0.id == old.id }) else { return false }
                      return next.text == old.text && next.attempts >= old.attempts
                          && (old.status != .completed || (next.status == .completed && next.results == old.results && next.completedAt == old.completedAt
                              && next.coverage == old.coverage && next.unavailableEngineIDs == old.unavailableEngineIDs))
                  }), previous.reads.allSatisfy({ old in
                      guard let next = next.reads.first(where: { $0.id == old.id }) else { return false }
                      return next.url == old.url && (old.status != .completed || (next.status == .completed && next.source == old.source))
                  }) else { return false }
    return true
}
