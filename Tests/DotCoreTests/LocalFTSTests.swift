import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class LocalFTSTests: XCTestCase {

    func testMemoryDatabaseCreationAndSchema() async throws {
        let store = try LocalFTSStore(inMemory: true)
        let results = try await store.searchConversations(query: "anything")
        XCTAssertTrue(results.isEmpty)
    }

    func testConversationIndexingAndFTS5Search() async throws {
        let store = try LocalFTSStore(inMemory: true)
        let turnID = UUID()
        let record = ConversationHistoryRecord(
            id: UUID(),
            date: Date(),
            role: .assistant,
            text: "The rust compiler achieves incredible speed and memory safety through zero-cost abstractions.",
            turnID: turnID,
            generation: .complete,
            playback: .completed,
            generationCompletedAt: Date(),
            playbackStartedAt: Date(),
            playbackCompletedAt: Date(),
            endedAt: Date(),
            failureStage: nil,
            textTruncated: false
        )

        try await store.indexConversation(record: record)

        let search1 = try await store.searchConversations(query: "compiler speed")
        XCTAssertEqual(search1.count, 1)
        XCTAssertEqual(search1.first?.id, record.id)
        XCTAssertEqual(search1.first?.text, record.text)

        let search2 = try await store.searchConversations(query: "abstractions")
        XCTAssertEqual(search2.count, 1)

        let search3 = try await store.searchConversations(query: "python django")
        XCTAssertTrue(search3.isEmpty)
    }

    func testMemoryFactAndSupersedingCorrection() async throws {
        let store = try LocalFTSStore(inMemory: true)

        // Initial fact
        let fact1 = try await store.saveMemory(
            category: .userPreference,
            fact: "User prefers British Kokoro Isabella voice for Dot companion",
            sourcePassage: "Please keep bf_isabella voice for all speech",
            confidence: 0.95
        )
        XCTAssertFalse(fact1.isStale)

        // Correction superseding fact1
        let fact2 = try await store.saveMemory(
            category: .userCorrection,
            fact: "User explicitly instructed Kokoro Isabella voice must run pure Rust Candle without Python helper",
            sourcePassage: "write all app in rust first so we can remove python and make app faster",
            confidence: 1.0,
            isCorrection: true,
            supersedesID: fact1.id
        )

        // Searching without stale facts should only return fact2
        let currentMemories = try await store.searchMemories(query: "Isabella voice", includeStale: false)
        XCTAssertEqual(currentMemories.count, 1)
        XCTAssertEqual(currentMemories.first?.id, fact2.id)
        XCTAssertTrue(currentMemories.first?.isCorrection == true)

        // Searching with stale facts should return both
        let allMemories = try await store.searchMemories(query: "Isabella voice", includeStale: true)
        XCTAssertEqual(allMemories.count, 2)
        XCTAssertTrue(allMemories.contains(where: { $0.id == fact1.id && $0.isStale }))
        XCTAssertTrue(allMemories.contains(where: { $0.id == fact2.id && !$0.isStale }))
    }

    func testDeleteMemory() async throws {
        let store = try LocalFTSStore(inMemory: true)
        let fact = try await store.saveMemory(
            category: .learnedFact,
            fact: "Temporary notes about Apple Silicon M4 unified memory architecture",
            confidence: 0.8
        )

        let before = try await store.searchMemories(query: "unified memory")
        XCTAssertEqual(before.count, 1)

        try await store.deleteMemory(id: fact.id)

        let after = try await store.searchMemories(query: "unified memory")
        XCTAssertTrue(after.isEmpty)
    }

    func testEvidenceIndexingAndSearch() async throws {
        let store = try LocalFTSStore(inMemory: true)
        let source = ResearchSource(
            id: UUID(),
            originalURL: URL(string: "https://developer.apple.com/documentation/screencapturekit")!,
            finalURL: URL(string: "https://developer.apple.com/documentation/screencapturekit")!,
            title: "ScreenCaptureKit Documentation",
            kind: .webPage,
            retrievedAt: Date(),
            modifiedAt: nil,
            bytesRead: 4096,
            sha256: "abc123def456",
            pagesRead: nil,
            text: "ScreenCaptureKit provides high-performance screen recording and capture streams for macOS applications.",
            truncated: false,
            transportReceipt: .httpsOnlyV1
        )

        try await store.indexEvidence(source: source)

        let results = try await store.searchEvidence(query: "screen recording streams")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, source.id)
        XCTAssertEqual(results.first?.title, "ScreenCaptureKit Documentation")
        XCTAssertTrue(results.first?.snippet.contains("ScreenCaptureKit") == true)
    }

    func testStrictSearchNeverFallsBackToAnyWord() async throws {
        // R6: "forget about X" deletes strict matches only.
        let store = try LocalFTSStore(inMemory: true)
        _ = try await store.saveMemory(category: .learnedFact, fact: "Friday pizza night with the team")
        _ = try await store.saveMemory(category: .learnedFact, fact: "Dentist appointment on Friday at 3 PM")
        let broad = try await store.searchMemories(query: "pizza Tuesday")
        XCTAssertFalse(broad.isEmpty, "ordinary recall may widen to any word")
        let strict = try await store.searchMemories(query: "pizza Tuesday", strictOnly: true)
        XCTAssertTrue(strict.isEmpty)
        let exact = try await store.searchMemories(query: "the dentist on Friday", strictOnly: true)
        XCTAssertEqual(exact.map(\.fact), ["Dentist appointment on Friday at 3 PM"])
    }

    func testClearAll() async throws {
        let store = try LocalFTSStore(inMemory: true)
        _ = try await store.saveMemory(category: .projectContext, fact: "Dot companion local only")
        try await store.clearAll()
        let results = try await store.searchMemories(query: "companion")
        XCTAssertTrue(results.isEmpty)
    }
}
