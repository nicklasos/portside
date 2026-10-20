import AppKit
import SwiftUI

/// Read-only terminal-style view of a `LogBuffer`. Appends only what is new since the last update
/// and trims from the top as the ring buffer drops lines, so it stays cheap at 10 000 lines.
struct LogTextView: NSViewRepresentable {
    let buffer: LogBuffer
    @Binding var follow: Bool
    var query: String
    /// Bumping this jumps to the next match after the current selection.
    var findNextToken: Int
    var onMatchCount: (Int) -> Void

    static let background = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1)
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.background
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Self.background
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = Self.font
        textView.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.26, green: 0.36, blue: 0.55, alpha: 1)]
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isAutomaticLinkDetectionEnabled = false

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.userScrolled), name: name, object: scrollView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        _ = buffer.revision
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.sync(with: buffer)
        coordinator.highlight(query: query)
        if coordinator.findNextToken != findNextToken {
            coordinator.findNextToken = findNextToken
            coordinator.selectNextMatch(query: query)
        } else if follow {
            coordinator.scrollToBottom()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: LogTextView?
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var findNextToken = 0
        private var bufferID: ObjectIdentifier?
        private var shownTotal = 0
        /// UTF-16 length of each shown line including its newline, oldest first.
        private var lineLengths: [Int] = []
        private var highlightedQuery = ""
        private var highlightedLength = -1

        func sync(with buffer: LogBuffer) {
            guard let storage = textView?.textStorage else { return }
            let snapshot = buffer.snapshot()
            let id = ObjectIdentifier(buffer)
            let delta = snapshot.totalAppended - shownTotal
            storage.beginEditing()
            defer { storage.endEditing() }
            if bufferID != id || delta < 0 || delta > snapshot.lines.count {
                bufferID = id
                storage.setAttributedString(NSAttributedString())
                lineLengths = []
                append(snapshot.lines[...], to: storage)
            } else if delta > 0 {
                append(snapshot.lines.suffix(delta), to: storage)
            }
            shownTotal = snapshot.totalAppended
            let excess = lineLengths.count - snapshot.lines.count
            if excess > 0 {
                let length = lineLengths.prefix(excess).reduce(0, +)
                storage.deleteCharacters(in: NSRange(location: 0, length: length))
                lineLengths.removeFirst(excess)
            }
        }

        private func append(_ lines: ArraySlice<String>, to storage: NSTextStorage) {
            guard !lines.isEmpty else { return }
            let chunk = NSMutableAttributedString()
            let newline = NSAttributedString(string: "\n", attributes: [.font: LogTextView.font])
            for line in lines {
                let rendered = line.hasPrefix("▶ ") || line.hasPrefix("■ ")
                    ? NSAttributedString(string: line, attributes: [.font: LogTextView.font, .foregroundColor: NSColor(white: 0.55, alpha: 1)])
                    : ANSIParser.attributedString(line, font: LogTextView.font, boldFont: LogTextView.boldFont)
                chunk.append(rendered)
                chunk.append(newline)
                lineLengths.append(rendered.length + 1)
            }
            storage.append(chunk)
        }

        func highlight(query: String) {
            guard let textView, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            guard query != highlightedQuery || storage.length != highlightedLength else { return }
            highlightedQuery = query
            highlightedLength = storage.length
            let full = NSRange(location: 0, length: storage.length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            let ranges = matches(of: query)
            for range in ranges {
                layout.addTemporaryAttributes([.backgroundColor: NSColor.systemYellow, .foregroundColor: NSColor.black], forCharacterRange: range)
            }
            let count = ranges.count
            DispatchQueue.main.async { [weak self] in self?.parent?.onMatchCount(count) }
        }

        func selectNextMatch(query: String) {
            guard let textView else { return }
            let ranges = matches(of: query)
            guard !ranges.isEmpty else { return }
            let after = textView.selectedRange().upperBound
            let next = ranges.first { $0.location >= after } ?? ranges[0]
            textView.setSelectedRange(next)
            textView.scrollRangeToVisible(next)
            setFollow(false)
        }

        func scrollToBottom() {
            guard let textView else { return }
            textView.scrollRangeToVisible(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
        }

        @objc func userScrolled(_ note: Notification) {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.bounds
            let atBottom = visible.maxY >= document.frame.height - 24
            setFollow(atBottom)
        }

        private func setFollow(_ value: Bool) {
            guard let parent, parent.follow != value else { return }
            DispatchQueue.main.async { parent.follow = value }
        }

        private func matches(of query: String) -> [NSRange] {
            guard !query.isEmpty, let text = textView?.textStorage?.string as NSString? else { return [] }
            var ranges: [NSRange] = []
            var search = NSRange(location: 0, length: text.length)
            while ranges.count < 5000 {
                let found = text.range(of: query, options: .caseInsensitive, range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = found.upperBound
                search = NSRange(location: next, length: text.length - next)
            }
            return ranges
        }
    }
}
