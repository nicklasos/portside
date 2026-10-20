import Foundation

enum ResolverStatus: Equatable {
    case installed, missing, mismatched
}

enum ResolverInstallError: Error, Equatable {
    case cancelled
    case failed(String)
}

/// Owns `/etc/resolver/<suffix>`, which sends macOS's lookups under that suffix to Portside's DNS server.
enum ResolverInstaller {
    static let directory = URL(fileURLWithPath: "/etc/resolver")

    static func resolverFile(for suffix: DomainSuffix, in directory: URL = directory) -> URL {
        directory.appendingPathComponent(suffix.label)
    }

    static func selfTestHost(zone: String) -> String {
        "portside-selftest.\(zone)"
    }

    static func expectedContents(dnsPort: Int) -> String {
        "nameserver 127.0.0.1\nport \(dnsPort)\n"
    }

    /// Compares directives, not bytes, so a hand-edited file with extra whitespace still counts.
    static func status(contents: String?, dnsPort: Int) -> ResolverStatus {
        guard let contents else { return .missing }
        return directives(contents) == directives(expectedContents(dnsPort: dnsPort)) ? .installed : .mismatched
    }

    /// Prompts for an administrator password, writes the resolver file and flushes the DNS caches.
    /// Runs NSAppleScript, so call it from the main thread.
    static func install(suffix: DomainSuffix, dnsPort: Int) throws {
        try runPrivileged(installCommand(suffix: suffix, dnsPort: dnsPort))
    }

    /// Removes the resolver file only while it still holds exactly what Portside writes, so another
    /// tool's file is never deleted. The check runs inside the privileged command, next to the `rm`.
    static func uninstall(suffix: DomainSuffix, dnsPort: Int) throws {
        try runPrivileged(uninstallCommand(suffix: suffix, dnsPort: dnsPort))
    }

    static func installCommand(suffix: DomainSuffix, dnsPort: Int) -> String {
        "mkdir -p \(directory.path) && printf '\(printfBody(dnsPort))' > \(resolverFile(for: suffix).path) && \(flushCaches)"
    }

    static func uninstallCommand(suffix: DomainSuffix, dnsPort: Int) -> String {
        let file = resolverFile(for: suffix).path
        return "if [ \"$(cat \(file))\" = \"$(printf '\(printfBody(dnsPort))')\" ]; then rm \(file) && \(flushCaches); else echo 'The file no longer holds the Portside resolver, so it was left in place.' >&2; exit 1; fi"
    }

    static func appleScriptSource(shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// True when the system resolver sends `portside-selftest.<suffix>` to Portside's own DNS server,
    /// which alone answers it with `DNSServer.selfTestAddress`.
    static func selfTest(suffix: DomainSuffix) async -> Bool {
        await SystemResolver.addresses(of: selfTestHost(zone: suffix.label)).contains(DNSServer.selfTestAddress)
    }

    private static let flushCaches = "(dscacheutil -flushcache; killall -HUP mDNSResponder; true)"

    private static func printfBody(_ dnsPort: Int) -> String {
        expectedContents(dnsPort: dnsPort).replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func runPrivileged(_ shellCommand: String) throws {
        guard let script = NSAppleScript(source: appleScriptSource(shellCommand: shellCommand)) else {
            throw ResolverInstallError.failed("Could not compile the admin script")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 {
            throw ResolverInstallError.cancelled
        }
        throw ResolverInstallError.failed(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
    }

    private static func directives(_ contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
