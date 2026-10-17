import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

/// Exercises the production follow-up controller with its real playback and capture
/// policies. It does not open devices, synthesize speech, or claim acoustic coverage.
@MainActor
private final class FollowupFixture {
    var now = 100.0
    var environment = VoiceFollowup.Environment(ready: true, microphoneAuthorized: true,
                                                screenAuthorized: true, interacting: false)
    var invitations: [(turn: UUID, continuation: UUID)] = []
    lazy var controller: VoiceFollowup = {
        let value = VoiceFollowup(clock: { [unowned self] in self.now }, automaticScheduling: false)
        value.environment = { [unowned self] in self.environment }
        value.onInvite = { [unowned self] turn, continuation in
            self.invitations.append((turn, continuation))
        }
        return value
    }()

    @discardableResult
    func prepareQuestion(turn: UUID = UUID(), continuation: UUID? = nil) -> UUID {
        controller.begin(turn: turn, continuation: continuation)
        controller.generationFinished(turn: turn, hasQuestion: true)
        return turn
    }
    func poll(after interval: Double) {
        now += interval; controller.poll()
    }
}

final class VoiceFollowupTests: XCTestCase {
    @MainActor func testCompleteLoopRequiresFinalAudioThenSelectedSilenceForEverySetting() throws {
        for silence in VoiceTimingSettings.silenceChoices {
            for invitation in VoiceTimingSettings.invitationChoices {
                let fixture = FollowupFixture(), turn = UUID(), answer = UUID(), question = UUID()
                fixture.controller.begin(turn: turn)
                var playback = FinalPlaybackBarrier()
                playback.begin(turn: turn)
                XCTAssertTrue(playback.enqueue(turn: turn, request: answer))
                // An answer sentence can drain while generation is still open.
                XCTAssertNil(playback.playbackFinished(turn: turn, request: answer, successfully: true))
                fixture.poll(after: 1)
                XCTAssertTrue(fixture.invitations.isEmpty)

                fixture.controller.generationFinished(turn: turn, hasQuestion: true)
                XCTAssertTrue(playback.enqueue(turn: turn, request: question))
                XCTAssertNil(playback.generationComplete(turn: turn))
                fixture.poll(after: 1)
                XCTAssertTrue(fixture.invitations.isEmpty)
                let completed = try XCTUnwrap(playback.playbackFinished(turn: turn, request: question, successfully: true))
                fixture.controller.playbackFinished(turn: completed)
                fixture.poll(after: QuestionReplyGate.playbackSettleSeconds - 0.001)
                XCTAssertTrue(fixture.invitations.isEmpty, "Capture cannot overlap final playback settling")
                fixture.poll(after: 0.002)
                XCTAssertEqual(fixture.invitations.count, 1)
                XCTAssertEqual(fixture.invitations.first?.turn, turn)
                XCTAssertFalse(fixture.controller.pending)

                let start = fixture.now
                var capture = VoiceCaptureDeadline(startedAt: start, silenceSeconds: silence, invitationSeconds: invitation)
                capture.observeAudio(firstSpeech: start + invitation - 0.01,
                                     lastSpeech: start + invitation + 0.5, through: start + invitation + 0.5)
                XCTAssertEqual(capture.evaluate(at: start + invitation + 0.5), .listening,
                               "A reply begun within the invitation must continue beyond its deadline")
                let ended = start + invitation + 0.5
                capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: ended + silence - 0.001)
                XCTAssertEqual(capture.evaluate(at: ended + silence - 0.001), .listening)
                XCTAssertNil(capture.timingEvidence, "No eligible transcript/reasoning boundary before full silence")
                capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: ended + silence)
                XCTAssertEqual(capture.evaluate(at: ended + silence), .silenceSatisfied)
                XCTAssertEqual(capture.timingEvidence?.silenceSatisfiedAt, ended + silence)
                XCTAssertEqual(capture.timingEvidence?.selectedSilenceSeconds, silence)
            }
        }
    }

    @MainActor func testPlaybackBeforeGenerationAndRepeatedIntermediateCallbacksCannotInvite() {
        let fixture = FollowupFixture(), turn = UUID()
        fixture.controller.begin(turn: turn)
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: 1)
        fixture.controller.generationFinished(turn: turn, hasQuestion: true)
        fixture.poll(after: 1)
        XCTAssertTrue(fixture.invitations.isEmpty)
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: 0.1)
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: 0.31)
        XCTAssertEqual(fixture.invitations.count, 1, "Repeated completion must not postpone the original settling deadline")
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: 1)
        XCTAssertEqual(fixture.invitations.count, 1)
    }

    @MainActor func testDuplicateGenerationCannotReplaceOrUpgradeOriginalIntent() {
        for firstHadQuestion in [false, true] {
            let fixture = FollowupFixture(), turn = UUID()
            fixture.controller.begin(turn: turn)
            fixture.controller.generationFinished(turn: turn, hasQuestion: firstHadQuestion)
            fixture.controller.generationFinished(turn: turn, hasQuestion: !firstHadQuestion)
            fixture.controller.playbackFinished(turn: turn)
            fixture.poll(after: 0.5)
            XCTAssertEqual(fixture.invitations.count, firstHadQuestion ? 1 : 0)
            XCTAssertFalse(fixture.controller.pending)
        }
    }

    @MainActor func testFailedPlaybackNeverOpensInvitation() {
        let fixture = FollowupFixture(), turn = fixture.prepareQuestion(), audio = UUID()
        var barrier = FinalPlaybackBarrier(); barrier.begin(turn: turn)
        XCTAssertTrue(barrier.enqueue(turn: turn, request: audio))
        XCTAssertNil(barrier.generationComplete(turn: turn))
        XCTAssertNil(barrier.playbackFinished(turn: turn, request: audio, successfully: false))
        // The production voice error path revokes the controller as well.
        fixture.controller.cancel()
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: 1)
        XCTAssertTrue(fixture.invitations.isEmpty)
        XCTAssertFalse(fixture.controller.pending)
    }

    @MainActor func testCancellationAtEachStageRejectsAllLateCallbacks() {
        for stage in 0..<4 {
            let fixture = FollowupFixture(), turn = UUID()
            fixture.controller.begin(turn: turn)
            if stage >= 1 { fixture.controller.generationFinished(turn: turn, hasQuestion: true) }
            if stage >= 2 { fixture.controller.playbackFinished(turn: turn) }
            if stage >= 3 { fixture.poll(after: 0.2) }
            fixture.controller.cancel()
            fixture.controller.generationFinished(turn: turn, hasQuestion: true)
            fixture.controller.playbackFinished(turn: turn)
            fixture.poll(after: 1)
            XCTAssertTrue(fixture.invitations.isEmpty)
            XCTAssertFalse(fixture.controller.pending)
        }
    }

    @MainActor func testTransientReadinessDefersButPermissionLossRevokes() {
        for loss in 0..<4 {
            let fixture = FollowupFixture(), turn = fixture.prepareQuestion()
            fixture.controller.playbackFinished(turn: turn)
            switch loss {
            case 0: fixture.environment.ready = false
            case 1: fixture.environment.interacting = true
            case 2: fixture.environment.microphoneAuthorized = false
            default: fixture.environment.screenAuthorized = false
            }
            fixture.poll(after: 0.5)
            fixture.environment = .init(ready: true, microphoneAuthorized: true, screenAuthorized: true, interacting: false)
            fixture.poll(after: 0.5)
            if loss < 2 {
                XCTAssertEqual(fixture.invitations.map(\.turn), [turn],
                               "A transient readiness/interaction loss must wait, not drop the reply")
                XCTAssertFalse(fixture.controller.pending)
            } else {
                XCTAssertTrue(fixture.invitations.isEmpty, "A permission loss is final")
                XCTAssertFalse(fixture.controller.pending)
            }
        }
    }

    @MainActor func testDeferredInvitationStillExpiresAtTheBoundedLifetime() {
        let fixture = FollowupFixture(), turn = fixture.prepareQuestion()
        fixture.controller.playbackFinished(turn: turn)
        fixture.environment.ready = false
        fixture.poll(after: 0.2)
        fixture.environment = .init(ready: true, microphoneAuthorized: true, screenAuthorized: true, interacting: false)
        fixture.poll(after: QuestionReplyGate.invitationLifetimeSeconds)
        XCTAssertTrue(fixture.invitations.isEmpty)
        XCTAssertFalse(fixture.controller.pending)
    }

    @MainActor func testReplacementTurnRejectsOldGenerationAndPlayback() {
        let fixture = FollowupFixture(), first = fixture.prepareQuestion(), next = UUID()
        fixture.controller.playbackFinished(turn: first)
        fixture.controller.begin(turn: next)
        fixture.controller.generationFinished(turn: first, hasQuestion: true)
        fixture.controller.playbackFinished(turn: first)
        fixture.poll(after: 0.5)
        XCTAssertTrue(fixture.invitations.isEmpty)
        fixture.controller.generationFinished(turn: next, hasQuestion: true)
        fixture.controller.playbackFinished(turn: next)
        fixture.poll(after: 0.5)
        XCTAssertEqual(fixture.invitations.map(\.turn), [next])
    }

    @MainActor func testExpiredPlaybackHandoffClearsPendingWithoutRestarting() {
        let fixture = FollowupFixture(), turn = fixture.prepareQuestion()
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: QuestionReplyGate.invitationLifetimeSeconds + 0.001)
        XCTAssertTrue(fixture.invitations.isEmpty)
        XCTAssertFalse(fixture.controller.pending)
        fixture.controller.playbackFinished(turn: turn)
        fixture.poll(after: 0.5)
        XCTAssertTrue(fixture.invitations.isEmpty)
    }

    @MainActor func testBoundedAutomaticChainAndManualClickReset() throws {
        let fixture = FollowupFixture()
        var continuation: UUID?
        for index in 0...QuestionReplyGate.maximumAutomaticReplies {
            let turn = fixture.prepareQuestion(continuation: continuation)
            fixture.controller.playbackFinished(turn: turn)
            fixture.poll(after: 0.5)
            XCTAssertEqual(fixture.invitations.count, min(index + 1, QuestionReplyGate.maximumAutomaticReplies))
            if index < QuestionReplyGate.maximumAutomaticReplies {
                continuation = try XCTUnwrap(fixture.invitations.last?.continuation)
            } else {
                XCTAssertFalse(fixture.controller.pending, "An exhausted chain must not remain pending forever")
            }
        }
        let manual = fixture.prepareQuestion()
        fixture.controller.playbackFinished(turn: manual)
        fixture.poll(after: 0.5)
        XCTAssertEqual(fixture.invitations.count, QuestionReplyGate.maximumAutomaticReplies + 1)
        XCTAssertEqual(fixture.invitations.last?.turn, manual)
    }

    @MainActor func testWrongExpiredOrReusedContinuationCannotInvite() throws {
        for failure in 0..<3 {
            let fixture = FollowupFixture(), first = fixture.prepareQuestion()
            fixture.controller.playbackFinished(turn: first)
            fixture.poll(after: 0.5)
            let continuation = try XCTUnwrap(fixture.invitations.first?.continuation)
            if failure == 1 { fixture.now += 1.001 }
            let next = fixture.prepareQuestion(continuation: failure == 0 ? UUID() : continuation)
            if failure == 2 {
                fixture.controller.begin(turn: next, continuation: continuation)
                fixture.controller.generationFinished(turn: next, hasQuestion: true)
            }
            fixture.controller.playbackFinished(turn: next)
            fixture.poll(after: 0.5)
            XCTAssertEqual(fixture.invitations.count, 1)
            XCTAssertFalse(fixture.controller.pending)
        }
    }

    @MainActor func testNoSpeechAndLateSpeechNeverReachEligibleTranscriptBoundary() {
        for invitation in VoiceTimingSettings.invitationChoices {
            var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: 3, invitationSeconds: invitation)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 100 + invitation)
            XCTAssertEqual(capture.evaluate(at: 100 + invitation), .noSpeech)
            capture.observeAudio(firstSpeech: 100 + invitation + 0.001,
                                 lastSpeech: 101 + invitation, through: 102 + invitation)
            XCTAssertEqual(capture.evaluate(at: 105 + invitation), .noSpeech)
            XCTAssertNil(capture.timingEvidence)
        }
    }

    @MainActor func testResumedReplyResetsSilenceAfterInvitationHasExpired() {
        var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: 3, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: 105.99, lastSpeech: 107, through: 107)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 109.99)
        XCTAssertEqual(capture.evaluate(at: 110), .listening, "In-flight audio must be resolved before silence closes")
        capture.observeAudio(firstSpeech: 109.995, lastSpeech: 111, through: 111)
        XCTAssertEqual(capture.evaluate(at: 111), .listening)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 113.999)
        XCTAssertEqual(capture.evaluate(at: 113.999), .listening)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 114)
        XCTAssertEqual(capture.evaluate(at: 114), .silenceSatisfied)
        XCTAssertEqual(capture.timingEvidence?.speechEndedAt, 111)
    }
}
