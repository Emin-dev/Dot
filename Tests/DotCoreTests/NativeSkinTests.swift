#if !SWIFT_PACKAGE
import XCTest
import SwiftUI
import AppKit

final class NativeSkinTests: XCTestCase {
    @MainActor private func preferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "dot.skin.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor func testDefaultAndUnknownSelectionKeepOriginalWithoutOverwritingOtherPreferences() {
        preferences { defaults in
            defaults.set("keep", forKey: "unrelated-setting")
            XCTAssertEqual(SkinPreferences(defaults: defaults).selected, .original)
            XCTAssertNil(defaults.object(forKey: SkinPreferences.selectionKey))
            for invalid in ["fold", "prototype-pearl", "future-skin"] {
                defaults.set(invalid, forKey: SkinPreferences.selectionKey)
                XCTAssertEqual(SkinPreferences(defaults: defaults).selected, .original)
            }
            XCTAssertEqual(defaults.string(forKey: "unrelated-setting"), "keep")
        }
    }

    @MainActor func testEveryApprovedSkinPersistsAcrossPreferenceOwnerRecreation() {
        XCTAssertEqual(DotSkin.allCases.map(\.rawValue), ["original", "pearl", "mochi", "cloudlet", "pip", "dew", "ripple", "sprout", "veil", "halo", "nova"])
        preferences { defaults in
            let settings = SkinPreferences(defaults: defaults)
            for skin in DotSkin.allCases {
                settings.selected = skin
                XCTAssertEqual(SkinPreferences(defaults: defaults).selected, skin)
            }
        }
    }

    @MainActor func testMotionDefaultPersistenceAndUnknownValueFallback() {
        preferences { defaults in
            let settings = SkinPreferences(defaults: defaults)
            XCTAssertEqual(settings.motionDetail, .full)
            for detail in SkinMotionDetail.allCases {
                settings.motionDetail = detail
                XCTAssertEqual(SkinPreferences(defaults: defaults).motionDetail, detail)
            }
            defaults.set("future-motion", forKey: SkinPreferences.motionKey)
            XCTAssertEqual(SkinPreferences(defaults: defaults).motionDetail, .full)
        }
    }

    func testVeilRemainsClearerThanDewAndHasNoFoldAnatomy() {
        let dew = NativeSkinAppearance.forSkin(.dew), veil = NativeSkinAppearance.forSkin(.veil)
        XCTAssertEqual(veil.silhouette, .lens)
        XCTAssertEqual(veil.material, .glass)
        XCTAssertLessThan(veil.bodyOpacity, dew.bodyOpacity)
        XCTAssertLessThan(veil.rimOpacity, dew.rimOpacity)
        XCTAssertLessThan(veil.bodyOpacity, 0.05)
    }

    func testGlassFaceContrastAdaptsWithoutLosingOpaqueFallbackInk() {
        for skin in [DotSkin.dew, .ripple, .veil] {
            let appearance = NativeSkinAppearance.forSkin(skin)
            let light = appearance.facialInk(darkAppearance: false, opaque: false)
            let dark = appearance.facialInk(darkAppearance: true, opaque: false)
            XCTAssertGreaterThan(dark.red, light.red)
            XCTAssertGreaterThan(dark.green, light.green)
            XCTAssertEqual(appearance.facialInk(darkAppearance: true, opaque: true), light)
        }
    }

    func testBodiesFitCompactPanelAndEachNewIdentityHasDistinctNativeAppearance() {
        let appearances = DotSkin.allCases.dropFirst().map(NativeSkinAppearance.forSkin)
        for (index, appearance) in appearances.enumerated() {
            XCTAssertFalse(appearances.prefix(index).contains(appearance))
            let path = NativeBodyShape(silhouette: appearance.silhouette).path(in: CGRect(x: 0, y: 0, width: 110, height: 114))
            XCTAssertFalse(path.isEmpty)
            // Small contour overshoot is allowed inside the established 132 x 138 pet surface.
            XCTAssertTrue(CGRect(x: -11, y: -12, width: 132, height: 138).contains(path.boundingRect))
        }
    }

    func testSpeechApertureUsesOnlyRealSpeakingEnvelopeAndNeverListeningMicrophoneLevel() {
        let quiet = pose(.speaking, input: 1, playback: 0)
        let loud = pose(.speaking, input: 0, playback: 0.8)
        XCTAssertGreaterThan(loud.mouthHeight, quiet.mouthHeight)
        XCTAssertEqual(pose(.speaking, input: 1, playback: 0), pose(.speaking, input: 0, playback: 0))
        XCTAssertEqual(pose(.idle, playback: 1).speakingOpening, 0)
        XCTAssertEqual(pose(.listening, playback: 1).speakingOpening, 0)
        XCTAssertEqual(pose(.thinking, playback: 1).speakingOpening, 0)
        XCTAssertEqual(pose(.speaking, time: 1, playback: nil).speakingOpening,
                       pose(.speaking, time: 2, playback: nil).speakingOpening)
    }

    func testStateReplacementImmediatelyClearsOldAudioAndListeningResponse() {
        let prior = pose(.speaking, playback: 1)
        XCTAssertGreaterThan(prior.speakingOpening, 0)
        let replacement = pose(.idle, input: 1, playback: 1)
        XCTAssertEqual(replacement.speakingOpening, 0)
        XCTAssertEqual(replacement.listeningLevel, 0)
        XCTAssertEqual(pose(.listening, input: 0.7).listeningLevel, 0.7)
        XCTAssertEqual(pose(.blocked("Audio unavailable"), input: 1, playback: 1).listeningLevel, 0)
    }

    func testReducedAndDisabledMotionStopMovementBlinkAndApertureOscillation() {
        for still in [true, false] {
            let mode: SkinMotionDetail = still ? .full : .still
            let first = NativeFacePose.sample(phase: .speaking, time: 0.01, inputLevel: 0,
                                             playbackLevel: 0, still: still, motion: mode)
            let later = NativeFacePose.sample(phase: .speaking, time: 80.01, inputLevel: 0,
                                             playbackLevel: 1, still: still, motion: mode)
            XCTAssertEqual(first, later)
            XCTAssertEqual(first.bob, 0); XCTAssertEqual(first.tilt, 0); XCTAssertEqual(first.blink, 1)
            let listening = NativeFacePose.sample(phase: .listening, time: 1, inputLevel: 1,
                                                 playbackLevel: nil, still: still, motion: mode)
            XCTAssertEqual(listening.listeningLevel, 0)
        }
        let full = NativeFacePose.sample(phase: .idle, time: 1, inputLevel: 0, playbackLevel: nil, still: false)
        let subtle = NativeFacePose.sample(phase: .idle, time: 1, inputLevel: 0, playbackLevel: nil, still: false, motion: .subtle)
        XCTAssertLessThan(abs(subtle.bob), abs(full.bob))
    }

    func testInvalidAudioAndClockCannotProduceInvalidGeometry() {
        for value in [Double.nan, .infinity, -.infinity, -10, 10] {
            let result = pose(.speaking, time: value, input: value, playback: value)
            for coordinate in [result.bob, result.tilt, result.gazeX, result.gazeY, result.mouthWidth, result.mouthHeight] {
                XCTAssertTrue(coordinate.isFinite)
            }
            XCTAssertTrue((0...1).contains(result.speakingOpening))
        }
    }

    func testAllInitialRecipesKeepFriendlyFaceAndExplicitLifecycle() {
        XCTAssertEqual(Set(NativeExpressionRecipe.initialRecipes.map(\.id)).count, 5)
        for state in NativeFaceState.allCases {
            let recipe = NativeExpressionRecipe.forState(state)
            XCTAssertEqual(recipe.compatibleStates, [state])
            XCTAssertGreaterThan(recipe.cycleSeconds, 0)
            XCTAssertFalse(recipe.trigger.isEmpty)
            XCTAssertFalse(recipe.cancellation.isEmpty)
            XCTAssertGreaterThan(recipe.mouthCurve, 0)
            XCTAssertLessThanOrEqual(recipe.browTilt, 0)
        }
    }

    @MainActor func testEachSkinRendersNatively() throws {
        _ = NSApplication.shared
        for skin in DotSkin.allCases {
            let content = PetCharacter(phase: .idle, level: 0, still: true, skin: skin)
                .frame(width: 132, height: 138)
            let renderer = ImageRenderer(content: content)
            let rendered = try XCTUnwrap(renderer.cgImage, skin.displayName)
            XCTAssertEqual(rendered.width, 132); XCTAssertEqual(rendered.height, 138)
        }
    }

    @MainActor func testOpaqueBodyPolicyRendersWithoutChangingOSAccessibilityPreferences() throws {
        _ = NSApplication.shared
        for skin in [DotSkin.dew, .ripple, .veil] {
            let body = NativeSkinBody(skin: skin, appearance: .forSkin(skin), opaque: true, increasedContrast: true)
                .frame(width: 132, height: 138)
            let renderer = ImageRenderer(content: body)
            let rendered = try XCTUnwrap(renderer.cgImage)
            // Tests the explicit fallback renderer; actual OS preference delivery needs device acceptance.
            XCTAssertEqual(rendered.width, 132); XCTAssertEqual(rendered.height, 138)
        }
    }

    private func pose(_ phase: PetPhase, time: Double = 1, input: Double = 0, playback: Double? = nil) -> NativeFacePose {
        NativeFacePose.sample(phase: phase, time: time, inputLevel: input, playbackLevel: playback, still: false)
    }
}
#endif
