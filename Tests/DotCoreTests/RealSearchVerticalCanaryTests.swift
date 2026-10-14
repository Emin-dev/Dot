import Foundation
import XCTest
import CryptoKit
import CoreFoundation
#if os(macOS)
import Darwin
#endif
#if SWIFT_PACKAGE
@testable import DotCore
#endif

#if DEBUG && os(macOS)
/// Opt-in, unaccepted build-fixture admission only. The real manager, owner,
/// bootstrap, helper, Waitress and pinned transport execute; no gateway response
/// or CONNECT transport is substituted. Native execution is a separate gate.
@MainActor
final class RealSearchVerticalCanaryTests: XCTestCase {
    func testSuccessCloseReceipts() async throws { try await run(.successClose) }
    func testSuccessHelperExit() async throws { try await run(.successExit) }
    func testFullInitializationStartupFailure() async throws { try await run(.startupFailure) }
    func testInFlightCancellation() async throws { try await run(.cancellation) }
    func testUntrustedCertificate() async throws { try await run(.untrusted) }
    func testWrongHostname() async throws { try await run(.wrongHost) }
    func testPrecedingManagerCapabilityReplay() async throws { try await run(.replay) }

    private func run(_ scenario: VerticalScenario) async throws {
        #if !arch(arm64)
        throw XCTSkip("Real Search vertical canary requires native Darwin arm64")
        #else
        let environment = ProcessInfo.processInfo.environment
        if environment["DOT_REAL_SEARCH_FIXTURE_CONFIG"] == nil,
           environment["DOT_REAL_SEARCH_FIXTURE_CONFIG_SHA256"] == nil {
            throw XCTSkip("Real Search vertical fixture was not requested")
        }
        let fixture: VerticalFixture
        do { fixture = try VerticalFixture(environment: environment, scenario: scenario) }
        catch { XCTFail("Real Search fixture identity/configuration was rejected"); return }
        let harness = VerticalHarness(fixture: fixture)
        let manager = harness.manager()
        var failure: VerticalFailure?
        do {
            try fixture.verifyIdentities()
            try await exercise(scenario, fixture: fixture, harness: harness, manager: manager)
        } catch { failure = (error as? VerticalFailure) ?? .observation }
        // These waits have no fabricated deadline receipt. The controller owns
        // the actual XCTest process and treats an unsettled child as failed.
        await harness.cleanup(manager: manager)
        do {
            try await harness.requireAllSettled()
            try fixture.verifyIdentities()
            try fixture.requireNonsecretInputs(records: harness.records)
            try harness.removeOnlyObservedMarkers()
            try fixture.writeResult(failure: failure, records: harness.records,
                                    observations: harness.observations)
        } catch {
            failure = failure ?? (error as? VerticalFailure) ?? .identity
        }
        if failure != nil { XCTFail("Real Search vertical canary failed; no acceptance was produced") }
        #endif
    }

    private func exercise(_ scenario: VerticalScenario, fixture: VerticalFixture,
                          harness: VerticalHarness, manager: SearchRuntimeManager) async throws {
        let search = harness.start(manager: manager)
        try await eventually { !harness.records.isEmpty }
        let first = try harness.record(0)
        if scenario == .startupFailure {
            try await eventually { try first.state.initialized() }
            try await eventually { !first.owner.isRunning }
            try await heldCloseProof(first, search: search, harness: harness, manager: manager)
            let held = await first.broker.testSnapshot()
            try require(held.requestDeadline == nil && held.admissions == 0 && held.connectAttempts == 0)
            let origin = try await fixture.control.snapshot()
            try require(origin.requests == 0 && origin.handshakes == 0 && origin.sniCount == 0)
            await first.broker.testReleaseCloseReceipts()
            try require(await search.value.isFailure)
            try await harness.requireSettled(first)
            try require(try first.state.supervisorReturned())
            harness.note("full_initialization_startup_failure", true)
            harness.note("provider_dispatch_suppressed", true)
            return
        }
        if scenario == .untrusted || scenario == .wrongHost {
            try await eventually { try first.state.initialized() }
            first.state.rememberGatewayIfPresent()
            try require(await search.value.isFailure)
            try await harness.requireSettled(first)
            let snapshot = await first.broker.testSnapshot()
            let origin = try await fixture.control.snapshot()
            try require(snapshot.admissions > 0 && snapshot.connectAttempts > 0 && snapshot.upstreamBytes > 0)
            try require(origin.requests == 0 && origin.sniCount > 0 && origin.fixedSNIOnly && origin.credentialFree)
            try require(try first.state.supervisorReturned())
            harness.note("tls_negative_no_http_or_fallback", true)
            return
        }
        try await requestHeld(first, ordinal: 1, fixture: fixture)
        let firstEndpoint = try preparedEndpoint(first)
        first.noteListener(firstEndpoint.port)
        if scenario == .cancellation {
            search.cancel()
            // Task cancellation synchronously executes the manager's registered
            // lease invalidation before any MainActor cleanup observer is made.
            try require(!first.lease.isValid)
            let stop = manager.invalidate(reason: .userStop)
            let quit = manager.invalidate(reason: .quit)
            let observed = VerticalCompletion()
            let observer = Task { await stop.value; observed.finish() }
            observer.cancel()
            try await eventually { !first.owner.isRunning }
            try await heldCloseProof(first, search: search, harness: harness, manager: manager)
            try require(!observed.isFinished)
            let before = await first.broker.testSnapshot()
            try require(before.deferredCloseReceipts > 0 && !before.drained)
            await first.broker.testReleaseCloseReceipts()
            await stop.value; await quit.value; await observer.value
            let result = await search.value
            try require(result.isCancelled && observed.isFinished)
            try await harness.requireSettled(first)
            let after = await first.broker.testSnapshot()
            try require(after.admissions == before.admissions && after.connectAttempts == before.connectAttempts)
            _ = try await fixture.control.release()
            try require(try first.state.supervisorReturned())
            harness.note("cancelled_search_and_observer_waited_for_real_cleanup", true)
            harness.note("no_result_published", true)
            return
        }
        _ = try await fixture.control.release()
        if scenario == .successClose {
            try await heldCloseProof(first, search: search, harness: harness, manager: manager)
            await first.broker.testReleaseCloseReceipts()
            harness.note("success_waited_for_actual_close_receipts", true)
        } else if scenario == .successExit {
            try await eventually {
                let snapshot = await first.broker.testSnapshot()
                guard snapshot.drained else { return false }
                return try first.state.supervisorReturned()
            }
            try require(first.owner.isRunning && !harness.completion(0).isFinished)
            try require(manager.state == .stopping)
            try await requireBusy(manager, harness: harness)
            harness.note("live_helper_observed_after_broker_drain", true)
        }
        try requireSuccess(await search.value)
        try await harness.requireSettled(first)
        try require(try first.state.initialized() && first.state.supervisorReturned())
        if scenario != .replay {
            try await requirePositiveOrigin(fixture, requests: 1)
            return
        }
        let oldDeadline = try deadline(await first.broker.testSnapshot())
        // The preceding manager-owned capability stays in this stack only.
        // Never stringify it in an assertion, failure, JSON, URL or argument.
        try fixture.verifyIdentities()
        let secondStart = ProcessInfo.processInfo.systemUptime
        let next = harness.start(manager: manager)
        try await eventually { harness.records.count == 2 }
        let second = try harness.record(1)
        try await requestHeld(second, ordinal: 2, fixture: fixture)
        let currentEndpoint = try preparedEndpoint(second)
        second.noteListener(currentEndpoint.port)
        try require(first.lease.generation != second.lease.generation)
        try require(firstEndpoint.proxyAuthorization != currentEndpoint.proxyAuthorization)
        let before = await second.broker.testSnapshot()
        let newDeadline = try deadline(before)
        try require(newDeadline > oldDeadline && newDeadline >= secondStart + SearchEgressBroker.searchSeconds)
        let originBefore = try await fixture.control.snapshot()
        let rejected = try await Task.detached {
            try VerticalSocket.rejectReplay(port: currentEndpoint.port,
                                            authorization: firstEndpoint.proxyAuthorization)
        }.value
        try require(rejected)
        try await eventually {
            let value = await second.broker.testSnapshot()
            return value.headers == before.headers && value.sockets == before.sockets
        }
        let after = await second.broker.testSnapshot()
        let originAfter = try await fixture.control.snapshot()
        try require(after.admissions == before.admissions && after.connectAttempts == before.connectAttempts)
        try require(originAfter.requests == originBefore.requests && originAfter.handshakes == originBefore.handshakes
                    && originAfter.sniCount == originBefore.sniCount)
        try require(second.lease.isValid && second.owner.isRunning && !harness.completion(1).isFinished)
        try require(after.tunnelPhases == before.tunnelPhases && after.headers == before.headers)
        harness.note("preceding_manager_broker_capability_replay_rejected", true)
        harness.note("fresh_lease_capability_and_deadline", true)
        _ = try await fixture.control.release()
        try requireSuccess(await next.value)
        try await harness.requireSettled(second)
        try require(try second.state.initialized() && second.state.supervisorReturned())
        try await requirePositiveOrigin(fixture, requests: 2)
    }

    private func requestHeld(_ record: VerticalRecord, ordinal: Int, fixture: VerticalFixture) async throws {
        try await eventually {
            let snapshot = try await fixture.control.snapshot()
            return snapshot.requests == ordinal
        }
        let origin = try await fixture.control.snapshot()
        let broker = await record.broker.testSnapshot()
        try require(origin.handshakes == ordinal && origin.sniCount == ordinal && origin.fixedSNIOnly
                    && origin.fixedRequestOnly && origin.credentialFree)
        try require(record.lease.isValid && record.owner.isRunning && record.owner.receipt != nil)
        record.state.rememberGatewayIfPresent()
        try require(broker.admissions == 1 && broker.connectAttempts == 1 && broker.requestDeadline != nil)
        try require(broker.upstreamBytes > 0 && broker.downstreamBytes > 0)
        try require(try record.state.initialized())
    }
    private func heldCloseProof(_ record: VerticalRecord, search: Task<VerticalOutcome, Never>,
                                harness: VerticalHarness, manager: SearchRuntimeManager) async throws {
        try await eventually {
            let value = await record.broker.testSnapshot()
            return value.deferredCloseReceipts > 0 && !record.lease.isValid
        }
        let snapshot = await record.broker.testSnapshot()
        try require(snapshot.actualCloses > 0 && !snapshot.drained)
        try require(!record.lease.isValid && record.owner.receipt == nil)
        try require(!harness.completion(harness.records.count - 1).isFinished)
        // A failing startup can still be inside start() awaiting owner cleanup;
        // the manager nevertheless retains its operation and rejects replacement.
        if harness.fixture.scenario != .startupFailure { try require(manager.state == .stopping) }
        try await requireBusy(manager, harness: harness)
    }
    private func requireBusy(_ manager: SearchRuntimeManager, harness: VerticalHarness) async throws {
        let count = harness.records.count
        do {
            _ = try await manager.searchResponse(query: "build-only-synthetic-query", limit: 1)
            throw VerticalFailure.publication
        } catch SearXNGSearchError.busy { }
        catch { throw VerticalFailure.publication }
        try require(harness.records.count == count)
    }
    private func requirePositiveOrigin(_ fixture: VerticalFixture, requests: Int) async throws {
        let origin = try await fixture.control.snapshot()
        try require(origin.requests == requests && origin.handshakes == requests && origin.sniCount == requests
                    && origin.fixedSNIOnly && origin.fixedRequestOnly && origin.credentialFree)
    }
    private func preparedEndpoint(_ record: VerticalRecord) throws -> SearchEgressEndpoint {
        guard let endpoint = record.owner.testPreparedEndpoint() else { throw VerticalFailure.observation }
        return endpoint
    }
    private func deadline(_ snapshot: SearchEgressBroker.Snapshot) throws -> TimeInterval {
        guard let deadline = snapshot.requestDeadline else { throw VerticalFailure.observation }
        return deadline
    }
    private func requireSuccess(_ outcome: VerticalOutcome) throws {
        guard case .success(let response) = outcome, response.coverage == .complete,
              response.unavailableEngineIDs.isEmpty, response.results.count == 1,
              let result = response.results.first,
              result.url.absoluteString == "https://example.org/fixture",
              result.title == "Synthetic result", result.snippet == "Offline parser fixture" else {
            throw VerticalFailure.publication
        }
    }
    private func eventually(_ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(40))
        while !(try await predicate()) {
            guard ContinuousClock.now < end else { throw VerticalFailure.observation }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum VerticalScenario: String, Sendable {
    case successClose = "success-close", successExit = "success-exit", startupFailure = "startup-failure"
    case cancellation, untrusted, wrongHost = "wrong-host", replay
    var holdsCloses: Bool { self == .successClose || self == .startupFailure || self == .cancellation }
}
private enum VerticalFailure: String, Error {
    case configuration, identity, observation, publication, control, socket, cleanup
}
private func require(_ condition: Bool) throws { if !condition { throw VerticalFailure.observation } }
private enum VerticalOutcome: Sendable {
    case success(WebSearchResponse), cancelled, failure
    var isFailure: Bool { if case .failure = self { return true }; return false }
    var isCancelled: Bool { if case .cancelled = self { return true }; return false }
}
private final class VerticalCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
private final class VerticalRecord: @unchecked Sendable {
    let lease: SearchGenerationLease
    let broker: SearchEgressBroker
    let owner: SearchOwnedProcess
    let state: VerticalStateObservation
    private let lock = NSLock()
    private var port: UInt16?
    init(lease: SearchGenerationLease, broker: SearchEgressBroker, owner: SearchOwnedProcess,
         state: VerticalStateObservation) {
        self.lease = lease; self.broker = broker; self.owner = owner; self.state = state
    }
    func noteListener(_ value: UInt16) { lock.lock(); port = value; lock.unlock() }
    var listenerPort: UInt16? { lock.lock(); defer { lock.unlock() }; return port ?? state.listenerPort }
}
private final class VerticalHarness: @unchecked Sendable {
    let fixture: VerticalFixture
    private let lock = NSLock()
    private var stored: [VerticalRecord] = []
    private var searches: [Task<VerticalOutcome, Never>] = []
    private var completions: [VerticalCompletion] = []
    private var evidence: [String: Any] = [:]
    var records: [VerticalRecord] { lock.lock(); defer { lock.unlock() }; return stored }
    var observations: [String: Any] { lock.lock(); defer { lock.unlock() }; return evidence }
    init(fixture: VerticalFixture) { self.fixture = fixture }
    private func append(_ value: VerticalRecord) { lock.lock(); stored.append(value); lock.unlock() }
    func note(_ name: String, _ value: Any) { lock.lock(); evidence[name] = value; lock.unlock() }
    func record(_ index: Int) throws -> VerticalRecord {
        let values = records
        guard values.indices.contains(index) else { throw VerticalFailure.observation }
        return values[index]
    }
    func completion(_ index: Int) -> VerticalCompletion { lock.lock(); defer { lock.unlock() }; return completions[index] }
    private func add(_ task: Task<VerticalOutcome, Never>, completion: VerticalCompletion) {
        lock.lock(); searches.append(task); completions.append(completion); lock.unlock()
    }
    private func tasks() -> [Task<VerticalOutcome, Never>] { lock.lock(); defer { lock.unlock() }; return searches }
    @MainActor func manager() -> SearchRuntimeManager {
        // Leave Testing.configuration at its actual ephemeral URLSession default.
        SearchRuntimeManager(testing: .init(makeProcess: { [self] lease, onFailure in
            let state = try VerticalStateObservation(parent: fixture.ownerStateParent, overlay: fixture.overlayRoot)
            let broker = try SearchEgressBroker(generation: lease.generation,
                testing: .init(resolve: { ["8.8.8.8"] }, loopbackPort: fixture.originPort,
                               holdCloseReceipts: fixture.scenario.holdsCloses))
            let owner = SearchOwnedProcess(testingBootstrap: fixture.bootstrap, fixtureRoot: fixture.overlayRoot,
                lease: lease, broker: broker, beforeControlWrite: { try state.capture() }, onFailure: onFailure)
            state.bind(owner)
            append(VerticalRecord(lease: lease, broker: broker, owner: owner, state: state))
            return owner
        }))
    }
    @MainActor func start(manager: SearchRuntimeManager) -> Task<VerticalOutcome, Never> {
        let completed = VerticalCompletion()
        let search = Task { @MainActor in
            defer { completed.finish() }
            do { return VerticalOutcome.success(try await manager.searchResponse(query: "build-only-synthetic-query", limit: 1)) }
            catch is CancellationError { return .cancelled }
            catch { return .failure }
        }
        add(search, completion: completed)
        return search
    }
    @MainActor func cleanup(manager: SearchRuntimeManager) async {
        let all = tasks()
        for task in all where !task.isCancelled { task.cancel() }
        let cleanup = manager.invalidate(reason: .quit)
        for record in records { await record.broker.testReleaseCloseReceipts() }
        for record in records { await record.owner.cleanup().value }
        await cleanup.value
        for task in all { _ = await task.value }
    }
    func requireSettled(_ record: VerticalRecord) async throws {
        await record.owner.cleanup().value
        let snapshot = await record.broker.testSnapshot()
        try require(!record.lease.isValid && !record.owner.isRunning && record.owner.receipt == nil)
        try require(record.owner.testPreparedEndpoint() == nil)
        try require(snapshot.drained && snapshot.sockets == 0 && snapshot.headers == 0
                    && snapshot.pendingWrites == 0 && snapshot.deferredCloseReceipts == 0
                    && snapshot.listenerDescriptor == nil)
        if let index = records.firstIndex(where: { $0 === record }) {
            let prefix = "generation_" + String(index + 1) + "_"
            note(prefix + "actual_closes", snapshot.actualCloses)
            note(prefix + "authenticated_admissions", snapshot.admissions)
            note(prefix + "connect_attempts", snapshot.connectAttempts)
            note(prefix + "upstream_bytes", snapshot.upstreamBytes)
            note(prefix + "downstream_bytes", snapshot.downstreamBytes)
            note(prefix + "broker_drained", snapshot.drained)
            note(prefix + "helper_exited", !record.owner.isRunning)
            note(prefix + "lease_invalidated", !record.lease.isValid)
            note(prefix + "sockets", snapshot.sockets)
            note(prefix + "headers", snapshot.headers)
            note(prefix + "pending_writes", snapshot.pendingWrites)
            note(prefix + "deferred_close_receipts", snapshot.deferredCloseReceipts)
        }
        if let port = record.listenerPort {
            try require(try await Task.detached { try VerticalSocket.refuses(port: port) }.value)
        }
    }
    func requireAllSettled() async throws { for record in records { try await requireSettled(record) } }
    func removeOnlyObservedMarkers() throws { for record in records { try record.state.removeMarkersAndEmptyDirectory() } }
}

private enum VerticalJSON {
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func canonical(_ value: Any, newline: Bool = true) throws -> Data {
        var raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        if newline { raw.append(10) }
        return raw
    }
    static func object(_ data: Data, keys: Set<String>? = nil) throws -> [String: Any] {
        guard data.count <= 8_000_000,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              keys == nil || Set(value.keys) == keys,
              try canonical(value) == data else { throw VerticalFailure.configuration }
        return value
    }
    static func integer(_ value: Any?, minimum: Int = 0, maximum: Int = 1_000_000) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) != "d", String(cString: number.objCType) != "f",
              number.int64Value >= Int64(minimum), number.int64Value <= Int64(maximum) else { throw VerticalFailure.configuration }
        return number.intValue
    }
    static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw VerticalFailure.configuration }
        return number.boolValue
    }
    static func string(_ value: Any?, maximum: Int = 4096) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximum,
              text.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw VerticalFailure.configuration }
        return text
    }
    static func hash(_ value: Any?) throws -> String {
        let text = try string(value, maximum: 64)
        guard SearchPayloadAudit.isHash(text) else { throw VerticalFailure.identity }
        return text
    }
    static func path(_ value: Any?, exists: Bool = true) throws -> URL {
        let text = try string(value)
        let url = URL(fileURLWithPath: text)
        guard text.hasPrefix("/"), url.standardizedFileURL.path == text,
              url.resolvingSymlinksInPath().path == text,
              !url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              !exists || FileManager.default.fileExists(atPath: text) else { throw VerticalFailure.configuration }
        return url
    }
    static func read(_ url: URL, limit: Int) throws -> Data { try SearchPayloadAudit.boundedFile(url, limit: limit) }
    static func fileHash(_ url: URL) throws -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_size >= 0 else { throw VerticalFailure.identity }
        return try SearchPayloadAudit.hashFile(url, expectedSize: value.st_size)
    }
}

private final class VerticalInventory {
    struct File {
        let path: String
        let sha256: String
        let size: Int64
        let mode: mode_t
    }
    let root: URL
    let path: URL
    let expectedHash: String
    let kind: String
    let files: [File]
    private let reader: SearchPayloadAudit.Reader
    private let rawReader: SearchPayloadAudit.Reader
    init(root: URL, path: URL, expectedHash: String, kind: String) throws {
        self.root = root; self.path = path; self.expectedHash = expectedHash; self.kind = kind
        reader = try SearchPayloadAudit.Reader(root: root)
        rawReader = try SearchPayloadAudit.Reader(root: path.deletingLastPathComponent())
        let raw = try rawReader.data(path.lastPathComponent, limit: 8_000_000)
        guard VerticalJSON.sha(raw) == expectedHash else { throw VerticalFailure.identity }
        let object = try VerticalJSON.object(raw, keys: ["schema", "kind", "files", "records_sha256"])
        guard try VerticalJSON.integer(object["schema"]) == 1,
              try VerticalJSON.string(object["kind"]) == kind,
              let records = object["files"] as? [[String: Any]], !records.isEmpty, records.count <= 20_000,
              try VerticalJSON.sha(VerticalJSON.canonical(records, newline: false)) == VerticalJSON.hash(object["records_sha256"]) else {
            throw VerticalFailure.identity
        }
        var decoded: [File] = []
        for record in records {
            guard Set(record.keys) == ["path", "sha256", "size", "mode"] else { throw VerticalFailure.identity }
            let name = try VerticalJSON.string(record["path"])
            guard SearchPayloadAudit.validRelativePath(name) else { throw VerticalFailure.identity }
            let modeText = try VerticalJSON.string(record["mode"])
            guard modeText == "0o644" || modeText == "0o755" else { throw VerticalFailure.identity }
            decoded.append(File(path: name, sha256: try VerticalJSON.hash(record["sha256"]),
                                size: Int64(try VerticalJSON.integer(record["size"], maximum: 2_000_000_000)),
                                mode: modeText == "0o644" ? 0o644 : 0o755))
        }
        guard decoded.map(\.path) == decoded.map(\.path).sorted(), Set(decoded.map(\.path)).count == decoded.count else {
            throw VerticalFailure.identity
        }
        files = decoded
    }
    func verify() throws {
        guard VerticalJSON.sha(try rawReader.data(path.lastPathComponent, limit: 8_000_000)) == expectedHash else {
            throw VerticalFailure.identity
        }
        for record in files {
            guard try reader.hash(record.path, expectedSize: record.size) == record.sha256 else { throw VerticalFailure.identity }
            var info = stat()
            guard lstat(root.appendingPathComponent(record.path).path, &info) == 0,
                  info.st_mode & 0o7777 == record.mode else { throw VerticalFailure.identity }
        }
        let names = Set(files.map(\.path))
        if kind == "real-search-runtime-overlay-inventory" {
            guard try reader.checkTree() == names else { throw VerticalFailure.identity }
            var expectedDirectories = Set<String>()
            for file in files {
                let components = file.path.split(separator: "/")
                if components.count > 1 {
                    for length in 1..<components.count { expectedDirectories.insert(components.prefix(length).joined(separator: "/")) }
                }
            }
            guard let tree = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw VerticalFailure.identity
            }
            var actualDirectories = Set<String>()
            for case let url as URL in tree {
                var value = stat()
                guard lstat(url.path, &value) == 0 else { throw VerticalFailure.identity }
                if value.st_mode & S_IFMT == S_IFDIR {
                    actualDirectories.insert(String(url.path.dropFirst(root.path.count + 1)))
                }
            }
            guard actualDirectories == expectedDirectories else { throw VerticalFailure.identity }
        } else {
            // Compile closure: all source and test Swift files are present, even
            // when this invocation runs just one opt-in XCTest method.
            for prefix in ["src", "Tests/DotCoreTests"] {
                guard let children = FileManager.default.enumerator(at: root.appendingPathComponent(prefix),
                    includingPropertiesForKeys: nil) else { throw VerticalFailure.identity }
                var actual = Set<String>()
                for case let url as URL in children {
                    var info = stat()
                    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw VerticalFailure.identity }
                    if url.path.hasSuffix(".swift") { actual.insert(String(url.path.dropFirst(root.path.count + 1))) }
                }
                let recorded = Set(names.filter { $0.hasPrefix(prefix + "/") && $0.hasSuffix(".swift") })
                guard actual == recorded else { throw VerticalFailure.identity }
            }
            let required: Set<String> = ["Package.swift", "Resources/Search/dot_search.py", "Resources/Search/search.sb",
                "packaging/search/dot-search-bootstrap.c", "packaging/search/search-lock-native-owner.json",
                "scripts/build_search_bootstrap.sh", "scripts/search_proxy_canary_support.py",
                "scripts/prepare_search_real_canary_payload.py", "scripts/verify_search_real_vertical_canary.sh",
                "Tests/Fixtures/search_real_vertical_entry.py", "Tests/Fixtures/search_real_vertical_fixture.py",
                "Tests/Fixtures/search_proxy_fixture_support.py", "Tests/Fixtures/search_proxy_pinned_hashes.json",
                "Tests/DotCoreTests/RealSearchVerticalCanaryTests.swift"]
            guard required.isSubset(of: names) else { throw VerticalFailure.identity }
        }
    }
    func hash(for name: String) throws -> String {
        guard let file = files.first(where: { $0.path == name }) else { throw VerticalFailure.identity }
        return file.sha256
    }
}

private final class VerticalFixture: @unchecked Sendable {
    let scenario: VerticalScenario
    let overlayRoot: URL
    let ownerStateParent: URL
    let originPort: UInt16
    let bootstrap: URL
    let control: VerticalControl
    private let source: VerticalInventory
    private let overlay: VerticalInventory
    private let config: URL
    private let configHash: String
    private let configReader: SearchPayloadAudit.Reader
    private let executable: URL
    private let executableHash: String
    private let executableReader: SearchPayloadAudit.Reader
    private let executableSize: Int64
    private let result: URL
    init(environment: [String: String], scenario: VerticalScenario) throws {
        config = try VerticalJSON.path(environment["DOT_REAL_SEARCH_FIXTURE_CONFIG"])
        configHash = try VerticalJSON.hash(environment["DOT_REAL_SEARCH_FIXTURE_CONFIG_SHA256"])
        configReader = try SearchPayloadAudit.Reader(root: config.deletingLastPathComponent())
        let raw = try configReader.data(config.lastPathComponent, limit: 16_384)
        guard VerticalJSON.sha(raw) == configHash else { throw VerticalFailure.identity }
        let value = try VerticalJSON.object(raw, keys: ["schema", "overlay_root", "overlay_inventory_path",
            "overlay_inventory_sha256", "bootstrap_sha256", "source_root", "source_records_path",
            "source_records_sha256", "test_executable_sha256", "scenario", "origin_port", "control_port",
            "owner_state_parent", "result_path"])
        guard try VerticalJSON.integer(value["schema"]) == 1,
              try VerticalJSON.string(value["scenario"]) == scenario.rawValue else { throw VerticalFailure.configuration }
        self.scenario = scenario
        overlayRoot = try VerticalJSON.path(value["overlay_root"])
        ownerStateParent = try VerticalJSON.path(value["owner_state_parent"])
        originPort = UInt16(try VerticalJSON.integer(value["origin_port"], minimum: 1, maximum: 65535))
        let controlPort = UInt16(try VerticalJSON.integer(value["control_port"], minimum: 1, maximum: 65535))
        guard controlPort != originPort else { throw VerticalFailure.configuration }
        control = VerticalControl(port: controlPort, originPort: originPort, scenario: scenario)
        bootstrap = overlayRoot.appendingPathComponent("bin/dot-search-bootstrap")
        let sourceRoot = try VerticalJSON.path(value["source_root"])
        source = try VerticalInventory(root: sourceRoot, path: VerticalJSON.path(value["source_records_path"]),
            expectedHash: VerticalJSON.hash(value["source_records_sha256"]), kind: "real-search-source-inventory")
        overlay = try VerticalInventory(root: overlayRoot, path: VerticalJSON.path(value["overlay_inventory_path"]),
            expectedHash: VerticalJSON.hash(value["overlay_inventory_sha256"]), kind: "real-search-runtime-overlay-inventory")
        guard try overlay.hash(for: "bin/dot-search-bootstrap") == VerticalJSON.hash(value["bootstrap_sha256"]),
              try overlay.hash(for: "fixture/dot_search_host.py") == source.hash(for: "Resources/Search/dot_search.py"),
              try overlay.hash(for: "search.sb") == source.hash(for: "Resources/Search/search.sb"),
              try overlay.hash(for: "dot_search.py") == source.hash(for: "Tests/Fixtures/search_real_vertical_entry.py") else {
            throw VerticalFailure.identity
        }
        guard let bundleExecutable = Bundle(for: RealSearchVerticalCanaryTests.self).executableURL else { throw VerticalFailure.identity }
        executable = bundleExecutable.resolvingSymlinksInPath().standardizedFileURL
        executableHash = try VerticalJSON.hash(value["test_executable_sha256"])
        executableReader = try SearchPayloadAudit.Reader(root: executable.deletingLastPathComponent())
        var info = stat()
        guard lstat(executable.path, &info) == 0, info.st_size > 0 else { throw VerticalFailure.identity }
        executableSize = info.st_size
        result = try VerticalJSON.path(value["result_path"], exists: false)
        let resultParent = result.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: result.path), resultParent == config.deletingLastPathComponent(),
              !result.path.hasPrefix(overlayRoot.path + "/"), !result.path.hasPrefix(sourceRoot.path + "/"),
              !ownerStateParent.path.hasPrefix(overlayRoot.path + "/"),
              FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path == ownerStateParent.path else {
            throw VerticalFailure.configuration
        }
        try VerticalStateObservation.requirePrivateDirectory(ownerStateParent)
        try VerticalStateObservation.requirePrivateDirectory(resultParent)
        guard try FileManager.default.contentsOfDirectory(atPath: ownerStateParent.path).isEmpty else { throw VerticalFailure.configuration }
    }
    func verifyIdentities() throws {
        guard VerticalJSON.sha(try configReader.data(config.lastPathComponent, limit: 16_384)) == configHash,
              try executableReader.hash(executable.lastPathComponent, expectedSize: executableSize) == executableHash else {
            throw VerticalFailure.identity
        }
        try source.verify(); try overlay.verify()
    }
    func requireNonsecretInputs(records: [VerticalRecord]) throws {
        let inputs = [try VerticalJSON.read(config, limit: 16_384),
                      try VerticalJSON.read(source.path, limit: 8_000_000),
                      try VerticalJSON.read(overlay.path, limit: 8_000_000)]
        for record in records { for input in inputs { try record.state.requireNoSecrets(input) } }
    }
    func writeResult(failure: VerticalFailure?, records: [VerticalRecord], observations: [String: Any]) throws {
        var facts: [String: Any] = observations
        facts["identity_and_drain_verified"] = true
        facts["generation_count"] = records.count
        facts["actual_swift_broker_executed"] = !records.isEmpty
        facts["actual_owned_bootstrap_source_executed"] = records.allSatisfy { $0.state.cachedProbe != nil } && !records.isEmpty
        facts["actual_reviewed_helper_bodies_executed"] = records.allSatisfy { $0.state.cachedProbe != nil } && !records.isEmpty
        for key in ["production_admission_exercised", "production_acceptance", "app_enabled", "live_provider_tested",
                    "owner_macos_26_4_accepted", "full_neural_app_accepted"] { facts[key] = false }
        let probe: Any = records.first?.state.cachedProbe.map { $0 as Any } ?? NSNull()
        let object: [String: Any] = ["schema": 1, "kind": "build-only-real-search-vertical-canary", "scenario": scenario.rawValue,
            "status": failure == nil ? "passed" : "failed", "failure_category": failure?.rawValue as Any? ?? NSNull(),
            "observations": facts, "dependency_probe": probe]
        let raw = try VerticalJSON.canonical(object)
        guard raw.count <= 32_768 else { throw VerticalFailure.identity }
        for record in records { try record.state.requireNoSecrets(raw) }
        // Exclusive new file under the controller's private directory. No
        // successful result is prewritten, and a prior artifact is never replaced.
        let parent = open(result.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw VerticalFailure.identity }
        defer { Darwin.close(parent) }
        var parentInfo = stat(), current = stat()
        guard fstat(parent, &parentInfo) == 0, lstat(result.deletingLastPathComponent().path, &current) == 0,
              parentInfo.st_ino == current.st_ino, parentInfo.st_dev == current.st_dev,
              parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o777 == 0o700 else { throw VerticalFailure.identity }
        let descriptor = openat(parent, result.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VerticalFailure.identity }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: raw); try handle.synchronize(); try handle.close()
        var finalParent = stat()
        guard lstat(result.deletingLastPathComponent().path, &finalParent) == 0,
              finalParent.st_dev == parentInfo.st_dev, finalParent.st_ino == parentInfo.st_ino,
              try VerticalJSON.read(result, limit: 32_768) == raw else { throw VerticalFailure.identity }
    }
}

private final class VerticalStateObservation: @unchecked Sendable {
    private let parent: URL
    private let overlay: URL
    private let precedingNames: Set<String>
    private let lock = NSLock()
    private var captured: (url: URL, device: dev_t, inode: ino_t)?
    private var markerIdentities: [String: (device: dev_t, inode: ino_t)] = [:]
    private var probe: [String: Any]?
    private weak var owner: SearchOwnedProcess?
    private var observedPort: UInt16?
    private var secrets: [Data] = []
    var cachedProbe: [String: Any]? { lock.lock(); defer { lock.unlock() }; return probe }
    var listenerPort: UInt16? { lock.lock(); defer { lock.unlock() }; return observedPort }
    init(parent: URL, overlay: URL) throws {
        self.parent = parent; self.overlay = overlay
        try Self.requirePrivateDirectory(parent)
        precedingNames = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path))
    }
    func bind(_ value: SearchOwnedProcess) { lock.lock(); owner = value; lock.unlock() }
    static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o7777 == 0o700, info.st_uid == getuid(),
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else { throw VerticalFailure.identity }
    }
    func capture() throws {
        lock.lock(); defer { lock.unlock() }
        guard captured == nil else { throw VerticalFailure.identity }
        try Self.requirePrivateDirectory(parent)
        let current = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path))
        let added = current.subtracting(precedingNames)
        guard precedingNames.isSubset(of: current), added.count == 1,
              let name = added.first, name.hasPrefix("dot-search-"),
              UUID(uuidString: String(name.dropFirst("dot-search-".count))) != nil else { throw VerticalFailure.identity }
        let url = parent.appendingPathComponent(name)
        try Self.requirePrivateDirectory(url)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              let endpoint = owner?.testPreparedEndpoint() else { throw VerticalFailure.identity }
        observedPort = endpoint.port
        secrets.append(Data(endpoint.proxyAuthorization.utf8))
        secrets.append(Data(endpoint.proxyAuthorization.dropFirst(6).utf8))
        guard let decoded = Data(base64Encoded: String(endpoint.proxyAuthorization.dropFirst(6))),
              decoded.starts(with: Data("dot:".utf8)), decoded.count == 68 else { throw VerticalFailure.identity }
        secrets.append(Data(decoded.dropFirst(4)))
        captured = (url, info.st_dev, info.st_ino)
    }
    func rememberGatewayIfPresent() {
        lock.lock(); defer { lock.unlock() }
        if let receipt = owner?.receipt { secrets.append(Data(receipt.capability.utf8)) }
    }
    func requireNoSecrets(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard secrets.allSatisfy({ data.range(of: $0) == nil }) else { throw VerticalFailure.identity }
    }
    private func requireBoundDirectory() throws -> URL? {
        guard let value = captured else { return nil }
        try Self.requirePrivateDirectory(value.url)
        var info = stat()
        guard lstat(value.url.path, &info) == 0, info.st_dev == value.device, info.st_ino == value.inode else {
            throw VerticalFailure.identity
        }
        return value.url
    }
    private func marker(_ name: String) throws -> [String: Any]? {
        guard let root = try requireBoundDirectory() else { return nil }
        let url = root.appendingPathComponent(name)
        var before = stat()
        if lstat(url.path, &before) != 0 {
            if errno == ENOENT { return nil }
            throw VerticalFailure.identity
        }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o7777 == 0o600,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size > 0, before.st_size <= 16_384 else {
            throw VerticalFailure.identity
        }
        let raw = try VerticalJSON.read(url, limit: 16_384)
        var after = stat()
        guard lstat(url.path, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw VerticalFailure.identity }
        if let prior = markerIdentities[name] {
            guard prior.device == after.st_dev && prior.inode == after.st_ino else { throw VerticalFailure.identity }
        }
        markerIdentities[name] = (after.st_dev, after.st_ino)
        _ = try requireBoundDirectory()
        return try VerticalJSON.object(raw)
    }
    func initialized() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = try marker("fixture-initialized.json") else { return false }
        guard Set(value.keys) == ["schema", "original_registration_passed", "actual_webapp_loaded",
                                  "empty_clients_guard_passed", "dependency_probe"],
              try VerticalJSON.integer(value["schema"]) == 1,
              try VerticalJSON.boolean(value["original_registration_passed"]),
              try VerticalJSON.boolean(value["actual_webapp_loaded"]),
              try VerticalJSON.boolean(value["empty_clients_guard_passed"]),
              let observed = value["dependency_probe"] as? [String: Any] else { throw VerticalFailure.identity }
        try validateProbe(observed)
        probe = observed
        return true
    }
    func supervisorReturned() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value = try marker("fixture-supervisor-returned.json") else { return false }
        guard Set(value.keys) == ["schema", "supervisor_returned"],
              try VerticalJSON.integer(value["schema"]) == 1,
              try VerticalJSON.boolean(value["supervisor_returned"]) else { throw VerticalFailure.identity }
        return true
    }
    private func validateProbe(_ value: [String: Any]) throws {
        guard Set(value.keys) == ["python", "openssl", "curl", "versions", "module_origins", "pinned_sources", "bundled_ca_sha256"],
              try VerticalJSON.string(value["python"]) == "3.11.17",
              try VerticalJSON.string(value["openssl"], maximum: 128).hasPrefix("OpenSSL 3.5.9 "),
              try VerticalJSON.string(value["curl"], maximum: 512).contains("libcurl/"),
              let versions = value["versions"] as? [String: String],
              let origins = value["module_origins"] as? [String: String],
              let pins = value["pinned_sources"] as? [String: String] else { throw VerticalFailure.identity }
        let expectedOrigins = ["searx.webapp": "python/lib/python3.11/site-packages/searx/webapp.py",
            "searx.network.network": "python/lib/python3.11/site-packages/searx/network/network.py",
            "searx.network.client": "python/lib/python3.11/site-packages/searx/network/client.py",
            "duckduckgo": "python/lib/python3.11/site-packages/searx/engines/duckduckgo.py",
            "curl_cffi": "python/lib/python3.11/site-packages/curl_cffi/__init__.py"]
        guard origins == expectedOrigins, pins.values.allSatisfy(SearchPayloadAudit.isHash),
              let lockFile = try JSONSerialization.jsonObject(with: VerticalJSON.read(overlay.appendingPathComponent("fixture/search-lock.json"), limit: 2_000_000)) as? [String: Any],
              let wheels = lockFile["wheels"] as? [[String: Any]],
              let pinFile = try JSONSerialization.jsonObject(with: VerticalJSON.read(overlay.appendingPathComponent("fixture/pinned-hashes.json"), limit: 65_536)) as? [String: Any],
              let expectedPins = pinFile["files"] as? [String: String], pins == expectedPins else { throw VerticalFailure.identity }
        var expectedVersions: [String: String] = [:]
        for wheel in wheels {
            expectedVersions[try VerticalJSON.string(wheel["name"])] = try VerticalJSON.string(wheel["version"])
        }
        guard versions == expectedVersions,
              try VerticalJSON.hash(value["bundled_ca_sha256"]) == VerticalJSON.fileHash(overlay.appendingPathComponent("python/lib/python3.11/site-packages/certifi/cacert.pem")) else {
            throw VerticalFailure.identity
        }
    }
    func removeMarkersAndEmptyDirectory() throws {
        lock.lock(); defer { lock.unlock() }
        guard let root = try requireBoundDirectory() else { return }
        let allowed: Set<String> = ["fixture-initialized.json", "fixture-supervisor-returned.json"]
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        guard names.isSubset(of: allowed) else { throw VerticalFailure.cleanup }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw VerticalFailure.cleanup }
        defer { Darwin.close(descriptor) }
        var held = stat()
        guard fstat(descriptor, &held) == 0, let captured,
              held.st_dev == captured.device, held.st_ino == captured.inode else { throw VerticalFailure.identity }
        for name in names {
            _ = try marker(name)
            guard let identity = markerIdentities[name] else { throw VerticalFailure.identity }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_dev == identity.device, info.st_ino == identity.inode,
                  unlinkat(descriptor, name, 0) == 0 else { throw VerticalFailure.cleanup }
        }
        _ = try requireBoundDirectory()
        guard rmdir(root.path) == 0 else { throw VerticalFailure.cleanup }
    }
}

private struct VerticalOriginSnapshot: Sendable {
    let requests: Int
    let handshakes: Int
    let sniCount: Int
    let fixedSNIOnly: Bool
    let fixedRequestOnly: Bool
    let credentialFree: Bool
}
private struct VerticalControl: Sendable {
    let port: UInt16
    let originPort: UInt16
    let scenario: VerticalScenario
    func snapshot() async throws -> VerticalOriginSnapshot { try await call(release: false) }
    func release() async throws -> VerticalOriginSnapshot { try await call(release: true) }
    private func call(release: Bool) async throws -> VerticalOriginSnapshot {
        let raw = try await Task.detached { try VerticalSocket.control(port: port, release: release) }.value
        let value = try VerticalJSON.object(raw, keys: ["schema", "scenario", "origin_port", "requests", "handshakes",
            "sni_count", "fixed_sni_only", "fixed_request_only", "credential_free", "response_releases", "active_handlers"])
        guard try VerticalJSON.integer(value["schema"]) == 1,
              try VerticalJSON.string(value["scenario"]) == scenario.rawValue,
              try VerticalJSON.integer(value["origin_port"], minimum: 1, maximum: 65535) == Int(originPort) else { throw VerticalFailure.control }
        _ = try VerticalJSON.integer(value["response_releases"], maximum: 2)
        _ = try VerticalJSON.integer(value["active_handlers"], maximum: 4)
        return VerticalOriginSnapshot(requests: try VerticalJSON.integer(value["requests"], maximum: 2),
            handshakes: try VerticalJSON.integer(value["handshakes"], maximum: 4),
            sniCount: try VerticalJSON.integer(value["sni_count"], maximum: 4),
            fixedSNIOnly: try VerticalJSON.boolean(value["fixed_sni_only"]),
            fixedRequestOnly: try VerticalJSON.boolean(value["fixed_request_only"]),
            credentialFree: try VerticalJSON.boolean(value["credential_free"]))
    }
}

/// Bounded local test probes. Never resolves DNS or connects to a supplied host.
/// The sole replay payload is built and consumed in memory on an owned listener.
private enum VerticalSocket {
    private static func connect(_ port: UInt16) throws -> (descriptor: Int32, refused: Bool) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VerticalFailure.socket }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw VerticalFailure.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status != 0 {
            if errno == ECONNREFUSED { return (-1, true) }
            guard errno == EINPROGRESS else { throw VerticalFailure.socket }
            try ready(fd, events: Int16(POLLOUT))
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw VerticalFailure.socket }
            if error == ECONNREFUSED { return (-1, true) }
            guard error == 0 else { throw VerticalFailure.socket }
        }
        retained = true
        return (fd, false)
    }
    private static func ready(_ fd: Int32, events: Int16) throws {
        var item = pollfd(fd: fd, events: events, revents: 0)
        let end = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let remaining = max(0, end - ProcessInfo.processInfo.systemUptime)
            guard remaining > 0 else { throw VerticalFailure.socket }
            let result = poll(&item, 1, Int32(remaining * 1000))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, item.revents & Int16(POLLNVAL) == 0 else { throw VerticalFailure.socket }
            return
        }
    }
    private static func send(_ fd: Int32, data: Data) throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard ProcessInfo.processInfo.systemUptime < end else { throw VerticalFailure.socket }
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try ready(fd, events: Int16(POLLOUT)); continue }
                guard count > 0 else { throw VerticalFailure.socket }; offset += count
            }
        }
    }
    private static func receive(_ fd: Int32, maximum: Int, resetMeansEOF: Bool) throws -> Data {
        let end = ProcessInfo.processInfo.systemUptime + 3
        var result = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            guard ProcessInfo.processInfo.systemUptime < end else { throw VerticalFailure.socket }
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
            if count == 0 { return result }
            if count < 0 && resetMeansEOF && errno == ECONNRESET { return result }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try ready(fd, events: Int16(POLLIN)); continue }
            guard count > 0, result.count + count <= maximum else { throw VerticalFailure.socket }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    static func refuses(port: UInt16) throws -> Bool {
        let connection = try connect(port)
        if connection.refused { return true }
        Darwin.close(connection.descriptor)
        return false
    }
    static func rejectReplay(port: UInt16, authorization: String) throws -> Bool {
        let connection = try connect(port)
        guard !connection.refused else { throw VerticalFailure.socket }
        defer { Darwin.close(connection.descriptor) }
        let frame = Data(("CONNECT html.duckduckgo.com:443 HTTP/1.1\r\nHost: html.duckduckgo.com:443\r\nProxy-Authorization: "
                          + authorization + "\r\n\r\n").utf8)
        guard frame.count < 1024 else { throw VerticalFailure.socket }
        try send(connection.descriptor, data: frame)
        return try receive(connection.descriptor, maximum: 512, resetMeansEOF: true).isEmpty
    }
    static func control(port: UInt16, release: Bool) throws -> Data {
        let connection = try connect(port)
        guard !connection.refused else { throw VerticalFailure.control }
        defer { Darwin.close(connection.descriptor) }
        let first = release ? "POST /release" : "GET /snapshot"
        let request = "\(first) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        try send(connection.descriptor, data: Data(request.utf8))
        let response = try receive(connection.descriptor, maximum: 16_384, resetMeansEOF: false)
        let delimiter = Data([13, 10, 13, 10])
        guard let split = response.range(of: delimiter), split.lowerBound <= 4096,
              let header = String(data: response[..<split.lowerBound], encoding: .ascii) else { throw VerticalFailure.control }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "HTTP/1.0 200 OK" || lines.first == "HTTP/1.1 200 OK" else { throw VerticalFailure.control }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.range(of: ": ") else { throw VerticalFailure.control }
            let name = line[..<separator.lowerBound].lowercased()
            guard headers[name] == nil else { throw VerticalFailure.control }
            headers[name] = String(line[separator.upperBound...])
        }
        let body = Data(response[split.upperBound...])
        guard headers["transfer-encoding"] == nil, headers["content-length"].flatMap(Int.init) == body.count,
              body.count <= 8192 else { throw VerticalFailure.control }
        return body
    }
}
#endif
