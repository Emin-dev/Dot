import SwiftUI

struct PetCharacter: View {
    let phase: PetPhase
    let level: Double
    let still: Bool
    var skin: DotSkin = .original
    var playbackLevel: Double? = nil
    var motionDetail: SkinMotionDetail = .full
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if skin == .original {
                OriginalPetCharacter(phase: phase, level: level, still: still || reduceMotion || motionDetail == .still,
                                     motionScale: motionDetail.movementScale)
            } else {
                NativeSkinCharacter(phase: phase, level: level, still: still || reduceMotion,
                                    skin: skin, playbackLevel: playbackLevel, motionDetail: motionDetail)
            }
        }.accessibilityHidden(true)
    }
}

// The original is kept as the default, retaining the existing shape and appearance.
private struct OriginalPetCharacter: View {
    let phase: PetPhase
    let level: Double
    let still: Bool
    let motionScale: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private var ink: Color { colorScheme == .dark ? Color(red: 0.08, green: 0.13, blue: 0.17) : Color(red: 0.22, green: 0.36, blue: 0.41) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still || phase == .listening)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let bob = still || phase.isActive ? 0.0 : sin(time * 1.4) * 3 * motionScale
            ZStack {
                Ellipse().fill(.black.opacity(0.10)).frame(width: 75, height: 10).blur(radius: 4).offset(y: 62)
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
                    HStack(spacing: 22) { eye(time: time); eye(time: time) }.offset(y: -4)
                    if phase == .speaking {
                        Ellipse().fill(ink)
                            .frame(width: 8, height: still ? 6 : 4 + 4 * abs(sin(time * 7)) * motionScale).offset(y: 12)
                    } else {
                        Smile().stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 9, height: 5).offset(y: 12)
                    }
                    if phase == .listening {
                        Circle().stroke(Color(red: 0.56, green: 0.68, blue: 0.87).opacity(0.55), lineWidth: 1.5)
                            .frame(width: 121 + (still ? 0 : min(level, 0.4) * 12), height: 121 + (still ? 0 : min(level, 0.4) * 12))
                    }
                    if phase == .thinking {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { index in
                                Circle().fill(ink).frame(width: 3, height: 3)
                                    .opacity(still ? 1 : 0.35 + 0.65 * abs(sin(time * 2 + Double(index))))
                            }
                        }.offset(y: 34)
                    }
                }.offset(y: bob)
            }
        }
    }
    private func eye(time: TimeInterval) -> some View {
        let closed = !still && time.truncatingRemainder(dividingBy: 5) < 0.16
        return Capsule().fill(ink).frame(width: 6, height: closed ? 2 : 11)
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
        material == .glass && darkAppearance && !opaque ? .init(red: 0.87, green: 0.97, blue: 1) : ink
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

enum NativeFaceState: CaseIterable {
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

/// These five authored state recipes are the first native slice, not the planned
/// 120 reviewed expression/animation recipes per skin. No synthetic phoneme timing.
struct NativeExpressionRecipe: Equatable {
    let id: String
    let state: NativeFaceState
    let cycleSeconds: Double
    let browTilt: Double
    let gazeX: Double
    let gazeY: Double
    let mouthCurve: Double
    var trigger: String { "Enter \(state)" }
    var compatibleStates: [NativeFaceState] { [state] }
    let cancellation = "Immediately replaced on phase, skin, motion preference or accessibility change"

    static let initialRecipes: [Self] = [
        .init(id: "quiet-breath", state: .idle, cycleSeconds: 4.8, browTilt: -3, gazeX: 0, gazeY: 0, mouthCurve: 4),
        .init(id: "attentive-listen", state: .listening, cycleSeconds: 5.4, browTilt: -10, gazeX: 0, gazeY: -1, mouthCurve: 2),
        .init(id: "considering", state: .thinking, cycleSeconds: 5.0, browTilt: -7, gazeX: 2, gazeY: -2, mouthCurve: 2.5),
        .init(id: "audible-response", state: .speaking, cycleSeconds: 4.6, browTilt: -4, gazeX: 0, gazeY: 0, mouthCurve: 3),
        .init(id: "patient-support", state: .blocked, cycleSeconds: 6.0, browTilt: -6, gazeX: 0, gazeY: 1, mouthCurve: 2.5)
    ]
    static func forState(_ state: NativeFaceState) -> Self { initialRecipes.first { $0.state == state }! }
}

struct NativeFacePose: Equatable {
    let bob: Double, tilt: Double, blink: Double, gazeX: Double, gazeY: Double
    let browTilt: Double, mouthWidth: Double, mouthHeight: Double, mouthCurve: Double
    let speakingOpening: Double, listeningLevel: Double

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

    /// Stateless sampling means an old state has no timer/task that can animate a replacement turn.
    /// playbackLevel is optional: absent a real audio envelope, use a static speaking pose.
    static func sample(phase: PetPhase, time: TimeInterval, inputLevel: Double, playbackLevel: Double?,
                       still: Bool, motion: SkinMotionDetail = .full) -> Self {
        let state = NativeFaceState(phase), recipe = NativeExpressionRecipe.forState(state)
        let amount = still ? 0 : motion.movementScale
        let clock = time.isFinite ? max(0, time) : 0
        let cycle = clock.truncatingRemainder(dividingBy: recipe.cycleSeconds)
        let blink = amount > 0 && cycle < 0.13 ? 0.15 : 1.0
        let speaking = state == .speaking
        let opening = speaking ? (amount == 0 ? 0.12 : playbackLevel.map(unit) ?? 0.12) : 0
        let listening = state == .listening && amount > 0 ? unit(inputLevel) : 0
        return Self(bob: amount * sin(clock * 1.25) * (state == .idle ? 1.3 : 0.25),
                    tilt: amount * sin(clock * 0.65) * (state == .listening ? 1.0 : 0.5),
                    blink: blink, gazeX: recipe.gazeX + amount * sin(clock * 0.48) * 0.7,
                    gazeY: recipe.gazeY, browTilt: recipe.browTilt,
                    mouthWidth: speaking ? 7 + opening * 8 : 9,
                    mouthHeight: speaking ? 2 + opening * 12 : 1,
                    mouthCurve: recipe.mouthCurve, speakingOpening: opening, listeningLevel: listening)
    }
}

private struct NativeSkinCharacter: View {
    let phase: PetPhase
    let level: Double
    let still: Bool
    let skin: DotSkin
    let playbackLevel: Double?
    let motionDetail: SkinMotionDetail
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let appearance = NativeSkinAppearance.forSkin(skin)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: still || motionDetail == .still)) { context in
            let pose = NativeFacePose.sample(phase: phase, time: context.date.timeIntervalSinceReferenceDate,
                                            inputLevel: level, playbackLevel: playbackLevel, still: still, motion: motionDetail)
            ZStack {
                Ellipse().fill(.black.opacity(skin == .veil ? 0.035 : 0.09))
                    .frame(width: 75, height: 8).blur(radius: 4).offset(y: 60)
                ZStack {
                    NativeSkinBody(skin: skin, appearance: appearance, opaque: reduceTransparency,
                                   increasedContrast: contrast == .increased)
                    NativeFace(phase: phase, skin: skin, appearance: appearance, pose: pose)
                        .offset(y: skin == .sprout || skin == .ripple ? 7 : skin == .mochi ? 6 : 0)
                }.rotationEffect(.degrees(pose.tilt)).offset(y: pose.bob)
                if phase == .listening {
                    Circle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 123 + pose.listeningLevel * 4, height: 123 + pose.listeningLevel * 4)
                }
                if phase == .thinking {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { _ in Circle().fill(Color.primary).frame(width: 3, height: 3) }
                    }.padding(4).background(.regularMaterial, in: Capsule()).offset(y: 44)
                }
            }.frame(width: 132, height: 138)
        }
    }
}

struct NativeSkinBody: View {
    let skin: DotSkin
    let appearance: NativeSkinAppearance
    let opaque: Bool
    let increasedContrast: Bool
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
                shape.stroke(LinearGradient(colors: [.white.opacity(appearance.rimOpacity), .cyan.opacity(0.23), .purple.opacity(0.22), .white.opacity(appearance.rimOpacity)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: skin == .veil ? 1 : 1.6)
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
            }.offset(y: 51)
        }
        if skin == .pip {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Ellipse().fill(gradient).frame(width: 22, height: 49)
                    .rotationEffect(.degrees(side * -22)).offset(x: side * 46, y: 15)
            }
        }
        if skin == .sprout {
            ForEach([-1.0, 1.0], id: \.self) { side in
                NativeBodyShape(silhouette: .leaf).fill(gradient).frame(width: 25, height: 53)
                    .rotationEffect(.degrees(side * 58)).offset(x: side * 36, y: 30)
            }
            Capsule().fill(appearance.shade.color).frame(width: 7, height: 21).rotationEffect(.degrees(12)).offset(y: 51)
        }
    }
    @ViewBuilder private var bodyDetail: some View {
        if skin == .pip {
            Ellipse().fill(RadialGradient(colors: [.init(red: 1, green: 0.98, blue: 0.88), .init(red: 0.85, green: 0.86, blue: 0.73)], center: .top, startRadius: 3, endRadius: 92))
                .frame(width: 74, height: 88).offset(y: 7)
            Capsule().fill(appearance.shade.color).frame(width: 5, height: 17).rotationEffect(.degrees(25)).offset(x: 2, y: -51)
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
                Capsule().fill(side < 0 ? Color.cyan : .purple).frame(width: 2, height: 23).offset(x: side * 49)
            }
        } else if skin == .halo {
            ForEach(0..<3) { index in
                Circle().trim(from: 0.02 + Double(index) * 0.07, to: 0.52 + Double(index) * 0.07)
                    .stroke(LinearGradient(colors: [.white.opacity(0.8), .cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 96 - Double(index) * 7, height: 96 - Double(index) * 7)
                    .rotationEffect(.degrees(Double(index) * 117))
            }
        } else if skin == .sprout {
            Path { path in
                path.move(to: CGPoint(x: 52, y: 108))
                path.addQuadCurve(to: CGPoint(x: 89, y: 4), control: CGPoint(x: 48, y: 31))
            }.stroke(.white.opacity(0.28), lineWidth: 1)
        } else {
            Ellipse().fill(.white.opacity(skin == .veil ? 0.25 : 0.48))
                .frame(width: skin == .veil ? 4 : 9, height: 25)
                .rotationEffect(.degrees(35)).offset(x: skin == .ripple ? -2 : -32, y: -32)
        }
    }
}

private struct NativeFace: View {
    let phase: PetPhase
    let skin: DotSkin
    let appearance: NativeSkinAppearance
    let pose: NativeFacePose
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var ink: Color { appearance.facialInk(darkAppearance: colorScheme == .dark, opaque: reduceTransparency).color }
    private var outline: Color {
        guard appearance.material == .glass && !reduceTransparency else { return .clear }
        return colorScheme == .dark ? .black.opacity(0.75) : .white.opacity(0.85)
    }
    var body: some View {
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                NativeMouth(curve: -2).stroke(ink.opacity(0.75), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    .frame(width: 12, height: 3)
                    .rotationEffect(.degrees(side * -pose.browTilt))
                    .offset(x: side * appearance.eyeSpacing / 2, y: -24)
                Ellipse().fill(ink)
                    .overlay(alignment: .topLeading) {
                        Ellipse().fill(.white.opacity(0.88)).frame(width: 2.8, height: 4).padding(2)
                    }
                    .frame(width: appearance.eyeWidth, height: appearance.eyeHeight)
                    .scaleEffect(x: 1, y: pose.blink)
                    .offset(x: side * appearance.eyeSpacing / 2 + pose.gazeX, y: -9 + pose.gazeY)
                if skin != .veil && skin != .nova {
                    Ellipse().fill(Color.pink.opacity(0.16)).frame(width: 13, height: 6).blur(radius: 2)
                        .offset(x: side * 27, y: 7)
                }
            }
            if skin == .pip {
                RoundedRectangle(cornerRadius: 4).fill(Color.orange)
                    .overlay {
                        if phase == .speaking {
                            Ellipse().fill(Color.brown).frame(width: pose.mouthWidth * 0.8, height: max(1, pose.mouthHeight - 1))
                        } else {
                            NativeMouth(curve: 2.5).stroke(Color.brown, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: 8, height: 3)
                        }
                    }
                    .frame(width: max(12, pose.mouthWidth), height: max(8, pose.mouthHeight + 3)).offset(y: 11)
            } else if phase == .speaking {
                Ellipse().fill(ink).frame(width: pose.mouthWidth, height: pose.mouthHeight)
                    .overlay(alignment: .bottom) {
                        if pose.speakingOpening > 0.25 {
                            Ellipse().fill(Color(red: 0.94, green: 0.60, blue: 0.65))
                                .frame(width: pose.mouthWidth * 0.55, height: 2).padding(.bottom, 1)
                        }
                    }.offset(y: 12)
                NativeMouth(curve: 3).stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: pose.mouthWidth + 3, height: 4).offset(y: 11)
            } else {
                NativeMouth(curve: pose.mouthCurve).stroke(ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: pose.mouthWidth, height: 5).offset(y: 12)
            }
        }.shadow(color: outline, radius: 0.7)
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
