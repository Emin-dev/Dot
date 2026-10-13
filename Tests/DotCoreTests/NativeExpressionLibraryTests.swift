#if !SWIFT_PACKAGE
import XCTest
import SwiftUI
import AppKit
import CryptoKit

final class NativeExpressionLibraryTests: XCTestCase {
    func testAuthoredInventoryHasIdentityAndLifecycleForEveryRecipe() {
        XCTAssertEqual(NativeExpressionLibrary.all.count, 120)
        XCTAssertEqual(Set(NativeExpressionLibrary.all.map(\.id)).count, 120)
        XCTAssertEqual(Set(NativeExpressionLibrary.all.map(\.name)).count, 120)
        for state in NativeFaceState.allCases {
            XCTAssertEqual(NativeExpressionLibrary.recipes(for: state).count, 24)
        }
        for recipe in NativeExpressionLibrary.all {
            XCTAssertFalse(recipe.purpose.isEmpty)
            XCTAssertFalse(recipe.trigger.isEmpty)
            XCTAssertFalse(recipe.cancellation.isEmpty)
            XCTAssertEqual(recipe.compatibleStates, [recipe.state])
            XCTAssertTrue((3...9).contains(recipe.duration))
            XCTAssertEqual(recipe.keyframes.first?.progress, 0)
            XCTAssertEqual(recipe.keyframes.last?.progress, 1)
            XCTAssertEqual(recipe.sample(elapsed: 0), .rest)
            XCTAssertEqual(recipe.sample(elapsed: recipe.duration), .rest)
            XCTAssertEqual(recipe.sample(elapsed: -.infinity), .rest)
            for pair in zip(recipe.keyframes, recipe.keyframes.dropFirst()) {
                XCTAssertLessThan(pair.0.progress, pair.1.progress)
            }
        }
    }

    func testAllTrajectoriesStayWarmFiniteAndInsideSmallMotionBounds() {
        for recipe in NativeExpressionLibrary.all {
            for index in 0...60 {
                let pose = recipe.sample(elapsed: recipe.duration * Double(index) / 60)
                for value in [pose.gazeX, pose.gazeY, pose.eyes, pose.browLift, pose.browAsymmetry,
                              pose.smile, pose.mouthWidth, pose.tilt, pose.lift, pose.squash, pose.accent, pose.cheeks,
                              pose.smileOpening, pose.teeth, pose.dimples] {
                    XCTAssertTrue(value.isFinite, recipe.id)
                }
                XCTAssertTrue((-4...4).contains(pose.gazeX), recipe.id)
                XCTAssertTrue((-4...3).contains(pose.gazeY), recipe.id)
                XCTAssertTrue((0.9...1.3).contains(pose.eyes), recipe.id)
                XCTAssertTrue((-3...0).contains(pose.browLift), recipe.id)
                XCTAssertTrue((-4...4).contains(pose.browAsymmetry), recipe.id)
                XCTAssertGreaterThanOrEqual(pose.smile, 4, recipe.id)
                XCTAssertTrue((9...13.5).contains(pose.mouthWidth), recipe.id)
                XCTAssertTrue((-5.5...5.5).contains(pose.tilt), recipe.id)
                XCTAssertTrue((-3...2.5).contains(pose.lift), recipe.id)
                XCTAssertTrue((0.97...1.035).contains(pose.squash), recipe.id)
                XCTAssertTrue((-1...1).contains(pose.accent), recipe.id)
                XCTAssertTrue((0...6).contains(pose.smileOpening), recipe.id)
                XCTAssertTrue((0...1).contains(pose.teeth), recipe.id)
                XCTAssertTrue((0...1).contains(pose.dimples), recipe.id)
            }
        }
    }

    func testStateChangeCancelsSelectionAndNeverCreatesResearchOrSuccessStatus() {
        for state in NativeFaceState.allCases {
            for visit in 0..<24 {
                let selected = NativeExpressionLibrary.select(.init(state: state, elapsed: 1.4, visit: UInt64(visit)))
                XCTAssertEqual(selected.recipe.compatibleStates, [state])
                XCTAssertFalse(selected.recipe.id.contains("research"))
                XCTAssertFalse(selected.recipe.id.contains("success"))
            }
        }
        let pose = NativeFacePose.sample(phase: .idle, context: .init(state: .speaking, elapsed: 2),
                                        inputLevel: 1, playbackLevel: 1, still: false)
        XCTAssertEqual(pose.speakingOpening, 0)
        XCTAssertEqual(pose.listeningLevel, 0)
    }

    func testEveryRecipeIsReachableAcrossShortRepeatedRealTurns() {
        var clock = NativeExpressionClock(now: 100)
        var reached: [NativeFaceState: Set<String>] = [:]
        for turn in 0..<24 {
            for (offset, state) in [NativeFaceState.listening, .thinking, .speaking, .idle, .blocked].enumerated() {
                let now = 100 + Double(turn * 10 + offset)
                clock.restart(state: state, at: now)
                let selected = NativeExpressionLibrary.select(clock.context(state: state, now: now + 0.01))
                reached[state, default: []].insert(selected.recipe.id)
            }
        }
        for state in NativeFaceState.allCases { XCTAssertEqual(reached[state]?.count, 24) }
    }

    func testSamePhaseStopRevisionRestartsWithoutRetainingOldProgress() {
        var clock = NativeExpressionClock(now: 100)
        let before = clock.context(state: .listening, now: 103)
        XCTAssertEqual(before.elapsed, 3)
        clock.restart(state: .listening, at: 103)
        let after = clock.context(state: .listening, now: 103)
        XCTAssertEqual(after.elapsed, 0)
        XCTAssertNotEqual(after.visit, before.visit)
        XCTAssertEqual(NativeExpressionLibrary.select(after).recipe.sample(elapsed: after.elapsed), .rest)
        XCTAssertEqual(clock.context(state: .idle, now: 99).elapsed, 0)
        XCTAssertEqual(clock.context(state: .idle, now: .nan).elapsed, 0)
    }

    func testRecipeBoundaryReturnsToRestBeforeNextCompatibleTrajectory() {
        for state in NativeFaceState.allCases {
            let recipes = NativeExpressionLibrary.recipes(for: state)
            for index in recipes.indices {
                let recipe = recipes[index]
                let next = NativeExpressionLibrary.select(.init(state: state, elapsed: recipe.duration, visit: UInt64(index)))
                XCTAssertEqual(next.recipe.id, recipes[(index + 1) % recipes.count].id)
                XCTAssertEqual(next.elapsed, 0, accuracy: 0.000001)
                XCTAssertEqual(next.recipe.sample(elapsed: next.elapsed), .rest)
            }
        }
    }

    func testReducedMotionIsStaticAcrossAllRecipesAndSpeechEnvelopes() {
        for state in NativeFaceState.allCases {
            let phase = phase(state)
            let reference = NativeFacePose.sample(phase: phase, context: .init(state: state, elapsed: 0),
                                                 inputLevel: 0, playbackLevel: 0, still: true)
            for visit in 0..<24 {
                for time in [0.2, 1.8, 5.4] {
                    let pose = NativeFacePose.sample(phase: phase, context: .init(state: state, elapsed: time, visit: UInt64(visit)),
                                                    inputLevel: 1, playbackLevel: 1, still: false, motion: .still)
                    XCTAssertEqual(pose, reference)
                    XCTAssertEqual(pose.blink, 1); XCTAssertEqual(pose.bodyAccent, 0)
                }
            }
        }
    }

    func testSpeakingRecipesArticulateOnlyThePlaybackEnvelope() {
        for visit in 0..<24 {
            let context = NativeExpressionContext(state: .speaking, elapsed: 1.5, visit: UInt64(visit))
            let quiet = NativeFacePose.sample(phase: .speaking, context: context, inputLevel: 1, playbackLevel: 0, still: false)
            let loud = NativeFacePose.sample(phase: .speaking, context: context, inputLevel: 0, playbackLevel: 0.8, still: false)
            XCTAssertEqual(quiet.speakingOpening, 0)
            XCTAssertEqual(loud.speakingOpening, 0.8)
            XCTAssertGreaterThan(loud.mouthHeight, quiet.mouthHeight)
            let absent = NativeFacePose.sample(phase: .speaking, context: context, inputLevel: 1, playbackLevel: nil, still: false)
            XCTAssertEqual(absent.speakingOpening, 0.12)
            let canceled = NativeFacePose.sample(phase: .idle, context: context, inputLevel: 1, playbackLevel: 0.8, still: false)
            XCTAssertEqual(canceled.speakingOpening, 0)
        }
    }

    func testInvalidAndLongClocksCannotExhaustSelectorOrCreateInvalidPose() {
        for time in [Double.nan, .infinity, -.infinity, -1, 1e20] {
            let context = NativeExpressionContext(state: .thinking, elapsed: time, visit: .max)
            let selected = NativeExpressionLibrary.select(context)
            XCTAssertTrue(selected.elapsed.isFinite)
            XCTAssertTrue((0..<selected.recipe.duration).contains(selected.elapsed))
            XCTAssertTrue(selected.recipe.sample(elapsed: selected.elapsed).tilt.isFinite)
        }
    }

    func testSubtleMotionReducesGeometryWithoutReplacingTheRecipe() {
        let context = NativeExpressionContext(state: .idle, elapsed: 1.5, visit: 1)
        let full = NativeFacePose.sample(phase: .idle, context: context, inputLevel: 0, playbackLevel: nil, still: false)
        let subtle = NativeFacePose.sample(phase: .idle, context: context, inputLevel: 0, playbackLevel: nil, still: false, motion: .subtle)
        XCTAssertLessThan(abs(subtle.tilt), abs(full.tilt))
        XCTAssertLessThan(abs(subtle.gazeX), abs(full.gazeX))
        XCTAssertGreaterThanOrEqual(subtle.mouthCurve, 4)
    }

    @MainActor func testAll120NativeTrajectoriesPaintDistinctlyOnEachNewIdentity() throws {
        _ = NSApplication.shared
        for skin in DotSkin.allCases where skin != .original {
            var signatures: Set<String> = []
            for recipe in NativeExpressionLibrary.all {
                var digest = SHA256()
                let visit = try XCTUnwrap(NativeExpressionLibrary.recipes(for: recipe.state).firstIndex { $0.id == recipe.id })
                for progress in [0.28, 0.48, 0.66] {
                    try autoreleasepool {
                        let context = NativeExpressionContext(state: recipe.state, elapsed: recipe.duration * progress, visit: UInt64(visit))
                        let pose = NativeFacePose.sample(phase: phase(recipe.state), context: context, inputLevel: 0.12,
                                                        playbackLevel: recipe.state == .speaking ? 0.25 : nil, still: false)
                        let frame = NativeSkinFrame(phase: phase(recipe.state), skin: skin, pose: pose)
                            .frame(width: 132, height: 138).environment(\.colorScheme, .light)
                        let renderer = ImageRenderer(content: frame)
                        let image = try XCTUnwrap(renderer.cgImage, "\(skin)/\(recipe.id)")
                        XCTAssertEqual(image.width, 132); XCTAssertEqual(image.height, 138)
                        let data = try XCTUnwrap(image.dataProvider?.data)
                        digest.update(data: data as Data)
                    }
                }
                let signature = digest.finalize().map { String(format: "%02x", $0) }.joined()
                XCTAssertTrue(signatures.insert(signature).inserted, "Duplicate painted trajectory for \(skin)/\(recipe.id)")
            }
            XCTAssertEqual(signatures.count, 120)
        }
        // Pixel uniqueness is a regression guard, not proof of perceptual review,
        // native frame-time/battery performance, or true audio/phoneme alignment.
    }

    private func phase(_ state: NativeFaceState) -> PetPhase {
        switch state {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .blocked: return .blocked("Issue remains unresolved")
        }
    }
}
#endif
