#if !SWIFT_PACKAGE
import XCTest
import Foundation

final class VoicePipeWriterTests: XCTestCase {
    func testFullPipeDoesNotBlockClose() throws {
        let pipe = Pipe()
        let closed = expectation(description: "close does not wait for child reads")
        let writer = try VoicePipeWriter(handle: pipe.fileHandleForWriting) {}
        for _ in 0..<24 { writer.append(Data(repeating: 42, count: 8192)) }
        writer.close { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        try pipe.fileHandleForReading.close()
    }
    func testBrokenPipeReportsFailureWithoutSIGPIPE() throws {
        let pipe = Pipe()
        let failed = expectation(description: "broken pipe error")
        let writer = try VoicePipeWriter(handle: pipe.fileHandleForWriting) { failed.fulfill() }
        try pipe.fileHandleForReading.close()
        writer.append(Data("hello\n".utf8))
        wait(for: [failed], timeout: 2)
        writer.close()
    }
    func testWriterDeliversBytesInOrder() throws {
        let pipe = Pipe()
        let writer = try VoicePipeWriter(handle: pipe.fileHandleForWriting) {}
        writer.append(Data("one\n".utf8)); writer.append(Data("two\n".utf8))
        let closed = expectation(description: "close")
        writer.close { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "one\ntwo\n")
        try pipe.fileHandleForReading.close()
    }
}
#endif
