import Foundation
import OSLog

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
    private var waitingReason: String?
    private static let log = Logger(subsystem: "app.dot", category: "timing")
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
        Self.log.notice("DOT_FOLLOWUP event=generation_finished has_question=\(hasQuestion)")
    }
    func playbackFinished(turn: UUID) {
        guard self.turn == turn, let question, playedAt == nil else { return }
        Self.log.notice("DOT_FOLLOWUP event=playback_finished")
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
        let now = clock()
        let elapsed = now - playedAt
        guard elapsed.isFinite, elapsed <= QuestionReplyGate.invitationLifetimeSeconds else {
            cancelInvitation(reason: "expired"); return
        }
        guard elapsed >= QuestionReplyGate.playbackSettleSeconds else {
            noteWaiting("settling"); retryAfter(QuestionReplyGate.playbackSettleSeconds - elapsed); return
        }
        // Invite-accept preconditions run before the gate is touched: a failing
        // environment defers the invitation without consuming the reply, so the
        // gate is consumed only when the invitation is genuinely armed. The same
        // `now` that validated the lifetime here is handed to the gate, so its
        // internal lifetime check can never disagree with this poll's.
        let value = environment()
        guard value.microphoneAuthorized else { cancelInvitation(reason: "microphone"); return }
        guard value.screenAuthorized else { cancelInvitation(reason: "screen"); return }
        guard value.ready, !value.interacting else {
            noteWaiting(value.ready ? "interacting" : "not_ready")
            retryAfter(0.2)
            return
        }
        guard let continuation = policy.consume(turn: turn, now: now, ready: value.ready,
            microphoneAuthorized: value.microphoneAuthorized, screenAuthorized: value.screenAuthorized,
            interacting: value.interacting) else {
            // A transient case was handled above; anything here is a hard
            // revocation, an exhausted chain or a missing question.
            cancelInvitation(reason: "policy")
            return
        }
        waitingReason = nil
        question = nil; self.turn = nil; pending = false
        Self.log.notice("DOT_FOLLOWUP event=invited")
        onInvite?(turn, continuation)
    }
    private func retryAfter(_ seconds: Double) {
        guard automaticScheduling, task == nil else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.poll()
        }
    }
    private func noteWaiting(_ reason: String) {
        guard waitingReason != reason else { return }
        waitingReason = reason
        Self.log.notice("DOT_FOLLOWUP event=deferred reason=\(reason, privacy: .public)")
    }
    private func cancelInvitation(reason: String) {
        Self.log.notice("DOT_FOLLOWUP event=cancelled reason=\(reason, privacy: .public)")
        waitingReason = nil
        cancel()
    }
    func cancel() {
        task?.cancel(); task = nil; policy.cancel()
        waitingReason = nil
        turn = nil; question = nil; pending = false; generationEnded = false; playedAt = nil
    }
}
