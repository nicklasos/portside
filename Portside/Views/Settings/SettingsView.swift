import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings()
                .tabItem { Label("Network", systemImage: "network") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(PortsideController.self) private var controller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = controller.settings
        @Bindable var updater = controller.updater
        Form {
            Toggle("Launch Portside at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            if let loginError {
                FieldMessage(text: loginError, isError: true)
            }
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                .disabled(!updater.isConfigured)
                .help(updater.isConfigured ? "" : "Updates are disabled in this build (no Sparkle signing key)")
            Toggle("Notify when a process exits unexpectedly", isOn: $settings.notifyOnCrash)
            Toggle("Mirror logs to ~/Library/Logs/Portside", isOn: $settings.mirrorLogsToDisk)
                .help("Takes effect the next time a process starts")
            LabeledContent("Portside") {
                Text(UpdaterService.versionDescription).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(height: 280)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct NetworkSettings: View {
    @Environment(PortsideController.self) private var controller
    @State private var proxyPort = ""
    @State private var dnsPort = ""
    @State private var isApplying = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Proxy port") {
                    HStack {
                        portField($proxyPort)
                        Text(proxyStatus).foregroundStyle(.secondary).font(.system(size: 11))
                    }
                }
                LabeledContent("DNS port") {
                    HStack {
                        portField($dnsPort)
                        Text(dnsStatus).foregroundStyle(.secondary).font(.system(size: 11))
                    }
                }
                HStack {
                    Spacer()
                    Button("Apply", action: apply)
                        .disabled(!hasChanges || parsed == nil || isApplying)
                }
            } footer: {
                Text("Port 80 gives plain `http://site.test` URLs. Any other port appears in every URL, such as `site.test:8080`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Resolver") {
                LabeledContent("/etc/resolver/test") {
                    Text(resolverLine).foregroundStyle(controller.resolverStatus == .installed ? Color.secondary : Color.orange)
                }
                LabeledContent("Self-test") {
                    HStack {
                        Text(selfTestLine).foregroundStyle(.secondary)
                        Button("Run") { Task { await controller.runResolverSelfTest() } }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button(controller.resolverStatus == .installed ? "Details…" : "Repair…") {
                        controller.refreshResolverStatus()
                        controller.show(.resolverSetup)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
        .onAppear(perform: load)
    }

    private func portField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .labelsHidden()
    }

    private func load() {
        proxyPort = String(controller.settings.proxyPort)
        dnsPort = String(controller.settings.dnsPort)
        controller.refreshResolverStatus()
    }

    private var parsed: (proxy: Int, dns: Int)? {
        guard let p = Int(proxyPort), let d = Int(dnsPort), (1...65535).contains(p), (1...65535).contains(d) else { return nil }
        return (p, d)
    }

    private var hasChanges: Bool {
        parsed.map { $0.proxy != controller.settings.proxyPort || $0.dns != controller.settings.dnsPort } ?? true
    }

    private func apply() {
        guard let parsed else { return }
        isApplying = true
        Task {
            await controller.applyNetworkSettings(proxyPort: parsed.proxy, dnsPort: parsed.dns, adminPort: controller.settings.caddyAdminPort)
            isApplying = false
        }
    }

    private var proxyStatus: String {
        switch controller.proxy.state {
        case .running: "Caddy running"
        case .starting: "Starting…"
        case .stopped: "Stopped"
        case .portConflict(let owner): "In use by \(owner.map { "\($0.command) (pid \($0.pid))" } ?? "another app")"
        case .failed(let reason): reason
        }
    }

    private var dnsStatus: String {
        switch controller.dnsState {
        case .running: "Answering *.test"
        case .stopped: "Stopped"
        case .portInUse: "In use by another app"
        case .failed(let reason): reason
        }
    }

    private var resolverLine: String {
        switch controller.resolverStatus {
        case .installed: "Installed, points to Portside"
        case .missing: "Not installed"
        case .mismatched: "Points elsewhere (another tool?)"
        }
    }

    private var selfTestLine: String {
        switch controller.resolverSelfTest {
        case true?: "Responding"
        case false?: "Not resolving through Portside"
        case nil: "Not run"
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(PortsideController.self) private var controller
    @State private var adminPort = ""
    @State private var showsCaddyLog = false

    var body: some View {
        Form {
            LabeledContent("Caddy admin port") {
                HStack {
                    TextField("", text: $adminPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .labelsHidden()
                    Button("Apply") {
                        guard let port = Int(adminPort), (1...65535).contains(port) else { return }
                        Task {
                            await controller.applyNetworkSettings(proxyPort: controller.settings.proxyPort, dnsPort: controller.settings.dnsPort, adminPort: port)
                        }
                    }
                    .disabled(Int(adminPort) == controller.settings.caddyAdminPort || !(1...65535).contains(Int(adminPort) ?? 0))
                }
            }
            LabeledContent("Files") {
                HStack {
                    Button("Open Config Folder") { controller.openConfigFolder() }
                    Button("Reveal Logs Folder") { controller.revealLogs() }
                }
            }
            DisclosureGroup("Caddy log", isExpanded: $showsCaddyLog) {
                ScrollView {
                    Text(controller.proxy.caddyLog.suffix(200).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults…", role: .destructive, action: confirmReset)
            }
        }
        .formStyle(.grouped)
        .frame(height: showsCaddyLog ? 400 : 240)
        .onAppear { adminPort = String(controller.settings.caddyAdminPort) }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Portside settings?"
        alert.informativeText = "Ports and preferences go back to their defaults. Your sites are kept."
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await controller.resetSettings()
            adminPort = String(controller.settings.caddyAdminPort)
        }
    }
}
