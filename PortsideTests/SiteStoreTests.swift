import XCTest
@testable import Portside

@MainActor
final class SiteStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> SiteStore {
        SiteStore(persistence: Persistence(fileURL: dir.appendingPathComponent("sites.json")))
    }

    private func makeSite(_ name: String = "blog", port: Int = 5474) -> Site {
        Site(name: name, folder: dir.path,
             main: ProcessConfig(label: "Frontend", command: "make dev", port: port),
             extras: [ProcessConfig(label: "API", command: "make api", port: port + 1, subdomain: "api")])
    }

    func testAddEditDeleteRoundTripsThroughDisk() throws {
        let store = makeStore()
        var site = try store.upsert(makeSite())
        XCTAssertEqual(makeStore().sites, [site])

        site.main.port = 3000
        try store.upsert(site)
        XCTAssertEqual(makeStore().sites.first?.main.port, 3000)

        try store.delete(id: site.id)
        XCTAssertTrue(makeStore().sites.isEmpty)
    }

    func testFileHasVersionEnvelope() throws {
        let store = makeStore()
        try store.upsert(makeSite())
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("sites.json"))) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual((json["sites"] as? [Any])?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sites.json.tmp").path))
    }

    func testLoadToleratesUnknownAndMissingKeys() throws {
        let json = """
        {"version": 1, "future": true, "sites": [{"name": "blog", "folder": "~", "main": {"port": 4000, "extra": 1}}]}
        """
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("sites.json"))
        let site = try XCTUnwrap(makeStore().sites.first)
        XCTAssertEqual(site.name, "blog")
        XCTAssertEqual(site.folder, NSHomeDirectory())
        XCTAssertEqual(site.main.host, "localhost")
        XCTAssertTrue(site.main.isStatic)
    }

    func testRejectsInvalidAndDuplicateNames() throws {
        let store = makeStore()
        try store.upsert(makeSite())
        XCTAssertThrowsError(try store.upsert(makeSite(port: 9000)))
        XCTAssertThrowsError(try store.upsert(makeSite("Bad_Name")))
        XCTAssertThrowsError(try store.upsert(makeSite("-dash")))
        XCTAssertEqual(store.sites.count, 1)
    }

    func testRejectsMissingFolderBadPortAndDuplicateSubdomain() {
        let store = makeStore()
        var site = makeSite()
        site.folder = "/definitely/not/here"
        site.main.port = 0
        site.extras.append(ProcessConfig(label: "Dup", command: "x", port: 7000, subdomain: "api"))
        let fields = Set(store.issues(for: site).filter { $0.severity == .error }.map(\.field))
        XCTAssertTrue(fields.contains(.folder))
        XCTAssertTrue(fields.contains(.port(site.main.id)))
        XCTAssertTrue(fields.contains(.subdomain(site.extras[1].id)))
    }

    func testSharedUpstreamIsWarningNotError() throws {
        let store = makeStore()
        try store.upsert(makeSite())
        let other = makeSite("shop", port: 5474)
        let issues = store.issues(for: other)
        XCTAssertTrue(issues.contains { $0.severity == .warning })
        XCTAssertNoThrow(try store.upsert(other))
    }

    func testDuplicateGetsFreshIdsAndName() throws {
        let store = makeStore()
        let site = try store.upsert(makeSite())
        let copy = try XCTUnwrap(store.duplicate(id: site.id))
        XCTAssertEqual(copy.name, "blog-copy")
        XCTAssertNotEqual(copy.main.id, site.main.id)
        XCTAssertEqual(store.sites.count, 2)
    }

    func testSitesWithoutCommandsLoadAndCommandsRoundTrip() throws {
        let json = """
        {"version": 1, "sites": [{"name": "blog", "folder": "/tmp", "main": {"port": 4000, "command": "make dev"}}]}
        """
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("sites.json"))
        let store = makeStore()
        var site = try XCTUnwrap(store.sites.first)
        XCTAssertEqual(site.commands, [])

        site.commands = [
            SiteCommand(name: "Deploy", command: "make deploy && echo ok", workingDirectory: dir.path, showsLogs: false),
            SiteCommand(name: "Seed", command: "make seed"),
        ]
        try store.upsert(site)
        XCTAssertEqual(makeStore().sites.first?.commands, site.commands)
    }

    func testDuplicateGivesCommandsFreshIds() throws {
        let store = makeStore()
        var site = makeSite()
        site.commands = [SiteCommand(name: "Deploy", command: "make deploy")]
        try store.upsert(site)
        let copy = try XCTUnwrap(store.duplicate(id: site.id))
        XCTAssertEqual(copy.commands.map(\.name), ["Deploy"])
        XCTAssertNotEqual(copy.commands.first?.id, site.commands.first?.id)
    }

    func testRejectsIncompleteAndDuplicateCommands() {
        let store = makeStore()
        var site = makeSite()
        let unnamed = SiteCommand(name: " ", command: "make deploy")
        let empty = SiteCommand(name: "Deploy", command: "  ")
        let lost = SiteCommand(name: "Seed", command: "make seed", workingDirectory: "/definitely/not/here")
        let twin = SiteCommand(name: "Deploy", command: "make deploy")
        site.commands = [unnamed, empty, lost, twin]
        let errors = store.issues(for: site).filter { $0.severity == .error }
        func message(_ field: SiteField) -> String? { errors.first { $0.field == field }?.message }
        XCTAssertEqual(message(.commandName(unnamed.id)), "Name is required")
        XCTAssertEqual(message(.commandLine(empty.id)), "Command is required")
        XCTAssertEqual(message(.commandDirectory(lost.id)), "Folder does not exist")
        XCTAssertEqual(message(.commandName(twin.id)), "Another command is named Deploy")
        XCTAssertNil(message(.commandName(empty.id)), "the first Deploy was flagged as a duplicate")
        XCTAssertThrowsError(try store.upsert(site))
    }

    func testSanitizeLabel() {
        XCTAssertEqual(SiteValidation.sanitizeLabel("My CRM_2!"), "mycrm2")
    }

    func testSiteStatusDerivation() {
        XCTAssertEqual(SiteStatus(states: [.stopped, .stopped]), .stopped)
        XCTAssertEqual(SiteStatus(states: [.running, .running]), .running)
        XCTAssertEqual(SiteStatus(states: [.running, .starting]), .starting)
        XCTAssertEqual(SiteStatus(states: [.running, .exited(code: 1)]), .partial)
        XCTAssertEqual(SiteStatus(states: [.exited(code: 1)]), .partial)
        XCTAssertEqual(SiteStatus(states: [.exited(code: 0)]), .stopped)
        XCTAssertEqual(SiteStatus(states: [.running, .stopped]), .running)
    }
}
