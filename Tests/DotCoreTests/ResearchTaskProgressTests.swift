import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class ResearchTaskProgressTests: XCTestCase {
    private func session() throws -> WebResearchSession {
        try WebResearchSession(question: "Compare primary sources", queries: ["first source", "second source"])
    }
    private func event(_ operation: UUID, _ sequence: UInt64, _ change: ResearchTaskProgress.Change,
                       generation: UInt64 = 1) -> ResearchTaskProgress.Event {
        .init(operation: operation, generation: generation, sequence: sequence, change: change)
    }
    private func settled() throws -> WebResearchSession {
        var value = try session()
        value.stage = .awaitingLocalSynthesis
        for index in value.queries.indices {
            value.queries[index].status = .completed; value.queries[index].attempts = 1
            value.queries[index].completedAt = Date(timeIntervalSince1970: 10)
        }
        return value
    }
    func testUnknownDiscoveryDoesNotInventAnArcOrETA() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try session()
        XCTAssertTrue(model.receive(event(op, 1, .started(session, resuming: false)), now: 0))
        model.tick(now: 120); XCTAssertEqual(model.progress.halo, .hidden)
        model.tick(now: 120.1); XCTAssertEqual(model.progress.halo, .indeterminate)
        XCTAssertEqual(model.progress.snapshot?.estimate, .unknown)
        XCTAssertTrue(model.progress.textStatus.contains("timing is still uncertain"))
    }
    func testTimeNeverAdvancesUnknownWork() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try session()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.tick(now: 10_000)
        XCTAssertEqual(model.progress.snapshot?.work, .unknown)
        XCTAssertEqual(model.progress.state, .running)
    }
    func testDiscoveryProgressUsesOnlyActualReceipts() throws {
        var model = ResearchTaskProgress(); let op = UUID(); var session = try session()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        session.queries[0].status = .inFlight
        XCTAssertTrue(model.receive(event(op, 2, .checkpoint(session)), now: 2))
        XCTAssertEqual(model.progress.snapshot?.completed, "0 searches completed and 0 sources read")
        session.queries[0].status = .completed
        XCTAssertTrue(model.receive(event(op, 3, .checkpoint(session)), now: 3))
        XCTAssertEqual(model.progress.snapshot?.completed, "1 searches completed and 0 sources read")
        XCTAssertEqual(model.progress.snapshot?.work, .unknown)
    }
    func testSettledPlanHasRealSynthesisAndVerificationUnitsOutstanding() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try settled()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        let old = model.progress.token
        model.receive(event(op, 2, .synthesizing(session)), now: 121)
        XCTAssertNotEqual(model.progress.token?.planID, old?.planID)
        guard case .measured(let work) = model.progress.snapshot?.work else { return XCTFail("Expected closed plan") }
        XCTAssertEqual(work.completedUnits, 2); XCTAssertEqual(work.remainingUnits, 2)
        model.receive(event(op, 3, .verifying(session)), now: 122)
        XCTAssertEqual(model.progress.snapshot?.phase, .finalVerification)
        guard case .measured(let verification) = model.progress.snapshot?.work else { return XCTFail("Expected verification unit") }
        XCTAssertEqual(verification.completedUnits, 3); XCTAssertEqual(verification.remainingUnits, 1)
        XCTAssertEqual(model.progress.halo, .determinate(0.75))
    }
    func testUncertainSearchDoesNotBecomeKnownScope() throws {
        var model = ResearchTaskProgress(); let op = UUID(); var session = try settled()
        session.queries[0].status = .uncertain
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.receive(event(op, 2, .synthesizing(session)), now: 121)
        XCTAssertEqual(model.progress.halo, .indeterminate)
    }
    func testDuplicateAndOutOfOrderEventsAreRejected() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try session()
        let start = event(op, 1, .started(session, resuming: false))
        XCTAssertTrue(model.receive(start, now: 0)); XCTAssertFalse(model.receive(start, now: 1))
        XCTAssertTrue(model.receive(event(op, 4, .checkpoint(session)), now: 2))
        XCTAssertFalse(model.receive(event(op, 3, .failed), now: 3))
        XCTAssertEqual(model.progress.state, .running)
    }
    func testReplacementRejectsOldUpdatesAndOldStart() throws {
        var model = ResearchTaskProgress(); let first = UUID(), second = UUID(), session = try session()
        let old = event(first, 1, .started(session, resuming: false))
        model.receive(old, now: 0)
        model.receive(event(second, 1, .started(try self.session(), resuming: false), generation: 2), now: 1)
        XCTAssertFalse(model.receive(event(first, 2, .failed), now: 2))
        XCTAssertFalse(model.receive(old, now: 3))
        XCTAssertEqual(model.operation, second)
    }
    func testMismatchedTaskCheckpointRejected() throws {
        var model = ResearchTaskProgress(); let op = UUID()
        model.receive(event(op, 1, .started(try session(), resuming: false)), now: 0)
        XCTAssertFalse(model.receive(event(op, 2, .checkpoint(try session())), now: 1))
    }
    func testPauseExcludesTimeAndResumeRetainsPromotionDuration() throws {
        var model = ResearchTaskProgress(); let op = UUID(), resumed = UUID(), session = try session()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.receive(event(op, 2, .paused), now: 100)
        model.tick(now: 900); XCTAssertFalse(model.progress.isLongTask)
        let old = model.progress.token
        model.receive(event(resumed, 1, .started(session, resuming: true), generation: 2), now: 1000)
        XCTAssertNotEqual(old?.runID, model.progress.token?.runID)
        model.tick(now: 1020); XCTAssertFalse(model.progress.isLongTask)
        model.tick(now: 1021); XCTAssertTrue(model.progress.isLongTask)
        XCTAssertFalse(model.receive(event(op, 3, .failed), now: 1022))
    }
    func testResumeOfLongTaskDoesNotReplayStartSpeech() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try session()
        var context = LongTaskProgress.SpeechContext(); context.ready = true
        model.setSpeechContext(context)
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.tick(now: 121)
        let initial = try XCTUnwrap(model.takeSpeech(now: 121)); model.finishSpeech(id: initial.id)
        model.receive(event(op, 2, .paused), now: 122)
        model.receive(event(UUID(), 1, .started(session, resuming: true), generation: 2), now: 1000)
        XCTAssertEqual(model.progress.halo, .indeterminate)
        XCTAssertNil(model.takeSpeech(now: 1001))
    }
    func testResumeAtLocalSynthesisKeepsKnownPlanAndDoesNotReplayRevisionSpeech() throws {
        var model = ResearchTaskProgress(); let operation = UUID(), session = try settled()
        var context = LongTaskProgress.SpeechContext(); context.ready = true
        model.setSpeechContext(context)
        model.receive(event(operation, 1, .started(session, resuming: false)), now: 0)
        model.receive(event(operation, 2, .synthesizing(session)), now: 121)
        let initial = try XCTUnwrap(model.takeSpeech(now: 121)); model.finishSpeech(id: initial.id)
        model.receive(event(operation, 3, .paused), now: 122)

        let resumed = UUID()
        XCTAssertTrue(model.receive(event(resumed, 1, .started(session, resuming: true), generation: 2), now: 1000))
        XCTAssertEqual(model.progress.snapshot?.stage, "Reasoning locally")
        XCTAssertEqual(model.progress.halo, .determinate(0.5))
        let plan = model.progress.token?.planID
        XCTAssertNil(model.takeSpeech(now: 1000))
        XCTAssertTrue(model.receive(event(resumed, 2, .synthesizing(session), generation: 2), now: 1001))
        XCTAssertEqual(model.progress.token?.planID, plan, "Re-entering a saved stage is not a new plan")
        XCTAssertNil(model.progress.planRevisionReason)
        XCTAssertNil(model.takeSpeech(now: 1001), "Resume must not replay a historical plan-change update")
    }
    func testCancelledTaskRejectsLateVerificationAndCanBeExplicitlyResumed() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try settled()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.tick(now: 121); model.cancelSelected(now: 122)
        XCTAssertEqual(model.progress.halo, .hidden)
        XCTAssertFalse(model.receive(event(op, 2, .verifying(session)), now: 123))
        XCTAssertTrue(model.receive(event(UUID(), 1, .started(session, resuming: true), generation: 2), now: 124))
        XCTAssertEqual(model.progress.halo, .determinate(0.5))
    }
    func testStoredDoneStatusAloneNeverCompletes() throws {
        var model = ResearchTaskProgress(); let op = UUID(); var session = try session()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        session.stage = .completed
        XCTAssertFalse(model.receive(event(op, 2, .checkpoint(session)), now: 121))
        XCTAssertEqual(model.progress.state, .running)
    }
    func testInvalidMatchingReadbackCannotComplete() throws {
        var model = ResearchTaskProgress(); let op = UUID(); var session = try settled()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.receive(event(op, 2, .verifying(session)), now: 121)
        session.stage = .completed // No synthesis/evidence, even though both copies match.
        let stored = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
        XCTAssertFalse(model.receive(event(op, 3, .verified(expected: stored, reloaded: stored)), now: 122))
        XCTAssertEqual(model.progress.state, .running)
    }
    func testReadbackRevisionMismatchCannotComplete() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try settled()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.receive(event(op, 2, .verifying(session)), now: 121)
        let expected = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
        let other = WebResearchStoredSession(revision: UUID(), session: session, recoveredAt: nil)
        XCTAssertFalse(model.receive(event(op, 3, .verified(expected: expected, reloaded: other)), now: 122))
    }
    func testBlockedAndFailedRetainActionableStatus() throws {
        var model = ResearchTaskProgress(); let op = UUID()
        model.receive(event(op, 1, .started(try session(), resuming: false)), now: 0)
        model.tick(now: 121)
        let detail = LongTaskProgress.Interruption(reason: "Provider cooldown", nextAction: "Retry after the saved deadline")!
        model.receive(event(op, 2, .blocked(detail)), now: 122)
        XCTAssertEqual(model.progress.state, .blocked(detail)); XCTAssertTrue(model.progress.canResume)
        XCTAssertTrue(model.progress.textStatus.contains("Retry after the saved deadline"))
        model.receive(event(op, 3, .failed), now: 123)
        XCTAssertFalse(model.progress.canResume); XCTAssertTrue(model.progress.textStatus.contains("inspect the error"))
    }
    func testRemovalIsSessionScopedAndRejectsOldDeletion() throws {
        var model = ResearchTaskProgress(); let op = UUID(), session = try session()
        model.receive(event(op, 1, .started(session, resuming: false)), now: 0)
        model.tick(now: 121)
        XCTAssertFalse(model.receive(event(UUID(), 1, .removed(taskID: UUID()), generation: 2), now: 122))
        XCTAssertFalse(model.receive(event(UUID(), 1, .removed(taskID: session.id)), now: 122))
        XCTAssertTrue(model.receive(event(UUID(), 1, .removed(taskID: session.id), generation: 2), now: 122))
        XCTAssertEqual(model.progress.state, .idle); XCTAssertEqual(model.progress.halo, .hidden)
    }
}
