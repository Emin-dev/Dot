import Foundation
import CoreFoundation

/// The two independent listening intervals. Values are snapshotted when a capture starts.
/// Registering missing defaults preserves existing preferences and unrelated keys.
final class VoiceTimingSettings {
    static let silenceChoices: [Double] = [2, 3, 5, 8]
    static let invitationChoices: [Double] = [3, 6, 9, 12, 20]
    static let silenceKey = "voice.trailingSilenceSeconds"
    static let invitationKey = "voice.questionInvitationSeconds"
    private let defaults: UserDefaults
    private(set) var silenceSeconds: Double
    private(set) var invitationSeconds: Double

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.silenceKey: 3.0, Self.invitationKey: 6.0])
        silenceSeconds = Self.read(defaults, key: Self.silenceKey, choices: Self.silenceChoices, fallback: 3)
        invitationSeconds = Self.read(defaults, key: Self.invitationKey, choices: Self.invitationChoices, fallback: 6)
    }

    @discardableResult func setSilenceSeconds(_ value: Double) -> Bool {
        guard Self.silenceChoices.contains(value) else { return false }
        silenceSeconds = value; defaults.set(value, forKey: Self.silenceKey); return true
    }
    @discardableResult func setInvitationSeconds(_ value: Double) -> Bool {
        guard Self.invitationChoices.contains(value) else { return false }
        invitationSeconds = value; defaults.set(value, forKey: Self.invitationKey); return true
    }
    private static func read(_ defaults: UserDefaults, key: String, choices: [Double], fallback: Double) -> Double {
        if let number = defaults.object(forKey: key) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), choices.contains(number.doubleValue) {
            return number.doubleValue
        }
        // Repair a malformed old value without clearing the preference domain.
        defaults.set(fallback, forKey: key)
        return fallback
    }
}

enum VoiceCaptureDecision: Equatable, Sendable {
    /// `forcedFinish` is an explicit end of an unfinished turn (the user released
    /// push-to-talk). It is a terminal outcome of its own, never a satisfied
    /// trailing silence.
    case listening, silenceSatisfied, forcedFinish, noSpeech, maximumDuration, audioUnavailable, cancelled
}

enum VoiceCaptureState: Equatable, Sendable {
    case idle, preparing, requestingPermission, capturing, transcribing
}

/// A terminal capture outcome, rather than an undifferentiated recognizer error.
/// Quiet outcomes deliberately have no recovery notice and never trigger a retry.
enum VoiceCaptureEndReason: String, CaseIterable, Equatable, Sendable {
    case intentionalCancellation, noSpeech, routeChanged, permissionLost
    case invalidAudio, missingAudio, maximumDuration, systemSleep, noRecognizedWords
    /// The user ended the turn explicitly (push-to-talk release). Not a failure,
    /// and not a satisfied trailing silence: the audio captured so far is used.
    case forcedFinish

    var recoveryMessage: String? {
        switch self {
        case .intentionalCancellation, .noSpeech, .forcedFinish: return nil
        case .routeChanged: return "The microphone or speaker changed. Click me to start again with the current devices."
        case .permissionLost: return "Microphone access is off or restricted by Screen Time. Enable Dot in System Settings → Privacy & Security → Microphone, or check Screen Time restrictions, then click me."
        case .invalidAudio: return "The microphone audio was interrupted or unreadable. Check your input device, then click me to try again."
        case .missingAudio: return "The microphone stopped sending audio. Check your input device, then click me to try again."
        case .maximumDuration: return "I listened for the five-minute limit without hearing speech. Click me to start a new turn."
        case .systemSleep: return "Listening stopped when your Mac went to sleep. Click me when you're ready."
        case .noRecognizedWords: return "I didn't catch any words. Click me and try again."
        }
    }
}

/// One immutable observation of the capture's monotonic timeline. UI reads this
/// sample; it must not invent or advance its own invitation/silence deadline.
struct VoiceCaptureTimingSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case waitingForSpeech, invitation, speaking, trailingSilence }
    let phase: Phase
    let sampledAt: Double
    let audioThrough: Double
    let deadlineAt: Double?
    let remainingSeconds: Double?
    let maximumRemainingSeconds: Double
    let selectedSilenceSeconds: Double
    let invitationSeconds: Double?
    let decision: VoiceCaptureDecision
}

/// One immutable measurement of a turn's audio timeline at the moment capture was
/// closed. Nothing here is inferred from the selected settings alone: `outcome`
/// distinguishes a completed trailing silence from an explicit release, and
/// `audioProcessedThrough` is always PCM that was really processed.
struct VoiceCaptureTimingEvidence: Equatable, Sendable {
    /// How the turn's speech boundary was closed. Only `.silenceSatisfied` claims
    /// the selected trailing-silence rule completed.
    enum Outcome: Equatable, Sendable { case silenceSatisfied, forcedFinish, maximumDuration }
    let captureStartedAt: Double
    let firstSpeechAt: Double
    let speechEndedAt: Double
    /// The instant this evidence releases the turn for transcription. It is the
    /// satisfied trailing-silence deadline for `.silenceSatisfied`, and the last
    /// audio actually processed for `.forcedFinish`. It is never a fabricated
    /// silence deadline.
    let silenceSatisfiedAt: Double
    /// Monotonic end of the PCM that was really processed for this turn.
    let audioProcessedThrough: Double
    let selectedSilenceSeconds: Double
    let invitationSeconds: Double?
    let outcome: Outcome

    init(captureStartedAt: Double, firstSpeechAt: Double, speechEndedAt: Double, silenceSatisfiedAt: Double,
         audioProcessedThrough: Double? = nil, selectedSilenceSeconds: Double, invitationSeconds: Double?,
         outcome: Outcome = .silenceSatisfied) {
        self.captureStartedAt = captureStartedAt
        self.firstSpeechAt = firstSpeechAt
        self.speechEndedAt = speechEndedAt
        self.silenceSatisfiedAt = silenceSatisfiedAt
        self.audioProcessedThrough = audioProcessedThrough ?? max(silenceSatisfiedAt, speechEndedAt)
        self.selectedSilenceSeconds = selectedSilenceSeconds
        self.invitationSeconds = invitationSeconds
        self.outcome = outcome
    }
    /// The terminal reason this evidence reports, or `nil` when the selected
    /// trailing silence completed normally.
    var endReason: VoiceCaptureEndReason? {
        switch outcome {
        case .silenceSatisfied: return nil
        case .forcedFinish: return .forcedFinish
        case .maximumDuration: return .maximumDuration
        }
    }
    var isSilenceSatisfied: Bool { outcome == .silenceSatisfied }
}

/// One locked sample of a capture store: the level to display, the decision the
/// caller must act on, and the evidence that authorizes transcription.
struct VoiceCaptureObservation: Equatable, Sendable {
    let level: Double
    let decision: VoiceCaptureDecision
    let evidence: VoiceCaptureTimingEvidence?
    let snapshot: VoiceCaptureTimingSnapshot?
    let endReason: VoiceCaptureEndReason?
}

/// Monotonic audio timeline, independent of timers and the main actor. A deadline is
/// not final until PCM has been processed through it. This protects speech in an
/// in-flight audio buffer when the UI timer runs before the tap delivers that buffer.
/// The owner serializes observe/evaluate/close under the same lock as PCM storage.
struct VoiceCaptureDeadline: Sendable {
    static let maximumDuration = 300.0
    static let missingAudioGrace = 1.0
    /// A route/format change removes the tap on purpose, so its restart gap is not
    /// missing PCM. This is the bounded window allowed for the re-armed tap to
    /// deliver; it can never extend past `maximumDuration`.
    static let routeRearmGrace = 2.0
    let startedAt: Double
    let silenceSeconds: Double
    let invitationSeconds: Double?
    private(set) var firstSpeechAt: Double?
    private(set) var lastSpeechAt: Double?
    private(set) var audioThrough: Double
    private(set) var decision = VoiceCaptureDecision.listening
    private(set) var audioFailure: VoiceCaptureEndReason?
    private(set) var routeRearmedAt: Double?
    /// Earliest instant covered by the current contiguous PCM epoch. A deliberate
    /// tap re-arm opens a new epoch when its first buffer arrives, so a device gap
    /// can never be counted as silence: only speech observed at or after the epoch
    /// start may be followed by a satisfied silence.
    private(set) var coverageStartedAt: Double
    private var awaitingCoverageResume = false
    private var latestBufferContainsSpeech = false

    init(startedAt: Double, silenceSeconds: Double, invitationSeconds: Double? = nil) {
        self.startedAt = startedAt
        self.silenceSeconds = VoiceTimingSettings.silenceChoices.contains(silenceSeconds) ? silenceSeconds : 3
        self.invitationSeconds = invitationSeconds.map { VoiceTimingSettings.invitationChoices.contains($0) ? $0 : 6 }
        audioThrough = startedAt
        coverageStartedAt = startedAt
    }

    mutating func observeAudio(firstSpeech: Double?, lastSpeech: Double?, through: Double) {
        guard decision == .listening, through.isFinite, through >= audioThrough else { return }
        routeRearmedAt = nil // PCM is flowing again, so the re-arm window is over.
        if awaitingCoverageResume {
            // Conservatively the epoch starts where this buffer ends: the gap
            // itself stays uncovered and cannot prove silence.
            awaitingCoverageResume = false; coverageStartedAt = through
        }
        latestBufferContainsSpeech = false
        // A delayed UI timer must not join two utterances separated by a fully
        // satisfied silence interval. Audio timestamps decide this boundary too.
        if let lastSpeechAt, lastSpeechAt + silenceSeconds <= startedAt + Self.maximumDuration,
           coverageStartedAt <= lastSpeechAt {
            let silenceDeadline = lastSpeechAt + silenceSeconds
            if through >= silenceDeadline, firstSpeech.map({ $0 >= silenceDeadline }) ?? true {
                audioThrough = through; decision = .silenceSatisfied; return
            }
        }
        if let firstSpeech, let lastSpeech, firstSpeech.isFinite, lastSpeech.isFinite,
           firstSpeech <= lastSpeech, lastSpeech >= startedAt, lastSpeech <= through {
            let first = max(startedAt, firstSpeech)
            // Equality is expired: the invitation is specifically time to BEGIN.
            let mayBegin = invitationSeconds.map { first < startedAt + $0 } ?? true
            if self.firstSpeechAt != nil || mayBegin {
                if self.firstSpeechAt == nil { self.firstSpeechAt = first }
                self.lastSpeechAt = max(self.lastSpeechAt ?? startedAt, lastSpeech)
                latestBufferContainsSpeech = true
            }
        }
        audioThrough = through
    }

    @discardableResult mutating func evaluate(at now: Double) -> VoiceCaptureDecision {
        guard decision == .listening, now.isFinite, now >= startedAt else { return decision }
        let limit = startedAt + Self.maximumDuration
        let deadline: Double?
        let completion: VoiceCaptureDecision
        if let lastSpeechAt {
            deadline = lastSpeechAt + silenceSeconds; completion = .silenceSatisfied
        } else if let invitationSeconds {
            deadline = startedAt + invitationSeconds; completion = .noSpeech
        } else {
            deadline = nil; completion = .maximumDuration
        }
        // The earliest satisfied boundary wins, even after delayed main-thread work.
        // A silence is only proven inside one contiguous PCM epoch, so a device gap
        // can never finalize the turn as satisfied silence.
        if let deadline, deadline <= limit, now >= deadline, audioThrough >= deadline,
           completion != .silenceSatisfied || coverageStartedAt <= (lastSpeechAt ?? startedAt) {
            decision = completion
        } else if now >= limit {
            decision = .maximumDuration
        } else if now >= missingAudioDeadline {
            // Missing PCM is not silence, including before a manual turn's first
            // word. A live microphone cannot remain "listening" for the whole capture limit with no tap.
            // The only exemption is a deliberate tap re-arm after a route change,
            // and it is bounded by the same audio deadline as everything else.
            audioFailure = .missingAudio; decision = .audioUnavailable
        }
        return decision
    }

    private var missingAudioDeadline: Double {
        guard let routeRearmedAt else { return audioThrough + Self.missingAudioGrace }
        return max(audioThrough, routeRearmedAt) + Self.routeRearmGrace
    }

    /// The input device changed and the tap was re-armed for its new format. The
    /// turn keeps its original timeline: the re-arm only buys a bounded window for
    /// the first buffer of the new tap, and it opens a fresh PCM coverage epoch so
    /// the gap itself is never mistaken for silence. It cannot outlive the capture's
    /// own limit.
    mutating func rearmAfterRouteChange(at now: Double) {
        guard decision == .listening, now.isFinite else { return }
        routeRearmedAt = now
        awaitingCoverageResume = true
    }

    /// The user ended an unfinished turn explicitly (push-to-talk release). The
    /// audio already processed stays usable for transcription; the selected
    /// silence rule is never reported as satisfied.
    mutating func forceFinish() { if decision == .listening { decision = .forcedFinish } }

    mutating func cancel() { decision = .cancelled }
    mutating func rejectAudio() {
        if decision == .listening { audioFailure = .invalidAudio; decision = .audioUnavailable }
    }
    mutating func reachCaptureLimit() { if decision == .listening { decision = .maximumDuration } }
    var endReason: VoiceCaptureEndReason? {
        switch decision {
        case .listening, .silenceSatisfied: return nil
        case .forcedFinish: return .forcedFinish
        case .noSpeech: return .noSpeech
        case .maximumDuration: return .maximumDuration
        case .audioUnavailable: return audioFailure ?? .invalidAudio
        case .cancelled: return .intentionalCancellation
        }
    }
    func snapshot(at now: Double) -> VoiceCaptureTimingSnapshot {
        let sample = now.isFinite ? max(startedAt, now) : max(startedAt, audioThrough)
        let phase: VoiceCaptureTimingSnapshot.Phase
        let deadline: Double?
        if let lastSpeechAt {
            phase = latestBufferContainsSpeech ? .speaking : .trailingSilence
            deadline = lastSpeechAt + silenceSeconds
        } else if let invitationSeconds {
            phase = .invitation; deadline = startedAt + invitationSeconds
        } else {
            phase = .waitingForSpeech; deadline = nil
        }
        return VoiceCaptureTimingSnapshot(phase: phase, sampledAt: sample, audioThrough: audioThrough,
            deadlineAt: deadline, remainingSeconds: deadline.map { max(0, $0 - sample) },
            maximumRemainingSeconds: max(0, startedAt + Self.maximumDuration - sample),
            selectedSilenceSeconds: silenceSeconds, invitationSeconds: invitationSeconds, decision: decision)
    }
    /// Evidence for a completed trailing silence. Unchanged: it exists only when
    /// the selected silence rule really completed inside the processed audio.
    var timingEvidence: VoiceCaptureTimingEvidence? {
        guard decision == .silenceSatisfied, let firstSpeechAt, let lastSpeechAt else { return nil }
        return VoiceCaptureTimingEvidence(captureStartedAt: startedAt, firstSpeechAt: firstSpeechAt,
                                          speechEndedAt: lastSpeechAt, silenceSatisfiedAt: lastSpeechAt + silenceSeconds,
                                          audioProcessedThrough: audioThrough,
                                          selectedSilenceSeconds: silenceSeconds, invitationSeconds: invitationSeconds,
                                          outcome: .silenceSatisfied)
    }
    /// Evidence for a turn closed by explicit release. Every value is measured from
    /// processed PCM; `silenceSatisfiedAt` is the audio that was really processed
    /// (the instant the release authorizes transcription), never a silence deadline.
    /// `nil` when no speech was measured, because such a turn has no utterance.
    var forcedFinishEvidence: VoiceCaptureTimingEvidence? {
        guard decision == .forcedFinish, let firstSpeechAt else { return nil }
        let endedAt = min(max(lastSpeechAt ?? firstSpeechAt, firstSpeechAt), audioThrough)
        return VoiceCaptureTimingEvidence(captureStartedAt: startedAt, firstSpeechAt: firstSpeechAt,
                                          speechEndedAt: endedAt, silenceSatisfiedAt: audioThrough,
                                          audioProcessedThrough: audioThrough,
                                          selectedSilenceSeconds: silenceSeconds, invitationSeconds: invitationSeconds,
                                          outcome: .forcedFinish)
    }

    /// Evidence for a turn closed by the five-minute cap. The utterance and the
    /// audio processed are real; the selected silence rule never completed, so this
    /// is not satisfied-silence evidence. It exists only when speech was heard.
    var maximumDurationEvidence: VoiceCaptureTimingEvidence? {
        guard decision == .maximumDuration, let firstSpeechAt else { return nil }
        let endedAt = min(max(lastSpeechAt ?? firstSpeechAt, firstSpeechAt), audioThrough)
        return VoiceCaptureTimingEvidence(captureStartedAt: startedAt, firstSpeechAt: firstSpeechAt,
                                          speechEndedAt: endedAt, silenceSatisfiedAt: audioThrough,
                                          audioProcessedThrough: audioThrough,
                                          selectedSilenceSeconds: silenceSeconds, invitationSeconds: invitationSeconds,
                                          outcome: .maximumDuration)
    }
    /// The evidence a closed turn publishes, whichever way it ended. It stays `nil`
    /// while the turn is still listening and after any failure that cannot
    /// authorize transcription.
    var closedEvidence: VoiceCaptureTimingEvidence? {
        switch decision {
        case .silenceSatisfied: return timingEvidence
        case .forcedFinish: return forcedFinishEvidence
        case .maximumDuration: return maximumDurationEvidence
        default: return nil
        }
    }
}

enum VoiceMicrophonePermission: Sendable { case authorized, undetermined, denied }
enum VoiceCaptureAccessPolicy {
    static func shouldRequestPermission(invitation: Bool, permission: VoiceMicrophonePermission) -> Bool {
        !invitation && permission == .undetermined
    }
    static func mayCapture(permission: VoiceMicrophonePermission, routeAvailable: Bool) -> Bool {
        permission == .authorized && routeAvailable
    }
}

/// Input host timestamps must cover the interval we call "silence". A device
/// discontinuity cannot be treated as silent PCM merely because a later buffer arrives.
struct VoiceAudioContinuity {
    static let timestampTolerance = 0.005
    private(set) var through: Double?
    mutating func accept(from start: Double, through end: Double) -> Bool {
        guard start.isFinite, end.isFinite, start <= end else { return false }
        if let through {
            guard start >= through - Self.timestampTolerance,
                  start <= through + Self.timestampTolerance, end > through else { return false }
        }
        through = end; return true
    }
}

/// Select the PCM prefix inside both the monotonic capture window and the sample
/// budget. Inspect that prefix before applying the cap: it may finish the silence.
struct VoiceCaptureFrameWindow {
    let offset: Int
    let count: Int
    let reachesLimit: Bool

    init(frames: Int, stored: Int, rate: Double, bufferStartedAt: Double, captureStartedAt: Double) {
        let maximum = Int(rate * VoiceCaptureDeadline.maximumDuration)
        let end = captureStartedAt + VoiceCaptureDeadline.maximumDuration
        let firstFrame = max(0, ceil((captureStartedAt - bufferStartedAt) * rate))
        let lastFrame = max(0, floor((end - bufferStartedAt) * rate))
        offset = firstFrame >= Double(frames) ? frames : Int(firstFrame)
        let availableEnd = lastFrame >= Double(frames) ? frames : Int(lastFrame)
        count = min(max(0, availableEnd - offset), max(0, maximum - stored))
        reachesLimit = stored + count >= maximum || bufferStartedAt + Double(frames) / rate >= end
    }
}
