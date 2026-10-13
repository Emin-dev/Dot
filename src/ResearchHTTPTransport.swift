import Foundation
import Darwin

struct ResearchHTTPResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

protocol ResearchHTTPTransport: Sendable {
    func fetch(_ url: URL) async throws -> ResearchHTTPResult
}

/// The OS resolver and isolated stdlib reader are separate bounded processes.
/// The reader receives only a vetted numeric address; it cannot resolve again.
/// Neither URLSession nor system curl is a fallback (macOS curl trust may fetch AIA).
struct ResearchPinnedHTTPTransport: ResearchHTTPTransport {
    typealias Resolver = @Sendable (String, TimeInterval) async throws -> [String]
    typealias Exchange = @Sendable (URL, String, TimeInterval) async throws -> ResearchHTTPResult
    private let resolve: Resolver
    private let exchange: Exchange
    private let timeout: TimeInterval
    private let available: Bool

    init(verifiedRuntime: (@Sendable () async throws -> ResearchFetchRuntime)? = nil, timeout: TimeInterval = 30,
         resolve: @escaping Resolver = { try await ResearchSystemHTTP.resolve($0, $1) },
         exchange: Exchange? = nil) {
        self.timeout = min(30, max(0.01, timeout)); self.resolve = resolve
        available = verifiedRuntime != nil || exchange != nil
        self.exchange = exchange ?? { url, address, deadline in
            guard let verifiedRuntime else { throw ResearchNotebookError.networkFailure }
            let runtime = try await verifiedRuntime()
            try Task.checkCancellation()
            return try await ResearchSystemHTTP.exchange(url, address, deadline, runtime: runtime)
        }
    }

    func fetch(_ url: URL) async throws -> ResearchHTTPResult {
        try Task.checkCancellation()
        guard available else { throw ResearchNotebookError.networkFailure }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var current = try Self.canonicalURL(url)
        for hop in 0...3 {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ResearchNotebookError.networkFailure }
            let addresses = try await resolve(current.host!, deadline)
            try Task.checkCancellation()
            // Reject the complete answer if *any* entry is unsafe, including mixed families.
            guard !addresses.isEmpty, addresses.count <= 64,
                  addresses.allSatisfy(ResearchPublicAddress.allowed),
                  ProcessInfo.processInfo.systemUptime < deadline else { throw ResearchNotebookError.networkFailure }
            // One address, one attempt. No DNS fallback or transparent retries.
            // dscacheutil prints AAAA first even on IPv4-only networks. Prefer a
            // vetted IPv4 candidate when present; this is selection, not a retry.
            let pin = addresses.first(where: { !$0.contains(":") }) ?? addresses[0]
            let result = try await exchange(current, pin, deadline)
            try Task.checkCancellation()
            guard result.response.url == current, result.data.count <= ResearchExtraction.maxBytes,
                  ProcessInfo.processInfo.systemUptime < deadline else { throw ResearchNotebookError.networkFailure }
            if [301, 302, 303, 307, 308].contains(result.response.statusCode) {
                guard hop < 3, let location = result.response.value(forHTTPHeaderField: "Location"),
                      location.utf8.count <= 8_192,
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else { throw ResearchNotebookError.networkFailure }
                current = try Self.redirect(from: current, to: next, count: hop + 1)
                continue
            }
            guard (200...299).contains(result.response.statusCode) else { throw ResearchNotebookError.networkFailure }
            return result
        }
        throw ResearchNotebookError.networkFailure
    }

    static func canonicalURL(_ url: URL) throws -> URL {
        guard ResearchWebReader.allowed(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.host?.lowercased() else { throw ResearchNotebookError.invalidInput }
        if host.hasSuffix(".") { host.removeLast() }
        components.scheme = components.scheme?.lowercased(); components.host = host; components.fragment = nil
        guard let clean = components.url, ResearchWebReader.allowed(clean) else { throw ResearchNotebookError.invalidInput }
        return clean
    }

    static func redirect(from: URL, to: URL, count: Int) throws -> URL {
        guard (1...3).contains(count), !(from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https") else {
            throw ResearchNotebookError.networkFailure
        }
        return try canonicalURL(to)
    }
}

/// Conservative IANA special-use policy. Even globally reachable special-purpose
/// exceptions are denied. IPv6 permits ordinary 2000::/3 global unicast only,
/// excluding protocol assignments, documentation, 6to4, old 6bone and ISATAP.
/// Mapped/compatible IPv4, NAT64, Teredo, ULA, scoped and multicast are never pins.
enum ResearchPublicAddress {
    static func allowed(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%") else { return false }
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let excluded: [(UInt32, Int)] = [
                (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10), (0x7f000000, 8),
                (0xa9fe0000, 16), (0xac100000, 12), (0xc0000000, 24), (0xc0000200, 24),
                (0xc01fc400, 24), (0xc034c100, 24), (0xc0586300, 24), (0xc0a80000, 16),
                (0xc0af3000, 24), (0xc6120000, 15), (0xc6336400, 24), (0xcb007100, 24),
                (0xe0000000, 3)
            ]
            return !excluded.contains { base, length in n >> (32 - length) == base >> (32 - length) }
        }
        var v6 = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        guard b[0] & 0xe0 == 0x20 else { return false }
        if b[0] == 0x20 && b[1] == 0x01 && b[2] < 2 { return false } // 2001::/23 (including Teredo)
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }
        if b[0] == 0x20 && b[1] == 0x02 { return false }
        if b[0] == 0x3f && (b[1] == 0xfe || (b[1] == 0xff && b[2] & 0xf0 == 0)) { return false }
        if Array(b.prefix(6)) == [0x26, 0x20, 0x00, 0x4f, 0x80, 0x00] { return false }
        if (b[8] == 0 || b[8] == 2) && b[9] == 0 && b[10] == 0x5e && b[11] == 0xfe { return false }
        return true
    }
}

enum ResearchSystemHTTP {
    static func resolve(_ host: String, _ deadline: TimeInterval) async throws -> [String] {
        let result = try await ResearchBoundedProcess.run(executable: "/usr/bin/dscacheutil",
            arguments: ["-q", "host", "-a", "name", host], deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 5),
            stdoutLimit: 16_384, stderrLimit: 1_024)
        guard result.status == 0, result.stderr.isEmpty else { throw ResearchNotebookError.networkFailure }
        return try parseDNS(result.stdout)
    }

    static func parseDNS(_ data: Data) throws -> [String] {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else { throw ResearchNotebookError.networkFailure }
        var addresses: [String] = []
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { throw ResearchNotebookError.networkFailure }
            let key = String(line[..<colon]), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "ip_address", "ipv6_address":
                guard ResearchPublicAddress.allowed(value), addresses.count < 64 else { throw ResearchNotebookError.networkFailure }
                addresses.append(value)
            case "name", "alias": break // Never use aliases as connection targets.
            default: throw ResearchNotebookError.networkFailure
            }
        }
        guard !addresses.isEmpty else { throw ResearchNotebookError.networkFailure }
        return addresses
    }

    static func exchange(_ url: URL, _ address: String, _ deadline: TimeInterval, runtime: ResearchFetchRuntime) async throws -> ResearchHTTPResult {
        guard ResearchWebReader.allowed(url), ResearchPublicAddress.allowed(address) else { throw ResearchNotebookError.networkFailure }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ResearchNotebookError.networkFailure }
        let result = try await ResearchBoundedProcess.run(executable: "/usr/bin/sandbox-exec",
            arguments: try runtime.arguments(url: url, address: address, remaining: remaining), deadline: deadline,
            stdoutLimit: ResearchExtraction.maxBytes, stderrLimit: 65_536)
        if result.status == 63 { throw ResearchNotebookError.limitExceeded }
        guard result.status == 0 else { throw ResearchNotebookError.networkFailure }
        let response = try parseMetadata(result.stderr, url: url)
        return ResearchHTTPResult(data: result.stdout, response: response)
    }

    static func parseMetadata(_ data: Data, url: URL) throws -> HTTPURLResponse {
        struct Metadata: Decodable { let status: Int; let headers: [String: String] }
        guard data.count <= 65_536, let decoded = try? JSONDecoder().decode(Metadata.self, from: data),
              (200...599).contains(decoded.status), decoded.headers.count <= 6,
              decoded.headers.keys.allSatisfy({ ["content-type", "content-length", "content-encoding", "transfer-encoding", "last-modified", "location"].contains($0) }),
              let response = HTTPURLResponse(url: url, statusCode: decoded.status, httpVersion: "HTTP/1.1", headerFields: decoded.headers) else {
            throw ResearchNotebookError.networkFailure
        }
        return response
    }
}

/// App must call this only after its pinned runtime audit succeeds. Keeping the
/// audit factory outside DotCore avoids a SwiftPM dependency on model packaging.
/// Paths alone are not an integrity receipt; there is no ambient/runtime fallback.
struct ResearchFetchRuntime: Sendable {
    let python: String
    let pythonRoot: String
    let helper: String
    let profile: String

    init(auditedPythonRoot: URL, signedHelper: URL, signedProfile: URL) throws {
        func canonical(_ url: URL, directory: Bool) throws -> String {
            guard url.isFileURL else { throw ResearchNotebookError.networkFailure }
            let result = url.resolvingSymlinksInPath().standardizedFileURL
            let values = try result.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard (directory ? values.isDirectory == true : values.isRegularFile == true) else { throw ResearchNotebookError.networkFailure }
            return result.path
        }
        pythonRoot = try canonical(auditedPythonRoot, directory: true)
        python = try canonical(auditedPythonRoot.appendingPathComponent("bin/python3"), directory: false)
        helper = try canonical(signedHelper, directory: false)
        profile = try canonical(signedProfile, directory: false)
        guard python.hasPrefix(pythonRoot + "/"), FileManager.default.isExecutableFile(atPath: python) else { throw ResearchNotebookError.networkFailure }
    }

    func arguments(url: URL, address: String, remaining: TimeInterval) throws -> [String] {
        guard ResearchWebReader.allowed(url), ResearchPublicAddress.allowed(address), remaining > 0 else { throw ResearchNotebookError.networkFailure }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let endpoint = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
        return ["-f", profile, "-D", "DOT_SOURCE_PYTHON=" + python, "-D", "DOT_SOURCE_PYTHON_ROOT=" + pythonRoot,
                "-D", "DOT_SOURCE_HELPER=" + helper, "-D", "DOT_SOURCE_ENDPOINT=" + endpoint,
                python, "-I", "-S", "-B", helper, url.absoluteString, address,
                String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), min(30, remaining))]
    }
}

/// No shell, inherited environment, temporary response files, blocking pipe reads,
/// unbounded DNS threads or detached retries. The caller owns the exact child PID.
/// Cancellation/deadline/overflow kills that child and closes both bounded pipes.
enum ResearchBoundedProcess {
    struct Output: Sendable { let stdout: Data; let stderr: Data; let status: Int32 }
    static let environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1"]

    static func run(executable: String, arguments: [String], deadline: TimeInterval,
                    stdoutLimit: Int, stderrLimit: Int) async throws -> Output {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ResearchNotebookError.networkFailure }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close()
        }
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ResearchNotebookError.networkFailure }
        }
        try process.run()
        try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
        var stdout = Data(), stderr = Data(), outEOF = false, errEOF = false
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ResearchNotebookError.networkFailure }
            if !outEOF { outEOF = try drain(output.fileHandleForReading.fileDescriptor, into: &stdout, limit: stdoutLimit) }
            if !errEOF { errEOF = try drain(errors.fileHandleForReading.fileDescriptor, into: &stderr, limit: stderrLimit) }
            if !process.isRunning, outEOF, errEOF {
                try Task.checkCancellation()
                return Output(stdout: stdout, stderr: stderr, status: process.terminationStatus)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func drain(_ fd: Int32, into data: inout Data, limit: Int) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Yield after bounded work even if the producer never stops writing.
        for _ in 0..<8 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return false }
                throw ResearchNotebookError.networkFailure
            }
            guard count <= limit - data.count else { throw ResearchNotebookError.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        return false
    }
}
