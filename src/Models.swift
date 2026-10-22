import Foundation

enum PetPhase: Equatable {
    case idle, listening, thinking, speaking, blocked(String)
    var caption: String {
        switch self {
        case .idle: return "Click to talk"
        case .listening: return "I'm listening"
        case .thinking: return "One little moment…"
        case .speaking: return "Click to interrupt"
        case .blocked(let message): return message
        }
    }
    var isActive: Bool {
        switch self { case .listening, .thinking, .speaking: return true; default: return false }
    }
    /// R19: an error never changes how Dot lives. Idle and blocked both roam, move
    /// and look normal; the error is shown as text above Dot instead.
    var isResting: Bool {
        switch self { case .idle, .blocked: return true; default: return false }
    }
    var blockedMessage: String? {
        if case .blocked(let message) = self { return message }
        return nil
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
}
