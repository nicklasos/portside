import Darwin
import Foundation

/// What a process is launched with. Two equal specs launch the same thing, so an edit
/// that leaves the spec unchanged needs no restart.
struct LaunchSpec: Equatable {
    var command: String
    var workingDirectory: String
    /// Applied on top of Portside's own environment.
    var environment: [String: String]
}

/// One spawned `/bin/zsh -ilc <command>` and its process group, from spawn until the
/// leader is reaped and its output drained.
final class ManagedProcess: @unchecked Sendable {
    let pid: pid_t
    let startTime: UInt64?

    private let buffer: LogBuffer
    private let onExit: @Sendable (ManagedProcess, Int32) -> Void
    // Everything below is confined to `queue`.
    private let queue: DispatchQueue
    private var readers: [DispatchSourceRead] = []
    private var exitSource: DispatchSourceProcess?
    private var openStreams = 2
    private var exitCode: Int32?
    private var result: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var groupTermination: Task<Void, Never>?

    /// Leftovers in the group get this long to write their last output after the leader exits.
    private static let drainWindow: DispatchTimeInterval = .milliseconds(500)

    /// `onExit` runs on a background queue once the leader is reaped and output is drained.
    init(spec: LaunchSpec, buffer: LogBuffer, onExit: @escaping @Sendable (ManagedProcess, Int32) -> Void) throws {
        let env = ProcessInfo.processInfo.environment.merging(spec.environment) { $1 }
        // Interactive so ~/.zshrc runs: that is where nvm, fnm and most version managers put PATH.
        let child = try Spawn.run(executable: "/bin/zsh", arguments: ["-ilc", spec.command], environment: env, workingDirectory: spec.workingDirectory)
        pid = child.pid
        startTime = Spawn.startTime(of: child.pid)
        self.buffer = buffer
        self.onExit = onExit
        queue = DispatchQueue(label: "portside.process.\(child.pid)")

        buffer.appendSystem("▶ \(spec.command) (pid \(child.pid))")

        queue.sync {
            for fd in [child.stdout, child.stderr] {
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [self] in read(fd, source) }
                source.setCancelHandler { [self] in
                    close(fd)
                    openStreams -= 1
                    concludeIfDone()
                }
                readers.append(source)
                source.resume()
            }
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [self] in reap(blocking: true) }
            exitSource = exit
            exit.resume()
        }
        // The child may have exited before the exit source was armed.
        queue.async { [self] in reap(blocking: false) }
    }

    /// SIGTERM the group, SIGKILL after 5 s, and return once the group is gone and the
    /// leader's exit has been processed. Safe to call repeatedly or after the process died.
    @discardableResult
    func terminate() async -> Int32 {
        await queue.sync(execute: groupTerminationTask).value
        return await withCheckedContinuation { c in
            queue.async { [self] in
                if let result { c.resume(returning: result) } else { waiters.append(c) }
            }
        }
    }

    private func groupTerminationTask() -> Task<Void, Never> {
        if let groupTermination { return groupTermination }
        let pgid = pid
        let task = Task {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    Spawn.terminateGroup(pgid)
                    c.resume()
                }
            }
        }
        groupTermination = task
        return task
    }

    private func read(_ fd: Int32, _ source: DispatchSourceRead) {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n > 0 {
            buffer.append(Data(bytes[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            source.cancel()
        }
    }

    private func reap(blocking: Bool) {
        guard exitCode == nil else { return }
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, blocking ? 0 : WNOHANG) } while r == -1 && errno == EINTR
        guard r == pid else { return }

        let signal = status & 0x7f
        exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        exitSource?.cancel()
        // A leader that dies on its own must not leave its children holding ports.
        _ = groupTerminationTask()
        queue.asyncAfter(deadline: .now() + Self.drainWindow) { [self] in readers.forEach { $0.cancel() } }
        concludeIfDone()
    }

    private func concludeIfDone() {
        guard result == nil, let exitCode, openStreams == 0 else { return }
        buffer.flush()
        result = exitCode
        waiters.forEach { $0.resume(returning: exitCode) }
        waiters = []
        onExit(self, exitCode)
    }
}
