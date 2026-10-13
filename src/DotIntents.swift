import AppIntents
import Foundation

enum DotIntentAction: CaseIterable, Sendable {
    case talk, stop, show
}

enum DotIntentError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        "dot is not ready for this action. Open dot and try again."
    }
}

/// A thin bridge to the existing app owner. Registration never starts capture,
/// requests permission or creates a second audio/model coordinator.
@MainActor
final class DotIntentRouter {
    static let shared = DotIntentRouter()
    typealias Handler = @MainActor () throws -> Void

    private var handlers: [DotIntentAction: Handler] = [:]

    func configure(talk: @escaping Handler, stop: @escaping Handler, show: @escaping Handler) {
        handlers = [.talk: talk, .stop: stop, .show: show]
    }

    func clear() { handlers.removeAll() }

    func perform(_ action: DotIntentAction) throws {
        guard let handler = handlers[action] else { throw DotIntentError.unavailable }
        try handler()
    }
}

/// Explicit invocation enters the same foreground/manual path as the Talk button.
/// It does not authorize automatic capture or substitute Siri's model or voice.
struct TalkToDotIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to dot"
    static let description = IntentDescription("Open dot and start a conversation using dot's local voice pipeline.")
    static let openAppWhenRun = true
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        try DotIntentRouter.shared.perform(.talk)
        return .result()
    }
}

struct StopDotIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop dot"
    static let description = IntentDescription("Stop dot's current listening, response and automatic reply invitation.")
    static let openAppWhenRun = true
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        try DotIntentRouter.shared.perform(.stop)
        return .result()
    }
}

struct ShowDotIntent: AppIntent {
    static let title: LocalizedStringResource = "Show dot"
    static let description = IntentDescription("Bring dot's companion into view without starting the microphone.")
    static let openAppWhenRun = true
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        try DotIntentRouter.shared.perform(.show)
        return .result()
    }
}

struct DotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToDotIntent(), phrases: ["Talk to \(.applicationName)"],
                    shortTitle: "Talk to dot", systemImageName: "mic")
        AppShortcut(intent: StopDotIntent(), phrases: ["Stop \(.applicationName)"],
                    shortTitle: "Stop dot", systemImageName: "stop.fill")
        AppShortcut(intent: ShowDotIntent(), phrases: ["Show \(.applicationName)"],
                    shortTitle: "Show dot", systemImageName: "eye")
    }
}
