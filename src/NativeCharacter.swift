import SwiftUI

enum PetEmotion: String, CaseIterable, Equatable {
    case idle
    case listening
    case thinking
    case working
    case speaking
    case puzzled

    var caption: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .speaking: return "Speaking"
        case .puzzled: return "Needs attention"
        }
    }
}

struct PetCharacter: View {
    var emotion: PetEmotion = .idle
    let phase: PetPhase
    let level: Double
    let still: Bool
    var skin: DotSkin = .original
    var playbackLevel: Double? = nil
    var motionDetail: SkinMotionDetail = .full
    var expressionRevision: UInt64 = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolvedEmotion: PetEmotion {
        if emotion != .idle { return emotion }
        switch phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .blocked: return .puzzled
        }
    }

    var body: some View {
        Group {
            if skin == .original {
                OriginalPetCharacter(emotion: resolvedEmotion, phase: phase, level: level,
                                     still: still || reduceMotion || motionDetail == .still,
                                     motionScale: motionDetail.movementScale, playbackLevel: playbackLevel)
            } else {
                NativeSkinCharacter(emotion: resolvedEmotion, phase: phase, level: level,
                                    still: still || reduceMotion,
                                    skin: skin, playbackLevel: playbackLevel, motionDetail: motionDetail,
                                    expressionRevision: expressionRevision)
            }
        }.accessibilityHidden(true)
    }
}

// The original is kept as the default, retaining the existing shape and appearance.
private struct OriginalPetCharacter: View {
    let emotion: PetEmotion
    let phase: PetPhase
    let level: Double
    let still: Bool
    let motionScale: Double
    let playbackLevel: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private var ink: Color { colorScheme == .dark ? Color(red: 0.08, green: 0.13, blue: 0.17) : Color(red: 0.22, green: 0.36, blue: 0.41) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let (bob, tilt, scaleY) = posture(time: time)
            ZStack {
                // Ground shadow
                Ellipse().fill(.black.opacity(0.10)).frame(width: 75, height: 10).blur(radius: 4).offset(y: 62)

                // Main character bubble
                ZStack {
                    if reduceTransparency {
                        Circle().fill(Color(red: 0.84, green: 0.91, blue: 0.93)).frame(width: 108, height: 108)
                    } else {
                        Circle().fill(.regularMaterial).frame(width: 108, height: 108)
                            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.60), Color(red: 0.55, green: 0.74, blue: 0.80).opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    }
                    Circle().strokeBorder(.white.opacity(0.58), lineWidth: 1.5).frame(width: 106, height: 106)
                    Circle().trim(from: 0.08, to: 0.43).stroke(.white.opacity(0.65), lineWidth: 2).rotationEffect(.degrees(90)).frame(width: 94, height: 94)
                    Ellipse().fill(.white.opacity(0.75)).frame(width: 25, height: 11).rotationEffect(.degrees(-35)).blur(radius: 2).offset(x: -26, y: -33)

                    // Warm cheeks
                    cheeksView(time: time)

                    // Eyebrows
                    HStack(spacing: 24) {
                        browView(side: -1.0, time: time)
                        browView(side: 1.0, time: time)
                    }
                    .offset(y: -15)

                    // Eyes
                    HStack(spacing: 22) {
                        eyeView(side: -1.0, time: time)
                        eyeView(side: 1.0, time: time)
                    }
                    .offset(y: -4)

                    // Mouth
                    mouthView(time: time)
                        .offset(y: 12)
                }
                .scaleEffect(y: scaleY)
                .rotationEffect(.degrees(tilt))
                .offset(y: bob)
            }
        }
    }

    private func posture(time: TimeInterval) -> (Double, Double, Double) {
        if still { return (0, 0, 1.0) }
        switch emotion {
        case .idle:
            let bob = sin(time * 1.5) * 2.5 * motionScale
            let tilt = sin(time * 0.8) * 1.5 * motionScale
            let scaleY = 1.0 + sin(time * 1.5) * 0.015
            return (bob, tilt, scaleY)
        case .listening:
            let bob = -1.5 + sin(time * 2.8) * 0.8
            let tilt = 3.2
            return (bob, tilt, 1.02)
        case .thinking:
            let bob = sin(time * 1.2) * 1.6 * motionScale
            let tilt = -5.0 + sin(time * 1.2) * 1.2 * motionScale
            return (bob, tilt, 0.99)
        case .working:
            let bob = sin(time * 3.5) * 0.9 * motionScale
            let tilt = 1.2
            return (bob, tilt, 1.0)
        case .speaking:
            let wave1 = abs(sin(time * 13.0))
            let wave2 = abs(sin(time * 21.0 + 1.1))
            let cadence = (wave1 * 0.65 + wave2 * 0.35)
            let bob = (cadence * 2.2 - 0.8) * motionScale
            let tilt = sin(time * 3.5) * 1.8 * motionScale
            return (bob, tilt, 1.0 + cadence * 0.02)
        case .puzzled:
            let bob = sin(time * 1.0) * 1.2 * motionScale
            let tilt = -8.5 + sin(time * 1.2) * 1.0
            return (bob, tilt, 0.98)
        }
    }

    private func eyeView(side: Double, time: TimeInterval) -> some View {
        let isBlinking = !still && emotion == .idle && (time.truncatingRemainder(dividingBy: 4.2) < 0.14)
        let isSpeaking = emotion == .speaking
        let isListening = emotion == .listening
        let isThinking = emotion == .thinking
        let isWorking = emotion == .working
        let isPuzzled = emotion == .puzzled

        let gazeX: CGFloat = {
            if isThinking {
                return still ? 3.0 : CGFloat(2.5 + sin(time * 1.5) * 1.5)
            }
            if isWorking {
                return still ? 0 : CGFloat(sin(time * 4.5) * 4.0)
            }
            if isPuzzled { return -1.5 }
            return 0
        }()
        let gazeY: CGFloat = {
            if isThinking {
                return still ? -3.0 : CGFloat(-3.2 + cos(time * 1.5) * 0.8)
            }
            if isWorking { return -0.8 }
            if isListening { return -1.2 }
            if isPuzzled { return 1.5 }
            return 0
        }()

        let w: CGFloat = isListening ? 6.8 : (isPuzzled ? 6.5 : (isWorking ? 6.2 : 6.0))
        let h: CGFloat = {
            if isBlinking { return 2.0 }
            if isSpeaking {
                let wave1 = abs(sin(time * 13.0))
                let wave2 = abs(sin(time * 21.0 + 1.1))
                let cadence = (wave1 * 0.65 + wave2 * 0.35)
                return max(4.0, 9.0 - CGFloat(cadence * 2.5))
            }
            if isListening { return 13.0 + CGFloat(min(level, 0.4) * 6.0) }
            if isThinking || isWorking { return 10.5 }
            if isPuzzled { return 11.5 }
            return 11.0
        }()

        return ZStack {
            Capsule()
                .fill(ink)
                .frame(width: w, height: h)

            if h > 4.5 {
                // Primary specular catchlight
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2.2, height: 2.2)
                    .offset(x: -1.2, y: -h * 0.26)

                // Secondary soft lower gleam
                Circle()
                    .fill(Color.white.opacity(0.60))
                    .frame(width: 1.3, height: 1.3)
                    .offset(x: 1.0, y: h * 0.22)

                if isThinking {
                    Circle()
                        .fill(Color.cyan.opacity(0.40 + 0.30 * abs(sin(time * 3.0))))
                        .frame(width: 4, height: 4)
                        .blur(radius: 1)
                }
            }
        }
        .offset(x: gazeX, y: gazeY)
    }

    private func browView(side: Double, time: TimeInterval) -> some View {
        let rotation: Double = {
            switch emotion {
            case .idle: return side * -3.0
            case .listening: return side * -4.0
            case .thinking: return side == -1.0 ? 8.0 : -2.0
            case .working: return side * 7.0
            case .speaking: return side * -3.0
            case .puzzled: return side == -1.0 ? -12.0 : -6.0
            }
        }()
        let offsetY: CGFloat = {
            switch emotion {
            case .idle: return 0
            case .listening: return -2.5
            case .thinking: return side == -1.0 ? -3.5 : 0.5
            case .working: return -1.0
            case .speaking: return -1.0 + CGFloat(sin(time * 16.0) * 0.8)
            case .puzzled: return side == -1.0 ? -3.0 : 0
            }
        }()

        return Capsule()
            .fill(ink.opacity(0.85))
            .frame(width: 8, height: 1.8)
            .rotationEffect(.degrees(rotation))
            .offset(y: offsetY)
    }

    @ViewBuilder
    private func mouthView(time: TimeInterval) -> some View {
        switch emotion {
        case .speaking:
            OriginalSpeakingMouth(time: time, ink: ink, still: still, playbackLevel: playbackLevel)
        case .idle:
            Smile().stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 10, height: 5)
        case .listening:
            ZStack {
                NativeSmileOpening()
                    .fill(ink)
                    .frame(width: 9, height: 4)
                Smile()
                    .stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 11, height: 3.5)
            }
        case .thinking:
            let pulse = still ? 0.0 : sin(time * 3.0) * 0.5
            ZStack {
                Capsule()
                    .fill(ink)
                    .frame(width: 5.5 + CGFloat(pulse), height: 3.0 + CGFloat(pulse * 0.5))
                Smile()
                    .stroke(ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: 7.0, height: 2.5)
                    .offset(y: -1.0)
            }
            .offset(x: 1.5)
        case .working:
            Smile().stroke(ink, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                .frame(width: 9.0, height: 3.8)
        case .puzzled:
            ZStack {
                Ellipse()
                    .stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 5.5, height: 5.5)
                NativeSmileOpening()
                    .fill(ink.opacity(0.25))
                    .frame(width: 4.0, height: 3.5)
            }
            .offset(x: -0.5)
        }
    }

    private func cheeksView(time: TimeInterval) -> some View {
        ForEach([-1.0, 1.0], id: \.self) { side in
            let blushOpacity: Double = {
                switch emotion {
                case .speaking: return still ? 0.25 : 0.35 + 0.08 * sin(time * 4.0)
                case .listening: return 0.28
                case .idle: return 0.20
                case .working: return 0.24
                case .thinking: return 0.22
                case .puzzled: return 0.16
                }
            }()
            Ellipse()
                .fill(Color.pink.opacity(blushOpacity))
                .frame(width: 14, height: 7)
                .blur(radius: 2)
                .offset(x: side * 28, y: 7)
        }
    }
}

private struct OriginalSpeakingMouth: View {
    let time: TimeInterval
    let ink: Color
    let still: Bool
    let playbackLevel: Double?

    var body: some View {
        let level = playbackLevel.map(NativeFacePose.unit) ?? 0.20
        let wave1 = abs(sin(time * 13.0))
        let wave2 = abs(sin(time * 21.0 + 1.1))
        let syllable = (wave1 * 0.65 + wave2 * 0.35)
        let cadence = still ? 0.45 : syllable
        let openFraction = still ? 0.35 : max(0.12, level * 0.70 + cadence * (level > 0.05 ? 0.50 : 0.25))
        let width = still ? 11.0 : (8.5 + openFraction * 8.5 - abs(sin(time * 10.0)) * 1.5)
        let height = still ? 6.0 : (2.5 + openFraction * 13.5)

        ZStack {
            NativeSmileOpening()
                .fill(ink)
                .frame(width: width, height: height)

            if height > 5.0 {
                Ellipse()
                    .fill(Color(red: 0.95, green: 0.55, blue: 0.62))
                    .frame(width: width * 0.58, height: max(2.0, height * 0.34))
                    .offset(y: height * 0.24)
            }

            if height > 6.2 {
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: width * 0.60, height: 1.8)
                    .offset(y: -height * 0.28)
            }

            Smile()
                .stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: width + 2.5, height: 3.5)
                .offset(y: -height * 0.32)
        }
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: 0), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

enum NativeSkinSilhouette: String { case circle, pebble, cloud, bird, bubble, droplet, leaf, lens, orb, visor }
enum NativeSkinMaterial: String { case ceramic, plush, cloud, feather, glass, leaf, energy, metal }

struct NativeSkinColor: Equatable {
    let red: Double, green: Double, blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// One render configuration and one shared facial rig per identity, rather than ten engines.
struct NativeSkinAppearance: Equatable {
    let silhouette: NativeSkinSilhouette
    let material: NativeSkinMaterial
    let light: NativeSkinColor
    let shade: NativeSkinColor
    let ink: NativeSkinColor
    let bodyOpacity: Double
    let rimOpacity: Double
    let eyeSpacing: Double
    let eyeWidth: Double
    let eyeHeight: Double

    func facialInk(darkAppearance: Bool, opaque: Bool) -> NativeSkinColor {
        // A transparent companion can cross either a light or a dark window,
        // independent of the OS appearance. Keep a dark centre plus a solid
        // light edge instead of guessing the pixels behind it from colorScheme.
        ink
    }
    func facialOutlineWidth(opaque: Bool, increasedContrast: Bool = false) -> Double {
        material == .glass && !opaque ? (increasedContrast ? 1.8 : 1.2) : 0
    }

    static func forSkin(_ skin: DotSkin) -> Self {
        let dark = NativeSkinColor(red: 0.12, green: 0.18, blue: 0.22)
        func style(_ shape: NativeSkinSilhouette, _ material: NativeSkinMaterial,
                   _ light: NativeSkinColor, _ shade: NativeSkinColor, opacity: Double = 1,
                   rim: Double = 0.65, spacing: Double = 31, width: Double = 10,
                   height: Double = 15, ink: NativeSkinColor? = nil) -> Self {
            Self(silhouette: shape, material: material, light: light, shade: shade, ink: ink ?? dark,
                 bodyOpacity: opacity, rimOpacity: rim, eyeSpacing: spacing, eyeWidth: width, eyeHeight: height)
        }
        switch skin {
        case .original: return style(.circle, .glass, .init(red: 0.84, green: 0.91, blue: 0.93), .init(red: 0.55, green: 0.74, blue: 0.80), spacing: 28, width: 6, height: 11)
        case .pearl: return style(.circle, .ceramic, .init(red: 1, green: 0.98, blue: 0.93), .init(red: 0.76, green: 0.84, blue: 0.86))
        case .mochi: return style(.pebble, .plush, .init(red: 1, green: 0.93, blue: 0.80), .init(red: 0.73, green: 0.67, blue: 0.53), spacing: 34, width: 11, height: 13)
        case .cloudlet: return style(.cloud, .cloud, .init(red: 0.96, green: 0.99, blue: 1), .init(red: 0.53, green: 0.69, blue: 0.89), spacing: 34, width: 11, height: 15)
        case .pip: return style(.bird, .feather, .init(red: 0.82, green: 0.95, blue: 0.92), .init(red: 0.32, green: 0.63, blue: 0.65), spacing: 34, width: 12, height: 16)
        case .dew: return style(.bubble, .glass, .init(red: 0.95, green: 1, blue: 1), .init(red: 0.72, green: 0.87, blue: 0.96), opacity: 0.13, rim: 0.82, spacing: 31, width: 9, height: 15)
        case .ripple: return style(.droplet, .glass, .init(red: 0.96, green: 0.93, blue: 1), .init(red: 0.77, green: 0.77, blue: 0.94), opacity: 0.16, rim: 0.74, spacing: 28, width: 9, height: 14)
        case .sprout: return style(.leaf, .leaf, .init(red: 0.88, green: 0.94, blue: 0.57), .init(red: 0.30, green: 0.49, blue: 0.13), spacing: 27, width: 9, height: 14)
        case .veil: return style(.lens, .glass, .init(red: 1, green: 1, blue: 1), .init(red: 0.89, green: 0.96, blue: 1), opacity: 0.025, rim: 0.40, spacing: 30, width: 8, height: 13)
        case .halo: return style(.orb, .energy, .init(red: 0.78, green: 0.97, blue: 1), .init(red: 0.12, green: 0.48, blue: 0.95), spacing: 33, width: 11, height: 16, ink: .init(red: 0.05, green: 0.21, blue: 0.43))
        case .nova: return style(.visor, .metal, .init(red: 0.30, green: 0.36, blue: 0.47), .init(red: 0.06, green: 0.09, blue: 0.16), spacing: 35, width: 12, height: 15, ink: .init(red: 0.55, green: 0.93, blue: 1))
        }
    }
}

enum NativeFaceState: CaseIterable, Hashable {
    case idle, listening, thinking, speaking, blocked
    init(_ phase: PetPhase) {
        switch phase {
        case .idle: self = .idle
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        case .blocked: self = .blocked
        }
    }
}

struct NativeFacePose: Equatable {
    let bob: Double, tilt: Double, blink: Double, gazeX: Double, gazeY: Double
    let browTilt: Double, mouthWidth: Double, mouthHeight: Double, mouthCurve: Double
    let speakingOpening: Double, listeningLevel: Double
    var eyes: Double = 1
    var browLift: Double = 0
    var browAsymmetry: Double = 0
    var squash: Double = 1
    var bodyAccent: Double = 0
    var cheeks: Double = 0.16
    var smileOpening: Double = 0
    var teeth: Double = 0
    var dimples: Double = 0

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    /// Stateless sampling means an old state has no timer/task that can animate a replacement turn.
    /// playbackLevel is optional: absent a real audio envelope, use a static speaking pose.
    static func sample(phase: PetPhase, time: TimeInterval, inputLevel: Double, playbackLevel: Double?,
                       still: Bool, motion: SkinMotionDetail = .full) -> Self {
        sample(phase: phase, context: .init(state: NativeFaceState(phase), elapsed: time),
               inputLevel: inputLevel, playbackLevel: playbackLevel, still: still, motion: motion)
    }

    static func sample(phase: PetPhase, context: NativeExpressionContext, inputLevel: Double,
                       playbackLevel: Double?, still: Bool, motion: SkinMotionDetail = .full) -> Self {
        let state = NativeFaceState(phase)
        let amount = still ? 0 : motion.movementScale
        // Ignore mismatched external state; the real app phase owns status.
        let actualContext = NativeExpressionContext(state: state, elapsed: context.elapsed, visit: context.visit)
        let selected = NativeExpressionLibrary.select(actualContext)
        let expression = amount == 0 ? NativeExpressionPose.rest : NativeExpressionPose.rest.mixed(toward: selected.recipe.sample(elapsed: selected.elapsed), by: amount)
        let blink = amount > 0 ? selected.recipe.blink(elapsed: selected.elapsed) : 1
        let speaking = state == .speaking
        let cadence = still ? 0.5 : (abs(sin(context.elapsed * 16.0)) * 0.5 + 0.5)
        let opening = speaking ? (amount == 0 ? 0.12 : max(0.12, (playbackLevel.map(unit) ?? 0.18) * 0.8 + cadence * ((playbackLevel ?? 0) > 0.05 ? 0.45 : 0.12))) : 0
        let listening = state == .listening && amount > 0 ? unit(inputLevel) : 0
        return Self(bob: expression.lift, tilt: expression.tilt * 1.2, blink: blink,
                    gazeX: expression.gazeX * 1.3, gazeY: expression.gazeY * 1.3, browTilt: -4,
                    mouthWidth: speaking ? expression.mouthWidth * (1 + opening * 0.8) : expression.mouthWidth * 1.22,
                    mouthHeight: speaking ? 2 + opening * 12 : 1,
                    mouthCurve: expression.smile, speakingOpening: opening, listeningLevel: listening,
                    eyes: expression.eyes, browLift: expression.browLift * 1.5, browAsymmetry: expression.browAsymmetry,
                    squash: expression.squash, bodyAccent: expression.accent, cheeks: expression.cheeks,
                    smileOpening: expression.smileOpening, teeth: expression.teeth, dimples: expression.dimples)
    }
}

private struct NativeSkinCharacter: View {
    var emotion: PetEmotion = .idle
    let phase: PetPhase
    let level: Double
    let still: Bool
    let skin: DotSkin
    let playbackLevel: Double?
    let motionDetail: SkinMotionDetail
    let expressionRevision: UInt64
    @State private var expressionClock = NativeExpressionClock()
    private var resolvedState: NativeFaceState {
        switch emotion {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking, .working: return .thinking
        case .speaking: return .speaking
        case .puzzled: return .blocked
        }
    }
    private var resetKey: NativeExpressionResetKey {
        .init(state: resolvedState, skin: skin, motion: motionDetail, still: still, revision: expressionRevision)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: phase == .speaking || phase == .listening || emotion == .working ? 1.0 / 24 : 1.0 / 12,
                                paused: still || motionDetail == .still)) { _ in
            let context = expressionClock.context(state: resolvedState, now: ProcessInfo.processInfo.systemUptime)
            NativeSkinFrame(phase: phase, skin: skin, pose: computePose(context: context))
        }
        // One combined key avoids advancing the recipe twice when a turn changes
        // phase and cancellation revision in the same SwiftUI transaction.
        .onChange(of: resetKey) { _, _ in resetExpression() }
        .onAppear { resetExpression() }
        .onDisappear { resetExpression() }
    }

    private func computePose(context: NativeExpressionContext) -> NativeFacePose {
        var pose = NativeFacePose.sample(phase: phase, context: context, inputLevel: level,
                                        playbackLevel: playbackLevel, still: still, motion: motionDetail)
        if emotion == .working {
            let scan = sin(context.elapsed * 3.5) * 0.4
            pose = NativeFacePose(bob: pose.bob, tilt: 1.0, blink: pose.blink, gazeX: scan, gazeY: -0.1,
                                  browTilt: pose.browTilt, mouthWidth: pose.mouthWidth, mouthHeight: pose.mouthHeight,
                                  mouthCurve: pose.mouthCurve, speakingOpening: pose.speakingOpening,
                                  listeningLevel: pose.listeningLevel, eyes: pose.eyes, browLift: pose.browLift,
                                  browAsymmetry: 0, squash: pose.squash, bodyAccent: pose.bodyAccent,
                                  cheeks: pose.cheeks, smileOpening: pose.smileOpening, teeth: pose.teeth, dimples: pose.dimples)
        } else if emotion == .puzzled {
            pose = NativeFacePose(bob: pose.bob, tilt: -7.5, blink: pose.blink, gazeX: -0.2, gazeY: 0.2,
                                  browTilt: pose.browTilt, mouthWidth: pose.mouthWidth * 0.8, mouthHeight: pose.mouthHeight,
                                  mouthCurve: -0.2, speakingOpening: 0, listeningLevel: 0, eyes: pose.eyes,
                                  browLift: pose.browLift, browAsymmetry: 0.4, squash: pose.squash, bodyAccent: pose.bodyAccent,
                                  cheeks: pose.cheeks, smileOpening: 0, teeth: 0, dimples: 0)
        }
        return pose
    }
    private func resetExpression() { expressionClock.restart(state: resolvedState, at: ProcessInfo.processInfo.systemUptime) }
}

private struct NativeExpressionResetKey: Equatable {
    let state: NativeFaceState
    let skin: DotSkin
    let motion: SkinMotionDetail
    let still: Bool
    let revision: UInt64
}

/// Actual runtime frame, also available to deterministic native render review.
/// It has no animation timer, audio access, model access or expression selector.
struct NativeSkinFrame: View {
    let phase: PetPhase
    let skin: DotSkin
    let pose: NativeFacePose
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        NativeSkinArtwork(phase: phase, skin: skin, pose: pose,
                          opaque: reduceTransparency, increasedContrast: contrast == .increased)
    }
}

/// Single artwork implementation with explicit accessibility policy. Native
/// snapshots exercise this same path without changing global OS preferences.
struct NativeSkinArtwork: View {
    let phase: PetPhase
    let skin: DotSkin
    let pose: NativeFacePose
    let opaque: Bool
    let increasedContrast: Bool

    var body: some View {
        let appearance = NativeSkinAppearance.forSkin(skin)
        ZStack {
                Ellipse().fill(.black.opacity(skin == .veil ? 0.035 : 0.09))
                    .frame(width: 75, height: 8).blur(radius: 4).offset(y: 60)
                ZStack {
                    NativeSkinBody(skin: skin, appearance: appearance, opaque: opaque,
                                   increasedContrast: increasedContrast, accent: pose.bodyAccent)
                    NativeFace(phase: phase, skin: skin, appearance: appearance, pose: pose,
                               opaque: opaque, increasedContrast: increasedContrast)
                        .offset(y: skin == .sprout || skin == .ripple ? 7 : skin == .mochi ? 6 : 0)
                }.scaleEffect(x: 1 / pose.squash, y: pose.squash)
                    .rotationEffect(.degrees(pose.tilt)).offset(y: pose.bob)
                if phase == .listening {
                    Circle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 123 + pose.listeningLevel * 4, height: 123 + pose.listeningLevel * 4)
                }
            }.frame(width: 132, height: 138)
    }
}

struct NativeSkinBody: View {
    let skin: DotSkin
    let appearance: NativeSkinAppearance
    let opaque: Bool
    let increasedContrast: Bool
    var accent: Double = 0
    private var shape: NativeBodyShape { NativeBodyShape(silhouette: appearance.silhouette) }
    private var gradient: RadialGradient {
        RadialGradient(colors: [appearance.light.color, appearance.shade.color], center: .topLeading, startRadius: 5, endRadius: 128)
    }
    var body: some View {
        ZStack {
            appendages
            if appearance.material == .glass && !opaque {
                // No WebView or opaque backing: Veil intentionally leaves the desktop visible.
                shape.fill(LinearGradient(colors: [.white.opacity(appearance.bodyOpacity * 2), appearance.shade.color.opacity(appearance.bodyOpacity)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if skin != .veil {
                    shape.fill(.ultraThinMaterial).opacity(0.17)
                }
                if increasedContrast {
                    // A two-tone rim survives either bright or dark content.
                    // Veil keeps its thinner contour and unchanged clearer body.
                    shape.stroke(.black.opacity(0.85), lineWidth: skin == .veil ? 3.4 : 4.2)
                    shape.stroke(.white, lineWidth: skin == .veil ? 1.4 : 2)
                } else {
                    shape.stroke(LinearGradient(colors: [.white.opacity(appearance.rimOpacity), .cyan.opacity(0.23), .purple.opacity(0.22), .white.opacity(appearance.rimOpacity)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: skin == .veil ? 1 : 1.6)
                }
            } else {
                shape.fill(gradient)
                shape.stroke(.white.opacity(increasedContrast ? 0.9 : 0.55), lineWidth: increasedContrast ? 2 : 1)
            }
            bodyDetail
        }.frame(width: 110, height: 114)
    }
    @ViewBuilder private var appendages: some View {
        if skin == .mochi || skin == .pip {
            HStack(spacing: skin == .pip ? 22 : 28) {
                ForEach(0..<2) { _ in
                    Ellipse().fill(skin == .pip ? Color.orange.opacity(0.9) : appearance.shade.color)
                        .frame(width: skin == .pip ? 16 : 22, height: 10)
                }
            }.rotationEffect(.degrees(accent * 3)).offset(y: 51)
        }
        if skin == .pip {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Ellipse().fill(gradient).frame(width: 22, height: 49)
                    .rotationEffect(.degrees(side * (-22 + accent * 8))).offset(x: side * 46, y: 15)
            }
        }
        if skin == .sprout {
            ForEach([-1.0, 1.0], id: \.self) { side in
                NativeBodyShape(silhouette: .leaf).fill(gradient).frame(width: 25, height: 53)
                    .rotationEffect(.degrees(side * (58 + accent * 9))).offset(x: side * 36, y: 30)
            }
            Capsule().fill(appearance.shade.color).frame(width: 7, height: 21).rotationEffect(.degrees(12)).offset(y: 51)
        }
    }
    @ViewBuilder private var bodyDetail: some View {
        if skin == .pip {
            Ellipse().fill(RadialGradient(colors: [.init(red: 1, green: 0.98, blue: 0.88), .init(red: 0.85, green: 0.86, blue: 0.73)], center: .top, startRadius: 3, endRadius: 92))
                .frame(width: 74, height: 88).offset(y: 7)
            Capsule().fill(appearance.shade.color).frame(width: 5, height: 17).rotationEffect(.degrees(25 + accent * 10)).offset(x: 2, y: -51)
        } else if skin == .mochi {
            // One inexpensive static texture layer. No timers per strand or appendage.
            Canvas { context, size in
                for row in 0..<11 { for col in 0..<12 {
                    let x = Double(col) * 9 + (row % 2 == 0 ? 0 : 4)
                    let y = Double(row) * 9 + 5
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.brown.opacity(0.16)))
                } }
            }.clipShape(shape)
        } else if skin == .nova {
            RoundedRectangle(cornerRadius: 33).fill(Color(red: 0.015, green: 0.027, blue: 0.055))
                .overlay(RoundedRectangle(cornerRadius: 33).stroke(.white.opacity(0.2), lineWidth: 1))
                .frame(width: 91, height: 82).offset(y: -1)
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule().fill(side < 0 ? Color.cyan : .purple).frame(width: 2, height: 23)
                    .opacity(0.8 + side * accent * 0.2).offset(x: side * 49)
            }
        } else if skin == .halo {
            ForEach(0..<3) { index in
                Circle().trim(from: 0.02 + Double(index) * 0.07, to: 0.52 + Double(index) * 0.07)
                    .stroke(LinearGradient(colors: [.white.opacity(0.8), .cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 96 - Double(index) * 7, height: 96 - Double(index) * 7)
                    .rotationEffect(.degrees(Double(index) * 117 + accent * 12))
            }
        } else if skin == .sprout {
            Path { path in
                path.move(to: CGPoint(x: 52, y: 108))
                path.addQuadCurve(to: CGPoint(x: 89, y: 4), control: CGPoint(x: 48, y: 31))
            }.stroke(.white.opacity(0.28), lineWidth: 1)
        } else {
            Ellipse().fill(.white.opacity(skin == .veil ? 0.25 : 0.48))
                .frame(width: skin == .veil ? 4 : 9, height: 25)
                .rotationEffect(.degrees(35 + accent * 5)).offset(x: (skin == .ripple ? -2 : -32) + accent * 2, y: -32)
        }
    }
}

private struct NativeFace: View {
    let phase: PetPhase
    let skin: DotSkin
    let appearance: NativeSkinAppearance
    let pose: NativeFacePose
    let opaque: Bool
    let increasedContrast: Bool
    private var ink: Color { appearance.ink.color }
    private var edge: Double { appearance.facialOutlineWidth(opaque: opaque, increasedContrast: increasedContrast) }
    var body: some View {
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                NativeFacialShape(shape: NativeMouth(curve: -2), ink: ink.opacity(edge > 0 ? 1 : 0.75), edge: edge, strokeWidth: 1.7)
                    .frame(width: 12, height: 3)
                    .rotationEffect(.degrees(side * -pose.browTilt + (side > 0 ? pose.browAsymmetry : 0)))
                    .offset(x: side * appearance.eyeSpacing / 2, y: -24 + pose.browLift)
                NativeFacialShape(shape: Ellipse(), ink: ink, edge: edge)
                    .overlay(alignment: .topLeading) {
                        Ellipse().fill(.white.opacity(0.88)).frame(width: 2.8, height: 4).padding(2)
                    }
                    .frame(width: appearance.eyeWidth, height: appearance.eyeHeight * pose.eyes)
                    .scaleEffect(x: 1, y: pose.blink)
                    .offset(x: side * appearance.eyeSpacing / 2 + pose.gazeX, y: -9 + pose.gazeY)
                if skin != .veil && skin != .nova {
                    Ellipse().fill(Color.pink.opacity(pose.cheeks)).frame(width: 13, height: 6).blur(radius: 2)
                        .offset(x: side * 27, y: 7)
                }
                Circle().fill(ink.opacity(pose.dimples * 0.45)).frame(width: 1.6, height: 1.6)
                    .offset(x: side * (pose.mouthWidth / 2 + 2.5), y: 12)
            }
            if skin == .pip {
                RoundedRectangle(cornerRadius: 4).fill(Color.orange)
                    .overlay {
                        if phase == .speaking {
                            Ellipse().fill(Color.brown).frame(width: pose.mouthWidth * 0.8, height: max(1, pose.mouthHeight - 1))
                        } else {
                            NativeMouth(curve: pose.mouthCurve * 0.6).stroke(Color.brown, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 8, height: 3)
                        }
                    }
                    .frame(width: max(12, pose.mouthWidth), height: max(8, pose.mouthHeight + 3)).offset(y: 11)
            } else if phase == .speaking {
                NativeFacialShape(shape: Ellipse(), ink: ink, edge: edge).frame(width: pose.mouthWidth, height: pose.mouthHeight)
                    .overlay(alignment: .bottom) {
                        if pose.speakingOpening > 0.25 {
                            Ellipse().fill(Color(red: 0.94, green: 0.60, blue: 0.65))
                                .frame(width: pose.mouthWidth * 0.55, height: 2).padding(.bottom, 1)
                        }
                        if pose.teeth > 0 && pose.speakingOpening > 0.15 {
                            Capsule().fill(.white.opacity(pose.teeth)).frame(width: pose.mouthWidth * 0.6, height: 1.6)
                                .offset(y: -pose.mouthHeight / 2 + 2)
                        }
                    }.offset(y: 12)
                NativeFacialShape(shape: NativeMouth(curve: pose.mouthCurve * 0.7), ink: ink, edge: edge, strokeWidth: 1.5)
                    .frame(width: pose.mouthWidth + 3, height: 4).offset(y: 11)
            } else if pose.smileOpening > 0.1 {
                NativeFacialShape(shape: NativeSmileOpening(), ink: ink, edge: edge).frame(width: pose.mouthWidth, height: pose.smileOpening + 2)
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(pose.teeth)).frame(width: pose.mouthWidth * 0.65, height: 1.7).padding(.top, 0.7)
                    }.offset(y: 13)
            } else {
                NativeFacialShape(shape: NativeMouth(curve: pose.mouthCurve), ink: ink, edge: edge, strokeWidth: 1.8)
                    .frame(width: pose.mouthWidth, height: 5).offset(y: 12)
            }
        }
    }
}

/// A crisp two-tone contour remains legible over both extremes without an opaque
/// face plate. The thin edge surrounds features only; Veil's body stays clear.
private struct NativeFacialShape<Contour: Shape>: View {
    let shape: Contour
    let ink: Color
    let edge: Double
    var strokeWidth: Double? = nil
    var body: some View {
        ZStack {
            if edge > 0 {
                shape.stroke(.white, style: StrokeStyle(lineWidth: (strokeWidth ?? 0) + edge * 2, lineCap: .round))
            }
            if let strokeWidth {
                shape.stroke(ink, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            } else {
                shape.fill(ink)
            }
        }
    }
}

private struct NativeSmileOpening: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.15))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.15), control: CGPoint(x: rect.midX, y: -rect.height * 0.1))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height * 0.15), control: CGPoint(x: rect.midX, y: rect.height * 1.7))
        path.closeSubpath()
        return path
    }
}

private struct NativeMouth: Shape {
    let curve: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.midY + curve))
        return path
    }
}

struct NativeBodyShape: Shape {
    let silhouette: NativeSkinSilhouette
    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        switch silhouette {
        case .circle, .bubble, .lens, .orb:
            path.addEllipse(in: rect.insetBy(dx: 1, dy: 3))
        case .pebble:
            path.move(to: p(0.05, 0.70))
            path.addCurve(to: p(0.50, 0.13), control1: p(-0.02, 0.28), control2: p(0.21, 0.12))
            path.addCurve(to: p(0.95, 0.70), control1: p(0.82, 0.12), control2: p(1.02, 0.30))
            path.addCurve(to: p(0.05, 0.70), control1: p(0.94, 1.05), control2: p(0.06, 1.05))
        case .bird:
            path.move(to: p(0.50, 0.01))
            path.addCurve(to: p(0.93, 0.65), control1: p(0.90, -0.01), control2: p(0.91, 0.35))
            path.addCurve(to: p(0.07, 0.65), control1: p(0.98, 1.06), control2: p(0.02, 1.06))
            path.addCurve(to: p(0.50, 0.01), control1: p(0.09, 0.35), control2: p(0.10, -0.01))
        case .cloud:
            path.move(to: p(0.10, 0.81))
            path.addCurve(to: p(0.20, 0.32), control1: p(-0.13, 0.68), control2: p(0.02, 0.32))
            path.addCurve(to: p(0.76, 0.26), control1: p(0.15, -0.02), control2: p(0.77, -0.09))
            path.addCurve(to: p(0.89, 0.82), control1: p(1.07, 0.25), control2: p(1.09, 0.75))
            path.addCurve(to: p(0.10, 0.81), control1: p(0.81, 1.04), control2: p(0.27, 1.05))
        case .droplet:
            path.move(to: p(0.51, 0.01))
            path.addCurve(to: p(0.70, 0.48), control1: p(0.83, 0.02), control2: p(0.57, 0.28))
            path.addCurve(to: p(0.79, 0.90), control1: p(1.24, 0.62), control2: p(0.98, 1.05))
            path.addCurve(to: p(0.28, 0.91), control1: p(0.49, 0.66), control2: p(0.61, 1.17))
            path.addCurve(to: p(0.34, 0.47), control1: p(-0.11, 0.99), control2: p(-0.09, 0.56))
            path.addCurve(to: p(0.51, 0.01), control1: p(0.56, 0.38), control2: p(0.21, 0.00))
        case .leaf:
            path.move(to: p(0.81, 0.01))
            path.addCurve(to: p(0.47, 0.99), control1: p(0.75, 0.31), control2: p(1.15, 0.71))
            path.addCurve(to: p(0.81, 0.01), control1: p(-0.17, 0.68), control2: p(0.19, 0.18))
        case .visor:
            path.addRoundedRect(in: rect.insetBy(dx: 0, dy: 7), cornerSize: CGSize(width: 40, height: 40))
        }
        path.closeSubpath()
        return path
    }
}

/// Slim progress halo for long tasks exceeding two minutes (LP01-LP07).
struct LongTaskHaloView: View {
    let halo: LongTaskProgress.Halo
    let stageText: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch halo {
            case .hidden:
                EmptyView()
            case .indeterminate:
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 2)
                    .frame(width: 116, height: 116)
                Circle()
                    .trim(from: 0.0, to: 0.25)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 116, height: 116)
                    .rotationEffect(.degrees(reduceMotion ? 0 : 360))
                    .animation(reduceMotion ? nil : .linear(duration: 2).repeatForever(autoreverses: false), value: reduceMotion)
            case .determinate(let fraction):
                Circle()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 2)
                    .frame(width: 116, height: 116)
                Circle()
                    .trim(from: 0.0, to: CGFloat(min(1.0, max(0.0, fraction))))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 116, height: 116)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            case .verifiedComplete:
                Circle()
                    .strokeBorder(Color.green, lineWidth: 2.5)
                    .frame(width: 116, height: 116)
                    .animation(.spring(), value: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stageText ?? "Task progress")
    }
}

