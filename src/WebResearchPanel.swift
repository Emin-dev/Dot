import AppKit
import SwiftUI

@MainActor
final class WebResearchModel: ObservableObject {
    typealias Synthesis = @MainActor @Sendable (WebResearchSession) async throws -> WebResearchSynthesis
    enum Activity: String { case loading = "Reading saved research…", retrieving = "Searching and reading sources…", synthesizing = "Reasoning locally…", pausing = "Pausing…", copying = "Preparing copy…", deleting = "Deleting research…" }
    @Published var question = "" {
        didSet { if question.utf8.count > 1_800 { question = question.truncated(toUTF8Bytes: 1_800); error = "Please keep the research question within 1,800 UTF-8 bytes." } }
    }
    @Published var queryText = "" {
        didSet { if queryText.utf8.count > 12_288 { queryText = queryText.truncated(toUTF8Bytes: 12_288); error = "The search plan is too long." } }
    }
    @Published private(set) var summaries: [WebResearchSessionSummary] = []
    @Published private(set) var selected: WebResearchStoredSession?
    @Published private(set) var activity: Activity?
    @Published private(set) var shuttingDown = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var providerName: String?
    private let store: (any WebResearchSessionAccess)?
    private var provider: (any WebSearchProvider)?
    private let reader: any WebResearchSourceReading
    private var synthesize: Synthesis?
    private var limits: WebResearchLimits
    private var retryPolicy: WebResearchRetryPolicy
    private let copyText: (String) -> Void
    private let openURL: (URL) -> Bool
    private var operation: Task<Void, Never>?
    // Keep admission reserved while publishing the final idle transition.
    private var publishingIdle = false
    private var operationID = UUID()
    private var progressSequence: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    var onTaskProgress: ((ResearchTaskProgress.Event) -> Void)?
    private var cancellationRequested = false
    private var acceptingActions = true
    private var activeStored: WebResearchStoredSession?
    // Keep the exact committed answer until its final read-back is verified.
    // This in-process receipt additionally covers a pause during receipt read-back, without
    // treating a saved .completed stage as proof that verification finished.
    private var pendingVerification: WebResearchStoredSession?
    private var researchSessionID: UUID?
    private var pendingDeletion: (prompt: UUID, stored: WebResearchStoredSession, operation: UUID)?

    var busy: Bool { operation != nil || publishingIdle }
    var maxQueries: Int { limits.maxQueries }
    var transient: Bool { store?.retention == .transient }
    var configured: Bool { provider != nil && (transient || provider?.permitsResultPersistence == true) }
    var canCopy: Bool { !transient && !busy && selected != nil }
    var canStart: Bool { acceptingActions && !busy && store != nil && configured && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canResume: Bool {
        guard acceptingActions, !busy, let selected else { return false }
        let session = selected.session
        if session.stage == .completed { return session.outputVerification == .pending || pendingVerification == selected }
        guard session.retryRequiresReview != true,
              session.retryNotBefore.map({ $0 <= Date() }) ?? true else { return false }
        if session.stage == .awaitingLocalSynthesis || Self.canFinishRetrievalLocally(session) {
            return synthesize != nil && Self.hasSynthesisEvidence(session)
        }
        guard configured, session.providerID == nil || session.providerID == providerName else { return false }
        return session.queries.contains { $0.status == .pending }
            || session.reads.contains { $0.status == .pending || $0.status == .inFlight }
            || session.queries.contains { ($0.status == .uncertain || $0.status == .inFlight)
                && retryPolicy == .retryUncertainWithinBudget && $0.attempts < 2 && session.searchAttempts < session.limits.maxSearchAttempts }
            || session.stage == .planned || session.stage == .retrieving
            || (session.stage == .paused && Self.hasTerminalRetrieval(session))
    }
    var canFollowUp: Bool {
        guard acceptingActions, !busy, configured, let session = selected?.session, let synthesis = session.synthesis,
              session.providerID == providerName, !synthesis.followUpQueries.isEmpty,
              session.hasAdditionalSourceCapacity else { return false }
        return session.queries.count + synthesis.followUpQueries.count <= session.limits.maxQueries
            && session.searchAttempts + synthesis.followUpQueries.count <= session.limits.maxSearchAttempts
    }
    var canRetryReviewedService: Bool {
        guard acceptingActions, !busy, configured, let session = selected?.session,
              session.stage == .paused, session.retryRequiresReview == true,
              session.providerID == providerName,
              session.retryNotBefore.map({ $0 <= Date() }) ?? true else { return false }
        return session.searchAttempts < session.limits.maxSearchAttempts
            && session.queries.contains { $0.status == .pending && $0.attempts < 2 }
    }
    var configurationSummary: String {
        guard let providerName else { return "Search is not ready. The verified local search runtime must be available before starting. Saved research remains available." }
        guard configured else { return "\(providerName) does not have confirmed result-retention rights for saved research." }
        let storage = transient ? "Temporary: held in memory until dot quits; no restart recovery or automatic saving." : "Research is saved locally."
        return "Search: \(providerName) · answers use local Qwen · up to \(limits.maxSearchAttempts) search attempts per session. " + storage
    }
    var retrySummary: String {
        retryPolicy == .preserveUncertain
            ? "Interrupted searches keep their unknown outcome; Resume does not repeat them."
            : "Resume may retry each interrupted search once within the saved attempt cap."
    }

    init(provider: (any WebSearchProvider)? = nil, store: (any WebResearchSessionAccess)? = nil,
         directory: URL? = nil, retention: WebResearchRetention = .permittedPersistence,
         reader: any WebResearchSourceReading = ResearchWebReader(),
         synthesize: Synthesis? = nil, limits: WebResearchLimits = WebResearchLimits(),
         retryPolicy: WebResearchRetryPolicy = .preserveUncertain,
         copyText: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
         }, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.provider = provider; providerName = provider?.providerID; self.reader = reader
        self.synthesize = synthesize; self.limits = limits; self.retryPolicy = retryPolicy
        self.copyText = copyText; self.openURL = openURL
        if let store { self.store = store }
        else if retention == .transient { self.store = TransientWebResearchStore() }
        else {
            do { self.store = try WebResearchSessionStore(directory: directory) }
            catch { self.store = nil; self.error = "Local research storage could not be opened." }
        }
    }

    /// Called by the owner after provider/budget selection and local credential setup. This never
    /// selects a service, provisions a key or falls back to a paid/remote answer provider itself.
    func configure(provider: (any WebSearchProvider)?, synthesize: Synthesis?,
                   limits: WebResearchLimits = WebResearchLimits(), retryPolicy: WebResearchRetryPolicy = .preserveUncertain) {
        guard !busy, !shuttingDown else { return }
        self.provider = provider; providerName = provider?.providerID; self.synthesize = synthesize
        self.limits = limits; self.retryPolicy = retryPolicy; error = nil
    }

    func open() { guard !shuttingDown else { return }; acceptingActions = true; if !busy { reload() } }
    func close() { acceptingActions = false; foregroundPause() }
    func closeAdmissions() { shuttingDown = true; close() }
    func cancel() {
        foregroundPause()
        if researchSessionID != nil { emitProgress(.cancelled, token: operationID) }
    }
    func flush() async { while let work = operation { await work.value } }

    /// Keeps the operation occupied until its request/synthesis exits and a paused receipt is saved.
    /// Foreground conversation can continue independently; Resume cannot overlap stale work.
    func foregroundPause() {
        cancelDeletion()
        guard let previous = operation, !cancellationRequested else { return }
        cancellationRequested = true; previous.cancel(); activity = .pausing
        if researchSessionID != nil { emitProgress(.paused, token: operationID) }
        let token = operationID
        operation = Task { [weak self] in
            await previous.value
            guard let self, self.operationID == token else { return }
            do {
                if let store = self.store, let active = self.activeStored, self.researchSessionID == active.id {
                    var session = active.session
                    if session.stage != .completed {
                        for index in session.queries.indices where session.queries[index].status == .inFlight {
                            session.queries[index].status = .uncertain; session.queries[index].failure = .interruptedOutcomeUnknown
                        }
                        for index in session.reads.indices where session.reads[index].status == .inFlight { session.reads[index].status = .pending }
                        // Stop must not discard retained results that still fit the source budget.
                        // Normalize first so an already-ready local receipt remains ready too.
                        session.stage = .paused
                        if Self.canFinishRetrievalLocally(session) { session.stage = .awaitingLocalSynthesis }
                        session.updatedAt = Date()
                        self.activeStored = try await store.save(session, expectedRevision: active.revision)
                    }
                }
                if let store = self.store { try await self.refresh(store: store, preferred: self.researchSessionID ?? self.selected?.id, token: token, duringCleanup: true) }
                if self.researchSessionID == nil { self.notice = "Stopped. Saved research refreshed." }
                else {
                    self.notice = self.selected?.session.stage == .completed
                        ? "The completed answer had already been saved before the pause."
                        : "Paused. Saved searches and source receipts are available to resume."
                }
                self.error = nil
            } catch {
                self.error = "Research stopped, but its latest saved state could not be refreshed. " + error.localizedDescription
                self.notice = nil
            }
            self.finish(token)
        }
    }

    func reload() {
        begin(.loading) { model, store, token in
            try await model.refresh(store: store, preferred: model.selected?.id, token: token)
        }
    }
    func select(_ id: UUID?) {
        guard acceptingActions, !busy else { return }
        cancelDeletion()
        guard let id else { selected = nil; return }
        begin(.loading) { model, store, token in
            let loaded = try await store.load(id: id); try model.check(token)
            model.selected = loaded
        }
    }

    func start() {
        guard canStart else { if !busy { notice = configurationSummary }; return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let queries: [String]
        do {
            queries = queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [question, question + " original sources evidence"]
                : queryText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            _ = try WebResearchSession(question: question, queries: queries, limits: limits, retryPolicy: retryPolicy)
        } catch { self.error = "Provide two to \(limits.maxQueries) distinct searches within the query limits."; return }
        begin(.retrieving) { model, store, token in
            let stored = try await store.create(question: question, queries: queries, limits: model.limits, retryPolicy: model.retryPolicy)
            // Track even a just-committed creation before checking cancellation, so cleanup can find it.
            model.activeStored = stored; model.researchSessionID = stored.id
            try model.check(token); model.selected = stored
            try await model.research(stored, store: store, token: token)
        }
    }
    func resume() {
        guard canResume, let selected else { return }
        if selected.session.stage == .completed {
            // Explicit Resume alone admits local verification of a durable pending
            // answer. Reload/open never runs searches, synthesis or actions.
            guard selected.session.outputVerification == .pending || pendingVerification == selected else { return }
            begin(.synthesizing) { model, store, token in
                try model.check(token)
                model.activeStored = selected; model.researchSessionID = selected.id
                model.pendingVerification = selected
                model.emitProgress(.started(selected.session, resuming: true), token: token)
                try model.check(token)
                model.emitProgress(.verifying(selected.session), token: token)
                try model.check(token)
                try await model.verifyCompleted(selected, store: store, token: token)
            }
            return
        }
        begin(selected.session.stage == .awaitingLocalSynthesis || Self.canFinishRetrievalLocally(selected.session) ? .synthesizing : .retrieving) { model, store, token in
            var current = try await store.load(id: selected.id)
            try model.check(token)
            guard current.revision == selected.revision else { throw WebResearchStoreError.conflict }
            model.activeStored = current; model.researchSessionID = current.id
            if Self.canFinishRetrievalLocally(current.session) {
                // Resume explicitly commits this target's retrieval barrier before local
                // synthesis. Reading a recovery projection alone never changes authority.
                var session = current.session; session.stage = .awaitingLocalSynthesis; session.updatedAt = Date()
                current = try await store.save(session, expectedRevision: selected.revision)
                model.activeStored = current // Capture an admitted write before cancellation.
                try model.check(token)
            }
            model.selected = current
            try await model.research(current, store: store, token: token, resuming: true)
        }
    }
    func retryReviewedService() {
        guard canRetryReviewedService, let selected else { return }
        begin(.retrieving) { model, store, token in
            let current = try await store.load(id: selected.id)
            try model.check(token)
            guard current.revision == selected.revision else { throw WebResearchStoreError.conflict }
            let updated = try await store.save(current.session.allowingReviewedProviderRetry(), expectedRevision: current.revision)
            model.activeStored = updated; model.researchSessionID = updated.id
            try model.check(token); model.selected = updated
            try await model.research(updated, store: store, token: token, resuming: true)
        }
    }
    func followUp() {
        guard canFollowUp, let selected, let suggestions = selected.session.synthesis?.followUpQueries else { return }
        begin(.retrieving) { model, store, token in
            let current = try await store.load(id: selected.id)
            try model.check(token)
            guard current.revision == selected.revision else { throw WebResearchStoreError.conflict }
            let updated = try await store.save(current.session.addingQueries(suggestions), expectedRevision: current.revision)
            model.activeStored = updated; model.researchSessionID = updated.id; try model.check(token); model.selected = updated
            try await model.research(updated, store: store, token: token)
        }
    }
    func requestDeleteSelected() -> LocalRecordDeletionPrompt? {
        guard acceptingActions, !busy, let selected else { return nil }
        let prompt = LocalRecordDeletionPrompt(title: transient ? "Remove this temporary research?" : "Delete this research session?",
            message: transient ? "This answer and its evidence will be removed from memory. They are not saved on disk and cannot be resumed after removal."
                : "The saved answer, searches and source excerpts for “\(selected.session.question)” will be permanently deleted. Original websites are unaffected. This cannot be undone.")
        pendingDeletion = (prompt.id, selected, operationID); return prompt
    }
    func cancelDeletion() { pendingDeletion = nil }
    @discardableResult func confirmDeletion(_ prompt: UUID) -> Bool {
        guard let request = pendingDeletion, request.prompt == prompt else { return false }
        pendingDeletion = nil
        guard acceptingActions, !busy, operationID == request.operation,
              selected?.id == request.stored.id, selected?.revision == request.stored.revision else { return false }
        let target = request.stored
        begin(.deleting) { model, store, token in
            try await store.delete(id: target.id, expectedRevision: target.revision)
            if model.pendingVerification?.id == target.id { model.pendingVerification = nil }
            try model.check(token); model.selected = nil
            model.emitProgress(.removed(taskID: target.id), token: token)
            try await model.refresh(store: store, preferred: nil, token: token)
            model.notice = "Research deleted from this store."
        }
        return true
    }
    func copySelected() {
        guard !transient else { notice = "Temporary research is not automatically copied or exported. Result-retention permissions have not been established."; return }
        guard let selected else { return }
        begin(.copying) { model, store, token in
            let current = try await store.load(id: selected.id)
            try model.check(token)
            guard current.revision == selected.revision, model.selected?.id == selected.id else { throw WebResearchStoreError.conflict }
            model.copyText(Self.report(current.session)); model.notice = "Research and source receipts copied."
        }
    }
    func openSource(id: UUID) {
        guard acceptingActions, !busy, let source = selected?.session.sources.first(where: { $0.id == id }) else { return }
        error = nil; notice = nil
        guard ResearchWebReader.allowed(source.originalURL) else {
            error = "This stored source cannot be opened safely. Use an HTTPS source in a new research pass."
            return
        }
        if openURL(source.originalURL) { notice = "Requested the original source in your browser." }
        else { error = "The original source could not be opened." }
    }

    private func research(_ original: WebResearchStoredSession, store: any WebResearchSessionAccess, token: UUID, resuming: Bool = false) async throws {
        try check(token)
        pendingVerification = nil
        emitProgress(.started(original.session, resuming: resuming), token: token)
        try check(token)
        var stored = original
        if stored.session.stage != .awaitingLocalSynthesis {
            guard let provider, transient || provider.permitsResultPersistence else { throw WebResearchError.resultRetentionUnavailable }
            var session = stored.session
            if session.retryPolicy != retryPolicy {
                session.retryPolicy = retryPolicy
                stored = try await store.save(session, expectedRevision: stored.revision)
                activeStored = stored; try check(token); selected = stored
            }
            let workflow = WebResearchWorkflow(provider: provider, reader: reader)
            activity = .retrieving
            let result = try await workflow.run(stored.session) { [weak self] checkpoint in
                guard let self else { throw CancellationError() }
                try await self.checkpoint(checkpoint, store: store, token: token)
            }
            try check(token)
            guard result.stage == .awaitingLocalSynthesis else {
                if result.retryRequiresReview == true { notice = "Research paused because its search service needs attention. No more searches were sent." }
                else if let date = result.retryNotBefore { notice = "Research paused until " + date.formatted() + ". Resume later; remaining searches have not been sent." }
                else { notice = "Paused with an interrupted search outcome. " + retrySummary }
                emitProgress(.blocked(.init(reason: result.retryRequiresReview == true ? "The search service needs attention" : "Search is waiting for a safe retry",
                    nextAction: "Open Web research and check the saved retry instructions")!), token: token)
                try await refresh(store: store, preferred: stored.id, token: token); return
            }
            guard let latest = activeStored else { throw WebResearchStoreError.notFound }; stored = latest
        }
        try check(token)
        guard Self.hasSynthesisEvidence(stored.session) else {
            emitProgress(.blocked(.init(reason: "There is not enough readable evidence for synthesis",
                nextAction: "Open Web research to inspect sources and revise the search plan")!), token: token)
            notice = "The available evidence is " + (transient ? "held temporarily in memory" : "saved locally") + ". At least two completed searches and two sources read over HTTPS are needed before local synthesis. Reread unverified historical sources in a new research pass."
            try await refresh(store: store, preferred: stored.id, token: token); return
        }
        guard let synthesize else {
            emitProgress(.blocked(.init(reason: "Local reasoning is unavailable",
                nextAction: "Check local Qwen readiness, then resume from Web research")!), token: token)
            notice = "Sources are ready. Local Qwen synthesis is not configured for this panel yet."
            try await refresh(store: store, preferred: stored.id, token: token); return
        }
        activity = .synthesizing
        emitProgress(.synthesizing(stored.session), token: token)
        try check(token)
        let result = try await synthesize(stored.session)
        try check(token)
        emitProgress(.verifying(stored.session), token: token)
        try check(token)
        let completed = try stored.session.completing(with: result)
        try await checkpoint(completed, store: store, token: token)
        guard let expected = activeStored else { throw WebResearchStoreError.notFound }
        try await verifyCompleted(expected, store: store, token: token)
    }

    private func verifyCompleted(_ expected: WebResearchStoredSession,
                                 store: any WebResearchSessionAccess, token: UUID) async throws {
        try check(token)
        guard expected.session.stage == .completed, expected.session.synthesis != nil,
              pendingVerification == expected else { throw WebResearchStoreError.conflict }
        // A successful save is insufficient for the complete halo. Revalidate the
        // exact checkpoint, reload it, and compare the visible refresh as well.
        // A resume after pause/Stop uses this same path without new synthesis.
        _ = try expected.session.encodedCheckpoint()
        let reloaded = try await store.load(id: expected.id)
        try check(token)
        guard reloaded == expected else { throw WebResearchStoreError.conflict }
        try await refresh(store: store, preferred: expected.id, token: token)
        try check(token) // Published observers may synchronously Stop or close.
        guard selected == expected else { throw WebResearchStoreError.conflict }
        // Persist a receipt only after the original answer passed both exact
        // read-backs. This metadata-only CAS cannot carry a receipt to new content.
        var verified = expected, checkedReadback = reloaded
        if expected.session.outputVerification == .pending {
            var checked = expected.session; checked.outputVerification = .checked
            verified = try await store.save(checked, expectedRevision: expected.revision)
            // Capture an admitted write before observing cancellation, so a late
            // Stop can resume only this exact receipt without replaying synthesis.
            activeStored = verified; pendingVerification = verified
            try check(token)
            let receipt = try await store.load(id: verified.id)
            try check(token)
            guard receipt == verified else { throw WebResearchStoreError.conflict }
            checkedReadback = receipt
            try await refresh(store: store, preferred: verified.id, token: token)
            try check(token) // Recheck admission after synchronous UI observers.
            guard selected == verified else { throw WebResearchStoreError.conflict }
        }
        emitProgress(.verified(expected: verified, reloaded: checkedReadback), token: token)
        try check(token) // A completion observer may synchronously Stop or close.
        pendingVerification = nil
        notice = (transient ? "Temporary research answer ready. It will be lost when dot quits." : "Research answer saved locally.") + " Citation excerpts match sources; conclusions still require judgment."
    }

    private func checkpoint(_ session: WebResearchSession, store: any WebResearchSessionAccess, token: UUID) async throws {
        try check(token)
        guard let active = activeStored, active.id == session.id else { throw WebResearchStoreError.conflict }
        let saved = try await store.save(session, expectedRevision: active.revision)
        activeStored = saved
        if session.stage == .completed { pendingVerification = saved }
        try check(token); selected = saved
        if session.stage != .completed { emitProgress(.checkpoint(session), token: token) }
    }

    private func refresh(store: any WebResearchSessionAccess, preferred: UUID?, token: UUID, duringCleanup: Bool = false) async throws {
        let list = try await store.list()
        if !duringCleanup { try check(token) }
        let id = preferred.flatMap { preferred in list.contains(where: { $0.id == preferred }) ? preferred : nil } ?? list.first?.id
        let loaded: WebResearchStoredSession?
        if let id { loaded = try await store.load(id: id) } else { loaded = nil }
        if !duringCleanup { try check(token) }
        guard operationID == token else { throw CancellationError() }
        summaries = list; selected = loaded
    }

    private func begin(_ activity: Activity,
                       body: @escaping @MainActor (WebResearchModel, any WebResearchSessionAccess, UUID) async throws -> Void) {
        guard acceptingActions, !busy, let store else { return }
        cancelDeletion()
        let token = UUID(); operationID = token; operationGeneration += 1; progressSequence = 0; cancellationRequested = false
        activeStored = nil; researchSessionID = nil
        // Install ownership before any synchronous Published observer can Stop,
        // close, or attempt another operation. This task cannot run until we yield.
        operation = Task { [weak self] in
            guard let self else { return }
            do { try self.check(token); try await body(self, store, token) }
            catch {
                if !self.cancellationRequested, self.operationID == token, !Task.isCancelled {
                    self.error = error.localizedDescription; self.notice = nil
                    if self.researchSessionID != nil { self.emitProgress(.failed, token: token) }
                }
            }
            if !self.cancellationRequested { self.finish(token) }
        }
        self.activity = activity; error = nil; notice = nil
        // Published uses willSet: a nested Stop may publish pausing before the
        // outer activity assignment finishes. Restore the admitted pause state.
        if cancellationRequested { self.activity = .pausing }
    }
    private func emitProgress(_ change: ResearchTaskProgress.Change, token: UUID) {
        guard operationID == token else { return }
        progressSequence += 1
        onTaskProgress?(.init(operation: token, generation: operationGeneration, sequence: progressSequence, change: change))
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard acceptingActions, operationID == token, !cancellationRequested else { throw CancellationError() }
    }
    private func finish(_ token: UUID) {
        guard operationID == token else { return }
        publishingIdle = true
        operation = nil; cancellationRequested = false; activeStored = nil; researchSessionID = nil
        // Reject nested admission until this outer Published assignment finishes;
        // otherwise it could overwrite a newly started operation's activity.
        activity = nil
        publishingIdle = false
    }
    private static func hasTerminalRetrieval(_ session: WebResearchSession) -> Bool {
        session.queries.allSatisfy { $0.status == .completed || $0.status == .failed }
            && session.reads.allSatisfy { $0.status == .completed || $0.status == .failed }
    }
    private static func canFinishRetrievalLocally(_ session: WebResearchSession) -> Bool {
        (session.stage == .paused || session.stage == .retrieving) && hasTerminalRetrieval(session)
            && hasSynthesisEvidence(session)
            // Completed queries may still have unqueued results. Leave those to the
            // existing bounded retrieval workflow rather than silently skipping sources.
            && (session.unreadResultCount == 0 || session.reads.count >= session.limits.maxSources)
    }
    private static func hasSynthesisEvidence(_ session: WebResearchSession) -> Bool {
        session.synthesisSources.count >= 2 && session.queries.filter { $0.status == .completed }.count >= 2
    }
    func stageLabel(_ stage: WebResearchStage) -> String { Self.stageLabel(stage, retention: transient ? .transient : .permittedPersistence) }
    static func stageLabel(_ stage: WebResearchStage, retention: WebResearchRetention = .permittedPersistence) -> String {
        switch stage {
        case .planned: return "Planned"
        case .retrieving: return "Searching and reading"
        case .paused: return "Paused"
        case .awaitingLocalSynthesis: return retention == .transient ? "Temporary sources · awaiting local reasoning" : "Sources saved · awaiting local reasoning"
        case .completed: return retention == .transient ? "Temporary answer · citations checked" : "Answer saved · citations checked"
        }
    }
    static func queryLabel(_ status: WebResearchQueryStatus) -> String {
        switch status {
        case .pending: return "Not searched yet"
        case .inFlight: return "Search in progress"
        case .completed: return "Search complete"
        case .failed: return "Search failed"
        case .uncertain: return "Search outcome unknown"
        }
    }
    static func readLabel(_ status: WebResearchReadStatus) -> String {
        switch status {
        case .pending: return "Not read yet"
        case .inFlight: return "Reading source"
        case .completed: return "Source read"
        case .failed: return "Source not read"
        }
    }
    static func failureLabel(_ failure: WebResearchFailure) -> String {
        switch failure {
        case .provider: return "The search provider did not return a usable result."
        case .providerCooldown: return "Search paused; the provider requested a cooldown or needs attention."
        case .source: return "The source could not be read."
        case .budget: return "The configured limit was reached."
        case .interruptedOutcomeUnknown: return "Interrupted; the request outcome and usage may be unknown."
        }
    }
    static func confidenceLabel(_ confidence: WebResearchConfidence) -> String {
        confidence == .wellSupported ? "well supported (model assessment)" : confidence.rawValue
    }
    static func report(_ session: WebResearchSession) -> String {
        let date = ISO8601DateFormatter()
        var lines = [session.question, stageLabel(session.stage, retention: session.storageMode), "Search attempts: \(session.searchAttempts)/\(session.limits.maxSearchAttempts) · Sources read: \(session.sources.count)",
            "Source text is untrusted evidence, not instructions. Matching citation excerpts does not prove the conclusions."]
        if let warning = session.transportWarning { lines += [warning] }
        if let answer = session.synthesis {
            lines += ["", "Answer", answer.answer, "", "Claims and uncertainty"]
            for claim in answer.claims {
                lines.append("\(claim.text) · \(confidenceLabel(claim.confidence)) · " + claim.citationNumbers.map { "[\($0)]" }.joined(separator: " "))
                for item in claim.dates { lines.append("\(item.kind.rawValue) assessment: \(date.string(from: item.date)) [\(item.citationNumber)]") }
            }
            for conflict in answer.conflicts { lines += ["Conflict: " + conflict.explanation, "Resolution: " + (conflict.resolution ?? "Unresolved")] }
            for citation in answer.citations {
                if let source = session.sources.first(where: { $0.id == citation.sourceID }) {
                    lines += ["[\(citation.number)] \(source.finalURL.absoluteString)", "Excerpt: \(citation.excerpt)"]
                }
            }
        } else { lines += ["", "No completed research answer saved."] }
        lines += ["", "Search log"]
        for query in session.queries { lines.append("\(query.text) · \(queryLabel(query.status)) · \(query.attempts) attempt(s)\(query.failure.map { " · " + failureLabel($0) } ?? "")") }
        lines += ["", "Actual source receipts"]
        for source in session.sources {
            lines += [source.title, source.finalURL.absoluteString, source.transportSummary, "Read: \(date.string(from: source.retrievedAt)) · \(source.bytesRead) bytes · SHA-256 \(source.sha256)",
                "Modified: \(source.modifiedAt.map { date.string(from: $0) } ?? "unknown") (not a publication date)",
                "Extract: " + String(source.text.prefix(2_000))]
            if source.truncated || source.text.count > 2_000 { lines.append("Extract shortened; consult the original source.") }
        }
        return lines.joined(separator: "\n")
    }
    deinit { operation?.cancel() }
}

@MainActor
final class WebResearchPanel: NSObject, NSWindowDelegate {
    let model: WebResearchModel
    var onVisibility: ((Bool) -> Void)?
    private let host = UtilityPanelHost(size: NSSize(width: 720, height: 660), minSize: NSSize(width: 560, height: 480),
                                        title: "Dot · Web research",
                                        makeWindow: { WebResearchWindow(contentRect: $0, styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                                                        backing: .buffered, defer: false) })
    private var panel: NSPanel? { host.panel }
    private let confirmation: LocalRecordDeletionConfirmation
    init(model: WebResearchModel, confirmation: LocalRecordDeletionConfirmation? = nil) {
        self.model = model; self.confirmation = confirmation ?? LocalRecordDeletionConfirmation(); super.init()
    }
    @discardableResult
    func prepare() -> NSPanel {
        host.window(delegate: self, configure: { [weak self] window in
            (window as? WebResearchWindow)?.pause = { [weak self] in self?.foregroundPause() }
        }) {
            NSHostingView(rootView: WebResearchView(model: model, delete: { [weak self] in self?.requestDeletion() }))
        }
    }
    func show() {
        guard !model.shuttingDown else { return }
        invalidateDeletion()
        prepare(); model.open(); host.present(onVisibility)
    }
    func foregroundPause() { invalidateDeletion(); model.foregroundPause() }
    func cancel() { invalidateDeletion(); model.cancel() }
    func close() { invalidateDeletion(); model.close(); panel?.close() }
    func closeAdmissions() { invalidateDeletion(); model.closeAdmissions(); panel?.close() }
    func windowWillClose(_ notification: Notification) { invalidateDeletion(); model.close(); onVisibility?(false) }
    private func invalidateDeletion() { confirmation.invalidate(); model.cancelDeletion() }
    func requestDeletion() {
        guard let panel, let prompt = model.requestDeleteSelected() else { return }
        confirmation.present(prompt, for: panel) { [weak model] confirmed in
            if confirmed { model?.confirmDeletion(prompt.id) } else { model?.cancelDeletion() }
        }
    }
}

private final class WebResearchWindow: NSPanel {
    var pause: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { pause?() }
}

struct WebResearchView: View {
    @ObservedObject var model: WebResearchModel
    let delete: () -> Void
    @State private var detail = "Answer"
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(model.configurationSummary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("What would you like to research?", text: $model.question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3).disabled(model.busy)
                .accessibilityLabel("Research question")
            DisclosureGroup("Search plan · optional") {
                Text("Leave blank for two initial searches based on your question, or enter 2–\(model.maxQueries) distinct searches, one per line.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $model.queryText).font(.system(.caption, design: .monospaced)).frame(height: 48)
                    .border(Color.secondary.opacity(0.3)).disabled(model.busy).accessibilityLabel("Search plan")
            }.font(.caption)
            HStack {
                Button("Research") { model.start() }.disabled(!model.canStart)
                if let activity = model.activity {
                    ProgressView().controlSize(.small)
                    Text(activity.rawValue).font(.caption)
                    Spacer()
                    Button("Pause") { model.foregroundPause() }.disabled(activity == .pausing).keyboardShortcut(.cancelAction)
                } else if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HSplitView {
                List(model.summaries, selection: Binding(get: { model.selected?.id }, set: { model.select($0) })) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: item.question).lineLimit(2).font(.callout)
                        Text(model.stageLabel(item.stage)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(item.id)
                }.frame(minWidth: 140, idealWidth: 180).disabled(model.busy)
                VStack(alignment: .leading, spacing: 7) {
                    if let session = model.selected?.session {
                        Text(verbatim: session.question).font(.callout.weight(.medium)).lineLimit(3).textSelection(.enabled)
                        Text(model.stageLabel(session.stage)).font(.callout.weight(.medium))
                        Text("\(session.searchAttempts)/\(session.limits.maxSearchAttempts) search attempts · \(session.sources.count) sources read · \(session.unreadResultCount) other results not read")
                            .font(.caption2).foregroundStyle(.secondary)
                        Picker("Read research", selection: $detail) { ForEach(["Answer", "Evidence", "Searches"], id: \.self) { Text($0) } }
                            .pickerStyle(.segmented)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if detail == "Answer" { answer(session) }
                                else if detail == "Evidence" { evidence(session) }
                                else { searches(session) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    } else {
                        Text(model.transient ? "Temporary research will appear here. Nothing is saved automatically; it cannot survive quitting dot." : "Saved research will appear here. A search result is not treated as a source read.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 260)
            }
            Text(model.retrySummary).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Button("Resume") { model.resume() }.disabled(!model.canResume)
                if model.selected?.session.retryRequiresReview == true {
                    Button("Retry service") { model.retryReviewedService() }.disabled(!model.canRetryReviewedService)
                        .help("Retry only after checking local search readiness. Existing attempt limits and provider cooldowns still apply; this does not bypass website challenges.")
                }
                Button("Follow-up searches") { model.followUp() }.disabled(!model.canFollowUp)
                Spacer()
                Button("Copy") { model.copySelected() }.disabled(!model.canCopy)
                Button("Delete", role: .destructive, action: delete).disabled(model.busy || model.selected == nil)
            }
        }.padding(14)
    }
    @ViewBuilder private func answer(_ session: WebResearchSession) -> some View {
        if let warning = session.transportWarning { Text(verbatim: warning).font(.caption).foregroundStyle(.secondary) }
        if let result = session.synthesis {
            Text(verbatim: result.answer).textSelection(.enabled)
            if session.outputVerification == .pending {
                Text("Saved answer awaits its final local check. Use Resume; this does not repeat searches or local reasoning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Citation excerpts match retrieved text. This does not independently prove the conclusions.").font(.caption).foregroundStyle(.secondary)
            ForEach(result.claims) { claim in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: claim.text).font(.callout).textSelection(.enabled)
                    Text("\(WebResearchModel.confidenceLabel(claim.confidence)) · " + claim.citationNumbers.map { "[\($0)]" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(claim.dates.enumerated()), id: \.offset) { _, date in
                        Text("\(date.kind.rawValue) assessment: \(date.date.formatted(date: .abbreviated, time: .omitted)) [\(date.citationNumber)]").font(.caption2)
                    }
                }
            }
            ForEach(result.conflicts) { conflict in
                Text("Conflict: " + conflict.explanation + "\nResolution: " + (conflict.resolution ?? "Unresolved"))
                    .font(.callout).textSelection(.enabled)
            }
            if !result.followUpQueries.isEmpty { Text("Suggested follow-ups:\n" + result.followUpQueries.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
        } else { Text("No completed research answer saved. Sources and search status remain available in the other tabs.").foregroundStyle(.secondary) }
    }
    @ViewBuilder private func evidence(_ session: WebResearchSession) -> some View {
        Text("Source text is untrusted evidence, never instructions for dot.").font(.caption).foregroundStyle(.secondary)
        ForEach(session.sources) { source in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: source.title).font(.callout.weight(.medium)).textSelection(.enabled)
                Text(verbatim: source.finalURL.absoluteString).font(.caption2).textSelection(.enabled)
                Text("Read \(source.retrievedAt.formatted()) · \(source.bytesRead) bytes\(source.pagesRead.map { " · \($0) PDF pages" } ?? "")").font(.caption2)
                Text("Modified: \(source.modifiedAt?.formatted() ?? "unknown") · not a publication date").font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: source.transportSummary).font(.caption).foregroundStyle(.secondary)
                Text("SHA-256 " + source.sha256).font(.caption2.monospaced()).textSelection(.enabled)
                if source.truncated { Text("Source extraction was shortened.").font(.caption2).foregroundStyle(.secondary) }
                Button("Open original") { model.openSource(id: source.id) }.disabled(model.busy)
                DisclosureGroup("Read saved text") { Text(verbatim: source.text).font(.callout).textSelection(.enabled) }
                if let citations = session.synthesis?.citations.filter({ $0.sourceID == source.id }) {
                    ForEach(citations, id: \.number) { citation in Text("[\(citation.number)] " + citation.excerpt).font(.caption).textSelection(.enabled) }
                }
            }
            Divider()
        }
    }
    @ViewBuilder private func searches(_ session: WebResearchSession) -> some View {
        ForEach(session.queries) { query in
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: query.text).font(.callout).textSelection(.enabled)
                Text("\(WebResearchModel.queryLabel(query.status)) · \(query.attempts) attempt(s) · \(query.results.count) search results").font(.caption)
                if query.coverage == .partial { Text("Partial search coverage. Some configured engines were unavailable.").font(.caption2).foregroundStyle(.secondary) }
                if let failure = query.failure { Text(WebResearchModel.failureLabel(failure)).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        ForEach(session.reads.filter { $0.status != .completed }) { read in
            Text("\(WebResearchModel.readLabel(read.status)): \(read.url.absoluteString)\(read.failure.map { " · " + WebResearchModel.failureLabel($0) } ?? "")")
                .font(.caption).textSelection(.enabled)
        }
    }
}
