import Foundation

/// Connects successful generation and final playback to one revocable invitation.
/// Audio capture owns the separate, user-selected time to begin speaking.
@MainActor
final class VoiceFollowup {
    struct Environment {
        var ready: Bool
        var microphoneAuthorized: Bool
        var screenAuthorized: Bool
        var interacting: Bool
    }
    var environment: () -> Environment = { .init(ready: false, microphoneAuthorized: false, screenAuthorized: false, interacting: true) }
    var onInvite: ((UUID, UUID) -> Void)?
    private let clock: () -> Double
    private let automaticScheduling: Bool
    private var policy = QuestionReplyGate()
    private var turn: UUID?
    private var question: UUID?
    private var generationEnded = false
    private var playedAt: Double?
    private var task: Task<Void, Never>?
    private(set) var pending = false

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, automaticScheduling: Bool = true) {
        self.clock = clock; self.automaticScheduling = automaticScheduling
    }
    func begin(turn: UUID, continuation: UUID? = nil) {
        task?.cancel(); task = nil
        self.turn = turn; question = nil; pending = false; generationEnded = false; playedAt = nil
        policy.begin(turn: turn, explicitClick: continuation == nil, continuation: continuation, now: clock())
    }
    func generationFinished(turn: UUID, hasQuestion: Bool) {
        guard self.turn == turn, !generationEnded else { return }
        generationEnded = true
        let question = hasQuestion ? UUID() : nil
        self.question = question; pending = hasQuestion
        policy.responseFinished(turn: turn, question: question, succeeded: true)
    }
    func playbackFinished(turn: UUID) {
        guard self.turn == turn, let question, playedAt == nil else { return }
        playedAt = clock()
        policy.questionPlayed(turn: turn, question: question, now: playedAt!)
        guard automaticScheduling else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(QuestionReplyGate.playbackSettleSeconds * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, self.turn == turn else { return }
            self.task = nil; self.poll()
        }
    }
    /// Also used by deterministic tests; all deadlines use the monotonic clock.
    func poll() {
        guard let turn, question != nil, let playedAt else { return }
        guard clock() - playedAt <= QuestionReplyGate.invitationLifetimeSeconds else { cancel(); return }
        let value = environment()
        guard value.ready, value.microphoneAuthorized, value.screenAuthorized, !value.interacting else { cancel(); return }
        guard clock() - playedAt >= QuestionReplyGate.playbackSettleSeconds else { return }
        guard let continuation = policy.consume(turn: turn, now: clock(), ready: value.ready,
            microphoneAuthorized: value.microphoneAuthorized, screenAuthorized: value.screenAuthorized,
            interacting: value.interacting) else { cancel(); return }
        question = nil; self.turn = nil; pending = false
        onInvite?(turn, continuation)
    }
    func cancel() {
        task?.cancel(); task = nil; policy.cancel()
        turn = nil; question = nil; pending = false; generationEnded = false; playedAt = nil
    }
}
