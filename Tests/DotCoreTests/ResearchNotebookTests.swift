import XCTest
import PDFKit
#if SWIFT_PACKAGE
@testable import DotCore
#endif

private final class ResearchFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/cancelled" { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let status = path == "/failure" ? 500 : 200
        let mime = path == "/binary" ? "application/octet-stream" : (path == "/latin" ? "text/html; charset=iso-8859-1" : "text/html")
        let body: Data
        if path == "/undeclared-large" { body = Data(repeating: 0x61, count: ResearchExtraction.maxBytes + 1) }
        else if path == "/latin" { body = "<p>Café résumé</p>".data(using: .isoLatin1)! }
        else { body = Data("<html><head><script>doNotRun()</script></head><body><h1>Original page</h1><p>Evidence &amp; facts.</p></body></html>".utf8) }
        let length = path == "/large" ? String(ResearchExtraction.maxBytes + 1) : (path == "/undeclared-large" ? "1" : String(body.count))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": length, "Last-Modified": "Tue, 14 Nov 2023 22:13:20 GMT"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ResearchNotebookTests: XCTestCase {
    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dot-research-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }
    private func web() -> ResearchWebReader {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResearchFixtureProtocol.self]
        return ResearchWebReader(configuration: config)
    }
    private func pdf(_ text: String, pages: Int = 1) -> Data {
        let contentID = 3 + pages, fontID = contentID + 1
        let stream = "BT /F1 12 Tf 20 100 Td (\(text)) Tj ET"
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [\((3..<(3 + pages)).map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages) >>"]
        for _ in 0..<pages { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 \(fontID) 0 R >> >> /Contents \(contentID) 0 R >>") }
        objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var result = "%PDF-1.4\n", offsets: [Int] = [0]
        for (index, object) in objects.enumerated() { offsets.append(result.utf8.count); result += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let start = result.utf8.count
        result += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { result += String(format: "%010d 00000 n \n", offset) }
        result += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF"
        return Data(result.utf8)
    }
    func testExplicitFolderReadsSortedTextAndSkipsHiddenDependenciesAndSymlinks() async throws {
        try await withDirectory { root in
            try Data("B evidence".utf8).write(to: root.appendingPathComponent("b.txt"))
            try Data("A evidence".utf8).write(to: root.appendingPathComponent("a.md"))
            try Data("hidden".utf8).write(to: root.appendingPathComponent(".secret.txt"))
            let dependency = root.appendingPathComponent("node_modules")
            try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
            try Data("dependency".utf8).write(to: dependency.appendingPathComponent("ignored.txt"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.txt"), withDestinationURL: root.appendingPathComponent("a.md"))
            let sources = try ResearchExtraction.localSources(folder: root)
            XCTAssertEqual(sources.map(\.title), ["a.md", "b.txt"])
            XCTAssertEqual(sources[0].text, "A evidence")
            XCTAssertEqual(sources[0].sha256.count, 64)
            XCTAssertNotNil(sources[0].modifiedAt)
            XCTAssertTrue(sources.allSatisfy(\.isUntrustedData))
        }
    }
    func testPDFKitExtractsTextAndMarksPageLimit() throws {
        let result = try ResearchExtraction.extract(pdf("PDF evidence", pages: 21), pdf: true, html: false)
        XCTAssertTrue(result.text.contains("PDF evidence"))
        XCTAssertEqual(result.pages, 20)
        XCTAssertTrue(result.truncated)
    }
    func testPinnedLocalReadRejectsReplacedDirectoryAndLeafSymlinks() async throws {
        try await withDirectory { base in
            let root = base.appendingPathComponent("selected"), outside = base.appendingPathComponent("outside")
            for path in [root, outside] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
            let canary = outside.appendingPathComponent("private.txt")
            try Data("Temporary outside canary".utf8).write(to: canary)
            let leaf = root.appendingPathComponent("changed.txt")
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: canary)
            XCTAssertThrowsError(try ResearchExtraction.localFile(leaf, under: root))
            let directory = root.appendingPathComponent("changed-folder")
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
            XCTAssertThrowsError(try ResearchExtraction.localFile(directory.appendingPathComponent("private.txt"), under: root))
            XCTAssertThrowsError(try ResearchExtraction.localFile(canary, under: root))
            let valid = root.appendingPathComponent("normal.txt"); try Data("Actual source".utf8).write(to: valid)
            let (bytes, date) = try ResearchExtraction.localFile(valid, under: root)
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "Actual source")
            XCTAssertLessThan(abs(date.timeIntervalSinceNow), 10)
        }
    }
    func testByteCharacterAndMalformedPDFLimits() throws {
        XCTAssertThrowsError(try ResearchExtraction.extract(Data(repeating: 0, count: ResearchExtraction.maxBytes + 1), pdf: false, html: false))
        XCTAssertThrowsError(try ResearchExtraction.extract(Data("not a PDF".utf8), pdf: true, html: false))
        let result = try ResearchExtraction.extract(Data(String(repeating: "x", count: 100_001).utf8), pdf: false, html: false)
        XCTAssertEqual(result.text.count, 100_000)
        XCTAssertTrue(result.truncated)
    }
    func testNativeHTMLParserExcludesRawScriptsCommentsAndHiddenText() throws {
        let html = """
        <!doctype html><html><head><style>css_secret</style></head><body>
        <p data-label="quoted > boundary">Visible <b>bold</b> evidence.</p>
        <!-- comment_secret --><script>if (x < 3) { script_secret("<p>not text</p>"); }</script>
        <p hidden>hidden_secret</p><p aria-hidden="true">aria_secret</p>
        <p style="display: none">style_secret</p><p>Final evidence</p>
        <script>unfinished_script_secret
        """
        let result = try ResearchExtraction.extract(Data(html.utf8), pdf: false, html: true)
        XCTAssertTrue(result.text.contains("Visible bold evidence.")); XCTAssertTrue(result.text.contains("Final evidence"))
        for value in ["css_secret", "comment_secret", "script_secret", "hidden_secret", "aria_secret", "style_secret", "unfinished_script_secret", "not text", "boundary"] {
            XCTAssertFalse(result.text.contains(value), value)
        }
    }
    func testHTMLDecodesUnicodeEntitiesWithoutExecutingMarkupOrExternalEntities() throws {
        let html = "<p>Café © 🙂 &#169; &#x1F642; &amp; &lt;script&gt;quoted text&lt;/script&gt;</p>"
        let result = try ResearchExtraction.extract(Data(html.utf8), pdf: false, html: true)
        XCTAssertTrue(result.text.contains("Café © 🙂 © 🙂 & <script>quoted text</script>"))
        let entity = "<!DOCTYPE html [<!ENTITY fixture SYSTEM 'file:///tmp/never-read-dot-fixture'>]><p>&fixture;</p>"
        XCTAssertThrowsError(try ResearchExtraction.extract(Data(entity.utf8), pdf: false, html: true)) {
            XCTAssertEqual($0 as? ResearchNotebookError, .unsupportedSource)
        }
    }
    func testHTMLCharacterAndNodeBudgetsAreReported() throws {
        let html = "<p>" + String(repeating: "a", count: 100_001) + "</p>"
        let result = try ResearchExtraction.extract(Data(html.utf8), pdf: false, html: true)
        XCTAssertLessThanOrEqual(result.text.count, ResearchExtraction.maxCharacters); XCTAssertTrue(result.truncated)
        let many = String(repeating: "<span>x</span>", count: 25_001)
        XCTAssertThrowsError(try ResearchExtraction.extract(Data(many.utf8), pdf: false, html: true)) {
            XCTAssertEqual($0 as? ResearchNotebookError, .limitExceeded)
        }
    }
    func testPDFBoundsDoNotAddAnExtraCharacterOrInventTruncationForShortText() throws {
        let short = try ResearchExtraction.extract(pdf("Short source", pages: 2), pdf: true, html: false)
        XCTAssertEqual(short.pages, 2); XCTAssertFalse(short.truncated)
        XCTAssertTrue(short.text.contains("Short source\nShort source"))
        let exact = try ResearchExtraction.extract(Data(String(repeating: "a", count: 100_000).utf8), pdf: false, html: false)
        XCTAssertEqual(exact.text.count, 100_000); XCTAssertFalse(exact.truncated)
    }
    func testAlreadyCancelledExtractionAndWebReadRemainCancellation() async throws {
        for pdf in [false, true] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try ResearchExtraction.extract(Data("fixture".utf8), pdf: pdf, html: !pdf)
            }
            do { _ = try await task.value; XCTFail("Cancelled extraction succeeded") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        let reader = web()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(URL(string: "https://example.org/article")!)
        }
        do { _ = try await task.value; XCTFail("Cancelled read succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await reader.read(URL(string: "https://example.org/cancelled")!); XCTFail("Cancelled transport succeeded") }
        catch is CancellationError {} catch { XCTFail("Transport cancellation became generic error: \(error)") }
    }
    func testDeclaredHTTPEncodingIsHonored() async throws {
        let source = try await web().read(URL(string: "https://example.org/latin")!)
        XCTAssertTrue(source.text.contains("Café résumé"))
        XCTAssertThrowsError(try ResearchExtraction.extract(Data("text".utf8), pdf: false, html: false, encodingName: "unknown-fixture-charset"))
    }
    func testWebFixtureProducesRealReadReceiptAndStripsExecutableHTML() async throws {
        let source = try await web().read(URL(string: "https://example.org/article")!)
        XCTAssertTrue(source.text.contains("Evidence & facts."))
        XCTAssertFalse(source.text.contains("doNotRun"))
        XCTAssertEqual(source.kind, .webPage)
        XCTAssertEqual(source.originalURL, URL(string: "https://example.org/article"))
        XCTAssertEqual(source.modifiedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(source.sha256.count, 64)
        XCTAssertGreaterThan(source.bytesRead, 0)
    }
    func testHTTPFailureUnsupportedContentAndOversizedDeclaredBodyAreRejected() async {
        for path in ["failure", "binary", "large"] {
            do { _ = try await web().read(URL(string: "https://example.org/\(path)")!); XCTFail("Expected \(path) rejection") }
            catch { XCTAssertTrue(error is ResearchNotebookError) }
        }
    }
    func testActualStreamingBodyLimitDoesNotTrustDeclaredLength() async {
        do { _ = try await web().read(URL(string: "https://example.org/undeclared-large")!); XCTFail("Expected actual body limit") }
        catch { XCTAssertEqual(error as? ResearchNotebookError, .limitExceeded) }
    }
    func testURLPolicyRejectsCredentialsFileLocalAndNumericDestinations() {
        for url in ["file:///tmp/private", "https://user:password@example.org", "http://localhost", "http://127.0.0.1", "http://127.1", "http://2130706433", "http://10.0.0.1", "http://[::1]", "http://host.local", "http://host.local.", "http://localhost.", "http://thing.internal.", "http://device.home.arpa", "http://0x7f.0.0.1", "http://0177.1", "http://example.org:0", "http://example..org"] {
            XCTAssertFalse(ResearchWebReader.allowed(URL(string: url)!), url)
        }
        XCTAssertTrue(ResearchWebReader.allowed(URL(string: "https://example.org/a")!))
        XCTAssertTrue(ResearchWebReader.allowed(URL(string: "https://www.w3.org./a")!))
        XCTAssertTrue(ResearchWebReader.allowed(URL(string: "https://xn--bcher-kva.de/a")!))
    }
    func testRedirectsAreBoundedAndRevalidateDestination() {
        let policy = ResearchRedirectPolicy(), destination = URL(string: "https://example.org/a")!
        XCTAssertTrue(policy.allowRedirect(to: destination))
        XCTAssertTrue(policy.allowRedirect(to: destination))
        XCTAssertTrue(policy.allowRedirect(to: destination))
        XCTAssertFalse(policy.allowRedirect(to: destination))
        XCTAssertFalse(ResearchRedirectPolicy().allowRedirect(to: URL(string: "http://127.0.0.1")!))
    }
    func testNotebookPersistsCopiesExportsAndDeletesWithoutModelExecution() async throws {
        try await withDirectory { root in
            let storeFolder = root.appendingPathComponent("store")
            let store = try ResearchNotebookStore(directory: storeFolder, webReader: web())
            let notebook = try await store.createBrief(title: "Project", urls: [URL(string: "https://example.org/article")!])
            let loaded = try await ResearchNotebookStore(directory: storeFolder).read()
            XCTAssertEqual(loaded, [notebook])
            let copy = try await store.textToCopy(id: notebook.id)
            XCTAssertEqual(copy, notebook.briefMarkdown)
            let export = root.appendingPathComponent("brief.md")
            try await store.export(id: notebook.id, to: export)
            XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), notebook.briefMarkdown)
            let attributes = try FileManager.default.attributesOfItem(atPath: storeFolder.appendingPathComponent("notebooks.json").path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try await store.delete(id: notebook.id)
            let empty = try await store.read(); XCTAssertTrue(empty.isEmpty)
        }
    }
    func testMalformedNotebookIsPreservedAndBlocksNewWrite() async throws {
        try await withDirectory { root in
            let store = try ResearchNotebookStore(directory: root, webReader: web())
            let file = root.appendingPathComponent("notebooks.json"), corrupt = Data("broken".utf8)
            try corrupt.write(to: file)
            do { _ = try await store.createBrief(title: "Project", urls: [URL(string: "https://example.org/article")!]); XCTFail("Expected preserved corruption") }
            catch { XCTAssertEqual(error as? ResearchNotebookError, .corruptNotebook) }
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
        }
    }
}
