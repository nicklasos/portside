import Darwin
import Foundation

struct SpawnError: Error, CustomStringConvertible {
    var call: String
    var code: Int32

    var description: String { "\(call): \(String(cString: strerror(code)))" }
}

/// `posix_spawn` with the child as a new session and process-group leader, so the whole
/// tree a dev command forks (`make` → `node` → esbuild …) can be signalled as one group.
enum Spawn {
    struct Child {
        var pid: pid_t
        var stdout: Int32
        var stderr: Int32
    }

    static func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) throws -> Child {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw SpawnError(call: "pipe", code: errno) }
        guard pipe(&err) == 0 else {
            let code = errno
            out.forEach { close($0) }
            throw SpawnError(call: "pipe", code: code)
        }
        for fd in [out[0], err[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        for fd in out + err where fd > 2 { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // CLOEXEC_DEFAULT keeps other children's pipe ends out of this child, or their EOF would never arrive.
        // SETSIGDEF/SETSIGMASK undo dispositions the app inherited (e.g. ignored SIGPIPE), which exec would otherwise keep.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(out[1])
        close(err[1])
        guard rc == 0 else {
            close(out[0])
            close(err[0])
            throw SpawnError(call: "posix_spawn", code: rc)
        }
        return Child(pid: pid, stdout: out[0], stderr: err[0])
    }

    static func groupExists(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    /// Blocking: SIGTERM the group, wait up to `grace`, then SIGKILL. Call off the main thread.
    static func terminateGroup(_ pgid: pid_t, grace: TimeInterval = 5) {
        guard kill(-pgid, SIGTERM) == 0 || errno != ESRCH else { return }
        if waitForGroupExit(pgid, timeout: grace) { return }
        kill(-pgid, SIGKILL)
        _ = waitForGroupExit(pgid, timeout: 1)
    }

    private static func waitForGroupExit(_ pgid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while groupExists(pgid) {
            if Date() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }

    /// Start time in microseconds since the epoch. Together with the pid it identifies a process across pid reuse.
    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
