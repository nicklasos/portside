import AppKit
import Observation

enum EditorTarget: Codable, Hashable {
    case new
    case edit(Site.ID)
}

enum AppWindow: Hashable {
    case editor(EditorTarget)
    case logs(Site.ID)
    case resolverSetup
    case settings
}

enum DNSState: Equatable {
    case stopped
    case running(port: Int)
    case portInUse(port: Int)
    case failed(String)
}

/// The menu bar glyph: filled while anything runs, with a red badge while something crashed.
struct MenuBarStatus: Equatable {
    var isActive: Bool
    var needsAttention: Bool
}

/// Owns every service and exposes the intents the UI calls. Views read state from here for
/// display and never call services for side effects.
@MainActor
@Observable
final class PortsideController {
    struct Configuration {
        var defaults: UserDefaults
        var supportDirectory: URL
        var logsDirectory: URL
        /// False for the unit-test host: no servers, no notifications, no updater.
        var isLive: Bool

        static let live = Configuration(defaults: .standard, supportDirectory: AppPaths.supportDirectory, logsDirectory: AppPaths.logsDirectory, isLive: true)

        static func isolated(in directory: URL) -> Configuration {
            Configuration(
                defaults: UserDefaults(suiteName: "portside-\(UUID().uuidString)")!,
                supportDirectory: directory.appendingPathComponent("support", isDirectory: true),
                logsDirectory: directory.appendingPathComponent("logs", isDirectory: true),
                isLive: false
            )
        }

        static var forCurrentProcess: Configuration {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return .live }
            return .isolated(in: FileManager.default.temporaryDirectory.appendingPathComponent("portside-host-\(UUID().uuidString)"))
        }
    }

    let settings: AppSettings
    let store: SiteStore
    let processes: ProcessManager
    let proxy: ProxyManager
    let updater: UpdaterService
    let configuration: Configuration

    private(set) var dnsState: DNSState = .stopped
    private(set) var resolverStatus: ResolverStatus = .missing
    /// What `/etc/resolver/test` holds now, shown when another tool owns `.test`.
    private(set) var resolverContents: String?
    /// nil until the self-test has run.
    private(set) var resolverSelfTest: Bool?
    private(set) var resolverError: String?
    private(set) var isInstallingResolver = false

    @ObservationIgnored private var dns: DNSServer?
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var didBootstrap = false
    /// Installed by a view that can open SwiftUI scenes. Requests made before that are queued.
    @ObservationIgnored var windowRouter: ((AppWindow) -> Void)? {
        didSet {
            guard let windowRouter else { return }
            pendingWindows.forEach(windowRouter)
            pendingWindows = []
        }
    }
    @ObservationIgnored private var pendingWindows: [AppWindow] = []

    private static let dismissedResolverKey = "resolverPromptDismissedContents"

    init(configuration: Configuration = .forCurrentProcess) {
        self.configuration = configuration
        settings = AppSettings(defaults: configuration.defaults)
        store = SiteStore(persistence: Persistence(fileURL: configuration.supportDirectory.appendingPathComponent("sites.json")))
        processes = ProcessManager(settings: settings, pidFile: configuration.supportDirectory.appendingPathComponent("pids.json"))
        proxy = ProxyManager(settings: settings, supportDirectory: configuration.supportDirectory, logsDirectory: configuration.logsDirectory)
        updater = UpdaterService(start: configuration.isLive)

        processes.onUnexpectedExit = { [weak self] site, process, code in
            self?.processExitedUnexpectedly(site: site, process: process, code: code)
        }
        notifier.onShowLogs = { [weak self] id in self?.show(.logs(id)) }
    }

    // MARK: - Derived state

    var menuBarStatus: MenuBarStatus {
        let statuses = store.sites.map { processes.status(of: $0) }
        return MenuBarStatus(
            isActive: statuses.contains { $0 != .stopped },
            needsAttention: statuses.contains(.partial)
        )
    }

    func status(of site: Site) -> SiteStatus {
        processes.status(of: site)
    }

    /// Whether the row's primary button should stop rather than start.
    func isAnyProcessAlive(_ site: Site) -> Bool {
        site.processes.contains { processes.state(of: $0.id).isAlive }
    }

    func url(for site: Site, process: ProcessConfig? = nil) -> URL? {
        site.domain(for: process ?? site.main).map(settings.url(forDomain:))
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard configuration.isLive, !didBootstrap else { return }
        didBootstrap = true
        startDNS()
        refreshResolverStatus()
        if shouldPromptForResolver { show(.resolverSetup) }
        notifier.activate()
        Task {
            await proxy.start(sites: store.sites, enabledStaticSites: processes.enabledStaticSites)
            for site in store.sites where site.autoStart {
                await start(site)
            }
            await runResolverSelfTest()
        }
    }

    func shutdown() async {
        async let stopped: Void = processes.stopAll()
        async let proxyStopped: Void = proxy.stop()
        _ = await (stopped, proxyStopped)
        dns?.stop()
        dns = nil
        dnsState = .stopped
    }

    // MARK: - Site intents

    func start(_ site: Site) async {
        await processes.start(site)
        syncProxy()
    }

    func stop(_ site: Site) async {
        await processes.stop(site)
        syncProxy()
    }

    func toggle(_ site: Site) async {
        if isAnyProcessAlive(site) { await stop(site) } else { await start(site) }
    }

    func startAll() async {
        await withTaskGroup(of: Void.self) { group in
            for site in store.sites { group.addTask { await self.processes.start(site) } }
        }
        syncProxy()
    }

    func stopAll() async {
        await processes.stopAll()
        syncProxy()
    }

    func start(_ process: ProcessConfig, in site: Site) async {
        await processes.start(process, in: site)
        syncProxy()
    }

    func stop(_ process: ProcessConfig) async {
        await processes.stop(processID: process.id)
        syncProxy()
    }

    func restart(_ process: ProcessConfig, in site: Site) async {
        await processes.restart(process, in: site)
        syncProxy()
    }

    /// Saves the site, restarts running processes whose launch changed, and returns a one-line
    /// notice when something running was affected.
    @discardableResult
    func save(edited site: Site) async throws -> String? {
        let previous = store.site(id: site.id)
        try store.upsert(site)
        var notice: String?
        if let previous, isAnyProcessAlive(previous) {
            let restarted = await processes.apply(edited: site, previous: previous)
            notice = restarted.isEmpty ? "Saved. The proxy picked up the change." : "Saved. Restarted \(restarted.joined(separator: ", "))."
        }
        syncProxy()
        return notice
    }

    func delete(_ site: Site) async {
        await processes.stop(site)
        do {
            try store.delete(id: site.id)
        } catch {
            presentError("Could not delete \(site.name)", error)
        }
        syncProxy()
    }

    func duplicate(_ site: Site) {
        do {
            if let copy = try store.duplicate(id: site.id) {
                syncProxy()
                show(.editor(.edit(copy.id)))
            }
        } catch {
            presentError("Could not duplicate \(site.name)", error)
        }
    }

    // MARK: - Workspace intents

    func openURL(_ site: Site, process: ProcessConfig? = nil) {
        if let url = url(for: site, process: process) { NSWorkspace.shared.open(url) }
    }

    func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }

    func openInTerminal(_ path: String) {
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        workspace.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealLogs() {
        try? FileManager.default.createDirectory(at: configuration.logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(configuration.logsDirectory)
    }

    func openConfigFolder() {
        try? FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(configuration.supportDirectory)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    func show(_ window: AppWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if let windowRouter { windowRouter(window) } else { pendingWindows.append(window) }
    }

    // MARK: - Network intents

    func useAlternateProxyPort(_ port: Int) async {
        settings.proxyPort = port
        await restartProxy()
    }

    func restartProxy() async {
        await proxy.stop()
        await proxy.start(sites: store.sites, enabledStaticSites: processes.enabledStaticSites)
    }

    /// Applies edited ports, restarting only the servers whose port changed.
    func applyNetworkSettings(proxyPort: Int, dnsPort: Int, adminPort: Int) async {
        let proxyChanged = proxyPort != settings.proxyPort || adminPort != settings.caddyAdminPort
        let dnsChanged = dnsPort != settings.dnsPort
        settings.proxyPort = proxyPort
        settings.caddyAdminPort = adminPort
        settings.dnsPort = dnsPort
        if dnsChanged {
            startDNS()
            refreshResolverStatus()
            await runResolverSelfTest()
        }
        if proxyChanged { await restartProxy() }
    }

    func resetSettings() async {
        let old = (settings.proxyPort, settings.dnsPort, settings.caddyAdminPort)
        settings.resetToDefaults()
        if old.1 != settings.dnsPort {
            startDNS()
            refreshResolverStatus()
        }
        if old.0 != settings.proxyPort || old.2 != settings.caddyAdminPort { await restartProxy() }
    }

    /// The only caller of `ResolverInstaller.install`, reached from an explicit button.
    func installResolver() {
        isInstallingResolver = true
        resolverError = nil
        defer { isInstallingResolver = false }
        do {
            try ResolverInstaller.install(dnsPort: settings.dnsPort)
        } catch ResolverInstallError.cancelled {
            resolverError = "Cancelled. Nothing was changed."
        } catch ResolverInstallError.failed(let message) {
            resolverError = message
        } catch {
            resolverError = error.localizedDescription
        }
        refreshResolverStatus()
        Task { await runResolverSelfTest() }
    }

    /// Remembers "Not now" for the file as it is, so an unchanged foreign resolver is not raised again.
    func dismissResolverPrompt() {
        configuration.defaults.set(resolverContents ?? "", forKey: Self.dismissedResolverKey)
    }

    func refreshResolverStatus() {
        resolverContents = try? String(contentsOf: ResolverInstaller.resolverFile, encoding: .utf8)
        resolverStatus = ResolverInstaller.status(contents: resolverContents, dnsPort: settings.dnsPort)
    }

    func runResolverSelfTest() async {
        resolverSelfTest = await ResolverInstaller.selfTest()
    }

    var shouldPromptForResolver: Bool {
        switch resolverStatus {
        case .installed: false
        case .missing: true
        case .mismatched: configuration.defaults.string(forKey: Self.dismissedResolverKey) != (resolverContents ?? "")
        }
    }

    // MARK: - Private

    /// The one path that pushes site and static-enablement changes to Caddy.
    private func syncProxy() {
        proxy.apply(sites: store.sites, enabledStaticSites: processes.enabledStaticSites)
    }

    private func startDNS() {
        dns?.stop()
        dns = nil
        let port = settings.dnsPort
        guard PortChecker.isUDPPortFree(port) else {
            dnsState = .portInUse(port: port)
            return
        }
        let server = DNSServer(port: port)
        do {
            try server.start()
            dns = server
            dnsState = .running(port: port)
        } catch {
            dnsState = .failed(error.localizedDescription)
        }
    }

    private func processExitedUnexpectedly(site siteID: Site.ID, process processID: ProcessConfig.ID, code: Int32) {
        guard code != 0, settings.notifyOnCrash, configuration.isLive,
              let site = store.site(id: siteID), let process = site.processes.first(where: { $0.id == processID }) else { return }
        let lastLine = processes.buffer(for: processID).snapshot().lines.last { line in
            !line.hasPrefix("■") && !ANSIParser.runs(line).map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty
        }
        notifier.postExit(site: site, process: process, code: code, lastLine: lastLine.map { ANSIParser.runs($0).map(\.text).joined() })
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
