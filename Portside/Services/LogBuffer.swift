import Foundation
import Observation
import os

/// Line-oriented ring buffer for one process's output. Appends come from any thread.
@Observable
final class LogBuffer: @unchecked Sendable {
    struct Snapshot: Equatable {
        var lines: [String]
        /// Lines ever appended; unaffected by `clear()`, so a reader can diff against what it last saw.
        var totalAppended: Int
        /// Lines trimmed by capacity since the last `clear()`.
        var dropped: Int
    }

    /// Bumped on the main thread, at most ~30 times a second, after new lines arrive.
    private(set) var revision = 0

    @ObservationIgnored let capacity: Int
    @ObservationIgnored private let storage: OSAllocatedUnfairLock<Storage>

    private struct Storage {
        var lines: [String] = []
        var tail = Data()
        var total = 0
        var dropped = 0
        var publishPending = false
        var mirror: FileHandle?
    }

    private static let maxTail = 64 * 1024

    init(capacity: Int = 10_000) {
        self.capacity = capacity
        storage = OSAllocatedUnfairLock(uncheckedState: Storage())
    }

    func append(_ data: Data) {
        commit { s in
            var chunk = s.tail
            chunk.append(data)
            var lines: [String] = []
            var start = chunk.startIndex
            while let nl = chunk[start...].firstIndex(of: 0x0A) {
                var end = nl
                if end > start, chunk[chunk.index(before: end)] == 0x0D { end = chunk.index(before: end) }
                lines.append(String(decoding: chunk[start..<end], as: UTF8.self))
                start = chunk.index(after: nl)
            }
            s.tail = Data(chunk[start...])
            if s.tail.count > Self.maxTail {
                lines.append(String(decoding: s.tail, as: UTF8.self))
                s.tail = Data()
            }
            return lines
        }
    }

    func appendSystem(_ line: String) {
        commit { _ in [line] }
    }

    /// Emits a trailing line that never got its newline, e.g. when the process exits.
    func flush() {
        commit { s in
            guard !s.tail.isEmpty else { return [] }
            defer { s.tail = Data() }
            return [String(decoding: s.tail, as: UTF8.self)]
        }
    }

    func snapshot() -> Snapshot {
        storage.withLockUnchecked { Snapshot(lines: $0.lines, totalAppended: $0.total, dropped: $0.dropped) }
    }

    func clear() {
        let publish = storage.withLockUnchecked { s in
            s.lines = []
            s.dropped = 0
            return Self.claimPublish(&s)
        }
        if publish { schedulePublish() }
    }

    /// Mirrors every future line to `url` (appending), or stops mirroring when nil.
    func mirror(to url: URL?) {
        var handle: FileHandle?
        if let url {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        let old = storage.withLockUnchecked { s in
            defer { s.mirror = handle }
            return s.mirror
        }
        try? old?.close()
    }

    private func commit(_ produce: (inout Storage) -> [String]) {
        let publish = storage.withLockUnchecked { s -> Bool in
            let lines = produce(&s)
            guard !lines.isEmpty else { return false }
            s.lines.append(contentsOf: lines)
            s.total += lines.count
            if s.lines.count > capacity {
                let over = s.lines.count - capacity
                s.lines.removeFirst(over)
                s.dropped += over
            }
            if let mirror = s.mirror {
                try? mirror.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            }
            return Self.claimPublish(&s)
        }
        if publish { schedulePublish() }
    }

    private static func claimPublish(_ s: inout Storage) -> Bool {
        guard !s.publishPending else { return false }
        s.publishPending = true
        return true
    }

    private func schedulePublish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
            guard let self else { return }
            storage.withLockUnchecked { $0.publishPending = false }
            revision &+= 1
        }
    }
}
