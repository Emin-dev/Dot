import Foundation
import CryptoKit
import PDFKit
import Darwin
#if canImport(Vision)
import Vision
#endif
#if canImport(AppKit)
import AppKit
#endif

enum ResearchNotebookError: Error, LocalizedError, Equatable {
    case invalidInput, unsupportedSource, limitExceeded, unreadableSource, networkFailure, corruptNotebook, notFound
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "Choose a local folder or provide public HTTPS source URLs. HTTP sources must be reread over HTTPS."
        case .unsupportedSource: return "That source is not supported readable text or an unlocked PDF."
        case .limitExceeded: return "The source or notebook exceeds this bounded research pass. Choose fewer or smaller sources."
        case .unreadableSource: return "A selected source could not be read."
        case .networkFailure: return "A web source could not be read successfully within the request limits."
        case .corruptNotebook: return "Saved research could not be read. The existing file has been preserved."
        case .notFound: return "That research notebook is no longer available."
        }
    }
}

enum ResearchExtraction {
    static let maxBytes = 4_194_304
    static let maxCharacters = 100_000
    static let maxPages = 20
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "json", "html", "htm", "swift", "rs", "py", "js", "ts", "tsx", "jsx", "css"]

    static func extract(_ data: Data, pdf: Bool, html: Bool, encodingName: String? = nil) throws -> (text: String, pages: Int?, truncated: Bool) {
        try Task.checkCancellation()
        guard data.count <= maxBytes else { throw ResearchNotebookError.limitExceeded }
        if pdf {
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
                throw ResearchNotebookError.unsupportedSource
            }
            try Task.checkCancellation()
            var text = "", read = 0, truncated = document.pageCount > maxPages
            let count = min(document.pageCount, maxPages)
            for page in 0..<count {
                try Task.checkCancellation()
                guard let pdfPage = document.page(at: page) else { throw ResearchNotebookError.unreadableSource }
                var value = pdfPage.string ?? ""
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    #if canImport(Vision) && canImport(AppKit)
                    let thumb = pdfPage.thumbnail(of: CGSize(width: 1200, height: 1600), for: .cropBox)
                    if let cgImage = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true
                        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                        try? handler.perform([request])
                        if let observations = request.results {
                            let recognized = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                            if !recognized.isEmpty { value = recognized }
                        }
                    }
                    #endif
                }
                try Task.checkCancellation()
                if !text.isEmpty, !value.isEmpty { text += "\n" }
                let remaining = max(0, maxCharacters - text.count)
                text += String(value.prefix(remaining))
                truncated = truncated || value.count > remaining
                read += 1
                if text.count >= maxCharacters { truncated = truncated || read < document.pageCount; break }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResearchNotebookError.unreadableSource }
            return (String(text.prefix(maxCharacters)), read, truncated)
        }
        var encoding = String.Encoding.utf8
        if let encodingName {
            let value = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            guard value != kCFStringEncodingInvalidId else { throw ResearchNotebookError.unsupportedSource }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        }
        guard let decoded = String(data: data, encoding: encoding) else { throw ResearchNotebookError.unsupportedSource }
        var text = decoded, shortened = false
        if html {
            (text, shortened) = try htmlText(decoded)
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResearchNotebookError.unreadableSource }
        return (String(text.prefix(maxCharacters)), nil, shortened || text.count > maxCharacters)
    }

    private static func htmlText(_ html: String) throws -> (String, Bool) {
        // Native parsing only: never render, execute scripts, fetch assets/DTDs or
        // interpret page text as tool authority. Reject custom entity expansion.
        guard html.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw ResearchNotebookError.unsupportedSource }
        guard html.utf8.lazy.filter({ $0 == 60 }).prefix(50_001).count <= 50_000 else { throw ResearchNotebookError.limitExceeded }
        let document: XMLDocument
        do { document = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) }
        catch { throw ResearchNotebookError.unsupportedSource }
        try Task.checkCancellation()
        guard let root = document.rootElement() else { throw ResearchNotebookError.unreadableSource }
        let excluded: Set<String> = ["head", "script", "style", "noscript", "template", "svg", "canvas", "iframe", "object"]
        let blocks: Set<String> = ["address", "article", "aside", "blockquote", "br", "div", "dl", "dt", "dd", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tr", "td", "th", "ul"]
        var stack: [(XMLNode, Bool)] = [(root, false)], text = "", count = 0, visited = 0, shortened = false
        func append(_ value: String) {
            let remaining = maxCharacters - count, added = String(value.prefix(remaining))
            text += added; count += added.count
            if value.count > remaining { shortened = true }
        }
        while let (node, closing) = stack.popLast() {
            visited += 1
            if visited.isMultiple(of: 256) { try Task.checkCancellation() }
            guard visited <= 100_000 else { throw ResearchNotebookError.limitExceeded }
            if count == maxCharacters { shortened = true; break }
            if closing { append("\n"); continue }
            if node.kind == .text { append(node.stringValue ?? ""); continue }
            guard let element = node as? XMLElement else { continue }
            let name = (element.localName ?? element.name ?? "").lowercased()
            let style = element.attribute(forName: "style")?.stringValue?.lowercased().filter { !$0.isWhitespace } ?? ""
            guard !excluded.contains(name), element.attribute(forName: "hidden") == nil,
                  element.attribute(forName: "aria-hidden")?.stringValue?.lowercased() != "true",
                  !style.contains("display:none"), !style.contains("visibility:hidden") else { continue }
            if blocks.contains(name) { append("\n"); stack.append((node, true)) }
            for child in (element.children ?? []).reversed() { stack.append((child, false)) }
        }
        try Task.checkCancellation()
        text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return (text, shortened)
    }

    static func localSources(folder: URL) throws -> [ResearchSource] {
        try Task.checkCancellation()
        guard folder.isFileURL else { throw ResearchNotebookError.invalidInput }
        let rootValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw ResearchNotebookError.invalidInput }
        guard let resolved = realpath(folder.path, nil) else { throw ResearchNotebookError.unreadableSource }
        defer { free(resolved) }
        // POSIX spelling matches the enumerator's kernel paths (/private/var);
        // Foundation resolvingSymlinksInPath may deliberately prefer /var again.
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw ResearchNotebookError.unreadableSource }
        let excluded: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "vendor", "target"]
        var files: [URL] = [], visited = 0
        for case let url as URL in walk {
            try Task.checkCancellation(); visited += 1
            guard visited <= 1_000 else { throw ResearchNotebookError.limitExceeded }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { walk.skipDescendants(); continue }
            if values.isDirectory == true {
                if walk.level > 4 || excluded.contains(url.lastPathComponent) { walk.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  url.pathExtension.lowercased() == "pdf" || textExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (values.fileSize ?? maxBytes + 1) <= maxBytes else { throw ResearchNotebookError.limitExceeded }
            files.append(url)
            guard files.count <= 20 else { throw ResearchNotebookError.limitExceeded }
        }
        var totalBytes = 0
        return try files.sorted { $0.path < $1.path }.map { url in
            try Task.checkCancellation()
            let (data, modifiedAt) = try localFile(url, under: root)
            totalBytes += data.count
            guard totalBytes <= 16_777_216 else { throw ResearchNotebookError.limitExceeded }
            let pdf = url.pathExtension.lowercased() == "pdf"
            let extracted = try extract(data, pdf: pdf, html: ["html", "htm"].contains(url.pathExtension.lowercased()))
            return ResearchSource(id: UUID(), originalURL: url, finalURL: url, title: url.lastPathComponent,
                                  kind: pdf ? .localPDF : .localText, retrievedAt: Date(),
                                  modifiedAt: modifiedAt,
                                  bytesRead: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                  pagesRead: extracted.pages, text: extracted.text, truncated: extracted.truncated)
        }
    }

    /// Pin each relative directory and the leaf instead of following a link
    /// introduced after enumeration. Receipts describe this opened file snapshot.
    static func localFile(_ url: URL, under root: URL) throws -> (Data, Date) {
        try Task.checkCancellation()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.isFileURL, root.isFileURL, url.path.hasPrefix(prefix) else { throw ResearchNotebookError.invalidInput }
        let components = String(url.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw ResearchNotebookError.invalidInput }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ResearchNotebookError.unreadableSource }
        defer { close(directory) }
        for component in components.dropLast() {
            try Task.checkCancellation()
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ResearchNotebookError.unreadableSource }
            close(directory); directory = next
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ResearchNotebookError.unreadableSource }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ResearchNotebookError.unreadableSource }
        guard before.st_size >= 0, before.st_size <= maxBytes else { throw ResearchNotebookError.limitExceeded }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        try Task.checkCancellation()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size, data.count == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ResearchNotebookError.unreadableSource }
        return (data, Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000))
    }
}

final class ResearchWebReader: @unchecked Sendable {
    private let transport: any ResearchHTTPTransport
    init(transport: any ResearchHTTPTransport = ResearchPinnedHTTPTransport()) { self.transport = transport }
    static func allowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && validArchivedURL(url)
    }
    /// Structural compatibility for saved receipts only, never network admission.
    static func validArchivedURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.absoluteString.utf8.count <= 8_192, url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.utf8.count <= 253,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }) else { return false }
        if ["localhost", "local", "internal", "home.arpa"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        // inet_aton handles decimal, octal, hexadecimal and short IPv4 forms without
        // DNS. Connection-time address enforcement belongs to ResearchPinnedHTTPTransport.
        var address = in_addr()
        if host.withCString({ inet_aton($0, &address) }) != 0 || host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return true
    }
    func read(_ url: URL) async throws -> ResearchSource {
        try Task.checkCancellation()
        guard Self.allowed(url) else { throw ResearchNotebookError.invalidInput }
        do {
            let result = try await transport.fetch(url)
            let data = result.data, response = result.response
            guard (200...299).contains(response.statusCode),
                  response.expectedContentLength <= ResearchExtraction.maxBytes,
                  let finalURL = response.url, Self.allowed(finalURL) else { throw ResearchNotebookError.networkFailure }
            guard data.count <= ResearchExtraction.maxBytes else { throw ResearchNotebookError.limitExceeded }
            let mime = response.mimeType?.lowercased() ?? ""
            let pdf = mime == "application/pdf"
            guard pdf || ["text/html", "text/plain", "text/markdown", "application/json"].contains(mime) else { throw ResearchNotebookError.unsupportedSource }
            try Task.checkCancellation()
            let extracted = try ResearchExtraction.extract(data, pdf: pdf, html: mime == "text/html", encodingName: response.textEncodingName)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return ResearchSource(id: UUID(), originalURL: url, finalURL: finalURL, title: finalURL.lastPathComponent.isEmpty ? (finalURL.host ?? "Web source") : finalURL.lastPathComponent,
                                  kind: pdf ? .webPDF : .webPage, retrievedAt: Date(),
                                  modifiedAt: response.value(forHTTPHeaderField: "Last-Modified").flatMap { formatter.date(from: $0) },
                                  bytesRead: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                  pagesRead: extracted.pages, text: extracted.text, truncated: extracted.truncated, transportReceipt: .httpsOnlyV1)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ResearchNotebookError { throw error }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ResearchNotebookError.networkFailure
        }
    }
}

protocol ResearchNotebookAccess: Sendable {
    func createBrief(title: String, folder: URL?, urls: [URL]) async throws -> ResearchNotebook
    func read() async throws -> [ResearchNotebook]
    func textToCopy(id: UUID) async throws -> String
    func export(id: UUID, to destination: URL) async throws
    func delete(id: UUID) async throws
}

actor ResearchNotebookStore: ResearchNotebookAccess {
    private let directory: URL
    private let file: URL
    private let web: ResearchWebReader
    init(directory: URL? = nil, webReader: ResearchWebReader = ResearchWebReader()) throws {
        guard let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Dot/Research", isDirectory: true), base.isFileURL else { throw ResearchNotebookError.invalidInput }
        self.directory = base; file = base.appendingPathComponent("notebooks.json"); web = webReader
        try Self.prepare(base)
    }
    func createBrief(title: String, folder: URL? = nil, urls: [URL] = []) async throws -> ResearchNotebook {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              folder != nil || !urls.isEmpty, urls.count <= 10 else { throw ResearchNotebookError.invalidInput }
        guard try read().count < 20 else { throw ResearchNotebookError.limitExceeded }
        var sources = try folder.map(ResearchExtraction.localSources) ?? []
        for url in urls {
            try Task.checkCancellation(); sources.append(try await web.read(url))
            guard sources.count <= 20, sources.reduce(0, { $0 + $1.bytesRead }) <= 16_777_216 else { throw ResearchNotebookError.limitExceeded }
        }
        guard !sources.isEmpty else { throw ResearchNotebookError.unreadableSource }
        guard sources.count <= 20, sources.reduce(0, { $0 + $1.bytesRead }) <= 16_777_216 else { throw ResearchNotebookError.limitExceeded }
        let created = Date()
        let notebook = ResearchNotebook(id: UUID(), title: title, createdAt: created,
                                        briefMarkdown: ProjectBrief.make(title: title, sources: sources, createdAt: created), sources: sources)
        try Task.checkCancellation()
        var notebooks = try read(); notebooks.append(notebook); try save(notebooks)
        return notebook
    }
    func read() throws -> [ResearchNotebook] {
        try Self.prepare(directory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil { throw ResearchNotebookError.corruptNotebook }
            return []
        }
        try Self.regular(file)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: 8_388_609) ?? Data()
        guard data.count <= 8_388_608 else { throw ResearchNotebookError.limitExceeded }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.schemaVersion == 1,
              document.notebooks.count <= 20,
              document.notebooks.allSatisfy({ $0.title.count <= 200 && $0.briefMarkdown.count <= 1_048_576 && $0.sources.count <= 20 && $0.sources.allSatisfy { $0.text.count <= ResearchExtraction.maxCharacters } }) else { throw ResearchNotebookError.corruptNotebook }
        return document.notebooks
    }
    func textToCopy(id: UUID) throws -> String {
        guard let notebook = try read().first(where: { $0.id == id }) else { throw ResearchNotebookError.notFound }
        return notebook.presentedBriefMarkdown
    }
    func export(id: UUID, to destination: URL) throws {
        try Task.checkCancellation()
        guard destination.isFileURL else { throw ResearchNotebookError.invalidInput }
        if FileManager.default.fileExists(atPath: destination.path) { try Self.regular(destination) }
        else if (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil { throw ResearchNotebookError.invalidInput }
        let data = Data(try textToCopy(id: id).utf8)
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func delete(id: UUID) throws { try Task.checkCancellation(); try save(read().filter { $0.id != id }) }
    private func save(_ notebooks: [ResearchNotebook]) throws {
        guard notebooks.count <= 20, notebooks.allSatisfy({ $0.briefMarkdown.count <= 1_048_576 }) else { throw ResearchNotebookError.limitExceeded }
        try Self.prepare(directory)
        if FileManager.default.fileExists(atPath: file.path) { try Self.regular(file) }
        else if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil { throw ResearchNotebookError.corruptNotebook }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: 1, notebooks: notebooks))
        guard data.count <= 8_388_608 else { throw ResearchNotebookError.limitExceeded }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func prepare(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) == nil else { throw ResearchNotebookError.corruptNotebook }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw ResearchNotebookError.corruptNotebook }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private static func regular(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw ResearchNotebookError.corruptNotebook }
    }
    private struct Document: Codable { let schemaVersion: Int; let notebooks: [ResearchNotebook] }
}
