import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class IdleMotionTests: XCTestCase {
    func testFallbackBeginsSmoothlyBeforeOneMinute() {
        var motion = IdleMotionCore(); let context = IdleMotionContext()
        XCTAssertEqual(motion.sample(now: 100, context: context), .zero)
        XCTAssertEqual(motion.sample(now: 144.999, context: context), .zero)
        XCTAssertEqual(motion.sample(now: 145, context: context), .zero)
        let onset = motion.sample(now: 145.01, context: context)
        XCTAssertGreaterThan(onset.x, 0); XCTAssertLessThan(abs(onset.x), 0.001)
        let moving = motion.sample(now: 148, context: context)
        XCTAssertEqual(moving.x, 1.5, accuracy: 0.0001)
        XCTAssertNotEqual(moving, .zero)
    }

    func testOffsetRemainsInsideAvailablePaddingWithSlowSpeed() {
        var motion = IdleMotionCore(); var context = IdleMotionContext()
        context.availablePadding = 0.8
        _ = motion.sample(now: 0, context: context)
        var previous = IdleMotionOffset.zero
        for index in 0...3_600 {
            let time = Double(index) / 20
            let next = motion.sample(now: time, context: context)
            XCTAssertLessThanOrEqual(abs(next.x), 0.8)
            XCTAssertLessThanOrEqual(abs(next.y), 0.8)
            XCTAssertLessThanOrEqual(abs(next.x - previous.x), 0.05)
            XCTAssertLessThanOrEqual(abs(next.y - previous.y), 0.05)
            previous = next
        }
    }

    func testEveryUserAccessibilityAndVisibilityGateStopsMotionAndRestartsDwell() {
        for gate in 0..<9 {
            var motion = IdleMotionCore(); let ordinary = IdleMotionContext()
            _ = motion.sample(now: 0, context: ordinary)
            XCTAssertNotEqual(motion.sample(now: 48, context: ordinary), .zero)
            var blocked = ordinary
            switch gate {
            case 0: blocked.visible = false
            case 1: blocked.idle = false
            case 2: blocked.paused = true
            case 3: blocked.pinned = true
            case 4: blocked.dragging = true
            case 5: blocked.pointerNearby = true
            case 6: blocked.reduceMotion = true
            case 7: blocked.motionScale = 0
            default: blocked.availablePadding = 0
            }
            XCTAssertEqual(motion.sample(now: 49, context: blocked), .zero)
            XCTAssertEqual(motion.sample(now: 50, context: ordinary), .zero)
            XCTAssertEqual(motion.sample(now: 94.999, context: ordinary), .zero)
            XCTAssertNotEqual(motion.sample(now: 98, context: ordinary), .zero)
        }
    }

    func testNormalMovementResetsFallbackRatherThanAddingCompetingDrift() {
        var motion = IdleMotionCore(); let context = IdleMotionContext()
        _ = motion.sample(now: 0, context: context)
        XCTAssertNotEqual(motion.sample(now: 48, context: context), .zero)
        motion.noteMovement(at: 49)
        XCTAssertEqual(motion.sample(now: 50, context: context), .zero)
        XCTAssertEqual(motion.sample(now: 94, context: context), .zero)
        XCTAssertNotEqual(motion.sample(now: 97, context: context), .zero)
    }

    func testSubtleMotionScalesAmplitudeWithoutChangingTiming() {
        var full = IdleMotionCore(), subtle = IdleMotionCore()
        let context = IdleMotionContext()
        var less = context; less.motionScale = 0.35
        _ = full.sample(now: 0, context: context); _ = subtle.sample(now: 0, context: less)
        let a = full.sample(now: 48, context: context), b = subtle.sample(now: 48, context: less)
        XCTAssertEqual(b.x, a.x * 0.35, accuracy: 0.000001)
        XCTAssertEqual(b.y, a.y * 0.35, accuracy: 0.000001)
    }

    func testInvalidOrRewindingClockAndNonfiniteGeometryNeverEscapePanel() {
        var motion = IdleMotionCore(); let context = IdleMotionContext()
        _ = motion.sample(now: 100, context: context)
        XCTAssertNotEqual(motion.sample(now: 148, context: context), .zero)
        XCTAssertEqual(motion.sample(now: 90, context: context), .zero)
        XCTAssertEqual(motion.sample(now: 91, context: context), .zero)
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(motion.sample(now: value, context: context), .zero)
            var invalid = context; invalid.availablePadding = value
            XCTAssertEqual(motion.sample(now: 200, context: invalid), .zero)
            invalid = context; invalid.motionScale = value
            XCTAssertEqual(motion.sample(now: 250, context: invalid), .zero)
        }
    }
}
