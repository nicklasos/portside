import Darwin
import XCTest
@testable import Portside

final class DNSServerTests: XCTestCase {
    private enum QType: UInt16 { case a = 1, aaaa = 28, mx = 15, any = 255 }

    private func query(_ name: String, _ type: QType, id: UInt16 = 0xBEEF, recursionDesired: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), recursionDesired ? 0x01 : 0x00, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += label.utf8
        }
        bytes.append(0)
        bytes += [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF), 0, 1]
        return bytes
    }

    private let aRecord: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1]
    private let aaaaRecord: [UInt8] = [0xC0, 0x0C, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16] + [UInt8](repeating: 0, count: 15) + [1]

    /// ID, then QR|AA|RD|RA with NOERROR, then counts.
    private func header(answers: UInt8, id: [UInt8] = [0xBE, 0xEF]) -> [UInt8] {
        id + [0x85, 0x80, 0, 1, 0, answers, 0, 0, 0, 0]
    }

    func testAQueryUnderTestAnswersIPv4Loopback() {
        let q = query("blog.test", .a)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), header(answers: 1) + Array(q[12...]) + aRecord)
    }

    func testSelfTestNameGetsPortsideOnlyAddress() {
        let q = query("Portside-Selftest.test", .a)
        let selfTestRecord = Array(aRecord.dropLast(4)) + [127, 0, 0, 53]
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), header(answers: 1) + Array(q[12...]) + selfTestRecord)
    }

    func testAAAAQueryAnswersIPv6Loopback() {
        let q = query("api.blog.test", .aaaa)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), header(answers: 1) + Array(q[12...]) + aaaaRecord)
    }

    func testAnyQueryAnswersBothFamilies() {
        let q = query("blog.test", .any)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), header(answers: 2) + Array(q[12...]) + aRecord + aaaaRecord)
    }

    func testOtherTypesUnderTestAreEmptyNoError() {
        let q = query("blog.test", .mx)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), header(answers: 0) + Array(q[12...]))
    }

    func testUppercaseNameMatchesAndQuestionIsEchoedVerbatim() {
        let q = query("Blog.TEST", .a)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), header(answers: 1) + Array(q[12...]) + aRecord)
    }

    func testNameOutsideTestIsNXDomainWithoutAuthority() {
        let q = query("example.com", .a, id: 0x0102, recursionDesired: false)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test"), [0x01, 0x02, 0x80, 0x83, 0, 1, 0, 0, 0, 0, 0, 0] + Array(q[12...]))
    }

    func testNameThatOnlyContainsTestIsNotInZone() {
        let q = query("test.example", .a)
        XCTAssertEqual(DNSServer.response(to: q, zone: "test")?[3], 0x83)
    }

    func testZoneIsAParameter() {
        let localhost = query("blog.localhost", .a)
        XCTAssertEqual(DNSServer.response(to: localhost, zone: "localhost"), header(answers: 1) + Array(localhost[12...]) + aRecord)
        XCTAssertEqual(DNSServer.response(to: localhost, zone: "test")?[3], 0x83, "outside the test zone")

        let test = query("blog.test", .a)
        XCTAssertEqual(DNSServer.response(to: test, zone: "loc")?[3], 0x83, "outside the loc zone")

        let selfTest = query("portside-selftest.loc", .a)
        XCTAssertEqual(DNSServer.response(to: selfTest, zone: "loc").map { Array($0.suffix(4)) }, [127, 0, 0, 53])
    }

    func testMalformedPacketsAreDropped() {
        let q = query("blog.test", .a)
        XCTAssertNil(DNSServer.response(to: Array(q.prefix(11)), zone: "test"), "shorter than a header")
        XCTAssertNil(DNSServer.response(to: Array(q.prefix(20)), zone: "test"), "label runs past the end")
        XCTAssertNil(DNSServer.response(to: Array(q.dropLast(2)), zone: "test"), "missing QCLASS")

        var response = q
        response[2] |= 0x80
        XCTAssertNil(DNSServer.response(to: response, zone: "test"), "QR set")

        var twoQuestions = q
        twoQuestions[5] = 2
        XCTAssertNil(DNSServer.response(to: twoQuestions, zone: "test"), "QDCOUNT 2")

        let pointer = Array(q.prefix(12)) + [0xC0, 0x0C, 0, 1, 0, 1]
        XCTAssertNil(DNSServer.response(to: pointer, zone: "test"), "compression pointer in question")
    }

    func testServesQueriesOverUDP() throws {
        let server = DNSServer(port: 0, zone: "test")
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let q = query("blog.test", .a)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, q, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, q.count)

        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(fd, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(received, 0, "no reply within 2 s")
        XCTAssertEqual(Array(buffer.prefix(max(received, 0))), header(answers: 1) + Array(q[12...]) + aRecord)
    }

    func testResolverContentCheck() {
        XCTAssertEqual(ResolverInstaller.expectedContents(dnsPort: 35353), "nameserver 127.0.0.1\nport 35353\n")
        XCTAssertEqual(ResolverInstaller.status(contents: nil, dnsPort: 35353), .missing)
        XCTAssertEqual(ResolverInstaller.status(contents: "nameserver 127.0.0.1\nport 35353\n", dnsPort: 35353), .installed)
        XCTAssertEqual(ResolverInstaller.status(contents: "nameserver  127.0.0.1\r\n\nport 35353", dnsPort: 35353), .installed)
        XCTAssertEqual(ResolverInstaller.status(contents: "nameserver 127.0.0.1\n", dnsPort: 35353), .mismatched, "another tool's resolver on port 53")
        XCTAssertEqual(ResolverInstaller.status(contents: "nameserver 127.0.0.1\nport 35354\n", dnsPort: 35353), .mismatched)
    }

    func testResolverInstallScriptWritesExpectedFile() {
        let command = ResolverInstaller.installCommand(suffix: .test, dnsPort: 35353)
        XCTAssertEqual(
            command,
            #"mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 35353\n' > /etc/resolver/test && (dscacheutil -flushcache; killall -HUP mDNSResponder; true)"#
        )
        XCTAssertEqual(
            ResolverInstaller.appleScriptSource(shellCommand: command),
            #"do shell script "mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\\nport 35353\\n' > /etc/resolver/test && (dscacheutil -flushcache; killall -HUP mDNSResponder; true)" with administrator privileges"#
        )
        XCTAssertTrue(ResolverInstaller.installCommand(suffix: .localhost, dnsPort: 35353).contains("> /etc/resolver/localhost &&"))
    }

    /// Runs the uninstall command against a temporary directory: it removes only Portside's exact file.
    func testResolverUninstallRemovesOnlyPortsidesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test")
        let command = ResolverInstaller.uninstallCommand(suffix: .test, dnsPort: 35353)
            .replacingOccurrences(of: "/etc/resolver/test", with: file.path)
            .replacingOccurrences(of: "(dscacheutil -flushcache; killall -HUP mDNSResponder; true)", with: "true")
        func run() -> Int32 {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", command]
            shell.standardError = FileHandle.nullDevice
            try! shell.run()
            shell.waitUntilExit()
            return shell.terminationStatus
        }

        try "nameserver 127.0.0.1\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(run(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "another tool's file stays")

        try "nameserver 127.0.0.1\nport 35354\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(run(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Portside's file for another port stays")

        try ResolverInstaller.expectedContents(dnsPort: 35353).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(run(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLsofFieldParsing() {
        XCTAssertEqual(PortChecker.parseLsofFields("p95298\ncnginx-arm64\nf4\np95299\ncnginx-arm64\n"), PortOwner(pid: 95298, command: "nginx-arm64"))
        XCTAssertNil(PortChecker.parseLsofFields(""))
    }

    func testPortCheckerSeesAListener() throws {
        let server = DNSServer(port: 0, zone: "test")
        try server.start()
        defer { server.stop() }
        XCTAssertFalse(PortChecker.isUDPPortFree(try XCTUnwrap(server.boundPort)))
    }
}
