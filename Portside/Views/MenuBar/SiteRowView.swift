import SwiftUI

struct SiteRowView: View {
    let site: Site
    @Environment(PortsideController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var hovering = false

    var body: some View {
        let status = controller.status(of: site)
        HStack(spacing: 10) {
            StatusDot(status)
                .help(tooltip)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(domainsLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                primaryControl
                IconButton("text.alignleft", help: "Logs") {
                    controller.show(.logs(site.id))
                    dismiss()
                }
                IconButton("arrow.up.right.square", help: "Open \(controller.url(for: site)?.absoluteString ?? site.name)") {
                    controller.openURL(site)
                }
                moreMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if site.isStatic {
            Toggle("", isOn: Binding(
                get: { controller.isAnyProcessAlive(site) },
                set: { _ in Task { await controller.toggle(site) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(controller.isAnyProcessAlive(site) ? "Stop serving \(site.folder)" : "Serve \(site.folder)")
            .padding(.trailing, 4)
        } else if controller.isAnyProcessAlive(site) {
            IconButton("stop.fill", help: "Stop") { Task { await controller.stop(site) } }
        } else {
            IconButton("play.fill", help: "Start") { Task { await controller.start(site) } }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Edit…") {
                controller.show(.editor(.edit(site.id)))
                dismiss()
            }
            Button("Open Folder") { controller.openFolder(site.folder) }
            Button("Open in Terminal") { controller.openInTerminal(site.folder) }
            Button("Duplicate") {
                controller.duplicate(site)
                dismiss()
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete() }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private var domainsLine: String {
        site.processes.compactMap { controller.domain(for: site, process: $0) }.joined(separator: " · ")
    }

    private var tooltip: String {
        site.processes.map { p in
            let name = p.label.isEmpty ? p.command : p.label
            let state = controller.processes.state(of: p.id)
            return "\(name.isEmpty ? "Static files" : name): \(p.isStatic && state == .running ? "Serving" : state.summary)"
        }.joined(separator: "\n")
    }

    private func confirmDelete() {
        dismiss()
        let alert = NSAlert()
        alert.messageText = "Delete \(site.name)?"
        alert.informativeText = "Its processes are stopped and \(controller.domain(for: site) ?? site.name) stops resolving to it. The folder on disk is not touched."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await controller.delete(site) }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
