import Foundation

/// The research producer sends only accepted, serial events. An operation ID is
/// captured when work begins; a cancelled callback never borrows a newer ID.
struct ResearchTaskProgress {
    struct Event {
        let operation: UUID
        let generation: UInt64
        let sequence: UInt64
        let change: Change
    }
    enum Change {
        case started(WebResearchSession, resuming: Bool)
        case checkpoint(WebResearchSession)
        case synthesizing(WebResearchSession)
        case verifying(WebResearchSession)
        /// Both values come from the local store, after citation validation and
        /// save/load. This verifies the stored result, not semantic truth.
        case verified(expected: WebResearchStoredSession, reloaded: WebResearchStoredSession)
        case removed(taskID: UUID)
        case paused, cancelled
        case blocked(LongTaskProgress.Interruption)
        case failed
    }
    private(set) var progress = LongTaskProgress()
    private(set) var operation: UUID?
    private var lastSequence: UInt64 = 0
    private var lastGeneration: UInt64 = 0

    @discardableResult
    mutating func receive(_ event: Event, now: Double) -> Bool {
        if case .removed(let taskID) = event.change {
            guard taskID == progress.token?.taskID, event.generation > lastGeneration, event.sequence > 0 else { return false }
            let context = progress.speechContext
            progress = LongTaskProgress(); progress.setSpeechContext(context)
            operation = event.operation; lastGeneration = event.generation; lastSequence = event.sequence
            return true
        }
        if case .started(let session, let resuming) = event.change {
            // Start admission is owned by the foreground research controller.
            // Duplicate delivery cannot restart a live operation or its clock.
            guard event.generation > lastGeneration, event.operation != operation, event.sequence > 0 else { return false }
            let sameTask = progress.token?.taskID == session.id
            let mode: LongTaskProgress.StartMode = resuming
                ? .restored(elapsedRunningSeconds: sameTask ? progress.accumulatedRunningSeconds : 0,
                            wasLongTask: sameTask && progress.isLongTask) : .fresh
            // A resumed closed source plan remains closed. Replacing it with an
            // unknown discovery snapshot would manufacture a plan revision and
            // replay speech as soon as the producer re-enters local synthesis.
            let initial: LongTaskProgress.Snapshot
            if resuming && session.stage == .completed {
                initial = Self.synthesizing(session, verifying: true)
            } else if resuming && session.stage == .awaitingLocalSynthesis {
                initial = Self.synthesizing(session, verifying: false)
            } else { initial = Self.retrieving(session) }
            guard progress.start(taskID: session.id, goal: "Research your question", snapshot: initial,
                                 now: now, mode: mode) != nil else { return false }
            operation = event.operation; lastGeneration = event.generation; lastSequence = event.sequence
            return true
        }
        guard operation == event.operation, event.generation == lastGeneration, event.sequence > lastSequence, let token = progress.token else { return false }
        let accepted: Bool
        switch event.change {
        case .started, .removed: return false
        case .checkpoint(let session):
            guard session.id == token.taskID, session.stage != .completed else { return false }
            accepted = report(Self.retrieving(session), now: now)
        case .synthesizing(let session):
            guard session.id == token.taskID else { return false }
            accepted = report(Self.synthesizing(session, verifying: false), now: now)
        case .verifying(let session):
            guard session.id == token.taskID else { return false }
            accepted = report(Self.synthesizing(session, verifying: true), now: now)
        case .verified(let expected, let reloaded):
            guard expected.id == token.taskID, expected == reloaded,
                  reloaded.session.stage == .completed, reloaded.session.synthesis != nil,
                  reloaded.session.outputVerification == .checked,
                  (try? reloaded.session.encodedCheckpoint()) != nil else { return false }
            let result = LongTaskProgress.VerifiedResult(evidenceID: reloaded.revision.uuidString,
                summary: "Citation excerpts and the stored answer were checked; conclusions still require judgment")!
            accepted = progress.completeVerified(token: token, sequence: lastSequence + 1, result: result, now: now)
        case .paused:
            accepted = progress.pause(token: token, detail: .init(reason: "Research pause requested",
                nextAction: "Wait for active work to stop, then use Resume in Web research")!, now: now)
        case .cancelled:
            accepted = progress.cancel(token: token, now: now)
        case .blocked(let detail): accepted = progress.block(token: token, detail: detail, now: now)
        case .failed:
            accepted = progress.fail(token: token, detail: .init(reason: "Research could not finish",
                nextAction: "Open Web research to inspect the error and saved evidence")!, now: now)
        }
        if accepted { lastSequence = event.sequence }
        return accepted
    }

    private mutating func report(_ snapshot: LongTaskProgress.Snapshot, now: Double) -> Bool {
        guard let token = progress.token, progress.state == .running else { return false }
        if progress.report(token: token, sequence: lastSequence + 1, snapshot: snapshot, now: now) { return true }
        // A transition from unknown discovery scope to a closed plan is explicit.
        // A changed denominator is never silently smoothed into a time-based arc.
        return progress.revisePlan(token: token, snapshot: snapshot,
            reason: "The source plan changed or its remaining steps became known", now: now) != nil
    }

    private static func retrieving(_ session: WebResearchSession) -> LongTaskProgress.Snapshot {
        let searches = session.queries.filter { $0.status == .completed }.count
        let stage = session.reads.contains(where: { $0.status == .inFlight }) ? "Reading sources" : "Searching sources"
        return .init(stage: stage, completed: "\(searches) searches completed and \(session.sources.count) sources read",
            remainingPlan: "finish source discovery, reason locally, then check citations and the stored answer", work: .unknown)!
    }
    private static func synthesizing(_ session: WebResearchSession, verifying: Bool) -> LongTaskProgress.Snapshot {
        let settled = session.queries.allSatisfy { $0.status == .completed || $0.status == .failed }
            && session.reads.allSatisfy { $0.status == .completed || $0.status == .failed }
        // One unit for each settled search/read, one for local synthesis, one for
        // citation validation + store read-back. Units do not predict duration.
        let done = session.queries.count + session.reads.count + (verifying ? 1 : 0)
        let work: LongTaskProgress.Work = settled
            ? .measured(.init(completedUnits: done, remainingUnits: verifying ? 1 : 2)!) : .unknown
        return .init(stage: verifying ? "Checking the answer" : "Reasoning locally",
            completed: verifying ? "The local draft is ready" : "Source discovery is finished; \(session.sources.count) sources were read",
            remainingPlan: verifying ? "check citation excerpts and read back the stored answer" : "reason locally, then check citations and the stored answer",
            work: work, phase: verifying ? .finalVerification : .working)!
    }

    mutating func cancelSelected(now: Double) {
        if let token = progress.token { progress.cancel(token: token, now: now) }
    }
    mutating func tick(now: Double) { if let token = progress.token { progress.tick(token: token, now: now) } }
    mutating func setSpeechContext(_ context: LongTaskProgress.SpeechContext) -> UUID? { progress.setSpeechContext(context) }
    mutating func takeSpeech(now: Double) -> LongTaskProgress.SpeechUpdate? { progress.takeSpeech(now: now) }
    mutating func finishSpeech(id: UUID) { progress.finishSpeech(id: id) }
}
