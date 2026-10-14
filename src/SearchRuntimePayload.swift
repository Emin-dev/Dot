import Foundation
import CryptoKit
#if os(macOS)
import Darwin
import Security
#endif

struct SearchPayloadFile: Decodable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

struct SearchPayloadManifest: Decodable, Sendable {
    let `protocol`: Int
    let searxng_revision: String
    let waitress_version: String
    let ddg_transient_patch_sha256: String
    let native_bootstrap: String
    let acceptance_receipt: String
    let files: [SearchPayloadFile]
}

/// Construction is confined to the real audit. A Boolean, arbitrary URL or
/// injected "verified" callback cannot mint a production launch configuration.
struct ValidatedSearchPayload: Sendable {
    let root: URL
    let bootstrap: URL
    let python: URL
    let helper: URL
    let profile: URL
    fileprivate init(root: URL) {
        self.root = root
        bootstrap = root.appendingPathComponent("bin/dot-search-bootstrap")
        python = root.appendingPathComponent("python/bin/python3")
        helper = root.appendingPathComponent("dot_search.py")
        profile = root.appendingPathComponent("search.sb")
    }
}

struct SearchRuntimeFactory: Sendable {
    private let bundleURL: URL
    private let resourcesURL: URL?
    init(bundle: Bundle = .main) { bundleURL = bundle.bundleURL; resourcesURL = bundle.resourceURL }

    func audit() throws -> ValidatedSearchPayload {
        guard let resourcesURL else { throw SearchRuntimeFailure.unavailable }
        let requested = resourcesURL.appendingPathComponent("Search", isDirectory: true)
        guard FileManager.default.fileExists(atPath: requested.appendingPathComponent("search-runtime-manifest.json").path) else {
            throw SearchRuntimeFailure.unavailable
        }
        #if os(macOS) && arch(arm64)
        try Task.checkCancellation()
        let root = requested.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == requested.standardizedFileURL.path else { throw SearchRuntimeFailure.invalidPayload }
        // The signed app's resource seal authenticates the manifest and acceptance
        // reports. Hashes listed by an unsigned adjacent JSON file prove nothing.
        guard bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
              resourcesURL.standardizedFileURL == Bundle.main.resourceURL?.standardizedFileURL else {
            throw SearchRuntimeFailure.invalidSignature
        }
        let appIdentity = try Self.signingIdentity(bundleURL, requirement: nil)
        try Self.verifyRunningApp(appIdentity)
        let manifest = try SearchPayloadAudit.verify(root)
        guard manifest.native_bootstrap == "bin/dot-search-bootstrap" else { throw SearchRuntimeFailure.invalidPayload }
        // An ad-hoc owner candidate still needs a real validated code/resource
        // seal and exact technical evidence. Paid Developer ID is a release gate.
        let teamRequirement = appIdentity.team.map {
            "anchor apple generic and certificate leaf[subject.OU] = \"\($0)\" and "
        } ?? ""
        if appIdentity.team != nil {
            _ = try Self.signingIdentity(bundleURL, requirement: String(teamRequirement.dropLast(5)))
        }
        _ = try Self.signingIdentity(root.appendingPathComponent("bin/dot-search-bootstrap"),
                                    requirement: teamRequirement + "identifier \"app.dot.search-bootstrap\"")
        _ = try Self.signingIdentity(root.appendingPathComponent("python/bin/python3"),
                                    requirement: teamRequirement + "identifier \"app.dot.search-python\"")
        try Task.checkCancellation()
        return ValidatedSearchPayload(root: root)
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }

    #if os(macOS)
    private struct SigningIdentity {
        let team: String?
        let cdHash: Data
    }
    private static func verifyRunningApp(_ expected: SigningIdentity) throws {
        var running: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate | SecCSFlags.noNetworkAccess.rawValue), nil) == errSecSuccess else {
            throw SearchRuntimeFailure.invalidSignature
        }
        var current: SecStaticCode?
        guard SecCodeCopyStaticCode(running, SecCSFlags(), &current) == errSecSuccess, let current else {
            throw SearchRuntimeFailure.invalidSignature
        }
        let actual = try identity(current)
        guard actual.cdHash == expected.cdHash, actual.team == expected.team else { throw SearchRuntimeFailure.invalidSignature }
    }
    private static func signingIdentity(_ url: URL, requirement text: String?) throws -> SigningIdentity {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw SearchRuntimeFailure.invalidSignature
        }
        var requirement: SecRequirement?
        if let text {
            guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess else {
                throw SearchRuntimeFailure.invalidSignature
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | SecCSFlags.noNetworkAccess.rawValue)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw SearchRuntimeFailure.invalidSignature }
        return try identity(code)
    }
    private static func identity(_ code: SecStaticCode) throws -> SigningIdentity {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let cdHash = values[kSecCodeInfoUnique as String] as? Data,
              !cdHash.isEmpty, let flags = values[kSecCodeInfoFlags as String] as? NSNumber else {
            throw SearchRuntimeFailure.invalidSignature
        }
        let team = values[kSecCodeInfoTeamIdentifier as String] as? String
        if let team {
            guard team.utf8.count == 10, team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
                throw SearchRuntimeFailure.invalidSignature
            }
        } else {
            guard flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0 else { throw SearchRuntimeFailure.invalidSignature }
        }
        return SigningIdentity(team: team, cdHash: cdHash)
    }
    #endif
}

/// Pure artifact audit is independently testable; it does not return the sealed
/// launch type and is never a signature substitute.
enum SearchPayloadAudit {
    static let requiredFiles: Set<String> = ["python/bin/python3", "dot_search.py", "bin/dot-search-bootstrap", "search.sb"]
    static let gates: Set<String> = ["native_boundary", "transient_cache",
                                     "searxng_waitress_compatibility"]
    struct Receipt: Decodable {
        struct Gate: Decodable { let result: String; let report: String; let sha256: String }
        let schema: Int
        let platform: String
        let payload_digest: String
        let gates: [String: Gate]
    }

    static func verify(_ root: URL) throws -> SearchPayloadManifest {
        #if os(macOS)
        let reader = try Reader(root: root)
        defer { reader.close() }
        let data = try reader.data("search-runtime-manifest.json", limit: 4 * 1024 * 1024)
        guard let manifest = try? JSONDecoder().decode(SearchPayloadManifest.self, from: data),
              manifest.protocol == 1,
              manifest.searxng_revision == "22c64b8d394b680c7ea96be25f36dad14126420a",
              manifest.waitress_version == "3.0.2",
              manifest.ddg_transient_patch_sha256 == "e4683ebd1207d9011016123ba09f8dc72af19638f164304ef94d5349cb09489f",
              manifest.native_bootstrap == "bin/dot-search-bootstrap",
              manifest.acceptance_receipt == "evidence/search-acceptance.json",
              !manifest.files.isEmpty, manifest.files.count <= 50_000 else { throw SearchRuntimeFailure.invalidPayload }
        let names = manifest.files.map(\.path)
        guard Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count,
              requiredFiles.isSubset(of: Set(names)), Set(names).contains(manifest.acceptance_receipt) else {
            throw SearchRuntimeFailure.invalidPayload
        }
        var total: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard validRelativePath(file.path), file.path != "search-runtime-manifest.json",
                  (0...2_000_000_000).contains(file.size), isHash(file.sha256) else { throw SearchRuntimeFailure.invalidPayload }
            total += file.size
            guard total <= 5_000_000_000 else { throw SearchRuntimeFailure.invalidPayload }
            guard try reader.hash(file.path, expectedSize: file.size) == file.sha256 else {
                throw SearchRuntimeFailure.invalidPayload
            }
        }
        guard try reader.checkTree() == Set(names).union(["search-runtime-manifest.json"]) else {
            throw SearchRuntimeFailure.invalidPayload
        }
        try verifyReceipt(manifest, data: reader.data(manifest.acceptance_receipt, limit: 1_048_576))
        return manifest
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }

    static func payloadDigest(_ files: [SearchPayloadFile]) -> String {
        let lines = files.filter { !$0.path.hasPrefix("evidence/") }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            .map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyReceipt(_ manifest: SearchPayloadManifest, root: URL) throws {
        #if os(macOS)
        let reader = try Reader(root: root)
        defer { reader.close() }
        try verifyReceipt(manifest, data: reader.data(manifest.acceptance_receipt, limit: 1_048_576))
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }
    private static func verifyReceipt(_ manifest: SearchPayloadManifest, data: Data) throws {
        // Parse exactly the receipt bytes bound by the manifest, not a later
        // same-path replacement after the first whole-tree hash pass.
        guard let entry = manifest.files.first(where: { $0.path == manifest.acceptance_receipt }),
              Int64(data.count) == entry.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schema == 1, receipt.platform == "macOS-arm64",
              receipt.payload_digest == payloadDigest(manifest.files), Set(receipt.gates.keys) == gates else {
            throw SearchRuntimeFailure.unacceptedPayload
        }
        for gate in receipt.gates.values {
            guard gate.result == "passed", gate.report.hasPrefix("evidence/"),
                  gate.report != manifest.acceptance_receipt, validRelativePath(gate.report), isHash(gate.sha256),
                  manifest.files.contains(where: { $0.path == gate.report && $0.sha256 == gate.sha256 && $0.size > 0 }) else {
                throw SearchRuntimeFailure.unacceptedPayload
            }
        }
    }

    static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && value.utf8.allSatisfy { $0 >= 32 && $0 != 127 }
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func boundedFile(_ url: URL, limit: Int) throws -> Data {
        guard limit > 0, limit < Int.max else { throw SearchRuntimeFailure.invalidPayload }
        #if os(macOS)
        let reader = try Reader(root: url.deletingLastPathComponent())
        defer { reader.close() }
        return try reader.data(url.lastPathComponent, limit: limit)
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }
    static func hashFile(_ url: URL, expectedSize: Int64) throws -> String {
        guard (0...2_000_000_000).contains(expectedSize) else { throw SearchRuntimeFailure.invalidPayload }
        #if os(macOS)
        let reader = try Reader(root: url.deletingLastPathComponent())
        defer { reader.close() }
        return try reader.hash(url.lastPathComponent, expectedSize: expectedSize)
        #else
        throw SearchRuntimeFailure.unavailable
        #endif
    }
    #if os(macOS)
    /// One audit owns one root descriptor and remembers every visited identity.
    /// Paths outside the supplied payload root may contain normal system aliases
    /// (for example /var). Inside the root, every component is opened no-follow.
    /// This is artifact inspection only; it cannot mint a launch configuration.
    /// Descriptor and metadata checks do not make the filesystem immutable or
    /// establish a hard deadline for pathological kernel/storage stalls.
    final class Reader {
        private let root: URL
        private var descriptor: Int32
        private var identities: [String: stat] = [:]

        init(root: URL) throws {
            try Task.checkCancellation()
            var before = stat(), opened = stat()
            guard root.isFileURL, lstat(root.path, &before) == 0, SearchPayloadAudit.validNode(before, directory: true) else {
                throw SearchRuntimeFailure.invalidPayload
            }
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw SearchRuntimeFailure.invalidPayload }
            guard fstat(fd, &opened) == 0, SearchPayloadAudit.validNode(opened, directory: true), SearchPayloadAudit.sameFile(before, opened) else {
                Darwin.close(fd); throw SearchRuntimeFailure.invalidPayload
            }
            self.root = root; descriptor = fd; identities[""] = opened
        }
        func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        deinit { close() }

        func data(_ name: String, limit: Int) throws -> Data {
            guard limit > 0, limit < Int.max else { throw SearchRuntimeFailure.invalidPayload }
            var data = Data()
            try readFile(name, maximumSize: Int64(limit)) { data.append($0) }
            guard !data.isEmpty else { throw SearchRuntimeFailure.invalidPayload }
            return data
        }
        func hash(_ name: String, expectedSize: Int64) throws -> String {
            guard (0...2_000_000_000).contains(expectedSize) else { throw SearchRuntimeFailure.invalidPayload }
            var hash = SHA256()
            try readFile(name, maximumSize: expectedSize, expectedSize: expectedSize) { hash.update(data: $0) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        /// Shared production streaming primitive. A consumer observes only bytes
        /// from the checked descriptor and cannot replace the I/O or validators.
        func readFile(_ name: String, maximumSize: Int64, expectedSize: Int64? = nil,
                      consume: (Data) throws -> Void) throws {
            guard SearchPayloadAudit.validRelativePath(name), maximumSize >= 0, maximumSize < Int64.max else {
                throw SearchRuntimeFailure.invalidPayload
            }
            let parts = name.split(separator: "/").map(String.init)
            try withDirectory(Array(parts.dropLast())) { parent in
                var before = stat()
                guard fstatat(parent, parts.last!, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      SearchPayloadAudit.validNode(before, directory: false), before.st_size >= 0, before.st_size <= maximumSize,
                      expectedSize == nil || before.st_size == expectedSize else { throw SearchRuntimeFailure.invalidPayload }
                try remember(name, before)
                let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw SearchRuntimeFailure.invalidPayload }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, SearchPayloadAudit.validNode(opened, directory: false) else {
                    throw SearchRuntimeFailure.invalidPayload
                }
                try remember(name, opened)
                var total: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let maximum = Int(min(1_048_576, before.st_size - total + 1))
                    guard let chunk = try handle.read(upToCount: maximum), !chunk.isEmpty else { break }
                    try Task.checkCancellation()
                    total += Int64(chunk.count)
                    guard total <= before.st_size else { throw SearchRuntimeFailure.invalidPayload }
                    try consume(chunk)
                }
                guard total == before.st_size else { throw SearchRuntimeFailure.invalidPayload }
                try Task.checkCancellation()
                var after = stat(), current = stat()
                guard fstat(fd, &after) == 0, fstatat(parent, parts.last!, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      SearchPayloadAudit.validNode(after, directory: false), SearchPayloadAudit.validNode(current, directory: false) else {
                    throw SearchRuntimeFailure.invalidPayload
                }
                try remember(name, after); try remember(name, current)
            }
        }

        private func remember(_ name: String, _ info: stat) throws {
            if let earlier = identities[name] {
                guard SearchPayloadAudit.sameFile(earlier, info) else { throw SearchRuntimeFailure.invalidPayload }
            } else { identities[name] = info }
        }
        private func withDirectory<T>(_ parts: [String], body: (Int32) throws -> T) throws -> T {
            try Task.checkCancellation()
            guard descriptor >= 0 else { throw SearchRuntimeFailure.invalidPayload }
            var opened: [(name: String, descriptor: Int32)] = [("", descriptor)]
            defer { for node in opened.dropFirst().reversed() { Darwin.close(node.descriptor) } }
            var rootInfo = stat()
            guard fstat(descriptor, &rootInfo) == 0, SearchPayloadAudit.validNode(rootInfo, directory: true) else {
                throw SearchRuntimeFailure.invalidPayload
            }
            try remember("", rootInfo)
            for part in parts {
                try Task.checkCancellation()
                let parent = opened.last!
                let name = parent.name.isEmpty ? part : parent.name + "/" + part
                var before = stat(), current = stat()
                guard fstatat(parent.descriptor, part, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      SearchPayloadAudit.validNode(before, directory: true) else { throw SearchRuntimeFailure.invalidPayload }
                try remember(name, before)
                let fd = openat(parent.descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw SearchRuntimeFailure.invalidPayload }
                opened.append((name, fd))
                guard fstat(fd, &current) == 0, SearchPayloadAudit.validNode(current, directory: true) else {
                    throw SearchRuntimeFailure.invalidPayload
                }
                try remember(name, current)
            }
            let result = try body(opened.last!.descriptor)
            // Retain every ancestor descriptor through the read, then check both
            // its inode and the directory entry through its pinned parent.
            for (index, node) in opened.enumerated() {
                try Task.checkCancellation()
                var current = stat(), entry = stat()
                guard fstat(node.descriptor, &current) == 0, SearchPayloadAudit.validNode(current, directory: true) else {
                    throw SearchRuntimeFailure.invalidPayload
                }
                try remember(node.name, current)
                let status = index == 0 ? lstat(root.path, &entry)
                    : fstatat(opened[index - 1].descriptor, parts[index - 1], &entry, AT_SYMLINK_NOFOLLOW)
                guard status == 0, SearchPayloadAudit.validNode(entry, directory: true) else { throw SearchRuntimeFailure.invalidPayload }
                try remember(node.name, entry)
            }
            return result
        }

        func checkTree() throws -> Set<String> {
            var actual = Set<String>(), pending: [[String]] = [[]], count = 0
            while let parts = pending.popLast() {
                try withDirectory(parts) { parent in
                    // fdopendir owns this separate no-follow descriptor. All
                    // classification uses fstatat, never URL resource caches.
                    let fd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw SearchRuntimeFailure.invalidPayload }
                    guard let stream = fdopendir(fd) else { Darwin.close(fd); throw SearchRuntimeFailure.invalidPayload }
                    defer { closedir(stream) }
                    while true {
                        try Task.checkCancellation()
                        errno = 0
                        guard let entry = readdir(stream) else {
                            guard errno == 0 else { throw SearchRuntimeFailure.invalidPayload }
                            break
                        }
                        let capacity = Int(entry.pointee.d_namlen) + 1
                        let component = withUnsafePointer(to: &entry.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
                        }
                        guard let component else { throw SearchRuntimeFailure.invalidPayload }
                        if component == "." || component == ".." { continue }
                        count += 1
                        guard count <= 100_000, SearchPayloadAudit.validRelativePath(component), !component.contains("/") else {
                            throw SearchRuntimeFailure.invalidPayload
                        }
                        let name = (parts + [component]).joined(separator: "/")
                        var info = stat()
                        guard fstatat(parent, component, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                            throw SearchRuntimeFailure.invalidPayload
                        }
                        let directory = info.st_mode & S_IFMT == S_IFDIR
                        guard SearchPayloadAudit.validNode(info, directory: directory), directory || identities[name] != nil else {
                            throw SearchRuntimeFailure.invalidPayload
                        }
                        try remember(name, info)
                        if directory { pending.append(parts + [component]) }
                        else { actual.insert(name) }
                    }
                }
            }
            return actual
        }
    }
    private static func validNode(_ info: stat, directory: Bool) -> Bool {
        info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
            && (directory || info.st_nlink == 1)
            && (info.st_uid == getuid() || info.st_uid == 0)
            && info.st_mode & (directory ? 0o022 : 0o6022) == 0
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    #endif
}
