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
        XCTAssertEqual(controller.url(for: site)?.absoluteString, "http://smartcity.localhost")
        controller.settings.proxyPort = 8080
        XCTAssertEqual(controller.url(for: site, process: site.extras[0])?.absoluteString, "http://api.smartcity.localhost:8080")
    }

    /// macOS answers loopback only for names under `systemResolved`.
    private func makeController(systemResolved: Set<String>) -> PortsideController {
        var configuration = PortsideController.Configuration.isolated(in: dir.appendingPathComponent("strategy"))
        configuration.probes.lookup = { host in
            systemResolved.contains(String(host.split(separator: ".").last ?? "")) ? [[127, 0, 0, 1]] : []
        }
        let controller = PortsideController(configuration: configuration)
        controller.settings.dnsPort = 0
        return controller
    }

    func testSystemResolvedSuffixRunsNoDNSServer() async {
        let controller = makeController(systemResolved: ["localhost"])
        await controller.chooseDomainSuffix(.localhost)
        XCTAssertTrue(controller.settings.hasChosenDomainSuffix)
        XCTAssertEqual(controller.resolution, .system)
        XCTAssertEqual(controller.dnsState, .stopped)
        XCTAssertFalse(controller.needsResolverSetup)
        XCTAssertFalse(controller.shouldPromptForResolver)
        await controller.shutdown()
    }

    func testSuffixNeedingPortsideDNSStartsItForThatZoneAndAsksForTheResolver() async throws {
        let controller = makeController(systemResolved: ["localhost"])
        await controller.chooseDomainSuffix(.test)
        XCTAssertEqual(controller.resolution, .portsideDNS)
        guard case .running(let port) = controller.dnsState else { return XCTFail("DNS not running: \(controller.dnsState)") }
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(controller.needsResolverSetup)
        XCTAssertTrue(controller.shouldPromptForResolver)
        XCTAssertEqual(controller.url(for: makeSite())?.absoluteString, "http://smartcity.test")

        await controller.chooseDomainSuffix(.localhost)
        XCTAssertEqual(controller.dnsState, .stopped, "switching to a system-resolved suffix stops the server")
        await controller.shutdown()
    }

    func testSuffixChangeWhileRunningAsksForRestart() async throws {
        let site = makeSite()
        try await controller.save(edited: site)
        await controller.chooseDomainSuffix(.localhost)
        XCTAssertNil(controller.domainNotice, "no change, nothing running")
        await controller.start(site)
        await controller.chooseDomainSuffix(.loc)
        XCTAssertEqual(controller.domainNotice, "Restart running sites to update PORTSIDE_URL.")
        XCTAssertEqual(controller.settings.domainSuffix.label, "loc")
    }

    func testOnlyPortsidesOwnLeftoverResolverIsOfferedForRemoval() async throws {
        let controller = makeController(systemResolved: [])
        let resolvers = controller.configuration.resolverDirectory
        try FileManager.default.createDirectory(at: resolvers, withIntermediateDirectories: true)
        try ResolverInstaller.expectedContents(dnsPort: 0).write(to: resolvers.appendingPathComponent("test"), atomically: true, encoding: .utf8)
        try "nameserver 127.0.0.1\n".write(to: resolvers.appendingPathComponent("loc"), atomically: true, encoding: .utf8)

        await controller.chooseDomainSuffix(.test)
        XCTAssertEqual(controller.resolverStatus, .installed)
        XCTAssertEqual(controller.staleResolvers, [], "the file in use is not stale")

        await controller.chooseDomainSuffix(.localhost)
        XCTAssertEqual(controller.staleResolvers, [.test], "loc belongs to another tool")
        await controller.shutdown()
    }

    func testSuffixSurvivesRelaunch() async throws {
        await controller.chooseDomainSuffix(try DomainSuffix.custom("wip").get())
        let reloaded = AppSettings(defaults: controller.configuration.defaults)
        XCTAssertEqual(reloaded.domainSuffix.label, "wip")
        XCTAssertTrue(reloaded.hasChosenDomainSuffix)
    }
}
