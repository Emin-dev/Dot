import Foundation

/// A bounded, platform-neutral model for ONE selected task. The owner serializes
/// access, supplies factual work/estimate/verification evidence, and connects the
/// returned presentation to its existing halo, accessibility and voice pipeline.
/// This type neither performs work nor starts audio, animation or microphone capture.
struct LongTaskProgress: Sendable {
    static let longTaskSeconds = 120.0
    static let minimumSpeechSpacing = 15.0
    static let maximumUnits = 1_000_000
    static let maximumTextLength = 240

    enum Kind: Equatable, Sendable { case work, shortQuestion }
    enum Phase: Equatable, Sendable { case working, finalVerification }
    enum Checkpoint: Int, Equatable, Sendable {
        case start = 0, halfway = 50, mostWorkFinished = 80, finalVerification = 95
    }
    enum SpeechReason: Equatable, Sendable { case checkpoint(Checkpoint), planRevised }
    enum Halo: Equatable, Sendable { case hidden, indeterminate, determinate(Double), verifiedComplete }

    /// Tokens are deliberately regenerated on replacement/restart, plan revision
    /// and resume. Callbacks must carry the exact token that started their work.
    struct Token: Equatable, Sendable {
        let taskID: UUID
        let runID: UUID
        let planID: UUID
    }

    struct EstimateRange: Equatable, Sendable {
        let lowerSeconds: Int
        let upperSeconds: Int
        init?(lowerSeconds: Int, upperSeconds: Int) {
            guard lowerSeconds > 0, upperSeconds >= lowerSeconds,
                  upperSeconds <= 31 * 24 * 60 * 60 else { return nil }
            self.lowerSeconds = lowerSeconds; self.upperSeconds = upperSeconds
        }
    }
    enum Estimate: Equatable, Sendable {
        case unknown
        case range(EstimateRange)
        var text: String {
            switch self {
            case .unknown: return "timing is still uncertain"
            case .range(let range):
                if range.upperSeconds < 60 {
                    return "about \(range.lowerSeconds) to \(range.upperSeconds) seconds remaining"
                }
                // Round outward, never narrow the producer's calibrated range.
                let lower = range.lowerSeconds / 60, upper = (range.upperSeconds + 59) / 60
                if lower == 0 { return "up to about \(upper) minutes remaining" }
                return "about \(lower) to \(upper) minutes remaining"
            }
        }
        fileprivate func materiallyDiffers(from previous: Estimate?) -> Bool {
            guard let previous else { return true }
            switch (self, previous) {
            case (.unknown, .unknown): return false
            case (.range(let current), .range(let old)):
                let threshold = max(30, old.upperSeconds / 4)
                return max(abs(current.lowerSeconds - old.lowerSeconds),
                           abs(current.upperSeconds - old.upperSeconds)) >= threshold
            default: return true
            }
        }
        fileprivate var expectsLongTask: Bool {
            if case .range(let range) = self { return Double(range.upperSeconds) > LongTaskProgress.longTaskSeconds }
            return false
        }
    }

    struct MeasuredWork: Equatable, Sendable {
        let completedUnits: Int
        let remainingUnits: Int
        var totalUnits: Int { completedUnits + remainingUnits }
        var fraction: Double { Double(completedUnits) / Double(totalUnits) }

        /// Units must describe an actual bounded work plan, not an estimate made
        /// from elapsed time. Keep at least one verification unit outstanding until
        /// completeVerified succeeds; 100% is not representable as running work.
        init?(completedUnits: Int, remainingUnits: Int) {
            guard completedUnits >= 0, remainingUnits > 0,
                  completedUnits < LongTaskProgress.maximumUnits,
                  remainingUnits <= LongTaskProgress.maximumUnits - completedUnits else { return nil }
            self.completedUnits = completedUnits; self.remainingUnits = remainingUnits
        }
    }
    enum Work: Equatable, Sendable { case unknown, measured(MeasuredWork) }

    struct Snapshot: Equatable, Sendable {
        let stage: String
        let completed: String
        /// An explicit description of the remaining plan, including verification.
        let remainingPlan: String
        let work: Work
        let phase: Phase
        let estimate: Estimate
        init?(stage: String, completed: String, remainingPlan: String, work: Work,
              phase: Phase = .working, estimate: Estimate = .unknown) {
            guard LongTaskProgress.validText(stage), LongTaskProgress.validText(completed),
                  LongTaskProgress.validText(remainingPlan) else { return nil }
            self.stage = stage; self.completed = completed; self.remainingPlan = remainingPlan
            self.work = work; self.phase = phase; self.estimate = estimate
        }
    }

    struct Interruption: Equatable, Sendable {
        let reason: String
        let nextAction: String
        init?(reason: String, nextAction: String) {
            guard LongTaskProgress.validText(reason), LongTaskProgress.validText(nextAction) else { return nil }
            self.reason = reason; self.nextAction = nextAction
        }
    }
    struct VerifiedResult: Equatable, Sendable {
        /// An opaque receipt/test/result reference, never a secret or full document.
        let evidenceID: String
        let summary: String
        init?(evidenceID: String, summary: String) {
            guard LongTaskProgress.validText(evidenceID), LongTaskProgress.validText(summary) else { return nil }
            self.evidenceID = evidenceID; self.summary = summary
        }
    }
    enum State: Equatable, Sendable {
        case idle, running
        case paused(Interruption), blocked(Interruption), failed(Interruption)
        case cancelled, completed(VerifiedResult)
    }
    enum StartMode: Sendable {
        case fresh
        /// Persist duration, not a monotonic clock origin from another process.
        /// Restoration deliberately does not replay start or historical milestones.
        case restored(elapsedRunningSeconds: Double, wasLongTask: Bool)
    }
    struct SpeechContext: Equatable, Sendable {
        var ready = false
        var muted = false
        var userSpeaking = false
        var listening = false
        /// Busy with OTHER voice output; the adapter tracks this update separately.
        var voiceBusy = false
        var foregroundInterrupted = false
        var quiet = false
        var callActive = false
        var permitsSpeech: Bool {
            ready && !muted && !userSpeaking && !listening && !voiceBusy &&
                !foregroundInterrupted && !quiet && !callActive
        }
        fileprivate var discardsDeferredSpeech: Bool { !ready || muted || quiet || callActive }
    }
    struct SpeechUpdate: Equatable, Sendable {
        let id: UUID
        let token: Token
        let reason: SpeechReason
        let text: String
        /// Declarative updates must never start the question-follow-up microphone loop.
        var invitesReply: Bool { false }
    }

    private(set) var token: Token?
    private(set) var state = State.idle
    private(set) var snapshot: Snapshot?
    private(set) var goal: String?
    private(set) var isLongTask = false
    private(set) var planRevisionReason: String?
    private(set) var speechContext = SpeechContext()
    private(set) var activeSpeech: SpeechUpdate?
    private var kind = Kind.work
    private var elapsedRunningSeconds = 0.0
    private var lastClock = 0.0
    private var lastSequence: UInt64 = 0
    private var highestCheckpoint = Checkpoint.start
    private var pending: SpeechReason?
    private var revisionNeedsSpeech = false
    private var lastSpokenEstimate: Estimate?
    private var lastSpeechAt: Double?

    var halo: Halo {
        guard isLongTask else { return .hidden }
        switch state {
        case .idle, .cancelled: return .hidden
        case .completed: return .verifiedComplete
        default:
            guard let snapshot else { return .hidden }
            switch snapshot.work {
            case .unknown: return .indeterminate
            case .measured(let work): return .determinate(work.fraction)
            }
        }
    }
    var canResume: Bool {
        switch state { case .paused, .blocked: return true; default: return false }
    }
    var canStop: Bool { state == .running || canResume }
    /// Readable without color, animation, numeric percentages or speech. UI decides
    /// when to announce this; reading the property never triggers VoiceOver events.
    var textStatus: String {
        guard let snapshot, let goal else { return "No active task" }
        let status: String
        switch state {
        case .idle: return "No active task"
        case .running: status = snapshot.stage
        case .paused(let detail): status = "Paused: \(detail.reason); \(detail.nextAction)"
        case .blocked(let detail): status = "Blocked: \(detail.reason); \(detail.nextAction)"
        case .failed(let detail): status = "Failed: \(detail.reason); \(detail.nextAction)"
        case .cancelled: return "\(goal): cancelled"
        case .completed(let result): return "\(goal): verified; \(result.summary)"
        }
        let revision = planRevisionReason.map { "; plan changed: \($0)" } ?? ""
        return "\(goal): \(status); \(snapshot.completed); next, \(snapshot.remainingPlan); \(snapshot.estimate.text)\(revision)"
    }

    /// Selects/replaces the sole displayed task. Preserve the previous activeSpeech
    /// ID before replacement if the integration needs to cancel already-started audio.
    @discardableResult mutating func start(taskID: UUID, goal: String, kind: Kind = .work,
                                           snapshot: Snapshot, now: Double,
                                           mode: StartMode = .fresh) -> Token? {
        guard Self.validText(goal), now.isFinite, now >= 0 else { return nil }
        let restored: Bool, elapsed: Double, previouslyLong: Bool
        switch mode {
        case .fresh: restored = false; elapsed = 0; previouslyLong = false
        case .restored(let seconds, let wasLong):
            guard seconds.isFinite, seconds >= 0 else { return nil }
            restored = true; elapsed = min(seconds, Self.longTaskSeconds + 1); previouslyLong = wasLong
        }
        let context = speechContext
        self = Self()
        speechContext = context
        let next = Token(taskID: taskID, runID: UUID(), planID: UUID())
        token = next; self.goal = goal; self.kind = kind; self.snapshot = snapshot
        state = .running; lastClock = now; elapsedRunningSeconds = elapsed
        isLongTask = kind == .work && (previouslyLong || elapsed > Self.longTaskSeconds || snapshot.estimate.expectsLongTask)
        highestCheckpoint = checkpoint(for: snapshot)
        if isLongTask && !restored { offer(.checkpoint(.start)) }
        return next
    }

    /// Time can only promote an initially short WORK task; it never changes work,
    /// stage, fraction or ETA. Short questions are excluded even after two minutes.
    @discardableResult mutating func tick(token: Token, now: Double) -> Bool {
        guard accepts(token), state == .running, validClock(now) else { return false }
        advanceClock(now)
        if !isLongTask, kind == .work,
           elapsedRunningSeconds > Self.longTaskSeconds || snapshot?.estimate.expectsLongTask == true {
            isLongTask = true
            if let snapshot { highestCheckpoint = checkpoint(for: snapshot) }
            offer(.checkpoint(.start))
        }
        return true
    }

    /// Sequence numbers are producer-owned and strictly increase within a token.
    /// A changing denominator, unknown-to-known scope or a return from final
    /// verification to ordinary work requires revisePlan and a new plan token.
    @discardableResult mutating func report(token: Token, sequence: UInt64,
                                            snapshot next: Snapshot, now: Double) -> Bool {
        guard accepts(token), state == .running, sequence > lastSequence,
              validClock(now), let old = snapshot, follows(next, old) else { return false }
        lastSequence = sequence; snapshot = next
        _ = tick(token: token, now: now)
        let checkpoint = checkpoint(for: next)
        if checkpoint.rawValue > highestCheckpoint.rawValue {
            highestCheckpoint = checkpoint
            if isLongTask { offer(.checkpoint(checkpoint)) }
        }
        return true
    }

    /// Newly discovered work may truthfully reduce the arc or make it indeterminate.
    /// Already crossed thresholds become this plan's baseline, avoiding a catch-up
    /// burst; new crossings are eligible once. The revision is visible immediately.
    @discardableResult mutating func revisePlan(token oldToken: Token, snapshot: Snapshot,
                                                reason: String, now: Double) -> Token? {
        guard accepts(oldToken), state == .running, Self.validText(reason), validClock(now) else { return nil }
        advanceClock(now)
        let next = Token(taskID: oldToken.taskID, runID: oldToken.runID, planID: UUID())
        let wasLongTask = isLongTask
        token = next; self.snapshot = snapshot; lastSequence = 0
        highestCheckpoint = checkpoint(for: snapshot)
        pending = nil; activeSpeech = nil
        planRevisionReason = reason; revisionNeedsSpeech = true
        if kind == .work && (snapshot.estimate.expectsLongTask || elapsedRunningSeconds > Self.longTaskSeconds) { isLongTask = true }
        if isLongTask { offer(wasLongTask ? .planRevised : .checkpoint(.start)) }
        return next
    }

    @discardableResult mutating func pause(token: Token, detail: Interruption, now: Double) -> Bool {
        interrupt(token: token, state: .paused(detail), now: now)
    }
    @discardableResult mutating func block(token: Token, detail: Interruption, now: Double) -> Bool {
        interrupt(token: token, state: .blocked(detail), now: now)
    }
    @discardableResult mutating func fail(token: Token, detail: Interruption, now: Double) -> Bool {
        guard accepts(token), canStop, validClock(now) else { return false }
        if state == .running { advanceClock(now) } else { lastClock = now }
        state = .failed(detail); clearSpeech(); return true
    }
    @discardableResult mutating func cancel(token: Token, now: Double) -> Bool {
        guard accepts(token), canStop, validClock(now) else { return false }
        if state == .running { advanceClock(now) } else { lastClock = now }
        state = .cancelled; clearSpeech(); return true
    }
    @discardableResult mutating func resume(token oldToken: Token, now: Double) -> Token? {
        guard accepts(oldToken), canResume, validClock(now) else { return nil }
        let next = Token(taskID: oldToken.taskID, runID: UUID(), planID: oldToken.planID)
        token = next; state = .running; lastClock = now; lastSequence = 0; clearSpeech()
        // Neither elapsed paused time nor queued milestones are replayed on resume.
        return next
    }

    /// The producer calls this only after actual result verification succeeds.
    /// A textual "done" report, elapsed timer or full unit count cannot complete.
    @discardableResult mutating func completeVerified(token: Token, sequence: UInt64,
                                                      result: VerifiedResult, now: Double) -> Bool {
        guard accepts(token), state == .running, sequence > lastSequence,
              snapshot?.phase == .finalVerification, validClock(now) else { return false }
        advanceClock(now); lastSequence = sequence; state = .completed(result); clearSpeech(); return true
    }

    /// Returns an in-flight speech ID for the adapter to cancel. Muting, quiet,
    /// calls and lost readiness discard pending speech; brief foreground/listening/
    /// TTS interruptions keep only the most recent milestone, never a FIFO queue.
    @discardableResult mutating func setSpeechContext(_ context: SpeechContext) -> UUID? {
        speechContext = context
        if context.discardsDeferredSpeech { pending = nil }
        guard !context.permitsSpeech else { return nil }
        let interrupted = activeSpeech?.id; activeSpeech = nil
        return interrupted
    }

    /// One revocable speech candidate. The adapter must recheck isSpeechCurrent
    /// immediately before playback and honour cancellation on stop/gate changes.
    /// Timing spaces speech; it never manufactures completion or milestones.
    mutating func takeSpeech(now: Double) -> SpeechUpdate? {
        guard validClock(now), state == .running, isLongTask,
              speechContext.permitsSpeech, activeSpeech == nil,
              let reason = pending, let token, let snapshot, let goal else { return nil }
        if let lastSpeechAt, now - lastSpeechAt < Self.minimumSpeechSpacing { return nil }
        advanceClock(now)
        let estimateChanged = snapshot.estimate.materiallyDiffers(from: lastSpokenEstimate)
        let timing: String
        if reason == .checkpoint(.start) || estimateChanged { timing = "; \(snapshot.estimate.text)" }
        else { timing = "" }
        let revision = revisionNeedsSpeech ? planRevisionReason.map { "The plan changed because \($0); " } ?? "" : ""
        let body: String
        if reason == .checkpoint(.start) { body = "\(revision)\(goal); first, \(snapshot.remainingPlan)\(timing)." }
        else { body = "\(revision)\(snapshot.completed); next, \(snapshot.remainingPlan)\(timing)." }
        let update = SpeechUpdate(id: UUID(), token: token, reason: reason, text: body)
        pending = nil; activeSpeech = update; lastSpeechAt = now
        if reason == .checkpoint(.start) || estimateChanged { lastSpokenEstimate = snapshot.estimate }
        revisionNeedsSpeech = false
        return update
    }
    func isSpeechCurrent(_ update: SpeechUpdate) -> Bool {
        state == .running && speechContext.permitsSpeech && token == update.token && activeSpeech?.id == update.id
    }
    @discardableResult mutating func finishSpeech(id: UUID) -> Bool {
        guard activeSpeech?.id == id else { return false }
        activeSpeech = nil; return true
    }

    private func accepts(_ token: Token) -> Bool { self.token == token }
    private func validClock(_ now: Double) -> Bool { now.isFinite && now >= lastClock }
    private mutating func advanceClock(_ now: Double) {
        elapsedRunningSeconds = min(Self.longTaskSeconds + 1, elapsedRunningSeconds + (now - lastClock))
        lastClock = now
    }
    private mutating func offer(_ reason: SpeechReason) {
        if !speechContext.discardsDeferredSpeech { pending = reason }
    }
    private mutating func clearSpeech() { pending = nil; activeSpeech = nil }
    private mutating func interrupt(token: Token, state: State, now: Double) -> Bool {
        guard accepts(token), self.state == .running, validClock(now) else { return false }
        advanceClock(now); self.state = state; clearSpeech(); return true
    }
    private func checkpoint(for snapshot: Snapshot) -> Checkpoint {
        guard case .measured(let work) = snapshot.work else { return .start }
        if snapshot.phase == .finalVerification && work.completedUnits * 100 >= work.totalUnits * 95 { return .finalVerification }
        if work.completedUnits * 100 >= work.totalUnits * 80 { return .mostWorkFinished }
        if work.completedUnits * 100 >= work.totalUnits * 50 { return .halfway }
        return .start
    }
    private func follows(_ next: Snapshot, _ old: Snapshot) -> Bool {
        if old.phase == .finalVerification && next.phase != .finalVerification { return false }
        switch (old.work, next.work) {
        case (.unknown, .unknown): return true
        case (.measured(let prior), .measured(let current)):
            return current.totalUnits == prior.totalUnits && current.completedUnits >= prior.completedUnits
        default: return false
        }
    }
    private static func validText(_ text: String) -> Bool {
        text.utf8.count <= maximumTextLength &&
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}
