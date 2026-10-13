import Foundation

struct IdleMotionContext: Equatable {
    var visible = true
    var idle = true
    var paused = false
    var pinned = false
    var dragging = false
    var pointerNearby = false
    var reduceMotion = false
    var motionScale = 1.0
    /// The renderer supplies actual spare space inside its existing panel.
    var availablePadding = 2.0
    var permitsMotion: Bool {
        visible && idle && !paused && !pinned && !dragging && !pointerNearby && !reduceMotion
            && motionScale.isFinite && motionScale > 0 && availablePadding.isFinite && availablePadding > 0
    }
}

struct IdleMotionOffset: Equatable {
    let x: Double
    let y: Double
    static let zero = IdleMotionOffset(x: 0, y: 0)
}

/// Tiny character-only motion within the existing panel. It never produces a
/// window origin or bypasses placement analysis. Accessibility and direct user
/// controls take priority over the ordinary one-minute stillness target.
struct IdleMotionCore {
    static let quietDelay = 45.0
    static let cycleSeconds = 12.0
    static let maximumAmplitude = 1.5
    private var idleSince: Double?
    private var previousSample: Double?

    mutating func noteMovement(at now: Double) {
        idleSince = now.isFinite ? now : nil; previousSample = idleSince
    }
    mutating func sample(now: Double, context: IdleMotionContext) -> IdleMotionOffset {
        guard now.isFinite else { idleSince = nil; previousSample = nil; return .zero }
        defer { previousSample = now }
        guard context.permitsMotion else { idleSince = nil; return .zero }
        if let previousSample, now < previousSample { idleSince = now; return .zero }
        if idleSince == nil { idleSince = now }
        guard let idleSince, now - idleSince > Self.quietDelay else { return .zero }
        let elapsed = now - idleSince - Self.quietDelay
        guard elapsed.isFinite else { self.idleSince = now; return .zero }
        let phase = elapsed.truncatingRemainder(dividingBy: Self.cycleSeconds) * (2 * Double.pi / Self.cycleSeconds)
        let ramp = min(1, elapsed / 3)
        let amplitude = min(Self.maximumAmplitude, context.availablePadding) * min(1, context.motionScale) * ramp
        return IdleMotionOffset(x: amplitude * sin(phase), y: amplitude * 0.5 * (cos(phase) - 1))
    }
}
