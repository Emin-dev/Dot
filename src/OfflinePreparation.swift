import Foundation
import Combine

struct BundledModelIndex: Decodable {
    struct Asset: Decodable { let path: String; let bytes: Int64; let sha256: String }
    let schema_version: Int
    let total_bytes: Int64
    let files: [Asset]
}

/// Reads only the signed application's own payload. There is no downloader or external-folder discovery.
@MainActor
final class OfflinePreparation: ObservableObject {
    static let shared = OfflinePreparation()
    @Published private(set) var state: CompanionReadiness = .checking
    @Published private(set) var progress = 0.0
    var ready: Bool { state == .ready }
    private(set) var root: URL?
    private let resources: URL?
    private let runtimeCheck: @Sendable () async throws -> URL
    private var work: Task<Void, Never>?
    private var resumeRequested = false
    private var generation = UUID()
    private var recognizerAvailable = false

    init(resources: URL? = Bundle.main.resourceURL,
         runtimeCheck: @escaping @Sendable () async throws -> URL = { try await OfflinePayload.shared.validate() }) {
        self.resources = resources; self.runtimeCheck = runtimeCheck
    }
    func start(nativeRecognizerAvailable: Bool? = nil) {
        if let nativeRecognizerAvailable { recognizerAvailable = nativeRecognizerAvailable }
        guard recognizerAvailable else {
            state = .unavailable("This app is missing its bundled speech recognizer. A complete build is required."); return
        }
        guard work == nil, !ready else { return }
        state = .checking; progress = 0
        let token = UUID(); generation = token
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.work = nil
                if self.resumeRequested { self.resumeRequested = false; self.start() }
            }
            do {
                do { _ = try await self.runtimeCheck() }
                catch { throw PreparationFailure.runtime }
                try Task.checkCancellation()
                guard let resources = self.resources else { throw PreparationFailure.models }
                let manifest = resources.appendingPathComponent("bundled-models.json")
                let values = try manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (1...1_000_000).contains(values.fileSize ?? 0) else { throw PreparationFailure.integrity }
                let plan = try JSONDecoder().decode(BundledModelIndex.self, from: Data(contentsOf: manifest))
                guard plan.schema_version == 1, (1...100).contains(plan.files.count),
                      plan.files.allSatisfy({ (1...25_000_000_000).contains($0.bytes) && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
                      plan.total_bytes == plan.files.reduce(0, { $0 + $1.bytes }), plan.total_bytes <= 25_000_000_000,
                      Set(plan.files.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == plan.files.count else { throw PreparationFailure.integrity }
                let folder = resources.appendingPathComponent("OfflineModels", isDirectory: true)
                let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
                      folder.resolvingSymlinksInPath().deletingLastPathComponent().path == resources.resolvingSymlinksInPath().path else { throw PreparationFailure.models }
                let closure = Task.detached(priority: .utility) { try Self.verifyClosure(folder, names: Set(plan.files.map(\.path))) }
                try await withTaskCancellationHandler(operation: { try await closure.value }, onCancel: { closure.cancel() })
                var completed: Int64 = 0
                for asset in plan.files {
                    try Task.checkCancellation()
                    let path = try OfflinePayload.safePath(asset.path, root: folder)
                    try await OfflinePayload.verifyHash(path, bytes: asset.bytes, expected: asset.sha256)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    completed += asset.bytes; self.progress = Double(completed) / Double(plan.total_bytes)
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.root = folder; self.progress = 1; self.state = .ready
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.state = .unavailable((error as? PreparationFailure ?? .integrity).localizedDescription)
            }
        }
    }
    nonisolated private static func verifyClosure(_ folder: URL, names: Set<String>) throws {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw PreparationFailure.integrity }
        var actual = Set<String>(), nodes = 0
        for case let item as URL in items {
            try Task.checkCancellation(); nodes += 1
            guard nodes <= 1000 else { throw PreparationFailure.integrity }
            let properties = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw PreparationFailure.integrity }
            if properties.isDirectory != true {
                actual.insert(String(item.path.dropFirst(folder.path.count + 1)))
                guard actual.count <= 100 else { throw PreparationFailure.integrity }
            }
        }
        guard actual == names else { throw PreparationFailure.integrity }
    }
    func pause() {
        resumeRequested = false
        guard state == .checking else { return }
         generation = UUID(); state = .paused; work?.cancel()
    }
    func retry() {
        guard !ready else { return }
        if work != nil { resumeRequested = true }
        else { start() }
    }
    func shutdown() { resumeRequested = false; generation = UUID(); work?.cancel() }
}

enum PreparationFailure: LocalizedError {
    case runtime, models, integrity
    var errorDescription: String? {
        switch self {
        case .runtime: return "The bundled voice runtime is missing or damaged. A complete build is required."
        case .models: return "The bundled local model is missing. A complete build is required."
        case .integrity: return "Bundled files could not be verified. This app needs a repaired complete build."
        }
    }
}
