import Foundation
import SQLite3

/// Structured fact category for evidence-backed memory (R07, R08, R239).
enum MemoryFactCategory: String, Codable, CaseIterable, Sendable {
    case userPreference
    case userCorrection
    case projectContext
    case systemObservation
    case learnedFact
}

/// Durable fact record tied to source passages, dates and hashes.
struct MemoryFactRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let category: MemoryFactCategory
    let fact: String
    let sourcePassage: String?
    let sourceURL: URL?
    let sourceSHA256: String?
    let confidence: Double
    let isCorrection: Bool
    let supersedesID: UUID?
    var isStale: Bool
    let createdAt: Date
    var updatedAt: Date
}

/// Search hit for full-text search across document and web evidence.
struct EvidenceSearchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let url: URL
    let kind: String
    let snippet: String
    let sha256: String
    let retrievedAt: Date
}

/// Local SQLite + FTS5 durable store for conversations, editable memory and evidence passages (R47, R239, R269).
actor LocalFTSStore {
    private var db: OpaquePointer?
    private let fileURL: URL
    private static let defaultDirectoryName = "Records"
    private static let defaultFileName = "dot_records.sqlite"

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil, inMemory: Bool = false) throws {
        let handle: OpaquePointer?
        if inMemory {
            fileURL = URL(fileURLWithPath: ":memory:")
            var opened: OpaquePointer?
            guard sqlite3_open_v2(":memory:", &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                throw LocalFTSError.openFailed("Failed to open in-memory SQLite database")
            }
            handle = opened
        } else {
            let dir: URL
            if let directory {
                dir = directory
            } else {
                guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    throw LocalFTSError.openFailed("Application Support directory unavailable")
                }
                dir = support.appendingPathComponent("Dot", isDirectory: true)
                    .appendingPathComponent(Self.defaultDirectoryName, isDirectory: true)
            }
            try Self.prepareDirectory(dir)
            fileURL = dir.appendingPathComponent(Self.defaultFileName)
            var opened: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(fileURL.path, &opened, flags, nil) == SQLITE_OK else {
                throw LocalFTSError.openFailed("Failed to open SQLite database at \(fileURL.path)")
            }
            handle = opened
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        db = handle
        guard let handle else { throw LocalFTSError.closed }
        // MS-5: a busy writer is normal under WAL; wait up to 5 s instead of failing
        // the step, so tier writes and fact writes on the shared file never race.
        sqlite3_busy_timeout(handle, 5_000)
        try Self.execute(db: handle, sql: "PRAGMA journal_mode = WAL;")
        try Self.execute(db: handle, sql: "PRAGMA synchronous = NORMAL;")
        try Self.createSchema(db: handle)
    }

    deinit {
        if let handle = db {
            sqlite3_close_v2(handle)
        }
    }

    private static func prepareDirectory(_ dir: URL) throws {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func execute(db: OpaquePointer?, sql: String) throws {
        guard let db else { throw LocalFTSError.closed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let msg = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw LocalFTSError.executionFailed(msg)
        }
    }

    private func execute(sql: String) throws {
        try Self.execute(db: db, sql: sql)
    }

    /// MS-5: runs a statement to completion and reports any step failure to the
    /// diagnostic log, so a discarded step result can never pass silently as success.
    @discardableResult
    private func stepLogged(_ stmt: OpaquePointer?, context: String) -> Bool {
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else {
            let message = db.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) } ?? "unknown error"
            DiagnosticChatLogger.record(role: "memory", text: "SQLite \(context) failed (code \(result)): \(message)")
            return false
        }
        return true
    }

    private static func createSchema(db: OpaquePointer) throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS conversation_records (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            ended_at REAL,
            generation_status TEXT,
            playback_status TEXT
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS fts_conversations USING fts5(
            id UNINDEXED,
            text,
            role UNINDEXED,
            tokenize='porter unicode61'
        );

        CREATE TABLE IF NOT EXISTS memory_facts (
            id TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            fact TEXT NOT NULL,
            source_passage TEXT,
            source_url TEXT,
            source_sha256 TEXT,
            confidence REAL NOT NULL,
            is_correction INTEGER NOT NULL,
            supersedes_id TEXT,
            is_stale INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS fts_memories USING fts5(
            id UNINDEXED,
            category,
            fact,
            source_passage,
            tokenize='porter unicode61'
        );

        CREATE TABLE IF NOT EXISTS document_evidence (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            url TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            bytes_read INTEGER NOT NULL,
            retrieved_at REAL NOT NULL,
            modified_at REAL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS fts_evidence USING fts5(
            id UNINDEXED,
            title,
            text,
            tokenize='porter unicode61'
        );

        CREATE TABLE IF NOT EXISTS memory_tier_state (
            id TEXT PRIMARY KEY,
            tier INTEGER NOT NULL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_accessed_at REAL NOT NULL,
            superseded_by TEXT,
            pinned INTEGER NOT NULL DEFAULT 0,
            represents_count INTEGER NOT NULL DEFAULT 1
        );

        CREATE INDEX IF NOT EXISTS memory_tier_state_tier ON memory_tier_state (tier, created_at);
        """
        try execute(db: db, sql: schema)
    }

    /// R5/B4: the tier store is constructed with this store — the app's single handle —
    /// rather than opening its own connection, so one database keeps one owner. The
    /// closure runs on this actor's executor, so tier writes serialize with fact writes
    /// instead of racing a second handle.
    func withMemoryConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw LocalFTSError.closed }
        return try body(db)
    }

    // MARK: - Conversation Indexing & Retrieval

    func indexConversation(record: ConversationHistoryRecord) throws {
        guard let db else { throw LocalFTSError.closed }
        let insertSQL = """
        INSERT OR REPLACE INTO conversation_records (id, turn_id, role, text, created_at, ended_at, generation_status, playback_status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare insert for conversation")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, record.turnID.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, record.role.rawValue, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, record.text, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, record.date.timeIntervalSince1970)
        if let endedAt = record.endedAt {
            sqlite3_bind_double(stmt, 6, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_text(stmt, 7, record.generation.rawValue, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, record.playback.rawValue, -1, Self.SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Insert conversation failed")
        }

        // FTS update
        let ftsDelete = "DELETE FROM fts_conversations WHERE id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsDelete, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, record.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(delStmt, context: "conversation FTS delete")
            sqlite3_finalize(delStmt)
        }

        let ftsInsert = "INSERT INTO fts_conversations (id, text, role) VALUES (?, ?, ?);"
        var ftsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsInsert, -1, &ftsStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(ftsStmt, 1, record.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 2, record.text, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 3, record.role.rawValue, -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(ftsStmt, context: "conversation FTS insert")
            sqlite3_finalize(ftsStmt)
        }
    }

    func searchConversations(query: String, limit: Int = 20) throws -> [ConversationHistoryRecord] {
        let strictQuery = sanitizeFTSQuery(query, joinOperator: "AND")
        guard !strictQuery.isEmpty else { return [] }
        let strictResults = try performSearchConversations(ftsQuery: strictQuery, limit: limit)
        if !strictResults.isEmpty { return strictResults }

        let broadQuery = sanitizeFTSQuery(query, joinOperator: "OR")
        guard !broadQuery.isEmpty, broadQuery != strictQuery else { return [] }
        return try performSearchConversations(ftsQuery: broadQuery, limit: limit)
    }

    private func performSearchConversations(ftsQuery: String, limit: Int) throws -> [ConversationHistoryRecord] {
        guard let db else { throw LocalFTSError.closed }
        let searchSQL = """
        SELECT c.id, c.turn_id, c.role, c.text, c.created_at, c.ended_at, c.generation_status, c.playback_status
        FROM fts_conversations f
        JOIN conversation_records c ON f.id = c.id
        WHERE fts_conversations MATCH ?
        ORDER BY bm25(fts_conversations) ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, searchSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare conversation search")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [ConversationHistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0),
                  let turnStr = sqlite3_column_text(stmt, 1),
                  let roleStr = sqlite3_column_text(stmt, 2),
                  let textStr = sqlite3_column_text(stmt, 3),
                  let id = UUID(uuidString: String(cString: idStr)),
                  let turnID = UUID(uuidString: String(cString: turnStr)),
                  let role = ConversationHistoryRole(rawValue: String(cString: roleStr)) else { continue }

            let text = String(cString: textStr)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let endedAt = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let genStatus = sqlite3_column_text(stmt, 6).flatMap { ConversationGenerationStatus(rawValue: String(cString: $0)) } ?? .unknown
            let playStatus = sqlite3_column_text(stmt, 7).flatMap { ConversationPlaybackStatus(rawValue: String(cString: $0)) } ?? .unknown

            results.append(ConversationHistoryRecord(
                id: id,
                date: createdAt,
                role: role,
                text: text,
                turnID: turnID,
                generation: genStatus,
                playback: playStatus,
                generationCompletedAt: nil,
                playbackStartedAt: nil,
                playbackCompletedAt: endedAt,
                endedAt: endedAt,
                failureStage: nil,
                textTruncated: false
            ))
        }
        return results
    }


    // MARK: - Evidence-Backed Memory

    func saveMemory(id: UUID = UUID(), category: MemoryFactCategory, fact: String, sourcePassage: String? = nil,
                    sourceURL: URL? = nil, sourceSHA256: String? = nil, confidence: Double = 1.0,
                    isCorrection: Bool = false, supersedesID: UUID? = nil) throws -> MemoryFactRecord {
        guard let db else { throw LocalFTSError.closed }
        let now = Date()
        var effectiveID = id
        var effectiveCreatedAt = now
        var effectiveConfidence = confidence
        var effectiveCategory = category
        var effectiveIsCorrection = isCorrection
        var effectiveSupersedesID = supersedesID

        if supersedesID == nil {
            // MS-2: an identical-text write dedups onto the existing live row and keeps
            // that row's category and supersession, so a re-stated fact never demotes a
            // stored record back to this call's defaults.
            let checkSQL = "SELECT id, category, is_correction, supersedes_id, created_at, confidence FROM memory_facts WHERE LOWER(TRIM(fact)) = LOWER(TRIM(?)) AND is_stale = 0 LIMIT 1;"
            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, fact, -1, Self.SQLITE_TRANSIENT)
                if sqlite3_step(checkStmt) == SQLITE_ROW,
                   let existingIDStr = sqlite3_column_text(checkStmt, 0),
                   let existingUUID = UUID(uuidString: String(cString: existingIDStr)) {
                    effectiveID = existingUUID
                    if let existingCategoryStr = sqlite3_column_text(checkStmt, 1),
                       let existingCategory = MemoryFactCategory(rawValue: String(cString: existingCategoryStr)) {
                        effectiveCategory = existingCategory
                    }
                    effectiveIsCorrection = sqlite3_column_int(checkStmt, 2) != 0
                    effectiveSupersedesID = sqlite3_column_text(checkStmt, 3).flatMap { UUID(uuidString: String(cString: $0)) }
                    effectiveCreatedAt = Date(timeIntervalSince1970: sqlite3_column_double(checkStmt, 4))
                    effectiveConfidence = max(confidence, sqlite3_column_double(checkStmt, 5))
                }
                sqlite3_finalize(checkStmt)
            }
        }

        if let supersedes = supersedesID {
            let staleSQL = "UPDATE memory_facts SET is_stale = 1, updated_at = ? WHERE id = ?;"
            var staleStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, staleSQL, -1, &staleStmt, nil) == SQLITE_OK else {
                throw LocalFTSError.prepareFailed("Failed to prepare supersede stale mark")
            }
            defer { sqlite3_finalize(staleStmt) }
            sqlite3_bind_double(staleStmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(staleStmt, 2, supersedes.uuidString, -1, Self.SQLITE_TRANSIENT)
            guard stepLogged(staleStmt, context: "supersede stale mark") else {
                throw LocalFTSError.executionFailed("Supersede stale mark failed")
            }
        }

        let insertSQL = """
        INSERT OR REPLACE INTO memory_facts (id, category, fact, source_passage, source_url, source_sha256, confidence, is_correction, supersedes_id, is_stale, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare memory insert")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, effectiveID.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, effectiveCategory.rawValue, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, fact, -1, Self.SQLITE_TRANSIENT)
        if let passage = sourcePassage {
            sqlite3_bind_text(stmt, 4, passage, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let url = sourceURL {
            sqlite3_bind_text(stmt, 5, url.absoluteString, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let sha = sourceSHA256 {
            sqlite3_bind_text(stmt, 6, sha, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_double(stmt, 7, effectiveConfidence)
        sqlite3_bind_int(stmt, 8, effectiveIsCorrection ? 1 : 0)
        if let supersedes = effectiveSupersedesID {
            sqlite3_bind_text(stmt, 9, supersedes.uuidString, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        sqlite3_bind_int(stmt, 10, 0)
        sqlite3_bind_double(stmt, 11, effectiveCreatedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 12, now.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Insert memory failed")
        }

        // Remove any prior FTS row for this ID before inserting updated FTS entry
        let ftsDelete = "DELETE FROM fts_memories WHERE id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsDelete, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, effectiveID.uuidString, -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(delStmt, context: "memory FTS delete")
            sqlite3_finalize(delStmt)
        }

        // FTS update
        let ftsInsert = "INSERT INTO fts_memories (id, category, fact, source_passage) VALUES (?, ?, ?, ?);"
        var ftsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsInsert, -1, &ftsStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(ftsStmt, 1, effectiveID.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 2, effectiveCategory.rawValue, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 3, fact, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 4, sourcePassage ?? "", -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(ftsStmt, context: "memory FTS insert")
            sqlite3_finalize(ftsStmt)
        }

        return MemoryFactRecord(
            id: effectiveID,
            category: effectiveCategory,
            fact: fact,
            sourcePassage: sourcePassage,
            sourceURL: sourceURL,
            sourceSHA256: sourceSHA256,
            confidence: effectiveConfidence,
            isCorrection: effectiveIsCorrection,
            supersedesID: effectiveSupersedesID,
            isStale: false,
            createdAt: effectiveCreatedAt,
            updatedAt: now
        )
    }

    func listPinnedMemories(limit: Int = 25) throws -> [MemoryFactRecord] {
        guard let db else { throw LocalFTSError.closed }
        let sql = """
        SELECT id, category, fact, source_passage, source_url, source_sha256, confidence, is_correction, supersedes_id, is_stale, created_at, updated_at
        FROM memory_facts
        WHERE is_stale = 0
        ORDER BY is_correction DESC,
                 CASE category
                     WHEN 'userCorrection' THEN 0
                     WHEN 'userPreference' THEN 1
                     WHEN 'projectContext' THEN 2
                     WHEN 'learnedFact' THEN 3
                     ELSE 4
                 END ASC,
                 confidence DESC,
                 updated_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare pinned memories query")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
        return readMemoryRows(stmt: stmt)
    }

    func searchMemories(query: String, includeStale: Bool = false, limit: Int = 20) throws -> [MemoryFactRecord] {
        let strictQuery = sanitizeFTSQuery(query, joinOperator: "AND")
        guard !strictQuery.isEmpty else { return [] }
        let strictResults = try performSearchMemories(ftsQuery: strictQuery, includeStale: includeStale, limit: limit)
        if !strictResults.isEmpty { return strictResults }

        let broadQuery = sanitizeFTSQuery(query, joinOperator: "OR")
        guard !broadQuery.isEmpty, broadQuery != strictQuery else { return [] }
        return try performSearchMemories(ftsQuery: broadQuery, includeStale: includeStale, limit: limit)
    }

    private func performSearchMemories(ftsQuery: String, includeStale: Bool, limit: Int) throws -> [MemoryFactRecord] {
        guard let db else { throw LocalFTSError.closed }
        let searchSQL = """
        SELECT m.id, m.category, m.fact, m.source_passage, m.source_url, m.source_sha256, m.confidence, m.is_correction, m.supersedes_id, m.is_stale, m.created_at, m.updated_at
        FROM fts_memories f
        JOIN memory_facts m ON f.id = m.id
        WHERE fts_memories MATCH ? \(includeStale ? "" : "AND m.is_stale = 0")
        ORDER BY bm25(fts_memories) ASC, m.is_correction DESC, m.updated_at DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, searchSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare memory search")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return readMemoryRows(stmt: stmt)
    }

    private func readMemoryRows(stmt: OpaquePointer?) -> [MemoryFactRecord] {
        var results: [MemoryFactRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0),
                  let catStr = sqlite3_column_text(stmt, 1),
                  let factStr = sqlite3_column_text(stmt, 2),
                  let id = UUID(uuidString: String(cString: idStr)),
                  let category = MemoryFactCategory(rawValue: String(cString: catStr)) else { continue }

            let fact = String(cString: factStr)
            let passage = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let url = sqlite3_column_text(stmt, 4).flatMap { URL(string: String(cString: $0)) }
            let sha = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let confidence = sqlite3_column_double(stmt, 6)
            let isCorrection = sqlite3_column_int(stmt, 7) != 0
            let supersedesID = sqlite3_column_text(stmt, 8).flatMap { UUID(uuidString: String(cString: $0)) }
            let isStale = sqlite3_column_int(stmt, 9) != 0
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))

            results.append(MemoryFactRecord(
                id: id,
                category: category,
                fact: fact,
                sourcePassage: passage,
                sourceURL: url,
                sourceSHA256: sha,
                confidence: confidence,
                isCorrection: isCorrection,
                supersedesID: supersedesID,
                isStale: isStale,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }
        return results
    }

    func markMemoryStale(id: UUID) throws {
        guard let db else { throw LocalFTSError.closed }
        let sql = "UPDATE memory_facts SET is_stale = 1, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare mark stale")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        guard stepLogged(stmt, context: "mark memory stale") else {
            throw LocalFTSError.executionFailed("Mark memory stale failed")
        }
    }

    func deleteMemory(id: UUID) throws {
        guard let db else { throw LocalFTSError.closed }
        // MS-5/MS-6: drop the FTS row first so a failure can never leave the raw text
        // orphaned in the index after the fact row is gone, and throw on step failure
        // so a caller (forget) can never report success it did not achieve.
        let ftsSQL = "DELETE FROM fts_memories WHERE id = ?;"
        var ftsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare memory FTS delete")
        }
        defer { sqlite3_finalize(ftsStmt) }
        sqlite3_bind_text(ftsStmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        guard stepLogged(ftsStmt, context: "memory FTS delete") else {
            throw LocalFTSError.executionFailed("Memory FTS delete failed")
        }

        let factSQL = "DELETE FROM memory_facts WHERE id = ?;"
        var factStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, factSQL, -1, &factStmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare memory delete")
        }
        defer { sqlite3_finalize(factStmt) }
        sqlite3_bind_text(factStmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        guard stepLogged(factStmt, context: "memory delete") else {
            throw LocalFTSError.executionFailed("Memory delete failed")
        }

        // MS-6: a deleted id must not linger as another record's supersedes pointer.
        let unlinkSQL = "UPDATE memory_facts SET supersedes_id = NULL WHERE supersedes_id = ?;"
        var unlinkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, unlinkSQL, -1, &unlinkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(unlinkStmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(unlinkStmt, context: "supersedes pointer cleanup")
            sqlite3_finalize(unlinkStmt)
        }
    }

    // MARK: - Evidence Indexing & Search

    func indexEvidence(source: ResearchSource) throws {
        guard let db else { throw LocalFTSError.closed }
        let insertSQL = """
        INSERT OR REPLACE INTO document_evidence (id, title, url, kind, text, sha256, bytes_read, retrieved_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare evidence insert")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, source.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source.title, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, source.finalURL.absoluteString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, source.kind.rawValue, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, source.text, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, source.sha256, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 7, Int64(source.bytesRead))
        sqlite3_bind_double(stmt, 8, source.retrievedAt.timeIntervalSince1970)
        if let modified = source.modifiedAt {
            sqlite3_bind_double(stmt, 9, modified.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Insert evidence failed")
        }

        // FTS update
        let ftsDelete = "DELETE FROM fts_evidence WHERE id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsDelete, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, source.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(delStmt, context: "evidence FTS delete")
            sqlite3_finalize(delStmt)
        }

        let ftsInsert = "INSERT INTO fts_evidence (id, title, text) VALUES (?, ?, ?);"
        var ftsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsInsert, -1, &ftsStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(ftsStmt, 1, source.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 2, source.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(ftsStmt, 3, source.text, -1, Self.SQLITE_TRANSIENT)
            _ = stepLogged(ftsStmt, context: "evidence FTS insert")
            sqlite3_finalize(ftsStmt)
        }
    }

    func searchEvidence(query: String, limit: Int = 10) throws -> [EvidenceSearchResult] {
        let strictQuery = sanitizeFTSQuery(query, joinOperator: "AND")
        guard !strictQuery.isEmpty else { return [] }
        let strictResults = try performSearchEvidence(ftsQuery: strictQuery, limit: limit)
        if !strictResults.isEmpty { return strictResults }

        let broadQuery = sanitizeFTSQuery(query, joinOperator: "OR")
        guard !broadQuery.isEmpty, broadQuery != strictQuery else { return [] }
        return try performSearchEvidence(ftsQuery: broadQuery, limit: limit)
    }

    private func performSearchEvidence(ftsQuery: String, limit: Int) throws -> [EvidenceSearchResult] {
        guard let db else { throw LocalFTSError.closed }
        let searchSQL = """
        SELECT e.id, e.title, e.url, e.kind, snippet(fts_evidence, 2, '<b>', '</b>', '...', 32), e.sha256, e.retrieved_at
        FROM fts_evidence f
        JOIN document_evidence e ON f.id = e.id
        WHERE fts_evidence MATCH ?
        ORDER BY bm25(fts_evidence) ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, searchSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw LocalFTSError.prepareFailed("Failed to prepare evidence search")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [EvidenceSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0),
                  let titleStr = sqlite3_column_text(stmt, 1),
                  let urlStr = sqlite3_column_text(stmt, 2),
                  let kindStr = sqlite3_column_text(stmt, 3),
                  let snippetStr = sqlite3_column_text(stmt, 4),
                  let shaStr = sqlite3_column_text(stmt, 5),
                  let id = UUID(uuidString: String(cString: idStr)),
                  let url = URL(string: String(cString: urlStr)) else { continue }

            let title = String(cString: titleStr)
            let kind = String(cString: kindStr)
            let snippet = String(cString: snippetStr)
            let sha = String(cString: shaStr)
            let retrievedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

            results.append(EvidenceSearchResult(
                id: id,
                title: title,
                url: url,
                kind: kind,
                snippet: snippet,
                sha256: sha,
                retrievedAt: retrievedAt
            ))
        }
        return results
    }

    func clearAll() throws {
        try execute(sql: """
        DELETE FROM conversation_records;
        DELETE FROM fts_conversations;
        DELETE FROM memory_facts;
        DELETE FROM fts_memories;
        DELETE FROM memory_tier_state;
        DELETE FROM document_evidence;
        DELETE FROM fts_evidence;
        """)
    }

    private static let ftsStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
        "can", "could", "did", "do", "does", "for", "from", "had", "has", "have",
        "he", "her", "here", "him", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "just", "me", "my", "no", "not", "now", "of",
        "on", "or", "our", "out", "please", "right", "she", "should", "so", "some",
        "tell", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "to", "up", "us", "was", "we", "were", "what", "when", "where",
        "which", "who", "why", "will", "with", "would", "you", "your", "about"
    ]

    private func sanitizeFTSQuery(_ query: String, joinOperator: String = "AND") -> String {
        // Strip out non-alphanumeric chars that break FTS5 token syntax
        let rawTokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return "" }

        let meaningful = rawTokens.filter { !Self.ftsStopWords.contains($0.lowercased()) && $0.count >= 2 }
        let chosen = meaningful.isEmpty ? rawTokens : meaningful
        // Deduplicate while preserving order, cap at 12 tokens for fast FTS5 matching
        var seen = Set<String>()
        var unique: [String] = []
        for token in chosen {
            let lower = token.lowercased()
            if seen.insert(lower).inserted {
                unique.append(token)
                if unique.count >= 12 { break }
            }
        }
        guard !unique.isEmpty else { return "" }
        return unique.map { "\"\($0)\"" }.joined(separator: " \(joinOperator) ")
    }
}

enum LocalFTSError: Error, LocalizedError {
    case openFailed(String)
    case closed
    case prepareFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open error: \(msg)"
        case .closed: return "Database connection is closed"
        case .prepareFailed(let msg): return "SQLite prepare error: \(msg)"
        case .executionFailed(let msg): return "SQLite execution error: \(msg)"
        }
    }
}
