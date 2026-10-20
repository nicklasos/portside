import Foundation
import Observation

/// User preferences backed by `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var proxyPort: Int { didSet { defaults.set(proxyPort, forKey: Keys.proxyPort) } }
    var dnsPort: Int { didSet { defaults.set(dnsPort, forKey: Keys.dnsPort) } }
    var caddyAdminPort: Int { didSet { defaults.set(caddyAdminPort, forKey: Keys.caddyAdminPort) } }
    var notifyOnCrash: Bool { didSet { defaults.set(notifyOnCrash, forKey: Keys.notifyOnCrash) } }
    var mirrorLogsToDisk: Bool { didSet { defaults.set(mirrorLogsToDisk, forKey: Keys.mirrorLogsToDisk) } }
    var domainSuffix: DomainSuffix { didSet { defaults.set(domainSuffix.label, forKey: Keys.domainSuffix) } }
    /// False until the user picks a suffix in onboarding or Settings.
    var hasChosenDomainSuffix: Bool { didSet { defaults.set(hasChosenDomainSuffix, forKey: Keys.hasChosenDomainSuffix) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.proxyPort: 80,
            Keys.dnsPort: 35353,
            Keys.caddyAdminPort: 2019,
            Keys.notifyOnCrash: true,
            Keys.mirrorLogsToDisk: false,
        ])
        proxyPort = defaults.integer(forKey: Keys.proxyPort)
        dnsPort = defaults.integer(forKey: Keys.dnsPort)
        caddyAdminPort = defaults.integer(forKey: Keys.caddyAdminPort)
        notifyOnCrash = defaults.bool(forKey: Keys.notifyOnCrash)
        mirrorLogsToDisk = defaults.bool(forKey: Keys.mirrorLogsToDisk)
        domainSuffix = defaults.string(forKey: Keys.domainSuffix).flatMap(DomainSuffix.stored) ?? .localhost
        hasChosenDomainSuffix = defaults.bool(forKey: Keys.hasChosenDomainSuffix)
    }

    /// `smartcity.localhost` on port 80, `smartcity.localhost:8080` otherwise.
    func url(forDomain domain: String) -> URL {
        URL(string: proxyPort == 80 ? "http://\(domain)" : "http://\(domain):\(proxyPort)")!
    }

    /// Leaves the domain suffix alone: resetting it would move every site to another domain.
    func resetToDefaults() {
        for key in [Keys.proxyPort, Keys.dnsPort, Keys.caddyAdminPort, Keys.notifyOnCrash, Keys.mirrorLogsToDisk] {
            defaults.removeObject(forKey: key)
        }
        proxyPort = defaults.integer(forKey: Keys.proxyPort)
        dnsPort = defaults.integer(forKey: Keys.dnsPort)
        caddyAdminPort = defaults.integer(forKey: Keys.caddyAdminPort)
        notifyOnCrash = defaults.bool(forKey: Keys.notifyOnCrash)
        mirrorLogsToDisk = defaults.bool(forKey: Keys.mirrorLogsToDisk)
    }

    private enum Keys {
        static let proxyPort = "proxyPort"
        static let dnsPort = "dnsPort"
        static let caddyAdminPort = "caddyAdminPort"
        static let notifyOnCrash = "notifyOnCrash"
        static let mirrorLogsToDisk = "mirrorLogsToDisk"
        static let domainSuffix = "domainSuffix"
        static let hasChosenDomainSuffix = "hasChosenDomainSuffix"
    }
}
