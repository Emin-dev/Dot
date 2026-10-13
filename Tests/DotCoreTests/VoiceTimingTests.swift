import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class VoiceTimingTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let name = "app.dot.tests.voice-timing." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults)
    }

    func testDefaultMigrationPreservesUnrelatedPreferences() {
        withDefaults { defaults in
            defaults.set(false, forKey: "screenContextEnabled")
            let settings = VoiceTimingSettings(defaults: defaults)
            XCTAssertEqual(settings.silenceSeconds, 3)
            XCTAssertEqual(settings.invitationSeconds, 6)
            XCTAssertEqual(defaults.object(forKey: "screenContextEnabled") as? Bool, false)
        }
    }
    func testEverySettingPersistsAcrossStoreRecreation() {
        withDefaults { defaults in
            let settings = VoiceTimingSettings(defaults: defaults)
            for silence in [2.0, 3, 5, 8] {
                for invitation in [3.0, 6, 9, 12, 20] {
                    XCTAssertTrue(settings.setSilenceSeconds(silence))
                    XCTAssertTrue(settings.setInvitationSeconds(invitation))
                    let restored = VoiceTimingSettings(defaults: defaults)
                    XCTAssertEqual(restored.silenceSeconds, silence)
                    XCTAssertEqual(restored.invitationSeconds, invitation)
                }
            }
        }
    }
    func testInvalidSettersDoNotOverwriteValidPreferences() {
        withDefaults { defaults in
            let settings = VoiceTimingSettings(defaults: defaults)
            settings.setSilenceSeconds(8); settings.setInvitationSeconds(20)
            for value in [0.0, -1, 2.5, .infinity, -.infinity, .nan] {
                XCTAssertFalse(settings.setSilenceSeconds(value))
                XCTAssertFalse(settings.setInvitationSeconds(value))
            }
            XCTAssertEqual(VoiceTimingSettings(defaults: defaults).silenceSeconds, 8)
            XCTAssertEqual(VoiceTimingSettings(defaults: defaults).invitationSeconds, 20)
        }
    }
    func testMalformedPersistedValuesAreRepaired() {
        for bad in ["3", true, -1, 2.5, [3]] as [Any] {
            withDefaults { defaults in
                defaults.set(bad, forKey: VoiceTimingSettings.silenceKey)
                defaults.set(bad, forKey: VoiceTimingSettings.invitationKey)
                let settings = VoiceTimingSettings(defaults: defaults)
                XCTAssertEqual(settings.silenceSeconds, 3)
                XCTAssertEqual(settings.invitationSeconds, 6)
                XCTAssertEqual(defaults.double(forKey: VoiceTimingSettings.silenceKey), 3)
                XCTAssertEqual(defaults.double(forKey: VoiceTimingSettings.invitationKey), 6)
            }
        }
    }
    func testEverySilenceChoiceRequiresItsWholeInterval() {
        for seconds in VoiceTimingSettings.silenceChoices {
            var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: seconds)
            capture.observeAudio(firstSpeech: 100.5, lastSpeech: 101, through: 101)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 101 + seconds - 0.001)
            XCTAssertEqual(capture.evaluate(at: 101 + seconds - 0.001), .listening)
            XCTAssertNil(capture.timingEvidence)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 101 + seconds)
            XCTAssertEqual(capture.evaluate(at: 101 + seconds), .silenceSatisfied)
            XCTAssertEqual(capture.timingEvidence?.silenceSatisfiedAt, 101 + seconds)
            XCTAssertEqual(capture.timingEvidence?.selectedSilenceSeconds, seconds)
        }
    }
    func testResumedSpeechBeforeSilenceDeadlineResetsIt() {
        for seconds in VoiceTimingSettings.silenceChoices {
            var capture = VoiceCaptureDeadline(startedAt: 10, silenceSeconds: seconds)
            capture.observeAudio(firstSpeech: 10.1, lastSpeech: 11, through: 11)
            let resumed = 11 + seconds - 0.001
            capture.observeAudio(firstSpeech: resumed, lastSpeech: resumed + 0.5, through: resumed + 0.5)
            XCTAssertEqual(capture.evaluate(at: 11 + seconds), .listening)
            let newDeadline = resumed + 0.5 + seconds
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: newDeadline)
            XCTAssertEqual(capture.evaluate(at: newDeadline), .silenceSatisfied)
            XCTAssertEqual(capture.timingEvidence?.speechEndedAt, resumed + 0.5)
        }
    }
    func testNoSpeechClosesAtEachInvitationWithNoTranscriptionEvidence() {
        for seconds in VoiceTimingSettings.invitationChoices {
            var capture = VoiceCaptureDeadline(startedAt: 200, silenceSeconds: 3, invitationSeconds: seconds)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 200 + seconds)
            XCTAssertEqual(capture.evaluate(at: 200 + seconds - 0.001), .listening)
            XCTAssertEqual(capture.evaluate(at: 200 + seconds), .noSpeech)
            XCTAssertNil(capture.timingEvidence)
        }
    }
    func testSpeechJustBeforeEveryInvitationExpiryContinuesBeyondIt() {
        for seconds in VoiceTimingSettings.invitationChoices {
            var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 8, invitationSeconds: seconds)
            capture.observeAudio(firstSpeech: seconds - 0.001, lastSpeech: seconds + 0.1, through: seconds + 0.1)
            XCTAssertEqual(capture.evaluate(at: seconds + 0.1), .listening)
            capture.observeAudio(firstSpeech: seconds + 2, lastSpeech: seconds + 10, through: seconds + 10)
            XCTAssertEqual(capture.evaluate(at: seconds + 10), .listening)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: seconds + 18)
            XCTAssertEqual(capture.evaluate(at: seconds + 18), .silenceSatisfied)
        }
    }
    func testSpeechAtOrAfterInvitationExpiryDoesNotOpenANewTurn() {
        for seconds in VoiceTimingSettings.invitationChoices {
            for onset in [seconds, seconds + 0.001] {
                var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: seconds)
                capture.observeAudio(firstSpeech: onset, lastSpeech: onset + 0.2, through: onset + 0.2)
                XCTAssertEqual(capture.evaluate(at: onset + 0.2), .noSpeech)
                XCTAssertNil(capture.firstSpeechAt)
            }
        }
    }
    func testTimerCannotExpireAnAudioBufferStillInFlightAcrossInvitationBoundary() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 5.95)
        XCTAssertEqual(capture.evaluate(at: 6.05), .listening)
        capture.observeAudio(firstSpeech: 5.99, lastSpeech: 6.03, through: 6.06)
        XCTAssertEqual(capture.evaluate(at: 6.1), .listening)
        XCTAssertEqual(capture.firstSpeechAt, 5.99)
    }
    func testTimerCannotFinalizeBeforePendingResumedSpeechBuffer() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 1, through: 1)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 3.95)
        XCTAssertEqual(capture.evaluate(at: 4.05), .listening)
        capture.observeAudio(firstSpeech: 3.99, lastSpeech: 4.03, through: 4.06)
        XCTAssertEqual(capture.evaluate(at: 4.1), .listening)
        XCTAssertEqual(capture.lastSpeechAt, 4.03)
    }
    func testAudioTimelineDoesNotMergeALaterUtteranceWhenMainThreadIsLate() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 1, through: 1)
        capture.observeAudio(firstSpeech: 4.1, lastSpeech: 4.3, through: 4.4)
        XCTAssertEqual(capture.evaluate(at: 4.5), .silenceSatisfied)
        XCTAssertEqual(capture.lastSpeechAt, 1)
    }
    func testFinalizedCaptureRejectsLateCallbacksAndCancellationRejectsAllAudio() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 6)
        XCTAssertEqual(capture.evaluate(at: 6), .noSpeech)
        capture.observeAudio(firstSpeech: 5.99, lastSpeech: 6.1, through: 6.2)
        XCTAssertNil(capture.firstSpeechAt)
        capture.cancel()
        capture.observeAudio(firstSpeech: 6.3, lastSpeech: 7, through: 7)
        XCTAssertEqual(capture.evaluate(at: 20), .cancelled)
    }
    func testCaptureNeverReasonsAtSixtySecondLimitWithoutSatisfiedSilence() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 8, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 59.9, through: 60)
        XCTAssertEqual(capture.evaluate(at: 60), .maximumDuration)
        XCTAssertNil(capture.timingEvidence)
        var manual = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        manual.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 60)
        XCTAssertEqual(manual.evaluate(at: 60), .maximumDuration)
    }
    func testEarlierCompletedSilenceWinsDelayedTimerPastOverallLimit() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 56, through: 56)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 60)
        XCTAssertEqual(capture.evaluate(at: 61), .silenceSatisfied)
        XCTAssertEqual(capture.timingEvidence?.silenceSatisfiedAt, 59)
    }
    func testMissingAudioFailsClosedAfterBoundedGrace() {
        for invitation in [nil, 6.0] {
            var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: invitation)
            XCTAssertEqual(capture.evaluate(at: 0.999), .listening)
            XCTAssertEqual(capture.evaluate(at: 1), .audioUnavailable)
            XCTAssertEqual(capture.endReason, .missingAudio)
            XCTAssertNil(capture.timingEvidence)
        }
    }
    func testAutomaticInvitationNeverRequestsPermissionAndRequiresLiveRoute() {
        for permission in [VoiceMicrophonePermission.authorized, .undetermined, .denied] {
            XCTAssertFalse(VoiceCaptureAccessPolicy.shouldRequestPermission(invitation: true, permission: permission))
            XCTAssertFalse(VoiceCaptureAccessPolicy.mayCapture(permission: permission, routeAvailable: false))
        }
        XCTAssertTrue(VoiceCaptureAccessPolicy.shouldRequestPermission(invitation: false, permission: .undetermined))
        XCTAssertFalse(VoiceCaptureAccessPolicy.shouldRequestPermission(invitation: false, permission: .denied))
        XCTAssertTrue(VoiceCaptureAccessPolicy.mayCapture(permission: .authorized, routeAvailable: true))
        XCTAssertFalse(VoiceCaptureAccessPolicy.mayCapture(permission: .denied, routeAvailable: true))
        XCTAssertFalse(VoiceCaptureAccessPolicy.mayCapture(permission: .undetermined, routeAvailable: true))
    }
    func testContiguousAudioAndSmallTimestampRoundingRemainValid() {
        var continuity = VoiceAudioContinuity()
        XCTAssertTrue(continuity.accept(from: 10, through: 10.1))
        XCTAssertTrue(continuity.accept(from: 10.1, through: 10.2))
        XCTAssertTrue(continuity.accept(from: 10.20001, through: 10.3))
    }
    func testMissingOrReorderedAudioCannotProveContinuousSilence() {
        var continuity = VoiceAudioContinuity()
        XCTAssertTrue(continuity.accept(from: 10, through: 10.1))
        XCTAssertFalse(continuity.accept(from: 10.5, through: 10.6))
        XCTAssertEqual(continuity.through, 10.1)
        XCTAssertFalse(continuity.accept(from: 10, through: 10.1))
        XCTAssertFalse(continuity.accept(from: 9, through: 10.2))
        XCTAssertFalse(continuity.accept(from: .nan, through: 10.2))
        XCTAssertFalse(continuity.accept(from: 10.2, through: .infinity))
        XCTAssertFalse(continuity.accept(from: 10.3, through: 10.2))
    }
    func testInvalidAudioIsTerminalBeforeLaterSilenceCanBeAccepted() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 1, through: 1)
        // The tap detects invalid/nonfinite/gapped PCM before the UI can poll.
        capture.rejectAudio()
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 4)
        capture.observeAudio(firstSpeech: 4.1, lastSpeech: 5, through: 5)
        XCTAssertEqual(capture.evaluate(at: 8), .audioUnavailable)
        XCTAssertEqual(capture.endReason, .invalidAudio)
        XCTAssertNil(capture.timingEvidence)
        XCTAssertEqual(capture.lastSpeechAt, 1)
    }
    func testSampleBoundIsTerminalBeforeLaterSilenceCanBeAccepted() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 59.9, through: 59.9)
        capture.reachCaptureLimit()
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 63)
        XCTAssertEqual(capture.evaluate(at: 63), .maximumDuration)
        XCTAssertNil(capture.timingEvidence)
    }
    func testCrossingLimitBufferKeepsEarlierSilenceInsideItsAllowedPrefix() {
        let window = VoiceCaptureFrameWindow(frames: 320, stored: 479_840, rate: 8_000,
                                             bufferStartedAt: 59.98, captureStartedAt: 0)
        XCTAssertEqual(window.offset, 0)
        XCTAssertLessThanOrEqual(window.count, 160)
        XCTAssertTrue(window.reachesLimit)
        let through = 59.98 + Double(window.count) / 8_000
        XCTAssertGreaterThanOrEqual(through, 59.99)
        XCTAssertLessThanOrEqual(through, 60)
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 56.99, through: 59.98)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: through)
        capture.reachCaptureLimit()
        XCTAssertEqual(capture.evaluate(at: 60.1), .silenceSatisfied)
        XCTAssertEqual(capture.timingEvidence?.silenceSatisfiedAt, 59.99)
    }
    func testCrossingLimitBufferCannotTranscribeAnUnfinishedUtterance() {
        let window = VoiceCaptureFrameWindow(frames: 320, stored: 479_840, rate: 8_000,
                                             bufferStartedAt: 59.98, captureStartedAt: 0)
        let through = 59.98 + Double(window.count) / 8_000
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 56.99, through: 59.98)
        capture.observeAudio(firstSpeech: 59.98, lastSpeech: through, through: through)
        capture.reachCaptureLimit()
        XCTAssertEqual(capture.evaluate(at: 60.1), .maximumDuration)
        XCTAssertNil(capture.timingEvidence)
    }
    func testFrameWindowTrimsBeforeCaptureAndNeverExceedsSampleBudget() {
        let first = VoiceCaptureFrameWindow(frames: 320, stored: 0, rate: 8_000,
                                            bufferStartedAt: 9.98, captureStartedAt: 10)
        XCTAssertGreaterThanOrEqual(first.offset, 160)
        XCTAssertLessThanOrEqual(first.count, 160)
        XCTAssertFalse(first.reachesLimit)
        let final = VoiceCaptureFrameWindow(frames: 320, stored: 479_999, rate: 8_000,
                                            bufferStartedAt: 59, captureStartedAt: 0)
        XCTAssertEqual(final.count, 1)
        XCTAssertTrue(final.reachesLimit)
        let expired = VoiceCaptureFrameWindow(frames: 320, stored: 100, rate: 8_000,
                                              bufferStartedAt: 60.1, captureStartedAt: 0)
        XCTAssertEqual(expired.count, 0)
        XCTAssertTrue(expired.reachesLimit)
    }

    func testSnapshotUsesActualInvitationDeadlineForEveryChoice() {
        for invitation in VoiceTimingSettings.invitationChoices {
            var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: 3, invitationSeconds: invitation)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 100.5)
            let snapshot = capture.snapshot(at: 100.6)
            XCTAssertEqual(snapshot.phase, .invitation)
            XCTAssertEqual(snapshot.deadlineAt, 100 + invitation)
            XCTAssertEqual(snapshot.remainingSeconds!, invitation - 0.6, accuracy: 0.00001)
            XCTAssertEqual(snapshot.maximumRemainingSeconds, 59.4, accuracy: 0.00001)
            XCTAssertEqual(snapshot.audioThrough, 100.5)
            XCTAssertEqual(snapshot.sampledAt, 100.6)
            XCTAssertEqual(snapshot.decision, .listening)
        }
    }

    func testSnapshotFollowsSpeechResetsAndNeverRetainsInvitationDeadline() {
        for silence in VoiceTimingSettings.silenceChoices {
            var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: silence, invitationSeconds: 6)
            capture.observeAudio(firstSpeech: 105.99, lastSpeech: 106.1, through: 106.1)
            XCTAssertEqual(capture.snapshot(at: 106.1).phase, .speaking)
            XCTAssertEqual(capture.snapshot(at: 106.1).deadlineAt, 106.1 + silence)
            capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 106.3)
            let trailing = capture.snapshot(at: 106.3)
            XCTAssertEqual(trailing.phase, .trailingSilence)
            XCTAssertEqual(trailing.remainingSeconds!, silence - 0.2, accuracy: 0.00001)
            capture.observeAudio(firstSpeech: 106.4, lastSpeech: 106.5, through: 106.5)
            XCTAssertEqual(capture.snapshot(at: 106.5).phase, .speaking)
            XCTAssertEqual(capture.snapshot(at: 106.5).deadlineAt, 106.5 + silence)
            XCTAssertEqual(capture.snapshot(at: 106.5).remainingSeconds!, silence, accuracy: 0.00001)
        }
    }

    func testZeroCountdownStillWaitsForInFlightPCMAndLateOnsetResetsSnapshot() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 5.95)
        XCTAssertEqual(capture.evaluate(at: 6.05), .listening)
        let pending = capture.snapshot(at: 6.05)
        XCTAssertEqual(pending.remainingSeconds, 0)
        XCTAssertEqual(pending.decision, .listening)
        capture.observeAudio(firstSpeech: 5.99, lastSpeech: 6.03, through: 6.06)
        XCTAssertEqual(capture.evaluate(at: 6.1), .listening)
        let resumed = capture.snapshot(at: 6.1)
        XCTAssertEqual(resumed.phase, .speaking)
        XCTAssertEqual(resumed.deadlineAt!, 9.03, accuracy: 0.00001)
        XCTAssertEqual(resumed.remainingSeconds!, 2.93, accuracy: 0.00001)
    }

    func testManualSnapshotHasNoInventedInvitationAndNonfiniteClockCannotPoisonUI() {
        var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 100.1)
        let snapshot = capture.snapshot(at: .nan)
        XCTAssertEqual(snapshot.phase, .waitingForSpeech)
        XCTAssertNil(snapshot.deadlineAt)
        XCTAssertNil(snapshot.remainingSeconds)
        XCTAssertEqual(snapshot.sampledAt, 100.1)
        XCTAssertTrue(snapshot.maximumRemainingSeconds.isFinite)
        XCTAssertEqual(capture.snapshot(at: 1).sampledAt, 100)
    }

    func testMissingAudioDuringSpeechDoesNotBecomeSatisfiedSilence() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 0.5, through: 0.5)
        XCTAssertEqual(capture.evaluate(at: 1.499), .listening)
        XCTAssertEqual(capture.evaluate(at: 1.5), .audioUnavailable)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 4)
        XCTAssertEqual(capture.evaluate(at: 4), .audioUnavailable)
        XCTAssertEqual(capture.endReason, .missingAudio)
        XCTAssertNil(capture.timingEvidence)
    }

    func testTypedTerminalReasonsKeepQuietAndRecoveryOutcomesSeparate() {
        for reason in VoiceCaptureEndReason.allCases {
            if reason == .intentionalCancellation || reason == .noSpeech {
                XCTAssertNil(reason.recoveryMessage)
            } else { XCTAssertFalse(reason.recoveryMessage?.isEmpty ?? true) }
        }
        var quiet = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: 3)
        quiet.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 3)
        XCTAssertEqual(quiet.evaluate(at: 3), .noSpeech)
        XCTAssertEqual(quiet.endReason, .noSpeech)
        quiet.cancel()
        XCTAssertEqual(quiet.endReason, .intentionalCancellation)
        var maximum = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        maximum.reachCaptureLimit()
        XCTAssertEqual(maximum.endReason, .maximumDuration)
    }
}

#if !SWIFT_PACKAGE
import AVFoundation

/// Deterministic AVAudioPCMBuffer replay; no microphone, recognizer, or model starts.
final class CapturedPCMTimingTests: XCTestCase {
    private func append(_ pcm: CapturedPCM, at start: Double, amplitude: Float, frames: UInt32 = 800) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData!.pointee.initialize(repeating: amplitude, count: Int(frames))
        pcm.append(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
    }

    func testLockedSnapshotAndDecisionShareActualProcessedPCMDeadline() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: 3, invitation: 6)
        append(pcm, at: 100, amplitude: 0.1)
        XCTAssertEqual(pcm.poll(at: 100.1).snapshot?.phase, .speaking)
        for index in 1..<30 { append(pcm, at: 100 + Double(index) / 10, amplitude: 0) }
        let pending = pcm.poll(at: 103.05)
        XCTAssertEqual(pending.decision, .listening)
        XCTAssertEqual(pending.snapshot?.decision, pending.decision)
        XCTAssertEqual(pending.snapshot?.phase, .trailingSilence)
        XCTAssertEqual(pending.snapshot!.deadlineAt!, 103.1, accuracy: 0.00001)
        XCTAssertEqual(pending.snapshot!.remainingSeconds!, 0.05, accuracy: 0.00001)
        append(pcm, at: 103, amplitude: 0)
        let ended = pcm.poll(at: 103.2)
        XCTAssertEqual(ended.decision, .silenceSatisfied)
        XCTAssertEqual(ended.snapshot?.decision, ended.decision)
        XCTAssertEqual(ended.snapshot?.deadlineAt, ended.evidence?.silenceSatisfiedAt)
        XCTAssertNil(ended.endReason)
        append(pcm, at: 103.1, amplitude: 0.1)
        XCTAssertEqual(pcm.poll(at: 103.3).evidence, ended.evidence)
    }

    func testInvalidPCMAndMissingPCMHaveDifferentRecoveryCauses() {
        let invalid = CapturedPCM(rate: 8_000)
        invalid.begin(at: 100, silence: 3, invitation: nil)
        append(invalid, at: 100, amplitude: .nan)
        let rejected = invalid.poll(at: 100.2)
        XCTAssertEqual(rejected.decision, .audioUnavailable)
        XCTAssertEqual(rejected.endReason, .invalidAudio)
        XCTAssertNil(rejected.evidence)
        let missing = CapturedPCM(rate: 8_000)
        missing.begin(at: 100, silence: 3, invitation: nil)
        XCTAssertEqual(missing.poll(at: 101).endReason, .missingAudio)
    }

    func testCancelledPCMRejectsStaleTapAndClearsCapturedSamples() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: 3, invitation: 6)
        append(pcm, at: 100, amplitude: 0.1)
        pcm.cancel()
        append(pcm, at: 100.1, amplitude: 0.1)
        let ended = pcm.poll(at: 100.2)
        XCTAssertEqual(ended.decision, .cancelled)
        XCTAssertEqual(ended.endReason, .intentionalCancellation)
        XCTAssertNil(ended.evidence)
        XCTAssertTrue(pcm.take().isEmpty)
    }
}
#endif
