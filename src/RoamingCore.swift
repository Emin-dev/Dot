#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

enum PetLayout {
    static let petSize = CGSize(width: 140, height: 148)
    static let edgePadding: CGFloat = 4
    static let panelSize = CGSize(width: petSize.width + edgePadding * 2, height: petSize.height + edgePadding * 2)
    static var petBottom: CGFloat { edgePadding }
    static var petCenterY: CGFloat { petBottom + petSize.height / 2 }
}

/// A pointer gesture can become a click or a drag, never both.
struct CompanionDragState {
    static let threshold: CGFloat = 6
    private var start: CGPoint?
    private var origin = CGPoint.zero
    private(set) var dragging = false
    var isPressed: Bool { start != nil }
    mutating func begin(point: CGPoint, origin: CGPoint) {
        cancel(); start = point; self.origin = origin
    }
    mutating func update(point: CGPoint) -> CGPoint? {
        guard let start else { return nil }
        let dx = point.x - start.x, dy = point.y - start.y
        if hypot(dx, dy) >= Self.threshold { dragging = true }
        return dragging ? CGPoint(x: origin.x + dx, y: origin.y + dy) : nil
    }
    mutating func release(point: CGPoint, inside: Bool) -> Bool {
        guard start != nil else { return false }
        _ = update(point: point)
        let click = !dragging && inside
        cancel(); return click
    }
    mutating func cancel() { start = nil; dragging = false }
}

/// A bounded, ephemeral map in AppKit points. No pixels or recognized text are retained.
struct PlacementSnapshot: Equatable {
    static let lifetime = 1.5
    static let maximumRegions = 8192
    let displayID: UInt32
    let displayFrame: CGRect
    let visibleFrame: CGRect
    let capturedAt: Double
    let protected: [CGRect]
    func valid(displayID: UInt32, visible: CGRect, now: Double) -> Bool {
        self.displayID == displayID && visibleFrame == visible && now.isFinite && capturedAt.isFinite
            && now >= capturedAt && now - capturedAt <= Self.lifetime
            && Self.validRect(displayFrame) && Self.validRect(visible) && displayFrame.contains(visible)
            && protected.count <= Self.maximumRegions && protected.allSatisfy(Self.validRect)
    }
    static func validRect(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy { $0.isFinite }
            && rect.width > 0 && rect.height > 0 && !rect.isInfinite && !rect.isNull
    }
    static func visionRect(_ box: CGRect, display: CGRect) -> CGRect? {
        guard validRect(box), validRect(display), CGRect(x: 0, y: 0, width: 1, height: 1).contains(box) else { return nil }
        return CGRect(x: display.minX + box.minX * display.width, y: display.minY + box.minY * display.height,
                      width: box.width * display.width, height: box.height * display.height)
    }
    static func quartzRect(_ box: CGRect, primaryTop: CGFloat) -> CGRect? {
        guard validRect(box), primaryTop.isFinite else { return nil }
        return CGRect(x: box.minX, y: primaryTop - box.maxY, width: box.width, height: box.height)
    }
    static func rasterRect(_ box: CGRect, width: Int, height: Int, display: CGRect) -> CGRect? {
        guard width > 0, height > 0, validRect(display), validRect(box),
              CGRect(x: 0, y: 0, width: width, height: height).contains(box) else { return nil }
        return CGRect(x: display.minX + box.minX / CGFloat(width) * display.width,
                      y: display.maxY - box.maxY / CGFloat(height) * display.height,
                      width: box.width / CGFloat(width) * display.width, height: box.height / CGFloat(height) * display.height)
    }
}

/// Conservative short relocations; no random or unsensed fallback. Manual dragging is separate.
struct RoamingCore {
    private struct Trip {
        let start: CGPoint
        let target: CGPoint
        let snapshot: PlacementSnapshot
        var elapsed = 0.0
    }
    private var nextDecision: Double
    private var minimumRestUntil = 0.0
    private var lastTick: Double?
    private var trip: Trip?
    private(set) var isTravelling = false
    init(seed: UInt64, now: Double) { nextDecision = now + 8 }
    mutating func cancel(now: Double, longRest: Bool = false) {
        trip = nil; isTravelling = false; lastTick = now
        if longRest { minimumRestUntil = now + 45 }
        nextDecision = max(minimumRestUntil, now + 8)
    }
    static func originBounds(window: CGSize, visible: CGRect) -> CGRect? {
        guard PlacementSnapshot.validRect(visible), window.width.isFinite, window.height.isFinite else { return nil }
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
    static func clear(_ frame: CGRect, regions: [CGRect]) -> Bool {
        !regions.contains { frame.intersects($0) }
    }
    /// Axis-only motion permits escape from existing overlap without increasing it or crossing new content.
    static func safePath(from frame: CGRect, to target: CGPoint, regions: [CGRect]) -> Bool {
        let dx = target.x - frame.minX, dy = target.y - frame.minY
        guard (dx == 0) != (dy == 0) else { return false }
        let end = CGRect(origin: target, size: frame.size)
        guard clear(end, regions: regions) else { return false }
        let swept = frame.union(end)
        for rect in regions where swept.intersects(rect) {
            guard frame.intersects(rect) else { return false }
            if dx > 0 && frame.minX < rect.minX && frame.maxX < rect.maxX { return false }
            if dx < 0 && frame.maxX > rect.maxX && frame.minX > rect.minX { return false }
            if dy > 0 && frame.minY < rect.minY && frame.maxY < rect.maxY { return false }
            if dy < 0 && frame.maxY > rect.maxY && frame.minY > rect.minY { return false }
        }
        return true
    }
    mutating func step(frame: CGRect, visible: CGRect, cursor: CGPoint, paused: Bool, now: Double,
                       displayID: UInt32 = 0, snapshot: PlacementSnapshot? = nil) -> CGPoint {
        let dt = min(0.08, max(0, now - (lastTick ?? now))); lastTick = now
        guard !paused, PlacementSnapshot.validRect(frame), cursor.x.isFinite, cursor.y.isFinite,
              let snapshot, snapshot.valid(displayID: displayID, visible: visible, now: now),
              let bounds = Self.originBounds(window: frame.size, visible: visible),
              Self.clamp(frame.origin, to: bounds) == frame.origin,
              !frame.insetBy(dx: -32, dy: -32).contains(cursor) else {
            if trip != nil { cancel(now: now) }
            return frame.origin // Permission/pause/staleness never causes an unsensed clamp.
        }
        let origin = frame.origin
        if var active = trip {
            guard active.snapshot == snapshot,
                  Self.safePath(from: frame, to: active.target, regions: snapshot.protected),
                  Self.distanceToSegment(cursor, CGPoint(x: frame.midX, y: frame.midY),
                    CGPoint(x: active.target.x + frame.width / 2, y: active.target.y + frame.height / 2)) >= 120 else {
                cancel(now: now); return origin
            }
            active.elapsed += dt
            let t = min(1, active.elapsed / 0.6), eased = t * t * (3 - 2 * t)
            let result = CGPoint(x: active.start.x + (active.target.x - active.start.x) * eased,
                                 y: active.start.y + (active.target.y - active.start.y) * eased)
            if t >= 1 { cancel(now: now) } else { trip = active }
            return result
        }
        guard now >= nextDecision, now - snapshot.capturedAt <= PlacementSnapshot.lifetime - 0.7,
              !Self.clear(frame, regions: snapshot.protected) else { return origin }
        let overlapping = snapshot.protected.filter { frame.intersects($0) }
        guard !overlapping.isEmpty else { return origin }
        var candidates = [
            CGPoint(x: overlapping.map { $0.minX - frame.width - 1 }.min()!, y: origin.y),
            CGPoint(x: overlapping.map { $0.maxX + 1 }.max()!, y: origin.y),
            CGPoint(x: origin.x, y: overlapping.map { $0.minY - frame.height - 1 }.min()!),
            CGPoint(x: origin.x, y: overlapping.map { $0.maxY + 1 }.max()!)
        ]
        candidates.sort { hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y) }
        for target in candidates {
            let distance = hypot(target.x - origin.x, target.y - origin.y)
            guard distance > 0, distance <= 96, Self.clamp(target, to: bounds) == target,
                  Self.safePath(from: frame, to: target, regions: snapshot.protected) else { continue }
            let endCenter = CGPoint(x: target.x + frame.width / 2, y: target.y + frame.height / 2)
            guard hypot(cursor.x - endCenter.x, cursor.y - endCenter.y) >= 180,
                  Self.distanceToSegment(cursor, CGPoint(x: frame.midX, y: frame.midY), endCenter) >= 120 else { continue }
            trip = Trip(start: origin, target: target, snapshot: snapshot); isTravelling = true; return origin
        }
        nextDecision = now + 10
        return origin
    }
}

/// Cancellation invalidates results without admitting a second overlapping capture.
struct PlacementScanGate {
    private(set) var snapshot: PlacementSnapshot?
    private(set) var active: UUID?
    private var generation = UUID()
    private var nextAllowed = 0.0
    mutating func begin(now: Double, eligible: Bool) -> UUID? {
        guard eligible, now.isFinite, active == nil, now >= nextAllowed else { return nil }
        generation = UUID(); active = generation; nextAllowed = now + 10; snapshot = nil
        return generation
    }
    mutating func invalidate() { generation = UUID(); snapshot = nil }
    mutating func finish(token: UUID, result: PlacementSnapshot?) {
        guard active == token else { return }
        active = nil
        if generation == token { snapshot = result }
    }
}
