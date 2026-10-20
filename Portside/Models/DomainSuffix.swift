import Foundation

/// The top-level label every site lives under, such as `localhost` in `smartcity.localhost`.
/// The only ways to get one are the presets and `custom(_:)`, so a value is always usable.
struct DomainSuffix: Hashable, Codable {
    let label: String

    private init(label: String) {
        self.label = label
    }

    static let localhost = DomainSuffix(label: "localhost")
    static let test = DomainSuffix(label: "test")
    static let loc = DomainSuffix(label: "loc")
    static let local = DomainSuffix(label: "local")
    static let presets: [DomainSuffix] = [.localhost, .test, .loc, .local]

    var display: String { ".\(label)" }
    var isPreset: Bool { Self.presets.contains(self) }

    /// What the name itself means, before anything is probed.
    var nameCheck: CheckLine {
        switch label {
        case "localhost":
            CheckLine(.ok, "Reserved for this computer (RFC 6761)")
        case "test":
            CheckLine(.ok, "Reserved for testing (RFC 6761), never a public TLD")
        case "local":
            CheckLine(.warning, "Not recommended. macOS uses .local for Bonjour (AirDrop, printers, YourMac.local), so lookups go over multicast and can be slow or collide")
        case _ where Self.unreservedLocalNames.contains(label):
            CheckLine(.warning, "Not reserved. It may collide with names on your network")
        default:
            CheckLine(.ok, "Valid name, not a public TLD")
        }
    }

    /// Validates a typed suffix. A leading dot and uppercase letters are accepted.
    static func custom(_ raw: String) -> Result<DomainSuffix, Rejection> {
        var label = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if label.hasPrefix(".") { label.removeFirst() }
        if label.isEmpty { return .failure(.init(reason: "Type a suffix, such as loc")) }
        if let preset = presets.first(where: { $0.label == label }) {
            return .failure(.init(reason: "Choose the \(preset.display) option above"))
        }
        guard SiteValidation.isValidLabel(label) else {
            return .failure(.init(reason: "Use one label of lowercase letters, digits and dashes"))
        }
        // A numeric last label makes browsers parse the host as an IPv4 address.
        if label.allSatisfy(\.isNumber) { return .failure(.init(reason: "A suffix cannot be only digits")) }
        if hstsPreloaded.contains(label) {
            return .failure(.init(reason: ".\(label) is a real TLD that forces HTTPS in browsers"))
        }
        if publicTLDs.contains(label) {
            return .failure(.init(reason: ".\(label) is a real public TLD. Its websites would stop working"))
        }
        return .success(DomainSuffix(label: label))
    }

    struct Rejection: Error, Equatable {
        var reason: String
    }

    /// Reads a saved label back. Presets come first because `custom(_:)` rejects their labels.
    static func stored(_ label: String) -> DomainSuffix? {
        presets.first { $0.label == label } ?? (try? custom(label).get())
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let suffix = Self.stored(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a usable domain suffix")
        }
        self = suffix
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }

    /// Whole TLDs on the HSTS preload list: browsers refuse plain HTTP for every name under them.
    private static let hstsPreloaded: Set<String> = [
        "app", "bank", "boo", "channel", "dad", "day", "dev", "esq", "foo", "gle", "google",
        "insurance", "meme", "mov", "new", "nexus", "page", "phd", "prof", "rsvp", "zip",
    ]

    private static let publicTLDs: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "int", "info", "biz", "io", "ai", "co", "me",
        "us", "uk", "de", "fr", "eu", "ca", "au", "ru", "cn", "jp", "in", "br", "nl", "it", "es",
        "ch", "se", "no", "pl", "ua", "tv", "cc", "ly", "sh", "gg", "to", "fm", "xyz", "site",
        "online", "tech", "store", "shop", "blog", "cloud", "design", "studio", "art", "club",
        "live", "host", "website", "space", "fun", "top", "work", "run", "codes", "tools", "build",
    ]

    private static let unreservedLocalNames: Set<String> = [
        "loc", "lan", "internal", "home", "corp", "private", "intranet", "localdomain",
    ]
}
