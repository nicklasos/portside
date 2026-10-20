import XCTest
@testable import Portside

@MainActor
final class PortsideControllerTests: XCTestCase {
    private var dir: URL!
    private var controller: PortsideController!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        controller = PortsideController(configuration: .isolated(in: dir))
    }

    override func tearDown() async throws {
        await controller.shutdown()
        controller = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSite(main: String = "sleep 30", api: String = "sleep 30") -> Site {
        Site(name: "smartcity", folder: dir.path,
             main: ProcessConfig(label: "Frontend", command: main, port: 5474),
             extras: [ProcessConfig(label: "API", command: api, port: 8185, subdomain: "api")])
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testBootstrapStartsNothingOutsideTheLiveApp() {
        controller.bootstrap()
        XCTAssertEqual(controller.dnsState, .stopped)
        XCTAssertEqual(controller.proxy.state, .stopped)
    }

    func testMenuBarStatusFollowsSites() async throws {
        let site = makeSite(api: "exit 3")
        try await controller.save(edited: site)
        XCTAssertEqual(controller.menuBarStatus, MenuBarStatus(isActive: false, needsAttention: false))

        await controller.start(site)
        XCTAssertTrue(controller.menuBarStatus.isActive)
        try await waitUntil("API to crash") { controller.menuBarStatus.needsAttention }
        XCTAssertTrue(controller.menuBarStatus.isActive, "main still runs")

        await controller.stop(site)
        XCTAssertEqual(controller.menuBarStatus, MenuBarStatus(isActive: false, needsAttention: false))
    }

    func testSavingANewSitePersistsWithoutNotice() async throws {
        let notice = try await controller.save(edited: makeSite())
        XCTAssertNil(notice)
        XCTAssertEqual(SiteStore(persistence: Persistence(fileURL: dir.appendingPathComponent("support/sites.json"))).sites.map(\.name), ["smartcity"])
    }

    func testSavingInvalidSiteThrowsAndKeepsStore() async {
        var site = makeSite()
        site.name = "Bad Name"
        do {
            try await controller.save(edited: site)
            XCTFail("expected a validation error")
        } catch {}
        XCTAssertTrue(controller.store.sites.isEmpty)
    }

    func testEditingARunningSiteRestartsChangedProcessesAndSaysSo() async throws {
        var site = makeSite()
        try await controller.save(edited: site)
        await controller.start(site)
        try await waitUntil("both running") { controller.status(of: site) == .running }

        site.extras[0].command = "sleep 31"
        let notice = try await controller.save(edited: site)
        XCTAssertEqual(notice, "Saved. Restarted API.")
        XCTAssertTrue(controller.processes.state(of: site.extras[0].id).isAlive)

        site.main.preserveHost = true
        let proxyOnlyNotice = try await controller.save(edited: site)
        XCTAssertEqual(proxyOnlyNotice, "Saved. The proxy picked up the change.")

        site.name = "renamed"
        let renameNotice = try await controller.save(edited: site)
        XCTAssertEqual(renameNotice, "Saved. Restarted Frontend, API.", "PORTSIDE_SITE changes with the name")
    }

    func testToggleStartsThenStops() async throws {
        let site = makeSite()
        try await controller.save(edited: site)
        await controller.toggle(site)
        XCTAssertTrue(controller.isAnyProcessAlive(site))
        await controller.toggle(site)
        XCTAssertFalse(controller.isAnyProcessAlive(site))
    }

    func testDeleteStopsProcessesAndRemovesTheSite() async throws {
        let site = makeSite()
        try await controller.save(edited: site)
        await controller.start(site)
        await controller.delete(site)
        XCTAssertTrue(controller.store.sites.isEmpty)
        XCTAssertFalse(controller.isAnyProcessAlive(site))
    }

    func testStaticSiteToggleEnablesItForTheProxy() async throws {
        let site = Site(name: "blog", folder: dir.path, main: ProcessConfig(label: "", command: "", port: 1))
        try await controller.save(edited: site)
        await controller.toggle(site)
        XCTAssertEqual(controller.processes.enabledStaticSites, [site.id])
        XCTAssertEqual(controller.status(of: site), .running)
        await controller.toggle(site)
        XCTAssertTrue(controller.processes.enabledStaticSites.isEmpty)
    }

    func testURLsCarryANonDefaultProxyPort() async throws {
        let site = makeSite()
        XCTAssertEqual(controller.url(for: site)?.absoluteString, "http://smartcity.test")
        controller.settings.proxyPort = 8080
        XCTAssertEqual(controller.url(for: site, process: site.extras[0])?.absoluteString, "http://api.smartcity.test:8080")
    }
}
