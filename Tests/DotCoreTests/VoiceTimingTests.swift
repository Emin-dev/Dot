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
    func testCaptureNeverReasonsAtFiveMinuteLimitWithoutSatisfiedSilence() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 8, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 299.9, through: 300)
        XCTAssertEqual(capture.evaluate(at: 300), .maximumDuration)
        XCTAssertNil(capture.timingEvidence)
        var manual = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        manual.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 300)
        XCTAssertEqual(manual.evaluate(at: 300), .maximumDuration)
    }
    func testEarlierCompletedSilenceWinsDelayedTimer() {
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
        capture.observeAudio(firstSpeech: 1, lastSpeech: 299.9, through: 299.9)
        capture.reachCaptureLimit()
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 303)
        XCTAssertEqual(capture.evaluate(at: 303), .maximumDuration)
        XCTAssertNil(capture.timingEvidence)
    }
    func testCrossingLimitBufferKeepsEarlierSilenceInsideItsAllowedPrefix() {
        let window = VoiceCaptureFrameWindow(frames: 320, stored: 2_399_840, rate: 8_000,
                                             bufferStartedAt: 299.98, captureStartedAt: 0)
        XCTAssertEqual(window.offset, 0)
        XCTAssertLessThanOrEqual(window.count, 160)
        XCTAssertTrue(window.reachesLimit)
        let through = 299.98 + Double(window.count) / 8_000
        XCTAssertGreaterThanOrEqual(through, 299.99)
        XCTAssertLessThanOrEqual(through, 300)
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 296.99, through: 299.98)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: through)
        capture.reachCaptureLimit()
        XCTAssertEqual(capture.evaluate(at: 300.1), .silenceSatisfied)
        XCTAssertEqual(capture.timingEvidence?.silenceSatisfiedAt, 299.99)
    }
    func testCrossingLimitBufferCannotTranscribeAnUnfinishedUtterance() {
        let window = VoiceCaptureFrameWindow(frames: 320, stored: 2_399_840, rate: 8_000,
                                             bufferStartedAt: 299.98, captureStartedAt: 0)
        let through = 299.98 + Double(window.count) / 8_000
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 296.99, through: 299.98)
        capture.observeAudio(firstSpeech: 299.98, lastSpeech: through, through: through)
        capture.reachCaptureLimit()
        XCTAssertEqual(capture.evaluate(at: 300.1), .maximumDuration)
        XCTAssertNil(capture.timingEvidence)
    }
    func testFrameWindowTrimsBeforeCaptureAndNeverExceedsSampleBudget() {
        let first = VoiceCaptureFrameWindow(frames: 320, stored: 0, rate: 8_000,
                                            bufferStartedAt: 9.98, captureStartedAt: 10)
        XCTAssertGreaterThanOrEqual(first.offset, 160)
        XCTAssertLessThanOrEqual(first.count, 160)
        XCTAssertFalse(first.reachesLimit)
        let final = VoiceCaptureFrameWindow(frames: 320, stored: 2_399_999, rate: 8_000,
                                            bufferStartedAt: 299, captureStartedAt: 0)
        XCTAssertEqual(final.count, 1)
        XCTAssertTrue(final.reachesLimit)
        let expired = VoiceCaptureFrameWindow(frames: 320, stored: 100, rate: 8_000,
                                              bufferStartedAt: 300.1, captureStartedAt: 0)
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
            XCTAssertEqual(snapshot.maximumRemainingSeconds, 299.4, accuracy: 0.00001)
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
            if reason == .intentionalCancellation || reason == .noSpeech || reason == .forcedFinish {
                XCTAssertNil(reason.recoveryMessage, "\(reason) is not a failure and must stay quiet")
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
        var released = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        released.forceFinish()
        XCTAssertEqual(released.endReason, .forcedFinish)
    }

    /// Releasing push-to-talk closes the turn with evidence measured from the PCM
    /// that was really processed. It must never borrow a silence deadline it did
    /// not observe.
    func testForcedFinishPublishesMeasuredEvidenceAndNeverClaimsSatisfiedSilence() throws {
        var capture = VoiceCaptureDeadline(startedAt: 100, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 100.2, lastSpeech: 101, through: 101.05)
        XCTAssertEqual(capture.evaluate(at: 101.2), .listening)
        capture.forceFinish()
        XCTAssertEqual(capture.decision, .forcedFinish)
        XCTAssertEqual(capture.endReason, .forcedFinish)
        XCTAssertNil(capture.timingEvidence, "A released turn did not complete the silence rule")
        let evidence = try XCTUnwrap(capture.forcedFinishEvidence)
        XCTAssertEqual(evidence.outcome, .forcedFinish)
        XCTAssertEqual(evidence.endReason, .forcedFinish)
        XCTAssertFalse(evidence.isSilenceSatisfied)
        XCTAssertEqual(evidence.captureStartedAt, 100)
        XCTAssertEqual(evidence.firstSpeechAt, 100.2)
        XCTAssertEqual(evidence.speechEndedAt, 101)
        XCTAssertEqual(evidence.silenceSatisfiedAt, 101.05, "The release anchor is the audio really processed")
        XCTAssertEqual(evidence.audioProcessedThrough, 101.05)
        XCTAssertEqual(evidence.selectedSilenceSeconds, 3)
        XCTAssertNotEqual(evidence.silenceSatisfiedAt, evidence.speechEndedAt + evidence.selectedSilenceSeconds)
        XCTAssertEqual(capture.closedEvidence, evidence)
        XCTAssertNil(VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3).forcedFinishEvidence)
    }

    func testForcedFinishIsTerminalAndLateAudioCannotReopenOrProveSilence() throws {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 1, through: 1)
        capture.forceFinish()
        // A late buffer that would have completed the silence rule cannot revise it.
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 5)
        XCTAssertEqual(capture.evaluate(at: 5), .forcedFinish)
        XCTAssertNil(capture.timingEvidence)
        let evidence = try XCTUnwrap(capture.closedEvidence)
        XCTAssertEqual(evidence.silenceSatisfiedAt, 1, "The release stays anchored to the audio processed then")
        XCTAssertEqual(capture.audioThrough, 1, "Audio arriving after the release is not counted")
    }

    func testReleaseAfterACompletedSilenceKeepsSatisfiedEvidence() throws {
        var capture = VoiceCaptureDeadline(startedAt: 10, silenceSeconds: 2)
        capture.observeAudio(firstSpeech: 10.1, lastSpeech: 10.5, through: 12.5)
        XCTAssertEqual(capture.evaluate(at: 12.5), .silenceSatisfied)
        capture.forceFinish()
        XCTAssertEqual(capture.decision, .silenceSatisfied, "A completed rule is never downgraded by a release")
        let evidence = try XCTUnwrap(capture.timingEvidence)
        XCTAssertEqual(evidence.outcome, .silenceSatisfied)
        XCTAssertEqual(evidence.silenceSatisfiedAt, 12.5)
        XCTAssertNil(evidence.endReason)
    }

    /// Pins the exact coordinator contract: a forced turn satisfies every existing
    /// check except the silence arithmetic, so the caller must branch on `outcome`.
    func testForcedEvidenceNeedsTheExplicitOutcomeBranchInTheCoordinator() throws {
        var capture = VoiceCaptureDeadline(startedAt: 20, silenceSeconds: 8)
        capture.observeAudio(firstSpeech: 20.5, lastSpeech: 21, through: 21.02)
        capture.forceFinish()
        let evidence = try XCTUnwrap(capture.closedEvidence)
        XCTAssertTrue([evidence.captureStartedAt, evidence.firstSpeechAt, evidence.speechEndedAt,
                       evidence.silenceSatisfiedAt, evidence.audioProcessedThrough].allSatisfy(\.isFinite))
        XCTAssertTrue(VoiceTimingSettings.silenceChoices.contains(evidence.selectedSilenceSeconds))
        XCTAssertLessThanOrEqual(evidence.captureStartedAt, evidence.firstSpeechAt)
        XCTAssertLessThanOrEqual(evidence.firstSpeechAt, evidence.speechEndedAt)
        XCTAssertGreaterThan(abs(evidence.silenceSatisfiedAt - evidence.speechEndedAt
                                 - evidence.selectedSilenceSeconds), 0.000001,
                             "Only a completed silence may satisfy this arithmetic")
        XCTAssertEqual(evidence.outcome, .forcedFinish)
        XCTAssertEqual(evidence.endReason, .forcedFinish)
    }

    func testRouteRearmKeepsTheTurnListeningWithinItsBoundedWindow() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 3)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 1, through: 1)
        capture.rearmAfterRouteChange(at: 1.05)
        XCTAssertEqual(capture.evaluate(at: 2.5), .listening, "A deliberate restart gap is not missing PCM")
        XCTAssertNil(capture.closedEvidence)
        XCTAssertEqual(capture.evaluate(at: 3.06), .audioUnavailable, "A re-armed tap that never delivers fails closed")
        XCTAssertEqual(capture.endReason, .missingAudio)
    }

    func testRouteRearmGapIsNeverSilentPCMAndLaterSpeechReanchorsTheRule() {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 2)
        capture.observeAudio(firstSpeech: 0.1, lastSpeech: 1, through: 1)
        capture.rearmAfterRouteChange(at: 1.05)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 4)
        XCTAssertEqual(capture.evaluate(at: 4), .listening, "Uncovered audio cannot prove silence")
        XCTAssertNil(capture.closedEvidence)
        capture.observeAudio(firstSpeech: 4.1, lastSpeech: 4.5, through: 4.5)
        capture.observeAudio(firstSpeech: nil, lastSpeech: nil, through: 6.5)
        XCTAssertEqual(capture.evaluate(at: 6.5), .silenceSatisfied)
        XCTAssertEqual(capture.timingEvidence?.speechEndedAt, 4.5)
        XCTAssertEqual(capture.timingEvidence?.firstSpeechAt, 0.1, "The turn's own timeline survives the change")
    }

    func testRouteRearmCannotOutliveTheCaptureLimit() throws {
        var capture = VoiceCaptureDeadline(startedAt: 0, silenceSeconds: 8, invitationSeconds: 6)
        capture.observeAudio(firstSpeech: 1, lastSpeech: 2, through: 2)
        capture.rearmAfterRouteChange(at: 299.9)
        XCTAssertEqual(capture.evaluate(at: 300.5), .maximumDuration, "The 300-second bound still wins")
        XCTAssertNil(capture.timingEvidence)
        let evidence = try XCTUnwrap(capture.closedEvidence)
        XCTAssertEqual(evidence.outcome, .maximumDuration)
        XCTAssertEqual(evidence.firstSpeechAt, 1)
        XCTAssertEqual(evidence.silenceSatisfiedAt, 2, "The cap uses the last PCM processed, not a silence deadline")
    }
}

#if !SWIFT_PACKAGE
import AVFoundation

/// Deterministic AVAudioPCMBuffer replay; no microphone, recognizer, or model starts.
final class CapturedPCMTimingTests: XCTestCase {
    private func buffer(rate: Double, frames: UInt32, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData!.pointee.initialize(repeating: amplitude, count: Int(frames))
        return buffer
    }
    private func append(_ pcm: CapturedPCM, at start: Double, amplitude: Float, frames: UInt32 = 800) {
        append(pcm, at: start, rate: 8_000, amplitude: amplitude, frames: frames)
    }
    private func append(_ pcm: CapturedPCM, at start: Double, rate: Double, amplitude: Float, frames: UInt32 = 800) {
        pcm.append(buffer(rate: rate, frames: frames, amplitude: amplitude),
                   at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
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

    // MARK: - Explicit release (hold-Fn push-to-talk)

    func testExplicitReleaseClosesCaptureWithMeasuredEvidenceAndKeepsSamples() throws {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: 3, invitation: nil)
        append(pcm, at: 100.0, amplitude: 0.1)
        append(pcm, at: 100.1, amplitude: 0.1)
        append(pcm, at: 100.2, amplitude: 0)
        XCTAssertEqual(pcm.poll(at: 100.3).decision, .listening)
        let released = pcm.poll(at: 100.4, finishing: true)
        XCTAssertEqual(released.decision, .forcedFinish, "A release closes an unfinished turn")
        XCTAssertEqual(released.endReason, .forcedFinish)
        let evidence = try XCTUnwrap(released.evidence)
        XCTAssertEqual(evidence.outcome, .forcedFinish)
        XCTAssertFalse(evidence.isSilenceSatisfied)
        XCTAssertEqual(evidence.firstSpeechAt, 100, accuracy: 0.00001)
        XCTAssertEqual(evidence.speechEndedAt, 100.2, accuracy: 0.00001)
        XCTAssertEqual(evidence.silenceSatisfiedAt, 100.3, accuracy: 0.00001)
        XCTAssertEqual(evidence.audioProcessedThrough, 100.3, accuracy: 0.00001)
        XCTAssertNotEqual(evidence.silenceSatisfiedAt, evidence.speechEndedAt + evidence.selectedSilenceSeconds)
        XCTAssertEqual(pcm.take().count, 2_400, "Released audio is transcribed instead of discarded")
    }

    func testReleaseAfterCompletedSilenceKeepsSatisfiedEvidence() throws {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 10, silence: 2, invitation: nil)
        append(pcm, at: 10.0, amplitude: 0.1)
        for index in 1...21 { append(pcm, at: 10.0 + Double(index) / 10, amplitude: 0) }
        let released = pcm.poll(at: 12.2, finishing: true)
        XCTAssertEqual(released.decision, .silenceSatisfied)
        let evidence = try XCTUnwrap(released.evidence)
        XCTAssertEqual(evidence.outcome, .silenceSatisfied)
        XCTAssertNil(evidence.endReason)
        XCTAssertEqual(evidence.silenceSatisfiedAt, 12.1, accuracy: 0.00001)
    }

    func testReleaseWithNoMeasuredSpeechPublishesNoEvidence() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 15, silence: 3, invitation: 6)
        append(pcm, at: 15.0, amplitude: 0)
        let released = pcm.poll(at: 15.2, finishing: true)
        XCTAssertEqual(released.decision, .forcedFinish)
        XCTAssertNil(released.evidence, "No measured utterance means nothing to transcribe")
        XCTAssertEqual(released.endReason, .forcedFinish)
    }

    func testReleaseCannotHideARealCaptureFailure() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 20, silence: 3, invitation: nil)
        append(pcm, at: 20.0, amplitude: .nan)
        let released = pcm.poll(at: 20.2, finishing: true)
        XCTAssertEqual(released.decision, .audioUnavailable)
        XCTAssertEqual(released.endReason, .invalidAudio)
        XCTAssertNil(released.evidence)
    }

    /// R25: captured samples convert to the 16 kHz 16-bit mono format a speech model asks for,
    /// and bad input is refused instead of being sent to the recognizer.
    func testCapturedSamplesConvertToTheRecognizerFormat() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.05) * 0.3) }
        let buffer = try WhisperRecognizer.buffer(samples, sampleRate: 48_000, format: format)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(Double(buffer.frameLength), 16_000, accuracy: 400)
        // The sound survives: a 0.3 sine peaks near 0.3 x 32,767.
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).map { abs(Int(channel[$0])) }.max() ?? 0
        XCTAssertTrue((8_000...11_000).contains(peak), "peak \(peak)")
        // The 16 kHz float format the bundled recognizer uses converts too.
        let float = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        XCTAssertEqual(Double(try WhisperRecognizer.buffer(samples, sampleRate: 48_000, format: float).frameLength), 16_000, accuracy: 400)
        // R1: more than five minutes is too long, not an unreadable format.
        XCTAssertThrowsError(try WhisperRecognizer.buffer([Float](repeating: 0.1, count: 8_000 * 301 + 1), sampleRate: 8_000, format: format)) {
            guard case RecognitionFailure.tooLong = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try WhisperRecognizer.buffer([], sampleRate: 48_000, format: format))
        XCTAssertThrowsError(try WhisperRecognizer.buffer([Float.nan], sampleRate: 48_000, format: format))
        XCTAssertThrowsError(try WhisperRecognizer.buffer(samples, sampleRate: 4_000, format: format))
    }

    @MainActor func testSTTManagerPublishesForcedFinishEvidenceForTheCoordinator() {
        let manager = STTManager()
        var published: (UUID, VoiceCaptureTimingEvidence)?
        manager.onSpeechEnded = { published = ($0, $1) }
        let id = UUID()
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 300, silence: 3, invitation: nil)
        append(pcm, at: 300.0, amplitude: 0.1)
        manager.closeCapture(id, pcm.poll(at: 300.2, finishing: true))
        XCTAssertEqual(published?.0, id)
        XCTAssertEqual(published?.1.outcome, .forcedFinish, "A forced finish publishes evidence, not silence")
        XCTAssertEqual(published?.1.endReason, .forcedFinish)
        XCTAssertEqual(published?.1.silenceSatisfiedAt ?? -1, 300.1, accuracy: 0.00001)
    }

    // MARK: - Audio route/format change mid-capture

    func testUnmigratedStoresAreExactlyWhatTheRouteChangeFixReplaces() {
        let staleRate = CapturedPCM(rate: 8_000)
        staleRate.begin(at: 100, silence: 3, invitation: nil)
        append(staleRate, at: 100.0, amplitude: 0.1)
        staleRate.append(buffer(rate: 16_000, frames: 1_600, amplitude: 0.1),
                         at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.1)))
        XCTAssertEqual(staleRate.poll(at: 100.2).endReason, .invalidAudio,
                       "Post-switch audio in an old-rate store is rejected")
        let gapped = CapturedPCM(rate: 8_000)
        gapped.begin(at: 200, silence: 3, invitation: nil)
        append(gapped, at: 200.0, amplitude: 0.1)
        append(gapped, at: 200.8, amplitude: 0)
        XCTAssertEqual(gapped.poll(at: 200.9).endReason, .invalidAudio,
                       "Unreset continuity rejects the tap restart gap")
    }

    func testFormatAndRateChangeReArmsCaptureAndPreservesCapturedAudio() {
        let before = CapturedPCM(rate: 8_000)
        before.begin(at: 300, silence: 3, invitation: nil)
        append(before, at: 300.0, amplitude: 0.1)
        append(before, at: 300.1, amplitude: 0.1)
        XCTAssertEqual(before.poll(at: 300.25).decision, .listening)
        // The input device switches to 16 kHz and its tap resumes 0.5s later.
        let after = CapturedPCM(rate: 16_000, migrating: before, at: 300.7)
        append(after, at: 300.8, rate: 16_000, amplitude: 0.1, frames: 1_600)
        let observation = after.poll(at: 300.9)
        XCTAssertEqual(observation.decision, .listening, "Post-switch audio must keep the turn alive")
        XCTAssertNotEqual(observation.endReason, .invalidAudio)
        XCTAssertEqual(observation.snapshot?.phase, .speaking)
        XCTAssertEqual(observation.snapshot?.audioThrough ?? -1, 300.9, accuracy: 0.00001)
        XCTAssertEqual(after.rate, 16_000, "The store reports the new device rate")
        append(before, at: 300.85, amplitude: 0.1) // retired tap callback
        XCTAssertEqual(after.poll(at: 300.95).decision, .listening, "The retired tap cannot disturb the turn")
        XCTAssertEqual(after.take().count, 3_200, "Pre-switch and post-switch audio are both preserved")
    }

    /// voice-listen-02: a successful route-change re-arm keeps the turn on the
    /// migrated store and deactivates the old one. The coordinator's tick must
    /// return early after the re-arm: polling the old store now reads `.cancelled`,
    /// so acting on it would silently cancel a turn that just re-armed.
    func testSuccessfulRearmDeactivatesTheOldStoreSoItCannotCancelTheTurn() {
        let old = CapturedPCM(rate: 8_000)
        old.begin(at: 300, silence: 3, invitation: nil)
        append(old, at: 300.0, amplitude: 0.1)
        XCTAssertEqual(old.poll(at: 300.2).decision, .listening)

        let migrated = CapturedPCM(rate: 16_000, migrating: old, at: 300.7)
        XCTAssertEqual(migrated.poll(at: 300.9).decision, .listening, "The re-armed turn stays alive")
        XCTAssertEqual(old.poll(at: 300.9).decision, .cancelled,
                       "The old store is deactivated by the re-arm and must not be polled as the live turn")
    }

    func testReArmedCaptureKeepsItsOriginalFiveMinuteBound() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: 3, invitation: nil)
        append(pcm, at: 100.0, amplitude: 0.1)
        let migrated = CapturedPCM(rate: 8_000, migrating: pcm, at: 150.0)
        XCTAssertEqual(migrated.poll(at: 150.0).snapshot?.maximumRemainingSeconds ?? -1, 250, accuracy: 0.00001)
        XCTAssertEqual(migrated.poll(at: 400.1).decision, .maximumDuration, "The turn ends at its original bound")
    }

    func testCancellationSurvivesAFormatChange() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 200, silence: 3, invitation: nil)
        append(pcm, at: 200.0, amplitude: 0.1)
        let migrated = CapturedPCM(rate: 16_000, migrating: pcm, at: 200.2)
        migrated.cancel()
        append(migrated, at: 200.3, rate: 16_000, amplitude: 0.1)
        let cancelled = migrated.poll(at: 200.4)
        XCTAssertEqual(cancelled.decision, .cancelled)
        XCTAssertEqual(cancelled.endReason, .intentionalCancellation)
        XCTAssertTrue(migrated.take().isEmpty)
    }

    func testReArmedTapThatNeverDeliversStillFailsClosedAsMissingAudio() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: 3, invitation: nil)
        append(pcm, at: 100.0, amplitude: 0)
        let migrated = CapturedPCM(rate: 8_000, migrating: pcm, at: 100.2)
        XCTAssertEqual(migrated.poll(at: 101.0).decision, .listening, "A deliberate restart gap is tolerated")
        XCTAssertEqual(migrated.poll(at: 102.3).endReason, .missingAudio, "No first buffer still fails closed")
    }

    func testDeviceGapAcrossAReArmIsNeverCountedAsSilence() {
        let pcm = CapturedPCM(rate: 8_000)
        pcm.begin(at: 100, silence: 2, invitation: nil)
        append(pcm, at: 100.0, amplitude: 0.1)
        let migrated = CapturedPCM(rate: 8_000, migrating: pcm, at: 100.2)
        append(migrated, at: 101.0, amplitude: 0)
        for index in 1...11 { append(migrated, at: 101.0 + Double(index) / 10, amplitude: 0) }
        let duringGap = migrated.poll(at: 102.2)
        XCTAssertEqual(duringGap.decision, .listening, "A device gap is not silent PCM")
        XCTAssertNil(duringGap.evidence)
        append(migrated, at: 102.2, amplitude: 0.1)
        append(migrated, at: 102.3, amplitude: 0.1)
        for index in 4...24 { append(migrated, at: 102.0 + Double(index) / 10, amplitude: 0) }
        let ended = migrated.poll(at: 104.6)
        XCTAssertEqual(ended.decision, .silenceSatisfied)
        XCTAssertEqual(ended.evidence?.firstSpeechAt ?? -1, 100, accuracy: 0.00001)
        XCTAssertEqual(ended.evidence?.speechEndedAt ?? -1, 102.4, accuracy: 0.00001)
    }
}
#endif

final class VoicePermissionMessageTests: XCTestCase {
    func testPermissionLostMessageCoversRestrictedMicrophone() {
        let message = VoiceCaptureEndReason.permissionLost.recoveryMessage ?? ""
        XCTAssertTrue(message.contains("restricted"))
        XCTAssertTrue(message.contains("Screen Time"))
    }

    /// F6: the restricted state maps explicitly to its own Screen Time notice, and
    /// the notice is the exact string the production readiness branch speaks — never
    /// the plain denial hint.
    func testRestrictedMapsExplicitlyToTheExactScreenTimeNotice() {
        XCTAssertEqual(VoiceMicrophonePermission.restricted.notReadyNotice,
                       "Microphone access is restricted by Screen Time or a device-management profile. Ask the Mac's administrator to allow Dot, then click me again.")
        XCTAssertEqual(VoiceMicrophonePermission.denied.notReadyNotice,
                       "Microphone access is off. Enable Dot in System Settings > Privacy & Security > Microphone, then click me again.")
        XCTAssertNil(VoiceMicrophonePermission.authorized.notReadyNotice)
        XCTAssertNil(VoiceMicrophonePermission.undetermined.notReadyNotice)
    }
}
