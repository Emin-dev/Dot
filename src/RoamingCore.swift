#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

enum PetStatusLayout { static let controlHeight: CGFloat = 0 }

enum PetLayout {
    static let petSize = CGSize(width: 140, height: 148)
    static let edgePadding: CGFloat = 4
    static let panelSize = CGSize(width: petSize.width + edgePadding * 2, height: petSize.height + edgePadding * 2 + PetStatusLayout.controlHeight)
    static var petBottom: CGFloat { edgePadding + PetStatusLayout.controlHeight }
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
    static let lifetime = 10.0
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
    /// Protected-window order is irrelevant; retain duplicate coverage and reject every real geometry change.
    static func sameGeometry(_ lhs: [CGRect], _ rhs: [CGRect]) -> Bool {
        lhs.count == rhs.count && preservesGeometry(lhs, in: rhs)
    }
    /// A capture may add occupied regions, but may never lose or alter a previously observed region.
    static func preservesGeometry(_ prior: [CGRect], in current: [CGRect]) -> Bool {
        guard prior.count <= current.count, current.count <= maximumRegions,
              prior.allSatisfy(validRect), current.allSatisfy(validRect) else { return false }
        func ordered(_ a: CGRect, _ b: CGRect) -> Bool {
            if a.minX != b.minX { return a.minX < b.minX }
            if a.minY != b.minY { return a.minY < b.minY }
            if a.width != b.width { return a.width < b.width }
            return a.height < b.height
        }
        let old = prior.sorted(by: ordered)
        var matched = 0
        for rect in current.sorted(by: ordered) where matched < old.count {
            if rect == old[matched] { matched += 1 }
        }
        return matched == old.count
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
    /// The only autonomous movement cadence the owner allows is two minutes. A
    /// covered map used to trigger a relocation on every movement tick, and the
    /// least-overlap fallback always found a target, so Dot moved nonstop.
    static let minimumAutonomousMoveInterval = 115.0
    static func autonomousMoveAllowed(now: Double, lastMoveAt: Double) -> Bool {
        now.isFinite && lastMoveAt.isFinite && now - lastMoveAt >= minimumAutonomousMoveInterval
    }
    private struct Trip {
        let start: CGPoint
        let target: CGPoint
        let snapshot: PlacementSnapshot?
        var elapsed = 0.0
        let isEscape: Bool
    }
    private var minimumRestUntil = 0.0
    private var lastTick: Double?
    private var trip: Trip?
    private(set) var isTravelling = false
    private var lastKnownProtected: [CGRect] = []
    /// Overlap escape has its own short retry so content is cleared quickly without
    /// re-running a failed empty-space search on every tick.
    private var escapeRetryAt = 0.0
    /// A manual drag or completed roam rests autonomous motion; the direct coverage
    /// escape in the app must respect it too, not only the internal step path.
    func isResting(now: Double) -> Bool { now.isFinite && now < minimumRestUntil }

    mutating func cancel(now: Double, longRest: Bool = false) {
        trip = nil; isTravelling = false; lastTick = now
        if longRest {
            minimumRestUntil = now + 45
        }
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
    /// Finds a candidate position in `bounds` that does not intersect any protected region
    /// (windows, text boxes, buttons) and maintains distance from the cursor.
    static func findEmptySpace(frame: CGRect, bounds: CGRect, cursor: CGPoint,
                                regions: [CGRect], preferredNear: CGPoint? = nil,
                                minDistance: CGFloat = 0) -> CGPoint? {
        var candidates: [CGPoint] = []
        let origin = frame.origin
        let overlapping = regions.filter { frame.intersects($0) }

        // 1. Gutter positions directly adjacent to overlapping obstacles
        for obs in overlapping {
            candidates.append(CGPoint(x: obs.minX - frame.width - 24, y: origin.y))
            candidates.append(CGPoint(x: obs.maxX + 24, y: origin.y))
            candidates.append(CGPoint(x: origin.x, y: obs.minY - frame.height - 24))
            candidates.append(CGPoint(x: origin.x, y: obs.maxY + 24))

            candidates.append(CGPoint(x: obs.minX - frame.width - 40, y: obs.minY - frame.height - 40))
            candidates.append(CGPoint(x: obs.maxX + 40, y: obs.maxY + 40))
            candidates.append(CGPoint(x: obs.maxX + 40, y: obs.minY - frame.height - 40))
            candidates.append(CGPoint(x: obs.minX - frame.width - 40, y: obs.maxY + 40))
        }

        // 2. Screen corner and margin pockets (typically clear desktop/gutters)
        let margin: CGFloat = 24
        candidates.append(CGPoint(x: bounds.maxX - margin, y: bounds.maxY - margin)) // Top-right
        candidates.append(CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin)) // Top-left
        candidates.append(CGPoint(x: bounds.maxX - margin, y: bounds.minY + margin)) // Bottom-right
        candidates.append(CGPoint(x: bounds.minX + margin, y: bounds.minY + margin)) // Bottom-left
        candidates.append(CGPoint(x: bounds.maxX - margin, y: bounds.midY))           // Mid-right edge
        candidates.append(CGPoint(x: bounds.minX + margin, y: bounds.midY))           // Mid-left edge

        // 3. Grid sampling across visible bounds
        let stepX: CGFloat = max(60, bounds.width / 16)
        let stepY: CGFloat = max(60, bounds.height / 12)
        for y in stride(from: bounds.minY + margin, through: bounds.maxY - margin, by: stepY) {
            for x in stride(from: bounds.minX + margin, through: bounds.maxX - margin, by: stepX) {
                candidates.append(CGPoint(x: x, y: y))
            }
        }

        let reference = preferredNear ?? origin
        var bestPoint: CGPoint? = nil
        var bestScore = Double.infinity

        for candidate in candidates {
            let clamped = clamp(candidate, to: bounds)
            let distToOrigin = hypot(clamped.x - origin.x, clamped.y - origin.y)
            guard distToOrigin >= minDistance else { continue }
            let testRect = CGRect(origin: clamped, size: frame.size).insetBy(dx: -12, dy: -12)
            guard clear(testRect, regions: regions) else { continue }
            let center = CGPoint(x: clamped.x + frame.width / 2, y: clamped.y + frame.height / 2)
            guard hypot(cursor.x - center.x, cursor.y - center.y) >= 70 else { continue }

            let dist = hypot(clamped.x - reference.x, clamped.y - reference.y)
            if dist < bestScore {
                bestScore = dist
                bestPoint = clamped
            }
        }
        if bestPoint == nil {
            for candidate in candidates {
                let clamped = clamp(candidate, to: bounds)
                let distToOrigin = hypot(clamped.x - origin.x, clamped.y - origin.y)
                guard distToOrigin >= minDistance else { continue }
                let testRect = CGRect(origin: clamped, size: frame.size).insetBy(dx: -6, dy: -6)
                guard clear(testRect, regions: regions) else { continue }
                let center = CGPoint(x: clamped.x + frame.width / 2, y: clamped.y + frame.height / 2)
                guard hypot(cursor.x - center.x, cursor.y - center.y) >= 30 else { continue }
                let dist = hypot(clamped.x - reference.x, clamped.y - reference.y)
                if dist < bestScore {
                    bestScore = dist
                    bestPoint = clamped
                }
            }
        }
        return bestPoint
    }
    /// Finds a random safe candidate position in `bounds` that does not intersect any protected region
    /// (windows, text boxes, buttons) and maintains distance from the cursor and current position.
    static func findRandomEmptySpace(frame: CGRect, bounds: CGRect, cursor: CGPoint,
                                     regions: [CGRect], minDistance: CGFloat = 140) -> CGPoint? {
        let margin: CGFloat = 24

        // 1. Screen corner and perimeter gutter pockets (strongly preferred)
        let perimeterCandidates: [CGPoint] = [
            CGPoint(x: bounds.maxX - margin, y: bounds.maxY - margin), // Top right
            CGPoint(x: bounds.minX + margin, y: bounds.maxY - margin), // Top left
            CGPoint(x: bounds.maxX - margin, y: bounds.minY + margin), // Bottom right
            CGPoint(x: bounds.minX + margin, y: bounds.minY + margin), // Bottom left
            CGPoint(x: bounds.maxX - margin, y: bounds.midY),           // Right edge
            CGPoint(x: bounds.minX + margin, y: bounds.midY),           // Left edge
            CGPoint(x: bounds.midX, y: bounds.maxY - margin),           // Top center
            CGPoint(x: bounds.midX, y: bounds.minY + margin),           // Bottom center
            CGPoint(x: bounds.maxX - margin - 48, y: bounds.minY + margin),
            CGPoint(x: bounds.maxX - margin, y: bounds.minY + margin + 48),
            CGPoint(x: bounds.maxX - margin - 48, y: bounds.maxY - margin),
            CGPoint(x: bounds.minX + margin + 48, y: bounds.maxY - margin)
        ]

        // 2. Interior grid sampling across visible bounds
        var interiorCandidates: [CGPoint] = []
        let stepX: CGFloat = max(80, bounds.width / 12)
        let stepY: CGFloat = max(80, bounds.height / 10)
        for y in stride(from: bounds.minY + margin + 40, through: bounds.maxY - margin - 40, by: stepY) {
            for x in stride(from: bounds.minX + margin + 40, through: bounds.maxX - margin - 40, by: stepX) {
                interiorCandidates.append(CGPoint(x: x, y: y))
            }
        }

        let origin = frame.origin

        // Priority 1: Safe perimeter/gutter positions that are completely clear of windows, buttons, and text
        var safePerimeter: [CGPoint] = []
        for candidate in perimeterCandidates {
            let clamped = clamp(candidate, to: bounds)
            let distToOrigin = hypot(clamped.x - origin.x, clamped.y - origin.y)
            guard distToOrigin >= minDistance else { continue }
            let testRect = CGRect(origin: clamped, size: frame.size).insetBy(dx: -10, dy: -10)
            guard clear(testRect, regions: regions) else { continue }
            let center = CGPoint(x: clamped.x + frame.width / 2, y: clamped.y + frame.height / 2)
            guard hypot(cursor.x - center.x, cursor.y - center.y) >= 60 else { continue }
            safePerimeter.append(clamped)
        }
        if let chosen = safePerimeter.randomElement() {
            return chosen
        }

        // Priority 2: Interior candidates that are completely clear of all regions
        var safeInterior: [CGPoint] = []
        for candidate in interiorCandidates {
            let clamped = clamp(candidate, to: bounds)
            let distToOrigin = hypot(clamped.x - origin.x, clamped.y - origin.y)
            guard distToOrigin >= minDistance else { continue }
            let testRect = CGRect(origin: clamped, size: frame.size).insetBy(dx: -10, dy: -10)
            guard clear(testRect, regions: regions) else { continue }
            let center = CGPoint(x: clamped.x + frame.width / 2, y: clamped.y + frame.height / 2)
            guard hypot(cursor.x - center.x, cursor.y - center.y) >= 60 else { continue }
            safeInterior.append(clamped)
        }
        if let chosen = safeInterior.randomElement() {
            return chosen
        }

        // Pass 2: Relaxed margin for perimeter candidates first (minDistance / 2)
        var fallbackPerimeter: [CGPoint] = []
        for candidate in perimeterCandidates {
            let clamped = clamp(candidate, to: bounds)
            let distToOrigin = hypot(clamped.x - origin.x, clamped.y - origin.y)
            guard distToOrigin >= min(80, minDistance / 2) else { continue }
            let testRect = CGRect(origin: clamped, size: frame.size).insetBy(dx: -4, dy: -4)
            guard clear(testRect, regions: regions) else { continue }
            let center = CGPoint(x: clamped.x + frame.width / 2, y: clamped.y + frame.height / 2)
            guard hypot(cursor.x - center.x, cursor.y - center.y) >= 30 else { continue }
            fallbackPerimeter.append(clamped)
        }
        if let chosen = fallbackPerimeter.randomElement() {
            return chosen
        }

        // No clear pocket exists: stay rather than covering content.
        return nil
    }
    mutating func evadeToEmptySpace(frame: CGRect, visible: CGRect, cursor: CGPoint,
                                    now: Double, displayID: UInt32, snapshot: PlacementSnapshot) -> CGPoint {
        guard PlacementSnapshot.validRect(frame), cursor.x.isFinite, cursor.y.isFinite,
              let bounds = Self.originBounds(window: frame.size, visible: visible) else {
            return frame.origin
        }
        guard let target = Self.findRandomEmptySpace(frame: frame, bounds: bounds, cursor: cursor,
                                                     regions: snapshot.protected, minDistance: 120)
                ?? Self.findEmptySpace(frame: frame, bounds: bounds, cursor: cursor,
                                       regions: snapshot.protected, preferredNear: frame.origin) else {
            return frame.origin
        }
        guard Self.safePath(from: frame, to: target, regions: snapshot.protected) else { return frame.origin }
        let origin = frame.origin
        trip = Trip(start: origin, target: target, snapshot: snapshot, isEscape: true)
        isTravelling = true
        return origin
    }
    /// The swept bounds must not cross content the pet does not already overlap. Axis
    /// moves are exact; a diagonal uses the conservative union of start and end.
    static func safePath(from frame: CGRect, to target: CGPoint, regions: [CGRect]) -> Bool {
        let dx = target.x - frame.minX, dy = target.y - frame.minY
        guard dx != 0 || dy != 0 else { return true }
        let end = CGRect(origin: target, size: frame.size)
        guard clear(end, regions: regions) else { return false }
        let swept = frame.union(end)
        for rect in regions where swept.intersects(rect) {
            // Content the pet already overlaps is allowed only while escaping; content
            // newly crossed by the swept path is never allowed.
            guard frame.intersects(rect) else { return false }
            if dx != 0 && dy != 0 { continue }
            if dx > 0 && frame.minX < rect.minX && frame.maxX < rect.maxX { return false }
            if dx < 0 && frame.maxX > rect.maxX && frame.minX > rect.minX { return false }
            if dy > 0 && frame.minY < rect.minY && frame.maxY < rect.maxY { return false }
            if dy < 0 && frame.maxY > rect.maxY && frame.minY > rect.minY { return false }
        }
        return true
    }
    mutating func step(frame: CGRect, visible: CGRect, cursor: CGPoint, paused: Bool, now: Double,
                       displayID: UInt32 = 0, snapshot: PlacementSnapshot? = nil) -> CGPoint {
        if let last = lastTick, now - last > 15.0 {
            cancel(now: now)
        }
        let dt = min(0.08, max(0, now - (lastTick ?? now))); lastTick = now
        guard !paused, PlacementSnapshot.validRect(frame), cursor.x.isFinite, cursor.y.isFinite,
              let bounds = Self.originBounds(window: frame.size, visible: visible),
              visible.intersects(frame),
              !frame.insetBy(dx: -32, dy: -32).contains(cursor) else {
            if trip != nil { cancel(now: now) }
            return frame.origin // Permission/pause/staleness never causes an unsensed clamp.
        }
        let clampedOrigin = Self.clamp(frame.origin, to: bounds)
        guard hypot(clampedOrigin.x - frame.origin.x, clampedOrigin.y - frame.origin.y) <= 48.0 else {
            if trip != nil { cancel(now: now) }
            return frame.origin
        }
        let validSnapshot: PlacementSnapshot? = {
            guard let snapshot, snapshot.valid(displayID: displayID, visible: visible, now: now) else { return nil }
            return snapshot
        }()
        if let snap = validSnapshot {
            lastKnownProtected = snap.protected
        }
        let origin = frame.origin
        if var active = trip {
            guard let snap = validSnapshot else {
                cancel(now: now); return origin
            }
            guard Self.safePath(from: frame, to: active.target, regions: snap.protected) else {
                cancel(now: now); return origin
            }
            guard Self.distanceToSegment(cursor, CGPoint(x: frame.midX, y: frame.midY),
                    CGPoint(x: active.target.x + frame.width / 2, y: active.target.y + frame.height / 2)) >= 50 else {
                cancel(now: now); return origin
            }
            active.elapsed += dt
            let travelDist = hypot(active.target.x - active.start.x, active.target.y - active.start.y)
            let travelDuration = active.isEscape ? 0.6 : max(2.5, min(3.8, travelDist / 50.0))
            let t = min(1, active.elapsed / travelDuration), eased = t * t * (3 - 2 * t)
            let result = CGPoint(x: active.start.x + (active.target.x - active.start.x) * eased,
                                 y: active.start.y + (active.target.y - active.start.y) * eased)
            if t >= 1 {
                cancel(now: now)
            } else {
                trip = active
            }
            return result
        }

        // 1. Collision Escape (if overlapping a protected window, text, or button)
        let checkRegions = validSnapshot?.protected ?? lastKnownProtected
        if now >= escapeRetryAt, now >= minimumRestUntil,
           !checkRegions.isEmpty && !Self.clear(frame, regions: checkRegions) {
            let overlapping = checkRegions.filter { frame.intersects($0) }
            if !overlapping.isEmpty {
                var immediateCandidates = [
                    CGPoint(x: overlapping.map { $0.minX - frame.width - 1 }.min()!, y: origin.y),
                    CGPoint(x: overlapping.map { $0.maxX + 1 }.max()!, y: origin.y),
                    CGPoint(x: origin.x, y: overlapping.map { $0.minY - frame.height - 1 }.min()!),
                    CGPoint(x: origin.x, y: overlapping.map { $0.maxY + 1 }.max()!)
                ]
                immediateCandidates.sort { hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y) }
                var chosenTarget: CGPoint? = nil
                for target in immediateCandidates {
                    let distance = hypot(target.x - origin.x, target.y - origin.y)
                    guard distance > 0, distance <= 96, Self.clamp(target, to: bounds) == target,
                          Self.safePath(from: frame, to: target, regions: checkRegions) else { continue }
                    let endCenter = CGPoint(x: target.x + frame.width / 2, y: target.y + frame.height / 2)
                    guard hypot(cursor.x - endCenter.x, cursor.y - endCenter.y) >= 70,
                          Self.distanceToSegment(cursor, CGPoint(x: frame.midX, y: frame.midY), endCenter) >= 50 else { continue }
                    chosenTarget = target
                    break
                }
                if chosenTarget == nil {
                    chosenTarget = Self.findEmptySpace(frame: frame, bounds: bounds, cursor: cursor,
                                                       regions: checkRegions, preferredNear: origin)
                }
                if let target = chosenTarget,
                   Self.safePath(from: frame, to: target, regions: checkRegions) {
                    trip = Trip(start: origin, target: target, snapshot: validSnapshot, isEscape: true)
                    isTravelling = true
                    return origin
                }
                escapeRetryAt = now + 1.5
                return origin
            }
        }
        return origin
    }
}

/// Cancellation invalidates results without admitting a second overlapping capture.
struct PlacementScanGate {
    private(set) var snapshot: PlacementSnapshot?
    private(set) var active: UUID?
    private var generation = UUID()
    private var nextAllowed = 0.0
    mutating func begin(now: Double, eligible: Bool, immediate: Bool = false) -> UUID? {
        guard eligible, now.isFinite, active == nil, (immediate || now >= nextAllowed) else { return nil }
        generation = UUID(); active = generation
        if immediate {
            nextAllowed = now + 4.0
        } else {
            nextAllowed = now + 10
        }
        return generation
    }
    mutating func invalidate() { generation = UUID(); snapshot = nil }
    mutating func finish(token: UUID, result: PlacementSnapshot?) {
        guard active == token else { return }
        active = nil
        if generation == token { snapshot = result }
    }
}

/// Public placement diagnostics accept only fixed categories and bounded numeric measurements.
struct PlacementDiagnostic: Equatable {
    enum Stage: String { case windows, shareable, capture, analysis, validation }
    enum Outcome: String { case ready, rejected, cancelled, failed }
    enum Reason: String {
        case permission, inputChanged = "input_changed", displayMissing = "display_missing"
        case windowsChanged = "windows_changed", expired, invalidMap = "invalid_map"
        case windowMetadata = "window_metadata", imageBounds = "image_bounds", textAnalysis = "text_analysis"
        case pixelAnalysis = "pixel_analysis", cancelled, framework
    }
    let stage: Stage
    let outcome: Outcome
    let reason: Reason?
    let elapsedMilliseconds: Int
    let captureMilliseconds: Int
    let analysisMilliseconds: Int
    let regions: Int
    let errorCode: Int?
    let imageWidth: Int
    let imageHeight: Int
    let observedAlpha: Int?
    let unknownTiles: Int
    let addedWindows: Int
    init(stage: Stage, outcome: Outcome, reason: Reason? = nil, elapsed: Double = 0,
         capture: Double = 0, analysis: Double = 0, regions: Int = 0, errorCode: Int? = nil, imageWidth: Int = 0, imageHeight: Int = 0, observedAlpha: Int? = nil, unknownTiles: Int = 0, addedWindows: Int = 0) {
        self.stage = stage; self.outcome = outcome; self.reason = reason
        self.elapsedMilliseconds = Self.milliseconds(elapsed)
        self.captureMilliseconds = Self.milliseconds(capture)
        self.analysisMilliseconds = Self.milliseconds(analysis)
        self.regions = min(PlacementSnapshot.maximumRegions, max(0, regions))
        self.imageWidth = min(65536, max(0, imageWidth)); self.imageHeight = min(65536, max(0, imageHeight))
        self.addedWindows = min(512, max(0, addedWindows))
        self.unknownTiles = min(PlacementSnapshot.maximumRegions, max(0, unknownTiles))
        self.observedAlpha = observedAlpha.flatMap { (0...255).contains($0) ? $0 : nil }
        self.errorCode = errorCode.flatMap { (-1_000_000...1_000_000).contains($0) ? $0 : nil }
    }
    private static func milliseconds(_ value: Double) -> Int {
        value.isFinite ? Int(min(60, max(0, value)) * 1000) : 0
    }
    var logLine: String {
        "DOT_PLACEMENT stage=\(stage.rawValue) outcome=\(outcome.rawValue) reason=\(reason?.rawValue ?? "none") elapsed=\(elapsedMilliseconds)ms capture=\(captureMilliseconds)ms analysis=\(analysisMilliseconds)ms regions=\(regions) code=\(errorCode.map(String.init) ?? "none") image=\(imageWidth)x\(imageHeight) alpha=\(observedAlpha.map(String.init) ?? "none") unknown_tiles=\(unknownTiles) added_windows=\(addedWindows)"
    }
}
