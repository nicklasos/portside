import XCTest
@testable import Portside

final class LogWindowTests: XCTestCase {
    private func buffer(lines: Range<Int>, capacity: Int = 10_000) -> LogBuffer {
        let buffer = LogBuffer(capacity: capacity)
        append(lines, to: buffer)
        return buffer
    }

    private func append(_ lines: Range<Int>, to buffer: LogBuffer) {
        buffer.append(Data(lines.map { "\($0)\n" }.joined().utf8))
    }

    /// Plays `edit` on the lines a view holds, the way the text view does.
    private func apply(_ edit: LogWindow.Edit, to shown: [String], from snapshot: LogBuffer.Snapshot) -> [String] {
        Array(snapshot.lines(edit.prepend)) + shown.dropFirst(edit.removeFromTop) + snapshot.lines(edit.append)
    }

    func testShowsTheNewestChunkAndCountsTheRest() {
        let snapshot = buffer(lines: 0..<2500).snapshot()
        let window = LogWindow(snapshot: snapshot, limit: LogWindow.chunk)
        XCTAssertEqual(Array(snapshot.lines(window.lines)), (1500..<2500).map(String.init))
        XCTAssertEqual(window.hidden, 1500)
        XCTAssertEqual(window.dropped, 0)
    }

    func testShowsEverythingWhenTheBufferIsSmallerThanTheWindow() {
        let snapshot = buffer(lines: 0..<40).snapshot()
        let window = LogWindow(snapshot: snapshot, limit: LogWindow.chunk)
        XCTAssertEqual(Array(snapshot.lines(window.lines)), (0..<40).map(String.init))
        XCTAssertEqual(window.hidden, 0)
    }

    func testShowEarlierLoadsOneChunkAtATimeUpToTheWholeBuffer() {
        let snapshot = buffer(lines: 0..<2500).snapshot()
        var state = LogViewState()
        var window = LogWindow(snapshot: snapshot, limit: state.shownLimit)
        XCTAssertEqual(window.nextChunk, 1000)

        state.showEarlier(than: window)
        window = LogWindow(snapshot: snapshot, limit: state.shownLimit)
        XCTAssertEqual(window.lines.count, 2000)
        XCTAssertEqual(window.nextChunk, 500)

        state.showEarlier(than: window)
        window = LogWindow(snapshot: snapshot, limit: state.shownLimit)
        XCTAssertEqual(Array(snapshot.lines(window.lines)), (0..<2500).map(String.init))
        XCTAssertEqual(window.hidden, 0)
    }

    func testShowEarlierOnlyPrependsTheOlderLines() {
        let snapshot = buffer(lines: 0..<2500).snapshot()
        let first = LogWindow(snapshot: snapshot, limit: 1000)
        let shown = Array(snapshot.lines(first.lines))
        let more = LogWindow(snapshot: snapshot, limit: 2000)
        let edit = more.edit(from: first.lines)
        XCTAssertEqual(edit.removeFromTop, 0)
        XCTAssertEqual(edit.append.count, 0)
        XCTAssertEqual(edit.prepend.count, 1000)
        XCTAssertEqual(apply(edit, to: shown, from: snapshot), (500..<2500).map(String.init))
    }

    func testNewOutputAppendsAndTrimsTheTopWithoutReRendering() {
        let buffer = buffer(lines: 0..<1500)
        let before = buffer.snapshot()
        let first = LogWindow(snapshot: before, limit: 1000)
        let shown = Array(before.lines(first.lines))

        append(1500..<1503, to: buffer)
        let after = buffer.snapshot()
        let window = LogWindow(snapshot: after, limit: 1000)
        let edit = window.edit(from: first.lines)
        XCTAssertEqual(edit, .init(removeFromTop: 3, prepend: window.lines.lowerBound..<window.lines.lowerBound, append: window.lines.upperBound - 3..<window.lines.upperBound))
        XCTAssertEqual(apply(edit, to: shown, from: after), (503..<1503).map(String.init))
    }

    func testLinesTheBufferDroppedAreReportedApartFromHiddenOnes() {
        let buffer = buffer(lines: 0..<8, capacity: 5)
        let window = LogWindow(snapshot: buffer.snapshot(), limit: 2)
        XCTAssertEqual(Array(buffer.snapshot().lines(window.lines)), ["6", "7"])
        XCTAssertEqual(window.hidden, 3)
        XCTAssertEqual(window.dropped, 3)
    }

    func testWindowAtTheBufferCapacityKeepsFollowingWhatTheBufferKeeps() {
        let buffer = buffer(lines: 0..<5, capacity: 5)
        let before = buffer.snapshot()
        let first = LogWindow(snapshot: before, limit: 1000)
        append(5..<7, to: buffer)
        let after = buffer.snapshot()
        let window = LogWindow(snapshot: after, limit: 1000)
        let edit = window.edit(from: first.lines)
        XCTAssertEqual(apply(edit, to: Array(before.lines(first.lines)), from: after), ["2", "3", "4", "5", "6"])
        XCTAssertEqual(window.dropped, 2)
    }

    func testClearEmptiesTheViewAndNewLinesStartFresh() {
        let buffer = buffer(lines: 0..<1500)
        let before = buffer.snapshot()
        let first = LogWindow(snapshot: before, limit: 1000)
        buffer.clear()
        let cleared = LogWindow(snapshot: buffer.snapshot(), limit: 1000)
        XCTAssertEqual(apply(cleared.edit(from: first.lines), to: Array(before.lines(first.lines)), from: buffer.snapshot()), [])
        XCTAssertEqual(cleared.hidden, 0)

        append(0..<2, to: buffer)
        let after = buffer.snapshot()
        let window = LogWindow(snapshot: after, limit: 1000)
        XCTAssertEqual(apply(window.edit(from: cleared.lines), to: [], from: after), ["0", "1"])
    }

    func testViewOpensAtTheNewestLineWithFollowOff() {
        let state = LogViewState()
        XCTAssertFalse(state.follow)
        XCTAssertTrue(state.pinnedToBottom)
    }

    func testLeavingTheBottomTurnsFollowOff() {
        var state = LogViewState()
        state.follow = true
        state.leaveBottom()
        XCTAssertFalse(state.follow)
        XCTAssertFalse(state.pinnedToBottom)
    }

    func testClearKeepsFollowAndDropsLoadedChunks() {
        let snapshot = buffer(lines: 0..<2500).snapshot()
        var state = LogViewState()
        state.follow = true
        state.showEarlier(than: LogWindow(snapshot: snapshot, limit: state.shownLimit))
        state.clear()
        XCTAssertTrue(state.follow)
        XCTAssertEqual(state.shownLimit, LogWindow.chunk)
    }
}
