import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Portside", isDirectory: true)
    }

    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Portside", isDirectory: true)
    }

    static var caddyConfigFile: URL { supportDirectory.appendingPathComponent("caddy.json") }

    /// The Caddy binary embedded next to the app executable.
    static var caddyBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/caddy")
    }
}
