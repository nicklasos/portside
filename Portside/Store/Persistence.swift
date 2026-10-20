import Foundation

struct SitesFile: Codable {
    var version: Int = 1
    var sites: [Site]
}

struct Persistence {
    var fileURL: URL

    static let `default` = Persistence(fileURL: AppPaths.supportDirectory.appendingPathComponent("sites.json"))

    func load() throws -> [Site] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SitesFile.self, from: data).sites
    }

    /// Writes `<file>.tmp` then renames it over the target, so a crash never leaves a half-written file.
    func save(_ sites: [Site]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SitesFile(sites: sites))
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if rename(tmp.path, fileURL.path) != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
    }
}
