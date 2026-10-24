import Foundation

struct Site: Identifiable, Codable, Hashable {
    var id: UUID = .init()
    var name: String
    var folder: String
    var main: ProcessConfig
    var extras: [ProcessConfig] = []
    var autoStart: Bool = false
    var commands: [SiteCommand] = []

    var isStatic: Bool { main.isStatic }

    /// Main first, then extras in configured order.
    var processes: [ProcessConfig] { [main] + extras }

    func domain(in suffix: DomainSuffix) -> String {
        "\(name).\(suffix.label)"
    }

    /// The main process gets the site's domain, an extra gets one only when it has a subdomain.
    func domain(for process: ProcessConfig, in suffix: DomainSuffix) -> String? {
        if process.id == main.id { return domain(in: suffix) }
        guard let sub = process.subdomain, !sub.isEmpty else { return nil }
        return "\(sub).\(domain(in: suffix))"
    }

    func workingDirectory(for process: ProcessConfig) -> String {
        let dir = process.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? folder
        return (dir as NSString).expandingTildeInPath
    }

    func workingDirectory(for command: SiteCommand) -> String {
        let dir = command.workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? folder
        return (dir as NSString).expandingTildeInPath
    }

    init(id: UUID = .init(), name: String, folder: String, main: ProcessConfig, extras: [ProcessConfig] = [], autoStart: Bool = false, commands: [SiteCommand] = []) {
        self.id = id
        self.name = name
        self.folder = folder
        self.main = main
        self.extras = extras
        self.autoStart = autoStart
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? .init()
        name = try c.decode(String.self, forKey: .name)
        folder = (try c.decode(String.self, forKey: .folder) as NSString).expandingTildeInPath
        main = try c.decode(ProcessConfig.self, forKey: .main)
        extras = try c.decodeIfPresent([ProcessConfig].self, forKey: .extras) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        commands = try c.decodeIfPresent([SiteCommand].self, forKey: .commands) ?? []
    }
}
