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

    @MainActor func testDefaultAndUnknownSelectionKeepDewWithoutOverwritingOtherPreferences() {
        preferences { defaults in
            defaults.set("keep", forKey: "unrelated-setting")
            XCTAssertEqual(SkinPreferences(defaults: defaults).selected, .dew)
            XCTAssertNil(defaults.object(forKey: SkinPreferences.selectionKey))
            for invalid in ["fold", "prototype-pearl", "future-skin"] {
                defaults.set(invalid, forKey: SkinPreferences.selectionKey)
                XCTAssertEqual(SkinPreferences(defaults: defaults).selected, .dew)
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

    func testGlassFaceHasDualToneEdgeIndependentOfOSAppearance() {
        for skin in [DotSkin.dew, .ripple, .veil] {
            let appearance = NativeSkinAppearance.forSkin(skin)
            let light = appearance.facialInk(darkAppearance: false, opaque: false)
            let dark = appearance.facialInk(darkAppearance: true, opaque: false)
            XCTAssertEqual(dark, light)
            XCTAssertLessThan(dark.red, 0.25)
            XCTAssertGreaterThanOrEqual(appearance.facialOutlineWidth(opaque: false), 1)
            XCTAssertGreaterThan(appearance.facialOutlineWidth(opaque: false, increasedContrast: true),
                                 appearance.facialOutlineWidth(opaque: false))
            XCTAssertEqual(appearance.facialOutlineWidth(opaque: true), 0)
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

    @MainActor func testGlassFeaturesRemainVisibleAcrossOpposingAndSyntheticSceneBackdrops() throws {
        _ = NSApplication.shared
        let backdrops: [AnyView] = [AnyView(Color(white: 0.97)), AnyView(Color(white: 0.03)), AnyView(SyntheticContrastScene())]
        for skin in [DotSkin.dew, .ripple, .veil] {
            for scheme in [ColorScheme.light, .dark] {
                for increased in [false, true] {
                    for (index, backdrop) in backdrops.enumerated() {
                        let pose = NativeFacePose.sample(phase: .idle, time: 0, inputLevel: 0, playbackLevel: nil, still: true)
                        let content = NativeSkinArtwork(phase: .idle, skin: skin, pose: pose, opaque: false, increasedContrast: increased)
                            .frame(width: 148, height: 156).background(backdrop).environment(\.colorScheme, scheme)
                        let image = try renderPixels(content)
                        let background = try renderPixels(backdrop.frame(width: 148, height: 156))
                        let shift = skin == .ripple ? 7 : 0
                        let regions = [CGRect(x: 51, y: 58 + shift, width: 18, height: 24),
                                       CGRect(x: 63, y: 85 + shift, width: 23, height: 13),
                                       CGRect(x: 48, y: 48 + shift, width: 50, height: 12)]
                        for region in regions {
                            var distinguishable = 0
                            for y in Int(region.minY * 2)..<Int(region.maxY * 2) {
                                for x in Int(region.minX * 2)..<Int(region.maxX * 2) {
                                    let offset = (y * 296 + x) * 4
                                    let foreground = luminance(image, offset: offset)
                                    let behind = luminance(background, offset: offset)
                                    if (max(foreground, behind) + 0.05) / (min(foreground, behind) + 0.05) >= 4.5 {
                                        distinguishable += 1
                                    }
                                }
                            }
                            XCTAssertGreaterThan(distinguishable, 40, "\(skin) / \(scheme) / increased \(increased) / backdrop \(index) / \(region)")
                        }
                    }
                }
            }
        }
        // Controlled feature visibility is not certification over every image or
        // evidence that macOS delivered a changed accessibility preference.
    }

    @MainActor private func renderPixels<V: View>(_ view: V) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 296); XCTAssertEqual(image.height, 312)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func luminance(_ data: [UInt8], offset: Int) -> Double {
        func linear(_ value: UInt8) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return linear(data[offset]) * 0.2126 + linear(data[offset + 1]) * 0.7152 + linear(data[offset + 2]) * 0.0722
    }

    private func pose(_ phase: PetPhase, time: Double = 1, input: Double = 0, playback: Double? = nil) -> NativeFacePose {
        NativeFacePose.sample(phase: phase, time: time, inputLevel: input, playbackLevel: playback, still: false)
    }
}

/// Generated scenery/text-like detail; contains no user screen or file content.
private struct SyntheticContrastScene: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.53, blue: 0.9), .white, Color(red: 0.2, green: 0.36, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<9) { index in
                Ellipse().fill(index.isMultiple(of: 2) ? Color.green.opacity(0.65) : Color.orange.opacity(0.65))
                    .frame(width: 60, height: 85).rotationEffect(.degrees(Double(index * 23)))
                    .offset(x: Double((index * 37) % 121) - 60, y: Double((index * 29) % 121) - 60)
            }
            ForEach(0..<8) { index in
                Rectangle().fill(index.isMultiple(of: 2) ? .white.opacity(0.9) : .black.opacity(0.8))
                    .frame(width: 148, height: index.isMultiple(of: 2) ? 3 : 5).offset(y: Double(index * 19) - 70)
            }
        }.frame(width: 148, height: 156).clipped()
    }
}
#endif
