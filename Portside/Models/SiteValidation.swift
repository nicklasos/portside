import Foundation

enum SiteField: Hashable {
    case name
    case folder
    case port(ProcessConfig.ID)
    case subdomain(ProcessConfig.ID)
    case workingDirectory(ProcessConfig.ID)
    case commandName(SiteCommand.ID)
    case commandLine(SiteCommand.ID)
    case commandDirectory(SiteCommand.ID)

    /// Fields that live on the editor's Commands tab.
    var isCommand: Bool {
        switch self {
        case .commandName, .commandLine, .commandDirectory: true
        case .name, .folder, .port, .subdomain, .workingDirectory: false
        }
    }
}

struct ValidationIssue: Hashable {
    enum Severity { case error, warning }
    var field: SiteField
    var message: String
    var severity: Severity = .error
}

enum SiteValidation {
    static let labelPattern = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/

    static func isValidLabel(_ s: String) -> Bool {
        s.wholeMatch(of: labelPattern) != nil
    }

    /// Lowercases and strips anything outside `[a-z0-9-]`, for as-you-type sanitizing.
    static func sanitizeLabel(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }.map(Character.init))
    }

    static func issues(for site: Site, among all: [Site], fileManager: FileManager = .default) -> [ValidationIssue] {
        var out: [ValidationIssue] = []

        if site.name.isEmpty {
            out.append(.init(field: .name, message: "Name is required"))
        } else if !isValidLabel(site.name) {
            out.append(.init(field: .name, message: "Use lowercase letters, digits and dashes"))
        } else if site.name == "portside-selftest" {
            out.append(.init(field: .name, message: "This name is reserved for Portside's self-test"))
        } else if all.contains(where: { $0.id != site.id && $0.name == site.name }) {
            out.append(.init(field: .name, message: "Another site is already named \(site.name)"))
        }

        if site.folder.isEmpty {
            out.append(.init(field: .folder, message: "Folder is required"))
        } else if !isDirectory((site.folder as NSString).expandingTildeInPath, fileManager) {
            out.append(.init(field: .folder, message: "Folder does not exist"))
        }

        var seenSubdomains = Set<String>()
        for p in site.processes {
            if !(1...65535).contains(p.port) {
                out.append(.init(field: .port(p.id), message: "Port must be 1–65535"))
            }
            if p.id != site.main.id, let sub = p.subdomain, !sub.isEmpty {
                if !isValidLabel(sub) {
                    out.append(.init(field: .subdomain(p.id), message: "Use lowercase letters, digits and dashes"))
                } else if !seenSubdomains.insert(sub).inserted {
                    out.append(.init(field: .subdomain(p.id), message: "Subdomain used twice"))
                }
            }
            if let wd = p.workingDirectory, !wd.isEmpty, !isDirectory((wd as NSString).expandingTildeInPath, fileManager) {
                out.append(.init(field: .workingDirectory(p.id), message: "Folder does not exist"))
            }
        }

        var seenCommandNames = Set<String>()
        for c in site.commands {
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(.init(field: .commandName(c.id), message: "Name is required"))
            } else if !seenCommandNames.insert(c.name).inserted {
                out.append(.init(field: .commandName(c.id), message: "Another command is named \(c.name)"))
            }
            if c.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.init(field: .commandLine(c.id), message: "Command is required"))
            }
            if let wd = c.workingDirectory, !wd.isEmpty, !isDirectory((wd as NSString).expandingTildeInPath, fileManager) {
                out.append(.init(field: .commandDirectory(c.id), message: "Folder does not exist"))
            }
        }

        let others = all.filter { $0.id != site.id }.flatMap { s in s.processes.filter { !$0.isStatic }.map { (s.name, $0) } }
        var seenUpstreams = [String: String]()
        for p in site.processes where !p.isStatic {
            if let owner = seenUpstreams[p.upstream] ?? others.first(where: { $0.1.upstream == p.upstream })?.0 {
                out.append(.init(field: .port(p.id), message: "\(p.upstream) is also used by \(owner)", severity: .warning))
            }
            seenUpstreams[p.upstream] = seenUpstreams[p.upstream] ?? site.name
        }
        return out
    }

    private static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
