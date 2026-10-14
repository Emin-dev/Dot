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
private struct SearchProxyCapability: CustomStringConvertible, CustomDebugStringConvertible {
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
