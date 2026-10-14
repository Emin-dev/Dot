import Foundation
#if os(macOS)
import Darwin
#endif

/// A reusable facade, never a reusable helper generation. Every call belongs to
/// the manager until both its result and its real resource receipts settle.
struct OwnedSearXNGSearchProvider: WebSearchProvider, Sendable {
    let providerID = "searxng-owned-keyless"
    let permitsResultPersistence = false
    private let manager: SearchRuntimeManager
    @MainActor init(manager: SearchRuntimeManager) { self.manager = manager }
    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        try await searchResponse(query: query, limit: limit).results
    }
    func searchResponse(query: String, limit: Int) async throws -> WebSearchResponse {
        try await manager.searchResponse(query: query, limit: limit)
    }
}

@MainActor
final class SearchRuntimeManager {
    enum State: Equatable { case stopped, starting, ready, stopping, unavailable }
    private(set) var state: State = .stopped
    private let factory: SearchRuntimeFactory
    private let gate: SearXNGRequestGate
    private var epoch = UUID()
    private var operation: UUID?
    private var lease: SearchGenerationLease?
    private var startup: Task<SearXNGSearchProvider, Error>?
    private var owned: SearchOwnedProcess?
    private var cleanup: Task<Void, Never>?
    private var cleanupID: UUID?
    #if DEBUG
    /// An unaccepted fixture factory is only a lifecycle test seam. It cannot
    /// construct ValidatedSearchPayload, pass audit(), or configure the App.
    struct Testing: Sendable {
        let makeProcess: @Sendable (SearchGenerationLease, @escaping @Sendable () -> Void) async throws -> SearchOwnedProcess
        var configuration: URLSessionConfiguration = .ephemeral
    }
    private var testing: Testing?
    convenience init(testing: Testing, gate: SearXNGRequestGate = SearXNGRequestGate()) {
        self.init(factory: SearchRuntimeFactory(), gate: gate)
        self.testing = testing
    }
    #endif
    init(factory: SearchRuntimeFactory = SearchRuntimeFactory()) {
        self.factory = factory; gate = SearXNGRequestGate()
    }
    private init(factory: SearchRuntimeFactory, gate: SearXNGRequestGate) {
        self.factory = factory; self.gate = gate
    }

    func searchResponse(query: String, limit: Int) async throws -> WebSearchResponse {
        try Task.checkCancellation()
        guard operation == nil else { throw SearXNGSearchError.busy }
        // Reserve on MainActor before the first suspension, including old drain
        // and audit. A concurrent call cannot acquire this generation's adapter.
        let operationID = UUID(), requestEpoch = epoch
        operation = operationID
        defer { if operation == operationID { operation = nil } }
        if let cleanup { await cleanup.value }
        try Task.checkCancellation()
        guard requestEpoch == epoch else { throw SearchRuntimeFailure.stopped }
        let launchLease = SearchGenerationLease()
        lease = launchLease; state = .starting
        let starting = Task { @MainActor [self] in try await start(launchLease) }
        startup = starting
        return try await withTaskCancellationHandler(operation: {
            do {
                let adapter = try await starting.value
                try Task.checkCancellation()
                guard isCurrent(launchLease.generation), requestEpoch == epoch else { throw SearchRuntimeFailure.stopped }
                let response = try await adapter.searchResponse(query: query, limit: limit)
                try Task.checkCancellation()
                guard isCurrent(launchLease.generation), requestEpoch == epoch else { throw SearchRuntimeFailure.stopped }
                // Validate before intentional revocation, then retain the operation
                // through real drain. Stop during drain still suppresses publication.
                let completion = revokeGeneration(failed: false)
                await completion.value
                try Task.checkCancellation()
                guard requestEpoch == epoch else { throw SearchRuntimeFailure.stopped }
                return response
            } catch {
                let completion = revokeGeneration(failed: !(error is CancellationError) && !Task.isCancelled)
                await completion.value
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let safe = error as? SearchRuntimeFailure { throw safe }
                if let safe = error as? SearXNGSearchError { throw safe }
                throw SearchRuntimeFailure.startupFailed
            }
        }, onCancel: { [weak self] in
            // This callback closes broker admission immediately, without waiting
            // for MainActor. The retained startup/owner supplies the drain receipt.
            launchLease.invalidate()
            starting.cancel()
            Task { @MainActor in
                guard let self, self.operation == operationID else { return }
                _ = self.invalidate(reason: .interruption)
            }
        })
    }

    /// Stop, willSleep, interruption and quit call this synchronously. Multiple
    /// callers observe the same independent cleanup, including during success.
    @discardableResult
    func invalidate(reason: SearchRuntimeStopReason) -> Task<Void, Never> {
        epoch = UUID()
        return revokeGeneration(failed: reason == .failure)
    }

    private func revokeGeneration(failed: Bool) -> Task<Void, Never> {
        guard let priorLease = lease else {
            if let cleanup { return cleanup }
            return Task.detached { }
        }
        priorLease.invalidate()
        lease = nil
        let priorStartup = startup; startup = nil; priorStartup?.cancel()
        let priorProcess = owned; owned = nil
        priorProcess?.requestStop()
        state = .stopping
        let id = UUID(); cleanupID = id
        let completion = Task.detached(priority: .utility) { [weak self] in
            await priorProcess?.cleanup().value
            // Startup may still be returning from audit/prepare. Startup only
            // awaits owner cleanup, never this manager task, so no wait cycle.
            _ = await priorStartup?.result
            await self?.finishedCleanup(id: id, failed: failed)
        }
        cleanup = completion
        return completion
    }

    func stop(reason: SearchRuntimeStopReason) async { await invalidate(reason: reason).value }
    private func finishedCleanup(id: UUID, failed: Bool) {
        guard cleanupID == id, lease == nil else { return }
        state = failed ? .unavailable : .stopped
    }
    private func processFailed(_ generation: UUID) {
        guard lease?.generation == generation else { return }
        _ = invalidate(reason: .failure)
    }

    private func makeProcess(_ launchLease: SearchGenerationLease) async throws -> SearchOwnedProcess {
        let onFailure: @Sendable () -> Void = { [weak self, launchLease] in
            Task { @MainActor in self?.processFailed(launchLease.generation) }
        }
        #if DEBUG
        if let testing { return try await testing.makeProcess(launchLease, onFailure) }
        #endif
        let audit = Task.detached(priority: .utility) { [factory] in try factory.audit() }
        let payload: ValidatedSearchPayload
        do {
            payload = try await withTaskCancellationHandler(operation: { try await audit.value }, onCancel: { audit.cancel() })
        } catch {
            if error is CancellationError { throw error }
            if let safe = error as? SearchRuntimeFailure { throw safe }
            throw SearchRuntimeFailure.invalidPayload
        }
        try Task.checkCancellation()
        guard lease === launchLease, launchLease.isValid else { throw SearchRuntimeFailure.stopped }
        return try SearchOwnedProcess(payload: payload, lease: launchLease, onFailure: onFailure)
    }

    private func start(_ launchLease: SearchGenerationLease) async throws -> SearXNGSearchProvider {
        let process = try await makeProcess(launchLease)
        do {
            try Task.checkCancellation()
            guard lease === launchLease, launchLease.isValid else { throw SearchRuntimeFailure.stopped }
            // Ownership and the synchronous broker invalidation callback already
            // exist before prepare can suspend or create a single descriptor.
            owned = process
            try await process.prepare()
            try Task.checkCancellation()
            guard lease === launchLease, launchLease.isValid else { throw SearchRuntimeFailure.stopped }
            // No asynchronous launch: cleanup cannot observe launched == false
            // and finish while a suspended launch later creates a helper.
            try process.run()
            while ContinuousClock.now < process.preparationDeadline {
                try Task.checkCancellation()
                guard lease === launchLease, launchLease.isValid else { throw SearchRuntimeFailure.stopped }
                if let receipt = process.receipt {
                    guard process.isRunning else { throw SearchRuntimeFailure.startupFailed }
                    let endpoint = try SearXNGOwnedEndpoint(port: receipt.port, capability: receipt.capability,
                                                          generation: receipt.generation)
                    state = .ready
                    var configuration = URLSessionConfiguration.ephemeral
                    #if DEBUG
                    if let testing { configuration = testing.configuration }
                    #endif
                    return try SearXNGSearchProvider(endpoint: endpoint, gate: gate,
                        isCurrentGeneration: { [weak self, launchLease] generation in
                            guard launchLease.isValid else { return false }
                            return await self?.isCurrent(generation) ?? false
                        }, onCancellation: { [weak self, launchLease] generation in
                            launchLease.invalidate()
                            await self?.stop(generation: generation)
                        }, cancellationLease: launchLease,
                        beforeDispatch: { [weak self, launchLease, process] in
                            try Task.checkCancellation()
                            guard launchLease.isValid, await self?.isCurrent(launchLease.generation) == true else {
                                throw SearchRuntimeFailure.stopped
                            }
                            try await process.beginSearch()
                        }, configuration: configuration)
                }
                guard process.isRunning, !process.failed else { throw SearchRuntimeFailure.startupFailed }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw SearchRuntimeFailure.startupTimeout
        } catch {
            launchLease.invalidate(); process.requestStop()
            await process.cleanup().value
            throw error
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        lease?.generation == generation && lease?.isValid == true && owned?.isRunning == true && owned?.failed == false
    }
    private func stop(generation: UUID) async {
        if lease?.generation == generation { await stop(reason: .interruption) }
        else if let cleanup { await cleanup.value }
    }
}

/// The existing helper owner also owns its broker, from before preparation until
/// real broker, process and pipe receipts. No timeout/flag licenses replacement.
final class SearchOwnedProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lease: SearchGenerationLease
    private let broker: SearchEgressBroker
    let preparationDeadline: ContinuousClock.Instant
    private let bootstrap: URL
    private let payloadRoot: URL
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var directory: URL?
    private var identity: SearchPrivateDirectoryIdentity?
    private var egress: SearchEgressEndpoint?
    private var reader: SearchControlPipeReader?
    private var ready: SearchReadyReceipt?
    private var protocolFailed = false
    private var launched = false
    private var controlClosed = false
    private var cleanupTask: Task<Void, Never>?
    #if DEBUG
    private var beforeControlWrite: (@Sendable () throws -> Void)?
    #endif

    convenience init(payload: ValidatedSearchPayload, lease: SearchGenerationLease,
                     onFailure: @escaping @Sendable () -> Void) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(SearchEgressBroker.preparationSeconds))
        let broker = try SearchEgressBroker(generation: lease.generation)
        self.init(bootstrap: payload.bootstrap, payloadRoot: payload.root, lease: lease,
                  broker: broker, deadline: deadline, onFailure: onFailure)
    }
    private init(bootstrap: URL, payloadRoot: URL, lease: SearchGenerationLease, broker: SearchEgressBroker,
                 deadline: ContinuousClock.Instant, onFailure: @escaping @Sendable () -> Void) {
        self.bootstrap = bootstrap; self.payloadRoot = payloadRoot
        self.lease = lease; self.broker = broker; preparationDeadline = deadline; self.onFailure = onFailure
        _ = lease.register { broker.invalidate() }
        process.terminationHandler = { [weak self] _ in
            self?.lease.invalidate()
            self?.onFailure()
        }
    }
    #if DEBUG
    /// Unaccepted local executable fixture only, never production audit/readiness.
    convenience init(testingBootstrap: URL, fixtureRoot: URL, lease: SearchGenerationLease,
                     broker: SearchEgressBroker, preparationDeadline: ContinuousClock.Instant? = nil,
                     beforeControlWrite: (@Sendable () throws -> Void)? = nil,
                     onFailure: @escaping @Sendable () -> Void) {
        self.init(bootstrap: testingBootstrap, payloadRoot: fixtureRoot, lease: lease, broker: broker,
                  deadline: preparationDeadline ?? ContinuousClock.now.advanced(by: .seconds(SearchEgressBroker.preparationSeconds)),
                  onFailure: onFailure)
        self.beforeControlWrite = beforeControlWrite
    }
    /// In-memory observation of this owner's existing handoff, never preparation
    /// or admission. Callers must keep its capability out of diagnostics.
    func testPreparedEndpoint() -> SearchEgressEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return lease.isValid ? egress : nil
    }
    #endif

    var isRunning: Bool { process.isRunning }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return protocolFailed }
    var receipt: SearchReadyReceipt? { lock.lock(); defer { lock.unlock() }; return lease.isValid ? ready : nil }

    func prepare() async throws {
        let endpoint = try await broker.prepare()
        try Task.checkCancellation()
        guard lease.isValid else { throw SearchRuntimeFailure.stopped }
        storeEgress(endpoint)
    }
    private func storeEgress(_ endpoint: SearchEgressEndpoint) {
        lock.lock(); egress = endpoint; lock.unlock()
    }
    func beginSearch() async throws { try await broker.beginSearch() }

    @MainActor func run() throws {
        guard lease.isValid, ContinuousClock.now < preparationDeadline else { throw SearchRuntimeFailure.stopped }
        guard let egress else { throw SearchRuntimeFailure.startupFailed }
        do {
            let requested = FileManager.default.temporaryDirectory.appendingPathComponent("dot-search-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let root = requested.resolvingSymlinksInPath().standardizedFileURL
            directory = root
            identity = try SearchPrivateDirectoryIdentity(root)
            process.executableURL = bootstrap
            process.arguments = ["--payload", payloadRoot.path, "--state-root", root.path, "--egress-port", String(egress.port)]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                                   "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
            process.currentDirectoryURL = root
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            #if os(macOS)
            // A bootstrap may close stdin before this one bounded write. Turn
            // broken-pipe delivery into EPIPE rather than terminating the App.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw SearchRuntimeFailure.startupFailed
            }
            #endif
            try Task.checkCancellation()
            guard lease.isValid else { throw SearchRuntimeFailure.stopped }
            try process.run()
            lock.lock(); launched = true; lock.unlock()
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            let newReader = try SearchControlPipeReader(handle: output.fileHandleForReading) { [weak self] line in self?.receive(line) }
            lock.lock(); reader = newReader; lock.unlock()
            #if DEBUG
            try beforeControlWrite?()
            #endif
            // All values come from fixed internal owners. UUID is canonical
            // uppercase; Basic is canonical ASCII. Only the port goes in argv.
            let start = "{\"protocol\":1,\"command\":\"start\",\"generation\":\"\(lease.generation.uuidString)\",\"egress_port\":\(egress.port),\"proxy_authorization\":\"\(egress.proxyAuthorization)\"}\n"
            try input.fileHandleForWriting.write(contentsOf: Data(start.utf8))
        } catch {
            requestStop()
            if error is CancellationError { throw error }
            throw SearchRuntimeFailure.startupFailed
        }
    }

    private func receive(_ line: Data?) {
        // Normal settlement closes stdin first; EOF/termination caused by this
        // teardown is not a fresh failure and cannot poison the next operation.
        lock.lock(); let stopping = controlClosed; lock.unlock()
        if stopping { return }
        do {
            guard let line else { throw SearchRuntimeFailure.invalidControl }
            let event = try SearchControlEvent.decode(line, generation: lease.generation, ownedPID: process.processIdentifier)
            lock.lock()
            switch event {
            case .ready(let receipt):
                if ready == nil, lease.isValid, process.isRunning { ready = receipt; lock.unlock(); return }
            case .stopped:
                if controlClosed { lock.unlock(); return }
            case .failed: break
            }
            lock.unlock()
            throw SearchRuntimeFailure.invalidControl
        } catch {
            lock.lock(); protocolFailed = true; ready = nil; lock.unlock()
            lease.invalidate(); requestStop(); onFailure()
        }
    }

    func requestStop() {
        lease.invalidate()
        lock.lock(); let shouldClose = !controlClosed; controlClosed = true; ready = nil; lock.unlock()
        if shouldClose { try? input.fileHandleForWriting.close() }
    }
    private func cleanupSnapshot() -> (launched: Bool, reader: SearchControlPipeReader?, directory: URL?, identity: SearchPrivateDirectoryIdentity?) {
        lock.lock(); defer { lock.unlock() }; return (launched, reader, directory, identity)
    }
    func cleanup() -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        if let cleanupTask { return cleanupTask }
        let task = Task.detached(priority: .utility) { [self] in
            requestStop()
            // Drain begins even on prepare/run failure, independently of the
            // helper wait. A held resolver or socket receipt always keeps it open.
            let brokerCleanup = Task.detached(priority: .utility) { [broker] in await broker.drain() }
            let snapshot = cleanupSnapshot()
            if snapshot.launched { process.waitUntilExit() }
            await snapshot.reader?.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
            await brokerCleanup.value
            if let directory = snapshot.directory { snapshot.identity?.removeIfEmpty(directory) }
        }
        cleanupTask = task
        return task
    }
}

private struct SearchPrivateDirectoryIdentity: Sendable {
    let device: UInt64
    let inode: UInt64
    init(_ url: URL) throws {
        #if os(macOS)
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o777 == 0o700, value.st_uid == getuid() else { throw SearchRuntimeFailure.invalidPayload }
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino)
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }
    func removeIfEmpty(_ url: URL) {
        #if os(macOS)
        guard let current = try? SearchPrivateDirectoryIdentity(url), current.device == device, current.inode == inode else { return }
        _ = rmdir(url.path)
        #endif
    }
}

/// Nonblocking reads are serialized with close. One oversized/malformed frame
/// permanently fails this launch rather than filling memory or silently skipping.
private final class SearchControlPipeReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.dot.search-control")
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let deliver: @Sendable (Data?) -> Void
    private var buffer = Data()
    private var totalBytes = 0
    private var finished = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    init(handle: FileHandle, deliver: @escaping @Sendable (Data?) -> Void) throws {
        #if os(macOS)
        let fd = dup(handle.fileDescriptor)
        guard fd >= 0 else { throw SearchRuntimeFailure.startupFailed }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd); throw SearchRuntimeFailure.startupFailed
        }
        descriptor = fd; self.deliver = deliver
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [weak self] in Darwin.close(fd); self?.didClose() }
        source.resume()
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }
    private func readAvailable() {
        #if os(macOS)
        guard !finished else { return }
        var bytes = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            guard count > 0 else { finish(notify: true); return }
            totalBytes += count
            guard totalBytes <= 4096 else { finish(notify: true); return }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    guard !buffer.isEmpty else { finish(notify: true); return }
                    deliver(buffer); buffer.removeAll(keepingCapacity: true)
                } else {
                    guard buffer.count < 2047 else { finish(notify: true); return }
                    buffer.append(byte)
                }
            }
        }
        #endif
    }
    private func finish(notify: Bool) {
        guard !finished else { return }; finished = true
        buffer.removeAll(); source.cancel()
        if notify { deliver(nil) }
    }
    private func didClose() {
        closed = true
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if closed { continuation.resume() }
                else { closeWaiters.append(continuation); finish(notify: false) }
            }
        }
    }
    deinit { source.cancel() }
}
