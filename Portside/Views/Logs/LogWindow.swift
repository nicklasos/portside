import Foundation

/// The lines of a `LogBuffer` the logs view renders: the newest `limit` of them.
/// Lines are numbered absolutely, counting every line the buffer ever received, so a range
/// stays meaningful while the buffer drops old lines and appends new ones.
struct LogWindow: Equatable {
    static let chunk = 1_000

    /// Absolute numbers of the rendered lines.
    let lines: Range<Int>
    /// Lines still in the buffer, older than `lines`.
    let hidden: Int
    /// Lines the buffer itself discarded.
    let dropped: Int

    init(snapshot: LogBuffer.Snapshot, limit: Int) {
        let shown = min(max(limit, 0), snapshot.lines.count)
        lines = (snapshot.totalAppended - shown)..<snapshot.totalAppended
        hidden = snapshot.lines.count - shown
        dropped = snapshot.dropped
    }

    /// How many more lines one "Show earlier" press would render.
    var nextChunk: Int { min(Self.chunk, hidden) }

    /// What a view holding `rendered` must change to hold `lines` instead. Every change happens at
    /// the top or the bottom, so the view never re-renders the lines it keeps.
    func edit(from rendered: Range<Int>) -> Edit {
        let keep = rendered.clamped(to: lines)
        guard !keep.isEmpty, rendered.upperBound <= lines.upperBound else {
            return Edit(removeFromTop: rendered.count, prepend: lines.lowerBound..<lines.lowerBound, append: lines)
        }
        return Edit(
            removeFromTop: keep.lowerBound - rendered.lowerBound,
            prepend: lines.lowerBound..<keep.lowerBound,
            append: keep.upperBound..<lines.upperBound
        )
    }

    struct Edit: Equatable {
        var removeFromTop: Int
        /// Absolute line numbers to insert above the lines that remain.
        var prepend: Range<Int>
        var append: Range<Int>

        var isEmpty: Bool { removeFromTop == 0 && prepend.isEmpty && append.isEmpty }
    }
}

extension LogBuffer.Snapshot {
    /// Lines by absolute number; `range` must lie within what the buffer still holds.
    func lines(_ range: Range<Int>) -> ArraySlice<String> {
        let first = totalAppended - lines.count
        return lines[(range.lowerBound - first)..<(range.upperBound - first)]
    }
}

/// What one logs pane shows and where it keeps the scroll position.
struct LogViewState: Equatable {
    var shownLimit = LogWindow.chunk
    /// While on, every new line and every resize keeps the newest line in view.
    var follow = false
    /// The pane has not yet scrolled to the newest line since it appeared. It can only do that once
    /// the text view has a window and a size, which happens after the first render.
    var scrollToBottomPending = true

    var pinnedToBottom: Bool { follow || scrollToBottomPending }

    mutating func showEarlier(than window: LogWindow) {
        shownLimit = window.lines.count + LogWindow.chunk
    }

    /// The operator scrolled away from the bottom or jumped to a search match.
    mutating func leaveBottom() {
        follow = false
        scrollToBottomPending = false
    }

    mutating func clear() {
        shownLimit = LogWindow.chunk
    }
}
