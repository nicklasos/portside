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
    }

    /// `smartcity.test` on port 80, `smartcity.test:8080` otherwise.
    func url(forDomain domain: String) -> URL {
        URL(string: proxyPort == 80 ? "http://\(domain)" : "http://\(domain):\(proxyPort)")!
    }

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
    }
}
