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
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
}
