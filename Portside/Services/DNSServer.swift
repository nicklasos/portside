import Foundation
import NIOCore
import NIOPosix

/// Answers every name under one zone, such as `test`, with loopback addresses, so
/// `/etc/resolver/<zone>` can point at it.
final class DNSServer {
    let port: Int
    let zone: String
    /// The port actually bound; differs from `port` only when `port` is 0.
    private(set) var boundPort: Int?

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(port: Int, zone: String) {
        self.port = port
        self.zone = zone.lowercased()
    }

    deinit {
        stop()
    }

    func start() throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let zone = zone
        do {
            let channel = try DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(QueryHandler(zone: zone))
                    }
                }
                .bind(host: "127.0.0.1", port: port)
                .wait()
            self.group = group
            self.channel = channel
            boundPort = channel.localAddress?.port
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
        boundPort = nil
    }

    // MARK: - Wire format

    static let ttl: UInt32 = 60

    private enum RecordType {
        static let a: UInt16 = 1
        static let aaaa: UInt16 = 28
        static let any: UInt16 = 255
    }

    private enum RecordClass {
        static let internet: UInt16 = 1
        static let any: UInt16 = 255
    }

    private static let loopback: [UInt16: [UInt8]] = [
        RecordType.a: [127, 0, 0, 1],
        RecordType.aaaa: [UInt8](repeating: 0, count: 15) + [1],
    ]

    /// Still loopback, but no other resolver (Herd, Valet, dnsmasq) answers with it,
    /// so the self-test can tell Portside's resolver apart from theirs.
    static let selfTestAddress: [UInt8] = [127, 0, 0, 53]

    /// Builds the reply for one raw DNS query, or `nil` when the packet should be dropped.
    static func response(to query: [UInt8], zone: String) -> [UInt8]? {
        guard query.count >= 12 else { return nil }
        let flags = u16(query, 2)
        let isResponse = flags & 0x8000 != 0
        let opcode = (flags >> 11) & 0xF
        guard !isResponse, opcode == 0, u16(query, 4) == 1 else { return nil }

        var offset = 12
        var labels: [String] = []
        while true {
            guard offset < query.count else { return nil }
            let length = Int(query[offset])
            offset += 1
            if length == 0 { break }
            // Lengths above 63 are compression pointers or reserved; neither is valid in a question.
            guard length <= 63, offset + length <= query.count else { return nil }
            labels.append(String(decoding: query[offset..<offset + length], as: UTF8.self).lowercased())
            offset += length
        }
        guard offset - 12 <= 255, offset + 4 <= query.count else { return nil }
        let qtype = u16(query, offset)
        let qclass = u16(query, offset + 2)
        let question = query[12..<offset + 4]

        let inZone = labels.last == zone
        let isSelfTest = labels.joined(separator: ".") == ResolverInstaller.selfTestHost(zone: zone)
        var answerTypes: [UInt16] = []
        if inZone, qclass == RecordClass.internet || qclass == RecordClass.any {
            answerTypes = qtype == RecordType.any ? [RecordType.a, RecordType.aaaa] : [qtype].filter { loopback[$0] != nil }
        }

        let recursionDesired = flags & 0x0100
        var replyFlags: UInt16 = 0x8000 | recursionDesired | 0x0080
        replyFlags |= inZone ? 0x0400 : 3

        var out: [UInt8] = []
        out += query[0..<2]
        out += be(replyFlags)
        out += be(1) + be(UInt16(answerTypes.count)) + be(0) + be(0)
        out += question
        for type in answerTypes {
            let rdata = isSelfTest && type == RecordType.a ? selfTestAddress : loopback[type]!
            out += [0xC0, 0x0C]
            out += be(type) + be(RecordClass.internet)
            out += be(UInt16(ttl >> 16)) + be(UInt16(ttl & 0xFFFF))
            out += be(UInt16(rdata.count)) + rdata
        }
        return out
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func be(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}

private final class QueryHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let zone: String

    init(zone: String) {
        self.zone = zone
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard let reply = DNSServer.response(to: Array(envelope.data.readableBytesView), zone: zone) else { return }
        let buffer = context.channel.allocator.buffer(bytes: reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer)), promise: nil)
    }

    // A failed send to one client must not close the socket for everyone else.
    func errorCaught(context: ChannelHandlerContext, error: Error) {}
}
