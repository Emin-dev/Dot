#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

enum PetLayout {
    static let petSize = CGSize(width: 140, height: 148)
    static let panelSize = CGSize(width: 180, height: 224)
    static let captionHeight: CGFloat = 48
    static let captionBottomPadding: CGFloat = 8
    static let stackSpacing: CGFloat = 8
    static var petBottom: CGFloat { captionHeight + captionBottomPadding + stackSpacing }
    static var petCenterY: CGFloat { petBottom + petSize.height / 2 }
}

/// Deterministic within-display wandering. Coordinates are AppKit points, not pixels.
struct RoamingCore {
    private struct Trip {
        let start: CGPoint
        let target: CGPoint
        let duration: Double
        var elapsed: Double
    }
    private var random: UInt64
    private var nextDecision: Double
    private var lastTick: Double?
    private var trip: Trip?
    private var recentCells: [Int] = []
    private var wasPaused = false
    private(set) var isTravelling = false
    init(seed: UInt64, now: Double) {
        random = seed; nextDecision = now + 8
    }
    mutating func cancel(now: Double, longRest: Bool = false) {
        trip = nil; isTravelling = false; lastTick = now
        nextDecision = now + (longRest ? 30 + unit() * 30 : 8 + unit() * 7)
    }
    private mutating func unit() -> Double {
        random &+= 0x9e3779b97f4a7c15
        var value = random
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) >> 11) / 9_007_199_254_740_992
    }
    static func originBounds(window: CGSize, visible: CGRect) -> CGRect? {
        let area = visible.insetBy(dx: 16, dy: 16)
        guard window.width > 0, window.height > 0,
              area.width >= window.width, area.height >= window.height else { return nil }
        return CGRect(x: area.minX, y: area.minY, width: area.width - window.width, height: area.height - window.height)
    }
    static func clamp(_ origin: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, bounds.minX), bounds.maxX), y: min(max(origin.y, bounds.minY), bounds.maxY))
    }
    static func distanceToSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = dx * dx + dy * dy
        if length == 0 { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
    }
    mutating func step(frame: CGRect, visible: CGRect, cursor: CGPoint, paused: Bool, now: Double) -> CGPoint {
        let dt = min(0.08, max(0, now - (lastTick ?? now))); lastTick = now
        guard let bounds = Self.originBounds(window: frame.size, visible: visible) else {
            cancel(now: now); return frame.origin
        }
        let origin = Self.clamp(frame.origin, to: bounds)
        // The visible character sits at bottom center; transparent upper padding isn't its body.
        let body = CGRect(x: origin.x + frame.width / 2 - PetLayout.petSize.width / 2, y: origin.y + PetLayout.petBottom, width: PetLayout.petSize.width, height: PetLayout.petSize.height)
        let interrupted = paused || body.insetBy(dx: -32, dy: -32).contains(cursor)
        if interrupted {
            if !wasPaused || trip != nil { cancel(now: now) }
            wasPaused = true; return origin
        }
        if wasPaused { wasPaused = false; cancel(now: now); return origin }
        if var active = trip {
            guard bounds.contains(active.target),
                  Self.distanceToSegment(cursor, CGPoint(x: origin.x + frame.width / 2, y: origin.y + PetLayout.petCenterY),
                                         CGPoint(x: active.target.x + frame.width / 2, y: active.target.y + PetLayout.petCenterY)) >= 120 else {
                cancel(now: now); return origin
            }
            active.elapsed += dt
            let t = min(1, active.elapsed / active.duration), eased = t * t * (3 - 2 * t)
            let result = Self.clamp(CGPoint(x: active.start.x + (active.target.x - active.start.x) * eased,
                                           y: active.start.y + (active.target.y - active.start.y) * eased), to: bounds)
            if t >= 1 { trip = nil; isTravelling = false; nextDecision = now + 8 + unit() * 10 }
            else { trip = active }
            return result
        }
        guard now >= nextDecision else { return origin }
        let action = unit()
        guard action < 0.7 else { nextDecision = now + (action < 0.9 ? 8 + unit() * 10 : 20 + unit() * 20); return origin }
        let minimum = min(220, 0.25 * min(visible.width, visible.height))
        for _ in 0..<24 {
            let mode = unit()
            let cell = Int(unit() * 9)
            if mode < 0.6 && recentCells.contains(cell) { continue }
            var x = unit(), y = unit()
            if mode < 0.6 { x = (Double(cell % 3) + x) / 3; y = (Double(cell / 3) + y) / 3 }
            else if mode < 0.9 {
                switch Int(unit() * 4) { case 0: x *= 0.12; case 1: x = 0.88 + x * 0.12; case 2: y *= 0.12; default: y = 0.88 + y * 0.12 }
            }
            var target = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
            let distance = hypot(target.x - origin.x, target.y - origin.y)
            guard distance >= minimum else { continue }
            if distance > 840 {
                target = CGPoint(x: origin.x + (target.x - origin.x) * 840 / distance,
                                 y: origin.y + (target.y - origin.y) * 840 / distance)
            }
            let startCenter = CGPoint(x: origin.x + frame.width / 2, y: origin.y + PetLayout.petCenterY)
            let endCenter = CGPoint(x: target.x + frame.width / 2, y: target.y + PetLayout.petCenterY)
            guard hypot(cursor.x - endCenter.x, cursor.y - endCenter.y) >= 180,
                  Self.distanceToSegment(cursor, startCenter, endCenter) >= 120 else { continue }
            let actualCell = min(2, Int((target.x - bounds.minX) / max(1, bounds.width) * 3))
                + 3 * min(2, Int((target.y - bounds.minY) / max(1, bounds.height) * 3))
            recentCells.append(actualCell); if recentCells.count > 3 { recentCells.removeFirst() }
            trip = Trip(start: origin, target: target, duration: min(7, max(2.5, hypot(target.x - origin.x, target.y - origin.y) / 120)), elapsed: 0)
            isTravelling = true; return origin
        }
        nextDecision = now + 8 + unit() * 10
        return origin
    }
}
