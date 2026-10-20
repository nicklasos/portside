import XCTest
@testable import Portside

/// Golden files live in `Fixtures/`. Run with `TEST_RUNNER_RECORD_GOLDENS=1` to rewrite them,
/// then review the diff and run `caddy validate --config <file>` on each.
final class CaddyConfigBuilderTests: XCTestCase {
    static let fixtureRoot = "/tmp/portside-fixtures"

    private let smartcity = Site(
        name: "smartcity", folder: "\(fixtureRoot)/smartcity",
        main: ProcessConfig(label: "Frontend", command: "make dev", port: 5474),
        extras: [
            ProcessConfig(label: "API", command: "make api", port: 8185, subdomain: "api"),
            ProcessConfig(label: "Worker", command: "make worker", port: 9000),
        ]
    )
    private let legacy = Site(
        name: "legacy", folder: "\(fixtureRoot)/legacy",
        main: ProcessConfig(label: "App", command: "php -S 127.0.0.1:5475", host: "127.0.0.1", port: 5475, preserveHost: true)
    )
    private let docs = Site(
        name: "docs", folder: "\(fixtureRoot)/docs",
        main: ProcessConfig(label: "Files", command: "", port: 1)
    )
    private let logs = URL(fileURLWithPath: "\(fixtureRoot)/logs")

    func testPlanExampleSmartcityWithApiExtra() throws {
        try assertGolden("smartcity", CaddyConfigBuilder.build(sites: [smartcity], enabledStaticSites: [], proxyPort: 80, adminPort: 2019, logsDirectory: nil))
    }

    func testPreserveHostPassesOriginalHost() throws {
        try assertGolden("preserve-host", CaddyConfigBuilder.build(sites: [legacy], enabledStaticSites: [], proxyPort: 8080, adminPort: 2019, logsDirectory: nil))
    }

    func testStaticSiteEnabledServesFolderWithAccessLog() throws {
        try assertGolden("static-enabled", CaddyConfigBuilder.build(sites: [docs], enabledStaticSites: [docs.id], proxyPort: 8080, adminPort: 2019, logsDirectory: logs))
    }

    func testStaticSiteDisabledShowsStoppedPage() throws {
        try assertGolden("static-disabled", CaddyConfigBuilder.build(sites: [docs], enabledStaticSites: [], proxyPort: 8080, adminPort: 2019, logsDirectory: nil))
    }

    func testNoSitesOnlyHasUnknownHostFallback() throws {
        try assertGolden("empty", CaddyConfigBuilder.build(sites: [], enabledStaticSites: [], proxyPort: 8080, adminPort: 2019, logsDirectory: nil))
    }

    /// The config used for the live proof: every route kind on an alternate proxy port.
    func testAllSitesOnAlternateProxyPort() throws {
        try assertGolden("all-8080", CaddyConfigBuilder.build(sites: [smartcity, legacy, docs], enabledStaticSites: [docs.id], proxyPort: 8080, adminPort: 2019, logsDirectory: logs))
    }

    func testOutputIsIndependentOfSiteOrder() {
        let a = CaddyConfigBuilder.build(sites: [smartcity, legacy, docs], enabledStaticSites: [docs.id], proxyPort: 8080, adminPort: 2019, logsDirectory: logs)
        let b = CaddyConfigBuilder.build(sites: [docs, legacy, smartcity], enabledStaticSites: [docs.id], proxyPort: 8080, adminPort: 2019, logsDirectory: logs)
        XCTAssertEqual(a, b)
    }

    func testAccessLogPath() {
        XCTAssertEqual(CaddyConfigBuilder.accessLogFile(siteName: "docs", in: logs).path, "\(Self.fixtureRoot)/logs/docs/access.log")
    }

    private func assertGolden(_ name: String, _ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/caddy-\(name).json")
        let actual = String(decoding: data, as: UTF8.self) + "\n"
        if ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(actual, expected, "\(url.lastPathComponent) differs; rerun with TEST_RUNNER_RECORD_GOLDENS=1 and review", file: file, line: line)
    }
}
