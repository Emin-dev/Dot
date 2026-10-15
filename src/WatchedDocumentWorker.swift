import Foundation
import CryptoKit

/// Watched-folder document worker and project brief maintenance (R06, R09, R10, R36, R241, R242, R286).
@MainActor
final class WatchedDocumentWorker: ObservableObject {
    @Published private(set) var isWatching = false
    @Published private(set) var lastScannedAt: Date?
    @Published private(set) var processedSourceCount: Int = 0
    @Published private(set) var activeBriefTitle: String?

    private let watchedFolderURL: URL
    private let ftsStore: LocalFTSStore
    private let notebookStore: ResearchNotebookStore
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var debounceTimer: Task<Void, Never>?
    private var knownFileHashes: [String: String] = [:]

    init(folderURL: URL? = nil, ftsStore: LocalFTSStore? = nil, notebookStore: ResearchNotebookStore? = nil) {
        if let folderURL {
            self.watchedFolderURL = folderURL
        } else {
            self.watchedFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        self.ftsStore = ftsStore ?? (try! LocalFTSStore())
        self.notebookStore = notebookStore ?? (try! ResearchNotebookStore())
    }

    func start() {
        guard !isWatching else { return }
        let path = watchedFolderURL.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .link],
            queue: .main
        )

        dispatchSource.setEventHandler { [weak self] in
            self?.scheduleDebouncedScan()
        }

        dispatchSource.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        self.source = dispatchSource
        dispatchSource.resume()
        isWatching = true
        scheduleDebouncedScan()
    }

    func stop() {
        guard isWatching else { return }
        debounceTimer?.cancel()
        debounceTimer = nil
        source?.cancel()
        source = nil
        isWatching = false
    }

    private func scheduleDebouncedScan() {
        debounceTimer?.cancel()
        debounceTimer = Task { [weak self] in
            // Debounce writes by 1.5 seconds to avoid reading partially written files
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.scanAndMaintainBrief()
        }
    }

    func scanAndMaintainBrief() async {
        guard FileManager.default.fileExists(atPath: watchedFolderURL.path) else { return }
        do {
            let sources = try ResearchExtraction.localSources(folder: watchedFolderURL)
            guard !sources.isEmpty else { return }

            var hasNewOrModified = false
            for source in sources {
                let existingHash = knownFileHashes[source.originalURL.path]
                if existingHash != source.sha256 {
                    hasNewOrModified = true
                    knownFileHashes[source.originalURL.path] = source.sha256
                    try await ftsStore.indexEvidence(source: source)
                }
            }

            if hasNewOrModified {
                processedSourceCount = sources.count
                lastScannedAt = Date()
                let title = "Project Brief · \(watchedFolderURL.lastPathComponent)"
                activeBriefTitle = title
                _ = try await notebookStore.createBrief(title: title, folder: watchedFolderURL, urls: [])
            }
        } catch {
            // Non-fatal error; logs or preserves state
        }
    }
}
