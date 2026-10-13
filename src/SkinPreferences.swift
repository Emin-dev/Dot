import Combine
import Foundation

/// Stable identifiers are stored locally. Prototype selections never change this default.
enum DotSkin: String, CaseIterable, Identifiable {
    case original, pearl, mochi, cloudlet, pip, dew, ripple, sprout, veil, halo, nova
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum SkinMotionDetail: String, CaseIterable, Identifiable {
    case full, subtle, still
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var movementScale: Double {
        switch self { case .full: return 1; case .subtle: return 0.35; case .still: return 0 }
    }
}

@MainActor
final class SkinPreferences: ObservableObject {
    static let selectionKey = "dot.appearance.skin.v1"
    static let motionKey = "dot.appearance.motion.v1"
    private let defaults: UserDefaults
    @Published var selected: DotSkin { didSet { defaults.set(selected.rawValue, forKey: Self.selectionKey) } }
    @Published var motionDetail: SkinMotionDetail { didSet { defaults.set(motionDetail.rawValue, forKey: Self.motionKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.selectionKey).flatMap(DotSkin.init(rawValue:)) ?? .original
        motionDetail = defaults.string(forKey: Self.motionKey).flatMap(SkinMotionDetail.init(rawValue:)) ?? .full
    }
}
