import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case system, user, assistant }
    let id = UUID()
    var role: Role
    var content: String
    /// Qwen3.8 thinking text (rendered dimmed/collapsible, never counted as answer).
    var thinking: String = ""
    var isStreaming: Bool = false
}

enum EnginePhase: Equatable {
    case idle
    case checking
    case downloading(Double)      // 0.0...1.0
    case starting
    case ready
    case failed(String)
}

/// Where the model is being served from.
enum EngineSource: Equatable {
    case llamaServer        // our supervised llama-server (bundled with LM Studio)
    case external(String)   // user-provided OpenAI-compatible URL (e.g. Bionic + Splash)
}
