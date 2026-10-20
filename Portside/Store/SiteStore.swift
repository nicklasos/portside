import Foundation
import Observation

@MainActor
@Observable
final class SiteStore {
    private(set) var sites: [Site] = []
    private(set) var loadError: String?
    private let persistence: Persistence

    init(persistence: Persistence = .default) {
        self.persistence = persistence
        do {
            sites = try persistence.load()
        } catch {
            loadError = "Could not read \(persistence.fileURL.path): \(error.localizedDescription)"
        }
    }

    func site(id: Site.ID) -> Site? { sites.first { $0.id == id } }

    func issues(for site: Site) -> [ValidationIssue] {
        SiteValidation.issues(for: site, among: sites)
    }

    /// Inserts or replaces by id. Refuses to save a site with blocking validation errors.
    @discardableResult
    func upsert(_ site: Site) throws -> Site {
        let errors = issues(for: site).filter { $0.severity == .error }
        guard errors.isEmpty else { throw StoreError.invalid(errors) }
        if let i = sites.firstIndex(where: { $0.id == site.id }) {
            sites[i] = site
        } else {
            sites.append(site)
        }
        try persist()
        return site
    }

    func delete(id: Site.ID) throws {
        sites.removeAll { $0.id == id }
        try persist()
    }

    func duplicate(id: Site.ID) throws -> Site? {
        guard let original = site(id: id) else { return nil }
        var name = "\(original.name)-copy"
        var n = 2
        while sites.contains(where: { $0.name == name }) { name = "\(original.name)-copy-\(n)"; n += 1 }
        var copy = original
        copy.id = .init()
        copy.name = name
        copy.main.id = .init()
        copy.extras = copy.extras.map { var p = $0; p.id = .init(); return p }
        copy.autoStart = false
        sites.append(copy)
        try persist()
        return copy
    }

    private func persist() throws {
        try persistence.save(sites)
    }
}

enum StoreError: LocalizedError {
    case invalid([ValidationIssue])

    var errorDescription: String? {
        switch self {
        case .invalid(let issues): issues.map(\.message).joined(separator: "\n")
        }
    }
}
