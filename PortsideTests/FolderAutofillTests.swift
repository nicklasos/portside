import XCTest
@testable import Portside

final class FolderAutofillTests: XCTestCase {
    private let detected = DetectedPort(port: 8000, key: "APP_PORT", file: ".env")
    private let npmDev = DetectedCommand(command: "npm run dev", source: "package.json (scripts.dev)")

    private func newSite() -> Site {
        Site(name: "", folder: "", main: ProcessConfig(label: "Frontend", command: "", port: 3000))
    }

    func testNewSiteGetsNameFromFolderAndDetectedPort() {
        var site = newSite()
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/Users/me/Projects/My CRM", detected: detected, command: nil, to: &site)
        XCTAssertEqual(site.name, "mycrm")
        XCTAssertEqual(site.main.port, 8000)
    }

    func testTypedPortIsKept() {
        var site = newSite()
        site.main.port = 5474
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/blog", detected: detected, command: nil, to: &site)
        XCTAssertEqual(site.main.port, 5474)
    }

    func testEmptyPortIsFilled() {
        var site = newSite()
        site.main.port = 0
        _ = FolderAutofill().apply(folder: "/p/blog", detected: detected, command: nil, to: &site)
        XCTAssertEqual(site.main.port, 8000)
    }

    func testTypedNameIsKept() {
        var site = newSite()
        site.name = "shop"
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/blog", detected: nil, command: nil, to: &site)
        XCTAssertEqual(site.name, "shop")
        XCTAssertEqual(site.main.port, 3000)
    }

    func testFilledValuesFollowTheNextFolder() {
        var site = newSite()
        let first = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/blog", detected: detected, command: npmDev, to: &site)
        _ = first.apply(
            folder: "/p/shop",
            detected: DetectedPort(port: 4000, key: "PORT", file: ".env.local"),
            command: DetectedCommand(command: "go run .", source: "go.mod"),
            to: &site
        )
        XCTAssertEqual(site.name, "shop")
        XCTAssertEqual(site.main.port, 4000)
        XCTAssertEqual(site.main.command, "go run .")
    }

    func testEditedSiteKeepsItsSavedPortAndName() {
        var site = Site(name: "blog", folder: "/p/blog", main: ProcessConfig(label: "Frontend", command: "make dev", port: 3000))
        _ = FolderAutofill().apply(folder: "/p/blog-v2", detected: detected, command: npmDev, to: &site)
        XCTAssertEqual(site.name, "blog")
        XCTAssertEqual(site.main.port, 3000)
        XCTAssertEqual(site.main.command, "make dev")
    }

    func testEmptyCommandIsFilledFromTheFolder() {
        var site = newSite()
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/example", detected: nil, command: npmDev, to: &site)
        XCTAssertEqual(site.main.command, "npm run dev")
    }

    func testTypedCommandIsKept() {
        var site = newSite()
        site.main.command = "make watch"
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/example", detected: nil, command: npmDev, to: &site)
        XCTAssertEqual(site.main.command, "make watch")
    }

    func testFilledCommandClearsForAFolderWithNoCommand() {
        var site = newSite()
        let first = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/example", detected: nil, command: npmDev, to: &site)
        _ = first.apply(folder: "/p/docs", detected: nil, command: nil, to: &site)
        XCTAssertEqual(site.main.command, "")
    }

    func testStaticSiteGetsACommandWhenItsFolderChanges() {
        var site = Site(name: "blog", folder: "/p/blog", main: ProcessConfig(label: "Frontend", command: "", port: 3000))
        _ = FolderAutofill().apply(folder: "/p/example", detected: nil, command: npmDev, to: &site)
        XCTAssertEqual(site.main.command, "npm run dev")
    }
}
