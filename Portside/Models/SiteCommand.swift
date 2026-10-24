import Foundation

/// A one-off shell command run on demand from the site's menu, such as a deploy.
struct SiteCommand: Identifiable, Codable, Hashable {
    var id: UUID = .init()
    var name: String
    var command: String
    /// nil or empty runs in the site folder.
    var workingDirectory: String? = nil
    var showsLogs: Bool = true

    init(id: UUID = .init(), name: String, command: String, workingDirectory: String? = nil, showsLogs: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.showsLogs = showsLogs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? .init()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        showsLogs = try c.decodeIfPresent(Bool.self, forKey: .showsLogs) ?? true
    }
}
