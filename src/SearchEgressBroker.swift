import Foundation
import Security

/// Deliberately fixed diagnostics: never include a header, capability or query.
enum SearchEgressFailure: Error, Equatable, LocalizedError {
    case capabilityUnavailable, invalidHeader, headerTooLarge, incompleteHeader
    case trailingBytes, parserFinished, unauthorized, wrongGeneration
    case invalidTime, deadlineExceeded, invalidated, searchNotAdmitted, searchAlreadyAdmitted
    case admissionLimitExceeded, byteLimitExceeded, invalidAdmission, invalidWrite, writePending

    var errorDescription: String? { "The bounded Search connection could not proceed safely." }
}

/// Private handoff material. Generate a fresh value for every generation, never
/// place it in a URL, environment, command line, log or user-facing description.
fileprivate struct SearchProxyCapability: CustomStringConvertible, CustomDebugStringConvertible {
    let authorization: [UInt8]

    init() throws {
        var random = [UInt8](repeating: 0, count: 32)
        let status = random.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw SearchEgressFailure.capabilityUnavailable }
        let hex = random.map { String(format: "%02x", $0) }.joined()
        authorization = Array(("Basic " + Data("dot:\(hex)".utf8).base64EncodedString()).utf8)
    }

    static func isCanonical(_ value: String) -> Bool {
        guard value.utf8.count == 98, value.hasPrefix("Basic "),
              let decoded = Data(base64Encoded: String(value.dropFirst(6))), decoded.count == 68,
              decoded.starts(with: Array("dot:".utf8)),
              decoded.dropFirst(4).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return "Basic " + decoded.base64EncodedString() == value
    }

    func matches(_ candidate: [UInt8]) -> Bool {
        // Canonical authorization has a public fixed length. Every byte is
        // compared, with no secret-dependent short-circuit or early return.
        guard candidate.count == authorization.count else { return false }
        var difference: UInt8 = 0
        for index in authorization.indices { difference |= authorization[index] ^ candidate[index] }
        return difference == 0
    }

    var description: String { "Search proxy capability (redacted)" }
    var debugDescription: String { description }
}

struct SearchCONNECTRequest: CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let generation: UUID
    fileprivate let authorization: [UInt8]
    var description: String { "Search CONNECT request (authorization redacted)" }
    var debugDescription: String { description }
}

/// A single bounded header, with no body or pipelined bytes. Only the finite
/// Python fixture header set is accepted; pinned-curl compatibility is unproven.
struct SearchCONNECTParser: CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumHeaderBytes = 8 * 1024
    // The whole header cap also bounds the optional printable User-Agent value.
    static let maximumUserAgentBytes = maximumHeaderBytes
    static let authority = "html.duckduckgo.com:443"
    private let generation: UUID
    private var bytes: [UInt8] = []
    private var complete = false
    private var failure: SearchEgressFailure?
    var bufferedByteCount: Int { bytes.count }

    init(generation: UUID) { self.generation = generation }

    mutating func append(_ fragment: Data) throws -> SearchCONNECTRequest? {
        if let failure { throw failure }
        guard !complete else { throw SearchEgressFailure.parserFinished }
        // Subtraction is safe because the only append is guarded below. Avoid
        // copying an arbitrarily large fragment before rejecting its size.
        guard fragment.count <= Self.maximumHeaderBytes - bytes.count else { throw fail(.headerTooLarge) }
        for (offset, byte) in fragment.enumerated() {
            guard byte == 13 || byte == 10 || (32...126).contains(byte) else { throw fail(.invalidHeader) }
            if bytes.last == 13, byte != 10 { throw fail(.invalidHeader) }
            if byte == 10, bytes.last != 13 { throw fail(.invalidHeader) }
            bytes.append(byte)
            if bytes.count >= 4, bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard offset == fragment.count - 1 else { throw fail(.trailingBytes) }
                do {
                    let request = try decodeHeader()
                    complete = true
                    bytes.removeAll(keepingCapacity: false)
                    return request
                } catch let error as SearchEgressFailure {
                    throw fail(error)
                } catch {
                    throw fail(.invalidHeader)
                }
            }
        }
        guard bytes.count < Self.maximumHeaderBytes else { throw fail(.headerTooLarge) }
        return nil
    }

    /// Call on EOF while receiving a header. Success is returned by append only.
    mutating func finish() throws {
        if let failure { throw failure }
        guard !complete else { throw SearchEgressFailure.parserFinished }
        throw fail(.incompleteHeader)
    }

    private mutating func fail(_ error: SearchEgressFailure) -> SearchEgressFailure {
        failure = error
        bytes.removeAll(keepingCapacity: false)
        return error
    }

    private func decodeHeader() throws -> SearchCONNECTRequest {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        guard lines.first == "CONNECT \(Self.authority) HTTP/1.1", lines.count >= 5,
              lines.suffix(2).allSatisfy({ $0.isEmpty }) else { throw SearchEgressFailure.invalidHeader }
        var names = Set<String>()
        var authorization: [UInt8]?
        for line in lines.dropFirst().dropLast(2) {
            guard let separator = line.range(of: ": ") else { throw SearchEgressFailure.invalidHeader }
            let name = String(line[..<separator.lowerBound]).lowercased()
            let value = String(line[separator.upperBound...])
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  names.insert(name).inserted, !value.isEmpty,
                  value.first != " ", value.last != " " else { throw SearchEgressFailure.invalidHeader }
            switch name {
            case "host":
                guard value == Self.authority else { throw SearchEgressFailure.invalidHeader }
            case "proxy-authorization":
                guard SearchProxyCapability.isCanonical(value) else { throw SearchEgressFailure.unauthorized }
                authorization = Array(value.utf8)
            case "proxy-connection":
                guard value == "Keep-Alive" else { throw SearchEgressFailure.invalidHeader }
            case "user-agent":
                guard value.utf8.count <= Self.maximumUserAgentBytes else { throw SearchEgressFailure.invalidHeader }
            default:
                throw SearchEgressFailure.invalidHeader
            }
        }
        guard names.contains("host"), let authorization else { throw SearchEgressFailure.invalidHeader }
        return SearchCONNECTRequest(generation: generation, authorization: authorization)
    }

    var description: String { "Search CONNECT parser (header redacted)" }
    var debugDescription: String { description }
}

enum SearchEgressDirection: Equatable { case upstream, downstream }

struct SearchCONNECTAdmission: Equatable {
    fileprivate let budget: UUID
    fileprivate let identifier: Int
}

struct SearchEgressWritePermit: Equatable {
    fileprivate let budget: UUID
    fileprivate let identifier: UUID
    let byteCount: Int
}

/// Accounting only, confined to the real broker's serial queue. This value is
/// not a listener, runtime owner, close receipt, scheduler or readiness result.
/// The owner keeps exactly one instance per generation and never copies it to
/// restart a search. It calls invalidate at cancellation/settlement and observes
/// terminalFailure to close real sockets. Time is absolute monotonic uptime.
struct SearchEgressBudget: CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumAdmissions = 2
    static let maximumUpstreamBytes = 64 * 1024
    static let maximumDownstreamBytes = 8 * 1024 * 1024
    static let maximumRelayChunkBytes = 32 * 1024

    let generation: UUID
    let absoluteDeadline: TimeInterval
    private let identity = UUID()
    private let capability: SearchProxyCapability
    private var lastObservedTime: TimeInterval
    private(set) var searchAdmitted = false
    private(set) var authenticatedAdmissions = 0
    private(set) var upstreamBytes = 0
    private(set) var downstreamBytes = 0
    private(set) var terminalFailure: SearchEgressFailure?
    private var activeAdmissions = Set<Int>()
    private var pending: [UUID: PendingWrite] = [:]

    private struct PendingWrite {
        let admission: Int
        let direction: SearchEgressDirection
        let maximum: Int
    }

    init(generation: UUID, absoluteDeadline: TimeInterval, now: TimeInterval) throws {
        guard now.isFinite, now >= 0, absoluteDeadline.isFinite else { throw SearchEgressFailure.invalidTime }
        guard absoluteDeadline > now else { throw SearchEgressFailure.deadlineExceeded }
        self.generation = generation
        self.absoluteDeadline = absoluteDeadline
        lastObservedTime = now
        capability = try SearchProxyCapability()
    }

    /// Only the socket owner uses this initializer when its one search is armed.
    /// The capability was already generated for the private helper handoff;
    /// arming creates the first budget, never a replacement or reset.
    fileprivate init(generation: UUID, absoluteDeadline: TimeInterval, now: TimeInterval,
                     capability: SearchProxyCapability) throws {
        guard now.isFinite, now >= 0, absoluteDeadline.isFinite else { throw SearchEgressFailure.invalidTime }
        guard absoluteDeadline > now else { throw SearchEgressFailure.deadlineExceeded }
        self.generation = generation
        self.absoluteDeadline = absoluteDeadline
        lastObservedTime = now
        self.capability = capability
    }

    /// Only the next private helper handoff may transmit this value. Reading it
    /// does not admit a search or authorize a network connection.
    var proxyAuthorization: String { String(decoding: capability.authorization, as: UTF8.self) }
    var pendingWriteCount: Int { pending.count }
    func makeParser() -> SearchCONNECTParser { SearchCONNECTParser(generation: generation) }

    mutating func beginSearch(now: TimeInterval) throws {
        try checkActive(now: now)
        guard !searchAdmitted else { throw SearchEgressFailure.searchAlreadyAdmitted }
        searchAdmitted = true
    }

    /// Admission is charged before attempting DNS/connect. A failed connect,
    /// reconnect or endAdmission never refunds it. Failed authentication does
    /// not consume an admission or any relay bytes.
    mutating func admit(_ request: SearchCONNECTRequest, now: TimeInterval) throws -> SearchCONNECTAdmission {
        try checkActive(now: now)
        guard searchAdmitted else { throw SearchEgressFailure.searchNotAdmitted }
        guard request.generation == generation else { throw SearchEgressFailure.wrongGeneration }
        guard capability.matches(request.authorization) else { throw SearchEgressFailure.unauthorized }
        guard authenticatedAdmissions < Self.maximumAdmissions else { throw stop(.admissionLimitExceeded) }
        authenticatedAdmissions += 1
        activeAdmissions.insert(authenticatedAdmissions)
        return SearchCONNECTAdmission(budget: identity, identifier: authenticatedAdmissions)
    }

    /// Accounting retirement only; the owner must obtain actual socket close
    /// evidence separately. Outstanding write completions still need settling.
    mutating func endAdmission(_ admission: SearchCONNECTAdmission) throws {
        guard admission.budget == identity, activeAdmissions.remove(admission.identifier) != nil else {
            throw SearchEgressFailure.invalidAdmission
        }
    }

    /// Reserve before submitting a socket write. At most one pending write per
    /// admission/direction (four total) prevents two in-flight partial writes
    /// from each spending the same remaining shared budget. No socket is held.
    mutating func reserveWrite(_ admission: SearchCONNECTAdmission, direction: SearchEgressDirection,
                               requestedBytes: Int, now: TimeInterval) throws -> SearchEgressWritePermit {
        try checkActive(now: now)
        guard admission.budget == identity, activeAdmissions.contains(admission.identifier) else {
            throw SearchEgressFailure.invalidAdmission
        }
        guard requestedBytes > 0, requestedBytes <= Self.maximumRelayChunkBytes else {
            throw SearchEgressFailure.invalidWrite
        }
        guard !pending.values.contains(where: { $0.admission == admission.identifier && $0.direction == direction }) else {
            throw SearchEgressFailure.writePending
        }
        let cap = direction == .upstream ? Self.maximumUpstreamBytes : Self.maximumDownstreamBytes
        let used = direction == .upstream ? upstreamBytes : downstreamBytes
        // All terms are independently capped; subtraction avoids overflow even
        // when a caller supplies Int.max as a requested byte count.
        let reserved = pending.values.filter { $0.direction == direction }.reduce(0) { $0 + $1.maximum }
        let available = cap - used - reserved
        guard available > 0 else {
            // A full in-flight reservation is temporary, not exhausted bytes.
            if used < cap { throw SearchEgressFailure.writePending }
            throw stop(.byteLimitExceeded)
        }
        let maximum = min(requestedBytes, available)
        let identifier = UUID()
        pending[identifier] = PendingWrite(admission: admission.identifier, direction: direction, maximum: maximum)
        return SearchEgressWritePermit(budget: identity, identifier: identifier, byteCount: maximum)
    }

    /// Settle exactly once with the actual successful byte count, including zero
    /// for a failed/cancelled write. Account an already-completed write even if
    /// cancellation or expiry happened while it was in flight. The caller must
    /// never send more than permit.byteCount, nor reuse its unwritten suffix
    /// without a new reservation. Invalid completion counts fail closed.
    mutating func settleWrite(_ permit: SearchEgressWritePermit, successfulBytes: Int, now: TimeInterval) throws {
        guard permit.budget == identity, let write = pending.removeValue(forKey: permit.identifier) else {
            throw SearchEgressFailure.invalidWrite
        }
        guard successfulBytes >= 0, successfulBytes <= write.maximum else { throw stop(.invalidWrite) }
        if write.direction == .upstream { upstreamBytes += successfulBytes }
        else { downstreamBytes += successfulBytes }
        // Account first: expiry/cancellation cannot erase successful OS writes.
        try checkActive(now: now)
        if upstreamBytes == Self.maximumUpstreamBytes || downstreamBytes == Self.maximumDownstreamBytes {
            _ = stop(.byteLimitExceeded)
        }
    }

    mutating func invalidate() { _ = stop(.invalidated) }

    /// Also used by the real broker's deadline event while no bytes arrive.
    mutating func checkActive(now: TimeInterval) throws {
        if let terminalFailure { throw terminalFailure }
        guard now.isFinite, now >= lastObservedTime else { throw stop(.invalidTime) }
        lastObservedTime = now
        guard now < absoluteDeadline else { throw stop(.deadlineExceeded) }
    }

    private mutating func stop(_ error: SearchEgressFailure) -> SearchEgressFailure {
        if terminalFailure == nil { terminalFailure = error }
        return terminalFailure!
    }

    var description: String { "Search egress accounting (capability redacted)" }
    var debugDescription: String { description }
}

import Darwin

/// A real listener receipt, not helper/provider readiness. Its authorization may
/// be transmitted only through the existing private helper bootstrap pipe.
struct SearchEgressEndpoint: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
    let port: UInt16
    let proxyAuthorization: String
    var description: String { "Search loopback endpoint (capability redacted)" }
    var debugDescription: String { description }
}

enum SearchEgressSocketFailure: Error, LocalizedError {
    case socketFailure, unsafeResolution, alreadyPrepared, notPrepared
    var errorDescription: String? { "The bounded Search connection could not proceed safely." }
}

/// One generation, one continuously held listener, one fixed DNS snapshot, and
/// one armed search. The existing Search owner must invalidate and await drain
/// before replacing this object. No helper wiring or live-readiness is implied.
/// Four header slots bound resources, but cannot prevent local flooding DoS.
final class SearchEgressBroker: @unchecked Sendable {
    static let maximumHeaderSlots = 4
    static let preparationSeconds: TimeInterval = 35
    static let searchSeconds: TimeInterval = 30
    static let headerSeconds: TimeInterval = 2
    static let connectSeconds: TimeInterval = 5
    private static let success = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    private let queue = DispatchQueue(label: "app.dot.search-egress")
    private let gate = NSLock()
    private var admissionOpen = true // Protected by gate, including public invalidation.
    private let generation: UUID
    private let capability: SearchProxyCapability
    private let preparationDeadline: TimeInterval
    private var budget: SearchEgressBudget?
    private var beganPreparation = false
    private var prepared = false
    private var stopping = false
    private var drained = false
    private var pins: [String] = []
    private var listener: Socket?
    private var sockets: [UUID: Socket] = [:]
    private var tunnels: [UUID: Tunnel] = [:]
    private var timer: DispatchSourceTimer?
    private var timerCancelling = false
    private var resolver: Task<[String], Error>?
    private var preparing: CheckedContinuation<SearchEgressEndpoint, Error>?
    private var preparationError: Error = SearchEgressFailure.invalidated
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
    private var testing: Testing?
    private var deferredCloses: [Socket] = []
    private var resolverCalls = 0
    private var connectAttempts = 0
    private var actualCloses = 0
    private var partialWrites = 0
    private var wouldBlockWrites = 0
    #endif

    private enum Role { case listener, client(UUID), upstream(UUID) }
    private final class Socket {
        let id = UUID()
        let descriptor: Int32
        let role: Role
        var read: DispatchSourceRead?
        var write: DispatchSourceWrite?
        var reading = false
        var writing = false
        var sourceReceipts = 0
        var closing = false
        var closed = false
        init(_ descriptor: Int32, _ role: Role) { self.descriptor = descriptor; self.role = role }
    }
    private enum Phase { case header, connecting, reply, relay, closing }
    private final class Tunnel {
        let id: UUID
        let client: Socket
        var upstream: Socket?
        var parser: SearchCONNECTParser
        var admission: SearchCONNECTAdmission?
        var phase = Phase.header
        var deadline: TimeInterval
        var expectedPeer: sockaddr_in?
        var upload = Data()
        var download = Data()
        var reply = SearchEgressBroker.success
        var clientEOF = false
        var upstreamEOF = false
        var uploadShutdown = false
        var downloadShutdown = false
        init(id: UUID, client: Socket, generation: UUID, deadline: TimeInterval) {
            self.id = id; self.client = client; self.deadline = deadline
            parser = SearchCONNECTParser(generation: generation)
        }
    }

    init(generation: UUID) throws {
        self.generation = generation
        capability = try SearchProxyCapability()
        preparationDeadline = ProcessInfo.processInfo.systemUptime + Self.preparationSeconds
    }

    /// Neither a caller's cancellation nor a timeout substitutes for resolver
    /// return. ResearchSystemHTTP.resolve must include real child/pipe settlement.
    func prepare() async throws -> SearchEgressEndpoint {
        try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                let endpoint = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<SearchEgressEndpoint, Error>) in
                    queue.async { [self] in startPreparation(continuation) }
                }
                try Task.checkCancellation()
                return endpoint
            } catch {
                await drain()
                throw error
            }
        }, onCancel: { self.invalidate() })
    }

    /// Call once after helper readiness, before its one search. Startup never
    /// consumes the request's 30 seconds. The same capability enters the first
    /// and only budget here; reconnects do not rearm or regenerate anything.
    func beginSearch() async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        try whileAdmissionOpen {
                            guard prepared, !stopping else { throw SearchEgressSocketFailure.notPrepared }
                            guard budget == nil else { throw SearchEgressFailure.searchAlreadyAdmitted }
                            let now = ProcessInfo.processInfo.systemUptime
                            guard now < preparationDeadline else { throw SearchEgressFailure.deadlineExceeded }
                            var armed = try SearchEgressBudget(generation: generation,
                                absoluteDeadline: now + Self.searchSeconds, now: now, capability: capability)
                            try armed.beginSearch(now: now)
                            budget = armed
                        }
                        scheduleDeadline()
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
        }, onCancel: { self.invalidate() })
    }

    /// This is only a tiny admission-gate lock, never a queue, blocking IO or
    /// receipt wait. The final nonblocking connect/send syscalls share this gate.
    /// Socket teardown is asynchronous on its owning queue. Nonblocking writes
    /// already in progress may finish and their successful bytes remain charged.
    func invalidate() {
        gate.lock(); let changed = admissionOpen; admissionOpen = false; gate.unlock()
        if changed { queue.async { [self] in stop() } }
    }

    /// Idempotent and intentionally cancellation-independent. All callers observe
    /// the same actual descriptor/source and resolver receipts, including late ones.
    func drain() async {
        invalidate()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if drained { continuation.resume() }
                else { drainWaiters.append(continuation); stop(); finishDrainIfPossible() }
            }
        }
    }

    private var isOpen: Bool {
        gate.lock(); defer { gate.unlock() }; return admissionOpen
    }
    private func whileAdmissionOpen<T>(_ operation: () throws -> T) throws -> T {
        gate.lock(); defer { gate.unlock() }
        guard admissionOpen else { throw SearchEgressFailure.invalidated }
        return try operation()
    }
    private var absoluteDeadline: TimeInterval { budget?.absoluteDeadline ?? preparationDeadline }

    private func startPreparation(_ continuation: CheckedContinuation<SearchEgressEndpoint, Error>) {
        guard isOpen, !stopping else { continuation.resume(throwing: SearchEgressFailure.invalidated); return }
        guard !beganPreparation else { continuation.resume(throwing: SearchEgressSocketFailure.alreadyPrepared); return }
        beganPreparation = true; preparing = continuation
        do {
            guard ProcessInfo.processInfo.systemUptime < preparationDeadline else { throw SearchEgressFailure.deadlineExceeded }
            let fd = try Self.newSocket()
            do {
                var address = try Self.address("127.0.0.1", port: 0)
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bound == 0, Darwin.listen(fd, Int32(Self.maximumHeaderSlots)) == 0 else {
                    throw SearchEgressSocketFailure.socketFailure
                }
            } catch { Darwin.close(fd); throw error }
            listener = own(fd, role: .listener, writable: false)
            let clock = DispatchSource.makeTimerSource(queue: queue)
            timer = clock
            clock.setEventHandler { [self] in deadlineFired() }
            clock.setCancelHandler { [self] in timer = nil; finishDrainIfPossible() }
            clock.resume(); scheduleDeadline()
            #if DEBUG
            let testResolver = testing?.resolve
            resolverCalls += 1
            #endif
            let deadline = preparationDeadline
            // This task is retained until its body has returned from the bounded
            // resolver. Cancellation never clears it; only its completion does.
            let work: Task<[String], Error> = Task.detached {
                #if DEBUG
                if let testResolver { return try await testResolver() }
                #endif
                return try await ResearchSystemHTTP.resolve("html.duckduckgo.com", deadline)
            }
            resolver = work
            Task { [self] in
                let result = await work.result // Observe actual task return, even after cancellation.
                queue.async { [self] in resolutionFinished(result) }
            }
        } catch { preparationError = error; stop() }
    }

    private func resolutionFinished(_ result: Result<[String], Error>) {
        resolver = nil // The resolver returned only after its real child drain.
        guard isOpen, !stopping else { stop(); finishDrainIfPossible(); return }
        do {
            let raw = try result.get()
            guard !raw.isEmpty, raw.count <= 64 else { throw SearchEgressSocketFailure.unsafeResolution }
            var unique = Set<UInt32>()
            var vetted: [String] = []
            for pin in raw {
                guard ResearchPublicAddress.allowed(pin) else { throw SearchEgressSocketFailure.unsafeResolution }
                let numeric = try Self.address(pin, port: 443) // AF_INET only, even with an older classifier.
                if unique.insert(numeric.sin_addr.s_addr).inserted { vetted.append(pin) }
                guard vetted.count <= 16 else { throw SearchEgressSocketFailure.unsafeResolution }
            }
            guard ProcessInfo.processInfo.systemUptime < preparationDeadline, let listener else {
                throw SearchEgressFailure.deadlineExceeded
            }
            pins = vetted
            let local = try Self.socketAddress(listener.descriptor, peer: false)
            guard local.sin_addr.s_addr == (try Self.address("127.0.0.1", port: 0)).sin_addr.s_addr,
                  local.sin_port != 0 else { throw SearchEgressSocketFailure.socketFailure }
            prepared = true; setRead(listener, true)
            let ready = preparing; preparing = nil
            ready?.resume(returning: SearchEgressEndpoint(port: UInt16(bigEndian: local.sin_port),
                                                          proxyAuthorization: String(decoding: capability.authorization, as: UTF8.self)))
        } catch { preparationError = error; stop() }
    }

    private static func address(_ text: String, port: UInt16) throws -> sockaddr_in {
        var result = sockaddr_in()
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        result.sin_family = sa_family_t(AF_INET); result.sin_port = port.bigEndian
        guard text.withCString({ inet_pton(AF_INET, $0, &result.sin_addr) }) == 1 else {
            throw SearchEgressSocketFailure.unsafeResolution
        }
        return result
    }
    private static func socketAddress(_ fd: Int32, peer: Bool) throws -> sockaddr_in {
        var address = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? Darwin.getpeername(fd, $0, &size) : Darwin.getsockname(fd, $0, &size)
            }
        }
        guard result == 0, size == MemoryLayout<sockaddr_in>.size,
              address.sin_family == sa_family_t(AF_INET) else { throw SearchEgressSocketFailure.socketFailure }
        return address
    }
    private static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL), descriptorFlags = fcntl(fd, F_GETFD)
        var one: Int32 = 1
        guard flags >= 0, descriptorFlags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SearchEgressSocketFailure.socketFailure
        }
    }
    private static func newSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SearchEgressSocketFailure.socketFailure }
        do { try configure(fd); return fd } catch { Darwin.close(fd); throw error }
    }

    private func own(_ fd: Int32, role: Role, writable: Bool = true) -> Socket {
        let socket = Socket(fd, role); sockets[socket.id] = socket
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        socket.read = read; socket.sourceReceipts += 1
        read.setEventHandler { [self, socket] in readable(socket) }
        read.setCancelHandler { [self, socket] in sourceCancelled(socket) }
        if writable {
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            socket.write = write; socket.sourceReceipts += 1
            write.setEventHandler { [self, socket] in writableEvent(socket) }
            write.setCancelHandler { [self, socket] in sourceCancelled(socket) }
        }
        return socket // Sources stay suspended until their specific operation is ready.
    }
    private func setRead(_ socket: Socket, _ enabled: Bool) {
        guard !socket.closing, socket.reading != enabled, let read = socket.read else { return }
        socket.reading = enabled
        if enabled { read.resume() } else { read.suspend() }
    }
    private func setWrite(_ socket: Socket, _ enabled: Bool) {
        guard !socket.closing, socket.writing != enabled, let write = socket.write else { return }
        socket.writing = enabled
        if enabled { write.resume() } else { write.suspend() }
    }
    private func close(_ socket: Socket) {
        guard !socket.closing else { return }
        socket.closing = true
        socket.read?.cancel()
        if !socket.reading { socket.read?.resume(); socket.reading = true }
        socket.write?.cancel()
        if !socket.writing { socket.write?.resume(); socket.writing = true }
    }
    private func sourceCancelled(_ socket: Socket) {
        socket.sourceReceipts -= 1
        guard socket.sourceReceipts == 0 else { return }
        // All sources have acknowledged cancellation on their owning queue.
        // No old event may use this fd after this single close, even if reused.
        Darwin.close(socket.descriptor); socket.closed = true
        socket.read = nil; socket.write = nil
        #if DEBUG
        actualCloses += 1
        if testing?.holdCloseReceipts == true { deferredCloses.append(socket); return }
        #endif
        closedReceipt(socket)
    }
    private func closedReceipt(_ socket: Socket) {
        sockets.removeValue(forKey: socket.id)
        if listener === socket { listener = nil }
        let completed = tunnels.values.filter { $0.phase == .closing && $0.client.closed && ($0.upstream?.closed ?? true) }
        for tunnel in completed { tunnels.removeValue(forKey: tunnel.id) }
        finishDrainIfPossible()
    }

    private func readable(_ socket: Socket) {
        guard isOpen, !stopping, !socket.closing, !socket.closed else { return }
        do { try budget?.checkActive(now: ProcessInfo.processInfo.systemUptime) }
        catch { stop(); return }
        switch socket.role {
        case .listener: acceptAvailable(socket)
        case .client(let id):
            guard let tunnel = tunnels[id] else { return }
            switch tunnel.phase {
            case .header: readHeader(tunnel)
            case .connecting, .reply:
                // Readiness callbacks may be coalesced/stale. Inspect the real
                // socket; reject data or EOF, but never infer bytes from an event.
                var byte: UInt8 = 0
                let count = Darwin.recv(socket.descriptor, &byte, 1, MSG_PEEK)
                if count >= 0 || !(errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { close(tunnel) }
            case .relay: readRelay(tunnel, fromClient: true)
            case .closing: break
            }
        case .upstream(let id):
            if let tunnel = tunnels[id], tunnel.phase == .relay { readRelay(tunnel, fromClient: false) }
        }
    }
    private func acceptAvailable(_ socket: Socket) {
        // Bound each callback so timers/cancellation cannot starve under a flood.
        for _ in 0..<16 {
            guard isOpen, !stopping else { return }
            let fd = Darwin.accept(socket.descriptor, nil, nil)
            if fd < 0 { return } // EINTR is retried by a later readiness callback.
            do {
                let peer = try Self.socketAddress(fd, peer: true)
                guard peer.sin_addr.s_addr == (try Self.address("127.0.0.1", port: 0)).sin_addr.s_addr,
                      tunnels.values.filter({ $0.admission == nil }).count < Self.maximumHeaderSlots else {
                    Darwin.close(fd); continue
                }
                try Self.configure(fd)
                #if DEBUG
                try configureTestBuffer(fd)
                #endif
            } catch { Darwin.close(fd); continue }
            let id = UUID(), client = own(fd, role: .client(id))
            let tunnel = Tunnel(id: id, client: client, generation: generation,
                                deadline: min(absoluteDeadline, ProcessInfo.processInfo.systemUptime + Self.headerSeconds))
            tunnels[id] = tunnel; setRead(client, true); scheduleDeadline()
        }
    }
    private func readHeader(_ tunnel: Tunnel) {
        var bytes = [UInt8](repeating: 0, count: SearchCONNECTParser.maximumHeaderBytes)
        let count = bytes.withUnsafeMutableBytes { Darwin.recv(tunnel.client.descriptor, $0.baseAddress!, $0.count, 0) }
        if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return }
        guard count > 0 else { close(tunnel); return }
        do {
            guard let request = try tunnel.parser.append(Data(bytes.prefix(count))) else { return }
            let admission = try whileAdmissionOpen { () throws -> SearchCONNECTAdmission in
                let now = ProcessInfo.processInfo.systemUptime
                guard now < tunnel.deadline else { throw SearchEgressFailure.deadlineExceeded }
                guard budget != nil else { throw SearchEgressFailure.searchNotAdmitted }
                return try budget!.admit(request, now: now)
            }
            tunnel.admission = admission
            try connect(tunnel)
        } catch {
            if budget?.terminalFailure != nil { stop() } else { close(tunnel) }
        }
    }
    private func connect(_ tunnel: Tunnel) throws {
        guard isOpen, !stopping, let pin = pins.first else { throw SearchEgressFailure.invalidated }
        var target = try Self.address(pin, port: 443)
        tunnel.expectedPeer = target
        #if DEBUG
        if let testing {
            target = try Self.address("127.0.0.1", port: testing.loopbackPort)
            tunnel.expectedPeer = try Self.address("127.0.0.1", port: testing.expectedPeerPort ?? testing.loopbackPort)
        }
        #endif
        let descriptor = try Self.newSocket()
        #if DEBUG
        do { try configureTestBuffer(descriptor) } catch { Darwin.close(descriptor); throw error }
        #endif
        let upstream = own(descriptor, role: .upstream(tunnel.id))
        tunnel.upstream = upstream; tunnel.phase = .connecting
        tunnel.deadline = min(absoluteDeadline, ProcessInfo.processInfo.systemUptime + Self.connectSeconds)
        #if DEBUG
        if testing?.invalidateBeforeConnect == true { invalidate() }
        #endif
        // Authentication and socket setup precede this point. Invalidation can
        // race either, so make the actual nonblocking syscall atomic with the
        // final admission check. Nothing can start a connect after it returns.
        let (result, connectErrno) = try whileAdmissionOpen {
            try budget!.checkActive(now: ProcessInfo.processInfo.systemUptime)
            #if DEBUG
            connectAttempts += 1
            #endif
            let result = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(upstream.descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return (result, errno)
        }
        guard result == 0 || (result < 0 && connectErrno == EINPROGRESS) else { throw SearchEgressSocketFailure.socketFailure }
        setWrite(upstream, true); scheduleDeadline()
    }
    private func writableEvent(_ socket: Socket) {
        guard isOpen, !stopping, !socket.closing, !socket.closed else { return }
        do { try budget?.checkActive(now: ProcessInfo.processInfo.systemUptime) }
        catch { stop(); return }
        switch socket.role {
        case .upstream(let id):
            guard let tunnel = tunnels[id] else { return }
            if tunnel.phase == .connecting {
                #if DEBUG
                if testing?.holdConnectCompletion == true { setWrite(socket, false); return }
                #endif
                finishConnect(tunnel)
            } else if tunnel.phase == .relay { writeRelay(tunnel, upstream: true) }
        case .client(let id):
            guard let tunnel = tunnels[id] else { return }
            if tunnel.phase == .reply { writeReply(tunnel) }
            else if tunnel.phase == .relay { writeRelay(tunnel, upstream: false) }
        case .listener: break
        }
    }
    private func finishConnect(_ tunnel: Tunnel) {
        guard let upstream = tunnel.upstream, let expected = tunnel.expectedPeer else { close(tunnel); return }
        do {
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard ProcessInfo.processInfo.systemUptime < tunnel.deadline,
                  getsockopt(upstream.descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw SearchEgressSocketFailure.socketFailure
            }
            let peer = try Self.socketAddress(upstream.descriptor, peer: true)
            guard peer.sin_addr.s_addr == expected.sin_addr.s_addr, peer.sin_port == expected.sin_port else {
                throw SearchEgressSocketFailure.socketFailure
            }
            // Reject already buffered early payload before even the first 200 byte.
            var byte: UInt8 = 0
            let peek = Darwin.recv(tunnel.client.descriptor, &byte, 1, MSG_PEEK)
            guard peek < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw SearchEgressFailure.trailingBytes }
            setWrite(upstream, false); tunnel.phase = .reply
            setWrite(tunnel.client, true); scheduleDeadline()
        } catch { close(tunnel) }
    }
    private func writeReply(_ tunnel: Tunnel) {
        do {
            let (count, savedErrno) = try whileAdmissionOpen {
                try budget!.checkActive(now: ProcessInfo.processInfo.systemUptime)
                if tunnel.reply.count == Self.success.count {
                    // Completion and writable callbacks are separate. Check
                    // again immediately before the first success-response byte.
                    var byte: UInt8 = 0
                    let peek = Darwin.recv(tunnel.client.descriptor, &byte, 1, MSG_PEEK)
                    guard peek < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                        throw SearchEgressFailure.trailingBytes
                    }
                }
                let count = tunnel.reply.withUnsafeBytes { Darwin.send(tunnel.client.descriptor, $0.baseAddress!, $0.count, 0) }
                return (count, errno)
            }
            if count < 0 && (savedErrno == EINTR || savedErrno == EAGAIN || savedErrno == EWOULDBLOCK) { return }
            guard count > 0 else { close(tunnel); return }
            tunnel.reply.removeFirst(count)
            if tunnel.reply.isEmpty, let upstream = tunnel.upstream {
                tunnel.phase = .relay; setWrite(tunnel.client, false); setRead(upstream, true)
            }
        } catch {
            if budget?.terminalFailure != nil || !isOpen { stop() } else { close(tunnel) }
        }
    }
    private func readRelay(_ tunnel: Tunnel, fromClient: Bool) {
        guard let upstream = tunnel.upstream else { close(tunnel); return }
        let source = fromClient ? tunnel.client : upstream
        guard fromClient ? tunnel.upload.isEmpty : tunnel.download.isEmpty else { setRead(source, false); return }
        var bytes = [UInt8](repeating: 0, count: SearchEgressBudget.maximumRelayChunkBytes)
        let count = bytes.withUnsafeMutableBytes { Darwin.recv(source.descriptor, $0.baseAddress!, $0.count, 0) }
        if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { return }
        guard count >= 0 else { close(tunnel); return }
        setRead(source, false)
        if count == 0 {
            if fromClient { tunnel.clientEOF = true } else { tunnel.upstreamEOF = true }
            finishHalfCloses(tunnel); return
        }
        if fromClient { tunnel.upload = Data(bytes.prefix(count)); setWrite(upstream, true) }
        else { tunnel.download = Data(bytes.prefix(count)); setWrite(tunnel.client, true) }
    }
    private func writeRelay(_ tunnel: Tunnel, upstream uploading: Bool) {
        guard let remote = tunnel.upstream, let admission = tunnel.admission else { close(tunnel); return }
        let destination = uploading ? remote : tunnel.client
        let data = uploading ? tunnel.upload : tunnel.download
        guard !data.isEmpty else { setWrite(destination, false); finishHalfCloses(tunnel); return }
        do {
            var requested = data.count
            #if DEBUG
            if let cap = testing?.maximumWriteBytes { requested = min(requested, max(1, cap)) }
            #endif
            let permit = try budget!.reserveWrite(admission, direction: uploading ? .upstream : .downstream,
                                                   requestedBytes: requested, now: ProcessInfo.processInfo.systemUptime)
            #if DEBUG
            if testing?.invalidateBeforeRelayWrite == true { invalidate() }
            #endif
            let count: Int, savedErrno: Int32
            do {
                (count, savedErrno) = try whileAdmissionOpen {
                    try budget!.checkActive(now: ProcessInfo.processInfo.systemUptime)
                    let count = data.withUnsafeBytes { Darwin.send(destination.descriptor, $0.baseAddress!, permit.byteCount, 0) }
                    return (count, errno)
                }
            } catch {
                // A reservation is already outstanding even when invalidation
                // wins before send. Settle its zero-byte receipt exactly once.
                try? budget!.settleWrite(permit, successfulBytes: 0, now: ProcessInfo.processInfo.systemUptime)
                throw error
            }
            #if DEBUG
            if count > 0 && count < permit.byteCount { partialWrites += 1 }
            if count < 0 && (savedErrno == EAGAIN || savedErrno == EWOULDBLOCK) { wouldBlockWrites += 1 }
            #endif
            // A synchronous nonblocking syscall is always settled immediately,
            // including cancellation/failure/partial success. No permit escapes.
            try budget!.settleWrite(permit, successfulBytes: max(0, count), now: ProcessInfo.processInfo.systemUptime)
            if budget!.terminalFailure != nil || !isOpen { stop(); return }
            if count < 0 && (savedErrno == EINTR || savedErrno == EAGAIN || savedErrno == EWOULDBLOCK) { return }
            guard count > 0 else { close(tunnel); return }
            if uploading { tunnel.upload.removeFirst(count) } else { tunnel.download.removeFirst(count) }
            if uploading ? tunnel.upload.isEmpty : tunnel.download.isEmpty {
                setWrite(destination, false)
                if uploading { if !tunnel.clientEOF { setRead(tunnel.client, true) } }
                else if !tunnel.upstreamEOF { setRead(remote, true) }
                finishHalfCloses(tunnel)
            }
        } catch { stop() }
    }
    private func finishHalfCloses(_ tunnel: Tunnel) {
        guard let remote = tunnel.upstream else { return }
        if tunnel.clientEOF, tunnel.upload.isEmpty, !tunnel.uploadShutdown {
            tunnel.uploadShutdown = true; Darwin.shutdown(remote.descriptor, SHUT_WR)
        }
        if tunnel.upstreamEOF, tunnel.download.isEmpty, !tunnel.downloadShutdown {
            tunnel.downloadShutdown = true; Darwin.shutdown(tunnel.client.descriptor, SHUT_WR)
        }
        if tunnel.uploadShutdown, tunnel.downloadShutdown { close(tunnel) }
    }
    private func close(_ tunnel: Tunnel) {
        guard tunnel.phase != .closing else { return }
        tunnel.phase = .closing
        if let admission = tunnel.admission { try? budget?.endAdmission(admission) }
        tunnel.upload.removeAll(); tunnel.download.removeAll(); tunnel.reply.removeAll()
        close(tunnel.client)
        if let upstream = tunnel.upstream { close(upstream) }
        scheduleDeadline()
    }
    private func scheduleDeadline() {
        guard !stopping, let timer else { return }
        let deadline = tunnels.values.filter { $0.phase == .header || $0.phase == .connecting }
            .reduce(absoluteDeadline) { min($0, $1.deadline) }
        timer.schedule(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), leeway: .milliseconds(1))
    }
    private func deadlineFired() {
        guard isOpen, !stopping else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < absoluteDeadline else { preparationError = SearchEgressFailure.deadlineExceeded; stop(); return }
        for tunnel in Array(tunnels.values) where (tunnel.phase == .header || tunnel.phase == .connecting) && now >= tunnel.deadline {
            close(tunnel)
        }
        scheduleDeadline()
    }
    private func stop() {
        gate.lock(); admissionOpen = false; gate.unlock()
        if !stopping {
            stopping = true; budget?.invalidate(); resolver?.cancel()
            for tunnel in Array(tunnels.values) { close(tunnel) }
            if let listener { close(listener) }
            if let timer, !timerCancelling { timerCancelling = true; timer.cancel() }
        }
        finishDrainIfPossible()
    }
    private func finishDrainIfPossible() {
        guard stopping, !drained, sockets.isEmpty, resolver == nil, timer == nil else { return }
        drained = true
        let pending = preparing; preparing = nil
        pending?.resume(throwing: preparationError)
        let waiters = drainWaiters; drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    #if DEBUG
    /// Test-only fixed-host resolver and owned loopback connector. This entire
    /// interface is absent in Release. It cannot supply a name, protocol, family,
    /// arbitrary descriptor, or production target; real peer checks stay active.
    struct Testing: Sendable {
        let resolve: @Sendable () async throws -> [String]
        let loopbackPort: UInt16
        var expectedPeerPort: UInt16? = nil
        var maximumWriteBytes: Int? = nil
        var socketSendBufferBytes: Int32? = nil
        var holdConnectCompletion = false
        var holdCloseReceipts = false
        var invalidateBeforeConnect = false
        var invalidateBeforeRelayWrite = false
    }
    private func configureTestBuffer(_ descriptor: Int32) throws {
        if var bytes = testing?.socketSendBufferBytes {
            guard bytes > 0, bytes <= 32_768,
                  setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bytes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw SearchEgressSocketFailure.socketFailure
            }
        }
    }
    convenience init(generation: UUID, testing: Testing) throws {
        try self.init(generation: generation); self.testing = testing
    }
    struct Snapshot: Sendable {
        let listenerDescriptor: Int32?
        let sockets: Int
        let headers: Int
        let admissions: Int
        let upstreamBytes: Int
        let downstreamBytes: Int
        let pendingWrites: Int
        let resolverCalls: Int
        let connectAttempts: Int
        let actualCloses: Int
        let partialWrites: Int
        let wouldBlockWrites: Int
        let clientSendBufferBytes: [Int32]
        let tunnelPhases: [String]
        let deferredCloseReceipts: Int
        let requestDeadline: TimeInterval?
        let drained: Bool
    }
    func testSnapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                // Read actual kernel sizes after the TCP handshake; the OS may
                // round the requested DEBUG send buffer. Never expose descriptors.
                let clientSendBufferBytes = sockets.values.compactMap { socket -> Int32? in
                    guard case .client = socket.role, !socket.closing, !socket.closed else { return nil }
                    var bytes: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                    return getsockopt(socket.descriptor, SOL_SOCKET, SO_SNDBUF, &bytes, &size) == 0 ? bytes : -1
                }
                continuation.resume(returning: Snapshot(listenerDescriptor: listener?.descriptor,
                    sockets: sockets.count, headers: tunnels.values.filter { $0.admission == nil }.count,
                    admissions: budget?.authenticatedAdmissions ?? 0, upstreamBytes: budget?.upstreamBytes ?? 0,
                    downstreamBytes: budget?.downstreamBytes ?? 0, pendingWrites: budget?.pendingWriteCount ?? 0,
                    resolverCalls: resolverCalls, connectAttempts: connectAttempts, actualCloses: actualCloses,
                    partialWrites: partialWrites, wouldBlockWrites: wouldBlockWrites, clientSendBufferBytes: clientSendBufferBytes,
                    tunnelPhases: tunnels.values.map { String(describing: $0.phase) }.sorted(), deferredCloseReceipts: deferredCloses.count, requestDeadline: budget?.absoluteDeadline, drained: drained))
            }
        }
    }
    func testReleaseConnectCompletion() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                testing?.holdConnectCompletion = false
                if isOpen, !stopping {
                    for tunnel in tunnels.values where tunnel.phase == .connecting {
                        if let upstream = tunnel.upstream { setWrite(upstream, true) }
                    }
                }
                continuation.resume()
            }
        }
    }
    func testReleaseCloseReceipts() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                testing?.holdCloseReceipts = false
                let closed = deferredCloses; deferredCloses.removeAll()
                for socket in closed { closedReceipt(socket) }
                continuation.resume()
            }
        }
    }
    #endif
}
