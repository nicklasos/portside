import Foundation

struct PortOwner: Equatable {
    var pid: Int32
    var command: String
}

enum PortChecker {
    /// Probes the wildcard address on both stacks, as Caddy's `:<port>` listener does.
    /// macOS lets unprivileged processes bind ports below 1024 only on the wildcard address,
    /// so probing 127.0.0.1 would report :80 as busy even when it is free.
    ///
    /// A strict bind fails both for a real listener and for TIME_WAIT leftovers. Go binds with
    /// SO_REUSEADDR, which would let Caddy start while a same-user server on 127.0.0.1 silently
    /// shadows it, so a failed strict bind counts as busy unless only TIME_WAIT sockets remain:
    /// the SO_REUSEADDR bind succeeds and nobody is listening.
    static func isTCPPortFree(_ port: Int) -> Bool {
        if canBindTCP(port, reuseAddress: false) { return true }
        return canBindTCP(port, reuseAddress: true) && owner(ofTCPPort: port) == nil
    }

    /// Probes 127.0.0.1, the address `DNSServer` binds.
    static func isUDPPortFree(_ port: Int) -> Bool {
        canBind(family: AF_INET, type: SOCK_DGRAM, port: port, loopback: true, reuseAddress: false)
    }

    static func owner(ofTCPPort port: Int) -> PortOwner? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "+c", "0", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLsofFields(String(decoding: data, as: UTF8.self))
    }

    /// Parses `lsof -F pc` output and returns the first process listed.
    static func parseLsofFields(_ output: String) -> PortOwner? {
        var pid: Int32?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst())
            case "c": if let pid { return PortOwner(pid: pid, command: String(line.dropFirst())) }
            default: break
            }
        }
        return nil
    }

    private static func canBindTCP(_ port: Int, reuseAddress: Bool) -> Bool {
        canBind(family: AF_INET, type: SOCK_STREAM, port: port, loopback: false, reuseAddress: reuseAddress)
            && canBind(family: AF_INET6, type: SOCK_STREAM, port: port, loopback: false, reuseAddress: reuseAddress)
    }

    private static func canBind(family: Int32, type: Int32, port: Int, loopback: Bool, reuseAddress: Bool) -> Bool {
        guard (0...65535).contains(port) else { return false }
        let fd = socket(family, type, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        if reuseAddress {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            addr.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = loopback ? UInt32(0x7F00_0001).bigEndian : INADDR_ANY
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
