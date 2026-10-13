import Foundation

/// A small shared rig: all values describe rendered geometry, not an inferred emotion
/// or a claim about task success. Recipes never open the microphone or start work.
struct NativeExpressionPose: Equatable {
    var gazeX: Double = 0
    var gazeY: Double = 0
    var eyes: Double = 1
    var browLift: Double = 0
    var browAsymmetry: Double = 0
    var smile: Double = 4
    var mouthWidth: Double = 9
    var smileOpening: Double = 0
    var teeth: Double = 0
    var tilt: Double = 0
    var lift: Double = 0
    var squash: Double = 1
    var accent: Double = 0
    var cheeks: Double = 0.16
    var dimples: Double = 0

    static let rest = Self()
    func mixed(toward other: Self, by fraction: Double) -> Self {
        let u = min(1, max(0, fraction)), t = u * u * (3 - 2 * u)
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return Self(gazeX: blend(gazeX, other.gazeX), gazeY: blend(gazeY, other.gazeY),
                    eyes: blend(eyes, other.eyes), browLift: blend(browLift, other.browLift),
                    browAsymmetry: blend(browAsymmetry, other.browAsymmetry), smile: blend(smile, other.smile),
                    mouthWidth: blend(mouthWidth, other.mouthWidth), smileOpening: blend(smileOpening, other.smileOpening),
                    teeth: blend(teeth, other.teeth), tilt: blend(tilt, other.tilt),
                    lift: blend(lift, other.lift), squash: blend(squash, other.squash),
                    accent: blend(accent, other.accent), cheeks: blend(cheeks, other.cheeks), dimples: blend(dimples, other.dimples))
    }
}

struct NativeExpressionKeyframe: Equatable {
    let progress: Double
    let pose: NativeExpressionPose
}

struct NativeExpressionDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let state: NativeFaceState
    let purpose: String
    let duration: TimeInterval
    let keyframes: [NativeExpressionKeyframe]
    let blinkMoment: TimeInterval
    var compatibleStates: [NativeFaceState] { [state] }
    var trigger: String { "Actual \(state) phase entry or the preceding compatible recipe finishing: \(purpose)" }
    var cancellation: String { "Discard immediately on phase/skin change, hidden view, Stop, or motion/accessibility change; no delayed completion callback." }

    func sample(elapsed: TimeInterval) -> NativeExpressionPose {
        let progress = elapsed.isFinite ? min(1, max(0, elapsed / duration)) : 0
        for index in 1..<keyframes.count where progress <= keyframes[index].progress {
            let previous = keyframes[index - 1], next = keyframes[index]
            return previous.pose.mixed(toward: next.pose, by: (progress - previous.progress) / (next.progress - previous.progress))
        }
        return keyframes.last?.pose ?? .rest
    }

    func blink(elapsed: TimeInterval) -> Double {
        // A brief complete blink, never a sustained suspicious eye slit.
        let distance = abs(elapsed - blinkMoment)
        return distance < 0.09 ? 0.15 + 0.85 * distance / 0.09 : 1
    }
}

struct NativeExpressionContext {
    let state: NativeFaceState
    let elapsed: TimeInterval
    let visit: UInt64
    init(state: NativeFaceState, elapsed: TimeInterval, visit: UInt64 = 0) {
        self.state = state
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.visit = visit
    }
}

struct NativeExpressionSelection {
    let recipe: NativeExpressionDefinition
    let elapsed: TimeInterval
}

/// Uses monotonic time. The owning view resets it for state, skin, settings and
/// explicit turn/cancellation revisions; it owns no timer and starts no work.
struct NativeExpressionClock {
    private(set) var started: TimeInterval
    private(set) var visit: UInt64 = 0
    private var stateVisits: [NativeFaceState: UInt64] = [:]
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { started = now.isFinite ? now : 0 }
    mutating func restart(state: NativeFaceState, at now: TimeInterval) {
        started = now.isFinite ? now : 0
        visit &+= 1
        stateVisits[state, default: 0] &+= 1
    }
    func context(state: NativeFaceState, now: TimeInterval) -> NativeExpressionContext {
        .init(state: state, elapsed: now.isFinite ? max(0, now - started) : 0, visit: stateVisits[state, default: 0])
    }
}

enum NativeExpressionLibrary {
    /// These are explicitly authored trajectories, not a state × emotion Cartesian
    /// product. Shared use by ten identities does not imply ten separately authored
    /// libraries. Per-identity visual review and device performance remain evidence gates.
    static let all = idle + listening + thinking + speaking + blocked

    static func recipes(for state: NativeFaceState) -> [NativeExpressionDefinition] {
        switch state {
        case .idle: return idle
        case .listening: return listening
        case .thinking: return thinking
        case .speaking: return speaking
        case .blocked: return blocked
        }
    }

    static func select(_ context: NativeExpressionContext) -> NativeExpressionSelection {
        let candidates = recipes(for: context.state)
        let total = candidates.reduce(0) { $0 + $1.duration }
        var remaining = context.elapsed.truncatingRemainder(dividingBy: total)
        let start = Int(context.visit % UInt64(candidates.count))
        for offset in candidates.indices {
            let candidate = candidates[(start + offset) % candidates.count]
            if remaining < candidate.duration { return .init(recipe: candidate, elapsed: remaining) }
            remaining -= candidate.duration
        }
        return .init(recipe: candidates[start], elapsed: 0)
    }

    private static func r(_ id: String, _ name: String, _ state: NativeFaceState, _ purpose: String,
                          _ duration: Double, _ first: NativeExpressionPose, _ second: NativeExpressionPose,
                          beats: (Double, Double) = (0.28, 0.66)) -> NativeExpressionDefinition {
        .init(id: id, name: name, state: state, purpose: purpose, duration: duration,
              keyframes: [.init(progress: 0, pose: .rest), .init(progress: beats.0, pose: first),
                          .init(progress: beats.1, pose: second), .init(progress: 1, pose: .rest)],
              blinkMoment: duration * 0.84)
    }

    // A quiet companion: every gesture returns to a warm resting face. Body movement
    // stays inside the existing panel; it is not roaming, screen observation or a task.
    static let idle: [NativeExpressionDefinition] = [
        r("idle.soft-arrival", "Soft arrival", .idle, "settle into a quiet turn", 4.8,
          .init(eyes: 1.10, smile: 5.8, mouthWidth: 11, lift: -1.8, squash: 1.018, cheeks: 0.23),
          .init(gazeY: 0.6, smile: 4.8, lift: 0.8, squash: 0.993, accent: 0.2)),
        r("idle.left-curiosity", "Left curiosity", .idle, "a small curious glance", 5.2,
          .init(gazeX: -3.5, gazeY: -1.2, eyes: 1.14, browLift: -1.5, tilt: -4.4, accent: -0.5),
          .init(gazeX: -1, eyes: 1.03, smile: 5.5, tilt: -1.2, accent: 0.2)),
        r("idle.right-interest", "Right interest", .idle, "a light upward glance", 4.9,
          .init(gazeX: 3.2, gazeY: -2, eyes: 1.18, browLift: -2, browAsymmetry: -3, tilt: 3.1),
          .init(gazeX: 1.3, smile: 6, mouthWidth: 11.5, tilt: -0.8, cheeks: 0.24)),
        r("idle.breath-release", "Breath release", .idle, "a slow relaxed exhale gesture", 6.4,
          .init(eyes: 1.04, smile: 4.7, lift: -2.2, squash: 1.025, accent: 0.3),
          .init(gazeY: 1.1, eyes: 0.94, smile: 5.4, mouthWidth: 10.8, lift: 1.1, squash: 0.98)),
        r("idle.tiny-greeting", "Tiny greeting", .idle, "a small welcoming nod", 3.7,
          .init(gazeY: 1.7, eyes: 1.10, smile: 6.2, mouthWidth: 12, smileOpening: 2.8, lift: 2.2, accent: 0.7, cheeks: 0.24, dimples: 0.8),
          .init(gazeY: -0.8, eyes: 1.05, smile: 5.3, tilt: 1.4, lift: -0.7)),
        r("idle.soft-sway", "Soft sway", .idle, "a relaxed side-to-side settling motion", 6.1,
          .init(gazeX: -1.2, smile: 5, tilt: -4.8, squash: 1.01, accent: -0.65),
          .init(gazeX: 1.7, smile: 5.4, mouthWidth: 10.5, tilt: 3.7, accent: 0.55)),
        r("idle.open-welcome", "Open welcome", .idle, "an open friendly resting expression", 4.3,
          .init(eyes: 1.24, browLift: -2.4, smile: 6.8, mouthWidth: 12.5, smileOpening: 4.5, teeth: 0.7, lift: -1, cheeks: 0.28),
          .init(eyes: 1.12, browLift: -0.8, smile: 5.8, mouthWidth: 11, accent: 0.4)),
        r("idle.comfortable-pause", "Comfortable pause", .idle, "a calm companion pause", 7.2,
          .init(gazeY: 0.8, eyes: 0.94, smile: 4.3, tilt: 2.6, lift: 0.8, cheeks: 0.20),
          .init(gazeX: -0.7, eyes: 1.06, smile: 5.2, tilt: 0.7, lift: -0.8)),
        r("idle.spark-of-interest", "Spark of interest", .idle, "brief bright-eyed interest without making a suggestion", 3.9,
          .init(gazeX: 1.2, gazeY: -2.1, eyes: 1.27, browLift: -2.6, smile: 5.8, smileOpening: 3.6, lift: -2.1, accent: 0.85),
          .init(gazeX: 0.5, eyes: 1.09, smile: 6.3, mouthWidth: 11.7, tilt: 1.9)),
        r("idle.gentle-lean", "Gentle lean", .idle, "a small warm lean and return", 5.8,
          .init(gazeX: -1.8, gazeY: 0.4, eyes: 1.08, smile: 5.7, tilt: -5.2, lift: 0.5),
          .init(gazeX: 0.8, smile: 4.9, tilt: -1.7, accent: 0.45)),
        r("idle.sunny-rest", "Sunny rest", .idle, "a broad gentle resting smile", 6.0,
          .init(eyes: 1.05, browLift: -0.7, smile: 7.0, mouthWidth: 13, smileOpening: 3, teeth: 0.85, cheeks: 0.30, dimples: 1),
          .init(gazeY: -0.7, smile: 5.9, mouthWidth: 11.8, lift: -0.8, accent: 0.35)),
        r("idle.upward-wonder", "Upward wonder", .idle, "a soft look upward", 5.6,
          .init(gazeY: -3.2, eyes: 1.23, browLift: -2.1, smile: 4.7, smileOpening: 2.2, tilt: -1.8, lift: -1.1),
          .init(gazeX: 1.4, gazeY: -1.2, smile: 5.7, tilt: 1.3, accent: -0.3)),
        r("idle.playful-balance", "Playful balance", .idle, "a contained playful balancing gesture", 4.6,
          .init(gazeX: 2.1, eyes: 1.14, smile: 6.1, smileOpening: 4, teeth: 0.4, tilt: 4.8, lift: -1.5, accent: 0.8, dimples: 0.6),
          .init(gazeX: -1.5, smile: 6.5, mouthWidth: 12, tilt: -3.9, squash: 0.987, accent: -0.6)),
        r("idle.little-stretch", "Little stretch", .idle, "a tiny in-place stretch", 5.1,
          .init(gazeY: -1.8, eyes: 1.12, browLift: -1.6, smile: 5.8, lift: -2.5, squash: 1.035, accent: 0.5),
          .init(eyes: 0.97, smile: 6.1, mouthWidth: 11.2, lift: 1.4, squash: 0.975)),
        r("idle.kind-attention", "Kind attention", .idle, "return attention softly to the user", 5.3,
          .init(gazeX: -2.5, eyes: 1.06, browAsymmetry: 3, smile: 4.8, tilt: -2.2),
          .init(eyes: 1.19, browLift: -1.2, smile: 6.4, mouthWidth: 11.8, smileOpening: 2, lift: -0.6, cheeks: 0.25, dimples: 0.9)),
        r("idle.cozy-settle", "Cozy settle", .idle, "settle lower without looking asleep", 6.8,
          .init(gazeY: 1.6, eyes: 0.96, smile: 5.2, tilt: 1.8, lift: 2.0, squash: 0.97),
          .init(gazeY: 0.4, eyes: 1.04, smile: 5.7, tilt: -0.8, lift: 0.6, accent: -0.2)),
        r("idle.bright-nod", "Bright nod", .idle, "a light upbeat nod", 3.6,
          .init(eyes: 1.22, browLift: -1.8, smile: 6.6, mouthWidth: 12, smileOpening: 3.2, teeth: 0.5, lift: -1.2, accent: 0.65),
          .init(gazeY: 1.7, eyes: 1.10, smile: 5.9, lift: 1.9, squash: 0.985)),
        r("idle.small-delight", "Small delight", .idle, "a quiet cheerful lift", 4.2,
          .init(eyes: 1.20, browLift: -2.3, smile: 7.2, mouthWidth: 13.2, smileOpening: 6, teeth: 1, lift: -1.9, cheeks: 0.32, dimples: 1),
          .init(gazeX: 0.8, smile: 6.1, tilt: 2.4, accent: 0.55)),
        r("idle.easy-rock", "Easy rock", .idle, "slow grounding movement", 7.0,
          .init(gazeX: 1.0, gazeY: 0.6, eyes: 0.97, smile: 5, tilt: 3.3, lift: 1.0, accent: 0.3),
          .init(gazeX: -1.2, eyes: 1.04, smile: 5.8, tilt: -2.4, lift: -0.6, accent: -0.4)),
        r("idle.friendly-double-look", "Friendly double look", .idle, "two small glances and a welcoming return", 5.7,
          .init(gazeX: -3, gazeY: -0.6, eyes: 1.17, browLift: -1.2, smile: 5.4, tilt: -2.8),
          .init(gazeX: 2.5, gazeY: 0.4, eyes: 1.12, browAsymmetry: -2, smile: 6, tilt: 2.1)),
        r("idle.airy-rise", "Airy rise", .idle, "a gentle buoyant breath", 6.6,
          .init(gazeY: -1.4, eyes: 1.09, smile: 5.5, lift: -2.8, squash: 1.02, accent: 0.9),
          .init(gazeY: 0.8, eyes: 1.01, smile: 4.8, lift: 0.9, accent: -0.45)),
        r("idle.reassuring-presence", "Reassuring presence", .idle, "a steady kind expression", 6.9,
          .init(eyes: 1.12, browLift: -1, smile: 5.1, mouthWidth: 10.3, tilt: -1.3, cheeks: 0.22, dimples: 0.75),
          .init(gazeY: 0.9, eyes: 1.07, smile: 6.2, mouthWidth: 11.9, lift: 0.6)),
        r("idle.mellow-curiosity", "Mellow curiosity", .idle, "a gentle asymmetric inquisitive pose", 5.5,
          .init(gazeX: 2.6, gazeY: -1.1, eyes: 1.13, browLift: -0.8, browAsymmetry: -4, smile: 4.9, tilt: 4.1),
          .init(gazeX: 0.7, eyes: 1.07, smile: 5.8, tilt: 1.8, accent: 0.2)),
        r("idle.return-to-center", "Return to center", .idle, "a small downward glance and recentering", 4.7,
          .init(gazeX: -1.4, gazeY: 2.1, eyes: 1.01, smile: 4.6, tilt: -1.7, lift: 1.3),
          .init(eyes: 1.16, browLift: -1.3, smile: 6, mouthWidth: 11.4, lift: -0.7, accent: 0.45))
    ]

    static let listening: [NativeExpressionDefinition] = [
        r("listen.open-attention", "Open attention", .listening, "welcome the actual listening phase", 4.2,
          .init(eyes: 1.24, browLift: -2.3, smile: 5.2, mouthWidth: 10.5, lift: -1, accent: 0.5),
          .init(gazeY: 0.5, eyes: 1.14, smile: 4.8, tilt: 1.2)),
        r("listen.kind-lean", "Kind listening lean", .listening, "lean gently while capture continues", 5.0,
          .init(gazeX: -1.1, eyes: 1.18, browLift: -1.3, smile: 5, tilt: -4.0, accent: -0.6),
          .init(eyes: 1.12, smile: 5.7, mouthWidth: 10.8, tilt: -1.4)),
        r("listen.soft-nod", "Soft listening nod", .listening, "a listening nod without claiming understanding", 3.8,
          .init(gazeY: 1.9, eyes: 1.12, smile: 5.4, lift: 1.6, squash: 0.989),
          .init(gazeY: -0.5, eyes: 1.20, browLift: -1.2, smile: 4.8, lift: -0.8, accent: 0.3)),
        r("listen.steady-presence", "Steady listening presence", .listening, "maintain calm attention", 6.3,
          .init(eyes: 1.10, browLift: -0.5, smile: 4.5, mouthWidth: 9.8, tilt: 0.8),
          .init(gazeY: -0.8, eyes: 1.15, smile: 5.4, lift: -0.4, cheeks: 0.22)),
        r("listen.gentle-interest", "Gentle interest", .listening, "friendly curiosity while listening", 4.9,
          .init(gazeX: 1.6, gazeY: -0.7, eyes: 1.22, browLift: -1.6, browAsymmetry: -3, smile: 5.1, tilt: 3.2),
          .init(gazeX: 0.4, eyes: 1.15, smile: 5.8, tilt: 0.9, accent: 0.3)),
        r("listen.patient-space", "Patient space", .listening, "leave the user room to finish", 6.8,
          .init(gazeY: 0.6, eyes: 1.03, smile: 4.8, tilt: -1.5, lift: 0.8, accent: -0.2),
          .init(eyes: 1.15, browLift: -1.0, smile: 5.2, lift: -0.6)),
        r("listen.bright-focus", "Bright focus", .listening, "open-eyed focus without a frown", 4.1,
          .init(eyes: 1.28, browLift: -2.5, smile: 4.9, lift: -1.4, accent: 0.7),
          .init(eyes: 1.17, browLift: -0.7, smile: 5.7, mouthWidth: 11.2, cheeks: 0.24)),
        r("listen.right-tilt", "Listening right tilt", .listening, "a warm head tilt", 5.6,
          .init(gazeX: 0.8, eyes: 1.16, smile: 5.4, tilt: 4.8, lift: -0.4, accent: 0.55),
          .init(gazeX: -0.3, eyes: 1.11, smile: 4.7, tilt: 1.8)),
        r("listen.small-settle", "Small listening settle", .listening, "settle while remaining attentive", 5.8,
          .init(gazeY: 1.2, eyes: 1.08, smile: 5.2, lift: 1.4, squash: 0.983),
          .init(eyes: 1.19, browLift: -1.4, smile: 5.8, lift: -0.6, accent: 0.4)),
        r("listen.attentive-breath", "Attentive breath", .listening, "a restrained breathing motion during capture", 6.1,
          .init(gazeY: -0.8, eyes: 1.12, smile: 4.7, lift: -1.8, squash: 1.022),
          .init(gazeY: 0.7, eyes: 1.10, smile: 5.3, lift: 0.9, squash: 0.992, accent: -0.3)),
        r("listen.curious-brow", "Curious listening brow", .listening, "gentle asymmetric interest", 4.6,
          .init(gazeX: -1.2, eyes: 1.17, browLift: -1.8, browAsymmetry: 4, smile: 5.0, tilt: -2.6),
          .init(eyes: 1.21, browLift: -0.9, smile: 5.6, accent: 0.5)),
        r("listen.encouraging-smile", "Encouraging smile", .listening, "a warm nonverbal listening cue", 5.3,
          .init(eyes: 1.15, smile: 6.5, mouthWidth: 12.2, smileOpening: 1.7, accent: 0.4, cheeks: 0.29, dimples: 0.8),
          .init(gazeY: 0.5, eyes: 1.12, smile: 5.8, tilt: 1.6, lift: 0.6)),
        r("listen.unhurried-nod", "Unhurried nod", .listening, "an unhurried attention gesture", 6.5,
          .init(gazeY: 1.5, eyes: 1.13, smile: 5.1, tilt: -0.8, lift: 1.8),
          .init(gazeY: -1.0, eyes: 1.22, browLift: -1.6, smile: 5.5, lift: -1.1)),
        r("listen.centered-warmth", "Centered warmth", .listening, "steady direct attention", 5.7,
          .init(eyes: 1.20, browLift: -1.4, smile: 5.9, mouthWidth: 11.6, cheeks: 0.25, dimples: 1),
          .init(eyes: 1.09, smile: 5.0, lift: 0.4, accent: -0.2)),
        r("listen.little-lean-in", "Little lean in", .listening, "a contained leaning gesture", 4.4,
          .init(gazeY: 0.8, eyes: 1.25, browLift: -2, smile: 5.3, lift: 0.8, squash: 1.018, accent: 0.65),
          .init(eyes: 1.16, smile: 5.7, tilt: -1.2, lift: -0.3)),
        r("listen.easy-patience", "Easy patience", .listening, "wait calmly through a speaking pause", 7.0,
          .init(gazeY: 0.4, eyes: 1.02, smile: 5.4, tilt: 2.1, lift: 0.5),
          .init(eyes: 1.14, browLift: -0.8, smile: 6.0, mouthWidth: 11.4, accent: 0.3, dimples: 0.65)),
        r("listen.friendly-poise", "Friendly poise", .listening, "a small poised head turn", 5.1,
          .init(gazeX: 1.3, eyes: 1.19, browAsymmetry: -2, smile: 5.2, tilt: 2.7, accent: 0.5),
          .init(gazeX: -0.6, eyes: 1.12, smile: 5.6, tilt: -1.7, accent: -0.35)),
        r("listen.soft-alertness", "Soft alertness", .listening, "bright eyes with relaxed brows", 4.7,
          .init(gazeY: -0.5, eyes: 1.26, browLift: -2.2, smile: 4.8, lift: -0.9),
          .init(eyes: 1.18, smile: 6.1, mouthWidth: 11.8, smileOpening: 1.4, cheeks: 0.26, dimples: 0.5)),
        r("listen.kind-pause", "Kind pause", .listening, "an attentive still moment inside listening", 6.7,
          .init(eyes: 1.09, smile: 5.7, mouthWidth: 11, tilt: -1.1, cheeks: 0.24),
          .init(gazeY: 1.0, eyes: 1.14, smile: 5.2, lift: 0.7, accent: -0.25)),
        r("listen.rising-attention", "Rising attention", .listening, "a small attentive lift", 4.5,
          .init(gazeY: -1.2, eyes: 1.23, browLift: -1.9, smile: 5.4, lift: -1.6, accent: 0.75),
          .init(eyes: 1.16, smile: 5.9, lift: 0.6, squash: 0.989)),
        r("listen.comfortable-focus", "Comfortable focus", .listening, "focus while staying approachable", 5.9,
          .init(gazeX: -0.6, eyes: 1.12, browLift: -1.1, smile: 5.0, tilt: -2.0, accent: -0.45),
          .init(eyes: 1.18, smile: 5.8, mouthWidth: 11.1, lift: -0.5)),
        r("listen.gentle-acknowledgment", "Gentle listening cue", .listening, "a listening cue, not a judgment of the utterance", 4.0,
          .init(gazeY: 1.6, eyes: 1.15, smile: 6.0, mouthWidth: 11.7, lift: 1.4, accent: 0.55),
          .init(gazeY: -0.7, eyes: 1.24, browLift: -1.5, smile: 5.3, tilt: 1.1)),
        r("listen.receptive-tilt", "Receptive tilt", .listening, "a receptive open-eyed pose", 5.4,
          .init(gazeX: -0.8, gazeY: -0.3, eyes: 1.22, browLift: -1.7, smile: 5.6, tilt: -3.5),
          .init(gazeX: 0.3, eyes: 1.15, smile: 6.2, mouthWidth: 11.9, tilt: -0.6, accent: 0.35)),
        r("listen.patient-return", "Patient return", .listening, "return to centered attention without ending capture", 6.2,
          .init(gazeX: 1.0, gazeY: 0.7, eyes: 1.08, smile: 5.1, tilt: 1.9, lift: 0.8),
          .init(eyes: 1.23, browLift: -1.8, smile: 5.9, mouthWidth: 11.3, lift: -0.8, accent: 0.6))
    ]

    static let thinking: [NativeExpressionDefinition] = [
        r("think.gentle-consideration", "Gentle consideration", .thinking, "a friendly work-in-progress pose", 5.4,
          .init(gazeX: 2.5, gazeY: -2.2, eyes: 1.16, browLift: -1.7, smile: 4.8, tilt: 2.8),
          .init(gazeX: 0.8, gazeY: -0.7, eyes: 1.09, smile: 5.6, accent: 0.4)),
        r("think.left-reflection", "Left reflection", .thinking, "a soft reflective glance", 6.0,
          .init(gazeX: -3.2, gazeY: -1.7, eyes: 1.11, browAsymmetry: 3, smile: 4.5, tilt: -3.8),
          .init(gazeX: -1.4, gazeY: 0.5, smile: 5.8, mouthWidth: 11.3, tilt: -0.9, accent: -0.4)),
        r("think.upward-focus", "Upward focus", .thinking, "open-eyed concentration", 4.7,
          .init(gazeY: -3.5, eyes: 1.23, browLift: -2.5, smile: 4.7, lift: -1.4, accent: 0.65),
          .init(gazeX: 1.2, gazeY: -1, eyes: 1.13, smile: 5.2, tilt: 1.3)),
        r("think.patient-breath", "Patient working breath", .thinking, "stay calm while processing continues", 7.1,
          .init(gazeY: -0.5, eyes: 1.05, smile: 5.1, lift: -2.0, squash: 1.024, accent: 0.2),
          .init(gazeY: 1.3, eyes: 1.02, smile: 5.7, mouthWidth: 11, lift: 1.2, squash: 0.981)),
        r("think.curious-pause", "Curious working pause", .thinking, "a small inquisitive pause", 5.2,
          .init(gazeX: 3.1, gazeY: -0.8, eyes: 1.21, browLift: -1.2, browAsymmetry: -4, smile: 5, tilt: 4.5),
          .init(gazeX: 0.5, eyes: 1.12, smile: 6.1, mouthWidth: 11.8, tilt: 0.8)),
        r("think.quiet-connection", "Quiet connection", .thinking, "a gentle moving gaze during processing", 5.8,
          .init(gazeX: -2.7, gazeY: -1.4, eyes: 1.12, smile: 4.8, tilt: -2.1, accent: -0.5),
          .init(gazeX: 2.4, gazeY: -1.8, eyes: 1.20, browLift: -1.5, smile: 5.6, tilt: 2.3, accent: 0.5)),
        r("think.steady-warmth", "Steady working warmth", .thinking, "remain approachable during a longer wait", 7.4,
          .init(eyes: 1.08, browLift: -0.7, smile: 6.0, mouthWidth: 11.8, cheeks: 0.27),
          .init(gazeY: -0.9, eyes: 1.16, smile: 5.3, lift: -0.7, accent: 0.3)),
        r("think.gentle-nod", "Gentle working nod", .thinking, "a quiet movement without claiming completion", 4.1,
          .init(gazeY: 1.9, eyes: 1.13, smile: 5.4, lift: 1.9, squash: 0.987),
          .init(gazeY: -1.3, eyes: 1.22, browLift: -1.8, smile: 5.9, lift: -1.0, accent: 0.55)),
        r("think.soft-brow-lift", "Soft brow lift", .thinking, "a relaxed brightening of attention", 4.8,
          .init(gazeX: 0.8, gazeY: -1.5, eyes: 1.26, browLift: -3, smile: 5.2, lift: -1.1),
          .init(gazeX: -0.5, eyes: 1.10, browLift: -0.6, smile: 6.2, mouthWidth: 12.2, cheeks: 0.26)),
        r("think.easy-lean", "Easy working lean", .thinking, "a gentle lateral shift of attention", 6.2,
          .init(gazeX: -1.6, gazeY: -0.6, eyes: 1.11, smile: 5.6, tilt: -5.0, accent: -0.75),
          .init(gazeX: 0.7, gazeY: -1.1, eyes: 1.18, smile: 5.1, tilt: -1.5, accent: 0.25)),
        r("think.open-mind", "Open-minded pose", .thinking, "a friendly open-eyed processing pose", 5.0,
          .init(eyes: 1.29, browLift: -2.2, smile: 5.8, mouthWidth: 11.5, smileOpening: 2.4, lift: -1.7, accent: 0.8),
          .init(gazeY: 0.5, eyes: 1.17, smile: 6.4, mouthWidth: 12.3, cheeks: 0.30)),
        r("think.downward-return", "Downward return", .thinking, "a small downward glance and warm return", 5.7,
          .init(gazeX: 1.4, gazeY: 2.6, eyes: 1.03, smile: 4.7, tilt: 2.2, lift: 1.4),
          .init(gazeY: -0.6, eyes: 1.20, browLift: -1.4, smile: 5.9, lift: -0.7)),
        r("think.light-sway", "Light working sway", .thinking, "a restrained in-place sway", 6.9,
          .init(gazeX: 1.8, eyes: 1.09, smile: 5.3, tilt: 3.9, accent: 0.55),
          .init(gazeX: -2.0, gazeY: -0.5, eyes: 1.16, smile: 5.8, tilt: -3.2, accent: -0.45)),
        r("think.kind-concentration", "Kind concentration", .thinking, "concentrate without narrowing the eyes", 5.5,
          .init(gazeY: -1.0, eyes: 1.15, browLift: -1.1, smile: 4.6, mouthWidth: 9.5, tilt: -0.8),
          .init(gazeX: 1.6, gazeY: -1.5, eyes: 1.22, browAsymmetry: -3, smile: 5.5, tilt: 1.8)),
        r("think.buoyant-patience", "Buoyant patience", .thinking, "a slow upward settling motion", 7.0,
          .init(gazeY: -1.6, eyes: 1.12, smile: 5.5, lift: -2.7, squash: 1.027, accent: 0.9),
          .init(gazeY: 0.8, eyes: 1.06, smile: 6.0, mouthWidth: 11.6, lift: 0.9, accent: -0.3)),
        r("think.friendly-angle", "Friendly thinking angle", .thinking, "a warm angled head pose", 5.3,
          .init(gazeX: 2.1, gazeY: -1.1, eyes: 1.18, browLift: -1.3, smile: 5.9, tilt: 5.1, cheeks: 0.25),
          .init(gazeX: 0.7, eyes: 1.11, smile: 5.0, tilt: 2.0, accent: 0.35)),
        r("think.small-recenter", "Small recenter", .thinking, "recenter from a short side glance", 4.4,
          .init(gazeX: -3.8, gazeY: 0.5, eyes: 1.14, smile: 5.1, tilt: -2.9),
          .init(gazeX: 0.4, gazeY: -0.7, eyes: 1.23, browLift: -1.6, smile: 6.3, mouthWidth: 12, lift: -0.5)),
        r("think.cheerful-endurance", "Cheerful endurance", .thinking, "maintain warmth during continued work", 7.6,
          .init(eyes: 1.10, smile: 6.8, mouthWidth: 12.7, tilt: -1.1, cheeks: 0.31, dimples: 1),
          .init(gazeY: 1.0, eyes: 1.05, smile: 5.7, lift: 0.8, accent: 0.25)),
        r("think.tiny-stretch", "Tiny working stretch", .thinking, "a contained stretch without leaving the work state", 5.9,
          .init(gazeY: -2.3, eyes: 1.18, browLift: -1.9, smile: 5.2, lift: -2.2, squash: 1.033),
          .init(gazeY: 0.7, eyes: 1.10, smile: 6.1, lift: 1.1, squash: 0.976, accent: 0.6)),
        r("think.gentle-alternation", "Gentle alternation", .thinking, "alternate two small reflective glances", 6.5,
          .init(gazeX: 2.8, gazeY: -2.0, eyes: 1.20, smile: 4.9, tilt: 2.7, accent: 0.45),
          .init(gazeX: -2.3, gazeY: 0.8, eyes: 1.13, smile: 5.8, tilt: -2.2, accent: -0.55)),
        r("think.soft-encouragement", "Soft working encouragement", .thinking, "offer a friendly expression while the result is pending", 5.6,
          .init(eyes: 1.16, browLift: -1.5, smile: 6.2, mouthWidth: 12.1, lift: -0.8, cheeks: 0.27),
          .init(gazeY: 1.2, eyes: 1.10, smile: 5.4, tilt: 1.5, lift: 1.0)),
        r("think.calm-curiosity", "Calm working curiosity", .thinking, "a curious pose with unhurried timing", 6.6,
          .init(gazeX: -2.1, gazeY: -2.7, eyes: 1.17, browLift: -2.0, browAsymmetry: 4, smile: 5.0, tilt: -3.4),
          .init(gazeX: -0.4, eyes: 1.12, smile: 5.9, mouthWidth: 11.7, accent: 0.4)),
        r("think.warm-oblique-glance", "Warm oblique glance", .thinking, "a brief diagonal look while staying friendly", 4.9,
          .init(gazeX: 3.4, gazeY: 1.7, eyes: 1.12, smile: 5.3, tilt: 3.5, lift: 0.6),
          .init(gazeX: 0.3, gazeY: -1.2, eyes: 1.24, browLift: -1.7, smile: 6.0, lift: -0.9)),
        r("think.patient-center", "Patient center", .thinking, "return to centered warmth while processing continues", 7.3,
          .init(gazeX: -0.8, eyes: 1.06, smile: 5.8, mouthWidth: 11.4, tilt: -1.9, lift: 0.7),
          .init(eyes: 1.21, browLift: -1.3, smile: 6.5, mouthWidth: 12.3, lift: -1.0, accent: 0.5))
    ]

    static let speaking: [NativeExpressionDefinition] = [
        r("speak.warm-opening", "Warm opening", .speaking, "a welcoming posture during actual playback", 4.0,
          .init(eyes: 1.20, browLift: -1.8, smile: 5.9, mouthWidth: 11.4, lift: -1.0, cheeks: 0.25),
          .init(gazeY: 0.6, eyes: 1.12, smile: 5.1, tilt: 1.3, accent: 0.35)),
        r("speak.gentle-emphasis", "Gentle emphasis", .speaking, "a small expressive nod over real audio", 3.7,
          .init(gazeY: 1.7, eyes: 1.17, browLift: -1.2, smile: 5.8, mouthWidth: 12.4, lift: 1.7, accent: 0.65),
          .init(gazeY: -0.5, eyes: 1.23, smile: 5.1, mouthWidth: 9.8, lift: -0.8)),
        r("speak.easy-explanation", "Easy explanation", .speaking, "a relaxed speaking posture", 5.6,
          .init(gazeX: 1.2, eyes: 1.11, smile: 5.3, mouthWidth: 10.5, tilt: 3.2, accent: 0.4),
          .init(gazeX: -0.6, eyes: 1.17, smile: 6.0, mouthWidth: 11.8, tilt: -1.6)),
        r("speak.friendly-cadence", "Friendly cadence", .speaking, "a contained side-to-side speaking gesture", 4.9,
          .init(gazeX: -1.8, eyes: 1.15, smile: 5.6, mouthWidth: 10.2, tilt: -3.8, accent: -0.55),
          .init(gazeX: 1.6, eyes: 1.20, smile: 6.2, mouthWidth: 12.0, tilt: 3.0, accent: 0.6)),
        r("speak.clear-attention", "Clear speaking attention", .speaking, "direct and friendly speaking attention", 4.4,
          .init(eyes: 1.26, browLift: -2.4, smile: 5.4, mouthWidth: 10.7, lift: -1.3),
          .init(eyes: 1.14, smile: 6.4, mouthWidth: 12.5, accent: 0.5, cheeks: 0.28)),
        r("speak.soft-lean", "Soft speaking lean", .speaking, "a small companionable lean", 5.2,
          .init(gazeX: -0.7, gazeY: 0.4, eyes: 1.13, smile: 5.8, mouthWidth: 11.3, tilt: -4.9),
          .init(eyes: 1.20, browLift: -1.2, smile: 5.2, mouthWidth: 9.7, tilt: -1.7, accent: 0.3)),
        r("speak.bright-delivery", "Bright delivery", .speaking, "a cheerful delivery posture without claiming success", 3.9,
          .init(eyes: 1.25, browLift: -2.0, smile: 7.0, mouthWidth: 13, teeth: 0.85, lift: -1.8, cheeks: 0.30, dimples: 0.9),
          .init(gazeY: 0.7, eyes: 1.16, smile: 6.0, mouthWidth: 11.2, lift: 0.7, accent: 0.7)),
        r("speak.calm-detail", "Calm detail", .speaking, "an unhurried speaking expression", 6.2,
          .init(gazeX: 0.8, eyes: 1.06, smile: 5.0, mouthWidth: 9.5, tilt: 1.7, lift: 0.5),
          .init(eyes: 1.16, browLift: -1.0, smile: 5.8, mouthWidth: 11.6, accent: 0.25)),
        r("speak.open-brow", "Open speaking brow", .speaking, "gentle brow emphasis during playback", 4.6,
          .init(gazeY: -0.8, eyes: 1.22, browLift: -3, browAsymmetry: -2, smile: 5.5, mouthWidth: 11.1),
          .init(gazeY: 0.5, eyes: 1.10, smile: 6.3, mouthWidth: 12.2, tilt: 1.4)),
        r("speak.little-nod", "Little speaking nod", .speaking, "a concise nod within the spoken reply", 3.5,
          .init(gazeY: 2.1, eyes: 1.14, smile: 5.7, mouthWidth: 11.8, lift: 2.1, squash: 0.984),
          .init(gazeY: -1.1, eyes: 1.24, browLift: -1.7, smile: 5.0, mouthWidth: 9.4, lift: -1.1)),
        r("speak.kind-assurance", "Kind speaking tone", .speaking, "warmth independent of factual certainty", 5.8,
          .init(eyes: 1.12, smile: 6.5, mouthWidth: 12.4, tilt: -1.5, cheeks: 0.29),
          .init(gazeY: 0.8, eyes: 1.18, smile: 5.6, mouthWidth: 10.9, lift: 0.6, accent: 0.35)),
        r("speak.light-turn", "Light speaking turn", .speaking, "a small expressive head turn", 4.8,
          .init(gazeX: 2.2, gazeY: -0.7, eyes: 1.16, browAsymmetry: -3, smile: 5.3, mouthWidth: 10.4, tilt: 4.3),
          .init(gazeX: 0.4, eyes: 1.23, smile: 6.1, mouthWidth: 12.1, tilt: 0.8, accent: 0.55)),
        r("speak.gentle-breath", "Gentle speaking breath", .speaking, "a slow body breath while mouth follows audio", 6.4,
          .init(eyes: 1.10, smile: 5.2, mouthWidth: 10.1, lift: -2.2, squash: 1.025, accent: 0.3),
          .init(gazeY: 0.9, eyes: 1.08, smile: 5.9, mouthWidth: 11.9, lift: 1.0, squash: 0.98)),
        r("speak.warm-inclination", "Warm inclination", .speaking, "a warm asymmetric speaking pose", 5.3,
          .init(gazeX: -1.5, eyes: 1.19, browLift: -1.4, browAsymmetry: 3, smile: 6.1, mouthWidth: 11.7, tilt: -3.1),
          .init(gazeX: 0.5, eyes: 1.12, smile: 5.4, mouthWidth: 10.2, tilt: 1.2, accent: 0.45)),
        r("speak.soft-expansion", "Soft expansion", .speaking, "a small open expressive lift", 4.1,
          .init(eyes: 1.27, browLift: -2.1, smile: 6.7, mouthWidth: 13.2, teeth: 0.7, lift: -1.5, squash: 1.018, accent: 0.8, dimples: 0.7),
          .init(gazeY: 0.5, eyes: 1.15, smile: 5.8, mouthWidth: 10.8, lift: 0.8)),
        r("speak.centered-clarity", "Centered clarity", .speaking, "steady centered delivery", 5.9,
          .init(eyes: 1.18, browLift: -1.5, smile: 5.1, mouthWidth: 9.6, lift: -0.6),
          .init(eyes: 1.10, smile: 6.2, mouthWidth: 12.3, accent: 0.2, cheeks: 0.26)),
        r("speak.cheerful-poise", "Cheerful poise", .speaking, "a friendly angled reply", 4.5,
          .init(gazeX: 1.1, eyes: 1.21, smile: 6.4, mouthWidth: 12.0, tilt: 3.7, lift: -0.8, cheeks: 0.28),
          .init(gazeX: -0.8, eyes: 1.14, smile: 5.6, mouthWidth: 10.5, tilt: -1.1, accent: -0.4)),
        r("speak.unhurried-emphasis", "Unhurried emphasis", .speaking, "a slower nod accompanying speech", 6.6,
          .init(gazeY: 1.5, eyes: 1.13, smile: 5.5, mouthWidth: 11.3, lift: 1.8, accent: 0.6),
          .init(gazeY: -0.9, eyes: 1.22, browLift: -1.8, smile: 6.0, mouthWidth: 11.9, lift: -1.0)),
        r("speak.small-lilt", "Small speaking lilt", .speaking, "a light return from a head tilt", 4.3,
          .init(gazeX: -2.0, gazeY: -0.6, eyes: 1.17, smile: 5.8, mouthWidth: 11.1, tilt: -4.2, accent: -0.65),
          .init(gazeX: 0.6, eyes: 1.23, smile: 6.6, mouthWidth: 12.7, tilt: 1.9, accent: 0.4)),
        r("speak.friendly-reflection", "Friendly speaking reflection", .speaking, "a brief reflective glance during a reply", 5.7,
          .init(gazeX: 1.8, gazeY: -2.1, eyes: 1.16, browLift: -1.8, smile: 5.3, mouthWidth: 10.0, tilt: 2.5),
          .init(eyes: 1.21, smile: 6.1, mouthWidth: 12.2, cheeks: 0.25)),
        r("speak.grounded-warmth", "Grounded warmth", .speaking, "a comfortable lower body pose while speaking", 6.1,
          .init(gazeY: 0.7, eyes: 1.08, smile: 5.8, mouthWidth: 11.4, lift: 1.5, squash: 0.977),
          .init(eyes: 1.19, browLift: -1.2, smile: 6.4, mouthWidth: 12.5, lift: -0.5, accent: 0.4)),
        r("speak.bright-attention", "Bright speaking attention", .speaking, "a bright yet gentle speaking face", 4.2,
          .init(eyes: 1.29, browLift: -2.6, smile: 6.0, mouthWidth: 11.6, lift: -1.2),
          .init(gazeX: 0.8, eyes: 1.18, smile: 6.9, mouthWidth: 13.0, teeth: 1, tilt: 1.7, cheeks: 0.31, dimples: 1)),
        r("speak.easy-recenter", "Easy speaking recenter", .speaking, "return to direct attention during audio", 5.1,
          .init(gazeX: -2.8, gazeY: 0.6, eyes: 1.12, smile: 5.2, mouthWidth: 10.4, tilt: -2.7),
          .init(gazeY: -0.4, eyes: 1.24, browLift: -1.6, smile: 6.3, mouthWidth: 12.1, lift: -0.7, accent: 0.5)),
        r("speak.companionable-close", "Companionable cadence", .speaking, "a warm cadence without declaring the answer finished", 6.0,
          .init(eyes: 1.15, smile: 6.7, mouthWidth: 12.8, tilt: 1.5, cheeks: 0.30),
          .init(gazeY: 1.0, eyes: 1.11, smile: 5.8, mouthWidth: 11.2, lift: 1.1, accent: 0.3))
    ]

    static let blocked: [NativeExpressionDefinition] = [
        r("support.patient-presence", "Patient presence", .blocked, "remain kind while a visible issue is unresolved", 7.2,
          .init(eyes: 1.10, smile: 5.0, mouthWidth: 10.4, tilt: -1.4, cheeks: 0.22),
          .init(gazeY: 0.7, eyes: 1.05, smile: 5.7, mouthWidth: 11.2, lift: 0.7)),
        r("support.gentle-tilt", "Gentle supportive tilt", .blocked, "a warm attentive issue-state pose", 5.8,
          .init(gazeX: -1.0, eyes: 1.17, browLift: -1.2, smile: 5.4, tilt: -4.0, accent: -0.45),
          .init(eyes: 1.10, smile: 5.9, mouthWidth: 11.3, tilt: -1.1)),
        r("support.steady-smile", "Steady supportive smile", .blocked, "warmth without implying the issue is fixed", 7.7,
          .init(eyes: 1.08, smile: 6.3, mouthWidth: 12.0, cheeks: 0.28, dimples: 0.75),
          .init(gazeY: -0.4, eyes: 1.15, browLift: -0.8, smile: 5.5, lift: -0.5)),
        r("support.soft-breath", "Soft supportive breath", .blocked, "a slow calming breath gesture", 7.4,
          .init(eyes: 1.04, smile: 5.2, lift: -1.8, squash: 1.02, accent: 0.25),
          .init(gazeY: 1.1, eyes: 0.98, smile: 5.8, mouthWidth: 11, lift: 1.0, squash: 0.982)),
        r("support.open-patience", "Open patience", .blocked, "open eyes and patient attention", 6.1,
          .init(eyes: 1.24, browLift: -1.9, smile: 5.3, mouthWidth: 10.8, lift: -0.7),
          .init(eyes: 1.13, smile: 6.0, mouthWidth: 11.7, accent: 0.4, cheeks: 0.26)),
        r("support.small-nod", "Small supportive nod", .blocked, "a gentle cue while waiting for resolution", 5.2,
          .init(gazeY: 1.7, eyes: 1.12, smile: 5.6, lift: 1.5, squash: 0.986),
          .init(gazeY: -0.6, eyes: 1.18, browLift: -1.0, smile: 5.2, lift: -0.6, accent: 0.3)),
        r("support.kind-focus", "Kind issue focus", .blocked, "stay attentive to the unresolved state", 6.6,
          .init(gazeX: 0.5, eyes: 1.16, browLift: -1.2, smile: 4.8, tilt: 1.6),
          .init(eyes: 1.09, smile: 5.9, mouthWidth: 11.5, accent: 0.2, cheeks: 0.24)),
        r("support.comfortable-wait", "Comfortable wait", .blocked, "wait without agitation", 8.0,
          .init(gazeY: 0.8, eyes: 1.00, smile: 5.5, tilt: -2.0, lift: 0.8),
          .init(eyes: 1.13, browLift: -0.7, smile: 5.1, tilt: -0.5, lift: -0.4)),
        r("support.friendly-inclination", "Friendly supportive inclination", .blocked, "a kind angled face", 5.7,
          .init(gazeX: 0.9, eyes: 1.18, smile: 5.8, mouthWidth: 11.1, tilt: 3.9, cheeks: 0.25),
          .init(eyes: 1.11, smile: 5.2, tilt: 1.2, accent: 0.35)),
        r("support.unhurried-attention", "Unhurried attention", .blocked, "maintain patient availability", 7.5,
          .init(gazeY: -0.6, eyes: 1.12, browLift: -0.8, smile: 5.0, lift: -0.8),
          .init(gazeY: 0.9, eyes: 1.06, smile: 6.1, mouthWidth: 11.9, lift: 0.8, cheeks: 0.27)),
        r("support.quiet-encouragement", "Quiet encouragement", .blocked, "a gentle smile independent of task outcome", 6.0,
          .init(eyes: 1.19, browLift: -1.3, smile: 6.5, mouthWidth: 12.4, lift: -0.6, cheeks: 0.29),
          .init(gazeY: 0.5, eyes: 1.10, smile: 5.6, tilt: 1.1, accent: 0.4)),
        r("support.easy-settle", "Easy supportive settle", .blocked, "a small settling motion", 7.0,
          .init(gazeY: 1.4, eyes: 1.03, smile: 5.3, lift: 1.8, squash: 0.974),
          .init(eyes: 1.16, browLift: -1.1, smile: 5.9, lift: -0.5, accent: 0.3)),
        r("support.gentle-recenter", "Gentle supportive recenter", .blocked, "return softly from a small glance", 5.9,
          .init(gazeX: -2.3, gazeY: 0.6, eyes: 1.11, smile: 5.1, tilt: -2.5),
          .init(eyes: 1.20, browLift: -1.4, smile: 6.0, mouthWidth: 11.8, lift: -0.5)),
        r("support.warm-stillness", "Warm stillness", .blocked, "a low-motion smile during an issue", 8.3,
          .init(eyes: 1.07, smile: 6.1, mouthWidth: 11.7, cheeks: 0.27),
          .init(gazeY: 0.4, eyes: 1.12, smile: 5.4, mouthWidth: 10.7, accent: 0.15)),
        r("support.soft-alertness", "Soft supportive alertness", .blocked, "stay visibly awake without pressure", 5.4,
          .init(eyes: 1.25, browLift: -2.1, smile: 5.4, lift: -1.2, accent: 0.55),
          .init(eyes: 1.14, smile: 6.2, mouthWidth: 12.1, cheeks: 0.26)),
        r("support.kind-rock", "Kind supportive rock", .blocked, "a slow reassuring in-place sway", 7.8,
          .init(gazeX: -0.9, eyes: 1.09, smile: 5.6, tilt: -3.0, accent: -0.35),
          .init(gazeX: 1.1, eyes: 1.15, smile: 5.9, mouthWidth: 11.2, tilt: 2.4, accent: 0.4)),
        r("support.patient-lean", "Patient supportive lean", .blocked, "a small patient lean", 6.3,
          .init(gazeX: -0.6, gazeY: 0.5, eyes: 1.16, smile: 5.2, tilt: -4.7, lift: 0.5),
          .init(eyes: 1.11, smile: 6.1, mouthWidth: 11.8, tilt: -1.8, accent: 0.25)),
        r("support.calm-lift", "Calm supportive lift", .blocked, "a quiet buoyant breath", 7.1,
          .init(gazeY: -1.0, eyes: 1.12, smile: 5.4, lift: -2.2, squash: 1.025, accent: 0.65),
          .init(gazeY: 0.7, eyes: 1.06, smile: 5.8, lift: 0.8, accent: -0.2)),
        r("support.gentle-brow", "Gentle supportive brow", .blocked, "a softly raised friendly brow", 5.6,
          .init(eyes: 1.18, browLift: -1.7, browAsymmetry: 3, smile: 5.1, tilt: -1.9),
          .init(eyes: 1.12, smile: 6.0, mouthWidth: 11.6, accent: 0.3, cheeks: 0.25)),
        r("support.companionable-wait", "Companionable wait", .blocked, "a comfortable smile while the issue remains", 8.1,
          .init(gazeX: 0.7, eyes: 1.05, smile: 5.9, mouthWidth: 11.5, tilt: 1.7, lift: 0.6),
          .init(eyes: 1.14, browLift: -0.9, smile: 5.3, lift: -0.6)),
        r("support.light-nod", "Light supportive nod", .blocked, "a gentle attentive nod", 4.9,
          .init(gazeY: 1.9, eyes: 1.14, smile: 5.8, mouthWidth: 11.2, lift: 1.7, accent: 0.45),
          .init(gazeY: -0.9, eyes: 1.22, browLift: -1.5, smile: 5.4, lift: -0.9)),
        r("support.open-hearted", "Open-hearted patience", .blocked, "a broader warm smile with relaxed eyes", 6.8,
          .init(eyes: 1.13, browLift: -0.6, smile: 6.8, mouthWidth: 12.8, cheeks: 0.31, dimples: 1),
          .init(gazeY: 0.5, eyes: 1.18, smile: 5.9, tilt: -1.2, accent: 0.4)),
        r("support.soft-right-return", "Soft right return", .blocked, "a small rightward glance and return", 6.4,
          .init(gazeX: 2.4, gazeY: -0.6, eyes: 1.16, browAsymmetry: -2, smile: 5.3, tilt: 2.8),
          .init(eyes: 1.20, browLift: -1.1, smile: 6.2, mouthWidth: 12, lift: -0.4)),
        r("support.here-with-you", "Here with you", .blocked, "centered friendly presence without hiding the issue", 8.2,
          .init(eyes: 1.10, smile: 5.7, mouthWidth: 11.1, tilt: -0.8, cheeks: 0.25),
          .init(gazeY: 0.8, eyes: 1.16, browLift: -0.7, smile: 6.4, mouthWidth: 12.3, lift: 0.6, accent: 0.3))
    ]
}
