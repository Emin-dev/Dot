import Foundation

/// Deliberately independent of URLs supplied by callers and of any other runtime.
/// The private control protocol carries only bounded ASCII scalar values.
enum SearchRuntimeFailure: Error, Equatable, LocalizedError, WebSearchTemporarilyUnavailable {
    case unavailable, invalidPayload, unacceptedPayload, invalidSignature
    case invalidControl, startupFailed, startupTimeout, stopped
    var retryDate: Date? { nil }
    var retryRequiresReview: Bool { true }
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Web search is unavailable in this build. Its separate local Search runtime is missing."
        case .invalidPayload, .unacceptedPayload, .invalidSignature:
            return "The separate Search runtime has not passed its required integrity and acceptance checks."
        case .invalidControl, .startupFailed, .startupTimeout:
            return "The owned Search runtime could not start safely."
        case .stopped: return "Web search was stopped."
        }
    }
}

enum SearchRuntimeStopReason: Sendable, Equatable { case userStop, interruption, sleep, quit, failure }

/// A lock makes revocation immediate even in an async cancellation handler.
/// No caller task, main-actor scheduling delay or stale provider can revive it.
final class SearchGenerationLease: @unchecked Sendable {
    let generation: UUID
    private let lock = NSLock()
    private var valid = true
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    init(generation: UUID = UUID()) { self.generation = generation }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func register(_ cancellation: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if valid { cancellations[id] = cancellation; lock.unlock() }
        else { lock.unlock(); cancellation() }
        return id
    }
    func unregister(_ id: UUID) { lock.lock(); cancellations.removeValue(forKey: id); lock.unlock() }
    func invalidate() {
        lock.lock(); valid = false
        let pending = Array(cancellations.values); cancellations.removeAll(); lock.unlock()
        for cancel in pending { cancel() }
    }
}

struct SearchReadyReceipt: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let generation: UUID
    let port: Int
    let capability: String
    let helperPID: Int32
    let serverPID: Int32
    var description: String { "Owned Search readiness (capability redacted)" }
    var debugDescription: String { description }
}

enum SearchControlEvent: Equatable, Sendable {
    case ready(SearchReadyReceipt), stopped(UUID), failed

    static func decode(_ line: Data, generation: UUID, ownedPID: Int32) throws -> Self {
        var parser = SearchControlParser(line)
        let object = try parser.object()
        guard object["protocol"] == .integer(1), let event = object["event"]?.string else {
            throw SearchRuntimeFailure.invalidControl
        }
        if event == "failed" {
            guard Set(object.keys).isSubset(of: ["protocol", "event", "generation", "reason"]),
                  let reason = object["reason"]?.string,
                  ["cancelled", "parent_closed", "invalid_control", "startup_timeout", "startup_failed",
                   "invalid_worker", "server_exited", "payload_unavailable", "native_boundary_failed"].contains(reason),
                  object["generation"] == nil || object["generation"] == .null
                    || object["generation"] == .string(generation.uuidString) else {
                throw SearchRuntimeFailure.invalidControl
            }
            return .failed
        }
        guard object["generation"] == .string(generation.uuidString) else { throw SearchRuntimeFailure.invalidControl }
        if event == "stopped" {
            guard Set(object.keys) == ["protocol", "event", "generation"] else { throw SearchRuntimeFailure.invalidControl }
            return .stopped(generation)
        }
        guard event == "ready", Set(object.keys) == ["protocol", "event", "generation", "endpoint", "capability", "helper_pid", "server_pid"],
              let helper = object["helper_pid"]?.integer, helper == Int(ownedPID), ownedPID > 0,
              let server = object["server_pid"]?.integer, server > 0, server <= Int(Int32.max), server != helper,
              let capability = object["capability"]?.string, capability.utf8.count == 64,
              capability.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let endpoint = object["endpoint"]?.string,
              endpoint.hasPrefix("http://127.0.0.1:"), endpoint.hasSuffix("/search") else {
            throw SearchRuntimeFailure.invalidControl
        }
        let digits = String(endpoint.dropFirst("http://127.0.0.1:".count).dropLast("/search".count))
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(digits), (1...65535).contains(port), digits == String(port),
              endpoint == "http://127.0.0.1:\(port)/search" else { throw SearchRuntimeFailure.invalidControl }
        return .ready(.init(generation: generation, port: port, capability: capability,
                            helperPID: ownedPID, serverPID: Int32(server)))
    }
}

/// Unlike JSONSerialization/JSONDecoder, this rejects duplicate keys, booleans
/// masquerading as numbers, floats, escaped endpoint spellings and nested values.
/// The helper emits ASCII scalars only; a permissive general parser is unnecessary.
private struct SearchControlParser {
    enum Scalar: Equatable {
        case string(String), integer(Int), null
        var string: String? { if case .string(let value) = self { return value }; return nil }
        var integer: Int? { if case .integer(let value) = self { return value }; return nil }
    }
    let bytes: [UInt8]
    var index = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func object() throws -> [String: Scalar] {
        guard !bytes.isEmpty, bytes.count < 2048, bytes.allSatisfy({ $0 < 128 }) else { throw SearchRuntimeFailure.invalidControl }
        try expect(123)
        var result: [String: Scalar] = [:]
        repeat {
            skip()
            let key = try string()
            guard result[key] == nil, result.count < 8 else { throw SearchRuntimeFailure.invalidControl }
            try expect(58); skip()
            if peek == 34 { result[key] = .string(try string()) }
            else if peek == 110 {
                guard index + 4 <= bytes.count, Array(bytes[index..<(index + 4)]) == [110,117,108,108] else {
                    throw SearchRuntimeFailure.invalidControl
                }
                index += 4; result[key] = .null
            } else {
                let start = index
                while let value = peek, (48...57).contains(value) { index += 1 }
                guard index > start, index - start <= 10,
                      index - start == 1 || bytes[start] != 48,
                      let number = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw SearchRuntimeFailure.invalidControl }
                result[key] = .integer(number)
            }
            skip()
            if peek == 125 { index += 1; break }
            try expect(44)
        } while true
        skip()
        guard index == bytes.count else { throw SearchRuntimeFailure.invalidControl }
        return result
    }
    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    mutating func skip() { while let value = peek, value == 32 || value == 9 || value == 13 { index += 1 } }
    mutating func expect(_ byte: UInt8) throws {
        skip(); guard peek == byte else { throw SearchRuntimeFailure.invalidControl }; index += 1
    }
    mutating func string() throws -> String {
        try expect(34); let start = index
        while let byte = peek, byte != 34 {
            guard byte >= 32, byte != 92 else { throw SearchRuntimeFailure.invalidControl }; index += 1
        }
        guard peek == 34 else { throw SearchRuntimeFailure.invalidControl }
        let value = String(decoding: bytes[start..<index], as: UTF8.self); index += 1; return value
    }
}
