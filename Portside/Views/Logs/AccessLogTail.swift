import Foundation

/// Follows a static site's Caddy access log and feeds one readable line per request into a `LogBuffer`.
@MainActor
final class AccessLogTail {
    let buffer = LogBuffer()
    private let file: URL
    private var offset: UInt64?
    private var partial = Data()
    private var timer: Timer?

    private static let initialTail: UInt64 = 64 * 1024

    init(file: URL) {
        self.file = file
    }

    func start() {
        guard timer == nil else { return }
        buffer.appendSystem("▶ access log \((file.path as NSString).abbreviatingWithTildeInPath)")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        let isFirstRead = offset == nil
        var start = offset ?? (size > Self.initialTail ? size - Self.initialTail : 0)
        if size < start { start = 0; partial = Data() }
        guard size > start else { offset = size; return }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return }
        offset = start + UInt64(data.count)
        var chunk = partial + data
        // Starting mid-file lands inside a line; skip to the first whole one.
        if isFirstRead, start > 0 {
            chunk = Data(chunk.drop { $0 != 0x0A }.dropFirst())
        }
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else { partial = chunk; return }
        partial = Data(chunk[chunk.index(after: lastNewline)...])
        for line in chunk[..<lastNewline].split(separator: 0x0A) {
            buffer.appendSystem(Self.format(Data(line)))
        }
    }

    static func format(_ line: Data) -> String {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let request = entry["request"] as? [String: Any] else {
            return String(decoding: line, as: UTF8.self)
        }
        let method = request["method"] as? String ?? "?"
        let uri = request["uri"] as? String ?? "?"
        let status = entry["status"] as? Int ?? 0
        let duration = (entry["duration"] as? Double).map { String(format: "%.1f ms", $0 * 1000) } ?? ""
        let size = entry["size"] as? Int ?? 0
        let time = (entry["ts"] as? Double).map { timeFormatter.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
        let color = switch status {
        case 200..<300: "32"
        case 300..<400: "36"
        case 400..<500: "33"
        default: "31"
        }
        return "\u{1B}[90m\(time)\u{1B}[0m  \(method) \(uri)  \u{1B}[\(color)m\(status)\u{1B}[0m  \(duration)  \(size) B"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
