import SwiftUI

struct MenuBarView: View {
    @Environment(PortsideController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            banners
            siteList
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Portside")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            IconButton("gearshape", help: "Settings…") { open(.settings) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var banners: some View {
        let items = bannerItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.message) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(item.message)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let action = item.action {
                            Button(action.title, action: action.run)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
    }

    @ViewBuilder
    private var siteList: some View {
        if controller.store.sites.isEmpty {
            Text("No sites yet. Add one to get started.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(controller.store.sites) { site in
                    SiteRowView(site: site)
                }
            }
            .padding(4)
            if controller.store.sites.count > Self.visibleRows {
                ScrollView { rows }
                    .frame(height: Self.rowHeight * CGFloat(Self.visibleRows))
            } else {
                rows
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow("Add Site…", systemImage: "plus", shortcut: "⌘N") { open(.editor(.new)) }
                .keyboardShortcut("n")
            HStack(spacing: 0) {
                MenuRow("Start All", systemImage: "play") { Task { await controller.startAll() } }
                    .disabled(controller.store.sites.isEmpty)
                MenuRow("Stop All", systemImage: "stop") { Task { await controller.stopAll() } }
                    .disabled(!controller.menuBarStatus.isActive)
            }
            Divider().padding(.vertical, 4)
            MenuRow("Check for Updates…") {
                dismiss()
                controller.checkForUpdates()
            }
            .disabled(!controller.updater.isConfigured)
            .help(controller.updater.isConfigured ? "" : "Updates are disabled in this build (no Sparkle signing key)")
            MenuRow("Settings…", shortcut: "⌘,") { open(.settings) }
                .keyboardShortcut(",")
            MenuRow("Quit Portside", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(4)
    }

    private func open(_ window: AppWindow) {
        dismiss()
        controller.show(window)
    }

    private struct Banner {
        struct Action {
            var title: String
            var run: () -> Void
        }

        var message: String
        var action: Action?
    }

    private var bannerItems: [Banner] {
        var items: [Banner] = []
        let port = controller.settings.proxyPort
        switch controller.proxy.state {
        case .portConflict(let owner):
            let who = owner.map { "\($0.command) (pid \($0.pid))" } ?? "another app"
            let alternate = port == 8080 ? 8081 : 8080
            items.append(Banner(message: "Port \(port) is used by \(who)", action: .init(title: "Use port \(alternate)") {
                Task { await controller.useAlternateProxyPort(alternate) }
            }))
        case .failed(let reason):
            items.append(Banner(message: "Proxy stopped: \(reason)", action: .init(title: "Retry") {
                Task { await controller.restartProxy() }
            }))
        case .stopped, .starting, .running:
            break
        }
        switch controller.dnsState {
        case .portInUse(let p):
            items.append(Banner(message: "DNS port \(p) is in use. Pick another in Settings.", action: .init(title: "Settings…") { open(.settings) }))
        case .failed(let reason):
            items.append(Banner(message: "DNS server failed: \(reason)", action: nil))
        case .stopped, .running:
            break
        }
        if controller.configuration.isLive, controller.resolverStatus != .installed {
            let message = controller.resolverStatus == .missing
                ? ".test domains are not set up yet"
                : "Another tool answers .test lookups"
            items.append(Banner(message: message, action: .init(title: "Details…") { open(.resolverSetup) }))
        }
        if let error = controller.store.loadError {
            items.append(Banner(message: error, action: nil))
        }
        return items
    }
}

/// A full-width, menu-like row with hover highlight and an optional shortcut hint.
struct MenuRow: View {
    let title: String
    var systemImage: String?
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 14)
                }
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && isEnabled ? Color.accentColor.opacity(0.85) : .clear))
            .foregroundStyle(hovering && isEnabled ? Color.white : Color.primary)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
