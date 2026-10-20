import XCTest
@testable import Portside

final class DomainSuffixTests: XCTestCase {
    private func reason(_ raw: String) -> String? {
        if case .failure(let rejection) = DomainSuffix.custom(raw) { return rejection.reason }
        return nil
    }

    func testPresetsHaveLabelAndDisplay() {
        XCTAssertEqual(DomainSuffix.localhost.label, "localhost")
        XCTAssertEqual(DomainSuffix.localhost.display, ".localhost")
        XCTAssertEqual(DomainSuffix.test.display, ".test")
    }

    func testCustomAcceptsOneLabelAndNormalizes() throws {
        XCTAssertEqual(try DomainSuffix.custom("loc").get().label, "loc")
        XCTAssertEqual(try DomainSuffix.custom(" .Wip ").get().label, "wip")
        XCTAssertFalse(try DomainSuffix.custom("wip").get().isPreset)
    }

    func testCustomRejectsMalformedLabels() {
        for raw in ["", "two.labels", "-dash", "dash-", "under_score", "spa ce", "123"] {
            XCTAssertNotNil(reason(raw), raw)
        }
    }

    func testCustomRejectsRealAndHSTSPreloadedTLDs() {
        for tld in ["com", "net", "org", "io", "dev", "app", "page", "new", "day", "foo", "zip", "mov", "ai", "co", "me"] {
            XCTAssertNotNil(reason(tld), tld)
        }
        XCTAssertEqual(reason("dev"), ".dev is a real TLD that forces HTTPS in browsers")
    }

    func testCustomRejectsMDNSAndPointsPresetsToTheirOption() {
        XCTAssertEqual(reason("local"), ".local belongs to Bonjour (mDNS). Lookups would go to the network")
        XCTAssertEqual(reason("localhost"), "Choose the .localhost option above")
        XCTAssertEqual(reason(".TEST"), "Choose the .test option above")
    }

    func testUnreservedLocalNamesWarnButPass() throws {
        for raw in ["loc", "lan", "internal", "home"] {
            let suffix = try DomainSuffix.custom(raw).get()
            XCTAssertEqual(suffix.warning, ".\(raw) is not reserved. It may collide with names on your network.")
        }
        XCTAssertNil(DomainSuffix.localhost.warning)
        XCTAssertNil(try DomainSuffix.custom("wip").get().warning)
    }

    func testCodableRoundTripsAsTheLabel() throws {
        let loc = try DomainSuffix.custom("loc").get()
        for suffix in [DomainSuffix.localhost, .test, loc] {
            let data = try JSONEncoder().encode(suffix)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(suffix.label)\"")
            XCTAssertEqual(try JSONDecoder().decode(DomainSuffix.self, from: data), suffix)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DomainSuffix.self, from: Data("\"com\"".utf8)))
    }

    func testStoredSuffixFallsBackToLocalhost() {
        let defaults = UserDefaults(suiteName: "portside-suffix-\(UUID().uuidString)")!
        defaults.set("com", forKey: "domainSuffix")
        let settings = MainActor.assumeIsolated { AppSettings(defaults: defaults) }
        MainActor.assumeIsolated {
            XCTAssertEqual(settings.domainSuffix, .localhost)
            XCTAssertFalse(settings.hasChosenDomainSuffix)
        }
    }

    func testDomainsDeriveFromNameSubdomainAndSuffix() throws {
        let site = Site(
            name: "smartcity", folder: "/tmp",
            main: ProcessConfig(label: "Frontend", command: "make dev", port: 5474),
            extras: [
                ProcessConfig(label: "API", command: "make api", port: 8185, subdomain: "api"),
                ProcessConfig(label: "Worker", command: "make worker", port: 9000),
            ]
        )
        XCTAssertEqual(site.domain(in: .localhost), "smartcity.localhost")
        XCTAssertEqual(site.domain(for: site.main, in: .test), "smartcity.test")
        XCTAssertEqual(site.domain(for: site.extras[0], in: try DomainSuffix.custom("loc").get()), "api.smartcity.loc")
        XCTAssertNil(site.domain(for: site.extras[1], in: .localhost), "no subdomain, no domain")
    }

    func testSystemResolverLoopbackCheck() {
        XCTAssertTrue(SystemResolver.isLoopback([127, 0, 0, 1]))
        XCTAssertTrue(SystemResolver.isLoopback([127, 0, 0, 53]))
        XCTAssertTrue(SystemResolver.isLoopback([UInt8](repeating: 0, count: 15) + [1]))
        XCTAssertFalse(SystemResolver.isLoopback([10, 0, 0, 1]))
        XCTAssertFalse(SystemResolver.isLoopback([UInt8](repeating: 0, count: 16)))
    }

    /// The probe treats a suffix whose resolver file exists as needing Portside's DNS server,
    /// even when another tool's server answers it today.
    func testDetectNeedsPortsideDNSWhenAResolverFileExists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "nameserver 127.0.0.1\n".write(to: dir.appendingPathComponent("localhost"), atomically: true, encoding: .utf8)
        let strategy = await ResolutionStrategy.detect(.localhost, resolverDirectory: dir)
        XCTAssertEqual(strategy, .portsideDNS)
    }
}
