import XCTest
@testable import Portside

final class EnvPortDetectorTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    private func detect(_ files: [String: String]) -> DetectedPort? {
        EnvPortDetector.detect(in: folder) { url in
            XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/project")
            return files[url.lastPathComponent]
        }
    }

    func testNoFilesDetectsNothing() {
        XCTAssertNil(detect([:]))
        XCTAssertNil(detect([".env": "APP_NAME=blog\nDEBUG=true\n"]))
    }

    func testPortWinsOverOtherWebKeys() {
        let env = "VITE_PORT=5173\nAPP_PORT=8000\nPORT=3000\n"
        XCTAssertEqual(detect([".env": env]), DetectedPort(port: 3000, key: "PORT", file: ".env"))
    }

    func testPriorityTableOrder() {
        let env = "DEV_PORT=7000\nVITE_PORT=5173\nWEB_PORT=6000\nHTTP_PORT=4000\nSERVER_PORT=9000\nAPP_PORT=8000\n"
        XCTAssertEqual(detect([".env": env])?.key, "APP_PORT")
        XCTAssertEqual(detect([".env": "DEV_PORT=7000\nVITE_PORT=5173\n"])?.key, "VITE_PORT")
    }

    func testDatabaseAndServicePortsAreIgnored() {
        let env = """
        DB_PORT=5432
        FORWARD_DB_PORT=5433
        REDIS_PORT=6379
        MAIL_PORT=1025
        POSTGRES_PORT=5432
        MEMCACHED_PORT=11211
        """
        XCTAssertNil(detect([".env": env]))
        XCTAssertEqual(detect([".env": env + "\nAPP_PORT=8000"]), DetectedPort(port: 8000, key: "APP_PORT", file: ".env"))
    }

    func testOtherPortKeyFallsBackInFileOrder() {
        let env = "DB_PORT=5432\nBACKEND_PORT=8080\nADMIN_PORT=9090\n"
        XCTAssertEqual(detect([".env": env]), DetectedPort(port: 8080, key: "BACKEND_PORT", file: ".env"))
    }

    func testLaterFilesOverrideEarlierOnes() {
        let files = [
            ".env": "APP_PORT=8000\nPORT=3000\n",
            ".env.local": "PORT=3001\n",
            ".env.development": "PORT=3002\n",
            ".env.development.local": "APP_PORT=8003\n",
            ".env.example": "PORT=1111\n",
        ]
        XCTAssertEqual(detect(files), DetectedPort(port: 3002, key: "PORT", file: ".env.development"))
    }

    func testExampleFileIsNotRead() {
        XCTAssertNil(detect([".env.example": "PORT=3000\n"]))
    }

    func testQuotesCommentsAndExport() {
        XCTAssertEqual(detect([".env": "# PORT=1\n\nexport PORT=\"4000\"\n"])?.port, 4000)
        XCTAssertEqual(detect([".env": "PORT='4001' # dev\n"])?.port, 4001)
        XCTAssertEqual(detect([".env": "PORT=4002 # dev server\n"])?.port, 4002)
        XCTAssertEqual(detect([".env": "  PORT = 4003  \n"])?.port, 4003)
        XCTAssertEqual(EnvPortDetector.parse("A=\"x # y\"\nB=x#y\n").map(\.value), ["x # y", "x#y"])
    }

    func testTrivialReferenceIsExpanded() {
        let env = "SERVER_PORT=8000\nPORT=${SERVER_PORT}\n"
        XCTAssertEqual(detect([".env": env]), DetectedPort(port: 8000, key: "PORT", file: ".env"))
        XCTAssertEqual(detect([".env": "PORT=${MISSING}\nAPP_PORT=8001\n"])?.key, "APP_PORT")
    }

    func testInvalidValuesAreSkipped() {
        XCTAssertEqual(detect([".env": "PORT=0\nAPP_PORT=70000\nSERVER_PORT=abc\nHTTP_PORT=-1\nWEB_PORT=8080\n"])?.key, "WEB_PORT")
        XCTAssertNil(detect([".env": "PORT=\nAPP_PORT=80a\n"]))
    }

    func testLocalURLWithExplicitPortIsTheLastResort() {
        XCTAssertEqual(detect([".env": "APP_URL=http://localhost:8000\n"]), DetectedPort(port: 8000, key: "APP_URL", file: ".env"))
        XCTAssertEqual(detect([".env": "SITE_URL=http://127.0.0.1:4321/blog\n"])?.port, 4321)
        XCTAssertNil(detect([".env": "APP_URL=http://localhost\nBASE_URL=https://example.com:8443\n"]))
        XCTAssertEqual(detect([".env": "APP_URL=http://localhost:8000\nPORT=3000\n"])?.key, "PORT")
    }

    func testReadsFilesFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "DB_PORT=5432\nAPP_PORT=8000\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvPortDetector.detect(in: dir), DetectedPort(port: 8000, key: "APP_PORT", file: ".env"))
    }
}

final class FolderAutofillTests: XCTestCase {
    private let detected = DetectedPort(port: 8000, key: "APP_PORT", file: ".env")

    private func newSite() -> Site {
        Site(name: "", folder: "", main: ProcessConfig(label: "Frontend", command: "", port: 3000))
    }

    func testNewSiteGetsNameFromFolderAndDetectedPort() {
        var site = newSite()
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/Users/me/Projects/My CRM", detected: detected, to: &site)
        XCTAssertEqual(site.name, "mycrm")
        XCTAssertEqual(site.main.port, 8000)
    }

    func testTypedPortIsKept() {
        var site = newSite()
        site.main.port = 5474
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/blog", detected: detected, to: &site)
        XCTAssertEqual(site.main.port, 5474)
    }

    func testEmptyPortIsFilled() {
        var site = newSite()
        site.main.port = 0
        _ = FolderAutofill().apply(folder: "/p/blog", detected: detected, to: &site)
        XCTAssertEqual(site.main.port, 8000)
    }

    func testTypedNameIsKept() {
        var site = newSite()
        site.name = "shop"
        _ = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/blog", detected: nil, to: &site)
        XCTAssertEqual(site.name, "shop")
        XCTAssertEqual(site.main.port, 3000)
    }

    func testFilledValuesFollowTheNextFolder() {
        var site = newSite()
        let first = FolderAutofill.newSite(defaultPort: 3000).apply(folder: "/p/blog", detected: detected, to: &site)
        _ = first.apply(folder: "/p/shop", detected: DetectedPort(port: 4000, key: "PORT", file: ".env.local"), to: &site)
        XCTAssertEqual(site.name, "shop")
        XCTAssertEqual(site.main.port, 4000)
    }

    func testEditedSiteKeepsItsSavedPortAndName() {
        var site = Site(name: "blog", folder: "/p/blog", main: ProcessConfig(label: "Frontend", command: "make dev", port: 3000))
        _ = FolderAutofill().apply(folder: "/p/blog-v2", detected: detected, to: &site)
        XCTAssertEqual(site.name, "blog")
        XCTAssertEqual(site.main.port, 3000)
    }
}
