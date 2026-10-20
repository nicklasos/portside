import Darwin
import Foundation
import Observation

enum ProxyState: Equatable {
    case stopped
    case starting
    case running
    case portConflict(PortOwner?)
    case failed(String)
}

/// Runs the bundled Caddy as a child process and keeps its config in sync with the sites.
@MainActor
@Observable
final class ProxyManager {
    private(set) var state: ProxyState = .stopped
    /// Caddy's stdout and stderr, newest last, capped at `logLimit` lines.
    private(set) var caddyLog: [String] = []
    /// Set when the last live reconfiguration was rejected; cleared by the next success.
    private(set) var lastApplyError: String?

    static let logLimit = 500
    static let applyDebounce: Duration = .milliseconds(200)

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let caddyBinary: URL
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let logsDirectory: URL?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// Ports of the running instance. Changing them in settings takes effect on the next start.
    @ObservationIgnored private var ports: (proxy: Int, admin: Int)?
    @ObservationIgnored private var desiredConfig: Data?
    @ObservationIgnored private var loadedConfig: Data?

    var configFile: URL { supportDirectory.appendingPathComponent("caddy.json") }
    var pidFile: URL { caddyHome.appendingPathComponent("caddy.pid") }
    private var caddyHome: URL { supportDirectory.appendingPathComponent("caddy", isDirectory: true) }

    init(
        settings: AppSettings,
        caddyBinary: URL = AppPaths.caddyBinary,
        supportDirectory: URL = AppPaths.supportDirectory,
        logsDirectory: URL? = AppPaths.logsDirectory
    ) {
        self.settings = settings
        self.caddyBinary = caddyBinary
        self.supportDirectory = supportDirectory
        self.logsDirectory = logsDirectory
    }

    /// Idempotent: a running proxy just takes the new sites.
    func start(sites: [Site], enabledStaticSites: Set<Site.ID>) async {
        switch state {
        case .starting, .running:
            apply(sites: sites, enabledStaticSites: enabledStaticSites)
            return
        case .stopped, .portConflict, .failed:
            break
        }
        state = .starting
        caddyLog.removeAll()
        lastApplyError = nil
        await terminateStaleCaddy()
        guard state == .starting else { return }

        let proxyPort = settings.proxyPort
        let adminPort = settings.caddyAdminPort
        guard PortChecker.isTCPPortFree(proxyPort) else {
            state = .portConflict(PortChecker.owner(ofTCPPort: proxyPort))
            return
        }
        guard PortChecker.isTCPPortFree(adminPort) else {
            let owner = PortChecker.owner(ofTCPPort: adminPort).map { " by \($0.command) (pid \($0.pid))" } ?? ""
            state = .failed("Caddy admin port \(adminPort) is in use\(owner)")
            return
        }

        ports = (proxyPort, adminPort)
        let config = buildConfig(sites: sites, enabledStaticSites: enabledStaticSites)
        desiredConfig = config
        do {
            try writeConfig(config)
            try launch()
        } catch {
            ports = nil
            state = .failed(error.localizedDescription)
            return
        }
        loadedConfig = config

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            guard state == .starting else { return }
            if await adminResponds(adminPort) {
                state = .running
                if let desiredConfig, desiredConfig != loadedConfig { await load(desiredConfig) }
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard state == .starting else { return }
        await stop()
        state = .failed(Self.lastError(in: caddyLog) ?? "Caddy did not answer on 127.0.0.1:\(adminPort)")
    }

    /// Debounced. Rebuilds the config and pushes it to Caddy's admin API when running.
    func apply(sites: [Site], enabledStaticSites: Set<Site.ID>) {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.applyDebounce)
            guard !Task.isCancelled, let self, self.ports != nil else { return }
            let config = self.buildConfig(sites: sites, enabledStaticSites: enabledStaticSites)
            self.desiredConfig = config
            try? self.writeConfig(config)
            if self.state == .running { await self.load(config) }
        }
    }

    func stop() async {
        applyTask?.cancel()
        applyTask = nil
        ports = nil
        if let process {
            self.process = nil
            await Self.terminate(pid: process.processIdentifier) { process.isRunning }
            forgetPid(process.processIdentifier)
        }
        state = .stopped
    }

    // MARK: - Launch

    private func buildConfig(sites: [Site], enabledStaticSites: Set<Site.ID>) -> Data {
        CaddyConfigBuilder.build(
            sites: sites, enabledStaticSites: enabledStaticSites,
            proxyPort: ports?.proxy ?? settings.proxyPort, adminPort: ports?.admin ?? settings.caddyAdminPort,
            logsDirectory: logsDirectory
        )
    }

    private func writeConfig(_ config: Data) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try config.write(to: configFile, options: .atomic)
    }

    private func launch() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: caddyBinary.path) else {
            throw ProxyError("Caddy binary not found at \(caddyBinary.path)")
        }
        let configHome = caddyHome.appendingPathComponent("config", isDirectory: true)
        let dataHome = caddyHome.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: configHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataHome, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = caddyBinary
        process.arguments = ["run", "--config", configFile.path]
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = configHome.path
        env["XDG_DATA_HOME"] = dataHome.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        self.process = process
        try? "\(process.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        monitor(process, output: pipe.fileHandleForReading)
    }

    /// Reads output until EOF, then reports the exit, so the failure message sees the final line.
    private func monitor(_ process: Process, output: FileHandle) {
        Task.detached { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    await self?.appendLog(line)
                }
            } catch {}
            process.waitUntilExit()
            await self?.processExited(process)
        }
    }

    private func appendLog(_ line: String) {
        caddyLog.append(line)
        if caddyLog.count > Self.logLimit { caddyLog.removeFirst(caddyLog.count - Self.logLimit) }
    }

    private func processExited(_ exited: Process) {
        guard exited === process else { return }
        process = nil
        ports = nil
        forgetPid(exited.processIdentifier)
        let exit = exited.terminationReason == .uncaughtSignal
            ? "Caddy was killed by signal \(exited.terminationStatus)"
            : "Caddy exited with status \(exited.terminationStatus)"
        state = .failed(Self.lastError(in: caddyLog) ?? exit)
    }

    /// The newest error Caddy logged. Caddy writes JSON log lines, plus plain text for some fatal
    /// startup errors; info lines (such as "shutdown complete") are not a failure reason.
    static func lastError(in log: [String]) -> String? {
        for line in log.reversed() {
            guard line.hasPrefix("{") else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let level = object["level"] as? String, ["error", "fatal", "panic"].contains(level),
                  let message = object["msg"] as? String else { continue }
            return (object["error"] as? String).map { "\(message): \($0)" } ?? message
        }
        return nil
    }

    // MARK: - Admin API

    /// Bypasses any system HTTP proxy and cache, which must never sit between us and 127.0.0.1.
    private static let adminSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private func adminResponds(_ adminPort: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(adminPort)/config/")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await Self.adminSession.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func load(_ config: Data) async {
        guard let adminPort = ports?.admin else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(adminPort)/load")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = config
        request.timeoutInterval = 10
        do {
            let (body, response) = try await Self.adminSession.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                loadedConfig = config
                lastApplyError = nil
            } else {
                lastApplyError = String(decoding: body, as: UTF8.self)
            }
        } catch {
            lastApplyError = error.localizedDescription
        }
    }

    // MARK: - Termination

    /// Kills a Caddy left behind by a Portside that crashed or was force-quit.
    private func terminateStaleCaddy() async {
        guard let pid = recordedPid else { return }
        if Self.executableName(of: pid) == "caddy" {
            await Self.terminate(pid: pid) { kill(pid, 0) == 0 }
        }
        forgetPid(pid)
    }

    private var recordedPid: pid_t? {
        (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Removes the pid file only while it still names `pid`, so a newer instance's record survives.
    private func forgetPid(_ pid: pid_t) {
        if recordedPid == pid { try? FileManager.default.removeItem(at: pidFile) }
    }

    private static func terminate(pid: pid_t, isAlive: () -> Bool) async {
        kill(pid, SIGTERM)
        if await waitForExit(within: .seconds(5), isAlive) { return }
        kill(pid, SIGKILL)
        _ = await waitForExit(within: .seconds(1), isAlive)
    }

    private static func waitForExit(within timeout: Duration, _ isAlive: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isAlive() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}

private struct ProxyError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
