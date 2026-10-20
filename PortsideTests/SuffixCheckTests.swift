import Darwin
import XCTest
@testable import Portside

final class SuffixCheckTests: XCTestCase {
    private let loopback: [[UInt8]] = [[127, 0, 0, 1], [UInt8](repeating: 0, count: 15) + [1]]
    private let portsideFile = ResolverInstaller.expectedContents(dnsPort: 35353)
    private let herdFile = "nameserver 127.0.0.1\n"

    private func evaluate(_ suffix: DomainSuffix, file: String?, resolves: [[UInt8]]) async -> SuffixUsability {
        await SuffixUsability.evaluate(suffix, resolverContents: file, dnsPort: 35353) { _ in resolves }
    }

    func testSystemResolvedSuffixWorksWithoutSetup() async {
        let usability = await evaluate(.localhost, file: nil, resolves: loopback)
        XCTAssertEqual(usability.strategy, .system)
        XCTAssertEqual(usability.lines, [
            CheckLine(.ok, "Reserved for this computer (RFC 6761)"),
            CheckLine(.ok, "Works without setup. macOS resolves *.localhost to this Mac"),
            CheckLine(.ok, "No /etc/resolver/localhost needed"),
        ])
    }

    func testUnresolvedSuffixNeedsTheResolverFile() async {
        let usability = await evaluate(.test, file: nil, resolves: [])
        XCTAssertEqual(usability.strategy, .portsideDNS)
        XCTAssertEqual(usability.lines[1], CheckLine(.warning, "Needs /etc/resolver/test (one admin prompt)"))
        XCTAssertEqual(usability.lines[2], CheckLine(.ok, "/etc/resolver/test is free to install"))
    }

    func testOnlyAnAllLoopbackAnswerCountsAsSystemResolved() async {
        let usability = await evaluate(.loc, file: nil, resolves: [[127, 0, 0, 1], [93, 184, 216, 34]])
        XCTAssertEqual(usability.strategy, .portsideDNS, "a network that answers unknown names does not count")
    }

    /// Herd's dnsmasq answers `.test` with loopback, but that answer disappears with Herd.
    func testForeignResolverFileIsATakeoverEvenWhenItResolves() async {
        let usability = await evaluate(.test, file: herdFile, resolves: loopback)
        XCTAssertEqual(usability.strategy, .portsideDNS)
        XCTAssertEqual(usability.lines[1], CheckLine(.warning, "Needs /etc/resolver/test (one admin prompt)"))
        XCTAssertEqual(usability.lines[2], CheckLine(
            .warning,
            "/etc/resolver/test belongs to another tool, for example Laravel Herd or Valet. Choosing this takes it over",
            detail: "nameserver 127.0.0.1"
        ))
    }

    func testPortsidesOwnResolverFileIsReady() async {
        let usability = await evaluate(.test, file: portsideFile, resolves: [])
        XCTAssertEqual(usability.lines[1], CheckLine(.ok, "Resolves through Portside's DNS server"))
        XCTAssertEqual(usability.lines[2], CheckLine(.ok, "/etc/resolver/test is Portside's"))
    }

    func testLocalIsOfferedWithItsBonjourWarning() async {
        let usability = await evaluate(.local, file: nil, resolves: [])
        XCTAssertEqual(usability.lines[0].mark, .warning)
        XCTAssertTrue(usability.lines[0].text.hasPrefix("Not recommended. macOS uses .local for Bonjour"))
    }

    // MARK: - End to end

    private func endToEnd(
        _ strategy: ResolutionStrategy, suffix: DomainSuffix = .localhost, resolves: [[UInt8]], proxy: ProxyState = .running,
        port: Int = 8080, fetch: FetchResult = .response(status: 200, body: "portside-ok")
    ) async -> CheckLine {
        let probes = SuffixProbes(lookup: { _ in resolves }, fetch: { _, _ in fetch })
        return await EndToEndCheck.run(suffix: suffix, strategy: strategy, proxyPort: port, proxyState: proxy, probes: probes)
    }

    func testEndToEndPassesWhenNameAndProxyBothAnswer() async {
        let system = await endToEnd(.system, resolves: loopback)
        XCTAssertEqual(system, CheckLine(.ok, "Works end to end: http://portside-selftest.localhost:8080 reached Portside's proxy"))
        let dns = await endToEnd(.portsideDNS, suffix: .test, resolves: [DNSServer.selfTestAddress], port: 80)
        XCTAssertEqual(dns, CheckLine(.ok, "Works end to end: http://portside-selftest.test reached Portside's proxy"))
    }

    func testEndToEndBlamesDNSFirst() async {
        let line = await endToEnd(.portsideDNS, suffix: .test, resolves: [[127, 0, 0, 1]])
        XCTAssertEqual(line, CheckLine(.failure, "DNS: portside-selftest.test does not resolve through Portside's DNS server"), "Herd answers, not Portside")
        let system = await endToEnd(.system, resolves: [])
        XCTAssertEqual(system, CheckLine(.failure, "DNS: macOS does not resolve portside-selftest.localhost to this Mac"))
    }

    func testEndToEndNamesTheProxyPortOwner() async {
        let line = await endToEnd(.system, resolves: loopback, proxy: .portConflict(PortOwner(pid: 95298, command: "nginx")), port: 80)
        XCTAssertEqual(line, CheckLine(.failure, "Proxy: port 80 is used by nginx (pid 95298)"))
    }

    func testEndToEndReportsCaddyDown() async {
        let stopped = await endToEnd(.system, resolves: loopback, proxy: .stopped)
        XCTAssertEqual(stopped, CheckLine(.failure, "Proxy: Caddy is not running"))
        let refused = await endToEnd(.system, resolves: loopback, fetch: .unreachable("Connection refused"))
        XCTAssertEqual(refused, CheckLine(.failure, "Proxy: nothing answered on port 8080. Connection refused"))
        let impostor = await endToEnd(.system, resolves: loopback, fetch: .response(status: 404, body: "nginx"))
        XCTAssertEqual(impostor, CheckLine(.failure, "Proxy: port 8080 answered HTTP 404, not Portside's proxy"))
    }

    // MARK: - Live helpers

    func testLoopbackHTTPSendsTheHostHeaderAndReadsTheReply() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        XCTAssertEqual(listen(listener, 1), 0)
        let port = Int(UInt16(bigEndian: addr.sin_port))

        let served = expectation(description: "served")
        var request = ""
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = recv(client, &buffer, buffer.count, 0)
            request = String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self)
            let reply = Array("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nportside-ok".utf8)
            _ = send(client, reply, reply.count, 0)
            close(client)
            served.fulfill()
        }
        let result = LoopbackHTTP.get(host: "portside-selftest.localhost", port: port)
        wait(for: [served], timeout: 5)
        XCTAssertEqual(result, .response(status: 200, body: "portside-ok"))
        XCTAssertTrue(request.contains("\r\nHost: portside-selftest.localhost\r\n"), request)
    }

    func testLoopbackHTTPReportsAClosedPort() {
        guard case .unreachable = LoopbackHTTP.get(host: "x.localhost", port: 1) else { return XCTFail("port 1 answered") }
    }
}
