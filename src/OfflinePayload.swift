import Foundation
import CryptoKit

struct OfflineFile: Decodable {
    let path: String
    let kind: String
    let bytes: Int64?
    let sha256: String?
    let target: String?
}
struct RuntimeManifest: Decodable {
    struct Component: Decodable { let role: String; let files: [String]; let license_paths: [String] }
    let schema_version: Int
    let kind: String
    let files: [OfflineFile]
    let components: [Component]
    let transport_patch: String?
}
enum OfflineFailure: LocalizedError {
    case incomplete, corrupt, space, download, paused, runtime
    var errorDescription: String? {
        switch self {
        case .incomplete: return "This is a development build without its local voice runtime. Please install the complete Dot installer."
        case .corrupt: return "A bundled file failed its integrity check. This app needs a repaired complete build."
        case .space: return "I need space for the remaining model files plus 5 GB of working space."
        case .download: return "A required local file is unavailable."
        case .paused: return "The operation was paused."
        case .runtime: return "My bundled Splash engine couldn't start. No other engine was used."
        }
    }
}

actor OfflinePayload {
    static let shared = OfflinePayload()
    /// A new, independently sandboxed source-fetch process uses the bundled native
    /// `dot-fetch` reader (`crates/dot-research`). No interpreter, stdlib or script is
    /// involved, and the reader never joins Splash's process, environment or model.
    nonisolated static func sourceReader() -> ResearchWebReader {
        let resources = Bundle.main.resourceURL
        return ResearchWebReader(transport: ResearchPinnedHTTPTransport(verifiedRuntime: {
            guard let resources, let native = Bundle.main.executableURL?
                .deletingLastPathComponent().appendingPathComponent("dot-fetch") else { throw OfflineFailure.incomplete }
            // The payload audit is still the integrity receipt for the reader process.
            _ = try await OfflinePayload.shared.validate()
            return try ResearchFetchRuntime(signedHelper: native,
                signedProfile: resources.appendingPathComponent("Research/source_fetch.sb"))
        }))
    }
    private var validation: (id: UUID, task: Task<URL, Error>)?
    private var verified: URL?
    private let root: URL?
    init(root: URL? = Bundle.main.resourceURL?.appendingPathComponent("Offline", isDirectory: true)) { self.root = root }
    func validate() async throws -> URL {
        try Task.checkCancellation()
        if let verified { return verified }
        guard let root else { throw OfflineFailure.incomplete }
        let current: (id: UUID, task: Task<URL, Error>)
        if let validation { current = validation }
        else {
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw OfflineFailure.incomplete }
                try Self.audit(root); return root
            }
            current = (UUID(), task); validation = current
        }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await current.task.value }, onCancel: { current.task.cancel() })
            try Task.checkCancellation()
            if validation?.id == current.id { verified = value; validation = nil }
            return value
        } catch {
            if validation?.id == current.id { validation = nil }
            throw error
        }
    }
    nonisolated static func safePath(_ name: String, root: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw OfflineFailure.corrupt }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var current = canonicalRoot
        // Resolve each existing ancestor separately. Foundation may leave an entire
        // path unresolved when its final download filename does not exist yet.
        for part in name.split(separator: "/") {
            let candidate = current.appendingPathComponent(String(part)).standardizedFileURL
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil,
               !FileManager.default.fileExists(atPath: candidate.path) { throw OfflineFailure.corrupt }
            current = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard current.path.hasPrefix(canonicalRoot.path + "/") else { throw OfflineFailure.corrupt }
        }
        return root.appendingPathComponent(name).standardizedFileURL
    }
    nonisolated static func hash(_ url: URL, bytes: Int64, expected: String) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard bytes >= 0, expected.count == 64, values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == bytes else { throw OfflineFailure.corrupt }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256(), read: Int64 = 0
        // Up to 8 MiB per read for multi-gigabyte models, never more than the file needs (one
        // byte more detects a file that grew); each chunk is released before the next.
        while true {
            let wanted = Int(min(max(1, bytes - read + 1), 8_388_608))
            let data = try autoreleasepool { try file.read(upToCount: wanted) }
            guard let data, !data.isEmpty else { break }
            try Task.checkCancellation()
            read += Int64(data.count); guard read <= bytes else { throw OfflineFailure.corrupt }; digest.update(data: data)
        }
        guard read == bytes, digest.finalize().hexString == expected else { throw OfflineFailure.corrupt }
    }
    nonisolated static func verifyHash(_ url: URL, bytes: Int64, expected: String) async throws {
        try Task.checkCancellation()
        // The owner waits on this check before Dot can answer, so it is user-initiated work.
        let task = Task.detached(priority: .userInitiated) { try hash(url, bytes: bytes, expected: expected) }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    nonisolated static func audit(_ root: URL) throws {
        try Task.checkCancellation()
        let manifestURL = root.appendingPathComponent("runtime-manifest.json")
        let manifestValues = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
              (1...16_000_000).contains(manifestValues.fileSize ?? 0),
              let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data),
              manifest.schema_version == 1, manifest.kind == "verified_runtime_payload", !manifest.files.isEmpty,
              manifest.files.count <= 100_000 else { throw OfflineFailure.incomplete }
        let roles = Set(manifest.components.map(\.role))
        guard manifest.components.count == 3, roles == Set(["splash_runtime", "speech_recognition", "speech_synthesis"]) else { throw OfflineFailure.incomplete }
        let names = manifest.files.map(\.path)
        guard Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == names.count else { throw OfflineFailure.corrupt }
        guard manifest.transport_patch == "dot-splash-owned-listener-secret-pipe-v2" else { throw OfflineFailure.incomplete }
        let managedSources = [
            "Splash/install/launcher.py": "bc04fa504e8fd6df2aa2b8ff0d00f2580add0d771d50ddd5120a5937bbf23493",
            "Splash/server/serve_options.py": "d254b93bad8e84e8ac30add4e6d2cca1ad85dda423151081982be4d8a36ad9e7",
            "Splash/server/server.py": "32de35c53d12d9a6596cb1c4cc630fdaa9a69104176c1c61e0c55453324140e7"
        ]
        guard managedSources.allSatisfy({ name, expected in manifest.files.contains { $0.path == name && $0.kind == "file" && $0.sha256 == expected } }) else { throw OfflineFailure.incomplete }
        let nameSet = Set(names)
        let entries = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        var total: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let path = try safePath(file.path, root: root)
            if file.kind == "file", let bytes = file.bytes, let checksum = file.sha256 {
                guard (0...5_000_000_000).contains(bytes) else { throw OfflineFailure.corrupt }
                total += bytes; guard total <= 5_000_000_000 else { throw OfflineFailure.corrupt }
                guard !(try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) else { throw OfflineFailure.corrupt }
                try hash(path, bytes: bytes, expected: checksum)
            } else if file.kind == "symlink", let target = file.target, !target.hasPrefix("/") {
                guard try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == target else { throw OfflineFailure.corrupt }
            } else { throw OfflineFailure.corrupt }
        }
        let enumerationRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: enumerationRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw OfflineFailure.corrupt }
        var actual = Set<String>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isDirectory != true {
                let prefix = enumerationRoot.path + "/"
                guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw OfflineFailure.corrupt }
                let name = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                if name != "runtime-manifest.json" { actual.insert(name) }
                if actual.count > 100_000 { throw OfflineFailure.corrupt }
            }
        }
        guard actual == nameSet else { throw OfflineFailure.corrupt }
        for component in manifest.components {
            guard !component.files.isEmpty, !component.license_paths.isEmpty,
                  (component.files + component.license_paths).allSatisfy({ nameSet.contains($0) }) else { throw OfflineFailure.incomplete }
        }
        let requiredByRole = [
            "splash_runtime": ["Splash/python/bin/python3", "Splash/install/launcher.py", "Splash/engine/splash", "Splash/engine/splash.metallib"],
            "speech_synthesis": ["Voice/python/bin/python3", "Voice/model/config.json", "Voice/model/kokoro-v1_0.pth", "Voice/model/voices/bf_isabella.pt"],
            "speech_recognition": ["STT/ggml-base.en.bin"]
        ]
        for (role, required) in requiredByRole {
            guard let component = manifest.components.first(where: { $0.role == role }) else { throw OfflineFailure.incomplete }
            let componentNames = Set(component.files)
            for name in required {
                guard componentNames.contains(name), let entry = entries[name] else { throw OfflineFailure.incomplete }
                let path = try safePath(name, root: root)
                if entry.kind == "symlink" {
                    let resolved = path.resolvingSymlinksInPath()
                    guard try manifest.files.contains(where: { candidate in
                        guard candidate.kind == "file", componentNames.contains(candidate.path) else { return false }
                        return try safePath(candidate.path, root: root).resolvingSymlinksInPath() == resolved
                    }) else { throw OfflineFailure.corrupt }
                }
                guard FileManager.default.isReadableFile(atPath: path.path) else { throw OfflineFailure.incomplete }
            }
        }
    }
}
