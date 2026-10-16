import AppKit
import SwiftUI

@MainActor
final class SourceReferenceModel: ObservableObject {
    @Published var path = "src/App.swift"
    @Published private(set) var reference: SourceReference?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    let commit: String?
    private let store: SourceReferenceStore?
    private var work: Task<Void, Never>?
    private var revision = UUID()

    init(provenance: SourceProvenance? = nil) {
        do {
            let value = try provenance ?? SourceProvenance.load()
            commit = value.commit; store = SourceReferenceStore(provenance: value)
        } catch {
            commit = nil; store = nil; self.error = error.localizedDescription
        }
    }

    func read() {
        cancel()
        guard let store else { return }
        let expected = revision, requested = path.trimmingCharacters(in: .whitespacesAndNewlines)
        reference = nil; error = nil; busy = true
        work = Task { [weak self] in
            do {
                let reference = try await store.read(path: requested)
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.reference = reference; self.busy = false
            } catch {
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.busy = false
            }
        }
    }

    func cancel() { revision = UUID(); work?.cancel(); work = nil; busy = false }
    func copy() {
        guard let reference, !busy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.text + "\n\n" + reference.citation, forType: .string)
    }
}

/// Reads the public source at this binary's bundled revision, never moving main.
@MainActor
final class SourceReferencePanel: NSObject, NSWindowDelegate {
    let model = SourceReferenceModel()
    var onVisibility: ((Bool) -> Void)?
    private let host = UtilityPanelHost(size: NSSize(width: 600, height: 520), minSize: NSSize(width: 440, height: 360),
                                        title: "Dot · This version's source")

    func show() {
        host.window(delegate: self) { NSHostingView(rootView: SourceReferenceView(model: model)) }
        host.present(onVisibility)
    }

    func stop() { model.cancel() }
    func windowWillClose(_ notification: Notification) { model.cancel(); onVisibility?(false) }
}

private struct SourceReferenceView: View {
    @ObservedObject var model: SourceReferenceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read dot's public source for this exact build.").font(.headline)
            if let commit = model.commit {
                Text("Revision " + commit).font(.caption.monospaced()).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Link("View latest code on GitHub ↗", destination: URL(string: "https://github.com/Emin-dev/Dot")!)
                    .font(.caption.weight(.medium))
                Text("·").foregroundStyle(.secondary)
                Link("Latest commits ↗", destination: URL(string: "https://github.com/Emin-dev/Dot/commits/main")!)
                    .font(.caption)
            }
            HStack {
                TextField("Repository path", text: $model.path).onSubmit { model.read() }
                Button("Read") { model.read() }.disabled(model.busy || model.commit == nil)
                if model.busy { Button("Cancel") { model.cancel() } }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange) }
            if let reference = model.reference {
                HStack {
                    Link(reference.path, destination: reference.citationURL)
                    Spacer()
                    Button("Copy with citation") { model.copy() }
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(reference.text).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Read " + reference.fetchedAt.formatted() + " · SHA-256 " + reference.contentSHA256)
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text(model.busy ? "Reading source…" : "Enter a file such as src/App.swift or docs/BUILD_CHECKLIST.md.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(16)
    }
}
