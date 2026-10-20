import Foundation

enum ResolverStatus: Equatable {
    case installed, missing, mismatched
}

enum ResolverInstallError: Error, Equatable {
    case cancelled
    case failed(String)
}

/// Owns `/etc/resolver/test`, which sends macOS's `.test` lookups to Portside's DNS server.
enum ResolverInstaller {
    static let resolverFile = URL(fileURLWithPath: "/etc/resolver/test")
    static let selfTestHost = "portside-selftest.test"

    static func expectedContents(dnsPort: Int) -> String {
        "nameserver 127.0.0.1\nport \(dnsPort)\n"
    }

    static func status(dnsPort: Int) -> ResolverStatus {
        status(contents: try? String(contentsOf: resolverFile, encoding: .utf8), dnsPort: dnsPort)
    }

    /// Compares directives, not bytes, so a hand-edited file with extra whitespace still counts.
    static func status(contents: String?, dnsPort: Int) -> ResolverStatus {
        guard let contents else { return .missing }
        return directives(contents) == directives(expectedContents(dnsPort: dnsPort)) ? .installed : .mismatched
    }

    /// Prompts for an administrator password, writes the resolver file and flushes the DNS caches.
    /// Runs NSAppleScript, so call it from the main thread.
    static func install(dnsPort: Int) throws {
        guard let script = NSAppleScript(source: appleScriptSource(dnsPort: dnsPort)) else {
            throw ResolverInstallError.failed("Could not compile the install script")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 {
            throw ResolverInstallError.cancelled
        }
        throw ResolverInstallError.failed(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
    }

    static func shellCommand(dnsPort: Int) -> String {
        let body = expectedContents(dnsPort: dnsPort).replacingOccurrences(of: "\n", with: "\\n")
        return "mkdir -p /etc/resolver && printf '\(body)' > \(resolverFile.path) && (dscacheutil -flushcache; killall -HUP mDNSResponder; true)"
    }

    static func appleScriptSource(dnsPort: Int) -> String {
        let escaped = shellCommand(dnsPort: dnsPort)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// True when the system resolver sends `portside-selftest.test` to Portside's own DNS server,
    /// which alone answers it with `DNSServer.selfTestAddress`.
    static func selfTest() async -> Bool {
        await Task.detached { resolvesToPortside(selfTestHost) }.value
    }

    private static func resolvesToPortside(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let addr = info.pointee.ai_addr, isSelfTestAddress(addr) { return true }
            cursor = info.pointee.ai_next
        }
        return false
    }

    private static func isSelfTestAddress(_ addr: UnsafeMutablePointer<sockaddr>) -> Bool {
        guard Int32(addr.pointee.sa_family) == AF_INET else { return false }
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin_addr.s_addr) { $0.elementsEqual(DNSServer.selfTestAddress) }
        }
    }

    private static func directives(_ contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
