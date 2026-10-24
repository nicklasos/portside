import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class ProcessManager {
    private var states: [ProcessConfig.ID: ProcessState] = [:]
    /// Static sites that are switched on, with their main process id.
    private var staticMains: [Site.ID: ProcessConfig.ID] = [:]

    @ObservationIgnored var onUnexpectedExit: ((_ site: Site.ID, _ process: ProcessConfig.ID, _ code: Int32) -> Void)?
    /// A command ending on its own, which is how a command is expected to end.
    @ObservationIgnored var onCommandFinished: ((_ site: Site.ID, _ command: SiteCommand.ID, _ code: Int32) -> Void)?

    /// A spawned group Portside owns. Leaving `.live` is what marks an exit as requested.
    private enum Child {
        case live(ManagedProcess)
        case stopping(ManagedProcess, Task<Void, Never>)

        var process: ManagedProcess {
            switch self {
            case .live(let p), .stopping(let p, _): p
            }
        }
    }

    @ObservationIgnored private var children: [ProcessConfig.ID: Child] = [:]
    @ObservationIgnored private var buffers: [ProcessConfig.ID: LogBuffer] = [:]
    /// Ids in `children` that are site commands rather than processes, so their exit is not a crash.
    @ObservationIgnored private var commandIDs: Set<SiteCommand.ID> = []
    @ObservationIgnored private let ledger: GroupLedger
    @ObservationIgnored private let settings: AppSettings

    private static let stagger: Duration = .milliseconds(300)
    private static let settleTime: Duration = .seconds(1)

    init(settings: AppSettings, pidFile: URL = AppPaths.supportDirectory.appendingPathComponent("pids.json")) {
        self.settings = settings
        ledger = GroupLedger(file: pidFile)
        ledger.killLeftovers()
    }

    var enabledStaticSites: Set<Site.ID> { Set(staticMains.keys) }

    func state(of processID: ProcessConfig.ID) -> ProcessState {
        staticMains.values.contains(processID) ? .running : states[processID] ?? .stopped
    }

    func status(of site: Site) -> SiteStatus {
        SiteStatus(states: site.processes.map { state(of: $0.id) })
    }

    func buffer(for processID: ProcessConfig.ID) -> LogBuffer {
        if let buffer = buffers[processID] { return buffer }
        let buffer = LogBuffer()
        buffers[processID] = buffer
        return buffer
    }

    /// Whether the process or command has run or logged anything this session.
    func hasRun(_ id: UUID) -> Bool {
        states[id] != nil || buffers[id] != nil
    }

    func start(_ site: Site) async {
        let idle = site.processes.filter { !state(of: $0.id).isAlive && children[$0.id] == nil }
        if site.isStatic, idle.contains(where: { $0.id == site.main.id }) { enableStatic(site) }
        let spawnable = idle.filter { !$0.isStatic }
        for p in spawnable { states[p.id] = .starting }
        for (i, p) in spawnable.enumerated() {
            if i > 0 { try? await Task.sleep(for: Self.stagger) }
            guard states[p.id] == .starting, children[p.id] == nil else { continue }
            launch(p.id, spec: launchSpec(for: p, in: site), mirror: mirrorURL(named: p.label.isEmpty ? p.id.uuidString : p.label, in: site), site: site.id)
        }
    }

    func stop(_ site: Site) async {
        await stopAll(site.processes.map(\.id))
    }

    func start(_ process: ProcessConfig, in site: Site) async {
        if case .stopping(_, let task) = children[process.id] { await task.value }
        guard !state(of: process.id).isAlive, children[process.id] == nil else { return }
        if process.isStatic {
            if process.id == site.main.id { enableStatic(site) }
            return
        }
        states[process.id] = .starting
        launch(process.id, spec: launchSpec(for: process, in: site), mirror: mirrorURL(named: process.label.isEmpty ? process.id.uuidString : process.label, in: site), site: site.id)
    }

    /// Runs a site command once. Stopping it goes through `stop(processID:)`.
    func run(_ command: SiteCommand, in site: Site) async {
        if case .stopping(_, let task) = children[command.id] { await task.value }
        guard !state(of: command.id).isAlive, children[command.id] == nil else { return }
        commandIDs.insert(command.id)
        // A command has no readiness to wait for, so it skips `.starting`.
        states[command.id] = .running
        launch(command.id, spec: launchSpec(for: command, in: site), mirror: mirrorURL(named: command.name, in: site), site: site.id)
    }

    func stop(processID id: ProcessConfig.ID) async {
        if let site = staticMains.first(where: { $0.value == id })?.key {
            staticMains[site] = nil
            return
        }
        switch children[id] {
        case nil:
            states[id] = nil
        case .stopping(_, let task):
            await task.value
        case .live(let process):
            let task = Task { _ = await process.terminate() }
            children[id] = .stopping(process, task)
            await task.value
            guard case .stopping(let p, _) = children[id], p === process else { return }
            children[id] = nil
            states[id] = nil
            ledger.remove(process.pid)
            buffer(for: id).appendSystem("■ stopped")
        }
    }

    func restart(_ process: ProcessConfig, in site: Site) async {
        await stop(processID: process.id)
        await start(process, in: site)
    }

    func apply(edited new: Site, previous old: Site) async -> [String] {
        let kept = Set(new.processes.map(\.id) + new.commands.map(\.id))
        let removed = (old.processes.map(\.id) + old.commands.map(\.id)).filter { !kept.contains($0) }
        let changed = new.processes.filter { p in
            guard state(of: p.id).isAlive, let before = old.processes.first(where: { $0.id == p.id }) else { return false }
            return launchSpec(for: before, in: old) != launchSpec(for: p, in: new)
        }
        await withTaskGroup(of: Void.self) { group in
            for id in removed { group.addTask { await self.stop(processID: id) } }
            for p in changed { group.addTask { await self.restart(p, in: new) } }
        }
        return changed.map { $0.label.isEmpty ? $0.command : $0.label }
    }

    func stopAll() async {
        await stopAll(Array(Set(states.keys).union(children.keys).union(staticMains.values)))
    }

    private func stopAll(_ ids: [ProcessConfig.ID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.stop(processID: id) } }
        }
    }

    private func enableStatic(_ site: Site) {
        states[site.main.id] = nil
        staticMains[site.id] = site.main.id
    }

    private func launch(_ id: UUID, spec: LaunchSpec, mirror: URL, site: Site.ID) {
        let buffer = buffer(for: id)
        buffer.mirror(to: settings.mirrorLogsToDisk ? mirror : nil)
        let process: ManagedProcess
        do {
            process = try ManagedProcess(spec: spec, buffer: buffer) { [weak self] process, code in
                Task { @MainActor in self?.processExited(process, code: code, id: id, site: site) }
            }
        } catch {
            states[id] = .failed("\(error)")
            buffer.appendSystem("■ could not start \(spec.command): \(error)")
            return
        }
        children[id] = .live(process)
        ledger.insert(process)
        Task {
            try? await Task.sleep(for: Self.settleTime)
            if case .live(let p) = children[id], p === process, states[id] == .starting { states[id] = .running }
        }
    }

    private func processExited(_ process: ManagedProcess, code: Int32, id: UUID, site: Site.ID) {
        guard case .live(let p) = children[id], p === process else { return }
        children[id] = nil
        states[id] = .exited(code: code)
        buffer(for: id).appendSystem("■ exited with code \(code)")
        Task {
            await process.terminate()
            ledger.remove(process.pid)
        }
        if commandIDs.contains(id) {
            onCommandFinished?(site, id, code)
        } else {
            onUnexpectedExit?(site, id, code)
        }
    }

    private func launchSpec(for p: ProcessConfig, in site: Site) -> LaunchSpec {
        var env = [
            "PORT": String(p.port),
            "HOST": p.host,
            "PORTSIDE": "1",
            "PORTSIDE_SITE": site.name,
        ]
        if let domain = site.domain(for: p, in: settings.domainSuffix) { env["PORTSIDE_URL"] = settings.url(forDomain: domain).absoluteString }
        env.merge(p.env) { $1 }
        env["TERM"] = "xterm-256color"
        env["FORCE_COLOR"] = "1"
        return LaunchSpec(command: p.command, workingDirectory: site.workingDirectory(for: p), environment: env)
    }

    private func launchSpec(for c: SiteCommand, in site: Site) -> LaunchSpec {
        let env = [
            "PORTSIDE": "1",
            "PORTSIDE_SITE": site.name,
            "PORTSIDE_URL": settings.url(forDomain: site.domain(in: settings.domainSuffix)).absoluteString,
            "TERM": "xterm-256color",
            "FORCE_COLOR": "1",
        ]
        return LaunchSpec(command: c.command, workingDirectory: site.workingDirectory(for: c), environment: env)
    }

    private func mirrorURL(named name: String, in site: Site) -> URL {
        AppPaths.logsDirectory.appendingPathComponent(site.name, isDirectory: true)
            .appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).log")
    }
}

/// Process groups spawned and not yet confirmed dead, persisted so a relaunch after a crash can kill them.
@MainActor
private final class GroupLedger {
    private struct Entry: Codable, Hashable {
        var pgid: pid_t
        var startTime: UInt64?
    }

    private let file: URL
    private var entries: Set<Entry> = []

    init(file: URL) {
        self.file = file
    }

    func insert(_ process: ManagedProcess) {
        entries.insert(Entry(pgid: process.pid, startTime: process.startTime))
        save()
    }

    func remove(_ pgid: pid_t) {
        entries = entries.filter { $0.pgid != pgid }
        save()
    }

    /// Kills recorded groups that are still ours. A group counts as ours when its leader is the
    /// same process (pid and start time match), or when the leader is gone but the group lives on,
    /// since a pgid cannot be handed to a new process while its group still exists.
    func killLeftovers() {
        guard let data = try? Data(contentsOf: file), let recorded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        let ours = recorded.filter { entry in
            guard Spawn.groupExists(entry.pgid) else { return false }
            guard let leaderStart = Spawn.startTime(of: entry.pgid) else { return true }
            return leaderStart == entry.startTime
        }
        entries = Set(ours)
        save()
        for entry in ours {
            kill(-entry.pgid, SIGTERM)
            DispatchQueue.global().async {
                Spawn.terminateGroup(entry.pgid)
                Task { @MainActor in self.remove(entry.pgid) }
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries.sorted { $0.pgid < $1.pgid }).write(to: file, options: .atomic)
        } catch {
            NSLog("Portside: could not write \(file.path): \(error)")
        }
    }
}
