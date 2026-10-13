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
    case listening, silenceSatisfied, noSpeech, maximumDuration, audioUnavailable, cancelled
}

struct VoiceCaptureTimingEvidence: Equatable, Sendable {
    let captureStartedAt: Double
    let firstSpeechAt: Double
    let speechEndedAt: Double
    let silenceSatisfiedAt: Double
    let selectedSilenceSeconds: Double
    let invitationSeconds: Double?
}

/// Monotonic audio timeline, independent of timers and the main actor. A deadline is
/// not final until PCM has been processed through it. This protects speech in an
/// in-flight audio buffer when the UI timer runs before the tap delivers that buffer.
/// The owner serializes observe/evaluate/close under the same lock as PCM storage.
struct VoiceCaptureDeadline: Sendable {
    static let maximumDuration = 60.0
    static let missingAudioGrace = 1.0
    let startedAt: Double
    let silenceSeconds: Double
    let invitationSeconds: Double?
    private(set) var firstSpeechAt: Double?
    private(set) var lastSpeechAt: Double?
    private(set) var audioThrough: Double
    private(set) var decision = VoiceCaptureDecision.listening

    init(startedAt: Double, silenceSeconds: Double, invitationSeconds: Double? = nil) {
        self.startedAt = startedAt
        self.silenceSeconds = VoiceTimingSettings.silenceChoices.contains(silenceSeconds) ? silenceSeconds : 3
        self.invitationSeconds = invitationSeconds.map { VoiceTimingSettings.invitationChoices.contains($0) ? $0 : 6 }
        audioThrough = startedAt
    }

    mutating func observeAudio(firstSpeech: Double?, lastSpeech: Double?, through: Double) {
        guard decision == .listening, through.isFinite, through >= audioThrough else { return }
        // A delayed UI timer must not join two utterances separated by a fully
        // satisfied silence interval. Audio timestamps decide this boundary too.
        if let lastSpeechAt, lastSpeechAt + silenceSeconds <= startedAt + Self.maximumDuration {
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
        if let deadline, deadline <= limit, now >= deadline, audioThrough >= deadline {
            decision = completion
        } else if now >= limit {
            decision = .maximumDuration
        } else if let deadline, now >= deadline + Self.missingAudioGrace, audioThrough < deadline {
            decision = .audioUnavailable
        }
        return decision
    }

    mutating func cancel() { decision = .cancelled }
    mutating func rejectAudio() { if decision == .listening { decision = .audioUnavailable } }
    mutating func reachCaptureLimit() { if decision == .listening { decision = .maximumDuration } }
    var timingEvidence: VoiceCaptureTimingEvidence? {
        guard decision == .silenceSatisfied, let firstSpeechAt, let lastSpeechAt else { return nil }
        return VoiceCaptureTimingEvidence(captureStartedAt: startedAt, firstSpeechAt: firstSpeechAt,
                                          speechEndedAt: lastSpeechAt, silenceSatisfiedAt: lastSpeechAt + silenceSeconds,
                                          selectedSilenceSeconds: silenceSeconds, invitationSeconds: invitationSeconds)
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
