import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DotCore
#endif

final class ProactiveBehaviorTests: XCTestCase {
    private var ready: ProactiveContext { .init(ready: true, visible: true) }

    func testEveryPresetWaitsItsExactMonotonicInterval() throws {
        XCTAssertEqual(ProactiveFrequency.high.interval, 60)
        XCTAssertEqual(ProactiveFrequency.normal.interval, 240)
        XCTAssertEqual(ProactiveFrequency.low.interval, 600)
        for frequency in ProactiveFrequency.allCases {
            var schedule = ProactiveSchedule(frequency: frequency, now: 100)
            schedule.update(ready, now: 100)
            XCTAssertTrue(schedule.offer(key: "context-v1", reason: .relevantContextChanged))
            XCTAssertNil(schedule.take(now: 100 + frequency.interval - 0.001))
            let opportunity = try XCTUnwrap(schedule.take(now: 100 + frequency.interval))
            XCTAssertEqual(opportunity.contextKey, "context-v1")
            XCTAssertEqual(opportunity.createdAt, 100 + frequency.interval)
            XCTAssertEqual(schedule.nextEligibleAt, 100 + frequency.interval * 2)
        }
    }

    func testNoRelevantContextDoesNoWorkEvenWhenManyIntervalsElapsed() {
        var schedule = ProactiveSchedule(now: 0)
        schedule.update(ready, now: 0)
        for time in [60.0, 600, 6_000, 60_000] {
            XCTAssertNil(schedule.take(now: time))
            XCTAssertNil(schedule.nextWake(now: time))
        }
    }

    func testLatestContextReplacesPendingAndConsumedContextDoesNotRepeat() throws {
        // This case exercises the 60-second cadence; the shipped default is covered separately.
        var schedule = ProactiveSchedule(frequency: .high, now: 0)
        schedule.update(ready, now: 0)
        XCTAssertTrue(schedule.offer(key: "old", reason: .workspaceChanged))
        XCTAssertTrue(schedule.offer(key: "fresh", reason: .relevantContextChanged))
        XCTAssertFalse(schedule.offer(key: "fresh", reason: .workspaceChanged))
        let first = try XCTUnwrap(schedule.take(now: 60))
        XCTAssertEqual(first.contextKey, "fresh")
        XCTAssertFalse(schedule.offer(key: "fresh", reason: .relevantContextChanged))
        schedule.complete(id: first.id)
        XCTAssertFalse(schedule.offer(key: "fresh", reason: .foregroundApplicationChanged))
        XCTAssertNil(schedule.take(now: 600))
        XCTAssertTrue(schedule.offer(key: "fresh-revision-2", reason: .relevantContextChanged))
        XCTAssertNotNil(schedule.take(now: 600))
        XCTAssertNil(schedule.take(now: 6_000), "No burst of overdue work while an opportunity is active")
    }

    func testInvalidOpaqueKeysNeverBecomeOpportunities() {
        var schedule = ProactiveSchedule(now: 0)
        schedule.update(ready, now: 0)
        for key in ["", "line\nbreak", "\u{007f}", String(repeating: "x", count: 257)] {
            XCTAssertFalse(schedule.offer(key: key, reason: .relevantContextChanged))
        }
        XCTAssertNil(schedule.take(now: 60))
        XCTAssertTrue(schedule.offer(key: "folder-change:revision-2", reason: .relevantContextChanged))
    }

    func testEveryForegroundOrQuietGateCancelsActiveWorkAndDropsStalePending() throws {
        for condition in 0..<6 {
            var schedule = ProactiveSchedule(frequency: .high, now: 0)
            schedule.update(ready, now: 0)
            schedule.offer(key: "active", reason: .relevantContextChanged)
            let opportunity = try XCTUnwrap(schedule.take(now: 60))
            schedule.offer(key: "queued", reason: .relevantContextChanged)
            var blocked = ready
            switch condition {
            case 0: blocked.ready = false
            case 1: blocked.visible = false
            case 2: blocked.foregroundBusy = true
            case 3: blocked.interactionBusy = true
            case 4: blocked.quiet = true
            default: blocked.callActive = true
            }
            XCTAssertEqual(schedule.update(blocked, now: 65), opportunity.id)
            XCTAssertNil(schedule.update(blocked, now: 66), "Cancellation is single-use")
            XCTAssertNil(schedule.active)
            schedule.update(ready, now: 67)
            XCTAssertNil(schedule.take(now: 125), "Resume does not revive a stale queued suggestion")
            schedule.offer(key: "new-evidence", reason: .relevantContextChanged)
            XCTAssertNil(schedule.take(now: 125.999))
            XCTAssertNotNil(schedule.take(now: 126))
        }
    }

    func testEngineBusyPreventsNewWorkButDoesNotCancelOwnInFlightWork() throws {
        var schedule = ProactiveSchedule(frequency: .high, now: 0)
        var busy = ready; busy.engineBusy = true
        schedule.update(busy, now: 0)
        schedule.offer(key: "context", reason: .relevantContextChanged)
        XCTAssertNil(schedule.take(now: 60)); XCTAssertNil(schedule.nextWake(now: 60))
        schedule.update(ready, now: 60)
        let opportunity = try XCTUnwrap(schedule.take(now: 60))
        XCTAssertNil(schedule.update(busy, now: 61))
        XCTAssertEqual(schedule.active, opportunity)
        schedule.complete(id: UUID())
        XCTAssertEqual(schedule.active, opportunity, "A stale completion cannot release the current job")
        schedule.complete(id: opportunity.id)
        XCTAssertNil(schedule.active)
    }

    func testPauseAndFrequencyChangeStartFreshCadenceWithoutCatchUp() throws {
        var schedule = ProactiveSchedule(frequency: .high, now: 0)
        schedule.update(ready, now: 0)
        schedule.offer(key: "first", reason: .relevantContextChanged)
        let opportunity = try XCTUnwrap(schedule.take(now: 60))
        XCTAssertEqual(schedule.setPaused(true, now: 61), opportunity.id)
        XCTAssertFalse(schedule.offer(key: "while-paused", reason: .workspaceChanged))
        schedule.setPaused(false, now: 10_000)
        schedule.offer(key: "fresh", reason: .workspaceChanged)
        XCTAssertNil(schedule.take(now: 10_059.999))
        XCTAssertNotNil(schedule.take(now: 10_060))
        schedule.cancelActive()
        schedule.setFrequency(.low, now: 10_061)
        schedule.offer(key: "new", reason: .relevantContextChanged)
        XCTAssertNil(schedule.take(now: 10_660.999))
        XCTAssertNotNil(schedule.take(now: 10_661))
    }

    func testNonfiniteClockCannotDispatchOrSchedule() {
        var schedule = ProactiveSchedule(now: 0)
        schedule.update(ready, now: 0)
        schedule.offer(key: "context", reason: .relevantContextChanged)
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(schedule.take(now: time)); XCTAssertNil(schedule.nextWake(now: time))
        }
    }

    @MainActor func testDefaultAndAllPersistedPreferencesUseIsolatedDomain() throws {
        let name = "dot-proactive-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserve", forKey: "unrelated")
        let initial = ProactiveBehavior(defaults: defaults, automaticScheduling: false, observeWorkspace: false)
        XCTAssertEqual(initial.frequency, .normal); XCTAssertFalse(initial.paused)
        for value in ProactiveFrequency.allCases {
            initial.setFrequency(value); initial.setPaused(true)
            let reopened = ProactiveBehavior(defaults: defaults, automaticScheduling: false, observeWorkspace: false)
            XCTAssertEqual(reopened.frequency, value); XCTAssertTrue(reopened.paused)
        }
        initial.setPaused(false)
        XCTAssertFalse(ProactiveBehavior(defaults: defaults, automaticScheduling: false, observeWorkspace: false).paused)
        defaults.set("unknown", forKey: ProactiveBehavior.frequencyKey)
        defaults.set("true", forKey: ProactiveBehavior.pausedKey)
        let repaired = ProactiveBehavior(defaults: defaults, automaticScheduling: false, observeWorkspace: false)
        XCTAssertEqual(repaired.frequency, .normal); XCTAssertFalse(repaired.paused)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserve")
    }

    @MainActor func testCoordinatorPriorityPauseReplacementAndStopCallbacks() throws {
        let name = "dot-proactive-coordinator-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var now = 100.0, dispatched: [ProactiveOpportunity] = [], cancelled: [UUID] = []
        let coordinator = ProactiveBehavior(defaults: defaults, clock: { now }, automaticScheduling: false, observeWorkspace: false)
        coordinator.setFrequency(.high) // This case exercises the 60-second cadence.
        coordinator.onOpportunity = { dispatched.append($0) }
        coordinator.onCancel = { cancelled.append($0) }
        coordinator.updateContext(ready)
        coordinator.offerContext(key: "first")
        now = 160; coordinator.poll()
        XCTAssertTrue(dispatched.isEmpty, "Stopped coordinator never calls an engine")
        coordinator.start(); coordinator.poll()
        let first = try XCTUnwrap(dispatched.first)
        XCTAssertEqual(coordinator.activeOpportunity, first)
        XCTAssertTrue(coordinator.offerContext(key: "replacement"))
        XCTAssertEqual(cancelled, [first.id])
        coordinator.complete(id: first.id)
        now = 219.99; coordinator.poll(); XCTAssertEqual(dispatched.count, 1)
        now = 220; coordinator.poll(); XCTAssertEqual(dispatched.count, 2)
        var busy = ready; busy.foregroundBusy = true
        coordinator.updateContext(busy)
        XCTAssertEqual(cancelled.count, 2)
        XCTAssertNil(coordinator.activeOpportunity)
        coordinator.updateContext(ready)
        coordinator.offerContext(key: "third")
        now = 280; coordinator.poll(); XCTAssertEqual(dispatched.count, 3)
        coordinator.setPaused(true)
        XCTAssertEqual(cancelled.count, 3); XCTAssertNil(coordinator.activeOpportunity)
        coordinator.setPaused(false); coordinator.offerContext(key: "fourth")
        now = 340; coordinator.poll(); XCTAssertEqual(dispatched.count, 4)
        coordinator.stop(); XCTAssertEqual(cancelled.count, 4)
        now = 1_000; coordinator.poll(); XCTAssertEqual(dispatched.count, 4)
        coordinator.stop(); XCTAssertEqual(cancelled.count, 4)
    }
}
