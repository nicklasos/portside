import Foundation

enum ProcessState: Equatable {
    case stopped
    case starting
    case running
    case exited(code: Int32)
    case failed(String)

    var isAlive: Bool {
        switch self {
        case .starting, .running: true
        case .stopped, .exited, .failed: false
        }
    }

    var isCrashed: Bool {
        switch self {
        case .exited(let code): code != 0
        case .failed: true
        case .stopped, .starting, .running: false
        }
    }

    var summary: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .exited(let code): "Exited (\(code))"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

enum SiteStatus: Equatable {
    case stopped, starting, running, partial

    /// `partial` means at least one process crashed, whether or not others still run.
    init(states: [ProcessState]) {
        let alive = states.filter(\.isAlive)
        if states.contains(where: \.isCrashed) {
            self = .partial
        } else if alive.isEmpty {
            self = .stopped
        } else if alive.contains(.starting) {
            self = .starting
        } else {
            self = .running
        }
    }
}
