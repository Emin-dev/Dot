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
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3, invitationSeconds: 6)
        XCTAssertEqual(capture.evaluate(at: 6), .listening)
        XCTAssertEqual(capture.evaluate(at: 7), .audioUnavailable)
        XCTAssertNil(capture.timingEvidence)
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
}
