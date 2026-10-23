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

    /// Concatenated summaries are bounded; a longer group splits into several summaries.
    static let maxSummaryCharacters = 1200

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// MS-1: the tier store is handed the app's existing `LocalFTSStore` (ChatView's
    /// single handle) instead of opening a second connection to the same SQLite file.
    /// `LocalFTSStore` creates the `memory_tier_state` table in its schema, and every
    /// read/write here runs inside `facts.withMemoryConnection` on that one handle.
    init(facts: LocalFTSStore) {
        self.facts = facts
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
        return try await facts.withMemoryConnection { db in
            if let supersedes {
                try Self.markSuperseded(id: supersedes, by: fact.id, now: now, db: db)
            }
            // MS-2: when saveMemory deduped onto an existing id whose tier state is
            // already materialised, refresh only the edit/access times and keep the
            // stored tier, pin, supersession and source, so an identical-text write
            // never demotes or unpins a core record. The gate must be real tier state:
            // record(id:) joins the fact row and synthesises a legacy-default record
            // for rows without tier state, which would otherwise swallow every
            // brand-new insert along with the requested tier and the caller's now.
            if try Self.hasMetadata(id: fact.id, db: db),
               var stored = try Self.record(id: fact.id, db: db) {
                stored.updatedAt = now
                stored.lastAccessedAt = now
                try Self.writeMetadata(stored, db: db)
                return stored
            }
            try Self.writeMetadata(created, db: db)
            return created
        }
    }

    /// Full-text recall. Superseded records are excluded and every hit is touched so the
    /// most useful memories are the most recently accessed ones.
    func recall(query: String, limit: Int = 20, now: Date, strictOnly: Bool = false) async throws -> [MemoryRecord] {
        let hits = try await facts.searchMemories(query: query, limit: max(1, limit), strictOnly: strictOnly)
        guard !hits.isEmpty else { return [] }
        return try await facts.withMemoryConnection { db in
            for hit in hits {
                try Self.ensureMetadata(id: hit.id, now: now, db: db)
            }
            let touch = try Self.prepare("UPDATE memory_tier_state SET last_accessed_at = ? WHERE id = ?;",
                                         "Failed to prepare access time update", db: db)
            defer { sqlite3_finalize(touch) }
            for hit in hits {
                sqlite3_reset(touch)
                sqlite3_clear_bindings(touch)
                sqlite3_bind_double(touch, 1, now.timeIntervalSince1970)
                sqlite3_bind_text(touch, 2, hit.id.uuidString, -1, Self.SQLITE_TRANSIENT)
                _ = sqlite3_step(touch)
            }
            let stored = Dictionary(uniqueKeysWithValues: try Self.fetchRecords(db: db).map { ($0.id, $0) })
            let results: [MemoryRecord] = hits.compactMap { hit -> MemoryRecord? in
                // The FTS stale flag and the tier-state supersession are separate rows;
                // a corrected fact must never reappear because only one of them says so.
                guard var found = stored[hit.id], !found.isSuperseded else { return nil }
                found.lastAccessedAt = now
                return found
            }
            // MS-8: the documented recall order is newest-edited first; FTS ranks by
            // relevance, so re-sort to the same key fetchRecords uses.
            return results.sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id > rhs.id : lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    /// Explicit user delete (Read / Copy / Delete). Removes the fact, its tier state
    /// and — recursively — every record whose `superseded_by` points at the forgotten
    /// id, so forgetting a summary also removes the raw archive rows it represents
    /// instead of leaving their text in the database forever.
    @discardableResult
    func forget(id: UUID) async throws -> Bool {
        let doomed = try await facts.withMemoryConnection { db -> [UUID] in
            let all = try Self.fetchRecords(db: db)
            let valid = Set(all.map(\.id))
            var supersededBy: [UUID: [UUID]] = [:]
            for stored in all {
                if let replacedBy = stored.supersededBy {
                    supersededBy[replacedBy, default: []].append(stored.id)
                }
            }
            var queue = [id]
            var seen = Set<UUID>()
            var result: [UUID] = []
            while let current = queue.popLast() {
                guard seen.insert(current).inserted, valid.contains(current) else { continue }
                result.append(current)
                queue.append(contentsOf: supersededBy[current] ?? [])
            }
            return result
        }
        guard doomed.contains(id) else { return false }
        try await facts.withMemoryConnection { db in
            for doomedID in doomed {
                let stmt = try Self.prepare("DELETE FROM memory_tier_state WHERE id = ?;",
                                            "Failed to prepare tier delete", db: db)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, doomedID.uuidString, -1, Self.SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw LocalFTSError.executionFailed("Tier delete failed")
                }
            }
        }
        for doomedID in doomed {
            try await facts.deleteMemory(id: doomedID)
        }
        return true
    }

    /// Records are user-editable, including their tier.
    @discardableResult
    func setTier(id: UUID, tier: MemoryTier, now: Date) async throws -> MemoryRecord? {
        try await facts.withMemoryConnection { db in
            guard var stored = try Self.record(id: id, db: db) else { return nil }
            stored.tier = tier
            stored.updatedAt = now
            try Self.writeMetadata(stored, db: db)
            return stored
        }
    }

    /// A pinned record is kept out of automatic eviction.
    @discardableResult
    func setPinned(id: UUID, pinned: Bool, now: Date) async throws -> MemoryRecord? {
        try await facts.withMemoryConnection { db in
            guard var stored = try Self.record(id: id, db: db) else { return nil }
            stored.pinned = pinned
            stored.updatedAt = now
            try Self.writeMetadata(stored, db: db)
            return stored
        }
    }

    /// Newest first (most recently edited) for recall and listing paths. Superseded
    /// archive rows are included only when asked for explicitly.
    func records(tier: MemoryTier? = nil, limit: Int = 200, includeSuperseded: Bool = false) async throws -> [MemoryRecord] {
        try await facts.withMemoryConnection { db in
            let filtered = try Self.fetchRecords(db: db).filter { stored in
                guard includeSuperseded || !stored.isSuperseded else { return false }
                guard let tier else { return true }
                return stored.tier == tier
            }
            return Array(filtered.prefix(max(0, limit)))
        }
    }

    /// Live (non-superseded) records per tier; every tier is present, zero included.
    func tierCounts() async throws -> [MemoryTier: Int] {
        try await facts.withMemoryConnection { db in
            var counts = Dictionary(uniqueKeysWithValues: MemoryTier.allCases.map { ($0, 0) })
            for stored in try Self.fetchRecords(db: db) where !stored.isSuperseded {
                counts[stored.tier, default: 0] += 1
            }
            return counts
        }
    }

    /// Bytes the stored corpus occupies, including superseded archive rows.
    func usedBytes() async throws -> Int {
        try await facts.withMemoryConnection { db in
            try Self.fetchRecords(db: db).reduce(0) { $0 + $1.byteCost }
        }
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
            let due = try await facts.withMemoryConnection { db in
                try Self.fetchRecords(db: db).filter { $0.tier == tier && !$0.isSuperseded && $0.createdAt <= cutoff }
            }
            guard !due.isEmpty else { continue }
            for pinned in due where pinned.pinned {
                if let promoted = try await promote(id: pinned.id, to: next, now: now) {
                    changed.append(promoted)
                }
            }
            for source in MemorySource.allCases {
                let group = due.filter { !$0.pinned && $0.source == source }
                for chunk in Self.summaryChunks(of: group) {
                    if chunk.count == 1, let only = chunk.first {
                        if let promoted = try await promote(id: only.id, to: next, now: now) {
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

    private func promote(id: UUID, to tier: MemoryTier, now: Date) async throws -> MemoryRecord? {
        try await facts.withMemoryConnection { db in
            guard var stored = try Self.record(id: id, db: db) else { return nil }
            stored.tier = tier
            stored.updatedAt = now
            try Self.writeMetadata(stored, db: db)
            return stored
        }
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
        for member in members {
            try await facts.markMemoryStale(id: member.id)
        }
        return try await facts.withMemoryConnection { db in
            try Self.writeMetadata(summary, db: db)
            for var member in members {
                member.tier = tier
                member.supersededBy = summary.id
                member.updatedAt = now
                try Self.writeMetadata(member, db: db)
            }
            return try Self.record(id: summary.id, db: db) ?? summary
        }
    }

    // MARK: - Eviction: the only path that deletes

    /// Deletes oldest T1 first, then oldest T2, and stops the moment the budget is met.
    /// Pinned records, T3, T4 and T5 are never deleted by this path. MS-3: each pressure
    /// pass is capped at a quarter of the evictable bytes, so one RAM-pressure event can
    /// never wipe all recent working memory while T4/T5 sit untouched.
    func evictIfNeeded(pressure: MemoryPressure, now: Date) async throws -> [MemoryRecord] {
        let initial = pressure.currentBytes
        var used: Int
        if let initial { used = initial } else { used = try await usedBytes() }
        guard used > pressure.budgetBytes else { return [] }
        // Evictable = unpinned T1+T2 rows only, oldest first with T1 exhausted before T2.
        let candidates = try await facts.withMemoryConnection { db in
            try Self.fetchRecords(db: db).filter {
                $0.tier.isAutoEvictable && !$0.pinned && $0.createdAt <= now
            }
        }
        guard !candidates.isEmpty else { return [] }
        let ordered = candidates.sorted {
            ($0.tier.rawValue, $0.createdAt, $0.id.uuidString) < ($1.tier.rawValue, $1.createdAt, $1.id.uuidString)
        }
        let evictableBytes = ordered.reduce(0) { $0 + $1.byteCost }
        let passCap = max(1, evictableBytes / 4)
        var deleted: [MemoryRecord] = []
        var deletedBytes = 0
        for victim in ordered {
            guard used > pressure.budgetBytes else { break }
            // Always take at least one victim so pressure makes progress; then stop
            // once this pass has freed its quarter of the evictable corpus.
            guard deleted.isEmpty || deletedBytes < passCap else { break }
            try await forget(id: victim.id)
            used -= victim.byteCost
            deletedBytes += victim.byteCost
            deleted.append(victim)
        }
        return deleted
    }

    // MARK: - Tier metadata storage

    /// MS-8: newest first (by last edit) for recall and listing; eviction sorts its
    /// candidates oldest-first itself because that is the only place age order matters.
    private static func fetchRecords(db: OpaquePointer) throws -> [MemoryRecord] {
        let sql = """
        SELECT f.id, f.category, f.fact, s.tier, s.source,
               COALESCE(s.created_at, f.created_at), COALESCE(s.updated_at, f.updated_at),
               COALESCE(s.last_accessed_at, f.updated_at), s.superseded_by,
               COALESCE(s.pinned, 0), COALESCE(s.represents_count, 1)
        FROM memory_facts f
        LEFT JOIN memory_tier_state s ON s.id = f.id
        ORDER BY COALESCE(s.updated_at, f.updated_at) DESC, f.id DESC;
        """
        let stmt = try prepare(sql, "Failed to prepare memory listing", db: db)
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

    private static func record(id: UUID, db: OpaquePointer) throws -> MemoryRecord? {
        try fetchRecords(db: db).first { $0.id == id }
    }

    /// Facts written by the rest of the app get their tier state materialised on first use.
    private static func ensureMetadata(id: UUID, now: Date, db: OpaquePointer) throws {
        guard try !hasMetadata(id: id, db: db) else { return }
        let sql = "SELECT category, fact, created_at, updated_at FROM memory_facts WHERE id = ?;"
        let stmt = try prepare(sql, "Failed to prepare fact lookup", db: db)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let categoryText = sqlite3_column_text(stmt, 0),
              let factText = sqlite3_column_text(stmt, 1),
              let category = MemoryFactCategory(rawValue: String(cString: categoryText)) else { return }
        let source = MemorySource(factCategory: category)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        try writeMetadata(MemoryRecord(id: id, tier: source.defaultTier, text: String(cString: factText),
                                       source: source, createdAt: createdAt,
                                       updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                       lastAccessedAt: now), db: db)
    }

    private static func markSuperseded(id: UUID, by newID: UUID, now: Date, db: OpaquePointer) throws {
        try ensureMetadata(id: id, now: now, db: db)
        let stmt = try prepare("UPDATE memory_tier_state SET superseded_by = ?, updated_at = ? WHERE id = ?;",
                               "Failed to prepare supersede update", db: db)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, newID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Supersede update failed")
        }
    }

    private static func hasMetadata(id: UUID, db: OpaquePointer) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM memory_tier_state WHERE id = ? LIMIT 1;", "Failed to prepare tier lookup", db: db)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Tier state is upserted; `created_at` is preserved so ageing always measures the age
    /// of the memory itself, never the age of the last edit.
    private static func writeMetadata(_ record: MemoryRecord, db: OpaquePointer) throws {
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
        let stmt = try prepare(sql, "Failed to prepare tier state write", db: db)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(record.tier.rawValue))
        sqlite3_bind_text(stmt, 3, record.source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, record.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, record.lastAccessedAt.timeIntervalSince1970)
        if let supersededBy = record.supersededBy {
            sqlite3_bind_text(stmt, 7, supersededBy.uuidString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int(stmt, 8, record.pinned ? 1 : 0)
        sqlite3_bind_int(stmt, 9, Int32(record.representsCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw LocalFTSError.executionFailed("Tier state write failed")
        }
    }

    private static func prepare(_ sql: String, _ message: String, db: OpaquePointer) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalFTSError.prepareFailed(message)
        }
        return stmt
    }
}
