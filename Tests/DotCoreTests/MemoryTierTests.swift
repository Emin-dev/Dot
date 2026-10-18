import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

/// Five-tier memory: ageing compresses and promotes, eviction is the only deletion path,
/// and it happens only under an explicit pressure budget, oldest T1 first, then T2.
final class MemoryTierTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private var directories: [URL] = []

    private func at(_ days: Double) -> Date { epoch.addingTimeInterval(days * day) }

    /// A real SQLite file in a temporary directory, so the fact table and the tier side
    /// table are exercised in the same database exactly as they are in the app.
    private func makeStore() throws -> MemoryTierStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dot-memory-tiers-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        return try MemoryTierStore(facts: LocalFTSStore(directory: directory))
    }

    override func tearDownWithError() throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
    }

    func testNominalAgesTerminalTiersAndSourceMapping() {
        XCTAssertEqual(MemoryTier.session.nominalAge, 90 * day)
        XCTAssertEqual(MemoryTier.working.nominalAge, 182 * day)
        XCTAssertEqual(MemoryTier.keyPoints.nominalAge, 365 * day)
        XCTAssertNil(MemoryTier.longTerm.nominalAge)
        XCTAssertNil(MemoryTier.core.nominalAge)

        XCTAssertEqual(MemoryTier.session.next, .working)
        XCTAssertEqual(MemoryTier.working.next, .keyPoints)
        XCTAssertEqual(MemoryTier.keyPoints.next, .longTerm)
        XCTAssertNil(MemoryTier.longTerm.next)
        XCTAssertNil(MemoryTier.core.next)

        XCTAssertTrue(MemoryTier.session.isAutoEvictable)
        XCTAssertTrue(MemoryTier.working.isAutoEvictable)
        XCTAssertFalse(MemoryTier.keyPoints.isAutoEvictable)
        XCTAssertFalse(MemoryTier.longTerm.isAutoEvictable)
        XCTAssertFalse(MemoryTier.core.isAutoEvictable)

        XCTAssertTrue(MemorySource.preference.isCore)
        XCTAssertEqual(MemorySource.preference.defaultTier, .core)
        XCTAssertEqual(MemorySource.observed.defaultTier, .session)
        XCTAssertEqual(MemorySource(factCategory: .userPreference), .preference)
        XCTAssertEqual(MemorySource(factCategory: .userCorrection), .userStated)
        XCTAssertEqual(MemorySource(factCategory: .systemObservation), .observed)
        XCTAssertEqual(MemorySource(factCategory: .projectContext), .inferred)
        XCTAssertEqual(MemorySource.preference.factCategory, .userPreference)
    }

    func testThreeMonthAgeingPromotesSessionToWorking() async throws {
        let store = try makeStore()
        let record = try await store.remember(text: "session note about rust", source: .observed, now: at(0))
        XCTAssertEqual(record.tier, .session)

        let tooEarly = try await store.age(now: at(89))
        XCTAssertTrue(tooEarly.isEmpty)

        let promoted = try await store.age(now: at(91))
        XCTAssertEqual(promoted.map(\.id), [record.id])
        XCTAssertEqual(promoted.first?.tier, .working)
        XCTAssertEqual(promoted.first?.text, record.text)
        XCTAssertEqual(promoted.first?.representsCount, 1)
        XCTAssertNil(promoted.first?.supersededBy)

        let session = try await store.records(tier: .session)
        let working = try await store.records(tier: .working)
        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(working.map(\.id), [record.id])
    }

    func testCompressionMergesASameSourceGroupAndKeepsOriginalsRetrievable() async throws {
        let store = try makeStore()
        let first = try await store.remember(text: "alpha rust note", source: .observed, now: at(0))
        let second = try await store.remember(text: "beta rust note", source: .observed, now: at(1))
        let third = try await store.remember(text: "gamma rust note", source: .observed, now: at(2))
        let other = try await store.remember(text: "delta inferred note", source: .inferred, now: at(3))

        let changed = try await store.age(now: at(100))
        XCTAssertEqual(changed.count, 2)

        // The three same-source records become one summary; the lone record is promoted as is.
        let working = try await store.records(tier: .working)
        XCTAssertEqual(working.count, 2)
        let summary = try XCTUnwrap(working.first { $0.isSummary })
        XCTAssertEqual(summary.tier, .working)
        XCTAssertEqual(summary.source, .observed)
        XCTAssertEqual(summary.representsCount, 3)
        XCTAssertEqual(summary.text, "alpha rust note\nbeta rust note\ngamma rust note")
        XCTAssertEqual(working.first { $0.id == other.id }?.representsCount, 1)

        // The originals are never rewritten, truncated or dropped: they are archived at the
        // promoted tier and point at the summary that represents them.
        let archived = try await store.records(tier: .working, includeSuperseded: true).filter(\.isSuperseded)
        XCTAssertEqual(Set(archived.map(\.id)), Set([first.id, second.id, third.id]))
        XCTAssertTrue(archived.allSatisfy { $0.supersededBy == summary.id })
        XCTAssertEqual(Set(archived.map(\.text)), Set([first.text, second.text, third.text]))
        let everything = try await store.records(includeSuperseded: true)
        XCTAssertEqual(everything.count, 5) // four originals plus the summary: nothing deleted

        // Recall reaches the summary, not the archived originals.
        let hits = try await store.recall(query: "alpha rust", now: at(101))
        XCTAssertEqual(hits.map(\.id), [summary.id])
        XCTAssertEqual(hits.first?.tier, .working)
    }

    func testSixAndTwelveMonthAgeingWalkTheLadderToLongTermAndStop() async throws {
        let store = try makeStore()
        let record = try await store.remember(text: "second tier note", tier: .working, source: .userStated, now: at(0))

        let beforeSixMonths = try await store.age(now: at(180))
        XCTAssertTrue(beforeSixMonths.isEmpty)

        let atSixMonths = try await store.age(now: at(190))
        XCTAssertEqual(atSixMonths.first?.tier, .keyPoints)

        let atOneYear = try await store.age(now: at(370))
        XCTAssertEqual(atOneYear.map(\.id), [record.id])
        XCTAssertEqual(atOneYear.first?.tier, .longTerm)

        // T4 is terminal: it never promotes again and is never deleted.
        let afterYears = try await store.age(now: at(4000))
        XCTAssertTrue(afterYears.isEmpty)
        let deleted = try await store.evictIfNeeded(pressure: MemoryPressure(budgetBytes: 0), now: at(4000))
        XCTAssertTrue(deleted.isEmpty)
        let longTerm = try await store.records(tier: .longTerm)
        XCTAssertEqual(longTerm.map(\.id), [record.id])
    }

    func testPreferenceAndCorrectedFactAreHeldInCoreAndNeverAge() async throws {
        let store = try makeStore()
        let preference = try await store.remember(text: "i prefer the isabella voice", tier: .session,
                                                 source: .preference, now: at(0))
        XCTAssertEqual(preference.tier, .core)
        let old = try await store.remember(text: "the user works on the old project", source: .userStated, now: at(0))
        let correction = try await store.remember(text: "the user works on the new project", source: .userStated,
                                                  supersedes: old.id, now: at(1))
        XCTAssertEqual(correction.tier, .core)

        let aged = try await store.age(now: at(4000))
        XCTAssertTrue(aged.isEmpty)
        let counts = try await store.tierCounts()
        XCTAssertEqual(counts[.core], 2)
        XCTAssertEqual(counts[.session], 0)
        let core = try await store.records(tier: .core)
        XCTAssertEqual(core.map(\.id), [correction.id, preference.id], "Core lists newest-edited first")
    }

    func testEvictionTakesOldestSessionThenOldestWorkingAndStops() async throws {
        let store = try makeStore()
        let first = try await store.remember(text: "oldest session note", source: .observed, now: at(-30))
        let second = try await store.remember(text: "second session note", source: .observed, now: at(-20))
        let third = try await store.remember(text: "third session note", source: .observed, now: at(-10))
        let workingOne = try await store.remember(text: "first working note", tier: .working, source: .observed, now: at(-5))
        let workingTwo = try await store.remember(text: "second working note", tier: .working, source: .observed, now: at(-4))
        let keyPoints = try await store.remember(text: "a key point", tier: .keyPoints, source: .observed, now: at(-3))
        let longTerm = try await store.remember(text: "a long term summary", tier: .longTerm, source: .observed, now: at(-2))
        let core = try await store.remember(text: "core identity fact", tier: .core, source: .userStated, now: at(-1))

        // A budget that is only relieved once exactly two records are gone.
        let used = try await store.usedBytes()
        let budget = used - first.byteCost - second.byteCost
        let deleted = try await store.evictIfNeeded(
            pressure: MemoryPressure(budgetBytes: budget, currentBytes: used), now: at(0))
        XCTAssertEqual(deleted.map(\.id), [first.id, second.id])
        XCTAssertEqual(deleted.map(\.text), [first.text, second.text])

        // Same rule across the tier boundary: T1 is exhausted before T2 is touched,
        // with the byte cap allowing one victim per pass at these sizes.
        let after = try await store.usedBytes()
        let more = try await store.evictIfNeeded(
            pressure: MemoryPressure(budgetBytes: after - third.byteCost - workingOne.byteCost, currentBytes: after),
            now: at(1))
        XCTAssertEqual(more.map(\.id), [third.id])

        let afterSecond = try await store.usedBytes()
        let tierTwo = try await store.evictIfNeeded(
            pressure: MemoryPressure(budgetBytes: afterSecond - workingOne.byteCost, currentBytes: afterSecond),
            now: at(2))
        XCTAssertEqual(tierTwo.map(\.id), [workingOne.id], "T1 is exhausted before T2 is touched")

        // It stopped as soon as the pressure was relieved.
        let remaining = Set(try await store.records(includeSuperseded: true).map(\.id))
        XCTAssertEqual(remaining, Set([workingTwo.id, keyPoints.id, longTerm.id, core.id]))
    }

    func testEvictionNeverDeletesPinnedKeyPointsLongTermOrCore() async throws {
        let store = try makeStore()
        let pinned = try await store.remember(text: "pinned session note", source: .observed, pinned: true, now: at(-100))
        let session = try await store.remember(text: "old session note", source: .observed, now: at(-90))
        let working = try await store.remember(text: "old working note", tier: .working, source: .observed, now: at(-80))
        let keyPoints = try await store.remember(text: "a key point", tier: .keyPoints, source: .observed, now: at(-70))
        let longTerm = try await store.remember(text: "a long term summary", tier: .longTerm, source: .observed, now: at(-60))
        let core = try await store.remember(text: "core identity fact", tier: .core, source: .userStated, now: at(-50))

        let firstPass = try await store.evictIfNeeded(pressure: MemoryPressure(budgetBytes: 0), now: at(0))
        XCTAssertEqual(Set(firstPass.map(\.id)), Set([session.id]), "Capped pass takes the oldest evictable record")
        let secondPass = try await store.evictIfNeeded(pressure: MemoryPressure(budgetBytes: 0), now: at(1))
        XCTAssertEqual(Set(secondPass.map(\.id)), Set([working.id]), "Then the working record; nothing else")

        let survivors = Set(try await store.records(includeSuperseded: true).map(\.id))
        XCTAssertEqual(survivors, Set([pinned.id, keyPoints.id, longTerm.id, core.id]))
    }

    func testCoreRecordSurvivesEvenWhenItIsTheOldestRecordInTheStore() async throws {
        let store = try makeStore()
        let core = try await store.remember(text: "oldest core identity fact", tier: .core, source: .userStated, now: at(-1000))
        let session = try await store.remember(text: "newer session note", source: .observed, now: at(-1))
        XCTAssertLessThan(core.createdAt, session.createdAt)

        let deleted = try await store.evictIfNeeded(pressure: MemoryPressure(budgetBytes: 0), now: at(0))
        XCTAssertEqual(deleted.map(\.id), [session.id])
        let survivors = try await store.records(tier: .core)
        XCTAssertEqual(survivors.map(\.id), [core.id])
    }

    func testRecallFindsPromotedRecordAtItsNewTierAndTouchesAccessTime() async throws {
        let store = try makeStore()
        let record = try await store.remember(text: "the rust compiler avoids garbage collection",
                                             source: .observed, now: at(0))
        XCTAssertEqual(record.lastAccessedAt, at(0))
        _ = try await store.age(now: at(100))

        let hits = try await store.recall(query: "rust compiler", now: at(101))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, record.id)
        XCTAssertEqual(hits.first?.tier, .working)
        XCTAssertEqual(hits.first?.lastAccessedAt, at(101))

        let stored = try await store.records(tier: .working)
        XCTAssertEqual(stored.first?.lastAccessedAt, at(101))
    }

    func testExplicitUserDeleteRemovesARecord() async throws {
        let store = try makeStore()
        let record = try await store.remember(text: "temporary note about apples", source: .observed, now: at(0))
        let deleted = try await store.forget(id: record.id)
        XCTAssertTrue(deleted)
        let remaining = try await store.records(includeSuperseded: true)
        XCTAssertTrue(remaining.isEmpty)
        let hits = try await store.recall(query: "apples", now: at(1))
        XCTAssertTrue(hits.isEmpty)
        let again = try await store.forget(id: record.id)
        XCTAssertFalse(again)
    }

    func testSupersedingKeepsTheNewerFactAndArchivesTheOlder() async throws {
        let store = try makeStore()
        let older = try await store.remember(text: "the user prefers the isabella voice", source: .preference, now: at(0))
        let newer = try await store.remember(text: "the user now prefers the kokoro voice", source: .preference,
                                             supersedes: older.id, now: at(1))
        XCTAssertEqual(newer.tier, .core)

        let live = try await store.records(tier: .core)
        XCTAssertEqual(live.map(\.id), [newer.id])

        let withArchive = try await store.records(tier: .core, includeSuperseded: true)
        let archived = try XCTUnwrap(withArchive.first { $0.id == older.id })
        XCTAssertEqual(archived.supersededBy, newer.id)
        XCTAssertEqual(archived.text, older.text)

        let hits = try await store.recall(query: "isabella voice", now: at(2))
        XCTAssertEqual(hits.map(\.id), [newer.id])
    }

    func testRecallNeverReturnsAFactWhoseTierStateIsSuperseded() async throws {
        let store = try makeStore()
        let older = try await store.remember(text: "the user prefers the isabella voice", source: .preference, now: at(0))
        let newer = try await store.remember(text: "the user now prefers the kokoro voice", source: .preference,
                                             supersedes: older.id, now: at(1))
        // Simulate drifted data where the FTS stale flag was cleared but the tier
        // state still records the supersession. Recall must trust the tier state.
        _ = try await store.facts.saveMemory(id: older.id, category: .userPreference, fact: older.text)
        let hits = try await store.recall(query: "voice", now: at(2))
        XCTAssertFalse(hits.contains { $0.id == older.id })
        XCTAssertTrue(hits.contains { $0.id == newer.id })
    }

    func testTierCountsAndManualTierEditAreUserEditable() async throws {
        let store = try makeStore()
        let record = try await store.remember(text: "promote me by hand", source: .observed, now: at(0))

        let moved = try await store.setTier(id: record.id, tier: .core, now: at(1))
        XCTAssertEqual(moved?.tier, .core)
        let core = try await store.records(tier: .core)
        XCTAssertEqual(core.map(\.id), [record.id])

        let pinned = try await store.setPinned(id: record.id, pinned: true, now: at(2))
        XCTAssertEqual(pinned?.pinned, true)

        var counts = try await store.tierCounts()
        XCTAssertEqual(counts[.core], 1)
        XCTAssertEqual(counts.values.reduce(0, +), 1)

        // A pinned record survives maximum pressure wherever it sits.
        _ = try await store.setTier(id: record.id, tier: .session, now: at(3))
        let deleted = try await store.evictIfNeeded(pressure: MemoryPressure(budgetBytes: 0), now: at(4))
        XCTAssertTrue(deleted.isEmpty)
        counts = try await store.tierCounts()
        XCTAssertEqual(counts[.session], 1)
    }

    /// MS-2: an identical-text write dedups onto the stored row and must keep the
    /// stored core tier, pin and supersession instead of rewriting them from the new
    /// call's defaults, so a re-stated preference can never be demoted or unpinned.
    func testIdenticalTextRewritePreservesCoreTierAndPin() async throws {
        let store = try makeStore()
        let original = try await store.remember(text: "i prefer the isabella voice", source: .preference, now: at(0))
        XCTAssertEqual(original.tier, .core)
        let pinned = try await store.setPinned(id: original.id, pinned: true, now: at(1))
        XCTAssertEqual(pinned?.pinned, true)

        let rewritten = try await store.remember(text: "i prefer the isabella voice", source: .observed, now: at(2))
        XCTAssertEqual(rewritten.id, original.id, "Identical text is the same memory, not a second one")
        XCTAssertEqual(rewritten.tier, .core, "The stored core tier survives a re-stated preference")
        XCTAssertTrue(rewritten.pinned, "The stored pin survives a re-stated preference")
        XCTAssertEqual(rewritten.source, .preference, "The stored source survives a re-stated preference")

        let counts = try await store.tierCounts()
        XCTAssertEqual(counts.values.reduce(0, +), 1)
        let stored = try await store.records(tier: .core)
        XCTAssertEqual(stored.map(\.id), [original.id])
        XCTAssertTrue(stored[0].pinned)
    }

    /// MS-3: one pressure pass frees at most a quarter of the evictable bytes, so a
    /// single RAM-pressure event can never wipe all recent working memory at once.
    func testEvictionPassCapsAtAQuarterOfEvictableBytes() async throws {
        let store = try makeStore()
        var records: [MemoryRecord] = []
        for index in 0..<8 {
            records.append(try await store.remember(text: "session note number \(index)", source: .observed, now: at(Double(index) - 30)))
        }
        let used = try await store.usedBytes()
        let evictableBytes = records.reduce(0) { $0 + $1.byteCost }
        let cap = max(1, evictableBytes / 4)
        XCTAssertEqual(records.map(\.byteCost).reduce(0, +), evictableBytes)

        let deleted = try await store.evictIfNeeded(
            pressure: MemoryPressure(budgetBytes: 0, currentBytes: used), now: at(0))
        let freedBytes = deleted.reduce(0) { $0 + $1.byteCost }
        XCTAssertEqual(deleted.count, 2, "Exactly the quarter-cap's worth of records leave in one pass")
        XCTAssertLessThanOrEqual(freedBytes, cap)

        let survivors = try await store.records(tier: .session)
        XCTAssertEqual(survivors.count, 6, "The rest survives for a later pressure pass")
    }

    /// MS-7: clearAll removes the tier side table together with the facts, so a later
    /// write of the same fact id cannot resurrect the old tier state.
    func testClearAllAlsoClearsMemoryTierState() async throws {
        let store = try makeStore()
        let id = UUID()
        _ = try await store.facts.saveMemory(id: id, category: .userPreference, fact: "core preference fact")
        _ = try await store.remember(text: "core preference fact", source: .preference, now: at(0))
        let coreCount = try await store.tierCounts()[.core]
        XCTAssertEqual(coreCount, 1)

        try await store.facts.clearAll()
        let remaining = try await store.tierCounts().values.reduce(0, +)
        XCTAssertEqual(remaining, 0)
        let afterClear = try await store.records(includeSuperseded: true)
        XCTAssertTrue(afterClear.isEmpty)

        // Re-inserting the same fact id must start without the old core tier state.
        _ = try await store.facts.saveMemory(id: id, category: .systemObservation, fact: "core preference fact")
        let restored = try await store.records(includeSuperseded: true)
        XCTAssertEqual(restored.map(\.id), [id])
        XCTAssertEqual(restored.map(\.tier), [.session],
                       "clearAll must clear memory_tier_state, not just the fact table")
    }

    /// MS-8: recall returns matches newest-edited first, and editing an older fact
    /// moves it ahead of its newer neighbours.
    func testRecallReturnsHitsNewestEditedFirst() async throws {
        let store = try makeStore()
        let older = try await store.remember(text: "alpha rust note", source: .observed, now: at(-10))
        let newer = try await store.remember(text: "beta rust note", source: .observed, now: at(-5))

        let hits = try await store.recall(query: "rust note", now: at(0))
        XCTAssertEqual(hits.map(\.id), [newer.id, older.id])

        _ = try await store.setTier(id: older.id, tier: .session, now: at(1))
        let touched = try await store.recall(query: "rust note", now: at(2))
        XCTAssertEqual(touched.map(\.id), [older.id, newer.id],
                       "The most recently edited fact leads recall")
    }
}
