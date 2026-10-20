import Foundation

/// What the site editor fills in when the user picks a folder.
///
/// `name`, `port` and `command` hold the values the user has not chosen themselves: the new-site
/// default port, or what an earlier folder filled in. A field still holding one of them, or empty,
/// follows the new folder. `nil` means the field's value is the user's own and stays.
struct FolderAutofill: Equatable {
    var name: String?
    var port: Int?
    var command: String?

    static func newSite(defaultPort: Int) -> FolderAutofill { FolderAutofill(name: nil, port: defaultPort) }

    func apply(folder: String, detected: DetectedPort?, command detectedCommand: DetectedCommand?, to site: inout Site) -> FolderAutofill {
        var next = self
        if site.name.isEmpty || site.name == name {
            let label = SiteValidation.sanitizeLabel(URL(fileURLWithPath: folder).lastPathComponent)
            site.name = label
            next.name = label
        }
        if let detected, site.main.port == 0 || site.main.port == port {
            site.main.port = detected.port
            next.port = detected.port
        }
        if site.main.command.isEmpty || site.main.command == command {
            site.main.command = detectedCommand?.command ?? ""
            next.command = detectedCommand?.command
        }
        return next
    }
}
