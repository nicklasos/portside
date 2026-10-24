import AppKit
import Observation

enum EditorTarget: Codable, Hashable {
    case new
    case edit(Site.ID)
}

enum AppWindow: Hashable {
    case editor(EditorTarget)
    /// `tab` selects a process or command tab. nil keeps the window's current tab.
    case logs(Site.ID, tab: UUID? = nil)
    case onboarding
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
        /// Where resolver files are read from. Writes always go to `/etc/resolver` through the admin prompt.
        var resolverDirectory: URL
        var probes: SuffixProbes
        /// False for the unit-test host: no servers at launch, no notifications, no updater.
        var isLive: Bool

        static let live = Configuration(
            defaults: .standard, supportDirectory: AppPaths.supportDirectory, logsDirectory: AppPaths.logsDirectory,
            resolverDirectory: ResolverInstaller.directory, probes: .live, isLive: true
        )

        static func isolated(in directory: URL) -> Configuration {
            Configuration(
                defaults: UserDefaults(suiteName: "portside-\(UUID().uuidString)")!,
                supportDirectory: directory.appendingPathComponent("support", isDirectory: true),
                logsDirectory: directory.appendingPathComponent("logs", isDirectory: true),
                resolverDirectory: directory.appendingPathComponent("resolver", isDirectory: true),
                probes: SuffixProbes(lookup: { _ in [[127, 0, 0, 1]] }, fetch: { _, _ in .unreachable("Not live") }),
                isLive: false
            )
        }

        static var forCurrentProcess: Configuration {
            #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "PortsideSupportDirectory") {
                var config = Configuration.live
                config.supportDirectory = URL(fileURLWithPath: path, isDirectory: true)
                config.logsDirectory = config.supportDirectory.appendingPathComponent("logs", isDirectory: true)
                return config
            }
            #endif
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
    /// nil while the probe for the current suffix runs.
    private(set) var resolution: ResolutionStrategy?
    private(set) var resolverStatus: ResolverStatus = .missing
    /// What `/etc/resolver/<suffix>` holds now, shown when another tool owns the suffix.
    private(set) var resolverContents: String?
    /// Portside's own resolver files for suffixes no longer in use, which the user may remove.
    private(set) var staleResolvers: [DomainSuffix] = []
    /// Set after a suffix change while processes run with the old `PORTSIDE_URL`.
    private(set) var domainNotice: String?
    /// nil until the end-to-end check has run for the current suffix.
    private(set) var endToEnd: CheckLine?
    private(set) var isCheckingEndToEnd = false
    private(set) var resolverError: String?
    private(set) var isInstallingResolver = false
    /// The selected tab of each site's logs window, so a request can open the window on a given tab.
    var logTabs: [Site.ID: UUID] = [:]

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

    private var dismissedResolverKey: String { "resolverPromptDismissedContents.\(settings.domainSuffix.label)" }

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
        processes.onCommandFinished = { [weak self] site, command, code in
            self?.commandFinished(site: site, command: command, code: code)
        }
        notifier.onShowLogs = { [weak self] id, tab in self?.show(.logs(id, tab: tab)) }
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

    func domain(for site: Site, process: ProcessConfig? = nil) -> String? {
        site.domain(for: process ?? site.main, in: settings.domainSuffix)
    }

    func url(for site: Site, process: ProcessConfig? = nil) -> URL? {
        domain(for: site, process: process).map(settings.url(forDomain:))
    }

    /// The suffix needs Portside's resolver file and it is not in place yet.
    var needsResolverSetup: Bool {
        resolution == .portsideDNS && resolverStatus != .installed
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard configuration.isLive, !didBootstrap else { return }
        didBootstrap = true
        notifier.activate()
        if !settings.hasChosenDomainSuffix { show(.onboarding) }
        Task {
            async let proxyStarted: Void = proxy.start(sites: store.sites, enabledStaticSites: processes.enabledStaticSites)
            await refreshResolution()
            if settings.hasChosenDomainSuffix, shouldPromptForResolver { show(.resolverSetup) }
            await proxyStarted
            for site in store.sites where site.autoStart {
                await start(site)
            }
            await runEndToEndCheck()
        }
    }

    func shutdown() async {
        async let stopped: Void = processes.stopAll()
        async let proxyStopped: Void = proxy.stop()
        _ = await (stopped, proxyStopped)
        stopDNS()
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
        if let previous {
            let wasRunning = isAnyProcessAlive(previous)
            let restarted = await processes.apply(edited: site, previous: previous)
            if wasRunning {
                notice = restarted.isEmpty ? "Saved. The proxy picked up the change." : "Saved. Restarted \(restarted.joined(separator: ", "))."
            }
        }
        syncProxy()
        return notice
    }

    func delete(_ site: Site) async {
        await processes.stop(site)
        for command in site.commands { await processes.stop(processID: command.id) }
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

    // MARK: - Command intents

    func isRunning(_ command: SiteCommand) -> Bool {
        processes.state(of: command.id).isAlive
    }

    func run(_ command: SiteCommand, in site: Site) async {
        await processes.run(command, in: site)
        if command.showsLogs { show(.logs(site.id, tab: command.id)) }
    }

    func stopCommand(_ command: SiteCommand) async {
        await processes.stop(processID: command.id)
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
        if case .logs(let site, let tab?) = window { logTabs[site] = tab }
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
        endToEnd = nil
    }

    /// Applies edited ports, restarting only the servers whose port changed.
    func applyNetworkSettings(proxyPort: Int, dnsPort: Int, adminPort: Int) async {
        let proxyChanged = proxyPort != settings.proxyPort || adminPort != settings.caddyAdminPort
        let dnsChanged = dnsPort != settings.dnsPort
        settings.proxyPort = proxyPort
        settings.caddyAdminPort = adminPort
        settings.dnsPort = dnsPort
        if dnsChanged { await refreshResolution() }
        if proxyChanged { await restartProxy() }
    }

    func resetSettings() async {
        let old = (settings.proxyPort, settings.dnsPort, settings.caddyAdminPort)
        settings.resetToDefaults()
        if old.1 != settings.dnsPort { await refreshResolution() }
        if old.0 != settings.proxyPort || old.2 != settings.caddyAdminPort { await restartProxy() }
    }

    /// Moves every domain to `suffix` and sets up resolution for it. Running processes keep the
    /// `PORTSIDE_URL` they started with, so the user is told to restart them.
    func chooseDomainSuffix(_ suffix: DomainSuffix) async {
        settings.hasChosenDomainSuffix = true
        if suffix != settings.domainSuffix {
            settings.domainSuffix = suffix
            syncProxy()
            domainNotice = store.sites.contains(where: isAnyProcessAlive) ? "Restart running sites to update PORTSIDE_URL." : nil
        }
        await refreshResolution()
    }

    /// Probes how the current suffix resolves, then runs Portside's DNS server only when macOS needs it.
    func refreshResolution() async {
        let suffix = settings.domainSuffix
        resolution = nil
        endToEnd = nil
        let strategy = await usability(of: suffix).strategy
        guard suffix == settings.domainSuffix else { return }
        resolution = strategy
        switch strategy {
        case .system: stopDNS()
        case .portsideDNS: startDNS(zone: suffix.label)
        }
        refreshResolverStatus()
    }

    func usability(of suffix: DomainSuffix) async -> SuffixUsability {
        await SuffixUsability.evaluate(suffix, resolverContents: resolverContents(for: suffix), dnsPort: settings.dnsPort, lookup: configuration.probes.lookup)
    }

    /// Resolves the self-test name and fetches it through the proxy, as a browser would.
    func runEndToEndCheck() async {
        guard let resolution else { return }
        isCheckingEndToEnd = true
        defer { isCheckingEndToEnd = false }
        endToEnd = await EndToEndCheck.run(
            suffix: settings.domainSuffix, strategy: resolution, proxyPort: settings.proxyPort,
            proxyState: proxy.state, probes: configuration.probes
        )
        if configuration.isLive, let endToEnd { NSLog("Portside: end-to-end check for %@: %@", settings.domainSuffix.display, endToEnd.text) }
    }

    func resolverStatus(for suffix: DomainSuffix) -> ResolverStatus {
        ResolverInstaller.status(contents: resolverContents(for: suffix), dnsPort: settings.dnsPort)
    }

    /// The only caller of `ResolverInstaller.install`, reached from an explicit button.
    func installResolver() {
        runAdminAction { try ResolverInstaller.install(suffix: settings.domainSuffix, dnsPort: settings.dnsPort) }
        Task { await runEndToEndCheck() }
    }

    /// The only caller of `ResolverInstaller.uninstall`, offered only for Portside's own stale files.
    func removeResolver(for suffix: DomainSuffix) {
        guard staleResolvers.contains(suffix) else { return }
        runAdminAction { try ResolverInstaller.uninstall(suffix: suffix, dnsPort: settings.dnsPort) }
    }

    /// Remembers "Not now" for the file as it is, so an unchanged foreign resolver is not raised again.
    func dismissResolverPrompt() {
        configuration.defaults.set(resolverContents ?? "", forKey: dismissedResolverKey)
    }

    func refreshResolverStatus() {
        let current = settings.domainSuffix
        resolverContents = resolverContents(for: current)
        resolverStatus = ResolverInstaller.status(contents: resolverContents, dnsPort: settings.dnsPort)
        let labels = (try? FileManager.default.contentsOfDirectory(atPath: configuration.resolverDirectory.path)) ?? []
        staleResolvers = labels.sorted().compactMap(DomainSuffix.stored).filter { $0 != current && resolverStatus(for: $0) == .installed }
    }

    var shouldPromptForResolver: Bool {
        guard resolution == .portsideDNS else { return false }
        switch resolverStatus {
        case .installed: return false
        case .missing: return true
        case .mismatched: return configuration.defaults.string(forKey: dismissedResolverKey) != (resolverContents ?? "")
        }
    }

    // MARK: - Private

    /// The one path that pushes site and static-enablement changes to Caddy.
    private func syncProxy() {
        proxy.apply(sites: store.sites, enabledStaticSites: processes.enabledStaticSites)
    }

    private func resolverContents(for suffix: DomainSuffix) -> String? {
        try? String(contentsOf: ResolverInstaller.resolverFile(for: suffix, in: configuration.resolverDirectory), encoding: .utf8)
    }

    private func runAdminAction(_ action: () throws -> Void) {
        isInstallingResolver = true
        resolverError = nil
        defer { isInstallingResolver = false }
        do {
            try action()
        } catch ResolverInstallError.cancelled {
            resolverError = "Cancelled. Nothing was changed."
        } catch ResolverInstallError.failed(let message) {
            resolverError = message
        } catch {
            resolverError = error.localizedDescription
        }
        refreshResolverStatus()
    }

    /// Keeps a server that already answers this zone on this port.
    private func startDNS(zone: String) {
        let port = settings.dnsPort
        if let dns, dns.zone == zone, dns.port == port { return }
        stopDNS()
        guard PortChecker.isUDPPortFree(port) else {
            dnsState = .portInUse(port: port)
            return
        }
        let server = DNSServer(port: port, zone: zone)
        do {
            try server.start()
            dns = server
            dnsState = .running(port: server.boundPort ?? port)
        } catch {
            dnsState = .failed(error.localizedDescription)
        }
    }

    private func stopDNS() {
        dns?.stop()
        dns = nil
        dnsState = .stopped
    }

    private func processExitedUnexpectedly(site siteID: Site.ID, process processID: ProcessConfig.ID, code: Int32) {
        guard code != 0, settings.notifyOnCrash, configuration.isLive,
              let site = store.site(id: siteID), let process = site.processes.first(where: { $0.id == processID }) else { return }
        notifier.postExit(site: site, process: process, code: code, lastLine: lastOutputLine(of: processID))
    }

    /// Commands that open the logs window need no notification, since their output is on screen.
    private func commandFinished(site siteID: Site.ID, command commandID: SiteCommand.ID, code: Int32) {
        guard configuration.isLive, let site = store.site(id: siteID),
              let command = site.commands.first(where: { $0.id == commandID }), !command.showsLogs else { return }
        notifier.postCommandFinished(site: site, command: command, code: code, lastLine: lastOutputLine(of: commandID))
    }

    /// The last line the program printed, without color codes, skipping Portside's own lines.
    private func lastOutputLine(of id: UUID) -> String? {
        let line = processes.buffer(for: id).snapshot().lines.last { line in
            !line.hasPrefix("■") && !ANSIParser.runs(line).map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty
        }
        return line.map { ANSIParser.runs($0).map(\.text).joined() }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
