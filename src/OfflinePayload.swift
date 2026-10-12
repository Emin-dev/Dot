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
}
enum OfflineFailure: LocalizedError {
    case incomplete, corrupt, space, download, paused, runtime
    var errorDescription: String? {
        switch self {
        case .incomplete: return "This is a development build without its local voice runtime. Please install the complete Dot installer."
        case .corrupt: return "One of my local files didn't pass its integrity check. The download can be resumed safely."
        case .space: return "I need space for the remaining model files plus 5 GB of working space."
        case .download: return "The model download paused. Check your connection, then choose Resume."
        case .paused: return "Model download paused. Resume whenever you're ready."
        case .runtime: return "My bundled Splash engine couldn't start. No other engine was used."
        }
    }
}

actor OfflinePayload {
    static let shared = OfflinePayload()
    private var validation: Task<URL, Error>?
    func validate() async throws -> URL {
        if let validation { return try await validation.value }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Offline", isDirectory: true) else { throw OfflineFailure.incomplete }
        let task = Task.detached(priority: .utility) { try Self.audit(root); return root }
        validation = task
        do { return try await task.value }
        catch { validation = nil; throw error }
    }
    nonisolated static func safePath(_ name: String, root: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw OfflineFailure.corrupt }
        let path = root.appendingPathComponent(name).standardizedFileURL
        let canonical = path.resolvingSymlinksInPath().path
        guard canonical.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw OfflineFailure.corrupt }
        return path
    }
    nonisolated static func hash(_ url: URL, bytes: Int64, expected: String) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard bytes >= 0, expected.count == 64, values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == bytes else { throw OfflineFailure.corrupt }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256(), read: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            read += Int64(data.count); guard read <= bytes else { throw OfflineFailure.corrupt }; digest.update(data: data)
        }
        guard read == bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw OfflineFailure.corrupt }
    }
    nonisolated static func verifyHash(_ url: URL, bytes: Int64, expected: String) async throws {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { try hash(url, bytes: bytes, expected: expected) }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private nonisolated static func audit(_ root: URL) throws {
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
        var total: Int64 = 0
        for file in manifest.files {
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
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw OfflineFailure.corrupt }
        var actual = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isDirectory != true {
                let prefix = root.standardizedFileURL.path + "/"
                guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw OfflineFailure.corrupt }
                let name = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                if name != "runtime-manifest.json" { actual.insert(name) }
                if actual.count > 100_000 { throw OfflineFailure.corrupt }
            }
        }
        guard actual == Set(names) else { throw OfflineFailure.corrupt }
        for component in manifest.components {
            guard !component.files.isEmpty, !component.license_paths.isEmpty,
                  (component.files + component.license_paths).allSatisfy({ names.contains($0) }) else { throw OfflineFailure.incomplete }
        }
        let requiredByRole = [
            "splash_runtime": ["Splash/python/bin/python3", "Splash/install/launcher.py", "Splash/engine/splash", "Splash/engine/splash.metallib"],
            "speech_synthesis": ["Voice/python/bin/python3", "Voice/model/config.json", "Voice/model/kokoro-v1_0.pth", "Voice/model/voices/bf_isabella.pt"],
            "speech_recognition": ["STT/ggml-base.en.bin"]
        ]
        for (role, required) in requiredByRole {
            guard let component = manifest.components.first(where: { $0.role == role }) else { throw OfflineFailure.incomplete }
            for name in required {
                guard component.files.contains(name), let entry = manifest.files.first(where: { $0.path == name }) else { throw OfflineFailure.incomplete }
                let path = try safePath(name, root: root)
                if entry.kind == "symlink" {
                    let resolved = path.resolvingSymlinksInPath()
                    guard try manifest.files.contains(where: { candidate in
                        guard candidate.kind == "file", component.files.contains(candidate.path) else { return false }
                        return try safePath(candidate.path, root: root).resolvingSymlinksInPath() == resolved
                    }) else { throw OfflineFailure.corrupt }
                }
                guard FileManager.default.isReadableFile(atPath: path.path) else { throw OfflineFailure.incomplete }
            }
        }
    }
}
