import Foundation
import SQLite3

// Five-tier memory: T1 session, T2 working, T3 key points, T4 long-term summaries,
// T5 core (identity, preferences, corrected facts).
//
// Ageing compresses and promotes; it never deletes. Deletion happens only under an
// explicit memory-pressure budget, oldest first: T1 first, then T2. T3, T4 and T5 are
// never deleted automatically, and T5 survives even when it is the oldest data present.
// Ageing is deterministic: it never calls a model and never reads the wall clock.

/// One of the five retention tiers. The nominal age is how long a record may stay in the
/// tier before ageing compresses and promotes it to the next one.
enum MemoryTier: Int, CaseIterable, Codable, Sendable {
    case session = 1
    case working = 2
    case keyPoints = 3
    case longTerm = 4
    case core = 5

    /// Nominal age after which a record is promoted; `nil` means the tier is terminal.
    var nominalAge: TimeInterval? {
        switch self {
        case .session: return 90 * 86_400    // T1 ≈ 3 months
        case .working: return 182 * 86_400   // T2 ≈ 6 months
        case .keyPoints: return 365 * 86_400 // T3 ≈ 1 year
        case .longTerm, .core: return nil    // T4 and T5 never age
        }
    }

    /// Promotion target used by `age(now:)`. T4 and T5 are terminal.
    var next: MemoryTier? {
        switch self {
        case .session: return .working
        case .working: return .keyPoints
        case .keyPoints: return .longTerm
        case .longTerm, .core: return nil
        }
    }

    /// Only T1 and T2 may ever be deleted automatically, and only under memory pressure.
    var isAutoEvictable: Bool { self == .session || self == .working }

    var label: String {
        switch self {
        case .session: return "T1 session"
        case .working: return "T2 working"
        case .keyPoints: return "T3 key points"
        case .longTerm: return "T4 long-term summaries"
        case .core: return "T5 core"
        }
    }
}

/// Where a memory came from. A user preference, an observation and an inference stay
/// distinguishable all the way through storage and retrieval.
enum MemorySource: String, CaseIterable, Codable, Sendable {
    case userStated
    case observed
    case inferred
    case preference

    /// A preference belongs in T5 (core), as does any corrected fact.
    var isCore: Bool { self == .preference }

    var defaultTier: MemoryTier { isCore ? .core : .session }

    /// Bridge to the fact categories of the existing `LocalFTSStore` schema.
    var factCategory: MemoryFactCategory {
        switch self {
        case .userStated: return .learnedFact
        case .observed: return .systemObservation
        case .inferred: return .projectContext
        case .preference: return .userPreference
        }
    }

    init(factCategory: MemoryFactCategory) {
        switch factCategory {
        case .userPreference: self = .preference
        case .userCorrection: self = .userStated
        case .systemObservation: self = .observed
        case .projectContext: self = .inferred
        case .learnedFact: self = .userStated
        }
    }
}

/// A single memory. The text stays the authoritative, user-editable content.
struct MemoryRecord: Identifiable, Equatable, Sendable {
    /// Fixed per-record overhead included in the byte budget, so pressure stays testable.
    static let overheadBytes = 96

    let id: UUID
    var tier: MemoryTier
    var text: String
    var source: MemorySource
    let createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date
    /// The record that replaced this one; it stays retrievable until the user deletes it.
    var supersededBy: UUID?
    var pinned: Bool
    /// 1 for an ordinary record, more when this record is a compression summary.
    var representsCount: Int

    init(id: UUID, tier: MemoryTier, text: String, source: MemorySource, createdAt: Date,
         updatedAt: Date, lastAccessedAt: Date, supersededBy: UUID? = nil,
         pinned: Bool = false, representsCount: Int = 1) {
        self.id = id
        self.tier = tier
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.supersededBy = supersededBy
        self.pinned = pinned
        self.representsCount = representsCount
    }

    var isSummary: Bool { representsCount > 1 }
    var isSuperseded: Bool { supersededBy != nil }
    var byteCost: Int { Self.overheadBytes + text.utf8.count }
}

/// Errors the tier layer raises on its own; storage errors come from `LocalFTSError`.
enum MemoryTierError: Error, Equatable {
    case emptyText
}

/// An explicit, caller-supplied budget so eviction is decided and tested without touching
/// real RAM. `currentBytes` is the measured corpus size; `nil` makes the store measure it.
struct MemoryPressure: Equatable, Sendable {
    var budgetBytes: Int
    var currentBytes: Int?

    init(budgetBytes: Int, currentBytes: Int? = nil) {
        self.budgetBytes = budgetBytes
        self.currentBytes = currentBytes
    }
}

/// Five-tier memory over the existing `LocalFTSStore` database.
///
/// Fact text lives in the store's `memory_facts` table and is written through its public
/// API, so its FTS5 index and superseding rules stay authoritative. Tier, source, access
/// time, pin and supersession live in `memory_tier_state`, a small side table keyed by the
/// same row id in the same SQLite file; a second database is never opened.
actor MemoryTierStore {
    /// The underlying fact store, shared with the rest of the app.
    let facts: LocalFTSStore

    private var db: OpaquePointer?
    private let metadataURL: URL

    /// Same directory and file name as `LocalFTSStore`, so both share one database file.
    private static let defaultDirectoryName = "Records"
    private static let defaultFileName = "dot_records.sqlite"

    /// Concatenated summaries are bounded; a longer group splits into several summaries.
    static let maxSummaryCharacters = 1200

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) throws {
        facts = try LocalFTSStore(directory: directory)
        if let directory {
            metadataURL = directory.appendingPathComponent(Self.defaultFileName)
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw LocalFTSError.openFailed("Application Support directory unavailable")
            }
            let directory = support.appendingPathComponent("Dot", isDirectory: true)
                .appendingPathComponent(Self.defaultDirectoryName, isDirectory: true)
            metadataURL = directory.appendingPathComponent(Self.defaultFileName)
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(metadataURL.path, &opened, flags, nil) == SQLITE_OK else {
            throw LocalFTSError.openFailed("Failed to open tier metadata at \(metadataURL.path)")
        }
        db = opened
        guard let handle = db else { throw LocalFTSError.closed }
        // Same file and same locking approach as LocalFTSStore (WAL journal, serialized
        // handle); this connection only ever creates and writes the side table below.
        try Self.execute(db: handle, sql: "PRAGMA busy_timeout = 2000;")
        try Self.execute(db: handle, sql: """
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
        """)
    }

    deinit {
        if let handle = db {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - User-facing API

    /// Stores a memory. A preference, and anything that supersedes another record, is
    /// corrected or identity-level content and is therefore held in T5 (core).
    @discardableResult
    func remember(text: String, tier: MemoryTier = .session, source: MemorySource = .userStated,
                  supersedes: UUID? = nil, pinned: Bool = false, now: Date) async throws -> MemoryRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryTierError.emptyText }
        let isCore = source.isCore || supersedes != nil
        let fact = try await facts.saveMemory(
            category: source.factCategory,
            fact: trimmed,
            confidence: 1.0,
            isCorrection: isCore,
            supersedesID: supersedes
        )
        let created = MemoryRecord(id: fact.id, tier: isCore ? .core : tier, text: trimmed, source: source,
                                   createdAt: now, updatedAt: now, lastAccessedAt: now, pinned: pinned)
        try writeMetadata(created)
        if let supersedes {
            try markSuperseded(id: supersedes, by: fact.id, now: now)
        }
        return try record(id: fact.id) ?? created
    }

    /// Full-text recall. Superseded records are excluded and every hit is touched so the
    /// most useful memories are the most recently accessed ones.
    func recall(query: String, limit: Int = 20, now: Date) async throws -> [MemoryRecord] {
        let hits = try await facts.searchMemories(query: query, limit: max(1, limit))
        guard !hits.isEmpty else { return [] }
        for hit in hits {
            try ensureMetadata(id: hit.id, now: now)
        }
        let touch = try prepare("UPDATE memory_tier_state SET last_accessed_at = ? WHERE id = ?;",
                                "Failed to prepare access time update")
        defer { sqlite3_finalize(touch) }
        for hit in hits {
            sqlite3_reset(touch)
            sqlite3_clear_bindings(touch)
            sqlite3_bind_double(touch, 1, now.timeIntervalSince1970)
            sqlite3_bind_text(touch, 2, hit.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            _ = sqlite3_step(touch)
        }
        let stored = Dictionary(uniqueKeysWithValues: try fetchRecords().map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard var found = stored[hit.id] else { return nil }
            found.lastAccessedAt = now
            return found
        }
    }

    /// Explicit user delete (Read / Copy / Delete). Removes the fact and its tier state.
    @discardableResult
    func forget(id: UUID) async throws -> Bool {
        guard try record(id: id) != nil else { return false }
        let stmt = try prepare("DELETE FROM memory_tier_state WHERE id = ?;", "Failed to prepare tier delete")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
        try await facts.deleteMemory(id: id)
        return true
    }

    /// Records are user-editable, including their tier.
    @discardableResult
    func setTier(id: UUID, tier: MemoryTier, now: Date) throws -> MemoryRecord? {
        guard var stored = try record(id: id) else { return nil }
        stored.tier = tier
        stored.updatedAt = now
        try writeMetadata(stored)
        return stored
    }

    /// A pinned record is kept out of automatic eviction.
    @discardableResult
    func setPinned(id: UUID, pinned: Bool, now: Date) throws -> MemoryRecord? {
        guard var stored = try record(id: id) else { return nil }
        stored.pinned = pinned
        stored.updatedAt = now
        try writeMetadata(stored)
        return stored
    }

    /// Oldest first. Superseded archive rows are included only when asked for explicitly.
    func records(tier: MemoryTier? = nil, limit: Int = 200, includeSuperseded: Bool = false) throws -> [MemoryRecord] {
        let filtered = try fetchRecords().filter { stored in
            guard includeSuperseded || !stored.isSuperseded else { return false }
            guard let tier else { return true }
            return stored.tier == tier
        }
        return Array(filtered.prefix(max(0, limit)))
    }

    /// Live (non-superseded) records per tier; every tier is present, zero included.
    func tierCounts() throws -> [MemoryTier: Int] {
        var counts = Dictionary(uniqueKeysWithValues: MemoryTier.allCases.map { ($0, 0) })
        for stored in try fetchRecords() where !stored.isSuperseded {
            counts[stored.tier, default: 0] += 1
        }
        return counts
    }

    /// Bytes the stored corpus occupies, including superseded archive rows.
    func usedBytes() throws -> Int {
        try fetchRecords().reduce(0) { $0 + $1.byteCost }
    }

    // MARK: - Ageing: compress and promote, never delete

    /// Promotes everything past its nominal age, compressing same-source groups as it goes.
    /// One call walks the whole ladder (T1 → T2 → T3 → T4), so a corpus that sat idle for
    /// years catches up. Pinned records are promoted unchanged. T4 and T5 never move.
    @discardableResult
    func age(now: Date) async throws -> [MemoryRecord] {
        var changed: [MemoryRecord] = []
        for tier in MemoryTier.allCases {
            guard let next = tier.next, let nominalAge = tier.nominalAge else { break }
            let cutoff = now.addingTimeInterval(-nominalAge)
            let due = try fetchRecords().filter { $0.tier == tier && !$0.isSuperseded && $0.createdAt <= cutoff }
            guard !due.isEmpty else { continue }
            for pinned in due where pinned.pinned {
                if let promoted = try promote(id: pinned.id, to: next, now: now) {
                    changed.append(promoted)
                }
            }
            for source in MemorySource.allCases {
                let group = due.filter { !$0.pinned && $0.source == source }
                for chunk in Self.summaryChunks(of: group) {
                    if chunk.count == 1, let only = chunk.first {
                        if let promoted = try promote(id: only.id, to: next, now: now) {
                            changed.append(promoted)
                        }
                    } else {
                        changed.append(try await merge(chunk, to: next, now: now))
                    }
                }
            }
        }
        return changed
    }

    /// Oldest-first chunks whose joined text stays within `maxSummaryCharacters`. A record
    /// longer than the bound keeps its own chunk and is therefore promoted unchanged.
    static func summaryChunks(of records: [MemoryRecord]) -> [[MemoryRecord]] {
        let ordered = records.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var chunks: [[MemoryRecord]] = []
        var current: [MemoryRecord] = []
        var length = 0
        for record in ordered {
            if !current.isEmpty, length + 1 + record.text.count > maxSummaryCharacters {
                chunks.append(current)
                current = []
                length = 0
            }
            length += (current.isEmpty ? 0 : 1) + record.text.count
            current.append(record)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func promote(id: UUID, to tier: MemoryTier, now: Date) throws -> MemoryRecord? {
        guard var stored = try record(id: id) else { return nil }
        stored.tier = tier
        stored.updatedAt = now
        try writeMetadata(stored)
        return stored
    }

    /// Compression concatenates a group into one summary that records how many records it
    /// represents. The originals are never rewritten or truncated: they are archived at the
    /// promoted tier, marked superseded by the summary, and stay retrievable through
    /// `records(includeSuperseded:)` until the user deletes them.
    private func merge(_ members: [MemoryRecord], to tier: MemoryTier, now: Date) async throws -> MemoryRecord {
        let text = members.map(\.text).joined(separator: "\n")
        let source = members[0].source
        let fact = try await facts.saveMemory(category: source.factCategory, fact: text, confidence: 1.0)
        let summary = MemoryRecord(id: fact.id, tier: tier, text: text, source: source,
                                   createdAt: members.map(\.createdAt).min() ?? now,
                                   updatedAt: now, lastAccessedAt: now,
                                   representsCount: members.reduce(0) { $0 + $1.representsCount })
        try writeMetadata(summary)
        for var member in members {
            try await facts.markMemoryStale(id: member.id)
            member.tier = tier
            member.supersededBy = summary.id
            member.updatedAt = now
            try writeMetadata(member)
        }
        return try record(id: summary.id) ?? summary
    }

    // MARK: - Eviction: the only path that deletes

    /// Deletes oldest T1 first, then oldest T2, and stops the moment the budget is met.
    /// Pinned records, T3, T4 and T5 are never deleted by this path.
    func evictIfNeeded(pressure: MemoryPressure, now: Date) async throws -> [MemoryRecord] {
        var used = try pressure.currentBytes ?? usedBytes()
        guard used > pressure.budgetBytes else { return [] }
        var deleted: [MemoryRecord] = []
        for tier in MemoryTier.allCases where tier.isAutoEvictable {
            while used > pressure.budgetBytes {
                let candidates = try fetchRecords().filter {
                    $0.tier == tier && !$0.pinned && $0.createdAt <= now
                }
                guard let victim = candidates.first else { break }
                try await forget(id: victim.id)
                used -= victim.byteCost
                deleted.append(victim)
            }
        }
        return deleted
    }

    // MARK: - Tier metadata storage

    private func fetchRecords() throws -> [MemoryRecord] {
        let sql = """
        SELECT f.id, f.category, f.fact, s.tier, s.source,
               COALESCE(s.created_at, f.created_at), COALESCE(s.updated_at, f.updated_at),
               COALESCE(s.last_accessed_at, f.updated_at), s.superseded_by,
               COALESCE(s.pinned, 0), COALESCE(s.represents_count, 1)
        FROM memory_facts f
        LEFT JOIN memory_tier_state s ON s.id = f.id
        ORDER BY COALESCE(s.created_at, f.created_at) ASC, f.id ASC;
        """
        let stmt = try prepare(sql, "Failed to prepare memory listing")
        defer { sqlite3_finalize(stmt) }
        var results: [MemoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0),
                  let categoryText = sqlite3_column_text(stmt, 1),
                  let factText = sqlite3_column_text(stmt, 2),
                  let id = UUID(uuidString: String(cString: idText)),
                  let category = MemoryFactCategory(rawValue: String(cString: categoryText)) else { continue }
            let legacySource = MemorySource(factCategory: category)
            let source = sqlite3_column_text(stmt, 4).flatMap { MemorySource(rawValue: String(cString: $0)) } ?? legacySource
            let storedTier = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? legacySource.defaultTier
                : MemoryTier(rawValue: Int(sqlite3_column_int(stmt, 3))) ?? legacySource.defaultTier
            results.append(MemoryRecord(
                id: id,
                tier: storedTier,
                text: String(cString: factText),
                source: source,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                lastAccessedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                supersededBy: sqlite3_column_text(stmt, 8).flatMap { UUID(uuidString: String(cString: $0)) },
                pinned: sqlite3_column_int(stmt, 9) != 0,
                representsCount: Int(sqlite3_column_int(stmt, 10))
            ))
        }
        return results
    }

    private func record(id: UUID) throws -> MemoryRecord? {
        try fetchRecords().first { $0.id == id }
    }

    /// Facts written by the rest of the app get their tier state materialised on first use.
    private func ensureMetadata(id: UUID, now: Date) throws {
        guard try !hasMetadata(id: id) else { return }
        let sql = "SELECT category, fact, created_at, updated_at FROM memory_facts WHERE id = ?;"
        let stmt = try prepare(sql, "Failed to prepare fact lookup")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let categoryText = sqlite3_column_text(stmt, 0),
              let factText = sqlite3_column_text(stmt, 1),
              let category = MemoryFactCategory(rawValue: String(cString: categoryText)) else { return }
        let source = MemorySource(factCategory: category)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        try writeMetadata(MemoryRecord(id: id, tier: source.defaultTier, text: String(cString: factText),
                                       source: source, createdAt: createdAt,
                                       updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                       lastAccessedAt: now))
    }

    private func markSuperseded(id: UUID, by newID: UUID, now: Date) throws {
        try ensureMetadata(id: id, now: now)
        let stmt = try prepare("UPDATE memory_tier_state SET superseded_by = ?, updated_at = ? WHERE id = ?;",
                               "Failed to prepare supersede update")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, newID.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Supersede update failed")
        }
    }

    private func hasMetadata(id: UUID) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM memory_tier_state WHERE id = ? LIMIT 1;", "Failed to prepare tier lookup")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Tier state is upserted; `created_at` is preserved so ageing always measures the age
    /// of the memory itself, never the age of the last edit.
    private func writeMetadata(_ record: MemoryRecord) throws {
        let sql = """
        INSERT INTO memory_tier_state (id, tier, source, created_at, updated_at, last_accessed_at, superseded_by, pinned, represents_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            tier = excluded.tier,
            source = excluded.source,
            updated_at = excluded.updated_at,
            last_accessed_at = excluded.last_accessed_at,
            superseded_by = excluded.superseded_by,
            pinned = excluded.pinned,
            represents_count = excluded.represents_count;
        """
        let stmt = try prepare(sql, "Failed to prepare tier state write")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(record.tier.rawValue))
        sqlite3_bind_text(stmt, 3, record.source.rawValue, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, record.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, record.lastAccessedAt.timeIntervalSince1970)
        if let supersededBy = record.supersededBy {
            sqlite3_bind_text(stmt, 7, supersededBy.uuidString, -1, Self.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int(stmt, 8, record.pinned ? 1 : 0)
        sqlite3_bind_int(stmt, 9, Int32(record.representsCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Tier state write failed")
        }
    }

    private static func execute(db: OpaquePointer?, sql: String) throws {
        guard let db else { throw LocalFTSError.closed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw LocalFTSError.executionFailed(message)
        }
    }

    private func prepare(_ sql: String, _ message: String) throws -> OpaquePointer {
        guard let db else { throw LocalFTSError.closed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalFTSError.prepareFailed(message)
        }
        return stmt
    }
}
