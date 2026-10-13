import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

private typealias Progress = LongTaskProgress

/// Real model inputs from a small source-review plan. No timers, devices, models,
/// UI or generated percentage estimates are substituted for completed work.
private final class ProgressFixture {
    var core = Progress()
    var now = 100.0
    var token: Progress.Token
    var sequence: UInt64 = 0
    static let estimate = Progress.Estimate.range(Progress.EstimateRange(lowerSeconds: 180, upperSeconds: 300)!)
    static func snapshot(_ completed: Int = 0, total: Int = 100,
                         phase: Progress.Phase = .working,
                         estimate: Progress.Estimate = ProgressFixture.estimate,
                         unknown: Bool = false) -> Progress.Snapshot {
        Progress.Snapshot(stage: phase == .working ? "Reviewing sources" : "Verifying findings",
                          completed: "Reviewed \(completed) source units",
                          remainingPlan: phase == .working ? "review the remaining sources and verify the answer" : "verify the final answer",
                          work: unknown ? .unknown : .measured(Progress.MeasuredWork(completedUnits: completed, remainingUnits: total - completed)!),
                          phase: phase, estimate: estimate)!
    }
    init(kind: Progress.Kind = .work, snapshot: Progress.Snapshot = ProgressFixture.snapshot(),
         mode: Progress.StartMode = .fresh) {
        var model = Progress()
        model.setSpeechContext(.init(ready: true))
        let initial = model.start(taskID: UUID(), goal: "Compare the source findings", kind: kind,
                                  snapshot: snapshot, now: 100, mode: mode)!
        core = model; token = initial
    }
    @discardableResult func report(_ completed: Int, phase: Progress.Phase = .working,
                                    estimate: Progress.Estimate = ProgressFixture.estimate, after: Double = 20) -> Bool {
        now += after; sequence += 1
        return core.report(token: token, sequence: sequence,
                           snapshot: Self.snapshot(completed, phase: phase, estimate: estimate), now: now)
    }
    func take(after: Double = 0) -> Progress.SpeechUpdate? {
        now += after; return core.takeSpeech(now: now)
    }
    func finish(_ speech: Progress.SpeechUpdate?) {
        if let speech { XCTAssertTrue(core.finishSpeech(id: speech.id)) }
    }
    func revise(_ snapshot: Progress.Snapshot, reason: String = "two sources need deeper checking") {
        now += 20
        token = core.revisePlan(token: token, snapshot: snapshot, reason: reason, now: now)!
        sequence = 0
    }
    static var interruption: Progress.Interruption {
        .init(reason: "A source is unavailable", nextAction: "Retry the source or continue without it")!
    }
    static var verified: Progress.VerifiedResult {
        .init(evidenceID: "verification:source-review-42", summary: "Sources and answer checked")!
    }
}

final class LongTaskProgressTests: XCTestCase {
    func testInitialLongTaskHasOneHaloAndGoalStepEstimateSpeech() throws {
        let fixture = ProgressFixture()
        XCTAssertEqual(fixture.core.halo, .determinate(0))
        let speech = try XCTUnwrap(fixture.take())
        XCTAssertEqual(speech.reason, .checkpoint(.start))
        XCTAssertTrue(speech.text.contains("Compare the source findings"))
        XCTAssertTrue(speech.text.contains("first, review the remaining sources and verify the answer"))
        XCTAssertTrue(speech.text.contains("3 to 5 minutes"))
        XCTAssertFalse(speech.text.contains("%"))
        XCTAssertFalse(speech.invitesReply)
        XCTAssertTrue(fixture.core.isSpeechCurrent(speech))
        XCTAssertNil(fixture.take())
        fixture.finish(speech)
        XCTAssertNil(fixture.take(after: 20))
    }

    func testExpectedTwoMinuteBoundaryAndShortQuestionExclusion() {
        for (seconds, expectedLong) in [(120, false), (121, true)] {
            let estimate = Progress.Estimate.range(.init(lowerSeconds: seconds, upperSeconds: seconds)!)
            let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(estimate: estimate))
            XCTAssertEqual(fixture.core.isLongTask, expectedLong)
        }
        let question = ProgressFixture(kind: .shortQuestion)
        XCTAssertFalse(question.core.isLongTask)
        XCTAssertTrue(question.core.tick(token: question.token, now: 1_000))
        XCTAssertEqual(question.core.halo, .hidden)
        XCTAssertNil(question.core.takeSpeech(now: 1_000))
    }

    func testInitiallyShortWorkPromotesOnlyAfterTwoMinutesAndOnlyOnce() throws {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(estimate: .unknown))
        XCTAssertEqual(fixture.core.halo, .hidden)
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: 220))
        XCTAssertFalse(fixture.core.isLongTask)
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: 220.001))
        XCTAssertTrue(fixture.core.isLongTask)
        let speech = try XCTUnwrap(fixture.core.takeSpeech(now: 220.001))
        XCTAssertEqual(speech.reason, .checkpoint(.start))
        XCTAssertTrue(speech.text.contains("timing is still uncertain"))
        fixture.finish(speech)
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: 10_000))
        XCTAssertNil(fixture.core.takeSpeech(now: 10_000))
        XCTAssertEqual(fixture.core.halo, .determinate(0))
    }

    func testRevisedEstimateCanPromoteBeforeElapsedThreshold() {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(estimate: .unknown))
        XCTAssertTrue(fixture.report(10, after: 1))
        XCTAssertTrue(fixture.core.isLongTask)
        XCTAssertEqual(fixture.take()?.reason, .checkpoint(.start))
    }

    func testNewLongPlanPromotesWithGoalAndTransparentRevision() throws {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(estimate: .unknown))
        fixture.revise(ProgressFixture.snapshot(10))
        XCTAssertTrue(fixture.core.isLongTask)
        let speech = try XCTUnwrap(fixture.take())
        XCTAssertEqual(speech.reason, .checkpoint(.start))
        XCTAssertTrue(speech.text.contains("Compare the source findings"))
        XCTAssertTrue(speech.text.contains("The plan changed because"))
        XCTAssertTrue(speech.text.contains("3 to 5 minutes"))
    }

    func testUnknownScopeStaysIndeterminateWithoutTimerMilestonesOrCountdown() throws {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(estimate: .unknown, unknown: true))
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: 221))
        XCTAssertEqual(fixture.core.halo, .indeterminate)
        let start = try XCTUnwrap(fixture.core.takeSpeech(now: 221))
        fixture.finish(start)
        let status = fixture.core.textStatus
        for now in [1_000.0, 5_000, 50_000] {
            XCTAssertTrue(fixture.core.tick(token: fixture.token, now: now))
            XCTAssertEqual(fixture.core.halo, .indeterminate)
            XCTAssertEqual(fixture.core.textStatus, status)
            XCTAssertNil(fixture.core.takeSpeech(now: now))
        }
    }

    func testExactMeasuredThresholdsSpeakOnceWithCompletedAndNext() throws {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        let crossings: [(Int, Progress.Checkpoint?)] = [(49, nil), (50, .halfway),
                                  (51, nil), (79, nil), (80, .mostWorkFinished), (81, nil),
                                  (94, nil), (95, .finalVerification), (96, nil)]
        for (units, expected) in crossings {
            XCTAssertTrue(fixture.report(units, phase: units >= 94 ? .finalVerification : .working))
            let speech = fixture.take()
            XCTAssertEqual(speech?.reason, expected.map { Progress.SpeechReason.checkpoint($0) })
            if let speech {
                XCTAssertTrue(speech.text.contains("Reviewed \(units) source units"))
                XCTAssertTrue(speech.text.contains("next,"))
                XCTAssertFalse(speech.text.contains("%"))
                fixture.finish(speech)
            }
        }
        XCTAssertEqual(fixture.core.halo, .determinate(0.96))
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: fixture.now + 5_000))
        XCTAssertEqual(fixture.core.halo, .determinate(0.96))
    }

    func testJumpAcrossMultipleThresholdsCoalescesToLatest() {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        XCTAssertTrue(fixture.report(96, phase: .finalVerification))
        let speech = fixture.take()
        XCTAssertEqual(speech?.reason, .checkpoint(.finalVerification))
        fixture.finish(speech)
        XCTAssertNil(fixture.take(after: 20))
    }

    func testNinetyFiveRequiresRealFinalVerificationEvenAtHighMeasuredFraction() {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        XCTAssertTrue(fixture.report(96))
        let eighty = fixture.take()
        XCTAssertEqual(eighty?.reason, .checkpoint(.mostWorkFinished))
        fixture.finish(eighty)
        XCTAssertTrue(fixture.report(96, phase: .finalVerification))
        let final = fixture.take()
        XCTAssertEqual(final?.reason, .checkpoint(.finalVerification))
        fixture.finish(final)
        XCTAssertTrue(fixture.report(96, phase: .finalVerification))
        XCTAssertNil(fixture.take())
    }

    func testFinalVerificationStageAloneDoesNotInventNinetyFive() {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        XCTAssertTrue(fixture.report(80, phase: .finalVerification))
        XCTAssertEqual(fixture.take()?.reason, .checkpoint(.mostWorkFinished))
        XCTAssertEqual(fixture.core.halo, .determinate(0.8))
    }

    func testPlanRevisionCanHonestlyRegressAndRejectOldGeneration() throws {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        fixture.report(80); fixture.finish(fixture.take())
        let old = fixture.token
        fixture.revise(ProgressFixture.snapshot(20))
        XCTAssertEqual(fixture.core.halo, .determinate(0.2))
        XCTAssertNotEqual(old.planID, fixture.token.planID)
        XCTAssertFalse(fixture.core.report(token: old, sequence: 1_000,
                                           snapshot: ProgressFixture.snapshot(99), now: fixture.now))
        let revision = try XCTUnwrap(fixture.take())
        XCTAssertEqual(revision.reason, .planRevised)
        XCTAssertTrue(revision.text.contains("two sources need deeper checking"))
        XCTAssertTrue(fixture.core.textStatus.contains("plan changed"))
        fixture.finish(revision)
        XCTAssertTrue(fixture.report(50))
        let half = fixture.take()
        XCTAssertEqual(half?.reason, .checkpoint(.halfway))
        fixture.finish(half)
        XCTAssertTrue(fixture.report(50))
        XCTAssertNil(fixture.take())
    }

    func testRevisionAtAlreadyCrossedThresholdDoesNotReplayIt() {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        fixture.revise(ProgressFixture.snapshot(80))
        fixture.finish(fixture.take())
        XCTAssertTrue(fixture.report(81))
        XCTAssertNil(fixture.take())
        XCTAssertTrue(fixture.report(95, phase: .finalVerification))
        XCTAssertEqual(fixture.take()?.reason, .checkpoint(.finalVerification))
    }

    func testUnknownAndMeasuredScopeChangesRequireExplicitPlanRevision() {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(unknown: true))
        XCTAssertFalse(fixture.report(50))
        fixture.revise(ProgressFixture.snapshot(50))
        XCTAssertEqual(fixture.core.halo, .determinate(0.5))
        XCTAssertFalse(fixture.core.report(token: fixture.token, sequence: 1,
                                           snapshot: ProgressFixture.snapshot(unknown: true), now: fixture.now))
        fixture.revise(ProgressFixture.snapshot(estimate: .unknown, unknown: true))
        XCTAssertEqual(fixture.core.halo, .indeterminate)
        XCTAssertTrue(fixture.core.textStatus.contains("timing is still uncertain"))
    }

    func testOutOfOrderDuplicateRegressionAndDenominatorChangesAreAtomicRejections() {
        let fixture = ProgressFixture()
        XCTAssertTrue(fixture.report(50))
        let snapshot = fixture.core.snapshot
        for (sequence, value) in [(UInt64(1), ProgressFixture.snapshot(80)),
                                   (0, ProgressFixture.snapshot(80)),
                                   (2, ProgressFixture.snapshot(49)),
                                   (2, ProgressFixture.snapshot(50, total: 200))] {
            XCTAssertFalse(fixture.core.report(token: fixture.token, sequence: sequence, snapshot: value, now: fixture.now))
            XCTAssertEqual(fixture.core.snapshot, snapshot)
        }
        XCTAssertTrue(fixture.core.report(token: fixture.token, sequence: 2,
                                          snapshot: ProgressFixture.snapshot(80), now: fixture.now))
    }

    func testReturningFromVerificationRequiresRevision() {
        let fixture = ProgressFixture()
        XCTAssertTrue(fixture.report(95, phase: .finalVerification))
        XCTAssertFalse(fixture.report(96, phase: .working))
        fixture.revise(ProgressFixture.snapshot(40), reason: "verification found missing evidence")
        XCTAssertEqual(fixture.core.snapshot?.phase, .working)
        XCTAssertEqual(fixture.core.halo, .determinate(0.4))
    }

    func testBriefForegroundGatesRetainOnlyLatestCheckpointAndNeverOverlap() {
        for gate in 0..<4 {
            let fixture = ProgressFixture()
            fixture.finish(fixture.take())
            var context = Progress.SpeechContext(ready: true)
            switch gate {
            case 0: context.userSpeaking = true
            case 1: context.listening = true
            case 2: context.voiceBusy = true
            default: context.foregroundInterrupted = true
            }
            fixture.core.setSpeechContext(context)
            fixture.report(50); XCTAssertNil(fixture.take())
            fixture.report(80); XCTAssertNil(fixture.take())
            fixture.core.setSpeechContext(.init(ready: true))
            let speech = fixture.take()
            XCTAssertEqual(speech?.reason, .checkpoint(.mostWorkFinished))
            fixture.finish(speech)
            XCTAssertNil(fixture.take(after: 20))
        }
    }

    func testMuteQuietCallsAndUnavailableVoiceDiscardDeferredSpeech() {
        for gate in 0..<4 {
            let fixture = ProgressFixture()
            fixture.finish(fixture.take())
            fixture.report(50)
            var context = Progress.SpeechContext(ready: true)
            switch gate {
            case 0: context.muted = true
            case 1: context.quiet = true
            case 2: context.callActive = true
            default: context.ready = false
            }
            fixture.core.setSpeechContext(context)
            fixture.report(80)
            XCTAssertNil(fixture.take())
            XCTAssertTrue(fixture.core.textStatus.contains("Reviewed 80"))
            fixture.core.setSpeechContext(.init(ready: true))
            XCTAssertNil(fixture.take(after: 20))
            fixture.report(95, phase: .finalVerification)
            XCTAssertEqual(fixture.take()?.reason, .checkpoint(.finalVerification))
        }
    }

    func testGateRevokesTakenSpeechWithoutReplayingItOrAcceptingLateFinish() throws {
        let fixture = ProgressFixture()
        let speech = try XCTUnwrap(fixture.take())
        XCTAssertEqual(fixture.core.setSpeechContext(.init(ready: true, userSpeaking: true)), speech.id)
        XCTAssertFalse(fixture.core.isSpeechCurrent(speech))
        XCTAssertFalse(fixture.core.finishSpeech(id: speech.id))
        fixture.core.setSpeechContext(.init(ready: true))
        XCTAssertNil(fixture.take(after: 20))
        fixture.report(50)
        let next = try XCTUnwrap(fixture.take())
        XCTAssertFalse(fixture.core.finishSpeech(id: speech.id))
        XCTAssertTrue(fixture.core.isSpeechCurrent(next))
    }

    func testSpeechSpacingAndSingleInFlightSlotCoalesceWhileBusy() throws {
        let fixture = ProgressFixture()
        let start = try XCTUnwrap(fixture.take())
        fixture.report(50, after: 1)
        XCTAssertNil(fixture.take())
        fixture.finish(start)
        XCTAssertNil(fixture.take(), "Speech spacing applies even after fast synthesis/playback")
        fixture.report(80, after: 1)
        let next = try XCTUnwrap(fixture.take(after: 13))
        XCTAssertEqual(next.reason, .checkpoint(.mostWorkFinished))
        fixture.finish(next)
        XCTAssertNil(fixture.take(after: 15))
    }

    func testPausedAndBlockedStatesHaveReasonsAndResumeWithoutSpeechBurst() {
        for blocked in [false, true] {
            let fixture = ProgressFixture()
            fixture.finish(fixture.take())
            fixture.report(80)
            let old = fixture.token
            let accepted = blocked
                ? fixture.core.block(token: old, detail: ProgressFixture.interruption, now: fixture.now)
                : fixture.core.pause(token: old, detail: ProgressFixture.interruption, now: fixture.now)
            XCTAssertTrue(accepted)
            XCTAssertTrue(fixture.core.canResume)
            XCTAssertTrue(fixture.core.canStop)
            XCTAssertTrue(fixture.core.textStatus.contains(blocked ? "Blocked:" : "Paused:"))
            XCTAssertTrue(fixture.core.textStatus.contains("Retry the source"))
            XCTAssertNil(fixture.take(after: 1_000))
            XCTAssertFalse(fixture.core.report(token: old, sequence: 100,
                                               snapshot: ProgressFixture.snapshot(95, phase: .finalVerification), now: fixture.now))
            fixture.token = fixture.core.resume(token: old, now: fixture.now)!
            fixture.sequence = 0
            XCTAssertNotEqual(fixture.token.runID, old.runID)
            XCTAssertEqual(fixture.token.planID, old.planID)
            XCTAssertNil(fixture.take())
            XCTAssertFalse(fixture.core.report(token: old, sequence: 101,
                                               snapshot: ProgressFixture.snapshot(95, phase: .finalVerification), now: fixture.now))
            fixture.report(95, phase: .finalVerification)
            XCTAssertEqual(fixture.take()?.reason, .checkpoint(.finalVerification))
        }
    }

    func testPausedDurationDoesNotArtificiallyPromoteInitiallyShortTask() {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(estimate: .unknown))
        XCTAssertTrue(fixture.core.pause(token: fixture.token, detail: ProgressFixture.interruption, now: 110))
        fixture.token = fixture.core.resume(token: fixture.token, now: 1_000)!
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: 1_110))
        XCTAssertFalse(fixture.core.isLongTask)
        XCTAssertTrue(fixture.core.tick(token: fixture.token, now: 1_110.01))
        XCTAssertTrue(fixture.core.isLongTask)
    }

    func testRestoredTaskStartsAtHonestFractionWithoutHistoricalSpeech() {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(80),
                                      mode: .restored(elapsedRunningSeconds: 180, wasLongTask: true))
        XCTAssertEqual(fixture.core.halo, .determinate(0.8))
        XCTAssertNil(fixture.take())
        fixture.report(81); XCTAssertNil(fixture.take())
        fixture.report(95, phase: .finalVerification)
        XCTAssertEqual(fixture.take()?.reason, .checkpoint(.finalVerification))
    }

    func testRestartSameTaskAndSelectDifferentTaskBothRejectOldCallbacks() throws {
        for sameTask in [true, false] {
            let fixture = ProgressFixture()
            let speech = try XCTUnwrap(fixture.take()), old = fixture.token
            let taskID = sameTask ? old.taskID : UUID()
            let next = try XCTUnwrap(fixture.core.start(taskID: taskID, goal: "Review a new answer",
                                                       snapshot: ProgressFixture.snapshot(80), now: fixture.now,
                                                       mode: .restored(elapsedRunningSeconds: 300, wasLongTask: true)))
            XCTAssertEqual(fixture.core.token, next)
            XCTAssertNotEqual(next.runID, old.runID)
            XCTAssertFalse(fixture.core.isSpeechCurrent(speech))
            XCTAssertFalse(fixture.core.finishSpeech(id: speech.id))
            XCTAssertFalse(fixture.core.cancel(token: old, now: fixture.now))
            XCTAssertFalse(fixture.core.report(token: old, sequence: 1_000,
                                               snapshot: ProgressFixture.snapshot(95, phase: .finalVerification), now: fixture.now))
            XCTAssertFalse(fixture.core.completeVerified(token: old, sequence: 1_001,
                                                          result: ProgressFixture.verified, now: fixture.now))
            XCTAssertNil(fixture.take())
            XCTAssertEqual(fixture.core.halo, .determinate(0.8))
            XCTAssertTrue(fixture.core.textStatus.hasPrefix("Review a new answer"))
        }
    }

    func testCancellationClearsQueuedAndTakenSpeechAndCannotBecomeSuccess() throws {
        let fixture = ProgressFixture()
        let speech = try XCTUnwrap(fixture.take())
        fixture.report(95, phase: .finalVerification)
        XCTAssertTrue(fixture.core.cancel(token: fixture.token, now: fixture.now))
        XCTAssertEqual(fixture.core.state, .cancelled)
        XCTAssertEqual(fixture.core.halo, .hidden)
        XCTAssertFalse(fixture.core.canResume)
        XCTAssertFalse(fixture.core.isSpeechCurrent(speech))
        XCTAssertNil(fixture.take(after: 20))
        XCTAssertFalse(fixture.core.completeVerified(token: fixture.token, sequence: 100,
                                                      result: ProgressFixture.verified, now: fixture.now))
        XCTAssertFalse(fixture.report(99, phase: .finalVerification))
    }

    func testFailureIsDistinctAndTerminalButRetainsActionableStatus() {
        let fixture = ProgressFixture()
        XCTAssertTrue(fixture.core.fail(token: fixture.token, detail: ProgressFixture.interruption, now: fixture.now))
        XCTAssertEqual(fixture.core.state, .failed(ProgressFixture.interruption))
        XCTAssertTrue(fixture.core.textStatus.contains("Failed:"))
        XCTAssertTrue(fixture.core.textStatus.contains("continue without it"))
        XCTAssertFalse(fixture.core.canStop)
        XCTAssertFalse(fixture.core.canResume)
        XCTAssertNil(fixture.core.resume(token: fixture.token, now: fixture.now))
        XCTAssertNil(fixture.take())
        XCTAssertFalse(fixture.report(95, phase: .finalVerification))
    }

    func testOnlyExplicitCurrentFinalVerificationReceiptCompletesRing() {
        let fixture = ProgressFixture()
        XCTAssertFalse(fixture.core.completeVerified(token: fixture.token, sequence: 1,
                                                      result: ProgressFixture.verified, now: fixture.now))
        fixture.report(99, phase: .finalVerification)
        XCTAssertEqual(fixture.core.halo, .determinate(0.99))
        XCTAssertFalse(fixture.core.completeVerified(token: fixture.token, sequence: 1,
                                                      result: ProgressFixture.verified, now: fixture.now))
        XCTAssertTrue(fixture.core.completeVerified(token: fixture.token, sequence: 2,
                                                     result: ProgressFixture.verified, now: fixture.now))
        XCTAssertEqual(fixture.core.halo, .verifiedComplete)
        XCTAssertEqual(fixture.core.state, .completed(ProgressFixture.verified))
        XCTAssertTrue(fixture.core.textStatus.contains("verified; Sources and answer checked"))
        XCTAssertNil(fixture.take())
        XCTAssertFalse(fixture.core.completeVerified(token: fixture.token, sequence: 3,
                                                      result: ProgressFixture.verified, now: fixture.now))
        XCTAssertFalse(fixture.report(99, phase: .finalVerification))
        XCTAssertFalse(fixture.core.cancel(token: fixture.token, now: fixture.now))
    }

    func testUnknownWorkCanFinishFromRealVerificationWithoutInventedMilestones() {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(unknown: true))
        fixture.finish(fixture.take())
        XCTAssertTrue(fixture.core.report(token: fixture.token, sequence: 1,
                                          snapshot: ProgressFixture.snapshot(phase: .finalVerification, unknown: true), now: fixture.now))
        XCTAssertEqual(fixture.core.halo, .indeterminate)
        XCTAssertNil(fixture.take())
        XCTAssertTrue(fixture.core.completeVerified(token: fixture.token, sequence: 2,
                                                     result: ProgressFixture.verified, now: fixture.now))
        XCTAssertEqual(fixture.core.halo, .verifiedComplete)
    }

    func testCompletionCannotUsePausedOrSupersededVerification() {
        let fixture = ProgressFixture(snapshot: ProgressFixture.snapshot(95, phase: .finalVerification))
        let old = fixture.token
        XCTAssertTrue(fixture.core.pause(token: old, detail: ProgressFixture.interruption, now: fixture.now))
        XCTAssertFalse(fixture.core.completeVerified(token: old, sequence: 1,
                                                      result: ProgressFixture.verified, now: fixture.now))
        fixture.token = fixture.core.resume(token: old, now: fixture.now)!
        XCTAssertFalse(fixture.core.completeVerified(token: old, sequence: 2,
                                                      result: ProgressFixture.verified, now: fixture.now))
        let resumed = fixture.token
        fixture.revise(ProgressFixture.snapshot(10))
        XCTAssertFalse(fixture.core.completeVerified(token: resumed, sequence: 3,
                                                      result: ProgressFixture.verified, now: fixture.now))
    }

    func testEstimatesAreSpokenOnlyInitiallyOrWhenMateriallyChanged() throws {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        let near = Progress.Estimate.range(Progress.EstimateRange(lowerSeconds: 170, upperSeconds: 290)!)
        fixture.report(50, estimate: near)
        let half = try XCTUnwrap(fixture.take())
        XCTAssertFalse(half.text.contains("minutes remaining"))
        fixture.finish(half)
        let changed = Progress.Estimate.range(Progress.EstimateRange(lowerSeconds: 60, upperSeconds: 120)!)
        fixture.report(80, estimate: changed)
        let eighty = try XCTUnwrap(fixture.take())
        XCTAssertTrue(eighty.text.contains("1 to 2 minutes remaining"))
        fixture.finish(eighty)
        fixture.report(95, phase: .finalVerification, estimate: .unknown)
        XCTAssertTrue(try XCTUnwrap(fixture.take()).text.contains("timing is still uncertain"))
    }

    func testRevisionCarriesReasonEvenWhenLaterCheckpointCoalescesItsSpeech() throws {
        let fixture = ProgressFixture()
        fixture.finish(fixture.take())
        fixture.core.setSpeechContext(.init(ready: true, listening: true))
        fixture.revise(ProgressFixture.snapshot(10, estimate: .unknown))
        fixture.report(80, estimate: .unknown)
        fixture.core.setSpeechContext(.init(ready: true))
        let speech = try XCTUnwrap(fixture.take())
        XCTAssertEqual(speech.reason, .checkpoint(.mostWorkFinished))
        XCTAssertTrue(speech.text.contains("The plan changed because two sources need deeper checking"))
        XCTAssertTrue(speech.text.contains("timing is still uncertain"))
        fixture.finish(speech)
        XCTAssertNil(fixture.take(after: 20))
    }

    func testLongTaskPresentationDoesNotFlickerAwayAfterShorterEstimate() {
        let fixture = ProgressFixture()
        let short = Progress.Estimate.range(Progress.EstimateRange(lowerSeconds: 10, upperSeconds: 20)!)
        fixture.revise(ProgressFixture.snapshot(20, estimate: short))
        XCTAssertTrue(fixture.core.isLongTask)
        XCTAssertEqual(fixture.core.halo, .determinate(0.2))
    }

    func testInvalidUnitsCannotOverflowOrRepresentUnverifiedCompletion() {
        for (completed, remaining) in [(-1, 10), (0, 0), (100, 0), (10, -1),
                                       (Int.max, 1), (1, Int.max), (1_000_000, 1), (999_999, 2)] {
            XCTAssertNil(Progress.MeasuredWork(completedUnits: completed, remainingUnits: remaining))
        }
        let maximum = Progress.MeasuredWork(completedUnits: 999_999, remainingUnits: 1)!
        XCTAssertLessThan(maximum.fraction, 1)
        XCTAssertEqual(maximum.totalUnits, Progress.maximumUnits)
    }

    func testInvalidTextAndMissingActionOrVerificationEvidenceAreRejected() {
        for text in ["", "   ", "bad\ntext", "bad\u{7F}text", String(repeating: "é", count: 121)] {
            XCTAssertNil(Progress.Snapshot(stage: text, completed: "none", remainingPlan: "verify", work: .unknown))
            XCTAssertNil(Progress.Snapshot(stage: "review", completed: text, remainingPlan: "verify", work: .unknown))
            XCTAssertNil(Progress.Snapshot(stage: "review", completed: "none", remainingPlan: text, work: .unknown))
            XCTAssertNil(Progress.Interruption(reason: text, nextAction: "Retry"))
            XCTAssertNil(Progress.Interruption(reason: "Paused", nextAction: text))
            XCTAssertNil(Progress.VerifiedResult(evidenceID: text, summary: "Checked"))
            XCTAssertNil(Progress.VerifiedResult(evidenceID: "receipt-1", summary: text))
        }
    }

    func testInvalidEstimateRangesAndOutwardRounding() {
        for (lower, upper) in [(0, 20), (-1, 20), (20, 10), (1, Int.max)] {
            XCTAssertNil(Progress.EstimateRange(lowerSeconds: lower, upperSeconds: upper))
        }
        XCTAssertEqual(Progress.Estimate.range(.init(lowerSeconds: 61, upperSeconds: 121)!).text,
                       "about 1 to 3 minutes remaining")
        XCTAssertEqual(Progress.Estimate.range(.init(lowerSeconds: 30, upperSeconds: 90)!).text,
                       "up to about 2 minutes remaining")
    }

    func testInvalidClocksAndInvalidRestartCannotDisturbCurrentTask() {
        let fixture = ProgressFixture()
        let old = fixture.token, snapshot = fixture.core.snapshot
        for now in [Double.nan, .infinity, -.infinity, -1, 99] {
            XCTAssertFalse(fixture.core.tick(token: old, now: now))
            XCTAssertFalse(fixture.core.report(token: old, sequence: 1,
                                               snapshot: ProgressFixture.snapshot(80), now: now))
            XCTAssertFalse(fixture.core.cancel(token: old, now: now))
        }
        for elapsed in [Double.nan, .infinity, -1] {
            XCTAssertNil(fixture.core.start(taskID: UUID(), goal: "A replacement",
                                            snapshot: ProgressFixture.snapshot(), now: 100,
                                            mode: .restored(elapsedRunningSeconds: elapsed, wasLongTask: true)))
        }
        XCTAssertNil(fixture.core.start(taskID: UUID(), goal: "", snapshot: ProgressFixture.snapshot(), now: 100))
        XCTAssertNil(fixture.core.start(taskID: UUID(), goal: "A replacement", snapshot: ProgressFixture.snapshot(), now: .nan))
        XCTAssertEqual(fixture.core.token, old)
        XCTAssertEqual(fixture.core.snapshot, snapshot)
    }

    func testInvalidRevisionDoesNotInvalidatePreparedSpeech() throws {
        let fixture = ProgressFixture()
        let speech = try XCTUnwrap(fixture.take())
        XCTAssertNil(fixture.core.revisePlan(token: fixture.token, snapshot: ProgressFixture.snapshot(20),
                                             reason: "", now: fixture.now))
        XCTAssertTrue(fixture.core.isSpeechCurrent(speech))
        fixture.revise(ProgressFixture.snapshot(20))
        XCTAssertFalse(fixture.core.isSpeechCurrent(speech))
        XCTAssertFalse(fixture.core.finishSpeech(id: speech.id))
    }

    func testVoiceReadinessDefaultsToFailClosedWithoutStartCatchup() {
        var core = Progress()
        let token = core.start(taskID: UUID(), goal: "Check sources", snapshot: ProgressFixture.snapshot(), now: 100)!
        XCTAssertNil(core.takeSpeech(now: 100))
        core.setSpeechContext(.init(ready: true))
        XCTAssertNil(core.takeSpeech(now: 100))
        XCTAssertTrue(core.report(token: token, sequence: 1, snapshot: ProgressFixture.snapshot(50), now: 120))
        XCTAssertEqual(core.takeSpeech(now: 120)?.reason, .checkpoint(.halfway))
    }
}
