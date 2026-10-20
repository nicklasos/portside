import XCTest
@testable import Portside

final class LogBufferTests: XCTestCase {
    func testJoinsPartialLinesAcrossChunksAndTreatsCRLFAsOneNewline() {
        let buffer = LogBuffer()
        buffer.append(Data("hel".utf8))
        buffer.append(Data("lo\r\nwor".utf8))
        XCTAssertEqual(buffer.snapshot().lines, ["hello"])
        buffer.append(Data("ld\n\n".utf8))
        XCTAssertEqual(buffer.snapshot().lines, ["hello", "world", ""])
    }

    func testFlushEmitsUnterminatedTail() {
        let buffer = LogBuffer()
        buffer.append(Data("no newline".utf8))
        XCTAssertEqual(buffer.snapshot().lines, [])
        buffer.flush()
        XCTAssertEqual(buffer.snapshot().lines, ["no newline"])
    }

    func testKeepsAnsiEscapesAndLoneCarriageReturns() {
        let buffer = LogBuffer()
        buffer.append(Data("\u{1B}[31mred\u{1B}[0m\nprogress 1\rprogress 2\n".utf8))
        XCTAssertEqual(buffer.snapshot().lines, ["\u{1B}[31mred\u{1B}[0m", "progress 1\rprogress 2"])
    }

    func testTrimsToCapacityAndCountsDropped() {
        let buffer = LogBuffer(capacity: 3)
        buffer.append(Data("1\n2\n3\n4\n".utf8))
        buffer.appendSystem("■ exited with code 1")
        let snap = buffer.snapshot()
        XCTAssertEqual(snap.lines, ["3", "4", "■ exited with code 1"])
        XCTAssertEqual(snap.totalAppended, 5)
        XCTAssertEqual(snap.dropped, 2)
    }

    func testClearEmptiesLinesButKeepsTotal() {
        let buffer = LogBuffer(capacity: 1)
        buffer.append(Data("a\nb\n".utf8))
        buffer.clear()
        XCTAssertEqual(buffer.snapshot(), .init(lines: [], totalAppended: 2, dropped: 0))
    }

    @MainActor
    func testRevisionBumpsOnMainAfterAppendsAndCoalesces() async throws {
        let buffer = LogBuffer()
        let before = buffer.revision
        for i in 0..<500 { buffer.append(Data("line \(i)\n".utf8)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(buffer.revision, before + 1)
    }

    func testMirrorsLinesToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("api.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let buffer = LogBuffer()
        buffer.mirror(to: url)
        buffer.append(Data("one\ntw".utf8))
        buffer.append(Data("o\n".utf8))
        buffer.mirror(to: nil)
        buffer.append(Data("three\n".utf8))
        XCTAssertEqual(try String(contentsOf: url), "one\ntwo\n")
    }
}
