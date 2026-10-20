import Darwin
import Foundation

/// How names under the chosen suffix reach the proxy on loopback.
enum ResolutionStrategy: Equatable {
    /// macOS already answers with loopback, as it does for `.localhost` on recent versions.
    /// Portside runs no DNS server and needs no resolver file.
    case system
    /// Portside's DNS server answers, and `/etc/resolver/<suffix>` must point macOS at it.
    case portsideDNS

    /// Asks the system resolver for a random name under the suffix. Only an all-loopback answer
    /// counts, so a network that resolves unknown names to a search page does not pass.
    static func detect(_ suffix: DomainSuffix, resolverDirectory: URL = ResolverInstaller.directory) async -> ResolutionStrategy {
        // With a resolver file in place, a loopback answer comes from whichever tool owns that
        // file (Herd's dnsmasq for `.test`), not from macOS, and would vanish with that tool.
        if FileManager.default.fileExists(atPath: ResolverInstaller.resolverFile(for: suffix, in: resolverDirectory).path) {
            return .portsideDNS
        }
        let addresses = await SystemResolver.addresses(of: "portside-probe-\(UUID().uuidString.lowercased()).\(suffix.label)")
        return !addresses.isEmpty && addresses.allSatisfy(SystemResolver.isLoopback) ? .system : .portsideDNS
    }
}

/// `getaddrinfo`, the lookup path browsers and command-line tools use.
enum SystemResolver {
    /// Raw address bytes: 4 for IPv4, 16 for IPv6. Empty when the name does not resolve.
    static func addresses(of host: String) async -> [[UInt8]] {
        await Task.detached { lookup(host) }.value
    }

    static func isLoopback(_ address: [UInt8]) -> Bool {
        address.count == 4 ? address[0] == 127 : address == [UInt8](repeating: 0, count: 15) + [1]
    }

    private static func lookup(_ host: String) -> [[UInt8]] {
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
