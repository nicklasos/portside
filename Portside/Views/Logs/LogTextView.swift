import AppKit
import SwiftUI

/// Read-only terminal-style view of the newest lines of a `LogBuffer`. It edits its text only at
/// the top and the bottom, so new output and "Show earlier" never re-render the lines it keeps.
struct LogTextView: NSViewRepresentable {
    let buffer: LogBuffer
    @Binding var state: LogViewState
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
        textView.isAutomaticLinkDetectionEnabled = false

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        let center = NotificationCenter.default
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            center.addObserver(coordinator, selector: #selector(Coordinator.userScrolled), name: name, object: scrollView)
        }
        scrollView.contentView.postsFrameChangedNotifications = true
        center.addObserver(coordinator, selector: #selector(Coordinator.geometryChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        #if DEBUG
        center.addObserver(coordinator, selector: #selector(Coordinator.debugAction), name: DebugLaunch.logsAction, object: nil)
        #endif
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        _ = buffer.revision
        let coordinator = context.coordinator
        coordinator.parent = self
        let snapshot = buffer.snapshot()
        coordinator.render(LogWindow(snapshot: snapshot, limit: state.shownLimit), of: snapshot, from: buffer, pinned: state.pinnedToBottom)
        coordinator.highlight(query: query)
        if coordinator.findNextToken != findNextToken {
            coordinator.findNextToken = findNextToken
            coordinator.selectNextMatch(query: query)
        } else if state.pinnedToBottom {
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
        /// Absolute numbers of the lines in the text storage.
        private var rendered = 0..<0
        /// UTF-16 length of each rendered line including its newline, oldest first.
        private var lineLengths: [Int] = []
        /// Bumped on every text change, so highlights are redone even when the length stays the same.
        private var textVersion = 0
        private var highlightedQuery = ""
        private var highlightedVersion = -1

        func render(_ window: LogWindow, of snapshot: LogBuffer.Snapshot, from buffer: LogBuffer, pinned: Bool) {
            guard let storage = textView?.textStorage else { return }
            if bufferID != ObjectIdentifier(buffer) {
                bufferID = ObjectIdentifier(buffer)
                rendered = 0..<0
            }
            let edit = window.edit(from: rendered)
            guard !edit.isEmpty else { return }
            #if DEBUG
            let started = Date()
            #endif
            let keepsPosition = !pinned && edit.removeFromTop < lineLengths.count
            let removed = lineLengths.prefix(edit.removeFromTop).reduce(0, +)
            let removedHeight = keepsPosition ? heightOfTop(removed) : 0
            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: 0, length: removed))
            lineLengths.removeFirst(edit.removeFromTop)
            let (top, topLengths) = Self.attributed(snapshot.lines(edit.prepend))
            storage.insert(top, at: 0)
            lineLengths.insert(contentsOf: topLengths, at: 0)
            let (bottom, bottomLengths) = Self.attributed(snapshot.lines(edit.append))
            storage.append(bottom)
            lineLengths.append(contentsOf: bottomLengths)
            storage.endEditing()
            rendered = window.lines
            textVersion += 1
            if keepsPosition, removed > 0 || top.length > 0 {
                shiftScroll(by: heightOfTop(top.length) - removedHeight)
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "PortsideLogViewTrace") {
                let storageLines = storage.string.utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                NSLog("Portside: log view storageLines=\(storageLines) window=\(window.lines.count) hidden=\(window.hidden) dropped=\(window.dropped) ms=\(Int(Date().timeIntervalSince(started) * 1000)) scrollY=\(scrollView?.contentView.bounds.minY ?? -1)")
            }
            #endif
        }

        private static func attributed(_ lines: ArraySlice<String>) -> (NSAttributedString, [Int]) {
            let chunk = NSMutableAttributedString()
            var lengths: [Int] = []
            lengths.reserveCapacity(lines.count)
            let newline = NSAttributedString(string: "\n", attributes: [.font: LogTextView.font])
            for line in lines {
                let rendered = line.hasPrefix("▶ ") || line.hasPrefix("■ ")
                    ? NSAttributedString(string: line, attributes: [.font: LogTextView.font, .foregroundColor: NSColor(white: 0.55, alpha: 1)])
                    : ANSIParser.attributedString(line, font: LogTextView.font, boldFont: LogTextView.boldFont)
                chunk.append(rendered)
                chunk.append(newline)
                lengths.append(rendered.length + 1)
            }
            return (chunk, lengths)
        }

        /// Height of the first `characters` characters.
        private func heightOfTop(_ characters: Int) -> CGFloat {
            guard characters > 0, let layout = textView?.layoutManager, let container = textView?.textContainer,
                  let length = textView?.textStorage?.length else { return 0 }
            guard characters < length else {
                layout.ensureLayout(for: container)
                return layout.usedRect(for: container).height
            }
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: characters + 1))
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: characters), effectiveRange: nil).minY
        }

        /// Keeps the lines on screen in place after lines were added or removed above them.
        private func shiftScroll(by delta: CGFloat) {
            guard delta != 0, let scrollView, let textView, let container = textView.textContainer else { return }
            if delta > 0 {
                // The text view grows to fit new text only on its next layout pass; scrolling down
                // before that would be clamped to the old height.
                textView.layoutManager?.ensureLayout(for: container)
                textView.sizeToFit()
            }
            let y = max(scrollView.contentView.bounds.minY + delta, 0)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func highlight(query: String) {
            guard let textView, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            guard query != highlightedQuery || textVersion != highlightedVersion else { return }
            highlightedQuery = query
            highlightedVersion = textVersion
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
            updateState { $0.leaveBottom() }
        }

        /// Scrolls to the newest line once the view has a window and a size. Before that,
        /// scrolling has no effect, and the view would open at the top.
        func scrollToBottom() {
            guard let textView, let scrollView, scrollView.window != nil, scrollView.contentView.bounds.height > 0 else { return }
            textView.scrollRangeToVisible(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
            if parent?.state.scrollToBottomPending == true {
                updateState { $0.scrollToBottomPending = false }
            }
        }

        @objc func geometryChanged(_ note: Notification) {
            guard parent?.state.pinnedToBottom == true else { return }
            DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
        }

        @objc func userScrolled(_ note: Notification) {
            guard let scrollView, let document = scrollView.documentView, parent?.state.pinnedToBottom == true else { return }
            let atBottom = scrollView.contentView.bounds.maxY >= document.frame.height - 24
            if !atBottom { updateState { $0.leaveBottom() } }
        }

        private func updateState(_ change: @escaping (inout LogViewState) -> Void) {
            guard let parent else { return }
            DispatchQueue.main.async { change(&parent.state) }
        }

        #if DEBUG
        @objc func debugAction(_ note: Notification) {
            guard note.object as? String == "scrollup", let scrollView,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)) else { return }
            scrollView.scrollWheel(with: event)
        }
        #endif

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
