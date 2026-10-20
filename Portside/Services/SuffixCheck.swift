import Darwin
import Foundation

/// One fact about a suffix, shown as ✓, ⚠ or ✗.
struct CheckLine: Equatable {
    enum Mark { case ok, warning, failure }

    var mark: Mark
    var text: String
    /// Extra text shown verbatim, such as another tool's resolver file.
    var detail: String?

    init(_ mark: Mark, _ text: String, detail: String? = nil) {
        self.mark = mark
        self.text = text
        self.detail = detail
    }
}

/// How names under the chosen suffix reach the proxy on loopback.
enum ResolutionStrategy: Equatable {
    /// macOS already answers with loopback, as it does for `.localhost` on recent versions.
    /// Portside runs no DNS server and needs no resolver file.
    case system
    /// Portside's DNS server answers, and `/etc/resolver/<suffix>` must point macOS at it.
    case portsideDNS
}

enum FetchResult: Equatable {
    case response(status: Int, body: String)
    case unreachable(String)
}

/// The side effects the checks need, injected so tests can script them.
struct SuffixProbes: Sendable {
    /// Resolves a name the way browsers do. Raw address bytes, 4 for IPv4 and 16 for IPv6.
    var lookup: @Sendable (String) async -> [[UInt8]]
    /// Sends `GET /` with the given Host header to the proxy port on 127.0.0.1.
    var fetch: @Sendable (_ host: String, _ port: Int) async -> FetchResult

    static let live = SuffixProbes(
        lookup: { host in await Task.detached { SystemResolver.lookup(host) }.value },
        fetch: { host, port in await Task.detached { LoopbackHTTP.get(host: host, port: port) }.value }
    )
}

/// What Portside can tell about a suffix on this Mac before the user commits to it.
struct SuffixUsability: Equatable {
    var strategy: ResolutionStrategy
    var lines: [CheckLine]

    /// A resolver file decides the strategy on its own: with one in place, a loopback answer comes
    /// from whichever tool owns it (Herd's dnsmasq for `.test`) and would vanish with that tool.
    /// Otherwise a random name is looked up, and only an all-loopback answer counts, so a network
    /// that resolves unknown names to a search page does not pass.
    static func evaluate(_ suffix: DomainSuffix, resolverContents: String?, dnsPort: Int, lookup: (String) async -> [[UInt8]]) async -> SuffixUsability {
        let file = ResolverInstaller.resolverFile(for: suffix).path
        let fileStatus = ResolverInstaller.status(contents: resolverContents, dnsPort: dnsPort)
        let strategy: ResolutionStrategy
        if resolverContents != nil {
            strategy = .portsideDNS
        } else {
            let addresses = await lookup("portside-probe-\(UUID().uuidString.lowercased()).\(suffix.label)")
            strategy = !addresses.isEmpty && addresses.allSatisfy(SystemResolver.isLoopback) ? .system : .portsideDNS
        }

        let resolution: CheckLine = switch (strategy, fileStatus) {
        case (.system, _): CheckLine(.ok, "Works without setup. macOS resolves *\(suffix.display) to this Mac")
        case (.portsideDNS, .installed): CheckLine(.ok, "Resolves through Portside's DNS server")
        case (.portsideDNS, _): CheckLine(.warning, "Needs \(file) (one admin prompt)")
        }
        let resolverFile: CheckLine = switch fileStatus {
        case .missing: CheckLine(.ok, strategy == .system ? "No \(file) needed" : "\(file) is free to install")
        case .installed: CheckLine(.ok, "\(file) is Portside's")
        case .mismatched: CheckLine(.warning, "\(file) belongs to another tool, for example Laravel Herd or Valet. Choosing this takes it over", detail: resolverContents?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return SuffixUsability(strategy: strategy, lines: [suffix.nameCheck, resolution, resolverFile])
    }
}

/// Proves a browser would reach Portside: the self-test name resolves the way the strategy says,
/// and the proxy answers it with Portside's marker. Reports the first step that fails.
enum EndToEndCheck {
    static let marker = "portside-ok"

    static func run(suffix: DomainSuffix, strategy: ResolutionStrategy, proxyPort: Int, proxyState: ProxyState, probes: SuffixProbes) async -> CheckLine {
        let host = ResolverInstaller.selfTestHost(zone: suffix.label)
        let addresses = await probes.lookup(host)
        switch strategy {
        case .portsideDNS where !addresses.contains(DNSServer.selfTestAddress):
            return CheckLine(.failure, "DNS: \(host) does not resolve through Portside's DNS server")
        case .system where addresses.isEmpty || !addresses.allSatisfy(SystemResolver.isLoopback):
            return CheckLine(.failure, "DNS: macOS does not resolve \(host) to this Mac")
        case .portsideDNS, .system:
            break
        }
        switch proxyState {
        case .portConflict(let owner):
            return CheckLine(.failure, "Proxy: port \(proxyPort) is used by \(owner.map { "\($0.command) (pid \($0.pid))" } ?? "another app")")
        case .failed(let reason):
            return CheckLine(.failure, "Proxy: Caddy failed. \(reason)")
        case .stopped, .starting:
            return CheckLine(.failure, "Proxy: Caddy is not running")
        case .running:
            break
        }
        // 127.0.0.53, the self-test answer, is not routable on macOS, so the request goes to
        // 127.0.0.1 with the self-test name as Host, as a browser's would after resolving it.
        switch await probes.fetch(host, proxyPort) {
        case .response(200, let body) where body.trimmingCharacters(in: .whitespacesAndNewlines) == marker:
            return CheckLine(.ok, "Works end to end: http://\(host)\(proxyPort == 80 ? "" : ":\(proxyPort)") reached Portside's proxy")
        case .response(let status, _):
            return CheckLine(.failure, "Proxy: port \(proxyPort) answered HTTP \(status), not Portside's proxy")
        case .unreachable(let reason):
            return CheckLine(.failure, "Proxy: nothing answered on port \(proxyPort). \(reason)")
        }
    }
}

/// `getaddrinfo`, the lookup path browsers and command-line tools use.
enum SystemResolver {
    static func isLoopback(_ address: [UInt8]) -> Bool {
        address.count == 4 ? address[0] == 127 : address == [UInt8](repeating: 0, count: 15) + [1]
    }

    static func lookup(_ host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var out: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let addr = info.pointee.ai_addr {
                switch Int32(addr.pointee.sa_family) {
                case AF_INET:
                    addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { out.append(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }) }
                case AF_INET6:
                    addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { out.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }) }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        return out
    }
}

/// A plain HTTP/1.1 GET over a socket. URLSession treats `Host` as a reserved header.
enum LoopbackHTTP {
    static func get(host: String, port: Int, timeoutSeconds: Int = 3) -> FetchResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable(String(cString: strerror(errno))) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return .unreachable(String(cString: strerror(errno))) }

        let request = Array("GET / HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Portside\r\nConnection: close\r\n\r\n".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return .unreachable(String(cString: strerror(errno))) }

        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 65536 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            response += buffer[0..<n]
        }
        let text = String(decoding: response, as: UTF8.self)
        guard let statusLine = text.split(separator: "\r\n", maxSplits: 1).first,
              let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            return .unreachable(response.isEmpty ? "No response" : "Not an HTTP response")
        }
        let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return .response(status: status, body: body)
    }
}
