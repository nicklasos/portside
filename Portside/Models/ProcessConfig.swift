import Foundation

struct ProcessConfig: Identifiable, Codable, Hashable {
    var id: UUID = .init()
    var label: String
    var command: String
    var host: String = "localhost"
    var port: Int
    var subdomain: String? = nil
    var workingDirectory: String? = nil
    var env: [String: String] = [:]
    /// Pass the browser's `Host` header through instead of rewriting it to the upstream.
    var preserveHost: Bool = false

    var upstream: String { "\(host):\(port)" }
    var isStatic: Bool { command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(id: UUID = .init(), label: String, command: String, host: String = "localhost", port: Int, subdomain: String? = nil, workingDirectory: String? = nil, env: [String: String] = [:], preserveHost: Bool = false) {
        self.id = id
        self.label = label
        self.command = command
        self.host = host
        self.port = port
        self.subdomain = subdomain
        self.workingDirectory = workingDirectory
        self.env = env
        self.preserveHost = preserveHost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? .init()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decode(Int.self, forKey: .port)
        subdomain = try c.decodeIfPresent(String.self, forKey: .subdomain)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        preserveHost = try c.decodeIfPresent(Bool.self, forKey: .preserveHost) ?? false
    }
}
