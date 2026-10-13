import AppKit
import SwiftUI

@MainActor
final class WebResearchModel: ObservableObject {
    typealias Synthesis = @MainActor @Sendable (WebResearchSession) async throws -> WebResearchSynthesis
    enum Activity: String { case loading = "Reading saved research…", retrieving = "Searching and reading sources…", synthesizing = "Reasoning locally…", pausing = "Pausing…", copying = "Preparing copy…", deleting = "Deleting research…" }
    @Published var question = "" {
        didSet { if question.utf8.count > 1_800 { question = Self.bounded(question, bytes: 1_800); error = "Please keep the research question within 1,800 UTF-8 bytes." } }
    }
    @Published var queryText = "" {
        didSet { if queryText.utf8.count > 12_288 { queryText = Self.bounded(queryText, bytes: 12_288); error = "The search plan is too long." } }
    }
    @Published private(set) var summaries: [WebResearchSessionSummary] = []
    @Published private(set) var selected: WebResearchStoredSession?
    @Published private(set) var activity: Activity?
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
    private var operationID = UUID()
    private var cancellationRequested = false
    private var acceptingActions = true
    private var activeStored: WebResearchStoredSession?
    private var researchSessionID: UUID?

    var busy: Bool { activity != nil }
    var maxQueries: Int { limits.maxQueries }
    var configured: Bool { provider != nil && provider?.permitsResultPersistence == true }
    var canStart: Bool { acceptingActions && !busy && store != nil && configured && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canResume: Bool {
        guard acceptingActions, !busy, let session = selected?.session, session.stage != .completed else { return false }
        if session.stage == .awaitingLocalSynthesis { return synthesize != nil && Self.hasSynthesisEvidence(session) }
        guard configured, session.providerID == nil || session.providerID == providerName else { return false }
        return session.queries.contains { $0.status == .pending }
            || session.reads.contains { $0.status == .pending || $0.status == .inFlight }
            || session.queries.contains { ($0.status == .uncertain || $0.status == .inFlight)
                && retryPolicy == .retryUncertainWithinBudget && $0.attempts < 2 && session.searchAttempts < session.limits.maxSearchAttempts }
            || session.stage == .planned || session.stage == .retrieving
    }
    var canFollowUp: Bool {
        guard acceptingActions, !busy, configured, let session = selected?.session, let synthesis = session.synthesis,
              session.providerID == providerName, !synthesis.followUpQueries.isEmpty else { return false }
        return session.queries.count + synthesis.followUpQueries.count <= session.limits.maxQueries
            && session.searchAttempts + synthesis.followUpQueries.count <= session.limits.maxSearchAttempts
    }
    var configurationSummary: String {
        guard let providerName else { return "Search is not configured. Choose a provider and set up its key locally before starting. Saved research remains available." }
        guard configured else { return "\(providerName) does not have confirmed result-retention rights for saved research." }
        return "Search: \(providerName) · answers use local Qwen · up to \(limits.maxSearchAttempts) search attempts per session."
    }
    var retrySummary: String {
        retryPolicy == .preserveUncertain
            ? "Interrupted searches keep their unknown outcome; Resume does not repeat them."
            : "Resume may retry each interrupted search once within the saved attempt cap."
    }

    init(provider: (any WebSearchProvider)? = nil, store: (any WebResearchSessionAccess)? = nil,
         directory: URL? = nil, reader: any WebResearchSourceReading = ResearchWebReader(),
         synthesize: Synthesis? = nil, limits: WebResearchLimits = WebResearchLimits(),
         retryPolicy: WebResearchRetryPolicy = .preserveUncertain,
         copyText: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
         }, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.provider = provider; providerName = provider?.providerID; self.reader = reader
        self.synthesize = synthesize; self.limits = limits; self.retryPolicy = retryPolicy
        self.copyText = copyText; self.openURL = openURL
        if let store { self.store = store }
        else {
            do { self.store = try WebResearchSessionStore(directory: directory) }
            catch { self.store = nil; self.error = "Local research storage could not be opened." }
        }
    }

    /// Called by the owner after provider/budget selection and local credential setup. This never
    /// selects a service, provisions a key or falls back to a paid/remote answer provider itself.
    func configure(provider: (any WebSearchProvider)?, synthesize: Synthesis?,
                   limits: WebResearchLimits = WebResearchLimits(), retryPolicy: WebResearchRetryPolicy = .preserveUncertain) {
        guard !busy else { return }
        self.provider = provider; providerName = provider?.providerID; self.synthesize = synthesize
        self.limits = limits; self.retryPolicy = retryPolicy; error = nil
    }

    func open() { acceptingActions = true; if !busy { reload() } }
    func close() { acceptingActions = false; foregroundPause() }
    func cancel() { foregroundPause() }
    func flush() async { while let work = operation { await work.value } }

    /// Keeps the operation occupied until its request/synthesis exits and a paused receipt is saved.
    /// Foreground conversation can continue independently; Resume cannot overlap stale work.
    func foregroundPause() {
        guard let previous = operation, !cancellationRequested else { return }
        cancellationRequested = true; previous.cancel(); activity = .pausing
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
                        session.stage = Self.hasSynthesisEvidence(session) && session.queries.allSatisfy({ $0.status == .completed || $0.status == .failed })
                            && session.reads.allSatisfy({ $0.status == .completed || $0.status == .failed }) ? .awaitingLocalSynthesis : .paused
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
        begin(selected.session.stage == .awaitingLocalSynthesis ? .synthesizing : .retrieving) { model, store, token in
            let current = try await store.load(id: selected.id)
            try model.check(token); model.activeStored = current; model.researchSessionID = current.id; model.selected = current
            try await model.research(current, store: store, token: token)
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
    func deleteSelected() {
        guard let selected else { return }
        begin(.deleting) { model, store, token in
            try await store.delete(id: selected.id, expectedRevision: selected.revision)
            try model.check(token); model.selected = nil
            try await model.refresh(store: store, preferred: nil, token: token)
            model.notice = "Research deleted from this store."
        }
    }
    func copySelected() {
        guard let selected else { return }
        begin(.copying) { model, store, token in
            let current = try await store.load(id: selected.id)
            try model.check(token)
            guard current.revision == selected.revision, model.selected?.id == selected.id else { throw WebResearchStoreError.conflict }
            model.copyText(Self.report(current.session)); model.notice = "Research and source receipts copied."
        }
    }
    func openSource(id: UUID) {
        guard acceptingActions, !busy, let source = selected?.session.sources.first(where: { $0.id == id }),
              ResearchWebReader.allowed(source.originalURL) else { return }
        error = nil; notice = nil
        if openURL(source.originalURL) { notice = "Requested the original source in your browser." }
        else { error = "The original source could not be opened." }
    }

    private func research(_ original: WebResearchStoredSession, store: any WebResearchSessionAccess, token: UUID) async throws {
        var stored = original
        if stored.session.stage != .awaitingLocalSynthesis {
            guard let provider, provider.permitsResultPersistence else { throw WebResearchError.resultRetentionUnavailable }
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
                notice = "Paused with an interrupted search outcome. " + retrySummary
                try await refresh(store: store, preferred: stored.id, token: token); return
            }
            guard let latest = activeStored else { throw WebResearchStoreError.notFound }; stored = latest
        }
        try check(token)
        guard Self.hasSynthesisEvidence(stored.session) else {
            notice = "Saved the available evidence. At least two completed searches and two readable sources are needed before local synthesis."
            try await refresh(store: store, preferred: stored.id, token: token); return
        }
        guard let synthesize else {
            notice = "Sources saved. Local Qwen synthesis is not configured for this panel yet."
            try await refresh(store: store, preferred: stored.id, token: token); return
        }
        activity = .synthesizing
        let result = try await synthesize(stored.session)
        try check(token)
        let completed = try stored.session.completing(with: result)
        try await checkpoint(completed, store: store, token: token)
        try await refresh(store: store, preferred: stored.id, token: token)
        notice = "Research answer saved locally. Citation excerpts match sources; conclusions still require judgment."
    }

    private func checkpoint(_ session: WebResearchSession, store: any WebResearchSessionAccess, token: UUID) async throws {
        try check(token)
        guard let active = activeStored, active.id == session.id else { throw WebResearchStoreError.conflict }
        let saved = try await store.save(session, expectedRevision: active.revision)
        activeStored = saved
        try check(token); selected = saved
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
        let token = UUID(); operationID = token; cancellationRequested = false
        self.activity = activity; error = nil; notice = nil; activeStored = nil; researchSessionID = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do { try self.check(token); try await body(self, store, token) }
            catch {
                if !self.cancellationRequested, self.operationID == token, !Task.isCancelled { self.error = error.localizedDescription; self.notice = nil }
            }
            if !self.cancellationRequested { self.finish(token) }
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard acceptingActions, operationID == token, !cancellationRequested else { throw CancellationError() }
    }
    private func finish(_ token: UUID) {
        guard operationID == token else { return }
        activity = nil; operation = nil; cancellationRequested = false; activeStored = nil; researchSessionID = nil
    }
    private static func hasSynthesisEvidence(_ session: WebResearchSession) -> Bool {
        session.sources.count >= 2 && session.queries.filter { $0.status == .completed }.count >= 2
    }
    private static func bounded(_ text: String, bytes: Int) -> String {
        let data = Array(text.utf8.prefix(bytes)); var count = data.count
        while count > 0 { if let text = String(bytes: data[..<count], encoding: .utf8) { return text }; count -= 1 }
        return ""
    }
    static func stageLabel(_ stage: WebResearchStage) -> String {
        switch stage {
        case .planned: return "Planned"
        case .retrieving: return "Searching and reading"
        case .paused: return "Paused"
        case .awaitingLocalSynthesis: return "Sources saved · awaiting local reasoning"
        case .completed: return "Answer saved · citations checked"
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
        var lines = [session.question, stageLabel(session.stage), "Search attempts: \(session.searchAttempts)/\(session.limits.maxSearchAttempts) · Sources read: \(session.sources.count)",
            "Source text is untrusted evidence, not instructions. Matching citation excerpts does not prove the conclusions."]
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
            lines += [source.title, source.finalURL.absoluteString, "Read: \(date.string(from: source.retrievedAt)) · \(source.bytesRead) bytes · SHA-256 \(source.sha256)",
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
    private var panel: WebResearchWindow?
    init(model: WebResearchModel) { self.model = model; super.init() }
    func prepare() -> NSPanel {
        if let panel { return panel }
        let window = WebResearchWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Dot · Web research"; window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.pause = { [weak model] in model?.foregroundPause() }
        window.contentView = NSHostingView(rootView: WebResearchView(model: model))
        window.center(); panel = window; return window
    }
    func show() {
        let window = prepare(); model.open(); onVisibility?(true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: false)
    }
    func foregroundPause() { model.foregroundPause() }
    func cancel() { model.cancel() }
    func close() { model.close(); panel?.close() }
    func windowWillClose(_ notification: Notification) { model.close(); onVisibility?(false) }
}

private final class WebResearchWindow: NSPanel {
    var pause: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { pause?() }
}

struct WebResearchView: View {
    @ObservedObject var model: WebResearchModel
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
                        Text(WebResearchModel.stageLabel(item.stage)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(item.id)
                }.frame(minWidth: 140, idealWidth: 180).disabled(model.busy)
                VStack(alignment: .leading, spacing: 7) {
                    if let session = model.selected?.session {
                        Text(verbatim: session.question).font(.callout.weight(.medium)).lineLimit(3).textSelection(.enabled)
                        Text(WebResearchModel.stageLabel(session.stage)).font(.callout.weight(.medium))
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
                        Text("Saved research will appear here. A search result is not treated as a source read.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 260)
            }
            Text(model.retrySummary).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Button("Resume") { model.resume() }.disabled(!model.canResume)
                Button("Follow-up searches") { model.followUp() }.disabled(!model.canFollowUp)
                Spacer()
                Button("Copy") { model.copySelected() }.disabled(model.busy || model.selected == nil)
                Button("Delete", role: .destructive) { model.deleteSelected() }.disabled(model.busy || model.selected == nil)
            }
        }.padding(14)
    }
    @ViewBuilder private func answer(_ session: WebResearchSession) -> some View {
        if let result = session.synthesis {
            Text(verbatim: result.answer).textSelection(.enabled)
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
                if let failure = query.failure { Text(WebResearchModel.failureLabel(failure)).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        ForEach(session.reads.filter { $0.status != .completed }) { read in
            Text("\(WebResearchModel.readLabel(read.status)): \(read.url.absoluteString)\(read.failure.map { " · " + WebResearchModel.failureLabel($0) } ?? "")")
                .font(.caption).textSelection(.enabled)
        }
    }
}
