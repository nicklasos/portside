import XCTest
@testable import Portside

final class DomainSuffixTests: XCTestCase {
    private func reason(_ raw: String) -> String? {
        if case .failure(let rejection) = DomainSuffix.custom(raw) { return rejection.reason }
        return nil
    }

    func testPresetsHaveLabelAndDisplay() {
        XCTAssertEqual(DomainSuffix.presets.map(\.display), [".localhost", ".test", ".loc", ".local"])
        XCTAssertEqual(DomainSuffix.localhost.label, "localhost")
    }

    func testCustomAcceptsOneLabelAndNormalizes() throws {
        XCTAssertEqual(try DomainSuffix.custom("wip").get().label, "wip")
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

    func testCustomPointsPresetsToTheirOption() {
        XCTAssertEqual(reason("localhost"), "Choose the .localhost option above")
        XCTAssertEqual(reason(".TEST"), "Choose the .test option above")
        XCTAssertEqual(reason("local"), "Choose the .local option above")
    }

    func testNameCheckExplainsEachKindOfName() throws {
        XCTAssertEqual(DomainSuffix.localhost.nameCheck.mark, .ok)
        XCTAssertEqual(DomainSuffix.test.nameCheck.mark, .ok)
        XCTAssertEqual(DomainSuffix.local.nameCheck.mark, .warning)
        XCTAssertTrue(DomainSuffix.local.nameCheck.text.contains("Bonjour"))
        for suffix in [DomainSuffix.loc, try DomainSuffix.custom("lan").get(), try DomainSuffix.custom("internal").get(), try DomainSuffix.custom("home").get()] {
            XCTAssertEqual(suffix.nameCheck, CheckLine(.warning, "Not reserved. It may collide with names on your network"), suffix.label)
        }
        XCTAssertEqual(try DomainSuffix.custom("wip").get().nameCheck, CheckLine(.ok, "Valid name, not a public TLD"))
    }

    func testCodableRoundTripsAsTheLabel() throws {
        let wip = try DomainSuffix.custom("wip").get()
        for suffix in [DomainSuffix.localhost, .test, .local, wip] {
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
            name: "blog", folder: "/tmp",
            main: ProcessConfig(label: "Frontend", command: "make dev", port: 5474),
            extras: [
                ProcessConfig(label: "API", command: "make api", port: 8185, subdomain: "api"),
                ProcessConfig(label: "Worker", command: "make worker", port: 9000),
            ]
        )
        XCTAssertEqual(site.domain(in: .localhost), "blog.localhost")
        XCTAssertEqual(site.domain(for: site.main, in: .test), "blog.test")
        XCTAssertEqual(site.domain(for: site.extras[0], in: .loc), "api.blog.loc")
        XCTAssertNil(site.domain(for: site.extras[1], in: .localhost), "no subdomain, no domain")
    }

    func testSystemResolverLoopbackCheck() {
        XCTAssertTrue(SystemResolver.isLoopback([127, 0, 0, 1]))
        XCTAssertTrue(SystemResolver.isLoopback([127, 0, 0, 53]))
        XCTAssertTrue(SystemResolver.isLoopback([UInt8](repeating: 0, count: 15) + [1]))
        XCTAssertFalse(SystemResolver.isLoopback([10, 0, 0, 1]))
        XCTAssertFalse(SystemResolver.isLoopback([UInt8](repeating: 0, count: 16)))
    }
}
