import Darwin
import XCTest
@testable import Portside

@MainActor
final class ProcessManagerTests: XCTestCase {
    private var dir: URL!
    private var settings: AppSettings!
    private var managers: [ProcessManager] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = AppSettings(defaults: UserDefaults(suiteName: "portside-tests-\(UUID().uuidString)")!)
    }

    override func tearDown() async throws {
        for manager in managers { await manager.stopAll() }
        managers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeManager(pidFile: String = "pids.json") -> ProcessManager {
        let manager = ProcessManager(settings: settings, pidFile: dir.appendingPathComponent(pidFile))
        managers.append(manager)
        return manager
    }

    private func makeSite(_ command: String, extras: [ProcessConfig] = []) -> Site {
        Site(name: "blog", folder: dir.path, main: ProcessConfig(label: "Frontend", command: command, port: 5474), extras: extras)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Values printed by test commands as `key=value` lines.
    private func printed(_ key: String, in buffer: LogBuffer) -> [String] {
        buffer.snapshot().lines.compactMap { line in
            line.hasPrefix("\(key)=") ? String(line.dropFirst(key.count + 1)) : nil
        }
    }

    private func pids(_ key: String, in buffer: LogBuffer) -> [pid_t] {
        printed(key, in: buffer).compactMap { pid_t($0) }
    }

    private func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    func testStopKillsTheWholeProcessGroup() async throws {
        let manager = makeManager()
        let site = makeSite("echo leader=$$; sleep 30 & echo child=$!; wait")
        await manager.start(site)
        let buffer = manager.buffer(for: site.main.id)
        try await waitUntil("pids printed") { !pids("child", in: buffer).isEmpty }
        let leader = try XCTUnwrap(pids("leader", in: buffer).first)
        let child = try XCTUnwrap(pids("child", in: buffer).first)
        XCTAssertFalse(isGone(leader))
        XCTAssertFalse(isGone(child))

        await manager.stop(site)

        XCTAssertTrue(isGone(leader), "zsh leader survived stop")
        XCTAssertTrue(isGone(child), "backgrounded grandchild survived stop")
        XCTAssertEqual(manager.state(of: site.main.id), .stopped)
        XCTAssertEqual(manager.status(of: site), .stopped)
    }

    func testStartingBecomesRunningAndRequestedStopDoesNotReportAnExit() async throws {
        let manager = makeManager()
        var exits: [Int32] = []
        manager.onUnexpectedExit = { _, _, code in exits.append(code) }
        let site = makeSite("sleep 30")

        await manager.start(site)
        XCTAssertEqual(manager.state(of: site.main.id), .starting)
        try await waitUntil("running") { manager.state(of: site.main.id) == .running }
        XCTAssertEqual(manager.status(of: site), .running)

        await manager.stop(site)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.state(of: site.main.id), .stopped)
        XCTAssertEqual(exits, [])
        XCTAssertEqual(manager.buffer(for: site.main.id).snapshot().lines.last, "■ stopped")
    }

    func testProcessExitingOnItsOwnReportsItsCode() async throws {
        let manager = makeManager()
        var exits: [(Site.ID, ProcessConfig.ID, Int32)] = []
        manager.onUnexpectedExit = { exits.append(($0, $1, $2)) }
        let site = makeSite("echo bye; exit 3")

        await manager.start(site)
        try await waitUntil("exit") { manager.state(of: site.main.id) == .exited(code: 3) }
        XCTAssertEqual(manager.status(of: site), .partial)
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first?.0, site.id)
        XCTAssertEqual(exits.first?.1, site.main.id)
        XCTAssertEqual(exits.first?.2, 3)
        XCTAssertEqual(Array(manager.buffer(for: site.main.id).snapshot().lines.suffix(2)), ["bye", "■ exited with code 3"])
    }

    func testSignalDeathMapsTo128PlusSignal() async throws {
        let manager = makeManager()
        let site = makeSite("kill -9 $$")
        await manager.start(site)
        try await waitUntil("exit") { manager.state(of: site.main.id) == .exited(code: 128 + SIGKILL) }
    }

    func testEnvironmentReachesTheChild() async throws {
        let manager = makeManager()
        var site = makeSite("echo \"env=$PORT $HOST $PORTSIDE $PORTSIDE_SITE $PORTSIDE_URL $FOO $TERM $FORCE_COLOR\"; echo cwd=$PWD")
        site.main.env = ["FOO": "bar"]
        await manager.start(site)
        try await waitUntil("exit") { manager.state(of: site.main.id) == .exited(code: 0) }
        let buffer = manager.buffer(for: site.main.id)
        XCTAssertEqual(printed("env", in: buffer), ["5474 localhost 1 blog http://blog.localhost bar xterm-256color 1"])
        XCTAssertEqual(printed("cwd", in: buffer).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, [dir.resolvingSymlinksInPath()])
    }

    func testProcessIgnoringSigtermIsKilledWithinSixSeconds() async throws {
        let manager = makeManager()
        // zsh's `trap '' TERM` does not reach its children here, so the ignoring tree runs under POSIX sh.
        let site = makeSite("exec /bin/sh -c 'trap \"\" TERM; echo leader=$$; sleep 60 & echo child=$!; wait'")
        await manager.start(site)
        let buffer = manager.buffer(for: site.main.id)
        try await waitUntil("pids printed") { !pids("child", in: buffer).isEmpty }
        let leader = try XCTUnwrap(pids("leader", in: buffer).first)
        let child = try XCTUnwrap(pids("child", in: buffer).first)

        let started = Date()
        await manager.stop(site)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(isGone(leader))
        XCTAssertTrue(isGone(child))
        XCTAssertGreaterThan(elapsed, 4.5, "SIGKILL came before the grace period")
        XCTAssertLessThan(elapsed, 6.5)
        XCTAssertEqual(manager.state(of: site.main.id), .stopped)
    }

    func testApplyRestartsOnlyChangedProcessesAndStopsRemovedOnes() async throws {
        let manager = makeManager()
        let api = ProcessConfig(label: "API", command: "echo leader=$$; exec sleep 30", port: 8185, subdomain: "api")
        let worker = ProcessConfig(label: "Worker", command: "echo leader=$$; exec sleep 30", port: 8186)
        let old = makeSite("echo leader=$$; exec sleep 30", extras: [api, worker])
        await manager.start(old)
        try await waitUntil("all running") { manager.status(of: old) == .running }
        let workerLeader = try XCTUnwrap(pids("leader", in: manager.buffer(for: worker.id)).first)

        var new = old
        new.extras = [api]
        new.extras[0].port = 8190
        let restarted = await manager.apply(edited: new, previous: old)

        XCTAssertEqual(restarted, ["API"])
        XCTAssertEqual(manager.state(of: worker.id), .stopped)
        XCTAssertTrue(isGone(workerLeader))
        try await waitUntil("api running again") { manager.state(of: api.id) == .running }
        XCTAssertEqual(pids("leader", in: manager.buffer(for: api.id)).count, 2, "API was not restarted")
        XCTAssertEqual(pids("leader", in: manager.buffer(for: old.main.id)).count, 1, "main was restarted")
        XCTAssertEqual(manager.state(of: old.main.id), .running)

        let none = await manager.apply(edited: new, previous: new)
        XCTAssertEqual(none, [])
    }

    func testStaticSiteTogglesWithoutSpawningMain() async throws {
        let manager = makeManager()
        let site = makeSite("", extras: [
            ProcessConfig(label: "Watcher", command: "sleep 30", port: 9000),
            ProcessConfig(label: "Assets", command: " ", port: 9001),
        ])
        await manager.start(site)
        XCTAssertEqual(manager.enabledStaticSites, [site.id])
        XCTAssertEqual(manager.state(of: site.main.id), .running)
        XCTAssertEqual(manager.state(of: site.extras[1].id), .stopped)
        try await waitUntil("watcher running") { manager.state(of: site.extras[0].id) == .running }
        XCTAssertEqual(manager.buffer(for: site.main.id).snapshot().totalAppended, 0)

        await manager.stop(site)
        XCTAssertEqual(manager.enabledStaticSites, [])
        XCTAssertEqual(manager.status(of: site), .stopped)
    }

    func testBadWorkingDirectoryFails() async throws {
        let manager = makeManager()
        var site = makeSite("true")
        site.main.workingDirectory = dir.appendingPathComponent("missing").path
        await manager.start(site)
        guard case .failed = manager.state(of: site.main.id) else {
            return XCTFail("expected .failed, got \(manager.state(of: site.main.id))")
        }
    }

    func testCommandOutputIsCapturedAndFinishingReportsItsCodeNotACrash() async throws {
        let manager = makeManager()
        var crashes: [Int32] = []
        var finished: [(Site.ID, SiteCommand.ID, Int32)] = []
        manager.onUnexpectedExit = { _, _, code in crashes.append(code) }
        manager.onCommandFinished = { finished.append(($0, $1, $2)) }
        let ok = SiteCommand(name: "Deploy", command: "echo deployed")
        let bad = SiteCommand(name: "Lint", command: "echo broken; exit 2")
        var site = makeSite("sleep 30")
        site.commands = [ok, bad]

        await manager.run(ok, in: site)
        await manager.run(bad, in: site)
        try await waitUntil("both finished") { finished.count == 2 }

        XCTAssertEqual(crashes, [])
        XCTAssertEqual(finished.first { $0.1 == ok.id }?.2, 0)
        XCTAssertEqual(finished.first { $0.1 == bad.id }?.2, 2)
        XCTAssertTrue(finished.allSatisfy { $0.0 == site.id })
        XCTAssertEqual(manager.state(of: bad.id), .exited(code: 2))
        XCTAssertTrue(manager.buffer(for: ok.id).snapshot().lines.contains("deployed"))
        XCTAssertEqual(Array(manager.buffer(for: bad.id).snapshot().lines.suffix(2)), ["broken", "■ exited with code 2"])
        XCTAssertTrue(manager.hasRun(ok.id))
        XCTAssertFalse(manager.hasRun(UUID()))
    }

    func testCommandRunsInItsFolderWithTheSiteEnvironment() async throws {
        let manager = makeManager()
        let sub = dir.appendingPathComponent("deploy")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let command = SiteCommand(name: "Deploy", command: "echo \"env=$PORTSIDE $PORTSIDE_SITE $PORTSIDE_URL $PORT\"; echo cwd=$PWD", workingDirectory: sub.path)
        var site = makeSite("sleep 30")
        site.commands = [command]

        await manager.run(command, in: site)
        try await waitUntil("exit") { manager.state(of: command.id) == .exited(code: 0) }

        let buffer = manager.buffer(for: command.id)
        XCTAssertEqual(printed("env", in: buffer), ["1 blog http://blog.localhost "])
        XCTAssertEqual(printed("cwd", in: buffer).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, [sub.resolvingSymlinksInPath()])
    }

    func testStoppingASiteLeavesItsRunningCommandAlive() async throws {
        let manager = makeManager()
        var finished: [Int32] = []
        manager.onCommandFinished = { _, _, code in finished.append(code) }
        let command = SiteCommand(name: "Deploy", command: "echo leader=$$; exec sleep 30")
        var site = makeSite("sleep 30")
        site.commands = [command]
        await manager.start(site)
        await manager.run(command, in: site)
        let buffer = manager.buffer(for: command.id)
        try await waitUntil("command printed") { !pids("leader", in: buffer).isEmpty }
        let leader = try XCTUnwrap(pids("leader", in: buffer).first)

        await manager.stop(site)

        XCTAssertEqual(manager.status(of: site), .stopped)
        XCTAssertEqual(manager.state(of: command.id), .running)
        XCTAssertFalse(isGone(leader), "stopping the site killed its command")

        await manager.stop(processID: command.id)
        XCTAssertTrue(isGone(leader))
        XCTAssertEqual(manager.state(of: command.id), .stopped)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(finished, [], "a requested stop reported the command as finished")
    }

    func testApplyStopsARunningCommandThatWasRemoved() async throws {
        let manager = makeManager()
        let deploy = SiteCommand(name: "Deploy", command: "echo leader=$$; exec sleep 30")
        let old = Site(name: "blog", folder: dir.path, main: ProcessConfig(label: "Frontend", command: "sleep 30", port: 5474), commands: [deploy])
        await manager.run(deploy, in: old)
        let buffer = manager.buffer(for: deploy.id)
        try await waitUntil("command printed") { !pids("leader", in: buffer).isEmpty }
        let leader = try XCTUnwrap(pids("leader", in: buffer).first)

        var new = old
        new.commands = []
        _ = await manager.apply(edited: new, previous: old)

        XCTAssertTrue(isGone(leader))
        XCTAssertEqual(manager.state(of: deploy.id), .stopped)
    }

    func testRelaunchKillsGroupsLeftByACrashedRun() async throws {
        let crashed = makeManager(pidFile: "crashed.json")
        let site = makeSite("echo leader=$$; sleep 30 & echo child=$!; wait")
        await crashed.start(site)
        let buffer = crashed.buffer(for: site.main.id)
        try await waitUntil("pids printed") { !pids("child", in: buffer).isEmpty }
        let leader = try XCTUnwrap(pids("leader", in: buffer).first)
        let child = try XCTUnwrap(pids("child", in: buffer).first)
        try FileManager.default.copyItem(at: dir.appendingPathComponent("crashed.json"), to: dir.appendingPathComponent("relaunch.json"))

        _ = makeManager(pidFile: "relaunch.json")

        try await waitUntil("leftovers killed", timeout: 7) { isGone(leader) && isGone(child) }
        try await waitUntil("ledger cleared") {
            (try? Data(contentsOf: dir.appendingPathComponent("relaunch.json"))) == Data("[]".utf8)
        }
    }
}
